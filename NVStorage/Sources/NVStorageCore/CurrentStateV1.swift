/// Full operation occurrence used by private current-state records.
public struct StoredOperationReferenceV1: Equatable, Hashable, Sendable {
    public let locator: SegmentLocator
    public let index: OperationIndex
    public let id: OperationID
    public init(locator: SegmentLocator, index: OperationIndex, id: OperationID) {
        self.locator = locator; self.index = index; self.id = id
    }
    public var reference: OperationReference { .external(locator: locator, index: index, expectedID: id) }
    func encoded() -> [UInt8] { locator.encodedV1() + bigEndianBytes(index.rawValue) + id.bytes }
    static func decode(_ c: inout ByteCursor) throws -> Self {
        try Self(locator: SegmentLocator.decode(&c), index: OperationIndex(c.unsigned32()), id: OperationID(bytes: c.fixedBytes(32)))
    }
}

/// Full action occurrence used by private authoring frontiers.
public struct StoredActionReferenceV1: Equatable, Hashable, Sendable {
    public let locator: SegmentLocator
    public let index: ActionIndex
    public let id: ActionID
    public init(locator: SegmentLocator, index: ActionIndex, id: ActionID) {
        self.locator = locator; self.index = index; self.id = id
    }
    public var reference: ActionReference { .external(locator: locator, index: index, expectedID: id) }
    func encoded() -> [UInt8] { locator.encodedV1() + bigEndianBytes(index.rawValue) + id.bytes }
    static func decode(_ c: inout ByteCursor) throws -> Self {
        try Self(locator: SegmentLocator.decode(&c), index: ActionIndex(c.unsigned32()), id: ActionID(bytes: c.fixedBytes(16)))
    }
}

func checkedActions(_ refs: [StoredActionReferenceV1]) throws -> [StoredActionReferenceV1] {
    guard UInt64(refs.count) <= ObjectLimitsV1.decodedPayloadBytes / 76 else { throw CanonicalEncodingError.lengthLimit }
    let sorted = refs.sorted { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) }
    guard Set(sorted.map(\.id)).count == sorted.count else { throw CanonicalEncodingError.noncanonicalSet }
    return sorted
}

/// Uncompressed current value and exact editing references for a single-valued birth.
public struct CurrentNoteCellV1: Equatable, Sendable {
    public let birth: NoteBirth
    public let value: PlaintextNoteValue
    public let revision: StoredOperationReferenceV1
    public let scopeFrontier: [StoredActionReferenceV1]
    public init(birth: NoteBirth, value: PlaintextNoteValue, revision: StoredOperationReferenceV1,
                scopeFrontier: [StoredActionReferenceV1]) throws {
        self.birth = birth; self.value = value; self.revision = revision
        self.scopeFrontier = try checkedActions(scopeFrontier)
        guard 126 + value.encodedByteCount + 76 * UInt64(scopeFrontier.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
    }
    public func encodedV1() -> [UInt8] {
        var bytes = Array("NVCEL1\r\n".utf8) + bigEndianBytes(UInt16(1)) + birth.bytes
        bytes += bigEndianBytes(UInt32(value.encodedByteCount)) + value.encodedV1() + revision.encoded()
        bytes += bigEndianBytes(UInt32(scopeFrontier.count))
        for ref in scopeFrontier { bytes += ref.encoded() }
        return bytes
    }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == Array("NVCEL1\r\n".utf8), try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        let birth = try NoteBirth(bytes: c.fixedBytes(16)), value = try PlaintextNoteValue.decodeV1(c.lengthPrefixedBytes())
        let revision = try StoredOperationReferenceV1.decode(&c), count = try c.count(minimumElementBytes: 76)
        var refs: [StoredActionReferenceV1] = []
        for _ in 0..<count { refs.append(try StoredActionReferenceV1.decode(&c)) }
        let result = try Self(birth: birth, value: value, revision: revision, scopeFrontier: refs)
        try c.requireEnd()
        guard result.scopeFrontier == refs else { throw CanonicalEncodingError.noncanonicalSet }
        return result
    }
}

/// Collection-wide causal and collection-action frontiers at a materialized prefix.
public struct AuthoringContextV1: Equatable, Sendable {
    public let operations: [StoredOperationReferenceV1]
    public let collectionActions: [StoredActionReferenceV1]
    public init(operations: [StoredOperationReferenceV1], collectionActions: [StoredActionReferenceV1]) throws {
        guard UInt64(operations.count) <= ObjectLimitsV1.decodedPayloadBytes / 92 else { throw CanonicalEncodingError.lengthLimit }
        self.operations = operations.sorted { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) }
        guard Set(operations.map(\.id)).count == operations.count else { throw CanonicalEncodingError.noncanonicalSet }
        self.collectionActions = try checkedActions(collectionActions)
        guard 18 + 92 * UInt64(operations.count) + 76 * UInt64(collectionActions.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
    }
    public func encodedV1() -> [UInt8] {
        var bytes = Array("NVCTX1\r\n".utf8) + bigEndianBytes(UInt16(1)) + bigEndianBytes(UInt32(operations.count))
        for ref in operations { bytes += ref.encoded() }
        bytes += bigEndianBytes(UInt32(collectionActions.count))
        for ref in collectionActions { bytes += ref.encoded() }
        return bytes
    }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == Array("NVCTX1\r\n".utf8), try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        var ops: [StoredOperationReferenceV1] = [], actions: [StoredActionReferenceV1] = []
        for _ in 0..<(try c.count(minimumElementBytes: 92)) { ops.append(try StoredOperationReferenceV1.decode(&c)) }
        for _ in 0..<(try c.count(minimumElementBytes: 76)) { actions.append(try StoredActionReferenceV1.decode(&c)) }
        try c.requireEnd()
        let result = try Self(operations: ops, collectionActions: actions)
        guard result.operations == ops, result.collectionActions == actions else { throw CanonicalEncodingError.noncanonicalSet }
        return result
    }
}
