import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

func fullCheck(_ bytes: [UInt8], in session: LocalStoreSession, protection: ObjectProtectionV1) async throws {
    let lane = await session.lane, selection = await session.selection
    let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
    let payload = try ChangesPayloadV1.decodeV1(opened.payload)
    let through = try await lane.perform { try $0.acceptedThrough() }
    try await OrdinaryHistoryV1.validate(payload, at: opened.locator,
        payloadAt: { id in try await lane.historyRead(through: through) { try $0.payload(id, collection: selection.descriptor.collection, protection: protection) } },
        operationByID: { id in try await lane.historyRead(through: through) { try $0.operation(id, selection: selection, protection: protection) } },
        actionByID: { id in try await lane.historyRead(through: through) { try $0.action(id, selection: selection, protection: protection) } },
        birthExists: { id in try await lane.historyRead(through: through) { try !$0.rows("SELECT 1 FROM operations WHERE birth=?", [.blob(id.bytes)]).isEmpty } })
}

func measureReceive(_ bytes: [UInt8], in session: LocalStoreSession) async throws -> StorageWork {
    let lane = await session.lane
    try await lane.perform { $0.work = StorageWork() }
    _ = try await session.receive(bytes)
    return try await lane.perform { db in let result = db.work!; db.work = nil; return result }
}

@Test(arguments: [false, true]) func currentBasisAgreesWithFullValidation(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let c = try NoteBirth(bytes: Array(repeating: 3, count: 16)), d = try NoteBirth(bytes: Array(repeating: 4, count: 16))
    let edited = try testValue("edited")
    let renamed = try PlaintextNoteValue(title: ExactUTF8(bytes: Array("renamed".utf8)), body: edited.body,
        labels: edited.labels, created: edited.created, modified: edited.modified)
    let labeled = try PlaintextNoteValue(title: renamed.title, body: renamed.body,
        labels: CanonicalLabels([ExactUTF8(bytes: Array("label".utf8))]), created: renamed.created, modified: renamed.modified)
    let ga = try CapturedNoteGeneration(birth: a, generation: 1)
    let gc = try CapturedNoteGeneration(birth: c, generation: 1), gd = try CapturedNoteGeneration(birth: d, generation: 1)
    let steps: [(OrdinaryActionKind, [CapturedNoteChange], [String])] = try [
        (.savedEdit, [.put(ga, edited)], ["edited", "untouched"]),
        (.rename, [.put(ga, renamed)], ["edited", "untouched"]),
        (.labels, [.put(ga, labeled)], ["edited", "untouched"]),
        (.createImportBatch, [.create(gc, testValue("C")), .create(gd, testValue("D"))], ["C", "D", "edited", "untouched"]),
        (.deleteBatch, [.delete(gc), .delete(gd)], ["edited", "untouched"]),
        (.deleteBatch, [.delete(ga)], ["untouched"])
    ]
    for (kind, changes, expected) in steps {
        let capture = try await CapturedActionGroup(snapshot: source.snapshot(), kind: kind, changes: changes)
        let saved = try requireReceipt(await source.persist(capture: capture))
        let bytes = try await source.retainedObject(at: saved.object)
        try await fullCheck(bytes, in: receiver, protection: protection)
        let work = try await measureReceive(bytes, in: receiver)
        #expect(work[.validation].fastChecks == 1)
        #expect(work[.validation].fullChecks == 0)
        #expect(work[.validation].ancestors == 0)
        #expect(work[.acceptance].envelopeDecodes == 0)
        let view = try await receiver.snapshot()
        #expect(view.notes.map(\.value.body.string).sorted() == expected)
        if kind == .rename { #expect(view.notes.first { $0.birth == a }?.value.title.string == "renamed") }
        if kind == .labels { #expect(view.notes.first { $0.birth == a }?.value == labeled) }
    }
    let selection = await receiver.selection
    try await receiver.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string) == ["untouched"])
    try await reopened.quiesce(); try await source.quiesce()
}

private enum BasisFault: String, CaseIterable, Sendable {
    case valid, scope, before, predecessor, parents, origin, index, reusedAction
}

