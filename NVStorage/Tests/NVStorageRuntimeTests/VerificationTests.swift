import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private let reminderQuery = "SELECT group_key,codec,generation,payload FROM private_groups WHERE group_key>=? AND group_key<? ORDER BY group_key"
private let reminderRange: [SQLValue] = [.blob(VerificationRecord.prefix), .blob(VerificationRecord.end)]

/// Keeps the caller's frozen command usable after repeated pre-admission storage failures.
@Test(arguments: [false, true])
func compensationVerificationAdmissionFailurePreservesCommand(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), lane = await session.lane
    _ = try await put("E", birth: birth, generation: 1, session: session)
    guard case .automatic(let command) = try await session.prepareCompensation(scope: .note(birth), direction: .undo) else {
        Issue.record("The valid companion must offer an automatic reversal"); return
    }
    let before = try await session.snapshot()
    let membership = try await lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") }
    try await lane.perform { try $0.exec("CREATE TEMP TRIGGER fail_command_verification BEFORE INSERT ON private_groups WHEN substr(NEW.group_key,1,13)=X'766572696669636174696F6E2F' BEGIN SELECT RAISE(ABORT,'failed command verification admission'); END") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(19 | (7 << 8))) { try await session.applyCompensation(command) }
        let unchanged = try await session.snapshot()
        #expect(unchanged.notes == before.notes && unchanged.context == before.context && unchanged.through == before.through)
        #expect(try await lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") } == membership)
        #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
        #expect(await session.commitState.owned == nil)
    }
    try await lane.perform { try $0.exec("DROP TRIGGER fail_command_verification") }
    let receipt = try requireReceipt(await session.applyCompensation(command))
    #expect(receipt.sequence == before.through + 1)
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM actions") } == [[.integer(4)]])
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
    try await session.quiesce()
}

private actor VerificationAdmissionGate {
    private var arrivals = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var observer: CheckedContinuation<Void, Never>?
    func hold() async {
        await withCheckedContinuation { continuation in
            held.append(continuation); arrivals += 1
            if arrivals == 64 { observer?.resume(); observer = nil }
        }
    }
    func waitForFullAdmission() async {
        if arrivals < 64 { await withCheckedContinuation { observer = $0 } }
    }
    func release() { for continuation in held { continuation.resume() }; held.removeAll() }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func verificationAdmissionBoundPreservesOwnedRequests(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, gate = VerificationAdmissionGate()
    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<64 { group.addTask { try await lane.verifyingHistory { await gate.hold() } } }
        await gate.waitForFullAdmission()
        let requests = try await lane.perform { try $0.rows(reminderQuery, reminderRange) }
        #expect(requests.count == 64 && Set(requests.map { try! $0[0].bytes }).count == 64)
        await #expect(throws: StorageError.busy) {
            try await lane.verifyingHistory { Issue.record("Inspection began without a free verification slot") }
        }
        #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) } == requests)
        let plan = try await lane.perform { try $0.rows("EXPLAIN QUERY PLAN SELECT group_key FROM private_groups WHERE group_key>=? AND group_key<? LIMIT 64", reminderRange) }
        #expect(plan.contains { row in if case .text(let detail) = row.last { detail.contains("SEARCH") && detail.contains("USING COVERING INDEX sqlite_autoindex_private_groups_1") } else { false } })
        await gate.release(); try await group.waitForAll()
    }
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await session.quiesce()
}

