import NVStorageCore
import Testing

private func literal(_ hex: String) throws -> [UInt8] {
    let chars = Array(hex.filter { !$0.isWhitespace })
    return try stride(from: 0, to: chars.count, by: 2).map {
        try #require(UInt8(String(chars[$0...($0 + 1)]), radix: 16))
    }
}

// Independently assembled with Python struct/hashlib from the field tables.
// These codec fixtures exercise framing with a declared Genesis commitment.
private let actionHex = """
1112131415161718191a1b1c1d1e1f204142434445464748494a4b4c4d4e4f50
000000000000040000000100000001000000012122232425262728292a2b2c2d2e2f30
00010100000001
"""
private let payloadHex = """
4e56434847310d0a000100000000000000020000007c
0984aace16fc3b80c587eba41b70b3813d56f2edd4005b838c67e2d0126add5d
0102030405060708090a0b0c0d0e0f1001000000000000000000000000003d
3132333435363738393a3b3c3d3e3f4001000100010000000000000002
6161616161616161616161616161616161616161616161616161616161616161
00000094
21b2c4fb643c6da6fafcb1254cb53c9d87bedfd8eb4cbaaa61b845047dead384
0102030405060708090a0b0c0d0e0f1003011112131415161718191a1b1c1d1e1f20
012122232425262728292a2b2c2d2e2f300000000101000000000000000000000030
01000000014100000002620a0000000200000004576f726b00000004776f726b
00000000000000003ff0000000000000
000000010000004a
""" + actionHex

private struct PayloadFixture {
    let birth = try! NoteBirth(bytes: Array(33...48))
    let origin = try! ActionOriginID(bytes: Array(65...80))
    let table = try! DependencyLocatorTable([])
    let ids = [try! ActionID(bytes: Array(17...32)),
               try! ActionID(bytes: Array(repeating: 2, count: 16)),
               try! ActionID(bytes: Array(repeating: 3, count: 16))]
    let records: [OperationRecordV1]
    var operations: [IdentifiedOperation] { records.map(\.operation) }

    init() throws {
        let value = try PlaintextNoteValue(title: ExactUTF8(bytes: [65]), body: ExactUTF8(bytes: [98, 10]),
            labels: CanonicalLabels([ExactUTF8(bytes: Array("Work".utf8)), ExactUTF8(bytes: Array("work".utf8))]),
            created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 1))
        let effects: [OperationEffectV1] = [
            try .genesis(importID: ImportID(bytes: Array(49...64)), profile: .plaintextFiles,
                initialCount: 2, initialValuesDigest: InitialValuesDigest(bytes: Array(repeating: 0x61, count: 32))),
            .create(action: ids[0], birth: birth, value: value),
            .put(action: ids[1], birth: birth, value: value),
            .delete(action: ids[2], birth: birth)]
        var result: [OperationRecordV1] = []
        for (i, effect) in effects.enumerated() {
            let parent = result.last.map { [$0.operation.id] } ?? []
            let ref: [OperationReference] = i == 0 ? [] : [.earlierLocal(index: OperationIndex(UInt32(i - 1)))]
            let operation = try IdentifiedOperation(nonce: OperationNonce(bytes: Array(1...16)), effect: effect,
                causalParents: CausalParentSet(parent), notePredecessors: NotePredecessorSet(i == 2 ? parent : []))
            result.append(try OperationRecordV1(operation: operation, causalReferences: ref,
                noteReferences: i == 2 ? ref : [], earlierOperations: result.map(\.operation)))
        }
        records = result
    }

    func action(_ step: Int, members: [OperationIndex]? = nil, before: ActionStateReference? = nil,
                after: ActionStateReference? = nil, scope: ActionScopeV1 = .collection,
                previous: ActionReference? = nil, parents: [ActionReference] = [], origin: ActionOriginID? = nil,
                earlier: [ActionV1] = []) throws -> ActionRecordV1 {
        let beforeState: ActionStateReference = step == 0 ? .freshBirthAbsence : .value(.earlierLocal(index: OperationIndex(UInt32(step))))
        let ref = OperationReference.earlierLocal(index: OperationIndex(UInt32(step + 1)))
        return try ActionRecordV1(id: ids[step], origin: origin ?? self.origin, previousOrigin: previous,
            scope: scope, scopeParents: parents, kind: [.createImportBatch, .savedEdit, .deleteBatch][step],
            members: members ?? [OperationIndex(UInt32(step + 1))],
            affected: [ActionAffectedReference(birth: birth, before: before ?? beforeState,
                after: after ?? (step == 2 ? .deleted(ref) : .value(ref)))],
            operations: operations, earlierActions: earlier)
    }

    func payload() throws -> ChangesPayloadV1 {
        let a = try action(0)
        let b = try action(1, previous: .earlierLocal(index: ActionIndex(0)),
            parents: [.earlierLocal(index: ActionIndex(0))], earlier: [a.action])
        let c = try action(2, previous: .earlierLocal(index: ActionIndex(1)),
            parents: [.earlierLocal(index: ActionIndex(1))], earlier: [a.action, b.action])
        return try ChangesPayloadV1(dependencies: table, operations: records, actions: [a, b, c])
    }
}

