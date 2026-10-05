import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Test-only record-by-record reader retained as a comparison for envelope batching.
private struct RecordByRecordReference: Sendable {
    let operations: [OperationID: IdentifiedOperation]
    let actions: [ActionID: ActionV1]
    let operationReferences: [OperationID: StoredOperationReferenceV1]
    let actionReferences: [ActionID: StoredActionReferenceV1]
    static func read(lane: DatabaseLane, selection: LocalStoreSelection, protection: ObjectProtectionV1) async throws -> Self {
        try await lane.verifyingHistory {
            let ids = try await lane.perform { db in
                (try db.rows("SELECT operation_id FROM operations ORDER BY operation_id"),
                 try db.rows("SELECT action_id FROM actions ORDER BY action_id"))
            }
            var operations: [OperationID: IdentifiedOperation] = [:], actions: [ActionID: ActionV1] = [:]
            var operationReferences: [OperationID: StoredOperationReferenceV1] = [:], actionReferences: [ActionID: StoredActionReferenceV1] = [:]
            for row in ids.0 {
                let id = try OperationID(bytes: row[0].bytes)
                let (operation, reference) = try await lane.perform { db in
                    (try #require(try db.operation(id, selection: selection, protection: protection)), try db.operationOccurrence(id))
                }
                operations[id] = operation; operationReferences[id] = reference
            }
            for row in ids.1 {
                let id = try ActionID(bytes: row[0].bytes)
                let (action, reference) = try await lane.perform { db in
                    (try #require(try db.action(id, selection: selection, protection: protection)), try db.actionOccurrence(id))
                }
                actions[id] = action; actionReferences[id] = reference
            }
            return Self(operations: operations, actions: actions, operationReferences: operationReferences, actionReferences: actionReferences)
        }
    }
}

private func comparePackedReaders(encrypted: Bool, size: Int, rounds: Int) async throws {
    let (reference, protection) = try testInitial(encrypted)
    let expected = try (0..<size).map { index in
        let suffix = (0..<8).reversed().map { UInt8(truncatingIfNeeded: UInt64(index + 1) >> ($0 * 8)) }
        return try (NoteBirth(bytes: Array(repeating: 19, count: 8) + suffix), testValue("packed-\(index)-" + String(repeating: "x", count: 1024)))
    }
    var writer = try InitialCollectionWriterV1(collection: reference.descriptor.collection, notes: expected,
        protection: protection, passphrase: encrypted ? "test" : nil, targetBytes: 32_768, notesPerAction: 3)
    var objects: [SegmentLocator: [UInt8]] = [:]
    while let next = try writer.next() { objects[next.locator] = next.bytes }
    let root = try #require(writer.snapshot)
    let selection = try LocalStoreSelection(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        store: LocalStoreID(bytes: uuidBytes()), descriptor: writer.descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: root, protection: protection)
    for bytes in objects.values { _ = try await candidate.retain(bytes) }
    let store = try await candidate.complete(snapshot: root), lane = await store.lane
    let sources = try Set(objects.values.compactMap { bytes -> SegmentID? in
        let opened = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection)
        return opened.kind == .changes ? opened.locator.segmentID : nil
    })
    let frozenReference = try await RecordByRecordReference.read(lane: lane, selection: selection, protection: protection)
    for round in 0..<rounds {
        for batched in (round % 2 == 0 ? [false, true] : [true, false]) {
            try await lane.perform { $0.work = StorageWork() }
            let start = DispatchTime.now().uptimeNanoseconds
            let elapsed: UInt64
            if batched {
                let traversal = try await CheckedHistoryTraversal.read(through: 1, scope: .representatives, lane: lane, selection: selection, protection: protection)
                elapsed = DispatchTime.now().uptimeNanoseconds - start
                let graph = traversal.graph
                #expect(graph.operations.count == size + 2)
                #expect(try Dictionary(uniqueKeysWithValues: graph.currentCells(collection: selection.descriptor.collection).map { ($0.birth, $0.value) }) == Dictionary(uniqueKeysWithValues: expected))
                #expect(graph.operations == frozenReference.operations && graph.actions == frozenReference.actions)
                #expect(graph.operationReferences == frozenReference.operationReferences && graph.actionReferences == frozenReference.actionReferences)
            } else {
                let original = try await RecordByRecordReference.read(lane: lane, selection: selection, protection: protection)
                elapsed = DispatchTime.now().uptimeNanoseconds - start
                #expect(original.operations.count == size + 2)
                #expect(Set(original.operations.values.compactMap { operation -> String? in
                    if case .importNote(_, _, let value) = operation.effect { return value.body.string }; return nil
                }) == Set(expected.map { $0.1.body.string }))
            }
            let work = try await lane.perform { $0.work! }
            let visits = work.stages.values.flatMap { $0.traversalDecodes.values }, payloads = work.stages.values.flatMap { $0.traversalPayloadDecodes.values }
            if batched {
                #expect(visits.count == 1 && payloads.count == 1)
                try #require(visits.count == 1 && payloads.count == 1)
                #expect(Set(visits[0].keys) == sources && visits[0] == payloads[0] && visits[0].values.allSatisfy { $0 == 1 })
            }
            #expect(work.stages.values.reduce(0) { $0 + $1.envelopeDecodes } == (batched ? sources.count : frozenReference.operations.count + frozenReference.actions.count))
            if rounds > 1 { print("PACKED-READER encrypted=\(encrypted) notes=\(size) round=\(round) batched=\(batched) elapsedNS=\(elapsed) decodes=\(work.stages.values.reduce(0) { $0 + $1.envelopeDecodes }) sql=\(work.stages.values.reduce(0) { $0 + $1.statements })") }
        }
    }
    try await store.quiesce()
}

@Test(arguments: [false, true])
func batchedReaderMatchesRecordReferenceAndIndependentValues(encrypted: Bool) async throws {
    try await comparePackedReaders(encrypted: encrypted, size: 16, rounds: 1)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_STORAGE_IMPROVEMENT_BENCHMARK"] == "1"),
      arguments: [false, true], [64, 256, 1024, 2048])
func packedReaderImprovementMeasurements(encrypted: Bool, size: Int) async throws {
    try await comparePackedReaders(encrypted: encrypted, size: size, rounds: 3)
}
