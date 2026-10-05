/// Semantic rejection categories for the single-value ordinary-action reducer.
public enum OrdinaryHistoryError: Error, Equatable, Sendable {
    case conflictingClaim, invalidCausality, invalidAction, invalidBeforeAfter, reusedBirth
    case requiresLaterReducer
}

/// Checks ordinary groups against their declared causal past. The supplied history
/// readers resolve already validated records through their retained occurrences.
public enum OrdinaryHistoryV1 {
    public static func validate(_ payload: ChangesPayloadV1, at locator: SegmentLocator, collection: CollectionID? = nil,
        payloadAt: (SegmentLocator) async throws -> ChangesPayloadV1?,
        operationByID: (OperationID) async throws -> IdentifiedOperation?,
        actionByID: (ActionID) async throws -> ActionV1?,
        birthExists: (NoteBirth) async throws -> Bool) async throws {
        try await validate(payload, at: locator, collection: collection, payloadAt: payloadAt, operationByID: operationByID,
            actionByID: actionByID, birthExists: birthExists, visitingAncestor: {})
    }

    package static func validate(_ payload: ChangesPayloadV1, at locator: SegmentLocator, collection: CollectionID? = nil,
        payloadAt: (SegmentLocator) async throws -> ChangesPayloadV1?,
        operationByID: (OperationID) async throws -> IdentifiedOperation?,
        actionByID: (ActionID) async throws -> ActionV1?,
        birthExists: (NoteBirth) async throws -> Bool, visitingAncestor: () -> Void) async throws {
        try await payload.checkExternalReferences(at: locator, resolve: payloadAt)
        let localOps = Dictionary(uniqueKeysWithValues: payload.operations.map { ($0.operation.id, $0.operation) })
        let localActions = Dictionary(uniqueKeysWithValues: payload.actions.map { ($0.action.id, $0.action) })
        func operation(_ id: OperationID) async throws -> IdentifiedOperation {
            let resolved = localOps[id] != nil ? localOps[id] : try await operationByID(id)
            guard let result = resolved, result.id == id else {
                throw CanonicalEncodingError.missingDependency
            }
            return result
        }
        func action(_ id: ActionID) async throws -> ActionV1 {
            let resolved = localActions[id] != nil ? localActions[id] : try await actionByID(id)
            guard let result = resolved, result.id == id else {
                throw CanonicalEncodingError.missingDependency
            }
            return result
        }
        for record in payload.operations {
            let op = record.operation
            if let old = try await operationByID(op.id) {
                guard old == op else { throw OrdinaryHistoryError.conflictingClaim }
                continue
            }
            switch op.effect {
            case .genesis, .importComplete, .importNote: throw OrdinaryHistoryError.requiresLaterReducer
            case .create(_, let birth, _):
                if try await operationByID(op.id) == nil, try await birthExists(birth) { throw OrdinaryHistoryError.reusedBirth }
            case .put, .delete, .recoverCopy, .retireConflict, .adoptAutomatic: break
            }
        }
        for record in payload.actions {
            let a = record.action, members = Set(record.action.members)
            if let old = try await actionByID(a.id) {
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
                stack += try await operation(id).causalParents.ids.map { ($0, false) }
            }
            basis.subtract(members)
            var observed: [ActionID: ActionV1] = [:]
            for id in basis {
                if let actionID = try await operation(id).effect.actionID, observed[actionID] == nil {
                    let prior = try await action(actionID)
                    guard Set(prior.members).isSubset(of: basis) else { throw OrdinaryHistoryError.invalidAction }
                    observed[actionID] = prior
                }
            }
            var maxima = Set(observed.values.filter { $0.scope == a.scope }.map(\.id))
            for prior in Array(maxima) { maxima.subtract(observed[prior]!.scopeParents) }
            guard Set(a.scopeParents) == maxima else { throw OrdinaryHistoryError.invalidAction }
            var states: [NoteBirth: OrdinaryNoteInputsV1] = [:]
            var basisOperations: [IdentifiedOperation] = []
            for id in basis { basisOperations.append(try await operation(id)) }
            var collectionState: CollectionReductionV1?
            if a.details != nil || a.affected.contains(where: { if case .automatic = $0.before { true } else { false } }) {
                guard let collection else { throw OrdinaryHistoryError.invalidBeforeAfter }
                collectionState = try CollectionReductionV1.compute(collection: collection, operations: basisOperations, actions: Array(observed.values))
            }
            for entry in a.affected {
                var priorValues: [OperationID: IdentifiedOperation] = [:]
                var deleted = false
                for id in basis {
                    let op = try await operation(id)
                    guard op.effect.targetBirth == entry.birth else { continue }
                    switch op.effect {
                    case .delete: deleted = true
                    case .retireConflict: break
                    case .recoverCopy(_, _, let source, _) where source.reused != nil: break
                    default: if op.effect.noteValue != nil { priorValues[id] = op }
                    }
                }
                var heads = Set(priorValues.keys)
                for op in priorValues.values { heads.subtract(op.notePredecessors.ids) }
                if (a.kind == .createImportBatch || a.kind == .restoreBatch), !priorValues.isEmpty { throw OrdinaryHistoryError.reusedBirth }
                var represented = heads
                if case .value(let id) = entry.before {
                    guard heads.contains(id) else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    represented = [id]
                } else if case .derived(let state) = entry.before {
                    guard let collection, let reference = record.affectedReferences.first(where: { $0.birth == entry.birth }),
                          case .derived(let ref) = reference.before,
                          !deleted else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    let checked = try await ref.reconstruct(collection: collection, birth: entry.birth,
                        history: Array(priorValues.values), earlierOperations: payload.operations.map(\.operation),
                        at: locator, resolve: payloadAt)
                    guard checked.reference.state == state else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    represented = Set(state.inputs)
                } else if case .automatic(let source) = entry.before {
                    guard let cell = collectionState?.cells.first(where: { $0.birth == entry.birth }),
                          cell.automatic == source else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    represented = [source.revision]; deleted = false
                }
                if a.kind == .conflictChoice { represented = heads }
                states[entry.birth] = OrdinaryNoteInputsV1(heads: represented, deleted: deleted, before: entry.before)
            }
            var requirements = try actionRequirements(a, scopeMaxima: maxima, states: states,
                operation: { id in
                    guard let op = localOps[id] else { throw CanonicalEncodingError.missingDependency }
                    return op
                }, previousOriginIsObserved: { observed[$0]?.origin == a.origin })
            for source in a.restorations {
                guard let deletion = observed[source.deletionAction],
                      let entry = deletion.affected.first(where: { $0.birth == source.sourceBirth }),
                      case .deleted(let deleteID) = entry.after,
                      let created = a.affected.first(where: { $0.birth == source.birth }),
                      case .value(let createdID) = created.after else { throw OrdinaryHistoryError.invalidAction }
                let revision = try await operation(source.revision)
                let referenceBirth: NoteBirth
                if case .automatic(let automatic) = source.priorState { referenceBirth = automatic.birth }
                else { referenceBirth = source.sourceBirth }
                guard revision.effect.targetBirth == referenceBirth else { throw OrdinaryHistoryError.invalidAction }
                guard basis.contains(source.revision), !deletion.members.contains(source.revision), revision.effect.noteValue != nil else { throw OrdinaryHistoryError.invalidAction }
                let member = try await operation(createdID)
                if let state = source.priorState {
                    guard state == entry.before else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    var records: [OperationID: IdentifiedOperation] = [:]
                    for id in state.represented { records[id] = try await operation(id) }
                    if case .derived(.merged(_, let base, _, _)) = state { records[base] = try await operation(base) }
                    guard try CompensationV1.value(state, operations: records) == value(member) else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    for id in state.represented {
                        guard basis.contains(id) else { throw OrdinaryHistoryError.invalidCausality }
                        requirements.append(CausalRequirement(parent: id, operation: member, failure: .invalidCausality))
                    }
                } else {
                    guard value(revision) != nil, value(revision) == value(member) else { throw OrdinaryHistoryError.invalidBeforeAfter }
                }
                requirements.append(CausalRequirement(parent: deleteID, operation: member, failure: .invalidCausality))
                requirements.append(CausalRequirement(parent: source.revision, operation: member, failure: .invalidCausality))
            }
            try validateDetails(a, observed: observed, basisOperations: basisOperations, state: collectionState,
                localOperations: localOps)
            for requirement in requirements {
                let past = try await causalPast(requirement.operation, operation: operation,
                                                visitingAncestor: visitingAncestor)
                guard past.contains(requirement.parent) else { throw requirement.failure }
            }
        }
    }

