import Foundation
@testable import NVStorageCore
import Testing

private func queryAction(_ number: Int, parents: [ActionID], kind: ActionKindV1 = .savedEdit,
                         target: ActionID? = nil) throws -> ActionV1 {
    let id = try ActionID(bytes: withUnsafeBytes(of: UInt64(number).bigEndian) { Array(repeating: 0, count: 8) + Array($0) })
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let operation = try OperationID(bytes: Array(repeating: 0, count: 24) + Array(id.bytes.suffix(8)))
    return try .init(id: id, origin: ActionOriginID(bytes: Array(repeating: 2, count: 16)), previousOriginAction: nil,
        scope: .note(birth), scopeParents: parents, kind: kind, members: [operation],
        affected: [.init(birth: birth, before: .value(operation), after: .value(operation))], restorations: [],
        details: target.map { .compensation(target: $0, reviewed: false) })
}

/// Boolean transitive closure and integer candidate sets provide an independent small-graph oracle.
private func queryOracle(_ actions: [ActionV1], direction: UndoDirectionV1) -> (Set<ActionID>, UndoSelectionModeV1, Set<ActionID>) {
    let count = actions.count, indices = Dictionary(uniqueKeysWithValues: actions.enumerated().map { ($0.element.id, $0.offset) })
    var reach = Array(repeating: Array(repeating: false, count: count), count: count)
    for (index, action) in actions.enumerated() {
        for parent in action.scopeParents { reach[index][indices[parent]!] = true }
    }
    for via in 0..<count {
        for from in 0..<count {
            for to in 0..<count { reach[from][to] = reach[from][to] || (reach[from][via] && reach[via][to]) }
        }
    }
    let all = Set(0..<count)
    let targets = actions.map { action -> Int? in
        if case .compensation(let target, _) = action.details { indices[target] } else { nil }
    }
    let leaves = all.subtracting(targets.compactMap { $0 })
    let forward = leaves.filter { actions[$0].kind != .undo }
    let candidates: Set<Int>
    if direction == .undo { candidates = Set(forward) }
    else {
        candidates = leaves.filter { index in
            actions[index].kind == .undo && !all.contains { newer in
                actions[newer].kind != .undo && actions[newer].kind != .redo && reach[newer][index]
            }
        }
    }
    let maximal = candidates.filter { older in !candidates.contains { reach[$0][older] } }
    func root(_ index: Int) -> Int {
        var next = index
        while let target = targets[next] { next = target }
        return next
    }
    var review = maximal.count > 1
    for index in maximal {
        if leaves.contains(where: { $0 != index && root($0) == root(index) }) { review = true }
        if direction == .redo && forward.contains(where: { $0 != index && !reach[$0][index] && !reach[index][$0] }) { review = true }
    }
    let frontier = all.filter { older in !all.contains { reach[$0][older] } }
    return (Set(maximal.map { actions[$0].id }), maximal.isEmpty ? .none : review ? .review : .automatic,
            Set(frontier.map { actions[$0].id }))
}

@Test func undoQueryMatchesIndependentSmallGraphClosure() throws {
    let scope = ActionScopeV1.note(try .init(bytes: Array(repeating: 1, count: 16)))
    let edges = (0..<5).flatMap { child in (0..<child).map { (child, $0) } }
    var comparisons = 0
    for mask in 0..<(1 << edges.count) {
        var baseline: [ActionV1] = []
        for index in 0..<5 {
            let parents = edges.enumerated().compactMap { bit, edge in
                edge.0 == index && mask & (1 << bit) != 0 ? baseline[edge.1].id : nil
            }
            baseline.append(try queryAction(index + 1, parents: parents))
        }
        var histories = [baseline]
        for index in 1..<5 {
            for target in 0..<index {
                // Only a declared ancestor can be a compensation target.
                var reachable: Set<ActionID> = [], work = baseline[index].scopeParents
                while let next = work.popLast() {
                    if reachable.insert(next).inserted { work += baseline.first { $0.id == next }!.scopeParents }
                }
                guard reachable.contains(baseline[target].id) else { continue }
                var undo = baseline
                undo[index] = try queryAction(index + 1, parents: baseline[index].scopeParents, kind: .undo, target: baseline[target].id)
                histories.append(undo)
                for redoIndex in (index + 1)..<5 where baseline[redoIndex].scopeParents.contains(baseline[index].id) {
                    var redo = undo
                    redo[redoIndex] = try queryAction(redoIndex + 1, parents: baseline[redoIndex].scopeParents,
                        kind: .redo, target: undo[index].id)
                    histories.append(redo)
                }
            }
        }
        for history in histories {
            for direction in [UndoDirectionV1.undo, .redo] {
                let expected = queryOracle(history, direction: direction)
                let result = try CausalUndoV1.select(actions: history.reversed(), scope: scope, direction: direction)
                #expect(Set(result.candidates) == expected.0 && result.mode == expected.1 && Set(result.scopeFrontier) == expected.2)
                comparisons += 1
            }
        }
    }
    #expect(comparisons > 10_000)
    print("Undo query independent DAG comparisons: \(comparisons)")
}

@Test(.timeLimit(.minutes(1)), arguments: [64, 256, 1024, 2048])
func undoQueryLinearHistoryKeepsLatestCandidate(count: Int) throws {
    var history: [ActionV1] = []
    for index in 1...count { history.append(try queryAction(index, parents: history.last.map { [$0.id] } ?? [])) }
    let start = DispatchTime.now().uptimeNanoseconds
    let result = try CausalUndoV1.select(actions: history, scope: history[0].scope, direction: .undo)
    #expect(result.candidates == [history.last!.id] && result.scopeFrontier == [history.last!.id] && result.mode == .automatic)
    #expect(try CausalUndoV1.select(actions: history, scope: history[0].scope, direction: .redo).candidates.isEmpty)
    print("Undo query linear \(count): \(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000) ms")
}

@Test func undoQueryRejectsBrokenScopeGraph() throws {
    let first = try queryAction(1, parents: []), second = try queryAction(2, parents: [first.id])
    let cyclic = try queryAction(1, parents: [second.id])
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try CausalUndoV1.select(actions: [cyclic, second], scope: first.scope, direction: .undo)
    }
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try CausalUndoV1.select(actions: [second], scope: first.scope, direction: .undo)
    }
    #expect(throws: CanonicalEncodingError.invalidAction) {
        try CausalUndoV1.select(actions: [first, first], scope: first.scope, direction: .undo)
    }
}
