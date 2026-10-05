import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

func pendingInput(_ session: LocalStoreSession, body: String) async throws -> PendingSnapshotV1 {
    let s = await session.selection
    return try PendingSnapshotV1(id: PendingSnapshotID(bytes: uuidBytes()),
        scope: PrivateRecordScopeV1(collection: s.descriptor.collection, store: s.store, descriptor: s.descriptor.descriptorID),
        presence: .present, path: ExactUTF8(bytes: Array("external.txt".utf8)),
        observation: PassivePlatformRecordV1(codec: 1, bytes: [42]), source: Array(body.utf8), value: testValue(body))
}

@Test(arguments: [false, true])
func privateSettingsRebuildAndStaleGenerations(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let settings = try CollectionSettingsV1([.storageFormat(0), .secureTextEntry(true), .confirmFileDeletion(false),
        .baseBodyFont(PassivePlatformRecordV1(codec: 1, bytes: [1,2,3]))])
    let first = try await session.collectionSettings()
    try await session.saveCollectionSettings(settings, basedOn: first)
    await #expect(throws: StorageError.staleCapture) { try await session.saveCollectionSettings(try CollectionSettingsV1([]), basedOn: first) }
    let item = try PendingItemID(bytes: uuidBytes()), input = try await pendingInput(session, body: "private")
    try await session.retainPendingSnapshot(input, basedOn: session.pendingItem(item))
    let selection = await session.selection
    let pin = try await session.lane.perform { try $0.rows("SELECT * FROM retained_frontier ORDER BY object_id") }
    try await session.lane.perform { try $0.run("UPDATE current_notes SET cell=?", [.blob([0])]) }
    try await session.quiesce()
    let opened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await opened.collectionSettings().value == settings)
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    #expect(try await opened.retainedPendingSnapshot(input.id) == input)
    #expect(try await opened.lane.perform { try $0.rows("SELECT * FROM retained_frontier ORDER BY object_id") } == pin)
    await #expect(throws: StorageError.wrongContext) { try await opened.saveCollectionSettings(settings, basedOn: first) }
    try await opened.quiesce()
}

@Test(arguments: [false, true])
func pendingImportLostReceiptSurvivesDeleteAndNewPreview(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let item = try PendingItemID(bytes: uuidBytes()), a = try await pendingInput(session, body: "admitted A")
    try await session.retainPendingSnapshot(a, basedOn: session.pendingItem(item))
    let prepared = try await session.preparePendingImport(basedOn: session.pendingItem(item), automatic: false)
    _ = try requireReceipt(await session.persistPendingAction(prepared))
    let b = try await pendingInput(session, body: "unreviewed B")
    let beforeNewPreview = try await session.pendingItem(item)
    try await session.retainPendingSnapshot(b, basedOn: session.pendingItem(item))
    #expect(try await session.retainedPendingSnapshot(a.id) == a)
    await #expect(throws: StorageError.staleCapture) {
        try await session.completePendingAssociation(prepared.reservation.id, basedOn: beforeNewPreview) { _, _ in
            Issue.record("obsolete pending generation reached the physical consumer")
            return try PassivePlatformRecordV1(codec: 1, bytes: [])
        }
    }
    let deletion = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .deleteBatch,
        changes: [.delete(CapturedNoteGeneration(birth: prepared.reservation.birth, generation: 2))])
    _ = try requireReceipt(await session.persist(capture: deletion))
    let selection = await session.selection
    try await session.quiesce()
    let opened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let recovered = try await opened.pendingRecovery(item)
    guard case .committed(let reservation, let op) = try #require(recovered.first) else { Issue.record("committed Import lost after Delete"); return }
    #expect(reservation == prepared.reservation)
    let stale = try await opened.pendingItem(item)
    try await opened.completePendingAssociation(reservation.id, basedOn: stale) { input, currentMatches in
        #expect(input.source == Array("admitted A".utf8) && !currentMatches)
        return try PassivePlatformRecordV1(codec: 1, bytes: [77])
    }
    #expect(try await opened.pendingSettlement(item: item, snapshot: a.id)?.operation == op)
    #expect(try await opened.pendingItem(item).latest == b.id)
    #expect(try await opened.retainedPendingSnapshot(b.id) == b)
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let actions = try await opened.lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") }
    #expect(actions == [[.integer(4)]])
    try await opened.quiesce()
    let again = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await again.pendingRecovery(item).isEmpty)
    #expect(try await again.pendingSettlement(item: item, snapshot: a.id)?.operation == op)
    #expect(try await again.pendingItem(item).latest == b.id)
    try await again.quiesce()
}

