import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

extension LocalStoreSession {
    /// Observes settlement of the real receive owner without driving its worker.
    func waitForReceiveForTesting() async {
        while receiving { await withCheckedContinuation { drained.append($0) } }
    }
}

/// Leaves one complete optional root durably queued at a real lost-completion boundary.
func queuedOptionalSnapshot(_ store: LocalStoreSession) async throws -> (SegmentLocator, [UInt8]) {
    let lane = await store.lane
    try await lane.perform { db in
        db.work = StorageWork()
        db.work?.snapshotCandidateCompletion = { locator in
            let kind = try await lane.perform { try $0.rows("SELECT kind FROM objects WHERE object_id=?", [.blob(locator.segmentID.bytes)])[0][0].number }
            if kind == 2 { throw StorageError.database(10) }
        }
    }
    guard case .pending = try await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()) else {
        Issue.record("Expected a complete queued optional root"); throw StorageError.incomplete
    }
    let rows = try await lane.perform { try $0.rows("SELECT writer_epoch,sequence,object_id,encoded FROM objects JOIN ready_objects USING(object_id)") }
    try #require(rows.count == 1)
    return try (SegmentLocator.decodeV1(rows[0][0].bytes + rows[0][1].bytes + rows[0][2].bytes), rows[0][3].bytes)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func startupSelectsRequiredWorkBehindOptional(encrypted: Bool, rebuild: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let store = try await newSession(initial, protection), peer = try await newSession(initial, protection)
    let (root, bytes) = try await queuedOptionalSnapshot(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("required remote E", birth: birth, generation: 1, session: peer)
    let incoming = try await peer.retainedObject(at: edit.object)
    let lane = await store.lane, selection = await store.selection
    try await lane.perform { db in
        let opened = try ObjectEnvelopeV1.open(incoming, collection: selection.descriptor.collection, protection: protection)
        try db.transaction { try db.retainCandidate(incoming, opened: opened, ready: true) }
        if rebuild { try db.run("UPDATE current_notes SET cell=X'00' WHERE birth=?", [.blob(birth.bytes)]) }
    }
    await lane.close()
    let work = StorageWork(), reopened = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: work)
    let recoveredLane = await reopened.lane
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["required remote E", "untouched"])
    #expect(try await recoveredLane.perform { try $0.rows("SELECT object_id FROM ready_objects") } == [[.blob(root.segmentID.bytes)]])
    let pause = ImprovementGate()
    try await recoveredLane.perform { $0.work?.publishedReceiveStart = { await pause.hold() } }
    let capture = try await reopened.prepareReduction(liveGeneration: 0)
    _ = try await reopened.publish(capture, liveGeneration: 0) { $0 }
    try #require(await reopened.receiving)
    // A repeated publication shares the already reserved receive owner.
    _ = try await reopened.publish(capture, liveGeneration: 0) { $0 }
    await pause.wait()
    await #expect(throws: StorageError.busy) { try await reopened.receive(incoming) }
    _ = try await put("local F", birth: birth, generation: 2, session: reopened)
    await pause.release()
    await reopened.waitForReceiveForTesting()
    #expect(try await reopened.retainedObject(at: root) == bytes)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["local F", "untouched"])
    #expect(try await recoveredLane.perform { try $0.rows("SELECT count(*) FROM ready_objects") } == [[.integer(0)]])
    try await reopened.quiesce(); try await peer.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func optionalStartupRequiresSuccessfulHostPublication(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let (root, bytes) = try await queuedOptionalSnapshot(store), selection = await store.selection
    await store.lane.close()
    let pause = ImprovementGate()
    var work = StorageWork(); work.publishedReceiveStart = { await pause.hold() }
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: work)
    let capture = try await reopened.prepareReduction(liveGeneration: 0)
    await #expect(throws: StorageError.staleCapture) {
        try await reopened.publish(capture, liveGeneration: 1) { $0 }
    }
    await #expect(throws: StorageError.unsupported) {
        try await reopened.publish(capture, liveGeneration: 0) { _ -> Bool in throw StorageError.unsupported }
    }
    #expect(await reopened.receiving == false, "Failed publication leaves background work unreserved")
    #expect(try await reopened.lane.perform { try $0.rows("SELECT encoded FROM objects JOIN ready_objects USING(object_id)") } == [[.blob(bytes)]])
    let published = try await reopened.publish(capture, liveGeneration: 0) { $0 }
    #expect(published.through == 1)
    await pause.wait(); await pause.release(); await reopened.waitForReceiveForTesting()
    #expect(try await reopened.retainedObject(at: root) == bytes)
    #expect(try await reopened.snapshot().through == 2)
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func deferredSnapshotCloseKeepsExactReadyWork(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let (root, bytes) = try await queuedOptionalSnapshot(store), selection = await store.selection
    await store.lane.close()
    let pause = ImprovementGate()
    var work = StorageWork(); work.publishedReceiveStart = { await pause.hold() }
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: work)
    _ = try await reopened.publish(reopened.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
    try #require(await reopened.receiving)
    await pause.wait()
    try await reopened.quiesce()
    await pause.release(); await reopened.waitForReceiveForTesting()
    let next = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await next.snapshot().through == 1)
    #expect(try await next.lane.perform { try $0.rows("SELECT encoded FROM objects JOIN ready_objects USING(object_id) WHERE object_id=?", [.blob(root.segmentID.bytes)]) } == [[.blob(bytes)]])
    _ = try await next.publish(next.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
    await next.waitForReceiveForTesting()
    #expect(try await next.retainedObject(at: root) == bytes)
    try await next.quiesce()
}

