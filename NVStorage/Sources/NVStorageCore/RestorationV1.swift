/// Exact historical deletion and value named by a fresh-birth Restore member.
public struct RestorationV1: Equatable, Hashable, Sendable {
    public let birth: NoteBirth
    public let sourceBirth: NoteBirth
    public let deletionAction: ActionID
    public let revision: OperationID
    public let priorState: ActionStateV1?
}

/// Transport references binding a Restore member to its retained source entry.
public struct RestorationReference: Equatable, Sendable {
    public let birth: NoteBirth
    public let sourceBirth: NoteBirth
    public let deletionAction: ActionReference
    public let revision: OperationReference
    public let priorState: ActionStateReference?

    public init(birth: NoteBirth, sourceBirth: NoteBirth, deletionAction: ActionReference,
                revision: OperationReference, priorState: ActionStateReference? = nil) {
        self.birth = birth; self.sourceBirth = sourceBirth
        self.deletionAction = deletionAction; self.revision = revision; self.priorState = priorState
    }

    func expanded(operations: [IdentifiedOperation], earlierActions: [ActionV1]) throws -> RestorationV1 {
        if let priorState {
            switch priorState {
            case .derived, .automatic: break
            default: throw CanonicalEncodingError.invalidAction
            }
            guard try priorState.expanded(operations: operations).represented.contains(revision.expandedID(earlierOperations: operations)) else { throw CanonicalEncodingError.invalidAction }
        }
        return try RestorationV1(birth: birth, sourceBirth: sourceBirth,
            deletionAction: deletionAction.expandedID(earlierActions: earlierActions),
            revision: revision.expandedID(earlierOperations: operations), priorState: priorState?.expanded(operations: operations))
    }

    var encodedByteCount: UInt64 { 33 + deletionAction.encodedByteCount + revision.encodedByteCount + (priorState?.encodedByteCount ?? 0) }

    func encoded(dependencies: DependencyLocatorTable, operations: [IdentifiedOperation]) throws -> [UInt8] {
        var bytes = try birth.bytes + sourceBirth.bytes + deletionAction.encoded(dependencies: dependencies)
            + revision.encoded(dependencies: dependencies)
        bytes.append(priorState == nil ? 0 : 1)
        if let priorState { bytes += try priorState.encoded(dependencies: dependencies, operations: operations) }
        return bytes
    }

    static func decode(_ cursor: inout ByteCursor, dependencies: DependencyLocatorTable, operations: [IdentifiedOperation]) throws -> Self {
        let birth = try NoteBirth(bytes: cursor.fixedBytes(16)), source = try NoteBirth(bytes: cursor.fixedBytes(16))
        let deletion = try ActionReference.decode(&cursor, dependencies: dependencies)
        let revision = try OperationReference.decode(&cursor, dependencies: dependencies)
        let tag = try cursor.byte()
        guard tag <= 1 else { throw CanonicalEncodingError.invalidDiscriminant }
        let state = try tag == 1 ? ActionStateReference.decode(&cursor, dependencies: dependencies, operations: operations) : nil
        return Self(birth: birth, sourceBirth: source, deletionAction: deletion, revision: revision, priorState: state)
    }
}
