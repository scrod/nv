import Foundation
import NVStorageCore
import Testing

private func mergeValue(_ body: String, title: String = "T", labels: [String] = [], created: Double = 1,
                        modified: Double = 2) throws -> PlaintextNoteValue {
    try PlaintextNoteValue(title: ExactUTF8(bytes: Array(title.utf8)), body: ExactUTF8(bytes: Array(body.utf8)),
        labels: CanonicalLabels(labels.map { try ExactUTF8(bytes: Array($0.utf8)) }),
        created: DisplayDate(secondsSinceReferenceDate: created), modified: DisplayDate(secondsSinceReferenceDate: modified))
}

private func bodyResult(_ b: String, _ l: String, _ r: String) throws -> String? {
    switch try NVConservativeMergeV1.merge(base: mergeValue(b), left: mergeValue(l), right: mergeValue(r),
                                         birthCreated: DisplayDate(secondsSinceReferenceDate: 1)) {
    case .merged(let value): return value.body.string
    case .review: return nil
    }
}

@Test func mergeScalarLabelsAndDates() throws {
    for b in 0...2 { for l in 0...2 { for r in 0...2 {
        let changed = Set([l, r]).subtracting([b])
        let expected = changed.isEmpty ? b : (changed.count == 1 ? changed.first : nil)
        let result = try NVConservativeMergeV1.merge(base: mergeValue("body", title: "\(b)"),
            left: mergeValue("body", title: "\(l)", created: 400, modified: 8),
            right: mergeValue("body", title: "\(r)", created: 900, modified: -5), birthCreated: DisplayDate(secondsSinceReferenceDate: 1))
        if let expected {
            guard case .merged(let v) = result else { Issue.record("scalar should merge"); continue }
            #expect(v.title.string == "\(expected)" && v.created.secondsSinceReferenceDate == 1 && v.modified.secondsSinceReferenceDate == 8)
        } else { #expect(result == .review(.title)) }
    } } }
    for b in [false, true] { for l in [false, true] { for r in [false, true] {
        let result = try NVConservativeMergeV1.merge(base: mergeValue("body", labels: b ? ["tag"] : []),
            left: mergeValue("body", labels: l ? ["tag"] : []), right: mergeValue("body", labels: r ? ["tag"] : []),
            birthCreated: DisplayDate(secondsSinceReferenceDate: 1))
        guard case .merged(let v) = result else { Issue.record("Boolean membership always merges"); continue }
        let expected = b ? l && r : l || r
        #expect(v.labels.entries.map(\.string) == (expected ? ["tag"] : []))
    } } }
    let result = try NVConservativeMergeV1.merge(base: mergeValue("a\ngap\nz", labels: ["old"]),
        left: mergeValue("A\ngap\nz", labels: ["é", "Tag"]),
        right: mergeValue("a\ngap\nZ", title: "new", labels: ["old", "e\u{301}", "tag"]),
        birthCreated: DisplayDate(secondsSinceReferenceDate: 1))
    guard case .merged(let v) = result else { Issue.record("independent fields must all merge"); return }
    #expect(v.body.string == "A\ngap\nZ" && v.title.string == "new")
    #expect(v.labels.entries.map(\.bytes) == ["Tag", "e\u{301}", "tag", "é"].map { Array($0.utf8) })
}

@Test func mergeGeneratedEditCoordinates() throws {
    let base = ["a\n", "b\n", "c\n", "d\n", "e\n"]
    var edits: [(Int, Int, [String])] = []
    for i in 0...base.count { for j in i...base.count { for replacement in [[], ["X\n"], ["Y\n"]] {
        if i != j || !replacement.isEmpty { edits.append((i, j, replacement)) }
    } } }
    func apply(_ e: (Int, Int, [String])) -> [String] { Array(base[..<e.0]) + e.2 + Array(base[e.1...]) }
    var cases = 0
    for a in edits { for z in edits {
        let l = apply(a), r = apply(z)
        let (first, second) = a.0 < z.0 ? (a, z) : (z, a)
        // Expected text uses original generated coordinates, independently of inferred edits.
        let expected = l == r ? l.joined() : (first.1 < second.0
            ? (Array(base[..<first.0]) + first.2 + Array(base[first.1..<second.0]) + second.2 + Array(base[second.1...])).joined() : nil)
        #expect(try bodyResult(base.joined(), l.joined(), r.joined()) == expected)
        #expect(try bodyResult(base.joined(), r.joined(), l.joined()) == expected)
        cases += 1
    } }
    #expect(cases == 3249)
}

@Test func mergeExactTextAndLimits() throws {
    let vectors: [(String, String, String, String?)] = [
        ("a\ngap\nz", "A\ngap\nz", "a\ngap\nZ", "A\ngap\nZ"),
        ("a\nb\n", "A\nb\n", "a\nB\n", nil),
        ("ab", "Ab", "aB", nil),
        ("x\ny\n", "p\nx\ny\n", "q\nx\ny\n", nil),
        ("a\r\ngap\r\nz\r\n", "A\r\ngap\r\nz\r\n", "a\r\ngap\r\nZ\r\n", "A\r\ngap\r\nZ\r\n"),
        ("é\ngap\n🦄", "e\u{301}\ngap\n🦄", "é\ngap\n🐈", "e\u{301}\ngap\n🐈"),
        ("", "", "new", "new"), ("", "\n", "x", nil),
        ("\0\ngap\nz", "a\0\ngap\nz", "\0\ngap\nZ", "a\0\ngap\nZ"),
        ("x\nx\nx\n", "X\nx\nx\n", "x\nx\nX\n", "X\nx\nX\n"),
        ("a\nb\nc\nd\ne\n", "A\nb\nc\nd\nE\n", "a\nb\nC\nd\ne\n", nil),
        ("a\ngap\nz\n", "a\ninsert\ngap\nz\n", "A\ngap\nz\n", nil)
    ]
    for (b, l, r, expected) in vectors {
        // Compare bytes to distinguish canonically equivalent Unicode spellings.
        #expect(try bodyResult(b, l, r).map { Array($0.utf8) } == expected.map { Array($0.utf8) })
        #expect(try bodyResult(b, r, l).map { Array($0.utf8) } == expected.map { Array($0.utf8) })
    }
    for count in [10_000, 10_001] {
        let b = String(repeating: "a\n", count: count), l = "L\n" + b.dropFirst(2), r = String(b.dropLast(2)) + "R\n"
        #expect(try bodyResult(b, l, r) == (count == 10_000 ? "L\n" + String(repeating: "a\n", count: count - 2) + "R\n" : nil))
        #expect(try bodyResult(b, b, l) == l)
        #expect(try bodyResult(b, l, l) == l)
    }
    let half = String(repeating: "x", count: Int(ObjectLimitsV1.decodedPayloadBytes / 2))
    #expect(try NVConservativeMergeV1.merge(base: mergeValue(""), left: mergeValue("", title: half),
        right: mergeValue(half), birthCreated: DisplayDate(secondsSinceReferenceDate: 1)) == .review(.resultLimit))
}

