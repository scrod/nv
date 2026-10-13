import Foundation
import Dispatch
import Crypto
import NVStorageCore

/// Per-attempt reader bounds; a larger retry budget accommodates a larger collection.
public struct PrivateBackupBudget: Sendable {
    public let pagesPerTurn: Int32
    public let maximumTurns: Int
    public let maximumNanoseconds: UInt64
    public init(pagesPerTurn: Int32 = 128, maximumTurns: Int = 4096, maximumNanoseconds: UInt64 = 30_000_000_000) throws {
        guard pagesPerTurn > 0, pagesPerTurn <= 1024, maximumTurns > 0, maximumNanoseconds > 0 else { throw StorageError.limit }
        self.pagesPerTurn = pagesPerTurn; self.maximumTurns = maximumTurns; self.maximumNanoseconds = maximumNanoseconds
    }
}

/// A complete fixed-state backup whose normal reopen checked its captured private/history cut.
public struct CompletePrivateBackup: Sendable {
    public let selection: LocalStoreSelection
    /// Source acceptance prefix captured by the fixed reader.
    public let through: Int64
    fileprivate init(selection: LocalStoreSelection, through: Int64) { self.selection = selection; self.through = through }
}

extension LocalStoreSession {
    /// Copies a keyed fixed read state, closes its reader, and independently reopens the destination.
    public func backupPrivateStore(to directory: String, budget: PrivateBackupBudget? = nil) async throws -> CompletePrivateBackup {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard !backupInFlight else { throw StorageError.busy }
        backupInFlight = true
        cancelMaintenance()
        defer {
            backupInFlight = false
            let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() }
        }
        let budget = try budget ?? PrivateBackupBudget(), selection = selection, protection = protection
        let start = DispatchTime.now().uptimeNanoseconds
        let candidate = LocalStoreSelection(directory: directory, store: selection.store, descriptor: selection.descriptor)
        var opened: LocalStoreSession?
        do {
            let cut = try await lane.perform { db in
                try db.beginPrivateBackup(directory: directory, selection: selection,
                    key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
            }
            let gate = try await lane.perform { $0.work?.backupCaptured }
            if let gate { await gate() }
            var finished = false
            for _ in 0..<budget.maximumTurns {
                try Task.checkCancellation()
                guard DispatchTime.now().uptimeNanoseconds - start <= budget.maximumNanoseconds else { throw StorageError.limit }
                if try await lane.perform({ try $0.stepPrivateBackup(pages: budget.pagesPerTurn) }) { finished = true; break }
            }
            guard finished else { throw StorageError.limit }
            try await lane.perform { $0.cancelPrivateBackup() }
            let copied = DatabaseLane()
            do {
                try await copied.open(directory: directory, create: false,
                    key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
                try await copied.perform { db in
                    try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                    guard try db.acceptedThrough() == cut.through,
                          try db.rows("SELECT group_key,generation,codec,payload FROM private_groups ORDER BY group_key") == cut.groups,
                          try db.rows("SELECT object_id,locator FROM retained_frontier ORDER BY object_id") == cut.pin,
                          try db.rows("SELECT birth,cell FROM current_notes ORDER BY birth") == cut.current,
                          try db.rows("SELECT dictionary_id,encoded FROM current_dictionaries ORDER BY dictionary_id") == cut.dictionaries,
                          try db.rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1") == cut.view,
                          try db.pendingPrivateFingerprint() == cut.pending else { throw StorageError.integrity }
                }
                await copied.close()
            } catch { await copied.close(); throw error }
            try Task.checkCancellation()
            opened = try await LocalStoreSession.open(selection: candidate, protection: protection)
            guard let destination = opened else { throw StorageError.incomplete }
            try await destination.lane.perform { db in
                // Normal reopening settles captured verification work before comparison of durable private values.
                let groups = try db.rows("SELECT group_key,generation,codec,payload FROM private_groups ORDER BY group_key")
                let capturedValues = try cut.groups.filter { !(try $0[0].bytes).starts(with: VerificationRecord.prefix) }
                let reopenedValues = try groups.filter { !(try $0[0].bytes).starts(with: VerificationRecord.prefix) }
                guard try db.acceptedThrough() >= cut.through,
                      reopenedValues == capturedValues,
                      try db.pendingPrivateFingerprint() == cut.pending else { throw StorageError.integrity }
                try db.installUnlockDescriptor(selection.descriptor)
            }
            try await destination.verifyCompletePrivateState()
            try await destination.quiesce(); opened = nil
            return CompletePrivateBackup(selection: candidate, through: cut.through)
        } catch {
            try? await lane.perform { $0.cancelPrivateBackup() }
            try? await opened?.quiesce()
            throw error
        }
    }

    /// Audits complete history and every pending reference for exceptional backup/repair qualification.
    func verifyCompletePrivateState() async throws {
        let selection = selection, protection = protection
        let through = try await lane.perform { try $0.acceptedThrough() }
        try await lane.verifyingHistory {
            let records = try await CheckedHistoryTraversal.read(through: through, scope: .allOccurrences, lane: lane,
                selection: selection, protection: protection)
            do {
                let (cells, context) = try await lane.historyWork {
                    let graph = records.graph, cells = try graph.currentCells(collection: selection.descriptor.collection)
                    let maxima = Set(graph.operations.keys).subtracting(graph.operations.values.flatMap { $0.causalParents.ids })
                    let context = try AuthoringContextV1(operations: maxima.map {
                        guard let ref = graph.operationReferences[$0] else { throw StorageError.integrity }; return ref
                    }, collectionActions: graph.scopeMaxima(.collection).map {
                        guard let ref = graph.actionReferences[$0] else { throw StorageError.integrity }; return ref
                    })
                    return (cells, context)
                }
                try await lane.perform { db in
                    let decoder = try CurrentRowRead()
                    let stored = try db.rows("SELECT cell FROM current_notes ORDER BY birth").map { try decoder.decode($0[0].bytes, database: db) }
                    let expected = cells.sorted { $0.birth.bytes.lexicographicallyPrecedes($1.birth.bytes) }
                    guard stored == expected,
                          try db.rows("SELECT through_seq,authoring_context FROM view_meta WHERE singleton=1") == [[.integer(through), .blob(context.encodedV1())]] else { throw StorageError.integrity }
                }
                try await lane.auditAcceptedSnapshots(records, selection: selection, protection: protection)
            } catch {
                try await lane.perform { db in try db.checkingRetainedHistory { throw error } }
            }
        }
        let items = try await lane.perform { try $0.rows("SELECT item_id,latest FROM pending_items ORDER BY item_id") }
        for row in items {
            let item = try PendingItemID(bytes: row[0].bytes)
            if case .blob(let b) = row[1] { _ = try await retainedPendingSnapshot(PendingSnapshotID(bytes: b)) }
            let recoveries = try await pendingRecovery(item)
            for recovery in recoveries {
                if case .blocked(_, let error) = recovery { throw error }
            }
        }
        try await lane.perform { db in
            guard try db.rows("PRAGMA foreign_key_check").isEmpty,
                  try db.rows("PRAGMA integrity_check") == [[.text("ok")]] else { throw StorageError.integrity }
        }
    }
}

extension Database {
    /// Streams the exact pending table cut into a transient, framed comparison digest.
    func pendingPrivateFingerprint() throws -> [UInt8] {
        var digest = SHA256()
        digest.update(data: Array("NV private backup pending\0v1\0".utf8))
        func frame(_ bytes: [UInt8], tag: UInt8) {
            let size = UInt64(bytes.count)
            digest.update(data: [tag] + stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: size >> $0) })
            digest.update(data: bytes)
        }
        for (name, query) in pendingPrivateQueries.sorted(by: { $0.key < $1.key }) {
            frame(Array(name.utf8), tag: 1)
            try each(query) { row in
                digest.update(data: [2])
                for value in row {
                    switch value {
                    case .null: frame([], tag: 3)
                    case .integer(let n):
                        frame(stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: UInt64(bitPattern: n) >> $0) }, tag: 4)
                    case .blob(let bytes): frame(bytes, tag: 5)
                    case .text(let text): frame(Array(text.utf8), tag: 6)
                    }
                }
                digest.update(data: [7])
            }
            digest.update(data: [8])
        }
        return Array(digest.finalize())
    }
}

let pendingPrivateQueries: [String: String] = [
    "pending_payloads": "SELECT snapshot_id,codec,encoded FROM pending_payloads ORDER BY snapshot_id",
    "pending_items": "SELECT item_id,generation,latest,status FROM pending_items ORDER BY item_id",
    "pending_reservations": "SELECT reservation_id,item_id,snapshot_id,operation_id,codec,encoded FROM pending_reservations ORDER BY reservation_id",
    "pending_settlements": "SELECT item_id,snapshot_id,reservation_id,operation_id,birth,decision_digest,observation_codec,observation FROM pending_settlements ORDER BY item_id,snapshot_id"
]
