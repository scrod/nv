import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Compares actual bulk catalogs, rooted observations and accepted-file discovery on identical files.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_STORAGE_SCAN_BENCHMARK_NATIVE"] != nil),
      .timeLimit(.minutes(20)), arguments: [false, true])
func repositoryDirectoryScanBenchmark(encrypted: Bool) async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["NV_STORAGE_SCAN_BENCHMARK_NATIVE"])
    let repetitions = Int(ProcessInfo.processInfo.environment["NV_STORAGE_SCAN_BENCHMARK_REPETITIONS"] ?? "9") ?? 9
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let path = try repositoryDirectory(), birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    try FileManager.default.createDirectory(atPath: path + "/NV Data/v1/keys", withIntermediateDirectories: true)
    var size = 0
    for target in [64, 256, 1024] {
        while size < target {
            size += 1
            let saved = try await put("scan benchmark \(size)", birth: birth, generation: UInt64(size), session: source)
            try await deliverFile(source.retainedObject(at: saved.object), relative: ImmutableRepositoryLocator.segment(saved.object).relativePath, to: path)
        }
        let process = Process(), stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [path, String(target), String(repetitions)]
        process.standardOutput = stdout
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let native = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        #expect(native["files"] as? Int == target)
        let root = try await RepositoryRootSession.open(directory: path)
        _ = try await discoverPass(root, into: source, budget: 16)
        var milliseconds: [Double] = [], turns: [Int] = [], statements: [Int] = []
        let providerReads = RepositoryReadCounter()
        for round in 0...repetitions {
            // The excluded warmup records SQL work; timed passes use the ordinary runtime configuration.
            if round == 0 { try await source.lane.perform { $0.work = StorageWork() } }
            let start = ContinuousClock.now
            var ended = false, count = 0, calls = 0
            while !ended {
                let turn: RepositoryDiscoveryTurn
                if round == 0 {
                    turn = try await root.discover(into: source, opportunity: .backgroundTurn, budget: 16,
                        hooks: RepositoryDiscoveryHooks(read: { _ in await providerReads.add() }))
                } else {
                    turn = try await root.discover(into: source, opportunity: .backgroundTurn, budget: 16)
                }
                try await root.validate(turn, for: source)
                for entry in turn.entries {
                    guard case .unchangedAccepted = entry.outcome else {
                        Issue.record("A measured unchanged scan must reuse its accepted observation: \(entry.relativePath)")
                        continue
                    }
                    count += 1
                }
                ended = turn.passEnded; calls += 1
            }
            let elapsed = start.duration(to: .now)
            #expect(count == target)
            if round == 0 {
                let work = try await source.lane.perform { db in let result = db.work!; db.work = nil; return result }
                #expect(work.stages.values.reduce(0) { $0 + $1.historyReads } == 0)
                #expect(work.stages.values.reduce(0) { $0 + $1.envelopeDecodes } == 0)
                #expect(await providerReads.count == 0)
                statements.append(work.stages.values.reduce(0) { $0 + $1.statements })
            }
            if round > 0 {
                milliseconds.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
                turns.append(calls)
            }
        }
        let result: [String: Any] = ["profile": encrypted ? "encrypted" : "public", "history": target,
            "repository": path, "native": native, "discoveryMilliseconds": milliseconds, "turns": turns,
            "sqlStatements": statements, "historicalBodyReads": 0, "verificationProviderBodyReads": await providerReads.count,
            "sqlWorkInstrumentationDuringTiming": false]
        let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        if let directory = ProcessInfo.processInfo.environment["NV_STORAGE_SCAN_BENCHMARK_RESULTS"] {
            let file = URL(fileURLWithPath: directory).appendingPathComponent("scan-\(encrypted ? "encrypted" : "public")-\(target).json")
            try encoded.write(to: file, options: .atomic)
        }
        print("SCAN-BENCHMARK " + String(decoding: encoded, as: UTF8.self))
        await root.close()
    }
    try await source.quiesce()
}
