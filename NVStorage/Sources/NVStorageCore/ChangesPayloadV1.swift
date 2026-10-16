/// Complete dependency, operation and action sections with in-payload group checks.
/// Decoding returns a payload after every record and group passes validation.
public struct ChangesPayloadV1: Equatable, Sendable {
    public let dependencies: DependencyLocatorTable
    public let operations: [OperationRecordV1]
    public let actions: [ActionRecordV1]
    public let projections: [ProjectionBindingV1]
    private static let magic = Array("NVCHG1\r\n".utf8)
    private static let projectionMagic = Array("NVPRJ1\r\n".utf8)

    public init(dependencies: DependencyLocatorTable, operations: [OperationRecordV1],
                actions: [ActionRecordV1]) throws {
        try self.init(dependencies: dependencies, operations: operations, actions: actions, projections: [])
    }

    public init(dependencies: DependencyLocatorTable, operations: [OperationRecordV1],
                actions: [ActionRecordV1], projections: [ProjectionBindingV1]) throws {
        var size: UInt64 = 10 + 4 + 56 * UInt64(dependencies.entries.count) + 4 + 4
        for record in operations {
            size += 4 + record.encodedByteCount
            guard size <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        }
        for record in actions {
            size += 4 + record.encodedByteCount
            guard size <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        }
        if !projections.isEmpty { size += 12 }
        var previous: [UInt8]?
        for binding in projections {
            size += 4 + binding.encodedByteCount
            guard size <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
            let bytes = try binding.encodedV1()
            if let previous, !previous.lexicographicallyPrecedes(bytes) { throw CanonicalEncodingError.noncanonicalSet }
            previous = bytes
            for locator in binding.dependencies.entries { _ = try dependencies.index(of: locator) }
        }
        guard size <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        self.dependencies = dependencies
        self.operations = operations
        self.actions = actions
        self.projections = projections
        try checkGroups()
    }

    public func encodedV1() throws -> [UInt8] {
        // Immutable records were checked against precisely these section prefixes.
        var bytes = Self.magic + bigEndianBytes(UInt16(1)) + dependencies.encodedV1()
        bytes += bigEndianBytes(UInt32(operations.count))
        var preceding: [IdentifiedOperation] = []
        for record in operations {
            let encoded = try record.encodedV1(dependencies: dependencies, earlierOperations: preceding)
            bytes += bigEndianBytes(UInt32(encoded.count))
            bytes += encoded
            preceding.append(record.operation)
        }
        bytes += bigEndianBytes(UInt32(actions.count))
        var earlierActions: [ActionV1] = []
        for record in actions {
            let encoded = try record.encodedV1(dependencies: dependencies, operations: preceding, earlierActions: earlierActions)
            bytes += bigEndianBytes(UInt32(encoded.count))
            bytes += encoded
            earlierActions.append(record.action)
        }
        if !projections.isEmpty {
            bytes += Self.projectionMagic + bigEndianBytes(UInt32(projections.count))
            for binding in projections {
                let encoded = try binding.encodedV1()
                bytes += bigEndianBytes(UInt32(encoded.count)) + encoded
            }
        }
        return bytes
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        var cursor = ByteCursor(bytes: bytes)
        guard try cursor.fixedBytes(8) == magic, try cursor.unsigned16() == 1 else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        let table = try DependencyLocatorTable.decode(&cursor)
        let operationCount = try cursor.count(minimumElementBytes: 4)
        var records: [OperationRecordV1] = []
        var preceding: [IdentifiedOperation] = []
        for _ in 0..<operationCount {
            let record = try OperationRecordV1.decodeV1(cursor.lengthPrefixedBytes(),
                dependencies: table, earlierOperations: preceding)
            records.append(record)
            preceding.append(record.operation)
        }
        let actionCount = try cursor.count(minimumElementBytes: 4)
        var actions: [ActionRecordV1] = []
        var earlierActions: [ActionV1] = []
        for _ in 0..<actionCount {
            let record = try ActionRecordV1.decodeV1(cursor.lengthPrefixedBytes(), dependencies: table,
                operations: preceding, earlierActions: earlierActions)
            actions.append(record)
            earlierActions.append(record.action)
        }
        var projections: [ProjectionBindingV1] = []
        if cursor.remaining > 0 {
            guard bytes.suffix(cursor.remaining).starts(with: projectionMagic) else { throw CanonicalEncodingError.trailingBytes }
            _ = try cursor.fixedBytes(8)
            let count = try cursor.count(minimumElementBytes: 4)
            guard count > 0 else { throw CanonicalEncodingError.noncanonicalSet }
            for _ in 0..<count { projections.append(try ProjectionBindingV1.decodeV1(cursor.lengthPrefixedBytes(), profile: .plaintextFiles)) }
        }
        try cursor.requireEnd()
        return try Self(dependencies: table, operations: records, actions: actions, projections: projections)
    }

