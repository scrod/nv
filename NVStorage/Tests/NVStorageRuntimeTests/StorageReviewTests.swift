import NVStorageTestSupport
import Foundation
import Testing
@testable import NVStorageCore
@testable import NVStorageRuntime

/// Aggregates actual connection work across the existing qualification stages.
private struct ReviewWork: Sendable {
    var reads = 0, decodes = 0, encodedBytes = 0, decodedBytes = 0
    var currentCells = 0, leaves = 0, graphs = 0, statements = 0
    init(_ work: StorageWork) {
        for counts in work.stages.values {
            reads += counts.historyReads; decodes += counts.envelopeDecodes
            encodedBytes += counts.historyEncodedBytes; decodedBytes += counts.historyDecodedBytes
            currentCells += counts.currentCellDecodes; leaves += counts.retainedLeafChecks
            graphs += counts.graphLoads; statements += counts.statements
        }
    }
    func report(_ name: String, encrypted: Bool, size: Int) {
        print("STORAGE_REVIEW \(name) encrypted=\(encrypted) size=\(size) reads=\(reads) decodes=\(decodes) encodedBytes=\(encodedBytes) decodedBytes=\(decodedBytes) currentCells=\(currentCells) leaves=\(leaves) graphs=\(graphs) statements=\(statements)")
    }
}
private func reviewWork(_ lane: DatabaseLane) async throws -> ReviewWork {
    try await lane.perform { ReviewWork($0.work!) }
}
private func measuredOpen(_ selection: LocalStoreSelection, _ protection: ObjectProtectionV1) async throws -> LocalStoreSession {
    try await LocalStoreSession.open(selection: selection, protection: protection, measuring: StorageWork())
}
private func reviewNote(_ byte: UInt8 = 1) throws -> NoteBirth {
    try .init(bytes: Array(repeating: byte, count: 16))
}

