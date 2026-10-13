import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Measures the real returning owner through complete host values and synchronous search setup.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_STORAGE_LOCALITY_BENCHMARK"] == "1"),
      .timeLimit(.minutes(10)), arguments: [false, true], [(64, false), (64, true), (256, false), (256, true)])
func currentProductionStartupBenchmark(encrypted: Bool, workload: (Int, Bool)) async throws {
    let (count, aged) = workload
    let (initial, protection) = try testInitial(encrypted)
    let notes = try (1...count).map { index in
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[14] = UInt8(index >> 8); bytes[15] = UInt8(index & 255)
        let paragraphs = (0..<16).map { p in
            "Synthetic current value \(index), paragraph \(p): history and privacy, Unicode café 日本語. " +
            (index % 8 == 0 ? String(index &* 7919 &+ p &* 104729, radix: 16) : "Ordinary editable prose and durable user changes.")
        }
        return try (NoteBirth(bytes: bytes), testValue(paragraphs.joined(separator: "\n")))
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    var session = try await LocalStoreSession.create(directory: directory, collection: initial.descriptor.collection,
        notes: notes, protection: protection, passphrase: encrypted ? "synthetic" : nil)
    if aged {
        for n in 1...64 { _ = try await put("Aged saved value \(n)", birth: notes[0].0, generation: UInt64(n), session: session) }
    }
    let expected = try await session.snapshot(), selection = await session.selection
    let expectedValues = Dictionary(uniqueKeysWithValues: expected.notes.map { ($0.birth, $0.value) })
    for representation in ["raw", "plain", "dictionary", "compacted"] {
        let lane = await session.lane
        if representation == "raw" {
            try await lane.perform { db in try db.transaction {
                for cell in expected.notes {
                    try db.run("UPDATE current_notes SET cell=? WHERE birth=?", [.blob(cell.encodedV1()), .blob(cell.birth.bytes)])
                }
            } }
        } else if representation == "plain" {
            let rows = try await lane.historyWork { try EncodedCurrentRows(cells: expected.notes) }
            try await lane.perform { db in try db.transaction { try rows.install(database: db) } }
        } else if representation == "dictionary" {
            _ = try await session.recodeCurrentRows(basedOn: session.snapshot(), maximumRows: 256, trainDictionary: true)
        } else {
            #expect(try await session.compactPrivateStore() == .completed)
        }
        try await session.quiesce()
        for repetition in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            session = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: StorageWork())
            let captured = try await session.snapshot(), model = HeadlessModel(snapshot: captured)
            let search = model.values.map { ($0.key, ($0.value.title.string + "\n" + $0.value.body.string).lowercased()) }
            let matched = search.filter { $0.1.contains("unicode") }.count
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            #expect(model.values == expectedValues && captured.context == expected.context)
            #expect(matched == count - (aged ? 1 : 0))
            let work = try await session.lane.perform { $0.work! }
            let sum = work.stages.values.reduce(StorageWork.Counts()) { total, c in
                var t = total
                t.statements += c.statements; t.rows += c.rows; t.currentCellDecodes += c.currentCellDecodes
                t.currentEncodedBytes += c.currentEncodedBytes; t.currentExpandedBytes += c.currentExpandedBytes
                t.dictionaryLoads += c.dictionaryLoads; t.historyReads += c.historyReads; t.graphLoads += c.graphLoads
                t.retainedLeafChecks += c.retainedLeafChecks; return t
            }
            #expect(sum.currentCellDecodes == count && sum.historyReads == 0 && sum.graphLoads == 0)
            print("CURRENT-START profile=\(encrypted) notes=\(count) aged=\(aged) format=\(representation) repetition=\(repetition) ns=\(elapsed) sql=\(sum.statements) rows=\(sum.rows) decodes=\(sum.currentCellDecodes) encoded=\(sum.currentEncodedBytes) expanded=\(sum.currentExpandedBytes) dictionaries=\(sum.dictionaryLoads) leaves=\(sum.retainedLeafChecks) residency=warm")
            try await session.quiesce()
        }
        session = try await LocalStoreSession.open(selection: selection, protection: protection)
    }
    try await session.quiesce()
}
