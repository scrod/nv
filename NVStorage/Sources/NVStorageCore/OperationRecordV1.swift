/// Addresses an immutable envelope by writer epoch, allocation sequence and segment hash.
public struct SegmentLocator: Equatable, Hashable, Sendable {
    public let writerEpoch: WriterEpoch
    public let sequence: UInt64
    public let segmentID: SegmentID

    public init(writerEpoch: WriterEpoch, sequence: UInt64, segmentID: SegmentID) {
        self.writerEpoch = writerEpoch
        self.sequence = sequence
        self.segmentID = segmentID
    }

    public func encodedV1() -> [UInt8] {
        writerEpoch.bytes + bigEndianBytes(sequence) + segmentID.bytes
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        var cursor = ByteCursor(bytes: bytes)
        let locator = try decode(&cursor)
        try cursor.requireEnd()
        return locator
    }

    static func decode(_ cursor: inout ByteCursor) throws -> Self {
        try Self(writerEpoch: WriterEpoch(bytes: cursor.fixedBytes(16)),
                 sequence: cursor.unsigned64(), segmentID: SegmentID(bytes: cursor.fixedBytes(32)))
    }
}

public struct DependencyLocatorTable: Equatable, Sendable {
    public let entries: [SegmentLocator]
    private let indices: [SegmentLocator: UInt32]

    public init(_ entries: [SegmentLocator]) throws {
        guard UInt64(entries.count) <= (ObjectLimitsV1.decodedPayloadBytes - 4) / 56 else {
            throw CanonicalEncodingError.lengthLimit
        }
        let sorted = entries.sorted { $0.encodedV1().lexicographicallyPrecedes($1.encodedV1()) }
        var indices: [SegmentLocator: UInt32] = [:]
        for (index, locator) in sorted.enumerated() {
            guard indices.updateValue(UInt32(index), forKey: locator) == nil else {
                throw CanonicalEncodingError.noncanonicalSet
            }
        }
        self.entries = sorted
        self.indices = indices
    }

    public func encodedV1() -> [UInt8] {
        var bytes = bigEndianBytes(UInt32(entries.count))
        for entry in entries { bytes += entry.encodedV1() }
        return bytes
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        var cursor = ByteCursor(bytes: bytes)
        let result = try decode(&cursor)
        try cursor.requireEnd()
        return result
    }

    static func decode(_ cursor: inout ByteCursor) throws -> Self {
        let count = UInt64(try cursor.unsigned32())
        guard count <= UInt64(cursor.remaining / 56) else { throw CanonicalEncodingError.truncated }
        var entries: [SegmentLocator] = []
        for _ in 0..<count {
            let next = try SegmentLocator.decode(&cursor)
            if let previous = entries.last,
               !previous.encodedV1().lexicographicallyPrecedes(next.encodedV1()) {
                throw CanonicalEncodingError.noncanonicalSet
            }
            entries.append(next)
        }
        return try Self(entries)
    }

    func index(of locator: SegmentLocator) throws -> UInt32 {
        guard let index = indices[locator] else { throw CanonicalEncodingError.invalidReference }
        return index
    }
}

/// Addresses an operation by an earlier local index or an exact external locator,
/// section index and expected identity. Closure validation resolves that exact
/// external occurrence when its object becomes available.
public enum OperationReference: Equatable, Hashable, Sendable {
    case external(locator: SegmentLocator, index: OperationIndex, expectedID: OperationID)
    case earlierLocal(index: OperationIndex)

    func expandedID(earlierOperations: [IdentifiedOperation]) throws -> OperationID {
        switch self {
        case .external(_, _, let id): return id
        case .earlierLocal(let index):
            guard UInt64(index.rawValue) < UInt64(earlierOperations.count) else {
                throw CanonicalEncodingError.invalidReference
            }
            return earlierOperations[Int(index.rawValue)].id
        }
    }

    var encodedByteCount: UInt64 {
        switch self { case .external: 41; case .earlierLocal: 5 }
    }

    func encoded(dependencies: DependencyLocatorTable) throws -> [UInt8] {
        switch self {
        case .external(let locator, let index, let id):
            return try [0] + bigEndianBytes(dependencies.index(of: locator))
                + bigEndianBytes(index.rawValue) + id.bytes
        case .earlierLocal(let index): return [1] + bigEndianBytes(index.rawValue)
        }
    }

