import Testing
import NVStorageCore

@Test func incrementalFrontierMatchesIndependentReachability() {
    let n = 5
    let slots = (1..<n).flatMap { child in (0..<child).map { (child, $0) } }
    var checked = 0
    for mask in 0..<(1 << slots.count) {
        var parents = [[Int]](repeating: [], count: n)
        for (bit, pair) in slots.enumerated() where mask & (1 << bit) != 0 { parents[pair.0].append(pair.1) }
        func oracle(_ nodes: Set<Int>) -> Set<Int> {
            var result = nodes
            for node in nodes {
                var work = parents[node], seen: Set<Int> = []
                while let p = work.popLast() {
                    result.remove(p)
                    if seen.insert(p).inserted { work += parents[p] }
                }
            }
            return result
        }
        for assignment in 0..<243 {
            var digits = assignment, old: Set<Int> = [], fresh: Set<Int> = []
            for node in 0..<n {
                if digits % 3 == 1 { old.insert(node) }
                if digits % 3 == 2 { fresh.insert(node) }
                digits /= 3
            }
            let all = old.union(fresh)
            guard old.allSatisfy({ Set(parents[$0]).isSubset(of: old) }),
                  all.allSatisfy({ Set(parents[$0]).isSubset(of: all) }) else { continue }
            let result = advancingFrontier(oracle(old), adding: fresh, parents: Set(fresh.flatMap { parents[$0] }))
            #expect(result == oracle(all), "graph=\(mask) assignment=\(assignment)")
            checked += 1
        }
    }
    #expect(checked == 54_036)
}