struct MergeGraphFixture {
    let collection = try! CollectionID(bytes: Array(repeating: 1, count: 16))
    let birth = try! NoteBirth(bytes: Array(repeating: 2, count: 16))
    func operation(_ n: UInt8, _ body: String, parents: [IdentifiedOperation] = [],
                   knowledge: [IdentifiedOperation]? = nil, title: String = "T", modified: Double = 2) throws -> IdentifiedOperation {
        let action = try ActionID(bytes: Array(repeating: n, count: 16)), value = try mergeValue(body, title: title, modified: modified)
        let causal = (knowledge ?? parents).map(\.id)
        return try IdentifiedOperation(nonce: OperationNonce(bytes: Array(repeating: n, count: 16)),
            effect: parents.isEmpty ? .create(action: action, birth: birth, value: value) : .put(action: action, birth: birth, value: value),
            causalParents: CausalParentSet(causal.isEmpty ? [OperationID(bytes: Array(repeating: 99, count: 32))] : causal),
            notePredecessors: NotePredecessorSet(parents.map(\.id)))
    }
    func reduce(_ ops: [IdentifiedOperation]) throws -> NoteReductionV1 { try .compute(collection: collection, birth: birth, operations: ops) }
}

@Test func mergeGraphSelectionAndProvenance() throws {
    let f = MergeGraphFixture(), b = try f.operation(3, "a\ngap\nz")
    let l = try f.operation(4, "A\ngap\nz", parents: [b]), r = try f.operation(5, "a\ngap\nZ", parents: [b], modified: 8)
    let result = try f.reduce([l, b, r])
    guard case .current(let current) = result.outcome else { Issue.record("separated edits must merge"); return }
    #expect(current.value.body.string == "A\ngap\nZ")
    #expect(Set(current.represented) == [l.id, r.id])
    #expect(current.merge?.base == b.id && current.merge?.inputs == result.heads)
    #expect(current.value.modified.secondsSinceReferenceDate == 8)
    for order in [[b, l, r], [r, b, l], [r, l, b], [l, r, b]] { #expect(try f.reduce(order) == result) }
    let t = try f.operation(6, "third", parents: [b])
    let triple = try f.reduce([b, l, r, t])
    guard case .conflict(let choice, let reason) = triple.outcome else { Issue.record("third head requires review"); return }
    #expect(reason == .headCount && Set(triple.heads) == [l.id, r.id, t.id] && choice.merge == nil)
    #expect(choice.represented.first == triple.heads.first)
    let descendant = try f.operation(7, "L2\ngap\nz", parents: [l])
    guard case .current(let dominated) = try f.reduce([b, l, r, descendant]).outcome else { Issue.record("dominated input must be removed"); return }
    #expect(dominated.value.body.string == "L2\ngap\nZ" && Set(dominated.represented) == [descendant.id, r.id])
    let x = try f.operation(8, "other", parents: [b]), y = try f.operation(9, "third", parents: [b])
    let a = try f.operation(10, "left", parents: [x, y]), z = try f.operation(11, "right", parents: [x, y])
    let ambiguous = try f.reduce([b, x, y, a, z])
    #expect(Set(ambiguous.bestBases) == [x.id, y.id])
    guard case .conflict(_, .ambiguousBase) = ambiguous.outcome else { Issue.record("multiple best bases require review"); return }
    let aware = try f.operation(12, "left edited", parents: [x], knowledge: [x, y])
    let knowledge = try f.reduce([b, x, y, aware])
    #expect(Set(knowledge.heads) == [aware.id, y.id], "causal knowledge preserves unchosen note heads")
    #expect(knowledge.bestBases == [b.id])
}

@Test func mergeEqualHeadsAndRejectedGraphInputs() throws {
    let f = MergeGraphFixture(), b = try f.operation(3, "base")
    let l = try f.operation(4, "equal", parents: [b]), r = try f.operation(5, "equal", parents: [b], modified: 8)
    let t = try f.operation(6, "equal", parents: [b], modified: 9)
    guard case .current(let value) = try f.reduce([b, l, r, t]).outcome else { Issue.record("equal heads retain one view"); return }
    #expect(Set(value.represented) == [l.id, r.id, t.id] && value.merge == nil)
    #expect(value.value.modified.secondsSinceReferenceDate == 9)
    #expect(throws: CanonicalEncodingError.missingDependency) { try f.reduce([b, try f.operation(7, "new", parents: [l])]) }
    #expect(throws: CanonicalEncodingError.invalidOperation) { try f.reduce([b, b]) }
    #expect(throws: CanonicalEncodingError.invalidOperation) { try f.reduce([b, f.operation(8, "second creation")]) }
    #expect(throws: CanonicalEncodingError.invalidOperation) {
        try NoteReductionV1.compute(collection: f.collection, birth: NoteBirth(bytes: Array(repeating: 9, count: 16)), operations: [b])
    }
    let deleted = try IdentifiedOperation(nonce: OperationNonce(bytes: Array(repeating: 9, count: 16)),
        effect: .delete(action: ActionID(bytes: Array(repeating: 9, count: 16)), birth: f.birth),
        causalParents: CausalParentSet([l.id]), notePredecessors: NotePredecessorSet([]))
    #expect(try f.reduce([b, l, r, deleted]).outcome == .deletionRequired([deleted.id]))
    #expect(try f.reduce([]).outcome == .empty)
}

