import NVStorageTestSupport
import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

private func edgeBirth(_ n: UInt8 = 1) throws -> NoteBirth { try .init(bytes: Array(repeating: n, count: 16)) }
private func payload(_ receipt: AcceptedHistoryReceipt, _ store: LocalStoreSession, _ protection: ObjectProtectionV1) async throws -> ChangesPayloadV1 {
    let selection = await store.selection
    return try await .decodeV1(ObjectEnvelopeV1.open(store.retainedObject(at: receipt.object), collection: selection.descriptor.collection, protection: protection).payload)
}
private func erase(_ birth: NoteBirth, _ store: LocalStoreSession) async throws -> AcceptedHistoryReceipt {
    let capture = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .deleteBatch, changes: [.delete(.init(birth: birth, generation: 9))])
    return try requireReceipt(await store.persist(capture: capture))
}

@Test(arguments: [false, true]) func conflictCopySlotsVerifyStateAndRetainExactRetries(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let source = try edgeBirth(), edit = try await put("Right", birth: source, generation: 1, session: right)
    let revision = try await payload(edit, right, protection).operations[0].operation.id
    _ = try await left.receive(right.retainedObject(at: edit.object))
    let first = try await left.copyVersion(for: source, revision: revision, generation: 2)
    let saved = try requireReceipt(await left.persist(capture: first)), copy = first.covered[0].birth
    let exact = try await left.retainedObject(at: saved.object)
    #expect(try await left.snapshot().notes.first { $0.birth == copy }?.identity == .recovery(ConflictRecoveryKeyV1.compute(source: source, body: testValue("Right").body), slot: 0))
    let original = try #require(try await left.snapshot().notes.first { $0.birth == copy })
    let renamed = try PlaintextNoteValue(title: .init(bytes: Array("My preserved title".utf8)), body: original.value.body,
        labels: .init([.init(bytes: Array("personal".utf8))]), created: original.value.created, modified: original.value.modified)
    let metadata = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .rename, changes: [.put(.init(birth: copy, generation: 3), renamed)])
    _ = try requireReceipt(await left.persist(capture: metadata))
    let reuse = try await left.copyVersion(for: source, revision: revision, generation: 4)
    #expect(reuse.covered[0].birth == copy)
    let reused = try requireReceipt(await left.persist(capture: reuse)), reusedPayload = try await payload(reused, left, protection)
    if case .copy(_, _, _, let slot, let operation) = reusedPayload.actions[0].action.details {
        #expect(slot == 0 && operation != nil)
    } else { Issue.record("Reuse must carry its exact qualifying occurrence") }
    #expect(try await left.snapshot().notes.first { $0.birth == copy }?.value == renamed)
    _ = try await put("independently changed", birth: copy, generation: 5, session: left)
    let newer = try await left.copyVersion(for: source, revision: revision, generation: 6)
    #expect(newer.covered[0].birth != copy)
    let next = try requireReceipt(await left.persist(capture: newer))
    #expect(try await left.snapshot().notes.first { $0.birth == copy }?.value.body.string == "independently changed")
    let repeated = try requireReceipt(await left.persist(capture: first))
    #expect(repeated.object == saved.object && repeated.sequence == saved.sequence)
    #expect(try await left.retainedObject(at: repeated.object) == exact)
    #expect(try await left.snapshot().notes.first { $0.birth == copy }?.value.body.string == "independently changed")
    let deletion = try await erase(newer.covered[0].birth, left)
    _ = try await right.receive(exact); _ = try await right.receive(left.retainedObject(at: reused.object))
    // Deliver the intervening metadata and edit dependencies before the later objects.
    let graph = try await left.lane.retainedGraph(through: left.snapshot().through, selection: left.selection, protection: protection)
    for locator in Set(graph.operationReferences.values.map(\.locator)).sorted(by: { $0.segmentID.bytes.lexicographicallyPrecedes($1.segmentID.bytes) }) {
        _ = try await right.receive(left.retainedObject(at: locator))
    }
    _ = try await right.receive(left.retainedObject(at: next.object)); _ = try await right.receive(left.retainedObject(at: deletion.object))
    #expect(try await right.snapshot().notes.first { $0.birth == copy }?.value.body.string == "independently changed")
    #expect(try await right.snapshot().notes.allSatisfy { $0.birth != newer.covered[0].birth })
    #expect(try await right.conflicts(for: source).representedSeparately.contains(revision))
    try await left.quiesce(); try await right.quiesce()
}

