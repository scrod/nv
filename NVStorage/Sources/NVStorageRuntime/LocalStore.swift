import Foundation
import NVStorageCore

/// Caller-selected location and expected logical identity, checked against a live directory lease.
public struct LocalStoreSelection: Sendable {
    public let directory: String
    public let store: LocalStoreID
    public let descriptor: BootstrapDescriptorV1
    public init(directory: String, store: LocalStoreID, descriptor: BootstrapDescriptorV1) {
        self.directory = directory; self.store = store; self.descriptor = descriptor
    }
}

/// Complete current-row capture from one materialized acceptance prefix.
public struct StoreSnapshot: Sendable {
    let session: UUID
    public let store: LocalStoreID
    public let through: Int64
    public let viewEpoch: [UInt8]
    public let notes: [CurrentNoteCellV1]
    public let context: AuthoringContextV1
    fileprivate init(session: UUID, store: LocalStoreID, through: Int64, viewEpoch: [UInt8],
                     notes: [CurrentNoteCellV1], context: AuthoringContextV1) {
        self.session = session; self.store = store; self.through = through; self.viewEpoch = viewEpoch; self.notes = notes; self.context = context
    }
}

public actor LocalStoreSession {
    public let selection: LocalStoreSelection
    let lane: DatabaseLane
    let protection: ObjectProtectionV1
    let incarnation = UUID()
    var closed = false
    var quiescing = false
    var inFlight = false
    var receiving = false
    var drained: [CheckedContinuation<Void, Never>] = []
    var commits: [UUID: OwnedCommit] = [:]
    var writer = try! WriterEpoch(bytes: uuidBytes())
    let origin = try! ActionOriginID(bytes: uuidBytes())
    var sequence: UInt64 = 0
    var previousOrigin: StoredActionReferenceV1?

    private init(selection: LocalStoreSelection, lane: DatabaseLane, protection: ObjectProtectionV1) {
        self.selection = selection; self.lane = lane; self.protection = protection
    }

    public static func create(directory: String, initial: InitialCollectionV1,
                              protection: ObjectProtectionV1, storeID: LocalStoreID? = nil) async throws -> LocalStoreSession {
        try await create(directory: directory, initial: initial, protection: protection, storeID: storeID, lane: DatabaseLane())
    }

    /// Seals frozen initial values and initializes a newly owned candidate on its I/O worker.
    public static func create(directory: String, collection: CollectionID, notes: [(NoteBirth, PlaintextNoteValue)],
                              protection: ObjectProtectionV1, passphrase: String? = nil) async throws -> LocalStoreSession {
        let lane = DatabaseLane()
        let initial = try await lane.prepare {
            try InitialCollectionV1.build(collection: collection, notes: notes, protection: protection, passphrase: passphrase)
        }
        return try await create(directory: directory, initial: initial, protection: protection, storeID: nil, lane: lane)
    }

    private static func create(directory: String, initial: InitialCollectionV1, protection: ObjectProtectionV1,
                               storeID: LocalStoreID?, lane: DatabaseLane) async throws -> LocalStoreSession {
        let store = try storeID ?? LocalStoreID(bytes: uuidBytes())
        let selection = LocalStoreSelection(directory: directory, store: store, descriptor: initial.descriptor)
        try await lane.open(directory: directory, create: true,
            key: PrivateDatabaseKeyV1.derive(collection: initial.descriptor.collection, protection: protection))
        do {
            try await lane.perform { db in
                try db.initialize(store: store, descriptor: initial.descriptor, snapshot: initial.snapshot)
                let checked = try db.acceptBootstrap(initial, selection: selection, protection: protection)
                try db.materializeBootstrap(checked)
            }
            return LocalStoreSession(selection: selection, lane: lane, protection: protection)
        } catch { await lane.close(); throw error }
    }

    public static func open(selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> LocalStoreSession {
        let lane = DatabaseLane()
        try await lane.open(directory: selection.directory, create: false,
            key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
        do {
            try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                try db.checkRequiredLeaves(descriptor: selection.descriptor, protection: protection)
            }
            try await lane.perform { db in
                try db.recoverMaterialization(selection: selection, protection: protection)
            }
            try await lane.drainReady(selection: selection, protection: protection)
            try await lane.catchUp(selection: selection, protection: protection)
            try await lane.perform { db in
                _ = try db.snapshot(store: selection.store, session: UUID())
            }
            return LocalStoreSession(selection: selection, lane: lane, protection: protection)
        } catch { await lane.close(); throw error }
    }

    public func snapshot() async throws -> StoreSnapshot {
        guard !closed else { throw StorageError.closed }
        let store = selection.store, session = incarnation
        return try await lane.perform { try $0.snapshot(store: store, session: session) }
    }
    public func quiesce() async throws {
        guard !closed else { return }
        guard !quiescing else { throw StorageError.busy }
        quiescing = true
        while inFlight || receiving { await withCheckedContinuation { drained.append($0) } }
        guard commits.isEmpty else { quiescing = false; throw StorageError.busy }
        closed = true
        try? await lane.perform { try $0.checkpoint() }
        await lane.close()
    }
    public func checkpointMaintenance() async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        try await lane.perform { try $0.checkpoint() }
    }
}

