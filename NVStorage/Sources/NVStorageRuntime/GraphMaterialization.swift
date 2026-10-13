import Foundation
import NVStorageCore

/// Immutable accepted records and occurrences read at one bounded history prefix.
struct RetainedGraph: Sendable {
    let operations: [OperationID: IdentifiedOperation]
    let actions: [ActionID: ActionV1]
    let operationReferences: [OperationID: StoredOperationReferenceV1]
    let actionReferences: [ActionID: StoredActionReferenceV1]
    private init(operations: [OperationID: IdentifiedOperation], actions: [ActionID: ActionV1],
                 operationReferences: [OperationID: StoredOperationReferenceV1], actionReferences: [ActionID: StoredActionReferenceV1]) {
        self.operations = operations; self.actions = actions
        self.operationReferences = operationReferences; self.actionReferences = actionReferences
    }

    /// Issues a complete prefix after its records, occurrence addresses and group links agree.
    fileprivate static func checked(operations: [OperationID: IdentifiedOperation], actions: [ActionID: ActionV1],
                                    operationReferences: [OperationID: StoredOperationReferenceV1], actionReferences: [ActionID: StoredActionReferenceV1]) throws -> Self {
        guard Set(operations.keys) == Set(operationReferences.keys), Set(actions.keys) == Set(actionReferences.keys) else {
            throw StorageError.integrity
        }
        guard operations.values.filter({ if case .genesis = $0.effect { true } else { false } }).count == 1,
              operations.values.filter({ if case .importComplete = $0.effect { true } else { false } }).count == 1 else { throw StorageError.integrity }
        for (id, operation) in operations {
            try Task.checkCancellation()
            guard operation.id == id, operationReferences[id]?.id == id,
                  operation.causalParents.ids.allSatisfy({ operations[$0] != nil }),
                  operation.notePredecessors.ids.allSatisfy({ operations[$0]?.effect.targetBirth == operation.effect.targetBirth }),
                  operation.effect.actionID.map({ actions[$0]?.members.contains(id) == true }) ?? true else { throw StorageError.integrity }
        }
        for (id, action) in actions {
            try Task.checkCancellation()
            guard action.id == id, actionReferences[id]?.id == id,
                  action.members.allSatisfy({ operations[$0]?.effect.actionID == id }),
                  action.scopeParents.allSatisfy({ actions[$0]?.scope == action.scope }),
                  action.previousOriginAction.map({ actions[$0]?.origin == action.origin }) ?? true else { throw StorageError.integrity }
        }
        return Self(operations: operations, actions: actions, operationReferences: operationReferences, actionReferences: actionReferences)
    }

    /// Derives a complete causal cut, preserving bootstrap coverage and whole action groups.
    func causalCut(frontier: Set<OperationID>) async throws -> Self {
        var seen: Set<OperationID> = [], pending = Array(frontier)
        while let id = pending.popLast() {
            try Task.checkCancellation()
            if !seen.insert(id).inserted { continue }
            guard let op = operations[id] else { throw GeneralSnapshotError.invalidState }
            pending += op.causalParents.ids
            if seen.count % 64 == 0 { await Task.yield() }
        }
        let cutOperations = operations.filter { seen.contains($0.key) }
        let actionIDs = Set(cutOperations.values.compactMap { $0.effect.actionID })
        let cutActions = actions.filter { actionIDs.contains($0.key) }
        guard cutActions.count == actionIDs.count else { throw GeneralSnapshotError.invalidState }
        for op in operations.values {
            switch op.effect {
            case .genesis, .importNote, .importComplete:
                guard seen.contains(op.id) else { throw GeneralSnapshotError.invalidState }
            default: break
            }
        }
        for op in cutOperations.values {
            guard op.notePredecessors.ids.allSatisfy(seen.contains) else { throw GeneralSnapshotError.invalidState }
        }
        for action in cutActions.values {
            guard action.members.allSatisfy(seen.contains), action.scopeParents.allSatisfy(actionIDs.contains),
                  action.previousOriginAction.map(actionIDs.contains) ?? true else { throw GeneralSnapshotError.invalidState }
        }
        return Self(operations: cutOperations, actions: cutActions,
                    operationReferences: operationReferences.filter { seen.contains($0.key) },
                    actionReferences: actionReferences.filter { actionIDs.contains($0.key) })
    }
}

