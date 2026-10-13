import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
@testable import NVStorageRuntime

private actor GrowthBuildWitness {
    private(set) var events: [GrowthHistoryBuildEvent] = []
    func record(_ event: GrowthHistoryBuildEvent) { events.append(event) }
}

private enum GrowthFixtureFailure: Error { case injected }

@Test(arguments: [false, true])
func growthHistoryRequestsCoalesceAndKeepStoresIsolated(encrypted: Bool) async throws {
    let witness = GrowthBuildWitness(), gate = ImprovementGate()
    let bank = try GrowthHistoryFixtures(checkpoints: [2, 4], onBuildEvent: { event in
        await witness.record(event)
        if event == .started { await gate.hold() }
    })
    let first = Task { try await bank.fixture(encrypted: encrypted, actions: 2) }
    await gate.wait()
    let second = Task { try await bank.fixture(encrypted: encrypted, actions: 4) }
    await gate.release()
    let small = try await first.value, large = try await second.value
    #expect(await witness.events == [.started, .checkpoint(2), .checkpoint(4)])
    #expect(small.history.count == 2 && large.history.count == 4)
    #expect(small.history == Array(large.history.prefix(2)))
    #expect(small.following == large.history[2])
    #expect(large.following.locator.writerEpoch == large.history[3].locator.writerEpoch)
    #expect(large.following.locator.sequence == large.history[3].locator.sequence + 1)
    let body = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(large.following.bytes,
        collection: large.initial.descriptor.collection, protection: large.protection).payload)
    #expect(body.operations[0].operation.effect.noteValue?.body.string == "one new file")
    let a = try await small.openSender(), b = try await small.openSender(), receiver = try await small.openReceiver()
    let aSelection = await a.selection, bSelection = await b.selection, receiverSelection = await receiver.selection
    #expect(Set([aSelection.directory, bSelection.directory, receiverSelection.directory]).count == 3)
    let identities = try [aSelection, bSelection, receiverSelection].map { selection in
        let attributes = try FileManager.default.attributesOfItem(atPath: selection.directory + "/Collection.sqlite")
        let device = try #require(attributes[.systemNumber] as? NSNumber).uint64Value
        let inode = try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
        return "\(device):\(inode)"
    }
    #expect(Set(identities).count == 3)
    let expected = Set(small.initial.objects.keys.map(\.segmentID.bytes) + small.history.map(\.locator.segmentID.bytes)
        + [small.initial.descriptor.descriptorID])
    func inventory(_ store: LocalStoreSession) async throws -> Set<[UInt8]> {
        try await store.lane.perform { db in Set(try db.rows("SELECT object_id FROM accepted_objects").map { try $0[0].bytes }) }
    }
    #expect(try await inventory(a) == expected)
    let bInventory = try await inventory(b), receiverInventory = try await inventory(receiver)
    #expect(bInventory == expected && receiverInventory == expected)
    let recordCounts = try await b.lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") }
    #expect(recordCounts == [[.integer(6)], [.integer(4)]])
    let untouched = try await b.snapshot(), received = try await receiver.snapshot()
    #expect(untouched.notes.map(\.value.body.string).sorted() == ["E2", "untouched"])
    #expect(untouched.notes == received.notes && untouched.context == received.context)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("isolated consumer edit", birth: birth, generation: 3, session: a)
    try await a.quiesce()
    #expect(try await b.snapshot().notes == untouched.notes)
    #expect(try await receiver.snapshot().notes == received.notes)
    let laterB = try await inventory(b), laterReceiver = try await inventory(receiver)
    #expect(laterB == expected && laterReceiver == expected)
    for object in small.history {
        #expect(try await b.retainedObject(at: object.locator) == object.bytes)
        #expect(try await receiver.retainedObject(at: object.locator) == object.bytes)
    }
    try await b.quiesce()
    let reopened = try await LocalStoreSession.open(selection: bSelection, protection: small.protection)
    #expect(try await reopened.snapshot().notes == untouched.notes)
    #expect(try await inventory(reopened) == expected)
    let fresh = try await bank.fixture(encrypted: encrypted, actions: 2).openSender()
    #expect(try await fresh.snapshot().notes == untouched.notes)
    #expect(try await inventory(fresh) == expected)
    #expect(await witness.events == [.started, .checkpoint(2), .checkpoint(4)])
    try await reopened.quiesce(); try await receiver.quiesce(); try await fresh.quiesce()
}

@Test(arguments: [false, true])
func growthHistoryFailureKeepsPartialBuildUnpublished(encrypted: Bool) async throws {
    let witness = GrowthBuildWitness()
    let bank = try GrowthHistoryFixtures(checkpoints: [2, 4], onBuildEvent: { event in
        await witness.record(event)
        if event == .checkpoint(2) { throw GrowthFixtureFailure.injected }
    })
    await #expect(throws: GrowthFixtureFailure.injected) { try await bank.fixture(encrypted: encrypted, actions: 4) }
    await #expect(throws: GrowthFixtureFailure.injected) { try await bank.fixture(encrypted: encrypted, actions: 2) }
    #expect(await witness.events == [.started, .checkpoint(2)])
}

@Test func growthHistorySizeAndProfileSelectionAreExact() async throws {
    for sizes in [[], [0], [4, 2], [2, 2], [1025]] {
        #expect(throws: StorageError.limit) { try GrowthHistoryFixtures(checkpoints: sizes) }
    }
    let witness = GrowthBuildWitness()
    let bank = try GrowthHistoryFixtures(checkpoints: [1, 2], onBuildEvent: { await witness.record($0) })
    await #expect(throws: StorageError.limit) { try await bank.fixture(encrypted: false, actions: 3) }
    #expect(await witness.events.isEmpty)
    let plain = try await bank.fixture(encrypted: false, actions: 2)
    let encrypted = try await bank.fixture(encrypted: true, actions: 2)
    #expect(plain.initial.descriptor.keyID == nil && encrypted.initial.descriptor.keyID != nil)
    #expect(plain.history != encrypted.history)
    #expect(await witness.events.filter { $0 == .started }.count == 2)
}
