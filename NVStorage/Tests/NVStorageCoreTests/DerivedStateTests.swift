import Foundation
import NVStorageCore
import Testing

private struct DerivedFixture {
    let graph = MergeGraphFixture()
    let base: IdentifiedOperation
    let left: IdentifiedOperation
    let right: IdentifiedOperation
    let source: SegmentLocator
    let enclosing: SegmentLocator
    let literals: [String: [UInt8]]

    init(equal: Bool = false) throws {
        base = try graph.operation(3, "a\ngap\nz")
        left = try graph.operation(4, "A\ngap\nz", parents: [base])
        right = try graph.operation(equal ? 6 : 5, equal ? "A\ngap\nz" : "a\ngap\nZ",
                                    parents: [base], modified: equal ? 9 : 8)
        source = SegmentLocator(writerEpoch: try WriterEpoch(bytes: Array(repeating: 9, count: 16)),
            sequence: 7, segmentID: try SegmentID(bytes: Array(repeating: 8, count: 32)))
        enclosing = SegmentLocator(writerEpoch: source.writerEpoch, sequence: 8,
            segmentID: try SegmentID(bytes: Array(repeating: 7, count: 32)))
        let url = try #require(Bundle.module.url(forResource: "derived-state", withExtension: "json", subdirectory: "Fixtures"))
        let strings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        literals = strings.mapValues { text in
            let chars = Array(text)
            return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
        }
    }
    var history: [IdentifiedOperation] { [base, left, right] }
    var dependencies: DependencyLocatorTable { get throws { try DependencyLocatorTable([source]) } }
    func ref(_ i: Int) -> OperationReference {
        .external(locator: source, index: OperationIndex(UInt32(i)), expectedID: history[i].id)
    }
    func claim(equal: Bool = false) throws -> DerivedStateReferenceV1 {
        try .decodeV1(#require(literals[equal ? "equal_state" : "merged"]), dependencies: dependencies, earlierOperations: [])
    }
    func payload() throws -> ChangesPayloadV1 {
        var operations: [OperationRecordV1] = [], actions: [ActionRecordV1] = []
        let ancestor = SegmentLocator(writerEpoch: source.writerEpoch, sequence: 6,
                                      segmentID: try SegmentID(bytes: Array(repeating: 6, count: 32)))
        for (i, op) in history.enumerated() {
            let external = OperationReference.external(locator: ancestor, index: OperationIndex(0), expectedID: op.causalParents.ids[0])
            let parent = i == 0 ? external : .earlierLocal(index: OperationIndex(0))
            operations.append(try OperationRecordV1(operation: op, causalReferences: [parent],
                noteReferences: i == 0 ? [] : [parent], earlierOperations: history.prefix(i).map { $0 }))
            let id = try #require(op.effect.actionID)
            actions.append(try ActionRecordV1(id: id, origin: ActionOriginID(bytes: id.bytes), previousOrigin: nil,
                scope: i == 0 ? .collection : .note(graph.birth), scopeParents: [],
                kind: i == 0 ? .createImportBatch : .savedEdit, members: [OperationIndex(UInt32(i))],
                affected: [.init(birth: graph.birth, before: i == 0 ? .freshBirthAbsence : .value(parent),
                                 after: .value(.earlierLocal(index: OperationIndex(UInt32(i)))))],
                operations: history, earlierActions: actions.map(\.action)))
        }
        return try ChangesPayloadV1(dependencies: DependencyLocatorTable([ancestor]), operations: operations, actions: actions)
    }
    func reconstruct(_ claim: DerivedStateReferenceV1, history: [IdentifiedOperation]? = nil,
                     collection: CollectionID? = nil, birth: NoteBirth? = nil) async throws -> ReconstructedDerivedStateV1 {
        let payload = try payload()
        return try await claim.reconstruct(collection: collection ?? graph.collection, birth: birth ?? graph.birth,
            history: history ?? self.history, earlierOperations: [], at: enclosing) { $0 == source ? payload : nil }
    }
}

@Test(arguments: [false, true])
func derivedStateLiteralLayoutAndReconstruction(_ equal: Bool) async throws {
    let f = try DerivedFixture(equal: equal), claim = try f.claim(equal: equal)
    #expect(f.base.id.bytes == f.literals["base"] && f.left.id.bytes == f.literals["left"])
    #expect(f.right.id.bytes == f.literals[equal ? "equal" : "right"])
    let bytes = try #require(f.literals[equal ? "equal_state" : "merged"])
    #expect(try claim.encodedV1(dependencies: f.dependencies, earlierOperations: []) == bytes)
    #expect(claim.encodedByteCount == UInt64(equal ? 119 : 194))
    for order in [f.history, Array(f.history.reversed()), [f.left, f.right, f.base]] {
        let checked = try await f.reconstruct(claim, history: order)
        #expect(checked.collection == f.graph.collection && checked.birth == f.graph.birth)
        #expect(checked.value.value.body.string == (equal ? "A\ngap\nz" : "A\ngap\nZ"))
        #expect(Set(checked.value.represented) == [f.left.id, f.right.id])
        #expect(checked.value.value.modified.secondsSinceReferenceDate == (equal ? 9 : 8))
        #expect(checked.value.merge?.base == (equal ? nil : f.base.id))
        #expect(checked.value.merge?.id.bytes == (equal ? nil : f.literals["merge_id"]))
    }
}

@Test(arguments: [false, true])
func derivedStateMalformedEncodingAndLocalRebinding(_ equal: Bool) async throws {
    let f = try DerivedFixture(equal: equal), bytes = try #require(f.literals[equal ? "equal_state" : "merged"])
    func decode(_ b: [UInt8]) throws -> DerivedStateReferenceV1 {
        try .decodeV1(b, dependencies: f.dependencies, earlierOperations: [])
    }
    _ = try decode(bytes)
    for n in bytes.indices { #expect(throws: (any Error).self) { try decode(Array(bytes.prefix(n))) } }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try decode(bytes + [0]) }
    var bad = bytes; bad[0] = 99
    #expect(throws: CanonicalEncodingError.invalidDiscriminant) { try decode(bad) }
    bad = bytes; bad.replaceSubrange(1..<5, with: [0, 0, 0, 1])
    #expect(throws: CanonicalEncodingError.invalidReference) { try decode(bad) }
    bad = bytes; bad.replaceSubrange(1..<5, with: [255, 255, 255, 255])
    #expect(throws: (any Error).self) { try decode(bad) }
    bad = bytes; bad.replaceSubrange(5..<87, with: Array(bytes[46..<87]) + Array(bytes[5..<46]))
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try decode(bad) }
    bad = bytes; bad.replaceSubrange(46..<87, with: bytes[5..<46])
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try decode(bad) }
    if !equal {
        bad = bytes; bad[88] = 2
        #expect(throws: CanonicalEncodingError.unsupportedFormat) { try decode(bad) }
    }
    let original = try decode(bytes)
    let local = try DerivedStateReferenceV1(kind: equal ? .equal : .merged(base: .earlierLocal(index: OperationIndex(0)),
        id: MergeIDV1(bytes: #require(f.literals["merge_id"]))),
        inputs: [.earlierLocal(index: OperationIndex(2)), .earlierLocal(index: OperationIndex(1))],
        result: original.result, earlierOperations: f.history)
    #expect(local.state == original.state)
    let encoded = try local.encodedV1(dependencies: DependencyLocatorTable([]), earlierOperations: f.history)
    #expect(try DerivedStateReferenceV1.decodeV1(encoded, dependencies: DependencyLocatorTable([]), earlierOperations: f.history) == local)
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try local.encodedV1(dependencies: DependencyLocatorTable([]), earlierOperations: [f.right, f.base, f.left])
    }
    // Swapping equal-set inputs changes each local address while preserving the expanded ID set.
    let swapped = [f.base, f.right, f.left]
    #expect(throws: CanonicalEncodingError.invalidReference) { try local.encodedV1(dependencies: DependencyLocatorTable([]), earlierOperations: swapped) }
    let edit = try f.graph.operation(30, "edited", parents: [f.left, f.right])
    let inputs: [OperationReference] = [.earlierLocal(index: OperationIndex(1)), .earlierLocal(index: OperationIndex(2))]
    // Hold one vector's external addresses fixed while challenging the other vector's local order.
    for localCausal in [false, true] {
        let external = [f.ref(1), f.ref(2)]
        let operation = try OperationRecordV1(operation: edit, causalReferences: localCausal ? inputs : external,
            noteReferences: localCausal ? external : inputs, earlierOperations: f.history)
        let operationBytes = try operation.encodedV1(dependencies: f.dependencies, earlierOperations: f.history)
        #expect(try OperationRecordV1.decodeV1(operationBytes, dependencies: f.dependencies, earlierOperations: f.history) == operation)
        #expect(throws: CanonicalEncodingError.invalidReference) {
            try operation.encodedV1(dependencies: f.dependencies, earlierOperations: swapped)
        }
    }
    await #expect(throws: CanonicalEncodingError.invalidReference) {
        try await local.reconstruct(collection: f.graph.collection, birth: f.graph.birth, history: f.history,
            earlierOperations: swapped, at: f.enclosing, resolve: { _ in nil })
    }
    await #expect(throws: CanonicalEncodingError.invalidReference) {
        try await local.reconstruct(collection: f.graph.collection, birth: f.graph.birth, history: f.history,
            earlierOperations: [f.right, f.base, f.left], at: f.enclosing, resolve: { _ in nil })
    }
    let checked = try await local.reconstruct(collection: f.graph.collection, birth: f.graph.birth, history: f.history,
        earlierOperations: f.history, at: f.enclosing, resolve: { _ in nil })
    #expect(try await checked.value == f.reconstruct(original).value)
}