private struct CheckedGraphRows: Sendable {
    let start: [[SQLValue]]
    let target: Int64
    let rows: EncodedCurrentRows
    let context: AuthoringContextV1
    private let connection: UUID
    private let store: LocalStoreID
    private let descriptor: [UInt8]
    private let bootstrap: SegmentLocator
    private let purpose: CatchUpPurpose
    private init(start: [[SQLValue]], target: Int64, rows: EncodedCurrentRows, context: AuthoringContextV1,
                 connection: UUID, selection: LocalStoreSelection, bootstrap: SegmentLocator, purpose: CatchUpPurpose) {
        self.start = start; self.target = target; self.rows = rows; self.context = context
        self.connection = connection; store = selection.store; descriptor = selection.descriptor.descriptorID
        self.bootstrap = bootstrap; self.purpose = purpose
    }
    fileprivate static func prepare(graph: RetainedGraph, start: [[SQLValue]], target: Int64,
        connection: UUID, selection: LocalStoreSelection, bootstrap: SegmentLocator, purpose: CatchUpPurpose,
        dictionary: CurrentRowDictionaryV1?) throws -> Self {
        let cells = try graph.currentCells(collection: selection.descriptor.collection)
        let maxima = Set(graph.operations.keys).subtracting(graph.operations.values.flatMap { $0.causalParents.ids })
        let context = try AuthoringContextV1(operations: maxima.map {
            guard let ref = graph.operationReferences[$0] else { throw StorageError.integrity }; return ref
        }, collectionActions: graph.scopeMaxima(.collection).map {
            guard let ref = graph.actionReferences[$0] else { throw StorageError.integrity }; return ref
        })
        return try Self(start: start, target: target, rows: EncodedCurrentRows(cells: cells, dictionary: dictionary), context: context, connection: connection,
                    selection: selection, bootstrap: bootstrap, purpose: purpose)
    }
    func install(database db: Database, selection: LocalStoreSelection) throws {
        guard connection == db.incarnation, store == selection.store, descriptor == selection.descriptor.descriptorID else { throw StorageError.wrongContext }
        try db.transaction {
            try db.validateHeader(store: store, descriptor: selection.descriptor)
            let accepted = try db.acceptedThrough()
            guard try db.snapshotBootstrap() == bootstrap,
                  try db.rows("SELECT through_seq,epoch,reducer_version,authoring_context FROM view_meta WHERE singleton=1") == start,
                  purpose == .opening ? accepted == target : accepted >= target else { throw StorageError.staleCapture }
            try db.run("DELETE FROM current_notes")
            try rows.install(database: db)
            if purpose == .opening {
                try db.run("UPDATE view_meta SET through_seq=?,authoring_context=?,epoch=? WHERE singleton=1", [.integer(target), .blob(context.encodedV1()), .blob(uuidBytes())])
            } else {
                try db.run("UPDATE view_meta SET through_seq=?,authoring_context=? WHERE singleton=1", [.integer(target), .blob(context.encodedV1())])
            }
        }
    }
}

/// Selects the stored representatives or every accepted Changes occurrence for a snapshot audit.
enum HistoryReadScope: Sendable { case representatives, allOccurrences }

