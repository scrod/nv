/// Complete prefix-relative logical state, including independently preserved work.
public struct CollectionReductionV1: Sendable {
    public struct Cell: Sendable {
        public let birth: NoteBirth
        public let value: PlaintextNoteValue
        public let represented: [OperationID]
        public let heads: [OperationID]
        public let merge: DerivedMergeV1?
        public let automatic: AutomaticSourceV1?
    }
    public let cells: [Cell]
    public let retired: Set<DeterministicConflictIdentityV1>
    public let dispositions: Set<OperationID>

    /// Reduces a complete validated history, using causal coverage and note replacement
    /// as independent inputs to source selection.
    public static func compute(collection: CollectionID, operations: [IdentifiedOperation], actions: [ActionV1]) throws -> Self {
        try compute(collection: collection, operations: operations, actions: actions, affectedBirths: nil)
    }

    /// Recomputes selected scopes with the same causal and preservation rules as complete reduction.
    package static func compute(collection: CollectionID, operations: [IdentifiedOperation], actions: [ActionV1],
                                affectedBirths: Set<NoteBirth>?) throws -> Self {
        var graph: [OperationID: IdentifiedOperation] = [:]
        for operation in operations {
            guard graph.updateValue(operation, forKey: operation.id) == nil else { throw CanonicalEncodingError.invalidOperation }
        }
        func past(_ id: OperationID) throws -> Set<OperationID> {
            var seen: Set<OperationID> = [], work = graph[id]?.causalParents.ids ?? []
            while let next = work.popLast() {
                try Task.checkCancellation()
                guard next != id, let op = graph[next] else { throw CanonicalEncodingError.missingDependency }
                if seen.insert(next).inserted { work += op.causalParents.ids }
            }
            return seen
        }
        let groups = Dictionary(grouping: operations.filter { $0.effect.targetBirth != nil }, by: { $0.effect.targetBirth! })
        let retired = Set(operations.compactMap { op -> DeterministicConflictIdentityV1? in
            if case .retireConflict(_, _, let identity) = op.effect { return identity }; return nil
        })
        var cells: [NoteBirth: Cell] = [:], eligible: [AutomaticConflictKeyV1: [IdentifiedOperation]] = [:]
        for (birth, records) in groups {
            if let affectedBirths, !affectedBirths.contains(birth) { continue }
            let reduction = try NoteReductionV1.compute(collection: collection, birth: birth, operations: records)
            switch reduction.outcome {
            case .empty: break
            case .current(let current), .conflict(let current, _):
                cells[birth] = Cell(birth: birth, value: current.value, represented: current.represented,
                                    heads: reduction.heads, merge: current.merge, automatic: nil)
            case .deletionRequired(let deletes):
                var covered: Set<OperationID> = []
                for deletion in deletes { covered.formUnion(try past(deletion)) }
                let uncovered = Set(reduction.heads).subtracting(covered)
                for id in uncovered {
                    guard let op = graph[id], let value = op.effect.noteValue else { throw CanonicalEncodingError.invalidOperation }
                    let key = try AutomaticConflictKeyV1.compute(source: birth, value: value)
                    if !retired.contains(.automatic(key)) { eligible[key, default: []].append(op) }
                }
            }
        }
        for (key, sources) in eligible {
            let birth = try key.birth()
            // A user-authored revision at this birth remains an ordinary live note.
            if groups[birth] != nil { continue }
            guard let op = sources.sorted(by: { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) }).first,
                  let sourceBirth = op.effect.targetBirth, let value = op.effect.noteValue else { throw CanonicalEncodingError.invalidOperation }
            cells[birth] = try Cell(birth: birth, value: value.conflictCopyValue(), represented: [op.id],
                heads: [op.id], merge: nil, automatic: .init(birth: sourceBirth, revision: op.id, key: key))
        }
        let dispositions = Set(actions.compactMap { action -> OperationID? in
            if case .copy(_, let revision, _, _, _) = action.details { return revision }; return nil
        })
        return Self(cells: cells.values.sorted { $0.birth.bytes.lexicographicallyPrecedes($1.birth.bytes) }, retired: retired, dispositions: dispositions)
    }
}
