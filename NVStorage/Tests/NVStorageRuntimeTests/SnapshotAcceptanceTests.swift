import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

func snapshotReceipt(_ result: SnapshotCommitOutcome) throws -> AcceptedSnapshotReceipt {
    guard case .accepted(let receipt) = result else { Issue.record("Expected complete durable snapshot acceptance"); throw StorageError.incomplete }
    return receipt
}

/// Holds a real candidate or acceptance completion with compiler-isolated continuations.
private actor SnapshotGate {
    var entered = false
    var completion: CheckedContinuation<Void, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation in
            completion = continuation
            let ready = observers; observers.removeAll(); for observer in ready { observer.resume() }
        }
    }
    func wait() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { completion?.resume(); completion = nil }
}

@Test(arguments: [false, true], [false, true])
func snapshotAcceptancePreservesValuesAndCompletePin(encrypted: Bool, paged: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put(paged ? String(repeating: "a", count: 600_000) : "Saved E", birth: birth, generation: 1, session: store)
    let lane = await store.lane, before = try await store.snapshot()
    let counts = try await lane.perform { try $0.rows("SELECT (SELECT count(*) FROM actions),(SELECT count(*) FROM operations)") }
    let receipt = try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))
    #expect(try await lane.perform { try $0.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(receipt.snapshot.segmentID.bytes)]) } == [[.integer(receipt.sequence)]])
    let preview = try await GeneralSnapshotPreviewV1.read(snapshot: receipt.snapshot, collection: initial.descriptor.collection,
        protection: protection) { try await store.retainedObject(at: $0) }
    #expect(receipt.pages == preview.pages && !receipt.pages.isEmpty)
    if paged { #expect(receipt.pages.count >= 4) }
    let after = try await store.snapshot()
    #expect(after.notes == before.notes && after.context == before.context && after.viewEpoch == before.viewEpoch)
    #expect(after.through == before.through + 1 && receipt.sequence == after.through)
    #expect(try await lane.perform { try $0.rows("SELECT (SELECT count(*) FROM actions),(SELECT count(*) FROM operations)") } == counts)
    let expectedRoot = Set(preview.historyLocators.map(\.segmentID)).union([preview.root.tree.locator.segmentID])
    let rootEdges = try await lane.perform { db in
        try Set(db.rows("SELECT prerequisite FROM accepted_dependencies WHERE child=?", [.blob(receipt.snapshot.segmentID.bytes)]).map { try SegmentID(bytes: $0[0].bytes) })
    }
    #expect(rootEdges == expectedRoot)
    for page in receipt.pages {
        let opened = try await ObjectEnvelopeV1.open(store.retainedObject(at: page), collection: initial.descriptor.collection, protection: protection)
        let decoded = try GeneralSnapshotPageV1.decodeV1(opened.payload)
        let expected: Set<SegmentID>
        if case .index(let children) = decoded.contents { expected = Set(children.map { $0.locator.segmentID }) } else { expected = [] }
        let edges = try await lane.perform { db in
            try Set(db.rows("SELECT prerequisite FROM accepted_dependencies WHERE child=?", [.blob(page.segmentID.bytes)]).map { try SegmentID(bytes: $0[0].bytes) })
        }
        #expect(edges == expected)
        #expect(try await lane.perform { try $0.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(page.segmentID.bytes)]) } == [[.integer(receipt.sequence)]])
    }
    #expect(try await lane.perform { try $0.rows("SELECT object_id FROM retained_frontier") } == [[.blob(receipt.snapshot.segmentID.bytes)]])
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM ready_objects") } == [[.integer(0)]])
    let rootBytes = try await store.retainedObject(at: receipt.snapshot)
    let selection = await store.selection; try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes == before.notes)
    #expect(try await reopened.retainedObject(at: receipt.snapshot) == rootBytes)
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], ["construction", "completion"])
func snapshotWorkYieldsToNewerOrdinarySave(encrypted: Bool, stage: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), lane = await store.lane
    let capture = try await store.captureGeneralSnapshot(), gate = SnapshotGate()
    try await lane.perform { db in
        db.work = StorageWork()
        if stage == "construction" { db.work?.snapshotCandidateCompletion = { _ in await gate.hold() } }
        else { db.work?.acceptanceCompletion = { _ in await gate.hold() } }
    }
    let construction = Task { try await store.persistGeneralSnapshot(capture: capture) }
    await gate.wait()
    // Further ordinary callbacks proceed while this one snapshot completion is held.
    try await lane.perform { $0.work?.acceptanceCompletion = nil }
    let edit = try await put("Newer F", birth: birth, generation: 2, session: store)
    let publication = try await store.prepareReduction(liveGeneration: 1)
    var host = try await HeadlessModel(snapshot: store.snapshot())
    _ = try host.put(testValue("Unsaved G"), birth: birth)
    await gate.release()
    let receipt = try snapshotReceipt(await construction.value)
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "Newer F")
    #expect(host.values[birth]?.body.string == "Unsaved G" && !host.pending.isEmpty)
    await #expect(throws: StorageError.staleCapture) {
        try await store.publish(publication, liveGeneration: 2) { $0 }
    }
    let frontier = try await lane.perform { try Set($0.rows("SELECT object_id FROM retained_frontier").map { try $0[0].bytes }) }
    #expect(frontier == [receipt.snapshot.segmentID.bytes, edit.object.segmentID.bytes])
    let proof = try await store.verifyGeneralSnapshot(GeneralSnapshotPreviewV1.read(snapshot: receipt.snapshot,
        collection: initial.descriptor.collection, protection: protection) { try await store.retainedObject(at: $0) })
    #expect(proof.operationIDs.count == 4)
    try await store.quiesce()
}

