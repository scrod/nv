import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
import CSQLCipher
@testable import NVStorageRuntime

/// Exact test envelopes assembled independently of the receive queue.
private actor ReceiveSnapshotSink {
    let collection: CollectionID
    let protection: ObjectProtectionV1
    let writer = try! WriterEpoch(bytes: uuidBytes())
    var sequence: UInt64 = 0
    var objects: [SegmentLocator: [UInt8]] = [:]
    init(collection: CollectionID, protection: ObjectProtectionV1) { self.collection = collection; self.protection = protection }
    func emit(_ kind: ProviderObjectKind, _ payload: [UInt8]) throws -> SegmentLocator {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection,
            writer: writer, sequence: sequence, protection: protection)
        sequence += 1
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        objects[locator] = bytes; return locator
    }
}

private struct ReceivedSnapshotFixture: Sendable {
    let root: SegmentLocator
    let objects: [SegmentLocator: [UInt8]]
    let leaves: [SegmentLocator]
    let indexes: [SegmentLocator]
    static func build(_ capture: GeneralSnapshotCapture, protection: ObjectProtectionV1,
                      records: [GeneralSnapshotRecordV1]? = nil, chunkBytes: Int? = nil, fanout: Int = 128) async throws -> Self {
        let records = try GeneralSnapshotV1.canonicalOrder(records ?? capture.records)
        let streamBytes = try 10 + records.reduce(0) { try $0 + $1.encodedV1().count }
        let sink = ReceiveSnapshotSink(collection: capture.collection, protection: protection)
        let root = try await GeneralSnapshotV1.write(records: records, bootstrapSnapshot: capture.bootstrapSnapshot,
            chunkBytes: chunkBytes ?? (streamBytes + 1) / 2, fanout: fanout) { try await sink.emit($0, $1) }
        let objects = await sink.objects
        var leaves: [SegmentLocator] = [], indexes: [SegmentLocator] = []
        for (locator, bytes) in objects where locator != root {
            let page = try GeneralSnapshotPageV1.decodeV1(ObjectEnvelopeV1.open(bytes, collection: capture.collection, protection: protection).payload)
            switch page.contents { case .data: leaves.append(locator); case .index: indexes.append(locator) }
        }
        return Self(root: root, objects: objects, leaves: leaves.sorted { $0.sequence < $1.sequence }, indexes: indexes.sorted { $0.sequence < $1.sequence })
    }
}

private func permutations(_ values: [Int]) -> [[Int]] {
    if values.isEmpty { return [[]] }
    return values.flatMap { first in permutations(values.filter { $0 != first }).map { [first] + $0 } }
}
private let receivedOrders = permutations([0, 1, 2, 3])

private func receivedAccepted(_ result: ObjectAcceptanceOutcome) -> Bool { if case .accepted = result { true } else { false } }
private func receivedBlocked(_ result: ObjectAcceptanceOutcome?) -> Bool { if case .blocked? = result { true } else { false } }

private func receiveHistory(from source: LocalStoreSession, into receiver: LocalStoreSession) async throws {
    let bytes = try await source.lane.perform { try $0.rows("SELECT encoded FROM objects JOIN accepted_objects USING(object_id) WHERE kind=1 ORDER BY seq,object_id") }
    for row in bytes { _ = try await receiver.receive(row[0].bytes) }
}

private func receiveSnapshot(_ fixture: ReceivedSnapshotFixture, into receiver: LocalStoreSession) async throws -> ObjectAcceptanceOutcome {
    for page in fixture.indexes + fixture.leaves { _ = try await receiver.receive(fixture.objects[page]!) }
    return try await receiver.receive(fixture.objects[fixture.root]!)
}

@Test(arguments: [false, true], [false, true])
func receivedInitialSnapshotUsesCompleteBootstrapValidation(encrypted: Bool, rootFirst: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), receiver = try await newSession(initial, protection)
    let collection = initial.descriptor.collection, sink = ReceiveSnapshotSink(collection: collection, protection: protection)
    let original = try InitialSnapshotRootV1.decodeV1(ObjectEnvelopeV1.open(initial.objects[initial.snapshot]!, collection: collection, protection: protection).payload)
    var pages: [InitialSnapshotPageReferenceV1] = []
    for page in original.pages {
        let opened = try ObjectEnvelopeV1.open(initial.objects[page.locator]!, collection: collection, protection: protection)
        let locator = try await sink.emit(.snapshotPage, opened.payload)
        pages.append(.init(index: page.index, locator: locator, rowCount: page.rowCount))
    }
    let root = try InitialSnapshotRootV1(importID: original.importID, initialCount: original.initialCount,
        digest: original.digest, dependencies: original.dependencies, completion: original.completion,
        frontier: original.frontier, pages: pages)
    let locator = try await sink.emit(.snapshotRoot, root.encodedV1()), objects = await sink.objects
    if rootFirst {
        guard case .waiting(let requirements) = try await receiver.receive(objects[locator]!) else { Issue.record("Initial root must wait for its exact pages"); return }
        #expect(Set(requirements) == Set(pages.map { .retainedBytes($0.locator) }))
    }
    for page in pages {
        let outcome = try await receiver.receive(objects[page.locator]!)
        if !rootFirst || page.locator != pages.last!.locator {
            guard case .retainedForAssembly = outcome else { Issue.record("Initial page is retained independently"); return }
        }
    }
    guard case .accepted = try await receiver.receive(objects[locator]!) else { Issue.record("Complete initial snapshot must use its own validator"); return }
    let lane = await receiver.lane
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") } == [[.integer(4)], [.integer(2)]])
    let generations = try await lane.perform { try $0.rows("SELECT seq FROM accepted_objects WHERE object_id IN (SELECT object_id FROM objects WHERE writer_epoch=?)", [.blob(locator.writerEpoch.bytes)]) }
    #expect(generations.count == pages.count + 1 && generations.allSatisfy { $0 == [.integer(2)] })
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let selection = await receiver.selection; try await receiver.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.retainedObject(at: locator) == objects[locator])
    _ = try await put("Save after initial snapshot", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: reopened)
    try await reopened.quiesce()
}