/// Complete graph and occurrence coverage issued by one immutable-prefix traversal.
struct CheckedHistoryTraversal: Sendable {
    let graph: RetainedGraph
    let through: Int64
    private let scope: HistoryReadScope
    private let connection: UUID
    private let store: LocalStoreID
    private init(graph: RetainedGraph, through: Int64, scope: HistoryReadScope, connection: UUID, store: LocalStoreID) {
        self.graph = graph; self.through = through; self.scope = scope; self.connection = connection; self.store = store
    }
    /// Checks an exact disclosed occurrence using the traversal's fully audited immutable indexes.
    func checkReferences(locator: SegmentLocator, operations: [StoredOperationReferenceV1], actions: [StoredActionReferenceV1],
                         database db: Database, selection: LocalStoreSelection) throws {
        guard scope == .allOccurrences, connection == db.incarnation, store == selection.store else { throw StorageError.wrongContext }
        try db.validateHeader(store: store, descriptor: selection.descriptor)
        let rows = try db.rows("SELECT a.seq,o.kind,o.writer_epoch,o.sequence FROM accepted_objects a LEFT JOIN objects o USING(object_id) WHERE a.object_id=?", [.blob(locator.segmentID.bytes)])
        guard let row = rows.first, try row[0].number <= through else { throw GeneralSnapshotError.missingObject(locator) }
        guard row[1] == .integer(1), row[2] == .blob(locator.writerEpoch.bytes), row[3] == .blob(Array(locator.encodedV1()[16..<24])) else { throw GeneralSnapshotError.invalidState }
        for ref in operations {
            guard ref.locator == locator, graph.operations[ref.id] != nil,
                  try db.rows("SELECT operation_id FROM operation_occurrences WHERE object_id=? AND record_index=?",
                    [.blob(locator.segmentID.bytes), .integer(Int64(ref.index.rawValue))]) == [[.blob(ref.id.bytes)]] else { throw GeneralSnapshotError.invalidState }
        }
        for ref in actions {
            guard ref.locator == locator, graph.actions[ref.id] != nil,
                  try db.rows("SELECT action_id FROM action_occurrences WHERE object_id=? AND record_index=?",
                    [.blob(locator.segmentID.bytes), .integer(Int64(ref.index.rawValue))]) == [[.blob(ref.id.bytes)]] else { throw GeneralSnapshotError.invalidState }
        }
    }

    /// Reads bounded metadata turns, then opens and parses each selected envelope once on the worker.
    static func read(through: Int64, scope: HistoryReadScope, lane: DatabaseLane,
                     selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> Self {
        try await lane.verifying(.history(through)) {
            let connection = try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                guard through > 0, try db.acceptedThrough() >= through else { throw StorageError.staleCapture }
                db.countWork { $0.graphLoads += 1 }
                return db.incarnation
            }
            do {
                let opRows = try await metadata("operations", id: "operation_id", through: through, lane: lane)
                let actionRows = try await metadata("actions", id: "action_id", through: through, lane: lane)
                var operations: [OperationID: IdentifiedOperation] = [:], actions: [ActionID: ActionV1] = [:]
                var operationRefs: [OperationID: StoredOperationReferenceV1] = [:], actionRefs: [ActionID: StoredActionReferenceV1] = [:]
                let expectedOps = try Dictionary(uniqueKeysWithValues: opRows.map { try (OperationID(bytes: $0[0].bytes), $0) })
                let expectedActions = try Dictionary(uniqueKeysWithValues: actionRows.map { try (ActionID(bytes: $0[0].bytes), $0) })
                let sourceIDs = try Set(opRows.map { try $0[4].bytes } + actionRows.map { try $0[5].bytes })
                let sources: [[UInt8]]
                switch scope {
                case .representatives: sources = sourceIDs.sorted { $0.lexicographicallyPrecedes($1) }
                case .allOccurrences: sources = try await acceptedSources(through: through, lane: lane)
                }
                guard sourceIDs.isSubset(of: Set(sources)) else { throw StorageError.incomplete }
                let attempt = UUID()
                for source in sources {
                    try Task.checkCancellation()
                    let checked = try await CheckedEnvelopeRecords.read(source: source, through: through, attempt: attempt,
                        lane: lane, selection: selection, protection: protection)
                    for op in checked.operations {
                        guard expectedOps[op.id] != nil else { throw StorageError.integrity }
                        if let previous = operations[op.id], previous != op { throw StorageError.integrity }
                        operations[op.id] = op
                    }
                    for action in checked.actions {
                        guard expectedActions[action.id] != nil else { throw StorageError.integrity }
                        if let previous = actions[action.id], previous != action { throw StorageError.integrity }
                        actions[action.id] = action
                    }
                    operationRefs.merge(checked.operationReferences) { a, b in a }
                    actionRefs.merge(checked.actionReferences) { a, b in a }
                    await Task.yield()
                }
                guard Set(operations.keys) == Set(expectedOps.keys), Set(actions.keys) == Set(expectedActions.keys) else { throw StorageError.integrity }
                let ops = operations, acts = actions, refs = operationRefs, arefs = actionRefs
                let graph = try await lane.historyWork { try RetainedGraph.checked(operations: ops, actions: acts, operationReferences: refs, actionReferences: arefs) }
                return Self(graph: graph, through: through, scope: scope, connection: connection, store: selection.store)
            } catch { try await lane.failRetainedRead(error) }
        }
    }

