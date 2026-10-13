import NVStorageTestSupport
import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

private func birth(_ n: UInt8) throws -> NoteBirth { try NoteBirth(bytes: Array(repeating: n, count: 16)) }

private func deleted(_ births: [NoteBirth], in session: LocalStoreSession) async throws -> AcceptedHistoryReceipt {
    let capture = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .deleteBatch,
        changes: births.map { try .delete(CapturedNoteGeneration(birth: $0, generation: 1)) })
    return try requireReceipt(await session.persist(capture: capture))
}

private func visible(in session: LocalStoreSession) async throws -> Set<NoteBirth> {
    var cursor: HistoryCursor?, result: Set<NoteBirth> = []
    repeat {
        let page = try await session.history(for: .recentlyDeleted, after: cursor, limit: 1)
        result.formUnion(page.entries.map(\.birth)); cursor = page.continuation
    } while cursor != nil
    return result
}

private func restore(_ entry: HistoryEntry, as fresh: NoteBirth, in session: LocalStoreSession) async throws -> CapturedActionGroup {
    let source = try await session.restoration(from: entry, as: CapturedNoteGeneration(birth: fresh, generation: 1))
    return try await CapturedActionGroup(snapshot: session.snapshot(), restoring: [source])
}

@Test(arguments: [false, true]) func restorationPersistsExactEntryAcrossDeliveryAndReopen(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let old = try birth(1), fresh = try birth(3)
    let prior = try #require(try await source.snapshot().notes.first { $0.birth == old })
    let deletion = try await deleted([old], in: source)
    let entry = try #require(try await source.history(for: .recentlyDeleted).entries.first)
    _ = try snapshotReceipt(await source.persistGeneralSnapshot(capture: source.captureGeneralSnapshot()))
    let captured = try await restore(entry, as: fresh, in: source)
    #expect(try await visible(in: source) == [old])
    let receipt = try requireReceipt(await source.persist(capture: captured))
    let again = try requireReceipt(await source.persist(capture: captured))
    #expect(receipt.object == again.object && receipt.sequence == again.sequence)
    #expect(try await visible(in: source).isEmpty)
    let restored = try #require(try await source.snapshot().notes.first { $0.birth == fresh })
    _ = try await source.rebuildCurrentRows()
    #expect(restored.value == prior.value)
    let newEntry = try #require(try await source.history(for: .note(fresh)).entries.first)
    let provenance = try await source.preview(newEntry).action.restorations
    #expect(provenance.count == 1)
    #expect(provenance[0].birth == fresh && provenance[0].sourceBirth == old)
    #expect(provenance[0].deletionAction == entry.action && provenance[0].revision == prior.revision.id)
    let bytes = try await source.retainedObject(at: receipt.object)
    guard case .waiting = try await receiver.receive(bytes) else { Issue.record("Restore must wait for its exact Delete"); return }
    #expect(try await receiver.snapshot().notes.count == 2)
    let receivingSelection = await receiver.selection
    try await receiver.quiesce()
    receiver = try await .open(selection: receivingSelection, protection: protection)
    _ = try await receiver.receive(source.retainedObject(at: deletion.object))
    #expect(try await visible(in: receiver).isEmpty)
    #expect(try await receiver.snapshot().notes.first { $0.birth == fresh }?.value == prior.value)
    _ = try await receiver.receive(bytes)
    let repacked = try ObjectEnvelopeV1.seal(payload: ObjectEnvelopeV1.open(bytes,
        collection: initial.descriptor.collection, protection: protection).payload, kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 90, count: 16)),
        sequence: 0, protection: protection)
    _ = try await receiver.receive(repacked)
    #expect(try await receiver.history(for: .note(fresh)).entries.count == 1)
    _ = try await put("changed after Restore", birth: fresh, generation: 2, session: source)
    _ = try await deleted([fresh], in: source)
    #expect(try await visible(in: source) == [fresh], "deleting the restored birth keeps the original handled")
    #expect(try await source.history(for: .deletions).entries.count == 2)
    let selection = await source.selection, lane = await source.lane
    try await lane.perform { db in try db.run("DELETE FROM view_meta") }
    try await source.quiesce()
    source = try await .open(selection: selection, protection: protection)
    #expect(try await visible(in: source) == [fresh])
    #expect(try await source.snapshot().notes.map(\.value.body.string) == ["untouched"])
    try await source.quiesce(); try await receiver.quiesce()
}

