import Crypto
import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

private actor RuntimeSnapshotObjects {
    let collection: CollectionID
    let protection: ObjectProtectionV1
    let writer: WriterEpoch
    var sequence: UInt64 = 0
    var objects: [SegmentLocator: [UInt8]] = [:]
    init(collection: CollectionID, protection: ObjectProtectionV1) throws {
        self.collection = collection; self.protection = protection
        writer = try .init(bytes: Array(repeating: 71, count: 16))
    }
    func emit(_ kind: ProviderObjectKind, _ payload: [UInt8]) throws -> SegmentLocator {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection,
            writer: writer, sequence: sequence, protection: protection)
        sequence += 1
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        objects[locator] = bytes; return locator
    }
}

private func generalPreview(_ capture: GeneralSnapshotCapture, _ protection: ObjectProtectionV1,
                            records: [GeneralSnapshotRecordV1]? = nil, bootstrap: SegmentLocator? = nil) async throws -> GeneralSnapshotPreviewV1 {
    let sink = try RuntimeSnapshotObjects(collection: capture.collection, protection: protection)
    let snapshot = try await GeneralSnapshotV1.write(records: GeneralSnapshotV1.canonicalOrder(records ?? capture.records),
        bootstrapSnapshot: bootstrap ?? capture.bootstrapSnapshot, chunkBytes: 128, fanout: 3,
        emit: { try await sink.emit($0, $1) })
    let bytes = await sink.objects
    return try await GeneralSnapshotPreviewV1.read(snapshot: snapshot, collection: capture.collection,
        protection: protection, read: { bytes[$0] })
}

private func snapshotDelete(_ birth: NoteBirth, in session: LocalStoreSession) async throws -> AcceptedHistoryReceipt {
    let capture = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: birth, generation: 40))])
    return try requireReceipt(await session.persist(capture: capture))
}

private func snapshotRestore(_ source: NoteBirth, in session: LocalStoreSession) async throws -> NoteBirth {
    _ = try await snapshotDelete(source, in: session)
    let entry = try #require(try await session.history(for: .recentlyDeleted).entries.first { $0.birth == source })
    let fresh = try NoteBirth(bytes: Array(repeating: 51, count: 16))
    let restoration = try await session.restoration(from: entry, as: .init(birth: fresh, generation: 41))
    let capture = try await CapturedActionGroup(snapshot: session.snapshot(), restoring: [restoration])
    _ = try requireReceipt(await session.persist(capture: capture))
    return fresh
}

@Test(arguments: [false, true], ["empty", "initial", "edited", "deleted", "restored", "undo"])
func generalSnapshotClaimsMatchRealHistory(encrypted: Bool, stage: String) async throws {
    let (twoNotes, protection) = try testInitial(encrypted)
    let initial = try stage == "empty" ? InitialCollectionV1.build(collection: twoNotes.descriptor.collection, notes: [], protection: protection, passphrase: encrypted ? "synthetic" : nil) : twoNotes
    let store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    if stage != "initial" && stage != "empty" { _ = try await put("Saved E", birth: birth, generation: 1, session: store) }
    if stage == "deleted" { _ = try await snapshotDelete(birth, in: store) }
    if stage == "restored" { _ = try await snapshotRestore(birth, in: store) }
    if stage == "undo" {
        guard case .automatic(let command) = try await store.prepareCompensation(scope: .note(birth), direction: .undo) else {
            Issue.record("Expected the saved edit's inverse"); return
        }
        _ = try requireReceipt(await store.applyCompensation(command))
    }
    let current = try await store.snapshot(), capture = try await store.captureGeneralSnapshot()
    let preview = try await generalPreview(capture, protection), proof = try await store.verifyGeneralSnapshot(preview)
    let cells = preview.records.compactMap { if case .current(let cell) = $0 { cell } else { nil } }
    let expected = stage == "empty" ? [] : stage == "deleted" ? ["untouched"] : stage == "initial" || stage == "undo" ? ["A", "untouched"] : ["Saved E", "untouched"]
    #expect(cells.map(\.value.body.string).sorted() == expected)
    #expect(cells == current.notes && capture.through == current.through)
    #expect(proof.checkedThrough == current.through && proof.store == current.store)
    #expect(proof.operationIDs.count == (stage == "empty" ? 2 : Int(current.through) + 3))
    if stage == "deleted" || stage == "restored" {
        #expect(preview.records.contains { if case .deleted(let b, _) = $0 { b == birth } else { false } })
        #expect(cells.allSatisfy { $0.birth != birth })
    }
    if stage == "restored" {
        #expect(preview.records.filter { if case .restored = $0 { true } else { false } }.count == 1)
        #expect(try await store.history(for: .recentlyDeleted).entries.isEmpty)
    }
    let accepted = try snapshotReceipt(await store.persistGeneralSnapshot(capture: capture))
    #expect(accepted.sequence == current.through + 1)
    let retained = try await GeneralSnapshotPreviewV1.read(snapshot: accepted.snapshot, collection: initial.descriptor.collection,
        protection: protection) { try await store.retainedObject(at: $0) }
    #expect(retained.records == capture.records)
    let exactRoot = try await store.retainedObject(at: accepted.snapshot)
    let selection = await store.selection; try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let again = try await reopened.verifyGeneralSnapshot(preview)
    #expect(again.operationIDs == proof.operationIDs && again.checkedThrough == accepted.sequence)
    #expect(try await reopened.retainedObject(at: accepted.snapshot) == exactRoot)
    #expect(try await reopened.snapshot().notes == current.notes)
    try await reopened.quiesce()
}

