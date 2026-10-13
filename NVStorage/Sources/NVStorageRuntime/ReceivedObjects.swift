import NVStorageCore

/// Chooses the receive work needed before startup or by a live receive owner.
enum ReadyDrainPolicy: Sendable { case startupRequired, all }

public enum ObjectAcceptanceOutcome: Sendable {
    case pendingValidation
    case retainedForAssembly
    case waiting([ObjectRequirement])
    case blocked(prerequisites: [RejectedPrerequisite], unaccepted: [ObjectRequirement])
    case accepted(sequence: Int64)
}

/// A retained prerequisite's own validation result, exposed for receive diagnostics.
public struct RejectedPrerequisite: Equatable, Sendable {
    public let object: SegmentID
    public let reason: ReceiveRejection
}

extension LocalStoreSession {
    /// Retains received bytes, validates complete dependencies and wakes waiting work.
    public func receive(_ bytes: [UInt8]) async throws -> ObjectAcceptanceOutcome {
        try await receiveWithIdentity(bytes).outcome
    }

    /// Returns the checked envelope identity together with its ordinary receive outcome.
    func receiveWithIdentity(_ bytes: [UInt8]) async throws -> (locator: SegmentLocator, kind: ProviderObjectKind, outcome: ObjectAcceptanceOutcome) {
        guard !closed, !quiescing else { throw StorageError.closed }
        guard !receiving else { throw StorageError.busy }
        receiveState = .retaining
        cancelMaintenance()
        defer { receiveState = .idle; signalReceiveWaiters() }
        let selection = selection, protection = protection
        let opened = try await lane.historyWork {
            guard UInt64(bytes.count) <= ObjectLimitsV1.encodedPayloadBytes + 156 else { throw CanonicalEncodingError.lengthLimit }
            return try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
        }
        let completion = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            try db.transaction { try db.retainCandidate(bytes, opened: opened, ready: true) }
            return db.work?.receiveRetentionCompletion
        }
        receiveState = opened.kind == .changes ? .history : .optional
        signalReceiveWaiters()
        try await completion?(opened.locator)
        let accepted = try await resumeReceivedValidation(target: opened.locator)
        if let accepted { return (opened.locator, opened.kind, .accepted(sequence: accepted)) }
        guard !closed else { throw StorageError.closed }
        try await lane.catchUp(selection: selection, protection: protection)
        return try await (opened.locator, opened.kind, receivedObjectStatus(at: opened.locator))
    }

    /// Reconstructs exact waiting roles from retained bytes and current accepted membership.
    public func receivedObjectStatus(at locator: SegmentLocator) async throws -> ObjectAcceptanceOutcome {
        guard !closed else { throw StorageError.closed }
        let selection = selection, protection = protection
        if let accepted = try await lane.perform({ db -> Int64? in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            guard try db.snapshotCandidate(locator, collection: selection.descriptor.collection, protection: protection) != nil else { throw StorageError.incomplete }
            if let reason = try db.receivedRejection(.blob(locator.segmentID.bytes)) { throw reason.error }
            return try db.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).first?.first?.number
        }) { return .accepted(sequence: accepted) }
        do {
            let candidate = try await lane.prepareReceived(locator, selection: selection, protection: protection, recordingRejections: false)
            if case .page = candidate { return .retainedForAssembly }
            return .pendingValidation
        } catch let wait as ReceiveWait {
            let blockers = try await lane.rejectedPrerequisites(of: locator.segmentID, discovered: wait.requirements)
            return blockers.isEmpty ? .waiting(wait.requirements) : .blocked(prerequisites: blockers, unaccepted: wait.requirements)
        }
    }

    /// Keeps owned receive work moving after interfering saves finish.
    func signalReceiveWaiters() {
        let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() }
        signalTransportSettled()
    }
    func resumeReceivedValidation(target: SegmentLocator? = nil,
        candidateAllowed: (@Sendable (Int64) async -> Bool)? = nil) async throws -> Int64? {
        while true {
            do { return try await lane.drainReady(selection: selection, protection: protection, target: target,
                snapshotAllowed: { await self.lifecycle == .open }, candidateAllowed: candidateAllowed) }
            catch HistoryValidationInterrupted.historyAdvanced {
                while inFlight { await withCheckedContinuation { drained.append($0) } }
            }
        }
    }

    /// Reserves one live receive owner after checked host publication.
    func startPublishedReceiveWork() {
        guard lifecycle == .open, !receiving else { return }
        receiveState = .optional
        Task {
            defer { receiveState = .idle; signalReceiveWaiters() }
            do {
                let start = try await lane.perform { $0.work?.publishedReceiveStart }
                await start?()
                _ = try await resumeReceivedValidation(candidateAllowed: { await self.beginPublishedCandidate($0) })
            } catch {
                // Durable queue and verification records retain failed work for retry or reopening.
            }
        }
    }

    private func beginPublishedCandidate(_ kind: Int64) -> Bool {
        guard lifecycle == .open else { return false }
        receiveState = kind == 1 ? .history : .optional
        signalReceiveWaiters()
        return true
    }

    public func retainedObject(at locator: SegmentLocator) async throws -> [UInt8] {
        guard !closed else { throw StorageError.closed }
        let collection = selection.descriptor.collection, protection = protection
        return try await lane.perform { db in
            guard let (bytes, _) = try db.acceptedEnvelope(locator, collection: collection, protection: protection) else { throw StorageError.incomplete }
            return bytes
        }
    }
}

