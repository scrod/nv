import Foundation
import Crypto
import NVStorageCore

/// Ordinary transport opportunities revisit the namespace independently of presenter hints.
public enum RepositoryDiscoveryOpportunity: Sendable {
    case initialOpen, foreground, saveSettled, refresh, backgroundTurn
}

/// Separates observed descriptors, accepted history, retained candidates and inaccessible input.
public enum RepositoryDiscoveryOutcome: Sendable {
    case descriptor(BootstrapDescriptorV1)
    case received(SegmentLocator, ProviderObjectKind, ObjectAcceptanceOutcome)
    case unchangedAccepted(SegmentID)
    case rejected(ReceiveRejection)
    case invalid(CanonicalEncodingError)
    case unavailable(RepositoryFileFailure)
    case ignored
}

public struct RepositoryDiscoveryEntry: Sendable {
    public let relativePath: String
    public let outcome: RepositoryDiscoveryOutcome
    fileprivate init(_ path: String, _ outcome: RepositoryDiscoveryOutcome) { relativePath = path; self.outcome = outcome }
}

/// Binds discovery to one selected store and its live session or construction connection.
fileprivate enum RepositoryDiscoveryOwner: Equatable, Sendable {
    case store(LocalStoreID, session: UUID)
    case bootstrap(LocalStoreID, connection: UUID)
}

/// One bounded local pass turn; later opportunities always remain eligible to start another pass.
public struct RepositoryDiscoveryTurn: Sendable {
    public let entries: [RepositoryDiscoveryEntry]
    public let passEnded: Bool
    public let capturedInvalidation: UInt64
    public let latestInvalidation: UInt64
    fileprivate let permission: RepositoryRootPermission
    fileprivate let target: RepositoryDiscoveryOwner
    fileprivate init(entries: [RepositoryDiscoveryEntry], passEnded: Bool, captured: UInt64, latest: UInt64,
                     permission: RepositoryRootPermission, target: RepositoryDiscoveryOwner) {
        self.entries = entries; self.passEnded = passEnded; capturedInvalidation = captured; latestInvalidation = latest
        self.permission = permission; self.target = target
    }
}

struct RepositoryDiscoveryState: Sendable {
    struct Frame: Sendable {
        let directory: RepositoryProtocolDirectory
        var cursor: RepositoryListingCursor?
        var names: [RepositoryDiscoveredLeaf] = []
        var ended = false
    }
    let permission: RepositoryRootPermission
    fileprivate let target: RepositoryDiscoveryOwner
    let capturedInvalidation: UInt64
    var frames = [Frame(directory: .keys)]
    var reachedSegments = false
}

/// Qualification controls bracket real observations and durable receive effects.
struct RepositoryDiscoveryHooks: Sendable {
    var observed: (@Sendable (String) async throws -> Void)?
    var read: (@Sendable (String) async throws -> Void)?
    var delivered: (@Sendable (String) async throws -> Void)?
    var hintsReturned: (@Sendable () async throws -> Void)?
    var portableMetadata = false
}

enum RepositoryHintAnswer: Equatable, Sendable { case read, accepted(SegmentID) }

/// Checked answers retain the exact requests and live owners that issued them.
struct RepositoryHintLookup: Sendable {
    fileprivate let permission: RepositoryRootPermission
    fileprivate let store: LocalStoreID
    fileprivate let incarnation: UUID
    fileprivate let hints: [RepositoryObservationHint]
    fileprivate let answers: [RepositoryHintAnswer]
    fileprivate init(permission: RepositoryRootPermission, store: LocalStoreID, incarnation: UUID,
                     hints: [RepositoryObservationHint], answers: [RepositoryHintAnswer]) {
        self.permission = permission; self.store = store; self.incarnation = incarnation
        self.hints = hints; self.answers = answers
    }
}

private enum PreparedDiscoveryEntry {
    case result(RepositoryDiscoveryEntry)
    case file(String, RepositoryEntryObservation, RepositoryObservationHint, Int?)
}