    /// Applies ordinary action rules to prior note states supplied by the history reader.
    package static func validateAction(_ a: ActionV1, scopeMaxima: Set<ActionID>,
        states: [NoteBirth: OrdinaryNoteInputsV1], operation: (OperationID) throws -> IdentifiedOperation,
        previousOriginIsObserved: (ActionID) throws -> Bool,
        observes: (OperationID, IdentifiedOperation) throws -> Bool) throws {
        guard a.restorations.isEmpty, a.details == nil else { throw OrdinaryHistoryError.requiresLaterReducer }
        for requirement in try actionRequirements(a, scopeMaxima: scopeMaxima, states: states,
            operation: operation, previousOriginIsObserved: previousOriginIsObserved) {
            guard try observes(requirement.parent, requirement.operation) else { throw requirement.failure }
        }
    }

    private struct CausalRequirement {
        let parent: OperationID
        let operation: IdentifiedOperation
        let failure: OrdinaryHistoryError
    }

    /// Checks action structure and emits the exact remaining ancestry obligations.
    private static func actionRequirements(_ a: ActionV1, scopeMaxima: Set<ActionID>,
        states: [NoteBirth: OrdinaryNoteInputsV1], operation: (OperationID) throws -> IdentifiedOperation,
        previousOriginIsObserved: (ActionID) throws -> Bool) throws -> [CausalRequirement] {
        var requirements: [CausalRequirement] = []
        guard scopeMaxima == Set(a.scopeParents) else { throw OrdinaryHistoryError.invalidAction }
        if let previous = a.previousOriginAction {
            guard try previousOriginIsObserved(previous) else { throw OrdinaryHistoryError.invalidAction }
        }
        let groups = try Dictionary(grouping: a.members.map(operation), by: { $0.effect.targetBirth })
        for entry in a.affected {
            guard let prior = states[entry.birth] else { throw OrdinaryHistoryError.invalidBeforeAfter }
            var heads = prior.heads, deleted = prior.deleted
            guard let group = groups[entry.birth], !group.isEmpty else { throw OrdinaryHistoryError.invalidAction }
            let substantive = group.filter { if case .retireConflict = $0.effect { false } else { true } }
            if entry.before == .freshBirthAbsence {
                guard heads.isEmpty, !deleted, entry.before == .freshBirthAbsence,
                      substantive.count == 1 else { throw OrdinaryHistoryError.reusedBirth }
                switch substantive[0].effect {
                case .create, .recoverCopy: break
                default: throw OrdinaryHistoryError.invalidBeforeAfter
                }
            } else {
                guard !deleted else { throw OrdinaryHistoryError.invalidBeforeAfter }
                guard !heads.isEmpty, entry.before == (prior.before ?? heads.first.map { .value($0) }),
                      a.kind == .conflictChoice || Set(entry.before.represented) == heads else { throw OrdinaryHistoryError.invalidBeforeAfter }
            }
            // Validate each member against the value it edits and bind the declared
            // after-state to the final member's result.
            for op in group {
                switch op.effect {
                case .create: heads = [op.id]
                case .recoverCopy: heads = [op.id]
                case .adoptAutomatic:
                    guard case .automatic(let source) = entry.before, heads == [source.revision] else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    requirements.append(CausalRequirement(parent: source.revision, operation: op, failure: .invalidCausality)); heads = [op.id]
                case .put:
                    guard heads == Set(op.notePredecessors.ids), !deleted else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    requirements += heads.map { CausalRequirement(parent: $0, operation: op, failure: .invalidCausality) }
                    heads = [op.id]
                case .delete:
                    guard !deleted, !heads.isEmpty else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    requirements += heads.map { CausalRequirement(parent: $0, operation: op, failure: .invalidBeforeAfter) }
                    deleted = true; heads = [op.id]
                case .retireConflict(_, let birth, let identity):
                    guard deleted, try identity.birth() == birth, group.contains(where: { if case .delete = $0.effect { true } else { false } }) else { throw OrdinaryHistoryError.invalidAction }
                default: throw OrdinaryHistoryError.requiresLaterReducer
                }
            }
            guard heads.count == 1, let after = heads.first,
                  entry.after == (deleted ? .deleted(after) : .value(after)) else {
                throw OrdinaryHistoryError.invalidBeforeAfter
            }
        }
        return requirements
    }

