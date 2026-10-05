/// Fields explicitly selected in a historical recovery preview.
public struct HistoryFieldsV1: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let body = Self(rawValue: 1)
    public static let title = Self(rawValue: 2)
    public static let labels = Self(rawValue: 4)
    public static let all: Self = [.body, .title, .labels]
}

/// Durable remaining-effect statement for one saved-edit group.
public struct NativeCoverageV1: Equatable, Hashable, Sendable {
    public let action: ActionID
    public let remaining: ActionStateV1
    public let complete: Bool
}

public struct NativeCoverageReferenceV1: Equatable, Hashable, Sendable {
    public let action: ActionReference
    public let remaining: ActionStateReference
    public let complete: Bool
    public init(action: ActionReference, remaining: ActionStateReference, complete: Bool) {
        self.action = action; self.remaining = remaining; self.complete = complete
    }
}

/// Expanded command-specific provenance compared across occurrences of an action ID.
public enum ActionDetailsV1: Equatable, Hashable, Sendable {
    case historical(source: NoteBirth, revision: OperationID, fields: HistoryFieldsV1 = .body)
    case choice(selected: OperationID, heads: [OperationID])
    case copy(source: NoteBirth, revision: OperationID, key: ConflictRecoveryKeyV1, slot: UInt64, reused: OperationID?)
    case compensation(target: ActionID, reviewed: Bool)
    case native([NativeCoverageV1])
}

/// Transport references for source choice, exact preservation and actual compensation.
public enum ActionDetailsReferenceV1: Equatable, Hashable, Sendable {
    case historical(source: NoteBirth, revision: OperationReference, fields: HistoryFieldsV1 = .body)
    case choice(selected: OperationReference, heads: [OperationReference])
    case copy(source: NoteBirth, revision: OperationReference, key: ConflictRecoveryKeyV1, slot: UInt64, reused: OperationReference?)
    case compensation(target: ActionReference, reviewed: Bool)
    case native([NativeCoverageReferenceV1])

    package func expanded(operations: [IdentifiedOperation], actions: [ActionV1]) throws -> ActionDetailsV1 {
        switch self {
        case .historical(let source, let ref, let fields): return try .historical(source: source, revision: ref.expandedID(earlierOperations: operations), fields: fields)
        case .choice(let selected, let refs):
            return try .choice(selected: selected.expandedID(earlierOperations: operations),
                               heads: refs.map { try $0.expandedID(earlierOperations: operations) })
        case .copy(let source, let ref, let key, let slot, let reused):
            return try .copy(source: source, revision: ref.expandedID(earlierOperations: operations), key: key,
                             slot: slot, reused: reused?.expandedID(earlierOperations: operations))
        case .compensation(let target, let reviewed): return try .compensation(target: target.expandedID(earlierActions: actions), reviewed: reviewed)
        case .native(let coverage): return try .native(coverage.map {
            try NativeCoverageV1(action: $0.action.expandedID(earlierActions: actions), remaining: $0.remaining.expanded(operations: operations), complete: $0.complete)
        })
        }
    }

    package func canonical(operations: [IdentifiedOperation], actions: [ActionV1]) throws -> Self {
        switch self {
        case .historical(_, _, let fields):
            guard fields.rawValue > 0, fields.rawValue <= 7 else { throw CanonicalEncodingError.invalidAction }; return self
        case .choice(let selected, let heads):
            let sorted = try heads.map { ($0, try $0.expandedID(earlierOperations: operations)) }.sorted { $0.1.bytes.lexicographicallyPrecedes($1.1.bytes) }
            guard !sorted.isEmpty, Set(sorted.map(\.1)).count == sorted.count else { throw CanonicalEncodingError.invalidAction }
            return .choice(selected: selected, heads: sorted.map(\.0))
        case .native(let coverage):
            let sorted = try coverage.map { ($0, try $0.action.expandedID(earlierActions: actions)) }.sorted { $0.1.bytes.lexicographicallyPrecedes($1.1.bytes) }
            guard !sorted.isEmpty, Set(sorted.map(\.1)).count == sorted.count else { throw CanonicalEncodingError.invalidAction }
            return .native(sorted.map(\.0))
        default: return self
        }
    }

