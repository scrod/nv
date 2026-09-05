import NVStorageCore
import Testing

// Independent operation-identity fixtures calculated from the first-save field
// table with Python hashlib.sha256/struct.pack('>I/Q/d'), using declared parent IDs.
private let goldenOperationIDs = [
    "0984aace16fc3b80c587eba41b70b3813d56f2edd4005b838c67e2d0126add5d",
    "c0d638688e365c161bb45a5ececf355dd6f0409b2f0db302bd4a0547ad3e67fe",
    "04f9b10ee761942756a1d9723c2cd451eaa9b21273e678d656f530f0eb72f0e2",
    "459517c559edf4a7df470788b29e677bdc5df12ababd4233148c15ac73afa75e",
    "2f22b73653158292e65186495086e1667812f0fd03f772ab25e8a1cd5d81d96a",
    "2ee4818e504e53f562739966d5547e8ca3ccca39fa9030c2c4d7f04d71a0b38a"
]
private let valueHex = "01000000014100000002620a0000000200000004576f726b00000004776f726b00000000000000003ff0000000000000"

private func hexBytes(_ hex: String) throws -> [UInt8] {
    let chars = Array(hex)
    #expect(chars.count % 2 == 0)
    return try stride(from: 0, to: chars.count, by: 2).map {
        try #require(UInt8(String(chars[$0...($0 + 1)]), radix: 16))
    }
}

private struct OperationFixture {
    let nonce = try! OperationNonce(bytes: Array(1...16))
    let action = try! ActionID(bytes: Array(17...32))
    let birth = try! NoteBirth(bytes: Array(33...48))
    let importID = try! ImportID(bytes: Array(49...64))
    let first = try! OperationID(bytes: Array(repeating: 0x51, count: 32))
    let second = try! OperationID(bytes: Array(repeating: 0x52, count: 32))
    let initialDigest = try! InitialValuesDigest(bytes: Array(repeating: 0x61, count: 32))
    let locator = try! SegmentLocator(writerEpoch: WriterEpoch(bytes: Array(repeating: 0x71, count: 16)),
        sequence: 0x0102030405060708, segmentID: SegmentID(bytes: Array(repeating: 0x81, count: 32)))
    let value = try! PlaintextNoteValue(title: ExactUTF8(bytes: [0x41]), body: ExactUTF8(bytes: [0x62, 10]),
        labels: CanonicalLabels([ExactUTF8(bytes: Array("work".utf8)), ExactUTF8(bytes: Array("Work".utf8))]),
        created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 1))

    func operation(_ kind: Int) throws -> IdentifiedOperation {
        let effect: OperationEffectV1
        switch kind {
        case 1: effect = .genesis(importID: importID, profile: .plaintextFiles, initialCount: 2, initialValuesDigest: initialDigest)
        case 2: effect = .importComplete(importID: importID, initialCount: 2, initialValuesDigest: initialDigest)
        case 3: effect = .create(action: action, birth: birth, value: value)
        case 4: effect = .importNote(action: action, birth: birth, value: value)
        case 5: effect = .put(action: action, birth: birth, value: value)
        default: effect = .delete(action: action, birth: birth)
        }
        return try IdentifiedOperation(nonce: nonce, effect: effect,
            causalParents: CausalParentSet(kind == 1 ? [] : [second, first]),
            notePredecessors: NotePredecessorSet(kind == 5 ? [first] : []))
    }

    func record(_ kind: Int) throws -> OperationRecordV1 {
        let firstRef = OperationReference.external(locator: locator, index: OperationIndex(7), expectedID: first)
        let secondRef = OperationReference.external(locator: locator, index: OperationIndex(8), expectedID: second)
        return try OperationRecordV1(operation: operation(kind),
            causalReferences: kind == 1 ? [] : [secondRef, firstRef],
            noteReferences: kind == 5 ? [firstRef] : [], earlierOperations: [])
    }

    func expected(_ kind: Int) throws -> (preimage: [UInt8], record: [UInt8]) {
        let header = try hexBytes("0102030405060708090a0b0c0d0e0f10") + [UInt8(kind)]
            + (kind < 3 ? [0, 0] : hexBytes("011112131415161718191a1b1c1d1e1f20012122232425262728292a2b2c2d2e2f30"))
        let p1 = Array(repeating: UInt8(0x51), count: 32)
        let p2 = Array(repeating: UInt8(0x52), count: 32)
        let semanticParents: [UInt8] = kind == 1 ? [0, 0, 0, 0] : [0, 0, 0, 2] + p1 + p2
        let semanticPredecessors: [UInt8] = kind == 5 ? [0, 0, 0, 1] + p1 : [0, 0, 0, 0]
        let ref1: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 7] + p1
        let ref2: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 8] + p2
        let wireParents: [UInt8] = kind == 1 ? [0, 0, 0, 0] : [0, 0, 0, 2] + ref1 + ref2
        let wirePredecessors: [UInt8] = kind == 5 ? [0, 0, 0, 1] + ref1 : [0, 0, 0, 0]
        let payload: [UInt8]
        switch kind {
        case 1: payload = try hexBytes("0000003d3132333435363738393a3b3c3d3e3f4001000100010000000000000002") + Array(repeating: 0x61, count: 32)
        case 2: payload = try hexBytes("000000383132333435363738393a3b3c3d3e3f400000000000000002") + Array(repeating: 0x61, count: 32)
        case 6: payload = [0, 0, 0, 0]
        default: payload = try [0, 0, 0, 48] + hexBytes(valueHex)
        }
        return try (hexBytes("4e56206f7065726174696f6e00763100") + header + semanticParents + semanticPredecessors + payload,
                    hexBytes(goldenOperationIDs[kind - 1]) + header + wireParents + wirePredecessors + payload)
    }
}

