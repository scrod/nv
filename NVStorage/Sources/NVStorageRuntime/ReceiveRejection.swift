import NVStorageCore

/// Stable private reason codes for preserved, unaccepted receive candidates.
public enum ReceiveRejection: Int64, Sendable {
    case unsupported = 1
    case conflictingClaim, invalidCausality, invalidAction, invalidBeforeAfter, reusedBirth, laterReducer
    case truncated = 20, trailingBytes, lengthLimit, invalidUTF8, invalidDate, noncanonicalDate
    case noncanonicalLabels, unsupportedFormat, invalidIdentifier, invalidDiscriminant, noncanonicalSet
    case invalidReference, invalidOperation, identityMismatch, invalidCanonicalAction, invalidPayload
    case wrongScope, authenticationFailure

    init?(_ error: any Error) {
        switch error {
        case StorageError.unsupported: self = .unsupported
        case OrdinaryHistoryError.conflictingClaim: self = .conflictingClaim
        case OrdinaryHistoryError.invalidCausality: self = .invalidCausality
        case OrdinaryHistoryError.invalidAction: self = .invalidAction
        case OrdinaryHistoryError.invalidBeforeAfter: self = .invalidBeforeAfter
        case OrdinaryHistoryError.reusedBirth: self = .reusedBirth
        case OrdinaryHistoryError.requiresLaterReducer: self = .laterReducer
        case CanonicalEncodingError.truncated: self = .truncated
        case CanonicalEncodingError.trailingBytes: self = .trailingBytes
        case CanonicalEncodingError.lengthLimit: self = .lengthLimit
        case CanonicalEncodingError.invalidUTF8: self = .invalidUTF8
        case CanonicalEncodingError.invalidDate: self = .invalidDate
        case CanonicalEncodingError.noncanonicalDate: self = .noncanonicalDate
        case CanonicalEncodingError.noncanonicalLabels: self = .noncanonicalLabels
        case CanonicalEncodingError.unsupportedFormat: self = .unsupportedFormat
        case CanonicalEncodingError.invalidIdentifier: self = .invalidIdentifier
        case CanonicalEncodingError.invalidDiscriminant: self = .invalidDiscriminant
        case CanonicalEncodingError.noncanonicalSet: self = .noncanonicalSet
        case CanonicalEncodingError.invalidReference: self = .invalidReference
        case CanonicalEncodingError.invalidOperation: self = .invalidOperation
        case CanonicalEncodingError.identityMismatch: self = .identityMismatch
        case CanonicalEncodingError.invalidAction: self = .invalidCanonicalAction
        case CanonicalEncodingError.invalidPayload: self = .invalidPayload
        case CanonicalEncodingError.wrongScope: self = .wrongScope
        case CanonicalEncodingError.authenticationFailure: self = .authenticationFailure
        default: return nil
        }
    }

    var error: any Error {
        switch self {
        case .unsupported: return StorageError.unsupported
        case .conflictingClaim: return OrdinaryHistoryError.conflictingClaim
        case .invalidCausality: return OrdinaryHistoryError.invalidCausality
        case .invalidAction: return OrdinaryHistoryError.invalidAction
        case .invalidBeforeAfter: return OrdinaryHistoryError.invalidBeforeAfter
        case .reusedBirth: return OrdinaryHistoryError.reusedBirth
        case .laterReducer: return OrdinaryHistoryError.requiresLaterReducer
        case .truncated: return CanonicalEncodingError.truncated
        case .trailingBytes: return CanonicalEncodingError.trailingBytes
        case .lengthLimit: return CanonicalEncodingError.lengthLimit
        case .invalidUTF8: return CanonicalEncodingError.invalidUTF8
        case .invalidDate: return CanonicalEncodingError.invalidDate
        case .noncanonicalDate: return CanonicalEncodingError.noncanonicalDate
        case .noncanonicalLabels: return CanonicalEncodingError.noncanonicalLabels
        case .unsupportedFormat: return CanonicalEncodingError.unsupportedFormat
        case .invalidIdentifier: return CanonicalEncodingError.invalidIdentifier
        case .invalidDiscriminant: return CanonicalEncodingError.invalidDiscriminant
        case .noncanonicalSet: return CanonicalEncodingError.noncanonicalSet
        case .invalidReference: return CanonicalEncodingError.invalidReference
        case .invalidOperation: return CanonicalEncodingError.invalidOperation
        case .identityMismatch: return CanonicalEncodingError.identityMismatch
        case .invalidCanonicalAction: return CanonicalEncodingError.invalidAction
        case .invalidPayload: return CanonicalEncodingError.invalidPayload
        case .wrongScope: return CanonicalEncodingError.wrongScope
        case .authenticationFailure: return CanonicalEncodingError.authenticationFailure
        }
    }
}

extension Database {
    /// Settles a rejected candidate together with its queue and dependency entries.
    func rejectReceived(_ id: SQLValue, reason: ReceiveRejection) throws {
        try requireHealthyHistory()
        try transaction {
            guard try rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [id]).isEmpty else {
                throw StorageError.integrity
            }
            try run("INSERT INTO rejected_objects VALUES(?,1,?) ON CONFLICT(object_id) DO NOTHING",
                    [id, .integer(reason.rawValue)])
            try run("DELETE FROM ready_objects WHERE object_id=?", [id])
            try run("DELETE FROM object_waits WHERE child=?", [id])
        }
    }

    func receivedRejection(_ id: SQLValue) throws -> ReceiveRejection? {
        guard let row = try rows("SELECT validator_version,reason FROM rejected_objects WHERE object_id=?", [id]).first else { return nil }
        guard row[0] == .integer(1), let reason = try ReceiveRejection(rawValue: row[1].number) else {
            throw StorageError.unsupported
        }
        return reason
    }
}