private enum RepositoryReceiveTarget: Sendable {
    case store(LocalStoreSession), bootstrap(BootstrapCandidate)
    func identity() async throws -> RepositoryDiscoveryOwner {
        switch self {
        case .store(let store): .store(store.selection.store, session: store.incarnation)
        case .bootstrap(let candidate): .bootstrap(candidate.selection.store,
            connection: try await candidate.lane.perform { $0.incarnation })
        }
    }
    var selection: LocalStoreSelection {
        switch self { case .store(let store): store.selection; case .bootstrap(let candidate): candidate.selection }
    }
    func check() async throws {
        switch self {
        case .store(let store): try await store.checkDiscoveryTarget()
        case .bootstrap(let candidate): try await candidate.checkDiscoveryTarget()
        }
    }
    func known(_ hints: [RepositoryObservationHint], permission: RepositoryRootPermission) async throws -> RepositoryHintLookup? {
        switch self {
        case .store(let store): try await store.knownDiscoveryHints(hints, permission: permission)
        case .bootstrap: nil
        }
    }
    func deliver(_ bytes: [UInt8], hint: RepositoryObservationHint) async throws -> RepositoryDiscoveryOutcome {
        switch self {
        case .store(let store):
            do {
                let result = try await store.receiveWithIdentity(bytes)
                try await store.rememberDiscoveryHint(hint, object: result.locator.segmentID)
                return .received(result.locator, result.kind, result.outcome)
            } catch {
                if let rejected = try await store.discoveryRejection(bytes) { return .rejected(rejected) }
                throw error
            }
        case .bootstrap(let candidate):
            let result = try await candidate.retainWithIdentity(bytes, ready: true)
            return .received(result.locator, result.kind, .retainedForAssembly)
        }
    }
}

extension RepositoryRootSession {
    /// Records a disclosure hint while allowing an in-progress bounded pass to finish.
    public func noteRepositoryChange() {
        precondition(discoveryInvalidation < UInt64.max, "Discovery generation exhausted")
        discoveryInvalidation += 1
        signalTransport(.discovery)
    }

    public func discover(into store: LocalStoreSession, opportunity: RepositoryDiscoveryOpportunity,
                         budget: Int = 16) async throws -> RepositoryDiscoveryTurn {
        try await discover(target: .store(store), opportunity: opportunity, budget: budget, hooks: .init())
    }

    public func discover(into candidate: BootstrapCandidate, opportunity: RepositoryDiscoveryOpportunity,
                         budget: Int = 16) async throws -> RepositoryDiscoveryTurn {
        try await discover(target: .bootstrap(candidate), opportunity: opportunity, budget: budget, hooks: .init())
    }

    func discover(into store: LocalStoreSession, opportunity: RepositoryDiscoveryOpportunity,
                  budget: Int, hooks: RepositoryDiscoveryHooks) async throws -> RepositoryDiscoveryTurn {
        try await discover(target: .store(store), opportunity: opportunity, budget: budget, hooks: hooks)
    }

    /// Rechecks the issuing root and intended local owner before consuming turn observations.
    public func validate(_ turn: RepositoryDiscoveryTurn, for store: LocalStoreSession) async throws {
        try checkPermission(turn.permission)
        guard turn.target == .store(store.selection.store, session: store.incarnation) else { throw RepositoryRootError.wrongContext }
        try await store.checkDiscoveryTarget(); try checkPermission(turn.permission)
    }

    /// Consumes only answers for this root generation, exact request order and live store.
    func validateDiscoveryHints(_ lookup: RepositoryHintLookup, hints: [RepositoryObservationHint],
                                for store: LocalStoreSession) async throws -> [RepositoryHintAnswer] {
        try checkPermission(lookup.permission)
        guard lookup.store == store.selection.store, lookup.incarnation == store.incarnation,
              lookup.hints.count == hints.count, lookup.answers.count == hints.count,
              zip(lookup.hints, hints).allSatisfy({ $0.key == $1.key && $0.fingerprint == $1.fingerprint }) else {
            throw RepositoryRootError.wrongContext
        }
        try await store.checkDiscoveryTarget(); try checkPermission(lookup.permission)
        return lookup.answers
    }