@Test(arguments: [false, true])
func pendingFailureIsolationAndNeutralCompletion(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let item = try PendingItemID(bytes: uuidBytes()), a = try await pendingInput(session, body: "A")
    let empty = try await session.pendingItem(item)
    try await session.retainPendingSnapshot(a, basedOn: empty)
    let before = try await session.pendingItem(item), b = try await pendingInput(session, body: "B")
    try await session.lane.perform { try $0.exec("CREATE TEMP TRIGGER refuse_latest BEFORE UPDATE ON pending_items BEGIN SELECT RAISE(ABORT,'failed latest'); END;") }
    await #expect(throws: (any Error).self) { try await session.retainPendingSnapshot(b, basedOn: before) }
    #expect(try await session.pendingItem(item).latest == a.id)
    #expect(try await session.retainedPendingSnapshot(a.id) == a)
    _ = try await put("unrelated", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 1, session: session)
    try await session.lane.perform { try $0.exec("DROP TRIGGER refuse_latest") }
    let cell = try #require(await session.snapshot().notes.first { $0.value.body.string == "A" })
    let r = try PendingReservationV1(id: PendingReservationID(bytes: uuidBytes()), snapshot: a.id,
        decision: .neutralAssociation, birth: cell.birth, effect: .neutral(PendingNeutralStateV1(cell: cell)))
    let reserved = try await session.reservePending(r, basedOn: before)
    let count = try await session.lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") }
    try await session.completePendingAssociation(r.id, basedOn: reserved) { _, matching in
        #expect(matching); return try PassivePlatformRecordV1(codec: 1, bytes: [9])
    }
    #expect(try await session.lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") } == count)
    #expect(try await session.pendingItem(item).latest == nil)
    try await session.quiesce()
}

@Test(arguments: [false, true])
func pendingCompetingReviewReusesBirthAndCommitsOnce(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let item = try PendingItemID(bytes: uuidBytes()), input = try await pendingInput(session, body: "one observation")
    try await session.retainPendingSnapshot(input, basedOn: session.pendingItem(item))
    let state = try await session.pendingItem(item)
    let first = try await session.preparePendingImport(basedOn: state, automatic: false)
    await #expect(throws: StorageError.staleCapture) { try await session.preparePendingImport(basedOn: state, automatic: false) }
    let current = try await session.pendingItem(item)
    let reviewed = try await session.preparePendingImport(basedOn: current, automatic: false)
    #expect(reviewed.reservation.birth == first.reservation.birth)
    #expect(reviewed.reservation.id != first.reservation.id)
    guard case .pending(_, .staleCapture) = try await session.persistPendingAction(first) else { Issue.record("obsolete review was admitted"); return }
    _ = try requireReceipt(await session.persistPendingAction(reviewed))
    await #expect(throws: StorageError.staleCapture) { try await session.preparePendingImport(basedOn: session.pendingItem(item), automatic: false) }
    #expect(try await session.lane.perform { try $0.rows("SELECT COUNT(*) FROM pending_reservations") } == [[.integer(1)]])
    #expect(try await session.snapshot().notes.filter { $0.value == input.value }.count == 1)
    try await session.quiesce()
}

