import NVStorageCore
@testable import NVStorageRuntime
import Testing

enum ConnectedInvalidClaim: CaseIterable, Sendable { case choiceHeads, copyKey, nativeComplete, nativeCandidate, historyFields, compensationScope }

@Test(arguments: [false, true], ConnectedInvalidClaim.allCases)
func connectedCommandsRejectAuthenticatedNearValidClaims(encrypted: Bool, defect: ConnectedInvalidClaim) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let writer = try await newSession(initial, protection), peer = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let entry = try #require(try await writer.history(for: .note(birth)).entries.first)
    let edit = try await put("AB", birth: birth, generation: 1, session: writer)
    let capture: CapturedActionGroup
    switch defect {
    case .choiceHeads:
        let other = try await newSession(initial, protection)
        let r = try await put("Right", birth: birth, generation: 1, session: other)
        _ = try await writer.receive(other.retainedObject(at: r.object))
        let revision = try #require(try await other.snapshot().notes.first { $0.birth == birth }).revision.id
        capture = try await writer.chooseVersion(for: birth, revision: revision, generation: 2)
        try await other.quiesce()
    case .copyKey:
        capture = try await writer.copyVersion(for: birth, revision: writer.snapshot().notes.first { $0.birth == birth }!.revision.id, generation: 2)
    case .nativeComplete:
        let payload = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(writer.retainedObject(at: edit.object), collection: initial.descriptor.collection, protection: protection).payload)
        capture = try await writer.nativeCompensation(for: birth, steps: [.init(value: testValue("A!"), coverage: [.init(action: payload.actions[0].action.id, complete: false)])], generation: 2)
    case .nativeCandidate:
        let newest = try await put("ABCD", birth: birth, generation: 2, session: writer)
        let payload = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(writer.retainedObject(at: newest.object), collection: initial.descriptor.collection, protection: protection).payload)
        capture = try await writer.nativeCompensation(for: birth, steps: [.init(value: testValue("ABC"), coverage: [.init(action: payload.actions[0].action.id, complete: false)])], generation: 3)
    case .historyFields: capture = try await writer.recoverHistory(entry, to: birth, generation: 2)
    case .compensationScope:
        guard case .automatic(let proposal) = try await writer.prepareCompensation(scope: .note(birth), direction: .undo) else { Issue.record("The valid saved edit must be automatically undoable"); return }
        let committed = try requireReceipt(await writer.applyCompensation(proposal))
        let opened = try await ObjectEnvelopeV1.open(writer.retainedObject(at: committed.object), collection: initial.descriptor.collection, protection: protection)
        try await challenge(ChangesPayloadV1.decodeV1(opened.payload), committed)
        try await writer.quiesce(); try await peer.quiesce(); return
    }
    let committed = try requireReceipt(await writer.persist(capture: capture))
    let opened = try await ObjectEnvelopeV1.open(writer.retainedObject(at: committed.object), collection: initial.descriptor.collection, protection: protection)
    try await challenge(ChangesPayloadV1.decodeV1(opened.payload), committed)
    try await writer.quiesce(); try await peer.quiesce()

    func challenge(_ payload: ChangesPayloadV1, _ committed: AcceptedHistoryReceipt) async throws {
        let graph = try await writer.lane.retainedGraph(through: writer.snapshot().through, selection: writer.selection, protection: protection)
        for locator in Set(graph.operationReferences.values.map(\.locator)) where locator != committed.object {
            _ = try await peer.receive(writer.retainedObject(at: locator))
        }
        let original = payload.actions[0], ops = payload.operations.map(\.operation)
        let details: ActionDetailsReferenceV1
        switch (defect, original.detailsReference) {
        case (.choiceHeads, .choice(let selected, _)): details = .choice(selected: selected, heads: [selected])
        case (.copyKey, .copy(let source, let revision, _, let slot, let reused)):
            details = .copy(source: source, revision: revision, key: try .init(bytes: Array(repeating: 33, count: 32)), slot: slot, reused: reused)
        case (.nativeComplete, .native(let records)):
            details = .native(records.map { .init(action: $0.action, remaining: $0.remaining, complete: true) })
        case (.nativeCandidate, .native(let records)):
            let old = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(writer.retainedObject(at: edit.object), collection: initial.descriptor.collection, protection: protection).payload)
            let reference = try #require(graph.actionReferences[old.actions[0].action.id])
            details = .native(records.map { .init(action: reference.reference, remaining: $0.remaining, complete: $0.complete) })
        case (.historyFields, .historical(let source, let revision, _)): details = .historical(source: source, revision: revision, fields: .title)
        case (.compensationScope, .compensation):
            let wrong = try #require(graph.actionReferences[entry.action])
            details = .compensation(target: wrong.reference, reviewed: false)
        default: Issue.record("The positive command must supply the intended details variant"); return
        }
        let record = try ActionRecordV1(id: original.action.id, origin: original.action.origin, previousOrigin: original.previousOriginReference,
            scope: original.action.scope, scopeParents: original.scopeReferences, kind: original.action.kind, members: original.memberIndices,
            affected: original.affectedReferences, operations: ops, earlierActions: [], restorations: original.restorationReferences, details: details)
        var locators = payload.dependencies.entries
        if case .compensation(.external(let locator, _, _), _) = details { locators.append(locator) }
        if case .native(let records) = details {
            for record in records { if case .external(let locator, _, _) = record.action { locators.append(locator) } }
        }
        let invalid = try ChangesPayloadV1(dependencies: DependencyLocatorTable(Array(Set(locators))), operations: payload.operations, actions: [record])
        let bytes = try ObjectEnvelopeV1.seal(payload: invalid.encodedV1(), kind: .changes, collection: initial.descriptor.collection,
            writer: .init(bytes: Array(repeating: 61, count: 16)), sequence: 0, protection: protection)
        let locator = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection).locator
        let before = try await peer.snapshot()
        let expected: OrdinaryHistoryError = defect == .copyKey || defect == .compensationScope || defect == .nativeCandidate ? .invalidAction : .invalidBeforeAfter
        await #expect(throws: expected) { try await peer.receive(bytes) }
        let unchanged = try await peer.snapshot()
        #expect(unchanged.notes == before.notes && unchanged.through == before.through)
        #expect(try await peer.lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]) } == [[.blob(bytes)]])
        await #expect(throws: StorageError.incomplete) { try await peer.retainedObject(at: locator) }
        #expect(try await peer.lane.perform { try $0.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).isEmpty })
        let good = try await peer.receive(writer.retainedObject(at: committed.object))
        if case .accepted = good {} else { Issue.record("The supported companion must accept after isolated rejection") }
        #expect(try await peer.snapshot().notes == writer.snapshot().notes)
    }
}