@Test(arguments: BasisFault.allCases) private func currentBasisRejectsNearValidClaims(fault: BasisFault) async throws {
    let (initial, protection) = try testInitial(false)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let initialView = try await source.snapshot(), original = try #require(initialView.notes.first { $0.birth == birth })
    let e = try await put("E", birth: birth, generation: 1, session: source)
    _ = try await receiver.receive(source.retainedObject(at: e.object))
    let f = try await put("F", birth: birth, generation: 2, session: source)
    let originalBytes = try await source.retainedObject(at: f.object)
    let opened = try ObjectEnvelopeV1.open(originalBytes, collection: initial.descriptor.collection, protection: protection)
    let p = try ChangesPayloadV1.decodeV1(opened.payload), a = p.actions[0], oldOp = p.operations[0]
    let before: OperationReference = fault == .before ? original.revision.reference :
        (fault == .index ? .external(locator: e.object, index: OperationIndex(99), expectedID: oldOp.operation.notePredecessors.ids[0]) : a.affectedReferences[0].before.referenceForTest!)
    let actionID: ActionID
    if fault == .reusedAction {
        let ep = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(try await source.retainedObject(at: e.object),
            collection: initial.descriptor.collection, protection: protection).payload)
        actionID = ep.actions[0].action.id
    } else { actionID = a.action.id }
    let parents = fault == .parents ? initialView.context.operations.map(\.reference) : oldOp.causalReferences
    let predecessors = fault == .predecessor ? [original.revision.reference] : oldOp.noteReferences
    let op = try IdentifiedOperation(nonce: oldOp.operation.nonce, effect: .put(action: actionID, birth: birth, value: testValue("F")),
        causalParents: CausalParentSet(parents.map(\.idForTest)), notePredecessors: NotePredecessorSet(predecessors.map(\.idForTest)))
    let record = try OperationRecordV1(operation: op, causalReferences: parents, noteReferences: predecessors, earlierOperations: [])
    let action = try ActionRecordV1(id: actionID,
        origin: fault == .origin ? ActionOriginID(bytes: Array(repeating: 77, count: 16)) : a.action.origin,
        previousOrigin: fault == .reusedAction ? nil : a.previousOriginReference, scope: a.action.scope,
        scopeParents: fault == .scope || fault == .reusedAction ? [] : a.scopeReferences, kind: a.action.kind, members: [OperationIndex(0)],
        affected: [.init(birth: birth, before: .value(before), after: .value(.earlierLocal(index: OperationIndex(0))))],
        operations: [op], earlierActions: [])
    let locators = Set(p.dependencies.entries + [original.revision.locator] + initialView.context.operations.map(\.locator))
    let changed = try ChangesPayloadV1(dependencies: DependencyLocatorTable(Array(locators)), operations: [record], actions: [action])
    let bytes = try ObjectEnvelopeV1.seal(payload: changed.encodedV1(), kind: .changes, collection: initial.descriptor.collection,
        writer: WriterEpoch(bytes: Array(repeating: 88, count: 16)), sequence: 0, protection: protection)
    if fault == .valid {
        try await fullCheck(bytes, in: receiver, protection: protection)
        let work = try await measureReceive(bytes, in: receiver)
        #expect(work[.validation].fastChecks == 1)
        #expect(try await receiver.snapshot().notes.first { $0.birth == birth }?.value.body.string == "F")
    } else {
        let expected: any Error
        switch fault {
        case .scope, .parents: expected = OrdinaryHistoryError.invalidAction
        case .before, .predecessor: expected = OrdinaryHistoryError.invalidBeforeAfter
        case .origin: expected = CanonicalEncodingError.invalidAction
        case .index: expected = CanonicalEncodingError.invalidReference
        case .reusedAction: expected = OrdinaryHistoryError.conflictingClaim
        case .valid: fatalError("handled above")
        }
        await #expect { try await fullCheck(bytes, in: receiver, protection: protection) } throws: { sameError($0, expected) }
        await #expect { try await receiver.receive(bytes) } throws: { sameError($0, expected) }
        #expect(try await receiver.snapshot().through == 2)
        #expect(try await receiver.snapshot().notes.first { $0.birth == birth }?.value.body.string == "E")
    }
    try await source.quiesce(); try await receiver.quiesce()
}

