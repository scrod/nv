import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Captures an actual complete derived view for a controlled materialization-lag fixture.
private struct LaggedViewFixture: Sendable {
    let metadata: [SQLValue]
    let cells: [[SQLValue]]
    static func capture(_ lane: DatabaseLane) async throws -> Self {
        try await lane.perform { db in
            Self(metadata: try db.rows("SELECT through_seq,epoch,reducer_version,authoring_context FROM view_meta WHERE singleton=1")[0],
                 cells: try db.rows("SELECT birth,cell FROM current_notes ORDER BY birth"))
        }
    }
    func restore(_ lane: DatabaseLane) async throws {
        try await lane.perform { db in
            try db.transaction {
                try db.exec("DELETE FROM current_notes")
                for row in cells { try db.run("INSERT INTO current_notes(birth,cell) VALUES(?,?)", row) }
                try db.run("UPDATE view_meta SET through_seq=?,epoch=?,reducer_version=?,authoring_context=? WHERE singleton=1", metadata)
            }
        }
    }
}

/// Compares real per-batch catch-up with the returning opener on identical accepted histories.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_STORAGE_IMPROVEMENT_BENCHMARK"] == "1"),
      arguments: [false, true], [64, 256, 1024])
func recoveryWorkAcrossHistoryAndLag(encrypted: Bool, historySize: Int) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let writer = try await newSession(initial, protection), reader = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let selection = await reader.selection, lane = await reader.lane
    for index in 1...historySize {
        let saved = try await put("base-\(index)", birth: birth, generation: UInt64(index), session: writer)
        guard case .accepted = try await reader.receive(writer.retainedObject(at: saved.object)) else {
            Issue.record("The ordinary prefix must be accepted through the public receive path"); return
        }
    }
    var lagged: [Int: LaggedViewFixture] = [:], envelopes: [(SegmentLocator, [UInt8])] = []
    for index in 0..<16 {
        let remaining = 16 - index
        if [1, 4, 16].contains(remaining) { lagged[remaining] = try await .capture(lane) }
        guard case .automatic(let command) = try await writer.prepareCompensation(scope: .note(birth), direction: index % 2 == 0 ? .undo : .redo) else {
            Issue.record("Every suffix member must exercise actual compensation"); return
        }
        let saved = try requireReceipt(await writer.applyCompensation(command))
        let bytes = try await writer.retainedObject(at: saved.object)
        guard case .accepted = try await reader.receive(bytes) else {
            Issue.record("The compensation companion must be fully supported"); return
        }
        envelopes.append((saved.object, bytes))
    }
    let expected = try await writer.snapshot(), expectedUndo = try await writer.undoCandidates(scope: .note(birth), direction: .undo)
    #expect(expected.notes.map(\.value.body.string).sorted() == ["base-\(historySize)", "untouched"])
    let accepted = try await lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY seq,object_id") }
    let privateState = try await lane.perform { try $0.rows("SELECT group_key,codec,generation,payload FROM private_groups ORDER BY group_key") }
    try await reader.quiesce()
    for lag in [1, 4, 16] {
        let fixture = try #require(lagged[lag])
        for opening in [false, true] {
            let basis = try await LocalStoreSession.open(selection: selection, protection: protection)
            let basisLane = await basis.lane
            try await fixture.restore(basisLane)
            let recovered: LocalStoreSession, elapsed: UInt64
            if opening {
                await basisLane.close()
                let start = DispatchTime.now().uptimeNanoseconds
                recovered = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: StorageWork())
                elapsed = DispatchTime.now().uptimeNanoseconds - start
            } else {
                try await basisLane.perform { $0.work = StorageWork() }
                let start = DispatchTime.now().uptimeNanoseconds
                try await basisLane.catchUp(selection: selection, protection: protection)
                elapsed = DispatchTime.now().uptimeNanoseconds - start
                recovered = basis
            }
            let recoveredLane = await recovered.lane, state = try await recovered.snapshot()
            let work = try await recoveredLane.perform { $0.work! }
            let counts = work.stages.values
            #expect(state.notes == expected.notes && state.context == expected.context && state.through == expected.through)
            #expect(counts.reduce(0) { $0 + $1.graphLoads } == (opening ? 1 : lag))
            #expect(try await recoveredLane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY seq,object_id") } == accepted)
            #expect(try await recoveredLane.perform { try $0.rows("SELECT group_key,codec,generation,payload FROM private_groups ORDER BY group_key") } == privateState)
            let undo = try await recovered.undoCandidates(scope: .note(birth), direction: .undo)
            #expect(undo.ids == expectedUndo.ids && undo.mode == expectedUndo.mode && undo.scope == .note(birth) && undo.direction == .undo)
            for (locator, bytes) in envelopes { #expect(try await recovered.retainedObject(at: locator) == bytes) }
            print("RECOVERY-WORK encrypted=\(encrypted) history=\(historySize) lag=\(lag) opening=\(opening) elapsedNS=\(elapsed) graphs=\(counts.reduce(0) { $0 + $1.graphLoads }) decodes=\(counts.reduce(0) { $0 + $1.envelopeDecodes }) sql=\(counts.reduce(0) { $0 + $1.statements }) rows=\(counts.reduce(0) { $0 + $1.rows }) maxWriterNS=\(counts.map(\.maxWriterNanoseconds).max() ?? 0)")
            try await recovered.quiesce()
        }
    }
    try await writer.quiesce()
}