@Test(arguments: [false, true]) func concurrentRestoresKeepBothFreshBirths(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let old = try birth(1), a = try birth(3), b = try birth(4)
    let deletion = try await deleted([old], in: left)
    _ = try await right.receive(left.retainedObject(at: deletion.object))
    let l = try #require(try await left.history(for: .recentlyDeleted).entries.first)
    let r = try #require(try await right.history(for: .recentlyDeleted).entries.first)
    let lc = try await restore(l, as: a, in: left), rc = try await restore(r, as: b, in: right)
    let lr = try requireReceipt(await left.persist(capture: lc)), rr = try requireReceipt(await right.persist(capture: rc))
    _ = try await left.receive(right.retainedObject(at: rr.object))
    _ = try await right.receive(left.retainedObject(at: lr.object))
    for session in [left, right] {
        #expect(try await visible(in: session).isEmpty)
        #expect(Set(try await session.snapshot().notes.map(\.birth)) == [try birth(2), a, b])
        #expect(try await session.history(for: .deletions).entries.map(\.operation) == [l.operation])
        let lane = await session.lane
        #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM restorations") } == [[.integer(1)]])
        try await session.quiesce()
    }
}

@Test func restorationBatchScopeContextAndOrdinaryCopies() async throws {
    let (initial, protection) = try testInitial(false)
    var session = try await newSession(initial, protection)
    let other = try await newSession(initial, protection)
    _ = try await deleted([birth(1), birth(2)], in: session)
    let entries = try await session.history(for: .recentlyDeleted).entries
    #expect(entries.count == 2)
    let initialPage = try await session.history(for: .recentlyDeleted, limit: 1)
    let first = try #require(entries.first), generation = try CapturedNoteGeneration(birth: birth(3), generation: 1)
    await #expect(throws: StorageError.wrongContext) { try await other.restoration(from: first, as: generation) }
    let source = try await session.restoration(from: first, as: generation)
    let otherSnapshot = try await other.snapshot()
    #expect(throws: StorageError.wrongContext) { try CapturedActionGroup(snapshot: otherSnapshot, restoring: [source]) }
    let copy = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .createImportBatch,
        changes: [.create(generation, source.value)])
    _ = try requireReceipt(await session.persist(capture: copy))
    #expect(try await visible(in: session) == [try birth(1), try birth(2)])
    let one = try await restore(first, as: birth(6), in: session)
    _ = try requireReceipt(await session.persist(capture: one))
    #expect(try await visible(in: session) == Set(entries.dropFirst().map(\.birth)))
    var sources: [CapturedRestoration] = []
    for (index, entry) in entries.enumerated() {
        sources.append(try await session.restoration(from: entry,
            as: CapturedNoteGeneration(birth: birth(UInt8(index + 4)), generation: 1)))
    }
    let captured = try await CapturedActionGroup(snapshot: session.snapshot(), restoring: sources)
    _ = try requireReceipt(await session.persist(capture: captured))
    #expect(try await visible(in: session).isEmpty)
    #expect(try await session.snapshot().notes.count == 4)
    let continuation = try #require(initialPage.continuation)
    let oldPage = try await session.history(for: .recentlyDeleted, after: continuation, limit: 1)
    #expect(oldPage.entries.count == 1)
    let selection = await session.selection
    try await session.quiesce()
    session = try await .open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await session.restoration(from: first, as: generation) }
    let snapshot = try await session.snapshot()
    #expect(throws: StorageError.wrongContext) { try CapturedActionGroup(snapshot: snapshot, restoring: [source]) }
    try await session.quiesce(); try await other.quiesce()
}

