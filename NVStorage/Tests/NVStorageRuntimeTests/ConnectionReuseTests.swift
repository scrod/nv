import NVStorageTestSupport
import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

@Test(arguments: [false, true], [1, 64])
func connectionContextReusesFixedChecks(encrypted: Bool, statements: Int) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let selection = await store.selection, lane = await store.lane
    try await lane.perform { $0.work = StorageWork() }
    let values = try await lane.perform { db in
        var values: [[SQLValue]] = []
        for _ in 0..<statements {
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            values += try db.rows("SELECT 42")
        }
        return values
    }
    #expect(values == Array(repeating: [.integer(42)], count: statements))
    let work = try await lane.perform { db in let result = db.work!; db.work = nil; return result }
    #expect(work.stages.values.reduce(0) { $0 + $1.statements } == statements)
    #expect(work.stages.values.reduce(0) { $0 + $1.connectionContextChecks } == 0)
    // Instrumentation setup and collection each contribute one boundary check.
    #expect(work.stages.values.reduce(0) { $0 + $1.physicalOwnerChecks } == 4)
    let wrongStore = try LocalStoreID(bytes: Array(repeating: 254, count: 16))
    await #expect(throws: StorageError.wrongContext, "Checked context rejects another store") {
        try await lane.perform { try $0.validateHeader(store: wrongStore, descriptor: selection.descriptor) }
    }
    let wrongDescriptor = try BootstrapDescriptorV1.publicDescriptor(
        collection: CollectionID(bytes: Array(repeating: 253, count: 16)), genesis: selection.descriptor.genesis)
    await #expect(throws: StorageError.wrongContext) {
        try await lane.perform { try $0.validateHeader(store: selection.store, descriptor: wrongDescriptor) }
    }
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: StorageWork())
    let openWork = try await reopened.lane.perform { db in let result = db.work!; db.work = nil; return result }
    #expect(openWork.stages.values.reduce(0) { $0 + $1.connectionContextChecks } == 1)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func connectionCandidateChecksRequireCompleteBootstrap(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let selection = try LocalStoreSelection(directory: path, store: LocalStoreID(bytes: uuidBytes()), descriptor: initial.descriptor)
    let key = try PrivateDatabaseKeyV1.derive(collection: initial.descriptor.collection, protection: protection)
    let lane = DatabaseLane()
    try await lane.open(directory: path, create: true, key: key)
    try await lane.perform { db in
        try db.initialize(store: selection.store, descriptor: initial.descriptor, snapshot: initial.snapshot)
        try db.validateHeader(store: selection.store, descriptor: initial.descriptor, requireBootstrap: false)
    }
    for _ in 0..<2 {
        await #expect(throws: StorageError.incomplete) {
            try await lane.perform { try $0.validateHeader(store: selection.store, descriptor: initial.descriptor) }
        }
    }
    await lane.close()
    await #expect(throws: StorageError.incomplete) {
        try await LocalStoreSession.open(selection: selection, protection: protection)
    }
    let candidate = try await BootstrapCandidate.resume(selection: selection, protection: protection)
    for bytes in initial.objects.values { _ = try await candidate.retain(bytes) }
    let complete = try await candidate.complete(snapshot: initial.snapshot)
    #expect(try await complete.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await complete.quiesce()
}

