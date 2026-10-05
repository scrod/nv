/// Failures specific to validating a complete initial import.
public enum InitialBootstrapValidationError: Error, Equatable, Sendable {
    case missingObject(SegmentLocator)
    case cyclicDependencies
    case conflictingClaim
    case invalidCommitment
    case invalidCausalHistory
    case invalidActionHistory
    case invalidSnapshot
    case requiresGeneralHistoryValidation
}

/// Maximal actions for one scope in the initial commitment's logical history.
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

/// Checked initial values and logical cut, paired with exact retained-object requirements.
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
    /// Operations covered by ImportComplete, independently of transport envelopes.
    public let operationIDs: Set<OperationID>
    package let changesOrder: [SegmentLocator]

    private init(facts: BootstrapFacts, collection: CollectionID, descriptor: BootstrapDescriptorV1,
                 snapshot: SegmentLocator, allowLaterHistory: Bool) throws {
        let checked = try facts.finish(descriptor: descriptor, allowLaterHistory: allowLaterHistory)
        self.collection = collection; self.descriptor = descriptor; self.snapshot = snapshot
        importID = checked.importID; completion = checked.completion; rows = facts.rows
        actions = checked.actions; operationIDs = checked.operations
        requiredObjects = facts.required; changesOrder = facts.order
        scopeFrontiers = Dictionary(uniqueKeysWithValues: checked.scopes.map { scope, ids in
            (scope, InitialImportScopeFrontierV1(collection: collection, snapshot: snapshot,
                completion: checked.completion, scope: scope, actionIDs: ids))
        })
    }

    /// Reads one envelope at a time through the in-memory fixture adapter.
    public static func validate(descriptor: BootstrapDescriptorV1, expectedCollection: CollectionID,
                                protection: ObjectProtectionV1, snapshot: SegmentLocator,
                                checkCancellation: () throws -> Void = {},
                                read: (SegmentLocator) throws -> [UInt8]?) throws -> Self {
        try checkProfile(descriptor, expectedCollection, protection)
        func open(_ locator: SegmentLocator) throws -> OpenedObjectV1 {
            try checkCancellation()
            guard let bytes = try read(locator) else { throw InitialBootstrapValidationError.missingObject(locator) }
            return try ObjectEnvelopeV1.open(bytes, collection: expectedCollection, protection: protection, expectedLocator: locator)
        }
        var facts = BootstrapFacts(snapshot: snapshot, genesis: descriptor.genesis)
        while let request = try facts.next() { try facts.consume(open(request.locator), request: request) }
        for locator in facts.order {
            let payload = try ChangesPayloadV1.decodeV1(open(locator).payload)
            try payload.checkExternalReferences(at: locator) { try ChangesPayloadV1.decodeV1(open($0).payload) }
        }
        return try Self(facts: facts, collection: expectedCollection, descriptor: descriptor,
                        snapshot: snapshot, allowLaterHistory: false)
    }

    /// Suspends between owned reads, retaining current values and compact graph metadata.
    /// The runtime validates complete incidental groups against their declared history.
    package static func validateStored(descriptor: BootstrapDescriptorV1, expectedCollection: CollectionID,
                                       protection: ObjectProtectionV1, snapshot: SegmentLocator,
                                       read: @Sendable (SegmentLocator) async throws -> [UInt8]?) async throws -> Self {
        try checkProfile(descriptor, expectedCollection, protection)
        func open(_ locator: SegmentLocator) async throws -> OpenedObjectV1 {
            try Task.checkCancellation()
            guard let bytes = try await read(locator) else { throw InitialBootstrapValidationError.missingObject(locator) }
            return try ObjectEnvelopeV1.open(bytes, collection: expectedCollection, protection: protection, expectedLocator: locator)
        }
        var facts = BootstrapFacts(snapshot: snapshot, genesis: descriptor.genesis)
        while let request = try facts.next() { try facts.consume(await open(request.locator), request: request) }
        for locator in facts.order {
            let payload = try ChangesPayloadV1.decodeV1(await open(locator).payload)
            try await payload.checkExternalReferences(at: locator) { try ChangesPayloadV1.decodeV1(await open($0).payload) }
        }
        return try Self(facts: facts, collection: expectedCollection, descriptor: descriptor,
                        snapshot: snapshot, allowLaterHistory: true)
    }
    private static func checkProfile(_ descriptor: BootstrapDescriptorV1, _ collection: CollectionID,
                                     _ protection: ObjectProtectionV1) throws {
        guard descriptor.collection == collection,
              (descriptor.keyID?.bytes ?? [UInt8](repeating: 0, count: 16)) == protection.keyIDBytes else {
            throw CanonicalEncodingError.wrongScope
        }
    }
}