@Suite(.serialized)
struct ReceivedSnapshotWorkTests {
    @Test(.timeLimit(.minutes(10)), arguments: [false, true], [64, 256, 1024])
    func receivedSnapshotGrowingHistoryMeasuresCompleteWork(encrypted: Bool, actions: Int) async throws {
        let history = try await GrowthHistoryFixtures.shared.fixture(encrypted: encrypted, actions: actions)
        let protection = history.protection
        let sender = try await history.openSender(), receiver = try await history.openReceiver()
        let capture = try await sender.captureGeneralSnapshot(), lane = await receiver.lane
        let references = Set(capture.records.flatMap { $0.operationReferences.map(\.locator) + $0.actionReferences.map(\.locator) } + [capture.bootstrapSnapshot])
        let recordBytes = try capture.records.reduce(0) { try $0 + $1.encodedV1().count }
        let sourceCount = try await lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") }
        for budget in [64, 1] {
            let fixture = try await ReceivedSnapshotFixture.build(capture, protection: protection, chunkBytes: budget == 1 ? 128 : 1024, fanout: 2)
            for page in fixture.indexes + fixture.leaves { _ = try await receiver.receive(fixture.objects[page]!) }
            try await lane.perform { db in db.work = StorageWork(); db.work?.receiveRecordsPerTurn = budget }
            let start = DispatchTime.now().uptimeNanoseconds
            guard case .accepted = try await receiver.receive(fixture.objects[fixture.root]!) else { Issue.record("Every valid size/budget must accept"); return }
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let work = try await lane.perform { try #require($0.work) }, counts = work[.preparation]
            #expect(counts.candidateReads == 2 + fixture.leaves.count + fixture.indexes.count + references.count)
            #expect(counts.snapshotRecords == capture.records.count && counts.snapshotRecordBytes == recordBytes)
            #expect(counts.largestCandidateBytes <= Int(ObjectLimitsV1.encodedPayloadBytes) + 156)
            #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") } == sourceCount)
            #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["E\(actions)", "untouched"])
            let turns = work.stages.values.reduce(0) { $0 + $1.writerTurns }, maxTurn = work.stages.values.map(\.maxWriterNanoseconds).max() ?? 0
            let sql = work.stages.values.reduce(0) { $0 + $1.statements }, reads = work.stages.values.reduce(0) { $0 + $1.historyReads }
            print("RECEIVE-SNAPSHOT actions=\(actions) encrypted=\(encrypted) budget=\(budget) pages=\(fixture.leaves.count + fixture.indexes.count) records=\(counts.snapshotRecords) recordBytes=\(counts.snapshotRecordBytes) candidateReads=\(counts.candidateReads) candidateBytes=\(counts.candidateBytes) historyReads=\(reads) sql=\(sql) writerTurns=\(turns) maxWriterNS=\(maxTurn) acceptanceNS=\(work[.acceptance].nanoseconds) totalNS=\(elapsed)")
        }
        try await receiver.quiesce(); try await sender.quiesce()
    }
}

@Test(arguments: [false, true])
func receivedSnapshotWideHeadsKeepEveryBranch(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    var bodies: [OperationID: String] = [:]
    for n in 0..<8 {
        let peer = try await newSession(initial, protection), body = "Independent writer \(n)"
        let edit = try await put(body, birth: birth, generation: 1, session: peer)
        let revision = try #require(try await peer.snapshot().notes.first { $0.birth == birth }).revision.id
        bodies[revision] = body
        let bytes = try await peer.retainedObject(at: edit.object)
        _ = try await sender.receive(bytes); _ = try await receiver.receive(bytes)
        try await peer.quiesce()
    }
    let selected = try #require(bodies.keys.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }.first)
    let capture = try await sender.captureGeneralSnapshot()
    let wide = try #require(capture.records.compactMap { if case .current(let cell) = $0 { cell } else { nil } }.first { $0.birth == birth })
    try #require(wide.heads.count == 8)
    for budget in [64, 1] {
        let fixture = try await ReceivedSnapshotFixture.build(capture, protection: protection, chunkBytes: 128, fanout: 2)
        try #require(fixture.indexes.count > 2 && fixture.leaves.count > 8)
        let lane = await receiver.lane
        try await lane.perform { db in db.work = StorageWork(); db.work?.receiveRecordsPerTurn = budget }
        guard case .accepted = try await receiveSnapshot(fixture, into: receiver) else { Issue.record("Every valid wide continuation must accept"); return }
        let cell = try #require(try await receiver.snapshot().notes.first { $0.birth == birth })
        #expect(Set(cell.heads.map(\.id)) == Set(bodies.keys))
        #expect(cell.value.body.string == bodies[selected])
        #expect(try await receiver.lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") } == [[.integer(12)], [.integer(10)]])
    }
    let selection = await receiver.selection; try await receiver.quiesce(); try await sender.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(Set(try #require(try await reopened.snapshot().notes.first { $0.birth == birth }).heads.map(\.id)) == Set(bodies.keys))
    _ = try await put("Unrelated save preserves wide source", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 1, session: reopened)
    #expect(try #require(try await reopened.snapshot().notes.first { $0.birth == birth }).heads.count == 8)
    try await reopened.quiesce()
}

@Test(arguments: [false, true], ["scope", "deleted", "restored", "undo", "copied", "retired"])
func receivedSnapshotContinuationClaimsPreserveCommandBehavior(encrypted: Bool, stage: String) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection), peer = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), fresh = try NoteBirth(bytes: Array(repeating: 41, count: 16))
    _ = try await put("Source E", birth: birth, generation: 1, session: source)
    func deletion(_ target: NoteBirth) async throws {
        let captured = try await CapturedActionGroup(snapshot: source.snapshot(), kind: .deleteBatch, changes: [.delete(.init(birth: target, generation: 2))])
        _ = try requireReceipt(await source.persist(capture: captured))
    }
    if stage == "deleted" || stage == "restored" { try await deletion(birth) }
    if stage == "restored" {
        let entry = try #require(try await source.history(for: .recentlyDeleted).entries.first { $0.birth == birth })
        let restored = try await source.restoration(from: entry, as: .init(birth: fresh, generation: 3))
        let captured = try await CapturedActionGroup(snapshot: source.snapshot(), restoring: [restored])
        _ = try requireReceipt(await source.persist(capture: captured))
    }
    if stage == "undo" {
        guard case .automatic(let undo) = try await source.prepareCompensation(scope: .note(birth), direction: .undo) else { Issue.record("Real Undo must qualify"); return }
        _ = try requireReceipt(await source.applyCompensation(undo))
    }
    var recovered: NoteBirth?, revision: OperationID?
    if stage == "copied" || stage == "retired" {
        let r = try await put("Peer R", birth: birth, generation: 1, session: peer)
        revision = try #require(try await peer.snapshot().notes.first { $0.birth == birth }).revision.id
        _ = try await source.receive(peer.retainedObject(at: r.object))
        let captured = try await source.copyVersion(for: birth, revision: revision!, generation: 3)
        _ = try requireReceipt(await source.persist(capture: captured)); recovered = captured.covered[0].birth
        if stage == "retired" { try await deletion(recovered!) }
    }
    try await receiveHistory(from: source, into: receiver)
    let capture = try await source.captureGeneralSnapshot(), expected = try await source.snapshot()
    let fixture = try await ReceivedSnapshotFixture.build(capture, protection: protection, chunkBytes: 256, fanout: 2)
    guard case .accepted = try await receiveSnapshot(fixture, into: receiver) else { Issue.record("Complete causal claims must accept"); return }
    #expect(try await receiver.snapshot().notes == expected.notes)
    var wrong = capture.records
    if stage == "scope" || stage == "undo" {
        let i = try #require(wrong.firstIndex { if case .current(let cell) = $0 { cell.birth == birth } else { false } })
        guard case .current(let cell) = wrong[i] else { return }
        try #require(!cell.scopeFrontier.isEmpty)
        if stage == "scope" {
            wrong[i] = try .current(.init(birth: cell.birth, value: cell.value, represented: cell.represented,
                heads: cell.heads, provenance: cell.provenance, scopeFrontier: [], identity: cell.identity))
        } else {
            let original = try #require(try await peer.snapshot().notes.first { $0.birth == birth })
            try #require(original.value == cell.value && original.revision.id != cell.revision.id)
            wrong[i] = try .current(.init(birth: cell.birth, value: cell.value, revision: original.revision,
                scopeFrontier: cell.scopeFrontier))
        }
    } else if stage == "restored" {
        let i = try #require(wrong.firstIndex { if case .restored = $0 { true } else { false } })
        guard case .restored(let source, let deletion, _, let target) = wrong[i] else { return }
        wrong[i] = .restored(source: source, deletion: deletion, action: try .init(bytes: uuidBytes()), birth: target)
    } else {
        let tag: UInt8 = stage == "deleted" ? 4 : stage == "retired" ? 5 : 6
        try #require(wrong.contains { $0.tag == tag })
        wrong.removeAll { $0.tag == tag }
    }
    let authenticWrong = try await ReceivedSnapshotFixture.build(capture, protection: protection, records: wrong, chunkBytes: 256, fanout: 2)
    let beforeWrong = try await receiver.snapshot()
    await #expect(throws: OrdinaryHistoryError.invalidBeforeAfter) { try await receiveSnapshot(authenticWrong, into: receiver) }
    #expect(try await receiver.snapshot().notes == beforeWrong.notes)
    #expect(try await receiver.snapshot().through == beforeWrong.through)
    #expect(try await receiver.lane.perform { try $0.rows("SELECT reason FROM rejected_objects WHERE object_id=?", [.blob(authenticWrong.root.segmentID.bytes)]) } == [[.integer(ReceiveRejection.invalidBeforeAfter.rawValue)]])
    let selection = await receiver.selection; try await receiver.quiesce()
    receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await receiver.snapshot().notes == expected.notes)
    if stage == "scope" { try #require(capture.records.contains { if case .scope(.note(birth), _) = $0 { true } else { false } }) }
    if stage == "deleted" { #expect(try await receiver.history(for: .recentlyDeleted).entries.map(\.birth) == [birth]) }
    if stage == "restored" {
        try #require(capture.records.contains { if case .restored = $0 { true } else { false } })
        #expect(try await receiver.history(for: .recentlyDeleted).entries.isEmpty)
        #expect(try await receiver.snapshot().notes.contains { $0.birth == fresh && $0.value.body.string == "Source E" })
    }
    if stage == "undo" {
        guard case .automatic(let redo) = try await receiver.prepareCompensation(scope: .note(birth), direction: .redo) else { Issue.record("Portable Redo context must survive receipt/reopen"); return }
        _ = try requireReceipt(await receiver.applyCompensation(redo))
        #expect(try await receiver.snapshot().notes.first { $0.birth == birth }?.value.body.string == "Source E")
    }
    if let revision {
        #expect(try await receiver.conflicts(for: birth).representedSeparately.contains(revision))
        if stage == "retired" {
            try #require(capture.records.contains { if case .retired = $0 { true } else { false } })
            let again = try await receiver.copyVersion(for: birth, revision: revision, generation: 4)
            #expect(again.covered[0].birth != recovered)
        }
    }
    _ = try await put("Further ordinary save", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 10, session: receiver)
    try await receiver.quiesce(); try await source.quiesce(); try await peer.quiesce()
}

/// Reads committed SQL independently of the damaged owner's admission checks.
private final class ReceivedStoreInspection {
    private var handle: OpaquePointer?
    init(_ selection: LocalStoreSelection, _ protection: ObjectProtectionV1) throws {
        guard sqlite3_open_v2(selection.directory + "/Collection.sqlite", &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw StorageError.integrity }
        let key = try PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection)
        let raw = "x'" + key.map { String(format: "%02x", $0) }.joined() + "'"
        guard sqlite3_key(handle, raw, Int32(raw.utf8.count)) == SQLITE_OK else { throw StorageError.integrity }
    }
    deinit { sqlite3_close(handle) }
    func integer(_ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw StorageError.integrity }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw StorageError.integrity }
        return sqlite3_column_int64(statement, 0)
    }
}

