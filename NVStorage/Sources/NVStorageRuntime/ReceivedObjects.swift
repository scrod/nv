import NVStorageCore
import Crypto

public enum ObjectAcceptanceOutcome: Sendable {
    case pendingValidation
    case waiting([SegmentLocator])
    case blocked(prerequisites: [RejectedPrerequisite], unaccepted: [SegmentLocator])
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
        guard !closed, !quiescing else { throw StorageError.closed }
        guard !receiving else { throw StorageError.busy }
        receiving = true
        defer { receiving = false; let waiters = drained; drained.removeAll(); for waiter in waiters { waiter.resume() } }
        let selection = selection, protection = protection
        let opened = try await lane.perform { db in
            guard UInt64(bytes.count) <= ObjectLimitsV1.encodedPayloadBytes + 156 else { throw CanonicalEncodingError.lengthLimit }
            let identifier = SQLValue.blob(Array(SHA256.hash(data: bytes)))
            if let reason = try db.receivedRejection(identifier) {
                guard try db.rows("SELECT encoded FROM objects WHERE object_id=?", [identifier]) == [[.blob(bytes)]] else {
                    throw StorageError.integrity
                }
                throw reason.error
            }
            let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
            guard opened.kind == .changes else { throw StorageError.unsupported }
            try db.transaction {
                let old = try db.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(opened.locator.segmentID.bytes)])
                if old.isEmpty {
                    try db.run("INSERT INTO objects VALUES(?,1,?,?,?)", [.blob(opened.locator.segmentID.bytes),
                        .blob(opened.locator.writerEpoch.bytes), .blob(Array(opened.locator.encodedV1()[16..<24])), .blob(bytes)])
                    try db.run("INSERT INTO ready_objects VALUES(?)", [.blob(opened.locator.segmentID.bytes)])
                } else if old != [[.blob(bytes)]] { throw StorageError.integrity }
            }
            return opened
        }
        try await resumeReceivedValidation()
        try await lane.catchUp(selection: selection, protection: protection)
        return try await receivedObjectStatus(at: opened.locator)
    }

    /// Reads queue, acceptance and dependency diagnostics for an exact retained candidate.
    public func receivedObjectStatus(at locator: SegmentLocator) async throws -> ObjectAcceptanceOutcome {
        guard !closed else { throw StorageError.closed }
        let selection = selection, protection = protection
        let outcome: ObjectAcceptanceOutcome = try await lane.perform { db in
            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
            let id = SQLValue.blob(locator.segmentID.bytes)
            guard let row = try db.rows("SELECT encoded FROM objects WHERE object_id=?", [id]).first else {
                throw StorageError.incomplete
            }
            let opened = try ObjectEnvelopeV1.open(row[0].bytes, collection: selection.descriptor.collection,
                protection: protection, expectedLocator: locator)
            if let reason = try db.receivedRejection(id) { throw reason.error }
            let accepted = try db.rows("SELECT seq FROM accepted_objects WHERE object_id=?", [id])
            if let row = accepted.first {
                return try .accepted(sequence: row[0].number)
            }
            let payload = try ChangesPayloadV1.decodeV1(opened.payload)
            let missing = try db.missing(payload.dependencies.entries)
            if missing.isEmpty {
                guard try !db.rows("SELECT 1 FROM ready_objects WHERE object_id=?", [id]).isEmpty else {
                    throw StorageError.integrity
                }
                return .pendingValidation
            }
            return .waiting(missing)
        }
        guard case .waiting(let unaccepted) = outcome else { return outcome }
        let blockers = try await lane.rejectedPrerequisites(of: locator.segmentID)
        return blockers.isEmpty ? outcome : .blocked(prerequisites: blockers, unaccepted: unaccepted)
    }

    /// Keeps owned receive work moving after interfering saves finish.
    func resumeReceivedValidation() async throws {
        while true {
            do {
                try await lane.drainReady(selection: selection, protection: protection)
                return
            } catch HistoryValidationInterrupted.historyAdvanced {
                while inFlight {
                    await withCheckedContinuation { drained.append($0) }
                }
            }
        }
    }

    public func retainedObject(at locator: SegmentLocator) async throws -> [UInt8] {
        guard !closed else { throw StorageError.closed }
        let collection = selection.descriptor.collection, protection = protection
        return try await lane.perform { db in
            guard let (bytes, _) = try db.acceptedEnvelope(locator, collection: collection, protection: protection) else {
                throw StorageError.incomplete
            }
            return bytes
        }
    }
}

