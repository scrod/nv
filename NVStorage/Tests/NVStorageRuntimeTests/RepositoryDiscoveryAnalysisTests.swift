import NVStorageTestSupport
import Foundation
import Crypto
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Measures production discovery and isolated bounded-query candidates on identical accepted files.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_STORAGE_DISCOVERY_ANALYSIS"] != nil),
      .timeLimit(.minutes(20)), arguments: [false, true])
func repositoryDiscoveryWorkAnalysis(encrypted: Bool) async throws {
    let output = try #require(ProcessInfo.processInfo.environment["NV_STORAGE_DISCOVERY_ANALYSIS"])
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16)), selection = await source.selection
    try FileManager.default.createDirectory(atPath: path + "/NV Data/v1/keys", withIntermediateDirectories: true)
    var size = 0, expected: Set<SegmentID> = []
    for target in [64, 256, 1024] {
        while size < target {
            size += 1
            let receipt = try await put("discovery analysis \(size)", birth: birth, generation: UInt64(size), session: source)
            expected.insert(receipt.object.segmentID)
            try await deliverFile(source.retainedObject(at: receipt.object), relative: ImmutableRepositoryLocator.segment(receipt.object).relativePath, to: path)
        }
        _ = try await discoverPass(root, into: source, budget: 16)
        let writers = try FileManager.default.contentsOfDirectory(atPath: path + "/NV Data/v1/segments")
        #expect(writers.count == 1)
        var observations: [RepositoryEntryObservation] = []
        let permission = try await root.permission()
        for writer in writers {
            let epoch = try WriterEpoch(bytes: stride(from: 0, to: writer.count, by: 2).map { offset in
                let start = writer.index(writer.startIndex, offsetBy: offset)
                return try #require(UInt8(writer[start..<writer.index(start, offsetBy: 2)], radix: 16))
            })
            let directory = RepositoryProtocolDirectory.writer(epoch)
            var cursor: RepositoryListingCursor?
            repeat {
                let page = try await root.list(directory, continuing: cursor, budget: 16, using: permission)
                for leaf in page.names { observations.append(try await root.observe(leaf.relativePath(in: directory), using: permission)) }
                cursor = page.continuation
            } while cursor != nil
        }
        let hints = try await root.analysisHints(observations, using: permission)
        #expect(hints.count == target)
        var samples: [String: [Double]] = [:]
        let immutableHints = hints, expectedIDs = expected
        func measure(_ name: String, _ work: () async throws -> Void) async throws {
            for round in 0...9 {
                let start = ContinuousClock.now
                try await work()
                let duration = start.duration(to: .now)
                if round > 0 { samples[name, default: []].append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15) }
            }
        }
        for budget in [16, 64] {
            try await measure("production-discovery-\(budget)") {
                let entries = try await discoverPass(root, into: source, budget: budget)
                #expect(entries.count == target)
                let found = entries.compactMap { entry -> SegmentID? in
                    if case .unchangedAccepted(let id) = entry.outcome { return id }; return nil
                }
                #expect(found.count == target && Set(found) == expectedIDs)
            }
        }
        try await measure("header-only-per-file-one-lane-turn") {
            try await source.lane.perform { db in
                for _ in immutableHints { try db.validateHeader(store: selection.store, descriptor: selection.descriptor) }
            }
        }
        for budget in [1, 16, 64] {
            for joined in budget == 1 ? [false] : [false, true] {
                try await measure("hint-query-\(joined ? "joined" : "separate")-\(budget)") {
                    var found: [SegmentID] = []
                    for start in stride(from: 0, to: immutableHints.count, by: budget) {
                        let group = Array(immutableHints[start..<min(start + budget, immutableHints.count)])
                        found += try await source.lane.perform { db in
                            try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                            return try analysisHintIDs(db, hints: group, joined: joined)
                        }
                    }
                    #expect(found.count == target && Set(found) == expectedIDs)
                }
            }
        }
        try await source.lane.perform { $0.work = StorageWork() }
        _ = await root.measureMetadata(true)
        _ = try await discoverPass(root, into: source, budget: 16)
        let metadata = try #require(await root.measureMetadata(false))
        let counts = try await source.lane.perform { db in let work = db.work!; db.work = nil; return work }
        var calls: [String: Int] = [:]
        for stage in counts.stages.values { for (sql, count) in stage.statementCalls { calls[sql, default: 0] += count } }
        let groups = counts.stages.values.reduce(0) { $0 + $1.discoveryHintBatches }
        #expect(groups > 0 && groups < target)
        #expect(calls.values.reduce(0, +) == groups)
        #expect(counts.stages.values.reduce(0) { $0 + $1.connectionContextChecks } == 0)
        #expect(counts.stages.values.reduce(0) { $0 + $1.physicalOwnerChecks } == 2 * groups + 2)
        #expect(counts.stages.values.reduce(0) { $0 + $1.discoveryHintInputs } == target)
        #expect(counts.stages.values.reduce(0) { $0 + $1.discoveryHintHits } == target)
        #expect(counts.stages.values.reduce(0) { $0 + $1.historyReads + $1.envelopeDecodes } == 0)
        #expect(metadata.bodyReads == 0 && metadata.singleObservations == 0 && metadata.largestBatch <= 64)
        #expect(metadata.ancestorChecks == 2 * metadata.batches && metadata.largestNameBytes <= 64 * 255)
        let result: [String: Any] = ["profile": encrypted ? "encrypted" : "public", "files": target, "repository": path,
            "samplesMilliseconds": samples, "sqlStatementCalls": calls,
            "databaseTurns": counts.stages.values.reduce(0) { $0 + $1.writerTurns },
            "maxInstrumentedDatabaseTurnNanoseconds": counts.stages.values.map(\.maxWriterNanoseconds).max() ?? 0,
            "hintBatches": groups, "physicalOwnerChecks": counts.stages.values.reduce(0) { $0 + $1.physicalOwnerChecks },
            "vmSteps": counts.stages.values.reduce(0) { $0 + $1.vmSteps },
            "scanSteps": counts.stages.values.reduce(0) { $0 + $1.fullScanSteps },
            "metadata": ["batches": metadata.batches, "bulkCalls": metadata.bulkCalls, "statCalls": metadata.statCalls,
                "ancestorChecks": metadata.ancestorChecks, "largestBatch": metadata.largestBatch, "largestNameBytes": metadata.largestNameBytes,
                "bodyReads": metadata.bodyReads],
            "prototypeOnly": false, "productionBatched": true, "connectionContextReused": true,
            "cache": "warm", "repetitions": 9]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        try json.write(to: URL(fileURLWithPath: output + "/sql-\(encrypted ? "encrypted" : "public")-\(target).json"), options: .atomic)
    }
    #expect(try await source.snapshot().notes.first { $0.birth == birth }?.value.body.string == "discovery analysis 1024")
    try await source.quiesce(); await root.close()
}

