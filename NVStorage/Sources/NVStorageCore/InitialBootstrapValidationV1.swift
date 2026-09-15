/// Failures specific to validating a complete *initial import*. Ordinary envelope
/// and record failures retain their CanonicalEncodingError classification.
public enum InitialBootstrapValidationError: Error, Equatable, Sendable {
    case missingObject(SegmentLocator)
    case cyclicDependencies
    case conflictingClaim
    case invalidCommitment
    case invalidCausalHistory
    case invalidActionHistory
    case invalidSnapshot
/// Later-history operations require the general history validator and reducer.
    case requiresGeneralHistoryValidation
}

/// All maximal actions for one scope in a validated initial snapshot.
/// The snapshot and completion bind these IDs to the history used to derive them.
public struct InitialImportScopeFrontierV1: Sendable {
    public let collection: CollectionID
    public let snapshot: SegmentLocator
    public let completion: OperationID
    public let scope: ActionScopeV1
    public let actionIDs: Set<ActionID>

    fileprivate init(collection: CollectionID, snapshot: SegmentLocator, completion: OperationID,
                     scope: ActionScopeV1, actionIDs: Set<ActionID>) {
        self.collection = collection; self.snapshot = snapshot; self.completion = completion
        self.scope = scope; self.actionIDs = actionIDs
    }
}

/// Validated initial note values, action history and their exact object closure.
/// Durable acceptance additionally requires a store-owned commit of this evidence.
public struct InitialBootstrapValidationV1: Sendable {
    public let collection: CollectionID
    public let descriptor: BootstrapDescriptorV1
    public let snapshot: SegmentLocator
    public let importID: ImportID
    public let completion: OperationID
    public let rows: [InitialSnapshotRowV1]
    public let actions: [ActionV1]
    public let scopeFrontiers: [ActionScopeV1: InitialImportScopeFrontierV1]
    public let requiredObjects: Set<SegmentLocator>

    // Restrict issuance to the validator that establishes these facts.
    private init(collection: CollectionID, descriptor: BootstrapDescriptorV1, snapshot: SegmentLocator,
                 importID: ImportID, completion: OperationID, rows: [InitialSnapshotRowV1],
                 actions: [ActionV1], scopeFrontiers: [ActionScopeV1: InitialImportScopeFrontierV1],
                 requiredObjects: Set<SegmentLocator>) {
        self.collection = collection; self.descriptor = descriptor; self.snapshot = snapshot
        self.importID = importID; self.completion = completion; self.rows = rows
        self.actions = actions; self.scopeFrontiers = scopeFrontiers; self.requiredObjects = requiredObjects
    }

