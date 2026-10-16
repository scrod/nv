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

/// Host-authored actions whose complete intent is supplied by ordinary note changes.
public enum OrdinaryActionKind: Sendable {
    case savedEdit, rename, labels, createImportBatch, deleteBatch

    var historyKind: ActionKindV1 {
        switch self {
        case .savedEdit: .savedEdit
        case .rename: .rename
        case .labels: .labels
        case .createImportBatch: .createImportBatch
        case .deleteBatch: .deleteBatch
        }
    }
}

/// Admission mode recorded with an actual causal Undo or Redo.
enum CompensationAuthorization: Sendable { case automatic, reviewed }

/// Command variants carry the provenance required to encode that action.
enum CapturedActionIntent: Sendable {
    case ordinary(OrdinaryActionKind)
    case restore([RestorationReference])
    case choice(selected: OperationReference, heads: [OperationReference])
    case copy(source: NoteBirth, revision: OperationReference, key: ConflictRecoveryKeyV1, slot: UInt64, reused: OperationReference?)
    case historical(source: NoteBirth, revision: OperationReference, fields: HistoryFieldsV1)
    case compensation(direction: UndoDirectionV1, target: ActionReference, authorization: CompensationAuthorization, restorations: [RestorationReference])
    case native([NativeCoverageReferenceV1])

    var kind: ActionKindV1 {
        switch self {
        case .ordinary(let kind): kind.historyKind
        case .restore: .restoreBatch
        case .choice: .conflictChoice
        case .copy: .conflictCopy
        case .historical: .historicalRecovery
        case .compensation(let direction, _, _, _): direction == .undo ? .undo : .redo
        case .native: .nativeUndo
        }
    }
    var restorations: [RestorationReference] {
        switch self { case .restore(let records), .compensation(_, _, _, let records): records; default: [] }
    }
    var details: ActionDetailsReferenceV1? {
        switch self {
        case .ordinary, .restore: nil
        case .choice(let selected, let heads): .choice(selected: selected, heads: heads)
        case .copy(let source, let revision, let key, let slot, let reused):
            .copy(source: source, revision: revision, key: key, slot: slot, reused: reused)
        case .historical(let source, let revision, let fields): .historical(source: source, revision: revision, fields: fields)
        case .compensation(_, let target, let authorization, _): .compensation(target: target, reviewed: authorization == .reviewed)
        case .native(let coverage): .native(coverage)
        }
    }
}

/// Exact values and authoring basis frozen by the host before persistence admission.
public struct CapturedActionGroup: Sendable {
    let id: UUID
    let session: UUID
    let store: LocalStoreID
    let through: Int64
    let viewEpoch: [UInt8]
    let presentationEpoch: UUID
    let context: AuthoringContextV1
    let before: [NoteBirth: CurrentNoteCellV1]
    let changes: [CapturedNoteChange]
    let action: ActionID
    let reservedNonce: OperationNonce?
    let pendingBinding: PendingAdmissionBinding?
    let scope: ActionScopeV1
    let intent: CapturedActionIntent
    var kind: ActionKindV1 { intent.kind }
    var restorations: [RestorationReference] { intent.restorations }
    var details: ActionDetailsReferenceV1? { intent.details }
    public let covered: [CapturedNoteGeneration]

    public init(snapshot: StoreSnapshot, kind: OrdinaryActionKind, changes: [CapturedNoteChange]) throws {
        try self.init(snapshot: snapshot, intent: .ordinary(kind), changes: changes)
    }

    /// Freezes one or more selected deleted values as a single fresh-birth action.
    public init(snapshot: StoreSnapshot, restoring sources: [CapturedRestoration]) throws {
        guard sources.allSatisfy({ $0.session == snapshot.session && $0.store == snapshot.store && $0.through <= snapshot.through }) else {
            throw StorageError.wrongContext
        }
        try self.init(snapshot: snapshot, intent: .restore(sources.map(\.reference)),
            changes: sources.map { .create($0.generation, $0.value) })
    }