extension RepositoryRootSession {
    /// Builds root-scoped hints in one actor entry for the database diagnostics.
    fileprivate func analysisHints(_ observations: [RepositoryEntryObservation], using permission: RepositoryRootPermission) throws -> [RepositoryObservationHint] {
        try observations.map { try discoveryHint($0, using: permission) }
    }
}

/// Preserves the production fingerprint, digest and exact accepted-membership checks.
private func analysisHintIDs(_ db: Database, hints: [RepositoryObservationHint], joined: Bool) throws -> [SegmentID] {
    let rows: [[SQLValue]]
    if joined {
        let values = hints.indices.map { _ in "(?,?,?)" }.joined(separator: ",")
        let arguments = hints.enumerated().flatMap { index, hint in [SQLValue.integer(Int64(index)), .blob(hint.key), .blob(hint.fingerprint)] }
        rows = try db.rows("""
            WITH requested(ordinal,key,fingerprint) AS (VALUES \(values))
            SELECT r.ordinal,p.payload FROM requested r JOIN private_groups p ON p.group_key=r.key
            JOIN accepted_objects a ON a.object_id=substr(p.payload,33,32)
            WHERE p.codec=1 AND length(p.payload)=96 AND substr(p.payload,1,32)=r.fingerprint ORDER BY r.ordinal
            """, arguments)
    } else {
        rows = try hints.enumerated().map { index, hint in
            let row = try #require(db.rows("SELECT codec,payload FROM private_groups WHERE group_key=?", [.blob(hint.key)]).first)
            #expect(row[0] == .integer(1))
            let payload = try row[1].bytes
            #expect(try !db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(Array(payload[32..<64]))]).isEmpty)
            return [.integer(Int64(index)), .blob(payload)]
        }
    }
    #expect(rows.count == hints.count)
    return try rows.map { row in
        let index = try row[0].number, payload = try row[1].bytes
        let hint = hints[Int(index)]
        #expect(payload.count == 96 && Array(payload.prefix(32)) == hint.fingerprint)
        let identity = Array(payload[32..<64])
        let digest = Array(SHA256.hash(data: Array("NV repository observation hint\0v1\0".utf8) + hint.key + hint.fingerprint + identity))
        #expect(Array(payload.suffix(32)) == digest)
        return try SegmentID(bytes: identity)
    }
}

