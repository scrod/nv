import Foundation
import NVStorageCore

/// Current command alternatives issued by the collection's validated action graph.
public struct UndoCandidates: Sendable {
    public let scope: ActionScopeV1
    public let direction: UndoDirectionV1
    public let ids: [ActionID]
    public let mode: UndoSelectionModeV1
    fileprivate let frontier: [ActionID]
    fileprivate init(scope: ActionScopeV1, direction: UndoDirectionV1, selection: CausalUndoSelectionV1) {
        self.scope = scope; self.direction = direction; ids = selection.candidates; mode = selection.mode; frontier = selection.scopeFrontier
    }
}

public enum CompensationEffect: Sendable {
    case put(NoteBirth, PlaintextNoteValue)
    case delete(NoteBirth)
    case restore(NoteBirth, PlaintextNoteValue)
    public var birth: NoteBirth {
        switch self { case .put(let birth, _), .delete(let birth), .restore(let birth, _): birth }
    }
}

/// Frozen candidate, disclosed effects and exact context for compensation admission.
public struct CompensationProposal: Sendable {
    public let candidate: ActionID
    public let candidates: UndoCandidates
    public let effects: [CompensationEffect]
    fileprivate let session: UUID
    fileprivate let store: LocalStoreID
    fileprivate let epoch: [UInt8]
    fileprivate let presentationEpoch: UUID
    fileprivate let before: [NoteBirth: CurrentNoteCellV1]
    fileprivate let testedBirths: Set<NoteBirth>
    fileprivate let target: ActionReference
    fileprivate let restorations: [RestorationReference]
    fileprivate let generation: UInt64
    fileprivate let commandID: UUID
    fileprivate let actionID: ActionID
    fileprivate init(candidate: ActionID, candidates: UndoCandidates, effects: [CompensationEffect],
                     snapshot: StoreSnapshot, testedBirths: Set<NoteBirth>, target: ActionReference,
                     restorations: [RestorationReference], generation: UInt64) throws {
        self.candidate = candidate; self.candidates = candidates; self.effects = effects
        session = snapshot.session; store = snapshot.store; epoch = snapshot.viewEpoch; presentationEpoch = snapshot.presentationEpoch
        before = Dictionary(uniqueKeysWithValues: snapshot.notes.filter { testedBirths.contains($0.birth) }.map { ($0.birth, $0) })
        self.testedBirths = testedBirths; self.target = target; self.restorations = restorations; self.generation = generation
        commandID = UUID(); actionID = try ActionID(bytes: uuidBytes())
    }
}

/// Store-issued compensation eligible for the ordinary Undo/Redo path.
public struct AutomaticCompensation: Sendable {
    public let proposal: CompensationProposal
    fileprivate init(_ proposal: CompensationProposal) { self.proposal = proposal }

    /// Presents the same captured command for an explicit reviewed replacement.
    public func forReview() -> CompensationReview { CompensationReview(proposal) }
}

/// Store-issued compensation whose disclosed effects require explicit approval.
public struct CompensationReview: Sendable {
    public let proposal: CompensationProposal
    fileprivate init(_ proposal: CompensationProposal) { self.proposal = proposal }
}

public enum CompensationPreparation: Sendable {
    case none(UndoCandidates)
    case choose(UndoCandidates)
    case noEffect(UndoCandidates)
    case automatic(AutomaticCompensation)
    case review(CompensationReview)
}

/// Native command boundary retained for each saved group affected by a text-state step.
public struct NativeSavedEffect: Sendable {
    public let action: ActionID
    public let complete: Bool
    public init(action: ActionID, complete: Bool) { self.action = action; self.complete = complete }
}
public struct NativeCompensationStep: Sendable {
    public let value: PlaintextNoteValue
    public let coverage: [NativeSavedEffect]
    public init(value: PlaintextNoteValue, coverage: [NativeSavedEffect]) { self.value = value; self.coverage = coverage }
}