    private func discover(target: RepositoryReceiveTarget, opportunity: RepositoryDiscoveryOpportunity,
                          budget: Int, hooks: RepositoryDiscoveryHooks) async throws -> RepositoryDiscoveryTurn {
        guard budget > 0, budget <= 64 else { throw StorageError.limit }
        guard !discoveryRunning else { throw RepositoryRootError.busy }
        let permission = try permission()
        discoveryRunning = true; defer { discoveryRunning = false; signalTransport(.rootSettled) }
        try await target.check(); try checkPermission(permission)
        let identity = try await target.identity(); try checkPermission(permission)
        if let current = discoveryState {
            do {
                try checkPermission(current.permission)
                if current.target != identity { discoveryState = nil }
            } catch { discoveryState = nil }
        }
        if discoveryState == nil {
            discoveryState = RepositoryDiscoveryState(permission: permission, target: identity,
                capturedInvalidation: discoveryInvalidation)
        }
        guard var progress = discoveryState else { throw RepositoryRootError.wrongContext }
        var entries: [RepositoryDiscoveryEntry] = [], steps = 0
        var freshMetadata: [RepositoryMetadataEntry] = []
        do {
            while steps < budget, !progress.frames.isEmpty {
                try Task.checkCancellation(); try checkPermission(permission)
                let index = progress.frames.count - 1
                if progress.frames[index].names.isEmpty {
                    if progress.frames[index].ended {
                        if progress.frames[index].directory != .segments, let cursor = progress.frames[index].cursor {
                            try await cancelListing(cursor, using: permission)
                        }
                        progress.frames.removeLast()
                        freshMetadata = []
                        if progress.frames.isEmpty, !progress.reachedSegments {
                            progress.reachedSegments = true; progress.frames.append(.init(directory: .segments))
                        }
                        continue
                    }
                    steps += 1
                    let frame = progress.frames[index]
                    do {
                        if frame.directory == .segments {
                            let page = try await list(frame.directory, continuing: frame.cursor, budget: min(16, budget), using: permission)
                            progress.frames[index].names = page.names
                            progress.frames[index].cursor = page.continuation
                            progress.frames[index].ended = page.continuation == nil
                        } else {
                            let page = try await metadata(frame.directory, continuing: frame.cursor, budget: min(16, budget),
                                portable: hooks.portableMetadata, using: permission)
                            progress.frames[index].names = page.entries.map(\.leaf)
                            progress.frames[index].cursor = page.cursor
                            progress.frames[index].ended = page.finished
                            freshMetadata = page.entries
                        }
                    } catch RepositoryRootError.unavailable(let code) {
                        try checkPermission(permission)
                        entries.append(.init(frame.directory.relativePath, .unavailable(.init(code: code))))
                        progress.frames[index].ended = true
                    }
                    continue
                }
                let directory = progress.frames[index].directory
                if directory == .segments {
                    steps += 1
                    let name = progress.frames[index].names.removeFirst()
                    guard let path = try? name.relativePath(in: directory) else { continue }
                    guard let epoch = Self.writerEpoch(name.bytes) else { entries.append(.init(path, .ignored)); continue }
                    progress.frames.append(.init(directory: .writer(epoch)))
                    continue
                }
                let count = min(budget - steps, progress.frames[index].names.count)
                let names = Array(progress.frames[index].names.prefix(count))
                let observed: [RepositoryMetadataEntry]
                if !freshMetadata.isEmpty {
                    guard freshMetadata.count >= count,
                          zip(freshMetadata.prefix(count), names).allSatisfy({ $0.leaf.bytes == $1.bytes }) else { throw RepositoryRootError.wrongContext }
                    observed = Array(freshMetadata.prefix(count)); freshMetadata.removeFirst(count)
                } else {
                    let refreshed = try await metadata(directory, continuing: progress.frames[index].cursor,
                        refreshing: names, budget: count, using: permission)
                    observed = refreshed.entries; progress.frames[index].cursor = refreshed.cursor
                }
                progress.frames[index].names.removeFirst(count); steps += count
                var prepared: [PreparedDiscoveryEntry] = [], hints: [RepositoryObservationHint] = []
                for entry in observed {
                    guard let path = try? entry.leaf.relativePath(in: directory) else { continue }
                    switch entry.result {
                    case .invalidName: continue
                    case .unavailable(let failure): prepared.append(.result(.init(path, .unavailable(failure))))
                    case .observed(let observation):
                        guard observation.kind == .regularFile else {
                            prepared.append(.result(.init(path, .unavailable(.kindCollision)))); continue
                        }
                        try await hooks.observed?(path); try checkPermission(permission)
                        let hint = try discoveryHint(observation, using: permission)
                        let hintIndex = directory == .keys ? nil : hints.count
                        if hintIndex != nil { hints.append(hint) }
                        prepared.append(.file(path, observation, hint, hintIndex))
                    }
                }
                var answers = [RepositoryHintAnswer](repeating: .read, count: hints.count)
                if !hints.isEmpty, let lookup = try await target.known(hints, permission: permission) {
                    try await hooks.hintsReturned?(); try checkPermission(permission)
                    guard case .store(let store) = target else { throw RepositoryRootError.wrongContext }
                    answers = try await validateDiscoveryHints(lookup, hints: hints, for: store)
                }
                for entry in prepared {
                    try Task.checkCancellation(); try checkPermission(permission)
                    switch entry {
                    case .result(let result): entries.append(result)
                    case .file(let path, let observation, let hint, let hintIndex):
                        if let hintIndex, case .accepted(let known) = answers[hintIndex] {
                            entries.append(.init(path, .unchangedAccepted(known))); continue
                        }
                        switch try await read(observation, maximumBytes: Int(ObjectLimitsV1.encodedPayloadBytes + 156), using: permission) {
                        case .unavailable(let failure): entries.append(.init(path, .unavailable(failure)))
                        case .contents(let contents):
                            try await hooks.read?(path); try checkPermission(permission)
                            do {
                                let outcome: RepositoryDiscoveryOutcome
                                if directory == .keys {
                                    let descriptor = try BootstrapDescriptorV1.decodeV1(contents.bytes)
                                    guard descriptor.collection == target.selection.descriptor.collection,
                                          descriptor.keyID == target.selection.descriptor.keyID,
                                          descriptor.genesis == target.selection.descriptor.genesis else { throw CanonicalEncodingError.wrongScope }
                                    outcome = .descriptor(descriptor)
                                } else { outcome = try await target.deliver(contents.bytes, hint: hint) }
                                try await hooks.delivered?(path); try checkPermission(permission)
                                entries.append(.init(path, outcome))
                            } catch let failure as CanonicalEncodingError {
                                try checkPermission(permission); entries.append(.init(path, .invalid(failure)))
                            }
                        }
                    }
                }
            }
            try await target.check(); try checkPermission(permission)
            let ended = progress.frames.isEmpty
            discoveryState = ended ? nil : progress
            return RepositoryDiscoveryTurn(entries: entries, passEnded: ended, captured: progress.capturedInvalidation,
                latest: discoveryInvalidation, permission: permission, target: identity)
        } catch {
            // The next ordinary pass revisits disclosed files through idempotent durable receive.
            discoveryState = nil
            throw error
        }
    }