@Test(arguments: Array(1...6))
func literalOperationVectors(kind: Int) throws {
    let fixture = OperationFixture()
    let record = try fixture.record(kind)
    let expected = try fixture.expected(kind)
    let table = try DependencyLocatorTable([fixture.locator])
    #expect(record.operation.id.bytes == (try hexBytes(goldenOperationIDs[kind - 1])))
    #expect(record.operation.identityPreimageV1() == expected.preimage)
    #expect(try record.encodedV1(dependencies: table, earlierOperations: []) == expected.record)
    #expect(try OperationRecordV1.decodeV1(expected.record, dependencies: table, earlierOperations: []) == record)
    // Every truncation must fail; the error can be either framing or field validation.
    for cut in 0..<expected.record.count {
        #expect(throws: CanonicalEncodingError.self) {
            try OperationRecordV1.decodeV1(Array(expected.record.prefix(cut)), dependencies: table, earlierOperations: [])
        }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) {
        try OperationRecordV1.decodeV1(expected.record + [0], dependencies: table, earlierOperations: [])
    }
    var prefixed = [UInt8](repeating: 0xff, count: 3) + expected.record
    let decoded = try OperationRecordV1.decodeV1(Array(prefixed.dropFirst(3)), dependencies: table, earlierOperations: [])
    prefixed[3] ^= 1
    #expect(decoded == record) // Caller buffer is not retained as a mutable view.
}

@Test func valueDigestIncludesExactSpellingAndDates() throws {
    let fixture = OperationFixture()
    #expect(try fixture.value.digestV1().bytes == hexBytes("c15a9c3d4e6a230d1f34aa5bf514038087bf8ae4e19de469bdeb7c3358d2511b"))
    let dateOnly = try PlaintextNoteValue(title: fixture.value.title, body: fixture.value.body,
        labels: fixture.value.labels, created: fixture.value.created, modified: DisplayDate(secondsSinceReferenceDate: 2))
    #expect(dateOnly.hasSameEditableFields(as: fixture.value))
    #expect(try dateOnly.digestV1() != fixture.value.digestV1())
}

