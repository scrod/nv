import NVStorageTestSupport
import NVStorageCore
@testable import NVStorageRuntime
import Testing

private func commandBirth(_ byte: UInt8 = 1) throws -> NoteBirth { try .init(bytes: Array(repeating: byte, count: 16)) }
private func joinedMerge(_ encrypted: Bool) async throws -> (LocalStoreSession, LocalStoreSession, ObjectProtectionV1) {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try commandBirth(), base = try await put("a\ngap\nz", birth: birth, generation: 1, session: left)
    _ = try await right.receive(left.retainedObject(at: base.object))
    let l = try await put("A\ngap\nz", birth: birth, generation: 2, session: left)
    let r = try await put("a\ngap\nZ", birth: birth, generation: 2, session: right)
    _ = try await left.receive(right.retainedObject(at: r.object)); _ = try await right.receive(left.retainedObject(at: l.object))
    return (left, right, protection)
}

@Test(arguments: [false, true]) func mergedDeleteRestoresExactStateAndSelectedPriorBranch(encrypted: Bool) async throws {
    let (left, right, protection) = try await joinedMerge(encrypted)
    let birth = try commandBirth(), before = try #require(try await left.snapshot().notes.first { $0.birth == birth })
    #expect(before.value.body.string == "A\ngap\nZ" && before.represented.count == 2)
    _ = try snapshotReceipt(await left.persistGeneralSnapshot(capture: left.captureGeneralSnapshot()))
    let deletion = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .deleteBatch, changes: [.delete(.init(birth: birth, generation: 3))])
    let receipt = try requireReceipt(await left.persist(capture: deletion))
    _ = try await right.receive(left.retainedObject(at: receipt.object))
    let rebuilt = try await left.rebuildCurrentRows()
    #expect(rebuilt.notes.map(\.value.body.string) == ["untouched"])
    let entry = try #require(try await left.history(for: .recentlyDeleted).entries.first)
    guard case .deletedState(_, let state, let value) = try await left.preview(entry).state else { Issue.record("Delete must preview its merged admission state"); return }
    #expect(state == before.state && value == before.value)
    let restoration = try await left.restoration(from: entry, as: .init(birth: commandBirth(3), generation: 4))
    let restoreCapture = try await CapturedActionGroup(snapshot: left.snapshot(), restoring: [restoration])
    let restored = try requireReceipt(await left.persist(capture: restoreCapture))
    _ = try await right.receive(left.retainedObject(at: restored.object))
    let freshBirth = try commandBirth(3)
    #expect(try await right.snapshot().notes.first { $0.birth == freshBirth }?.value == before.value)
    #expect(try await right.history(for: .recentlyDeleted).entries.isEmpty)
    let branch = try #require(try await right.history(for: .note(birth)).entries.first { $0.operation == before.represented[0].id })
    let selected = try await right.restoration(from: right.history(for: .deletions).entries[0], as: .init(birth: commandBirth(4), generation: 5), selecting: branch)
    let separate = try await CapturedActionGroup(snapshot: right.snapshot(), restoring: [selected])
    _ = try requireReceipt(await right.persist(capture: separate))
    #expect(selected.value.body.string != before.value.body.string)
    // A separate owner can undo the original merged Delete as a fresh exact restoration.
    guard case .automatic(let undo) = try await left.prepareCompensation(scope: .collection, direction: .undo, candidate: nil) else { Issue.record("Restore itself remains automatically undoable"); return }
    _ = try requireReceipt(await left.applyCompensation(undo))
    guard case .automatic(let undoDelete) = try await left.prepareCompensation(scope: .collection, direction: .undo) else { Issue.record("Merged Delete remains automatically undoable"); return }
    _ = try requireReceipt(await left.applyCompensation(undoDelete))
    #expect(try await left.snapshot().notes.filter { $0.value.body.string == "A\ngap\nZ" }.count == 1)
    _ = try await left.rebuildCurrentRows()
    #expect(try await left.snapshot().notes.filter { $0.value.body.string == "A\ngap\nZ" }.count == 1)
    let selection = await left.selection; try await left.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.contains { $0.value.body.string == "A\ngap\nZ" })
    try await reopened.quiesce(); try await right.quiesce()
}