@Test func literalActionAndWholePayload() throws {
    let f = try PayloadFixture()
    let action = try f.action(0)
    let bytes = try literal(payloadHex)
    #expect(bytes.count == 380)
    #expect(try action.encodedV1(dependencies: f.table, operations: f.operations, earlierActions: []) == literal(actionHex))
    let payload = try ChangesPayloadV1(dependencies: f.table, operations: Array(f.records.prefix(2)), actions: [action])
    #expect(try payload.encodedV1() == bytes)
    #expect(try ChangesPayloadV1.decodeV1(bytes) == payload)
    for cut in 0..<bytes.count {
        #expect(throws: CanonicalEncodingError.self) { try ChangesPayloadV1.decodeV1(Array(bytes.prefix(cut))) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try ChangesPayloadV1.decodeV1(bytes + [0]) }
    let groups = try f.payload()
    #expect(try ChangesPayloadV1.decodeV1(groups.encodedV1()) == groups)
    #expect(groups.actions[2].action.affected[0].after == .deleted(f.operations[3].id))
}

@Test func wholePayloadHasNoPartiallyDecodedSuccess() throws {
    var bytes = try literal(payloadHex)
    // Damage only the final action's after-state index, after two valid operations.
    bytes[bytes.count - 1] = 0xff
    #expect(throws: CanonicalEncodingError.invalidReference) { try ChangesPayloadV1.decodeV1(bytes) }
    let f = try PayloadFixture()
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try ChangesPayloadV1(dependencies: f.table, operations: Array(f.records.prefix(2)), actions: [])
    }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try ChangesPayloadV1(dependencies: f.table, operations: [f.records[0]], actions: [f.action(0)])
    }
    #expect(throws: CanonicalEncodingError.invalidPayload) {
        try ChangesPayloadV1(dependencies: f.table, operations: [f.records[0], f.records[0]], actions: [])
    }
}

@Test(arguments: [(32, UInt8(2)), (33, 2), (38, 0xff), (67, 3), (68, 3)])
func actionUnknownDiscriminants(offset: Int, value: UInt8) throws {
    let f = try PayloadFixture()
    var bytes = try literal(actionHex)
    bytes[offset] = value
    #expect(throws: CanonicalEncodingError.self) {
        try ActionRecordV1.decodeV1(bytes, dependencies: f.table, operations: f.operations, earlierActions: [])
    }
}

@Test func actionBoundsAndContextAreChecked() throws {
    let f = try PayloadFixture()
    for offset in [34, 39, 47] { // Scope parents, members, affected births.
        var bytes = try literal(actionHex)
        bytes.replaceSubrange(offset..<(offset + 4), with: [255, 255, 255, 255])
        #expect(throws: CanonicalEncodingError.truncated) {
            try ActionRecordV1.decodeV1(bytes, dependencies: f.table, operations: f.operations, earlierActions: [])
        }
    }
    #expect(throws: CanonicalEncodingError.invalidAction) { try f.action(0, members: [OperationIndex(1), OperationIndex(1)]) }
    #expect(throws: CanonicalEncodingError.invalidReference) { try f.action(0, members: [OperationIndex(UInt32.max)]) }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try f.action(0).encodedV1(dependencies: f.table, operations: Array(f.operations.reversed()), earlierActions: [])
    }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try f.action(1, previous: .earlierLocal(index: ActionIndex(0)))
    }
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try f.action(1, parents: [.earlierLocal(index: ActionIndex(0)), .earlierLocal(index: ActionIndex(0))], earlier: [f.action(0).action])
    }
}

