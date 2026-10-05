import Foundation
import NVStorageCore

/// Selects retained revisions of one birth or the collection's logical deletion entries.
public enum HistoryQuery: Equatable, Sendable {
    case note(NoteBirth)
    case deletions
    case recentlyDeleted
}

/// Resumes an ID-ordered listing at its captured accepted-history prefix.
public struct HistoryCursor: Sendable {
    fileprivate let session: UUID
    fileprivate let store: LocalStoreID
    fileprivate let query: HistoryQuery
    fileprivate let through: Int64
    fileprivate let after: OperationID
    fileprivate init(session: UUID, store: LocalStoreID, query: HistoryQuery, through: Int64, after: OperationID) {
        self.session = session; self.store = store; self.query = query; self.through = through; self.after = after
    }
}

/// Store-issued identity for loading a detached preview of one accepted note operation.
public struct HistoryEntry: Sendable {
    public let operation: OperationID
    public let birth: NoteBirth
    public let action: ActionID
    fileprivate let session: UUID
    fileprivate let store: LocalStoreID
    fileprivate let through: Int64
    fileprivate init(operation: OperationID, birth: NoteBirth, action: ActionID,
                     session: UUID, store: LocalStoreID, through: Int64) {
        self.operation = operation; self.birth = birth; self.action = action
        self.session = session; self.store = store; self.through = through
    }
}

/// A bounded page of metadata in stable operation-ID order. Graph edges in the
/// detached previews describe causal order and note supersession. Follow the
/// continuation even when a chunk contains only records newer than the listing.
public struct HistoryPage: Sendable {
    public let entries: [HistoryEntry]
    public let continuation: HistoryCursor?
    fileprivate init(entries: [HistoryEntry], continuation: HistoryCursor?) {
        self.entries = entries; self.continuation = continuation
    }
}

/// An exact retained value, or a logical Delete together with its recorded prior value.
public enum HistoricalNoteState: Sendable {
    case value(IdentifiedOperation)
    case deleted(operation: IdentifiedOperation, before: IdentifiedOperation)
    case deletedState(operation: IdentifiedOperation, before: ActionStateV1, value: PlaintextNoteValue)
}

/// Detached historical inputs with their complete action metadata. The host fences
/// presentation by its selected entry and view generation when this read completes.
public struct HistoryPreview: Sendable {
    public let entry: HistoryEntry
    public let action: ActionV1
    public let state: HistoricalNoteState
    fileprivate init(entry: HistoryEntry, action: ActionV1, state: HistoricalNoteState) {
        self.entry = entry; self.action = action; self.state = state
    }
}

/// Store-issued source value and exact deletion references for one fresh Restore.
public struct CapturedRestoration: Sendable {
    public let generation: CapturedNoteGeneration
    public let value: PlaintextNoteValue
    let session: UUID
    let store: LocalStoreID
    let through: Int64
    let reference: RestorationReference
    fileprivate init(generation: CapturedNoteGeneration, value: PlaintextNoteValue, session: UUID,
                     store: LocalStoreID, through: Int64, reference: RestorationReference) {
        self.generation = generation; self.value = value; self.session = session
        self.store = store; self.through = through; self.reference = reference
    }
}

/// Detached reduction of one birth at a captured accepted-history prefix.
public struct NoteReductionPreview: Sendable {
    public let birth: NoteBirth
    public let through: Int64
    public let reduction: NoteReductionV1
    fileprivate init(birth: NoteBirth, through: Int64, reduction: NoteReductionV1) {
        self.birth = birth; self.through = through; self.reduction = reduction
    }
}