@Test(arguments: [false, true]) func sourceChoiceFencesConsentAndHistoryFieldsStayExplicit(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection), third = try await newSession(initial, protection)
    let birth = try commandBirth(), initialEntry = try #require(try await left.history(for: .note(birth)).entries.first)
    let l = try await put("Left", birth: birth, generation: 1, session: left), r = try await put("Right", birth: birth, generation: 1, session: right)
    let rID = try #require(try await right.snapshot().notes.first { $0.birth == birth }).revision.id
    _ = try await left.receive(right.retainedObject(at: r.object))
    let choice = try await left.chooseVersion(for: birth, revision: rID, generation: 2)
    let t = try await put("Third", birth: birth, generation: 1, session: third)
    _ = try await left.receive(third.retainedObject(at: t.object))
    let before = try await left.snapshot().through
    guard case .pending(_, .staleCapture) = try await left.persist(capture: choice) else { Issue.record("Changed source requires fresh consent"); return }
    #expect(try await left.snapshot().through == before)
    let fresh = try await left.chooseVersion(for: birth, revision: rID, generation: 3)
    let chosen = try requireReceipt(await left.persist(capture: fresh))
    _ = try await right.receive(left.retainedObject(at: l.object)); _ = try await right.receive(third.retainedObject(at: t.object)); _ = try await right.receive(left.retainedObject(at: chosen.object))
    #expect(try await right.snapshot().notes.first { $0.birth == birth }?.value.body.string == "Right")
    let current = try #require(try await left.snapshot().notes.first { $0.birth == birth })
    let fields = try PlaintextNoteValue(title: .init(bytes: Array("New title".utf8)), body: current.value.body,
        labels: .init([.init(bytes: Array("new label".utf8))]), created: current.value.created, modified: current.value.modified)
    let metadata = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .rename, changes: [.put(.init(birth: birth, generation: 4), fields)])
    _ = try requireReceipt(await left.persist(capture: metadata))
    let bodyOnly = try await left.recoverHistory(initialEntry, to: birth, generation: 5)
    _ = try requireReceipt(await left.persist(capture: bodyOnly))
    let bodyResult = try #require(try await left.snapshot().notes.first { $0.birth == birth })
    #expect(bodyResult.value.body.string == "A" && bodyResult.value.title == fields.title && bodyResult.value.labels == fields.labels)
    let all = try await left.recoverHistory(initialEntry, to: birth, generation: 6, fields: .all)
    _ = try requireReceipt(await left.persist(capture: all))
    #expect(try await left.snapshot().notes.first { $0.birth == birth }?.value.title != fields.title)
    let separate = try await left.recoverHistory(initialEntry, to: commandBirth(4), generation: 7, separate: true)
    _ = try requireReceipt(await left.persist(capture: separate))
    let historyCopyBirth = try commandBirth(4)
    #expect(try await left.snapshot().notes.first { $0.birth == historyCopyBirth }?.identity == nil)

    // A choice already committed observes only its captured heads; a later remote
    // descendant remains an independent source alternative through fresh reopening.
    let settled = try #require(try await left.snapshot().notes.first { $0.birth == birth })
    let late = try await put("Late third", birth: birth, generation: 2, session: third)
    let lateID = try #require(try await third.snapshot().notes.first { $0.birth == birth }).revision.id
    _ = try await left.receive(third.retainedObject(at: late.object))
    let lateState = try #require(try await left.snapshot().notes.first { $0.birth == birth })
    #expect(Set(lateState.heads.map(\.id)) == [settled.revision.id, lateID])
    let selection = await left.selection
    try await left.quiesce(); try await right.quiesce(); try await third.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.first { $0.birth == birth } == lateState)
    try await reopened.quiesce()
}
