import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

private func boundaryBirth() throws -> NoteBirth { try .init(bytes: Array(repeating: 1, count: 16)) }
private func subject(_ store: LocalStoreSession) async throws -> CurrentNoteCellV1 {
    let birth = try boundaryBirth()
    return try #require(try await store.snapshot().notes.first { $0.birth == birth })
}

@Test(arguments: [false, true], [10_000, 10_001])
func runtimeMergeBoundaryPreservesValidHistory(encrypted: Bool, lines: Int) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var left = try await newSession(initial, protection)
    let right = try await newSession(initial, protection), birth = try boundaryBirth()
    var baseLines = (0..<lines).map { "line \($0)" }
    let base = try await put(baseLines.joined(separator: "\n"), birth: birth, generation: 1, session: left)
    _ = try await right.receive(left.retainedObject(at: base.object))
    var leftLines = baseLines, rightLines = baseLines
    leftLines[0] = "Left"; rightLines[lines - 1] = "Right"
    let l = try await put(leftLines.joined(separator: "\n"), birth: birth, generation: 2, session: left)
    let r = try await put(rightLines.joined(separator: "\n"), birth: birth, generation: 2, session: right)
    let rID = try await subject(right).revision.id
    _ = try await left.receive(right.retainedObject(at: r.object))
    _ = try await right.receive(left.retainedObject(at: l.object))
    let current = try await subject(left), preview = try await left.reductionPreview(for: birth)
    #expect(current.heads.count == 2)
    #expect(try await subject(right) == current)
    if lines == 10_000 {
        baseLines[0] = "Left"; baseLines[lines - 1] = "Right"
        #expect(current.value.body.string == baseLines.joined(separator: "\n"))
        #expect(current.represented.count == 2 && current.derived != nil)
    } else {
        guard case .conflict(_, .lineLimit) = preview.reduction.outcome else {
            Issue.record("A valid over-limit two-sided history must require review"); return
        }
        #expect(current.represented.count == 1)
        #expect([leftLines.joined(separator: "\n"), rightLines.joined(separator: "\n")].contains(current.value.body.string))
    }
    guard case .accepted = try await left.receivedObjectStatus(at: r.object) else {
        Issue.record("Merge review preserves accepted remote history"); return
    }
    let selection = await left.selection
    try await left.quiesce(); left = try await .open(selection: selection, protection: protection)
    #expect(try await subject(left) == current)

    // An explicit choice establishes one common head for long one-sided/equal companions.
    let choice = try requireReceipt(await left.persist(capture: left.chooseVersion(for: birth, revision: rID, generation: 3)))
    _ = try await right.receive(left.retainedObject(at: choice.object))
    let unchanged = try await subject(left).value.body.string
    let unchangedLeft = try await put(unchanged, birth: birth, generation: 4, session: left)
    rightLines[0] = "One-sided"
    let oneSided = try await put(rightLines.joined(separator: "\n"), birth: birth, generation: 4, session: right)
    _ = try await left.receive(right.retainedObject(at: oneSided.object))
    _ = try await right.receive(left.retainedObject(at: unchangedLeft.object))
    #expect(try await subject(left).value.body.string == rightLines.joined(separator: "\n"))
    #expect(try await subject(left).represented.count == 2)
    let collapsed = try await put("Equal\n" + unchanged, birth: birth, generation: 5, session: left)
    _ = try await right.receive(left.retainedObject(at: collapsed.object))
    let equalBody = try await subject(left).value.body.string
    let equalLeft = try await put(equalBody, birth: birth, generation: 6, session: left)
    let equalRight = try await put(equalBody, birth: birth, generation: 6, session: right)
    _ = try await left.receive(right.retainedObject(at: equalRight.object))
    _ = try await right.receive(left.retainedObject(at: equalLeft.object))
    #expect(try await subject(left).value.body.string == equalBody)
    #expect(try await subject(left).represented.count == 2)
    #expect(try await subject(left) == subject(right))
    try await left.quiesce(); try await right.quiesce()
}