@Test func mergeExhaustiveRootedDAGs() throws {
    let f = MergeGraphFixture()
    var count = 0
    for m2 in 1..<4 { for m3 in 1..<8 { for m4 in 1..<16 {
        let masks = [0, 1, m2, m3, m4]
        var ops: [IdentifiedOperation] = [], reachable = Array(repeating: Array(repeating: false, count: 5), count: 5)
        for i in 0..<5 {
            let ps = (0..<i).filter { masks[i] & (1 << $0) != 0 }
            for p in ps { reachable[i][p] = true }
            ops.append(try f.operation(UInt8(i + 1), "value \(i)", parents: ps.map { ops[$0] }))
        }
        // Independent all-pairs transitive closure of the generated edge matrix.
        for k in 0..<5 { for i in 0..<5 { for j in 0..<5 { reachable[i][j] = reachable[i][j] || (reachable[i][k] && reachable[k][j]) } } }
        let heads = (0..<5).filter { j in !(0..<5).contains { reachable[$0][j] } }
        let reduction = try f.reduce(Array(ops.reversed()))
        #expect(Set(reduction.heads) == Set(heads.map { ops[$0].id }))
        if heads.count == 2 {
            let common = (0..<5).filter { j in heads.allSatisfy { reachable[$0][j] } }
            let best = common.filter { j in !common.contains { reachable[$0][j] } }
            #expect(Set(reduction.bestBases) == Set(best.map { ops[$0].id }))
        }
        count += 1
    } } }
    #expect(count == 315)
}

@Test func mergeLiteralIdentityFixture() throws {
    let url = try #require(Bundle.module.url(forResource: "merge", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
    let f = MergeGraphFixture(), b = try f.operation(3, "a\ngap\nz")
    let l = try f.operation(4, "A\ngap\nz", parents: [b]), r = try f.operation(5, "a\ngap\nZ", parents: [b], modified: 8)
    guard case .current(let current) = try f.reduce([r, b, l]).outcome else { Issue.record("fixture must merge"); return }
    let merge = try #require(current.merge)
    #expect(hex(b.id.bytes) == fixture["base"] && hex(l.id.bytes) == fixture["left"] && hex(r.id.bytes) == fixture["right"])
    #expect(hex(current.value.encodedV1()) == fixture["value"] && hex(merge.result.bytes) == fixture["digest"])
    #expect(hex(merge.identityPreimageV1()) == fixture["preimage"] && hex(merge.id.bytes) == fixture["identity"])
    let other = try CollectionID(bytes: Array(repeating: 7, count: 16))
    guard case .current(let changed) = try NoteReductionV1.compute(collection: other, birth: f.birth, operations: [b, l, r]).outcome else {
        Issue.record("different collection has the same merge value"); return
    }
    #expect(changed.value == current.value && changed.merge?.id != merge.id)
}