extension LocalStoreSession {
    /// Captures actual native text states and each saved group's remaining effect together.
    public func nativeCompensation(for birth: NoteBirth, steps: [NativeCompensationStep], generation: UInt64) async throws -> CapturedActionGroup {
        return try await lane.verifyingHistory {
            guard !steps.isEmpty else { throw StorageError.staleCapture }
            let (snapshot, graph) = try await commandBasis()
            return try await commandWork {
                let eligible = try CausalUndoV1.select(actions: Array(graph.actions.values), scope: .note(birth), direction: .undo)
                guard eligible.mode == .automatic, eligible.candidates.count == 1,
                      steps.first!.coverage.contains(where: { $0.action == eligible.candidates[0] }) else { throw StorageError.staleCapture }
                var coverage: [NativeCoverageReferenceV1] = []
                for (index, step) in steps.enumerated() {
                    for effect in step.coverage {
                        guard let ref = graph.actionReferences[effect.action], graph.actions[effect.action]?.scope == .note(birth), graph.actions[effect.action]?.kind == .savedEdit else { throw StorageError.staleCapture }
                        coverage.append(.init(action: ref.reference, remaining: .value(.earlierLocal(index: OperationIndex(UInt32(index)))), complete: effect.complete))
                    }
                }
                guard Set(steps.flatMap { $0.coverage.map(\.action) }).count == coverage.count else { throw StorageError.staleCapture }
                return try CapturedActionGroup(snapshot: snapshot, intent: .native(coverage),
                    changes: steps.map { try .put(.init(birth: birth, generation: generation), $0.value) }, scope: .note(birth))
            }
        }
    }

    public func undoCandidates(scope: ActionScopeV1, direction: UndoDirectionV1) async throws -> UndoCandidates {
        return try await lane.verifyingHistory {
            if case .note(let birth) = scope {
                guard !closed, !quiescing else { throw StorageError.closed }
                let snapshot = try await snapshot(), lane = lane, selection = selection
                let checked = try await CheckedQueryHistory.read(scope: .undo(birth), snapshot: snapshot, session: incarnation,
                    lane: lane, selection: selection, protection: protection)
                let actions = try await lane.perform { try checked.undoActions(for: birth, snapshot: snapshot, database: $0, selection: selection) }
                let result = try await commandWork {
                    try UndoCandidates(scope: scope, direction: direction, selection: CausalUndoV1.select(actions: actions, scope: scope, direction: direction))
                }
                try await lane.perform { try checked.check(scope: .undo(birth), snapshot: snapshot, database: $0, selection: selection) }
                return result
            }
            let (_, graph) = try await commandBasis()
            return try await commandWork {
                try UndoCandidates(scope: scope, direction: direction, selection: CausalUndoV1.select(actions: Array(graph.actions.values), scope: scope, direction: direction))
            }
        }
    }

    /// Prepares every affected member against Current, retaining an unsafe maximal candidate for review.
    public func prepareCompensation(scope: ActionScopeV1, direction: UndoDirectionV1, candidate: ActionID? = nil,
                                    generation: UInt64 = 1) async throws -> CompensationPreparation {
        return try await lane.verifyingHistory {
            let (snapshot, graph) = try await commandBasis()
            return try await commandWork {
                let selected = try CausalUndoV1.select(actions: Array(graph.actions.values), scope: scope, direction: direction)
                let candidates = UndoCandidates(scope: scope, direction: direction, selection: selected)
                if candidates.ids.isEmpty { return .none(candidates) }
                if candidate == nil && candidates.ids.count != 1 { return .choose(candidates) }
                let id = candidate ?? candidates.ids[0]
                guard candidates.ids.contains(id), let target = graph.actions[id], let reference = graph.actionReferences[id] else { throw StorageError.staleCapture }
                var effects: [CompensationEffect] = [], restorations: [RestorationReference] = []
                var review = candidates.mode == .review, tested: Set<NoteBirth> = []
                for entry in target.affected {
                    try Task.checkCancellation()
                    tested.insert(entry.birth)
                    let before = try CompensationV1.value(entry.before, operations: graph.operations)
                    let current = snapshot.notes.first(where: { $0.birth == entry.birth })
                    let after = try CompensationV1.value(CompensationV1.remainingAfter(of: target, actions: Array(graph.actions.values), current: current?.state,
                        operations: graph.operations) ?? entry.after, operations: graph.operations)
                    if let before, after == nil {
                        guard current == nil, case .deleted = entry.after, let revision = entry.before.represented.first,
                              let source = graph.operationReferences[revision] else { throw StorageError.staleCapture }
                        let fresh = try NoteBirth(bytes: uuidBytes())
                        effects.append(.restore(fresh, before)); tested.insert(fresh)
                        let state = try graph.stateReference(entry.before)
                        restorations.append(.init(birth: fresh, sourceBirth: entry.birth, deletionAction: reference.reference,
                            revision: source.reference, priorState: entry.before.represented.count > 1 || { if case .automatic = entry.before { true } else { false } }() ? state : nil))
                    } else if before == nil {
                        guard let current, let after else { return .noEffect(candidates) }
                        review = review || !current.value.hasSameEditableFields(as: after)
                        effects.append(.delete(entry.birth))
                    } else {
                        guard let current, let before, let after else { return .noEffect(candidates) }
                        switch try CompensationV1.reverse(before: before, after: after, current: current.value) {
                        case .unchanged: return .noEffect(candidates)
                        case .automatic(let value): effects.append(.put(entry.birth, value))
                        case .review(let value): review = true; effects.append(.put(entry.birth, value))
                        }
                    }
                }
                let proposal = try CompensationProposal(candidate: id, candidates: candidates, effects: effects,
                    snapshot: snapshot, testedBirths: tested, target: reference.reference, restorations: restorations, generation: generation)
                return review ? .review(CompensationReview(proposal)) : .automatic(AutomaticCompensation(proposal))
            }
        }
    }

