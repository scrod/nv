/// The collection-wide or single-note domain in which action ancestry is tracked.
public enum ActionScopeV1: Equatable, Hashable, Sendable {
    case collection
    case note(NoteBirth)
}

public enum ActionKindV1: UInt8, Sendable {
    case savedEdit = 1, rename = 2, labels = 3, createImportBatch = 4, deleteBatch = 5
}

public enum ActionReference: Equatable, Hashable, Sendable {
    case external(locator: SegmentLocator, index: ActionIndex, expectedID: ActionID)
    case earlierLocal(index: ActionIndex)

    func expandedID(earlierActions: [ActionV1]) throws -> ActionID {
        switch self {
        case .external(_, _, let id): return id
        case .earlierLocal(let index):
            guard UInt64(index.rawValue) < UInt64(earlierActions.count) else {
                throw CanonicalEncodingError.invalidReference
            }
            return earlierActions[Int(index.rawValue)].id
        }
    }

    var encodedByteCount: UInt64 {
        switch self { case .external: 25; case .earlierLocal: 5 }
    }

    func encoded(dependencies: DependencyLocatorTable) throws -> [UInt8] {
        switch self {
        case .external(let locator, let index, let id):
            return try [0] + bigEndianBytes(dependencies.index(of: locator))
                + bigEndianBytes(index.rawValue) + id.bytes
        case .earlierLocal(let index): return [1] + bigEndianBytes(index.rawValue)
        }
    }

    static func decode(_ cursor: inout ByteCursor, dependencies: DependencyLocatorTable) throws -> Self {
        switch try cursor.byte() {
        case 0:
            let i = try cursor.unsigned32()
            guard UInt64(i) < UInt64(dependencies.entries.count) else {
                throw CanonicalEncodingError.invalidReference
            }
            return try .external(locator: dependencies.entries[Int(i)],
                index: ActionIndex(cursor.unsigned32()), expectedID: ActionID(bytes: cursor.fixedBytes(16)))
        case 1: return try .earlierLocal(index: ActionIndex(cursor.unsigned32()))
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
    }
}

public enum ActionStateV1: Equatable, Hashable, Sendable {
    case freshBirthAbsence
    case value(OperationID)
    case deleted(OperationID)
}

public enum ActionStateReference: Equatable, Hashable, Sendable {
    case freshBirthAbsence
    case value(OperationReference)
    case deleted(OperationReference)

    func expanded(operations: [IdentifiedOperation]) throws -> ActionStateV1 {
        switch self {
        case .freshBirthAbsence: return .freshBirthAbsence
        case .value(let ref): return try .value(ref.expandedID(earlierOperations: operations))
        case .deleted(let ref): return try .deleted(ref.expandedID(earlierOperations: operations))
        }
    }

    var encodedByteCount: UInt64 {
        switch self {
        case .freshBirthAbsence: 1
        case .value(let ref), .deleted(let ref): 1 + ref.encodedByteCount
        }
    }

    func encoded(dependencies: DependencyLocatorTable) throws -> [UInt8] {
        switch self {
        case .freshBirthAbsence: return [0]
        case .value(let ref): return try [1] + ref.encoded(dependencies: dependencies)
        case .deleted(let ref): return try [2] + ref.encoded(dependencies: dependencies)
        }
    }

    static func decode(_ cursor: inout ByteCursor, dependencies: DependencyLocatorTable) throws -> Self {
        switch try cursor.byte() {
        case 0: return .freshBirthAbsence
        case 1: return try .value(OperationReference.decode(&cursor, dependencies: dependencies))
        case 2: return try .deleted(OperationReference.decode(&cursor, dependencies: dependencies))
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
    }
}

public struct ActionAffectedStateV1: Equatable, Hashable, Sendable {
    public let birth: NoteBirth
    public let before: ActionStateV1
    public let after: ActionStateV1
}

public struct ActionAffectedReference: Equatable, Hashable, Sendable {
    public let birth: NoteBirth
    public let before: ActionStateReference
    public let after: ActionStateReference