    private static func value(_ operation: IdentifiedOperation) -> PlaintextNoteValue? {
        operation.effect.noteValue
    }

    private static func validateDetails(_ a: ActionV1, observed: [ActionID: ActionV1],
        basisOperations: [IdentifiedOperation], state: CollectionReductionV1?, localOperations: [OperationID: IdentifiedOperation]) throws {
        let prior = Dictionary(uniqueKeysWithValues: basisOperations.map { ($0.id, $0) })
        func source(_ id: OperationID, birth: NoteBirth? = nil) throws -> IdentifiedOperation {
            guard let op = prior[id], birth == nil || op.effect.targetBirth == birth else { throw OrdinaryHistoryError.invalidAction }; return op
        }
        func beforeValue(_ entry: ActionAffectedStateV1) throws -> PlaintextNoteValue? {
            switch entry.before {
            case .freshBirthAbsence, .deleted: return nil
            case .value(let id): return try source(id, birth: entry.birth).effect.noteValue
            case .derived: return state?.cells.first(where: { $0.birth == entry.birth })?.value
            case .automatic(let source): return try prior[source.revision]?.effect.noteValue?.conflictCopyValue()
            }
        }
        for member in a.members {
            guard let op = localOperations[member] else { throw OrdinaryHistoryError.invalidAction }
            if case .adoptAutomatic(_, let birth, let origin, _) = op.effect {
                guard let value = try source(origin.revision, birth: origin.birth).effect.noteValue,
                      a.affected.first(where: { $0.birth == birth })?.before == .automatic(origin),
                      try AutomaticConflictKeyV1.compute(source: origin.birth, value: value) == origin.key else { throw OrdinaryHistoryError.invalidBeforeAfter }
            }
        }
        // Explicit deletion of a deterministic domain retains retirement in the same group.
        for entry in a.affected {
            guard case .deleted = entry.after else { continue }
            var domain: DeterministicConflictIdentityV1?
            if case .automatic(let origin) = entry.before { domain = .automatic(origin.key) }
            for op in basisOperations where op.effect.targetBirth == entry.birth {
                switch op.effect {
                case .adoptAutomatic(_, _, let origin, _): domain = .automatic(origin.key)
                case .recoverCopy(_, _, let origin, _): domain = .recovery(origin.key, slot: origin.slot)
                default: break
                }
            }
            let retirements = a.members.compactMap { id -> DeterministicConflictIdentityV1? in
                if case .retireConflict(_, let birth, let identity) = localOperations[id]?.effect, birth == entry.birth { return identity }; return nil
            }
            guard domain.map({ retirements == [$0] }) ?? retirements.isEmpty else { throw OrdinaryHistoryError.invalidAction }
        }
        switch a.details {
        case nil: break
        case .historical(let birth, let revision, let fields):
            guard let value = try source(revision, birth: birth).effect.noteValue, a.affected.count == 1,
                  let entry = a.affected.first, case .value(let after) = entry.after,
                  let result = localOperations[after]?.effect.noteValue else { throw OrdinaryHistoryError.invalidAction }
            if entry.before == .freshBirthAbsence { guard fields == .all, result == value else { throw OrdinaryHistoryError.invalidBeforeAfter } }
            else {
                guard let before = try beforeValue(entry), result.body == (fields.contains(.body) ? value.body : before.body),
                      result.title == (fields.contains(.title) ? value.title : before.title),
                      result.labels == (fields.contains(.labels) ? value.labels : before.labels) else { throw OrdinaryHistoryError.invalidBeforeAfter }
            }
        case .choice(let selected, let heads):
            guard a.affected.count == 1, let entry = a.affected.first, case .note(entry.birth) = a.scope,
                  let chosen = try source(selected, birth: entry.birth).effect.noteValue,
                  let before = try beforeValue(entry), case .value(let after) = entry.after,
                  let op = localOperations[after], let result = op.effect.noteValue,
                  Set(heads) == Set(op.notePredecessors.ids), heads.contains(selected),
                  result.body == chosen.body, result.title == before.title, result.labels == before.labels else { throw OrdinaryHistoryError.invalidBeforeAfter }
        case .copy(let birth, let revision, let key, let slot, let reused):
            guard slot <= UInt64(basisOperations.count) + 1 else { throw OrdinaryHistoryError.invalidAction }
            guard a.affected.count == 1, let entry = a.affected.first, a.scope == .collection,
                  let original = try source(revision, birth: birth).effect.noteValue,
                  try ConflictRecoveryKeyV1.compute(source: birth, body: original.body) == key,
                  try key.birth(slot: slot) == entry.birth,
                  case .value(let after) = entry.after,
                  case .recoverCopy(_, _, let copy, let result) = localOperations[after]?.effect,
                  copy.birth == birth, copy.revision == revision, copy.key == key, copy.slot == slot, copy.reused == reused,
                  !((state?.retired ?? []).contains(.recovery(key, slot: slot))) else { throw OrdinaryHistoryError.invalidAction }
            let canonical = original.body.string.precomposedStringWithCanonicalMapping
            guard result.body.string.precomposedStringWithCanonicalMapping == canonical else { throw OrdinaryHistoryError.invalidBeforeAfter }
            func belongsToSlot(_ candidate: NoteBirth, _ ordinal: UInt64) -> Bool {
                basisOperations.contains { op in
                    if case .recoverCopy(_, let birth, let source, _) = op.effect {
                        return birth == candidate && source.key == key && source.slot == ordinal && source.reused == nil
                    }; return false
                }
            }
            if let reused {
                guard entry.before == .value(reused), let cell = state?.cells.first(where: { $0.birth == entry.birth }),
                      belongsToSlot(entry.birth, slot),
                      cell.represented == [reused], cell.value == result,
                      cell.value.body.string.precomposedStringWithCanonicalMapping == canonical else { throw OrdinaryHistoryError.invalidBeforeAfter }
            } else { guard entry.before == .freshBirthAbsence else { throw OrdinaryHistoryError.reusedBirth } }
            // A requested high slot cannot bypass the first available or exact usable slot.
            for earlier in 0..<slot {
                let candidate = try key.birth(slot: earlier)
                if (state?.retired ?? []).contains(.recovery(key, slot: earlier)) { continue }
                if let cell = state?.cells.first(where: { $0.birth == candidate }) {
                    guard !belongsToSlot(candidate, earlier) || cell.value.body.string.precomposedStringWithCanonicalMapping != canonical || cell.represented.count != 1 else { throw OrdinaryHistoryError.invalidAction }
                } else if !basisOperations.contains(where: { $0.effect.targetBirth == candidate }) { throw OrdinaryHistoryError.invalidAction }
            }
        case .compensation(let target, let reviewed):
            guard let original = observed[target], original.scope == a.scope else { throw OrdinaryHistoryError.invalidAction }
            let direction: UndoDirectionV1 = a.kind == .undo ? .undo : .redo
            let selection = try CausalUndoV1.select(actions: Array(observed.values), scope: a.scope, direction: direction)
            guard selection.candidates.contains(target), reviewed || selection.mode == .automatic else { throw OrdinaryHistoryError.invalidAction }
            try CompensationV1.validate(action: a, target: original, history: basisOperations, priorActions: Array(observed.values), members: localOperations, reviewed: reviewed)
        case .native(let coverage):
            guard case .note(let birth) = a.scope, a.affected.count == 1, !coverage.isEmpty,
                  let entry = a.affected.first, case .value(let after) = entry.after else { throw OrdinaryHistoryError.invalidAction }
            let eligible = try CausalUndoV1.select(actions: Array(observed.values), scope: a.scope, direction: .undo)
            guard eligible.mode == .automatic, eligible.candidates.count == 1,
                  coverage.first(where: { $0.action == eligible.candidates[0] })?.remaining == .value(a.members[0]) else {
                throw OrdinaryHistoryError.invalidAction
            }
            for record in coverage {
                guard let target = observed[record.action], target.kind == .savedEdit, target.scope == a.scope,
                      target.affected.count == 1, case .value(let remaining) = record.remaining, a.members.contains(remaining),
                      target.affected[0].birth == birth else { throw OrdinaryHistoryError.invalidAction }
                let targetBefore = try CompensationV1.value(target.affected[0].before, operations: prior)
                guard let actual = localOperations[remaining]?.effect.noteValue,
                      let targetBefore, actual.title == targetBefore.title, actual.labels == targetBefore.labels,
                      record.complete == actual.hasSameEditableFields(as: targetBefore) else { throw OrdinaryHistoryError.invalidBeforeAfter }
            }
            _ = after
        }
    }

    private static func causalPast(_ op: IdentifiedOperation,
        operation: (OperationID) async throws -> IdentifiedOperation, visitingAncestor: () -> Void) async throws -> Set<OperationID> {
        var seen: Set<OperationID> = [], work = op.causalParents.ids
        while let id = work.popLast() {
            guard id != op.id else { throw OrdinaryHistoryError.invalidCausality }
            if seen.insert(id).inserted { visitingAncestor(); work += try await operation(id).causalParents.ids }
        }
        return seen
    }
}

/// Prior note revisions used as inputs to the ordinary action rules.
package struct OrdinaryNoteInputsV1 {
    package let heads: Set<OperationID>
    package let deleted: Bool
    package let before: ActionStateV1?
    package init(heads: Set<OperationID>, deleted: Bool, before: ActionStateV1? = nil) {
        self.heads = heads; self.deleted = deleted; self.before = before
    }
}