@Test func actionMembershipAndStateClaimsMustAgree() throws {
    let f = try PayloadFixture()
    let a = try f.action(0)
    let c = try f.action(2)
    let bad = try [
        f.action(1, members: [OperationIndex(1)]), // Another action's member.
        f.action(1, before: .freshBirthAbsence),
        f.action(1, before: .value(.earlierLocal(index: OperationIndex(2)))), // Own result as before-state.
        f.action(1, before: .deleted(.earlierLocal(index: OperationIndex(1)))), // Create is not Delete.
        f.action(1, after: .value(.earlierLocal(index: OperationIndex(1)))), // Not a member result.
        f.action(1, after: .deleted(.earlierLocal(index: OperationIndex(2)))), // Put is not Delete.
        f.action(1, scope: .note(NoteBirth(bytes: Array(repeating: 9, count: 16))))]
    for b in bad {
        #expect(throws: CanonicalEncodingError.invalidAction) {
            try ChangesPayloadV1(dependencies: f.table, operations: f.records, actions: [a, b, c])
        }
    }
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try ChangesPayloadV1(dependencies: f.table, operations: f.records, actions: [a, f.action(1), c, c])
    }
}

@Test func actionParentsAreCanonicalButMembersKeepTheirOrder() throws {
    let f = try PayloadFixture()
    let a = try f.action(0), b = try f.action(1)
    // Allocated IDs put b before a, although b occupies the later section index.
    let c = try f.action(2, members: [OperationIndex(3), OperationIndex(2)],
        parents: [.earlierLocal(index: ActionIndex(0)), .earlierLocal(index: ActionIndex(1))], earlier: [a.action, b.action])
    #expect(c.scopeReferences == [.earlierLocal(index: ActionIndex(1)), .earlierLocal(index: ActionIndex(0))])
    #expect(c.memberIndices == [OperationIndex(3), OperationIndex(2)])
    var wire = try c.encodedV1(dependencies: f.table, operations: f.operations, earlierActions: [a.action, b.action])
    wire.replaceSubrange(38..<48, with: [1, 0, 0, 0, 0, 1, 0, 0, 0, 1])
    #expect(throws: CanonicalEncodingError.noncanonicalSet) {
        try ActionRecordV1.decodeV1(wire, dependencies: f.table, operations: f.operations, earlierActions: [a.action, b.action])
    }
// Group validation rejects the extra member because it belongs to b.
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try ChangesPayloadV1(dependencies: f.table, operations: f.records, actions: [a, b, c])
    }
}

@Test func completeMultiBirthGroupAndAffectedOrdering() throws {
    let f = try PayloadFixture()
    guard case .create(_, _, let value) = f.operations[1].effect else { Issue.record("fixture kind"); return }
    let secondBirth = try NoteBirth(bytes: Array(repeating: 0x70, count: 16))
    let second = try IdentifiedOperation(nonce: f.operations[1].nonce,
        effect: .create(action: f.ids[0], birth: secondBirth, value: value),
        causalParents: f.operations[1].causalParents, notePredecessors: NotePredecessorSet([]))
    let records = try Array(f.records.prefix(2)) + [OperationRecordV1(operation: second,
        causalReferences: [.earlierLocal(index: OperationIndex(0))], noteReferences: [], earlierOperations: f.operations)]
    let firstEntry = ActionAffectedReference(birth: f.birth, before: .freshBirthAbsence, after: .value(.earlierLocal(index: OperationIndex(1))))
    let secondEntry = ActionAffectedReference(birth: secondBirth, before: .freshBirthAbsence, after: .value(.earlierLocal(index: OperationIndex(2))))
    func action(_ affected: [ActionAffectedReference]) throws -> ActionRecordV1 {
        try ActionRecordV1(id: f.ids[0], origin: f.origin, previousOrigin: nil, scope: .collection, scopeParents: [],
            kind: .createImportBatch, members: [OperationIndex(2), OperationIndex(1)], affected: affected,
            operations: records.map(\.operation), earlierActions: [])
    }
    let group = try action([secondEntry, firstEntry])
    let payload = try ChangesPayloadV1(dependencies: f.table, operations: records, actions: [group])
    #expect(try ChangesPayloadV1.decodeV1(payload.encodedV1()) == payload)
    #expect(group.action.members == [second.id, f.operations[1].id])
    #expect(group.affectedReferences == [firstEntry, secondEntry])
    #expect(throws: CanonicalEncodingError.invalidAction) { try action([firstEntry, firstEntry]) }
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try ChangesPayloadV1(dependencies: f.table, operations: records, actions: [action([firstEntry])])
    }
    #expect(throws: CanonicalEncodingError.invalidAction) {
        let wrongBirth = ActionAffectedReference(birth: f.birth, before: .freshBirthAbsence, after: secondEntry.after)
        _ = try ChangesPayloadV1(dependencies: f.table, operations: records, actions: [action([wrongBirth, secondEntry])])
    }
    var bytes = try group.encodedV1(dependencies: f.table, operations: records.map(\.operation), earlierActions: [])
    bytes.replaceSubrange(55..<101, with: Array(bytes[78..<101]) + Array(bytes[55..<78]))
    #expect(throws: CanonicalEncodingError.noncanonicalSet) {
        try ActionRecordV1.decodeV1(bytes, dependencies: f.table, operations: records.map(\.operation), earlierActions: [])
    }
}

