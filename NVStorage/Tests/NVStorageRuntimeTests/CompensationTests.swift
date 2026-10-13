import NVStorageTestSupport
import NVStorageCore
@testable import NVStorageRuntime
import Testing

private func birthForUndo(_ byte: UInt8 = 1) throws -> NoteBirth { try NoteBirth(bytes: Array(repeating: byte, count: 16)) }
private func automatic(_ preparation: CompensationPreparation) throws -> AutomaticCompensation {
    guard case .automatic(let command) = preparation else { Issue.record("Expected an automatically applicable compensation"); throw StorageError.integrity }; return command
}
private func compensate(_ store: LocalStoreSession, _ scope: ActionScopeV1, _ direction: UndoDirectionV1,
                        candidate: ActionID? = nil, reviewed: Bool = false) async throws -> AcceptedHistoryReceipt {
    let prepared = try await store.prepareCompensation(scope: scope, direction: direction, candidate: candidate)
    switch prepared {
    case .automatic(let command):
        return try requireReceipt(await (reviewed ? store.applyReviewedCompensation(command.forReview()) : store.applyCompensation(command)))
    case .review(let review):
        try #require(reviewed, "The test must explicitly approve review-required compensation")
        return try requireReceipt(await store.applyReviewedCompensation(review))
    default: Issue.record("Expected a complete compensation"); throw StorageError.integrity
    }
}
private func undoBody(_ store: LocalStoreSession, _ birth: NoteBirth) async throws -> String {
    try #require(try await store.snapshot().notes.first { $0.birth == birth }).value.body.string
}

@Test(arguments: [false, true]) func orderedUndoRedoKeepsActualValuesAndRemainingTail(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var store = try await newSession(initial, protection)
    let n = try birthForUndo(), scope = ActionScopeV1.note(n)
    _ = try await put("Shopping", birth: n, generation: 1, session: store)
    _ = try await put("Groceries", birth: n, generation: 2, session: store)
    _ = try await put("Errands", birth: n, generation: 3, session: store)
    _ = try await compensate(store, scope, .undo)
    #expect(try await undoBody(store, n) == "Groceries")
    _ = try await compensate(store, scope, .undo, reviewed: true)
    #expect(try await undoBody(store, n) == "Shopping")
    let selection = await store.selection
    try await store.quiesce(); store = try await .open(selection: selection, protection: protection)
    _ = try await compensate(store, scope, .redo)
    #expect(try await undoBody(store, n) == "Groceries")
    _ = try await compensate(store, scope, .redo)
    #expect(try await undoBody(store, n) == "Errands")
    _ = try await compensate(store, scope, .undo)
    #expect(try await undoBody(store, n) == "Groceries")
    try await store.quiesce()
}

@Test(arguments: [false, true]) func concurrentCompensationsNoOpAndIndependentFamily(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let n = try birthForUndo(), scope = ActionScopeV1.note(n)
    let a = try await put("1", birth: n, generation: 1, session: left)
    _ = try await right.receive(left.retainedObject(at: a.object))
    let u = try await compensate(left, scope, .undo), v = try await compensate(right, scope, .undo)
    _ = try snapshotReceipt(await left.persistGeneralSnapshot(capture: left.captureGeneralSnapshot()))
    _ = try await left.receive(right.retainedObject(at: v.object)); _ = try await right.receive(left.retainedObject(at: u.object))
    _ = try await left.rebuildCurrentRows()
    #expect(try await undoBody(left, n) == "A")
    let p = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(left.retainedObject(at: u.object), collection: initial.descriptor.collection, protection: protection).payload)
    let q = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(right.retainedObject(at: v.object), collection: initial.descriptor.collection, protection: protection).payload)
    #expect(p.actions[0].action.id != q.actions[0].action.id)
    #expect(try await left.undoCandidates(scope: scope, direction: .redo).mode == .review)
    _ = try await compensate(left, scope, .redo, candidate: p.actions[0].action.id, reviewed: true)
    #expect(try await undoBody(left, n) == "1")
    let before = try await left.snapshot().through
    guard case .noEffect = try await left.prepareCompensation(scope: scope, direction: .redo, candidate: q.actions[0].action.id) else { Issue.record("Sibling inverse already absent must be a no-op"); return }
    #expect(try await left.snapshot().through == before)
    _ = try await compensate(left, scope, .undo, reviewed: true)
    #expect(try await undoBody(left, n) == "A")
    _ = try await compensate(left, scope, .redo, reviewed: true)
    #expect(try await undoBody(left, n) == "1")
    _ = try await put("independent X", birth: n, generation: 10, session: left)
    #expect(try await left.undoCandidates(scope: scope, direction: .undo).mode == .automatic)
    _ = try await compensate(left, scope, .undo)
    #expect(try await undoBody(left, n) == "1")
    #expect(try await left.undoCandidates(scope: scope, direction: .redo).mode == .automatic)
    _ = try await compensate(left, scope, .redo)
    #expect(try await undoBody(left, n) == "independent X")
    _ = try await left.rebuildCurrentRows()
    #expect(try await undoBody(left, n) == "independent X")
    try await left.quiesce(); try await right.quiesce()
}

