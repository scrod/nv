import Foundation
import NVStorageCore

/// Owner-issued retry access to one frozen snapshot and its exact sealed emissions.
public struct SnapshotCommitHandle: Sendable {
    fileprivate let session: UUID
    fileprivate let id: UUID
    fileprivate let construction: SnapshotConstruction
    private init(session: UUID, capture: GeneralSnapshotCapture) {
        self.session = session; id = UUID(); construction = SnapshotConstruction(capture: capture)
    }
    fileprivate static func start(session: UUID, capture: GeneralSnapshotCapture) -> Self {
        Self(session: session, capture: capture)
    }
}

/// Durable object coverage for a complete general snapshot accepted by this owner.
public struct AcceptedSnapshotReceipt: Sendable {
    public let store: LocalStoreID
    public let sequence: Int64
    public let snapshot: SegmentLocator
    public let pages: Set<SegmentLocator>
    private let session: UUID
    private init(store: LocalStoreID, session: UUID, sequence: Int64, snapshot: SegmentLocator, pages: Set<SegmentLocator>) {
        self.store = store; self.session = session; self.sequence = sequence; self.snapshot = snapshot; self.pages = pages
    }
    fileprivate static func committed(store: LocalStoreID, session: UUID, sequence: Int64,
                                      preview: GeneralSnapshotPreviewV1) -> Self {
        Self(store: store, session: session, sequence: sequence, snapshot: preview.snapshot, pages: preview.pages)
    }
}

public enum SnapshotCommitOutcome: Sendable {
    case accepted(AcceptedSnapshotReceipt)
    case pending(SnapshotCommitHandle, StorageError)
}

/// Serial admission and retry ownership for one optional snapshot construction.
enum LocalSnapshotState: Sendable {
    case idle, pending(SnapshotCommitHandle), running(SnapshotCommitHandle)
    var owned: SnapshotCommitHandle? {
        switch self { case .idle: nil; case .pending(let handle), .running(let handle): handle }
    }
    var isRunning: Bool { if case .running = self { true } else { false } }
}

private struct SealedSnapshotObject: Sendable {
    let locator: SegmentLocator
    let bytes: [UInt8]
}

/// Replays deterministic emission positions using retained exact bytes after interrupted writes.
private actor SnapshotConstruction {
    let capture: GeneralSnapshotCapture
    var emitted: [SegmentLocator] = []
    var pending: SealedSnapshotObject?
    var root: SegmentLocator?
    var cursor = 0
    init(capture: GeneralSnapshotCapture) { self.capture = capture }

    func construct(owner: LocalStoreSession) async throws -> SegmentLocator {
        if let root { return root }
        cursor = 0
        let snapshot = try await GeneralSnapshotV1.write(records: capture.records, bootstrapSnapshot: capture.bootstrapSnapshot) { kind, payload in
            try await self.emit(kind: kind, payload: payload, owner: owner)
        }
        root = snapshot
        return snapshot
    }
    private func emit(kind: ProviderObjectKind, payload: [UInt8], owner: LocalStoreSession) async throws -> SegmentLocator {
        guard await owner.lifecycle == .open else { throw StorageError.closed }
        let lane = owner.lane, selection = owner.selection, protection = owner.protection
        if cursor < emitted.count {
            let locator = emitted[cursor]
            try await lane.perform { db in
                guard let bytes = try db.snapshotCandidate(locator, collection: selection.descriptor.collection, protection: protection) else {
                    throw StorageError.incomplete
                }
                let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection, expectedLocator: locator)
                guard opened.kind == kind, opened.payload == payload else { throw StorageError.integrity }
            }
            cursor += 1
            return locator
        }
        if pending == nil {
            let (writer, sequence) = try await owner.reserveObjectAddress()
            pending = try await lane.prepare {
                let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: selection.descriptor.collection,
                    writer: writer, sequence: sequence, protection: protection)
                return try SealedSnapshotObject(locator: ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection,
                    protection: protection).locator, bytes: bytes)
            }
        }
        guard let pending else { throw StorageError.integrity }
        let gate = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            let opened = try ObjectEnvelopeV1.open(pending.bytes, collection: selection.descriptor.collection,
                protection: protection, expectedLocator: pending.locator)
            guard opened.kind == kind, opened.payload == payload else { throw StorageError.integrity }
            try db.retainSnapshotCandidate(pending.bytes, opened: opened)
            return db.work?.snapshotCandidateCompletion
        }
        try await gate?(pending.locator)
        emitted.append(pending.locator); self.pending = nil; cursor += 1
        return pending.locator
    }
}

extension LocalStoreSession {
    /// Retains bounded snapshot emissions, then accepts the complete checked root/page set.
    public func persistGeneralSnapshot(capture: GeneralSnapshotCapture) async throws -> SnapshotCommitOutcome {
        guard !closed, !quiescing else { throw StorageError.closed }
        try capture.checkOwner(self)
        guard snapshotState.owned == nil else { throw StorageError.busy }
        return await finishSnapshot(.start(session: incarnation, capture: capture))
    }

    public func retry(snapshot commit: SnapshotCommitHandle) async throws -> SnapshotCommitOutcome {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard commit.session == incarnation else { throw StorageError.wrongContext }
        guard !snapshotState.isRunning, snapshotState.owned?.id == commit.id else { throw StorageError.busy }
        return await finishSnapshot(commit)
    }

    private func finishSnapshot(_ handle: SnapshotCommitHandle) async -> SnapshotCommitOutcome {
        snapshotState = .running(handle)
        defer {
            if case .running = snapshotState { snapshotState = .pending(handle) }
            let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() }
        }
        do {
            let root = try await handle.construction.construct(owner: self)
            let (sequence, preview) = try await lane.acceptGeneralSnapshot(root, selection: selection, protection: protection)
            let receipt = AcceptedSnapshotReceipt.committed(store: selection.store, session: incarnation,
                sequence: sequence, preview: preview)
            snapshotState = .idle
            return .accepted(receipt)
        } catch { return .pending(handle, error is CancellationError ? .busy : classify(error)) }
    }
}

extension Database {
    /// Candidate pages remain assembly input; a complete emitted root owns ready work.
    func retainSnapshotCandidate(_ bytes: [UInt8], opened: OpenedObjectV1) throws {
        guard opened.kind == .snapshotPage || opened.kind == .snapshotRoot else { throw StorageError.unsupported }
        try transaction {
            if let reason = try receivedRejection(.blob(opened.locator.segmentID.bytes)) { throw reason.error }
            try retainCandidate(bytes, opened: opened, ready: opened.kind == .snapshotRoot)
        }
    }
}
