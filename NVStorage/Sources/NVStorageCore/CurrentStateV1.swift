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

/// The source of a current value: one revision, a derived result, or a preserved alternative.
public enum CurrentNoteProvenanceV1: Equatable, Sendable {
    case revision
    case derived(DerivedStateReferenceV1)
    case automatic(AutomaticSourceReferenceV1)
}

/// Current value with the exact revision set and provenance needed for editing.
public struct CurrentNoteCellV1: Equatable, Sendable {
    public let birth: NoteBirth
    public let value: PlaintextNoteValue
    public let revision: StoredOperationReferenceV1
    public let scopeFrontier: [StoredActionReferenceV1]
    public let represented: [StoredOperationReferenceV1]
    public let heads: [StoredOperationReferenceV1]
    public let provenance: CurrentNoteProvenanceV1
    public var derived: DerivedStateReferenceV1? {
        if case .derived(let source) = provenance { source } else { nil }
    }
    public var automatic: AutomaticSourceReferenceV1? {
        if case .automatic(let source) = provenance { source } else { nil }
    }
    public let identity: DeterministicConflictIdentityV1?
    private let encodedDerived: [UInt8]?
    public var stateReference: ActionStateReference {
        switch provenance {
        case .revision: .value(revision.reference)
        case .derived(let source): .derived(source)
        case .automatic(let source): .automatic(source)
        }
    }
    public var state: ActionStateV1 {
        switch provenance {
        case .revision: .value(revision.id)
        case .derived(let source): .derived(source.state)
        case .automatic(let source): .automatic(.init(birth: source.birth, revision: revision.id, key: source.key))
        }
    }
    public init(birth: NoteBirth, value: PlaintextNoteValue, revision: StoredOperationReferenceV1,
                scopeFrontier: [StoredActionReferenceV1], identity: DeterministicConflictIdentityV1? = nil) throws {
        try self.init(birth: birth, value: value, represented: [revision], heads: [revision],
                      provenance: .revision, scopeFrontier: scopeFrontier, identity: identity)
    }
    public init(birth: NoteBirth, value: PlaintextNoteValue, represented: [StoredOperationReferenceV1],
                heads: [StoredOperationReferenceV1], provenance: CurrentNoteProvenanceV1,
                scopeFrontier: [StoredActionReferenceV1],
                identity: DeterministicConflictIdentityV1? = nil) throws {
        let ordered = represented.sorted { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) }
        let orderedHeads = heads.sorted { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) }
        guard let first = ordered.first, Set(ordered.map(\.id)).count == ordered.count,
              Set(orderedHeads.map(\.id)).count == orderedHeads.count,
              Set(ordered).isSubset(of: Set(orderedHeads)) else {
            throw CanonicalEncodingError.invalidReference
        }
        self.birth = birth; self.value = value; revision = first
        switch provenance {
        case .revision:
            guard ordered.count == 1 else { throw CanonicalEncodingError.invalidReference }
        case .derived(let source):
            guard source.state.inputs == ordered.map(\.id), try source.result == value.digestV1() else {
                throw CanonicalEncodingError.invalidReference
            }
        case .automatic(let source):
            guard ordered.count == 1, source.revision == first.reference,
                  try source.key.birth() == birth else { throw CanonicalEncodingError.invalidReference }
        }
        if let identity { guard try identity.birth() == birth else { throw CanonicalEncodingError.invalidReference } }
        let derived: DerivedStateReferenceV1?
        let automatic: AutomaticSourceReferenceV1?
        switch provenance {
        case .revision: derived = nil; automatic = nil
        case .derived(let source): derived = source; automatic = nil
        case .automatic(let source): derived = nil; automatic = source
        }
        self.provenance = provenance
        self.identity = identity ?? automatic.map { .automatic($0.key) }
        self.represented = ordered; self.heads = orderedHeads
        if case .derived(let derived) = provenance {
            guard derived.references.allSatisfy({ if case .external = $0 { true } else { false } }) else {
                throw CanonicalEncodingError.invalidReference
            }
            let table = try DependencyLocatorTable(Array(Set(derived.externalLocators)))
            let record = try derived.encodedV1(dependencies: table, earlierOperations: [])
            encodedDerived = table.encodedV1() + bigEndianBytes(UInt32(record.count)) + record
        } else { encodedDerived = nil }
        self.scopeFrontier = try checkedActions(scopeFrontier)
        let extended = ordered.count != 1 || orderedHeads != ordered || derived != nil || automatic != nil || self.identity != nil
        let extra: UInt64 = extended ? 11 + 92 * UInt64(ordered.count + orderedHeads.count) + UInt64(encodedDerived?.count ?? 0) + (automatic == nil ? 0 : 140) + UInt64(self.identity?.encoded.count ?? 0) : 0
        guard 126 + value.encodedByteCount + 76 * UInt64(scopeFrontier.count) + extra <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
    }
    public func encodedV1() -> [UInt8] {
        let extended = represented.count != 1 || heads != represented || derived != nil || automatic != nil || identity != nil
        var bytes = Array("NVCEL1\r\n".utf8) + bigEndianBytes(UInt16(extended ? 2 : 1)) + birth.bytes
        bytes += bigEndianBytes(UInt32(value.encodedByteCount)) + value.encodedV1() + revision.encoded()
        bytes += bigEndianBytes(UInt32(scopeFrontier.count))
        for ref in scopeFrontier { bytes += ref.encoded() }
        if extended {
            for refs in [represented, heads] {
                bytes += bigEndianBytes(UInt32(refs.count))
                for ref in refs { bytes += ref.encoded() }
            }
            if let encodedDerived {
                bytes += [1] + encodedDerived
            } else { bytes += [0] }
            if let automatic { bytes += [1] + automatic.birth.bytes + automatic.key.bytes + revision.encoded() }
            else { bytes += [0] }
            if let identity { bytes += [1] + identity.encoded } else { bytes += [0] }
        }
        return bytes
    }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == Array("NVCEL1\r\n".utf8) else { throw CanonicalEncodingError.unsupportedFormat }
        let version = try c.unsigned16()
        guard version == 1 || version == 2 else { throw CanonicalEncodingError.unsupportedFormat }
        let birth = try NoteBirth(bytes: c.fixedBytes(16)), value = try PlaintextNoteValue.decodeV1(c.lengthPrefixedBytes())
        let revision = try StoredOperationReferenceV1.decode(&c), count = try c.count(minimumElementBytes: 76)
        var refs: [StoredActionReferenceV1] = []
        for _ in 0..<count { refs.append(try StoredActionReferenceV1.decode(&c)) }
        var represented = [revision], heads = [revision], derived: DerivedStateReferenceV1?, automatic: AutomaticSourceReferenceV1?, identity: DeterministicConflictIdentityV1?
        if version == 2 {
            represented = []; heads = []
            for _ in 0..<(try c.count(minimumElementBytes: 92)) { represented.append(try StoredOperationReferenceV1.decode(&c)) }
            for _ in 0..<(try c.count(minimumElementBytes: 92)) { heads.append(try StoredOperationReferenceV1.decode(&c)) }
            switch try c.byte() {
            case 0: break
            case 1:
                let table = try DependencyLocatorTable.decode(&c)
                derived = try DerivedStateReferenceV1.decodeV1(c.lengthPrefixedBytes(), dependencies: table, earlierOperations: [])
            default: throw CanonicalEncodingError.invalidDiscriminant
            }
            switch try c.byte() {
            case 0: break
            case 1:
                let sourceBirth = try NoteBirth(bytes: c.fixedBytes(16)), key = try AutomaticConflictKeyV1(bytes: c.fixedBytes(32)), source = try StoredOperationReferenceV1.decode(&c)
                automatic = .init(birth: sourceBirth, revision: source.reference, key: key)
            default: throw CanonicalEncodingError.invalidDiscriminant
            }
            switch try c.byte() { case 0: break; case 1: identity = try DeterministicConflictIdentityV1.decode(&c); default: throw CanonicalEncodingError.invalidDiscriminant }
        }
        let provenance: CurrentNoteProvenanceV1
        switch (derived, automatic) {
        case (nil, nil): provenance = .revision
        case (let source?, nil): provenance = .derived(source)
        case (nil, let source?): provenance = .automatic(source)
        case (.some, .some): throw CanonicalEncodingError.invalidReference
        }
        let result = try Self(birth: birth, value: value, represented: represented, heads: heads,
                              provenance: provenance, scopeFrontier: refs, identity: identity)
        try c.requireEnd()
        guard result.scopeFrontier == refs, result.revision == revision, result.represented == represented,
              result.heads == heads, result.encodedV1() == bytes else { throw CanonicalEncodingError.noncanonicalSet }
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
