import Foundation
import NVStorageCore

/// Host generation covered by one immutable action capture.
public struct CapturedNoteGeneration: Equatable, Sendable {
    public let birth: NoteBirth
    public let generation: UInt64
    public init(birth: NoteBirth, generation: UInt64) throws {
        guard generation > 0 else { throw StorageError.staleCapture }
        self.birth = birth; self.generation = generation
    }
}

public enum CapturedNoteChange: Sendable {
    case create(CapturedNoteGeneration, PlaintextNoteValue)
    case put(CapturedNoteGeneration, PlaintextNoteValue)
    case delete(CapturedNoteGeneration)
    var covered: CapturedNoteGeneration {
        switch self { case .create(let g, _), .put(let g, _), .delete(let g): g }
    }
}

/// Exact values and authoring basis frozen by the host before persistence admission.
public struct CapturedActionGroup: Sendable {
    let id = UUID()
    let session: UUID
    let store: LocalStoreID
    let through: Int64
    let viewEpoch: [UInt8]
    let context: AuthoringContextV1
    let before: [NoteBirth: CurrentNoteCellV1]
    let changes: [CapturedNoteChange]
    let action: ActionID
    let scope: ActionScopeV1
    let kind: ActionKindV1
    public let covered: [CapturedNoteGeneration]

    public init(snapshot: StoreSnapshot, kind: ActionKindV1, changes: [CapturedNoteChange]) throws {
        guard !changes.isEmpty, Set(changes.map { $0.covered.birth }).count == changes.count else { throw StorageError.staleCapture }
        let cells = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.birth, $0) })
        for change in changes {
            switch change {
            case .create(let g, _): guard kind == .createImportBatch, cells[g.birth] == nil else { throw StorageError.staleCapture }
            case .put(let g, _): guard [.savedEdit, .rename, .labels].contains(kind), cells[g.birth] != nil else { throw StorageError.staleCapture }
            case .delete(let g):
                guard kind == .deleteBatch, cells[g.birth] != nil else { throw StorageError.staleCapture }
            }
        }
        guard kind == .createImportBatch || kind == .deleteBatch || changes.count == 1 else { throw StorageError.unsupported }
        session = snapshot.session; store = snapshot.store; through = snapshot.through
        viewEpoch = snapshot.viewEpoch; context = snapshot.context; self.kind = kind; self.changes = changes
        covered = changes.map(\.covered)
        let births = Set(changes.map { $0.covered.birth })
        before = cells.filter { births.contains($0.key) }
        action = try ActionID(bytes: uuidBytes())
        scope = kind == .createImportBatch || kind == .deleteBatch ? .collection : .note(changes[0].covered.birth)
    }
}

/// Opaque identity of an admitted commit retained by one live store owner.
public struct CommitHandle: Sendable {
    fileprivate let session: UUID
    fileprivate let id: UUID
    fileprivate let capture: CapturedActionGroup
    fileprivate init(session: UUID, id: UUID, capture: CapturedActionGroup) { self.session = session; self.id = id; self.capture = capture }
}

/// Exact accepted membership and host generations established by the committing owner.
public struct AcceptedHistoryReceipt: Sendable {
    public let store: LocalStoreID
    public let sequence: Int64
    public let object: SegmentLocator
    public let covered: [CapturedNoteGeneration]
    fileprivate let session: UUID
    fileprivate init(session: UUID, store: LocalStoreID, sequence: Int64, object: SegmentLocator,
                     covered: [CapturedNoteGeneration]) {
        self.session = session; self.store = store; self.sequence = sequence; self.object = object; self.covered = covered
    }
    func belongs(to snapshot: StoreSnapshot) -> Bool { store == snapshot.store && session == snapshot.session }
}

public enum CommitOutcome: Sendable {
    case accepted(AcceptedHistoryReceipt)
    case pending(CommitHandle, StorageError)
}

struct SealedCommit: Sendable {
    let payload: ChangesPayloadV1
    let bytes: [UInt8]
    let locator: SegmentLocator
}
struct OwnedCommit: Sendable {
    let capture: CapturedActionGroup
    var sealed: SealedCommit?
}
private enum SealPreparation: Sendable {
    case sealed(SealedCommit)
    case committed(Int64, SegmentLocator)
}