@Test func everyPutFieldParticipatesInIdentity() throws {
    let f = OperationFixture()
    let original = try f.operation(5)
    var variants: [IdentifiedOperation] = []
    func add(nonce: OperationNonce? = nil, effect: OperationEffectV1? = nil,
             parents: [OperationID]? = nil, predecessors: [OperationID]? = nil) throws {
        variants.append(try IdentifiedOperation(nonce: nonce ?? f.nonce, effect: effect ?? original.effect,
            causalParents: CausalParentSet(parents ?? [f.first, f.second]),
            notePredecessors: NotePredecessorSet(predecessors ?? [f.first])))
    }
    try add(nonce: OperationNonce(bytes: Array(repeating: 9, count: 16)))
    try add(effect: .put(action: ActionID(bytes: Array(repeating: 9, count: 16)), birth: f.birth, value: f.value))
    try add(effect: .put(action: f.action, birth: NoteBirth(bytes: Array(repeating: 9, count: 16)), value: f.value))
    try add(parents: [f.first])
    try add(predecessors: [f.second])
    try add(predecessors: [f.first, f.second])
    for field in 0..<5 {
        let value = try PlaintextNoteValue(title: field == 0 ? ExactUTF8(bytes: [0x42]) : f.value.title,
            body: field == 1 ? ExactUTF8(bytes: [0x63]) : f.value.body,
            labels: field == 2 ? CanonicalLabels([ExactUTF8(bytes: [0x58])]) : f.value.labels,
            created: field == 3 ? DisplayDate(secondsSinceReferenceDate: -1) : f.value.created,
            modified: field == 4 ? DisplayDate(secondsSinceReferenceDate: 2) : f.value.modified)
        try add(effect: .put(action: f.action, birth: f.birth, value: value))
    }
    for variant in variants { #expect(variant.id != original.id) }
    #expect(Set(variants.map(\.id)).count == variants.count)
    #expect(original.causalParents.ids == [f.first, f.second])
    #expect(original.notePredecessors.ids == [f.first]) // Knowing B does not replace B.
    #expect(try CausalParentSet([f.second, f.first]) == CausalParentSet([f.first, f.second]))
}

@Test func intrinsicRulesRejectInvalidOperations() throws {
    let f = OperationFixture()
    let emptyParents = try CausalParentSet([])
    let emptyPredecessors = try NotePredecessorSet([])
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try CausalParentSet([f.first, f.first]) }
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try NotePredecessorSet([f.first, f.first]) }
    for kind in 2...6 {
        #expect(throws: CanonicalEncodingError.invalidOperation) {
            try IdentifiedOperation(nonce: f.nonce, effect: f.operation(kind).effect,
                causalParents: emptyParents, notePredecessors: emptyPredecessors)
        }
    }
    for kind in [1, 2, 3, 4, 6] {
        #expect(throws: CanonicalEncodingError.invalidOperation) {
            try IdentifiedOperation(nonce: f.nonce, effect: f.operation(kind).effect,
                causalParents: f.operation(kind).causalParents, notePredecessors: NotePredecessorSet([f.first]))
        }
    }
    #expect(throws: CanonicalEncodingError.invalidOperation) {
        try IdentifiedOperation(nonce: f.nonce, effect: f.operation(5).effect,
            causalParents: CausalParentSet([f.first]), notePredecessors: emptyPredecessors)
    }
    #expect(throws: CanonicalEncodingError.invalidOperation) {
        try IdentifiedOperation(nonce: f.nonce, effect: f.operation(1).effect,
            causalParents: CausalParentSet([f.first]), notePredecessors: emptyPredecessors)
    }
}

@Test func bootstrapFieldsParticipateInIdentity() throws {
    let f = OperationFixture()
    for kind in [1, 2] {
        let original = try f.operation(kind)
        let changedImport = try ImportID(bytes: Array(repeating: 3, count: 16))
        let changedDigest = try InitialValuesDigest(bytes: Array(repeating: 4, count: 32))
        for (importID, count, digest) in [(changedImport, UInt64(2), f.initialDigest),
                                         (f.importID, UInt64.max, f.initialDigest),
                                         (f.importID, UInt64(2), changedDigest)] {
            let effect: OperationEffectV1 = kind == 1
                ? .genesis(importID: importID, profile: .plaintextFiles, initialCount: count, initialValuesDigest: digest)
                : .importComplete(importID: importID, initialCount: count, initialValuesDigest: digest)
            let changed = try IdentifiedOperation(nonce: f.nonce, effect: effect,
                causalParents: original.causalParents, notePredecessors: original.notePredecessors)
            #expect(changed.id != original.id)
        }
    }
    let encrypted = try IdentifiedOperation(nonce: f.nonce,
        effect: .genesis(importID: f.importID, profile: .encryptedSegments, initialCount: 2, initialValuesDigest: f.initialDigest),
        causalParents: CausalParentSet([]), notePredecessors: NotePredecessorSet([]))
    #expect(try encrypted.id != f.operation(1).id)
    let record = try OperationRecordV1(operation: encrypted, causalReferences: [], noteReferences: [], earlierOperations: [])
    let table = try DependencyLocatorTable([])
    #expect(try OperationRecordV1.decodeV1(record.encodedV1(dependencies: table, earlierOperations: []),
        dependencies: table, earlierOperations: []).operation == encrypted)
}