/// Final rows own note values; historical bookkeeping owns digests and identities.
private struct BootstrapOperation: Equatable {
    enum Effect: Equatable {
        case genesis(ImportID, CollectionProfileV1, UInt64, InitialValuesDigest)
        case completion(ImportID, UInt64, InitialValuesDigest)
        case imported(ActionID, NoteBirth, NoteValueDigest)
        case later
    }
    let parents: [OperationID]
    let effect: Effect
    init(_ op: IdentifiedOperation) throws {
        parents = op.causalParents.ids
        switch op.effect {
        case .genesis(let id, let profile, let count, let digest): effect = .genesis(id, profile, count, digest)
        case .importComplete(let id, let count, let digest): effect = .completion(id, count, digest)
        case .importNote(let action, let birth, let value): effect = try .imported(action, birth, value.digestV1())
        default: effect = .later
        }
    }
}

/// Iterative dependency traversal shared by fixture and asynchronous store readers.
private struct BootstrapFacts {
    struct Request {
        enum Kind { case root, page(InitialSnapshotPageReferenceV1), changes, leaving }
        let locator: SegmentLocator
        let kind: Kind
    }
    let genesis: SegmentLocator
    var stack: [Request]
    var root: InitialSnapshotRootV1?
    var rows: [InitialSnapshotRowV1] = []
    var required: Set<SegmentLocator> = []
    var active: Set<SegmentLocator> = []
    var order: [SegmentLocator] = []
    var occurrences: [SegmentLocator: [OperationID]] = [:]
    var operations: [OperationID: BootstrapOperation] = [:]
    var actions: [ActionID: ActionV1] = [:]

