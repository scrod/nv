import Foundation
import Testing
import NVStorageCore
import NVStorageRuntime

@Test func ordinaryValidationUsesExactWriterBasisAndPreservesOriginForks() async throws {
    let (initial, protection) = try testInitial(false), source = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let original = try #require(try await source.snapshot().notes.first { $0.birth == birth })
    let e = try await put("E", birth: birth, generation: 1, session: source)
    let f = try await put("F", birth: birth, generation: 2, session: source)
    var history: [SegmentLocator: ChangesPayloadV1] = [:]
    for (loc, bytes) in initial.objects {
        let o = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection)
        if o.kind == .changes { history[loc] = try ChangesPayloadV1.decodeV1(o.payload) }
    }
    history[e.object] = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(try await source.retainedObject(at: e.object),
        collection: initial.descriptor.collection, protection: protection).payload)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(try await source.retainedObject(at: f.object),
        collection: initial.descriptor.collection, protection: protection).payload)
    let operations = Dictionary(uniqueKeysWithValues: history.values.flatMap(\.operations).map { ($0.operation.id, $0.operation) })
    let actions = Dictionary(uniqueKeysWithValues: history.values.flatMap(\.actions).map { ($0.action.id, $0.action) })
    func validate(_ candidate: ChangesPayloadV1) async throws {
        let expected = Result { try SynchronousHistoryReference.validate(candidate, at: f.object,
            payloadAt: { history[$0] }, operationByID: { operations[$0] },
            actionByID: { actions[$0] }, birthExists: { $0 == birth }) }
        var failure: Error?
        do {
            try await OrdinaryHistoryV1.validate(candidate, at: f.object, payloadAt: { history[$0] },
            operationByID: { operations[$0] }, actionByID: { actions[$0] }, birthExists: { $0 == birth })
        } catch { failure = error }
        if let error = failure {
            guard case .failure(let reference) = expected else { Issue.record("Async validator rejected valid reference"); throw error }
            #expect(String(reflecting: error) == String(reflecting: reference))
            throw error
        }
        if case .failure = expected { Issue.record("Async validator accepted invalid reference") }
    }
    let record = payload.actions[0], action = record.action
    func changed(before: ActionStateReference? = nil, parents: [ActionReference]? = nil,
                 origin: ActionOriginID? = nil, previous: ActionReference? = nil) throws -> ChangesPayloadV1 {
        let a = try ActionRecordV1(id: action.id, origin: origin ?? action.origin,
            previousOrigin: previous ?? record.previousOriginReference, scope: action.scope,
            scopeParents: parents ?? record.scopeReferences, kind: action.kind, members: record.memberIndices,
            affected: [.init(birth: birth, before: before ?? record.affectedReferences[0].before,
                after: record.affectedReferences[0].after)], operations: payload.operations.map(\.operation), earlierActions: [])
        var locators = payload.dependencies.entries
        locators.append(original.revision.locator)
        if case .external(let loc, _, _) = previous { locators.append(loc) }
        return try ChangesPayloadV1(dependencies: DependencyLocatorTable(Array(Set(locators))), operations: payload.operations, actions: [a])
    }
    try await validate(payload)
    await #expect(throws: OrdinaryHistoryError.invalidBeforeAfter) {
        try await validate(changed(before: .value(.external(locator: original.revision.locator,
            index: original.revision.index, expectedID: original.revision.id))))
    }
    await #expect(throws: OrdinaryHistoryError.invalidAction) { try await validate(changed(parents: [])) }
    let extra = try IdentifiedOperation(nonce: OperationNonce(bytes: Array(repeating: 55, count: 16)),
        effect: .put(action: action.id, birth: birth, value: testValue("last member")),
        causalParents: CausalParentSet([payload.operations[0].operation.id]),
        notePredecessors: NotePredecessorSet([payload.operations[0].operation.id]))
    let extended = try payload.operations + [OperationRecordV1(operation: extra,
        causalReferences: [.earlierLocal(index: OperationIndex(0))], noteReferences: [.earlierLocal(index: OperationIndex(0))],
        earlierOperations: payload.operations.map(\.operation))]
    func group(after: UInt32, operations: [OperationRecordV1]? = nil) throws -> ChangesPayloadV1 {
        let extended = operations ?? extended
        let a = try ActionRecordV1(id: action.id, origin: action.origin, previousOrigin: record.previousOriginReference,
            scope: action.scope, scopeParents: record.scopeReferences, kind: action.kind,
            members: [OperationIndex(0), OperationIndex(1)],
            affected: [.init(birth: birth, before: record.affectedReferences[0].before,
                after: .value(.earlierLocal(index: OperationIndex(after))))],
            operations: extended.map(\.operation), earlierActions: [])
        return try ChangesPayloadV1(dependencies: payload.dependencies, operations: extended, actions: [a])
    }
    try await validate(group(after: 1))
    await #expect(throws: OrdinaryHistoryError.invalidBeforeAfter) { try await validate(group(after: 0)) }
    let detached = try IdentifiedOperation(nonce: OperationNonce(bytes: Array(repeating: 55, count: 16)),
        effect: extra.effect, causalParents: payload.operations[0].operation.causalParents,
        notePredecessors: extra.notePredecessors)
    let detachedGroup = try payload.operations + [OperationRecordV1(operation: detached,
        causalReferences: payload.operations[0].causalReferences, noteReferences: [.earlierLocal(index: OperationIndex(0))],
        earlierOperations: payload.operations.map(\.operation))]
    await #expect(throws: OrdinaryHistoryError.invalidCausality) { try await validate(group(after: 1, operations: detachedGroup)) }
    let prior = try #require(history[original.revision.locator]?.actions.first)
    // Preserve the fork's explicitly declared previous-origin edge when the
    // observed history also includes a later import from that origin.
    try await validate(changed(origin: prior.action.origin, previous: .external(locator: original.revision.locator,
        index: ActionIndex(0), expectedID: prior.action.id)))
    try await source.quiesce()
}