@Test(arguments: [false, true], ["body", "heads", "scope", "deletion", "retirement", "disposition", "restoration", "operationOccurrence", "actionOccurrence", "bootstrap"])
func generalSnapshotRejectsAuthenticWrongClaims(encrypted: Bool, fault: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    if fault == "scope" { _ = try await put("E with a note-scoped action", birth: birth, generation: 1, session: store) }
    if fault == "deletion" { _ = try await snapshotDelete(birth, in: store) }
    if fault == "restoration" { _ = try await snapshotRestore(birth, in: store) }
    let capture = try await store.captureGeneralSnapshot(), good = try await generalPreview(capture, protection)
    _ = try await store.verifyGeneralSnapshot(good)
    let before = try await store.snapshot()
    var records = capture.records, bootstrap: SegmentLocator?
    if ["body", "heads", "scope"].contains(fault) {
        let i = try #require(records.firstIndex { if case .current(let c) = $0 { c.birth == birth } else { false } })
        guard case .current(let c) = records[i] else { return }
        if fault == "scope" { try #require(!c.scopeFrontier.isEmpty) }
        let frontier = try #require(records.compactMap { if case .frontier(let ref) = $0 { ref } else { nil } }.first)
        records[i] = try .current(.init(birth: c.birth, value: fault == "body" ? testValue("false body") : c.value,
            represented: c.represented, heads: fault == "heads" ? c.heads + [frontier] : c.heads, provenance: c.provenance,
            scopeFrontier: fault == "scope" ? [] : c.scopeFrontier, identity: c.identity))
    } else if fault == "deletion" {
        records.removeAll { if case .deleted = $0 { true } else { false } }
    } else if fault == "retirement" {
        records.append(try .retired(.automatic(.init(bytes: Array(repeating: 61, count: 32)))))
    } else if fault == "disposition" {
        records.append(try .disposition(.init(bytes: Array(repeating: 62, count: 32))))
    } else if fault == "restoration" {
        let i = try #require(records.firstIndex { if case .restored = $0 { true } else { false } })
        guard case .restored(let source, let deletion, _, let fresh) = records[i] else { return }
        records[i] = try .restored(source: source, deletion: deletion, action: .init(bytes: Array(repeating: 63, count: 16)), birth: fresh)
    } else if fault == "operationOccurrence" {
        let i = try #require(records.firstIndex { if case .frontier = $0 { true } else { false } })
        guard case .frontier(let ref) = records[i] else { return }
        records[i] = .frontier(.init(locator: capture.bootstrapSnapshot, index: ref.index, id: ref.id))
    } else if fault == "actionOccurrence" {
        let i = try #require(records.firstIndex { if case .scope = $0 { true } else { false } })
        guard case .scope(let scope, let ref) = records[i] else { return }
        records[i] = .scope(scope, .init(locator: ref.locator, index: .init(UInt32.max), id: ref.id))
    } else if fault == "bootstrap" {
        bootstrap = initial.descriptor.genesis
    }
    let wrong = try await generalPreview(capture, protection, records: records, bootstrap: bootstrap)
    await #expect(throws: GeneralSnapshotError.invalidState) { try await store.verifyGeneralSnapshot(wrong) }
    let after = try await store.snapshot()
    #expect(after.notes == before.notes && after.through == before.through)
    _ = try await put("unrelated work progresses", birth: before.notes[0].birth, generation: 42, session: store)
    try await store.quiesce()
}

@Test(arguments: [false, true]) func generalSnapshotOldCutKeepsLaterBranchAndExactMissingHistory(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("Left E", birth: birth, generation: 1, session: left)
    let capture = try await left.captureGeneralSnapshot(), preview = try await generalPreview(capture, protection)
    await #expect(throws: GeneralSnapshotError.missingObject(edit.object)) { try await right.verifyGeneralSnapshot(preview) }
    let remote = try await put("Right R", birth: birth, generation: 1, session: right)
    _ = try await left.receive(right.retainedObject(at: remote.object))
    _ = try await left.pinCurrent(for: birth)
    let later = try await left.snapshot()
    _ = try await left.verifyGeneralSnapshot(preview)
    let after = try await left.snapshot()
    #expect(after.notes == later.notes && after.through == later.through)
    _ = try await right.receive(left.retainedObject(at: edit.object))
    _ = try await right.verifyGeneralSnapshot(preview)
    let neutral = try await left.captureGeneralSnapshot(), complete = try await generalPreview(neutral, protection)
    _ = try await right.verifyGeneralSnapshot(complete)
    #expect(complete.records.compactMap { if case .current(let c) = $0 { c } else { nil } }.first { $0.birth == birth }?.heads.count == 2)
    let accepted = try snapshotReceipt(await left.persistGeneralSnapshot(capture: capture))
    #expect(try await left.snapshot().notes == later.notes)
    let retained = try await GeneralSnapshotPreviewV1.read(snapshot: accepted.snapshot, collection: capture.collection,
        protection: protection) { try await left.retainedObject(at: $0) }
    #expect(retained.records == capture.records)
    let selection = await left.selection
    try await left.quiesce(); try await right.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let cell = try #require(try await reopened.snapshot().notes.first { $0.birth == birth })
    #expect(cell.heads.count == 2)
    let alternatives = try await reopened.conflicts(for: birth)
    #expect(Set(alternatives.alternatives.compactMap { $0.effect.noteValue?.body.string }).union([cell.value.body.string]) == ["Left E", "Right R"])
    try await reopened.quiesce()
}

@Test(arguments: [false, true]) func generalSnapshotCopiesPreserveDispositionAndRetirement(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("Left", birth: birth, generation: 1, session: left)
    let remote = try await put("Right", birth: birth, generation: 1, session: right)
    let revision = try #require(try await right.snapshot().notes.first { $0.birth == birth }).revision.id
    _ = try await left.receive(right.retainedObject(at: remote.object))
    let copying = try await left.copyVersion(for: birth, revision: revision, generation: 2)
    _ = try requireReceipt(await left.persist(capture: copying))
    let output = copying.covered[0].birth
    _ = try await snapshotDelete(output, in: left)
    let capture = try await left.captureGeneralSnapshot(), preview = try await generalPreview(capture, protection)
    _ = try await left.verifyGeneralSnapshot(preview)
    #expect(preview.records.contains(.disposition(revision)))
    #expect(preview.records.filter { if case .retired = $0 { true } else { false } }.count == 1)
    #expect(preview.records.compactMap { if case .current(let c) = $0 { c.birth } else { nil } }.contains(birth))
    #expect(try await left.snapshot().notes.allSatisfy { $0.birth != output })
    var missing = capture.records; missing.removeAll { if case .retired = $0 { true } else { false } }
    let wrong = try await generalPreview(capture, protection, records: missing)
    await #expect(throws: GeneralSnapshotError.invalidState) { try await left.verifyGeneralSnapshot(wrong) }
    let accepted = try snapshotReceipt(await left.persistGeneralSnapshot(capture: capture))
    let retained = try await GeneralSnapshotPreviewV1.read(snapshot: accepted.snapshot, collection: initial.descriptor.collection,
        protection: protection) { try await left.retainedObject(at: $0) }
    #expect(retained.records == capture.records)
    try await left.quiesce(); try await right.quiesce()
}

@Test func generalSnapshotActualConsumerChecksProfileAndLifecycle() async throws {
    let (initial, protection) = try testInitial(true), store = try await newSession(initial, protection)
    let capture = try await store.captureGeneralSnapshot()
    let wrongKey = try ObjectProtectionV1.encrypted(keyID: .init(bytes: Array(repeating: 3, count: 16)), key: SymmetricKey(data: [UInt8](repeating: 90, count: 32)))
    let wrong = try await generalPreview(capture, wrongKey)
    await #expect(throws: CanonicalEncodingError.authenticationFailure) { try await store.verifyGeneralSnapshot(wrong) }
    let preview = try await generalPreview(capture, protection)
    _ = try await store.verifyGeneralSnapshot(preview)
    try await store.quiesce()
    await #expect(throws: StorageError.closed) { try await store.verifyGeneralSnapshot(preview) }
    await #expect(throws: StorageError.closed) { try await store.captureGeneralSnapshot() }
}

@Test(arguments: [false, true]) func generalSnapshotRejectsPartialActionCut(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 81, count: 16)), b = try NoteBirth(bytes: Array(repeating: 82, count: 16))
    let creating = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .createImportBatch,
        changes: [.create(.init(birth: a, generation: 1), testValue("new A")), .create(.init(birth: b, generation: 1), testValue("new B"))])
    _ = try requireReceipt(await store.persist(capture: creating))
    let capture = try await store.captureGeneralSnapshot(), good = try await generalPreview(capture, protection)
    _ = try await store.verifyGeneralSnapshot(good)
    let currentA = try #require(capture.records.compactMap { if case .current(let c) = $0 { c } else { nil } }.first { $0.birth == a })
    var partial = capture.records.filter { if case .current(let c) = $0 { c.birth != b } else { true } }
    partial = partial.map { if case .frontier = $0 { .frontier(currentA.revision) } else { $0 } }
    let wrong = try await generalPreview(capture, protection, records: partial)
    await #expect(throws: GeneralSnapshotError.invalidState) { try await store.verifyGeneralSnapshot(wrong) }
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["A", "new A", "new B", "untouched"])
    try await store.quiesce()
}