    init(snapshot: StoreSnapshot, intent: CapturedActionIntent, changes: [CapturedNoteChange], scope: ActionScopeV1? = nil,
                 commandID: UUID = UUID(), actionID: ActionID? = nil,
                 reservedNonce: OperationNonce? = nil, pendingBinding: PendingAdmissionBinding? = nil) throws {
        let kind = intent.kind, restorations = intent.restorations
        if case .historical(_, _, let fields) = intent {
            guard fields.rawValue > 0, fields.rawValue <= 7 else { throw StorageError.staleCapture }
        }
        guard !changes.isEmpty, Set(changes.map { $0.covered.birth }).count == changes.count || (kind == .nativeUndo && Set(changes.map { $0.covered.birth }).count == 1) else { throw StorageError.staleCapture }
        guard kind == .restoreBatch ? restorations.count == changes.count : (restorations.isEmpty || kind == .undo || kind == .redo) else { throw StorageError.staleCapture }
        let cells = Dictionary(uniqueKeysWithValues: snapshot.notes.map { ($0.birth, $0) })
        for change in changes {
            switch change {
            case .create(let g, _): guard [.createImportBatch, .restoreBatch, .conflictCopy, .historicalRecovery, .undo, .redo].contains(kind), cells[g.birth] == nil else { throw StorageError.staleCapture }
            case .put(let g, _): guard [.savedEdit, .rename, .labels, .conflictChoice, .conflictCopy, .historicalRecovery, .undo, .redo, .nativeUndo].contains(kind), cells[g.birth] != nil else { throw StorageError.staleCapture }
            case .delete(let g):
                guard [.deleteBatch, .undo, .redo].contains(kind), cells[g.birth] != nil else { throw StorageError.staleCapture }
            }
        }
        guard [.createImportBatch, .restoreBatch, .deleteBatch, .undo, .redo, .nativeUndo].contains(kind) || changes.count == 1 else { throw StorageError.unsupported }
        id = commandID; session = snapshot.session; store = snapshot.store; through = snapshot.through
        viewEpoch = snapshot.viewEpoch; presentationEpoch = snapshot.presentationEpoch; context = snapshot.context
        self.intent = intent; self.changes = changes
        covered = kind == .nativeUndo ? [changes[changes.count - 1].covered] : changes.map(\.covered)
        let births = Set(changes.map { $0.covered.birth })
        before = cells.filter { births.contains($0.key) }
        action = try actionID ?? ActionID(bytes: uuidBytes())
        self.reservedNonce = reservedNonce; self.pendingBinding = pendingBinding
        self.scope = scope ?? ([.createImportBatch, .restoreBatch, .deleteBatch, .conflictCopy].contains(kind) ? .collection : .note(changes[0].covered.birth))
    }
}

/// Owner-issued identity and frozen input for one persistence attempt and its retries.
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
    fileprivate let command: UUID
    fileprivate init(session: UUID, store: LocalStoreID, sequence: Int64, object: SegmentLocator,
                     capture: CapturedActionGroup) {
        self.session = session; self.store = store; self.sequence = sequence; self.object = object
        command = capture.id; covered = capture.covered
    }
    func belongs(to snapshot: StoreSnapshot) -> Bool { store == snapshot.store && session == snapshot.session }

    /// Matches the local command whose exact acceptance issued this receipt.
    func belongs(to capture: CapturedActionGroup) -> Bool {
        store == capture.store && session == capture.session && command == capture.id && covered == capture.covered
    }
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
/// Frozen input or exact sealed bytes retained across persistence retries.
enum OwnedCommit: Sendable {
    case captured(CapturedActionGroup)
    case sealed(CapturedActionGroup, SealedCommit)

    var capture: CapturedActionGroup {
        switch self { case .captured(let capture), .sealed(let capture, _): capture }
    }
    var sealed: SealedCommit? {
        if case .sealed(_, let sealed) = self { sealed } else { nil }
    }
}

/// One owned local commit, either awaiting retry or executing its persistence attempt.
enum LocalCommitState: Sendable {
    case idle
    case pending(OwnedCommit)
    case running(OwnedCommit)

    var owned: OwnedCommit? {
        switch self { case .idle: nil; case .pending(let owned), .running(let owned): owned }
    }
    var isRunning: Bool { if case .running = self { true } else { false } }
}
private enum SealPreparation: Sendable {
    case sealed(SealedCommit, (@Sendable () async -> Void)?)
    case committed(Int64, SegmentLocator)
}