    /// Binds portable descriptions to the authenticated collection and provider profile.
    public static func decodeV1(_ opened: OpenedObjectV1) throws -> Self {
        guard opened.kind == .changes else { throw CanonicalEncodingError.invalidReference }
        let payload = try decodeV1(opened.payload)
        guard payload.projections.isEmpty || opened.profile == .plaintextFiles else { throw CanonicalEncodingError.wrongScope }
        guard payload.projections.allSatisfy({ $0.collection == opened.collection }) else { throw CanonicalEncodingError.wrongScope }
        return payload
    }

    private func checkGroups() throws {
        var preceding: [IdentifiedOperation] = []
        var operationIDs = Set<OperationID>()
        var births = Set<NoteBirth>()
        var expectedMembers: [ActionID: Set<OperationID>] = [:]
        for record in operations {
            guard operationIDs.insert(record.operation.id).inserted else { throw CanonicalEncodingError.invalidPayload }
            _ = try OperationRecordV1(operation: record.operation, causalReferences: record.causalReferences,
                noteReferences: record.noteReferences, earlierOperations: preceding)
            for ref in record.causalReferences + record.noteReferences {
                if case .external(let locator, _, _) = ref { _ = try dependencies.index(of: locator) }
            }
            if let action = record.operation.effect.actionID {
                expectedMembers[action, default: []].insert(record.operation.id)
            }
            switch record.operation.effect {
            case .create(_, let birth, _), .importNote(_, let birth, _):
                guard births.insert(birth).inserted else { throw CanonicalEncodingError.invalidPayload }
            default: break
            }
            preceding.append(record.operation)
        }
        var earlierActions: [ActionV1] = []
        var seen = Set<ActionID>()
        for record in actions {
            try record.checkContext(operations: preceding, earlierActions: earlierActions)
            let action = record.action
            guard seen.insert(action.id).inserted,
                  expectedMembers[action.id] == Set(action.members) else {
                throw CanonicalEncodingError.invalidAction
            }
            if let previous = record.previousOriginReference {
                try checkActionReference(previous, actions: earlierActions, record: action, origin: true)
            }
            for parent in record.scopeReferences {
                try checkActionReference(parent, actions: earlierActions, record: action, origin: false)
            }
            var memberBirths = Set<NoteBirth>()
            let members = Set(action.members)
            for index in record.memberIndices {
                let op = preceding[Int(index.rawValue)] // Constructor already checked bounds and rebinding.
                guard op.effect.actionID == action.id, let birth = op.effect.targetBirth else {
                    throw CanonicalEncodingError.invalidAction
                }
                switch (action.kind, op.effect) {
                case (.restoreBatch, .create), (.createImportBatch, .create), (.createImportBatch, .importNote),
                     (.deleteBatch, .delete), (.deleteBatch, .retireConflict),
                     (.savedEdit, .put), (.rename, .put), (.labels, .put),
                     (.savedEdit, .adoptAutomatic), (.rename, .adoptAutomatic), (.labels, .adoptAutomatic),
                     (.historicalRecovery, .put), (.historicalRecovery, .create), (.historicalRecovery, .adoptAutomatic),
                     (.conflictChoice, .put), (.conflictCopy, .recoverCopy),
                     (.undo, .create), (.undo, .put), (.undo, .delete), (.undo, .retireConflict),
                     (.redo, .create), (.redo, .put), (.redo, .delete), (.redo, .retireConflict),
                     (.nativeUndo, .put): break
                default: throw CanonicalEncodingError.invalidAction
                }
                memberBirths.insert(birth)
            }
            guard memberBirths == Set(action.affected.map(\.birth)) else { throw CanonicalEncodingError.invalidAction }
            if case .note(let birth) = action.scope, memberBirths != [birth] {
                throw CanonicalEncodingError.invalidAction
            }
            for entry in action.affected {
// Check membership of the declared after-state; causal validation
                // establishes that it is the group's final resulting state.
                switch entry.after {
                case .freshBirthAbsence: throw CanonicalEncodingError.invalidAction
                case .value(let id), .deleted(let id):
                    guard members.contains(id) else { throw CanonicalEncodingError.invalidAction }
                case .derived, .automatic: throw CanonicalEncodingError.invalidAction
                }
                if action.kind == .createImportBatch || action.kind == .restoreBatch {
                    guard entry.before == .freshBirthAbsence else { throw CanonicalEncodingError.invalidAction }
                } else {
                    switch entry.before {
                    case .freshBirthAbsence:
                        guard [.conflictCopy, .historicalRecovery, .undo, .redo].contains(action.kind) else { throw CanonicalEncodingError.invalidAction }
                    case .value(let id), .deleted(let id):
                        guard !members.contains(id) else { throw CanonicalEncodingError.invalidAction }
                    case .derived(let state):
                        guard Set(state.inputs).isDisjoint(with: members) else { throw CanonicalEncodingError.invalidAction }
                    case .automatic(let source):
                        guard !members.contains(source.revision) else { throw CanonicalEncodingError.invalidAction }
                    }
                }
            }
            for entry in record.affectedReferences {
                try checkStateReference(entry.before, birth: entry.birth, local: preceding)
                try checkStateReference(entry.after, birth: entry.birth, local: preceding)
            }
            for source in record.restorationReferences {
                if case .external(let locator, _, _) = source.deletionAction { _ = try dependencies.index(of: locator) }
                let referenceBirth: NoteBirth
                if case .automatic(let state) = source.priorState { referenceBirth = state.birth }
                else { referenceBirth = source.sourceBirth }
                try checkStateReference(.value(source.revision), birth: referenceBirth, local: preceding)
                if let state = source.priorState { try checkStateReference(state, birth: source.sourceBirth, local: preceding) }
            }
            if let details = record.detailsReference {
                for ref in details.operationReferences {
                    if case .external(let locator, _, _) = ref { _ = try dependencies.index(of: locator) }
                }
                for ref in details.actionReferences {
                    if case .external(let locator, _, _) = ref { _ = try dependencies.index(of: locator) }
                }
            }
            earlierActions.append(action)
        }
        guard seen == Set(expectedMembers.keys) else { throw CanonicalEncodingError.invalidAction }
    }