@Test func operationLimitCountsTransportOverheadBeforeEncoding() throws {
    let f = OperationFixture()
    let table = try DependencyLocatorTable([f.locator])
    let external = OperationReference.external(locator: f.locator, index: OperationIndex(7), expectedID: f.first)
    // One external-parent Create: 136 record bytes + 29 empty-value overhead.
// Literal independently calculated totals check the production sizing function.
    for count in [67_108_698, 67_108_699, 67_108_700] {
        let value = try PlaintextNoteValue(title: ExactUTF8(bytes: []),
            body: ExactUTF8(bytes: Array(repeating: 0x61, count: count)), labels: CanonicalLabels([]),
            created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 0))
        let op = try IdentifiedOperation(nonce: f.nonce, effect: .create(action: f.action, birth: f.birth, value: value),
            causalParents: CausalParentSet([f.first]), notePredecessors: NotePredecessorSet([]))
        if count == 67_108_700 {
            #expect(throws: CanonicalEncodingError.lengthLimit) {
                try OperationRecordV1(operation: op, causalReferences: [external], noteReferences: [], earlierOperations: [])
            }
        } else {
            let record = try OperationRecordV1(operation: op, causalReferences: [external], noteReferences: [], earlierOperations: [])
            let bytes = try record.encodedV1(dependencies: table, earlierOperations: [])
            #expect(bytes.count == count + 165)
            #expect(try OperationRecordV1.decodeV1(bytes, dependencies: table, earlierOperations: []).operation == op)
        }
    }
// Check the operation-size ceiling with a value whose wrapper pushes it over the limit.
    let value = try PlaintextNoteValue(title: ExactUTF8(bytes: []),
        body: ExactUTF8(bytes: Array(repeating: 0x61, count: 67_108_835)), labels: CanonicalLabels([]),
        created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 0))
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try IdentifiedOperation(nonce: f.nonce, effect: .create(action: f.action, birth: f.birth, value: value),
            causalParents: CausalParentSet([f.first]), notePredecessors: NotePredecessorSet([]))
    }
}

@Test func malformedOperationRecordsAreNotRepairedByDecoding() throws {
    let f = OperationFixture()
    let table = try DependencyLocatorTable([f.locator])
    let bytes = try f.expected(5).record
    let mutations: [(Int, [UInt8], CanonicalEncodingError)] = [
        (0, [0xff], .identityMismatch), (16, [0xff], .identityMismatch),
        (32, [0xff], .identityMismatch), (48, [0xff], .unsupportedFormat),
        (49, [2], .invalidDiscriminant), (50, [0xff], .identityMismatch),
        (66, [2], .invalidDiscriminant), (67, [0xff], .identityMismatch),
        (83, [0xff, 0xff, 0xff, 0xff], .truncated), (87, [2], .invalidDiscriminant),
        (88, [0xff, 0xff, 0xff, 0xff], .invalidReference), (96, [0x50], .identityMismatch),
        (214, [0xff, 0xff, 0xff, 0xff], .lengthLimit), (223, [0x42], .identityMismatch)
    ]
    for (offset, replacement, error) in mutations {
        var changed = bytes
        changed.replaceSubrange(offset..<(offset + replacement.count), with: replacement)
        #expect(throws: error) { try OperationRecordV1.decodeV1(changed, dependencies: table, earlierOperations: []) }
    }
    for replacements in [[Array(bytes[128..<169]), Array(bytes[87..<128])],
                         [Array(bytes[87..<128]), Array(bytes[87..<128])]] {
        var changed = bytes
        changed.replaceSubrange(87..<169, with: replacements.flatMap { $0 })
        #expect(throws: CanonicalEncodingError.noncanonicalSet) {
            try OperationRecordV1.decodeV1(changed, dependencies: table, earlierOperations: [])
        }
    }
    var genesis = try f.expected(1).record
    for offset in [79, 81, 83] { // Unknown profile, note codec or merge-policy version.
        var changed = genesis
        changed[offset] = 9
        #expect(throws: CanonicalEncodingError.unsupportedFormat) {
            try OperationRecordV1.decodeV1(changed, dependencies: table, earlierOperations: [])
        }
    }
    genesis.replaceSubrange(32..<48, with: Array(repeating: 0, count: 16))
    #expect(throws: CanonicalEncodingError.invalidIdentifier) {
        try OperationRecordV1.decodeV1(genesis, dependencies: table, earlierOperations: [])
    }
}

