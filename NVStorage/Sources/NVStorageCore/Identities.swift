// Distinct identifier types separate protocol roles and enforce byte widths and
// nonzero values. History validation resolves their referenced evidence.

func identifierBytes(_ bytes: [UInt8], count: Int) throws -> [UInt8] {
    guard bytes.count == count, bytes.contains(where: { $0 != 0 }) else {
        throw CanonicalEncodingError.invalidIdentifier
    }
    return bytes
}

public struct OperationID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 32) }
}

public struct SegmentID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 32) }
}

public struct NoteValueDigest: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 32) }
}

public struct InitialValuesDigest: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 32) }
}

public struct WriterEpoch: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct NoteBirth: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct ActionID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct ActionOriginID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct ActionIndex: Equatable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

public struct OperationNonce: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct ImportID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct CollectionID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct CollectionKeyID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct OperationIndex: Equatable, Hashable, Sendable {
    public let rawValue: UInt32
    public init(_ rawValue: UInt32) { self.rawValue = rawValue }
}

func canonicalOperationIDs(_ ids: [OperationID]) throws -> [OperationID] {
    guard UInt64(ids.count) <= ObjectLimitsV1.decodedPayloadBytes / 5 else {
        throw CanonicalEncodingError.lengthLimit
    }
    let sorted = ids.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    for index in sorted.indices.dropFirst() where sorted[index - 1] == sorted[index] {
        throw CanonicalEncodingError.noncanonicalSet
    }
    return sorted
}

/// Canonically ordered operation IDs declaring an operation's observed causal history.
public struct CausalParentSet: Equatable, Hashable, Sendable {
    public let ids: [OperationID]
    public init(_ ids: [OperationID]) throws { self.ids = try canonicalOperationIDs(ids) }
}

/// Canonically ordered IDs of superseded note revisions; graph validation checks
/// their note membership and ancestry.
public struct NotePredecessorSet: Equatable, Hashable, Sendable {
    public let ids: [OperationID]
    public init(_ ids: [OperationID]) throws { self.ids = try canonicalOperationIDs(ids) }
}
