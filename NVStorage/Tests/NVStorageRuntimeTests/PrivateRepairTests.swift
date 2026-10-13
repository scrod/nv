import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true])
func complementaryRepairPreservesUnpublishedHistoryAndPrivateInputs(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let peer = try await newSession(initial, protection)
    let aBirth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), bBirth = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let e = try await put("shared E", birth: aBirth, generation: 1, session: source)
    _ = try await peer.receive(source.retainedObject(at: e.object))
    let l = try await put("unpublished L", birth: bBirth, generation: 2, session: source)
    let r = try await put("peer R", birth: aBirth, generation: 1, session: peer)
    let settings = try CollectionSettingsV1([.secureTextEntry(true), .confirmFileDeletion(false)])
    try await source.saveCollectionSettings(settings, basedOn: source.collectionSettings())
    let item = try PendingItemID(bytes: uuidBytes()), frozen = try await pendingInput(source, body: "frozen A")
    try await source.retainPendingSnapshot(frozen, basedOn: source.pendingItem(item))
    let prepared = try await source.preparePendingImport(basedOn: source.pendingItem(item), automatic: false)
    let latest = try await pendingInput(source, body: "latest B")
    try await source.retainPendingSnapshot(latest, basedOn: source.pendingItem(item))
    let eBytes = try await source.retainedObject(at: e.object)
    try await source.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(e.object.segmentID.bytes)])
    }
    let old = await source.selection
    let original = try Data(contentsOf: URL(fileURLWithPath: old.directory).appendingPathComponent("Collection.sqlite"))
    let left = try await source.preserveForRepair(to: privateTempPath())
    #expect(left.unavailableCommittedObjects.contains(e.object.segmentID.bytes))
    let right = try await peer.preserveForRepair(to: privateTempPath())
    await #expect(throws: StorageError.incomplete) {
        try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: left, protection: protection)
    }
    let repaired = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: left, complementary: [right], protection: protection)
    #expect(repaired.selection.store != old.store)
    try await repaired.close()
    let opened = try await LocalStoreSession.open(selection: repaired.selection, protection: protection)
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["peer R", "unpublished L"])
    #expect(try await opened.retainedObject(at: e.object) == eBytes)
    #expect(try await !opened.retainedObject(at: l.object).isEmpty)
    #expect(try await !opened.retainedObject(at: r.object).isEmpty)
    #expect(try await opened.collectionSettings().value == settings)
    #expect(try await opened.pendingItem(item).latest == latest.id)
    #expect(try await opened.retainedPendingSnapshot(frozen.id) == frozen)
    #expect(try await opened.retainedPendingSnapshot(latest.id) == latest)
    let recoveredReservations = try await opened.pendingRecovery(item)
    #expect(recoveredReservations.count == 1)
    guard case .review(let reservation) = try #require(recoveredReservations.first) else { Issue.record("unused reservation gained consent"); return }
    #expect(reservation == prepared.reservation)
    let history = try await opened.history(for: .note(aBirth))
    #expect(history.entries.count == 3)
    try await opened.quiesce()
    #expect(try Data(contentsOf: URL(fileURLWithPath: old.directory).appendingPathComponent("Collection.sqlite")) == original)
}

@Test(arguments: [false, true])
func repairedVerificationUsesMembershipRatherThanCopiedSequence(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("E", birth: birth, generation: 1, session: source)
    _ = try await put("F", birth: birth, generation: 2, session: source)
    let selection = await source.selection
    let requestKey = VerificationRecord.prefix + uuidBytes()
    let request = Array("NVVRFY1\n".utf8) + selection.store.bytes + selection.descriptor.collection.bytes
        + selection.descriptor.descriptorID + VerificationRecipe.history(3).encoded()
    try await source.lane.perform { try $0.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(requestKey), .blob(request)]) }
    let evidence = try await source.preserveForRepair(to: privateTempPath())
    let repaired = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence, protection: protection)
    try await repaired.close()
    let opened = try await LocalStoreSession.open(selection: repaired.selection, protection: protection)
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["F", "untouched"])
    #expect(try await opened.lane.perform { try $0.rows("SELECT 1 FROM private_groups WHERE group_key=?", [.blob(requestKey)]) }.isEmpty)
    let membership = try await opened.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") }
    #expect(membership.count == initial.objects.count + 3)
    try await opened.quiesce()
}

