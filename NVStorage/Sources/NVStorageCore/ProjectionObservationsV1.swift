/// Durable source of exact output: retained UTF-8 history or captured encoded bytes.
public enum ProjectionTextEncodingV1: Equatable, Sendable {
    case utf8
    case captured(encoding: ProjectionEncodingV1, byteCount: UInt64)
    var encoded: [UInt8] {
        switch self {
        case .utf8: [1]
        case .captured(let encoding, let count): [2] + bigEndianBytes(encoding.rawValue) + bigEndianBytes(count)
        }
    }
}

/// One captured output generation and its complete history binding.
public struct ProjectionOutputV1: Equatable, Sendable {
    public let generation: UInt64
    public let encoding: ProjectionTextEncodingV1
    public let binding: ProjectionBindingV1
    var encodedByteCount: UInt64 { 12 + UInt64(encoding.encoded.count) + binding.encodedByteCount }
    public init(generation: UInt64, encoding: ProjectionTextEncodingV1, binding: ProjectionBindingV1) throws {
        guard generation > 0, generation <= Int64.max else { throw CanonicalEncodingError.invalidPayload }
        if case .captured(let id, let count) = encoding {
            guard id != .utf8, count <= Int64.max else { throw CanonicalEncodingError.invalidPayload }
        }
        self.generation = generation; self.encoding = encoding; self.binding = binding
        try projectionSize(encodedByteCount)
    }
    func encoded() throws -> [UInt8] { try bigEndianBytes(generation) + encoding.encoded + projectionBlob(binding.encodedV1()) }
    static func decode(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        var c = ByteCursor(bytes: bytes)
        let generation = try c.unsigned64()
        let encoding: ProjectionTextEncodingV1
        switch try c.byte() {
        case 1: encoding = .utf8
        case 2: encoding = try .captured(encoding: .init(rawValue: c.unsigned64()), byteCount: c.unsigned64())
        default: throw CanonicalEncodingError.unsupportedFormat
        }
        let result = try Self(generation: generation, encoding: encoding, binding: .decodeV1(c.lengthPrefixedBytes(), profile: profile))
        try c.requireEnd(); return result
    }
}

/// Earlier accepted file observation with raw metadata presence retained independently.
public struct AcceptedProjectionV1: Equatable, Sendable {
    public let output: ProjectionOutputV1
    public let physical: PassivePlatformRecordV1
    public let encoding: PassivePlatformRecordV1?
    public let tags: PassivePlatformRecordV1?
    public let created: PassivePlatformRecordV1?
    public let modified: PassivePlatformRecordV1?
    var encodedByteCount: UInt64 {
        4 + output.encodedByteCount + 8 + UInt64(physical.bytes.count)
            + [encoding, tags, created, modified].reduce(0) { $0 + ($1.map { 13 + UInt64($0.bytes.count) } ?? 1) }
    }
    public init(output: ProjectionOutputV1, physical: PassivePlatformRecordV1,
                encoding: PassivePlatformRecordV1?, tags: PassivePlatformRecordV1?,
                created: PassivePlatformRecordV1?, modified: PassivePlatformRecordV1?) throws {
        self.output = output; self.physical = physical; self.encoding = encoding
        self.tags = tags; self.created = created; self.modified = modified
        try projectionSize(encodedByteCount)
    }
    func encoded() throws -> [UInt8] {
        try projectionBlob(output.encoded()) + physical.encoded()
            + projectionOptional(encoding?.encoded()) + projectionOptional(tags?.encoded())
            + projectionOptional(created?.encoded()) + projectionOptional(modified?.encoded())
    }
    static func decode(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        var c = ByteCursor(bytes: bytes)
        func metadata(_ c: inout ByteCursor) throws -> PassivePlatformRecordV1? {
            guard let bytes = try projectionOptional(&c) else { return nil }
            var value = ByteCursor(bytes: bytes)
            let result = try PassivePlatformRecordV1.decode(&value)
            try value.requireEnd(); return result
        }
        let result = try Self(output: .decode(c.lengthPrefixedBytes(), profile: profile), physical: .decode(&c),
            encoding: metadata(&c), tags: metadata(&c), created: metadata(&c), modified: metadata(&c))
        try c.requireEnd(); return result
    }
}

/// Intended output and the captured earlier representation whose transition remains owed.
public struct IntendedProjectionV1: Equatable, Sendable {
    public let output: ProjectionOutputV1
    public let source: AcceptedProjectionV1?
    var encodedByteCount: UInt64 { 4 + output.encodedByteCount + (source.map { 5 + $0.encodedByteCount } ?? 1) }
    public init(output: ProjectionOutputV1, source: AcceptedProjectionV1?) throws {
        if let source {
            guard source.output.generation < output.generation,
                  source.output.binding.collection == output.binding.collection,
                  source.output.binding.birth == output.binding.birth else { throw CanonicalEncodingError.invalidReference }
        }
        self.output = output; self.source = source
        try projectionSize(encodedByteCount)
    }
    func encoded() throws -> [UInt8] { try projectionBlob(output.encoded()) + projectionOptional(source?.encoded()) }
    static func decode(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        var c = ByteCursor(bytes: bytes)
        let output = try ProjectionOutputV1.decode(c.lengthPrefixedBytes(), profile: profile)
        let source = try projectionOptional(&c).map { try AcceptedProjectionV1.decode($0, profile: profile) }
        try c.requireEnd(); return try Self(output: output, source: source)
    }
}