@Test(arguments: [false, true])
func verificationFinalGraphFailureSurvivesFailedDiagnosis(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, selection = await session.selection
    let original = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(initial.objects[initial.descriptor.genesis]!,
        collection: selection.descriptor.collection, protection: protection).payload).operations[0].operation
    let extra = try IdentifiedOperation(nonce: OperationNonce(bytes: uuidBytes()), effect: original.effect,
        causalParents: CausalParentSet([]), notePredecessors: NotePredecessorSet([]))
    let payload = try ChangesPayloadV1(dependencies: DependencyLocatorTable([]), operations: [
        OperationRecordV1(operation: extra, causalReferences: [], noteReferences: [], earlierOperations: [])], actions: [])
    let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: selection.descriptor.collection,
        writer: WriterEpoch(bytes: uuidBytes()), sequence: 0, protection: protection)
    let locator = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection).locator
    // Simulates later accepted-index corruption with an independently valid envelope.
    try await lane.perform { db in
        try db.transaction {
            try db.run("INSERT INTO objects VALUES(?,1,?,?,?)", [.blob(locator.segmentID.bytes), .blob(locator.writerEpoch.bytes), .blob(Array(repeating: 0, count: 8)), .blob(bytes)])
            try db.run("INSERT INTO acceptance_batches VALUES(2)")
            try db.run("INSERT INTO accepted_objects VALUES(?,2)", [.blob(locator.segmentID.bytes)])
            try db.run("INSERT INTO operations VALUES(?,1,NULL,NULL,?,0,2)", [.blob(extra.id.bytes), .blob(locator.segmentID.bytes)])
            try db.run("INSERT INTO operation_occurrences VALUES(?,0,?)", [.blob(locator.segmentID.bytes), .blob(extra.id.bytes)])
        }
        db.work = StorageWork()
        try db.exec("CREATE TEMP TRIGGER fail_graph_diagnosis BEFORE INSERT ON private_groups WHEN NEW.group_key=X'686973746F72792D64616D616765' BEGIN SELECT RAISE(ABORT,'failed diagnosis'); END")
    }
    await #expect(throws: StorageError.integrity) { try await lane.snapshotHistoryGraph(through: 2, selection: selection, protection: protection) }
    await lane.close()
    let raw = DatabaseLane()
    try await raw.open(directory: selection.directory, create: false, key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
    #expect(try await raw.perform { try $0.rows(reminderQuery, reminderRange) }.count == 1)
    #expect(try await raw.perform { try $0.rows("SELECT 1 FROM private_groups WHERE group_key=X'686973746F72792D64616D616765'") }.isEmpty)
    await raw.close()
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func verificationReplayIncludesAcceptedSnapshotPages(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, selection = await session.selection
    let snapshot = try snapshotReceipt(await session.persistGeneralSnapshot(capture: session.captureGeneralSnapshot()))
    let gate = ImprovementGate()
    try await lane.perform { db in
        db.work = StorageWork(); db.work?.verificationReplayWillStart = { await gate.hold() }
        let page = try #require(try db.rows("SELECT prerequisite FROM accepted_dependencies WHERE child=? AND prerequisite IN (SELECT object_id FROM objects WHERE kind=3) LIMIT 1", [.blob(snapshot.snapshot.segmentID.bytes)]).first)[0].bytes
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=X'00' WHERE object_id=?", [.blob(page)])
    }
    await #expect(throws: CancellationError.self) { try await lane.verifyingHistory { throw CancellationError() } }
    await gate.wait(); await lane.close(); await gate.release()
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}

@Test func verificationRecipeLiteralLayout() throws {
    let context = Array(repeating: UInt8(7), count: 64)
    let key = Array("verification/".utf8) + Array(repeating: UInt8(9), count: 16)
    let bytes: [UInt8] = [78,86,86,82,70,89,49,10] + context + [2,0,0,0,0,0,0,0,3]
    let record = try VerificationRecord.decode(key: key, codec: 1, generation: 1, bytes: bytes, context: context)
    #expect(record.recipe == .history(3))
    #expect(record.encoded == bytes)
    #expect(throws: StorageError.unsupported) { try VerificationRecord.decode(key: key, codec: 2, generation: 1, bytes: bytes, context: context) }
    #expect(throws: StorageError.integrity) { try VerificationRecord.decode(key: key, codec: 1, generation: 1, bytes: bytes + [0], context: context) }
    #expect(throws: StorageError.integrity) { try VerificationRecord.decode(key: key, codec: 1, generation: 1, bytes: bytes, context: Array(repeating: 8, count: 64)) }
    #expect(throws: StorageError.integrity) { try VerificationRecipe.decode([2,0,0,0,0,0,0,0,0]) }
    let locator = try SegmentLocator(writerEpoch: WriterEpoch(bytes: Array(repeating: 8, count: 16)), sequence: 9,
        segmentID: SegmentID(bytes: Array(repeating: 10, count: 32)))
    let locatorBytes = Array(repeating: UInt8(8), count: 16) + [0,0,0,0,0,0,0,9] + Array(repeating: UInt8(10), count: 32)
    for (tag, recipe) in [(UInt8(1), VerificationRecipe.object(locator)), (3, .bootstrap(locator))] {
        let literal = [UInt8(78),86,86,82,70,89,49,10] + context + [tag] + locatorBytes
        let decoded = try VerificationRecord.decode(key: key, codec: 1, generation: 1, bytes: literal, context: context)
        #expect(decoded.recipe == recipe && decoded.encoded == literal)
        #expect(throws: StorageError.integrity) { try VerificationRecipe.decode([tag] + Array(locatorBytes.dropLast())) }
    }
    #expect(throws: StorageError.unsupported) { try VerificationRecipe.decode([9]) }
}

@Test(arguments: [false, true], [false, true])
func verificationCancellationReplaysExactScope(encrypted: Bool, classified: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, selection = await session.selection
    let before = try await session.snapshot()
    let retryGate = ImprovementGate()
    try await lane.perform { db in db.work = StorageWork(); db.work?.verificationReplayWillStart = { await retryGate.hold() } }
    do {
        try await lane.verifying(.history(before.through)) {
            #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.count == 1)
            _ = try await lane.retainedGraph(through: before.through, selection: selection, protection: protection)
            #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.count == 1)
            if classified { throw classify(CancellationError()) }
            else { throw CancellationError() }
        }
        Issue.record("Cancelled verification must retain its interruption outcome")
    } catch {
        if classified { #expect(error as? StorageError == .cancelled) }
        else { #expect(error is CancellationError) }
        #expect(ReceiveRejection(error) == nil)
    }
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.count == 1)
    await retryGate.wait()
    await lane.close()
    await retryGate.release()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection), nextLane = await reopened.lane
    #expect(try await reopened.snapshot().notes == before.notes)
    #expect(try await nextLane.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func verificationFinalCheckKeepsFailedDiagnosisReplay(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, selection = await session.selection, birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let old = try await put("old", birth: birth, generation: 1, session: session)
    _ = try await put("new", birth: birth, generation: 2, session: session)
    await #expect(throws: StorageError.integrity) {
        try await lane.verifyingHistory {
            let graph = try await lane.retainedGraph(through: 3, selection: selection, protection: protection)
            #expect(graph.operations.count > 3)
            try await lane.perform { db in
                #expect(try db.rows(reminderQuery, reminderRange).count == 1)
                try db.exec("DROP TRIGGER objects_no_update")
                try db.run("UPDATE objects SET encoded=X'00' WHERE object_id=?", [.blob(old.object.segmentID.bytes)])
                try db.exec("CREATE TEMP TRIGGER fail_verification_diagnosis BEFORE INSERT ON private_groups WHEN NEW.group_key=X'686973746F72792D64616D616765' BEGIN SELECT RAISE(ABORT,'failed diagnosis'); END")
                try db.checkingRetainedHistory { throw StorageError.integrity }
            }
        }
    }
    await lane.close()
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}