/// Measures foreground save and database queue latency during an unchanged large discovery pass.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_STORAGE_DISCOVERY_ANALYSIS"] != nil),
      .timeLimit(.minutes(20)), arguments: [false, true])
func repositoryDiscoveryWorkAnalysisLatency(encrypted: Bool) async throws {
    let output = try #require(ProcessInfo.processInfo.environment["NV_STORAGE_DISCOVERY_ANALYSIS"])
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16)), foreground = try NoteBirth(bytes: .init(repeating: 2, count: 16))
    var expected: Set<SegmentID> = []
    for generation in 1...1024 {
        let receipt = try await put("latency history \(generation)", birth: birth, generation: UInt64(generation), session: store)
        expected.insert(receipt.object.segmentID)
        try await deliverFile(store.retainedObject(at: receipt.object), relative: ImmutableRepositoryLocator.segment(receipt.object).relativePath, to: path)
    }
    _ = try await discoverPass(root, into: store)
    func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    var baseline: [Double] = [], concurrent: [Double] = [], queue: [Double] = []
    for generation in 1...8 {
        let start = ContinuousClock.now
        _ = try await put("foreground edit \(generation)", birth: foreground, generation: UInt64(generation), session: store)
        baseline.append(milliseconds(start.duration(to: .now)))
    }
    let gate = ImprovementGate(), reads = RepositoryReadCounter()
    let scan = Task { () throws -> [RepositoryDiscoveryEntry] in
        var entries: [RepositoryDiscoveryEntry] = []
        for round in 0..<2048 {
            let turn = try await root.discover(into: store, opportunity: .backgroundTurn, budget: 16,
                hooks: .init(read: { _ in await reads.add() }, hintsReturned: { await gate.hold() }))
            try await root.validate(turn, for: store); entries += turn.entries
            if turn.passEnded { return entries }
            #expect(round < 2047)
        }
        throw StorageError.incomplete
    }
    await gate.wait()
    let first = ContinuousClock.now
    _ = try await put("foreground edit 9", birth: foreground, generation: 9, session: store)
    concurrent.append(milliseconds(first.duration(to: .now)))
    await gate.release()
    for generation in 10...16 {
        let enqueued = ContinuousClock.now
        let entered = try await store.lane.perform { _ in ContinuousClock.now }
        queue.append(milliseconds(enqueued.duration(to: entered)))
        let start = ContinuousClock.now
        _ = try await put("foreground edit \(generation)", birth: foreground, generation: UInt64(generation), session: store)
        concurrent.append(milliseconds(start.duration(to: .now)))
    }
    let entries = try await scan.value
    let found = entries.compactMap { entry -> SegmentID? in
        if case .unchangedAccepted(let id) = entry.outcome { return id }; return nil
    }
    #expect(found.count == 1024 && Set(found) == expected)
    #expect(await reads.count == 0)
    #expect(try await store.snapshot().notes.first { $0.birth == foreground }?.value.body.string == "foreground edit 16")
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "latency history 1024")
    let data: [String: Any] = ["profile": encrypted ? "encrypted" : "public", "files": 1024,
        "saveBaselineMilliseconds": baseline, "saveDuringDiscoveryMilliseconds": concurrent,
        "databaseQueueMilliseconds": queue, "providerBodyReads": await reads.count,
        "firstSaveCompletedWhileLookupCompletionHeld": true]
    try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]).write(
        to: URL(fileURLWithPath: output + "/latency-\(encrypted ? "encrypted" : "public").json"), options: .atomic)
    try await store.quiesce(); await root.close()
}