    private func checkActionReference(_ ref: ActionReference, actions: [ActionV1], record: ActionV1,
                                      origin: Bool) throws {
        switch ref {
        case .external(let locator, _, _): _ = try dependencies.index(of: locator)
        case .earlierLocal(let index):
            let target = actions[Int(index.rawValue)] // Context expansion already checked this index.
            guard origin ? target.origin == record.origin : target.scope == record.scope else {
                throw CanonicalEncodingError.invalidAction
            }
        }
    }

    private func checkStateReference(_ state: ActionStateReference, birth: NoteBirth,
                                     local: [IdentifiedOperation]) throws {
        let ref: OperationReference
        switch state {
        case .freshBirthAbsence: return
        case .value(let r), .deleted(let r): ref = r
        case .derived(let state):
            for ref in state.references { try checkStateReference(.value(ref), birth: birth, local: local) }
            return
        case .automatic(let source):
            try checkStateReference(.value(source.revision), birth: source.birth, local: local); return
        }
        switch ref {
        case .external(let locator, _, _): _ = try dependencies.index(of: locator)
        case .earlierLocal(let index): try Self.checkStateTarget(state, birth: birth, target: local[Int(index.rawValue)])
        }
    }

    private static func checkStateTarget(_ state: ActionStateReference, birth: NoteBirth,
                                         target: IdentifiedOperation) throws {
        guard target.effect.targetBirth == birth else { throw CanonicalEncodingError.invalidAction }
        switch (state, target.effect) {
        case (.value, .create), (.value, .importNote), (.value, .put), (.value, .recoverCopy),
             (.value, .adoptAutomatic), (.deleted, .delete): break
        default: throw CanonicalEncodingError.invalidAction
        }
    }

    /// Checks exact locator/index identities and note-state/action claims.
    public func checkExternalReferences(at locator: SegmentLocator,
        resolve: (SegmentLocator) throws -> ChangesPayloadV1?) throws {
        var lastLoaded: (locator: SegmentLocator, payload: ChangesPayloadV1)?
        for check in try referenceChecks() {
            var payload = self
            if let target = check.locator {
                guard target != locator else { throw CanonicalEncodingError.invalidReference }
                if lastLoaded?.locator != target {
                    guard let value = try resolve(target) else { throw CanonicalEncodingError.missingDependency }
                    lastLoaded = (target, value)
                }
                payload = lastLoaded!.payload
            }
            try Self.verify(check, in: payload)
        }
        for binding in projections { _ = try binding.validateSource(enclosing: locator, resolve: resolve) }
    }