@Test(arguments: [false, true])
func thirdWriterFencesPreparedMergeAndPreservesUnchosenHeads(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let third = try await newSession(initial, protection), birth = try boundaryBirth()
    let base = try await put("a\ngap\nmiddle\nz", birth: birth, generation: 1, session: left)
    let baseBytes = try await left.retainedObject(at: base.object)
    _ = try await right.receive(baseBytes); _ = try await third.receive(baseBytes)
    let l = try await put("A\ngap\nmiddle\nz", birth: birth, generation: 2, session: left)
    let lID = try await subject(left).revision.id
    let r = try await put("a\ngap\nmiddle\nZ", birth: birth, generation: 2, session: right)
    let rID = try await subject(right).revision.id
    _ = try await left.receive(right.retainedObject(at: r.object))
    #expect(try await subject(left).value.body.string == "A\ngap\nmiddle\nZ")
    let prepared = try await left.prepareReduction(liveGeneration: 7)
    let t = try await put("a\ngap\nThird\nz", birth: birth, generation: 2, session: third)
    let tID = try await subject(third).revision.id
    _ = try await left.receive(third.retainedObject(at: t.object))
    await #expect(throws: StorageError.staleCapture) {
        try await left.publish(prepared, liveGeneration: 7) { $0.notes.count }
    }
    let three = try await subject(left)
    #expect(Set(three.heads.map(\.id)) == [lID, rID, tID] && three.derived == nil)
    guard case .conflict(_, .headCount) = try await left.reductionPreview(for: birth).reduction.outcome else {
        Issue.record("Three differing heads require review"); return
    }
    _ = try await third.receive(left.retainedObject(at: l.object))
    let mergedBasis = try await subject(third)
    #expect(mergedBasis.value.body.string == "A\ngap\nThird\nz")
    #expect(Set(mergedBasis.represented.map(\.id)) == [lID, tID])
    let extensionReceipt = try await put("independent descendant", birth: birth, generation: 3, session: third)
    let extensionID = try await subject(third).revision.id
    _ = try await left.receive(third.retainedObject(at: extensionReceipt.object))
    #expect(Set(try await subject(left).heads.map(\.id)) == [rID, extensionID])
    #expect(try await left.retainedObject(at: l.object) == third.retainedObject(at: l.object))
    try await left.quiesce(); try await right.quiesce(); try await third.quiesce()
}

/// Holds a real post-commit completion while the host admits its next generation.
private actor CompensationCompletionGate {
    private var entered = false, released = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        let ready = observers; observers.removeAll()
        for observer in ready { observer.resume() }
        if !released { await withCheckedContinuation { completion = $0 } }
    }
    func wait() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { released = true; completion?.resume(); completion = nil }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func compensationCompletionPreservesNewerPendingGeneration(encrypted: Bool, deleteNewer: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let store = try await newSession(initial, protection), birth = try boundaryBirth()
    _ = try await put("saved A", birth: birth, generation: 1, session: store)
    let basis = try await store.snapshot()
    var model = HeadlessModel(snapshot: basis)
    let e = try model.put(testValue("A"), birth: birth)
    guard case .automatic(let proposal) = try await store.prepareCompensation(scope: .note(birth), direction: .undo, generation: e.generation) else {
        Issue.record("Saved edit must produce an actual compensation"); return
    }
    let gate = CompensationCompletionGate(), lane = await store.lane
    try await lane.perform { db in
        db.work = StorageWork()
        db.work?.acceptanceCompletion = { _ in await gate.hold() }
    }
    let saving = Task { try await store.applyCompensation(proposal) }
    await gate.wait()
    let f = try deleteNewer ? model.delete(birth) : model.put(testValue("newer F"), birth: birth)
    await gate.release()
    let receipt = try requireReceipt(await saving.value)
    #expect(receipt.covered == [e])
    try model.complete(receipt)
    #expect(model.pending[birth] == f)
    #expect(model.values[birth]?.body.string == (deleteNewer ? nil : "newer F"))
    let bytes = try await store.retainedObject(at: receipt.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection).payload)
    #expect(payload.actions[0].action.kind == .undo)
    #expect(payload.operations[0].operation.effect.noteValue?.body.string == "A")
    try await lane.perform { $0.work?.acceptanceCompletion = nil }
    let next = try await model.capture(birth, at: store.snapshot())
    try model.complete(requireReceipt(await store.persist(capture: next)))
    #expect(model.pending.isEmpty)
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == (deleteNewer ? ["untouched"] : ["newer F", "untouched"]))
    #expect(try await reopened.retainedObject(at: receipt.object) == bytes)
    try await reopened.quiesce()
}
