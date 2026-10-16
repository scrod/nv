import Foundation
import Crypto
import NVStorageCore

/// Latest-reference generation checked independently of frozen admitted inputs.
public struct PendingItemState: Sendable {
    public let id: PendingItemID
    public let generation: Int64
    public let latest: PendingSnapshotID?
    fileprivate let store: LocalStoreID
    fileprivate let session: UUID
    fileprivate init(id: PendingItemID, generation: Int64, latest: PendingSnapshotID?, store: LocalStoreID, session: UUID) {
        self.id = id; self.generation = generation; self.latest = latest; self.store = store; self.session = session
    }
}

/// Recovery classifies retained preparation independently of the note's present liveness.
public enum PendingReservationRecovery: Sendable {
    case review(PendingReservationV1)
    case committed(PendingReservationV1, OperationID)
    case blocked(PendingReservationID, StorageError)
}

/// A settled observation keeps its admitted identity after payload release and later Delete.
public struct PendingSettlement: Sendable {
    public let record: PendingSettlementV1
    public var snapshot: PendingSnapshotID { record.reservation.snapshot }
    public var birth: NoteBirth { record.reservation.birth }
    public var operation: OperationID? {
        if case .operation(let id, _, _, _) = record.reservation.effect { id } else { nil }
    }
    public var observation: PassivePlatformRecordV1 { record.outcome.observation }
    fileprivate init(record: PendingSettlementV1) { self.record = record }
}

/// Store-issued preparation carrying a reserved identity into ordinary history admission.
public struct PreparedPendingAction: Sendable {
    public let reservation: PendingReservationV1
    fileprivate let capture: CapturedActionGroup
    fileprivate init(reservation: PendingReservationV1, capture: CapturedActionGroup) {
        self.reservation = reservation; self.capture = capture
    }
}

/// Association either preserves the checked Current or admits one content-changing Put.
public enum PendingAssociationPreparation: Sendable {
    case neutral(PendingReservationV1)
    case changed(PreparedPendingAction)
}

/// Exact latest generation consumed by the ordinary commit's admission transaction.
struct PendingAdmissionBinding: Sendable {
    let item: PendingItemID
    let generation: Int64
    let reservation: PendingReservationV1
    fileprivate init(item: PendingItemID, generation: Int64, reservation: PendingReservationV1) {
        self.item = item; self.generation = generation; self.reservation = reservation
    }
}

extension LocalStoreSession {
    /// Reserves a fresh ordinary Create and records whether classification or a manual command requested it.
    public func preparePendingImport(basedOn state: PendingItemState, automatic: Bool,
                                     birth: NoteBirth? = nil, generation: UInt64 = 1) async throws -> PreparedPendingAction {
        try checkPendingState(state)
        guard let latest = state.latest else { throw StorageError.incomplete }
        let input = try await retainedPendingSnapshot(latest), current = try await snapshot()
        let prior = try await reusableReservation(item: state.id, snapshot: latest)
        let target = try birth ?? prior?.birth ?? NoteBirth(bytes: uuidBytes()), action = try ActionID(bytes: uuidBytes())
        let nonce = try OperationNonce(bytes: uuidBytes())
        let op = try IdentifiedOperation(nonce: nonce, effect: .create(action: action, birth: target, value: input.value),
            causalParents: CausalParentSet(current.context.operations.map(\.id)), notePredecessors: NotePredecessorSet([]))
        let r = try PendingReservationV1(id: PendingReservationID(bytes: uuidBytes()), snapshot: latest,
            decision: automatic ? .automaticImport : .explicitImport, birth: target,
            effect: .operation(id: op.id, nonce: nonce, action: action, result: input.value.digestV1()))
        let reserved = try await reservePending(r, basedOn: state)
        let capture = try CapturedActionGroup(snapshot: current, intent: .ordinary(.createImportBatch),
            changes: [.create(CapturedNoteGeneration(birth: target, generation: generation), input.value)], actionID: action,
            reservedNonce: nonce, pendingBinding: PendingAdmissionBinding(item: state.id, generation: reserved.generation, reservation: r))
        return PreparedPendingAction(reservation: r, capture: capture)
    }

