import Foundation
import NVStorageCore

/// Complete settings captured with the private generation that guards replacement.
public struct CollectionSettingsState: Sendable {
    public let generation: Int64
    public let value: CollectionSettingsV1
    fileprivate let store: LocalStoreID
    fileprivate let session: UUID
    fileprivate init(generation: Int64, value: CollectionSettingsV1, store: LocalStoreID, session: UUID) {
        self.generation = generation; self.value = value; self.store = store; self.session = session
    }
}

/// Captured association framing and the generation of its passive platform bookmark.
public struct LocalAssociationState: Sendable {
    public let generation: Int64
    public let value: LocalAssociationV1?
    fileprivate let store: LocalStoreID
    fileprivate let session: UUID
    fileprivate init(generation: Int64, value: LocalAssociationV1?, store: LocalStoreID, session: UUID) {
        self.generation = generation; self.value = value; self.store = store; self.session = session
    }
}

extension LocalStoreSession {
    public func collectionSettings() async throws -> CollectionSettingsState {
        guard !closed else { throw StorageError.closed }
        let store = selection.store, session = incarnation
        return try await lane.perform { db in
            let row = try db.privateGroup("settings")
            guard let row else { throw StorageError.incomplete }
            return try CollectionSettingsState(generation: row[0].number, value: db.decodedSettings(row), store: store, session: session)
        }
    }

    public func saveCollectionSettings(_ value: CollectionSettingsV1, basedOn state: CollectionSettingsState) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard state.store == selection.store, state.session == incarnation else { throw StorageError.wrongContext }
        let bytes = value.encodedV1()
        cancelMaintenance()
        try await lane.perform { db in
            try db.transaction {
                guard let old = try db.privateGroup("settings"), try old[0].number == state.generation else { throw StorageError.staleCapture }
                guard try db.decodedSettings(old) == state.value else { throw StorageError.integrity }
                try db.replacePrivateGroup("settings", generation: state.generation, codec: 2, bytes: bytes)
            }
        }
    }

    public func localAssociation() async throws -> LocalAssociationState {
        guard !closed else { throw StorageError.closed }
        let selection = selection, session = incarnation
        return try await lane.perform { db in
            let row = try db.privateGroup("association")
            return try LocalAssociationState(generation: row?[0].number ?? 0,
                value: row.map { try db.decodedAssociation($0, selection: selection) }, store: selection.store, session: session)
        }
    }

    public func saveLocalAssociation(_ value: LocalAssociationV1, basedOn state: LocalAssociationState) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard state.store == selection.store, state.session == incarnation else { throw StorageError.wrongContext }
        let selection = selection
        cancelMaintenance()
        try await lane.perform { db in
            try db.checkPrivateScope(value.scope, selection: selection)
            try db.transaction {
                let old = try db.privateGroup("association")
                guard try old?.first?.number ?? 0 == state.generation else { throw StorageError.staleCapture }
                guard try old.map({ try db.decodedAssociation($0, selection: selection) }) == state.value else { throw StorageError.integrity }
                try db.replacePrivateGroup("association", generation: state.generation, codec: 1, bytes: value.encodedV1())
            }
        }
    }
}

extension Database {
    /// Checks required private inputs before opening or replacing derived current rows.
    func validateRequiredPrivateGroups(store: LocalStoreID, descriptor: BootstrapDescriptorV1) throws {
        try requireHealthyHistory()
        guard try rows("SELECT 1 FROM private_groups WHERE group_key=?", [.blob(Array("history-damage".utf8))]).isEmpty else {
            throw StorageError.integrity
        }
        guard let settings = try privateGroup("settings") else { throw StorageError.incomplete }
        _ = try decodedSettings(settings)
        if let association = try privateGroup("association") {
            _ = try decodedAssociation(association, selection: .init(directory: "", store: store, descriptor: descriptor))
        }
        try validateProjectionObservations(selection: .init(directory: "", store: store, descriptor: descriptor))
        try validateProjectionReplacementAttempts(selection: .init(directory: "", store: store, descriptor: descriptor))
        try validateProjectionSourceAttempts(selection: .init(directory: "", store: store, descriptor: descriptor))
        let bootstrap = try rows("SELECT codec,payload FROM private_groups WHERE group_key=?", [.blob(Array("bootstrap".utf8))])
        guard bootstrap.count == 1 else { throw StorageError.incomplete }
        guard bootstrap[0][0] == .integer(1) else { throw StorageError.unsupported }
    }
    func privateGroup(_ key: String) throws -> [SQLValue]? {
        let rows = try rows("SELECT generation,codec,payload FROM private_groups WHERE group_key=?", [.blob(Array(key.utf8))])
        guard rows.count <= 1 else { throw StorageError.integrity }
        return rows.first
    }
    func decodedSettings(_ row: [SQLValue]) throws -> CollectionSettingsV1 {
        if row[1] == .integer(1), row[2] == .blob([]) { return try CollectionSettingsV1([]) }
        guard row[1] == .integer(2) else { throw StorageError.unsupported }
        do { return try CollectionSettingsV1.decodeV1(row[2].bytes) }
        catch { throw classify(error) }
    }
    func decodedAssociation(_ row: [SQLValue], selection: LocalStoreSelection) throws -> LocalAssociationV1 {
        guard row[1] == .integer(1) else { throw StorageError.unsupported }
        let value: LocalAssociationV1
        do { value = try LocalAssociationV1.decodeV1(row[2].bytes) } catch { throw classify(error) }
        try checkPrivateScope(value.scope, selection: selection)
        return value
    }
    func checkPrivateScope(_ scope: PrivateRecordScopeV1, selection: LocalStoreSelection) throws {
        guard scope.collection == selection.descriptor.collection, scope.store == selection.store,
              scope.descriptor == selection.descriptor.descriptorID else { throw StorageError.wrongContext }
    }
    /// Historical capture scopes remain readable after an explicitly verified sibling repair.
    func checkCapturedPrivateScope(_ scope: PrivateRecordScopeV1, selection: LocalStoreSelection) throws {
        if scope.store == selection.store { return try checkPrivateScope(scope, selection: selection) }
        guard scope.collection == selection.descriptor.collection,
              try rows("SELECT codec,payload FROM private_groups WHERE group_key=?",
                [.blob(Array("repair-source/".utf8) + scope.store.bytes)]) ==
                [[.integer(1), .blob(scope.collection.bytes + scope.descriptor)]] else { throw StorageError.wrongContext }
    }
    func replacePrivateGroup(_ key: String, generation: Int64, codec: Int64, bytes: [UInt8]) throws {
        guard generation >= 0, generation < Int64.max else { throw StorageError.limit }
        try run("INSERT INTO private_groups VALUES(?,?,?,?) ON CONFLICT(group_key) DO UPDATE SET generation=excluded.generation,codec=excluded.codec,payload=excluded.payload",
            [.blob(Array(key.utf8)), .integer(generation + 1), .integer(codec), .blob(bytes)])
    }
}