@Test(arguments: [false, true]) func concurrentHistoryIsRetainedButRequiresLaterReducer(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let remote = try await put("remote", birth: birth, generation: 1, session: source)
    let local = try await put("local", birth: birth, generation: 1, session: receiver)
    let bytes = try await source.retainedObject(at: remote.object)
    await #expect(throws: StorageError.unsupported) { try await receiver.receive(bytes) }
    #expect(try await receiver.retainedObject(at: remote.object) == bytes)
    #expect(try await !receiver.retainedObject(at: local.object).isEmpty)
    await #expect(throws: StorageError.incomplete) { try await receiver.snapshot() }
    let selection = await receiver.selection
    try await receiver.quiesce()
    await #expect(throws: StorageError.unsupported) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    try await source.quiesce()
}

@Test(arguments: [false, true]) func frozenCreationRenameLabelsAndBatchDeletion(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    // Creation provenance establishes this ordinary birth, even with version-8 bits.
    var bytes = Array(repeating: UInt8(1), count: 16); bytes[6] = 0x81; bytes[8] = 0x81
    let a = try NoteBirth(bytes: bytes), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let session = try await LocalStoreSession.create(directory: path, collection: initial.descriptor.collection,
        notes: [(a, testValue("A")), (b, testValue("B"))], protection: protection, passphrase: encrypted ? "synthetic" : nil)
    let original = try testValue("A")
    let renamed = try PlaintextNoteValue(title: ExactUTF8(bytes: Array("Renamed".utf8)), body: original.body,
        labels: original.labels, created: original.created, modified: original.modified)
    let labeled = try PlaintextNoteValue(title: renamed.title, body: renamed.body,
        labels: CanonicalLabels([ExactUTF8(bytes: Array("Tag".utf8))]), created: renamed.created, modified: renamed.modified)
    for (i, entry) in [(ActionKindV1.rename, renamed), (.labels, labeled)].enumerated() {
        let capture = try await CapturedActionGroup(snapshot: session.snapshot(), kind: entry.0,
            changes: [.put(CapturedNoteGeneration(birth: a, generation: UInt64(i + 1)), entry.1)])
        _ = try requireReceipt(await session.persist(capture: capture))
    }
    #expect(try await session.snapshot().notes.first { $0.birth == a }?.value == labeled)
    let deletion = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .deleteBatch,
        changes: [a, b].map { try .delete(CapturedNoteGeneration(birth: $0, generation: 3)) })
    let receipt = try requireReceipt(await session.persist(capture: deletion))
    #expect(receipt.covered.count == 2)
    let selection = await session.selection
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.isEmpty)
    #expect(try await reopened.snapshot().through == 4)
    try await reopened.quiesce()
}