/// Arranges a discovery/parking interleaving without occupying the database executor.
private actor ReceiveSnapshotGate {
    var entered = false
    var held: CheckedContinuation<Void, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation in
            held = continuation; let ready = observers; observers.removeAll(); for observer in ready { observer.resume() }
        }
    }
    func wait() async { if !entered { await withCheckedContinuation { observers.append($0) } } }
    func release() { held?.resume(); held = nil }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], [1, 2])
func receivedSnapshotPreparationKeepsProgressAcrossLocalSaves(encrypted: Bool, budget: Int) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let capture = try await sender.captureGeneralSnapshot(), fixture = try await ReceivedSnapshotFixture.build(capture, protection: protection, chunkBytes: 128, fanout: 2)
    for page in fixture.indexes + fixture.leaves { _ = try await receiver.receive(fixture.objects[page]!) }
    let first = ReceiveSnapshotGate(), second = ReceiveSnapshotGate(), lane = await receiver.lane
    try await lane.perform { db in
        db.work = StorageWork(); db.work?.receiveRecordsPerTurn = budget
        db.work?.snapshotPreparationYield = { locator, count in
            if locator == fixture.root, count == budget { await first.hold() }
            if locator == fixture.root, count == 2 * budget { await second.hold() }
        }
    }
    let receiving = Task { try await receiver.receive(fixture.objects[fixture.root]!) }
    await first.wait()
    let birth = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    _ = try await put("Local F1", birth: birth, generation: 1, session: receiver)
    await first.release(); await second.wait()
    _ = try await put("Local F2", birth: birth, generation: 2, session: receiver)
    await second.release()
    guard case .accepted = try await receiving.value else { Issue.record("Finite save interference must require no new delivery"); return }
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["A", "Local F2"])
    let counts = try await lane.perform { $0.work![.preparation] }
    let historyCount = Set(capture.records.flatMap { $0.operationReferences.map(\.locator) + $0.actionReferences.map(\.locator) } + [capture.bootstrapSnapshot]).count
    #expect(counts.candidateReads == 2 + fixture.leaves.count + fixture.indexes.count + historyCount)
    #expect(counts.snapshotRecords == capture.records.count)
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM ready_objects UNION ALL SELECT count(*) FROM object_waits") } == [[.integer(0)], [.integer(0)]])
    let selection = await receiver.selection; try await receiver.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "Local F2"])
    try await reopened.quiesce(); try await sender.quiesce()
}

