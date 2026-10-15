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
    let presentationEpoch: UUID
    fileprivate init(session: UUID, store: LocalStoreID, through: Int64, viewEpoch: [UInt8],
                     notes: [CurrentNoteCellV1], context: AuthoringContextV1, presentationEpoch: UUID) {
        self.session = session; self.store = store; self.through = through; self.viewEpoch = viewEpoch; self.notes = notes; self.context = context; self.presentationEpoch = presentationEpoch
    }
}

/// Collection admission remains open until quiescing finishes or a pending commit requires retry.
enum LocalStoreLifecycle: Sendable { case open, quiescing, closed }

/// Receive admission distinguishes an owned write from optional snapshot preparation.
enum ReceiveWorkState: Sendable { case idle, retaining, history, optional }

public actor LocalStoreSession {
    public let selection: LocalStoreSelection
    let lane: DatabaseLane
    let protection: ObjectProtectionV1
    let incarnation: UUID
    private var openingCapture: StoreSnapshot?
    private(set) var lifecycle: LocalStoreLifecycle = .open
    var closed: Bool { lifecycle == .closed }
    var quiescing: Bool { lifecycle == .quiescing }
    var inFlight: Bool { commitState.isRunning }
    var receiveState: ReceiveWorkState = .idle
    var receiving: Bool { receiveState != .idle }
    var requiredReceiveInFlight: Bool { receiveState == .retaining || receiveState == .history }
    var drained: [CheckedContinuation<Void, Never>] = []
    private var transport: (UUID, @Sendable (RepositoryTransportSignal) -> Void)?
    var commitState: LocalCommitState = .idle
    var snapshotState: LocalSnapshotState = .idle
    var backupInFlight = false
    var pendingPreparationInFlight = false
    var rowEncodingInFlight = false
    var trainedRowView: ([UInt8], Int64)?
    var maintenance: MaintenanceState = .idle
    var activationInFlight = false
    var writer = try! WriterEpoch(bytes: uuidBytes())
    let origin = try! ActionOriginID(bytes: uuidBytes())
    var sequence: UInt64 = 0
    var previousOrigin: StoredActionReferenceV1?

    private init(selection: LocalStoreSelection, lane: DatabaseLane, protection: ObjectProtectionV1,
                 incarnation: UUID = UUID(), openingCapture: StoreSnapshot? = nil) {
        self.selection = selection; self.lane = lane; self.protection = protection
        self.incarnation = incarnation; self.openingCapture = openingCapture
    }

    func attachTransport(_ owner: UUID, signal: @escaping @Sendable (RepositoryTransportSignal) -> Void) throws {
        guard lifecycle == .open else { throw StorageError.closed }
        guard transport == nil else { throw StorageError.busy }
        transport = (owner, signal)
    }
    func detachTransport(_ owner: UUID) { if transport?.0 == owner { transport = nil } }
    func signalTransportSettled() { transport?.1(.storeSettled) }
    func transportReady() -> Bool { lifecycle == .open && !receiving }

    public static func create(directory: String, initial: InitialCollectionV1,
                              protection: ObjectProtectionV1, storeID: LocalStoreID? = nil) async throws -> LocalStoreSession {
        let store = try storeID ?? LocalStoreID(bytes: uuidBytes())
        let selection = LocalStoreSelection(directory: directory, store: store, descriptor: initial.descriptor)
        let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: initial.snapshot, protection: protection)
        do {
            for bytes in initial.objects.values { _ = try await candidate.retain(bytes) }
            return try await candidate.complete(snapshot: initial.snapshot)
        } catch { try? await candidate.close(); throw error }
    }

    /// Seals frozen initial values and initializes a newly owned candidate on its I/O worker.
    public static func create(directory: String, collection: CollectionID, notes: [(NoteBirth, PlaintextNoteValue)],
                              protection: ObjectProtectionV1, passphrase: String? = nil) async throws -> LocalStoreSession {
        try await createIncrementally(directory: directory, collection: collection, notes: notes,
                                      protection: protection, passphrase: passphrase)
    }

    public static func open(selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> LocalStoreSession {
        try await open(selection: selection, protection: protection, measuring: nil)
    }

    /// Runs the normal returning-open path with optional queue-owned qualification counters.
    static func open(selection: LocalStoreSelection, protection: ObjectProtectionV1, measuring: StorageWork?,
                     diagnosing: (@Sendable (StorageOpenPhase) async -> Void)? = nil) async throws -> LocalStoreSession {
        let lane = DatabaseLane()
        let session = UUID()
        try await lane.open(directory: selection.directory, create: false,
            key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
        do {
            await diagnosing?(.headerAndPrivateGroups)
            try await lane.perform { db in
                db.work = measuring
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            }
            return try await CatchUpScope.$purpose.withValue(.opening) {
                await diagnosing?(.requiredHistory)
                try await lane.replayVerifications(selection: selection, protection: protection)
                try await lane.perform { db in
                    try db.checkRequiredLeaves(descriptor: selection.descriptor, protection: protection)
                }
                await diagnosing?(.currentReconstruction)
                let checked = try await lane.reconstructIfNeeded(selection: selection, protection: protection, session: session)
                _ = try await lane.drainReady(selection: selection, protection: protection, policy: .startupRequired)
                try await lane.catchUp(selection: selection, protection: protection)
                let initial = try await lane.perform { db in
                    if let checked {
                        do { try db.checkCurrentView(checked); return checked }
                        catch StorageError.staleCapture { }
                    }
                    return try db.snapshot(store: selection.store, session: session)
                }
                await lane.enableVerificationReplay(selection: selection, protection: protection)
                return LocalStoreSession(selection: selection, lane: lane, protection: protection, incarnation: session, openingCapture: initial)
            }
        } catch {
            await lane.close()
            if error is CanonicalEncodingError { throw StorageError.integrity }
            throw error
        }
    }

    public func snapshot() async throws -> StoreSnapshot {
        guard !closed else { throw StorageError.closed }
        let selection = selection, protection = protection, session = incarnation
        if let checked = openingCapture {
            openingCapture = nil
            do { return try await lane.perform { db in try db.checkCurrentView(checked); return checked } }
            catch StorageError.staleCapture { }
        }
        return try await lane.perform { try $0.presentedSnapshot(selection: selection, protection: protection, session: session) }
    }
    /// Keeps the currently represented local revision visible while its host work settles.
    public func pinCurrent(for birth: NoteBirth) async throws -> StoreSnapshot {
        guard !closed, !quiescing else { throw StorageError.closed }
        let selection = selection, protection = protection, session = incarnation
        return try await lane.perform { db in
            let snapshot = try db.presentedSnapshot(selection: selection, protection: protection, session: session)
            guard let cell = snapshot.notes.first(where: { $0.birth == birth }), cell.represented.count == 1 else { throw StorageError.staleCapture }
            db.presentationPins[birth] = cell.revision.id; db.presentationEpoch = UUID()
            return try db.presentedSnapshot(selection: selection, protection: protection, session: session)
        }
    }
    /// Publishes the already computed neutral selection after a local presentation fence settles.
    public func releaseCurrentPin(for birth: NoteBirth) async throws -> StoreSnapshot {
        guard !closed else { throw StorageError.closed }
        let selection = selection, protection = protection, session = incarnation
        return try await lane.perform { db in
            if db.presentationPins.removeValue(forKey: birth) != nil { db.presentationEpoch = UUID() }
            return try db.presentedSnapshot(selection: selection, protection: protection, session: session)
        }
    }
    public func quiesce() async throws {
        guard !closed else { return }
        guard !quiescing else { throw StorageError.busy }
        lifecycle = .quiescing
        transport?.1(.closed)
        cancelMaintenance()
        while inFlight || requiredReceiveInFlight || backupInFlight || activationInFlight || pendingPreparationInFlight || rowEncodingInFlight || maintenance.active { await withCheckedContinuation { drained.append($0) } }
        guard commitState.owned == nil else { lifecycle = .open; throw StorageError.busy }
        snapshotState = .idle
        openingCapture = nil
        lifecycle = .closed
        try? await lane.perform { try $0.checkpoint() }
        await lane.close()
    }
    public func checkpointMaintenance() async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        cancelMaintenance()
        try await lane.perform { try $0.checkpoint() }
    }
    /// Settles exclusive connections for a preserved repair copy while admitted work keeps its owner.
    func closeForPreservedRepair() async throws {
        guard !closed, !quiescing, !backupInFlight, !activationInFlight, !pendingPreparationInFlight, !rowEncodingInFlight, !maintenance.active, !receiving, !inFlight, commitState.owned == nil else { throw StorageError.busy }
        lifecycle = .closed
        transport?.1(.closed)
        await lane.close()
    }
    /// Fences new admission and checks the exact fixed copy before retiring the source connection.
    func retireForCopy(_ backup: CapturedPrivateBackup) async throws -> [UInt64] {
        guard !closed, !quiescing else { throw StorageError.closed }
        try backup.checkSession(incarnation, selection: selection)
        cancelMaintenance()
        guard !backupInFlight, !activationInFlight, !pendingPreparationInFlight, !rowEncodingInFlight,
              !maintenance.active, !receiving, !inFlight, commitState.owned == nil else { throw StorageError.busy }
        lifecycle = .quiescing
        do {
            let result = try await lane.retireForCopy(backup)
            lifecycle = .closed; transport?.1(.closed)
            return try result.get()
        } catch {
            if lifecycle != .closed { lifecycle = .open }
            throw error
        }
    }
    /// Reserves the candidate's live owner through a separately serialized selection operation.
    func reserveActivation(through: Int64) async throws {
        guard !closed, !quiescing, !activationInFlight else { throw StorageError.closed }
        activationInFlight = true
        cancelMaintenance()
        do {
            try await lane.perform { db in
                guard try db.acceptedThrough() == through else { throw StorageError.staleCapture }
                try db.validateOwner()
            }
        } catch { settleActivation(); throw error }
    }
    func settleActivation() {
        activationInFlight = false
        let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() }
    }
    /// Reserves a unique shared writer address before any envelope-sealing suspension.
    func reserveObjectAddress() throws -> (WriterEpoch, UInt64) {
        guard !closed else { throw StorageError.closed }
        let limit: UInt64
        switch protection { case .publicHash: limit = UInt64.max; case .encrypted: limit = 1 << 20 }
        if sequence >= limit { writer = try WriterEpoch(bytes: uuidBytes()); sequence = 0 }
        let address = (writer, sequence)
        sequence += 1
        return address
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
            self.countWork { $0.retainedLeafChecks += 1 }
            _ = try ObjectEnvelopeV1.open(row[1].bytes, collection: descriptor.collection, protection: protection,
                expectedLocator: SegmentLocator.decodeV1(row[0].bytes))
        }
    }
    func usableMaterialization(selection: LocalStoreSelection, session: UUID) throws -> CurrentMaterializationCheck {
        let view = try rows("SELECT through_seq FROM view_meta WHERE singleton=1")
        let through = try view.first?.first?.number
        let target = try acceptedThrough()
        if through == target {
            do { return try .current(snapshot(store: selection.store, session: session)) }
            catch is CanonicalEncodingError { }
            catch StorageError.integrity { }
        }
        if let through, through > 0, through < target {
            do {
                let context = try rows("SELECT authoring_context FROM view_meta WHERE singleton=1")
                _ = try AuthoringContextV1.decodeV1(context[0][0].bytes)
                let decoder = try CurrentRowRead()
                try each("SELECT birth,cell FROM current_notes") { row in
                    guard try decoder.decode(row[1].bytes, database: self).birth.bytes == row[0].bytes else { throw StorageError.integrity }
                }
                return .lagged
            }
            catch is CanonicalEncodingError { }
            catch StorageError.integrity { }
        }
        return .invalid
    }
    func snapshot(store: LocalStoreID, session: UUID) throws -> StoreSnapshot {
        try exec("BEGIN")
        do {
            let meta = try rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1")
            guard meta.count == 1, meta[0][1] == .integer(1) else { throw StorageError.incomplete }
            let through = try meta[0][2].number
            let accepted = try acceptedThrough()
            guard through > 0, through <= accepted else { throw StorageError.incomplete }
            guard accepted == through else { throw StorageError.staleCapture }
            let epoch = try meta[0][0].bytes
            guard epoch.count == 16 else { throw StorageError.integrity }
            let context = try AuthoringContextV1.decodeV1(meta[0][3].bytes)
            var cells: [CurrentNoteCellV1] = []
            let decoder = try CurrentRowRead()
            try each("SELECT birth,cell FROM current_notes ORDER BY rowid") { r in
                let cell = try decoder.decode(r[1].bytes, database: self)
                guard try cell.birth.bytes == r[0].bytes else { throw StorageError.integrity }
                cells.append(cell)
            }
            try exec("COMMIT")
            return StoreSnapshot(session: session, store: store, through: through, viewEpoch: epoch, notes: cells, context: context, presentationEpoch: presentationEpoch)
        } catch { try? exec("ROLLBACK"); throw error }
    }
    func presentedCell(_ cell: CurrentNoteCellV1, selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> CurrentNoteCellV1 {
        guard let pin = presentationPins[cell.birth] else { return cell }
        guard let reference = cell.heads.first(where: { $0.id == pin }), cell.automatic == nil else {
            presentationPins.removeValue(forKey: cell.birth); presentationEpoch = UUID(); return cell
        }
        return try checkingRetainedHistory {
            guard let op = try operation(pin, selection: selection, protection: protection),
                  op.effect.targetBirth == cell.birth, let value = op.effect.noteValue else { throw StorageError.integrity }
            return try CurrentNoteCellV1(birth: cell.birth, value: value, represented: [reference], heads: cell.heads,
                provenance: .revision, scopeFrontier: cell.scopeFrontier, identity: cell.identity)
        }
    }
    func presentedSnapshot(selection: LocalStoreSelection, protection: ObjectProtectionV1, session: UUID) throws -> StoreSnapshot {
        let snapshot = try snapshot(store: selection.store, session: session)
        let cells = try snapshot.notes.map { try presentedCell($0, selection: selection, protection: protection) }
        let absent = presentationPins.keys.filter { birth in !cells.contains(where: { $0.birth == birth }) }
        for birth in absent { presentationPins.removeValue(forKey: birth); presentationEpoch = UUID() }
        return StoreSnapshot(session: session, store: snapshot.store, through: snapshot.through, viewEpoch: snapshot.viewEpoch, notes: cells, context: snapshot.context, presentationEpoch: presentationEpoch)
    }
}

/// Returning startup carries its checked current capture through indexed recovery.
enum CurrentMaterializationCheck: Sendable { case current(StoreSnapshot), lagged, invalid }
