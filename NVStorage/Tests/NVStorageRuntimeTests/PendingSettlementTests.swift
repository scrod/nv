import NVStorageTestSupport
import Foundation
import Testing
import Crypto
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true])
func pendingSettlementRecordIsAtomicAndRetainsDecision(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let item = try PendingItemID(bytes: uuidBytes()), input = try await pendingInput(session, body: "frozen A")
    try await session.retainPendingSnapshot(input, basedOn: session.pendingItem(item))
    let prepared = try await session.preparePendingImport(basedOn: session.pendingItem(item), automatic: false)
    _ = try requireReceipt(await session.persistPendingAction(prepared))
    let newer = try await pendingInput(session, body: "latest B")
    try await session.retainPendingSnapshot(newer, basedOn: session.pendingItem(item))
    let before = try await session.pendingItem(item)
    try await session.lane.perform { try $0.exec("CREATE TEMP TRIGGER refuse_settlement BEFORE INSERT ON pending_settlements BEGIN SELECT RAISE(ABORT,'settlement failure'); END;") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) {
            try await session.completePendingAssociation(prepared.reservation.id, basedOn: before) { _, matches in
                #expect(matches); return try PassivePlatformRecordV1(codec: 7, bytes: [10, 11])
            }
        }
        #expect(try await session.pendingItem(item).generation == before.generation)
        #expect(try await session.retainedPendingSnapshot(input.id) == input)
        #expect(try await session.pendingSettlement(item: item, snapshot: input.id) == nil)
        #expect(try await session.pendingRecovery(item).count == 1)
    }
    try await session.lane.perform { try $0.exec("DROP TRIGGER refuse_settlement") }
    try await session.completePendingAssociation(prepared.reservation.id, basedOn: before) { _, _ in
        try PassivePlatformRecordV1(codec: 7, bytes: [10, 11])
    }
    let receipt = try #require(await session.pendingSettlement(item: item, snapshot: input.id))
    #expect(receipt.record.reservation == prepared.reservation)
    #expect(receipt.record.scope == input.scope && receipt.record.item == item)
    #expect(receipt.record.outcome == .consumed(try PassivePlatformRecordV1(codec: 7, bytes: [10, 11])))
    #expect(receipt.record.subsequentSnapshot == newer.id)
    let rows = try await session.lane.perform { try $0.rows("SELECT reservation_id,decision_digest,observation_codec,observation FROM pending_settlements") }
    #expect(try rows == [[.blob(prepared.reservation.id.bytes), .blob(Array(SHA256.hash(data: prepared.reservation.encodedV1()))),
        .integer(1), .blob(receipt.record.encodedV1())]])
    #expect(try await session.lane.perform { try $0.rows("SELECT snapshot_id FROM pending_payloads") } == [[.blob(newer.id.bytes)]])
    let selection = await session.selection
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.pendingSettlement(item: item, snapshot: input.id)?.record == receipt.record)
    #expect(try await reopened.pendingRecovery(item).isEmpty)
    #expect(try await reopened.pendingItem(item).latest == newer.id)
    #expect(try await reopened.retainedPendingSnapshot(newer.id) == newer)
    try await reopened.verifyCompletePrivateState()
    let association = try LocalAssociationV1(id: LocalAssociationID(bytes: uuidBytes()), scope: input.scope,
        bookmark: PassivePlatformRecordV1(codec: 1, bytes: []))
    try await reopened.saveLocalAssociation(association, basedOn: reopened.localAssociation())
    let inventory = try await reopened.lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    let copy = try await reopened.preparePrivateStoreCopy(to: privateTempPath())
    #expect(copy.selection.store != selection.store)
    try await copy.close()
    let copied = try await LocalStoreSession.open(selection: copy.selection, protection: protection)
    #expect(try await copied.pendingSettlement(item: item, snapshot: input.id)?.record == receipt.record)
    #expect(try await copied.pendingItem(item).latest == newer.id)
    #expect(try await copied.retainedPendingSnapshot(newer.id) == newer)
    #expect(try await copied.lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") } == inventory)
    try await copied.verifyCompletePrivateState()
    try await copied.quiesce()
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func pendingSettlementChecksIndexedIdentityAndScope(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let item = try PendingItemID(bytes: uuidBytes()), input = try await pendingInput(session, body: "A")
    try await session.retainPendingSnapshot(input, basedOn: session.pendingItem(item))
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    guard case .neutral(let r) = try await session.preparePendingAssociation(basedOn: session.pendingItem(item), birth: birth, generation: 1) else {
        Issue.record("neutral companion authored an action"); return
    }
    try await session.completePendingAssociation(r.id, basedOn: session.pendingItem(item)) { _, matches in
        #expect(matches); return try PassivePlatformRecordV1(codec: 1, bytes: [1])
    }
    let original = try #require(await session.pendingSettlement(item: item, snapshot: input.id)).record
    let checks: [(String, SQLValue, SQLValue, StorageError)] = [
        ("reservation_id", .blob(Array(repeating: 99, count: 16)), .blob(r.id.bytes), .integrity),
        ("operation_id", .blob(Array(repeating: 99, count: 32)), .null, .integrity),
        ("birth", .blob(Array(repeating: 99, count: 16)), .blob(birth.bytes), .integrity),
        ("decision_digest", .blob(Array(repeating: 99, count: 32)), .blob(Array(SHA256.hash(data: r.encodedV1()))), .integrity),
        ("observation_codec", .integer(2), .integer(1), .unsupported),
        ("observation", .blob([0]), .blob(try original.encodedV1()), .integrity),
    ]
    for (column, invalid, valid, error) in checks {
        try await session.lane.perform { try $0.run("UPDATE pending_settlements SET \(column)=?", [invalid]) }
        await #expect(throws: error) { try await session.pendingSettlement(item: item, snapshot: input.id) }
        try await session.lane.perform { try $0.run("UPDATE pending_settlements SET \(column)=?", [valid]) }
        #expect(try await session.pendingSettlement(item: item, snapshot: input.id)?.record == original)
    }
    let foreignScope = try PrivateRecordScopeV1(collection: input.scope.collection,
        store: LocalStoreID(bytes: uuidBytes()), descriptor: input.scope.descriptor)
    let foreign = try PendingSettlementV1(scope: foreignScope, item: item, reservation: r,
        outcome: original.outcome, subsequentSnapshot: nil).encodedV1()
    try await session.lane.perform { try $0.run("UPDATE pending_settlements SET observation=?", [.blob(foreign)]) }
    await #expect(throws: StorageError.wrongContext) { try await session.pendingSettlement(item: item, snapshot: input.id) }
    await #expect(throws: StorageError.wrongContext) { try await session.verifyCompletePrivateState() }
    try await session.lane.perform { try $0.run("UPDATE pending_settlements SET observation=?", [.blob(original.encodedV1())]) }
    try await session.verifyCompletePrivateState()
    try await session.quiesce()
}