@Test func localActionEdgesCheckOriginAndScopeIndependently() throws {
    let f = try PayloadFixture()
    let a = try f.action(0, scope: .note(f.birth))
    let b = try f.action(1, parents: [.earlierLocal(index: ActionIndex(0))], earlier: [a.action])
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try ChangesPayloadV1(dependencies: f.table, operations: f.records, actions: [a, b, f.action(2)])
    }
    let otherOrigin = try ActionOriginID(bytes: Array(repeating: 0x60, count: 16))
    let c = try f.action(1, previous: .earlierLocal(index: ActionIndex(0)), origin: otherOrigin, earlier: [a.action])
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try ChangesPayloadV1(dependencies: f.table, operations: f.records, actions: [a, c, f.action(2)])
    }
}

@Test func payloadLimitIncludesFramingAndWholeGroup() throws {
    let f = try PayloadFixture()
    let value = try PlaintextNoteValue(title: ExactUTF8(bytes: []),
        body: ExactUTF8(bytes: Array(repeating: 65, count: Int(ObjectLimitsV1.decodedPayloadBytes) - 200)),
        labels: CanonicalLabels([]), created: DisplayDate(secondsSinceReferenceDate: 0),
        modified: DisplayDate(secondsSinceReferenceDate: 0))
    let op = try IdentifiedOperation(nonce: f.operations[1].nonce, effect: .create(action: f.ids[0], birth: f.birth, value: value),
        causalParents: f.operations[1].causalParents, notePredecessors: NotePredecessorSet([]))
    let record = try OperationRecordV1(operation: op, causalReferences: [.earlierLocal(index: OperationIndex(0))],
        noteReferences: [], earlierOperations: [f.operations[0]])
    let action = try ActionRecordV1(id: f.ids[0], origin: f.origin, previousOrigin: nil, scope: .collection,
        scopeParents: [], kind: .createImportBatch, members: [OperationIndex(1)], affected: f.action(0).affectedReferences,
        operations: [f.operations[0], op], earlierActions: [])
// Enforce the aggregate payload ceiling even when each record fits individually.
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try ChangesPayloadV1(dependencies: f.table, operations: [f.records[0], record], actions: [action])
    }
}

private func address(_ byte: UInt8) throws -> SegmentLocator {
    try SegmentLocator(writerEpoch: WriterEpoch(bytes: Array(repeating: byte, count: 16)), sequence: UInt64.max,
        segmentID: SegmentID(bytes: Array(repeating: byte, count: 32)))
}

// Remap the same claims to another exact locator/index without changing logical IDs.
private func externalEdit(_ f: PayloadFixture, at locator: SegmentLocator,
                          operationIndex: UInt32 = 1, actionIndex: UInt32 = 0) throws -> ChangesPayloadV1 {
    let table = try DependencyLocatorTable([locator])
    let before = OperationReference.external(locator: locator, index: OperationIndex(operationIndex), expectedID: f.operations[1].id)
    let op = try OperationRecordV1(operation: f.operations[2], causalReferences: [before], noteReferences: [before], earlierOperations: [])
    let previous = ActionReference.external(locator: locator, index: ActionIndex(actionIndex), expectedID: f.ids[0])
    let action = try ActionRecordV1(id: f.ids[1], origin: f.origin, previousOrigin: previous, scope: .collection,
        scopeParents: [previous], kind: .savedEdit, members: [OperationIndex(0)],
        affected: [ActionAffectedReference(birth: f.birth, before: .value(before), after: .value(.earlierLocal(index: OperationIndex(0))))],
        operations: [op.operation], earlierActions: [])
    return try ChangesPayloadV1(dependencies: table, operations: [op], actions: [action])
}

