public enum UndoDirectionV1: Sendable { case undo, redo }
public enum UndoSelectionModeV1: Sendable { case none, automatic, review }

/// Direction-specific causal candidates derived from complete action records.
public struct CausalUndoSelectionV1: Sendable {
    public let candidates: [ActionID]
    public let mode: UndoSelectionModeV1
    public let scopeFrontier: [ActionID]
}

public enum CausalUndoV1 {
    public static func select(actions: [ActionV1], scope: ActionScopeV1, direction: UndoDirectionV1) throws -> CausalUndoSelectionV1 {
        var records: [ActionID: ActionV1] = [:]
        for action in actions {
            try Task.checkCancellation()
            guard records.updateValue(action, forKey: action.id) == nil else { throw CanonicalEncodingError.invalidAction }
        }
        let scoped = actions.filter { $0.scope == scope }
        // Check the scoped graph once, then reuse query-local ancestry and family results.
        var remaining: [ActionID: Int] = [:], children: [ActionID: [ActionID]] = [:], ready: [ActionID] = []
        for action in scoped {
            let parents = Set(action.scopeParents)
            for parent in parents {
                guard records[parent]?.scope == scope else { throw CanonicalEncodingError.invalidAction }
                children[parent, default: []].append(action.id)
            }
            remaining[action.id] = parents.count
            if parents.isEmpty { ready.append(action.id) }
        }
        var checked = 0
        while let id = ready.popLast() {
            try Task.checkCancellation()
            checked += 1
            for child in children[id] ?? [] {
                remaining[child]! -= 1
                if remaining[child] == 0 { ready.append(child) }
            }
        }
        guard checked == scoped.count else { throw CanonicalEncodingError.invalidAction }
        var ancestry: [ActionID: Set<ActionID>] = [:], family: [ActionID: Set<ActionID>] = [:]
        func ancestors(_ id: ActionID) throws -> Set<ActionID> {
            if let saved = ancestry[id] { return saved }
            var seen: Set<ActionID> = [], work = records[id]?.scopeParents ?? []
            while let next = work.popLast() {
                try Task.checkCancellation()
                guard next != id, let a = records[next], a.scope == records[id]?.scope else { throw CanonicalEncodingError.invalidAction }
                if seen.insert(next).inserted { work += a.scopeParents }
            }
            ancestry[id] = seen
            return seen
        }
        // One union traversal finds dominated candidates, including gaps left by consumed actions.
        func preceding(_ ids: Set<ActionID>) throws -> Set<ActionID> {
            var seen: Set<ActionID> = [], work = ids.flatMap { records[$0]?.scopeParents ?? [] }
            while let next = work.popLast() {
                try Task.checkCancellation()
                guard let action = records[next], action.scope == scope else { throw CanonicalEncodingError.invalidAction }
                if seen.insert(next).inserted { work += action.scopeParents }
            }
            return seen
        }
        func maxima(_ ids: Set<ActionID>) throws -> Set<ActionID> {
            try ids.subtracting(preceding(ids))
        }
        func targets(_ action: ActionV1) -> [ActionID] {
            switch action.details {
            case .compensation(let target, _): [target]
            case .native: []
            default: []
            }
        }
        func families(_ id: ActionID) throws -> Set<ActionID> {
            if let saved = family[id] { return saved }
            var roots: Set<ActionID> = [], seen: Set<ActionID> = [], work = [id]
            while let next = work.popLast() {
                try Task.checkCancellation()
                guard let a = records[next] else { throw CanonicalEncodingError.missingDependency }
                guard seen.insert(next).inserted else { continue }
                switch a.details {
                case .compensation(let target, _):
                    guard try ancestors(next).contains(target) else { throw CanonicalEncodingError.invalidAction }; work.append(target)
                case .native(let coverage): work += coverage.map(\.action)
                default: roots.insert(next)
                }
            }
            family[id] = roots
            return roots
        }
        var consumed = Set(scoped.flatMap(targets))
        let covered = Set(scoped.flatMap { action -> [ActionID] in if case .native(let claims) = action.details { claims.map(\.action) } else { [] } })
        for target in covered {
            let claimants = scoped.filter { action in if case .native(let claims) = action.details { claims.contains { $0.action == target } } else { false } }
            let maximalClaims = try maxima(Set(claimants.map(\.id)))
            if claimants.filter({ maximalClaims.contains($0.id) }).allSatisfy({ action in
                if case .native(let claims) = action.details { claims.first { $0.action == target }?.complete == true } else { false }
            }) { consumed.insert(target) }
        }
        let leaves = Set(scoped.map(\.id)).subtracting(consumed)
        let forward = Set(scoped.filter { $0.kind != .undo && $0.kind != .nativeUndo }.map(\.id)).intersection(leaves)
        func independent(_ a: ActionV1) -> Bool { a.kind != .undo && a.kind != .redo && a.kind != .nativeUndo }
        var candidates: Set<ActionID>
        if direction == .undo { candidates = forward }
        else {
            candidates = Set(scoped.filter { $0.kind == .undo || $0.kind == .nativeUndo }.map(\.id)).intersection(leaves)
            candidates.subtract(try preceding(Set(scoped.filter(independent).map(\.id))))
        }
        let maximal = try maxima(candidates)
        var review = maximal.count > 1
        for id in maximal {
            let root = try families(id)
            let natives = try scoped.filter { action in
                guard action.kind == .nativeUndo else { return false }
                return try !families(action.id).isDisjoint(with: root)
            }
            let nativeMaxima = try maxima(Set(natives.map(\.id)))
            var linearCoverage = nativeMaxima.count == 1
            if linearCoverage, let native = nativeMaxima.first {
                for command in scoped where command.kind == .undo || command.kind == .redo {
                    if !(try families(command.id)).isDisjoint(with: root),
                       try !ancestors(command.id).contains(native) && !ancestors(native).contains(command.id) {
                        linearCoverage = false
                    }
                }
            }
            for other in leaves where other != id {
                let ordered = try ancestors(id).contains(other) || ancestors(other).contains(id)
                let otherFamilies = try families(other)
                let coverageContinuation = ordered && linearCoverage
                if !coverageContinuation && !root.isDisjoint(with: otherFamilies) { review = true }
            }
            if direction == .redo {
                for other in forward where other != id {
                    if try !ancestors(other).contains(id) && !ancestors(id).contains(other) { review = true }
                }
            }
        }
        let frontier = Set(scoped.map(\.id)).subtracting(scoped.flatMap(\.scopeParents))
        return CausalUndoSelectionV1(candidates: sort(maximal), mode: maximal.isEmpty ? .none : review ? .review : .automatic, scopeFrontier: sort(frontier))
    }
    private static func sort(_ ids: Set<ActionID>) -> [ActionID] { ids.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) } }
}
