import Crypto

/// Content identity of a computed merge and its exact source provenance.
public struct MergeIDV1: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 32) }
}

/// Recomputable two-head merge evidence issued by the note-ancestry reducer.
public struct DerivedMergeV1: Equatable, Sendable {
    public let collection: CollectionID
    public let birth: NoteBirth
    public let inputs: [OperationID]
    public let base: OperationID
    public let result: NoteValueDigest
    public let id: MergeIDV1

    fileprivate init(collection: CollectionID, birth: NoteBirth, inputs: [OperationID], base: OperationID,
                     value: PlaintextNoteValue) throws {
        self.collection = collection; self.birth = birth; self.inputs = inputs; self.base = base
        result = try value.digestV1()
        id = try MergeIDV1(bytes: Array(SHA256.hash(data: Self.preimage(collection, birth, inputs, base, result))))
    }

    /// Fixed identity encoding: domain, collection, birth, version, inputs, base, result digest.
    public func identityPreimageV1() -> [UInt8] { Self.preimage(collection, birth, inputs, base, result) }

    private static func preimage(_ collection: CollectionID, _ birth: NoteBirth, _ inputs: [OperationID],
                                 _ base: OperationID, _ result: NoteValueDigest) -> [UInt8] {
        Array("NV derived merge\0v1\0".utf8) + collection.bytes + birth.bytes + bigEndianBytes(UInt16(1))
            + bigEndianBytes(UInt32(inputs.count)) + inputs.flatMap(\.bytes) + base.bytes + result.bytes
    }
}

/// A computed value paired with all the input revisions it represents.
public struct ReducedNoteValueV1: Equatable, Sendable {
    public let value: PlaintextNoteValue
    public let represented: [OperationID]
    public let merge: DerivedMergeV1?
    fileprivate init(value: PlaintextNoteValue, represented: [OperationID], merge: DerivedMergeV1? = nil) {
        self.value = value; self.represented = represented; self.merge = merge
    }
}

public enum NoteReductionOutcomeV1: Equatable, Sendable {
    case empty
    case current(ReducedNoteValueV1)
    case conflict(current: ReducedNoteValueV1, reason: MergeReviewReasonV1)
    /// Logical Delete requires the separate deletion/preservation reducer.
    case deletionRequired([OperationID])
}

/// Two differing maximal values and their unique best base, selected by note ancestry.
private struct EligibleHeadPair {
    let left: PlaintextNoteValue
    let right: PlaintextNoteValue
    let base: PlaintextNoteValue
}

/// Pure reduction of a supplied complete, accepted note history. The owner supplies
/// accepted membership and fences use of the computed result against its captured prefix.
public struct NoteReductionV1: Equatable, Sendable {
    public let heads: [OperationID]
    public let bestBases: [OperationID]
    public let outcome: NoteReductionOutcomeV1
    private init(heads: [OperationID], bestBases: [OperationID] = [], outcome: NoteReductionOutcomeV1) {
        self.heads = heads; self.bestBases = bestBases; self.outcome = outcome
    }