@Test func derivedStateExactEvidenceAndWrongContext() async throws {
    let f = try DerivedFixture(), claim = try f.claim()
    _ = try await f.reconstruct(claim)
    let wrongDigest = try DerivedStateReferenceV1(kind: claim.kind, inputs: claim.inputReferences,
        result: NoteValueDigest(bytes: Array(repeating: 55, count: 32)), earlierOperations: [])
    await #expect(throws: CanonicalEncodingError.identityMismatch) { try await f.reconstruct(wrongDigest) }
    let wrongID = try DerivedStateReferenceV1(kind: .merged(base: f.ref(0), id: MergeIDV1(bytes: Array(repeating: 77, count: 32))),
        inputs: claim.inputReferences, result: claim.result, earlierOperations: [])
    await #expect(throws: CanonicalEncodingError.identityMismatch) { try await f.reconstruct(wrongID) }
    await #expect(throws: CanonicalEncodingError.identityMismatch) {
        try await f.reconstruct(claim, collection: CollectionID(bytes: Array(repeating: 7, count: 16)))
    }
    await #expect(throws: CanonicalEncodingError.invalidReference) {
        try await f.reconstruct(claim, birth: NoteBirth(bytes: Array(repeating: 7, count: 16)))
    }
    await #expect(throws: CanonicalEncodingError.missingDependency) { try await f.reconstruct(claim, history: [f.left, f.base]) }
    await #expect(throws: CanonicalEncodingError.missingDependency) {
        try await claim.reconstruct(collection: f.graph.collection, birth: f.graph.birth, history: f.history,
            earlierOperations: [], at: f.enclosing, resolve: { _ in nil })
    }
    let badRef = OperationReference.external(locator: f.source, index: OperationIndex(0), expectedID: f.left.id)
    let misaddressed = try DerivedStateReferenceV1(kind: claim.kind, inputs: [badRef, f.ref(2)], result: claim.result, earlierOperations: [])
    await #expect(throws: CanonicalEncodingError.identityMismatch) { try await f.reconstruct(misaddressed) }
    await #expect(throws: CanonicalEncodingError.invalidReference) {
        try await claim.reconstruct(collection: f.graph.collection, birth: f.graph.birth, history: f.history,
            earlierOperations: [], at: f.source, resolve: { _ in try f.payload() })
    }
    // A different dependency-table layout retains the expanded state and exact target.
    let precedingLocator = SegmentLocator(writerEpoch: f.source.writerEpoch, sequence: 6, segmentID: f.enclosing.segmentID)
    let deps = try DependencyLocatorTable([precedingLocator, f.source])
    let bytes = try claim.encodedV1(dependencies: deps, earlierOperations: [])
    #expect(bytes != f.literals["merged"])
    #expect(try DerivedStateReferenceV1.decodeV1(bytes, dependencies: deps, earlierOperations: []).state == claim.state)
}

