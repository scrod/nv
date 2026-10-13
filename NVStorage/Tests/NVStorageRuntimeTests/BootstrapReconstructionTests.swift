import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private func importValues(_ count: Int) throws -> [(NoteBirth, PlaintextNoteValue)] {
    try (0..<count).map { n in
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = 10
        bytes[14] = UInt8(n >> 8); bytes[15] = UInt8(n & 255)
        return try (NoteBirth(bytes: bytes), testValue("initial-\(n)-" + String(repeating: "x", count: 1024)))
    }
}

private func packedInitial(_ count: Int, encrypted: Bool, target: Int = 16_384) throws ->
    (BootstrapDescriptorV1, SegmentLocator, [SegmentLocator: [UInt8]], ObjectProtectionV1, [(NoteBirth, PlaintextNoteValue)]) {
    let (reference, protection) = try testInitial(encrypted), values = try importValues(count)
    var writer = try InitialCollectionWriterV1(collection: reference.descriptor.collection, notes: values,
        protection: protection, passphrase: encrypted ? "test" : nil, targetBytes: target, notesPerAction: 3)
    var objects: [SegmentLocator: [UInt8]] = [:]
    while let next = try writer.next() { objects[next.locator] = next.bytes }
    return (writer.descriptor, try #require(writer.snapshot), objects, protection, values)
}

@Test(arguments: [false, true], [0, 2, 64, 256])
func packedBootstrapReadersAgreeOnCompleteGroups(encrypted: Bool, count: Int) async throws {
    let (descriptor, root, objects, protection, expected) = try packedInitial(count, encrypted: encrypted)
    let memory = try InitialBootstrapValidationV1.validate(descriptor: descriptor, expectedCollection: descriptor.collection,
        protection: protection, snapshot: root) { objects[$0] }
    let stored = try await InitialBootstrapValidationV1.validateStored(descriptor: descriptor,
        expectedCollection: descriptor.collection, protection: protection, snapshot: root) { objects[$0] }
    #expect(memory.rows == stored.rows && memory.operationIDs == stored.operationIDs)
    #expect(stored.rows.map(\.birth) == expected.map(\.0))
    #expect(stored.rows.map(\.value) == expected.map(\.1))
    #expect(memory.requiredObjects == Set(objects.keys))
    #expect(memory.actions == stored.actions && memory.completion == stored.completion)
    if count >= 64 {
        let payloads = try objects.values.compactMap { bytes -> ChangesPayloadV1? in
            let opened = try ObjectEnvelopeV1.open(bytes, collection: descriptor.collection, protection: protection)
            return opened.kind == .changes ? try ChangesPayloadV1.decodeV1(opened.payload) : nil
        }
        #expect(payloads.contains { $0.actions.count > 1 })
        #expect(payloads.contains { $0.actions.contains { $0.action.members.count > 1 } })
        #expect(payloads.filter { !$0.actions.isEmpty }.count > 1)
        #expect(try InitialSnapshotRootV1.decodeV1(ObjectEnvelopeV1.open(objects[root]!, collection: descriptor.collection, protection: protection).payload).pages.count > 1)
    }
}

@Test(arguments: [false, true])
func bootstrapCandidateResumesExactIncompleteCommitment(encrypted: Bool) async throws {
    let (descriptor, root, objects, protection, expected) = try packedInitial(64, encrypted: encrypted)
    let selection = try LocalStoreSelection(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        store: LocalStoreID(bytes: uuidBytes()), descriptor: descriptor)
    var candidate = try await BootstrapCandidate.create(selection: selection, snapshot: root, protection: protection)
    _ = try await candidate.retain(objects[root]!)
    await #expect(throws: InitialBootstrapValidationError.self) { try await candidate.complete(snapshot: root) }
    do { _ = try await LocalStoreSession.open(selection: selection, protection: protection); Issue.record("Candidate ownership must remain exclusive") }
    catch StorageError.ownership { }
    let lane = await candidate.lane
    #expect(try await lane.perform { try $0.acceptedThrough() } == 0)
    try await candidate.close()
    await #expect(throws: StorageError.incomplete) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    candidate = try await BootstrapCandidate.resume(selection: selection, protection: protection)
    for bytes in objects.values.reversed() { _ = try await candidate.retain(bytes); _ = try await candidate.retain(bytes) }
    let store = try await candidate.complete(snapshot: root), reopenedLane = await store.lane
    #expect(try await store.snapshot().notes.map(\.value) == expected.map(\.1))
    #expect(try await reopenedLane.perform { try $0.rows("SELECT count(*) FROM acceptance_batches") } == [[.integer(1)]])
    #expect(try await reopenedLane.perform { try $0.rows("SELECT count(*) FROM operations") } == [[.integer(66)]])
    #expect(try await reopenedLane.perform { try $0.rows("SELECT count(*) FROM ready_objects") } == [[.integer(0)]])
    for (locator, bytes) in objects { #expect(try await store.retainedObject(at: locator) == bytes) }
    _ = try await put("after-bootstrap", birth: expected[0].0, generation: 1, session: store)
    try await store.quiesce()
    let returning = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await returning.snapshot().notes.first { $0.birth == expected[0].0 }?.value.body.string == "after-bootstrap")
    try await returning.quiesce()
}

@Test(arguments: [false, true], [64, 256, 1024])
func productionIncrementalBootstrapReopensEditable(encrypted: Bool, count: Int) async throws {
    let (reference, protection) = try testInitial(encrypted), expected = try importValues(count)
    let store = try await LocalStoreSession.create(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        collection: reference.descriptor.collection, notes: expected, protection: protection, passphrase: encrypted ? "test" : nil)
    let selection = await store.selection
    #expect(try await store.snapshot().notes.map(\.value) == expected.map(\.1))
    let lane = await store.lane
    let counts = try await lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") }
    #expect(counts[0] == [.integer(Int64(count + 2))])
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection), newLane = await reopened.lane
    try await newLane.perform { $0.work = StorageWork() }
    _ = try await put("first returning edit", birth: expected[0].0, generation: 1, session: reopened)
    let work = try await newLane.perform { try #require($0.work) }
    #expect(work.stages.values.allSatisfy { $0.ancestors == 0 })
    #expect(work[.validation].fastChecks == 1)
    print("S3 bootstrap \(count) encrypted=\(encrypted): operations/actions \(counts), returning save SQL=\(work[.validation].statements)")
    try await reopened.quiesce()
}

private func sendSnapshots(from source: LocalStoreSession, into receiver: LocalStoreSession) async throws {
    let bytes = try await source.lane.perform { try $0.rows("SELECT encoded FROM objects JOIN accepted_objects USING(object_id) WHERE kind IN (2,3) ORDER BY seq DESC,object_id") }
    for row in bytes { _ = try await receiver.receive(row[0].bytes) }
}

private actor ReconstructionGate {
    var arrived = false
    var continuation: CheckedContinuation<Void, Never>?
    var observers: [CheckedContinuation<Void, Never>] = []
    func hold() async {
        if arrived { return }; arrived = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            for observer in observers { observer.resume() }; observers.removeAll()
        }
    }
    func wait() async { if !arrived { await withCheckedContinuation { observers.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
}

@Test(arguments: [false, true], [false, true])
func reconstructionIncludesBranchesOnBothSidesOfSnapshotAcceptance(encrypted: Bool, branchFirst: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), branch = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let e = try await put("snapshot E", birth: a, generation: 1, session: source)
    let f = try await put("off-cut F", birth: b, generation: 1, session: branch)
    _ = try snapshotReceipt(await source.persistGeneralSnapshot(capture: source.captureGeneralSnapshot()))
    if branchFirst { _ = try await receiver.receive(branch.retainedObject(at: f.object)) }
    _ = try await receiver.receive(source.retainedObject(at: e.object))
    try await sendSnapshots(from: source, into: receiver)
    if !branchFirst { _ = try await receiver.receive(branch.retainedObject(at: f.object)) }
    let before = try await receiver.snapshot(), lane = await receiver.lane
    let retained = try await lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") }
    try await lane.perform { $0.work = StorageWork() }
    let rebuilt = try await receiver.rebuildCurrentRows()
    #expect(rebuilt.notes == before.notes && rebuilt.context == before.context && rebuilt.viewEpoch != before.viewEpoch)
    #expect(rebuilt.notes.map(\.value.body.string).sorted() == ["off-cut F", "snapshot E"])
    let work = try await lane.perform { try #require($0.work) }
    #expect(work.stages.values.reduce(0) { $0 + $1.reconstructionOutsideOperations } == 1)
    #expect(work.stages.values.reduce(0) { $0 + $1.reconstructionReusedCells } == 1)
    #expect(try await lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") } == retained)
    _ = try await put("after reconstruction", birth: a, generation: 2, session: receiver)
    let capture = try await CapturedActionGroup(snapshot: receiver.snapshot(), kind: .deleteBatch,
        changes: [.delete(CapturedNoteGeneration(birth: b, generation: 3))])
    _ = try requireReceipt(await receiver.persist(capture: capture))
    #expect(try await receiver.snapshot().notes.map(\.value.body.string) == ["after reconstruction"])
    let selection = await receiver.selection; try await receiver.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string) == ["after reconstruction"])
    try await reopened.quiesce(); try await source.quiesce(); try await branch.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func reconstructionRepreparesAfterSaveAndPreservesLivePendingWork(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), lane = await store.lane
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))
    let oldPublication = try await store.prepareReduction(liveGeneration: 1), gate = ReconstructionGate()
    try await lane.perform { db in db.work = StorageWork(); db.work?.reconstructionPrepared = { await gate.hold() } }
    let task = Task { try await store.rebuildCurrentRows() }
    await gate.wait()
    _ = try await put("interfering saved E", birth: a, generation: 1, session: store)
    var host = try await HeadlessModel(snapshot: store.snapshot())
    _ = try host.put(testValue("unsaved F"), birth: a)
    await gate.release()
    let rebuilt = try #require(try? await task.value)
    #expect(rebuilt.notes.first { $0.birth == a }?.value.body.string == "interfering saved E")
    #expect(host.values[a]?.body.string == "unsaved F" && !host.pending.isEmpty)
    await #expect(throws: StorageError.staleCapture) { try await store.publish(oldPublication, liveGeneration: 1) { $0 } }
    #expect(try await lane.perform { $0.work?.stages.values.reduce(0) { $0 + $1.reconstructionInstallations } } == 1)
    #expect(try await lane.perform { $0.work?.stages.values.reduce(0) { $0 + $1.reconstructionSeeds } } == 2)
    try await store.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func reconstructionRechecksSameHistoryEpochAndKeepsPrivateGenerations(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), lane = await store.lane
    _ = try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))
    let before = try await store.snapshot(), publication = try await store.prepareReduction(liveGeneration: 1)
    let gate = ReconstructionGate()
    try await lane.perform { db in
        try db.run("INSERT INTO private_groups VALUES(?,17,1,?)", [.blob(Array("review-sentinel".utf8)), .blob([1, 2, 3, 4])])
        db.work = StorageWork(); db.work?.reconstructionPrepared = { await gate.hold() }
    }
    let first = Task { try await store.rebuildCurrentRows() }
    await gate.wait()
    try await store.saveEmptySettings(basedOn: store.settings())
    let privateState = try await lane.perform { try $0.rows("SELECT group_key,generation,codec,payload FROM private_groups WHERE group_key<? OR group_key>=? ORDER BY group_key", [.blob(VerificationRecord.prefix), .blob(VerificationRecord.end)]) }
    #expect(try await lane.perform { try $0.rows("SELECT 1 FROM private_groups WHERE group_key>=? AND group_key<?", [.blob(VerificationRecord.prefix), .blob(VerificationRecord.end)]) }.count == 1)
    let second = try await store.rebuildCurrentRows()
    #expect(second.through == before.through && second.viewEpoch != before.viewEpoch)
    await gate.release()
    let final = try await first.value
    #expect(final.through == before.through && final.viewEpoch != second.viewEpoch)
    #expect(final.notes == before.notes && final.context == before.context)
    #expect(try await lane.perform { try $0.rows("SELECT group_key,generation,codec,payload FROM private_groups WHERE group_key<? OR group_key>=? ORDER BY group_key", [.blob(VerificationRecord.prefix), .blob(VerificationRecord.end)]) } == privateState)
    #expect(try await lane.perform { try $0.rows("SELECT 1 FROM private_groups WHERE group_key>=? AND group_key<?", [.blob(VerificationRecord.prefix), .blob(VerificationRecord.end)]) }.isEmpty)
    #expect(try await lane.perform { $0.work?.stages.values.reduce(0) { $0 + $1.reconstructionInstallations } } == 2)
    #expect(try await lane.perform { $0.work?.stages.values.reduce(0) { $0 + $1.reconstructionSeeds } } == 3)
    await #expect(throws: StorageError.staleCapture) { try await store.publish(publication, liveGeneration: 1) { $0 } }
    _ = try await put("after both rebuilds", birth: before.notes[0].birth, generation: 1, session: store)
    try await store.quiesce()
}