@Test(arguments: [false, true])
func encryptedPageSalvageKeepsIndependentCommittedRows(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let layout: Int64, pageSize: Int64
    do {
        layout = try await source.lane.perform { db in
            let rows = try db.rows("PRAGMA page_count")
            guard case .integer(let n) = rows[0][0] else { Issue.record("page_count returned \(rows)"); throw StorageError.integrity }
            return n
        }
        pageSize = try await source.lane.perform { db in
            let rows = try db.rows("PRAGMA cipher_page_size")
            guard case .text(let text) = rows[0][0], let n = Int64(text) else { Issue.record("cipher_page_size returned \(rows)"); throw StorageError.integrity }
            return n
        }
    } catch { Issue.record("healthy cipher page layout: \(error)"); throw error }
    var entropy: UInt64 = 0x123456789abcdef, bytes: [UInt8] = []
    for _ in 0..<262144 {
        entropy ^= entropy << 13; entropy ^= entropy >> 7; entropy ^= entropy << 17
        bytes.append(33 + UInt8(entropy % 90))
    }
    let body = String(decoding: bytes, as: UTF8.self)
    let saved: AcceptedHistoryReceipt
    do { saved = try await put(body, birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: source) }
    catch { Issue.record("saving the healthy large note: \(error)"); throw error }
    let envelope: [UInt8]
    do { envelope = try await source.retainedObject(at: saved.object) }
    catch { Issue.record("reading the healthy large envelope: \(error)"); throw error }
    let selection = await source.selection
    try #require(envelope.count > Int(pageSize * 16))
    try await source.lane.perform { try $0.run("PRAGMA wal_checkpoint(TRUNCATE)") }
    do { try await source.quiesce() }
    catch { Issue.record("closing the healthy large store: \(error)"); throw error }
    let damaged = privateTempPath()
    try FileManager.default.copyItem(atPath: selection.directory, toPath: damaged)
    let databasePath = damaged + "/Collection.sqlite"
    let handle = try FileHandle(forUpdating: URL(fileURLWithPath: databasePath))
    let offset = UInt64((layout + 3) * pageSize + 200)
    try handle.seek(toOffset: offset)
    let original = try #require(handle.read(upToCount: 1)?.first)
    try handle.seek(toOffset: offset); try handle.write(contentsOf: Data([original ^ 0xff])); try handle.synchronize(); try handle.close()
    let preserved = try Data(contentsOf: URL(fileURLWithPath: databasePath))
    let claim = LocalStoreSelection(directory: damaged, store: selection.store, descriptor: selection.descriptor)
    let evidence: PrivateRepairEvidence
    do { evidence = try await LocalStoreSession.salvagePrivateStore(selection: claim, protection: protection, workingDirectory: privateTempPath()) }
    catch { Issue.record("encrypted-page working-copy salvage: \(error)"); throw error }
    try #require(evidence.unavailableCommittedObjects == [saved.object.segmentID.bytes])
    await #expect(throws: StorageError.incomplete) {
        try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence, protection: protection)
    }
    let peer = try await newSession(initial, protection)
    _ = try await peer.receive(envelope)
    let companion = try await peer.preserveForRepair(to: privateTempPath())
    let repaired: VerifiedReplacement
    do { repaired = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence,
        complementary: [companion], protection: protection) }
    catch { Issue.record("encrypted-page complementary reconstruction: \(error)"); throw error }
    try await repaired.close()
    let reopened = try await LocalStoreSession.open(selection: repaired.selection, protection: protection)
    #expect(try await reopened.snapshot().notes.contains { $0.value.body.string == body })
    #expect(try await reopened.retainedObject(at: saved.object) == envelope)
    try await reopened.quiesce()
    #expect(try Data(contentsOf: URL(fileURLWithPath: databasePath)) == preserved)
}