@Test func derivedStateChecksUniqueBaseAndClaimKind() async throws {
    let f = try DerivedFixture(), mid = try f.graph.operation(20, "a\ngap\nz", parents: [f.base])
    let l = try f.graph.operation(21, "A\ngap\nz", parents: [mid])
    let r = try f.graph.operation(22, "a\ngap\nZ", parents: [mid])
    let history = [f.base, mid, l, r]
    guard case .current(let current) = try f.graph.reduce(history).outcome else {
        Issue.record("unique-base companion must merge"); return
    }
    #expect(current.value.body.string == "A\ngap\nZ")
    let merge = try #require(current.merge)
    let refs: [OperationReference] = [.earlierLocal(index: OperationIndex(2)), .earlierLocal(index: OperationIndex(3))]
    func claim(_ base: Int) throws -> DerivedStateReferenceV1 {
        try .init(kind: .merged(base: .earlierLocal(index: OperationIndex(UInt32(base))), id: merge.id),
                  inputs: refs, result: merge.result, earlierOperations: history)
    }
    func check(_ claim: DerivedStateReferenceV1) async throws -> ReconstructedDerivedStateV1 {
        try await claim.reconstruct(collection: f.graph.collection, birth: f.graph.birth, history: history,
            earlierOperations: history, at: f.enclosing, resolve: { _ in nil })
    }
    #expect(try await check(claim(1)).value.merge?.base == mid.id)
    await #expect(throws: CanonicalEncodingError.identityMismatch) { try await check(claim(0)) }
    let wrongKind = try DerivedStateReferenceV1(kind: .equal, inputs: refs, result: merge.result, earlierOperations: history)
    await #expect(throws: CanonicalEncodingError.identityMismatch) { try await check(wrongKind) }
    #expect(throws: CanonicalEncodingError.invalidReference) { try claim(2) }

    let x = try f.graph.operation(23, "x", parents: [f.base]), y = try f.graph.operation(24, "y", parents: [f.base])
    let a = try f.graph.operation(25, "a", parents: [x, y]), b = try f.graph.operation(26, "b", parents: [x, y])
    let ambiguous = [f.base, x, y, a, b]
    let reduction = try f.graph.reduce(ambiguous)
    #expect(Set(reduction.bestBases) == [x.id, y.id])
    let forged = try DerivedStateReferenceV1(kind: .merged(base: .earlierLocal(index: OperationIndex(1)), id: merge.id),
        inputs: [.earlierLocal(index: OperationIndex(3)), .earlierLocal(index: OperationIndex(4))],
        result: merge.result, earlierOperations: ambiguous)
    await #expect(throws: CanonicalEncodingError.identityMismatch) {
        try await forged.reconstruct(collection: f.graph.collection, birth: f.graph.birth, history: ambiguous,
            earlierOperations: ambiguous, at: f.enclosing, resolve: { _ in nil })
    }
}