    public func preparePendingAssociation(basedOn state: PendingItemState, birth: NoteBirth,
                                          generation: UInt64) async throws -> PendingAssociationPreparation {
        try checkPendingState(state)
        guard let latest = state.latest else { throw StorageError.incomplete }
        let input = try await retainedPendingSnapshot(latest), current = try await snapshot()
        guard let cell = current.notes.first(where: { $0.birth == birth }) else { throw StorageError.staleCapture }
        _ = try await reusableReservation(item: state.id, snapshot: latest)
        let reservationID = try PendingReservationID(bytes: uuidBytes())
        if cell.value == input.value {
            let r = try PendingReservationV1(id: reservationID, snapshot: latest, decision: .neutralAssociation,
                birth: birth, effect: .neutral(PendingNeutralStateV1(cell: cell)))
            try await reservePending(r, basedOn: state)
            return .neutral(r)
        }
        let action = try ActionID(bytes: uuidBytes()), nonce = try OperationNonce(bytes: uuidBytes())
        let effect: OperationEffectV1
        if case .automatic(let source) = cell.state { effect = .adoptAutomatic(action: action, birth: birth, source: source, value: input.value) }
        else { effect = .put(action: action, birth: birth, value: input.value) }
        let predecessors = if case .put = effect { cell.represented.map(\.id) } else { [OperationID]() }
        let op = try IdentifiedOperation(nonce: nonce, effect: effect,
            causalParents: CausalParentSet(current.context.operations.map(\.id)), notePredecessors: NotePredecessorSet(predecessors))
        let r = try PendingReservationV1(id: reservationID, snapshot: latest, decision: .changedAssociation, birth: birth,
            effect: .operation(id: op.id, nonce: nonce, action: action, result: input.value.digestV1()))
        let reserved = try await reservePending(r, basedOn: state)
        let capture = try CapturedActionGroup(snapshot: current, intent: .ordinary(.savedEdit),
            changes: [.put(CapturedNoteGeneration(birth: birth, generation: generation), input.value)], actionID: action,
            reservedNonce: nonce, pendingBinding: PendingAdmissionBinding(item: state.id, generation: reserved.generation, reservation: r))
        return .changed(PreparedPendingAction(reservation: r, capture: capture))
    }

    private func reusableReservation(item: PendingItemID, snapshot: PendingSnapshotID) async throws -> PendingReservationV1? {
        for recovery in try await pendingRecovery(item) {
            switch recovery {
            case .review(let r) where r.snapshot == snapshot: return r
            case .committed(let r, _) where r.snapshot == snapshot: throw StorageError.staleCapture
            case .blocked(_, let error): throw error
            default: break
            }
        }
        return nil
    }

    public func persistPendingAction(_ prepared: PreparedPendingAction) async throws -> CommitOutcome {
        try await persist(capture: prepared.capture)
    }
    public func pendingItem(_ id: PendingItemID) async throws -> PendingItemState {
        guard !closed else { throw StorageError.closed }
        let store = selection.store, session = incarnation
        return try await lane.perform { db in
            let row = try db.pendingItemRow(id)
            return try PendingItemState(id: id, generation: row?[0].number ?? 0,
                latest: row.flatMap { if case .blob(let b) = $0[1] { try PendingSnapshotID(bytes: b) } else { nil } },
                store: store, session: session)
        }
    }

    /// Installs a complete latest payload/reference pair while independent frozen references remain owned.
    public func retainPendingSnapshot(_ snapshot: PendingSnapshotV1, basedOn state: PendingItemState) async throws {
        try checkPendingState(state)
        let selection = selection, bytes = snapshot.encodedV1()
        try await lane.perform { db in
            try db.checkPrivateScope(snapshot.scope, selection: selection)
            guard snapshot.presence == .present else { throw StorageError.staleCapture }
            try db.transaction {
                try db.checkPendingGeneration(state)
                guard try db.rows("SELECT 1 FROM pending_settlements WHERE item_id=? AND snapshot_id=?",
                    [.blob(state.id.bytes), .blob(snapshot.id.bytes)]).isEmpty else { throw StorageError.staleCapture }
                let old = try db.rows("SELECT codec,encoded FROM pending_payloads WHERE snapshot_id=?", [.blob(snapshot.id.bytes)])
                guard old.isEmpty || old == [[.integer(1), .blob(bytes)]] else { throw StorageError.integrity }
                if old.isEmpty { try db.run("INSERT INTO pending_payloads VALUES(?,1,?)", [.blob(snapshot.id.bytes), .blob(bytes)]) }
                guard state.generation < Int64.max else { throw StorageError.limit }
                try db.run("INSERT INTO pending_items VALUES(?,?,?,1) ON CONFLICT(item_id) DO UPDATE SET generation=excluded.generation,latest=excluded.latest,status=1",
                    [.blob(state.id.bytes), .integer(state.generation + 1), .blob(snapshot.id.bytes)])
            }
            if let previous = state.latest, previous != snapshot.id { try? db.releaseUnreferencedPending(previous) }
        }
    }