private actor BootstrapMeasurements {
    var work: StorageWork?
    func record(_ work: StorageWork) { self.work = work }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_STORAGE_RESOURCE_CAMPAIGN"] == "1"),
      arguments: [false, true], [64, 256, 1024, 2048])
func measuredBootstrapResourceCampaign(encrypted: Bool, count: Int) async throws {
    let (reference, protection) = try testInitial(encrypted), expected = try importValues(count)
    var writer = try InitialCollectionWriterV1(collection: reference.descriptor.collection, notes: expected,
        protection: protection, passphrase: encrypted ? "test" : nil)
    let selection = try LocalStoreSelection(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        store: LocalStoreID(bytes: uuidBytes()), descriptor: writer.descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: nil, protection: protection)
    let lane = await candidate.lane, measurements = BootstrapMeasurements()
    try await lane.perform { db in
        db.work = StorageWork()
        db.work?.acceptanceCompletion = { _ in
            await measurements.record(try await lane.perform { try #require($0.work) })
        }
    }
    let began = ContinuousClock.now
    var highWater = 0, objects = 0
    while let next = try writer.next() {
        highWater = max(highWater, next.bytes.count); objects += 1
        _ = try await candidate.retain(next.bytes)
    }
    let store = try await candidate.complete(snapshot: #require(writer.snapshot))
    let work = try #require(await measurements.work), snapshot = try await store.snapshot()
    #expect(snapshot.notes.map(\.value) == expected.map(\.1))
    #expect(highWater < 1_048_576 && work.stages.values.map(\.largestCandidateBytes).max() == highWater)
    #expect(work.stages.values.reduce(0) { $0 + $1.candidateReads } >= objects)
    #expect(work[.acceptance].nanoseconds > 0 && work[.acceptance].statements > 0)
    print("S3 measured count=\(count) encrypted=\(encrypted) objects=\(objects) encodedHighWater=\(highWater) candidateReads=\(work.stages.values.reduce(0) { $0 + $1.candidateReads }) acceptanceNs=\(work[.acceptance].nanoseconds) maxWriterNs=\(work.stages.values.map(\.maxWriterNanoseconds).max() ?? 0) complete=\(began.duration(to: .now))")
    try await store.quiesce()
}

@Test(arguments: [false, true])
func reconstructionKeepsBodyEqualContinuationAndUndoTargets(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let first = try await put("same visible body", birth: a, generation: 1, session: store)
    _ = try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))
    let current = try #require(try await store.snapshot().notes.first { $0.birth == a }).value
    let renamed = try PlaintextNoteValue(title: ExactUTF8(bytes: Array("Renamed F".utf8)), body: current.body,
        labels: current.labels, created: current.created, modified: current.modified)
    let capture = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .rename,
        changes: [.put(.init(birth: a, generation: 2), renamed)])
    let second = try requireReceipt(await store.persist(capture: capture))
    let before = try await store.snapshot(), candidates = try await store.undoCandidates(scope: .note(a), direction: .undo)
    let oldRevision = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(store.retainedObject(at: first.object), collection: initial.descriptor.collection, protection: protection).payload).operations[0].operation.id
    let newRevision = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(store.retainedObject(at: second.object), collection: initial.descriptor.collection, protection: protection).payload).operations[0].operation.id
    let rebuilt = try await store.rebuildCurrentRows()
    #expect(rebuilt.notes.first { $0.birth == a }?.represented.map(\.id) == [newRevision])
    #expect(newRevision != oldRevision && rebuilt.notes == before.notes && rebuilt.context == before.context)
    let recoveredCandidates = try await store.undoCandidates(scope: .note(a), direction: .undo)
    #expect(recoveredCandidates.ids == candidates.ids && recoveredCandidates.mode == candidates.mode)
    guard case .automatic(let undo) = try await store.prepareCompensation(scope: .note(a), direction: .undo) else {
        Issue.record("The body-equal saved edit must retain its real Undo target"); return
    }
    _ = try requireReceipt(await store.applyCompensation(undo))
    #expect(try await store.snapshot().notes.first { $0.birth == a }?.value.body.string == "same visible body")
    #expect(try await store.snapshot().notes.first { $0.birth == a }?.value.title == current.title)
    guard case .automatic(let redo) = try await store.prepareCompensation(scope: .note(a), direction: .redo) else {
        Issue.record("The compensating action must provide a real Redo target"); return
    }
    _ = try requireReceipt(await store.applyCompensation(redo))
    #expect(try await store.snapshot().notes.first { $0.birth == a }?.value.title == renamed.title)
    try await store.quiesce()
}

