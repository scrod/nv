import Foundation
import Crypto
import NVStorageCore

/// One exact accepted envelope/descriptor and its canonical add-only repository name.
struct CapturedRepositoryObject: Sendable {
    let path: String
    let bytes: [UInt8]
    let requirement: RepositoryByteRequirement
    var sha256: [UInt8] { requirement.sha256 }
    fileprivate init(path: String, bytes: [UInt8]) throws {
        self.path = path; self.bytes = bytes
        requirement = try RepositoryByteRequirement(path: path, sha256: Array(SHA256.hash(data: bytes)))
    }
}

/// The committing source issues a dependency-closed exact-byte capture at one private prefix.
struct CapturedRepositoryHistory: Sendable {
    let through: Int64
    let objects: [CapturedRepositoryObject]
    var requirements: [RepositoryByteRequirement] { objects.map(\.requirement) }
    fileprivate init(through: Int64, objects: [CapturedRepositoryObject]) { self.through = through; self.objects = objects }
}

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
    /// Drains owned admitted history, then preserves the captured repository plus this Mac's committed bytes.
    public func copyRepositoryAndSavedWork(from source: String, to destination: String) async throws -> ActiveRepositoryCopy {
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
        let copied = try await RepositoryCopyWorker().copy(source: source, destination: destination,
            requirements: [], saved: history)
        return ActiveRepositoryCopy(repository: copied, through: cut.through, pending: Int(pending), receipts: receipts)
    }

    /// Captures checked durable Current; the host's live-value overload also supports explicit unsaved-text recovery.
    public func exportCurrentValues(profile: CurrentExportProfile, toRepository destination: String,
                                    privateDirectory: String) async throws -> CurrentCollectionExport {
        let values = try await snapshot().notes.map(\.value)
        return try await CurrentCollectionExport.create(values: values, profile: profile,
            toRepository: destination, privateDirectory: privateDirectory)
    }

    fileprivate func captureRepositoryHistory(through: Int64) async throws -> CapturedRepositoryHistory {
        let selection = selection, protection = protection
        return try await lane.verifyingHistory {
            let ids = try await lane.perform { db in
                guard try db.acceptedThrough() >= through else { throw StorageError.staleCapture }
                guard try db.rows("SELECT 1 FROM accepted_dependencies d JOIN accepted_objects c ON c.object_id=d.child LEFT JOIN accepted_objects p ON p.object_id=d.prerequisite WHERE c.seq<=? AND (p.seq IS NULL OR p.seq>?) LIMIT 1", [.integer(through), .integer(through)]).isEmpty else { throw StorageError.incomplete }
                return try db.rows("SELECT object_id FROM accepted_objects WHERE seq<=? ORDER BY object_id", [.integer(through)])
            }
            var captured: [CapturedRepositoryObject] = []
            for row in ids {
                let object = try await lane.perform { db in
                    try db.checkingRetainedHistory {
                        guard let r = try db.rows("SELECT kind,writer_epoch,sequence,encoded FROM objects WHERE object_id=?", [row[0]]).first else { throw StorageError.incomplete }
                        let bytes = try r[3].bytes, id = try row[0].bytes, path: String
                        if r[0] == .integer(0) {
                            let d = try BootstrapDescriptorV1.decodeV1(bytes)
                            guard d.collection == selection.descriptor.collection, d.genesis == selection.descriptor.genesis,
                                  d.keyID == selection.descriptor.keyID, d.descriptorID == id else { throw StorageError.integrity }
                            path = "NV Data/v1/keys/" + lowercaseHex(d.descriptorID) + ".nvkey"
                        } else {
                            let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
                            let l = opened.locator
                            guard l.segmentID.bytes == id, r[0] == .integer(Int64(opened.kind.rawValue)),
                                  r[1] == .blob(l.writerEpoch.bytes), r[2] == .blob(Array(l.encodedV1()[16..<24])) else { throw StorageError.integrity }
                            let sequence = String(l.sequence)
                            path = "NV Data/v1/segments/" + lowercaseHex(l.writerEpoch.bytes) + "/"
                                + String(repeating: "0", count: 20 - sequence.count) + sequence + "-" + lowercaseHex(l.segmentID.bytes) + ".nvseg"
                        }
                        return try CapturedRepositoryObject(path: path, bytes: bytes)
                    }
                }
                captured.append(object)
            }
            return CapturedRepositoryHistory(through: through, objects: captured)
        }
    }
}

private func lowercaseHex(_ bytes: [UInt8]) -> String {
    let digits = Array("0123456789abcdef".utf8)
    return String(decoding: bytes.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
}