@Test(arguments: [false, true]) func ordinaryIdentityCollisionPreservesFileAndSkipsRecoverySlot(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let source = try edgeBirth(), current = try #require(try await store.snapshot().notes.first { $0.birth == source })
    let key = try ConflictRecoveryKeyV1.compute(source: source, body: current.value.body), occupied = try key.birth(slot: 0)
    let ordinary = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .createImportBatch,
        changes: [.create(.init(birth: occupied, generation: 1), current.value)])
    _ = try requireReceipt(await store.persist(capture: ordinary))
    let captured = try await store.copyVersion(for: source, revision: current.revision.id, generation: 2)
    #expect(captured.covered[0].birth == (try key.birth(slot: 1)))
    _ = try requireReceipt(await store.persist(capture: captured))
    #expect(try await store.snapshot().notes.first { $0.birth == occupied }?.value == current.value)
    #expect(try await store.snapshot().notes.first { $0.birth == occupied }?.identity == nil)
    try await store.quiesce()
}

@Test(arguments: [false, true]) func ordinaryConflictEditPreservesKnownUnchosenHeads(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try edgeBirth(), l = try await put("Left", birth: birth, generation: 1, session: left)
    let r = try await put("Right", birth: birth, generation: 1, session: right)
    _ = try await left.receive(right.retainedObject(at: r.object))
    let before = try #require(try await left.snapshot().notes.first { $0.birth == birth })
    #expect(before.heads.count == 2 && before.represented.count == 1)
    let untouched = Set(before.heads.map(\.id)).subtracting(before.represented.map(\.id))
    let value = try PlaintextNoteValue(title: .init(bytes: Array("Renamed".utf8)), body: before.value.body,
        labels: .init([.init(bytes: Array("new label".utf8))]), created: before.value.created, modified: before.value.modified)
    let captured = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .rename, changes: [.put(.init(birth: birth, generation: 2), value)])
    let outcome = try await left.persist(capture: captured)
    let wire: ChangesPayloadV1
    switch outcome {
    case .accepted(let receipt): wire = try await payload(receipt, left, protection)
    case .pending:
        // Inspect the exact owned emitted claim when downstream validation rejects it.
        let owned = try #require(await left.commitState.owned)
        #expect(owned.capture.id == captured.id)
        wire = try #require(owned.sealed).payload
    }
    let op = wire.operations[0].operation
    #expect(Set(op.notePredecessors.ids) == Set(before.represented.map(\.id)))
    #expect(Set(op.causalParents.ids).isSuperset(of: before.heads.map(\.id)))
    let receipt = try requireReceipt(outcome)
    #expect(Set(try await left.snapshot().notes.first { $0.birth == birth }!.heads.map(\.id)) == untouched.union([op.id]))
    _ = try await right.receive(left.retainedObject(at: l.object)); _ = try await right.receive(left.retainedObject(at: receipt.object))
    #expect(try await left.snapshot().notes == right.snapshot().notes)
    let selector = try await left.chooseVersion(for: birth, revision: untouched.first!, generation: 3)
    let choice = try requireReceipt(await left.persist(capture: selector)), chosen = try await payload(choice, left, protection)
    #expect(Set(chosen.operations[0].operation.notePredecessors.ids) == untouched.union([op.id]))
    #expect(try await left.snapshot().notes.first { $0.birth == birth }?.heads.count == 1)
    try await left.quiesce(); try await right.quiesce()
}

@Test(arguments: [false, true]) func equalAutomaticKeyNeedsEverySourceCovered(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let deleted = try await newSession(initial, protection), first = try await newSession(initial, protection), second = try await newSession(initial, protection)
    let birth = try edgeBirth(), d0 = try await erase(birth, deleted)
    let a = try await put("same uncovered body", birth: birth, generation: 1, session: first)
    let b = try await put("same uncovered body", birth: birth, generation: 1, session: second)
    _ = try await deleted.receive(first.retainedObject(at: a.object)); _ = try await deleted.receive(second.retainedObject(at: b.object))
    let copy = try #require(try await deleted.snapshot().notes.first { $0.automatic != nil })
    #expect(try await deleted.snapshot().notes.count == 2)
    let da = try await erase(birth, first)
    _ = try await deleted.receive(first.retainedObject(at: da.object))
    #expect(try await deleted.snapshot().notes.first { $0.birth == copy.birth }?.value.body.string == "same uncovered body")
    let db = try await erase(birth, second)
    _ = try await deleted.receive(second.retainedObject(at: db.object))
    #expect(try await deleted.snapshot().notes.map(\.value.body.string) == ["untouched"])
    let graph = try await deleted.lane.retainedGraph(through: deleted.snapshot().through, selection: deleted.selection, protection: protection)
    #expect(graph.operations.values.allSatisfy { if case .retireConflict = $0.effect { false } else { true } })
    #expect(try await deleted.retainedObject(at: d0.object).isEmpty == false)
    try await deleted.quiesce(); try await first.quiesce(); try await second.quiesce()
}

