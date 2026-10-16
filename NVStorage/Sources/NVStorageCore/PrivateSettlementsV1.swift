/// Historical description of one completed output and its accounted-for source.
/// The rooted consumer supplies fresh physical evidence before committing this record.
public struct ProjectionSettlementV1: Equatable, Sendable {
    public let scope: PrivateRecordScopeV1
    public let association: LocalAssociationID
    public let relationshipGeneration: UInt64
    public let transition: IntendedProjectionV1
    public let accepted: AcceptedProjectionV1
    public let sourceAccounting: PassivePlatformRecordV1?

    public init(profile: CollectionProfileV1, scope: PrivateRecordScopeV1, association: LocalAssociationID,
                relationshipGeneration: UInt64, transition: IntendedProjectionV1,
                accepted: AcceptedProjectionV1, sourceAccounting: PassivePlatformRecordV1?) throws {
        guard profile == .plaintextFiles, scope.collection == accepted.output.binding.collection else {
            throw CanonicalEncodingError.wrongScope
        }
        guard relationshipGeneration > 0, relationshipGeneration <= Int64.max,
              transition.output == accepted.output,
              (transition.source != nil) == (sourceAccounting != nil) else { throw CanonicalEncodingError.invalidReference }
        self.scope = scope; self.association = association; self.relationshipGeneration = relationshipGeneration
        self.transition = transition; self.accepted = accepted; self.sourceAccounting = sourceAccounting
        try settlementSize(encodedByteCount)
    }
    var encodedByteCount: UInt64 {
        106 + transition.encodedByteCount + accepted.encodedByteCount
            + (sourceAccounting.map { 13 + UInt64($0.bytes.count) } ?? 1)
    }
    public func encodedV1() throws -> [UInt8] {
        try Array("NVPSL1\r\n".utf8) + bigEndianBytes(UInt16(1)) + scope.encoded() + association.bytes
            + bigEndianBytes(relationshipGeneration) + settlementBlob(transition.encoded())
            + settlementBlob(accepted.encoded()) + settlementOptional(sourceAccounting?.encoded())
    }
    public static func decodeV1(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        var c = try settlementCursor(bytes, magic: "NVPSL1\r\n")
        let scope = try PrivateRecordScopeV1.decode(&c), association = try LocalAssociationID(bytes: c.fixedBytes(16))
        let generation = try c.unsigned64(), transition = try IntendedProjectionV1.decode(c.lengthPrefixedBytes(), profile: profile)
        let accepted = try AcceptedProjectionV1.decode(c.lengthPrefixedBytes(), profile: profile)
        let accounting = try settlementOptional(&c).map { bytes in
            var value = ByteCursor(bytes: bytes)
            let result = try PassivePlatformRecordV1.decode(&value)
            try value.requireEnd(); return result
        }
        try c.requireEnd()
        return try Self(profile: profile, scope: scope, association: association, relationshipGeneration: generation,
                        transition: transition, accepted: accepted, sourceAccounting: accounting)
    }

    /// Calculates the passive owner transfer after the consumer checks the live relationship.
    /// A newer intention keeps its output and starts its next transition from the newly accepted file.
    public func transferringOwners(in previous: ProjectionObservationsV1) throws -> ProjectionObservationsV1 {
        guard previous.scope == scope, previous.association == association,
              previous.birth == accepted.output.binding.birth else { throw CanonicalEncodingError.wrongScope }
        guard previous.frozen == transition, previous.accepted == transition.source,
              let intended = previous.intended else { throw CanonicalEncodingError.invalidReference }
        let remaining = try intended.output.generation == transition.output.generation ? nil :
            IntendedProjectionV1(output: intended.output, source: accepted)
        return try ProjectionObservationsV1(profile: .plaintextFiles, scope: scope, association: association,
            birth: previous.birth, accepted: accepted, intended: remaining)
    }
}

/// A consumed input or a completed projection, retaining their distinct recovery meanings.
public enum PendingSettlementOutcomeV1: Equatable, Sendable {
    case consumed(PassivePlatformRecordV1)
    case projection(ProjectionSettlementV1)
    public var observation: PassivePlatformRecordV1 {
        switch self { case .consumed(let value): value; case .projection(let value): value.accepted.physical }
    }
}

