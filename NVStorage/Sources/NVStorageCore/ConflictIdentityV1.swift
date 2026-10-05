import Foundation
import Crypto

/// Body-bound identity shared by explicit recovery slots from one source birth.
public struct ConflictRecoveryKeyV1: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 32) }
    public static func compute(source: NoteBirth, body: ExactUTF8) throws -> Self {
        let canonical = Array(body.string.precomposedStringWithCanonicalMapping.utf8)
        return try Self(bytes: Array(SHA256.hash(data: Array("NV unresolved recovery key\0v1\0".utf8)
            + source.bytes + bigEndianBytes(UInt64(canonical.count)) + canonical)))
    }
    public func birth(slot: UInt64) throws -> NoteBirth {
        try conflictBirth(Array("NV unresolved recovery slot\0v1\0".utf8) + bytes + bigEndianBytes(slot))
    }
}

/// State-bound identity for retractable automatic delete/edit preservation.
public struct AutomaticConflictKeyV1: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 32) }
    public static func compute(source: NoteBirth, value: PlaintextNoteValue) throws -> Self {
        func string(_ value: String) -> [UInt8] {
            let bytes = Array(value.precomposedStringWithCanonicalMapping.utf8)
            return bigEndianBytes(UInt64(bytes.count)) + bytes
        }
        let labels = Set(value.labels.entries.map { $0.string.precomposedStringWithCanonicalMapping })
            .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var preimage = Array("NV automatic conflict preservation\0v1\0".utf8) + source.bytes
        preimage += string(value.title.string) + string(value.body.string) + bigEndianBytes(UInt64(labels.count))
        for label in labels { preimage += string(label) }
        return try Self(bytes: Array(SHA256.hash(data: preimage)))
    }
    public func birth() throws -> NoteBirth { try conflictBirth(digest: bytes) }
}

private func conflictBirth(_ preimage: [UInt8]) throws -> NoteBirth {
    try conflictBirth(digest: Array(SHA256.hash(data: preimage)))
}
private func conflictBirth(digest: [UInt8]) throws -> NoteBirth {
    var bytes = Array(digest.prefix(16)); bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
    return try NoteBirth(bytes: bytes)
}

/// Creation-domain evidence retained with deterministic note identities.
public enum DeterministicConflictIdentityV1: Equatable, Hashable, Sendable {
    case automatic(AutomaticConflictKeyV1)
    case recovery(ConflictRecoveryKeyV1, slot: UInt64)
    public func birth() throws -> NoteBirth {
        switch self { case .automatic(let key): try key.birth(); case .recovery(let key, let slot): try key.birth(slot: slot) }
    }
    var encoded: [UInt8] {
        switch self { case .automatic(let key): [0] + key.bytes; case .recovery(let key, let slot): [1] + key.bytes + bigEndianBytes(slot) }
    }
    static func decode(_ cursor: inout ByteCursor) throws -> Self {
        switch try cursor.byte() {
        case 0: return try .automatic(AutomaticConflictKeyV1(bytes: cursor.fixedBytes(32)))
        case 1: return try .recovery(ConflictRecoveryKeyV1(bytes: cursor.fixedBytes(32)), slot: cursor.unsigned64())
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
    }
}

public struct AutomaticSourceV1: Equatable, Hashable, Sendable {
    public let birth: NoteBirth
    public let revision: OperationID
    public let key: AutomaticConflictKeyV1
}

/// Exact source and slot selected by one explicit preservation command.
public struct ConflictCopySourceV1: Equatable, Hashable, Sendable {
    public let birth: NoteBirth
    public let revision: OperationID
    public let key: ConflictRecoveryKeyV1
    public let slot: UInt64
    public let reused: OperationID?
    public init(birth: NoteBirth, revision: OperationID, key: ConflictRecoveryKeyV1, slot: UInt64, reused: OperationID?) {
        self.birth = birth; self.revision = revision; self.key = key; self.slot = slot; self.reused = reused
    }
}

/// Exact source occurrence used to validate an automatic note's first independent action.
public struct AutomaticSourceReferenceV1: Equatable, Hashable, Sendable {
    public let birth: NoteBirth
    public let revision: OperationReference
    public let key: AutomaticConflictKeyV1
    public init(birth: NoteBirth, revision: OperationReference, key: AutomaticConflictKeyV1) {
        self.birth = birth; self.revision = revision; self.key = key
    }
    func expanded(_ operations: [IdentifiedOperation]) throws -> AutomaticSourceV1 {
        try AutomaticSourceV1(birth: birth, revision: revision.expandedID(earlierOperations: operations), key: key)
    }
    var encodedByteCount: UInt64 { 48 + revision.encodedByteCount }
    func encoded(_ dependencies: DependencyLocatorTable) throws -> [UInt8] { try birth.bytes + key.bytes + revision.encoded(dependencies: dependencies) }
    static func decode(_ cursor: inout ByteCursor, dependencies: DependencyLocatorTable) throws -> Self {
        let birth = try NoteBirth(bytes: cursor.fixedBytes(16)), key = try AutomaticConflictKeyV1(bytes: cursor.fixedBytes(32))
        return try Self(birth: birth, revision: OperationReference.decode(&cursor, dependencies: dependencies), key: key)
    }
}

extension PlaintextNoteValue {
    /// Presentation value for an independently identified conflict note.
    public func conflictCopyValue() throws -> Self {
        try Self(title: ExactUTF8(bytes: Array((title.string + " (conflict)").utf8)), body: body, labels: labels, created: created, modified: modified)
    }
}