@Test(arguments: [false, true], ["page", "root", "accepted"])
func snapshotRetriesExactBytesAfterLostCompletion(encrypted: Bool, stage: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), lane = await store.lane
    try await lane.perform { db in
        db.work = StorageWork()
        if stage == "accepted" { db.work?.acceptanceCompletion = { _ in throw StorageError.database(10) } }
        else {
            db.work?.snapshotCandidateCompletion = { locator in
                let kind = try await lane.perform { try $0.rows("SELECT kind FROM objects WHERE object_id=?", [.blob(locator.segmentID.bytes)])[0][0].number }
                if (stage == "page" && kind == 3) || (stage == "root" && kind == 2) { throw StorageError.database(10) }
            }
        }
    }
    guard case .pending(let handle, .database(10)) = try await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()) else {
        Issue.record("The real post-commit completion must fail"); return
    }
    let retained = try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    let through = try await lane.perform { try $0.acceptedThrough() }
    #expect(through == (stage == "accepted" ? 2 : 1))
    #expect(await store.snapshotState.owned != nil)
    try await lane.perform { $0.work = nil }
    let receipt = try snapshotReceipt(await store.retry(snapshot: handle))
    for row in retained {
        #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [row[0]]) } == [[row[1]]])
    }
    #expect(receipt.sequence == 2)
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM acceptance_batches") } == [[.integer(2)]])
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await store.quiesce()
}

@Test(arguments: [false, true])
func snapshotCaptureAndRetryRequireTheIssuingOwner(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let capture = try await left.captureGeneralSnapshot(), lane = await left.lane
    await #expect(throws: StorageError.wrongContext) { try await right.persistGeneralSnapshot(capture: capture) }
    try await lane.perform { db in db.work = StorageWork(); db.work?.acceptanceCompletion = { _ in throw StorageError.database(10) } }
    guard case .pending(let handle, _) = try await left.persistGeneralSnapshot(capture: capture) else { Issue.record("Expected owned ambiguous completion"); return }
    await #expect(throws: StorageError.wrongContext) { try await right.retry(snapshot: handle) }
    try await lane.perform { $0.work = nil }
    let receipt = try snapshotReceipt(await left.retry(snapshot: handle))
    let preview = try await GeneralSnapshotPreviewV1.read(snapshot: receipt.snapshot,
        collection: initial.descriptor.collection, protection: protection) { try await left.retainedObject(at: $0) }
    let selection = await left.selection
    let checked = try await CheckedSnapshotAcceptance.verify(preview, lane: lane, selection: selection, protection: protection)
    try await lane.perform { try checked.check(database: $0, selection: selection) }
    let copy = try await LocalStoreSession.create(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        initial: initial, protection: protection, storeID: selection.store)
    let copiedLane = await copy.lane, copiedSelection = await copy.selection
    _ = try snapshotReceipt(await copy.persistGeneralSnapshot(capture: copy.captureGeneralSnapshot()))
    #expect(copiedSelection.store == selection.store)
    #expect(try await copy.snapshot().through == checked.through)
    await #expect(throws: StorageError.wrongContext) { try await copiedLane.perform { try checked.check(database: $0, selection: copiedSelection) } }
    try await copy.quiesce()
    try await left.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.persistGeneralSnapshot(capture: capture) }
    await #expect(throws: StorageError.wrongContext) { try await reopened.retry(snapshot: handle) }
    let reopenedLane = await reopened.lane
    await #expect(throws: StorageError.wrongContext) {
        try await reopenedLane.perform { try checked.check(database: $0, selection: selection) }
    }
    try await reopened.quiesce(); try await right.quiesce()
}