@Test(arguments: [false, true])
func partialPrivateSalvageContinuesIndependentReads(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    _ = try await put("retained history", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: source)
    let selection = await source.selection
    let count = try await source.lane.perform { try $0.rows("SELECT COUNT(*) FROM accepted_objects")[0][0].number }
    try await source.lane.perform { try $0.exec("DROP TABLE pending_reservations") }
    try await source.closeForPreservedRepair()
    let work = privateTempPath()
    guard case .partial(let result) = try await LocalStoreSession.salvagePrivateStoreDiagnosing(
        selection: selection, protection: protection, workingDirectory: work) else {
        Issue.record("missing required private table yielded complete repair evidence"); return
    }
    #expect(result.componentFailures["pending_reservations"] == .database(1))
    #expect(result.knownCommittedObjectCount == Int(count) && result.readableObjectCount == Int(count))
    #expect(result.workingDirectory == work)
    #expect(FileManager.default.fileExists(atPath: selection.directory + "/Collection.sqlite"))
}

@Test(arguments: [false, true])
func repairPreservesReceiveClassesAndWakesComplementedDependencies(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), writer = try await newSession(initial, protection)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let e = try await put("parent E", birth: birth, generation: 1, session: writer)
    let f = try await put("child F", birth: birth, generation: 2, session: writer)
    let eBytes = try await writer.retainedObject(at: e.object), fBytes = try await writer.retainedObject(at: f.object)
    guard case .waiting = try await left.receive(fBytes) else { Issue.record("child did not park"); return }
    _ = try await right.receive(eBytes)
    let rejected = try ObjectEnvelopeV1.seal(payload: Array("NVCHG1\r\n".utf8) + [0, 2], kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 77, count: 16)), sequence: 0, protection: protection)
    let rejectedID = try ObjectEnvelopeV1.open(rejected, collection: initial.descriptor.collection, protection: protection).locator
    await #expect(throws: CanonicalEncodingError.unsupportedFormat) { try await left.receive(rejected) }
    let orphanWriter = try await newSession(initial, protection)
    let o = try await put("uncommitted orphan O", birth: birth, generation: 1, session: orphanWriter)
    let orphan = try await orphanWriter.retainedObject(at: o.object)
    let orphanOpened = try ObjectEnvelopeV1.open(orphan, collection: initial.descriptor.collection, protection: protection)
    try await right.lane.perform { try $0.retainCandidate(orphan, opened: orphanOpened, ready: false) }
    let primary = try await left.preserveForRepair(to: privateTempPath())
    let complement = try await right.preserveForRepair(to: privateTempPath())
    let replacement = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: primary,
        complementary: [complement], protection: protection)
    try await replacement.close()
    let reopened = try await LocalStoreSession.open(selection: replacement.selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["child F", "untouched"])
    let states = try await reopened.lane.perform { db in
        (try db.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(o.object.segmentID.bytes)]),
         try db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(o.object.segmentID.bytes)]),
         try db.rows("SELECT reason FROM rejected_objects WHERE object_id=?", [.blob(rejectedID.segmentID.bytes)]),
         try db.rows("SELECT 1 FROM object_waits WHERE child=?", [.blob(f.object.segmentID.bytes)]))
    }
    #expect(states.0 == [[.blob(orphan)]] && states.1.isEmpty)
    #expect(states.2 == [[.integer(ReceiveRejection.unsupportedFormat.rawValue)]] && states.3.isEmpty)
    #expect(try await reopened.retainedObject(at: f.object) == fBytes)
    _ = try await put("after repair", birth: birth, generation: 3, session: reopened)
    try await reopened.quiesce(); try await writer.quiesce(); try await orphanWriter.quiesce()
}