extension LocalStoreSession {
    public func persist(capture: CapturedActionGroup) async throws -> CommitOutcome {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard capture.session == incarnation, capture.store == selection.store else { throw StorageError.wrongContext }
        guard !inFlight else { throw StorageError.busy }
        guard !commits.contains(where: { $0.key != capture.id }) else { throw StorageError.busy }
        // Admission retains the immutable capture before the first suspension.
        if commits[capture.id] == nil { commits[capture.id] = OwnedCommit(capture: capture) }
        return await finish(capture.id)
    }

    public func retry(commit: CommitHandle) async throws -> CommitOutcome {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard commit.session == incarnation, commit.id == commit.capture.id else { throw StorageError.wrongContext }
        return try await persist(capture: commit.capture)
    }

    private func finish(_ id: UUID) async -> CommitOutcome {
        inFlight = true
        defer { inFlight = false; let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() } }
        // Only persist/retry call finish after installing this owned slot.
        let owned = commits[id]!
        let handle = CommitHandle(session: incarnation, id: id, capture: owned.capture)
        let capture = owned.capture, selection = selection, protection = protection
        do {
            if owned.sealed == nil {
                let epochLimit: UInt64
                switch protection { case .publicHash: epochLimit = UInt64.max; case .encrypted: epochLimit = 1 << 20 }
                if sequence >= epochLimit {
                    writer = try WriterEpoch(bytes: uuidBytes()); sequence = 0
                }
                let writer = writer, sequence = sequence, origin = origin, previous = previousOrigin
                self.sequence += 1
                let preparation = try await lane.perform { db -> SealPreparation in
                    if let found = try db.existingCapture(capture, selection: selection, protection: protection) {
                        return .committed(found.0, found.1)
                    }
                    try db.validateCapture(capture)
                    let sealed = try sealCapture(capture, collection: selection.descriptor.collection,
                        writer: writer, sequence: sequence, origin: origin, previous: previous, protection: protection)
                    db.countWork { $0.envelopeDecodes += 1 }
                    return .sealed(sealed)
                }
                switch preparation {
                case .sealed(let sealed): commits[id]?.sealed = sealed
                case .committed(let seq, let locator):
                    commits.removeValue(forKey: id)
                    return .accepted(AcceptedHistoryReceipt(session: incarnation, store: selection.store,
                        sequence: seq, object: locator, covered: capture.covered))
                }
            }
            guard let sealed = commits[id]?.sealed else { throw StorageError.integrity }
            let accepted = try await lane.acceptScheduled(sealed.bytes, locator: sealed.locator,
                selection: selection, protection: protection)
            let receipt = AcceptedHistoryReceipt(session: incarnation, store: selection.store, sequence: accepted,
                object: sealed.locator, covered: capture.covered)
            previousOrigin = StoredActionReferenceV1(locator: sealed.locator, index: ActionIndex(0), id: capture.action)
            // A materialization failure leaves the independently committed receipt valid.
            try? await lane.catchUp(selection: selection, protection: protection)
            commits.removeValue(forKey: id)
            return .accepted(receipt)
        } catch {
            return .pending(handle, classify(error))
        }
    }
}

func classify(_ error: Error) -> StorageError {
    if error is HistoryValidationInterrupted { return .busy }
    if let e = error as? StorageError { return e }
    if let e = error as? OrdinaryHistoryError, e == .requiresLaterReducer { return .unsupported }
    if let e = error as? CanonicalEncodingError {
        switch e { case .unsupportedFormat: return .unsupported; case .missingDependency: return .incomplete
        case .wrongScope: return .wrongContext; default: break }
    }
    return .integrity
}

