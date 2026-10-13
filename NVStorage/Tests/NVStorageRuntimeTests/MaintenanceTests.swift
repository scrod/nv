import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private func maintenanceCut(_ lane: DatabaseLane) async throws -> [[[SQLValue]]] {
    try await lane.perform { db in
        try ["SELECT object_id,encoded FROM objects ORDER BY object_id",
             "SELECT * FROM accepted_objects ORDER BY object_id", "SELECT * FROM retained_frontier ORDER BY object_id",
             "SELECT * FROM retained_descriptors ORDER BY object_id", "SELECT * FROM operations ORDER BY operation_id",
             "SELECT * FROM action_members ORDER BY action_id,ordinal", "SELECT * FROM private_groups ORDER BY group_key",
             "SELECT * FROM current_notes ORDER BY birth", "SELECT * FROM current_dictionaries ORDER BY dictionary_id",
             "SELECT * FROM view_meta", "SELECT * FROM pending_payloads ORDER BY snapshot_id",
             "SELECT * FROM pending_items ORDER BY item_id", "SELECT * FROM pending_reservations ORDER BY reservation_id",
             "SELECT * FROM pending_settlements ORDER BY item_id,snapshot_id", "SELECT * FROM ready_objects ORDER BY object_id",
             "SELECT * FROM object_waits ORDER BY child,prerequisite"].map { try db.rows($0) }
    }
}

@Test(arguments: [false, true])
func vacuumPreservesCompletePrivateCutAndFreshReopen(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let settings = try CollectionSettingsV1([.secureTextEntry(true), .confirmFileDeletion(false)])
    try await session.saveCollectionSettings(settings, basedOn: session.collectionSettings())
    let item = try PendingItemID(bytes: uuidBytes()), a = try await pendingInput(session, body: "frozen A")
    try await session.retainPendingSnapshot(a, basedOn: session.pendingItem(item))
    let prepared = try await session.preparePendingImport(basedOn: session.pendingItem(item), automatic: false)
    let b = try await pendingInput(session, body: "latest B")
    try await session.retainPendingSnapshot(b, basedOn: session.pendingItem(item))
    let lane = await session.lane, before = try await maintenanceCut(lane), current = try await session.snapshot()
    #expect(try await session.compactPrivateStore() == .completed)
    #expect(try await maintenanceCut(lane) == before)
    #expect(try await session.snapshot().notes == current.notes)
    let selection = await session.selection; try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.collectionSettings().value == settings)
    #expect(try await reopened.retainedPendingSnapshot(a.id) == a)
    #expect(try await reopened.retainedPendingSnapshot(b.id) == b)
    #expect(try await reopened.pendingItem(item).latest == b.id)
    guard case .review(let reservation) = try #require(await reopened.pendingRecovery(item).first) else {
        Issue.record("compaction lost frozen pending import"); return
    }
    #expect(reservation == prepared.reservation)
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
func resumedSaveCancelsPreparedVacuumAndKeepsExactReceipt(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, gate = ImprovementGate()
    try await lane.perform { db in db.work = StorageWork(); db.work?.vacuumPrepared = { await gate.hold() } }
    let attempt = Task { try await session.compactPrivateStore() }
    await gate.wait()
    let receipt = try await put("resumed durable F", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    let exact = try await session.retainedObject(at: receipt.object)
    await gate.release()
    #expect(try await attempt.value == .interrupted)
    #expect(try await session.retainedObject(at: receipt.object) == exact)
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["resumed durable F", "untouched"])
    // A retired cancellation identity leaves the next required save fully usable.
    let retired = try await lane.perform { try $0.beginVacuum() }
    retired.cancel()
    let selection = await session.selection
    #expect(try await lane.perform { try $0.runVacuum(retired, directory: selection.directory, minimumFreeBytes: 0) } == .interrupted)
    retired.cancel()
    _ = try await put("G after late cancellation", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 2, session: session)
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["G after late cancellation", "untouched"])
    try await session.quiesce()
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true], [false, true])
func vacuumCancellationAndCloseRetainOwnerUntilSettled(encrypted: Bool, closing: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, gate = ImprovementGate(), selection = await session.selection
    try await lane.perform { db in db.work = StorageWork(); db.work?.vacuumPrepared = { await gate.hold() } }
    let attempt = Task { try await session.compactPrivateStore() }; await gate.wait()
    let close = closing ? Task { try await session.quiesce() } : nil
    if closing {
        while !(await session.quiescing) { await Task.yield() }
    } else { attempt.cancel() }
    await #expect(throws: (any Error).self) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    await gate.release()
    #expect(try await attempt.value == .interrupted)
    if let close { try await close.value } else { try await session.quiesce() }
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func vacuumBudgetsSkipWithoutChangingRequiredState(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, before = try await maintenanceCut(lane)
    #expect(try await session.compactPrivateStore(budget: VacuumBudget(maximumStoreBytes: 1)) == .skipped(.storeBudget))
    #expect(try await session.compactPrivateStore(budget: VacuumBudget(minimumFreeBytes: UInt64.max)) == .skipped(.spaceHeadroom))
    #expect(try await maintenanceCut(lane) == before)
    _ = try await put("F after skipped work", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["F after skipped work", "untouched"])
    try await session.quiesce()
}

@Test(arguments: [false, true])
func vacuumRequestRequiresIssuingConnectionBeforeRetirement(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), left = try await newSession(initial, protection)
    let right = try await newSession(initial, protection), leftLane = await left.lane, rightLane = await right.lane
    let request = try await leftLane.perform { try $0.beginVacuum() }
    let leftSelection = await left.selection, rightSelection = await right.selection
    await #expect(throws: StorageError.wrongContext) {
        try await rightLane.perform { try $0.runVacuum(request, directory: rightSelection.directory, minimumFreeBytes: 0) }
    }
    request.cancel()
    #expect(try await leftLane.perform { try $0.runVacuum(request, directory: leftSelection.directory, minimumFreeBytes: 0) } == .interrupted)
    _ = try await put("F after rejected foreign maintenance", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: right)
    #expect(try await right.snapshot().notes.map(\.value.body.string).sorted() == ["F after rejected foreign maintenance", "untouched"])
    try await left.quiesce(); try await right.quiesce()
}
