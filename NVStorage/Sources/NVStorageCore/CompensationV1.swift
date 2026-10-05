public enum ValueCompensationV1: Equatable, Sendable {
    case unchanged
    case automatic(PlaintextNoteValue)
    case review(PlaintextNoteValue)
}

/// Reconstructs retained admission states and reverses the actual selected effect.
public enum CompensationV1 {
    /// Latest causally ordered native statement of a saved group's remaining effect.
    public static func remainingAfter(of target: ActionV1, actions: [ActionV1], current: ActionStateV1? = nil,
                                      operations: [OperationID: IdentifiedOperation] = [:]) throws -> ActionStateV1? {
        var records: [ActionID: ActionV1] = [:]
        for action in actions {
            guard records.updateValue(action, forKey: action.id) == nil else { throw CanonicalEncodingError.invalidAction }
        }
        let claims = actions.compactMap { action -> (ActionID, ActionStateV1)? in
            if case .native(let coverage) = action.details, let record = coverage.first(where: { $0.action == target.id }) { return (action.id, record.remaining) }; return nil
        }
        var maxima = Set(claims.map(\.0))
        for claim in claims {
            var seen: Set<ActionID> = [], work = records[claim.0]?.scopeParents ?? []
            while let id = work.popLast() { guard let record = records[id] else { throw CanonicalEncodingError.missingDependency }; if seen.insert(id).inserted { maxima.remove(id); work += record.scopeParents } }
        }
        let states = Set(claims.filter { maxima.contains($0.0) }.map(\.1))
        if states.count > 1 {
            guard let current else { throw OrdinaryHistoryError.invalidBeforeAfter }
            var lineage: Set<OperationID> = [], work = current.represented
            while let id = work.popLast() {
                guard let record = operations[id] else { throw CanonicalEncodingError.missingDependency }
                if lineage.insert(id).inserted { work += record.notePredecessors.ids }
            }
            let represented = states.filter { Set($0.represented).isSubset(of: lineage) }
            if represented.count == 1 { return represented.first }
            if represented.isEmpty { return target.affected.first?.after }
            // A joined Current represents the combined remaining native effects.
            return current
        }
        return states.first
    }
    public static func value(_ state: ActionStateV1, operations: [OperationID: IdentifiedOperation]) throws -> PlaintextNoteValue? {
        func revision(_ id: OperationID) throws -> PlaintextNoteValue {
            guard let value = operations[id]?.effect.noteValue else { throw CanonicalEncodingError.missingDependency }; return value
        }
        switch state {
        case .freshBirthAbsence, .deleted: return nil
        case .value(let id): return try revision(id)
        case .automatic(let source): return try revision(source.revision).conflictCopyValue()
        case .derived(.equal(let inputs, let digest)):
            guard let first = inputs.first else { throw CanonicalEncodingError.invalidReference }
            let selected = try revision(first)
            var modified = selected.modified
            for id in inputs { let next = try revision(id); guard next.hasSameEditableFields(as: selected) else { throw CanonicalEncodingError.invalidReference }; modified = NVConservativeMergeV1.latest(modified, next.modified) }
            let result = try PlaintextNoteValue(title: selected.title, body: selected.body, labels: selected.labels, created: selected.created, modified: modified)
            guard try result.digestV1() == digest else { throw CanonicalEncodingError.identityMismatch }; return result
        case .derived(.merged(let inputs, let base, let digest, _)):
            guard inputs.count == 2 else { throw CanonicalEncodingError.invalidReference }
            let baseValue = try revision(base)
            guard case .merged(let result) = try NVConservativeMergeV1.merge(base: baseValue, left: revision(inputs[0]), right: revision(inputs[1]), birthCreated: baseValue.created),
                  try result.digestV1() == digest else { throw CanonicalEncodingError.identityMismatch }; return result
        }
    }

