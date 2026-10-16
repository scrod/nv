/// Identity of one independently reserved physical replacement attempt.
public struct ProjectionReplacementAttemptID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

/// The physical operation determined by the captured source and output names.
public enum ProjectionFileTransitionOperationV1: Equatable, Sendable {
    case replacement, relocation
}

/// Private location and captured inputs for a possibly interrupted projection transition.
/// Recovery uses the record to inspect retained material under fresh rooted checks.
public struct ProjectionReplacementAttemptV1: Equatable, Sendable {
    public let scope: PrivateRecordScopeV1
    public let association: LocalAssociationID
    public let attempt: ProjectionReplacementAttemptID
    public let transition: IntendedProjectionV1
    public let root: PassivePlatformRecordV1
    public let source: PassivePlatformRecordV1

    public var operation: ProjectionFileTransitionOperationV1 {
        transition.source?.output.binding.descriptor.filename == transition.output.binding.descriptor.filename ? .replacement : .relocation
    }

    /// A fixed hidden spelling derived from the operation's independently generated UUID.
    public var backupName: String {
        ".nv-replacement-" + attempt.bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() + ".backup"
    }

    public init(profile: CollectionProfileV1, scope: PrivateRecordScopeV1,
                association: LocalAssociationID, attempt: ProjectionReplacementAttemptID, transition: IntendedProjectionV1,
                root: PassivePlatformRecordV1, source: PassivePlatformRecordV1) throws {
        guard profile == .plaintextFiles, scope.collection == transition.output.binding.collection else {
            throw CanonicalEncodingError.wrongScope
        }
        guard transition.source != nil else {
            throw CanonicalEncodingError.invalidReference
        }
        self.attempt = attempt
        try Self.checkSize(126 + transition.encodedByteCount + UInt64(root.bytes.count) + UInt64(source.bytes.count))
        self.scope = scope; self.association = association; self.transition = transition
        self.root = root; self.source = source
    }

    public func encodedV1() throws -> [UInt8] {
        let captured = try transition.encoded()
        return Array("NVPRA1\r\n".utf8) + bigEndianBytes(UInt16(1)) + scope.encoded() + association.bytes
            + attempt.bytes + bigEndianBytes(UInt32(captured.count)) + captured + root.encoded() + source.encoded()
    }

    public static func decodeV1(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        try checkSize(UInt64(bytes.count))
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == Array("NVPRA1\r\n".utf8), try c.unsigned16() == 1 else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        let scope = try PrivateRecordScopeV1.decode(&c)
        let association = try LocalAssociationID(bytes: c.fixedBytes(16))
        let attempt = try ProjectionReplacementAttemptID(bytes: c.fixedBytes(16))
        let transition = try IntendedProjectionV1.decode(c.lengthPrefixedBytes(), profile: profile)
        let root = try PassivePlatformRecordV1.decode(&c), source = try PassivePlatformRecordV1.decode(&c)
        try c.requireEnd()
        return try Self(profile: profile, scope: scope, association: association, attempt: attempt,
                        transition: transition, root: root, source: source)
    }

    private static func checkSize(_ count: UInt64) throws {
        guard count <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
    }
}
