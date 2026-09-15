import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// A recorded validator lookup, used to replay identical database work in batches.
private enum HistoryLookup: Sendable {
    case payload(SegmentLocator), operation(OperationID), action(ActionID), birth(NoteBirth)

    func read(_ db: Database, selection: LocalStoreSelection, protection: ObjectProtectionV1) throws -> Int {
        switch self {
        case .payload(let id):
            return try db.payload(id, collection: selection.descriptor.collection, protection: protection)?.operations.count ?? 0
        case .operation(let id): return try db.operation(id, selection: selection, protection: protection) == nil ? 0 : 1
        case .action(let id): return try db.action(id, selection: selection, protection: protection)?.members.count ?? 0
        case .birth(let id): return try db.rows("SELECT 1 FROM operations WHERE birth=? LIMIT 1", [.blob(id.bytes)]).count
        }
    }
}

private func historyMilliseconds(_ ns: UInt64) -> String { String(format: "%.3f", Double(ns) / 1_000_000) }

/// Measures the complete existing validator with either direct or scheduled readers.
private func timedHistoryCheck(_ bytes: [UInt8], session: LocalStoreSession,
                               protection: ObjectProtectionV1, scheduled: Bool) async throws -> UInt64 {
    let lane = await session.lane, selection = await session.selection
    let through = try await lane.perform { try $0.acceptedThrough() }
    let start = DispatchTime.now().uptimeNanoseconds
    if scheduled {
        let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
        let payload = try ChangesPayloadV1.decodeV1(opened.payload)
        try await OrdinaryHistoryV1.validate(payload, at: opened.locator,
            payloadAt: { id in try await lane.historyRead(through: through) {
                try $0.payload(id, collection: selection.descriptor.collection, protection: protection)
            } },
            operationByID: { id in try await lane.historyRead(through: through) {
                try $0.operation(id, selection: selection, protection: protection)
            } },
            actionByID: { id in try await lane.historyRead(through: through) {
                try $0.action(id, selection: selection, protection: protection)
            } },
            birthExists: { id in try await lane.historyRead(through: through) {
                try !$0.rows("SELECT 1 FROM operations WHERE birth=? LIMIT 1", [.blob(id.bytes)]).isEmpty
            } })
    } else {
        try await lane.perform { db in
            try db.validateOwner()
            guard try db.acceptedThrough() == through else { throw StorageError.staleCapture }
            let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
            let payload = try ChangesPayloadV1.decodeV1(opened.payload)
            try SynchronousHistoryReference.validate(payload, at: opened.locator,
                payloadAt: { try db.payload($0, collection: selection.descriptor.collection, protection: protection) },
                operationByID: { try db.operation($0, selection: selection, protection: protection) },
                actionByID: { try db.action($0, selection: selection, protection: protection) },
                birthExists: { try !db.rows("SELECT 1 FROM operations WHERE birth=? LIMIT 1", [.blob($0.bytes)]).isEmpty })
        }
    }
    return DispatchTime.now().uptimeNanoseconds - start
}

private func recordHistoryLookups(_ bytes: [UInt8], session: LocalStoreSession,
                                  protection: ObjectProtectionV1) async throws -> [HistoryLookup] {
    let lane = await session.lane, selection = await session.selection
    return try await lane.perform { db in
        let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
        let payload = try ChangesPayloadV1.decodeV1(opened.payload)
        var trace: [HistoryLookup] = []
        try SynchronousHistoryReference.validate(payload, at: opened.locator,
            payloadAt: { id in
                trace.append(.payload(id))
                return try db.payload(id, collection: selection.descriptor.collection, protection: protection)
            },
            operationByID: { id in
                trace.append(.operation(id))
                return try db.operation(id, selection: selection, protection: protection)
            },
            actionByID: { id in
                trace.append(.action(id))
                return try db.action(id, selection: selection, protection: protection)
            },
            birthExists: { id in
                trace.append(.birth(id))
                return try !db.rows("SELECT 1 FROM operations WHERE birth=? LIMIT 1", [.blob(id.bytes)]).isEmpty
            })
        return trace
    }
}