    /// Suspends between dependency reads while sharing exact-reference validation.
    package func checkExternalReferences(at locator: SegmentLocator,
        resolve: (SegmentLocator) async throws -> ChangesPayloadV1?) async throws {
        var lastLoaded: (locator: SegmentLocator, payload: ChangesPayloadV1)?
        for check in try referenceChecks() {
            var payload = self
            if let target = check.locator {
                guard target != locator else { throw CanonicalEncodingError.invalidReference }
                if lastLoaded?.locator != target {
                    guard let value = try await resolve(target) else { throw CanonicalEncodingError.missingDependency }
                    lastLoaded = (target, value)
                }
                payload = lastLoaded!.payload
            }
            try Self.verify(check, in: payload)
        }
        for binding in projections { _ = try await binding.validateSource(enclosing: locator, resolve: resolve) }
    }

    private enum ReferenceCheck {
        case operation(OperationReference)
        case state(OperationReference, ActionStateReference, NoteBirth)
        case origin(ActionReference, ActionOriginID)
        case scope(ActionReference, ActionScopeV1)
        case deletion(ActionReference, NoteBirth)
        case action(ActionReference)
        var locator: SegmentLocator? {
            switch self {
            case .operation(let ref), .state(let ref, _, _):
                if case .external(let locator, _, _) = ref { return locator }
            case .origin(let ref, _), .scope(let ref, _), .deletion(let ref, _), .action(let ref):
                if case .external(let locator, _, _) = ref { return locator }
            }
            return nil
        }
    }

    /// Preserves encoded reference order and bounds working state by the input group.
    private func referenceChecks() throws -> [ReferenceCheck] {
        var checks: [ReferenceCheck] = []
        for record in operations {
            checks += record.causalReferences.map { .operation($0) }
            for ref in record.noteReferences {
                guard let birth = record.operation.effect.targetBirth else { throw CanonicalEncodingError.invalidOperation }
                checks.append(.state(ref, .value(ref), birth))
            }
        }
        for record in actions {
            if let ref = record.previousOriginReference { checks.append(.origin(ref, record.action.origin)) }
            checks += record.scopeReferences.map { .scope($0, record.action.scope) }
            for source in record.restorationReferences {
                checks.append(.deletion(source.deletionAction, source.sourceBirth))
                if case .automatic(let state) = source.priorState {
                    checks.append(.state(source.revision, .value(source.revision), state.birth))
                } else { checks.append(.state(source.revision, .value(source.revision), source.sourceBirth)) }
                if case .derived(let state) = source.priorState {
                    checks += state.references.map { .state($0, .value($0), source.sourceBirth) }
                }
            }
            for entry in record.affectedReferences {
                for state in [entry.before, entry.after] {
                    switch state {
                    case .freshBirthAbsence: break
                    case .value(let ref), .deleted(let ref): checks.append(.state(ref, state, entry.birth))
                    case .derived(let derived):
                        checks += derived.references.map { .state($0, .value($0), entry.birth) }
                    case .automatic(let source): checks.append(.state(source.revision, .value(source.revision), source.birth))
                    }
                }
            }
            if let details = record.detailsReference {
                checks += details.operationReferences.map { .operation($0) }
                checks += details.actionReferences.map { .action($0) }
            }
        }
        return checks
    }

    private static func verify(_ check: ReferenceCheck, in payload: ChangesPayloadV1) throws {
        func operation(_ ref: OperationReference) throws -> IdentifiedOperation {
            switch ref {
            case .earlierLocal(let index): return payload.operations[Int(index.rawValue)].operation
            case .external(_, let index, let id):
                guard UInt64(index.rawValue) < UInt64(payload.operations.count) else { throw CanonicalEncodingError.invalidReference }
                let found = payload.operations[Int(index.rawValue)].operation
                guard found.id == id else { throw CanonicalEncodingError.identityMismatch }
                return found
            }
        }
        func action(_ ref: ActionReference) throws -> ActionV1 {
            switch ref {
            case .earlierLocal(let index): return payload.actions[Int(index.rawValue)].action
            case .external(_, let index, let id):
                guard UInt64(index.rawValue) < UInt64(payload.actions.count) else { throw CanonicalEncodingError.invalidReference }
                let found = payload.actions[Int(index.rawValue)].action
                guard found.id == id else { throw CanonicalEncodingError.identityMismatch }
                return found
            }
        }
        switch check {
        case .operation(let ref): _ = try operation(ref)
        case .state(let ref, let state, let birth): try checkStateTarget(state, birth: birth, target: operation(ref))
        case .origin(let ref, let origin):
            guard try action(ref).origin == origin else { throw CanonicalEncodingError.invalidAction }
        case .scope(let ref, let scope):
            guard try action(ref).scope == scope else { throw CanonicalEncodingError.invalidAction }
        case .deletion(let ref, let birth):
            guard let entry = try action(ref).affected.first(where: { $0.birth == birth }),
                  case .deleted = entry.after else { throw CanonicalEncodingError.invalidAction }
        case .action(let ref): _ = try action(ref)
        }
    }
}
