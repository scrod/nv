import NVStorageCore

// Frozen pre-actor validator supplies an independent synchronous comparison oracle.
/// Checks ordinary groups against their declared causal past. The supplied history
/// readers resolve already validated records through their retained occurrences.
enum SynchronousHistoryReference {
    static func validate(_ payload: ChangesPayloadV1, at locator: SegmentLocator,
        payloadAt: (SegmentLocator) throws -> ChangesPayloadV1?,
        operationByID: (OperationID) throws -> IdentifiedOperation?,
        actionByID: (ActionID) throws -> ActionV1?,
        birthExists: (NoteBirth) throws -> Bool) throws {
        try validate(payload, at: locator, payloadAt: payloadAt, operationByID: operationByID,
            actionByID: actionByID, birthExists: birthExists, visitingAncestor: {})
    }

    static func validate(_ payload: ChangesPayloadV1, at locator: SegmentLocator,
        payloadAt: (SegmentLocator) throws -> ChangesPayloadV1?,
        operationByID: (OperationID) throws -> IdentifiedOperation?,
        actionByID: (ActionID) throws -> ActionV1?,
        birthExists: (NoteBirth) throws -> Bool, visitingAncestor: () -> Void) throws {
        try payload.checkExternalReferences(at: locator, resolve: payloadAt)
        let localOps = Dictionary(uniqueKeysWithValues: payload.operations.map { ($0.operation.id, $0.operation) })
        let localActions = Dictionary(uniqueKeysWithValues: payload.actions.map { ($0.action.id, $0.action) })
        func operation(_ id: OperationID) throws -> IdentifiedOperation {
            guard let result = try localOps[id] ?? operationByID(id), result.id == id else {
                throw CanonicalEncodingError.missingDependency
            }
            return result
        }
        func action(_ id: ActionID) throws -> ActionV1 {
            guard let result = try localActions[id] ?? actionByID(id), result.id == id else {
                throw CanonicalEncodingError.missingDependency
            }
            return result
        }
        for record in payload.operations {
            let op = record.operation
            if let old = try operationByID(op.id) {
                guard old == op else { throw OrdinaryHistoryError.conflictingClaim }
                continue
            }
            switch op.effect {
            case .genesis, .importComplete, .importNote, .recoverCopy, .retireConflict, .adoptAutomatic: throw OrdinaryHistoryError.requiresLaterReducer
            case .create(_, let birth, _):
                if try operationByID(op.id) == nil, try birthExists(birth) { throw OrdinaryHistoryError.reusedBirth }
            case .put, .delete: break
            }
        }
        for record in payload.actions {
            let a = record.action, members = Set(record.action.members)
            if let old = try actionByID(a.id) {
                guard old == a else { throw OrdinaryHistoryError.conflictingClaim }
                continue
            }
            var basis: Set<OperationID> = [], active: Set<OperationID> = []
            var stack = a.members.map { ($0, false) }
            while let (id, leaving) = stack.popLast() {
                if leaving { active.remove(id); basis.insert(id); continue }
                guard !active.contains(id) else { throw OrdinaryHistoryError.invalidCausality }
                if basis.contains(id) { continue }
                visitingAncestor()
                active.insert(id); stack.append((id, true))
                stack += try operation(id).causalParents.ids.map { ($0, false) }
            }
            basis.subtract(members)
            var observed: [ActionID: ActionV1] = [:]
            for id in basis {
                if let actionID = try operation(id).effect.actionID, observed[actionID] == nil {
                    let prior = try action(actionID)
                    guard Set(prior.members).isSubset(of: basis) else { throw OrdinaryHistoryError.invalidAction }
                    observed[actionID] = prior
                }
            }
            var maxima = Set(observed.values.filter { $0.scope == a.scope }.map(\.id))
            for prior in Array(maxima) { maxima.subtract(observed[prior]!.scopeParents) }
            var states: [NoteBirth: ReferenceNoteInputs] = [:]
            for entry in a.affected {
                var priorValues: [OperationID: IdentifiedOperation] = [:]
                var deleted = false
                for id in basis {
                    let op = try operation(id)
                    guard op.effect.targetBirth == entry.birth else { continue }
                    switch op.effect {
                    case .delete: deleted = true
                    default: priorValues[id] = op
                    }
                }
                var heads = Set(priorValues.keys)
                for op in priorValues.values { heads.subtract(op.notePredecessors.ids) }
                if a.kind == .createImportBatch, !priorValues.isEmpty { throw OrdinaryHistoryError.reusedBirth }
                states[entry.birth] = ReferenceNoteInputs(heads: heads, deleted: deleted)
            }
            try validateAction(a, scopeMaxima: maxima, states: states, operation: operation,
                previousOriginIsObserved: { observed[$0]?.origin == a.origin },
                observes: { id, op in try causalPast(op, operation: operation, visitingAncestor: visitingAncestor).contains(id) })
        }
    }