@Test func materializationRoutingCoversEverySupportedVariant() throws {
    for kind in [ActionKindV1.savedEdit, .rename, .labels, .createImportBatch, .deleteBatch, .restoreBatch] {
        #expect(MaterializationRoute.forAction(kind) == .currentRows)
    }
    for kind in [ActionKindV1.historicalRecovery, .conflictChoice, .conflictCopy, .undo, .redo, .nativeUndo] {
        #expect(MaterializationRoute.forAction(kind) == .noteGraph)
    }
    let value = try testValue("routing"), birth = try reviewNote(), action = try ActionID(bytes: Array(repeating: 3, count: 16))
    let id = try OperationID(bytes: Array(repeating: 4, count: 32)), importID = try ImportID(bytes: Array(repeating: 5, count: 16))
    let digest = try InitialValuesDigest(bytes: Array(repeating: 6, count: 32))
    let ordinary: [OperationEffectV1] = [
        .genesis(importID: importID, profile: .plaintextFiles, initialCount: 1, initialValuesDigest: digest),
        .importComplete(importID: importID, initialCount: 1, initialValuesDigest: digest),
        .create(action: action, birth: birth, value: value), .importNote(action: action, birth: birth, value: value),
        .put(action: action, birth: birth, value: value), .delete(action: action, birth: birth)]
    for effect in ordinary { #expect(MaterializationRoute.forEffect(effect) == .currentRows) }
    let key = try ConflictRecoveryKeyV1.compute(source: birth, body: value.body)
    let later: [OperationEffectV1] = try [
        .recoverCopy(action: action, birth: key.birth(slot: 0), source: .init(birth: birth, revision: id, key: key, slot: 0, reused: nil), value: value),
        .retireConflict(action: action, birth: key.birth(slot: 0), identity: .recovery(key, slot: 0))]
    for effect in later { #expect(MaterializationRoute.forEffect(effect) == .noteGraph) }
    let automatic = try AutomaticConflictKeyV1.compute(source: birth, value: value)
    let adoption = try OperationEffectV1.adoptAutomatic(action: action, birth: automatic.birth(),
        source: .init(birth: birth, revision: id, key: automatic), value: value)
    #expect(MaterializationRoute.forEffect(adoption) == .noteGraph)
}

@Test(arguments: [false, true])
func returningOpenDecodesCurrentCellsOnce(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    _ = try await put("latest", birth: reviewNote(), generation: 1, session: store)
    let selection = await store.selection; try await store.quiesce()
    let reopened = try await measuredOpen(selection, protection), lane = await reopened.lane
    let snapshot = try await reopened.snapshot(), counts = try await reviewWork(lane)
    #expect(snapshot.notes.map(\.value.body.string).sorted() == ["latest", "untouched"])
    #expect(counts.reads == 0 && counts.graphs == 0)
    counts.report("returning-current-rows", encrypted: encrypted, size: 2)
    #expect(counts.currentCells == 2)
    try await reopened.quiesce()
}

@Test(arguments: [false, true], [16, 64])
func optionalReadySnapshotKeepsReturningOpenHistoryBounded(encrypted: Bool, size: Int) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    for index in 1...size { _ = try await put("edit-\(index)", birth: reviewNote(), generation: UInt64(index), session: store) }
    let lane = await store.lane
    try await lane.perform { db in
        db.work = StorageWork()
        db.work?.snapshotCandidateCompletion = { locator in
            let kind = try await lane.perform { try $0.rows("SELECT kind FROM objects WHERE object_id=?", [.blob(locator.segmentID.bytes)])[0][0].number }
            if kind == 2 { throw StorageError.database(10) }
        }
    }
    guard case .pending = try await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()) else {
        Issue.record("The companion must stop after durably retaining the optional root"); return
    }
    let candidates = try await lane.perform { try $0.rows("SELECT o.encoded FROM ready_objects r JOIN objects o USING(object_id)") }
    let bytes = try #require(candidates.first)[0].bytes
    #expect(candidates.count == 1)
    let selection = await store.selection; await lane.close()
    let openingStart = DispatchTime.now().uptimeNanoseconds
    let reopened = try await measuredOpen(selection, protection), recoveredLane = await reopened.lane
    let counts = try await reviewWork(recoveredLane)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["edit-\(size)", "untouched"])
    counts.report("optional-ready-open", encrypted: encrypted, size: size)
    #expect(counts.graphs == 0 && counts.reads == 0)
    let pause = ImprovementGate()
    try await recoveredLane.perform { $0.work?.publishedReceiveStart = { await pause.hold() } }
    let change = try await reopened.prepareReduction(liveGeneration: 0)
    let published = try await reopened.publish(change, liveGeneration: 0) { $0 }
    let publicationNanoseconds = DispatchTime.now().uptimeNanoseconds - openingStart
    #expect(published.notes.map(\.value.body.string).sorted() == ["edit-\(size)", "untouched"])
    try #require(await reopened.receiving)
    await pause.wait()
    #expect(try await recoveredLane.perform { try $0.rows("SELECT count(*) FROM ready_objects") } == [[.integer(1)]])
    let backgroundStart = DispatchTime.now().uptimeNanoseconds
    await pause.release()
    await reopened.waitForReceiveForTesting()
    print("OPTIONAL_STARTUP encrypted=\(encrypted) actions=\(size) publicationNS=\(publicationNanoseconds) backgroundNS=\(DispatchTime.now().uptimeNanoseconds - backgroundStart)")
    let root = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection).locator
    #expect(try await reopened.retainedObject(at: root) == bytes)
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func repeatedSnapshotsKeepReturningOpenLeafWorkBounded(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    var roots: [(SegmentLocator, [UInt8])] = []
    for _ in 0..<8 {
        let receipt = try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))
        roots.append((receipt.snapshot, try await store.retainedObject(at: receipt.snapshot)))
    }
    #expect(Set(roots.map(\.0)).count == 8)
    let selection = await store.selection; try await store.quiesce()
    let reopened = try await measuredOpen(selection, protection), lane = await reopened.lane
    let counts = try await reviewWork(lane)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    #expect(counts.graphs == 0 && counts.reads == 0)
    counts.report("repeated-snapshot-open", encrypted: encrypted, size: roots.count)
    #expect(counts.leaves == 1)
    for (root, bytes) in roots { #expect(try await reopened.retainedObject(at: root) == bytes) }
    try await reopened.quiesce()
}