    static func writerEpoch(_ bytes: [UInt8]) -> WriterEpoch? {
        guard bytes.count == 32 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: c - 48; case 97...102: c - 87; default: nil }
        }
        var decoded: [UInt8] = []
        for i in stride(from: 0, to: 32, by: 2) {
            guard let a = nibble(bytes[i]), let b = nibble(bytes[i + 1]) else { return nil }
            decoded.append((a << 4) | b)
        }
        return try? WriterEpoch(bytes: decoded)
    }
}

extension LocalStoreSession {
    func checkDiscoveryTarget() throws { guard lifecycle == .open else { throw StorageError.closed } }

    /// Reuses a freshly rooted file observation while its previously checked object remains accepted.
    func knownDiscoveryHints(_ hints: [RepositoryObservationHint], permission: RepositoryRootPermission) async throws -> RepositoryHintLookup {
        try checkDiscoveryTarget()
        guard hints.count <= 64 else { throw StorageError.limit }
        let selection = selection, incarnation = incarnation
        let answers = try await lane.perform { db -> [RepositoryHintAnswer] in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard !hints.isEmpty else { return [] }
            db.countWork { $0.discoveryHintBatches += 1; $0.discoveryHintInputs += hints.count }
            let values = hints.map { _ in "(?,?,?)" }.joined(separator: ",")
            let arguments = hints.enumerated().flatMap { index, hint in
                [SQLValue.integer(Int64(index)), .blob(hint.key), .blob(hint.fingerprint)]
            }
            let rows = try db.rows("""
                WITH requested(ordinal,key,fingerprint) AS (VALUES \(values))
                SELECT r.ordinal,p.payload FROM requested r JOIN private_groups p ON p.group_key=r.key
                JOIN accepted_objects a ON a.object_id=substr(p.payload,33,32)
                WHERE p.codec=1 AND length(p.payload)=96 AND substr(p.payload,1,32)=r.fingerprint ORDER BY r.ordinal
                """, arguments)
            var answers = [RepositoryHintAnswer](repeating: .read, count: hints.count), seen = Set<Int>()
            for row in rows {
                guard row.count == 2, let index = Int(exactly: try row[0].number), hints.indices.contains(index),
                      seen.insert(index).inserted else { throw StorageError.integrity }
                let payload = try row[1].bytes, hint = hints[index]
                guard payload.count == 96, Array(payload.prefix(32)) == hint.fingerprint else { continue }
                let identity = Array(payload[32..<64])
                guard Array(payload.suffix(32)) == Self.hintDigest(key: hint.key, fingerprint: hint.fingerprint, object: identity) else { continue }
                answers[index] = .accepted(try SegmentID(bytes: identity))
                db.countWork { $0.discoveryHintHits += 1 }
            }
            return answers
        }
        try checkDiscoveryTarget()
        return RepositoryHintLookup(permission: permission, store: selection.store, incarnation: incarnation,
            hints: hints, answers: answers)
    }