/// Estimates batching's read-side benefit using the exact recorded lookup sequence.
private func replayHistoryLookups(_ trace: [HistoryLookup], batch: Int, session: LocalStoreSession,
                                  protection: ObjectProtectionV1) async throws -> (UInt64, [UInt64], Int) {
    let lane = await session.lane, selection = await session.selection
    let through = try await lane.perform { try $0.acceptedThrough() }
    let start = DispatchTime.now().uptimeNanoseconds
    var turns: [UInt64] = [], checksum = 0
    for offset in stride(from: 0, to: trace.count, by: batch) {
        let part = trace[offset..<min(offset + batch, trace.count)]
        let turnStart = DispatchTime.now().uptimeNanoseconds
        checksum += try await lane.historyRead(through: through) { db in
            var total = 0
            for request in part { total += try request.read(db, selection: selection, protection: protection) }
            return total
        }
        turns.append(DispatchTime.now().uptimeNanoseconds - turnStart)
    }
    return (DispatchTime.now().uptimeNanoseconds - start, turns, checksum)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_HISTORY_READ_BENCHMARK"] == "1"))
func historyReadSchedulingBenchmark() async throws {
    for encrypted in [false, true] {
        let (initial, protection) = try testInitial(encrypted)
        let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
        let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
        var count = 0
        for target in [64, 256, 1024] {
            while count < target {
                count += 1
                let saved = try await put(String(repeating: "x", count: 1024) + "-\(count)", birth: birth,
                                          generation: UInt64(count), session: source)
                _ = try await receiver.receive(source.retainedObject(at: saved.object))
            }
            let candidate = try await put("candidate", birth: birth, generation: UInt64(count + 1), session: source)
            let bytes = try await source.retainedObject(at: candidate.object)
            let trace = try await recordHistoryLookups(bytes, session: receiver, protection: protection)
            try #require(trace.count > target * 4)
            let before = try await receiver.snapshot()
            for repetition in 0...3 {
                for scheduled in (repetition % 2 == 0 ? [false, true] : [true, false]) {
                    let elapsed = try await timedHistoryCheck(bytes, session: receiver, protection: protection, scheduled: scheduled)
                    if repetition > 0 {
                        print("HISTORY-FULL encrypted=\(encrypted) actions=\(target) lookups=\(trace.count) scheduled=\(scheduled) run=\(repetition) ms=\(historyMilliseconds(elapsed))")
                    }
                }
            }
            var expectedChecksum: Int?
            for repetition in 0...3 {
                let batches = repetition % 2 == 0 ? [1, 16, 64, 256] : [256, 64, 16, 1]
                for batch in batches {
                    let (elapsed, turns, checksum) = try await replayHistoryLookups(trace, batch: batch,
                                                                                  session: receiver, protection: protection)
                    if let expectedChecksum { #expect(checksum == expectedChecksum) }
                    else { expectedChecksum = checksum }
                    #expect(turns.count == (trace.count + batch - 1) / batch)
                    if repetition > 0 {
                        let sorted = turns.sorted()
                        print("HISTORY-REPLAY encrypted=\(encrypted) actions=\(target) batch=\(batch) run=\(repetition) ms=\(historyMilliseconds(elapsed)) turn_p95_ms=\(historyMilliseconds(sorted[(sorted.count - 1) * 95 / 100])) turn_max_ms=\(historyMilliseconds(sorted.last!)) checksum=\(checksum)")
                    }
                }
            }
            #expect(try await receiver.snapshot().notes == before.notes)
            #expect(try await receiver.snapshot().through == before.through)
            _ = try await receiver.receive(bytes)
            #expect(try await receiver.snapshot().notes.first { $0.birth == birth }?.value.body.string == "candidate")
            count += 1
        }
        try await source.quiesce(); try await receiver.quiesce()
    }
}