@Test(arguments: [false, true])
func snapshotRootReadyRecoveryUsesRetainedExactCandidates(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), lane = await store.lane
    try await lane.perform { db in
        db.work = StorageWork()
        db.work?.snapshotCandidateCompletion = { locator in
            let kind = try await lane.perform { try $0.rows("SELECT kind FROM objects WHERE object_id=?", [.blob(locator.segmentID.bytes)])[0][0].number }
            if kind == 2 { throw StorageError.database(10) }
        }
    }
    guard case .pending = try await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()) else { Issue.record("Expected interrupted root completion"); return }
    #expect(try await lane.perform { try $0.acceptedThrough() } == 1)
    let roots = try await lane.perform { try $0.rows("SELECT o.object_id,o.encoded FROM ready_objects r JOIN objects o USING(object_id)") }
    try #require(roots.count == 1)
    let selection = await store.selection
    await lane.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection), recoveredLane = await reopened.lane
    #expect(try await reopened.snapshot().through == 2)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    #expect(try await recoveredLane.perform { try $0.rows("SELECT count(*) FROM ready_objects") } == [[.integer(0)]])
    #expect(try await recoveredLane.perform { try $0.rows("SELECT encoded FROM objects JOIN accepted_objects USING(object_id) WHERE object_id=?", [roots[0][0]]) } == [[roots[0][1]]])
    try await reopened.quiesce()
}

/// Independent candidate sink supplies authentic claims to ready processing.
private actor SnapshotCandidates {
    let collection: CollectionID
    let protection: ObjectProtectionV1
    var sequence: UInt64 = 0
    var objects: [(SegmentLocator, [UInt8])] = []
    init(collection: CollectionID, protection: ObjectProtectionV1) { self.collection = collection; self.protection = protection }
    func emit(_ kind: ProviderObjectKind, _ payload: [UInt8]) throws -> SegmentLocator {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection,
            writer: WriterEpoch(bytes: Array(repeating: 88, count: 16)), sequence: sequence, protection: protection)
        sequence += 1
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        objects.append((locator, bytes)); return locator
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func snapshotCancellationRetainsCandidatesAndAllowsOrdinarySaving(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), lane = await store.lane
    let capture = try await store.captureGeneralSnapshot(), gate = SnapshotGate()
    try await lane.perform { db in db.work = StorageWork(); db.work?.snapshotCandidateCompletion = { _ in await gate.hold() } }
    let building = Task { try await store.persistGeneralSnapshot(capture: capture) }
    await gate.wait(); building.cancel(); await gate.release()
    guard case .pending(let handle, .busy) = try await building.value else { Issue.record("Cancellation must retain a retryable snapshot"); return }
    let candidates = try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects WHERE object_id NOT IN (SELECT object_id FROM accepted_objects)") }
    try #require(candidates.count == 1)
    #expect(try await lane.perform { try $0.acceptedThrough() } == 1)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("Saved after cancellation", birth: birth, generation: 1, session: store)
    try await lane.perform { $0.work = nil }
    _ = try snapshotReceipt(await store.retry(snapshot: handle))
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "Saved after cancellation")
    #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects JOIN accepted_objects USING(object_id) WHERE object_id=?", [candidates[0][0]]) } == [[candidates[0][1]]])
    try await store.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], ["pending", "construction", "completion"])