@Test(arguments: [false, true]) func completeNamedActionRejectsOneWrongMemberAtomically(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), writer = try await newSession(initial, protection), peer = try await newSession(initial, protection)
    let births = try [1,2].map { try NoteBirth(bytes: Array(repeating: UInt8($0), count: 16)) }
    let capture = try await CapturedActionGroup(snapshot: writer.snapshot(), kind: .deleteBatch,
        changes: births.map { try .delete(.init(birth: $0, generation: 1)) })
    let receipt = try requireReceipt(await writer.persist(capture: capture))
    let p = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(writer.retainedObject(at: receipt.object), collection: initial.descriptor.collection, protection: protection).payload)
    let a = p.actions[0]
    var affected = a.affectedReferences
    affected[1] = .init(birth: affected[1].birth, before: affected[0].before, after: affected[1].after)
    let bad = try ActionRecordV1(id: a.action.id, origin: a.action.origin, previousOrigin: a.previousOriginReference, scope: a.action.scope,
        scopeParents: a.scopeReferences, kind: a.action.kind, members: a.memberIndices, affected: affected, operations: p.operations.map(\.operation), earlierActions: [])
    let bytes = try ObjectEnvelopeV1.seal(payload: ChangesPayloadV1(dependencies: p.dependencies, operations: p.operations, actions: [bad]).encodedV1(),
        kind: .changes, collection: initial.descriptor.collection, writer: .init(bytes: Array(repeating: 62, count: 16)), sequence: 0, protection: protection)
    let before = try await peer.snapshot()
    await #expect(throws: CanonicalEncodingError.invalidAction) { try await peer.receive(bytes) }
    let unchanged = try await peer.snapshot()
    #expect(unchanged.notes == before.notes && unchanged.through == before.through)
    #expect(try await peer.lane.perform { try $0.rows("SELECT 1 FROM actions WHERE action_id=?", [.blob(a.action.id.bytes)]).isEmpty })
    let good = try await peer.receive(writer.retainedObject(at: receipt.object))
    if case .accepted = good {} else { Issue.record("The complete valid group must accept") }
    #expect(try await peer.snapshot().notes.isEmpty)
    try await writer.quiesce(); try await peer.quiesce()
}
