import NVStorageTestSupport
import Foundation
import Crypto
import Testing
import NVStorageCore
@testable import NVStorageRuntime

func repositoryDirectory() throws -> String {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nv-exchange-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url.path
}

func publishRepository(_ source: LocalStoreSession, to root: RepositoryRootSession,
                       maximumObjects: Int = 2) async throws -> [ImmutableRepositoryLocator] {
    let permission = try await root.permission()
    var cursor: RepositoryPublicationCursor?, result: [ImmutableRepositoryLocator] = []
    repeat {
        let batch = try await source.captureRepositoryPublication(continuing: cursor, maximumObjects: maximumObjects)
        guard case .complete(let published) = try await root.publish(batch, from: source, using: permission) else {
            throw StorageError.incomplete
        }
        try await root.validate(published, from: source, using: permission)
        result += published.locators; cursor = batch.continuation
    } while cursor != nil
    return result
}

@Test(arguments: [false, true])
func repositoryPublicationRequiresAcceptedDependencyMembership(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let edit = try await put("requires exact parent", birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1, session: source)
    let lane = await source.lane
    #expect(try await source.captureRepositoryPublication(maximumObjects: 64).locators.contains(.segment(edit.object)))
    let parent = try await lane.perform { try $0.rows("SELECT prerequisite FROM accepted_dependencies WHERE child=? LIMIT 1",
        [.blob(edit.object.segmentID.bytes)])[0][0].bytes }
    try await lane.perform { db in
        try db.run("PRAGMA foreign_keys=OFF")
        try db.run("DELETE FROM accepted_objects WHERE object_id=?", [.blob(parent)])
        try db.run("PRAGMA foreign_keys=ON")
    }
    await #expect(throws: StorageError.incomplete) { try await source.captureRepositoryPublication(maximumObjects: 64) }
    let selection = await source.selection
    try await source.quiesce()
    let inspection = DatabaseLane()
    try await inspection.open(directory: selection.directory, create: false,
        key: PrivateDatabaseKeyV1.derive(collection: initial.descriptor.collection, protection: protection))
    #expect(try await inspection.perform { try $0.rows("SELECT payload FROM private_groups WHERE group_key=?",
        [.blob(Array("history-damage".utf8))]) } == [[.blob([])]])
    #expect(try await inspection.perform { try $0.rows("SELECT 1 FROM objects WHERE object_id=?", [.blob(parent)]) } == [[.integer(1)]])
    await inspection.close()
}

@Test(arguments: [false, true]) func repositoryPublicationNextPassSelectsOnlyNewAcceptedObjects(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let root = try await RepositoryRootSession.open(directory: repositoryDirectory()), permission = try await root.permission()
    var cursor: RepositoryPublicationCursor?, next: RepositoryPublicationCursor?
    repeat {
        let batch = try await source.captureRepositoryPublication(continuing: cursor, maximumObjects: 2)
        guard case .complete = try await root.publish(batch, from: source, using: permission) else { throw StorageError.incomplete }
        #expect((batch.nextPass == nil) == (batch.continuation != nil))
        cursor = batch.continuation; next = batch.nextPass
    } while cursor != nil
    let nextCursor = try #require(next)
    let empty = try await source.captureRepositoryPublication(continuing: nextCursor)
    #expect(empty.locators.isEmpty && empty.through == 1)
    let edit = try await put("only new object", birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1, session: source)
    let lane = await source.lane
    try await lane.perform { $0.work = StorageWork() }
    let laterCursor = try #require(empty.nextPass)
    let later = try await source.captureRepositoryPublication(continuing: laterCursor)
    let work = try await lane.perform { db in let work = db.work!; db.work = nil; return work }
    #expect(later.locators == [.segment(edit.object)] && later.through == 2)
    #expect(work.stages.values.reduce(0) { $0 + $1.historyReads } == 1)
    guard case .complete = try await root.publish(later, from: source, using: permission) else { throw StorageError.incomplete }
    let unrelated = try await newSession(initial, protection)
    await #expect(throws: StorageError.wrongContext) { try await unrelated.captureRepositoryPublication(continuing: later.nextPass) }
    try await unrelated.quiesce(); try await source.quiesce(); await root.close()
}