@Test(arguments: [false, true], [16, 64])
func scopedCommandsAvoidUnrelatedHistoryBodies(encrypted: Bool, size: Int) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    for index in 1...size { _ = try await put("other-\(index)", birth: reviewNote(), generation: UInt64(index), session: store) }
    let lane = await store.lane
    try await lane.perform { $0.work = StorageWork() }
    let untouched = try reviewNote(2)
    let undo = try await store.undoCandidates(scope: .note(untouched), direction: .undo)
    #expect(undo.ids.isEmpty)
    let conflicts = try await store.conflicts(for: untouched)
    #expect(conflicts.alternatives.isEmpty && conflicts.representedSeparately.isEmpty)
    let counts = try await reviewWork(lane)
    #expect(try await store.snapshot().notes.first { $0.birth == untouched }?.value.body.string == "untouched")
    counts.report("scoped-commands", encrypted: encrypted, size: size)
    #expect(counts.reads == 0 && counts.decodedBytes == 0)
    try await store.quiesce()
}

@Test(arguments: [false, true], [16, 64])
func packedBootstrapGraphDecodesEachEnvelopeOnce(encrypted: Bool, size: Int) async throws {
    let (reference, protection) = try testInitial(encrypted)
    let expected = try (1...size).map { index in
        try (reviewNote(UInt8(index)), testValue("packed-\(index)-" + String(repeating: "x", count: 1024)))
    }
    var writer = try InitialCollectionWriterV1(collection: reference.descriptor.collection, notes: expected,
        protection: protection, passphrase: encrypted ? "test" : nil, targetBytes: 32_768, notesPerAction: 3)
    var objects: [SegmentLocator: [UInt8]] = [:]
    while let next = try writer.next() { objects[next.locator] = next.bytes }
    let root = try #require(writer.snapshot)
    let selection = try LocalStoreSelection(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        store: LocalStoreID(bytes: uuidBytes()), descriptor: writer.descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: root, protection: protection)
    for bytes in objects.values { _ = try await candidate.retain(bytes) }
    let store = try await candidate.complete(snapshot: root), lane = await store.lane
    let changes = try objects.values.map { try ObjectEnvelopeV1.open($0, collection: selection.descriptor.collection, protection: protection) }.filter { $0.kind == .changes }
    #expect(changes.contains { (try? ChangesPayloadV1.decodeV1($0.payload).operations.count) ?? 0 > 3 })
    let uniqueDecodedBytes = changes.reduce(0) { $0 + $1.payload.count }
    try await lane.perform { $0.work = StorageWork() }
    let graph = try await lane.retainedGraph(through: 1, selection: selection, protection: protection)
    #expect(graph.operations.count == size + 2)
    let values = try graph.currentCells(collection: selection.descriptor.collection)
    #expect(Dictionary(uniqueKeysWithValues: values.map { ($0.birth, $0.value) }) == Dictionary(uniqueKeysWithValues: expected))
    let counts = try await reviewWork(lane)
    counts.report("packed-graph", encrypted: encrypted, size: size)
    #expect(counts.decodes == changes.count && counts.decodedBytes == uniqueDecodedBytes)
    let work = try await lane.perform { $0.work! }
    let visits = work.stages.values.flatMap { $0.traversalDecodes.values }
    #expect(visits.count == 1)
    try #require(visits.count == 1)
    #expect(Set(visits[0].keys) == Set(changes.map(\.locator.segmentID)))
    #expect(visits.allSatisfy { $0.values.allSatisfy { $0 == 1 } })
    try await lane.perform { $0.work = StorageWork() }
    let reconstructed = try await store.rebuildCurrentRows()
    #expect(Dictionary(uniqueKeysWithValues: reconstructed.notes.map { ($0.birth, $0.value) }) == Dictionary(uniqueKeysWithValues: expected))
    try await reviewWork(lane).report("packed-reconstruction", encrypted: encrypted, size: size)
    for (locator, bytes) in objects { #expect(try await store.retainedObject(at: locator) == bytes) }
    try await store.quiesce()
}

@Test(arguments: [false, true])
func unappliedCompensationBatchesRecoverEveryAction(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let writer = try await newSession(initial, protection), reader = try await newSession(initial, protection)
    let birth = try reviewNote(), lane = await reader.lane, selection = await reader.selection
    var saved: [(SegmentLocator, [UInt8])] = []
    let edit = try await put("E", birth: birth, generation: 1, session: writer)
    saved.append((edit.object, try await writer.retainedObject(at: edit.object)))
    for direction in [UndoDirectionV1.undo, .redo, .undo, .redo] {
        guard case .automatic(let command) = try await writer.prepareCompensation(scope: .note(birth), direction: direction) else {
            Issue.record("The companion must exercise supported compensation, rather than an unsupported outcome"); return
        }
        let receipt = try requireReceipt(await writer.applyCompensation(command))
        saved.append((receipt.object, try await writer.retainedObject(at: receipt.object)))
    }
    for (locator, bytes) in saved {
        _ = try await lane.acceptScheduled(bytes, locator: locator, selection: selection, protection: protection)
    }
    #expect(try await lane.perform { try $0.rows("SELECT through_seq FROM view_meta") } == [[.integer(1)]])
    #expect(try await lane.perform { try $0.acceptedThrough() } == 6)
    await lane.close()
    let recovered = try await measuredOpen(selection, protection), recoveredLane = await recovered.lane
    let snapshot = try await recovered.snapshot(), counts = try await reviewWork(recoveredLane)
    #expect(snapshot.notes.map(\.value.body.string).sorted() == ["E", "untouched"])
    #expect(snapshot.through == 6)
    #expect(try await recoveredLane.perform { try $0.rows("SELECT count(*) FROM actions") } == [[.integer(7)]])
    counts.report("compensation-catch-up", encrypted: encrypted, size: 5)
    #expect(counts.graphs == 1)
    let undo = try await recovered.undoCandidates(scope: .note(birth), direction: .undo)
    #expect(undo.ids.count == 1)
    for (locator, bytes) in saved { #expect(try await recovered.retainedObject(at: locator) == bytes) }
    try await recovered.quiesce(); try await writer.quiesce()
}

@Test(arguments: [false, true], [false, true])
func nonfrontierHistoryDamageSurvivesMarkerFailureAndRestart(encrypted: Bool, markerFails: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let old = try await put("old E", birth: reviewNote(), generation: 1, session: store)
    _ = try await put("current F", birth: reviewNote(), generation: 2, session: store)
    let lane = await store.lane, selection = await store.selection
    #expect(try await lane.perform { try $0.rows("SELECT 1 FROM retained_frontier WHERE object_id=?", [.blob(old.object.segmentID.bytes)]) }.isEmpty)
    try await lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=X'00' WHERE object_id=?", [.blob(old.object.segmentID.bytes)])
        if markerFails {
            try db.exec("CREATE TEMP TRIGGER fail_history_marker BEFORE INSERT ON private_groups WHEN NEW.group_key=X'686973746F72792D64616D616765' BEGIN SELECT RAISE(ABORT,'marker write failed'); END")
        }
    }
    await #expect(throws: CanonicalEncodingError.lengthLimit) { try await store.retainedObject(at: old.object) }
    await #expect(throws: StorageError.integrity) { try await store.snapshot() }
    await lane.close()
    if markerFails {
        var reopened: LocalStoreSession?
        do { reopened = try await LocalStoreSession.open(selection: selection, protection: protection) }
        catch StorageError.integrity { }
        let blocked = reopened == nil
        #expect(blocked)
        if let reopened {
            #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["current F", "untouched"])
            await #expect(throws: CanonicalEncodingError.lengthLimit) { try await reopened.retainedObject(at: old.object) }
            await #expect(throws: StorageError.integrity) { try await reopened.snapshot() }
            try await reopened.quiesce()
        }
    } else {
        await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    }
}