/// A definitive encoding rejection before any envelope or acceptance effect exists.
private struct RejectedCaptureEncoding: Error {
    let cause: CanonicalEncodingError
}

extension LocalStoreSession {
    public func persist(capture: CapturedActionGroup) async throws -> CommitOutcome {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard capture.pendingBinding == nil || !pendingPreparationInFlight else { throw StorageError.busy }
        guard capture.session == incarnation, capture.store == selection.store else { throw StorageError.wrongContext }
        let owned: OwnedCommit
        switch commitState {
        case .idle: owned = .captured(capture)
        case .pending(let pending):
            guard pending.capture.id == capture.id else { throw StorageError.busy }
            owned = pending
        case .running: throw StorageError.busy
        }
        return await finish(owned)
    }

    public func retry(commit: CommitHandle) async throws -> CommitOutcome {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard commit.session == incarnation, commit.id == commit.capture.id else { throw StorageError.wrongContext }
        return try await persist(capture: commit.capture)
    }

    private func finish(_ owned: OwnedCommit) async -> CommitOutcome {
        // Reserve the complete input before the first suspension.
        commitState = .running(owned)
        cancelMaintenance()
        defer {
            if case .running(let remaining) = commitState { commitState = .pending(remaining) }
            signalReceiveWaiters()
        }
        let handle = CommitHandle(session: incarnation, id: owned.capture.id, capture: owned.capture)
        let capture = owned.capture, selection = selection, protection = protection
        do {
            if owned.sealed == nil {
                let (writer, sequence) = try reserveObjectAddress()
                let origin = origin, previous = previousOrigin
                let preparation = try await lane.perform { db -> SealPreparation in
                    if let found = try db.existingCapture(capture, selection: selection, protection: protection) {
                        return .committed(found.0, found.1)
                    }
                    try db.validateCapture(capture, selection: selection, protection: protection)
                    let sealed: SealedCommit
                    do {
                        sealed = try sealCapture(capture, collection: selection.descriptor.collection,
                            writer: writer, sequence: sequence, origin: origin, previous: previous, protection: protection)
                    } catch let cause as CanonicalEncodingError { throw RejectedCaptureEncoding(cause: cause) }
                    db.countWork { $0.envelopeDecodes += 1 }
                    return .sealed(sealed, db.work?.localCommitSealed)
                }
                switch preparation {
                case .sealed(let sealed, let didSeal):
                    commitState = .running(.sealed(capture, sealed))
                    await didSeal?()
                case .committed(let seq, let locator):
                    commitState = .idle
                    return .accepted(AcceptedHistoryReceipt(session: incarnation, store: selection.store,
                        sequence: seq, object: locator, capture: capture))
                }
            }
            guard let sealed = commitState.owned?.sealed else { throw StorageError.integrity }
            let accepted = try await lane.acceptScheduled(sealed.bytes, locator: sealed.locator,
                selection: selection, protection: protection)
            let receipt = AcceptedHistoryReceipt(session: incarnation, store: selection.store, sequence: accepted,
                object: sealed.locator, capture: capture)
            previousOrigin = StoredActionReferenceV1(locator: sealed.locator, index: ActionIndex(0), id: capture.action)
            // A materialization failure leaves the independently committed receipt valid.
            try? await lane.catchUp(selection: selection, protection: protection)
            commitState = .idle
            return .accepted(receipt)
        } catch {
            let failure = classify((error as? RejectedCaptureEncoding)?.cause ?? error)
            // The returned handle retains frozen input rejected before envelope admission.
            if commitState.owned?.sealed == nil, failure == .staleCapture || error is RejectedCaptureEncoding {
                commitState = .idle
            }
            return .pending(handle, failure)
        }
    }
}