@Test(arguments: [false, true])
func pendingChangedAssociationAndNeutralFactoryReopen(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), item = try PendingItemID(bytes: uuidBytes())
    let changed = try await pendingInput(session, body: "associated edit")
    try await session.retainPendingSnapshot(changed, basedOn: session.pendingItem(item))
    guard case .changed(let action) = try await session.preparePendingAssociation(basedOn: session.pendingItem(item), birth: birth, generation: 1) else { Issue.record("changed association omitted Put"); return }
    let receipt = try requireReceipt(await session.persistPendingAction(action))
    let accepted = try ObjectEnvelopeV1.open(await session.retainedObject(at: receipt.object), collection: initial.descriptor.collection, protection: protection)
    #expect(try ChangesPayloadV1.decodeV1(accepted.payload).operations.first?.operation.id == {
        if case .operation(let id, _, _, _) = action.reservation.effect { id } else { nil }
    }())
    try await session.completePendingAssociation(action.reservation.id, basedOn: session.pendingItem(item)) { _, matches in
        #expect(matches); return try PassivePlatformRecordV1(codec: 1, bytes: [8])
    }
    let neutralItem = try PendingItemID(bytes: uuidBytes()), neutral = try await pendingInput(session, body: "associated edit")
    try await session.retainPendingSnapshot(neutral, basedOn: session.pendingItem(neutralItem))
    guard case .neutral(let reservation) = try await session.preparePendingAssociation(basedOn: session.pendingItem(neutralItem), birth: birth, generation: 2) else { Issue.record("equal association authored echo"); return }
    let count = try await session.lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") }
    try await session.completePendingAssociation(reservation.id, basedOn: session.pendingItem(neutralItem)) { _, matches in
        #expect(matches); return try PassivePlatformRecordV1(codec: 1, bytes: [9])
    }
    #expect(try await session.lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") } == count)
    let selection = await session.selection
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.pendingSettlement(item: item, snapshot: changed.id)?.birth == birth)
    #expect(try await reopened.pendingSettlement(item: neutralItem, snapshot: neutral.id)?.operation == nil)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["associated edit", "untouched"])
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func preservedRepairWaitsForPendingReservationOwner(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let item = try PendingItemID(bytes: uuidBytes()), input = try await pendingInput(session, body: "A")
    try await session.retainPendingSnapshot(input, basedOn: session.pendingItem(item))
    let state = try await session.pendingItem(item), cell = try #require(await session.snapshot().notes.first { $0.value == input.value })
    let reservation = try PendingReservationV1(id: PendingReservationID(bytes: uuidBytes()), snapshot: input.id,
        decision: .neutralAssociation, birth: cell.birth, effect: .neutral(PendingNeutralStateV1(cell: cell)))
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let held = Task {
        try await session.lane.perform { _ in
            entered.signal()
            guard release.wait(timeout: .now() + 10) == .success else { throw StorageError.busy }
        }
    }
    let observed = await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 10) == .success) }
    }
    try #require(observed)
    let preparing = Task { try await session.reservePending(reservation, basedOn: state) }
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    while !(await session.pendingPreparationInFlight) && DispatchTime.now().uptimeNanoseconds < deadline { await Task.yield() }
    try #require(await session.pendingPreparationInFlight)
    await #expect(throws: StorageError.busy) { try await session.closeForPreservedRepair() }
    release.signal()
    try await held.value
    let reserved = try await preparing.value
    #expect(reserved.generation == state.generation + 1)
    try await session.completePendingAssociation(reservation.id, basedOn: reserved) { _, matches in
        #expect(matches); return try PassivePlatformRecordV1(codec: 1, bytes: [9])
    }
    try await session.closeForPreservedRepair()
    let reopened = try await LocalStoreSession.open(selection: session.selection, protection: protection)
    #expect(try await reopened.pendingSettlement(item: item, snapshot: input.id)?.birth == cell.birth)
    try await reopened.quiesce()
}