@Test(arguments: [false, true])
func verificationAdmissionFailureStartsNoInspection(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane
    try await lane.perform { try $0.exec("CREATE TEMP TRIGGER fail_verification_admit BEFORE INSERT ON private_groups WHEN substr(NEW.group_key,1,13)=X'766572696669636174696F6E2F' BEGIN SELECT RAISE(ABORT,'failed admission'); END") }
    await #expect(throws: StorageError.database(19 | (7 << 8))) {
        try await lane.verifyingHistory { Issue.record("Uncovered inspection began after failed admission") }
    }
    try await lane.perform { try $0.exec("DROP TRIGGER fail_verification_admit") }
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
    try await session.quiesce()
}

@Test(arguments: [false, true])
func verificationWrongConnectionCannotReusePermission(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let first = try await newSession(initial, protection), second = try await newSession(initial, protection)
    let a = await first.lane, b = await second.lane
    try await a.verifyingHistory { () async throws -> Void in
        await #expect(throws: StorageError.wrongContext) { try await b.verifyingHistory { Issue.record("Foreign verification permission was consumed") } }
        #expect(try await a.perform { try $0.rows(reminderQuery, reminderRange) }.count == 1)
    }
    #expect(try await a.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
    #expect(try await b.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
    try await first.quiesce(); try await second.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func verificationResumesWithoutAnotherDelivery(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, gate = ImprovementGate(), finished = ImprovementGate()
    try await lane.perform { db in
        db.work = StorageWork(); db.work?.verificationReplayWillStart = { await gate.hold() }
        db.work?.verificationReplayFinished = { await finished.signal() }
    }
    await #expect(throws: CancellationError.self) { try await lane.verifyingHistory { throw CancellationError() } }
    await gate.wait()
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.count == 1)
    await gate.release(); await finished.wait()
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await session.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func verificationSiblingSettlementPreservesOtherRequest(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, hold = ImprovementGate()
    let a = Task { try await lane.verifyingHistory { await hold.hold(); return 1 } }
    await hold.wait()
    let original = try await lane.perform { try $0.rows(reminderQuery, reminderRange) }
    try #require(original.count == 1)
    try await lane.verifyingHistory { () async throws -> Void in
        #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.count == 2)
    }
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) } == original, "B settles only its own request")
    _ = try await put("later save", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) } == original)
    await hold.release(); #expect(try await a.value == 1)
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["later save", "untouched"])
    try await session.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func verificationFailedSettlementRetainsExactIdentity(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, retry = ImprovementGate(), finished = ImprovementGate()
    try await lane.perform { db in
        db.work = StorageWork(); db.work?.verificationReplayWillStart = { await retry.hold() }
        db.work?.verificationReplayFinished = { await finished.signal() }
        try db.exec("CREATE TEMP TRIGGER fail_verification_settle BEFORE DELETE ON private_groups WHEN substr(OLD.group_key,1,13)=X'766572696669636174696F6E2F' BEGIN SELECT RAISE(ABORT,'failed settlement'); END")
    }
    let identity = ImprovementGate()
    let attempt = Task { try await lane.verifyingHistory { await identity.hold(); return 12 } }
    await identity.wait()
    let request = try await lane.perform { try $0.rows(reminderQuery, reminderRange) }
    await identity.release()
    await #expect(throws: StorageError.database(19 | (7 << 8))) { try await attempt.value }
    await retry.wait()
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) } == request)
    try await lane.perform { try $0.exec("DROP TRIGGER fail_verification_settle") }
    await retry.release(); await finished.wait()
    #expect(try await lane.perform { try $0.rows(reminderQuery, reminderRange) }.isEmpty)
    #expect(try await session.snapshot().notes.count == 2)
    try await session.quiesce()
}