@Test func transportRemappingDoesNotChangeSemanticIdentity() throws {
    let f = OperationFixture()
    let parent = try f.operation(1)
    let child = try IdentifiedOperation(nonce: f.nonce, effect: .create(action: f.action, birth: f.birth, value: f.value),
        causalParents: CausalParentSet([parent.id]), notePredecessors: NotePredecessorSet([]))
    let local = try OperationRecordV1(operation: child, causalReferences: [.earlierLocal(index: OperationIndex(0))],
        noteReferences: [], earlierOperations: [parent])
    let emptyTable = try DependencyLocatorTable([])
    let localBytes = try local.encodedV1(dependencies: emptyTable, earlierOperations: [parent])
    #expect(try OperationRecordV1.decodeV1(localBytes, dependencies: emptyTable, earlierOperations: [parent]).operation == child)
    for sequence in [UInt64(0), 1, UInt64.max] {
        let other = try SegmentLocator(writerEpoch: WriterEpoch(bytes: Array(repeating: 0x72, count: 16)),
            sequence: sequence, segmentID: SegmentID(bytes: Array(repeating: 0x82, count: 32)))
        let external = OperationReference.external(locator: other, index: OperationIndex(UInt32.max), expectedID: parent.id)
        let record = try OperationRecordV1(operation: child, causalReferences: [external], noteReferences: [], earlierOperations: [])
        for locators in [[other], [other, f.locator]] { // Same reference moves from table slot 0 to 1.
            let table = try DependencyLocatorTable(locators)
            let bytes = try record.encodedV1(dependencies: table, earlierOperations: [])
            #expect(bytes != localBytes)
            let decoded = try OperationRecordV1.decodeV1(bytes, dependencies: table, earlierOperations: [])
            #expect(decoded.operation == child)
            #expect(decoded.causalReferences == [external]) // Exact, still-unverified locator/index survives.
        }
    }
    for prefix in [[IdentifiedOperation](), [try f.operation(2)]] {
        #expect(throws: CanonicalEncodingError.self) {
            try local.encodedV1(dependencies: emptyTable, earlierOperations: prefix)
        }
        #expect(throws: CanonicalEncodingError.self) {
            try OperationRecordV1.decodeV1(localBytes, dependencies: emptyTable, earlierOperations: prefix)
        }
    }
    for index in [UInt32(1), UInt32.max] { // Self/forward/out-of-bounds index.
        #expect(throws: CanonicalEncodingError.invalidReference) {
            try OperationRecordV1(operation: child, causalReferences: [.earlierLocal(index: OperationIndex(index))],
                noteReferences: [], earlierOperations: [parent])
        }
    }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try f.record(5).encodedV1(dependencies: emptyTable, earlierOperations: [])
    }
}

@Test func locatorTableHasLiteralWidthsOrderAndBounds() throws {
    let f = OperationFixture()
    let literal = try hexBytes(String(repeating: "71", count: 16) + "0102030405060708" + String(repeating: "81", count: 32))
    #expect(literal.count == 56)
    #expect(f.locator.encodedV1() == literal)
    #expect(try SegmentLocator.decodeV1(literal) == f.locator)
    for cut in 0..<56 {
        #expect(throws: CanonicalEncodingError.truncated) { try SegmentLocator.decodeV1(Array(literal.prefix(cut))) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try SegmentLocator.decodeV1(literal + [0]) }
    #expect(try DependencyLocatorTable([f.locator]).encodedV1() == [0, 0, 0, 1] + literal)
    #expect(try DependencyLocatorTable.decodeV1([0, 0, 0, 1] + literal).entries == [f.locator])
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try DependencyLocatorTable([f.locator, f.locator]) }
    #expect(throws: CanonicalEncodingError.noncanonicalSet) {
        try DependencyLocatorTable.decodeV1([0, 0, 0, 2] + literal + literal)
    }
    #expect(throws: CanonicalEncodingError.truncated) { try DependencyLocatorTable.decodeV1([0xff, 0xff, 0xff, 0xff]) }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try DependencyLocatorTable.decodeV1([0, 0, 0, 0, 0]) }
    for count in [0, 15, 17, 31, 33] {
        #expect(throws: CanonicalEncodingError.invalidIdentifier) { try OperationID(bytes: Array(repeating: 1, count: count)) }
    }
    #expect(throws: CanonicalEncodingError.invalidIdentifier) { try ActionID(bytes: Array(repeating: 0, count: 16)) }
    #expect(throws: CanonicalEncodingError.invalidIdentifier) { try OperationID(bytes: Array(repeating: 0, count: 32)) }
}