    public static func compute(collection: CollectionID, birth: NoteBirth,
                               operations: [IdentifiedOperation]) throws -> Self {
        var values: [OperationID: PlaintextNoteValue] = [:]
        var parents: [OperationID: [OperationID]] = [:], roots: [OperationID] = [], deletes: [OperationID] = []
        var seen: Set<OperationID> = []
        var rootDomains: Set<DeterministicConflictIdentityV1> = []
        var ordinaryRoots = 0
        for op in operations {
            try Task.checkCancellation()
            guard op.effect.targetBirth == birth, seen.insert(op.id).inserted else { throw CanonicalEncodingError.invalidOperation }
            switch op.effect {
            case .create(_, _, let value), .importNote(_, _, let value): roots.append(op.id); values[op.id] = value; ordinaryRoots += 1
            case .recoverCopy(_, _, let source, let value):
                if source.reused != nil { continue }
                roots.append(op.id); values[op.id] = value; rootDomains.insert(.recovery(source.key, slot: source.slot))
            case .adoptAutomatic(_, _, let source, let value):
                roots.append(op.id); values[op.id] = value; rootDomains.insert(.automatic(source.key))
            case .put(_, _, let value): values[op.id] = value
            case .delete: deletes.append(op.id); continue
            case .retireConflict: continue
            default: throw CanonicalEncodingError.invalidOperation
            }
            parents[op.id] = op.notePredecessors.ids
        }
        if seen.isEmpty { return Self(heads: [], outcome: .empty) }
        if values.isEmpty, !deletes.isEmpty { return Self(heads: [], outcome: .deletionRequired(sorted(deletes))) }
        guard !roots.isEmpty, roots.count == 1 || (ordinaryRoots == 0 && rootDomains.count == 1),
              let firstRoot = sorted(roots).first, let created = values[firstRoot]?.created else { throw CanonicalEncodingError.invalidOperation }
        var children: [OperationID: [OperationID]] = [:], remaining: [OperationID: Int] = [:]
        var superseded: Set<OperationID> = []
        for (id, ps) in parents {
            remaining[id] = ps.count
            for p in ps {
                guard values[p] != nil else { throw CanonicalEncodingError.missingDependency }
                children[p, default: []].append(id); superseded.insert(p)
            }
        }
        // Iterative topological validation bounds stack usage on long note histories.
        var ready = roots, visited = 0
        while let id = ready.popLast() {
            try Task.checkCancellation(); visited += 1
            for child in children[id] ?? [] {
                remaining[child]! -= 1
                if remaining[child] == 0 { ready.append(child) }
            }
        }
        guard visited == values.count else { throw CanonicalEncodingError.invalidOperation }
        let heads = sorted(Set(values.keys).subtracting(superseded))
        if !deletes.isEmpty { return Self(heads: heads, outcome: .deletionRequired(sorted(deletes))) }
        guard let first = heads.first, let firstValue = values[first] else { throw CanonicalEncodingError.invalidOperation }

        func selected() throws -> ReducedNoteValueV1 {
            let represented = heads.filter { values[$0]!.hasSameEditableFields(as: firstValue) }
            let modified = represented.reduce(firstValue.modified) { NVConservativeMergeV1.latest($0, values[$1]!.modified) }
            let value = try PlaintextNoteValue(title: firstValue.title, body: firstValue.body, labels: firstValue.labels,
                                               created: created, modified: modified)
            return ReducedNoteValueV1(value: value, represented: represented)
        }
        let chosen = try selected()
        if chosen.represented.count == heads.count { return Self(heads: heads, outcome: .current(chosen)) }
        guard heads.count == 2 else { return Self(heads: heads, outcome: .conflict(current: chosen, reason: .headCount)) }

        func ancestors(_ start: OperationID) throws -> Set<OperationID> {
            var result: Set<OperationID> = [], work = [start]
            while let id = work.popLast() {
                try Task.checkCancellation()
                if result.insert(id).inserted { work.append(contentsOf: parents[id]!) }
            }
            return result
        }
        let common = try ancestors(heads[0]).intersection(ancestors(heads[1]))
        // Common ancestry is downward closed: direct common parents identify every
        // nonmaximal common ancestor without repeated transitive searches.
        let dominated = Set(common.flatMap { parents[$0]! })
        let bases = sorted(common.subtracting(dominated))
        guard bases.count == 1 else {
            return Self(heads: heads, bestBases: bases, outcome: .conflict(current: chosen, reason: .ambiguousBase))
        }
        let pair = EligibleHeadPair(left: values[heads[0]]!, right: values[heads[1]]!, base: values[bases[0]]!)
        switch try NVConservativeMergeV1.merge(base: pair.base, left: pair.left, right: pair.right, birthCreated: created) {
        case .review(let reason): return Self(heads: heads, bestBases: bases, outcome: .conflict(current: chosen, reason: reason))
        case .merged(let value):
            let merge = try DerivedMergeV1(collection: collection, birth: birth, inputs: heads, base: bases[0], value: value)
            return Self(heads: heads, bestBases: bases,
                        outcome: .current(ReducedNoteValueV1(value: value, represented: heads, merge: merge)))
        }
    }

    private static func sorted<S: Sequence>(_ ids: S) -> [OperationID] where S.Element == OperationID {
        ids.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    }
}
