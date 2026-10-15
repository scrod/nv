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
        if let error = error as? StorageError { self.init(storage: error) }
        else if let error = error as? OrdinaryHistoryError { self.init(history: error) }
        else if let error = error as? CanonicalEncodingError { self.init(encoding: error) }
        else if let error = error as? GeneralSnapshotError {
            switch error {
            case .invalidManifest: self = .invalidPayload
            case .invalidState: self = .invalidBeforeAfter
            case .missingObject: return nil
            }
        }
        else if let error = error as? InitialBootstrapValidationError {
            switch error {
            case .missingObject: return nil
            case .cyclicDependencies, .invalidCausalHistory: self = .invalidCausality
            case .conflictingClaim: self = .conflictingClaim
            case .invalidCommitment, .invalidSnapshot: self = .invalidPayload
            case .invalidActionHistory: self = .invalidAction
            case .requiresGeneralHistoryValidation: self = .laterReducer
            }
        }
        else { return nil }
    }

    private init?(storage error: StorageError) {
        switch error {
        case .unsupported: self = .unsupported
        case .ownership, .database, .wrongContext, .incomplete, .integrity, .closed, .busy, .staleCapture, .limit, .cancelled: return nil
        }
    }

    private init(history error: OrdinaryHistoryError) {
        switch error {
        case .conflictingClaim: self = .conflictingClaim
        case .invalidCausality: self = .invalidCausality
        case .invalidAction: self = .invalidAction
        case .invalidBeforeAfter: self = .invalidBeforeAfter
        case .reusedBirth: self = .reusedBirth
        case .requiresLaterReducer: self = .laterReducer
        }
    }

    private init?(encoding error: CanonicalEncodingError) {
        switch error {
        case .truncated: self = .truncated
        case .trailingBytes: self = .trailingBytes
        case .lengthLimit: self = .lengthLimit
        case .invalidUTF8: self = .invalidUTF8
        case .invalidDate: self = .invalidDate
        case .noncanonicalDate: self = .noncanonicalDate
        case .noncanonicalLabels: self = .noncanonicalLabels
        case .unsupportedFormat: self = .unsupportedFormat
        case .invalidIdentifier: self = .invalidIdentifier
        case .invalidDiscriminant: self = .invalidDiscriminant
        case .noncanonicalSet: self = .noncanonicalSet
        case .invalidReference: self = .invalidReference
        case .invalidOperation: self = .invalidOperation
        case .identityMismatch: self = .identityMismatch
        case .invalidAction: self = .invalidCanonicalAction
        case .invalidPayload: self = .invalidPayload
        case .wrongScope: self = .wrongScope
        case .authenticationFailure: self = .authenticationFailure
        case .missingDependency, .keyDerivationFailure: return nil
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
