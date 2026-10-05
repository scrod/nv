/// The collection-wide or single-note domain in which action ancestry is tracked.
public enum ActionScopeV1: Equatable, Hashable, Sendable {
    case collection
    case note(NoteBirth)
}

public enum ActionKindV1: UInt8, Sendable {
    case savedEdit = 1, rename = 2, labels = 3, createImportBatch = 4, deleteBatch = 5, restoreBatch = 6
    case historicalRecovery = 7, conflictChoice = 8, conflictCopy = 9, undo = 10, redo = 11, nativeUndo = 12
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
    case derived(DerivedStateV1)
    case automatic(AutomaticSourceV1)

    public var represented: [OperationID] {
        switch self {
        case .freshBirthAbsence: []
        case .value(let id), .deleted(let id): [id]
        case .derived(let state): state.inputs
        case .automatic(let source): [source.revision]
        }
    }
}

public enum ActionStateReference: Equatable, Hashable, Sendable {
    case freshBirthAbsence
    case value(OperationReference)
    case deleted(OperationReference)
    case derived(DerivedStateReferenceV1)
    case automatic(AutomaticSourceReferenceV1)

    package func expanded(operations: [IdentifiedOperation]) throws -> ActionStateV1 {
        switch self {
        case .freshBirthAbsence: return .freshBirthAbsence
        case .value(let ref): return try .value(ref.expandedID(earlierOperations: operations))
        case .deleted(let ref): return try .deleted(ref.expandedID(earlierOperations: operations))
        case .derived(let ref):
            _ = try ref.encodedV1(dependencies: DependencyLocatorTable(Array(Set(ref.externalLocators))), earlierOperations: operations)
            return .derived(ref.state)
        case .automatic(let source): return try .automatic(source.expanded(operations))
        }
    }

    var encodedByteCount: UInt64 {
        switch self {
        case .freshBirthAbsence: 1
        case .value(let ref), .deleted(let ref): 1 + ref.encodedByteCount
        case .derived(let ref): ref.encodedByteCount
        case .automatic(let source): 1 + source.encodedByteCount
        }
    }

    func encoded(dependencies: DependencyLocatorTable, operations: [IdentifiedOperation] = []) throws -> [UInt8] {
        switch self {
        case .freshBirthAbsence: return [0]
        case .value(let ref): return try [1] + ref.encoded(dependencies: dependencies)
        case .deleted(let ref): return try [2] + ref.encoded(dependencies: dependencies)
        case .derived(let ref): return try ref.encodedV1(dependencies: dependencies, earlierOperations: operations)
        case .automatic(let source): return try [5] + source.encoded(dependencies)
        }
    }