/// A watchdog observes close; held callbacks establish the disputed schedule.
private func receiveClosed(_ session: LocalStoreSession) async throws -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if await session.closed { return true }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    return await session.closed
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], ["page", "blocked", "preparing", "completion"])
func receivedSnapshotOptionalClosePreservesOwnedInputs(encrypted: Bool, stage: String) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let fixture = try await ReceivedSnapshotFixture.build(sender.captureGeneralSnapshot(), protection: protection)
    let lane = await receiver.lane, selection = await receiver.selection, gate = ReceiveSnapshotGate()
    let target = stage == "page" ? fixture.leaves[0] : fixture.root
    if stage == "preparing" || stage == "completion" {
        for page in fixture.indexes + fixture.leaves { _ = try await receiver.receive(fixture.objects[page]!) }
    }
    try await lane.perform { db in
        db.work = StorageWork()
        if stage == "completion" { db.work?.acceptanceCompletion = { locator in if locator == target { await gate.hold() } } }
        else if stage != "blocked" { db.work?.receiveRetentionCompletion = { locator in if locator == target { await gate.hold() } } }
    }
    let receiving = Task { try await receiver.receive(fixture.objects[target]!) }
    if stage == "blocked" {
        guard case .waiting = try await receiving.value else { Issue.record("Missing pages must finish by durable parking"); return }
    } else { await gate.wait() }
    let retained = try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    let closing = Task { try await receiver.quiesce() }
    let closed = try await receiveClosed(receiver)
    #expect(closed, "Optional preparation or completion must permit close while held")
    if !closed { await gate.release(); _ = try? await receiving.value; try await closing.value; try await sender.quiesce(); return }
    try await closing.value
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection), reopenedLane = await reopened.lane
    #expect(try await reopened.snapshot().through == (stage == "completion" ? 2 : 1))
    if stage == "preparing" {
        _ = try await reopened.publish(reopened.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
        await reopened.waitForReceiveForTesting()
        #expect(try await reopened.snapshot().through == 2)
    }
    _ = try await put("New owner's edit", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 7, session: reopened)
    await gate.release()
    if stage == "completion" {
        guard case .accepted(let sequence) = try await receiving.value else { Issue.record("Late completion must report its actual historical commit"); return }
        #expect(sequence == 2)
    } else if stage != "blocked" { await #expect(throws: StorageError.closed) { try await receiving.value } }
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["New owner's edit", "untouched"])
    for row in retained { #expect(try await reopenedLane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [row[0]]) } == [[row[1]]]) }
    if stage == "blocked" { guard case .waiting = try await reopened.receivedObjectStatus(at: target) else { Issue.record("Blocked root must remain parked after reopening"); return } }
    if stage == "page" { guard case .retainedForAssembly = try await reopened.receivedObjectStatus(at: target) else { Issue.record("Standalone page must remain inert"); return } }
    try await reopened.quiesce(); try await sender.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func receivedSnapshotCancellationPreservesRetryAndCurrent(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let fixture = try await ReceivedSnapshotFixture.build(sender.captureGeneralSnapshot(), protection: protection)
    for page in fixture.indexes + fixture.leaves { _ = try await receiver.receive(fixture.objects[page]!) }
    let lane = await receiver.lane, selection = await receiver.selection, gate = ReceiveSnapshotGate()
    try await lane.perform { db in db.work = StorageWork(); db.work?.receiveRetentionCompletion = { locator in if locator == fixture.root { await gate.hold() } } }
    let receiving = Task { try await receiver.receive(fixture.objects[fixture.root]!) }
    await gate.wait(); receiving.cancel(); await gate.release()
    await #expect(throws: CancellationError.self) { try await receiving.value }
    #expect(try await lane.perform { try $0.rows("SELECT object_id FROM ready_objects") } == [[.blob(fixture.root.segmentID.bytes)]])
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM rejected_objects") } == [[.integer(0)]])
    _ = try await put("Edit after cancellation", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: receiver)
    try await receiver.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    guard case .pendingValidation = try await reopened.receivedObjectStatus(at: fixture.root) else { Issue.record("Optional input must remain durably queued before publication"); return }
    _ = try await reopened.publish(reopened.prepareReduction(liveGeneration: 0), liveGeneration: 0) { $0 }
    await reopened.waitForReceiveForTesting()
    guard case .accepted = try await reopened.receivedObjectStatus(at: fixture.root) else { Issue.record("Durable ready input must resume after host publication"); return }
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["Edit after cancellation", "untouched"])
    try await reopened.quiesce(); try await sender.quiesce()
}

@Test(arguments: [false, true], ["park", "reject"])
func receivedSnapshotRepeatedRecordingFailuresPreserveRetry(encrypted: Bool, stage: String) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection)
    let fixture = try await ReceivedSnapshotFixture.build(sender.captureGeneralSnapshot(), protection: protection)
    let sink = ReceiveSnapshotSink(collection: initial.descriptor.collection, protection: protection)
    let bad = try await sink.emit(.snapshotRoot, []), badBytes = try #require(await sink.objects[bad])
    let target = stage == "park" ? fixture.root : bad, bytes = stage == "park" ? fixture.objects[fixture.root]! : badBytes
    let lane = await receiver.lane, selection = await receiver.selection
    let trigger = stage == "park"
        ? "CREATE TEMP TRIGGER fail_receive BEFORE INSERT ON object_waits BEGIN SELECT RAISE(ABORT,'qualification park failure'); END"
        : "CREATE TEMP TRIGGER fail_receive BEFORE DELETE ON ready_objects BEGIN SELECT RAISE(ABORT,'qualification reject failure'); END"
    try await lane.perform { try $0.exec(trigger) }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) { try await receiver.receive(bytes) }
        #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects JOIN ready_objects USING(object_id) WHERE object_id=?", [.blob(target.segmentID.bytes)]) } == [[.blob(bytes)]])
        #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM object_waits UNION ALL SELECT count(*) FROM rejected_objects") } == [[.integer(0)], [.integer(0)]])
        #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    }
    try await lane.perform { try $0.exec("DROP TRIGGER fail_receive") }
    try await receiver.quiesce()
    receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
    if stage == "park" { guard case .waiting = try await receiver.receivedObjectStatus(at: target) else { Issue.record("Unfinished parking must resume"); return } }
    else { await #expect(throws: CanonicalEncodingError.truncated) { try await receiver.receivedObjectStatus(at: target) } }
    _ = try await put("Unrelated after repair", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 1, session: receiver)
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["A", "Unrelated after repair"])
    try await receiver.quiesce(); try await sender.quiesce()
}

