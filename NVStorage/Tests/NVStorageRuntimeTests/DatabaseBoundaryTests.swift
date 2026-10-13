import NVStorageTestSupport
import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

@Test(arguments: [false, true])
func cipherSchemaRequiresIntegralHistoryTags(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let session = try await newSession(initial, protection), before = try await session.snapshot()
    let selection = await session.selection, lane = await session.lane
    for (table, identifier, fractional) in [("operations", "operation_id", "3.5"), ("actions", "action_id", "4.5")] {
        let query = "SELECT \(identifier), kind FROM \(table) ORDER BY \(identifier)"
        let original = try await lane.perform { try $0.rows(query) }
        try #require(!original.isEmpty)
        do {
            try await lane.perform { try $0.exec("UPDATE \(table) SET kind=\(fractional)") }
            Issue.record("Fractional history tag admitted")
        } catch StorageError.database(let code) {
            #expect(code & 0xff == 19)
        }
        #expect(try await lane.perform { try $0.rows(query) } == original)
    }
    #expect(try await session.snapshot().notes == before.notes)
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes == before.notes)
    #expect(try await reopened.snapshot().through == before.through)
    try await reopened.quiesce()
}

@Test func ownedEncryptedCandidateBoundary() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let key = try PrivateDatabaseKeyV1.derive(collection: CollectionID(bytes: Array(repeating: 1, count: 16)), protection: .publicHash)
    let lane = DatabaseLane()
    try await lane.open(directory: path, create: true, key: key)
    try await lane.perform { db in try db.exec("CREATE TABLE probe (id INTEGER PRIMARY KEY); INSERT INTO probe VALUES(42);") }
    let other = DatabaseLane()
    do { try await other.open(directory: path, create: false, key: key); Issue.record("Second owner was admitted") }
    catch StorageError.ownership { }
    await lane.close()
    let disk = try Data(contentsOf: URL(fileURLWithPath: path + "/Collection.sqlite"))
    #expect(!disk.starts(with: Array("SQLite format 3".utf8)))
    try await other.open(directory: path, create: false, key: key)
    #expect(try await other.perform { try $0.rows("SELECT id FROM probe") } == [[.integer(42)]])
    await other.close()
    do { try await lane.open(directory: path, create: false, key: Array(repeating: 99, count: 32)); Issue.record("Wrong key was admitted") }
    catch StorageError.database { }
    try await other.open(directory: path, create: false, key: key)
    #expect(try await other.perform { try $0.rows("SELECT id FROM probe") } == [[.integer(42)]])
    await other.close()
}

/// Returning from this helper releases the sole live actor reference.
private func createAbandonedStore(path: String, key: [UInt8]) async throws {
    let owner = DatabaseLane()
    try await owner.open(directory: path, create: true, key: key)
    try await owner.perform { try $0.exec("CREATE TABLE abandoned(id INTEGER); INSERT INTO abandoned VALUES(42)") }
}

@Test(.timeLimit(.minutes(1))) func abandonedDatabaseOwnerReleasesLeaseAndPreservesRows() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let key = [UInt8](repeating: 37, count: 32), reopened = DatabaseLane()
    try await createAbandonedStore(path: path, key: key)
    let deadline = Date().addingTimeInterval(10)
    while true {
        do { try await reopened.open(directory: path, create: false, key: key); break }
        catch StorageError.ownership(let code) where code == EWOULDBLOCK && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    #expect(try await reopened.perform { try $0.rows("SELECT id FROM abandoned") } == [[.integer(42)]])
    await reopened.close()
    await #expect(throws: StorageError.closed) { try await reopened.perform { try $0.rows("SELECT 1") } }
}

/// Exercises final disposal while execution is already on the connection's owning queue.
private actor ScopedDatabaseOwner {
    nonisolated let executor = StorageExecutor(label: "NVStorageTests.scoped-disposal")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    func createAndRelease(path: String, key: [UInt8]) throws {
        let database = try Database(directory: path, create: true, key: key, executor: executor)
        try database.exec("CREATE TABLE scoped_disposal(id INTEGER); INSERT INTO scoped_disposal VALUES(43)")
    }
}

@Test(.timeLimit(.minutes(1))) func databaseDisposalOnOwningQueueReleasesImmediately() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let key = [UInt8](repeating: 39, count: 32), owner = ScopedDatabaseOwner()
    try await owner.createAndRelease(path: path, key: key)
    let reopened = DatabaseLane()
    try await reopened.open(directory: path, create: false, key: key)
    #expect(try await reopened.perform { try $0.rows("SELECT id FROM scoped_disposal") } == [[.integer(43)]])
    await reopened.close()
}

@Test(arguments: ["directory-replaced", "database-replaced", "hard-link"])
func livePhysicalOwnershipIsRechecked(change: String) async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let key = try PrivateDatabaseKeyV1.derive(collection: CollectionID(bytes: Array(repeating: 1, count: 16)), protection: .publicHash)
    let lane = DatabaseLane()
    try await lane.open(directory: path, create: true, key: key)
    try await lane.perform { try $0.exec("CREATE TABLE probe (id INTEGER PRIMARY KEY); INSERT INTO probe VALUES(42)") }
    let file = path + "/Collection.sqlite"
    switch change {
    case "directory-replaced":
        try FileManager.default.moveItem(atPath: path, toPath: path + ".previous")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    case "database-replaced":
        try FileManager.default.moveItem(atPath: file, toPath: file + ".previous")
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: file))
    default: try FileManager.default.linkItem(atPath: file, toPath: file + ".alias")
    }
    do { _ = try await lane.perform { try $0.rows("SELECT id FROM probe") }; Issue.record("Lost physical ownership accepted") }
    catch StorageError.ownership { }
    await lane.close()
}

@Test(arguments: ["directory-link", "file-link", "file-directory", "embedded-nul"])
func unsafeCandidatePathsAreRejected(kind: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: false)
    let lane = DatabaseLane(), key = [UInt8](repeating: 4, count: 32)
    var path = root + "/private"
    switch kind {
    case "directory-link": try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: root)
    case "embedded-nul": path += "\0suffix"
    default:
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        if kind == "file-link" {
            try FileManager.default.createSymbolicLink(atPath: path + "/Collection.sqlite", withDestinationPath: root + "/missing")
        } else { try FileManager.default.createDirectory(atPath: path + "/Collection.sqlite", withIntermediateDirectories: false) }
    }
    do { try await lane.open(directory: path, create: false, key: key); Issue.record("Unsafe path admitted") }
    catch StorageError.ownership { #expect(kind != "embedded-nul") }
    catch StorageError.wrongContext { #expect(kind == "embedded-nul") }
}
