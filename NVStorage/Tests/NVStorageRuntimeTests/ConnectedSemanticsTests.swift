import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

private func n(_ byte: UInt8 = 1) throws -> NoteBirth { try NoteBirth(bytes: Array(repeating: byte, count: 16)) }
private func remove(_ birth: NoteBirth, _ store: LocalStoreSession) async throws -> AcceptedHistoryReceipt {
    let capture = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: birth, generation: 100))])
    return try requireReceipt(await store.persist(capture: capture))
}
private func reopen(_ store: LocalStoreSession, _ protection: ObjectProtectionV1) async throws -> LocalStoreSession {
    let selection = await store.selection; try await store.quiesce()
    return try await .open(selection: selection, protection: protection)
}

@Test(arguments: [false, true]) func deleteCoverageRetractsOnlyUntouchedPreservation(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let old = try n(), d0 = try await remove(old, left)
    let e = try await put("uncovered E", birth: old, generation: 1, session: right)
    _ = try await left.receive(right.retainedObject(at: e.object))
    let temporary = try #require(try await left.snapshot().notes.first { $0.automatic != nil })
    #expect(temporary.value.body.string == "uncovered E" && temporary.birth != old)
    #expect(try await left.snapshot().notes.allSatisfy { $0.birth != old })
    _ = try snapshotReceipt(await left.persistGeneralSnapshot(capture: left.captureGeneralSnapshot()))
    let d1 = try await remove(old, right)
    _ = try await left.receive(right.retainedObject(at: d1.object))
    _ = try await left.rebuildCurrentRows()
    #expect(try await left.snapshot().notes.map(\.value.body.string) == ["untouched"])
    let graph = try await left.lane.retainedGraph(through: left.snapshot().through, selection: left.selection, protection: protection)
    #expect(!graph.operations.values.contains { if case .retireConflict = $0.effect { true } else { false } })
    #expect(graph.operations.values.filter { $0.effect.noteValue?.body.string == "uncovered E" }.count == 1)
    left = try await reopen(left, protection)
    #expect(try await left.snapshot().notes.map(\.value.body.string) == ["untouched"])
    // A third writer extending E while D1 is unknown supplies genuinely uncovered F.
    let third = try await newSession(initial, protection)
    _ = try await third.receive(right.retainedObject(at: e.object))
    let f = try await put("uncovered F", birth: old, generation: 2, session: third)
    _ = try await left.receive(third.retainedObject(at: f.object))
    #expect(Set(try await left.snapshot().notes.map(\.value.body.string)) == ["untouched", "uncovered F"])
    _ = try await third.receive(left.retainedObject(at: d0.object))
    _ = try await third.receive(right.retainedObject(at: d1.object))
    #expect(Set(try await third.snapshot().notes.map(\.value.body.string)) == ["untouched", "uncovered F"])
    try await left.quiesce(); try await right.quiesce(); try await third.quiesce()
}

@Test(arguments: [false, true]) func independentAutomaticEditSurvivesLateCoverageAndRetirement(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let old = try n(), d0 = try await remove(old, left)
    let e = try await put("uncovered E", birth: old, generation: 1, session: right)
    _ = try await left.receive(right.retainedObject(at: e.object))
    let copy = try #require(try await left.snapshot().notes.first { $0.automatic != nil })
    _ = try snapshotReceipt(await left.persistGeneralSnapshot(capture: left.captureGeneralSnapshot()))
    let p = try await put("independent P", birth: copy.birth, generation: 2, session: left)
    let d1 = try await remove(old, right)
    _ = try await right.receive(left.retainedObject(at: d0.object))
    #expect(try await right.snapshot().notes.map(\.value.body.string) == ["untouched"])
    _ = try await right.receive(left.retainedObject(at: p.object))
    _ = try await left.receive(right.retainedObject(at: d1.object))
    _ = try await left.rebuildCurrentRows()
    for store in [left, right] {
        let current = try #require(try await store.snapshot().notes.first { $0.birth == copy.birth })
        #expect(current.value.body.string == "independent P" && current.automatic == nil)
        #expect(current.identity == copy.identity)
    }
    left = try await reopen(left, protection)
    #expect(try await left.snapshot().notes.first { $0.birth == copy.birth }?.value.body.string == "independent P")
    let deletion = try await remove(copy.birth, left)
    let bytes = try await left.retainedObject(at: deletion.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection).payload)
    #expect(payload.operations.count == 2)
    #expect(payload.operations.contains { if case .retireConflict(_, let birth, let identity) = $0.operation.effect { birth == copy.birth && identity == copy.identity } else { false } })
    _ = try await right.receive(bytes)
    _ = try await right.receive(left.retainedObject(at: p.object))
    #expect(try await right.snapshot().notes.map(\.value.body.string) == ["untouched"])
    try await left.quiesce(); try await right.quiesce()
}