@Test(arguments: [false, true], ["metadata", "body", "index"])
func receivedSnapshotRequiredDamageStaysBlockedDespiteMarkerFailure(encrypted: Bool, damage: String) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let e = try await put("Required E", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: sender)
    _ = try await receiver.receive(sender.retainedObject(at: e.object))
    let fixture = try await ReceivedSnapshotFixture.build(sender.captureGeneralSnapshot(), protection: protection)
    for page in fixture.indexes + fixture.leaves { _ = try await receiver.receive(fixture.objects[page]!) }
    let lane = await receiver.lane, selection = await receiver.selection
    try await lane.perform { db in
        try db.exec("CREATE TEMP TRIGGER fail_damage BEFORE INSERT ON private_groups WHEN NEW.group_key=X'686973746F72792D64616D616765' BEGIN SELECT RAISE(ABORT,'qualification damage recording failure'); END")
        if damage == "index" {
            try db.exec("PRAGMA foreign_keys=OFF")
            try db.run("DELETE FROM operation_occurrences WHERE object_id=?", [.blob(e.object.segmentID.bytes)])
        } else {
            try db.exec("DROP TRIGGER objects_no_update")
            if damage == "body" { try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(e.object.segmentID.bytes)]) }
            else { try db.run("UPDATE objects SET writer_epoch=? WHERE object_id=?", [.blob(Array(repeating: 97, count: 16)), .blob(e.object.segmentID.bytes)]) }
        }
    }
    await #expect(throws: StorageError.integrity) { try await receiver.receive(fixture.objects[fixture.root]!) }
    for _ in 0..<2 {
        await #expect(throws: StorageError.integrity) { try await receiver.snapshot() }
        await #expect(throws: StorageError.integrity) { try await put("Must not save", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 2, session: receiver) }
    }
    let inspection = try ReceivedStoreInspection(selection, protection)
    let rootID = fixture.root.segmentID.bytes.map { String(format: "%02x", $0) }.joined()
    #expect(try inspection.integer("SELECT count(*) FROM accepted_objects WHERE object_id=X'" + rootID + "'") == 0)
    #expect(try inspection.integer("SELECT count(*) FROM private_groups WHERE group_key=X'686973746F72792D64616D616765'") == 0)
    try await receiver.quiesce()
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    try await sender.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], ["page-before", "page-during", "page-after", "history-before", "history-during", "history-after"])
func receivedSnapshotParkingRechecksConcurrentArrivals(encrypted: Bool, schedule: String) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let e = try await put("E", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: sender)
    let fixture = try await ReceivedSnapshotFixture.build(sender.captureGeneralSnapshot(), protection: protection)
    let history = schedule.starts(with: "history"), target = history ? e.object : fixture.leaves[1]
    let targetBytes = try history ? await sender.retainedObject(at: target) : fixture.objects[target]!
    for page in fixture.indexes + fixture.leaves where page != target { _ = try await receiver.receive(fixture.objects[page]!) }
    if !history { _ = try await receiver.receive(sender.retainedObject(at: e.object)) }
    let lane = await receiver.lane, selection = await receiver.selection, gate = ReceiveSnapshotGate()
    if schedule.hasSuffix("before") { _ = try await receiver.receive(targetBytes) }
    if schedule.hasSuffix("during") {
        try await lane.perform { db in
            db.work = StorageWork(); db.work?.receiveDiscovered = { locator, requirements in
                if locator == fixture.root, requirements.contains(where: { $0.locator == target }) { await gate.hold() }
            }
        }
        let receiving = Task { try await receiver.receive(fixture.objects[fixture.root]!) }
        await gate.wait()
        // Exercise the shared real SQL consumer while the public receiver owns its reservation.
        // The same session rejects overlapping receive calls; local acceptance/emission can interleave.
        if history { _ = try await lane.acceptScheduled(targetBytes, locator: target, selection: selection, protection: protection) }
        else {
            let opened = try ObjectEnvelopeV1.open(targetBytes, collection: initial.descriptor.collection, protection: protection)
            try await lane.perform { db in try db.transaction { try db.retainCandidate(targetBytes, opened: opened, ready: false) } }
        }
        await gate.release()
        #expect(receivedAccepted(try await receiving.value), "Transaction recheck must avoid a stale wait")
    } else {
        _ = try await receiver.receive(fixture.objects[fixture.root]!)
        if schedule.hasSuffix("after") { _ = try await receiver.receive(targetBytes) }
    }
    #expect(receivedAccepted(try await receiver.receivedObjectStatus(at: fixture.root)), "No further arrival may be required")
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM object_waits UNION ALL SELECT count(*) FROM ready_objects") } == [[.integer(0)], [.integer(0)]])
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["E", "untouched"])
    try await receiver.quiesce(); try await sender.quiesce()
}

