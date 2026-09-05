import Crypto

public enum CollectionProfileV1: UInt8, Sendable {
    case plaintextFiles = 1
    case encryptedSegments = 2
}

/// Bootstrap and ordinary note effects. Each note-mutation variant carries its
/// action membership, target birth and applicable value or import metadata.
public enum OperationEffectV1: Equatable, Hashable, Sendable {
    case genesis(importID: ImportID, profile: CollectionProfileV1,
                 initialCount: UInt64, initialValuesDigest: InitialValuesDigest)
    case importComplete(importID: ImportID, initialCount: UInt64,
                        initialValuesDigest: InitialValuesDigest)
    case create(action: ActionID, birth: NoteBirth, value: PlaintextNoteValue)
    case importNote(action: ActionID, birth: NoteBirth, value: PlaintextNoteValue)
    case put(action: ActionID, birth: NoteBirth, value: PlaintextNoteValue)
    case delete(action: ActionID, birth: NoteBirth)

    var tag: UInt8 {
        switch self {
        case .genesis: 1
        case .importComplete: 2
        case .create: 3
        case .importNote: 4
        case .put: 5
        case .delete: 6
        }
    }

    public var actionID: ActionID? {
        switch self {
        case .genesis, .importComplete: nil
        case .create(let action, _, _), .importNote(let action, _, _),
             .put(let action, _, _), .delete(let action, _): action
        }
    }

    public var targetBirth: NoteBirth? {
        switch self {
        case .genesis, .importComplete: nil
        case .create(_, let birth, _), .importNote(_, let birth, _),
             .put(_, let birth, _), .delete(_, let birth): birth
        }
    }

    var payloadByteCount: UInt64 {
        switch self {
        case .genesis: 61
        case .importComplete: 56
        case .create(_, _, let value), .importNote(_, _, let value), .put(_, _, let value):
            value.encodedByteCount
        case .delete: 0
        }
    }

    func payloadBytes() -> [UInt8] {
        switch self {
        case .genesis(let importID, let profile, let count, let digest):
            return importID.bytes + [profile.rawValue] + bigEndianBytes(UInt16(1))
                + bigEndianBytes(UInt16(1)) + bigEndianBytes(count) + digest.bytes
        case .importComplete(let importID, let count, let digest):
            return importID.bytes + bigEndianBytes(count) + digest.bytes
        case .create(_, _, let value), .importNote(_, _, let value), .put(_, _, let value):
            return value.encodedV1()
        case .delete: return []
        }
    }
}

/// An operation's effect, nonce and canonical parent IDs, bound by a computed
/// semantic hash. History validation resolves the parents and checks note births,
/// causal closure, scope and complete action groups.
public struct IdentifiedOperation: Equatable, Hashable, Sendable {
    public let id: OperationID
    public let nonce: OperationNonce
    public let effect: OperationEffectV1
    public let causalParents: CausalParentSet
    public let notePredecessors: NotePredecessorSet

    public init(nonce: OperationNonce, effect: OperationEffectV1,
                causalParents: CausalParentSet, notePredecessors: NotePredecessorSet) throws {
        switch effect {
        case .genesis:
            guard causalParents.ids.isEmpty, notePredecessors.ids.isEmpty else {
                throw CanonicalEncodingError.invalidOperation
            }
        case .put:
            guard !causalParents.ids.isEmpty, !notePredecessors.ids.isEmpty else {
                throw CanonicalEncodingError.invalidOperation
            }
        default:
            guard !causalParents.ids.isEmpty, notePredecessors.ids.isEmpty else {
                throw CanonicalEncodingError.invalidOperation
            }
        }
        // Even the smallest transport (all local references) must fit one object.
        let minimumSize: UInt64 = 32 + 16 + 1 + 2 + 8 + 4
            + (effect.actionID == nil ? 0 : 16) + (effect.targetBirth == nil ? 0 : 16)
            + 5 * (UInt64(causalParents.ids.count) + UInt64(notePredecessors.ids.count))
            + effect.payloadByteCount
        guard minimumSize <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        self.nonce = nonce
        self.effect = effect
        self.causalParents = causalParents
        self.notePredecessors = notePredecessors
// Hash the canonical semantic fields so transport repackaging preserves identity.
        var hasher = SHA256()
        Self.visitIdentityBytes(nonce: nonce, effect: effect, causalParents: causalParents,
                                notePredecessors: notePredecessors) { hasher.update(data: $0) }
        self.id = try OperationID(bytes: Array(hasher.finalize()))
    }

/// Complete input to the semantic identity hash, exposed for diagnostics and fixtures.
    public func identityPreimageV1() -> [UInt8] {
        var bytes: [UInt8] = []
        Self.visitIdentityBytes(nonce: nonce, effect: effect, causalParents: causalParents,
                                notePredecessors: notePredecessors) { bytes += $0 }
        return bytes
    }

    private static func visitIdentityBytes(nonce: OperationNonce, effect: OperationEffectV1,
                                          causalParents: CausalParentSet,
                                          notePredecessors: NotePredecessorSet,
                                          emit: ([UInt8]) -> Void) {
        emit(Array("NV operation\0v1\0".utf8))
        emit(operationHeader(nonce: nonce, effect: effect))
        for ids in [causalParents.ids, notePredecessors.ids] {
            emit(bigEndianBytes(UInt32(ids.count)))
            for id in ids { emit(id.bytes) }
        }
        emit(bigEndianBytes(UInt32(effect.payloadByteCount)))
        emit(effect.payloadBytes())
    }
}

func operationHeader(nonce: OperationNonce, effect: OperationEffectV1) -> [UInt8] {
    var bytes = nonce.bytes + [effect.tag]
    bytes += effect.actionID.map { [1] + $0.bytes } ?? [0]
    bytes += effect.targetBirth.map { [1] + $0.bytes } ?? [0]
    return bytes
}

extension PlaintextNoteValue {
/// Hashes the complete stored value, including dates and exact text spelling.
    public func digestV1() throws -> NoteValueDigest {
        var hasher = SHA256()
        hasher.update(data: Array("NV note value\0v1\0".utf8))
        hasher.update(data: encodedV1())
        return try NoteValueDigest(bytes: Array(hasher.finalize()))
    }
}