private enum ReadyTurn: Sendable {
    case finished, parked
    case validate(SegmentLocator, [UInt8])
}

extension DatabaseLane {
    /// Follows retained waiting edges in short writer turns, deduplicating shared ancestry.
    nonisolated func rejectedPrerequisites(of object: SegmentID) async throws -> [RejectedPrerequisite] {
        var pending = [object], visited: Set<SegmentID> = [], result: [RejectedPrerequisite] = []
        while let next = pending.popLast() {
            guard visited.insert(next).inserted else { continue }
            let (reason, parents) = try await perform { db in
                let id = SQLValue.blob(next.bytes)
                let reason = try db.receivedRejection(id)
                let parents = try db.rows("SELECT prerequisite FROM object_waits WHERE child=?", [id])
                    .map { try SegmentID(bytes: $0[0].bytes) }
                return (reason, parents)
            }
            if let reason { result.append(RejectedPrerequisite(object: next, reason: reason)) }
            pending.append(contentsOf: parents)
        }
        return result.sorted { $0.object.bytes.lexicographicallyPrecedes($1.object.bytes) }
    }

    /// Processes one candidate per writer turn; durable queue rows own unfinished work.
    nonisolated func drainReady(selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws {
        while true {
            let turn = try await perform { db -> ReadyTurn in
                guard let ready = try db.rows("SELECT object_id FROM ready_objects LIMIT 1").first else { return .finished }
                guard let row = try db.rows("SELECT encoded FROM objects WHERE object_id=?", ready).first else { throw StorageError.incomplete }
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                do {
                    return try db.transaction {
                        if try !db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", ready).isEmpty {
                            try db.run("DELETE FROM ready_objects WHERE object_id=?", ready)
                            return .parked
                        }
                        let bytes = try row[0].bytes
                        let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
                        guard opened.locator.segmentID.bytes == (try ready[0].bytes), opened.kind == .changes else { throw StorageError.unsupported }
                        let payload = try ChangesPayloadV1.decodeV1(opened.payload)
                        let missing = try db.missing(payload.dependencies.entries)
                        guard !missing.isEmpty else { return .validate(opened.locator, bytes) }
                        try db.run("DELETE FROM object_waits WHERE child=?", ready)
                        for dependency in missing { try db.run("INSERT INTO object_waits VALUES(?,?)", [ready[0], .blob(dependency.segmentID.bytes)]) }
                        try db.run("DELETE FROM ready_objects WHERE object_id=?", ready)
                        return .parked
                    }
                } catch {
                    try db.requireHealthyHistory()
                    guard let reason = ReceiveRejection(error) else { throw error }
                    try db.rejectReceived(ready[0], reason: reason)
                    return .parked
                }
            }
            switch turn {
            case .finished: return
            case .parked: continue
            case .validate(let locator, let bytes):
                do { _ = try await acceptScheduled(bytes, locator: locator, selection: selection, protection: protection) }
                catch {
                    guard let reason = ReceiveRejection(error) else { throw error }
                    try await perform { try $0.rejectReceived(.blob(locator.segmentID.bytes), reason: reason) }
                }
                try await catchUp(selection: selection, protection: protection)
            }
        }
    }
}

extension Database {
    func missing(_ locators: [SegmentLocator]) throws -> [SegmentLocator] {
        try locators.filter { locator in
            let r = try rows("SELECT o.writer_epoch,o.sequence FROM accepted_objects a JOIN objects o USING(object_id) WHERE object_id=?", [.blob(locator.segmentID.bytes)])
            if r.isEmpty { return true }
            guard r == [[.blob(locator.writerEpoch.bytes), .blob(Array(locator.encodedV1()[16..<24]))]] else { throw CanonicalEncodingError.invalidReference }
            return false
        }
    }
}