@Test func reviewedCompensationRejectsChangedScopeButAllowsUnrelatedWork() async throws {
    let (initial, protection) = try testInitial(false)
    let store = try await newSession(initial, protection), other = try await newSession(initial, protection)
    let n = try birthForUndo(), scope = ActionScopeV1.note(n)
    _ = try await put("one", birth: n, generation: 1, session: store)
    let first = try await automatic(store.prepareCompensation(scope: scope, direction: .undo))
    await #expect(throws: StorageError.wrongContext) { try await other.applyCompensation(first) }
    _ = try await put("unrelated", birth: birthForUndo(2), generation: 2, session: store)
    _ = try requireReceipt(await store.applyCompensation(first))
    #expect(try await undoBody(store, n) == "A")
    #expect(try await undoBody(store, birthForUndo(2)) == "unrelated")
    let stale = try await automatic(store.prepareCompensation(scope: scope, direction: .redo))
    _ = try await put("new independent", birth: n, generation: 3, session: store)
    let through = try await store.snapshot().through
    await #expect(throws: StorageError.staleCapture) { try await store.applyReviewedCompensation(stale.forReview()) }
    #expect(try await store.snapshot().through == through)
    try await store.quiesce(); try await other.quiesce()
}

@Test(arguments: [false, true]) func concurrentDeleteUndoKeepsFreshBirthMappings(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let n = try birthForUndo(), capture = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .deleteBatch, changes: [.delete(.init(birth: n, generation: 1))])
    let deletion = try requireReceipt(await left.persist(capture: capture))
    _ = try await right.receive(left.retainedObject(at: deletion.object))
    let u = try await compensate(left, .collection, .undo), v = try await compensate(right, .collection, .undo)
    let uBirth = u.covered[0].birth, vBirth = v.covered[0].birth
    #expect(uBirth != vBirth && uBirth != n && vBirth != n)
    _ = try await left.receive(right.retainedObject(at: v.object)); _ = try await right.receive(left.retainedObject(at: u.object))
    let p = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(left.retainedObject(at: u.object), collection: initial.descriptor.collection, protection: protection).payload)
    _ = try await compensate(left, .collection, .redo, candidate: p.actions[0].action.id, reviewed: true)
    #expect(Set(try await left.snapshot().notes.map(\.birth)) == [try birthForUndo(2), vBirth])
    let w = try await compensate(left, .collection, .undo, reviewed: true), wBirth = w.covered[0].birth
    #expect(wBirth != uBirth && wBirth != vBirth && wBirth != n)
    _ = try await compensate(left, .collection, .redo, reviewed: true)
    #expect(Set(try await left.snapshot().notes.map(\.birth)) == [try birthForUndo(2), vBirth])
    let selection = await left.selection
    try await left.quiesce(); left = try await .open(selection: selection, protection: protection)
    #expect(Set(try await left.snapshot().notes.map(\.birth)) == [try birthForUndo(2), vBirth])
    #expect(try await left.history(for: .recentlyDeleted).entries.allSatisfy { $0.birth != n })
    try await left.quiesce(); try await right.quiesce()
}