@Test func exactExternalLookupsAndTransportIndependentActions() throws {
    let f = try PayloadFixture()
    let base = try ChangesPayloadV1(dependencies: f.table, operations: Array(f.records.prefix(2)), actions: [f.action(0)])
    let target = try address(1), current = try address(2)
    let edit = try externalEdit(f, at: target)
    let remapped = try externalEdit(f, at: current, operationIndex: 7, actionIndex: 4)
    #expect(edit.actions[0].action == remapped.actions[0].action)
    #expect(edit.operations[0].operation == remapped.operations[0].operation)
    #expect(try edit.encodedV1() != remapped.encodedV1())
    #expect(try ChangesPayloadV1.decodeV1(edit.encodedV1()) == edit)
    var lookups: [SegmentLocator] = []
    try edit.checkExternalReferences(at: current) { locator in lookups.append(locator); return locator == target ? base : nil }
    #expect(lookups == [target])
    #expect(throws: CanonicalEncodingError.missingDependency) { try edit.checkExternalReferences(at: current) { _ in nil } }
    #expect(throws: CanonicalEncodingError.invalidReference) { try edit.checkExternalReferences(at: target) { _ in base } }
    #expect(throws: CanonicalEncodingError.identityMismatch) {
        try externalEdit(f, at: target, operationIndex: 0).checkExternalReferences(at: current) { _ in base }
    }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try externalEdit(f, at: target, operationIndex: 99).checkExternalReferences(at: current) { _ in base }
    }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try externalEdit(f, at: target, actionIndex: 1).checkExternalReferences(at: current) { _ in base }
    }
    #expect(throws: CanonicalEncodingError.identityMismatch) {
        try externalEdit(f, at: target, actionIndex: 1).checkExternalReferences(at: current) { _ in try f.payload() }
    }
    enum ReadFailure: Error { case denied }
    #expect(throws: ReadFailure.denied) {
        try edit.checkExternalReferences(at: current) { _ in throw ReadFailure.denied }
    }
    #expect(throws: CanonicalEncodingError.invalidAction) {
        let differentScope = try ChangesPayloadV1(dependencies: f.table, operations: Array(f.records.prefix(2)), actions: [f.action(0, scope: .note(f.birth))])
        try edit.checkExternalReferences(at: current) { _ in differentScope }
    }
    #expect(throws: CanonicalEncodingError.invalidAction) {
        let differentOrigin = try ChangesPayloadV1(dependencies: f.table, operations: Array(f.records.prefix(2)),
            actions: [f.action(0, origin: ActionOriginID(bytes: Array(repeating: 8, count: 16)))])
        try edit.checkExternalReferences(at: current) { _ in differentOrigin }
    }
}

@Test func framingDoesNotCertifyHistory() throws {
    let f = try PayloadFixture()
// This framed Put claims Genesis as a value predecessor; direct target
    // checking must reject that incompatible predecessor type.
    let op = try IdentifiedOperation(nonce: f.operations[2].nonce, effect: f.operations[2].effect,
        causalParents: CausalParentSet([f.operations[0].id]), notePredecessors: NotePredecessorSet([f.operations[0].id]))
    let record = try OperationRecordV1(operation: op, causalReferences: [.earlierLocal(index: OperationIndex(0))],
        noteReferences: [.earlierLocal(index: OperationIndex(0))], earlierOperations: [f.operations[0]])
    let target = try address(1)
    let before = OperationReference.external(locator: target, index: OperationIndex(1), expectedID: f.operations[1].id)
    let action = try ActionRecordV1(id: f.ids[1], origin: f.origin, previousOrigin: nil, scope: .collection,
        scopeParents: [], kind: .savedEdit, members: [OperationIndex(1)], affected: [ActionAffectedReference(birth: f.birth,
            before: .value(before), after: .value(.earlierLocal(index: OperationIndex(1))))],
        operations: [f.operations[0], op], earlierActions: [])
    let framed = try ChangesPayloadV1(dependencies: DependencyLocatorTable([target]), operations: [f.records[0], record], actions: [action])
    #expect(try ChangesPayloadV1.decodeV1(framed.encodedV1()) == framed)
    #expect(throws: CanonicalEncodingError.invalidAction) { try framed.checkExternalReferences(at: address(2)) { _ in nil } }
// The framed payload reaches reference validation, which rejects its invalid history claim.
}