    /// Applies ordinary action rules to prior note states supplied by the history reader.
    static func validateAction(_ a: ActionV1, scopeMaxima: Set<ActionID>,
        states: [NoteBirth: ReferenceNoteInputs], operation: (OperationID) throws -> IdentifiedOperation,
        previousOriginIsObserved: (ActionID) throws -> Bool,
        observes: (OperationID, IdentifiedOperation) throws -> Bool) throws {
        guard scopeMaxima == Set(a.scopeParents) else { throw OrdinaryHistoryError.invalidAction }
        if let previous = a.previousOriginAction {
            guard try previousOriginIsObserved(previous) else { throw OrdinaryHistoryError.invalidAction }
        }
        let groups = try Dictionary(grouping: a.members.map(operation), by: { $0.effect.targetBirth })
        for entry in a.affected {
            guard let prior = states[entry.birth] else { throw OrdinaryHistoryError.invalidBeforeAfter }
            var heads = prior.heads, deleted = prior.deleted
            guard let group = groups[entry.birth], !group.isEmpty else { throw OrdinaryHistoryError.invalidAction }
            if a.kind == .createImportBatch {
                guard heads.isEmpty, !deleted, entry.before == .freshBirthAbsence,
                      group.count == 1, case .create = group[0].effect else { throw OrdinaryHistoryError.reusedBirth }
            } else {
                guard !deleted else { throw OrdinaryHistoryError.invalidBeforeAfter }
                guard heads.count == 1, let head = heads.first else { throw OrdinaryHistoryError.requiresLaterReducer }
                guard entry.before == .value(head) else { throw OrdinaryHistoryError.invalidBeforeAfter }
            }
            // Validate each member against the value it edits and bind the declared
            // after-state to the final member's result.
            for op in group {
                switch op.effect {
                case .create: heads = [op.id]
                case .put:
                    guard heads == Set(op.notePredecessors.ids), !deleted else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    guard try heads.allSatisfy({ try observes($0, op) }) else { throw OrdinaryHistoryError.invalidCausality }
                    heads = [op.id]
                case .delete:
                    guard !deleted, heads.count == 1,
                          try heads.allSatisfy({ try observes($0, op) }) else {
                        throw OrdinaryHistoryError.invalidBeforeAfter
                    }
                    deleted = true; heads = [op.id]
                default: throw OrdinaryHistoryError.requiresLaterReducer
                }
            }
            guard heads.count == 1, let after = heads.first,
                  entry.after == (deleted ? .deleted(after) : .value(after)) else {
                throw OrdinaryHistoryError.invalidBeforeAfter
            }
        }
    }

    private static func causalPast(_ op: IdentifiedOperation,
        operation: (OperationID) throws -> IdentifiedOperation, visitingAncestor: () -> Void) throws -> Set<OperationID> {
        var seen: Set<OperationID> = [], work = op.causalParents.ids
        while let id = work.popLast() {
            guard id != op.id else { throw OrdinaryHistoryError.invalidCausality }
            if seen.insert(id).inserted { visitingAncestor(); work += try operation(id).causalParents.ids }
        }
        return seen
    }
}

/// Prior note revisions used as inputs to the ordinary action rules.
struct ReferenceNoteInputs {
    let heads: Set<OperationID>
    let deleted: Bool
    init(heads: Set<OperationID>, deleted: Bool) { self.heads = heads; self.deleted = deleted }
}
