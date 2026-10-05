import NVStorageCore
@testable import NVStorageRuntime
import Testing

private let rejectionMappings: [(any Error, Int64?)] = [
    (StorageError.unsupported, 1),
    (OrdinaryHistoryError.conflictingClaim, 2), (OrdinaryHistoryError.invalidCausality, 3),
    (OrdinaryHistoryError.invalidAction, 4), (OrdinaryHistoryError.invalidBeforeAfter, 5),
    (OrdinaryHistoryError.reusedBirth, 6), (OrdinaryHistoryError.requiresLaterReducer, 7),
    (CanonicalEncodingError.truncated, 20), (CanonicalEncodingError.trailingBytes, 21),
    (CanonicalEncodingError.lengthLimit, 22), (CanonicalEncodingError.invalidUTF8, 23),
    (CanonicalEncodingError.invalidDate, 24), (CanonicalEncodingError.noncanonicalDate, 25),
    (CanonicalEncodingError.noncanonicalLabels, 26), (CanonicalEncodingError.unsupportedFormat, 27),
    (CanonicalEncodingError.invalidIdentifier, 28), (CanonicalEncodingError.invalidDiscriminant, 29),
    (CanonicalEncodingError.noncanonicalSet, 30), (CanonicalEncodingError.invalidReference, 31),
    (CanonicalEncodingError.invalidOperation, 32), (CanonicalEncodingError.identityMismatch, 33),
    (CanonicalEncodingError.invalidAction, 34), (CanonicalEncodingError.invalidPayload, 35),
    (CanonicalEncodingError.wrongScope, 36), (CanonicalEncodingError.authenticationFailure, 37),
    (GeneralSnapshotError.invalidManifest, 35), (GeneralSnapshotError.invalidState, 5),
    (StorageError.database(5), nil), (StorageError.database(10), nil), (StorageError.database(13), nil),
    (StorageError.ownership(13), nil), (StorageError.wrongContext, nil), (StorageError.incomplete, nil),
    (StorageError.integrity, nil), (StorageError.closed, nil), (StorageError.busy, nil),
    (StorageError.staleCapture, nil), (StorageError.limit, nil),
    (CanonicalEncodingError.missingDependency, nil), (CanonicalEncodingError.keyDerivationFailure, nil),
    (HistoryValidationInterrupted.historyAdvanced, nil)
]

@Test(arguments: rejectionMappings)
private func receiveRejectionMatchesIndependentCodes(error: any Error, expected: Int64?) {
    #expect(ReceiveRejection(error)?.rawValue == expected)
}

@Test(arguments: [false, true])
func typedCompensationPreservesReviewIntentAndContext(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let store = try await newSession(initial, protection), other = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let unrelated = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let edited = try await put("saved edit", birth: birth, generation: 1, session: store)
    guard case .automatic(let automatic) = try await store.prepareCompensation(scope: .note(birth), direction: .undo) else {
        Issue.record("An isolated edit must issue an automatic command"); return
    }
    let review = automatic.forReview()
    #expect(review.proposal.candidate == automatic.proposal.candidate)
    #expect(review.proposal.effects.map(\.birth) == [birth])
    let replacement = try testValue("approved replacement")
    await #expect(throws: StorageError.wrongContext) { try await other.applyCompensation(automatic) }
    await #expect(throws: StorageError.wrongContext) { try await other.applyReviewedCompensation(review) }
    await #expect(throws: StorageError.staleCapture) {
        try await store.applyReviewedCompensation(review, replacements: [unrelated: replacement])
    }
    #expect(try await store.snapshot().through == edited.sequence)
    let receipt = try requireReceipt(await store.applyReviewedCompensation(review, replacements: [birth: replacement]))
    let opened = try await ObjectEnvelopeV1.open(store.retainedObject(at: receipt.object),
        collection: initial.descriptor.collection, protection: protection)
    let payload = try ChangesPayloadV1.decodeV1(opened.payload)
    #expect(payload.actions.count == 1 && payload.operations.count == 1)
    #expect(payload.actions[0].action.kind == .undo)
    #expect(payload.actions[0].action.details == .compensation(target: automatic.proposal.candidate, reviewed: true))
    #expect(payload.operations[0].operation.effect.noteValue == replacement)
    await #expect(throws: StorageError.staleCapture) { try await store.applyReviewedCompensation(review) }
    #expect(try await store.snapshot().through == receipt.sequence)
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.first { $0.birth == birth }?.value == replacement)
    await #expect(throws: StorageError.wrongContext) { try await reopened.applyReviewedCompensation(review) }
    guard case .automatic(let redo) = try await reopened.prepareCompensation(scope: .note(birth), direction: .redo) else {
        Issue.record("The actual reviewed inverse must have an automatic Redo"); return
    }
    _ = try requireReceipt(await reopened.applyCompensation(redo))
    #expect(try await reopened.snapshot().notes.first { $0.birth == birth }?.value.body.string == "saved edit")
    try await reopened.quiesce(); try await other.quiesce()
}

@Test(arguments: [false, true])
func validatedBatchesRetainExactObjectMembership(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let lane = await store.lane
    let bootstrap = try await lane.perform { try $0.rows("SELECT object_id,encoded FROM objects WHERE kind<>0") }
    #expect(bootstrap.count == initial.objects.count)
    for (locator, bytes) in initial.objects {
        #expect(bootstrap.contains([.blob(locator.segmentID.bytes), .blob(bytes)]))
        let opened = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection)
        let dependencies: Set<SegmentLocator>
        switch opened.kind {
        case .changes: dependencies = Set(try ChangesPayloadV1.decodeV1(opened.payload).dependencies.entries)
        case .snapshotPage: dependencies = Set(try InitialSnapshotPageV1.decodeV1(opened.payload).dependencies.entries)
        case .snapshotRoot:
            let root = try InitialSnapshotRootV1.decodeV1(opened.payload)
            dependencies = Set(root.dependencies.entries + root.pages.map(\.locator))
        }
        let recorded = try await lane.perform { db in
            try Set(db.rows("SELECT prerequisite FROM accepted_dependencies WHERE child=?",
                [.blob(locator.segmentID.bytes)]).map { try $0[0].bytes })
        }
        #expect(recorded == Set(dependencies.map { $0.segmentID.bytes }))
    }
    let receipt = try await put("complete action", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: store)
    let bytes = try await store.retainedObject(at: receipt.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes,
        collection: initial.descriptor.collection, protection: protection).payload)
    let membership = try await lane.perform { db in
        try (db.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(receipt.object.segmentID.bytes)]),
            db.rows("SELECT operation_id FROM operation_occurrences WHERE object_id=?", [.blob(receipt.object.segmentID.bytes)]),
            db.rows("SELECT action_id FROM action_occurrences WHERE object_id=?", [.blob(receipt.object.segmentID.bytes)]))
    }
    #expect(membership.0 == [[.blob(bytes)]])
    #expect(membership.1 == payload.operations.map { [.blob($0.operation.id.bytes)] })
    #expect(membership.2 == payload.actions.map { [.blob($0.action.id.bytes)] })
    #expect(payload.operations[0].operation.effect.noteValue?.body.string == "complete action")
    #expect(payload.actions[0].action.members == payload.operations.map(\.operation.id))
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.retainedObject(at: receipt.object) == bytes)
    #expect(try await reopened.snapshot().notes.first { $0.birth == receipt.covered[0].birth }?.value.body.string == "complete action")
    try await reopened.quiesce()
}