    public func retainedPendingSnapshot(_ id: PendingSnapshotID) async throws -> PendingSnapshotV1 {
        guard !closed else { throw StorageError.closed }
        let selection = selection
        return try await lane.perform { try $0.pendingSnapshot(id, selection: selection) }
    }

    /// Retains the exact prospective operation identity before the host admits its action.
    @discardableResult
    public func reservePending(_ reservation: PendingReservationV1, basedOn state: PendingItemState) async throws -> PendingItemState {
        try checkPendingState(state)
        guard !inFlight, commitState.owned == nil else { throw StorageError.busy }
        guard !pendingPreparationInFlight else { throw StorageError.busy }
        pendingPreparationInFlight = true
        defer {
            pendingPreparationInFlight = false
            let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() }
        }
        let selection = selection, protection = protection, session = incarnation
        return try await lane.perform { db in
            _ = try db.pendingSnapshot(reservation.snapshot, selection: selection)
            let replacements = try db.rows("SELECT reservation_id FROM pending_reservations WHERE item_id=? AND snapshot_id=?",
                [.blob(state.id.bytes), .blob(reservation.snapshot.bytes)])
            // Read retained history under its durable verification scope before starting the mutation transaction.
            for row in replacements where row[0] != .blob(reservation.id.bytes) {
                let prior = try db.pendingReservation(PendingReservationID(bytes: row[0].bytes), item: state.id, selection: selection)
                guard try db.pendingOperation(prior, selection: selection, protection: protection) == nil else { throw StorageError.staleCapture }
            }
            return try db.transaction {
                try db.checkPendingGeneration(state)
                guard state.latest == reservation.snapshot else { throw StorageError.staleCapture }
                let expected: [SQLValue] = [.blob(state.id.bytes), .blob(reservation.snapshot.bytes), reservation.operationSQL, .integer(1), .blob(reservation.encodedV1())]
                let old = try db.rows("SELECT item_id,snapshot_id,operation_id,codec,encoded FROM pending_reservations WHERE reservation_id=?", [.blob(reservation.id.bytes)])
                guard old.isEmpty || old == [expected] else { throw StorageError.integrity }
                if !old.isEmpty { return state }
                guard try db.rows("SELECT reservation_id FROM pending_reservations WHERE item_id=? AND snapshot_id=?",
                    [.blob(state.id.bytes), .blob(reservation.snapshot.bytes)]) == replacements else { throw StorageError.staleCapture }
                for row in replacements {
                    try db.run("DELETE FROM pending_reservations WHERE reservation_id=?", [row[0]])
                }
                guard state.generation < Int64.max else { throw StorageError.limit }
                try db.run("INSERT INTO pending_reservations VALUES(?,?,?,?,?,?)", [.blob(reservation.id.bytes)] + expected)
                try db.run("UPDATE pending_items SET generation=generation+1 WHERE item_id=?", [.blob(state.id.bytes)])
                return PendingItemState(id: state.id, generation: state.generation + 1, latest: state.latest,
                    store: selection.store, session: session)
            }
        }
    }

    /// Uses indexed exact operation membership; an unused reservation reopens for review.
    public func pendingRecovery(_ item: PendingItemID) async throws -> [PendingReservationRecovery] {
        guard !closed else { throw StorageError.closed }
        let selection = selection, protection = protection
        return try await lane.perform { db in
            let rows = try db.rows("SELECT reservation_id FROM pending_reservations WHERE item_id=? ORDER BY reservation_id", [.blob(item.bytes)])
            return try rows.map { row in
                let id = try PendingReservationID(bytes: row[0].bytes)
                do {
                    let r = try db.pendingReservation(id, item: item, selection: selection)
                    if try db.pendingOperation(r, selection: selection, protection: protection) != nil,
                       case .operation(let op, _, _, _) = r.effect { return .committed(r, op) }
                    return .review(r)
                } catch { return .blocked(id, classify(error)) }
            }
        }
    }

    /// Transfers an admitted observation to durable settlement after the host's fresh applicability check.
    /// The callback supplies the platform observation while storage verifies represented history.
    public func completePendingAssociation(_ reservation: PendingReservationID, basedOn state: PendingItemState,
        revalidate: @escaping @Sendable (PendingSnapshotV1, Bool) throws -> PassivePlatformRecordV1) async throws {
        try checkPendingState(state)
        let selection = selection, protection = protection
        try await lane.perform { db in
            try db.checkPendingGeneration(state)
            let r = try db.pendingReservation(reservation, item: state.id, selection: selection)
            let input = try db.pendingSnapshot(r.snapshot, selection: selection)
            let operation = try db.pendingOperation(r, selection: selection, protection: protection)
            guard try db.rows("SELECT reducer_version,through_seq FROM view_meta WHERE singleton=1") ==
                [[.integer(1), .integer(db.acceptedThrough())]] else { throw StorageError.incomplete }
            let current = try db.rows("SELECT cell FROM current_notes WHERE birth=?", [.blob(r.birth.bytes)])
                .first.map { try db.currentCell($0[0].bytes) }
            let matches: Bool
            switch r.effect {
            case .operation(_, _, _, let digest):
                guard operation != nil else { throw StorageError.incomplete }
                matches = try current?.value.digestV1() == digest
            case .neutral(let state):
                guard let current, try state.matches(current), input.value == current.value else { throw StorageError.staleCapture }
                matches = true
            }
            let observation = try revalidate(input, matches)
            let digest = Array(SHA256.hash(data: r.encodedV1()))
            let settlement = try PendingSettlementV1(scope: input.scope, item: state.id, reservation: r,
                outcome: .consumed(observation), subsequentSnapshot: state.latest == r.snapshot ? nil : state.latest)
            let encoded = try settlement.encodedV1()
            try db.transaction {
                try db.checkPendingGeneration(state)
                try db.run("INSERT INTO pending_settlements VALUES(?,?,?,?,?,?,?,?)",
                    [.blob(state.id.bytes), .blob(r.snapshot.bytes), .blob(r.id.bytes), r.operationSQL,
                     .blob(r.birth.bytes), .blob(digest), .integer(1), .blob(encoded)])
                try db.run("DELETE FROM pending_reservations WHERE reservation_id=?", [.blob(r.id.bytes)])
                guard state.generation < Int64.max else { throw StorageError.limit }
                if state.latest == r.snapshot {
                    try db.run("UPDATE pending_items SET generation=generation+1,latest=NULL,status=3 WHERE item_id=?", [.blob(state.id.bytes)])
                } else {
                    try db.run("UPDATE pending_items SET generation=generation+1 WHERE item_id=?", [.blob(state.id.bytes)])
                }
            }
            try? db.releaseUnreferencedPending(r.snapshot)
        }
    }

    public func pendingSettlement(item: PendingItemID, snapshot: PendingSnapshotID) async throws -> PendingSettlement? {
        guard !closed else { throw StorageError.closed }
        let selection = selection
        return try await lane.perform { db in
            try db.pendingSettlementRecord(item: item, snapshot: snapshot, selection: selection).map { PendingSettlement(record: $0) }
        }
    }

    private func checkPendingState(_ state: PendingItemState) throws {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard state.store == selection.store, state.session == incarnation else { throw StorageError.wrongContext }
        cancelMaintenance()
    }
}