extension Database {
    func checkRequiredLeaves(descriptor: BootstrapDescriptorV1, protection: ObjectProtectionV1) throws {
        let d = try rows("SELECT o.encoded FROM retained_descriptors r JOIN objects o USING(object_id) JOIN accepted_objects a USING(object_id) WHERE r.object_id=?", [.blob(descriptor.descriptorID)])
        guard d == [[.blob(descriptor.encodedBytes)]] else { throw StorageError.incomplete }
        let absent = try rows("SELECT 1 FROM retained_frontier r LEFT JOIN objects o USING(object_id) LEFT JOIN accepted_objects a USING(object_id) WHERE o.object_id IS NULL OR a.object_id IS NULL LIMIT 1")
        guard absent.isEmpty, try acceptedThrough() > 0 else { throw StorageError.incomplete }
        guard try !rows("SELECT 1 FROM retained_frontier LIMIT 1").isEmpty else { throw StorageError.incomplete }
        try each("SELECT r.locator,o.encoded FROM retained_frontier r JOIN objects o USING(object_id)") { row in
            _ = try ObjectEnvelopeV1.open(row[1].bytes, collection: descriptor.collection, protection: protection,
                expectedLocator: SegmentLocator.decodeV1(row[0].bytes))
        }
    }
    func materializeBootstrap(_ checked: InitialBootstrapValidationV1) throws {
        let target = try rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(checked.snapshot.segmentID.bytes)])[0][0].number
        var notes: [CurrentNoteCellV1] = []
        for row in checked.rows {
            guard case .external(let loc, let index, let id) = row.importReference else { throw StorageError.integrity }
            let refs = try (checked.scopeFrontiers[.note(row.birth)]?.actionIDs ?? []).map { try actionOccurrence($0) }
            notes.append(try CurrentNoteCellV1(birth: row.birth, value: row.value,
                revision: StoredOperationReferenceV1(locator: loc, index: index, id: id), scopeFrontier: refs))
        }
        let actions = try (checked.scopeFrontiers[.collection]?.actionIDs ?? []).map { try actionOccurrence($0) }
        let context = try AuthoringContextV1(operations: [operationOccurrence(checked.completion)], collectionActions: actions)
        try transaction {
            try run("DELETE FROM current_notes")
            for cell in notes { try run("INSERT INTO current_notes VALUES(?,?)", [.blob(cell.birth.bytes), .blob(cell.encodedV1())]) }
            try run("INSERT INTO view_meta VALUES(1,?,1,?,?) ON CONFLICT(singleton) DO UPDATE SET epoch=excluded.epoch,reducer_version=1,through_seq=excluded.through_seq,authoring_context=excluded.authoring_context",
                [.blob(uuidBytes()), .integer(target), .blob(context.encodedV1())])
        }
    }
    func recoverMaterialization(selection: LocalStoreSelection, protection: ObjectProtectionV1) throws {
        let view = try rows("SELECT through_seq FROM view_meta WHERE singleton=1")
        let through = try view.first?.first?.number
        let target = try acceptedThrough()
        if through == target {
            do { _ = try snapshot(store: selection.store, session: UUID()); return }
            catch is CanonicalEncodingError { }
            catch StorageError.integrity { }
        }
        if let through, through > 0, through < target {
            do { try catchUp(selection: selection, protection: protection); return }
            catch is CanonicalEncodingError { }
            catch StorageError.integrity { }
        }
        // Rebuild initial imports from their required root and exact object closure.
        let r = try rows("SELECT codec,payload FROM private_groups WHERE group_key=?", [.blob(Array("bootstrap".utf8))])
        guard r.count == 1, r[0][0] == .integer(1) else { throw StorageError.incomplete }
        let root = try SegmentLocator.decodeV1(r[0][1].bytes)
        let checked = try InitialBootstrapValidationV1.validate(descriptor: selection.descriptor,
            expectedCollection: selection.descriptor.collection, protection: protection, snapshot: root) { loc in
                let rows = try self.rows("SELECT o.encoded FROM objects o JOIN accepted_objects a USING(object_id) WHERE o.object_id=? AND o.writer_epoch=? AND o.sequence=?",
                    [.blob(loc.segmentID.bytes), .blob(loc.writerEpoch.bytes), .blob(Array(loc.encodedV1()[16..<24]))])
                return try rows.first?.first?.bytes
            }
        try materializeBootstrap(checked)
        try catchUp(selection: selection, protection: protection)
    }
    func snapshot(store: LocalStoreID, session: UUID) throws -> StoreSnapshot {
        try exec("BEGIN")
        do {
            let meta = try rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1")
            guard meta.count == 1, meta[0][1] == .integer(1) else { throw StorageError.incomplete }
            let through = try meta[0][2].number
            guard through > 0, try acceptedThrough() == through else { throw StorageError.incomplete }
            let epoch = try meta[0][0].bytes
            guard epoch.count == 16 else { throw StorageError.integrity }
            let context = try AuthoringContextV1.decodeV1(meta[0][3].bytes)
            var cells: [CurrentNoteCellV1] = []
            try each("SELECT birth,cell FROM current_notes ORDER BY rowid") { r in
                let cell = try CurrentNoteCellV1.decodeV1(r[1].bytes)
                guard try cell.birth.bytes == r[0].bytes else { throw StorageError.integrity }
                cells.append(cell)
            }
            try exec("COMMIT")
            return StoreSnapshot(session: session, store: store, through: through, viewEpoch: epoch, notes: cells, context: context)
        } catch { try? exec("ROLLBACK"); throw error }
    }
}