    private static func metadata(_ table: String, id: String, through: Int64, lane: DatabaseLane) async throws -> [[SQLValue]] {
        var result: [[SQLValue]] = [], sequence: Int64 = 0, position: [UInt8] = []
        while true {
            let cursor = position, start = sequence
            let rows = try await lane.perform { try $0.rows("SELECT * FROM \(table) WHERE first_seq<=? AND (first_seq,\(id))>(?,?) ORDER BY first_seq,\(id) LIMIT 64", [.integer(through), .integer(start), .blob(cursor)]) }
            result += rows
            guard rows.count == 64 else { return result }
            sequence = try rows.last!.last!.number; position = try rows.last![0].bytes
        }
    }
    private static func acceptedSources(through: Int64, lane: DatabaseLane) async throws -> [[UInt8]] {
        var result: [[UInt8]] = [], sequence: Int64 = 0, position: [UInt8] = []
        while true {
            let cursor = position, start = sequence
            let rows = try await lane.perform { try $0.rows("SELECT a.seq,a.object_id FROM accepted_objects a LEFT JOIN objects o USING(object_id) WHERE a.seq<=? AND (a.seq,a.object_id)>(?,?) AND (o.kind=1 OR o.object_id IS NULL) ORDER BY a.seq,a.object_id LIMIT 64", [.integer(through), .integer(start), .blob(cursor)]) }
            result += try rows.map { try $0[1].bytes }
            guard rows.count == 64 else { return result }
            sequence = try rows.last![0].number; position = try rows.last![1].bytes
        }
    }

}

