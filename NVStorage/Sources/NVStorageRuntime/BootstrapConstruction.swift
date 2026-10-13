import Foundation
import NVStorageCore

/// Complete displayed values from a selected protected snapshot, suitable for read-only recovery.
public struct BootstrapReadOnlyPreview: Sendable {
    public let collection: CollectionID
    public let snapshot: SegmentLocator
    public let notes: [Note]
    public struct Note: Equatable, Sendable {
        public let birth: NoteBirth
        public let value: PlaintextNoteValue
        fileprivate init(birth: NoteBirth, value: PlaintextNoteValue) { self.birth = birth; self.value = value }
    }
    fileprivate init(collection: CollectionID, snapshot: SegmentLocator, notes: [Note]) {
        self.collection = collection; self.snapshot = snapshot; self.notes = notes
    }
}

/// Page decoding and digest work run on a dedicated resource while named inputs arrive separately.
private actor BootstrapPreviewReader {
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.bootstrap-preview", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    func read(snapshot: SegmentLocator, collection: CollectionID, protection: ObjectProtectionV1,
              read: @escaping @Sendable (SegmentLocator) async throws -> [UInt8]?) async throws -> BootstrapReadOnlyPreview {
        guard let bytes = try await read(snapshot) else { throw GeneralSnapshotError.missingObject(snapshot) }
        let opened = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: snapshot)
        var notes: [BootstrapReadOnlyPreview.Note] = []
        switch try ReceivedPayload(opened) {
        case .root(let root):
            var hasher = InitialValuesHasherV1(expectedCount: root.initialCount)
            var last: NoteBirth?
            for ref in root.pages {
                try Task.checkCancellation()
                guard let bytes = try await read(ref.locator) else { throw GeneralSnapshotError.missingObject(ref.locator) }
                let object = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: ref.locator)
                guard object.kind == .snapshotPage else { throw CanonicalEncodingError.invalidReference }
                let page = try InitialSnapshotPageV1.decodeV1(object.payload)
                guard page.importID == root.importID, page.index == ref.index, page.rows.count == Int(ref.rowCount) else {
                    throw InitialBootstrapValidationError.invalidSnapshot
                }
                for row in page.rows {
                    guard last.map({ $0.bytes.lexicographicallyPrecedes(row.birth.bytes) }) ?? true else { throw CanonicalEncodingError.noncanonicalSet }
                    try hasher.append(birth: row.birth, value: row.value)
                    notes.append(.init(birth: row.birth, value: row.value)); last = row.birth
                }
            }
            guard try hasher.finish() == root.digest else { throw InitialBootstrapValidationError.invalidSnapshot }
        case .generalRoot:
            let preview = try await GeneralSnapshotPreviewV1.read(snapshot: snapshot, collection: collection, protection: protection,
                read: { locator in locator == snapshot ? bytes : try await read(locator) })
            var deleted: Set<NoteBirth> = []
            for record in preview.records {
                switch record {
                case .current(let cell): notes.append(.init(birth: cell.birth, value: cell.value))
                case .deleted(let birth, _): deleted.insert(birth)
                case .frontier, .scope, .retired, .disposition, .restored: break
                }
            }
            guard Set(notes.map(\.birth)).count == notes.count, Set(notes.map(\.birth)).isDisjoint(with: deleted) else {
                throw GeneralSnapshotError.invalidState
            }
        case .changes, .page, .generalPage: throw CanonicalEncodingError.invalidReference
        }
        return .init(collection: collection, snapshot: snapshot, notes: notes)
    }
}

/// A fresh store remains exclusively owned while its exact initial commitment is assembled.
public actor BootstrapCandidate {
    public let selection: LocalStoreSelection
    let lane: DatabaseLane
    private let protection: ObjectProtectionV1
    private var closed = false
    private var working = false
    private var committedSnapshot: SegmentLocator?

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
        try await retainWithIdentity(bytes).locator
    }
    /// Supplies the decoded kind to a discovery consumer after exact-byte retention.
    func retainWithIdentity(_ bytes: [UInt8], ready: Bool = false) async throws -> (locator: SegmentLocator, kind: ProviderObjectKind) {
        try reserve(); defer { working = false }
        let selection = selection, protection = protection
        let opened = try await lane.historyWork {
            try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
        }
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false)
            try db.transaction { try db.retainCandidate(bytes, opened: opened, ready: ready) }
        }
        return (opened.locator, opened.kind)
    }
    func checkDiscoveryTarget() throws { guard !closed else { throw StorageError.closed } }
    /// Presents every selected snapshot value after complete page/count/digest validation.
    public func preview(snapshot: SegmentLocator) async throws -> BootstrapReadOnlyPreview {
        try reserve(); defer { working = false }
        let selection = selection, protection = protection, lane = lane
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor, requireBootstrap: false)
            if let selected = try db.stagedBootstrap(), selected != snapshot { throw StorageError.wrongContext }
        }
        return try await BootstrapPreviewReader().read(snapshot: snapshot, collection: selection.descriptor.collection,
            protection: protection, read: { locator in
                try await lane.perform { try $0.snapshotCandidate(locator, collection: selection.descriptor.collection, protection: protection) }
            })
    }
    /// Freezes the selected root, commits its complete history, and returns a normally reopened session.
    public func complete(snapshot: SegmentLocator) async throws -> LocalStoreSession {
        try await complete(snapshot: snapshot, beforeReopen: nil)
    }
    func complete(snapshot: SegmentLocator, beforeReopen: (@Sendable () async throws -> Void)?) async throws -> LocalStoreSession {
        if closed {
            guard committedSnapshot == snapshot else { throw StorageError.closed }
            guard !working else { throw StorageError.busy }
            working = true; defer { working = false }
            return try await LocalStoreSession.open(selection: selection, protection: protection)
        }
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
        committedSnapshot = snapshot
        await lane.close(); closed = true
        try await beforeReopen?()
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
