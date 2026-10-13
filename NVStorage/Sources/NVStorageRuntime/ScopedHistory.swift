import Foundation
import NVStorageCore

/// The exact note-specific question answered by a selected history read.
enum QueryHistoryScope: Equatable, Sendable { case undo(NoteBirth), conflicts(NoteBirth) }

/// Verified query inputs bound to one checked current capture and owned connection.
struct CheckedQueryHistory: Sendable {
    private let scope: QueryHistoryScope
    private let store: LocalStoreID
    private let connection: UUID
    private let session: UUID
    private let through: Int64
    private let epoch: [UInt8]
    private let presentation: UUID
    private let actions: [ActionV1]
    private let alternatives: [IdentifiedOperation]
    private let dispositions: Set<OperationID>
    private init(scope: QueryHistoryScope, snapshot: StoreSnapshot, connection: UUID, actions: [ActionV1],
                 alternatives: [IdentifiedOperation], dispositions: Set<OperationID>) {
        self.scope = scope; store = snapshot.store; self.connection = connection; session = snapshot.session
        through = snapshot.through; epoch = snapshot.viewEpoch; presentation = snapshot.presentationEpoch
        self.actions = actions; self.alternatives = alternatives; self.dispositions = dispositions
    }

    /// Selects scope membership or source heads and global copy dispositions before loading bodies.
    static func read(scope: QueryHistoryScope, snapshot: StoreSnapshot, session: UUID, lane: DatabaseLane,
                     selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> Self {
        guard snapshot.session == session, snapshot.store == selection.store else { throw StorageError.wrongContext }
        return try await lane.verifying(.history(snapshot.through)) {
            do {
                let connection = try await lane.perform { db in
                    try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                    try db.checkCurrentView(snapshot)
                    return db.incarnation
                }
                let actionRows: [[SQLValue]], references: [StoredOperationReferenceV1]
                switch scope {
                case .undo(let birth):
                    actionRows = try await selectActions(birth: birth, through: snapshot.through, lane: lane)
                    references = []
                case .conflicts(let birth):
                    guard let cell = snapshot.notes.first(where: { $0.birth == birth }) else { throw StorageError.incomplete }
                    actionRows = try await selectActions(birth: nil, through: snapshot.through, lane: lane)
                    let represented = Set(cell.represented.map(\.id))
                    references = cell.heads.filter { !represented.contains($0.id) }
                }
                let selected = try await lane.perform { $0.work?.querySelected }
                await selected?()
                let sources = try Set(actionRows.map { try $0[1].bytes }).union(references.map { $0.locator.segmentID.bytes })
                var envelopes: [SegmentID: CheckedEnvelopeRecords] = [:]
                let attempt = UUID()
                for source in sources.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                    try Task.checkCancellation()
                    let checked = try await CheckedEnvelopeRecords.read(source: source, through: snapshot.through,
                        attempt: attempt, lane: lane, selection: selection, protection: protection)
                    envelopes[checked.locator.segmentID] = checked
                }
                var actions: [ActionV1] = [], alternatives: [IdentifiedOperation] = [], dispositions: Set<OperationID> = []
                for row in actionRows {
                    let id = try ActionID(bytes: row[0].bytes), source = try SegmentID(bytes: row[1].bytes)
                    guard let envelope = envelopes[source], let reference = envelope.actionReferences[id],
                          Int(reference.index.rawValue) < envelope.actions.count, try Int64(reference.index.rawValue) == row[2].number,
                          try envelope.sequence == row[3].number else { throw StorageError.integrity }
                    let action = envelope.actions[Int(reference.index.rawValue)]
                    guard action.id == id else { throw StorageError.integrity }
                    switch scope {
                    case .undo(let birth): guard action.scope == .note(birth) else { throw StorageError.integrity }; actions.append(action)
                    case .conflicts:
                        guard action.kind == .conflictCopy, case .copy(_, let revision, _, _, _) = action.details else { throw StorageError.integrity }
                        dispositions.insert(revision)
                    }
                }
                for ref in references {
                    guard let envelope = envelopes[ref.locator.segmentID], envelope.locator == ref.locator,
                          Int(ref.index.rawValue) < envelope.operations.count,
                          envelope.operations[Int(ref.index.rawValue)].id == ref.id else { throw StorageError.integrity }
                    try await CheckedEnvelopeRecords.checkOccurrence(ref.locator, index: ref.index.rawValue, id: ref.id.bytes,
                        operation: true, through: snapshot.through, lane: lane)
                    if !dispositions.contains(ref.id) { alternatives.append(envelope.operations[Int(ref.index.rawValue)]) }
                }
                if case .undo(let birth) = scope {
                    let ids = Set(actions.map(\.id))
                    for action in actions {
                        guard action.scopeParents.allSatisfy(ids.contains) else { throw StorageError.integrity }
                        switch action.details {
                        case .compensation(let target, _): guard ids.contains(target) else { throw StorageError.integrity }
                        case .native(let coverage): guard coverage.allSatisfy({ ids.contains($0.action) }) else { throw StorageError.integrity }
                        default: break
                        }
                    }
                    if let cell = snapshot.notes.first(where: { $0.birth == birth }) {
                        let maxima = ids.subtracting(actions.flatMap(\.scopeParents))
                        guard maxima == Set(cell.scopeFrontier.map(\.id)) else { throw StorageError.integrity }
                    }
                }
                let result = Self(scope: scope, snapshot: snapshot, connection: connection, actions: actions,
                                  alternatives: alternatives, dispositions: dispositions)
                try await lane.perform { try result.check(scope: scope, snapshot: snapshot, database: $0, selection: selection) }
                return result
            } catch { try await lane.failRetainedRead(error) }
        }
    }