private func sameError(_ a: any Error, _ b: any Error) -> Bool {
    if let a = a as? OrdinaryHistoryError, let b = b as? OrdinaryHistoryError { return a == b }
    if let a = a as? CanonicalEncodingError, let b = b as? CanonicalEncodingError { return a == b }
    return false
}
private extension ActionStateReference {
    var referenceForTest: OperationReference? {
        switch self { case .value(let r), .deleted(let r): return r; case .freshBirthAbsence, .derived, .automatic: return nil }
    }
}
private extension OperationReference {
    var idForTest: OperationID {
        guard case .external(_, _, let id) = self else { preconditionFailure("external fixture") }
        return id
    }
}

@Test(arguments: [false, true]) func currentBasisChecksHistoricalBirthReuse(reused: Bool) async throws {
    let (initial, protection) = try testInitial(false), receiver = try await newSession(initial, protection)
    let deleted = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let deletion = try await CapturedActionGroup(snapshot: receiver.snapshot(), kind: .deleteBatch,
        changes: [.delete(CapturedNoteGeneration(birth: deleted, generation: 1))])
    _ = try requireReceipt(await receiver.persist(capture: deletion))
    let birth = try reused ? deleted : NoteBirth(bytes: Array(repeating: 3, count: 16))
    let capture = try await CapturedActionGroup(snapshot: receiver.snapshot(), kind: .createImportBatch,
        changes: [.create(CapturedNoteGeneration(birth: birth, generation: 2), testValue("new"))])
    let context = capture.context
    let op = try IdentifiedOperation(nonce: OperationNonce(bytes: Array(repeating: 92, count: 16)),
        effect: .create(action: capture.action, birth: birth, value: testValue("new")),
        causalParents: CausalParentSet(context.operations.map(\.id)), notePredecessors: NotePredecessorSet([]))
    let record = try OperationRecordV1(operation: op, causalReferences: context.operations.map(\.reference),
        noteReferences: [], earlierOperations: [])
    let action = try ActionRecordV1(id: capture.action, origin: ActionOriginID(bytes: Array(repeating: 91, count: 16)),
        previousOrigin: nil, scope: .collection, scopeParents: context.collectionActions.map(\.reference),
        kind: .createImportBatch, members: [OperationIndex(0)],
        affected: [.init(birth: birth, before: .freshBirthAbsence, after: .value(.earlierLocal(index: OperationIndex(0))))],
        operations: [op], earlierActions: [])
    let payload = try ChangesPayloadV1(dependencies: DependencyLocatorTable(Array(Set(
        context.operations.map(\.locator) + context.collectionActions.map(\.locator)))), operations: [record], actions: [action])
    let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: initial.descriptor.collection,
        writer: WriterEpoch(bytes: Array(repeating: 90, count: 16)), sequence: 0, protection: protection)
    if reused {
        await #expect(throws: OrdinaryHistoryError.reusedBirth) { try await fullCheck(bytes, in: receiver, protection: protection) }
        await #expect(throws: OrdinaryHistoryError.reusedBirth) { try await receiver.receive(bytes) }
        #expect(try await receiver.snapshot().through == 2)
        #expect(try await receiver.snapshot().notes.map(\.value.body.string) == ["untouched"])
    } else {
        try await fullCheck(bytes, in: receiver, protection: protection)
        let work = try await measureReceive(bytes, in: receiver)
        #expect(work[.validation].fastChecks == 1)
        #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["new", "untouched"])
    }
    try await receiver.quiesce()
}