private extension PendingReservationV1 {
    var operationSQL: SQLValue { if case .operation(let id, _, _, _) = effect { .blob(id.bytes) } else { .null } }
}

extension Database {
    /// Checks indexed settlement identity against the complete retained decision and captured scope.
    func pendingSettlementRecord(item: PendingItemID, snapshot: PendingSnapshotID,
                                 selection: LocalStoreSelection) throws -> PendingSettlementV1? {
        guard let row = try rows("SELECT reservation_id,operation_id,birth,decision_digest,observation_codec,observation FROM pending_settlements WHERE item_id=? AND snapshot_id=?",
            [.blob(item.bytes), .blob(snapshot.bytes)]).first else { return nil }
        guard row[4] == .integer(1) else { throw StorageError.unsupported }
        let value: PendingSettlementV1
        do { value = try .decodeV1(row[5].bytes, profile: selection.descriptor.keyID == nil ? .plaintextFiles : .encryptedSegments) }
        catch CanonicalEncodingError.unsupportedFormat { throw StorageError.unsupported }
        catch { throw StorageError.integrity }
        let r = value.reservation
        guard value.item == item, r.snapshot == snapshot, row[0] == .blob(r.id.bytes), row[1] == r.operationSQL,
              row[2] == .blob(r.birth.bytes), row[3] == .blob(Array(SHA256.hash(data: r.encodedV1()))) else { throw StorageError.integrity }
        try checkCapturedPrivateScope(value.scope, selection: selection)
        if case .projection(let projection) = value.outcome { try checkCapturedPrivateScope(projection.scope, selection: selection) }
        return value
    }
    fileprivate func pendingItemRow(_ id: PendingItemID) throws -> [SQLValue]? {
        try rows("SELECT generation,latest,status FROM pending_items WHERE item_id=?", [.blob(id.bytes)]).first
    }
    fileprivate func checkPendingGeneration(_ state: PendingItemState) throws {
        let row = try pendingItemRow(state.id)
        guard try row?[0].number ?? 0 == state.generation,
              row?[1] ?? .null == state.latest.map({ .blob($0.bytes) }) ?? .null else { throw StorageError.staleCapture }
    }
    fileprivate func pendingSnapshot(_ id: PendingSnapshotID, selection: LocalStoreSelection) throws -> PendingSnapshotV1 {
        guard let row = try rows("SELECT codec,encoded FROM pending_payloads WHERE snapshot_id=?", [.blob(id.bytes)]).first else { throw StorageError.incomplete }
        guard row[0] == .integer(1) else { throw StorageError.unsupported }
        let result = try PendingSnapshotV1.decodeV1(row[1].bytes)
        guard result.id == id else { throw StorageError.integrity }
        try checkCapturedPrivateScope(result.scope, selection: selection)
        return result
    }
    fileprivate func pendingReservation(_ id: PendingReservationID, item: PendingItemID, selection: LocalStoreSelection) throws -> PendingReservationV1 {
        guard let row = try rows("SELECT item_id,snapshot_id,operation_id,codec,encoded FROM pending_reservations WHERE reservation_id=?", [.blob(id.bytes)]).first else { throw StorageError.incomplete }
        guard row[0] == .blob(item.bytes) else { throw StorageError.wrongContext }
        guard row[3] == .integer(1) else { throw StorageError.unsupported }
        let r = try PendingReservationV1.decodeV1(row[4].bytes)
        guard r.id == id, row[1] == .blob(r.snapshot.bytes), row[2] == r.operationSQL else { throw StorageError.integrity }
        _ = try pendingSnapshot(r.snapshot, selection: selection)
        return r
    }
    fileprivate func pendingOperation(_ r: PendingReservationV1, selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> IdentifiedOperation? {
        guard case .operation(let id, let nonce, let actionID, let result) = r.effect else { return nil }
        guard let op = try operation(id, selection: selection, protection: protection) else { return nil }
        guard op.nonce == nonce, op.effect.actionID == actionID, op.effect.targetBirth == r.birth,
              try op.effect.noteValue?.digestV1() == result,
              let action = try action(actionID, selection: selection, protection: protection), action.members.contains(id) else { throw StorageError.integrity }
        switch (r.decision, op.effect) {
        case (.automaticImport, .create), (.explicitImport, .create), (.changedAssociation, .put), (.changedAssociation, .adoptAutomatic): break
        default: throw StorageError.integrity
        }
        return op
    }
    fileprivate func releaseUnreferencedPending(_ id: PendingSnapshotID) throws {
        try transaction {
            try run("DELETE FROM pending_payloads WHERE snapshot_id=? AND NOT EXISTS(SELECT 1 FROM pending_items WHERE latest=?) AND NOT EXISTS(SELECT 1 FROM pending_reservations WHERE snapshot_id=?)",
                [.blob(id.bytes), .blob(id.bytes), .blob(id.bytes)])
        }
    }
    func checkPendingCapture(_ binding: PendingAdmissionBinding, selection: LocalStoreSelection) throws {
        guard let row = try pendingItemRow(binding.item), row[0] == .integer(binding.generation),
              row[1] == .blob(binding.reservation.snapshot.bytes) else { throw StorageError.staleCapture }
        guard try pendingReservation(binding.reservation.id, item: binding.item, selection: selection) == binding.reservation else {
            throw StorageError.integrity
        }
    }
}
