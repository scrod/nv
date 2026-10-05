import Crypto
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Complete independently constructed import and ordinary action share one authenticated envelope.
private func sharedBootstrap(encrypted: Bool, delete: Bool) throws ->
    (BootstrapDescriptorV1, SegmentLocator, [SegmentLocator: [UInt8]], ObjectProtectionV1, [GeneralSnapshotRecordV1]) {
    let collection = try CollectionID(bytes: Array(repeating: 31, count: 16))
    let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: try CollectionKeyID(bytes: Array(repeating: 32, count: 16)),
        key: SymmetricKey(data: Array(repeating: 33, count: 32))) : .publicHash
    let importID = try ImportID(bytes: Array(repeating: 34, count: 16))
    let origin = try ActionOriginID(bytes: Array(repeating: 35, count: 16))
    let importAction = try ActionID(bytes: Array(repeating: 36, count: 16)), laterAction = try ActionID(bytes: Array(repeating: 37, count: 16))
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let values = try [(a, testValue("initial A")), (b, testValue("sentinel B"))]
    var hash = InitialValuesHasherV1(expectedCount: 2)
    for (birth, value) in values { try hash.append(birth: birth, value: value) }
    let digest = try hash.finish()
    var records: [OperationRecordV1] = []
    func record(_ effect: OperationEffectV1, parent: Int?, predecessor: Int? = nil) throws -> OperationRecordV1 {
        let parents: [OperationReference] = parent.map { [.earlierLocal(index: OperationIndex(UInt32($0)))] } ?? []
        let previous: [OperationReference] = predecessor.map { [.earlierLocal(index: OperationIndex(UInt32($0)))] } ?? []
        let ops = records.map(\.operation)
        let op = try IdentifiedOperation(nonce: OperationNonce(bytes: uuidBytes()), effect: effect,
            causalParents: CausalParentSet(parent.map { [ops[$0].id] } ?? []),
            notePredecessors: NotePredecessorSet(predecessor.map { [ops[$0].id] } ?? []))
        return try OperationRecordV1(operation: op, causalReferences: parents, noteReferences: previous, earlierOperations: ops)
    }
    records.append(try record(.genesis(importID: importID, profile: encrypted ? .encryptedSegments : .plaintextFiles,
        initialCount: 2, initialValuesDigest: digest), parent: nil))
    records.append(try record(.importNote(action: importAction, birth: a, value: values[0].1), parent: 0))
    records.append(try record(.importNote(action: importAction, birth: b, value: values[1].1), parent: 1))
    records.append(try record(.importComplete(importID: importID, initialCount: 2, initialValuesDigest: digest), parent: 2))
    records.append(try record(delete ? .delete(action: laterAction, birth: a) : .put(action: laterAction, birth: a, value: testValue("later E")),
        parent: 3, predecessor: delete ? nil : 1))
    let imports = try ActionRecordV1(id: importAction, origin: origin, previousOrigin: nil, scope: .collection, scopeParents: [],
        kind: .createImportBatch, members: [OperationIndex(1), OperationIndex(2)], affected: [
            .init(birth: a, before: .freshBirthAbsence, after: .value(.earlierLocal(index: OperationIndex(1)))),
            .init(birth: b, before: .freshBirthAbsence, after: .value(.earlierLocal(index: OperationIndex(2))))], operations: records.map(\.operation), earlierActions: [])
    let later = try ActionRecordV1(id: laterAction, origin: origin, previousOrigin: .earlierLocal(index: ActionIndex(0)),
        scope: .note(a), scopeParents: [], kind: delete ? .deleteBatch : .savedEdit, members: [OperationIndex(4)], affected: [
            .init(birth: a, before: .value(.earlierLocal(index: OperationIndex(1))),
                after: delete ? .deleted(.earlierLocal(index: OperationIndex(4))) : .value(.earlierLocal(index: OperationIndex(4))))],
        operations: records.map(\.operation), earlierActions: [imports.action])
    var objects: [SegmentLocator: [UInt8]] = [:]
    func emit(_ payload: [UInt8], kind: ProviderObjectKind) throws -> SegmentLocator {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection,
            writer: WriterEpoch(bytes: Array(repeating: 38, count: 16)), sequence: UInt64(objects.count), protection: protection)
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        objects[locator] = bytes; return locator
    }
    let locator = try emit(ChangesPayloadV1(dependencies: DependencyLocatorTable([]), operations: records, actions: [imports, later]).encodedV1(), kind: .changes)
    let descriptor: BootstrapDescriptorV1
    if encrypted { descriptor = try .wrap(collection: collection, keyID: CollectionKeyID(bytes: Array(repeating: 32, count: 16)),
        genesis: locator, collectionKey: SymmetricKey(data: Array(repeating: 33, count: 32)), passphrase: "test") }
    else { descriptor = try .publicDescriptor(collection: collection, genesis: locator) }
    func reference(_ index: Int) -> StoredOperationReferenceV1 { .init(locator: locator, index: OperationIndex(UInt32(index)), id: records[index].operation.id) }
    let rows = try values.enumerated().map { i, pair in
        try InitialSnapshotRowV1(birth: pair.0, value: pair.1, importReference: reference(i + 1).reference)
    }
    let page = try InitialSnapshotPageV1(importID: importID, index: 0, dependencies: DependencyLocatorTable([locator]), rows: rows)
    let pageLocator = try emit(page.encodedV1(), kind: .snapshotPage)
    let root = try InitialSnapshotRootV1(importID: importID, initialCount: 2, digest: digest, dependencies: DependencyLocatorTable([locator]),
        completion: reference(3).reference, frontier: [reference(3).reference], pages: [.init(index: 0, locator: pageLocator, rowCount: 2)])
    let rootLocator = try emit(root.encodedV1(), kind: .snapshotRoot)
    let snapshotRecords: [GeneralSnapshotRecordV1] = try [
        .current(CurrentNoteCellV1(birth: a, value: values[0].1, revision: reference(1), scopeFrontier: [])),
        .current(CurrentNoteCellV1(birth: b, value: values[1].1, revision: reference(2), scopeFrontier: [])),
        .frontier(reference(3)), .scope(.collection, .init(locator: locator, index: ActionIndex(0), id: importAction))]
    return (descriptor, rootLocator, objects, protection, snapshotRecords)
}

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