/// Required private descriptions for one note relationship and its unfinished output.
public struct ProjectionObservationsV1: Equatable, Sendable {
    public let scope: PrivateRecordScopeV1
    public let association: LocalAssociationID
    public let birth: NoteBirth
    public let accepted: AcceptedProjectionV1?
    public let intended: IntendedProjectionV1?
    public let frozen: IntendedProjectionV1?
    /// Complete byte owners for the accepted, latest and independently frozen transition.
    public var ownedOutputs: [ProjectionOutputV1] {
        [accepted?.output, intended?.output, intended?.source?.output,
         frozen?.output, frozen?.source?.output].compactMap { $0 }
    }
    public init(profile: CollectionProfileV1, scope: PrivateRecordScopeV1, association: LocalAssociationID,
                birth: NoteBirth, accepted: AcceptedProjectionV1?, intended: IntendedProjectionV1?,
                frozen: IntendedProjectionV1? = nil) throws {
        guard profile == .plaintextFiles else { throw CanonicalEncodingError.wrongScope }
        for output in [accepted?.output, intended?.output, frozen?.output].compactMap({ $0 }) {
            guard output.binding.collection == scope.collection, output.binding.birth == birth else { throw CanonicalEncodingError.wrongScope }
        }
        if let accepted, let intended {
            guard accepted.output.generation <= intended.output.generation,
                  accepted.output.generation != intended.output.generation || accepted.output == intended.output else { throw CanonicalEncodingError.invalidReference }
        }
        if let frozen {
            guard let intended, frozen.output.generation <= intended.output.generation,
                  frozen.output.generation != intended.output.generation || frozen == intended,
                  accepted.map({ $0.output.generation < frozen.output.generation }) ?? true else {
                throw CanonicalEncodingError.invalidReference
            }
        }
        self.scope = scope; self.association = association; self.birth = birth
        self.accepted = accepted; self.intended = intended; self.frozen = frozen
        var generations: [UInt64: ProjectionOutputV1] = [:]
        for output in ownedOutputs {
            if let existing = generations[output.generation], existing != output { throw CanonicalEncodingError.invalidReference }
            generations[output.generation] = output
        }
        try projectionSize(106 + (accepted.map { 5 + $0.encodedByteCount } ?? 1)
            + (intended.map { 5 + $0.encodedByteCount } ?? 1) + (frozen.map { 5 + $0.encodedByteCount } ?? 1))
    }
    public func encodedV1() throws -> [UInt8] {
        try Array("NVPOB1\r\n".utf8) + bigEndianBytes(UInt16(1)) + scope.encoded() + association.bytes + birth.bytes
            + projectionOptional(accepted?.encoded()) + projectionOptional(intended?.encoded()) + projectionOptional(frozen?.encoded())
    }
    public static func decodeV1(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        try projectionSize(UInt64(bytes.count))
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == Array("NVPOB1\r\n".utf8), try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        let scope = try PrivateRecordScopeV1.decode(&c), association = try LocalAssociationID(bytes: c.fixedBytes(16))
        let birth = try NoteBirth(bytes: c.fixedBytes(16))
        let accepted = try projectionOptional(&c).map { try AcceptedProjectionV1.decode($0, profile: profile) }
        let intended = try projectionOptional(&c).map { try IntendedProjectionV1.decode($0, profile: profile) }
        let frozen = try projectionOptional(&c).map { try IntendedProjectionV1.decode($0, profile: profile) }
        try c.requireEnd()
        return try Self(profile: profile, scope: scope, association: association, birth: birth,
                        accepted: accepted, intended: intended, frozen: frozen)
    }
}

private func projectionSize(_ count: UInt64) throws {
    guard count <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
}
private func projectionBlob(_ bytes: [UInt8]) -> [UInt8] { bigEndianBytes(UInt32(bytes.count)) + bytes }
private func projectionOptional(_ bytes: [UInt8]?) -> [UInt8] { bytes.map { [1] + projectionBlob($0) } ?? [0] }
private func projectionOptional(_ c: inout ByteCursor) throws -> [UInt8]? {
    switch try c.byte() {
    case 0: return nil
    case 1: return try c.lengthPrefixedBytes()
    default: throw CanonicalEncodingError.invalidDiscriminant
    }
}