@Test(arguments: [false, true], [false, true]) func generalSnapshotTransportMembershipKeepsUnrepresentedGroup(encrypted: Bool, branchFirst: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection), peer = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let e = try await put("E", birth: a, generation: 1, session: source), early = try await source.captureGeneralSnapshot()
    let f = try await put("F", birth: b, generation: 2, session: source)
    let ep = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(source.retainedObject(at: e.object), collection: early.collection, protection: protection).payload)
    let fp = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(source.retainedObject(at: f.object), collection: early.collection, protection: protection).payload)
    let eop = ep.operations[0], fop = fp.operations[0], ea = ep.actions[0], fa = fp.actions[0]
    let operations = [eop.operation, fop.operation]
    let repackedF = try OperationRecordV1(operation: fop.operation,
        causalReferences: fop.causalReferences.map { if case .external(_, _, let id) = $0, id == eop.operation.id { .earlierLocal(index: .init(0)) } else { $0 } },
        noteReferences: fop.noteReferences, earlierOperations: [eop.operation])
    let repackedAction = try ActionRecordV1(id: fa.action.id, origin: fa.action.origin,
        previousOrigin: .earlierLocal(index: .init(0)), scope: fa.action.scope,
        scopeParents: fa.scopeReferences, kind: fa.action.kind, members: [.init(1)],
        affected: fa.affectedReferences.map { .init(birth: $0.birth, before: $0.before, after: .value(.earlierLocal(index: .init(1)))) },
        operations: operations, earlierActions: [ea.action])
    let payload = try ChangesPayloadV1(dependencies: .init(Array(Set(ep.dependencies.entries + fp.dependencies.entries).subtracting([e.object]))),
        operations: [eop, repackedF], actions: [ea, repackedAction])
    let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: early.collection,
        writer: .init(bytes: Array(repeating: 91, count: 16)), sequence: 0, protection: protection)
    let locator = try ObjectEnvelopeV1.open(bytes, collection: early.collection, protection: protection).locator
    _ = try await receiver.receive(bytes)
    let er = StoredOperationReferenceV1(locator: locator, index: .init(0), id: eop.operation.id)
    let ar = StoredActionReferenceV1(locator: locator, index: .init(0), id: ea.action.id)
    let records = try early.records.map { record -> GeneralSnapshotRecordV1 in
        switch record {
        case .frontier(let ref): return .frontier(ref.id == er.id ? er : ref)
        case .scope(let scope, let ref): return .scope(scope, ref.id == ar.id ? ar : ref)
        case .current(let cell):
            return try .current(.init(birth: cell.birth, value: cell.value, revision: cell.revision.id == er.id ? er : cell.revision,
                scopeFrontier: cell.scopeFrontier.map { $0.id == ar.id ? ar : $0 }))
        default: return record
        }
    }
    let preview = try await generalPreview(early, protection, records: records)
    let proof = try await receiver.verifyGeneralSnapshot(preview)
    #expect(proof.operationIDs.contains(eop.operation.id) && !proof.operationIDs.contains(fop.operation.id))
    #expect(preview.records.compactMap { if case .current(let c) = $0 { c.value.body.string } else { nil } }.sorted() == ["E", "untouched"])
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["E", "F"])
    let r = try await put("Concurrent R", birth: b, generation: 1, session: peer)
    if branchFirst { _ = try await receiver.receive(peer.retainedObject(at: r.object)) }
    let beforeRoot = try await receiver.snapshot()
    let sink = try RuntimeSnapshotObjects(collection: early.collection, protection: protection)
    let root = try await GeneralSnapshotV1.write(records: records, bootstrapSnapshot: early.bootstrapSnapshot) { try await sink.emit($0, $1) }
    let lane = await receiver.lane, selection = await receiver.selection
    let objects = await sink.objects
    for (candidate, bytes) in objects where candidate != root {
        guard case .retainedForAssembly = try await receiver.receive(bytes) else { Issue.record("A page must remain an assembly input"); return }
    }
    guard case .accepted(let sequence) = try await receiver.receive(objects[root]!) else { Issue.record("The old cut must accept through public intake"); return }
    #expect(sequence == (branchFirst ? 4 : 3))
    #expect(try await receiver.snapshot().notes == beforeRoot.notes)
    if !branchFirst {
        let isolated = try await receiver.rebuildCurrentRows()
        #expect(isolated.notes.map(\.value.body.string).sorted() == ["E", "F"])
        _ = try await receiver.receive(peer.retainedObject(at: r.object))
    }
    let complete = try await receiver.snapshot()
    let untouchedA = try #require(complete.notes.first { $0.birth == a })
    let concurrentB = try #require(complete.notes.first { $0.birth == b })
    let rPayload = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(peer.retainedObject(at: r.object), collection: early.collection, protection: protection).payload)
    #expect(untouchedA.value.body.string == "E")
    #expect(Set(concurrentB.heads.map(\.id)) == Set([fop.operation.id, rPayload.operations[0].operation.id]))
    #expect(try await receiver.retainedObject(at: locator) == bytes)
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") } == [[.integer(7)], [.integer(5)]])
    let rebuilt = try await receiver.rebuildCurrentRows()
    #expect(rebuilt.notes == complete.notes && rebuilt.context == complete.context)
    #expect(Set(rebuilt.notes.first { $0.birth == b }!.heads.map(\.id)) == Set([fop.operation.id, rPayload.operations[0].operation.id]))
    // A third writer continues its own branch after reconstruction retained both competing heads.
    let descendant = try await put("Third-writer descendant", birth: b, generation: 2, session: peer)
    _ = try await receiver.receive(peer.retainedObject(at: descendant.object))
    let followed = try await receiver.rebuildCurrentRows()
    let dPayload = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(peer.retainedObject(at: descendant.object), collection: early.collection, protection: protection).payload)
    #expect(Set(followed.notes.first { $0.birth == b }!.heads.map(\.id)) == Set([fop.operation.id, dPayload.operations[0].operation.id]))
    #expect(followed.notes.first { $0.birth == a } == untouchedA)
    try await source.quiesce(); try await receiver.quiesce(); try await peer.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes == followed.notes)
    #expect(try await reopened.retainedObject(at: locator) == bytes)
    try await reopened.quiesce()
}

@Test(arguments: [false, true]) func generalSnapshotDetectsUnindexedAcceptedLeaf(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("uniquely retained E", birth: birth, generation: 1, session: store)
    let capture = try await store.captureGeneralSnapshot(), preview = try await generalPreview(capture, protection)
    _ = try await store.verifyGeneralSnapshot(preview)
    let bytes = try await store.retainedObject(at: edit.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes, collection: capture.collection, protection: protection).payload)
    let op = payload.operations[0].operation.id, action = payload.actions[0].action.id
    // Simulate later index damage while retaining the complete accepted envelope.
    try await store.lane.perform { db in
        try db.exec("PRAGMA foreign_keys=OFF")
        defer { try? db.exec("PRAGMA foreign_keys=ON") }
        try db.run("DELETE FROM operations WHERE operation_id=?", [.blob(op.bytes)])
        try db.run("DELETE FROM actions WHERE action_id=?", [.blob(action.bytes)])
    }
    await #expect(throws: StorageError.integrity) { try await store.captureGeneralSnapshot() }
    await #expect(throws: StorageError.integrity) { try await store.snapshot() }
    let selection = await store.selection; try await store.quiesce()
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}
