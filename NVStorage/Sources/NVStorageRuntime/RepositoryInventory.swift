import Foundation
import Crypto
import NVStorageCore

/// Resumes a bounded canonical-name check at one accepted history prefix.
struct RepositoryInventoryCursor: Sendable {
    fileprivate let store: LocalStoreID
    fileprivate let session: UUID
    fileprivate let through: Int64
    fileprivate let afterSequence: Int64
    fileprivate let afterObject: [UInt8]
    fileprivate init(store: LocalStoreID, session: UUID, through: Int64, afterSequence: Int64, afterObject: [UInt8]) {
        self.store = store; self.session = session; self.through = through
        self.afterSequence = afterSequence; self.afterObject = afterObject
    }
}

private enum RetainedRepositoryIdentity: Sendable {
    case descriptor([UInt8]), segment(SegmentLocator)
    var id: [UInt8] { switch self { case .descriptor(let id): id; case .segment(let locator): locator.segmentID.bytes } }
    var path: ImmutableRepositoryLocator {
        switch self { case .descriptor(let id): .descriptorID(id); case .segment(let locator): .segment(locator) }
    }
    var directory: RepositoryProtocolDirectory {
        switch self { case .descriptor: .keys; case .segment(let locator): .writer(locator.writerEpoch) }
    }
    var leaf: String { String(path.relativePath.split(separator: "/").last!) }
}

/// Accepted membership selects canonical names; ordinary repair separately verifies local bytes before installation.
struct RepositoryInventoryBatch: Sendable {
    let continuation: RepositoryInventoryCursor?
    fileprivate let context: RepositoryInventoryCursor
    fileprivate let entries: [RetainedRepositoryIdentity]
    fileprivate init(context: RepositoryInventoryCursor, entries: [RetainedRepositoryIdentity], continuation: RepositoryInventoryCursor?) {
        self.context = context; self.entries = entries; self.continuation = continuation
    }
}

/// Root-checked observations preserve the exact accepted-name scope that revealed missing or damaged evidence.
struct RepositoryInventoryCheck: Sendable {
    let failures: [RepositoryFileFailure]
    let checkedCount: Int
    let readCount: Int
    fileprivate let batch: RepositoryInventoryBatch
    fileprivate let permission: RepositoryRootPermission
    fileprivate init(batch: RepositoryInventoryBatch, permission: RepositoryRootPermission,
                     failures: [RepositoryFileFailure], reads: Int) {
        self.batch = batch; self.permission = permission; self.failures = failures
        checkedCount = batch.entries.count; readCount = reads
    }
}

/// Exact provider bytes matched an accepted immutable identity under their captured file observation.
struct VerifiedRepositoryObservation: Sendable {
    let store: LocalStoreID
    let session: UUID
    let hint: RepositoryObservationHint
    let object: SegmentID
    fileprivate init(context: RepositoryInventoryCursor, hint: RepositoryObservationHint, object: SegmentID) {
        store = context.store; session = context.session; self.hint = hint; self.object = object
    }
}

extension LocalStoreSession {
    func captureRepositoryInventory(continuing cursor: RepositoryInventoryCursor? = nil,
                                    through publishedThrough: Int64? = nil, limit: Int = 16) async throws -> RepositoryInventoryBatch {
        try checkDiscoveryTarget()
        guard limit > 0, limit <= 64 else { throw StorageError.limit }
        if let cursor { try checkRepositoryInventory(cursor) }
        let selection = selection, session = incarnation
        let through = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            let accepted = try db.acceptedThrough()
            let through = cursor?.through ?? publishedThrough ?? accepted
            guard through >= 0, through <= accepted else { throw StorageError.staleCapture }
            return through
        }
        if through == 0 {
            let context = RepositoryInventoryCursor(store: selection.store, session: session,
                through: 0, afterSequence: 0, afterObject: [])
            try checkRepositoryInventory(context)
            return .init(context: context, entries: [], continuation: nil)
        }
        let result = try await lane.verifying(.history(through)) {
            try await lane.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                return try db.checkingRetainedHistory {
                    let rows = try db.rows("""
                        SELECT a.seq,a.object_id,o.kind,o.writer_epoch,o.sequence FROM accepted_objects a
                        LEFT JOIN objects o USING(object_id) WHERE a.seq<=? AND (a.seq,a.object_id)>(?,?)
                        ORDER BY a.seq,a.object_id LIMIT ?
                        """, [.integer(through), .integer(cursor?.afterSequence ?? 0), .blob(cursor?.afterObject ?? []), .integer(Int64(limit + 1))])
                    var entries: [RetainedRepositoryIdentity] = []
                    for row in rows.prefix(limit) {
                        let id = try row[1].bytes
                        guard id.count == 32 else { throw StorageError.integrity }
                        if row[2] == .integer(0) { entries.append(.descriptor(id)) }
                        else {
                            guard let kind = UInt8(exactly: try row[2].number), ProviderObjectKind(rawValue: kind) != nil,
                                  try row[4].bytes.count == 8 else { throw StorageError.integrity }
                            entries.append(.segment(try .init(writerEpoch: .init(bytes: row[3].bytes),
                                sequence: row[4].bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }, segmentID: .init(bytes: id))))
                        }
                    }
                    let context = RepositoryInventoryCursor(store: selection.store, session: session, through: through,
                        afterSequence: cursor?.afterSequence ?? 0, afterObject: cursor?.afterObject ?? [])
                    let next: RepositoryInventoryCursor?
                    if rows.count > limit {
                        let last = rows[limit - 1]
                        next = .init(store: selection.store, session: session, through: through,
                            afterSequence: try last[0].number, afterObject: try last[1].bytes)
                    } else { next = nil }
                    return RepositoryInventoryBatch(context: context, entries: entries, continuation: next)
                }
            }
        }
        try checkRepositoryInventory(result.context)
        return result
    }

    fileprivate func checkRepositoryInventory(_ context: RepositoryInventoryCursor) throws {
        try checkDiscoveryTarget()
        guard context.store == selection.store, context.session == incarnation else { throw StorageError.wrongContext }
    }
}