@Test(arguments: [false, true])
func complementaryRepairKeepsConflictRestoreAndCausalRedo(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let restoredBirth = try NoteBirth(bytes: Array(repeating: 3, count: 16))
    let l = try await put("Left", birth: a, generation: 1, session: left)
    let r = try await put("Right", birth: a, generation: 1, session: right)
    let lID = try #require(try await left.snapshot().notes.first { $0.birth == a }).revision.id
    let rID = try #require(try await right.snapshot().notes.first { $0.birth == a }).revision.id
    _ = try await left.receive(right.retainedObject(at: r.object)); _ = try await right.receive(left.retainedObject(at: l.object))
    let lc = try await left.copyVersion(for: a, revision: rID, generation: 2)
    let rc = try await right.copyVersion(for: a, revision: lID, generation: 2)
    let lr = try requireReceipt(await left.persist(capture: lc)), rr = try requireReceipt(await right.persist(capture: rc))
    _ = try await left.receive(right.retainedObject(at: rr.object)); _ = try await right.receive(left.retainedObject(at: lr.object))
    let copiedBirth = lc.covered[0].birth
    for target in [copiedBirth, b] {
        let deletion = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .deleteBatch,
            changes: [.delete(CapturedNoteGeneration(birth: target, generation: 3))])
        _ = try requireReceipt(await left.persist(capture: deletion))
    }
    let entry = try #require(try await left.history(for: .recentlyDeleted).entries.first { $0.birth == b })
    let restoration = try await left.restoration(from: entry, as: CapturedNoteGeneration(birth: restoredBirth, generation: 4))
    let restoreCapture = try await CapturedActionGroup(snapshot: left.snapshot(), restoring: [restoration])
    _ = try requireReceipt(await left.persist(capture: restoreCapture))
    _ = try await put("post-Restore edit", birth: restoredBirth, generation: 5, session: left)
    guard case .automatic(let command) = try await left.prepareCompensation(scope: .note(restoredBirth), direction: .undo) else {
        Issue.record("ordinary restored-note edit was not undoable"); return
    }
    let undo = try requireReceipt(await left.applyCompensation(command))
    let undoPayload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(await left.retainedObject(at: undo.object),
        collection: initial.descriptor.collection, protection: protection).payload)
    let undoID = undoPayload.actions[0].action.id
    _ = try snapshotReceipt(await left.persistGeneralSnapshot(capture: left.captureGeneralSnapshot()))
    try await left.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(r.object.segmentID.bytes)])
    }
    let primary = try await left.preserveForRepair(to: privateTempPath()), complement = try await right.preserveForRepair(to: privateTempPath())
    let replacement = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: primary,
        complementary: [complement], protection: protection)
    try await replacement.close()
    let opened = try await LocalStoreSession.open(selection: replacement.selection, protection: protection)
    let current = try await opened.snapshot()
    let expectedOriginal = lID.bytes.lexicographicallyPrecedes(rID.bytes) ? "Left" : "Right"
    #expect(Set(current.notes.map(\.birth)) == [a, rc.covered[0].birth, restoredBirth])
    #expect(current.notes.first { $0.birth == a }?.value.body.string == expectedOriginal)
    #expect(current.notes.first { $0.birth == rc.covered[0].birth }?.value.body.string == "Left")
    #expect(current.notes.first { $0.birth == restoredBirth }?.value.body.string == "untouched")
    #expect(try await opened.conflicts(for: a).alternatives.isEmpty)
    #expect(try await opened.conflicts(for: a).representedSeparately.isSuperset(of: [lID, rID]))
    #expect(try await opened.history(for: .recentlyDeleted).entries.map(\.birth) == [copiedBirth])
    #expect(try await opened.history(for: .note(restoredBirth)).entries.count == 3)
    #expect(try await opened.undoCandidates(scope: .note(restoredBirth), direction: .redo).ids == [undoID])
    guard case .automatic(let redo) = try await opened.prepareCompensation(scope: .note(restoredBirth), direction: .redo) else {
        Issue.record("repair lost the portable causal Redo"); return
    }
    _ = try requireReceipt(await opened.applyCompensation(redo))
    #expect(try await opened.snapshot().notes.first { $0.birth == restoredBirth }?.value.body.string == "post-Restore edit")
    try await opened.quiesce()
}