    /// Validates the complete initial import through exact immutable locators.
    /// Run this synchronous, cancellation-aware traversal on a worker. The caller
    /// supplies its selected collection and successfully unlocked protection profile.
    public static func validate(descriptor: BootstrapDescriptorV1,
                                expectedCollection: CollectionID,
                                protection: ObjectProtectionV1,
                                snapshot: SegmentLocator,
                                checkCancellation: () throws -> Void = {},
                                read: (SegmentLocator) throws -> [UInt8]?) throws -> Self {
        guard descriptor.collection == expectedCollection,
              (descriptor.keyID?.bytes ?? [UInt8](repeating: 0, count: 16)) == protection.keyIDBytes else {
            throw CanonicalEncodingError.wrongScope
        }
        var required: Set<SegmentLocator> = []
        func open(_ locator: SegmentLocator, kind: ProviderObjectKind) throws -> OpenedObjectV1 {
            try checkCancellation()
            guard let bytes = try read(locator) else {
                throw InitialBootstrapValidationError.missingObject(locator)
            }
            let result = try ObjectEnvelopeV1.open(bytes, collection: expectedCollection,
                protection: protection, expectedLocator: locator)
            guard result.kind == kind else { throw CanonicalEncodingError.invalidReference }
            required.insert(locator)
            return result
        }
        let root = try InitialSnapshotRootV1.decodeV1(open(snapshot, kind: .snapshotRoot).payload)
        var rows: [InitialSnapshotRowV1] = []
        var pending = root.dependencies.entries + [descriptor.genesis]
        for pageRef in root.pages {
            let page = try InitialSnapshotPageV1.decodeV1(open(pageRef.locator, kind: .snapshotPage).payload)
            guard page.importID == root.importID, page.index == pageRef.index,
                  UInt64(page.rows.count) == UInt64(pageRef.rowCount) else {
                throw InitialBootstrapValidationError.invalidSnapshot
            }
            if let last = rows.last, let first = page.rows.first,
               !last.birth.bytes.lexicographicallyPrecedes(first.birth.bytes) {
                throw InitialBootstrapValidationError.invalidSnapshot
            }
            rows += page.rows
            pending += page.dependencies.entries
        }

// Traverse exact dependency locators in postorder. An explicit stack supports
        // deep histories while preserving dependency-first validation.
        var payloads: [SegmentLocator: ChangesPayloadV1] = [:]
        var active: Set<SegmentLocator> = []
        var order: [SegmentLocator] = []
        var stack = pending.map { (locator: $0, leaving: false) }
        while let step = stack.popLast() {
            try checkCancellation()
            if step.leaving {
                active.remove(step.locator)
                order.append(step.locator)
                continue
            }
            guard !active.contains(step.locator) else {
                throw InitialBootstrapValidationError.cyclicDependencies
            }
            if payloads[step.locator] != nil { continue }
            let payload = try ChangesPayloadV1.decodeV1(open(step.locator, kind: .changes).payload)
            payloads[step.locator] = payload
            active.insert(step.locator)
            stack.append((step.locator, true))
            stack += payload.dependencies.entries.map { ($0, false) }
        }
        for locator in order {
            try checkCancellation()
            try payloads[locator]!.checkExternalReferences(at: locator) { payloads[$0] }
        }

// Compare expanded claims to coalesce repackaged operations/actions and reject
        // conflicting metadata for an allocated action ID. Every occurrence has
        // already passed exact-reference checks.
        var operations: [OperationID: IdentifiedOperation] = [:]
        var actions: [ActionID: ActionV1] = [:]
        var operationOrder: [OperationID] = []
        var actionOrder: [ActionID] = []
        for locator in order {
            for record in payloads[locator]!.operations {
                try checkCancellation()
                let op = record.operation
                if let old = operations[op.id] {
                    guard old == op else { throw InitialBootstrapValidationError.conflictingClaim }
                } else { operations[op.id] = op; operationOrder.append(op.id) }
            }
            for record in payloads[locator]!.actions {
                let action = record.action
                if let old = actions[action.id] {
                    guard old == action else { throw InitialBootstrapValidationError.conflictingClaim }
                } else { actions[action.id] = action; actionOrder.append(action.id) }
            }
        }
        func exactOperation(_ ref: OperationReference) throws -> IdentifiedOperation {
            guard case .external(let locator, let index, let id) = ref,
                  let payload = payloads[locator], UInt64(index.rawValue) < UInt64(payload.operations.count) else {
                throw CanonicalEncodingError.invalidReference
            }
            let op = payload.operations[Int(index.rawValue)].operation
            guard op.id == id else { throw CanonicalEncodingError.identityMismatch }
            return op
        }
        let completion = try exactOperation(root.completion)
        let genesisRecords = operations.values.filter { if case .genesis = $0.effect { true } else { false } }
        guard genesisRecords.count == 1, let genesis = genesisRecords.first,
              payloads[descriptor.genesis]!.operations.contains(where: { $0.operation.id == genesis.id }),
              case .genesis(let importID, let profile, let count, let digest) = genesis.effect,
              case .importComplete(let completeImport, let completeCount, let completeDigest) = completion.effect,
              importID == completeImport, count == completeCount, digest == completeDigest,
              root.importID == importID, root.initialCount == count, root.digest == digest else {
            throw InitialBootstrapValidationError.invalidCommitment
        }
        guard profile == (descriptor.keyID == nil ? .plaintextFiles : .encryptedSegments) else {
            throw CanonicalEncodingError.wrongScope
        }
// Require the completion operation as the sole initial frontier maximum,
        // covering all imports; reject additional frontier entries.
        for ref in root.frontier { _ = try exactOperation(ref) }
        guard root.frontier.count == 1 else { throw InitialBootstrapValidationError.invalidSnapshot }

        var imports: [NoteBirth: IdentifiedOperation] = [:]
        var seen: Set<OperationID> = []
        for id in operationOrder {
            try checkCancellation()
            let op = operations[id]!
            guard Set(op.causalParents.ids).isSubset(of: seen) else {
                throw InitialBootstrapValidationError.invalidCausalHistory
            }
            switch op.effect {
            case .genesis: break
            case .importComplete:
                guard id == completion.id else { throw InitialBootstrapValidationError.invalidCommitment }
            case .importNote(_, let birth, _):
                guard imports.updateValue(op, forKey: birth) == nil else {
                    throw InitialBootstrapValidationError.invalidCommitment
                }
            default: throw InitialBootstrapValidationError.requiresGeneralHistoryValidation
            }
            seen.insert(id)
        }
        // Retain one traversal's visited IDs at a time to bound working memory.
        func ancestors(_ starts: [OperationID]) throws -> Set<OperationID> {
            var visited: Set<OperationID> = [], work = starts
            while let id = work.popLast() {
                try checkCancellation()
                guard visited.insert(id).inserted else { continue }
                guard let op = operations[id] else { throw CanonicalEncodingError.missingDependency }
                work += op.causalParents.ids
            }
            return visited
        }
        let represented = try ancestors([completion.id])
        guard represented == Set(operations.keys), UInt64(imports.count) == count else {
            throw InitialBootstrapValidationError.invalidCommitment
        }
        var hasher = InitialValuesHasherV1(expectedCount: count)
        for birth in imports.keys.sorted(by: { $0.bytes.lexicographicallyPrecedes($1.bytes) }) {
            guard case .importNote(_, _, let value) = imports[birth]!.effect else {
                throw InitialBootstrapValidationError.invalidCommitment
            }
            try checkCancellation()
            try hasher.append(birth: birth, value: value)
        }
        guard try hasher.finish() == digest, UInt64(rows.count) == count else {
            throw InitialBootstrapValidationError.invalidCommitment
        }
        for row in rows {
            try checkCancellation()
            let op = try exactOperation(row.importReference)
            guard op == imports[row.birth], case .importNote(_, _, let value) = op.effect,
                  value == row.value else { throw InitialBootstrapValidationError.invalidSnapshot }
        }

// Each initial Import introduces one fresh value. Validate complete observed
        // action groups and every scope maximum against the writer's declared
        // causal history.
        for id in actionOrder {
            try checkCancellation()
            let action = actions[id]!
            guard action.kind == .createImportBatch else {
                throw InitialBootstrapValidationError.requiresGeneralHistoryValidation
            }
            let members = Set(action.members)
            let basis = try ancestors(action.members).subtracting(members)
            let observed = Set(basis.compactMap { operations[$0]!.effect.actionID })
            for prior in observed {
                guard Set(actions[prior]!.members).isSubset(of: basis) else {
                    throw InitialBootstrapValidationError.invalidActionHistory
                }
            }
            var maxima = Set(observed.filter { actions[$0]!.scope == action.scope })
            for prior in Array(maxima) { maxima.subtract(actions[prior]!.scopeParents) }
            guard Set(action.scopeParents) == maxima else {
                throw InitialBootstrapValidationError.invalidActionHistory
            }
            if let previous = action.previousOriginAction {
                guard observed.contains(previous) else { throw InitialBootstrapValidationError.invalidActionHistory }
            }
            // Group decoding checked local/external state type/birth and member
            // ownership. Bind each after-state to the unique imported birth, too.
            for entry in action.affected {
                guard entry.before == .freshBirthAbsence, let op = imports[entry.birth],
                      entry.after == .value(op.id), members.contains(op.id) else {
                    throw InitialBootstrapValidationError.invalidActionHistory
                }
            }
        }
        var scopes: [ActionScopeV1: Set<ActionID>] = [:]
        for action in actions.values { scopes[action.scope, default: []].insert(action.id) }
        for action in actions.values { scopes[action.scope, default: []].subtract(action.scopeParents) }
        let frontiers = Dictionary(uniqueKeysWithValues: scopes.map { scope, ids in
            (scope, InitialImportScopeFrontierV1(collection: expectedCollection, snapshot: snapshot,
                completion: completion.id, scope: scope, actionIDs: ids))
        })
        return Self(collection: expectedCollection, descriptor: descriptor, snapshot: snapshot,
            importID: importID, completion: completion.id,
            rows: rows, actions: actions.values.sorted { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) },
            scopeFrontiers: frontiers, requiredObjects: required)
    }
}
