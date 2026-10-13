import NVStorageTestSupport
import Crypto
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private actor SharedSnapshotSink {
    let collection: CollectionID, protection: ObjectProtectionV1
    var sequence: UInt64 = 0
    var objects: [SegmentLocator: [UInt8]] = [:]
    init(collection: CollectionID, protection: ObjectProtectionV1) { self.collection = collection; self.protection = protection }
    func emit(_ kind: ProviderObjectKind, _ payload: [UInt8]) throws -> SegmentLocator {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection,
            writer: WriterEpoch(bytes: Array(repeating: 39, count: 16)), sequence: sequence, protection: protection)
        sequence += 1
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        objects[locator] = bytes; return locator
    }
}

@Test(arguments: [false, true], [false, true])
func bootstrapAndSnapshotPreserveIncidentalOrdinaryGroups(encrypted: Bool, delete: Bool) async throws {
    let (descriptor, root, objects, protection, records) = try sharedBootstrap(encrypted: encrypted, delete: delete)
    let selection = try LocalStoreSelection(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        store: LocalStoreID(bytes: uuidBytes()), descriptor: descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: root, protection: protection)
    for bytes in objects.values { _ = try await candidate.retain(bytes) }
    let store = try await candidate.complete(snapshot: root), lane = await store.lane
    let expected = delete ? ["sentinel B"] : ["later E", "sentinel B"]
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == expected)
    #expect(try await store.snapshot().through == 1)
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") } == [[.integer(5)], [.integer(2)]])
    let sink = SharedSnapshotSink(collection: descriptor.collection, protection: protection)
    let snapshot = try await GeneralSnapshotV1.write(records: records, bootstrapSnapshot: root, chunkBytes: 256, fanout: 2) { try await sink.emit($0, $1) }
    let snapshotObjects = await sink.objects
    for bytes in snapshotObjects.values { _ = try await store.receive(bytes) }
    guard case .accepted = try await store.receive(snapshotObjects[snapshot]!) else { Issue.record("Valid partial-cut snapshot must be accepted"); return }
    let before = try await store.snapshot()
    try await lane.perform { $0.work = StorageWork() }
    let reconstructed = try await store.rebuildCurrentRows()
    #expect(reconstructed.notes == before.notes && reconstructed.context == before.context)
    #expect(reconstructed.notes.map(\.value.body.string).sorted() == expected)
    #expect(try await lane.perform { $0.work?.stages.values.reduce(0) { $0 + $1.reconstructionOutsideOperations } } == 1)
    #expect(try await lane.perform { $0.work?.stages.values.reduce(0) { $0 + $1.reconstructionReusedCells } } == 1)
    let b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    _ = try await put("follow-on saved edit", birth: b, generation: 1, session: store)
    #expect(try await store.snapshot().notes.first { $0.birth == b }?.value.body.string == "follow-on saved edit")
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.first { $0.birth == b }?.value.body.string == "follow-on saved edit")
    try await reopened.quiesce()
}
