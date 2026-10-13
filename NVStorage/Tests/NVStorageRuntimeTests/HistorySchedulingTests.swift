import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true])
func reopenRebuildsDamagedViewBeforeDrainingReadyHistory(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let saved = try await put("recovered child", birth: birth, generation: 1, session: source)
    let bytes = try await source.retainedObject(at: saved.object)
    let lane = await receiver.lane, selection = await receiver.selection
    try await lane.perform { db in
        try db.transaction {
            try db.run("INSERT INTO objects VALUES(?,1,?,?,?)", [.blob(saved.object.segmentID.bytes),
                .blob(saved.object.writerEpoch.bytes), .blob(Array(saved.object.encodedV1()[16..<24])), .blob(bytes)])
            try db.run("INSERT INTO ready_objects VALUES(?)", [.blob(saved.object.segmentID.bytes)])
            try db.run("UPDATE current_notes SET cell=? WHERE birth=?", [.blob([0]), .blob(birth.bytes)])
        }
    }
    try await receiver.quiesce()
    let recovered = try? await LocalStoreSession.open(selection: selection, protection: protection)
    let reopened = try #require(recovered)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["recovered child", "untouched"])
    #expect(try await reopened.snapshot().through == 2)
    try await reopened.quiesce(); try await source.quiesce()
}

@Test func historyReadRejectsStalePrefix() async throws {
    let (initial, protection) = try testInitial(false), session = try await newSession(initial, protection)
    let lane = await session.lane
    _ = try await put("new", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    #expect(try await lane.historyRead(through: 2) { try $0.acceptedThrough() } == 2)
    await #expect(throws: StorageError.staleCapture) {
        try await lane.historyRead(through: 1) { try $0.acceptedThrough() }
    }
    try await session.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func historicalValidationYieldsToSaveAndRechecksHistory(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    for n in 1...16 {
        let saved = try await put("B\(n)", birth: b, generation: UInt64(n), session: source)
        _ = try await receiver.receive(source.retainedObject(at: saved.object))
    }
    let remote = try await put("remote", birth: b, generation: 17, session: source)
    let bytes = try await source.retainedObject(at: remote.object)
    _ = try await put("local", birth: a, generation: 1, session: receiver)
    let lane = await receiver.lane
    let gate = HistoryCheckGate()
    try await lane.perform { db in
        db.work = StorageWork()
        db.work?.historyCheck = { await gate.check() }
    }
    let receiving = Task { try await receiver.receive(bytes) }
    await gate.waitFor(1)
    defer { Task { await gate.release(2) } }
    let started = try await lane.perform { ($0.work?[.validation].fullChecks ?? 0) > 0 }
    try #require(started)
    // The actual receiver has captured its prefix and is waiting on the history worker.
    let local = try await put("new local", birth: a, generation: 2, session: receiver)
    #expect(try await receiver.snapshot().notes.first { $0.birth == a }?.value.body.string == "new local")
    await gate.release(2)
    _ = try await receiving.value
    let result = try await receiver.snapshot()
    #expect(result.notes.map(\.value.body.string).sorted() == ["new local", "remote"])
    #expect(result.through == local.sequence + 1)
    #expect(try await lane.perform { $0.work![.validation].fullChecks } == 2)
    try await receiver.quiesce(); try await source.quiesce()
}

@Test(arguments: [false, true])
func catchUpCommitsOneCompletePrefixAtATime(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let lane = await receiver.lane, selection = await receiver.selection
    for n in 1...4 {
        let receipt = try await put("E\(n)", birth: birth, generation: UInt64(n), session: source)
        let bytes = try await source.retainedObject(at: receipt.object)
        _ = try await lane.acceptScheduled(bytes, locator: receipt.object, selection: selection, protection: protection)
    }
    for n in 1...4 {
        let done = try await lane.catchUpBatch(selection: selection, protection: protection)
        let result = try await lane.perform { db in
            let prefix = try db.rows("SELECT through_seq FROM view_meta")[0][0].number
            let cell = try db.currentCell(db.rows("SELECT cell FROM current_notes WHERE birth=?", [.blob(birth.bytes)])[0][0].bytes)
            return (done, prefix, cell.value.body.string)
        }
        #expect(result.0 == (n == 4))
        #expect(result.1 == Int64(n + 1))
        #expect(result.2 == "E\(n)")
    }
    try await receiver.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["E4", "untouched"])
    try await reopened.quiesce(); try await source.quiesce()
}