/// Complete preparation results consumed by the existing acceptance boundaries.
fileprivate enum PreparedCandidate: Sendable {
    case page
    case changes([UInt8])
    case general(GeneralSnapshotPreviewV1)
    case initial([SegmentLocator: [UInt8]])
}

extension DatabaseLane {
    /// Follows retained waiting edges in short turns, deduplicating shared ancestry.
    nonisolated func rejectedPrerequisites(of object: SegmentID, discovered: [ObjectRequirement] = []) async throws -> [RejectedPrerequisite] {
        var pending = [object] + discovered.map { $0.locator.segmentID }, visited: Set<SegmentID> = [], result: [RejectedPrerequisite] = []
        while let next = pending.popLast() {
            guard visited.insert(next).inserted else { continue }
            let (reason, parents) = try await perform { db in
                let id = SQLValue.blob(next.bytes), reason = try db.receivedRejection(id)
                let parents = try db.rows("SELECT prerequisite FROM object_waits WHERE child=?", [id]).map { try SegmentID(bytes: $0[0].bytes) }
                return (reason, parents)
            }
            if let reason { result.append(RejectedPrerequisite(object: next, reason: reason)) }
            pending.append(contentsOf: parents)
        }
        return result.sorted { $0.object.bytes.lexicographicallyPrecedes($1.object.bytes) }
    }