    static func decode(_ cursor: inout ByteCursor, dependencies: DependencyLocatorTable,
                       operations: [IdentifiedOperation] = []) throws -> Self {
        let tag = try cursor.byte()
        switch tag {
        case 0: return .freshBirthAbsence
        case 1: return try .value(OperationReference.decode(&cursor, dependencies: dependencies))
        case 2: return try .deleted(OperationReference.decode(&cursor, dependencies: dependencies))
        case 3, 4: return try .derived(DerivedStateReferenceV1.decode(&cursor, dependencies: dependencies,
            earlierOperations: operations, tag: tag))
        case 5: return try .automatic(AutomaticSourceReferenceV1.decode(&cursor, dependencies: dependencies))
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
    public let restorations: [RestorationV1]
    public let details: ActionDetailsV1?
}

public struct ActionRecordV1: Equatable, Sendable {
    public let action: ActionV1
    public let previousOriginReference: ActionReference?
    public let scopeReferences: [ActionReference]
    public let memberIndices: [OperationIndex]
    public let affectedReferences: [ActionAffectedReference]
    public let restorationReferences: [RestorationReference]
    public let detailsReference: ActionDetailsReferenceV1?

    /// `operations` is the already parsed complete operation section. State local
    /// references address that section; action local references address only earlier actions.
    public init(id: ActionID, origin: ActionOriginID, previousOrigin: ActionReference?,
                scope: ActionScopeV1, scopeParents: [ActionReference], kind: ActionKindV1,
                members: [OperationIndex], affected: [ActionAffectedReference],
                operations: [IdentifiedOperation], earlierActions: [ActionV1],
                restorations: [RestorationReference] = [], details: ActionDetailsReferenceV1? = nil) throws {
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
        let sources = restorations.sorted { $0.birth.bytes.lexicographicallyPrecedes($1.birth.bytes) }
        if kind == .restoreBatch {
            guard scope == .collection, sources.map(\.birth) == sorted.map(\.birth),
                  sources.allSatisfy({ $0.birth != $0.sourceBirth }) else { throw CanonicalEncodingError.invalidAction }
        } else if !sources.isEmpty && kind != .undo && kind != .redo { throw CanonicalEncodingError.invalidAction }
        restorationReferences = sources
        switch (kind, details) {
        case (.historicalRecovery, .historical), (.conflictChoice, .choice), (.conflictCopy, .copy),
             (.undo, .compensation), (.redo, .compensation), (.nativeUndo, .native): break
        case (.savedEdit, nil), (.rename, nil), (.labels, nil), (.createImportBatch, nil),
             (.deleteBatch, nil), (.restoreBatch, nil): break
        default: throw CanonicalEncodingError.invalidAction
        }
        detailsReference = try details?.canonical(operations: operations, actions: earlierActions)
        self.action = try ActionV1(id: id, origin: origin, previousOriginAction: previous,
            scope: scope, scopeParents: parents.map(\.1), kind: kind,
            members: members.map { try OperationReference.earlierLocal(index: $0).expandedID(earlierOperations: operations) },
            affected: sorted.map {
                try ActionAffectedStateV1(birth: $0.birth, before: $0.before.expanded(operations: operations),
                                         after: $0.after.expanded(operations: operations))
            }, restorations: sources.map { try $0.expanded(operations: operations, earlierActions: earlierActions) },
            details: detailsReference?.expanded(operations: operations, actions: earlierActions))
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
        if action.kind == .restoreBatch || action.kind == .undo || action.kind == .redo {
            size += 4; for source in restorationReferences { size += source.encodedByteCount }
        }
        size += detailsReference?.encodedByteCount ?? 0
        return size
    }

    func checkContext(operations: [IdentifiedOperation], earlierActions: [ActionV1]) throws {
        let rebound = try Self(id: action.id, origin: action.origin, previousOrigin: previousOriginReference,
            scope: action.scope, scopeParents: scopeReferences, kind: action.kind, members: memberIndices,
            affected: affectedReferences, operations: operations, earlierActions: earlierActions, restorations: restorationReferences, details: detailsReference)
        guard rebound.action == action, rebound.scopeReferences == scopeReferences else {
            throw CanonicalEncodingError.invalidReference
        }
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
            bytes += try entry.before.encoded(dependencies: dependencies, operations: operations)
            bytes += try entry.after.encoded(dependencies: dependencies, operations: operations)
        }
        if action.kind == .restoreBatch || action.kind == .undo || action.kind == .redo {
            bytes += bigEndianBytes(UInt32(restorationReferences.count))
            for source in restorationReferences { bytes += try source.encoded(dependencies: dependencies, operations: operations) }
        }
        if let detailsReference { bytes += try detailsReference.encoded(dependencies: dependencies, operations: operations) }
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
                before: ActionStateReference.decode(&cursor, dependencies: dependencies, operations: operations),
                after: ActionStateReference.decode(&cursor, dependencies: dependencies, operations: operations)))
        }
        var restorations: [RestorationReference] = []
        if kind == .restoreBatch || kind == .undo || kind == .redo {
            let count = try cursor.count(minimumElementBytes: 42)
            for _ in 0..<count { restorations.append(try RestorationReference.decode(&cursor, dependencies: dependencies, operations: operations)) }
        }
        let details = try ActionDetailsReferenceV1.decode(&cursor, kind: kind, dependencies: dependencies, operations: operations)
        try cursor.requireEnd()
        let record = try Self(id: id, origin: origin, previousOrigin: previous, scope: scope,
            scopeParents: parents, kind: kind, members: members, affected: affected,
            operations: operations, earlierActions: earlierActions, restorations: restorations, details: details)
        guard record.scopeReferences == parents, record.affectedReferences == affected,
              record.restorationReferences == restorations, record.detailsReference == details else {
            throw CanonicalEncodingError.noncanonicalSet
        }
        return record
    }
}
