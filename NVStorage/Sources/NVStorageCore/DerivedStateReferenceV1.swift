/// Expanded identities and result claims carried by a derived note-state record.
public enum DerivedStateV1: Equatable, Hashable, Sendable {
    case equal(inputs: [OperationID], result: NoteValueDigest)
    case merged(inputs: [OperationID], base: OperationID, result: NoteValueDigest, id: MergeIDV1)

    public var inputs: [OperationID] {
        switch self { case .equal(let inputs, _), .merged(let inputs, _, _, _): inputs }
    }
    public var result: NoteValueDigest {
        switch self { case .equal(_, let result), .merged(_, _, let result, _): result }
    }
}

/// Canonical transport references for an equal-value set or two-head merge.
public struct DerivedStateReferenceV1: Equatable, Hashable, Sendable {
    public enum Kind: Equatable, Hashable, Sendable {
        case equal
        case merged(base: OperationReference, id: MergeIDV1)
    }

    public let kind: Kind
    public let inputReferences: [OperationReference]
    public let result: NoteValueDigest
    public let state: DerivedStateV1

    public var references: [OperationReference] {
        switch kind { case .equal: inputReferences; case .merged(let base, _): inputReferences + [base] }
    }

    public var externalLocators: [SegmentLocator] {
        references.compactMap { if case .external(let locator, _, _) = $0 { locator } else { nil } }
    }

    /// Binds local references to the caller's earlier operation prefix and sorts by identity.
    public init(kind: Kind, inputs: [OperationReference], result: NoteValueDigest,
                earlierOperations: [IdentifiedOperation]) throws {
        guard inputs.count >= 2 else { throw CanonicalEncodingError.invalidReference }
        guard UInt64(inputs.count) <= ObjectLimitsV1.decodedPayloadBytes / 5 else {
            throw CanonicalEncodingError.lengthLimit
        }
        let ordered = try inputs.map { ($0, try $0.expandedID(earlierOperations: earlierOperations)) }
            .sorted { $0.1.bytes.lexicographicallyPrecedes($1.1.bytes) }
        let ids = ordered.map(\.1)
        guard Set(ids).count == ids.count else { throw CanonicalEncodingError.noncanonicalSet }
        switch kind {
        case .equal: state = .equal(inputs: ids, result: result)
        case .merged(let base, let id):
            let baseID = try base.expandedID(earlierOperations: earlierOperations)
            guard ids.count == 2, !ids.contains(baseID) else { throw CanonicalEncodingError.invalidReference }
            state = .merged(inputs: ids, base: baseID, result: result, id: id)
        }
        self.kind = kind; inputReferences = ordered.map(\.0); self.result = result
        guard encodedByteCount <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
    }

    public var encodedByteCount: UInt64 {
        let inputs = inputReferences.reduce(UInt64(0)) { $0 + $1.encodedByteCount }
        switch kind {
        case .equal: return 1 + 4 + inputs + 32
        case .merged(let base, _): return 1 + 4 + inputs + 2 + base.encodedByteCount + 32 + 32
        }
    }

    public func encodedV1(dependencies: DependencyLocatorTable,
                          earlierOperations: [IdentifiedOperation]) throws -> [UInt8] {
        try checkLocalBindings(earlierOperations)
        var bytes: [UInt8] = [kind == .equal ? 3 : 4]
        bytes += bigEndianBytes(UInt32(inputReferences.count))
        for ref in inputReferences { bytes += try ref.encoded(dependencies: dependencies) }
        if case .merged(let base, _) = kind {
            bytes += bigEndianBytes(UInt16(1))
            bytes += try base.encoded(dependencies: dependencies)
        }
        bytes += result.bytes
        if case .merged(_, let id) = kind { bytes += id.bytes }
        return bytes
    }

    public static func decodeV1(_ bytes: [UInt8], dependencies: DependencyLocatorTable,
                                earlierOperations: [IdentifiedOperation]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        var cursor = ByteCursor(bytes: bytes)
        let record = try decode(&cursor, dependencies: dependencies, earlierOperations: earlierOperations)
        try cursor.requireEnd()
        return record
    }

    static func decode(_ cursor: inout ByteCursor, dependencies: DependencyLocatorTable,
                       earlierOperations: [IdentifiedOperation], tag suppliedTag: UInt8? = nil) throws -> Self {
        let tag = try suppliedTag ?? cursor.byte()
        guard tag == 3 || tag == 4 else { throw CanonicalEncodingError.invalidDiscriminant }
        let count = try cursor.count(minimumElementBytes: 5)
        guard count >= 2, tag == 3 || count == 2 else { throw CanonicalEncodingError.invalidReference }
        var refs: [OperationReference] = []
        for _ in 0..<count { refs.append(try OperationReference.decode(&cursor, dependencies: dependencies)) }
        let base: OperationReference?
        if tag == 4 {
            guard try cursor.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
            base = try OperationReference.decode(&cursor, dependencies: dependencies)
        } else { base = nil }
        let result = try NoteValueDigest(bytes: cursor.fixedBytes(32))
        let kind: Kind
        if let base { kind = try .merged(base: base, id: MergeIDV1(bytes: cursor.fixedBytes(32))) }
        else { kind = .equal }
        let record = try Self(kind: kind, inputs: refs, result: result, earlierOperations: earlierOperations)
        guard record.inputReferences == refs else { throw CanonicalEncodingError.noncanonicalSet }
        return record
    }