@Test(arguments: [false, true], ["read-return", "before-commit", "after-commit"])
func connectionOwnershipChecksFenceResultsAndPermitExactRetry(encrypted: Bool, boundary: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let selection = await store.selection, lane = await store.lane, path = selection.directory
    try await lane.perform { try $0.exec("CREATE TABLE ownership_probe(value INTEGER); INSERT INTO ownership_probe VALUES(41)") }
    var returned = false
    do {
        _ = try await lane.perform { db in
            var work = StorageWork()
            work.databaseBoundary = { event in
                let selected = switch event {
                case .returning: boundary == "read-return"
                case .committing: boundary == "before-commit"
                case .committed: boundary == "after-commit"
                }
                if selected { try FileManager.default.moveItem(atPath: path, toPath: path + ".held") }
            }
            db.work = work
            if boundary == "read-return" { return try db.rows("SELECT value FROM ownership_probe") }
            return try db.transaction {
                try db.run("UPDATE ownership_probe SET value=42")
                return try db.rows("SELECT value FROM ownership_probe")
            }
        }
        returned = true
    } catch StorageError.ownership { }
    #expect(!returned, "Detached connection withholds the result")
    // An unrelated replacement at the same path remains outside this connection's ownership.
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    let replacementBytes = Data([42, 43, 44])
    try replacementBytes.write(to: URL(fileURLWithPath: path + "/Collection.sqlite"))
    let consumerMarker = URL(fileURLWithPath: path + ".consumer-ran")
    var replaced = false
    do {
        _ = try await lane.perform { db in
            try Data([1]).write(to: consumerMarker)
            db.work = nil
            return try db.rows("SELECT value FROM ownership_probe")
        }
        replaced = true
    } catch StorageError.ownership { }
    #expect(!replaced)
    #expect(!FileManager.default.fileExists(atPath: consumerMarker.path), "Ownership entry check precedes consumer work")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/Collection.sqlite")) == replacementBytes)
    try FileManager.default.moveItem(atPath: path, toPath: path + ".replacement")
    try FileManager.default.moveItem(atPath: path + ".held", toPath: path)
    let resumed = try await lane.perform { db in db.work = nil; return try db.rows("SELECT value FROM ownership_probe") }
    #expect(resumed == [[.integer(boundary == "after-commit" ? 42 : 41)]])
    await lane.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let actual = try await reopened.lane.perform { try $0.rows("SELECT value FROM ownership_probe") }
    #expect(actual == [[.integer(boundary == "after-commit" ? 42 : 41)]])
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func connectionDelayedCommitKeepsHistoricalReceipt(encrypted: Bool, deleteNewer: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let selection = await store.selection, lane = await store.lane
    var model = HeadlessModel(snapshot: try await store.snapshot())
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let committed = try model.put(testValue("committed without acknowledgment"), birth: birth)
    let capture = try await model.capture(birth, at: store.snapshot()), gate = ImprovementGate()
    try await lane.perform { db in var work = StorageWork(); work.acceptanceCompletion = { _ in await gate.hold() }; db.work = work }
    let saving = Task { try await store.persist(capture: capture) }
    await gate.wait()
    let newer = try deleteNewer ? model.delete(birth) : model.put(testValue("newer pending edit"), birth: birth)
    try FileManager.default.moveItem(atPath: selection.directory, toPath: selection.directory + ".held")
    await gate.release()
    let receipt = try requireReceipt(await saving.value)
    #expect(receipt.covered == [committed])
    try model.complete(receipt)
    #expect(model.pending[birth] == newer)
    #expect(model.values[birth]?.body.string == (deleteNewer ? nil : "newer pending edit"))
    try FileManager.default.moveItem(atPath: selection.directory + ".held", toPath: selection.directory)
    try await lane.perform { $0.work = nil }
    try await lane.catchUp(selection: selection, protection: protection)
    let durable = try await store.snapshot()
    #expect(durable.through == 2)
    #expect(durable.notes.map(\.value.body.string).sorted() == ["committed without acknowledgment", "untouched"])
    let membership = try await lane.perform { try $0.rows("SELECT COUNT(*) FROM actions WHERE action_id=?", [.blob(capture.action.bytes)]) }
    #expect(membership == [[.integer(1)]])
    let retained = try await store.retainedObject(at: receipt.object)
    let next = try await model.capture(birth, at: store.snapshot())
    let latest = try requireReceipt(await store.persist(capture: next))
    try model.complete(latest)
    #expect(model.pending.isEmpty)
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let recovered = try await reopened.snapshot()
    #expect(recovered.through == 3)
    #expect(recovered.notes.map(\.value.body.string).sorted() == (deleteNewer ? ["untouched"] : ["newer pending edit", "untouched"]))
    #expect(try await reopened.retainedObject(at: receipt.object) == retained)
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func connectionReconstructionRechecksRequiredPrivateInputs(encrypted: Bool, unsupported: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let lane = await store.lane, selection = await store.selection
    // Qualify a healthy reconstruction before changing required inputs during preparation.
    let healthy = try await store.rebuildCurrentRows()
    #expect(healthy.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let before = try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    let gate = ImprovementGate()
    try await lane.perform { db in var work = StorageWork(); work.reconstructionPrepared = { await gate.hold() }; db.work = work }
    let rebuilding = Task { try await store.rebuildCurrentRows() }
    await gate.wait()
    try await lane.perform { db in
        if unsupported { try db.run("UPDATE private_groups SET codec=99 WHERE group_key=?", [.blob(Array("settings".utf8))]) }
        else { try db.run("DELETE FROM private_groups WHERE group_key=?", [.blob(Array("settings".utf8))]) }
    }
    await gate.release()
    await #expect(throws: unsupported ? StorageError.unsupported : .incomplete) { try await rebuilding.value }
    #expect(try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") } == before)
    #expect(try await store.snapshot().notes == healthy.notes)
    try await store.quiesce()
    await #expect(throws: unsupported ? StorageError.unsupported : .incomplete) {
        try await LocalStoreSession.open(selection: selection, protection: protection)
    }
}