    static func decode(_ cursor: inout ByteCursor, dependencies: DependencyLocatorTable) throws -> Self {
        switch try cursor.byte() {
        case 0:
            let tableIndex = try cursor.unsigned32()
            guard UInt64(tableIndex) < UInt64(dependencies.entries.count) else {
                throw CanonicalEncodingError.invalidReference
            }
            return try .external(locator: dependencies.entries[Int(tableIndex)],
                index: OperationIndex(cursor.unsigned32()), expectedID: OperationID(bytes: cursor.fixedBytes(32)))
        case 1: return try .earlierLocal(index: OperationIndex(cursor.unsigned32()))
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
    }
}

/// An operation with checked fields and semantic identity, retaining its transport
/// references. Payload and history validators establish complete action groups
/// and resolve external occurrences in verified envelopes.
public struct OperationRecordV1: Equatable, Sendable {
    public let operation: IdentifiedOperation
    public let causalReferences: [OperationReference]
    public let noteReferences: [OperationReference]

/// Sorts references by expanded identity and rejects duplicates. Local references
    /// resolve against the supplied prefix of preceding operations.
    public init(operation: IdentifiedOperation, causalReferences: [OperationReference],
                noteReferences: [OperationReference], earlierOperations: [IdentifiedOperation]) throws {
        self.operation = operation
        self.causalReferences = try Self.canonicalReferences(causalReferences,
            expected: operation.causalParents.ids, earlierOperations: earlierOperations)
        self.noteReferences = try Self.canonicalReferences(noteReferences,
            expected: operation.notePredecessors.ids, earlierOperations: earlierOperations)
        guard encodedByteCount <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
    }

    var encodedByteCount: UInt64 {
        var size = UInt64(32 + operationHeader(nonce: operation.nonce, effect: operation.effect).count + 8 + 4)
            + operation.effect.payloadByteCount
        for refs in [causalReferences, noteReferences] {
            for ref in refs { size += ref.encodedByteCount }
        }
        return size
    }

    public func encodedV1(dependencies: DependencyLocatorTable,
                          earlierOperations: [IdentifiedOperation]) throws -> [UInt8] {
        // Preserve each local binding and its canonical position in the reference vector.
        let causal = try Self.canonicalReferences(causalReferences, expected: operation.causalParents.ids,
                                                  earlierOperations: earlierOperations)
        let predecessors = try Self.canonicalReferences(noteReferences, expected: operation.notePredecessors.ids,
                                                        earlierOperations: earlierOperations)
        guard causal == causalReferences, predecessors == noteReferences else {
            throw CanonicalEncodingError.invalidReference
        }
        var bytes = operation.id.bytes + operationHeader(nonce: operation.nonce, effect: operation.effect)
        for refs in [causalReferences, noteReferences] {
            bytes += bigEndianBytes(UInt32(refs.count))
            for ref in refs { bytes += try ref.encoded(dependencies: dependencies) }
        }
        bytes += bigEndianBytes(UInt32(operation.effect.payloadByteCount))
        bytes += operation.effect.payloadBytes()
        return bytes
    }

    public static func decodeV1(_ bytes: [UInt8], dependencies: DependencyLocatorTable,
                               earlierOperations: [IdentifiedOperation]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        var cursor = ByteCursor(bytes: bytes)
        let claimedID = try OperationID(bytes: cursor.fixedBytes(32))
        let nonce = try OperationNonce(bytes: cursor.fixedBytes(16))
        let kind = try cursor.byte()
        guard (1...9).contains(kind) else { throw CanonicalEncodingError.unsupportedFormat }
        let action = try optionalID(&cursor).map { try ActionID(bytes: $0) }
        let birth = try optionalID(&cursor).map { try NoteBirth(bytes: $0) }
        let causal = try references(&cursor, dependencies: dependencies, earlierOperations: earlierOperations)
        let predecessors = try references(&cursor, dependencies: dependencies, earlierOperations: earlierOperations)
        let effect = try decodeEffect(kind: kind, action: action, birth: birth,
                                      payload: cursor.lengthPrefixedBytes())
        try cursor.requireEnd()
        let operation = try IdentifiedOperation(nonce: nonce, effect: effect,
            causalParents: CausalParentSet(causal.map { try $0.expandedID(earlierOperations: earlierOperations) }),
            notePredecessors: NotePredecessorSet(predecessors.map { try $0.expandedID(earlierOperations: earlierOperations) }))
        guard operation.id == claimedID else { throw CanonicalEncodingError.identityMismatch }
        return try Self(operation: operation, causalReferences: causal, noteReferences: predecessors,
                        earlierOperations: earlierOperations)
    }

