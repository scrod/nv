extension ProjectionBindingV1 {
    /// Resolves exact occurrences and the note ancestry needed by a portable description.
    package func validateSource(enclosing: SegmentLocator,
                                resolve: (SegmentLocator) throws -> ChangesPayloadV1?) throws -> PlaintextNoteValue {
        var traversal = ProjectionSourceTraversal(binding: self, enclosing: enclosing)
        while let locator = try traversal.next() {
            guard let payload = try resolve(locator) else { throw CanonicalEncodingError.missingDependency }
            traversal.loaded[locator] = payload
        }
        return try traversal.value()
    }

    /// Shares source checks while allowing the database owner to yield between reads.
    package func validateSource(enclosing: SegmentLocator,
                                resolve: (SegmentLocator) async throws -> ChangesPayloadV1?) async throws -> PlaintextNoteValue {
        var traversal = ProjectionSourceTraversal(binding: self, enclosing: enclosing)
        while let locator = try traversal.next() {
            try Task.checkCancellation()
            guard let payload = try await resolve(locator) else { throw CanonicalEncodingError.missingDependency }
            traversal.loaded[locator] = payload
        }
        return try traversal.value()
    }
}

/// One traversal owns its decoded envelopes and visits each exact occurrence once.
private struct ProjectionSourceTraversal {
    let binding: ProjectionBindingV1
    let enclosing: SegmentLocator
    let sourceBirth: NoteBirth
    var loaded: [SegmentLocator: ChangesPayloadV1] = [:]
    private var pending: [StoredOperationReferenceV1]
    private var exact: [StoredOperationReferenceV1: IdentifiedOperation] = [:]
    private var history: [OperationID: IdentifiedOperation] = [:]

    init(binding: ProjectionBindingV1, enclosing: SegmentLocator) {
        self.binding = binding; self.enclosing = enclosing; pending = binding.occurrences
        if case .automatic(let source) = binding.state { sourceBirth = source.birth }
        else { sourceBirth = binding.birth }
    }

    mutating func next() throws -> SegmentLocator? {
        while let ref = pending.last {
            guard ref.locator != enclosing else { throw CanonicalEncodingError.invalidReference }
            if exact[ref] != nil { pending.removeLast(); continue }
            guard let payload = loaded[ref.locator] else { return ref.locator }
            guard Int(ref.index.rawValue) < payload.operations.count else { throw CanonicalEncodingError.invalidReference }
            let record = payload.operations[Int(ref.index.rawValue)], operation = record.operation
            guard operation.id == ref.id, operation.effect.targetBirth == sourceBirth,
                  operation.effect.noteValue != nil else { throw CanonicalEncodingError.invalidReference }
            if let old = history[operation.id], old != operation { throw CanonicalEncodingError.identityMismatch }
            pending.removeLast(); exact[ref] = operation; history[operation.id] = operation
            if case .derived = binding.state {
                for predecessor in record.noteReferences {
                    switch predecessor {
                    case .external(let locator, let index, let id): pending.append(.init(locator: locator, index: index, id: id))
                    case .earlierLocal(let index):
                        guard index.rawValue < ref.index.rawValue else { throw CanonicalEncodingError.invalidReference }
                        pending.append(.init(locator: ref.locator, index: index, id: payload.operations[Int(index.rawValue)].operation.id))
                    }
                }
            }
        }
        return nil
    }

    func value() throws -> PlaintextNoteValue {
        if case .derived(let source) = binding.state {
            return try source.reconstructStandalone(collection: binding.collection, birth: binding.birth,
                history: Array(history.values)) { exact[$0] }.value.value
        }
        return try binding.reconstructedValue(operations: history)
    }
}