func classify(_ error: Error) -> StorageError {
    if error is CancellationError { return .cancelled }
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
        guard a.kind == capture.kind, a.scope == capture.scope, a.affected.count == capture.covered.count,
              a.members.count == capture.changes.count + capture.changes.filter({ if case .delete = $0 { capture.before[$0.covered.birth]?.identity != nil } else { false } }).count else { throw StorageError.integrity }
        guard a.restorations.count == capture.restorations.count else { throw StorageError.integrity }
        for source in capture.restorations {
            let priorState = try source.priorState?.expanded(operations: [])
            guard case .external(_, _, let deletion) = source.deletionAction,
                  case .external(_, _, let revision) = source.revision,
                  a.restorations.contains(where: { $0.birth == source.birth && $0.sourceBirth == source.sourceBirth
                      && $0.deletionAction == deletion && $0.revision == revision
                      && $0.priorState == priorState }) else { throw StorageError.integrity }
        }
        let memberOperations = try a.members.map { id in
            guard let value = try operation(id, selection: selection, protection: protection) else { throw StorageError.incomplete }; return value
        }
        guard a.details == (try capture.details?.canonical(operations: memberOperations, actions: []).expanded(operations: memberOperations, actions: [])) else { throw StorageError.integrity }
        for (index, change) in capture.changes.enumerated() {
            guard let affected = a.affected.first(where: { $0.birth == change.covered.birth }),
                  affected.before == (capture.before[change.covered.birth]?.state ?? .freshBirthAbsence) else { throw StorageError.integrity }
            let id: OperationID
            if capture.kind == .nativeUndo { id = a.members[index] }
            else { switch affected.after { case .value(let value), .deleted(let value): id = value; default: throw StorageError.integrity } }
            guard let op = try operation(id, selection: selection, protection: protection),
                  op.effect.targetBirth == change.covered.birth, op.effect.actionID == capture.action else { throw StorageError.integrity }
            switch (change, op.effect) {
            case (.create(_, let value), .create(_, _, let saved)), (.put(_, let value), .put(_, _, let saved)),
                 (.put(_, let value), .adoptAutomatic(_, _, _, let saved)),
                 (.create(_, let value), .recoverCopy(_, _, _, let saved)), (.put(_, let value), .recoverCopy(_, _, _, let saved)):
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
    func validateCapture(_ capture: CapturedActionGroup, selection: LocalStoreSelection, protection: ObjectProtectionV1) throws {
        guard (capture.reservedNonce == nil) == (capture.pendingBinding == nil),
              capture.reservedNonce == nil || capture.changes.count == 1 else { throw StorageError.integrity }
        if let binding = capture.pendingBinding { try checkPendingCapture(binding, selection: selection) }
        let meta = try rows("SELECT epoch,through_seq,authoring_context FROM view_meta WHERE singleton=1")
        let accepted = try acceptedThrough()
        let currentBasis = meta == [[.blob(capture.viewEpoch), .integer(capture.through), .blob(capture.context.encodedV1())]] && accepted == capture.through
        // An independently captured edit keeps the exact originating automatic value
        // when newer coverage has retired only its derived presentation.
        let capturedAutomaticEdit = capture.changes.count == 1 && [.savedEdit, .rename, .labels].contains(capture.kind)
            && capture.changes.allSatisfy { change in
                if case .put = change { return capture.before[change.covered.birth]?.automatic != nil }; return false
            }
        guard presentationEpoch == capture.presentationEpoch, meta.count == 1,
              meta[0][0] == .blob(capture.viewEpoch),
              currentBasis || (capturedAutomaticEdit && capture.through > 0 && capture.through < accepted) else { throw StorageError.staleCapture }
        for change in capture.changes {
            let birth = change.covered.birth
            let r = try rows("SELECT cell FROM current_notes WHERE birth=?", [.blob(birth.bytes)])
            let cell = try r.first.map { try presentedCell(currentCell($0[0].bytes), selection: selection, protection: protection) }
            guard cell == capture.before[birth] || (capturedAutomaticEdit && cell == nil),
                  presentationEpoch == capture.presentationEpoch else { throw StorageError.staleCapture }
        }
    }
}

private func sealCapture(_ capture: CapturedActionGroup, collection: CollectionID, writer: WriterEpoch,
    sequence: UInt64, origin: ActionOriginID, previous: StoredActionReferenceV1?, protection: ObjectProtectionV1) throws -> SealedCommit {
    var deps = Set(capture.context.operations.map(\.locator)), records: [OperationRecordV1] = []
    var affected: [ActionAffectedReference] = []
    let scope = capture.scope == .collection ? capture.context.collectionActions : (capture.before[capture.covered[0].birth]?.scopeFrontier ?? [])
    deps.formUnion(scope.map(\.locator)); if let previous { deps.insert(previous.locator) }
    for source in capture.restorations {
        if case .external(let locator, _, _) = source.deletionAction { deps.insert(locator) }
        if case .external(let locator, _, _) = source.revision { deps.insert(locator) }
        if case .derived(let state) = source.priorState { deps.formUnion(state.externalLocators) }
        if case .automatic(let state) = source.priorState, case .external(let loc, _, _) = state.revision { deps.insert(loc) }
    }
    for ref in capture.details?.operationReferences ?? [] { if case .external(let loc, _, _) = ref { deps.insert(loc) } }
    for ref in capture.details?.actionReferences ?? [] { if case .external(let loc, _, _) = ref { deps.insert(loc) } }
    for change in capture.changes {
        let n = records.count
        let birth = change.covered.birth, old = capture.before[birth]
        if let old { deps.formUnion(old.heads.map(\.locator)); deps.formUnion(old.derived?.externalLocators ?? []) }
        let effect: OperationEffectV1
        switch change {
        case .create(_, let value), .put(_, let value):
            if case .copy(let source, let revision, let key, let slot, let reused) = capture.details,
               case .external(_, _, let sourceID) = revision {
                let reusedID: OperationID?
                if case .external(_, _, let id) = reused { reusedID = id } else { reusedID = nil }
                effect = .recoverCopy(action: capture.action, birth: birth, source: .init(birth: source, revision: sourceID, key: key, slot: slot, reused: reusedID), value: value)
            } else if let automatic = old?.automatic {
                guard case .automatic(let source) = old?.state else { throw StorageError.integrity }
                deps.formUnion([old!.revision.locator]); _ = automatic
                effect = .adoptAutomatic(action: capture.action, birth: birth, source: source, value: value)
            } else if case .create = change { effect = .create(action: capture.action, birth: birth, value: value) }
            else { effect = .put(action: capture.action, birth: birth, value: value) }
        case .delete: effect = .delete(action: capture.action, birth: birth)
        }
        let parentIDs = n == 0 ? capture.context.operations.map(\.id) : [records[n-1].operation.id]
        let parentRefs = n == 0 ? capture.context.operations.map(\.reference) : [.earlierLocal(index: OperationIndex(UInt32(n-1)))]
        let noteRefs: [OperationReference]
        let noteIDs: [OperationID]
        if case .put = effect {
            if capture.kind == .nativeUndo, let previous = records.lastIndex(where: { $0.operation.effect.targetBirth == birth }) {
                noteRefs = [.earlierLocal(index: OperationIndex(UInt32(previous)))]; noteIDs = [records[previous].operation.id]
            } else {
                let inputs = capture.kind == .conflictChoice ? (old?.heads ?? []) : (old?.represented ?? [])
                noteRefs = inputs.map(\.reference); noteIDs = inputs.map(\.id)
            }
        } else { noteRefs = []; noteIDs = [] }
        let op = try IdentifiedOperation(nonce: capture.reservedNonce ?? OperationNonce(bytes: uuidBytes()), effect: effect,
            causalParents: CausalParentSet(parentIDs), notePredecessors: NotePredecessorSet(noteIDs))
        records.append(try OperationRecordV1(operation: op, causalReferences: parentRefs, noteReferences: noteRefs,
            earlierOperations: records.map(\.operation)))
        let afterRef = OperationReference.earlierLocal(index: OperationIndex(UInt32(n)))
        let nextAffected = ActionAffectedReference(birth: birth, before: old?.stateReference ?? .freshBirthAbsence,
            after: { if case .delete = change { ActionStateReference.deleted(afterRef) } else { .value(afterRef) } }())
        if let previous = affected.firstIndex(where: { $0.birth == birth }) { affected[previous] = nextAffected }
        else { affected.append(nextAffected) }
        if case .delete = change, let identity = old?.identity {
            let retirement = try IdentifiedOperation(nonce: OperationNonce(bytes: uuidBytes()), effect: .retireConflict(action: capture.action, birth: birth, identity: identity),
                causalParents: CausalParentSet([op.id]), notePredecessors: NotePredecessorSet([]))
            records.append(try OperationRecordV1(operation: retirement, causalReferences: [.earlierLocal(index: OperationIndex(UInt32(n)))], noteReferences: [], earlierOperations: records.map(\.operation)))
        }
    }
    let action = try ActionRecordV1(id: capture.action, origin: origin, previousOrigin: previous?.reference,
        scope: capture.scope, scopeParents: scope.map(\.reference), kind: capture.kind,
        members: records.indices.map { OperationIndex(UInt32($0)) }, affected: affected,
        operations: records.map(\.operation), earlierActions: [], restorations: capture.restorations, details: capture.details)
    let payload = try ChangesPayloadV1(dependencies: DependencyLocatorTable(Array(deps)), operations: records, actions: [action])
    let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: collection,
        writer: writer, sequence: sequence, protection: protection)
    let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
    return SealedCommit(payload: payload, bytes: bytes, locator: locator)
}

/// Independent source heads still requiring an explicit preservation or choice.
public struct ConflictRevisions: Sendable {
    public let current: CurrentNoteCellV1
    public let alternatives: [IdentifiedOperation]
    public let representedSeparately: Set<OperationID>
    fileprivate init(current: CurrentNoteCellV1, alternatives: [IdentifiedOperation], representedSeparately: Set<OperationID>) {
        self.current = current; self.alternatives = alternatives; self.representedSeparately = representedSeparately
    }
}

/// Calculates one frozen command on a dedicated execution resource while callers keep running.
private actor CommandWorker {
    nonisolated let executor = StorageExecutor(label: "org.notationalvelocity.storage.command", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    func perform<T: Sendable>(_ work: @Sendable () throws -> T) rethrows -> T { try work() }
}

extension LocalStoreSession {
    /// Captures a consistent current prefix together with its retained graph.
    func commandBasis() async throws -> (StoreSnapshot, RetainedGraph) {
        guard !closed, !quiescing else { throw StorageError.closed }
        let snapshot = try await snapshot()
        let graph = try await lane.retainedGraph(through: snapshot.through, selection: selection, protection: protection)
        guard !closed else { throw StorageError.closed }
        return (snapshot, graph)
    }

    /// Calculates commands from immutable inputs while the collection owner serves saves.
    func commandWork<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        guard !closed, !quiescing else { throw StorageError.closed }
        let gate = try await lane.perform { $0.work?.commandCheck }
        let worker = Task.detached {
            try await CommandWorker().perform {
                try Task.checkCancellation()
                gate?()
                let result = try work()
                try Task.checkCancellation()
                return result
            }
        }
        let result = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
        guard !closed, !quiescing else { throw StorageError.closed }
        try Task.checkCancellation()
        let selection = selection
        try await lane.perform { try $0.validateHeader(store: selection.store, descriptor: selection.descriptor) }
        guard !closed, !quiescing else { throw StorageError.closed }
        try Task.checkCancellation()
        return try await lane.perform { db in try db.checkingRetainedHistory { try result.get() } }
    }

    public func conflicts(for birth: NoteBirth) async throws -> ConflictRevisions {
        return try await lane.verifyingHistory {
            guard !closed, !quiescing else { throw StorageError.closed }
            let snapshot = try await snapshot(), lane = lane, selection = selection
            guard let cell = snapshot.notes.first(where: { $0.birth == birth }) else { throw StorageError.incomplete }
            let checked = try await CheckedQueryHistory.read(scope: .conflicts(birth), snapshot: snapshot, session: incarnation,
                lane: lane, selection: selection, protection: protection)
            let inputs = try await lane.perform { try checked.conflicts(for: birth, snapshot: snapshot, database: $0, selection: selection) }
            let result = try await commandWork {
                ConflictRevisions(current: cell, alternatives: inputs.alternatives, representedSeparately: inputs.dispositions)
            }
            try await lane.perform { try checked.check(scope: .conflicts(birth), snapshot: snapshot, database: $0, selection: selection) }
            return result
        }
    }

    /// Freezes an explicit source-body selection over exactly the captured source heads.
    public func chooseVersion(for birth: NoteBirth, revision: OperationID, generation: UInt64) async throws -> CapturedActionGroup {
        return try await lane.verifyingHistory {
            let (snapshot, graph) = try await commandBasis()
            guard let cell = snapshot.notes.first(where: { $0.birth == birth }), cell.heads.contains(where: { $0.id == revision }),
                  let selected = graph.operations[revision]?.effect.noteValue, let ref = graph.operationReferences[revision] else { throw StorageError.staleCapture }
            let value = try PlaintextNoteValue(title: cell.value.title, body: selected.body, labels: cell.value.labels, created: cell.value.created, modified: cell.value.modified)
            return try CapturedActionGroup(snapshot: snapshot,
                intent: .choice(selected: ref.reference, heads: cell.heads.map(\.reference)),
                changes: [.put(.init(birth: birth, generation: generation), value)])
        }
    }

    /// Freezes one body-bound slot and its exact reusable-or-new preservation result.
    public func copyVersion(for source: NoteBirth, revision: OperationID, generation: UInt64) async throws -> CapturedActionGroup {
        return try await lane.verifyingHistory {
            let (snapshot, graph) = try await commandBasis()
            let collection = selection.descriptor.collection
            return try await commandWork {
                guard let original = graph.operations[revision], original.effect.targetBirth == source,
                      let value = original.effect.noteValue, let ref = graph.operationReferences[revision],
                      snapshot.notes.first(where: { $0.birth == source })?.heads.contains(where: { $0.id == revision }) == true else { throw StorageError.staleCapture }
                let state = try CollectionReductionV1.compute(collection: collection, operations: Array(graph.operations.values), actions: Array(graph.actions.values))
                let key = try ConflictRecoveryKeyV1.compute(source: source, body: value.body)
                var slot: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let identity = DeterministicConflictIdentityV1.recovery(key, slot: slot), birth = try identity.birth()
                    if !state.retired.contains(identity) {
                        if let cell = snapshot.notes.first(where: { $0.birth == birth }) {
                            if cell.identity == identity, cell.represented.count == 1,
                               cell.value.body.string.precomposedStringWithCanonicalMapping == value.body.string.precomposedStringWithCanonicalMapping {
                                return try CapturedActionGroup(snapshot: snapshot,
                                    intent: .copy(source: source, revision: ref.reference, key: key, slot: slot, reused: cell.revision.reference),
                                    changes: [.put(.init(birth: birth, generation: generation), cell.value)])
                            }
                        } else if !graph.operations.values.contains(where: { $0.effect.targetBirth == birth }) {
                            return try CapturedActionGroup(snapshot: snapshot,
                                intent: .copy(source: source, revision: ref.reference, key: key, slot: slot, reused: nil),
                                changes: [.create(.init(birth: birth, generation: generation), value.conflictCopyValue())])
                        }
                    }
                    guard slot < UInt64(graph.operations.count) + 1 else { throw StorageError.integrity }; slot += 1
                }
            }
        }
    }

    /// Makes a new independent body-recovery action or a fresh full-value history copy.
    public func recoverHistory(_ entry: HistoryEntry, to birth: NoteBirth, generation: UInt64, separate: Bool = false,
                               fields: HistoryFieldsV1 = .body) async throws -> CapturedActionGroup {
        return try await lane.verifyingHistory {
            let preview = try await preview(entry)
            guard case .value(let original) = preview.state, let value = original.effect.noteValue else { throw StorageError.unsupported }
            let (snapshot, graph) = try await commandBasis()
            guard let ref = graph.operationReferences[original.id] else { throw StorageError.incomplete }
            let change: CapturedNoteChange
            if separate { change = try .create(.init(birth: birth, generation: generation), value) }
            else {
                guard let current = snapshot.notes.first(where: { $0.birth == birth }) else { throw StorageError.staleCapture }
                change = try .put(.init(birth: birth, generation: generation), PlaintextNoteValue(title: fields.contains(.title) ? value.title : current.value.title,
                    body: fields.contains(.body) ? value.body : current.value.body, labels: fields.contains(.labels) ? value.labels : current.value.labels,
                    created: current.value.created, modified: current.value.modified))
            }
            return try CapturedActionGroup(snapshot: snapshot,
                intent: .historical(source: original.effect.targetBirth!, revision: ref.reference, fields: separate ? .all : fields),
                changes: [change], scope: separate ? .collection : .note(birth))
        }
    }
}