@Test(arguments: ["value", "birth", "action", "index", "scope", "unobserved", "reused"])
func restorationRejectsNearValidSources(fault: String) async throws {
    let (initial, protection) = try testInitial(false)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let old = try birth(1), fresh = try birth(3), base = try await source.snapshot()
    let deletion = try await deleted([old], in: source)
    let deleteBytes = try await source.retainedObject(at: deletion.object)
    _ = try await receiver.receive(deleteBytes)
    let entry = try #require(try await source.history(for: .deletions).entries.first)
    let capture = try await restore(entry, as: fresh, in: source)
    let receipt = try requireReceipt(await source.persist(capture: capture))
    let valid = try await source.retainedObject(at: receipt.object)
    let p = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(valid, collection: initial.descriptor.collection, protection: protection).payload)
    let record = p.actions[0], a = record.action, s = record.restorationReferences[0], member = p.operations[0]
    var deletionRef = s.deletionAction, priorRef = s.revision, sourceBirth = s.sourceBirth
    let target = try fault == "reused" ? birth(2) : fresh
    if fault == "birth" { sourceBirth = try birth(2) }
    if fault == "action" { deletionRef = base.context.collectionActions[0].reference }
    if fault == "index", case .external(let locator, _, let id) = priorRef {
        priorRef = .external(locator: locator, index: OperationIndex(UInt32.max), expectedID: id)
    }
    let originalValue = try #require(member.operation.effect.noteValue)
    let op = try IdentifiedOperation(nonce: member.operation.nonce,
        effect: .create(action: a.id, birth: target, value: fault == "value" ? testValue("wrong captured value") : originalValue),
        causalParents: fault == "unobserved" ? CausalParentSet(base.context.operations.map(\.id)) : member.operation.causalParents,
        notePredecessors: NotePredecessorSet([]))
    let newMember = try OperationRecordV1(operation: op,
        causalReferences: fault == "unobserved" ? base.context.operations.map(\.reference) : member.causalReferences,
        noteReferences: [], earlierOperations: [])
    let action = try ActionRecordV1(id: a.id, origin: a.origin,
        previousOrigin: fault == "unobserved" ? nil : record.previousOriginReference, scope: .collection,
        scopeParents: fault == "scope" ? [] : fault == "unobserved" ? base.context.collectionActions.map(\.reference) : record.scopeReferences,
        kind: .restoreBatch, members: [OperationIndex(0)],
        affected: [.init(birth: target, before: .freshBirthAbsence, after: .value(.earlierLocal(index: OperationIndex(0))))],
        operations: [op], earlierActions: [], restorations: [.init(birth: target, sourceBirth: sourceBirth, deletionAction: deletionRef, revision: priorRef)])
    let deps = try DependencyLocatorTable(Array(Set(p.dependencies.entries + base.context.operations.map(\.locator) + base.context.collectionActions.map(\.locator))))
    let payload = try ChangesPayloadV1(dependencies: deps, operations: [newMember], actions: [action])
    let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: initial.descriptor.collection,
        writer: WriterEpoch(bytes: Array(repeating: 72, count: 16)), sequence: 0, protection: protection)
    let expected: any Error
    switch fault {
    case "birth", "action": expected = CanonicalEncodingError.invalidAction
    case "index": expected = CanonicalEncodingError.invalidReference
    case "value": expected = OrdinaryHistoryError.invalidBeforeAfter
    case "reused": expected = OrdinaryHistoryError.reusedBirth
    default: expected = OrdinaryHistoryError.invalidAction
    }
    await #expect { try await receiver.receive(bytes) } throws: { String(reflecting: $0) == String(reflecting: expected) }
    #expect(try await visible(in: receiver) == [old])
    #expect(try await receiver.snapshot().notes.map(\.value.body.string) == ["untouched"])
    // The exact valid companion remains independently acceptable after rejection.
    _ = try await receiver.receive(valid)
    #expect(try await visible(in: receiver).isEmpty)
    #expect(try await receiver.snapshot().notes.first { $0.birth == fresh }?.value.body.string == "A")
    try await source.quiesce(); try await receiver.quiesce()
}

@Test func restorationNamesOneOfConcurrentDeletionActions() async throws {
    let (initial, protection) = try testInitial(false)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let old = try birth(1)
    let ld = try await deleted([old], in: left)
    _ = try await deleted([old], in: right)
    let leftEntry = try #require(try await left.history(for: .deletions).entries.first)
    let rightEntry = try #require(try await right.history(for: .deletions).entries.first)
    #expect(leftEntry.action != rightEntry.action)
    let capture = try await restore(leftEntry, as: birth(3), in: left)
    let restored = try requireReceipt(await left.persist(capture: capture))
    _ = try await right.receive(left.retainedObject(at: ld.object))
    #expect(try await right.history(for: .recentlyDeleted).entries.count == 2)
    _ = try await right.receive(left.retainedObject(at: restored.object))
    #expect(try await right.history(for: .recentlyDeleted).entries.map(\.action) == [rightEntry.action])
    #expect(try await right.history(for: .deletions).entries.count == 2)
    try await left.quiesce(); try await right.quiesce()
}
