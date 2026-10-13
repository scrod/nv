import Foundation
import NVStorageCore

/// Creation carries the caller's explicit destination intent through exclusive namespace acquisition.
public enum CollectionCreationIntent: Sendable { case createInExistingDirectory, createNewDirectory }

extension CollectionSession {
    /// Creates a complete private collection and an add-only initial repository under explicit intent.
    public static func create(repository: URL, intent: CollectionCreationIntent, privateDirectory: String,
                              collection: CollectionID, notes: [(NoteBirth, PlaintextNoteValue)],
                              protection: ObjectProtectionV1, passphrase: String? = nil) async throws -> CollectionSession {
        let root: RepositoryRootSession
        switch intent {
        case .createInExistingDirectory: root = try await .open(directory: repository)
        case .createNewDirectory: root = try await .create(directory: repository)
        }
        var local: LocalStoreSession?
        do {
            try await root.createRepositoryNamespace()
            let store = try await LocalStoreSession.create(directory: privateDirectory, collection: collection,
                notes: notes, protection: protection, passphrase: passphrase)
            local = store
            let descriptor = store.selection.descriptor
            let object = try ImmutableRepositoryObject.descriptor(descriptor, collection: collection, keyID: descriptor.keyID)
            guard case .verified = try await root.install(object, for: descriptor, using: root.permission()) else { throw StorageError.incomplete }
            return try await bindFresh(store, root: root)
        } catch {
            try? await local?.quiesce()
            await root.close()
            throw error
        }
    }

}

private enum BootstrapEntryPhase: Sendable {
    case assembling(BootstrapCandidate), binding(LocalStoreSession), completed, closed
}

/// Owns one explicitly selected bootstrap and its partial inputs through preview, completion or retry.
public actor CollectionBootstrapSession {
    public let selection: LocalStoreSelection
    public let snapshot: SegmentLocator
    private let root: RepositoryRootSession
    private var phase: BootstrapEntryPhase
    private var working = false

    private init(candidate: BootstrapCandidate, root: RepositoryRootSession, snapshot: SegmentLocator) {
        selection = candidate.selection; self.snapshot = snapshot; self.root = root
        phase = .assembling(candidate)
    }

    /// Starts fresh private construction after explicit descriptor/root/unlock selection.
    public static func open(repository: URL, privateDirectory: String, descriptor: BootstrapDescriptorV1,
                            snapshot: SegmentLocator, protection: ObjectProtectionV1) async throws -> CollectionBootstrapSession {
        let selection = try LocalStoreSelection(directory: privateDirectory, store: .init(bytes: uuidBytes()), descriptor: descriptor)
        return try await acquire(repository: repository, selection: selection, snapshot: snapshot, protection: protection, resuming: false)
    }
    /// Reuses the same durable commitment after interrupted construction.
    public static func resume(repository: URL, selection: LocalStoreSelection, snapshot: SegmentLocator,
                              protection: ObjectProtectionV1) async throws -> CollectionBootstrapSession {
        try await acquire(repository: repository, selection: selection, snapshot: snapshot, protection: protection, resuming: true)
    }
    private static func acquire(repository: URL, selection: LocalStoreSelection, snapshot: SegmentLocator,
                                protection: ObjectProtectionV1, resuming: Bool) async throws -> CollectionBootstrapSession {
        let root = try await RepositoryRootSession.open(directory: repository)
        do {
            let permission = try await root.permission()
            let path = ImmutableRepositoryLocator.descriptor(selection.descriptor).relativePath
            let entry = try await root.observe(path, using: permission)
            guard case .contents(let contents) = try await root.read(entry, maximumBytes: 16384, using: permission),
                  contents.bytes == selection.descriptor.encodedBytes else { throw StorageError.wrongContext }
            let candidate = try await resuming ? BootstrapCandidate.resume(selection: selection, protection: protection)
                : BootstrapCandidate.create(selection: selection, snapshot: snapshot, protection: protection)
            return .init(candidate: candidate, root: root, snapshot: snapshot)
        } catch { await root.close(); throw error }
    }
    public func discover(budget: Int = 16) async throws -> RepositoryDiscoveryTurn {
        try reserve(); defer { working = false }
        guard case .assembling(let candidate) = phase else { throw StorageError.closed }
        return try await root.discover(into: candidate, opportunity: .backgroundTurn, budget: budget)
    }
    public func preview() async throws -> BootstrapReadOnlyPreview {
        try reserve(); defer { working = false }
        guard case .assembling(let candidate) = phase else { throw StorageError.closed }
        return try await candidate.preview(snapshot: snapshot)
    }
    /// Complete durable import and normal reopening precede association and any editable capability.
    public func complete() async throws -> CollectionSession {
        try reserve(); defer { working = false }
        let store: LocalStoreSession
        switch phase {
        case .assembling(let candidate):
            store = try await candidate.complete(snapshot: snapshot)
            phase = .binding(store)
        case .binding(let owned): store = owned
        case .completed, .closed: throw StorageError.closed
        }
        let owner = try await CollectionSession.bindFresh(store, root: root)
        phase = .completed
        return owner
    }
    public func close() async throws {
        guard !working else { throw StorageError.busy }
        switch phase {
        case .assembling(let candidate): try await candidate.close()
        case .binding(let store): try await store.quiesce()
        case .completed, .closed: return
        }
        await root.close(); phase = .closed
    }
    private func reserve() throws {
        guard !working else { throw StorageError.busy }
        switch phase { case .completed, .closed: throw StorageError.closed; case .assembling, .binding: working = true }
    }
}