    /// Revalidates an automatically eligible command and admits its complete inverse.
    public func applyCompensation(_ command: AutomaticCompensation) async throws -> CommitOutcome {
        try await applyCompensation(command.proposal, authorization: .automatic, replacements: [:])
    }

    /// Approves the disclosed command, rechecks its context and admits the reviewed inverse.
    public func applyReviewedCompensation(_ review: CompensationReview,
                                         replacements: [NoteBirth: PlaintextNoteValue] = [:]) async throws -> CommitOutcome {
        try await applyCompensation(review.proposal, authorization: .reviewed, replacements: replacements)
    }

    private func applyCompensation(_ proposal: CompensationProposal, authorization: CompensationAuthorization,
                                   replacements: [NoteBirth: PlaintextNoteValue]) async throws -> CommitOutcome {
        return try await lane.verifyingHistory {
            guard proposal.session == incarnation, proposal.store == selection.store else { throw StorageError.wrongContext }
            let (snapshot, graph) = try await commandBasis()
            let capture = try await commandWork {
                guard snapshot.viewEpoch == proposal.epoch, snapshot.presentationEpoch == proposal.presentationEpoch else { throw StorageError.staleCapture }
                let current = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.birth, $0) })
                for birth in proposal.testedBirths { guard current[birth] == proposal.before[birth] else { throw StorageError.staleCapture } }
                let selected = try CausalUndoV1.select(actions: Array(graph.actions.values), scope: proposal.candidates.scope, direction: proposal.candidates.direction)
                guard selected.candidates == proposal.candidates.ids, selected.scopeFrontier == proposal.candidates.frontier else { throw StorageError.staleCapture }
                let puts = Set(proposal.effects.compactMap { if case .put(let birth, _) = $0 { birth } else { nil } })
                guard Set(replacements.keys).isSubset(of: puts) else { throw StorageError.staleCapture }
                let changes = try proposal.effects.map { effect -> CapturedNoteChange in
                    let generation = try CapturedNoteGeneration(birth: effect.birth, generation: proposal.generation)
                    switch effect {
                    case .put(let birth, let value): return .put(generation, replacements[birth] ?? value)
                    case .delete: return .delete(generation)
                    case .restore(_, let value): return .create(generation, value)
                    }
                }
                return try CapturedActionGroup(snapshot: snapshot,
                    intent: .compensation(direction: proposal.candidates.direction, target: proposal.target,
                        authorization: authorization, restorations: proposal.restorations), changes: changes,
                    scope: proposal.candidates.scope, commandID: proposal.commandID, actionID: proposal.actionID)
            }
            return try await persist(capture: capture)
        }
    }
}