@Test(arguments: [false, true], ["codec", "context", "missing"])
func verificationRequiredStateRejectsInvalidReplay(encrypted: Bool, defect: String) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, selection = await session.selection
    let key = VerificationRecord.prefix + Array(repeating: UInt8(21), count: 16)
    try await lane.perform { db in
        let header = try db.rows("SELECT local_store_id,collection_id,bootstrap_descriptor FROM store_header")[0]
        var context = try header.flatMap { try $0.bytes }
        if defect == "context" { context[0] ^= 1 }
        let recipe: [UInt8] = defect == "missing" ? [2,0,0,0,0,0,0,0,9] : [2,0,0,0,0,0,0,0,1]
        try db.run("INSERT INTO private_groups VALUES(?,1,?,?)", [.blob(key), .integer(defect == "codec" ? 7 : 1), .blob([78,86,86,82,70,89,49,10] + context + recipe)])
    }
    await lane.close()
    let expected: StorageError = defect == "codec" ? .unsupported : defect == "missing" ? .incomplete : .integrity
    await #expect(throws: expected) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    let raw = DatabaseLane()
    try await raw.open(directory: selection.directory, create: false, key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
    #expect(try await raw.perform { try $0.rows("SELECT count(*) FROM private_groups WHERE group_key=?", [.blob(key)]) } == [[.integer(1)]])
    await raw.close()
}