    public init(birth: NoteBirth, before: ActionStateReference, after: ActionStateReference) {
        self.birth = birth
        self.before = before
        self.after = after
    }
}

/// Expanded semantic fields for comparing occurrences of an allocated action ID.
/// History validation resolves external IDs through their exact references.
public struct ActionV1: Equatable, Hashable, Sendable {
    public let id: ActionID
    public let origin: ActionOriginID
    public let previousOriginAction: ActionID?
    public let scope: ActionScopeV1
    public let scopeParents: [ActionID]
    public let kind: ActionKindV1
    public let members: [OperationID]
    public let affected: [ActionAffectedStateV1]
}

public struct ActionRecordV1: Equatable, Sendable {
    public let action: ActionV1
    public let previousOriginReference: ActionReference?
    public let scopeReferences: [ActionReference]
    public let memberIndices: [OperationIndex]
    public let affectedReferences: [ActionAffectedReference]

    /// `operations` is the already parsed complete operation section. State local
    /// references address that section; action local references address only earlier actions.
    public init(id: ActionID, origin: ActionOriginID, previousOrigin: ActionReference?,
                scope: ActionScopeV1, scopeParents: [ActionReference], kind: ActionKindV1,
                members: [OperationIndex], affected: [ActionAffectedReference],
                operations: [IdentifiedOperation], earlierActions: [ActionV1]) throws {
        guard !members.isEmpty, !affected.isEmpty else { throw CanonicalEncodingError.invalidAction }
        guard UInt64(members.count) <= ObjectLimitsV1.decodedPayloadBytes / 4,
              UInt64(affected.count) <= ObjectLimitsV1.decodedPayloadBytes / 18,
              UInt64(scopeParents.count) <= ObjectLimitsV1.decodedPayloadBytes / 5 else {
            throw CanonicalEncodingError.lengthLimit
        }
        guard Set(members).count == members.count else { throw CanonicalEncodingError.invalidAction }
        let previous = try previousOrigin?.expandedID(earlierActions: earlierActions)
        let parents = try scopeParents.map { ($0, try $0.expandedID(earlierActions: earlierActions)) }
            .sorted { $0.1.bytes.lexicographicallyPrecedes($1.1.bytes) }
        guard previous != id, !parents.contains(where: { $0.1 == id }),
              Set(parents.map(\.1)).count == parents.count else {
            throw CanonicalEncodingError.invalidAction
        }
        let sorted = affected.sorted { $0.birth.bytes.lexicographicallyPrecedes($1.birth.bytes) }
        guard Set(sorted.map(\.birth)).count == sorted.count,
              !sorted.contains(where: { $0.after == .freshBirthAbsence }) else {
            throw CanonicalEncodingError.invalidAction
        }
        self.previousOriginReference = previousOrigin
        self.scopeReferences = parents.map(\.0)
        self.memberIndices = members
        self.affectedReferences = sorted
        self.action = try ActionV1(id: id, origin: origin, previousOriginAction: previous,
            scope: scope, scopeParents: parents.map(\.1), kind: kind,
            members: members.map { try OperationReference.earlierLocal(index: $0).expandedID(earlierOperations: operations) },
            affected: sorted.map {
                try ActionAffectedStateV1(birth: $0.birth, before: $0.before.expanded(operations: operations),
                                         after: $0.after.expanded(operations: operations))
            })
        guard encodedByteCount <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
    }

    var encodedByteCount: UInt64 {
        var size: UInt64 = 16 + 16 + 1
        size += previousOriginReference?.encodedByteCount ?? 0
        size += 1 + 4 + 1 + 4
        size += 4 * UInt64(memberIndices.count) + 4
        if case .note = action.scope { size += 16 }
        for ref in scopeReferences { size += ref.encodedByteCount }
        for entry in affectedReferences { size += 16 + entry.before.encodedByteCount + entry.after.encodedByteCount }
        return size
    }