    /// Rechecks ownership and the captured query context while allowing newer immutable acceptance.
    func check(scope: QueryHistoryScope, snapshot: StoreSnapshot, database db: Database, selection: LocalStoreSelection) throws {
        guard self.scope == scope, connection == db.incarnation, store == selection.store, snapshot.store == store,
              session == snapshot.session, through == snapshot.through, epoch == snapshot.viewEpoch,
              presentation == snapshot.presentationEpoch else { throw StorageError.wrongContext }
        try db.validateHeader(store: store, descriptor: selection.descriptor)
        guard try db.acceptedThrough() >= through else { throw StorageError.staleCapture }
    }
    func undoActions(for birth: NoteBirth, snapshot: StoreSnapshot, database db: Database, selection: LocalStoreSelection) throws -> [ActionV1] {
        try check(scope: .undo(birth), snapshot: snapshot, database: db, selection: selection)
        return actions
    }
    func conflicts(for birth: NoteBirth, snapshot: StoreSnapshot, database db: Database, selection: LocalStoreSelection) throws -> (alternatives: [IdentifiedOperation], dispositions: Set<OperationID>) {
        try check(scope: .conflicts(birth), snapshot: snapshot, database: db, selection: selection)
        return (alternatives, dispositions)
    }

    /// Uses scope and copy-only indexes, paging within the captured acceptance prefix.
    private static func selectActions(birth: NoteBirth?, through: Int64, lane: DatabaseLane) async throws -> [[SQLValue]] {
        var result: [[SQLValue]] = [], after: [UInt8] = [], sequence: Int64 = 0
        while true {
            let position = after, start = sequence
            let rows = try await lane.perform { db in
                if let birth {
                    return try db.rows("SELECT action_id,source_object,source_index,first_seq FROM actions INDEXED BY actions_scope WHERE scope_birth=? AND first_seq<=? AND action_id>? ORDER BY action_id LIMIT 64", [.blob(birth.bytes), .integer(through), .blob(position)])
                }
                return try db.rows("SELECT action_id,source_object,source_index,first_seq FROM actions INDEXED BY actions_conflict_copies WHERE kind=9 AND first_seq<=? AND (first_seq,action_id)>(?,?) ORDER BY first_seq,action_id LIMIT 64", [.integer(through), .integer(start), .blob(position)])
            }
            result += rows
            guard rows.count == 64 else { return result }
            after = try rows.last![0].bytes; sequence = try rows.last![3].number
        }
    }
}