    init(snapshot: SegmentLocator, genesis: SegmentLocator) {
        self.genesis = genesis; stack = [.init(locator: snapshot, kind: .root)]
    }
    mutating func next() throws -> Request? {
        while let request = stack.popLast() {
            switch request.kind {
            case .leaving: active.remove(request.locator); order.append(request.locator)
            case .changes:
                guard !active.contains(request.locator) else { throw InitialBootstrapValidationError.cyclicDependencies }
                if occurrences[request.locator] == nil { return request }
            default: return request
            }
        }
        return nil
    }
    mutating func consume(_ opened: OpenedObjectV1, request: Request) throws {
        required.insert(request.locator)
        switch request.kind {
        case .root:
            guard opened.kind == .snapshotRoot else { throw CanonicalEncodingError.invalidReference }
            let root = try InitialSnapshotRootV1.decodeV1(opened.payload); self.root = root
            stack += (root.dependencies.entries + [genesis]).map { .init(locator: $0, kind: .changes) }
            stack += root.pages.reversed().map { .init(locator: $0.locator, kind: .page($0)) }
        case .page(let ref):
            guard opened.kind == .snapshotPage else { throw CanonicalEncodingError.invalidReference }
            let page = try InitialSnapshotPageV1.decodeV1(opened.payload)
            guard page.importID == root?.importID, page.index == ref.index, page.rows.count == Int(ref.rowCount),
                  rows.last.map({ last in page.rows.first.map { last.birth.bytes.lexicographicallyPrecedes($0.birth.bytes) } ?? true }) ?? true else {
                throw InitialBootstrapValidationError.invalidSnapshot
            }
            rows += page.rows
            stack += page.dependencies.entries.map { .init(locator: $0, kind: .changes) }
        case .changes:
            guard opened.kind == .changes else { throw CanonicalEncodingError.invalidReference }
            let payload = try ChangesPayloadV1.decodeV1(opened.payload)
            occurrences[request.locator] = payload.operations.map(\.operation.id)
            for record in payload.operations {
                let id = record.operation.id, metadata = try BootstrapOperation(record.operation)
                if let old = operations[id] {
                    guard old == metadata else { throw InitialBootstrapValidationError.conflictingClaim }
                } else { operations[id] = metadata }
            }
            for record in payload.actions {
                if let old = actions[record.action.id], old != record.action { throw InitialBootstrapValidationError.conflictingClaim }
                actions[record.action.id] = record.action
            }
            active.insert(request.locator)
            stack.append(.init(locator: request.locator, kind: .leaving))
            stack += payload.dependencies.entries.map { .init(locator: $0, kind: .changes) }
        case .leaving: throw CanonicalEncodingError.invalidReference
        }
    }
    func exact(_ ref: OperationReference) throws -> OperationID {
        guard case .external(let loc, let index, let id) = ref,
              let ids = occurrences[loc], Int(index.rawValue) < ids.count else {
            throw CanonicalEncodingError.invalidReference
        }
        guard ids[Int(index.rawValue)] == id else { throw CanonicalEncodingError.identityMismatch }
        return id
    }
    func ancestors(_ starts: [OperationID]) throws -> Set<OperationID> {
        var seen: Set<OperationID> = [], work = starts
        while let id = work.popLast() {
            try Task.checkCancellation()
            if seen.insert(id).inserted {
                guard let op = operations[id] else { throw CanonicalEncodingError.missingDependency }
                work += op.parents
            }
        }
        return seen
    }
    func finish(descriptor: BootstrapDescriptorV1, allowLaterHistory: Bool) throws ->
        (importID: ImportID, completion: OperationID, operations: Set<OperationID>, actions: [ActionV1], scopes: [ActionScopeV1: Set<ActionID>]) {
        guard let root else { throw InitialBootstrapValidationError.invalidSnapshot }
        let completion = try exact(root.completion), represented = try ancestors([completion])
        if !allowLaterHistory, represented != Set(operations.keys) {
            if operations.filter({ !represented.contains($0.key) }).contains(where: { $0.value.effect == .later }) {
                throw InitialBootstrapValidationError.requiresGeneralHistoryValidation
            }
            throw InitialBootstrapValidationError.invalidCommitment
        }
        for ref in root.frontier { _ = try exact(ref) }
        guard root.frontier.count == 1 else { throw InitialBootstrapValidationError.invalidSnapshot }
        let genesisRecords = operations.filter { if case .genesis = $0.value.effect { true } else { false } }
        guard genesisRecords.count == 1, let first = genesisRecords.first,
              occurrences[genesis]?.contains(first.key) == true,
              case .genesis(let importID, let profile, let count, let digest) = first.value.effect,
              case .completion(let completeID, let completeCount, let completeDigest) = operations[completion]?.effect,
              importID == completeID, count == completeCount, digest == completeDigest,
              root.importID == importID, root.initialCount == count, root.digest == digest else {
            throw InitialBootstrapValidationError.invalidCommitment
        }
        guard profile == (descriptor.keyID == nil ? .plaintextFiles : .encryptedSegments) else { throw CanonicalEncodingError.wrongScope }
        var imports: [NoteBirth: (OperationID, NoteValueDigest)] = [:], initialActions: Set<ActionID> = []
        for id in represented {
            switch operations[id]!.effect {
            case .genesis: break
            case .completion: guard id == completion else { throw InitialBootstrapValidationError.invalidCommitment }
            case .imported(let action, let birth, let digest):
                guard imports.updateValue((id, digest), forKey: birth) == nil else { throw InitialBootstrapValidationError.invalidCommitment }
                initialActions.insert(action)
            case .later: throw InitialBootstrapValidationError.requiresGeneralHistoryValidation
            }
        }
        guard UInt64(imports.count) == count, UInt64(rows.count) == count else { throw InitialBootstrapValidationError.invalidCommitment }
        var hasher = InitialValuesHasherV1(expectedCount: count)
        for row in rows {
            guard let imported = imports[row.birth], try exact(row.importReference) == imported.0,
                  try row.value.digestV1() == imported.1 else { throw InitialBootstrapValidationError.invalidSnapshot }
            try hasher.append(birth: row.birth, value: row.value)
        }
        guard try hasher.finish() == digest else { throw InitialBootstrapValidationError.invalidCommitment }
        var seen: Set<OperationID> = [], ordered: [OperationID] = []
        for locator in order {
            for id in occurrences[locator]! where !seen.contains(id) {
                guard Set(operations[id]!.parents).isSubset(of: seen) else { throw InitialBootstrapValidationError.invalidCausalHistory }
                seen.insert(id); ordered.append(id)
            }
        }
        var observed: Set<ActionID> = [], checkedActions: Set<ActionID> = []
        var remaining: [ActionID: Set<OperationID>] = [:]
        var scopes: [ActionScopeV1: Set<ActionID>] = [:], frontier: Set<OperationID> = []
        for id in ordered where represented.contains(id) {
            let op = operations[id]!
            if case .imported(let actionID, _, _) = op.effect, !checkedActions.contains(actionID) {
                guard let action = actions[actionID], action.kind == .createImportBatch,
                      Set(action.members).isSubset(of: represented) else { throw InitialBootstrapValidationError.invalidActionHistory }
                var chain = frontier
                let linear = action.members.allSatisfy { member in
                    guard let metadata = operations[member], Set(metadata.parents) == chain else { return false }
                    chain = [member]; return true
                }
                let prior: Set<ActionID>, maxima: Set<ActionID>
                if linear, remaining.isEmpty { prior = observed; maxima = scopes[action.scope] ?? [] }
                else {
                    let basis = try ancestors(action.members).subtracting(action.members)
                    prior = Set(basis.compactMap { member in
                        if case .imported(let a, _, _) = operations[member]?.effect { return a }; return nil
                    })
                    for a in prior {
                        guard let priorAction = actions[a], Set(priorAction.members).isSubset(of: basis) else { throw InitialBootstrapValidationError.invalidActionHistory }
                    }
                    let scoped = prior.filter { actions[$0]?.scope == action.scope }
                    maxima = Set(scoped).subtracting(scoped.flatMap { actions[$0]!.scopeParents })
                }
                guard Set(action.scopeParents) == maxima,
                      action.previousOriginAction.map({ prior.contains($0) }) ?? true else { throw InitialBootstrapValidationError.invalidActionHistory }
                for entry in action.affected {
                    guard entry.before == .freshBirthAbsence, let imported = imports[entry.birth],
                          entry.after == .value(imported.0), action.members.contains(imported.0) else { throw InitialBootstrapValidationError.invalidActionHistory }
                }
                checkedActions.insert(actionID); remaining[actionID] = Set(action.members)
            }
            if case .imported(let actionID, _, _) = op.effect {
                remaining[actionID]?.remove(id)
                if remaining[actionID]?.isEmpty == true {
                    remaining.removeValue(forKey: actionID); observed.insert(actionID)
                    let action = actions[actionID]!
                    scopes[action.scope, default: []].insert(actionID)
                    scopes[action.scope, default: []].subtract(action.scopeParents)
                }
            }
            frontier.insert(id); frontier.subtract(op.parents)
        }
        guard observed == initialActions else { throw InitialBootstrapValidationError.invalidActionHistory }
        return (importID, completion, represented,
                observed.map { actions[$0]! }.sorted { $0.id.bytes.lexicographicallyPrecedes($1.id.bytes) }, scopes)
    }
}
