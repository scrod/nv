import Foundation
import NVStorageCore

/// A fresh store remains exclusively owned while its exact initial commitment is assembled.
public actor BootstrapCandidate {
    public let selection: LocalStoreSelection
    let lane: DatabaseLane
    private let protection: ObjectProtectionV1
    private var closed = false
    private var working = false

    private init(selection: LocalStoreSelection, lane: DatabaseLane, protection: ObjectProtectionV1) {
        self.selection = selection; self.lane = lane; self.protection = protection
    }
    /// Initializes a new candidate with optional selected root evidence.
    public static func create(selection: LocalStoreSelection, snapshot: SegmentLocator?,
                              protection: ObjectProtectionV1) async throws -> BootstrapCandidate {
        let lane = DatabaseLane()
        try await lane.open(directory: selection.directory, create: true,
            key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
        do {
            try await lane.perform { db in
                try db.initialize(store: selection.store, descriptor: selection.descriptor, snapshot: snapshot)
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false)
            }
            return BootstrapCandidate(selection: selection, lane: lane, protection: protection)
        } catch { await lane.close(); throw error }
    }
    /// Reopens positively identified construction state without changing its selected commitment.
    public static func resume(selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> BootstrapCandidate {
        let lane = DatabaseLane()
        try await lane.open(directory: selection.directory, create: false,
            key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
        do {
            try await lane.perform { try $0.validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false) }
            return BootstrapCandidate(selection: selection, lane: lane, protection: protection)
        } catch { await lane.close(); throw error }
    }
    /// Retains checked exact bytes independently of initial-history acceptance.
    public func retain(_ bytes: [UInt8]) async throws -> SegmentLocator {
        try reserve(); defer { working = false }
        let selection = selection, protection = protection
        let opened = try await lane.historyWork {
            try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
        }
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false)
            try db.transaction { try db.retainCandidate(bytes, opened: opened, ready: false) }
        }
        return opened.locator
    }
    /// Freezes the selected root, commits its complete history, and returns a normally reopened session.
    public func complete(snapshot: SegmentLocator) async throws -> LocalStoreSession {
        try reserve(); defer { working = false }
        let selection = selection, protection = protection
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false)
            if let stored = try db.stagedBootstrap() {
                guard stored == snapshot else { throw StorageError.wrongContext }
            } else {
                try db.transaction {
                    try db.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
                        [.blob(snapshot.encodedV1()), .blob(Array("bootstrap".utf8))])
                }
            }
        }
        _ = try await lane.acceptStoredBootstrap(snapshot, selection: selection, protection: protection)
        await lane.close(); closed = true
        return try await LocalStoreSession.open(selection: selection, protection: protection)
    }
    public func close() async throws {
        guard !working else { throw StorageError.busy }
        if !closed { closed = true; await lane.close() }
    }
    private func reserve() throws {
        guard !closed else { throw StorageError.closed }
        guard !working else { throw StorageError.busy }
        working = true
    }
}

/// Serial sealing on a dedicated worker keeps each output buffer owned until retention finishes.
private actor BootstrapProducer {
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.bootstrap", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    private var writer: InitialCollectionWriterV1
    init(writer: InitialCollectionWriterV1) { self.writer = writer }
    func next() throws -> InitialEnvelopeV1? { try writer.next() }
    func root() throws -> SegmentLocator {
        guard let snapshot = writer.snapshot else { throw StorageError.incomplete }; return snapshot
    }
}

extension LocalStoreSession {
    /// Streams frozen initial values into the candidate store before ordinary opening.
    static func createIncrementally(directory: String, collection: CollectionID, notes: [(NoteBirth, PlaintextNoteValue)],
                                    protection: ObjectProtectionV1, passphrase: String?) async throws -> LocalStoreSession {
        let worker = DatabaseLane()
        let writer = try await worker.historyWork {
            try InitialCollectionWriterV1(collection: collection, notes: notes, protection: protection, passphrase: passphrase)
        }
        let selection = try LocalStoreSelection(directory: directory, store: LocalStoreID(bytes: uuidBytes()), descriptor: writer.descriptor)
        let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: nil, protection: protection)
        let producer = BootstrapProducer(writer: writer)
        do {
            while let envelope = try await producer.next() { _ = try await candidate.retain(envelope.bytes) }
            return try await candidate.complete(snapshot: producer.root())
        } catch { try? await candidate.close(); throw error }
    }
}