    /// Reads one exact assembly input, preserving a prerequisite's own failure independently.
    private nonisolated func assemblyBytes(_ locator: SegmentLocator, root: SegmentLocator,
        selection: LocalStoreSelection, protection: ObjectProtectionV1, recordingRejections: Bool,
        snapshotAllowed: (@Sendable () async -> Bool)? = nil) async throws -> [UInt8] {
        do {
            if let snapshotAllowed, await !snapshotAllowed() { throw StorageError.closed }
            let bytes = try await perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                if locator != root, try db.receivedRejection(.blob(locator.segmentID.bytes)) != nil { throw ReceiveWait(requirements: [.retainedBytes(locator)]) }
                guard let bytes = try db.snapshotCandidate(locator, collection: selection.descriptor.collection, protection: protection) else { throw ReceiveWait(requirements: [.retainedBytes(locator)]) }
                return bytes
            }
            _ = try await historyWork { try ReceivedPayload(ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection, expectedLocator: locator)) }
            return bytes
        } catch {
            // A bad address belongs to the referring input; intact target bytes keep their status.
            if locator != root, error as? CanonicalEncodingError != .invalidReference, let reason = ReceiveRejection(error) {
                try await perform { db in
                    try db.requireHealthyHistory()
                    if try !db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).isEmpty { return try db.checkingRetainedHistory { throw StorageError.integrity } }
                    if recordingRejections { try db.rejectReceived(.blob(locator.segmentID.bytes), reason: reason) }
                }
                throw ReceiveWait(requirements: [.retainedBytes(locator)])
            }
            throw error
        }
    }

    /// Discovers complete pages first, then checks their exact accepted-history requirements.
    fileprivate nonisolated func prepareReceived(_ locator: SegmentLocator, selection: LocalStoreSelection,
        protection: ObjectProtectionV1, recordingRejections: Bool = true,
        snapshotAllowed: (@Sendable () async -> Bool)? = nil) async throws -> PreparedCandidate {
        let bytes = try await assemblyBytes(locator, root: locator, selection: selection, protection: protection, recordingRejections: recordingRejections)
        let input = try await historyWork { try ReceivedPayload(ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection, expectedLocator: locator)) }
        switch input {
        case .page, .generalPage: return .page
        case .changes:
            let missing = try await perform { try $0.missingRequirements(input.requirements) }
            if !missing.isEmpty { throw ReceiveWait(requirements: missing) }
            return .changes(bytes)
        case .generalRoot:
            let preparation = try await perform { db in (db.work?.receiveRecordsPerTurn ?? 64, db.work?.snapshotPreparationYield) }
            let didYield: (@Sendable (Int) async -> Void)?
            if let hook = preparation.1 { didYield = { count in await hook(locator, count) } }
            else { didYield = nil }
            let preview = try await GeneralSnapshotPreviewV1.read(snapshot: locator, collection: selection.descriptor.collection, protection: protection,
                recordsPerTurn: preparation.0, didYield: didYield) { target in
                try await self.assemblyBytes(target, root: locator, selection: selection, protection: protection,
                    recordingRejections: recordingRejections, snapshotAllowed: snapshotAllowed)
            }
            let recordBytes = try preview.records.reduce(0) { try $0 + $1.encodedV1().count }
            try await perform { db in db.countWork { $0.snapshotRecords += preview.records.count; $0.snapshotRecordBytes += recordBytes } }
            guard !preview.retentionParents.contains(locator) else { throw CanonicalEncodingError.invalidReference }
            let requirements = preview.requiredLocators.sorted { $0.encodedV1().lexicographicallyPrecedes($1.encodedV1()) }.map(ObjectRequirement.acceptedHistory)
            // Attribute damaged retained targets before interpreting a referring root's address.
            for requirement in requirements {
                do {
                    _ = try await assemblyBytes(requirement.locator, root: locator, selection: selection, protection: protection,
                        recordingRejections: recordingRejections, snapshotAllowed: snapshotAllowed)
                } catch is ReceiveWait { continue }
            }
            let missing = try await perform { try $0.missingRequirements(requirements) }
            if !missing.isEmpty { throw ReceiveWait(requirements: missing) }
            return .general(preview)
        case .root:
            var objects = [locator: bytes], pending = input.requirements + [.acceptedHistory(selection.descriptor.genesis)]
            var seen: Set<ObjectRequirement> = [], missing: [ObjectRequirement] = []
            while let requirement = pending.popLast() {
                guard seen.insert(requirement).inserted else { continue }
                let unavailable = try await perform { try $0.missingRequirements([requirement]) }
                if !unavailable.isEmpty { missing += unavailable; continue }
                let target = requirement.locator
                let bytes = try await assemblyBytes(target, root: locator, selection: selection, protection: protection,
                    recordingRejections: recordingRejections, snapshotAllowed: snapshotAllowed)
                let payload = try await historyWork { try ReceivedPayload(ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection, expectedLocator: target)) }
                objects[target] = bytes; pending += payload.requirements
            }
            if !missing.isEmpty { throw ReceiveWait(requirements: missing) }
            return .initial(objects)
        }
    }

    /// Processes one candidate per writer turn; durable queue rows own unfinished work.
    nonisolated func drainReady(selection: LocalStoreSelection, protection: ObjectProtectionV1,
        target: SegmentLocator? = nil, policy: ReadyDrainPolicy = .all,
        snapshotAllowed: (@Sendable () async -> Bool)? = nil,
        candidateAllowed: (@Sendable (Int64) async -> Bool)? = nil) async throws -> Int64? {
        var acceptedTarget: Int64?
        while true {
            guard let locator = try await perform({ db -> SegmentLocator? in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                // Drive this lookup from ready work, keeping an empty queue independent of history size.
                let query: String
                switch policy {
                case .all:
                    query = "SELECT o.writer_epoch,o.sequence,o.object_id FROM ready_objects r CROSS JOIN objects o USING(object_id) LIMIT 1"
                case .startupRequired:
                    // Wait edges also expose snapshot prerequisites of parked Changes.
                    query = """
                        WITH RECURSIVE required(object_id) AS (
                            SELECT r.object_id FROM ready_objects r CROSS JOIN objects o USING(object_id) WHERE o.kind=1
                            UNION
                            SELECT w.child FROM object_waits w JOIN objects o ON o.object_id=w.child WHERE o.kind=1
                            UNION
                            SELECT w.prerequisite FROM object_waits w JOIN required q ON q.object_id=w.child
                        )
                        SELECT o.writer_epoch,o.sequence,o.object_id FROM ready_objects r
                        CROSS JOIN objects o USING(object_id)
                        WHERE r.object_id IN (SELECT object_id FROM required) LIMIT 1
                        """
                }
                guard let row = try db.rows(query).first else { return nil }
                return try SegmentLocator.decodeV1(row[0].bytes + row[1].bytes + row[2].bytes)
            }) else { return acceptedTarget }
            do {
                if try await perform({ try !$0.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).isEmpty }) {
                    try await perform { try $0.run("DELETE FROM ready_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]) }; continue
                }
                let kind = try await perform { try $0.rows("SELECT kind FROM objects WHERE object_id=?", [.blob(locator.segmentID.bytes)])[0][0].number }
                if let candidateAllowed, await !candidateAllowed(kind) { return acceptedTarget }
                if kind != 1, let snapshotAllowed, await !snapshotAllowed() { return acceptedTarget }
                let sequence: Int64?
                switch try await prepareReceived(locator, selection: selection, protection: protection, snapshotAllowed: kind == 1 ? nil : snapshotAllowed) {
                case .page:
                    try await perform { db in try db.transaction { try db.run("DELETE FROM ready_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]) } }
                    sequence = nil
                case .changes(let bytes): sequence = try await acceptScheduled(bytes, locator: locator, selection: selection, protection: protection)
                case .general(let preview): sequence = try await acceptGeneralSnapshot(locator, selection: selection, protection: protection, assembled: preview).0
                case .initial(let objects): sequence = try await acceptReceivedBootstrap(locator, objects: objects, selection: selection, protection: protection)
                }
                if locator == target { acceptedTarget = sequence }
            } catch let wait as ReceiveWait {
                let gate = try await perform { $0.work?.receiveDiscovered }
                await gate?(locator, wait.requirements)
                try await perform { db in
                    try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                    try db.parkReceived(locator, requirements: wait.requirements)
                }
            } catch {
                guard let reason = ReceiveRejection(error) else { throw error }
                try await perform { try $0.rejectReceived(.blob(locator.segmentID.bytes), reason: reason) }
            }
            do { try await catchUp(selection: selection, protection: protection) }
            catch StorageError.closed { if let acceptedTarget { return acceptedTarget }; throw StorageError.closed }
        }
    }
}

extension Database {
    func missing(_ locators: [SegmentLocator]) throws -> [SegmentLocator] {
        try missingRequirements(locators.map(ObjectRequirement.acceptedHistory)).map(\.locator)
    }
}