extension RepositoryRootSession {
    func checkInventory(_ batch: RepositoryInventoryBatch, from store: LocalStoreSession,
                        observed: (@Sendable () async throws -> Void)? = nil) async throws -> RepositoryInventoryCheck {
        guard discoveryState == nil, !discoveryRunning else { throw RepositoryRootError.busy }
        let permission = try permission()
        try await store.checkRepositoryInventory(batch.context); try checkPermission(permission)
        var failures: [RepositoryFileFailure] = [], reads = 0
        var remaining = batch.entries
        while let first = remaining.first {
            let group = remaining.filter { $0.directory == first.directory }
            remaining.removeAll { $0.directory == first.directory }
            let metadata: [RepositoryMetadataEntry]
            do { metadata = try await inspectExpectedNames(group.map(\.leaf), in: first.directory, using: permission) }
            catch RepositoryRootError.unavailable(let code) {
                try checkPermission(permission); failures.append(.init(code: code)); continue
            }
            var readable: [(RetainedRepositoryIdentity, RepositoryEntryObservation, RepositoryObservationHint)] = []
            for (expected, entry) in zip(group, metadata) {
                switch entry.result {
                case .invalidName: throw RepositoryRootError.wrongContext
                case .unavailable(let failure): failures.append(failure == .sizeLimit ? .conflict : failure)
                case .observed(let observation):
                    guard observation.kind == .regularFile else { failures.append(.kindCollision); continue }
                    readable.append((expected, observation, try discoveryHint(observation, using: permission)))
                }
            }
            let hints = readable.map { $0.2 }
            let lookup = try await store.knownDiscoveryHints(hints, permission: permission)
            let answers = try await validateDiscoveryHints(lookup, hints: hints, for: store)
            try await observed?(); try checkPermission(permission)
            for ((expected, observation, hint), answer) in zip(readable, answers) {
                try Task.checkCancellation()
                if case .accepted(let id) = answer, id.bytes == expected.id { continue }
                switch try await read(observation, maximumBytes: Int(ObjectLimitsV1.encodedPayloadBytes + 156), using: permission) {
                case .unavailable(let failure): failures.append(failure == .sizeLimit ? .conflict : failure)
                case .contents(let content):
                    reads += 1
                    let hash = try await store.lane.historyWork { Array(SHA256.hash(data: content.bytes)) }
                    try checkPermission(permission)
                    guard hash == expected.id else { failures.append(.conflict); continue }
                    try await store.rememberInventoryHint(.init(context: batch.context, hint: hint, object: SegmentID(bytes: expected.id)))
                }
            }
        }
        try Task.checkCancellation(); try await store.checkRepositoryInventory(batch.context); try checkPermission(permission)
        return .init(batch: batch, permission: permission, failures: failures, reads: reads)
    }

    func validate(_ check: RepositoryInventoryCheck, for store: LocalStoreSession) async throws {
        try checkPermission(check.permission)
        try await store.checkRepositoryInventory(check.batch.context)
        try checkPermission(check.permission)
    }
}