func snapshotOptionalWorkAllowsDurableClose(encrypted: Bool, stage: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), lane = await store.lane
    let gate = SnapshotGate(), capture = try await store.captureGeneralSnapshot()
    try await lane.perform { db in
        db.work = StorageWork()
        if stage == "pending" { db.work?.snapshotCandidateCompletion = { _ in throw StorageError.database(10) } }
        else if stage == "construction" { db.work?.snapshotCandidateCompletion = { _ in await gate.hold() } }
        else { db.work?.acceptanceCompletion = { _ in await gate.hold() } }
    }
    let building = Task { try await store.persistGeneralSnapshot(capture: capture) }
    if stage == "pending" {
        guard case .pending = try await building.value else { Issue.record("Expected retained candidate work"); return }
    } else { await gate.wait() }
    let retained = try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    await #expect(throws: Never.self) { try await store.quiesce() }
    let closed = await store.closed
    #expect(closed)
    #expect(await store.snapshotState.owned == nil)
    guard closed else { await gate.release(); _ = try await building.value; await lane.close(); return }
    let selection = await store.selection
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection), reopenedLane = await reopened.lane
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    #expect(try await reopened.snapshot().through == (stage == "completion" ? 2 : 1))
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("Saved after reopen", birth: birth, generation: 1, session: reopened)
    await gate.release()
    if stage != "pending" {
        let result = try await building.value
        if stage == "completion" { #expect(try snapshotReceipt(result).sequence == 2) }
        else {
            guard case .pending(_, .closed) = result else { Issue.record("Closed construction must stop at the next emission"); return }
        }
    }
    #expect(await store.snapshotState.owned == nil)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["Saved after reopen", "untouched"])
    for row in retained {
        #expect(try await reopenedLane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [row[0]]) } == [[row[1]]])
    }
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func snapshotRequiredPageDamageRevokesEditablePublication(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), lane = await store.lane
    let receipt = try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))
    let page = try #require(receipt.pages.first), selection = await store.selection
    try await lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(page.segmentID.bytes)])
    }
    await #expect(throws: CanonicalEncodingError.lengthLimit) {
        try await lane.acceptGeneralSnapshot(receipt.snapshot, selection: selection, protection: protection)
    }
    await #expect(throws: StorageError.integrity) { try await store.snapshot() }
    try await store.quiesce()
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}

@Test(arguments: [false, true], [false, true])
func snapshotReadySemanticRejectionPreservesUnrelatedHistory(encrypted: Bool, wrong: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), lane = await store.lane
    let capture = try await store.captureGeneralSnapshot(), sink = SnapshotCandidates(collection: initial.descriptor.collection, protection: protection)
    var records = capture.records
    if wrong {
        let index = try #require(records.firstIndex { if case .current = $0 { true } else { false } })
        guard case .current(let cell) = records[index] else { throw StorageError.integrity }
        records[index] = try .current(.init(birth: cell.birth, value: testValue("Unauthored wrong body"),
            revision: cell.revision, scopeFrontier: cell.scopeFrontier))
    }
    let root = try await GeneralSnapshotV1.write(records: records, bootstrapSnapshot: capture.bootstrapSnapshot) { try await sink.emit($0, $1) }
    #expect(ReceiveRejection(GeneralSnapshotError.missingObject(root)) == nil)
    for (locator, bytes) in await sink.objects {
        try await lane.perform { db in
            try db.retainSnapshotCandidate(bytes, opened: ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection,
                protection: protection, expectedLocator: locator))
        }
    }
    _ = try await lane.drainReady(selection: store.selection, protection: protection)
    let admitted = try await lane.perform { try $0.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(root.segmentID.bytes)]) }
    #expect(admitted.isEmpty == wrong)
    #expect(try await lane.perform { try $0.rows("SELECT reason FROM rejected_objects WHERE object_id=?", [.blob(root.segmentID.bytes)]) } == (wrong ? [[.integer(ReceiveRejection.invalidBeforeAfter.rawValue)]] : []))
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("Unrelated valid saved edit", birth: birth, generation: 1, session: store)
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "Unrelated valid saved edit")
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM ready_objects") } == [[.integer(0)]])
    if wrong {
        for (locator, bytes) in await sink.objects {
            #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]) } == [[.blob(bytes)]])
        }
    }
    try await store.quiesce()
}
