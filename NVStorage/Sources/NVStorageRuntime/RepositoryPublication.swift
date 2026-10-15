import Foundation
import Crypto
import NVStorageCore

/// Resumes indexed selection at a frozen prefix, or starts the next pass after a completed prefix.
public struct RepositoryPublicationCursor: Sendable {
    /// Complete acceptance batches already passed by the publication cursor.
    var inventoryThrough: Int64 { through == nil ? afterSequence : max(0, afterSequence - 1) }
    fileprivate let store: LocalStoreID
    fileprivate let session: UUID
    fileprivate let through: Int64?
    fileprivate let afterSequence: Int64
    fileprivate let afterObject: [UInt8]
    fileprivate init(store: LocalStoreID, session: UUID, through: Int64?, afterSequence: Int64, afterObject: [UInt8]) {
        self.store = store; self.session = session; self.through = through
        self.afterSequence = afterSequence; self.afterObject = afterObject
    }
}

/// Exact accepted bytes selected in a bounded turn from a complete retained history prefix.
public struct RepositoryPublicationBatch: Sendable {
    public let through: Int64
    public let continuation: RepositoryPublicationCursor?
    /// Starts a later accepted prefix after every batch in this pass has been handed off successfully.
    public var nextPass: RepositoryPublicationCursor? {
        continuation == nil ? RepositoryPublicationCursor(store: store, session: session, through: nil,
            afterSequence: through, afterObject: Array(repeating: 255, count: 32)) : nil
    }
    public var locators: [ImmutableRepositoryLocator] { objects.map(\.locator) }
    public var encodedByteCount: Int { objects.reduce(0) { $0 + $1.bytes.count } }
    fileprivate let store: LocalStoreID
    fileprivate let session: UUID
    fileprivate let descriptor: BootstrapDescriptorV1
    fileprivate let objects: [ImmutableRepositoryObject]
    fileprivate init(store: LocalStoreID, session: UUID, descriptor: BootstrapDescriptorV1, through: Int64,
                     objects: [ImmutableRepositoryObject], continuation: RepositoryPublicationCursor?) {
        self.store = store; self.session = session; self.descriptor = descriptor; self.through = through
        self.objects = objects; self.continuation = continuation
    }
}

/// Physical installations checked against their original accepted capture and live root.
public struct PublishedRepositoryBatch: Sendable {
    public var locators: [ImmutableRepositoryLocator] { batch.locators }
    public var through: Int64 { batch.through }
    fileprivate let batch: RepositoryPublicationBatch
    fileprivate let installed: [ImmutableInstallation]
    fileprivate init(batch: RepositoryPublicationBatch, installed: [ImmutableInstallation]) {
        self.batch = batch; self.installed = installed
    }
}

/// A failed installation retains completed effects separately from its exact retry input.
public enum RepositoryPublicationResult: Sendable {
    case complete(PublishedRepositoryBatch)
    case incomplete(installed: [ImmutableInstallation], failure: RepositoryInstallationFailure)
}

/// A complete checked prefix supplies the fixed inventory for an automatic repair attempt.
struct CheckedRepositoryRepair: Sendable {
    let through: Int64
    let objectCount: Int
    fileprivate let beginning: RepositoryPublicationCursor
    fileprivate init(through: Int64, objectCount: Int, beginning: RepositoryPublicationCursor) {
        self.through = through; self.objectCount = objectCount; self.beginning = beginning
    }
}

/// Frozen canonical names and hashes bind bounded rereads to one checked saved-history cut.
struct CapturedRepositoryHistory: Sendable {
    let through: Int64
    let requirements: [RepositoryByteRequirement]
    fileprivate let source: LocalStoreSession
    fileprivate let beginning: RepositoryPublicationCursor
    fileprivate init(source: LocalStoreSession, beginning: RepositoryPublicationCursor,
                     through: Int64, requirements: [RepositoryByteRequirement]) {
        self.source = source; self.beginning = beginning; self.through = through; self.requirements = requirements
    }

    /// Reuses the publication reader's byte/object budgets and keeps verification pending through consumption.
    func forEachBatch(isolation: isolated (any Actor)? = #isolation,
                      _ consume: ([ImmutableRepositoryObject]) async throws -> Void) async throws {
        let lane = source.lane
        try await lane.verifying(.history(through), isolation: isolation) {
            let expected = Dictionary(requirements.map { ($0.path, $0.sha256) }, uniquingKeysWith: { first, _ in first })
            var cursor: RepositoryPublicationCursor? = beginning, seen = Set<String>()
            repeat {
                try Task.checkCancellation()
                let batch = try await source.captureRepositoryPublication(continuing: cursor)
                let entries = batch.objects.map { ($0.locator.relativePath, Array(SHA256.hash(data: $0.bytes))) }
                try await lane.perform { db in
                    try db.checkingRetainedHistory {
                        guard batch.through == through,
                              entries.allSatisfy({ expected[$0.0] == $0.1 }) else { throw StorageError.integrity }
                    }
                }
                seen.formUnion(entries.map(\.0))
                try await consume(batch.objects)
                cursor = batch.continuation
            } while cursor != nil
            let complete = seen.count == expected.count
            try await lane.perform { db in
                try db.checkingRetainedHistory { guard complete else { throw StorageError.incomplete } }
            }
        }
    }
}

