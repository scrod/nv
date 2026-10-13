import NVStorageTestSupport
import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

@Test(arguments: [false, true], [false, true])
func mergePreviewAcrossIndependentStores(encrypted: Bool, childFirst: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let base = try await put("a\ngap\nz", birth: birth, generation: 1, session: source)
    _ = try await right.receive(source.retainedObject(at: base.object))
    let leftChange = try await put("A\ngap\nz", birth: birth, generation: 2, session: source)
    let rightChange = try await put("a\ngap\nZ", birth: birth, generation: 1, session: right)
    let l = try await source.retainedObject(at: leftChange.object), r = try await right.retainedObject(at: rightChange.object)
    let baseBytes = try await source.retainedObject(at: base.object)
    let leftID = try #require(try await source.snapshot().notes.first { $0.birth == birth }).revision.id
    let rightID = try #require(try await right.snapshot().notes.first { $0.birth == birth }).revision.id
    let before = try await source.reductionPreview(for: birth)
    guard case .current(let old) = before.reduction.outcome else { Issue.record("single head must remain readable"); return }
    #expect(old.value.body.string == "A\ngap\nz" && old.represented == [leftID] && old.merge == nil)
    _ = try await source.receive(r)
    _ = try await right.receive(l)
    let first = try await source.reductionPreview(for: birth), second = try await right.reductionPreview(for: birth)
    #expect(first.reduction == second.reduction)
    guard case .current(let value) = first.reduction.outcome else { Issue.record("accepted branches must produce a merge preview"); return }
    #expect(value.value.body.string == "A\ngap\nZ" && Set(value.represented) == [leftID, rightID])
    #expect(value.merge?.inputs == first.reduction.heads)
    #expect(before.through < first.through && old.value.body.string == "A\ngap\nz")
    let lane = await source.lane
    let counts = try await lane.perform { try $0.rows("SELECT (SELECT count(*) FROM operations),(SELECT count(*) FROM actions),(SELECT count(*) FROM accepted_objects)") }
    #expect(try await source.reductionPreview(for: birth).reduction == first.reduction)
    #expect(try await lane.perform { try $0.rows("SELECT (SELECT count(*) FROM operations),(SELECT count(*) FROM actions),(SELECT count(*) FROM accepted_objects)") } == counts)
    // Fresh owner can receive the same real history in the opposite transport order.
    var receiver = try await newSession(initial, protection)
    if childFirst {
        guard case .waiting = try await receiver.receive(r) else { Issue.record("missing exact parent must park"); return }
        let selection = await receiver.selection
        try await receiver.quiesce(); receiver = try await .open(selection: selection, protection: protection)
    }
    _ = try await receiver.receive(baseBytes)
    if !childFirst { _ = try await receiver.receive(r) }
    _ = try await receiver.receive(l)
    #expect(try await receiver.reductionPreview(for: birth).reduction == first.reduction)
    guard case .accepted = try await receiver.receivedObjectStatus(at: leftChange.object) else { Issue.record("merge inputs remain accepted"); return }
    let current = try #require(try await receiver.snapshot().notes.first { $0.birth == birth })
    #expect(current.value.body.string == "A\ngap\nZ" && Set(current.represented.map(\.id)) == [leftID, rightID])
    try await expectScopedHistoryMatchesFull(receiver, birth: birth)
    #expect(try await receiver.conflicts(for: birth).alternatives.isEmpty)
    let selection = await receiver.selection
    try await receiver.quiesce(); receiver = try await .open(selection: selection, protection: protection)
    #expect(try await receiver.snapshot().notes.first { $0.birth == birth } == current)
    let edit = try await put("explicit E", birth: birth, generation: 3, session: receiver)
    let editBytes = try await receiver.retainedObject(at: edit.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(editBytes,
        collection: initial.descriptor.collection, protection: protection).payload)
    #expect(Set(payload.operations[0].operation.notePredecessors.ids) == [leftID, rightID])
    guard case .derived(.merged(let inputs, _, _, _)) = payload.actions[0].action.affected[0].before else {
        Issue.record("saved edit must retain merged before-state"); return
    }
    #expect(Set(inputs) == [leftID, rightID])
    _ = try await source.receive(receiver.retainedObject(at: edit.object))
    #expect(try await source.snapshot().notes.first { $0.birth == birth }?.value.body.string == "explicit E")
    try await source.quiesce(); try await right.quiesce(); try await receiver.quiesce()
}

@Test func mergePreviewDamageAndClosedOwner() async throws {
    let (initial, protection) = try testInitial(false), session = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let preview = try await session.reductionPreview(for: birth)
    guard case .current(let v) = preview.reduction.outcome else { Issue.record("bootstrap value"); return }
    #expect(v.value.body.string == "A")
    let other = try NoteBirth(bytes: Array(repeating: 77, count: 16))
    #expect(try await session.reductionPreview(for: other).reduction.outcome == .empty)
    let lane = await session.lane
    try await lane.perform { db in
        let ref = try db.operationOccurrence(v.represented[0])
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(ref.locator.segmentID.bytes)])
    }
    await #expect(throws: CanonicalEncodingError.lengthLimit) { try await session.reductionPreview(for: birth) }
    await #expect(throws: StorageError.integrity) { try await session.snapshot() }
    try await session.quiesce()
    await #expect(throws: StorageError.closed) { try await session.reductionPreview(for: birth) }
}

@Test func mergePreviewRejectsDamagedMembership() async throws {
    let (initial, protection) = try testInitial(false), session = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), other = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    _ = try await put("later", birth: birth, generation: 1, session: session)
    let valid = try await session.reductionPreview(for: birth)
    guard case .current(let value) = valid.reduction.outcome else { Issue.record("valid companion"); return }
    #expect(value.value.body.string == "later")
    let lane = await session.lane
    // Corrupt only membership metadata while keeping every retained envelope intact.
    try await lane.perform { db in
        try db.run("UPDATE operations SET birth=? WHERE birth=? AND kind=4", [.blob(other.bytes), .blob(birth.bytes)])
    }
    await #expect(throws: CanonicalEncodingError.invalidOperation) { try await session.reductionPreview(for: birth) }
    await #expect(throws: StorageError.integrity) { try await session.snapshot() }
    try await session.quiesce()
}
