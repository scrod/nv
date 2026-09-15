import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

extension LocalStoreSession {
    fileprivate func exhaustEpochForTesting(_ sequence: UInt64) -> WriterEpoch {
        self.sequence = sequence; return writer
    }
}

@Test(arguments: [false, true]) func writerBudgetStartsFreshEpoch(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let before = await session.exhaustEpochForTesting(encrypted ? 1 << 20 : UInt64.max)
    let receipt = try await put("rotated", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    #expect(receipt.object.writerEpoch != before)
    #expect(receipt.object.sequence == 0)
    #expect(receipt.sequence == 2)
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["rotated", "untouched"])
    try await session.quiesce()
}

@Test func acceptanceAndOlderSettingsPreserveExactRetention() async throws {
    let (initial, protection) = try testInitial(false), session = try await newSession(initial, protection)
    let settings = try await session.settings()
    let e = try await put("E", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    let expected = Set([initial.snapshot.segmentID.bytes, e.object.segmentID.bytes])
    let lane = await session.lane
    let acceptedPin = try await lane.perform { db in try Set(db.rows("SELECT object_id FROM retained_frontier").map { try $0[0].bytes }) }
    #expect(acceptedPin == expected)
    try await session.saveEmptySettings(basedOn: settings)
    let afterSettings = try await lane.perform { db in try Set(db.rows("SELECT object_id FROM retained_frontier").map { try $0[0].bytes }) }
    #expect(afterSettings == expected)
    let selection = await session.selection
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().through == 2)
    #expect(try await reopened.settings().generation == 2)
    try await reopened.quiesce()
}

@Test(arguments: [false, true]) func discoveredRequiredHistoryDamageBlocksPreparedPublication(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let prepared = try await session.prepareReduction(liveGeneration: 1)
// Accepted local history remains publishable after rejecting invalid incoming bytes.
    await #expect(throws: CanonicalEncodingError.lengthLimit) { try await session.receive([0]) }
    #expect(try await session.publish(prepared, liveGeneration: 1) { $0.notes.count } == 2)
    let lane = await session.lane
    try await lane.perform { db in
        // Fault injection bypasses the normal immutable-row protection.
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(initial.descriptor.genesis.segmentID.bytes)])
    }
    await #expect(throws: CanonicalEncodingError.lengthLimit) { try await session.retainedObject(at: initial.descriptor.genesis) }
    await #expect(throws: StorageError.integrity) { try await session.publish(prepared, liveGeneration: 1) { $0.notes.count } }
    let selection = await session.selection
    try await session.quiesce()
    await #expect(throws: StorageError.integrity) {
        try await LocalStoreSession.open(selection: selection, protection: protection)
    }
}