    public static func reverse(before: PlaintextNoteValue, after: PlaintextNoteValue, current: PlaintextNoteValue) throws -> ValueCompensationV1 {
        let titleChanged = before.title != after.title, labelsChanged = before.labels != after.labels, bodyChanged = before.body != after.body
        var needsReview = false
        let title: ExactUTF8
        if !titleChanged { title = current.title }
        else if current.title == after.title || current.title == before.title { title = before.title }
        else { title = before.title; needsReview = true }
        let labels: CanonicalLabels
        if !labelsChanged { labels = current.labels }
        else if current.labels == after.labels || current.labels == before.labels { labels = before.labels }
        else { labels = before.labels; needsReview = true }
        let body: ExactUTF8
        if !bodyChanged { body = current.body }
        else if current.body == after.body || current.body == before.body { body = before.body }
        else {
            // Limit the text reversal to body; independently preserved scalar fields stay current.
            let b = try PlaintextNoteValue(title: current.title, body: after.body, labels: current.labels, created: current.created, modified: current.modified)
            let l = try PlaintextNoteValue(title: current.title, body: before.body, labels: current.labels, created: current.created, modified: current.modified)
            switch try NVConservativeMergeV1.merge(base: b, left: l, right: current, birthCreated: current.created) {
            case .merged(let merged): body = merged.body
            case .review: body = before.body; needsReview = true
            }
        }
        let result = try PlaintextNoteValue(title: title, body: body, labels: labels, created: current.created, modified: current.modified)
        if result.hasSameEditableFields(as: current) { return .unchanged }
        return needsReview ? .review(result) : .automatic(result)
    }

    static func validate(action: ActionV1, target: ActionV1, history: [IdentifiedOperation], priorActions: [ActionV1],
                         members: [OperationID: IdentifiedOperation], reviewed: Bool) throws {
        let operations = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        var expectedBirths: Set<NoteBirth> = [], changed = false
        for effect in target.affected {
            let admission = action.affected.first { $0.birth == effect.birth }?.before
            let before = try value(effect.before, operations: operations), after = try value(remainingAfter(of: target, actions: priorActions, current: admission, operations: operations) ?? effect.after, operations: operations)
            if let before, after == nil {
                guard let restoration = action.restorations.first(where: { $0.sourceBirth == effect.birth && $0.deletionAction == target.id }),
                      let entry = action.affected.first(where: { $0.birth == restoration.birth }), entry.before == .freshBirthAbsence,
                      case .value(let id) = entry.after, let result = members[id]?.effect.noteValue,
                      result == before else { throw OrdinaryHistoryError.invalidBeforeAfter }
                expectedBirths.insert(restoration.birth); changed = true
            } else {
                guard let entry = action.affected.first(where: { $0.birth == effect.birth }),
                      let current = try value(entry.before, operations: operations) else { throw OrdinaryHistoryError.invalidBeforeAfter }
                expectedBirths.insert(effect.birth)
                if before == nil {
                    guard after != nil, case .deleted = entry.after,
                          reviewed || current.hasSameEditableFields(as: after!) else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    changed = true
                } else {
                    guard let after, let before, case .value(let id) = entry.after,
                          let result = members[id]?.effect.noteValue else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    let reversal = try reverse(before: before, after: after, current: current)
                    if case .unchanged = reversal { throw OrdinaryHistoryError.invalidBeforeAfter }
                    if reviewed {
                        guard before.title != after.title || result.title == current.title,
                              before.body != after.body || result.body == current.body,
                              before.labels != after.labels || result.labels == current.labels,
                              !result.hasSameEditableFields(as: current) else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    } else {
                        guard case .automatic(let expected) = reversal, result.hasSameEditableFields(as: expected) else { throw OrdinaryHistoryError.invalidBeforeAfter }
                    }
                    changed = true
                }
            }
        }
        guard changed, expectedBirths == Set(action.affected.map(\.birth)) else { throw OrdinaryHistoryError.invalidAction }
    }
}