@Test(arguments: [false, true]) func repositoryPublicationCapturesExactBoundedPrefix(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission(), lane = await source.lane
    let expected = initial.objects.values.map { $0 } + [initial.descriptor.encodedBytes]
    var cursor: RepositoryPublicationCursor?, paths: [String] = [], first = true
    repeat {
        let batch = try await source.captureRepositoryPublication(continuing: cursor, maximumObjects: 2, byteBudget: 1)
        #expect(batch.through == 1)
        #expect(batch.locators.count == 1, "An oversized first object makes bounded forward progress")
        guard case .complete(let published) = try await root.publish(batch, from: source, using: permission) else {
            Issue.record("Accepted bytes require complete installation"); return
        }
        paths += published.locators.map(\.relativePath)
        if first {
            _ = try await put("newer than capture", birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1, session: source)
            first = false
        }
        cursor = batch.continuation
    } while cursor != nil
    #expect(paths.count == expected.count && Set(paths).count == expected.count)
    let installed = try paths.map { try Array(Data(contentsOf: URL(fileURLWithPath: path + "/" + $0))) }
    #expect(Set(installed) == Set(expected))
    let ids = try await lane.perform { try $0.rows("SELECT object_id FROM accepted_objects WHERE seq=1") }.map { try $0[0].bytes }
    #expect(Set(ids) == Set(expected.map { Array(SHA256.hash(data: $0)) }))
    #expect(try await source.captureRepositoryPublication().through == 2)
    await root.close(); try await source.quiesce()
}

@Test(arguments: [false, true]) func repositoryPublicationRetryAndWrongConsumers(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let other = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let batch = try await source.captureRepositoryPublication(maximumObjects: 1), permission = try await root.permission()
    let target = URL(fileURLWithPath: path + "/" + batch.locators[0].relativePath)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([90, 91]).write(to: target)
    await #expect(throws: StorageError.wrongContext) { try await root.publish(batch, from: other, using: permission) }
    guard case .incomplete(let installed, let failure) = try await root.publish(batch, from: source, using: permission) else {
        Issue.record("Conflicting final requires preserved retry"); return
    }
    #expect(installed.isEmpty && failure.reason == .conflict)
    #expect(try Data(contentsOf: target) == Data([90, 91]))
    try FileManager.default.moveItem(at: target, to: target.appendingPathExtension("preserved"))
    guard case .complete(let completed) = try await root.publish(batch, from: source, using: permission),
          case .complete = try await root.publish(batch, from: source, using: permission) else {
        Issue.record("Exact retained capture must retry and reuse its final"); return
    }
    let otherRoot = try await RepositoryRootSession.open(directory: repositoryDirectory())
    await #expect(throws: RepositoryRootError.wrongContext) { try await otherRoot.validate(completed, from: source, using: otherRoot.permission()) }
    await #expect(throws: StorageError.wrongContext) { try await root.validate(completed, from: other, using: permission) }
    await #expect(throws: StorageError.wrongContext) { try await other.captureRepositoryPublication(continuing: batch.continuation) }
    let selection = await source.selection
    try await source.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await root.publish(batch, from: reopened, using: permission) }
    await #expect(throws: StorageError.wrongContext) { try await reopened.captureRepositoryPublication(continuing: batch.continuation) }
    await root.invalidate()
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.publish(batch, from: reopened, using: permission) }
    await root.close(); await otherRoot.close(); try await other.quiesce(); try await reopened.quiesce()
}

@Test(arguments: [false, true]) func repositoryPublicationSelectionWorkRemainsBounded(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let lane = await source.lane, birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    var count = 0
    for size in [64, 256, 1024] {
        while count < size { count += 1; _ = try await put("history \(count)", birth: birth, generation: UInt64(count), session: source) }
        try await lane.perform { $0.work = StorageWork() }
        let batch = try await source.captureRepositoryPublication(maximumObjects: 3)
        let work = try await lane.perform { db in let result = db.work!; db.work = nil; return result }
        #expect(batch.locators.count == 3 && batch.continuation != nil)
        #expect(work.stages.values.reduce(0) { $0 + $1.historyReads } == 3)
        #expect(work.stages.values.reduce(0) { $0 + $1.ancestors } == 0)
        let sql = "SELECT a.seq,a.object_id,length(o.encoded) FROM accepted_objects a LEFT JOIN objects o USING(object_id) WHERE a.seq<=? AND (a.seq,a.object_id)>(?,?) ORDER BY a.seq,a.object_id LIMIT ?"
        let measured = work.stages.values.filter { $0.statementCalls[sql] != nil }
        #expect(measured.count == 1)
        #expect(measured.first?.statementCalls[sql] == 1)
        #expect(measured.first?.statementScanSteps[sql] == 0)
        print("PUBLICATION-WORK history=\(size) objects=\(batch.locators.count) bytes=\(batch.encodedByteCount) sqlSteps=\(measured.first?.statementSteps[sql] ?? -1)")
    }
    try await source.quiesce()
}