/// Exact admitted decision retained after its external preview bytes are released.
/// The subsequent snapshot identifies work outstanding at settlement; the pending item owns its current bytes.
public struct PendingSettlementV1: Equatable, Sendable {
    public let scope: PrivateRecordScopeV1
    public let item: PendingItemID
    public let reservation: PendingReservationV1
    public let outcome: PendingSettlementOutcomeV1
    public let subsequentSnapshot: PendingSnapshotID?
    public init(scope: PrivateRecordScopeV1, item: PendingItemID, reservation: PendingReservationV1,
                outcome: PendingSettlementOutcomeV1, subsequentSnapshot: PendingSnapshotID?) throws {
        guard subsequentSnapshot != reservation.snapshot else { throw CanonicalEncodingError.invalidReference }
        let outcomeSize: UInt64
        switch outcome {
        case .consumed(let observation): outcomeSize = 8 + UInt64(observation.bytes.count)
        case .projection(let projection):
            guard projection.scope.collection == scope.collection,
                  projection.accepted.output.binding.birth == reservation.birth else { throw CanonicalEncodingError.wrongScope }
            outcomeSize = projection.encodedByteCount
        }
        try settlementSize(100 + UInt64(reservation.encodedV1().count) + outcomeSize + (subsequentSnapshot == nil ? 0 : 16))
        self.scope = scope; self.item = item; self.reservation = reservation
        self.outcome = outcome; self.subsequentSnapshot = subsequentSnapshot
    }
    public func encodedV1() throws -> [UInt8] {
        let tag: UInt8, bytes: [UInt8]
        switch outcome {
        case .consumed(let value): tag = 1; bytes = value.encoded()
        case .projection(let value): tag = 2; bytes = try value.encodedV1()
        }
        return Array("NVPST1\r\n".utf8) + bigEndianBytes(UInt16(1)) + scope.encoded() + item.bytes
            + settlementBlob(reservation.encodedV1()) + [tag] + settlementBlob(bytes)
            + (subsequentSnapshot.map { [1] + $0.bytes } ?? [0])
    }
    public static func decodeV1(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        var c = try settlementCursor(bytes, magic: "NVPST1\r\n")
        let scope = try PrivateRecordScopeV1.decode(&c), item = try PendingItemID(bytes: c.fixedBytes(16))
        let reservation = try PendingReservationV1.decodeV1(c.lengthPrefixedBytes()), tag = try c.byte()
        let bytes = try c.lengthPrefixedBytes(), outcome: PendingSettlementOutcomeV1
        switch tag {
        case 1:
            var value = ByteCursor(bytes: bytes)
            outcome = .consumed(try PassivePlatformRecordV1.decode(&value)); try value.requireEnd()
        case 2: outcome = .projection(try ProjectionSettlementV1.decodeV1(bytes, profile: profile))
        default: throw CanonicalEncodingError.unsupportedFormat
        }
        let subsequent: PendingSnapshotID?
        switch try c.byte() {
        case 0: subsequent = nil
        case 1: subsequent = try PendingSnapshotID(bytes: c.fixedBytes(16))
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
        try c.requireEnd()
        return try Self(scope: scope, item: item, reservation: reservation, outcome: outcome, subsequentSnapshot: subsequent)
    }
}

private func settlementSize(_ count: UInt64) throws {
    guard count <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
}
private func settlementBlob(_ bytes: [UInt8]) -> [UInt8] { bigEndianBytes(UInt32(bytes.count)) + bytes }
private func settlementOptional(_ bytes: [UInt8]?) -> [UInt8] { bytes.map { [1] + settlementBlob($0) } ?? [0] }
private func settlementOptional(_ c: inout ByteCursor) throws -> [UInt8]? {
    switch try c.byte() {
    case 0: nil
    case 1: try c.lengthPrefixedBytes()
    default: throw CanonicalEncodingError.invalidDiscriminant
    }
}
private func settlementCursor(_ bytes: [UInt8], magic: String) throws -> ByteCursor {
    try settlementSize(UInt64(bytes.count)); var c = ByteCursor(bytes: bytes)
    guard try c.fixedBytes(8) == Array(magic.utf8), try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
    return c
}