extension LocalStoreSession {
    /// Preflights the fixed cut in bounded batches; the retained capture contains inventory metadata.
    func captureRepositoryHistory(through: Int64) async throws -> CapturedRepositoryHistory {
        let beginning = RepositoryPublicationCursor(store: selection.store, session: incarnation,
            through: through, afterSequence: 0, afterObject: [])
        return try await lane.verifying(.history(through)) {
            var cursor: RepositoryPublicationCursor? = beginning, requirements: [RepositoryByteRequirement] = []
            repeat {
                try Task.checkCancellation()
                let batch = try await captureRepositoryPublication(continuing: cursor)
                requirements += try batch.objects.map {
                    try RepositoryByteRequirement(path: $0.locator.relativePath, sha256: Array(SHA256.hash(data: $0.bytes)))
                }
                cursor = batch.continuation
            } while cursor != nil
            return CapturedRepositoryHistory(source: self, beginning: beginning, through: through, requirements: requirements)
        }
    }

    /// Checks every accepted object before repair begins, retaining only a bounded batch at a time.
    func prepareRepositoryRepair(maximumObjects: Int = 16) async throws -> CheckedRepositoryRepair {
        var batch = try await captureRepositoryPublication(maximumObjects: maximumObjects)
        let beginning = RepositoryPublicationCursor(store: batch.store, session: batch.session,
            through: batch.through, afterSequence: 0, afterObject: [])
        var count = batch.locators.count
        while let cursor = batch.continuation {
            try Task.checkCancellation()
            batch = try await captureRepositoryPublication(continuing: cursor, maximumObjects: maximumObjects)
            count += batch.locators.count
        }
        try Task.checkCancellation()
        try await checkPublication(batch)
        return CheckedRepositoryRepair(through: batch.through, objectCount: count, beginning: beginning)
    }

    /// Re-reads exact repair bytes at the checked prefix while newer accepted work remains independent.
    func captureRepositoryRepair(_ repair: CheckedRepositoryRepair,
                                 continuing cursor: RepositoryPublicationCursor? = nil,
                                 maximumObjects: Int = 16) async throws -> RepositoryPublicationBatch {
        guard repair.beginning.store == selection.store, repair.beginning.session == incarnation else {
            throw StorageError.wrongContext
        }
        if let cursor {
            guard cursor.through == repair.through else { throw StorageError.wrongContext }
        }
        return try await captureRepositoryPublication(continuing: cursor ?? repair.beginning, maximumObjects: maximumObjects)
    }