@Test func derivedStateChangedGraphAndUnchosenAlternatives() async throws {
    let f = try DerivedFixture(), claim = try f.claim()
    let third = try f.graph.operation(7, "third", parents: [f.base])
    await #expect(throws: CanonicalEncodingError.identityMismatch) { try await f.reconstruct(claim, history: f.history + [third]) }
    let later = try f.graph.operation(8, "later", parents: [f.left])
    await #expect(throws: CanonicalEncodingError.identityMismatch) { try await f.reconstruct(claim, history: f.history + [later]) }
    // Receiver-only later evidence leaves the original declared-basis claim reconstructible.
    #expect(try await f.reconstruct(claim).value.value.body.string == "A\ngap\nZ")
    let equal = try DerivedFixture(equal: true), equalClaim = try equal.claim(equal: true)
    let duplicate = try equal.graph.operation(7, "A\ngap\nz", parents: [equal.base], modified: 9)
    await #expect(throws: CanonicalEncodingError.identityMismatch) { try await equal.reconstruct(equalClaim, history: equal.history + [duplicate]) }

    // Pick a fixed unequal head whose actual canonical ID sorts after the equal class.
    let alternate = try equal.graph.operation(8, "incompatible", parents: [equal.base])
    let expectedFirst = [equal.left.id.bytes, equal.right.id.bytes].sorted { $0.lexicographicallyPrecedes($1) }[0]
    #expect(expectedFirst.lexicographicallyPrecedes(alternate.id.bytes))
    let checked = try await equal.reconstruct(equalClaim, history: equal.history + [alternate])
    #expect(Set(checked.reduction.heads) == [equal.left.id, equal.right.id, alternate.id])
    #expect(Set(checked.value.represented) == [equal.left.id, equal.right.id])
    let edit = try equal.graph.operation(9, "edited", parents: [equal.left, equal.right], knowledge: [equal.left, equal.right, alternate])
    #expect(Set(try equal.graph.reduce(equal.history + [alternate, edit]).heads) == [edit.id, alternate.id])
}