@Test(arguments: [false, true])
func deferredRejectionWriteFailuresKeepExactInputAcrossRestart(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let selection = await store.selection, lane = await store.lane
    let bytes = try ObjectEnvelopeV1.seal(payload: [0], kind: .snapshotRoot, collection: initial.descriptor.collection,
        writer: WriterEpoch(bytes: uuidBytes()), sequence: 0, protection: protection)
    let opened = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection)
    try await lane.perform { db in try db.transaction { try db.retainCandidate(bytes, opened: opened, ready: true) } }
    await lane.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection), nextLane = await reopened.lane
    try await nextLane.perform { try $0.exec("CREATE TEMP TRIGGER fail_deferred_rejection BEFORE INSERT ON rejected_objects BEGIN SELECT RAISE(ABORT,'failed rejection'); END") }
    for _ in 0..<2 {
        let result = try await reopened.publish(reopened.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
        #expect(result.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
        await reopened.waitForReceiveForTesting()
        #expect(try await nextLane.perform { try $0.rows("SELECT encoded FROM objects JOIN ready_objects USING(object_id) WHERE object_id=?", [.blob(opened.locator.segmentID.bytes)]) } == [[.blob(bytes)]])
        #expect(try await nextLane.perform { try $0.rows("SELECT count(*) FROM rejected_objects UNION ALL SELECT count(*) FROM accepted_objects WHERE object_id=?", [.blob(opened.locator.segmentID.bytes)]) } == [[.integer(0)], [.integer(0)]])
    }
    await nextLane.close()
    let final = try await LocalStoreSession.open(selection: selection, protection: protection)
    _ = try await final.publish(final.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
    await final.waitForReceiveForTesting()
    #expect(try await final.lane.perform { try $0.rows("SELECT count(*) FROM ready_objects UNION ALL SELECT count(*) FROM rejected_objects") } == [[.integer(0)], [.integer(1)]])
    #expect(try await final.lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(opened.locator.segmentID.bytes)]) } == [[.blob(bytes)]])
    _ = try await put("unrelated save after rejection", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 1, session: final)
    #expect(try await final.snapshot().notes.map(\.value.body.string).sorted() == ["A", "unrelated save after rejection"])
    try await final.quiesce()
}

@Test(arguments: [false, true])
func unfinishedVerificationRemainsRequiredWithOptionalQueue(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let (root, _) = try await queuedOptionalSnapshot(store), lane = await store.lane, selection = await store.selection
    let key = VerificationRecord.prefix + uuidBytes()
    let context = selection.store.bytes + initial.descriptor.collection.bytes + initial.descriptor.descriptorID
    let bytes = Array("NVVRFY1\n".utf8) + context + [2,0,0,0,0,0,0,0,1]
    try await lane.perform { try $0.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(key), .blob(bytes)]) }
    await lane.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: StorageWork())
    #expect(try await reopened.lane.perform { try $0.rows("SELECT group_key FROM private_groups WHERE group_key=?", [.blob(key)]).isEmpty })
    #expect(try await reopened.lane.perform { $0.work!.stages.values.reduce(0) { $0 + $1.historyReads } } > 0)
    #expect(try await reopened.lane.perform { try $0.rows("SELECT object_id FROM ready_objects") } == [[.blob(root.segmentID.bytes)]])
    _ = try await reopened.publish(reopened.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
    await reopened.waitForReceiveForTesting()
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func publishedDrainResumesAfterFiniteSaveInterference(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), peer = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    _ = try await put("local E", birth: birth, generation: 1, session: store)
    let (root, bytes) = try await queuedOptionalSnapshot(store), selection = await store.selection
    await store.lane.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let incoming = try await put("remote R", birth: birth, generation: 1, session: peer)
    let input = try await peer.retainedObject(at: incoming.object), lane = await reopened.lane
    let history = HistoryCheckGate()
    defer { Task { await history.release(2) } }
    try await lane.perform { db in
        let opened = try ObjectEnvelopeV1.open(input, collection: initial.descriptor.collection, protection: protection)
        try db.transaction { try db.retainCandidate(input, opened: opened, ready: true) }
        db.work = StorageWork(); db.work?.historyCheck = { await history.check() }
    }
    _ = try await reopened.publish(reopened.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
    await history.waitFor(1)
    _ = try await put("local F1", birth: b, generation: 1, session: reopened)
    await history.release(1); await history.waitFor(2)
    _ = try await put("local F2", birth: b, generation: 2, session: reopened)
    await history.release(2)
    await reopened.waitForReceiveForTesting()
    #expect(try await reopened.retainedObject(at: incoming.object) == input)
    #expect(try await reopened.retainedObject(at: root) == bytes)
    #expect(try await reopened.lane.perform { $0.work![.validation].fullChecks } == 3)
    #expect(try await reopened.snapshot().notes.first { $0.birth == b }?.value.body.string == "local F2")
    try await expectScopedHistoryMatchesFull(reopened, birth: birth)
    let current = try await reopened.snapshot(), next = await reopened.selection
    try await reopened.quiesce()
    let final = try await LocalStoreSession.open(selection: next, protection: protection)
    #expect(try await final.snapshot().notes == current.notes)
    #expect(try await final.lane.perform { try $0.rows("SELECT count(*) FROM ready_objects") } == [[.integer(0)]])
    try await final.quiesce(); try await peer.quiesce()
}

@Test(arguments: [false, true])
func startupFollowsParkedChangesToRequiredSnapshot(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), peer = try await newSession(initial, protection)
    let (root, rootBytes) = try await queuedOptionalSnapshot(store), lane = await store.lane, selection = await store.selection
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("snapshot-dependent E", birth: birth, generation: 1, session: peer)
    let opened = try await ObjectEnvelopeV1.open(peer.retainedObject(at: edit.object), collection: initial.descriptor.collection, protection: protection)
    let payload = try ChangesPayloadV1.decodeV1(opened.payload)
    let dependent = try ChangesPayloadV1(dependencies: DependencyLocatorTable(payload.dependencies.entries + [root]),
        operations: payload.operations, actions: payload.actions)
    let bytes = try ObjectEnvelopeV1.seal(payload: dependent.encodedV1(), kind: .changes, collection: initial.descriptor.collection,
        writer: WriterEpoch(bytes: uuidBytes()), sequence: 0, protection: protection)
    let envelope = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection)
    try await lane.perform { db in try db.transaction { try db.retainCandidate(bytes, opened: envelope, ready: true) } }
    await lane.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["snapshot-dependent E", "untouched"])
    #expect(try await reopened.snapshot().through == 3)
    #expect(try await reopened.retainedObject(at: root) == rootBytes)
    #expect(try await reopened.retainedObject(at: envelope.locator) == bytes)
    #expect(try await reopened.lane.perform { try $0.rows("SELECT count(*) FROM ready_objects UNION ALL SELECT count(*) FROM object_waits") } == [[.integer(0)], [.integer(0)]])
    try await reopened.quiesce(); try await peer.quiesce()
}
