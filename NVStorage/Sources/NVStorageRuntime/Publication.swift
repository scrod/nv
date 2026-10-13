import NVStorageCore
import Foundation

/// Current values prepared for one host generation and one exact database view.
public struct PreparedModelChange: Sendable {
    fileprivate let snapshot: StoreSnapshot
    fileprivate let liveGeneration: UInt64
    fileprivate init(snapshot: StoreSnapshot, liveGeneration: UInt64) {
        self.snapshot = snapshot; self.liveGeneration = liveGeneration
    }
}

extension LocalStoreSession {
    public func prepareReduction(liveGeneration: UInt64) async throws -> PreparedModelChange {
        guard !closed else { throw StorageError.closed }
        return try await PreparedModelChange(snapshot: snapshot(), liveGeneration: liveGeneration)
    }

    /// Executes the headless host's synchronous publication while the database lane
    /// still owns the checked view. The host must also serialize its live generation.
    public func publish<T: Sendable>(_ change: PreparedModelChange, liveGeneration: UInt64,
                                    apply: @escaping @Sendable (StoreSnapshot) throws -> T) async throws -> T {
        guard !closed else { throw StorageError.closed }
        guard change.snapshot.session == incarnation, change.snapshot.store == selection.store else { throw StorageError.wrongContext }
        guard change.liveGeneration == liveGeneration else { throw StorageError.staleCapture }
        let result = try await lane.perform { db in
            let s = change.snapshot
            let meta = try db.rows("SELECT epoch,through_seq FROM view_meta WHERE singleton=1")
            guard meta == [[.blob(s.viewEpoch), .integer(s.through)]], try db.acceptedThrough() == s.through,
                  db.presentationEpoch == s.presentationEpoch else {
                throw StorageError.staleCapture
            }
            return try apply(s)
        }
        startPublishedReceiveWork()
        return result
    }
}

/// Empty settings value and its independently versioned private-state generation.
public struct EmptySettingsState: Sendable {
    public let generation: Int64
    fileprivate let store: LocalStoreID
    fileprivate let session: UUID
    fileprivate init(generation: Int64, store: LocalStoreID, session: UUID) {
        self.generation = generation; self.store = store; self.session = session
    }
}

extension LocalStoreSession {
    public func settings() async throws -> EmptySettingsState {
        guard !closed else { throw StorageError.closed }
        let store = selection.store, session = incarnation
        return try await lane.perform { db in
            let r = try db.rows("SELECT generation,codec,payload FROM private_groups WHERE group_key=?", [.blob(Array("settings".utf8))])
            guard r.count == 1 else { throw StorageError.incomplete }
            guard r[0][1] == .integer(1), r[0][2] == .blob([]) else { throw StorageError.unsupported }
            return try EmptySettingsState(generation: r[0][0].number, store: store, session: session)
        }
    }
    public func saveEmptySettings(basedOn state: EmptySettingsState) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard state.store == selection.store, state.session == incarnation else { throw StorageError.wrongContext }
        guard state.generation < Int64.max else { throw StorageError.limit }
        cancelMaintenance()
        try await lane.perform { db in
            try db.transaction {
                let old = try db.rows("SELECT generation,codec,payload FROM private_groups WHERE group_key=?", [.blob(Array("settings".utf8))])
                guard old == [[.integer(state.generation), .integer(1), .blob([])]] else { throw StorageError.staleCapture }
                try db.run("UPDATE private_groups SET generation=generation+1 WHERE group_key=?", [.blob(Array("settings".utf8))])
            }
        }
    }
}
