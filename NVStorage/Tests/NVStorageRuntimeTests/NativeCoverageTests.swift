import NVStorageTestSupport
import NVStorageCore
@testable import NVStorageRuntime
import Testing

@Test(arguments: [false, true]) func nativeRemainingEffectAndActualRedoSurviveReopen(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("", birth: birth, generation: 1, session: store)
    let a = try await put("AB", birth: birth, generation: 2, session: store)
    let b = try await put("ABCD", birth: birth, generation: 3, session: store)
    func action(_ receipt: AcceptedHistoryReceipt) async throws -> ActionID {
        try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(store.retainedObject(at: receipt.object), collection: initial.descriptor.collection, protection: protection).payload).actions[0].action.id
    }
    let aID = try await action(a), bID = try await action(b)
    let capture = try await store.nativeCompensation(for: birth, steps: [
        .init(value: testValue("AB"), coverage: [.init(action: bID, complete: true)]),
        .init(value: testValue("A"), coverage: [.init(action: aID, complete: false)])
    ], generation: 4)
    let receipt = try requireReceipt(await store.persist(capture: capture))
    #expect(try requireReceipt(await store.persist(capture: capture)).object == receipt.object)
    let p = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(store.retainedObject(at: receipt.object), collection: initial.descriptor.collection, protection: protection).payload)
    #expect(p.operations.count == 2 && p.actions[0].action.affected.count == 1)
    guard case .native(let records) = p.actions[0].action.details else { Issue.record("Native command must retain its coverage"); return }
    #expect(records.first { $0.action == aID }?.remaining == .value(p.operations[1].operation.id))
    #expect(records.first { $0.action == aID }?.complete == false)
    #expect(records.first { $0.action == bID }?.complete == true)
    _ = try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))
    let selection = await store.selection
    try await store.quiesce(); store = try await .open(selection: selection, protection: protection)
    #expect(try await store.undoCandidates(scope: .note(birth), direction: .undo).ids == [aID])
    try await expectScopedHistoryMatchesFull(store, birth: birth)
    let undoPreparation = try await store.prepareCompensation(scope: .note(birth), direction: .undo)
    #expect(isAutomaticCompensation(undoPreparation))
    guard case .automatic(let undo) = undoPreparation else { return }
    let actualUndo = try requireReceipt(await store.applyCompensation(undo))
    let actualUndoID = try await action(actualUndo)
    #expect(try await store.undoCandidates(scope: .note(birth), direction: .redo).ids == [actualUndoID], "Redo targets the recorded compensation")
    _ = try await store.rebuildCurrentRows()
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "")
    guard case .automatic(let redoA) = try await store.prepareCompensation(scope: .note(birth), direction: .redo) else { Issue.record("Actual inverse must be automatically redoable"); return }
    _ = try requireReceipt(await store.applyCompensation(redoA))
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "A")
    try await expectScopedHistoryMatchesFull(store, birth: birth)
    guard case .automatic(let redoNative) = try await store.prepareCompensation(scope: .note(birth), direction: .redo) else { Issue.record("Native actual compensation must remain automatic in redo tail"); return }
    _ = try requireReceipt(await store.applyCompensation(redoNative))
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "ABCD")
    try await expectScopedHistoryMatchesFull(store, birth: birth)
    guard case .automatic(let undoActual) = try await store.prepareCompensation(scope: .note(birth), direction: .undo) else { Issue.record("Actual native Redo must be automatically undoable"); return }
    _ = try requireReceipt(await store.applyCompensation(undoActual))
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "A")
    guard case .automatic(let redoActual) = try await store.prepareCompensation(scope: .note(birth), direction: .redo) else { Issue.record("Actual inverse must retain automatic Redo"); return }
    _ = try requireReceipt(await store.applyCompensation(redoActual))
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "ABCD")
    try await store.quiesce()
}

@Test(arguments: [false, true]) func incomparableNativeCoveragePreservesRemainingFamily(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("ABC", birth: birth, generation: 1, session: left)
    _ = try await right.receive(left.retainedObject(at: edit.object))
    let p = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(left.retainedObject(at: edit.object), collection: initial.descriptor.collection, protection: protection).payload)
    let target = p.actions[0].action.id
    let partial = try await left.nativeCompensation(for: birth, steps: [.init(value: testValue("AB"), coverage: [.init(action: target, complete: false)])], generation: 2)
    let complete = try await right.nativeCompensation(for: birth, steps: [.init(value: testValue("A"), coverage: [.init(action: target, complete: true)])], generation: 2)
    let l = try requireReceipt(await left.persist(capture: partial)), r = try requireReceipt(await right.persist(capture: complete))
    _ = try await left.receive(right.retainedObject(at: r.object)); _ = try await right.receive(left.retainedObject(at: l.object))
    let candidates = try await left.undoCandidates(scope: .note(birth), direction: .undo)
    #expect(candidates.ids == [target] && candidates.mode == .review)
    try await expectScopedHistoryMatchesFull(left, birth: birth)
    let before = try await left.snapshot()
    switch try await left.prepareCompensation(scope: .note(birth), direction: .undo) {
    case .review(let review):
        _ = try requireReceipt(await left.applyReviewedCompensation(review))
        #expect(try await left.snapshot().notes.first { $0.birth == birth }?.value.body.string == "A")
    case .noEffect:
        #expect(before.notes.first { $0.birth == birth }?.value.body.string == "A")
        #expect(try await left.snapshot().through == before.through)
    default: Issue.record("Fork must offer a reviewable remaining effect or the exact no-op")
    }
    #expect(try await left.undoCandidates(scope: .note(birth), direction: .redo).mode == .review)
    try await left.quiesce(); try await right.quiesce()
}

private func isAutomaticCompensation(_ preparation: CompensationPreparation) -> Bool {
    if case .automatic = preparation { true } else { false }
}