    private func checkLocalBindings(_ earlier: [IdentifiedOperation]) throws {
        let rebound = try Self(kind: kind, inputs: inputReferences, result: result, earlierOperations: earlier)
        guard rebound.state == state, rebound.inputReferences == inputReferences else {
            throw CanonicalEncodingError.invalidReference
        }
    }

    /// Resolves exact occurrences and recomputes the claimed value from the supplied note graph.
    public func reconstruct(collection: CollectionID, birth: NoteBirth,
                            history: [IdentifiedOperation], earlierOperations: [IdentifiedOperation],
                            at enclosing: SegmentLocator,
                            resolve: (SegmentLocator) async throws -> ChangesPayloadV1?) async throws -> ReconstructedDerivedStateV1 {
        try checkLocalBindings(earlierOperations)
        var refs = inputReferences
        if case .merged(let base, _) = kind { refs.append(base) }
        var loaded: [SegmentLocator: ChangesPayloadV1] = [:]
        var targets: [IdentifiedOperation] = []
        for ref in refs {
            let target: IdentifiedOperation
            switch ref {
            case .earlierLocal(let index): target = earlierOperations[Int(index.rawValue)]
            case .external(let locator, let index, let id):
                guard locator != enclosing else { throw CanonicalEncodingError.invalidReference }
                if loaded[locator] == nil {
                    guard let payload = try await resolve(locator) else { throw CanonicalEncodingError.missingDependency }
                    loaded[locator] = payload
                }
                guard let payload = loaded[locator], UInt64(index.rawValue) < UInt64(payload.operations.count) else {
                    throw CanonicalEncodingError.invalidReference
                }
                target = payload.operations[Int(index.rawValue)].operation
                guard target.id == id else { throw CanonicalEncodingError.identityMismatch }
            }
            targets.append(target)
        }
        return try reconstructResolved(collection: collection, birth: birth, history: history, targets: targets)
    }

    /// Reconstructs a standalone claim using exact external occurrences and its complete note ancestry.
    public func reconstructStandalone(collection: CollectionID, birth: NoteBirth,
        history: [IdentifiedOperation],
        resolve: (StoredOperationReferenceV1) throws -> IdentifiedOperation?) throws -> ReconstructedDerivedStateV1 {
        try checkLocalBindings([])
        var targets: [IdentifiedOperation] = []
        for ref in references {
            guard case .external(let locator, let index, let id) = ref else { throw CanonicalEncodingError.invalidReference }
            guard let target = try resolve(.init(locator: locator, index: index, id: id)) else {
                throw CanonicalEncodingError.missingDependency
            }
            guard target.id == id else { throw CanonicalEncodingError.identityMismatch }
            targets.append(target)
        }
        return try reconstructResolved(collection: collection, birth: birth, history: history, targets: targets)
    }

    private func reconstructResolved(collection: CollectionID, birth: NoteBirth, history: [IdentifiedOperation],
                                     targets: [IdentifiedOperation]) throws -> ReconstructedDerivedStateV1 {
        var byID: [OperationID: IdentifiedOperation] = [:]
        for operation in history {
            guard byID.updateValue(operation, forKey: operation.id) == nil else {
                throw CanonicalEncodingError.invalidOperation
            }
        }
        for target in targets {
            guard target.effect.targetBirth == birth else { throw CanonicalEncodingError.invalidReference }
            switch target.effect {
            case .create, .importNote, .put, .recoverCopy, .adoptAutomatic: break
            default: throw CanonicalEncodingError.invalidReference
            }
            guard byID[target.id] == target else { throw CanonicalEncodingError.missingDependency }
        }
        let reduction = try NoteReductionV1.compute(collection: collection, birth: birth, operations: history)
        let value: ReducedNoteValueV1
        switch reduction.outcome {
        case .current(let current), .conflict(let current, _): value = current
        default: throw CanonicalEncodingError.invalidReference
        }
        guard value.represented == state.inputs, try value.value.digestV1() == result else {
            throw CanonicalEncodingError.identityMismatch
        }
        switch state {
        case .equal:
            guard value.merge == nil else { throw CanonicalEncodingError.identityMismatch }
        case .merged(let inputs, let base, _, let id):
            guard let merge = value.merge, merge.inputs == inputs, merge.base == base, merge.id == id else {
                throw CanonicalEncodingError.identityMismatch
            }
        }
        return ReconstructedDerivedStateV1(reference: self, collection: collection, birth: birth,
                                           reduction: reduction, value: value)
    }
}

/// A reconstructed derived value and the exact graph result used to check its claim.
public struct ReconstructedDerivedStateV1: Equatable, Sendable {
    public let reference: DerivedStateReferenceV1
    public let collection: CollectionID
    public let birth: NoteBirth
    public let reduction: NoteReductionV1
    public let value: ReducedNoteValueV1

    fileprivate init(reference: DerivedStateReferenceV1, collection: CollectionID, birth: NoteBirth,
                     reduction: NoteReductionV1, value: ReducedNoteValueV1) {
        self.reference = reference; self.collection = collection; self.birth = birth
        self.reduction = reduction; self.value = value
    }
}
