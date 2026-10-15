import Foundation
import Crypto
import NVStorageCore

/// Saved-history coverage and source-private pending buffers are reported independently.
public struct ActiveRepositoryCopy: Sendable {
    public let repository: RepositoryCopyResult
    public let through: Int64
    public let excludedPrivatePendingItems: Int
    public let completedCommits: [AcceptedHistoryReceipt]
    fileprivate init(repository: RepositoryCopyResult, through: Int64, pending: Int, receipts: [AcceptedHistoryReceipt]) {
        self.repository = repository; self.through = through; excludedPrivatePendingItems = pending; completedCommits = receipts
    }
}

/// Explicit fresh-history export chooses the new collection's protection independently of its source.
public enum CurrentExportProfile: Sendable {
    case passwordFree
    case encrypted(passphrase: String)
}

/// Fresh births identify a coherent current-value export with its separately usable private store.
public struct CurrentCollectionExport: Sendable {
    public let selection: LocalStoreSelection
    public let repository: RepositoryCopyResult
    public let births: [NoteBirth]
    fileprivate init(selection: LocalStoreSelection, repository: RepositoryCopyResult, births: [NoteBirth]) {
        self.selection = selection; self.repository = repository; self.births = births
    }
    /// The host freezes complete live values, including available unsaved text, before requesting this explicit export.
    public static func create(values: [PlaintextNoteValue], profile: CurrentExportProfile,
                              toRepository destination: String, privateDirectory: String) async throws -> Self {
        let collection = try CollectionID(bytes: uuidBytes()), births = try values.map { _ in try NoteBirth(bytes: uuidBytes()) }
        let protection: ObjectProtectionV1, passphrase: String?
        switch profile {
        case .passwordFree: protection = .publicHash; passphrase = nil
        case .encrypted(let text):
            protection = try .encrypted(keyID: CollectionKeyID(bytes: uuidBytes()), key: SymmetricKey(size: .bits256)); passphrase = text
        }
        let session = try await LocalStoreSession.create(directory: privateDirectory, collection: collection,
            notes: Array(zip(births, values)), protection: protection, passphrase: passphrase)
        do {
            let selection = session.selection, through = try await session.snapshot().through
            try await session.lane.perform { try $0.installUnlockDescriptor(selection.descriptor) }
            let history = try await session.captureRepositoryHistory(through: through)
            let copied = try await RepositoryCopyWorker().export(history, to: destination)
            guard copied.capturedInventoryComplete, copied.unmetRequirements.isEmpty else { throw StorageError.incomplete }
            try await session.verifyCompletePrivateState()
            try await session.quiesce()
            let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
            guard try await reopened.snapshot().notes.sorted(by: { $0.birth.bytes.lexicographicallyPrecedes($1.birth.bytes) }).map(\.value)
                == Array(zip(births, values)).sorted(by: { $0.0.bytes.lexicographicallyPrecedes($1.0.bytes) }).map(\.1) else {
                try await reopened.quiesce(); throw StorageError.integrity
            }
            try await reopened.quiesce()
            return Self(selection: selection, repository: copied, births: births)
        } catch { try? await session.quiesce(); throw error }
    }
}

extension LocalStoreSession {
    /// Checks the complete saved cut under the destination's newly acquired physical ownership.
    func verifyCopiedHistory(at root: RepositoryRootSession, through: Int64) async throws {
        let history = try await captureRepositoryHistory(through: through)
        let permission = try await root.permission()
        try await history.forEachBatch { objects in
            for object in objects {
                let observed = try await root.observe(object.locator.relativePath, using: permission)
                guard case .contents(let contents) = try await root.read(observed, maximumBytes: object.bytes.count, using: permission),
                      contents.bytes == object.bytes else { throw StorageError.integrity }
            }
        }
    }

    /// Drains owned admitted history, then preserves the captured repository plus this Mac's committed bytes.
    public func copyRepositoryAndSavedWork(from source: String, to destination: String) async throws -> ActiveRepositoryCopy {
        try await copyRepositoryAndSavedWork(source: .path(source), to: destination)
    }

    /// Captures saved work while borrowing the active collection's existing physical root owner.
    public func copyRepositoryAndSavedWork(from source: RepositoryRootSession, to destination: String) async throws -> ActiveRepositoryCopy {
        try await copyRepositoryAndSavedWork(source: .owned(source), to: destination)
    }

    /// The integrated owner supplies its available root while local-only recovery reports excluded repository extras.
    func copyRepositoryAndSavedWork(from source: RepositoryRootSession?, to destination: String,
        captured: (@Sendable (String) async -> Void)?,
        beforeInstall: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ActiveRepositoryCopy {
        try await copyRepositoryAndSavedWork(source: source.map(CopySource.owned) ?? .unavailable,
                                            to: destination, captured: captured, beforeInstall: beforeInstall)
    }

    private enum CopySource { case path(String), owned(RepositoryRootSession), unavailable }
    private func copyRepositoryAndSavedWork(source: CopySource, to destination: String,
        captured: (@Sendable (String) async -> Void)? = nil,
        beforeInstall: @escaping @Sendable (String) -> Void = { _ in }) async throws -> ActiveRepositoryCopy {
        guard !closed, !quiescing else { throw StorageError.closed }
        while inFlight || requiredReceiveInFlight || pendingPreparationInFlight {
            await withCheckedContinuation { drained.append($0) }
        }
        var receipts: [AcceptedHistoryReceipt] = []
        if let owned = commitState.owned {
            switch try await persist(capture: owned.capture) {
            case .accepted(let receipt): receipts.append(receipt)
            case .pending(_, let cause): throw cause
            }
        }
        let cut = try await snapshot(), history = try await captureRepositoryHistory(through: cut.through)
        let pending = try await lane.perform { db in
            try db.rows("SELECT COUNT(*) FROM pending_items WHERE latest IS NOT NULL OR EXISTS(SELECT 1 FROM pending_reservations r WHERE r.item_id=pending_items.item_id)")[0][0].number
        }
        let copied: RepositoryCopyResult
        switch source {
        case .path(let path):
            copied = try await RepositoryCopyWorker().copy(source: path, destination: destination, requirements: [], saved: history)
        case .owned(let root):
            copied = try await root.copyRepository(to: destination, saved: history, captured: captured, beforeInstall: beforeInstall)
        case .unavailable:
            copied = try await RepositoryCopyWorker().export(history, to: destination, unavailable: .incomplete)
        }
        return ActiveRepositoryCopy(repository: copied, through: cut.through, pending: Int(pending), receipts: receipts)
    }

    /// Captures checked durable Current; the host's live-value overload also supports explicit unsaved-text recovery.
    public func exportCurrentValues(profile: CurrentExportProfile, toRepository destination: String,
                                    privateDirectory: String) async throws -> CurrentCollectionExport {
        let values = try await snapshot().notes.map(\.value)
        return try await CurrentCollectionExport.create(values: values, profile: profile,
            toRepository: destination, privateDirectory: privateDirectory)
    }

}
