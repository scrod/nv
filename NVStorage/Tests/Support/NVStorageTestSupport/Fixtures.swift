import Foundation
import Crypto
import Testing
import NVStorageCore
import NVStorageRuntime

// Shared fixtures construct complete histories and exercise the public save path.

package func testValue(_ body: String) throws -> PlaintextNoteValue {
    try PlaintextNoteValue(title: ExactUTF8(bytes: Array("Title".utf8)), body: ExactUTF8(bytes: Array(body.utf8)),
        labels: CanonicalLabels([]), created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 1))
}
package func testInitial(_ encrypted: Bool) throws -> (InitialCollectionV1, ObjectProtectionV1) {
    let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: try CollectionKeyID(bytes: Array(repeating: 3, count: 16)),
        key: SymmetricKey(data: Array(repeating: 4, count: 32))) : .publicHash
    let collection = try CollectionID(bytes: Array(repeating: 1, count: 16))
    let notes = try [(NoteBirth(bytes: Array(repeating: 1, count: 16)), testValue("A")),
                     (NoteBirth(bytes: Array(repeating: 2, count: 16)), testValue("untouched"))]
    return (try InitialCollectionV1.build(collection: collection, notes: notes, protection: protection, passphrase: encrypted ? "synthetic" : nil), protection)
}

package func privateTempPath() -> String { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path }

package func emptyRepository() throws -> String {
    let path = privateTempPath()
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    return path
}

package func newSession(_ initial: InitialCollectionV1, _ protection: ObjectProtectionV1) async throws -> LocalStoreSession {
    try await .create(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        initial: initial, protection: protection)
}
package func put(_ body: String, birth: NoteBirth, generation: UInt64, session: LocalStoreSession) async throws -> AcceptedHistoryReceipt {
    let capture = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .savedEdit,
        changes: [.put(CapturedNoteGeneration(birth: birth, generation: generation), testValue(body))])
    return try requireReceipt(await session.persist(capture: capture))
}

package func requireReceipt(_ outcome: CommitOutcome) throws -> AcceptedHistoryReceipt {
    switch outcome {
    case .accepted(let receipt): return receipt
    case .pending(_, let error): Issue.record("Commit remained pending: \(error)"); throw error
    }
}

/// Complete independently constructed import and ordinary action share one authenticated envelope.
package func sharedBootstrap(encrypted: Bool, delete: Bool) throws ->
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

package func snapshotReceipt(_ result: SnapshotCommitOutcome) throws -> AcceptedSnapshotReceipt {
    guard case .accepted(let receipt) = result else { Issue.record("Expected complete durable snapshot acceptance"); throw StorageError.incomplete }
    return receipt
}

package actor ImprovementGate {
    package init() {}
    private var arrived = false
    private var released = false
    private var held: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    package func signal() { arrived = true; for observer in observers { observer.resume() }; observers.removeAll() }
    package func hold() async {
        if arrived || released { return }
        await withCheckedContinuation { held = $0; signal() }
    }
    package func wait() async { if !arrived { await withCheckedContinuation { observers.append($0) } } }
    package func release() { released = true; held?.resume(); held = nil }
}

private func uuidBytes() -> [UInt8] {
    let u = UUID().uuid
    return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
}