extension Database {
    func existingCapture(_ capture: CapturedActionGroup, selection: LocalStoreSelection,
                         protection: ObjectProtectionV1) throws -> (Int64, SegmentLocator)? {
        guard let a = try action(capture.action, selection: selection, protection: protection) else { return nil }
        guard a.kind == capture.kind, a.scope == capture.scope, a.affected.count == capture.changes.count,
              a.members.count == capture.changes.count else { throw StorageError.integrity }
        for change in capture.changes {
            guard let affected = a.affected.first(where: { $0.birth == change.covered.birth }),
                  affected.before == (capture.before[change.covered.birth].map { .value($0.revision.id) } ?? .freshBirthAbsence) else { throw StorageError.integrity }
            let id: OperationID
            switch affected.after { case .value(let value), .deleted(let value): id = value; default: throw StorageError.integrity }
            guard let op = try operation(id, selection: selection, protection: protection),
                  op.effect.targetBirth == change.covered.birth, op.effect.actionID == capture.action else { throw StorageError.integrity }
            switch (change, op.effect) {
            case (.create(_, let value), .create(_, _, let saved)), (.put(_, let value), .put(_, _, let saved)):
                guard value == saved else { throw StorageError.integrity }
            case (.delete, .delete): break
            default: throw StorageError.integrity
            }
        }
        let ref = try actionOccurrence(capture.action)
        let rows = try rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(ref.locator.segmentID.bytes)])
        guard let row = rows.first else { throw StorageError.incomplete }
        return try (row[0].number, ref.locator)
    }
    func validateCapture(_ capture: CapturedActionGroup) throws {
        let meta = try rows("SELECT epoch,through_seq,authoring_context FROM view_meta WHERE singleton=1")
        guard meta == [[.blob(capture.viewEpoch), .integer(capture.through), .blob(capture.context.encodedV1())]],
              try acceptedThrough() == capture.through else { throw StorageError.staleCapture }
        for change in capture.changes {
            let birth = change.covered.birth
            let r = try rows("SELECT cell FROM current_notes WHERE birth=?", [.blob(birth.bytes)])
            let expected = capture.before[birth].map { [[SQLValue.blob($0.encodedV1())]] } ?? []
            guard r == expected else { throw StorageError.staleCapture }
        }
    }
}

private func sealCapture(_ capture: CapturedActionGroup, collection: CollectionID, writer: WriterEpoch,
    sequence: UInt64, origin: ActionOriginID, previous: StoredActionReferenceV1?, protection: ObjectProtectionV1) throws -> SealedCommit {
    var deps = Set(capture.context.operations.map(\.locator)), records: [OperationRecordV1] = []
    var affected: [ActionAffectedReference] = []
    let scope = capture.scope == .collection ? capture.context.collectionActions : (capture.before[capture.covered[0].birth]?.scopeFrontier ?? [])
    deps.formUnion(scope.map(\.locator)); if let previous { deps.insert(previous.locator) }
    for (n, change) in capture.changes.enumerated() {
        let birth = change.covered.birth, old = capture.before[birth]
        if let old { deps.insert(old.revision.locator) }
        let effect: OperationEffectV1
        switch change {
        case .create(_, let value): effect = .create(action: capture.action, birth: birth, value: value)
        case .put(_, let value): effect = .put(action: capture.action, birth: birth, value: value)
        case .delete: effect = .delete(action: capture.action, birth: birth)
        }
        let parentIDs = n == 0 ? capture.context.operations.map(\.id) : [records[n-1].operation.id]
        let parentRefs = n == 0 ? capture.context.operations.map(\.reference) : [.earlierLocal(index: OperationIndex(UInt32(n-1)))]
        let noteRefs: [OperationReference]
        if case .put = change { noteRefs = old.map { [$0.revision.reference] } ?? [] } else { noteRefs = [] }
        let op = try IdentifiedOperation(nonce: OperationNonce(bytes: uuidBytes()), effect: effect,
            causalParents: CausalParentSet(parentIDs), notePredecessors: NotePredecessorSet(noteRefs.isEmpty ? [] : [old!.revision.id]))
        records.append(try OperationRecordV1(operation: op, causalReferences: parentRefs, noteReferences: noteRefs,
            earlierOperations: records.map(\.operation)))
        let afterRef = OperationReference.earlierLocal(index: OperationIndex(UInt32(n)))
        affected.append(.init(birth: birth, before: old.map { .value($0.revision.reference) } ?? .freshBirthAbsence,
            after: capture.kind == .deleteBatch ? .deleted(afterRef) : .value(afterRef)))
    }
    let action = try ActionRecordV1(id: capture.action, origin: origin, previousOrigin: previous?.reference,
        scope: capture.scope, scopeParents: scope.map(\.reference), kind: capture.kind,
        members: records.indices.map { OperationIndex(UInt32($0)) }, affected: affected,
        operations: records.map(\.operation), earlierActions: [])
    let payload = try ChangesPayloadV1(dependencies: DependencyLocatorTable(Array(deps)), operations: records, actions: [action])
    let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: collection,
        writer: writer, sequence: sequence, protection: protection)
    let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
    return SealedCommit(payload: payload, bytes: bytes, locator: locator)
}