    /// Records a durably retained observation; reuse separately requires accepted membership.
    fileprivate func rememberDiscoveryHint(_ hint: RepositoryObservationHint, object: SegmentID) async throws {
        try checkDiscoveryTarget()
        let selection = selection
        try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard try !db.rows("SELECT 1 FROM objects WHERE object_id=?", [.blob(object.bytes)]).isEmpty else { throw StorageError.incomplete }
            let payload = hint.fingerprint + object.bytes + Self.hintDigest(key: hint.key, fingerprint: hint.fingerprint, object: object.bytes)
            try db.run("INSERT INTO private_groups VALUES(?,1,1,?) ON CONFLICT(group_key) DO UPDATE SET generation=1,codec=1,payload=excluded.payload",
                [.blob(hint.key), .blob(payload)])
        }
    }

    func rememberInventoryHint(_ checked: VerifiedRepositoryObservation) async throws {
        guard checked.store == selection.store, checked.session == incarnation else { throw StorageError.wrongContext }
        try await rememberDiscoveryHint(checked.hint, object: checked.object)
    }

    fileprivate func discoveryRejection(_ bytes: [UInt8]) async throws -> ReceiveRejection? {
        let identity = Array(SHA256.hash(data: bytes)), selection = selection
        return try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            return try db.receivedRejection(.blob(identity))
        }
    }
    private nonisolated static func hintDigest(key: [UInt8], fingerprint: [UInt8], object: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Array("NV repository observation hint\0v1\0".utf8) + key + fingerprint + object))
    }
}