@Test(arguments: [false, true])
func receivedSnapshotRejectionPreservesSharedPagesAndHealthyHistory(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let fixture = try await ReceivedSnapshotFixture.build(sender.captureGeneralSnapshot(), protection: protection)
    for page in fixture.indexes + fixture.leaves { _ = try await receiver.receive(fixture.objects[page]!) }
    let collection = initial.descriptor.collection
    let good = try GeneralSnapshotRootV1.decodeV1(ObjectEnvelopeV1.open(fixture.objects[fixture.root]!, collection: collection, protection: protection).payload)
    let sink = ReceiveSnapshotSink(collection: collection, protection: protection)
    let bad = try GeneralSnapshotRootV1(bootstrapSnapshot: good.bootstrapSnapshot, tree: good.tree, counts: good.counts, digest: .init(bytes: Array(repeating: 0, count: 32)))
    let badRoot = try await sink.emit(.snapshotRoot, bad.encodedV1()), badBytes = try #require(await sink.objects[badRoot])
    await #expect(throws: OrdinaryHistoryError.invalidBeforeAfter) { try await receiver.receive(badBytes) }
    let lane = await receiver.lane
    #expect(try await receiver.snapshot().through == 1)
    #expect(try await lane.perform { try $0.rows("SELECT object_id FROM rejected_objects") } == [[.blob(badRoot.segmentID.bytes)]])
    _ = try await receiver.receive(fixture.objects[fixture.root]!)
    for page in fixture.indexes + fixture.leaves { #expect(try await receiver.retainedObject(at: page) == fixture.objects[page]) }
    // A wrong incoming locator cannot turn an intact accepted target into history damage.
    let wrong = SegmentLocator(writerEpoch: try WriterEpoch(bytes: Array(repeating: 99, count: 16)), sequence: good.bootstrapSnapshot.sequence, segmentID: good.bootstrapSnapshot.segmentID)
    let misaddressed = try GeneralSnapshotRootV1(bootstrapSnapshot: wrong, tree: good.tree, counts: good.counts, digest: good.digest)
    let wrongRoot = try await sink.emit(.snapshotRoot, misaddressed.encodedV1()), wrongBytes = try #require(await sink.objects[wrongRoot])
    await #expect(throws: CanonicalEncodingError.invalidReference) { try await receiver.receive(wrongBytes) }
    _ = try await put("Still healthy", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 2, session: receiver)
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM private_groups WHERE group_key=?", [.blob(Array("history-damage".utf8))]) } == [[.integer(0)]])
    let selection = await receiver.selection; try await receiver.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["Still healthy", "untouched"])
    try await reopened.quiesce(); try await sender.quiesce()
}