    package var operationReferences: [OperationReference] {
        switch self {
        case .historical(_, let revision, _): [revision]
        case .choice(let selected, let heads): [selected] + heads
        case .copy(_, let revision, _, _, let reused): [revision] + (reused.map { [$0] } ?? [])
        case .compensation: []
        case .native(let records): records.flatMap { $0.remaining.operationReferences }
        }
    }
    package var actionReferences: [ActionReference] {
        switch self { case .compensation(let target, _): [target]; case .native(let records): records.map(\.action); default: [] }
    }
    var encodedByteCount: UInt64 {
        switch self {
        case .historical(_, let revision, _): 17 + revision.encodedByteCount
        case .choice(let selected, let heads): 4 + selected.encodedByteCount + heads.reduce(0) { $0 + $1.encodedByteCount }
        case .copy(_, let revision, _, _, let reused): 16 + 32 + 8 + revision.encodedByteCount + 1 + (reused?.encodedByteCount ?? 0)
        case .compensation(let target, _): 1 + target.encodedByteCount
        case .native(let records): 4 + records.reduce(0) { $0 + $1.action.encodedByteCount + $1.remaining.encodedByteCount + 1 }
        }
    }

    func encoded(dependencies: DependencyLocatorTable, operations: [IdentifiedOperation]) throws -> [UInt8] {
        switch self {
        case .historical(let source, let revision, let fields): return try source.bytes + revision.encoded(dependencies: dependencies) + [fields.rawValue]
        case .choice(let selected, let heads):
            var bytes = try selected.encoded(dependencies: dependencies) + bigEndianBytes(UInt32(heads.count))
            for ref in heads { bytes += try ref.encoded(dependencies: dependencies) }; return bytes
        case .copy(let source, let revision, let key, let slot, let reused):
            var bytes = try source.bytes + revision.encoded(dependencies: dependencies) + key.bytes + bigEndianBytes(slot)
            bytes += try reused.map { [1] + (try $0.encoded(dependencies: dependencies)) } ?? [0]; return bytes
        case .compensation(let target, let reviewed): return try target.encoded(dependencies: dependencies) + [reviewed ? 1 : 0]
        case .native(let records):
            var bytes = bigEndianBytes(UInt32(records.count))
            for record in records {
                bytes += try record.action.encoded(dependencies: dependencies)
                bytes += try record.remaining.encoded(dependencies: dependencies, operations: operations)
                bytes += [record.complete ? 1 : 0]
            }; return bytes
        }
    }

    static func decode(_ cursor: inout ByteCursor, kind: ActionKindV1, dependencies: DependencyLocatorTable,
                       operations: [IdentifiedOperation]) throws -> Self? {
        switch kind {
        case .historicalRecovery: return try .historical(source: NoteBirth(bytes: cursor.fixedBytes(16)), revision: OperationReference.decode(&cursor, dependencies: dependencies), fields: HistoryFieldsV1(rawValue: cursor.byte()))
        case .conflictChoice:
            let selected = try OperationReference.decode(&cursor, dependencies: dependencies)
            var heads: [OperationReference] = []
            for _ in 0..<(try cursor.count(minimumElementBytes: 5)) { heads.append(try OperationReference.decode(&cursor, dependencies: dependencies)) }
            return .choice(selected: selected, heads: heads)
        case .conflictCopy:
            let source = try NoteBirth(bytes: cursor.fixedBytes(16)), revision = try OperationReference.decode(&cursor, dependencies: dependencies)
            let key = try ConflictRecoveryKeyV1(bytes: cursor.fixedBytes(32)), slot = try cursor.unsigned64()
            let reused: OperationReference?
            switch try cursor.byte() { case 0: reused = nil; case 1: reused = try OperationReference.decode(&cursor, dependencies: dependencies); default: throw CanonicalEncodingError.invalidDiscriminant }
            return .copy(source: source, revision: revision, key: key, slot: slot, reused: reused)
        case .undo, .redo:
            let target = try ActionReference.decode(&cursor, dependencies: dependencies), flag = try cursor.byte()
            guard flag <= 1 else { throw CanonicalEncodingError.invalidDiscriminant }
            return .compensation(target: target, reviewed: flag == 1)
        case .nativeUndo:
            var records: [NativeCoverageReferenceV1] = []
            for _ in 0..<(try cursor.count(minimumElementBytes: 7)) {
                let action = try ActionReference.decode(&cursor, dependencies: dependencies)
                let state = try ActionStateReference.decode(&cursor, dependencies: dependencies, operations: operations), flag = try cursor.byte()
                guard flag <= 1 else { throw CanonicalEncodingError.invalidDiscriminant }
                records.append(.init(action: action, remaining: state, complete: flag == 1))
            }; return .native(records)
        default: return nil
        }
    }
}

extension ActionStateReference {
    var operationReferences: [OperationReference] {
        switch self { case .freshBirthAbsence: []; case .value(let ref), .deleted(let ref): [ref]
        case .derived(let ref): ref.references; case .automatic(let source): [source.revision] }
    }
}