    /// Selects accepted objects by private sequence and identity, releasing every SQL turn before transport.
    /// One oversized object advances a byte-budgeted turn within the existing envelope ceiling.
    public func captureRepositoryPublication(continuing cursor: RepositoryPublicationCursor? = nil,
                                            maximumObjects: Int = 16, byteBudget: Int = 4 * 1024 * 1024) async throws -> RepositoryPublicationBatch {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard maximumObjects > 0, maximumObjects <= 64, byteBudget > 0,
              UInt64(byteBudget) <= ObjectLimitsV1.encodedPayloadBytes + 156 else { throw StorageError.limit }
        if let cursor {
            guard cursor.store == selection.store, cursor.session == incarnation else { throw StorageError.wrongContext }
        }
        let selection = selection, protection = protection, session = incarnation
        let through = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            let accepted = try db.acceptedThrough()
            if let cut = cursor?.through, cut > accepted { throw StorageError.staleCapture }
            if let cursor, cursor.afterSequence > accepted { throw StorageError.staleCapture }
            return cursor?.through ?? accepted
        }
        let batch = try await lane.verifying(.history(through)) {
            try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                return try db.checkingRetainedHistory {
                    guard try db.rows("SELECT o.encoded FROM retained_descriptors r JOIN accepted_objects a USING(object_id) LEFT JOIN objects o USING(object_id) WHERE r.object_id=? AND a.seq<=?",
                        [.blob(selection.descriptor.descriptorID), .integer(through)]) == [[.blob(selection.descriptor.encodedBytes)]] else { throw StorageError.incomplete }
                    let rows = try db.rows("SELECT a.seq,a.object_id,length(o.encoded) FROM accepted_objects a LEFT JOIN objects o USING(object_id) WHERE a.seq<=? AND (a.seq,a.object_id)>(?,?) ORDER BY a.seq,a.object_id LIMIT ?",
                        [.integer(through), .integer(cursor?.afterSequence ?? 0), .blob(cursor?.afterObject ?? []), .integer(Int64(maximumObjects + 1))])
                    var objects: [ImmutableRepositoryObject] = [], size = 0, last: [SQLValue]?
                    for row in rows {
                        let length = try row[2].number
                        guard length > 0, UInt64(length) <= ObjectLimitsV1.encodedPayloadBytes + 156 else { throw StorageError.integrity }
                        if objects.count == maximumObjects || (!objects.isEmpty && length > byteBudget - size) { break }
                        let id = try row[1].bytes
                        guard try db.rows("SELECT 1 FROM accepted_dependencies d LEFT JOIN accepted_objects p ON p.object_id=d.prerequisite WHERE d.child=? AND (p.seq IS NULL OR p.seq>?) LIMIT 1",
                            [.blob(id), .integer(through)]).isEmpty else { throw StorageError.incomplete }
                        guard let stored = try db.rows("SELECT kind,writer_epoch,sequence,encoded FROM objects WHERE object_id=?", [.blob(id)]).first else { throw StorageError.incomplete }
                        let bytes = try stored[3].bytes, object: ImmutableRepositoryObject
                        db.countWork { $0.historyReads += 1; $0.historyEncodedBytes += bytes.count }
                        if stored[0] == .integer(0) {
                            let descriptor = try BootstrapDescriptorV1.decodeV1(bytes)
                            guard descriptor.descriptorID == id, descriptor.genesis == selection.descriptor.genesis else { throw StorageError.integrity }
                            object = try .descriptor(descriptor, collection: selection.descriptor.collection, keyID: selection.descriptor.keyID)
                        } else {
                            guard try stored[2].bytes.count == 8 else { throw StorageError.integrity }
                            let locator = try SegmentLocator(writerEpoch: WriterEpoch(bytes: stored[1].bytes),
                                sequence: stored[2].bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }, segmentID: SegmentID(bytes: id))
                            object = try .envelope(bytes, locator: locator, collection: selection.descriptor.collection, protection: protection)
                            db.countWork { $0.envelopeDecodes += 1 }
                            guard bytes.count > 10, stored[0] == .integer(Int64(bytes[10])) else { throw StorageError.integrity }
                        }
                        objects.append(object); size += bytes.count; last = row
                    }
                    let next: RepositoryPublicationCursor?
                    if let last, objects.count < rows.count {
                        next = try RepositoryPublicationCursor(store: selection.store, session: session, through: through,
                            afterSequence: last[0].number, afterObject: last[1].bytes)
                    } else { next = nil }
                    db.countWork {
                        $0.publicationBatches += 1
                        $0.largestPublicationObjects = max($0.largestPublicationObjects, objects.count)
                        $0.largestPublicationBytes = max($0.largestPublicationBytes, size)
                    }
                    return RepositoryPublicationBatch(store: selection.store, session: session, descriptor: selection.descriptor,
                        through: through, objects: objects, continuation: next)
                }
            }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
        return batch
    }

    fileprivate func checkPublication(_ batch: RepositoryPublicationBatch) async throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard batch.store == selection.store, batch.session == incarnation,
              batch.descriptor.encodedBytes == selection.descriptor.encodedBytes else { throw StorageError.wrongContext }
        let selection = selection
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard try db.acceptedThrough() >= batch.through else { throw StorageError.staleCapture }
        }
        guard !closed, !quiescing else { throw StorageError.closed }
    }
}

extension RepositoryRootSession {
    /// Installs a checked accepted batch through the existing exact-byte physical boundary.
    /// Interrupted callers retain the immutable batch for retry, including effects with lost completion.
    public func publish(_ batch: RepositoryPublicationBatch, from source: LocalStoreSession,
                        using permission: RepositoryRootPermission) async throws -> RepositoryPublicationResult {
        try await publish(batch, from: source, using: permission, beforeInstall: { _ in })
    }

    func publish(_ batch: RepositoryPublicationBatch, from source: LocalStoreSession,
                 using permission: RepositoryRootPermission,
                 beforeInstall: @escaping @Sendable (ImmutableRepositoryObject) -> Void) async throws -> RepositoryPublicationResult {
        try checkPermission(permission)
        try await source.checkPublication(batch)
        var installed: [ImmutableInstallation] = []
        for object in batch.objects {
            try await source.checkPublication(batch)
            switch try await install(object, for: batch.descriptor, using: permission,
                                     beforeInstall: { beforeInstall(object) }, afterInstall: {}) {
            case .verified(let evidence):
                try validate(evidence, for: object, using: permission)
                installed.append(evidence)
            case .notInstalled(let failure), .uncertain(let failure):
                return .incomplete(installed: installed, failure: failure)
            }
        }
        try await source.checkPublication(batch)
        try checkPermission(permission)
        return .complete(PublishedRepositoryBatch(batch: batch, installed: installed))
    }

    /// Rechecks both issuers before a consumer uses completed physical publication evidence.
    public func validate(_ published: PublishedRepositoryBatch, from source: LocalStoreSession,
                         using permission: RepositoryRootPermission) async throws {
        try checkPermission(permission)
        try await source.checkPublication(published.batch)
        guard published.installed.count == published.batch.objects.count else { throw RepositoryRootError.wrongContext }
        for (evidence, object) in zip(published.installed, published.batch.objects) {
            try validate(evidence, for: object, using: permission)
        }
        try checkPermission(permission)
    }
}