@Test(arguments: [false, true])
func receivedSnapshotUnsupportedChildBlocksOnlyItsDependents(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection)
    let fixture = try await ReceivedSnapshotFixture.build(sender.captureGeneralSnapshot(), protection: protection)
    let good = try GeneralSnapshotRootV1.decodeV1(ObjectEnvelopeV1.open(fixture.objects[fixture.root]!, collection: initial.descriptor.collection, protection: protection).payload)
    let sink = ReceiveSnapshotSink(collection: initial.descriptor.collection, protection: protection)
    let unsupported = try await sink.emit(.snapshotPage, Array("NVGPG1\r\n".utf8) + [0, 2])
    let futureBytes = try #require(await sink.objects[unsupported])
    let blockedRoot = try GeneralSnapshotRootV1(bootstrapSnapshot: good.bootstrapSnapshot,
        tree: .init(locator: unsupported, offset: 0, byteCount: good.tree.byteCount), counts: good.counts, digest: good.digest)
    let root = try await sink.emit(.snapshotRoot, blockedRoot.encodedV1()), rootBytes = try #require(await sink.objects[root])
    guard case .waiting = try await receiver.receive(rootBytes) else { Issue.record("Unknown page must be named as missing"); return }
    await #expect(throws: CanonicalEncodingError.unsupportedFormat) { try await receiver.receive(futureBytes) }
    let selection = await receiver.selection; try await receiver.quiesce()
    receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
    let blocked = try? await receiver.receivedObjectStatus(at: root)
    #expect(receivedBlocked(blocked), "Root must report its prerequisite's own result")
    guard case .blocked(let reasons, let missing)? = blocked else { return }
    #expect(reasons == [RejectedPrerequisite(object: unsupported.segmentID, reason: .unsupportedFormat)])
    #expect(missing == [.retainedBytes(unsupported)])
    let lane = await receiver.lane
    #expect(try await lane.perform { try $0.rows("SELECT object_id FROM rejected_objects") } == [[.blob(unsupported.segmentID.bytes)]])
    for page in fixture.indexes + fixture.leaves { _ = try await receiver.receive(fixture.objects[page]!) }
    _ = try await receiver.receive(fixture.objects[fixture.root]!)
    _ = try await put("Unrelated", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 2, session: receiver)
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["A", "Unrelated"])
    #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(root.segmentID.bytes)]) } == [[.blob(rootBytes)]])
    try await receiver.quiesce(); try await sender.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], receivedOrders)