@Test(arguments: [false, true], ["derived", "history", "settings"])
func reconstructionDistinguishesDisposableRowsFromRequiredLoss(encrypted: Bool, fault: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection), lane = await store.lane
    _ = try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))
    let publication = try await store.prepareReduction(liveGeneration: 1), selection = await store.selection
    let before = try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    try await lane.perform { db in
        if fault == "settings" { try db.run("DELETE FROM private_groups WHERE group_key=?", [.blob(Array("settings".utf8))]) }
        else if fault == "history" {
            try db.exec("DROP TRIGGER objects_no_update")
            try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(initial.descriptor.genesis.segmentID.bytes)])
        } else { try db.exec("UPDATE current_notes SET cell=X'00'") }
    }
    if fault == "derived" {
        let repaired = try await store.rebuildCurrentRows()
        #expect(repaired.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
        #expect(try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") } == before)
        _ = try await put("after row repair", birth: repaired.notes[0].birth, generation: 1, session: store)
        try await store.quiesce()
    } else {
        if fault == "settings" {
            await #expect(throws: StorageError.incomplete) { try await store.rebuildCurrentRows() }
        } else {
            await #expect(throws: CanonicalEncodingError.lengthLimit) { try await store.rebuildCurrentRows() }
            await #expect(throws: StorageError.integrity) { try await store.publish(publication, liveGeneration: 1) { $0 } }
        }
        await lane.close()
        await #expect(throws: fault == "settings" ? StorageError.incomplete : StorageError.integrity) {
            try await LocalStoreSession.open(selection: selection, protection: protection)
        }
    }
}