extension LocalStoreSession {
    /// Computes inspectable head/base/value evidence from retained history, yielding
    /// database access between bounded metadata pages and individual envelope reads.
    public func reductionPreview(for birth: NoteBirth) async throws -> NoteReductionPreview {
        return try await lane.verifyingHistory {
            guard !closed else { throw StorageError.closed }
            let selection = selection, protection = protection, lane = lane
            let through = try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                return try db.acceptedThrough()
            }
            var after: OperationID?, operations: [IdentifiedOperation] = []
            while true {
                try Task.checkCancellation()
                let position = after
                let page = try await lane.perform { db -> [(OperationID, Int64)] in
                    try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                    var bindings: [SQLValue] = [.blob(birth.bytes)]
                    if let position { bindings.append(.blob(position.bytes)) }
                    return try db.rows("SELECT operation_id,first_seq FROM operations WHERE birth=?\(position == nil ? "" : " AND operation_id>?") ORDER BY operation_id LIMIT 64", bindings).map {
                        try (OperationID(bytes: $0[0].bytes), $0[1].number)
                    }
                }
                for (id, first) in page where first <= through {
                    try Task.checkCancellation()
                    let op = try await lane.perform { db in
                        try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                        return try db.checkingRetainedHistory {
                            guard let op = try db.operation(id, selection: selection, protection: protection),
                                  op.effect.targetBirth == birth else { throw StorageError.integrity }
                            return op
                        }
                    }
                    operations.append(op)
                }
                if page.count < 64 { break }
                after = page.last!.0
            }
            let captured = operations
            let worker = Task.detached { try NoteReductionV1.compute(collection: selection.descriptor.collection,
                                                                      birth: birth, operations: captured) }
            let calculated = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
            guard !closed else { throw StorageError.closed }
            let reduction = try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                guard try through <= db.acceptedThrough() else { throw StorageError.integrity }
                return try db.checkingRetainedHistory { try calculated.get() }
            }
            try Task.checkCancellation()
            return NoteReductionPreview(birth: birth, through: through, reduction: reduction)
        }
    }

    /// Lists accepted metadata lazily. Starting a new listing captures newer history;
    /// continuing a page keeps the original prefix while local saves proceed.
    public func history(for query: HistoryQuery, after cursor: HistoryCursor? = nil,
                        limit: Int = 64) async throws -> HistoryPage {
        guard !closed else { throw StorageError.closed }
        guard (1...128).contains(limit) else { throw StorageError.limit }
        let session = incarnation, selection = selection
        if let cursor {
            guard cursor.session == session, cursor.store == selection.store, cursor.query == query else {
                throw StorageError.wrongContext
            }
        }
        return try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            let accepted = try db.acceptedThrough(), through = cursor?.through ?? accepted
            guard through > 0, through <= accepted else { throw StorageError.integrity }
            let predicate: String
            var bindings: [SQLValue] = []
            switch query {
            case .note(let birth): predicate = "birth=? AND kind!=8"; bindings.append(.blob(birth.bytes))
            case .deletions, .recentlyDeleted: predicate = "kind=6"
            }
            let position = cursor == nil ? "" : " AND operation_id>?"
            if let cursor { bindings.append(.blob(cursor.after.bytes)) }
            bindings.append(.integer(Int64(limit + 1)))
            let rows = try db.rows("SELECT operation_id,birth,action_id,first_seq FROM operations WHERE \(predicate)\(position) ORDER BY operation_id LIMIT ?", bindings)
            // Bound inspected metadata as well as returned entries when new history
            // arrives during paging through an older accepted prefix.
            let scanned = rows.prefix(limit)
            let entries = try scanned.filter { row in
                guard try row[3].number <= through else { return false }
                if query == .recentlyDeleted {
                    return try db.rows("SELECT 1 FROM restorations r JOIN actions a ON a.action_id=r.action_id WHERE r.source_birth=? AND r.deletion_action=? AND a.first_seq<=? LIMIT 1",
                        [row[1], row[2], .integer(through)]).isEmpty
                }
                return true
            }.map { row in
                try HistoryEntry(operation: OperationID(bytes: row[0].bytes), birth: NoteBirth(bytes: row[1].bytes),
                    action: ActionID(bytes: row[2].bytes), session: session, store: selection.store, through: through)
            }
            let continuation = try rows.count > limit ? scanned.last.map {
                try HistoryCursor(session: session, store: selection.store, query: query, through: through,
                    after: OperationID(bytes: $0[0].bytes))
            } : nil
            try db.validateOwner()
            return HistoryPage(entries: entries, continuation: continuation)
        }
    }

    /// Resolves the exact accepted operation and action behind a selected entry.
    public func preview(_ entry: HistoryEntry) async throws -> HistoryPreview {
        return try await lane.verifyingHistory {
            guard !closed else { throw StorageError.closed }
            guard entry.session == incarnation, entry.store == selection.store else { throw StorageError.wrongContext }
            let selection = selection, protection = protection
            return try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                return try db.checkingRetainedHistory {
                    guard try entry.through <= db.acceptedThrough(),
                          let row = try db.rows("SELECT first_seq FROM operations WHERE operation_id=?", [.blob(entry.operation.bytes)]).first,
                          try row[0].number <= entry.through,
                          let op = try db.operation(entry.operation, selection: selection, protection: protection),
                          op.effect.targetBirth == entry.birth, op.effect.actionID == entry.action,
                          let action = try db.action(entry.action, selection: selection, protection: protection),
                          action.members.contains(op.id) else { throw StorageError.integrity }
                    let state: HistoricalNoteState
                    switch op.effect {
                    case .create, .importNote, .put, .recoverCopy, .adoptAutomatic: state = .value(op)
                    case .delete:
                        guard let affected = action.affected.first(where: { $0.birth == entry.birth }),
                              affected.after == .deleted(op.id) else { throw StorageError.integrity }
                        if case .value(let prior) = affected.before {
                            guard let before = try db.operation(prior, selection: selection, protection: protection),
                                  before.effect.targetBirth == entry.birth, before.effect.noteValue != nil else { throw StorageError.integrity }
                            state = .deleted(operation: op, before: before)
                        } else {
                            var records: [OperationID: IdentifiedOperation] = [:]
                            var needed = affected.before.represented
                            if case .derived(.merged(_, let base, _, _)) = affected.before { needed.append(base) }
                            for id in needed {
                                guard let value = try db.operation(id, selection: selection, protection: protection) else { throw StorageError.incomplete }
                                records[id] = value
                            }
                            guard let value = try CompensationV1.value(affected.before, operations: records) else { throw StorageError.integrity }
                            state = .deletedState(operation: op, before: affected.before, value: value)
                        }
                    default: throw StorageError.unsupported
                    }
                    try db.validateOwner()
                    return HistoryPreview(entry: entry, action: action, state: state)
                }
            }
        }
    }

    /// Captures the selected Delete's prior value and retained references. The host
    /// reserves the fresh birth before admitting the resulting action to its model.
    public func restoration(from entry: HistoryEntry, as generation: CapturedNoteGeneration,
                            selecting revision: HistoryEntry? = nil) async throws -> CapturedRestoration {
        return try await lane.verifyingHistory {
            let preview = try await preview(entry)
            let value: PlaintextNoteValue, source: ActionStateV1
            switch preview.state {
            case .deleted(_, let before):
                guard let prior = before.effect.noteValue else { throw StorageError.integrity }
                value = prior; source = .value(before.id)
            case .deletedState(_, let before, let prior): value = prior; source = before
            default: throw StorageError.unsupported
            }
            let selectedState: ActionStateV1, selectedValue: PlaintextNoteValue
            if let revision {
                let selected = try await self.preview(revision)
                guard revision.birth == entry.birth, case .value(let op) = selected.state,
                      let prior = op.effect.noteValue else { throw StorageError.staleCapture }
                selectedState = .value(op.id); selectedValue = prior
            } else { selectedState = source; selectedValue = value }
            guard generation.birth != entry.birth else { throw StorageError.staleCapture }
            guard !closed, !quiescing else { throw StorageError.closed }
            let graph = try await lane.retainedGraph(through: entry.through, selection: selection, protection: protection)
            guard let selectedID = selectedState.represented.first, let reference = graph.operationReferences[selectedID] else { throw StorageError.incomplete }
            let stateReference = try graph.stateReference(selectedState)
            return try await lane.perform { db in
                try db.validateOwner()
                let source = try RestorationReference(birth: generation.birth, sourceBirth: entry.birth,
                    deletionAction: db.actionOccurrence(entry.action).reference,
                    revision: reference.reference, priorState: { switch selectedState { case .derived, .automatic: stateReference; default: nil } }())
                return CapturedRestoration(generation: generation, value: selectedValue, session: entry.session,
                    store: entry.store, through: entry.through, reference: source)
            }
        }
    }
}