extension DatabaseLane {
    /// Reads indexed membership in small turns so ordinary saves retain database access.
    nonisolated func retainedGraph(through: Int64, selection: LocalStoreSelection,
                                   protection: ObjectProtectionV1) async throws -> RetainedGraph {
        try await CheckedHistoryTraversal.read(through: through, scope: .representatives,
            lane: self, selection: selection, protection: protection).graph
    }
    /// Computes a complete batch away from the connection, then installs it under its view fence.
    nonisolated func materializeGraphBatch(selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws {
        return try await self.verifyingHistory {
            let purpose = CatchUpScope.purpose
            let (start, target, connection, bootstrap, dictionary) = try await perform { db in
                let row = try db.rows("SELECT through_seq,epoch,reducer_version,authoring_context FROM view_meta WHERE singleton=1")
                guard row.count == 1, row[0][2] == .integer(1) else { throw StorageError.integrity }
                let start = try row[0][0].number
                let accepted = try db.acceptedThrough()
                guard start < accepted else { throw StorageError.staleCapture }
                return try (row, purpose == .opening ? accepted : start + 1, db.incarnation, db.snapshotBootstrap(), db.currentDictionary())
            }
            let graph = try await retainedGraph(through: target, selection: selection, protection: protection)
            let checked: CheckedGraphRows
            do { checked = try await historyWork {
                try CheckedGraphRows.prepare(graph: graph, start: start, target: target, connection: connection,
                    selection: selection, bootstrap: bootstrap, purpose: purpose, dictionary: dictionary)
            } } catch {
                return try await perform { db in try db.checkingRetainedHistory { throw error } }
            }
            let gate = try await perform { $0.work?.recoveryPrepared }
            await gate?()
            try await perform { db in try checked.install(database: db, selection: selection) }
        }
    }
}

extension RetainedGraph {
    func stateReference(_ state: ActionStateV1) throws -> ActionStateReference {
        func reference(_ id: OperationID) throws -> OperationReference {
            guard let ref = operationReferences[id] else { throw StorageError.incomplete }; return ref.reference
        }
        switch state {
        case .freshBirthAbsence: return .freshBirthAbsence
        case .value(let id): return try .value(reference(id))
        case .deleted(let id): return try .deleted(reference(id))
        case .automatic(let source): return try .automatic(.init(birth: source.birth, revision: reference(source.revision), key: source.key))
        case .derived(let derived):
            let kind: DerivedStateReferenceV1.Kind
            switch derived {
            case .equal: kind = .equal
            case .merged(_, let base, _, let id): kind = try .merged(base: reference(base), id: id)
            }
            return try .derived(.init(kind: kind, inputs: derived.inputs.map(reference), result: derived.result, earlierOperations: []))
        }
    }
    func scopeMaxima(_ scope: ActionScopeV1) -> Set<ActionID> {
        let scoped = actions.values.filter { $0.scope == scope }
        return Set(scoped.map(\.id)).subtracting(scoped.flatMap(\.scopeParents))
    }

    func currentCells(collection: CollectionID, affectedBirths: Set<NoteBirth>? = nil) throws -> [CurrentNoteCellV1] {
        let reduction = try CollectionReductionV1.compute(collection: collection, operations: Array(operations.values),
            actions: Array(actions.values), affectedBirths: affectedBirths)
        return try reduction.cells.map { current in
            let birth = current.birth
            func reference(_ id: OperationID) throws -> StoredOperationReferenceV1 {
                guard let ref = operationReferences[id] else { throw StorageError.incomplete }; return ref
            }
            let represented = try current.represented.map(reference)
            let derived: DerivedStateReferenceV1?
            if let merge = current.merge {
                derived = try .init(kind: .merged(base: reference(merge.base).reference, id: merge.id),
                    inputs: represented.map(\.reference), result: merge.result, earlierOperations: [])
            } else if represented.count > 1 {
                derived = try .init(kind: .equal, inputs: represented.map(\.reference), result: current.value.digestV1(), earlierOperations: [])
            } else { derived = nil }
            let provenance: CurrentNoteProvenanceV1
            if let automatic = current.automatic {
                guard derived == nil else { throw StorageError.integrity }
                provenance = .automatic(.init(birth: automatic.birth, revision: try reference(automatic.revision).reference, key: automatic.key))
            } else if let derived { provenance = .derived(derived) }
            else { provenance = .revision }
            let identities = Set(operations.values.compactMap { op -> DeterministicConflictIdentityV1? in
                guard op.effect.targetBirth == birth else { return nil }
                switch op.effect { case .recoverCopy(_, _, let source, _): return .recovery(source.key, slot: source.slot)
                case .adoptAutomatic(_, _, let source, _): return .automatic(source.key); default: return nil }
            })
            guard identities.count <= 1 else { throw StorageError.integrity }
            return try CurrentNoteCellV1(birth: birth, value: current.value, represented: represented,
                heads: current.heads.map(reference), provenance: provenance,
                scopeFrontier: scopeMaxima(.note(birth)).map {
                    guard let ref = actionReferences[$0] else { throw StorageError.integrity }; return ref
                }, identity: identities.first)
        }
    }
}
