import Foundation
import Crypto
import Testing
import NVStorageCore
import NVStorageRuntime

func newSession(_ initial: InitialCollectionV1, _ protection: ObjectProtectionV1) async throws -> LocalStoreSession {
    try await .create(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        initial: initial, protection: protection)
}
func put(_ body: String, birth: NoteBirth, generation: UInt64, session: LocalStoreSession) async throws -> AcceptedHistoryReceipt {
    let capture = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .savedEdit,
        changes: [.put(CapturedNoteGeneration(birth: birth, generation: generation), testValue(body))])
    return try requireReceipt(await session.persist(capture: capture))
}

@Test(arguments: [false, true], [false, true])
func oldCompletionPreservesNewerPendingWork(encrypted: Bool, deleteNewer: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let first = try await session.snapshot(), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    var model = HeadlessModel(snapshot: first)
    let e = try model.put(testValue("E"), birth: birth)
    let capture = try model.capture(birth, at: first)
    let saved = try requireReceipt(await session.persist(capture: capture))
    #expect(saved.covered == [e])
    // Hold delivery to the host after the real barrier while a newer command is admitted.
    let f = try deleteNewer ? model.delete(birth) : model.put(testValue("F"), birth: birth)
    try model.complete(saved)
    #expect(model.pending[birth] == f)
    #expect(model.values[birth]?.body.string == (deleteNewer ? nil : "F"))
    let envelope = try await session.retainedObject(at: saved.object)
    let p = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(envelope,
        collection: initial.descriptor.collection, protection: protection).payload)
    guard case .put(_, _, let value) = p.operations[0].operation.effect else { Issue.record("missing durable E"); return }
    #expect(value.body.string == "E")
    let next = try await model.capture(birth, at: session.snapshot())
    let latest = try requireReceipt(await session.persist(capture: next))
    try model.complete(latest)
    #expect(model.pending.isEmpty)
    let repeated = try requireReceipt(await session.persist(capture: capture))
    #expect(repeated.object == saved.object && repeated.sequence == saved.sequence)
    #expect(try await session.snapshot().through == 3)
    let selection = await session.selection
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == (deleteNewer ? ["untouched"] : ["F", "untouched"]))
    try await reopened.quiesce()
}

@Test func settingsAndPublicationHaveIndependentContextChecks() async throws {
    let (initial, protection) = try testInitial(false), session = try await newSession(initial, protection)
    let settings = try await session.settings(), prepared = try await session.prepareReduction(liveGeneration: 1)
    #expect(try await session.publish(prepared, liveGeneration: 1) { $0.through } == 1)
    await #expect(throws: StorageError.staleCapture) { try await session.publish(prepared, liveGeneration: 2) { $0.through } }
    let other = try await newSession(initial, protection)
    await #expect(throws: StorageError.wrongContext) { try await other.publish(prepared, liveGeneration: 1) { $0.through } }
    await #expect(throws: StorageError.wrongContext) { try await other.saveEmptySettings(basedOn: settings) }
    try await other.quiesce()
    let receipt = try await put("E", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    await #expect(throws: StorageError.staleCapture) { try await session.publish(prepared, liveGeneration: 1) { $0.through } }
    try await session.saveEmptySettings(basedOn: settings)
    #expect(try await session.settings().generation == 2)
    #expect(try await session.snapshot().through == 2)
    #expect(try await !session.retainedObject(at: receipt.object).isEmpty)
    await #expect(throws: StorageError.staleCapture) { try await session.saveEmptySettings(basedOn: settings) }
    try await session.quiesce()
}

private let arrivalOrders = [[2, 1, 0], [2, 0, 1], [1, 2, 0], [1, 0, 2], [0, 2, 1], [0, 1, 2]]

@Test func realRetryHandleAndReceiptRejectOtherOwnersAndSessions() async throws {
    let (initial, protection) = try testInitial(false), source = try await newSession(initial, protection)
    let other = try await newSession(initial, protection), selection = await source.selection
    let snapshot = try await source.snapshot(), birth = try #require(snapshot.notes.first).birth
    let capture = try CapturedActionGroup(snapshot: snapshot, kind: .savedEdit,
        changes: [.put(CapturedNoteGeneration(birth: birth, generation: 1), testValue("retry"))])
    let displaced = selection.directory + ".temporarily-unavailable"
    try FileManager.default.moveItem(atPath: selection.directory, toPath: displaced)
    let outcome = try await source.persist(capture: capture)
    guard case .pending(let handle, .ownership) = outcome else { Issue.record("Missing owner did not retain a retry"); return }
    await #expect(throws: StorageError.wrongContext) { try await other.retry(commit: handle) }
    await #expect(throws: StorageError.busy) { try await source.quiesce() }
    try FileManager.default.moveItem(atPath: displaced, toPath: selection.directory)
    let receipt = try requireReceipt(await source.retry(commit: handle))
    var otherModel = try await HeadlessModel(snapshot: other.snapshot())
    #expect(throws: StorageError.wrongContext) { try otherModel.complete(receipt) }
    let again = try requireReceipt(await source.retry(commit: handle))
    #expect(again.object == receipt.object && again.sequence == receipt.sequence)
    try await source.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.retry(commit: handle) }
    var newModel = try await HeadlessModel(snapshot: reopened.snapshot())
    #expect(throws: StorageError.wrongContext) { try newModel.complete(receipt) }
    #expect(newModel.values[birth]?.body.string == "retry")
    try await reopened.quiesce(); try await other.quiesce()
}

@Test(arguments: [false, true], arrivalOrders)
func durableDependencyWakeupsAndRepackagedOperations(encrypted: Bool, order: [Int]) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    var destination = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let e = try await put("E", birth: a, generation: 1, session: source)
    let f = try await put("F", birth: b, generation: 2, session: source)
    let g = try await put("G", birth: a, generation: 3, session: source)
    let objects = try await [source.retainedObject(at: e.object), source.retainedObject(at: f.object), source.retainedObject(at: g.object)]
    let selection = await destination.selection
    for index in order {
        let outcome = try await destination.receive(objects[index])
        if order.first == index && index == 2 {
            guard case .waiting(let missing) = outcome else { Issue.record("child accepted without prerequisites"); return }
            #expect(Set(missing) == Set([e.object, f.object]))
            #expect(try await destination.snapshot().through == 1)
        }
        try await destination.quiesce()
        destination = try await LocalStoreSession.open(selection: selection, protection: protection)
    }
    let complete = try await destination.snapshot()
    #expect(complete.through == 4)
    #expect(complete.notes.map(\.value.body.string).sorted() == ["F", "G"])
    _ = try await destination.receive(objects[2])
    #expect(try await destination.snapshot().through == 4)
    let payload = try ObjectEnvelopeV1.open(objects[0], collection: initial.descriptor.collection, protection: protection).payload
    let repacked = try ObjectEnvelopeV1.seal(payload: payload, kind: .changes, collection: initial.descriptor.collection,
        writer: WriterEpoch(bytes: Array(repeating: 88, count: 16)), sequence: 0, protection: protection)
    _ = try await destination.receive(repacked)
    let repackedView = try await destination.snapshot()
    #expect(repackedView.through == 5)
    #expect(repackedView.notes == complete.notes)
    #expect(repackedView.context == complete.context)
    _ = try await destination.receive(repacked)
    #expect(try await destination.snapshot().through == 5)
    try await source.quiesce(); try await destination.quiesce()
}