func receivedSnapshotPermutationsRetainCompleteEvidence(encrypted: Bool, order: [Int]) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("Received E", birth: birth, generation: 1, session: sender)
    let fixture = try await ReceivedSnapshotFixture.build(sender.captureGeneralSnapshot(), protection: protection)
    try #require(fixture.leaves.count == 2 && fixture.indexes.count == 1 && receivedOrders.count == 24)
    let selection = await receiver.selection, lane = await receiver.lane
    let privateState = try await lane.perform { try $0.rows("SELECT group_key,codec,payload FROM private_groups ORDER BY group_key") }
    if case .retainedForAssembly = try await receiver.receive(fixture.objects[fixture.indexes[0]]!) {} else { Issue.record("Index page must remain a standalone assembly input") }
    let wire = try [fixture.objects[fixture.root]!] + fixture.leaves.map { fixture.objects[$0]! } + [await sender.retainedObject(at: edit.object)]
    var delivered: Set<Int> = []
    for index in order {
        _ = try await receiver.receive(wire[index]); delivered.insert(index)
        if delivered.contains(0) {
            let outcome = try await receiver.receivedObjectStatus(at: fixture.root)
            if delivered.count == 4 {
                guard case .accepted = outcome else { Issue.record("Final exact prerequisite must complete the root"); return }
            } else {
                guard case .waiting(let requirements) = outcome else { Issue.record("Incomplete root must wait"); return }
                try #require(!requirements.isEmpty)
                if delivered.isSuperset(of: [0, 1, 2]) { #expect(requirements == [.acceptedHistory(edit.object)]) }
                else { #expect(requirements.allSatisfy { if case .retainedBytes = $0 { true } else { false } }) }
            }
        }
        try await receiver.quiesce()
        receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
    }
    let reopenedLane = await receiver.lane
    let expectedNotes = try await receiver.snapshot().notes.map(\.value.body.string).sorted()
    #expect(expectedNotes == ["Received E", "untouched"])
    #expect(try await receiver.snapshot().through == 3)
    #expect(try await reopenedLane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") } == [[.integer(5)], [.integer(3)]])
    #expect(try await reopenedLane.perform { try $0.rows("SELECT group_key,codec,payload FROM private_groups ORDER BY group_key") } == privateState)
    let rootSequence = try await reopenedLane.perform { try $0.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(fixture.root.segmentID.bytes)])[0][0].number }
    for (locator, bytes) in fixture.objects {
        #expect(try await receiver.retainedObject(at: locator) == bytes)
        #expect(try await reopenedLane.perform { try $0.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]) } == [[.integer(rootSequence)]])
        _ = try await receiver.receive(bytes)
    }
    _ = try await receiver.receive(wire[3])
    #expect(try await receiver.snapshot().through == 3)
    #expect(try await reopenedLane.perform { try $0.rows("SELECT count(*) FROM ready_objects UNION ALL SELECT count(*) FROM object_waits UNION ALL SELECT count(*) FROM rejected_objects") } == [[.integer(0)], [.integer(0)], [.integer(0)]])
    try await receiver.quiesce(); try await sender.quiesce()
}

@Test(arguments: [false, true])
func receivedSnapshotDiscoversDeeperPagesAndUnacceptedHistory(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), sender = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let e = try await put("E", birth: a, generation: 1, session: sender), f = try await put("F", birth: b, generation: 1, session: sender)
    let fixture = try await ReceivedSnapshotFixture.build(sender.captureGeneralSnapshot(), protection: protection, chunkBytes: 256, fanout: 2)
    let root = try GeneralSnapshotRootV1.decodeV1(ObjectEnvelopeV1.open(fixture.objects[fixture.root]!, collection: initial.descriptor.collection, protection: protection).payload)
    guard case .waiting(let first) = try await receiver.receive(fixture.objects[fixture.root]!) else { Issue.record("Root must initially name its missing tree"); return }
    #expect(first == [.retainedBytes(root.tree.locator)])
    for page in fixture.indexes.reversed() { _ = try await receiver.receive(fixture.objects[page]!) }
    guard case .waiting(let deeper) = try await receiver.receivedObjectStatus(at: fixture.root) else { Issue.record("New index bytes must reveal a missing leaf"); return }
    #expect(deeper.count == 1 && fixture.leaves.contains(deeper[0].locator))
    _ = try await receiver.receive(sender.retainedObject(at: f.object))
    for page in fixture.leaves { _ = try await receiver.receive(fixture.objects[page]!) }
    guard case .waiting(let history) = try await receiver.receivedObjectStatus(at: fixture.root) else { Issue.record("Retained F must still wait for accepted E"); return }
    #expect(Set(history) == [.acceptedHistory(e.object), .acceptedHistory(f.object)])
    let selection = await receiver.selection; try await receiver.quiesce()
    receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
    guard case .waiting(let recovered) = try await receiver.receivedObjectStatus(at: fixture.root) else { Issue.record("Wait roles must be reconstructed after restart"); return }
    #expect(Set(recovered) == Set(history))
    _ = try await receiver.receive(sender.retainedObject(at: e.object))
    guard case .accepted = try await receiver.receivedObjectStatus(at: fixture.root) else { Issue.record("Accepted-parent wakeup must complete every prerequisite"); return }
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["E", "F"])
    try await receiver.quiesce(); try await sender.quiesce()
}