@Test(arguments: [false, true]) func currentBasisRequiresCompleteMaterialization(unobservedOrigin: Bool) async throws {
    let (initial, protection) = try testInitial(false)
    let firstWriter = try await newSession(initial, protection), secondWriter = try await newSession(initial, protection)
    let receiver = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let e = try await put("E", birth: a, generation: 1, session: firstWriter)
    let f = try await put("F", birth: b, generation: 1, session: secondWriter)
    let eb = try await firstWriter.retainedObject(at: e.object), fb = try await secondWriter.retainedObject(at: f.object)
    let ep = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(eb, collection: initial.descriptor.collection, protection: protection).payload)
    let fp = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(fb, collection: initial.descriptor.collection, protection: protection).payload)
    let original = fp.actions[0]
    let action = try ActionRecordV1(id: original.action.id,
        origin: unobservedOrigin ? ep.actions[0].action.origin : original.action.origin,
        previousOrigin: unobservedOrigin ? .external(locator: e.object, index: ActionIndex(0), expectedID: ep.actions[0].action.id) : nil,
        scope: original.action.scope, scopeParents: original.scopeReferences, kind: original.action.kind,
        members: original.memberIndices, affected: original.affectedReferences,
        operations: fp.operations.map(\.operation), earlierActions: [])
    let payload = try ChangesPayloadV1(dependencies: DependencyLocatorTable(Array(Set(fp.dependencies.entries + [e.object]))),
        operations: fp.operations, actions: [action])
    let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: initial.descriptor.collection,
        writer: WriterEpoch(bytes: Array(repeating: 89, count: 16)), sequence: 0, protection: protection)
    let lane = await receiver.lane, selection = await receiver.selection
    // Hold derived rows at bootstrap after the actual E acceptance transaction.
    try await lane.perform { db in
        _ = try db.acceptOrdinary(eb, locator: e.object, selection: selection, protection: protection)
        db.work = StorageWork()
    }
    if unobservedOrigin {
        await #expect(throws: OrdinaryHistoryError.invalidAction) { try await fullCheck(bytes, in: receiver, protection: protection) }
        await #expect(throws: OrdinaryHistoryError.invalidAction) { try await receiver.receive(bytes) }
        #expect(try await lane.perform { try $0.acceptedThrough() } == 2)
    } else {
        try await fullCheck(bytes, in: receiver, protection: protection)
        _ = try await receiver.receive(bytes)
        #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["E", "F"])
    }
    let work = try await lane.perform { $0.work! }
    #expect(work[.validation].fastChecks == 0)
    #expect(work[.validation].fullChecks == 1)
    try await firstWriter.quiesce(); try await secondWriter.quiesce(); try await receiver.quiesce()
}

@Test(arguments: [false, true]) func currentBasisPreservesBranchFrontiers(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let e = try await put("E", birth: a, generation: 1, session: left)
    let f = try await put("F", birth: b, generation: 1, session: right)
    let eb = try await left.retainedObject(at: e.object), fb = try await right.retainedObject(at: f.object)
    let fork = try await measureReceive(fb, in: left)
    #expect(fork[.validation].fastChecks == 0 && fork[.validation].fullChecks == 1)
    let both = try await left.snapshot()
    #expect(Set(both.context.operations.map(\.locator)) == [e.object, f.object])
    let lane = await left.lane
    let branchedPin = try await lane.perform { try Set($0.rows("SELECT object_id FROM retained_frontier").map { try $0[0].bytes }) }
    #expect(branchedPin == Set([initial.snapshot.segmentID.bytes, e.object.segmentID.bytes, f.object.segmentID.bytes]))
    let work = try await measuredPut(left, birth: a, generation: 2)
    #expect(work[.validation].fastChecks == 1 && work[.validation].ancestors == 0)
    let complete = try await left.snapshot(), joined = try #require(complete.context.operations.first).locator
    #expect(complete.context.operations.count == 1)
    let joinedPin = try await lane.perform { try Set($0.rows("SELECT object_id FROM retained_frontier").map { try $0[0].bytes }) }
    #expect(joinedPin == Set([initial.snapshot.segmentID.bytes, joined.segmentID.bytes]))
    let joinedBytes = try await left.retainedObject(at: joined)
    guard case .waiting = try await right.receive(joinedBytes) else { Issue.record("missing branch must park"); return }
    _ = try await right.receive(eb)
    let rightView = try await right.snapshot()
    #expect(rightView.notes.map(\.value.body.string).sorted() == ["F", "measured"])
    #expect(rightView.context == complete.context)
    _ = try await right.receive(joinedBytes)
    #expect(try await right.snapshot().through == rightView.through)
    let selection = await right.selection
    try await right.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().context == complete.context)
    try await reopened.quiesce(); try await left.quiesce()
}
