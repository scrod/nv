/// Identity of one reserved protected source-removal attempt.
public struct ProjectionSourceAttemptID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

/// Required private recovery location and inputs for an original local Delete.
public struct ProjectionSourceAttemptV1: Equatable, Sendable {
    public let scope: PrivateRecordScopeV1
    public let association: LocalAssociationID
    public let attempt: ProjectionSourceAttemptID
    public let deletion: StoredActionReferenceV1
    public let source: AcceptedProjectionV1
    public let root: PassivePlatformRecordV1
    public let observation: PassivePlatformRecordV1

    public var birth: NoteBirth { source.output.binding.birth }
    /// Stable attempt key used to derive the protected recovery directory.
    public var recoveryName: String {
        ".nv-source-" + attempt.bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined() + ".backup"
    }
    /// Persistent protected location for the actual item captured during cleanup.
    public var cleanupDirectoryName: String { recoveryName + ".cleanup" }

    public init(profile: CollectionProfileV1, scope: PrivateRecordScopeV1, association: LocalAssociationID,
                attempt: ProjectionSourceAttemptID, deletion: StoredActionReferenceV1, source: AcceptedProjectionV1,
                root: PassivePlatformRecordV1, observation: PassivePlatformRecordV1) throws {
        guard profile == .plaintextFiles, scope.collection == source.output.binding.collection else {
            throw CanonicalEncodingError.wrongScope
        }
        try Self.checkSize(202 + source.encodedByteCount + UInt64(root.bytes.count) + UInt64(observation.bytes.count))
        self.scope = scope; self.association = association; self.attempt = attempt; self.deletion = deletion
        self.source = source; self.root = root; self.observation = observation
    }

    public func encodedV1() throws -> [UInt8] {
        let captured = try source.encoded()
        return Array("NVSRC1\r\n".utf8) + bigEndianBytes(UInt16(1)) + scope.encoded() + association.bytes
            + attempt.bytes + deletion.encoded() + bigEndianBytes(UInt32(captured.count)) + captured
            + root.encoded() + observation.encoded()
    }

    public static func decodeV1(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        try checkSize(UInt64(bytes.count))
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == Array("NVSRC1\r\n".utf8), try c.unsigned16() == 1 else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        let scope = try PrivateRecordScopeV1.decode(&c), association = try LocalAssociationID(bytes: c.fixedBytes(16))
        let attempt = try ProjectionSourceAttemptID(bytes: c.fixedBytes(16)), deletion = try StoredActionReferenceV1.decode(&c)
        let source = try AcceptedProjectionV1.decode(c.lengthPrefixedBytes(), profile: profile)
        let root = try PassivePlatformRecordV1.decode(&c), observation = try PassivePlatformRecordV1.decode(&c)
        try c.requireEnd()
        return try Self(profile: profile, scope: scope, association: association, attempt: attempt,
                        deletion: deletion, source: source, root: root, observation: observation)
    }

    private static func checkSize(_ count: UInt64) throws {
        guard count <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
    }
}