@Test(arguments: [false, true]) func independentPreservationAdmissionFencesRetractionPublication(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try edgeBirth(), originalDeletion = try await erase(birth, left)
    let edit = try await put("E", birth: birth, generation: 1, session: right)
    _ = try await left.receive(right.retainedObject(at: edit.object))
    let copy = try #require(try await left.snapshot().notes.first { $0.automatic != nil })
    let modelBasis = try await left.snapshot()
    var model = HeadlessModel(snapshot: modelBasis)
    let deletion = try await erase(birth, right)
    _ = try await left.receive(right.retainedObject(at: deletion.object))
    let retraction = try await left.prepareReduction(liveGeneration: 1)
    let p = try model.put(testValue("pending independent P"), birth: copy.birth)
    await #expect(throws: StorageError.staleCapture) { try await left.publish(retraction, liveGeneration: 2) { $0.notes.count } }
    #expect(model.pending[copy.birth] == p && model.values[copy.birth]?.body.string == "pending independent P")
    // Its captured originating automatic state precedes D1 and remains valid on either receiver.
    let capture = try model.capture(copy.birth, at: modelBasis)
    let receipt = try requireReceipt(await left.persist(capture: capture))
    _ = try await right.receive(left.retainedObject(at: originalDeletion.object))
    let received = try await right.receive(left.retainedObject(at: receipt.object))
    if case .accepted = received {} else { Issue.record("The complete preservation closure must be accepted") }
    #expect(try await right.snapshot().notes.first { $0.birth == copy.birth }?.value.body.string == "pending independent P")
    #expect(try await left.snapshot().notes.first { $0.birth == copy.birth }?.value.body.string == "pending independent P")
    try model.complete(receipt); #expect(model.pending.isEmpty)
    try await left.quiesce(); try await right.quiesce()
}

@Test(arguments: [false, true]) func namedCompensationKeepsAllMembersAndRejectsStaleApproval(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let a = try edgeBirth(3), b = try edgeBirth(4)
    let capture = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .createImportBatch,
        changes: [.create(.init(birth: a, generation: 1), testValue("named A")), .create(.init(birth: b, generation: 1), testValue("named B"))])
    let receipt = try requireReceipt(await store.persist(capture: capture)), wire = try await payload(receipt, store, protection)
    _ = try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))
    guard case .automatic(let stale) = try await store.prepareCompensation(scope: .collection, direction: .undo) else { Issue.record("Complete named group must be automatically undoable"); return }
    _ = try await put("changed B", birth: b, generation: 2, session: store)
    _ = try await store.rebuildCurrentRows()
    let through = try await store.snapshot().through
    await #expect(throws: StorageError.staleCapture) { try await store.applyReviewedCompensation(stale.forReview()) }
    #expect(try await store.snapshot().notes.contains { $0.birth == a })
    #expect(try await store.snapshot().notes.first { $0.birth == b }?.value.body.string == "changed B")
    #expect(try await store.snapshot().through == through)
    guard case .review(let reviewed) = try await store.prepareCompensation(scope: .collection, direction: .undo, candidate: wire.actions[0].action.id) else { Issue.record("Changed result keeps the whole named candidate for review"); return }
    #expect(Set(reviewed.proposal.effects.map(\.birth)) == [a, b])
    let undo = try requireReceipt(await store.applyReviewedCompensation(reviewed)), inverse = try await payload(undo, store, protection)
    #expect(Set(inverse.actions[0].action.affected.map(\.birth)) == [a, b] && inverse.operations.count == 2)
    #expect(try await store.snapshot().notes.count == 2)
    _ = try await store.rebuildCurrentRows()
    guard case .automatic(let redo) = try await store.prepareCompensation(scope: .collection, direction: .redo) else { Issue.record("Actual two-member deletion must be automatically reversible"); return }
    let restored = try requireReceipt(await store.applyCompensation(redo)), births = Set(restored.covered.map(\.birth))
    #expect(births.count == 2 && births.isDisjoint(with: [a, b]))
    #expect(Set(try await store.snapshot().notes.map(\.value.body.string)) == ["A", "untouched", "named A", "changed B"])
    try await store.quiesce()
}
