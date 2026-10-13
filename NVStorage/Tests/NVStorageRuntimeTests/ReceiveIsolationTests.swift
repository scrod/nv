import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true])
func rejectionCleanupFailureKeepsRetryableBytes(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), receiver = try await newSession(initial, protection)
    let candidate = try ObjectEnvelopeV1.seal(payload: [], kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 76, count: 16)),
        sequence: 0, protection: protection)
    let lane = await receiver.lane
    try await lane.perform { try $0.exec("CREATE TEMP TRIGGER fail_rejection_cleanup BEFORE DELETE ON ready_objects BEGIN SELECT RAISE(ABORT,'qualification cleanup failure'); END") }
    for _ in 0..<3 {
        await #expect(throws: StorageError.database(1811)) { try await receiver.receive(candidate) }
        let state = try await lane.perform { db in
            (try db.rows("SELECT reason FROM rejected_objects"),
             try db.rows("SELECT encoded FROM objects JOIN ready_objects USING(object_id)"))
        }
        #expect(state.0.isEmpty)
        #expect(state.1 == [[.blob(candidate)]])
        #expect(try await receiver.snapshot().through == 1)
    }
    try await lane.perform { try $0.exec("DROP TRIGGER fail_rejection_cleanup") }
    await #expect(throws: CanonicalEncodingError.truncated) { try await receiver.receive(candidate) }
    #expect(try await lane.perform { try $0.rows("SELECT reason FROM rejected_objects") } == [[.integer(20)]])
    #expect(try await lane.perform { try $0.rows("SELECT object_id FROM ready_objects") }.isEmpty)
    try await receiver.quiesce()
}

@Test(arguments: [false, true])
func malformedPayloadIsRetainedAndRejectedAcrossReopen(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var receiver = try await newSession(initial, protection)
    let candidate = try ObjectEnvelopeV1.seal(payload: [], kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 78, count: 16)),
        sequence: 0, protection: protection)
    let id = try ObjectEnvelopeV1.open(candidate, collection: initial.descriptor.collection, protection: protection).locator.segmentID.bytes
    await #expect(throws: CanonicalEncodingError.truncated) { try await receiver.receive(candidate) }
    let selection = await receiver.selection
    try await receiver.quiesce()
    receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: CanonicalEncodingError.truncated) { try await receiver.receive(candidate) }
    let lane = await receiver.lane
    #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects JOIN rejected_objects USING(object_id) WHERE object_id=?", [.blob(id)]) } == [[.blob(candidate)]])
    #expect(try await receiver.snapshot().through == 1)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("still editable", birth: birth, generation: 1, session: receiver)
    #expect(try await receiver.snapshot().notes.contains { $0.value.body.string == "still editable" })
    try await receiver.quiesce()
}

@Test(arguments: [false, true])
func rejectedParkedChildPreservesIndependentProgress(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let parent = try await put("parent", birth: birth, generation: 1, session: source)
    let child = try await put("child", birth: birth, generation: 2, session: source)
    let good = try await source.retainedObject(at: child.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(good,
        collection: initial.descriptor.collection, protection: protection).payload)
    let record = payload.actions[0]
    let broken = try ActionRecordV1(id: record.action.id, origin: record.action.origin,
        previousOrigin: record.previousOriginReference, scope: record.action.scope,
        scopeParents: [], kind: record.action.kind, members: record.memberIndices,
        affected: record.affectedReferences, operations: payload.operations.map(\.operation), earlierActions: [])
    let candidate = try ChangesPayloadV1(dependencies: payload.dependencies, operations: payload.operations, actions: [broken])
    let bad = try ObjectEnvelopeV1.seal(payload: candidate.encodedV1(), kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 77, count: 16)),
        sequence: 0, protection: protection)
    let badID = try ObjectEnvelopeV1.open(bad, collection: initial.descriptor.collection, protection: protection).locator.segmentID.bytes
    guard case .waiting = try await receiver.receive(bad) else { Issue.record("child must wait for parent"); return }
    let selection = await receiver.selection
    try await receiver.quiesce()
    receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
    _ = try await receiver.receive(source.retainedObject(at: parent.object))
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["parent", "untouched"])
    await #expect(throws: OrdinaryHistoryError.invalidAction) { try await receiver.receive(bad) }
    _ = try await receiver.receive(good)
    let lane = await receiver.lane
    let evidence = try await lane.perform { db in
        (try db.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(badID)]),
         try db.rows("SELECT reason FROM rejected_objects WHERE object_id=?", [.blob(badID)]),
         try db.rows("SELECT object_id FROM ready_objects"),
         try db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(badID)]))
    }
    #expect(evidence.0 == [[.blob(bad)]])
    #expect(evidence.1 == [[.integer(ReceiveRejection.invalidAction.rawValue)]])
    #expect(evidence.2.isEmpty && evidence.3.isEmpty)
    try await receiver.quiesce()
    receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["child", "untouched"])
    await #expect(throws: OrdinaryHistoryError.invalidAction) { try await receiver.receive(bad) }
    #expect(try await receiver.snapshot().through == 3)
    try await receiver.quiesce(); try await source.quiesce()
}

@Test func receiveRejectionClassifiesOnlyDefiniteInputFailures() {
    for error in [StorageError.database(10), .database(13), .database(5), .ownership(13), .closed, .incomplete, .integrity] {
        #expect(ReceiveRejection(error) == nil)
    }
    #expect(ReceiveRejection(CanonicalEncodingError.missingDependency) == nil)
    #expect(ReceiveRejection(CanonicalEncodingError.keyDerivationFailure) == nil)
    for raw in Array(1...7) + Array(20...37) {
        let reason = ReceiveRejection(rawValue: Int64(raw))!
        #expect(ReceiveRejection(reason.error) == reason)
    }
}

@Test(arguments: [false, true])
func misaddressedReceiveDependencyIsIsolated(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let saved = try await put("valid", birth: birth, generation: 1, session: source)
    let good = try await source.retainedObject(at: saved.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(good,
        collection: initial.descriptor.collection, protection: protection).payload)
    let target = try #require(payload.dependencies.entries.first)
    let wrong = SegmentLocator(writerEpoch: try WriterEpoch(bytes: Array(repeating: 93, count: 16)),
        sequence: target.sequence, segmentID: target.segmentID)
    let altered = try ChangesPayloadV1(dependencies: DependencyLocatorTable(payload.dependencies.entries + [wrong]),
        operations: payload.operations, actions: payload.actions)
    let bad = try ObjectEnvelopeV1.seal(payload: altered.encodedV1(), kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 94, count: 16)),
        sequence: 0, protection: protection)
    await #expect(throws: CanonicalEncodingError.invalidReference) { try await receiver.receive(bad) }
    let lane = await receiver.lane
    #expect(try await lane.perform { try $0.rows("SELECT reason FROM rejected_objects") } == [[.integer(ReceiveRejection.invalidReference.rawValue)]])
    _ = try await receiver.receive(good)
    #expect(try await receiver.snapshot().notes.contains { $0.value.body.string == "valid" })
    try await receiver.quiesce(); try await source.quiesce()
}