@Test(arguments: [false, true]) func reciprocalCopiesKeepSourceAndDurableDispositions(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let source = try n()
    let l = try await put("Left", birth: source, generation: 1, session: left)
    let r = try await put("Right", birth: source, generation: 1, session: right)
    let lID = try #require(try await left.snapshot().notes.first { $0.birth == source }).revision.id
    let rID = try #require(try await right.snapshot().notes.first { $0.birth == source }).revision.id
    _ = try await left.pinCurrent(for: source); _ = try await right.pinCurrent(for: source)
    _ = try await left.receive(right.retainedObject(at: r.object)); _ = try await right.receive(left.retainedObject(at: l.object))
    let original = try #require(try await left.snapshot().notes.first { $0.birth == source })
    let rightOriginal = try #require(try await right.snapshot().notes.first { $0.birth == source })
    #expect(original.value.body.string == "Left" && rightOriginal.value.body.string == "Right")
    let lc = try await left.copyVersion(for: source, revision: rID, generation: 2)
    let rc = try await right.copyVersion(for: source, revision: lID, generation: 2)
    let lr = try requireReceipt(await left.persist(capture: lc)), rr = try requireReceipt(await right.persist(capture: rc))
    let duplicate = try requireReceipt(await left.persist(capture: lc))
    #expect(duplicate.object == lr.object)
    _ = try await left.receive(right.retainedObject(at: rr.object)); _ = try await right.receive(left.retainedObject(at: lr.object))
    for store in [left, right] {
        let current = try #require(try await store.snapshot().notes.first { $0.birth == source })
        #expect(current == (store === left ? original : rightOriginal))
        #expect(try await store.snapshot().notes.count == 4)
        #expect(try await store.conflicts(for: source).alternatives.isEmpty)
        #expect(try await store.conflicts(for: source).representedSeparately.isSuperset(of: [lID, rID]))
    }
    let pinnedPublication = try await right.prepareReduction(liveGeneration: 42)
    _ = try await right.releaseCurrentPin(for: source)
    await #expect(throws: StorageError.staleCapture) {
        try await right.publish(pinnedPublication, liveGeneration: 42) { $0.notes.count }
    }
    _ = try await left.releaseCurrentPin(for: source)
    let settled = try #require(try await left.snapshot().notes.first { $0.birth == source })
    #expect(try await right.snapshot().notes.first { $0.birth == source } == settled)
    let settledPublication = try await right.prepareReduction(liveGeneration: 42)
    #expect(try await right.publish(settledPublication, liveGeneration: 42) { $0.notes.count } == 4)
    let copiedBirth = lc.covered[0].birth
    _ = try snapshotReceipt(await left.persistGeneralSnapshot(capture: left.captureGeneralSnapshot()))
    let deleted = try await remove(copiedBirth, left)
    _ = try await right.receive(left.retainedObject(at: deleted.object))
    _ = try await left.rebuildCurrentRows()
    left = try await reopen(left, protection)
    #expect(try await left.conflicts(for: source).alternatives.isEmpty)
    #expect(try await left.conflicts(for: source).representedSeparately.isSuperset(of: [lID, rID]))
    #expect(try await left.snapshot().notes.allSatisfy { $0.birth != copiedBirth })
    // A later intentional copy uses another slot and preserves completed disposition history.
    let later = try await left.copyVersion(for: source, revision: rID, generation: 3)
    #expect(later.covered[0].birth != copiedBirth)
    _ = try requireReceipt(await left.persist(capture: later))
    #expect(try await left.snapshot().notes.first { $0.birth == source } == settled)
    try await left.quiesce(); try await right.quiesce()
}