    private static func optionalID(_ cursor: inout ByteCursor) throws -> [UInt8]? {
        switch try cursor.byte() {
        case 0: return nil
        case 1: return try cursor.fixedBytes(16)
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
    }

    private static func canonicalReferences(_ refs: [OperationReference], expected: [OperationID],
                                            earlierOperations: [IdentifiedOperation]) throws -> [OperationReference] {
        guard refs.count == expected.count else { throw CanonicalEncodingError.invalidReference }
        let pairs = try refs.map { (ref: $0, id: try $0.expandedID(earlierOperations: earlierOperations)) }
            .sorted { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) }
        guard pairs.map(\.id) == expected else { throw CanonicalEncodingError.invalidReference }
        return pairs.map(\.ref)
    }

    private static func references(_ cursor: inout ByteCursor, dependencies: DependencyLocatorTable,
                                   earlierOperations: [IdentifiedOperation]) throws -> [OperationReference] {
        let count = UInt64(try cursor.unsigned32())
        guard count <= UInt64(cursor.remaining / 5) else { throw CanonicalEncodingError.truncated }
        var refs: [OperationReference] = []
        var previous: OperationID?
        for _ in 0..<count {
            let ref = try OperationReference.decode(&cursor, dependencies: dependencies)
            let id = try ref.expandedID(earlierOperations: earlierOperations)
            if let previous, !previous.bytes.lexicographicallyPrecedes(id.bytes) {
                throw CanonicalEncodingError.noncanonicalSet
            }
            refs.append(ref)
            previous = id
        }
        return refs
    }

    private static func decodeEffect(kind: UInt8, action: ActionID?, birth: NoteBirth?,
                                     payload: [UInt8]) throws -> OperationEffectV1 {
        if kind >= 3 {
            guard let action, let birth else { throw CanonicalEncodingError.invalidOperation }
            if kind == 6 {
                guard payload.isEmpty else { throw CanonicalEncodingError.invalidOperation }
                return .delete(action: action, birth: birth)
            }
            if kind >= 7 {
                var cursor = ByteCursor(bytes: payload)
                let effect: OperationEffectV1
                switch kind {
                case 7:
                    let sourceBirth = try NoteBirth(bytes: cursor.fixedBytes(16)), revision = try OperationID(bytes: cursor.fixedBytes(32))
                    let key = try ConflictRecoveryKeyV1(bytes: cursor.fixedBytes(32)), slot = try cursor.unsigned64()
                    let reused: OperationID?
                    switch try cursor.byte() { case 0: reused = nil; case 1: reused = try OperationID(bytes: cursor.fixedBytes(32)); default: throw CanonicalEncodingError.invalidDiscriminant }
                    effect = try .recoverCopy(action: action, birth: birth,
                        source: .init(birth: sourceBirth, revision: revision, key: key, slot: slot, reused: reused), value: PlaintextNoteValue.decode(&cursor))
                case 8: effect = try .retireConflict(action: action, birth: birth, identity: DeterministicConflictIdentityV1.decode(&cursor))
                default:
                    let sourceBirth = try NoteBirth(bytes: cursor.fixedBytes(16)), revision = try OperationID(bytes: cursor.fixedBytes(32)), key = try AutomaticConflictKeyV1(bytes: cursor.fixedBytes(32))
                    effect = try .adoptAutomatic(action: action, birth: birth, source: .init(birth: sourceBirth, revision: revision, key: key), value: PlaintextNoteValue.decode(&cursor))
                }
                try cursor.requireEnd(); return effect
            }
            let value = try PlaintextNoteValue.decodeV1(payload)
            switch kind {
            case 3: return .create(action: action, birth: birth, value: value)
            case 4: return .importNote(action: action, birth: birth, value: value)
            default: return .put(action: action, birth: birth, value: value)
            }
        }
        guard action == nil, birth == nil else { throw CanonicalEncodingError.invalidOperation }
        var cursor = ByteCursor(bytes: payload)
        let importID = try ImportID(bytes: cursor.fixedBytes(16))
        let effect: OperationEffectV1
        if kind == 1 {
            guard let profile = CollectionProfileV1(rawValue: try cursor.byte()),
                  try cursor.unsigned16() == 1, try cursor.unsigned16() == 1 else {
                throw CanonicalEncodingError.unsupportedFormat
            }
            effect = try .genesis(importID: importID, profile: profile, initialCount: cursor.unsigned64(),
                                  initialValuesDigest: InitialValuesDigest(bytes: cursor.fixedBytes(32)))
        } else {
            effect = try .importComplete(importID: importID, initialCount: cursor.unsigned64(),
                                         initialValuesDigest: InitialValuesDigest(bytes: cursor.fixedBytes(32)))
        }
        try cursor.requireEnd()
        return effect
    }
}