    func checkContext(operations: [IdentifiedOperation], earlierActions: [ActionV1]) throws {
        let rebound = try Self(id: action.id, origin: action.origin, previousOrigin: previousOriginReference,
            scope: action.scope, scopeParents: scopeReferences, kind: action.kind, members: memberIndices,
            affected: affectedReferences, operations: operations, earlierActions: earlierActions)
        guard rebound.action == action else { throw CanonicalEncodingError.invalidReference }
    }

    public func encodedV1(dependencies: DependencyLocatorTable, operations: [IdentifiedOperation],
                          earlierActions: [ActionV1]) throws -> [UInt8] {
        try checkContext(operations: operations, earlierActions: earlierActions)
        var bytes = action.id.bytes + action.origin.bytes
        if let previousOriginReference {
            bytes += try [1] + previousOriginReference.encoded(dependencies: dependencies)
        } else { bytes += [0] }
        switch action.scope {
        case .collection: bytes += [0]
        case .note(let birth): bytes += [1] + birth.bytes
        }
        bytes += bigEndianBytes(UInt32(scopeReferences.count))
        for ref in scopeReferences { bytes += try ref.encoded(dependencies: dependencies) }
        bytes += [action.kind.rawValue] + bigEndianBytes(UInt32(memberIndices.count))
        for index in memberIndices { bytes += bigEndianBytes(index.rawValue) }
        bytes += bigEndianBytes(UInt32(affectedReferences.count))
        for entry in affectedReferences {
            bytes += entry.birth.bytes
            bytes += try entry.before.encoded(dependencies: dependencies)
            bytes += try entry.after.encoded(dependencies: dependencies)
        }
        return bytes
    }

    public static func decodeV1(_ bytes: [UInt8], dependencies: DependencyLocatorTable,
                               operations: [IdentifiedOperation], earlierActions: [ActionV1]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        var cursor = ByteCursor(bytes: bytes)
        let id = try ActionID(bytes: cursor.fixedBytes(16))
        let origin = try ActionOriginID(bytes: cursor.fixedBytes(16))
        let previous: ActionReference?
        switch try cursor.byte() {
        case 0: previous = nil
        case 1: previous = try ActionReference.decode(&cursor, dependencies: dependencies)
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
        let scope: ActionScopeV1
        switch try cursor.byte() {
        case 0: scope = .collection
        case 1: scope = try .note(NoteBirth(bytes: cursor.fixedBytes(16)))
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
        let parentCount = try cursor.count(minimumElementBytes: 5)
        var parents: [ActionReference] = []
        for _ in 0..<parentCount { parents.append(try ActionReference.decode(&cursor, dependencies: dependencies)) }
        guard let kind = ActionKindV1(rawValue: try cursor.byte()) else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        let memberCount = try cursor.count(minimumElementBytes: 4)
        var members: [OperationIndex] = []
        for _ in 0..<memberCount { members.append(try OperationIndex(cursor.unsigned32())) }
        let affectedCount = try cursor.count(minimumElementBytes: 18)
        var affected: [ActionAffectedReference] = []
        for _ in 0..<affectedCount {
            affected.append(try ActionAffectedReference(birth: NoteBirth(bytes: cursor.fixedBytes(16)),
                before: ActionStateReference.decode(&cursor, dependencies: dependencies),
                after: ActionStateReference.decode(&cursor, dependencies: dependencies)))
        }
        try cursor.requireEnd()
        let record = try Self(id: id, origin: origin, previousOrigin: previous, scope: scope,
            scopeParents: parents, kind: kind, members: members, affected: affected,
            operations: operations, earlierActions: earlierActions)
        guard record.scopeReferences == parents, record.affectedReferences == affected else {
            throw CanonicalEncodingError.noncanonicalSet
        }
        return record
    }
}
