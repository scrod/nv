import NVStorageTestSupport
import Crypto
import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

/// Independent provider sink for immutable snapshot manifests and exact test inventories.
private actor RetentionSink {
    let collection: CollectionID
    let protection: ObjectProtectionV1
    let writer: WriterEpoch
    var sequence: UInt64 = 0
    var objects: [SegmentLocator: [UInt8]] = [:]
    init(collection: CollectionID, protection: ObjectProtectionV1) throws {
        self.collection = collection; self.protection = protection
        writer = try WriterEpoch(bytes: withUnsafeBytes(of: UUID().uuid) { Array($0) })
    }
    func emit(_ kind: ProviderObjectKind, _ payload: [UInt8]) throws -> SegmentLocator {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection,
            writer: writer, sequence: sequence, protection: protection)
        sequence += 1
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        objects[locator] = bytes; return locator
    }
}

private struct RetentionFixture: Sendable {
    let root: SegmentLocator
    let objects: [SegmentLocator: [UInt8]]
    static func build(_ capture: GeneralSnapshotCapture, protection: ObjectProtectionV1,
                      parents: [SegmentLocator]? = nil) async throws -> Self {
        let sink = try RetentionSink(collection: capture.collection, protection: protection)
        let root = try await GeneralSnapshotV1.write(records: capture.records, bootstrapSnapshot: capture.bootstrapSnapshot,
            retentionParents: parents ?? capture.retentionParents, chunkBytes: 128, fanout: 3) {
                try await sink.emit($0, $1)
            }
        return Self(root: root, objects: await sink.objects)
    }
    func preview(collection: CollectionID, protection: ObjectProtectionV1) async throws -> GeneralSnapshotPreviewV1 {
        try await .read(snapshot: root, collection: collection, protection: protection) { objects[$0] }
    }
    func deliver(to session: LocalStoreSession) async throws -> ObjectAcceptanceOutcome {
        for locator in objects.keys.sorted(by: { $0.sequence < $1.sequence }) where locator != root {
            _ = try await session.receive(objects[locator]!)
        }
        return try await session.receive(objects[root]!)
    }
}

/// Checks the actual graph independently of the incremental frontier update.
private func assertRetentionClosure(_ session: LocalStoreSession, expected: Set<SegmentID>) async throws {
    let (accepted, edges, frontier) = try await session.lane.perform { db in
        try (Set(db.rows("SELECT a.object_id FROM accepted_objects a JOIN objects o USING(object_id) WHERE o.kind BETWEEN 1 AND 3").map { try SegmentID(bytes: $0[0].bytes) }),
             db.rows("SELECT child,prerequisite FROM accepted_dependencies"),
             Set(db.rows("SELECT object_id FROM retained_frontier").map { try SegmentID(bytes: $0[0].bytes) }))
    }
    var prerequisites: [SegmentID: Set<SegmentID>] = [:]
    for row in edges { try prerequisites[SegmentID(bytes: row[0].bytes), default: []].insert(SegmentID(bytes: row[1].bytes)) }
    #expect(frontier == expected)
    #expect(frontier == accepted.subtracting(prerequisites.values.reduce(into: Set<SegmentID>()) { $0.formUnion($1) }))
    var covered: Set<SegmentID> = [], pending = Array(frontier)
    while let object = pending.popLast() {
        if covered.insert(object).inserted { pending += Array(prerequisites[object] ?? []) }
    }
    #expect(covered == accepted)
}

@Test(arguments: [false, true])
func snapshotRetentionSequentialCoverageSurvivesRestart(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let before = try await session.snapshot(), birth = before.notes[0].birth
    let undo = try await session.undoCandidates(scope: .note(birth), direction: .undo)
    let conflicts = try await session.conflicts(for: birth)
    var inventory = initial.objects, parent = initial.snapshot
    for _ in 0..<8 {
        let capture = try await session.captureGeneralSnapshot()
        #expect(capture.retentionParents == [parent])
        let lane = await session.lane
        try await lane.perform { $0.work = StorageWork() }
        let receipt = try snapshotReceipt(await session.persistGeneralSnapshot(capture: capture))
        let preview = try await GeneralSnapshotPreviewV1.read(snapshot: receipt.snapshot, collection: initial.descriptor.collection,
            protection: protection) { try await session.retainedObject(at: $0) }
        #expect(preview.root.encodedV1()[9] == 1 && preview.retentionParents == [parent])
        let work = try await lane.perform { try #require($0.work) }
        #expect(work.stages.values.reduce(0) { $0 + $1.retentionParentChecks } == 2)
        #expect(work.stages.values.allSatisfy { $0.ancestors == 0 })
        for locator in preview.pages.union([receipt.snapshot]) { inventory[locator] = try await session.retainedObject(at: locator) }
        try await assertRetentionClosure(session, expected: [receipt.snapshot.segmentID])
        let actualFrontier = try await lane.perform { try $0.rows("SELECT object_id FROM retained_frontier") }
        #expect(actualFrontier == [[.blob(receipt.snapshot.segmentID.bytes)]])
        parent = receipt.snapshot
    }
    let selection = await session.selection; try await session.quiesce()
    for _ in 0..<2 {
        let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
        #expect(try await reopened.snapshot().notes == before.notes)
        #expect(try await reopened.undoCandidates(scope: .note(birth), direction: .undo).ids == undo.ids)
        #expect(try await reopened.conflicts(for: birth).representedSeparately == conflicts.representedSeparately)
        try await assertRetentionClosure(reopened, expected: [parent.segmentID])
        for (locator, bytes) in inventory { #expect(try await reopened.retainedObject(at: locator) == bytes) }
        #expect(try await reopened.rebuildCurrentRows().notes == before.notes)
        try await reopened.quiesce()
    }
}

@Test(arguments: [false, true])
func snapshotRetentionStaleCaptureKeepsConcurrentRoot(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let common = try await left.snapshot()
    let leftRoot = try snapshotReceipt(await left.persistGeneralSnapshot(capture: left.captureGeneralSnapshot()))
    let capture = try await left.captureGeneralSnapshot()
    let rightRoot = try snapshotReceipt(await right.persistGeneralSnapshot(capture: right.captureGeneralSnapshot()))
    for locator in rightRoot.pages { _ = try await left.receive(right.retainedObject(at: locator)) }
    _ = try await left.receive(right.retainedObject(at: rightRoot.snapshot))
    let child = try snapshotReceipt(await left.persistGeneralSnapshot(capture: capture))
    #expect(capture.retentionParents == [leftRoot.snapshot])
    try await assertRetentionClosure(left, expected: [child.snapshot.segmentID, rightRoot.snapshot.segmentID])
    let tips = try await left.lane.perform { db in try Set(db.rows("SELECT object_id FROM retained_frontier").map { try SegmentID(bytes: $0[0].bytes) }) }
    #expect(tips == [child.snapshot.segmentID, rightRoot.snapshot.segmentID])
    let after = try await left.snapshot()
    #expect(after.notes == common.notes && after.context == common.context)
    let joinCapture = try await left.captureGeneralSnapshot()
    #expect(Set(joinCapture.retentionParents) == [child.snapshot, rightRoot.snapshot])
    let join = try snapshotReceipt(await left.persistGeneralSnapshot(capture: joinCapture))
    try await assertRetentionClosure(left, expected: [join.snapshot.segmentID])
    for receipt in [leftRoot, child, join] {
        for locator in receipt.pages { _ = try await right.receive(left.retainedObject(at: locator)) }
        _ = try await right.receive(left.retainedObject(at: receipt.snapshot))
    }
    try await assertRetentionClosure(right, expected: [join.snapshot.segmentID])
    #expect(try await right.snapshot().notes == common.notes)
    try await left.quiesce(); try await right.quiesce()
}

@Test(arguments: [false, true])
func snapshotRetentionDelayedParentsWakeAfterRestart(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection), receipts: [AcceptedSnapshotReceipt] = []
    for _ in 0..<3 { receipts.append(try snapshotReceipt(await source.persistGeneralSnapshot(capture: source.captureGeneralSnapshot()))) }
    let child = receipts[2], parent = receipts[1]
    for locator in child.pages { _ = try await receiver.receive(source.retainedObject(at: locator)) }
    guard case .waiting(let inputs) = try await receiver.receive(source.retainedObject(at: child.snapshot)) else {
        Issue.record("The child needs the accepted parent root"); return
    }
    #expect(inputs == [.acceptedHistory(parent.snapshot)])
    #expect(try await receiver.snapshot().through == 1)
    let selection = await receiver.selection; try await receiver.quiesce()
    receiver = try await LocalStoreSession.open(selection: selection, protection: protection)
    for receipt in [parent, receipts[0]] {
        for locator in receipt.pages { _ = try await receiver.receive(source.retainedObject(at: locator)) }
        _ = try await receiver.receive(source.retainedObject(at: receipt.snapshot))
    }
    guard case .accepted = try await receiver.receivedObjectStatus(at: child.snapshot) else { Issue.record("Every dependency arrived; the parked child must wake"); return }
    let before = try await receiver.snapshot()
    _ = try await receiver.receive(source.retainedObject(at: child.snapshot))
    #expect(try await receiver.snapshot().through == before.through)
    #expect(before.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await assertRetentionClosure(receiver, expected: [child.snapshot.segmentID])
    try await receiver.quiesce(); try await source.quiesce()
}

@Test(arguments: [false, true])
func snapshotRetentionOldCutCanCoverNewerCut(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let old = try await session.captureGeneralSnapshot(), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("newer preserved", birth: birth, generation: 1, session: session)
    let newer = try snapshotReceipt(await session.persistGeneralSnapshot(capture: session.captureGeneralSnapshot()))
    let current = try await session.snapshot()
    let fixture = try await RetentionFixture.build(old, protection: protection, parents: [newer.snapshot])
    guard case .accepted = try await fixture.deliver(to: session) else { Issue.record("Retention and logical cuts are independent"); return }
    try await assertRetentionClosure(session, expected: [fixture.root.segmentID])
    let after = try await session.snapshot()
    #expect(after.notes == current.notes && after.context == current.context)
    #expect(try await session.retainedObject(at: edit.object).isEmpty == false)
    #expect(try await session.rebuildCurrentRows().notes == current.notes)
    #expect(try await session.undoCandidates(scope: .note(birth), direction: .undo).ids.first == current.notes.first { $0.birth == birth }?.scopeFrontier.first?.id)
    try await session.quiesce()
}

@Test(arguments: [false, true])
func snapshotRetentionWideFanInAndEmptyParentRoots(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let capture = try await session.captureGeneralSnapshot()
    var parents: [SegmentLocator] = [], inventory: [SegmentLocator: [UInt8]] = [:]
    for n in 0..<16 {
        let fixture = try await RetentionFixture.build(capture, protection: protection,
            parents: n == 0 ? [] : [initial.snapshot])
        guard case .accepted = try await fixture.deliver(to: session) else { Issue.record("Independent compatible roots accept"); return }
        parents.append(fixture.root); inventory.merge(fixture.objects) { a, _ in a }
        if n == 0 { #expect(try await fixture.preview(collection: capture.collection, protection: protection).retentionParents.isEmpty) }
    }
    try await assertRetentionClosure(session, expected: Set(parents.map(\.segmentID)))
    let joined = try await session.captureGeneralSnapshot()
    #expect(Set(joined.retentionParents) == Set(parents))
    let receipt = try snapshotReceipt(await session.persistGeneralSnapshot(capture: joined))
    try await assertRetentionClosure(session, expected: [receipt.snapshot.segmentID])
    for (locator, bytes) in inventory { #expect(try await session.retainedObject(at: locator) == bytes) }
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await session.quiesce()
}

@Test(arguments: [false, true], ["kind", "locator", "corrupt", "collection", "missing"])
func snapshotRetentionRejectsInvalidParentEvidence(encrypted: Bool, fault: String) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let root = try snapshotReceipt(await session.persistGeneralSnapshot(capture: session.captureGeneralSnapshot()))
    let before = try await session.snapshot(), capture = try await session.captureGeneralSnapshot(), lane = await session.lane
    var parent = root.snapshot
    if fault == "kind" { parent = initial.descriptor.genesis }
    if fault == "locator" { parent = SegmentLocator(writerEpoch: parent.writerEpoch, sequence: parent.sequence + 1, segmentID: parent.segmentID) }
    let fixture = try await RetentionFixture.build(capture, protection: protection, parents: [parent])
    let preview = try await fixture.preview(collection: capture.collection, protection: protection)
    let parentID = parent.segmentID
    if fault == "corrupt" || fault == "collection" {
        let replacement: [UInt8]
        if fault == "collection" {
            let bytes = try await session.retainedObject(at: parent)
            let opened = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection)
            replacement = try ObjectEnvelopeV1.seal(payload: opened.payload, kind: .snapshotRoot,
                collection: CollectionID(bytes: uuidBytes()), writer: parent.writerEpoch,
                sequence: parent.sequence, protection: protection)
        } else { replacement = [0] }
        try await lane.perform { db in
            try db.exec("DROP TRIGGER objects_no_update")
            try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob(replacement), .blob(parentID.bytes)])
        }
    }
    if fault == "missing" {
        try await lane.perform { db in
            try db.exec("PRAGMA foreign_keys=OFF")
            try db.run("DELETE FROM objects WHERE object_id=?", [.blob(parentID.bytes)])
            try db.exec("PRAGMA foreign_keys=ON")
        }
    }
    let expected: any Error = fault == "missing" ? StorageError.incomplete : CanonicalEncodingError.invalidReference
    if fault == "corrupt" {
        await #expect(throws: CanonicalEncodingError.lengthLimit) { try await session.verifyGeneralSnapshot(preview) }
    } else if fault == "collection" {
        await #expect(throws: CanonicalEncodingError.wrongScope) { try await session.verifyGeneralSnapshot(preview) }
    } else {
        await #expect { try await session.verifyGeneralSnapshot(preview) } throws: { String(reflecting: $0) == String(reflecting: expected) }
    }
    if fault == "kind" || fault == "locator" {
        #expect(try await lane.perform { try $0.acceptedThrough() } == before.through)
        #expect(try await session.snapshot().notes == before.notes)
        _ = try await put("unrelated work progresses", birth: before.notes[0].birth, generation: 2, session: session)
        try await session.quiesce()
    } else {
        await #expect(throws: StorageError.integrity) { try await session.snapshot() }
        let selection = await session.selection; await lane.close()
        await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    }
}

@Test(arguments: [false, true])
func snapshotRetentionUnsupportedParentBlocksWithoutRejectingChild(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let capture = try await session.captureGeneralSnapshot()
    let sink = try RetentionSink(collection: capture.collection, protection: protection)
    var payload = Array("NVGRT1\r\n".utf8) + [0, 99]
    payload += [0, 1]
    let unsupported = try await sink.emit(.snapshotRoot, payload), bytes = await sink.objects
    let child = try await RetentionFixture.build(capture, protection: protection, parents: [unsupported])
    guard case .waiting(let requirements) = try await child.deliver(to: session) else { Issue.record("Unavailable parent must park the child"); return }
    #expect(requirements == [.acceptedHistory(unsupported)])
    await #expect(throws: CanonicalEncodingError.unsupportedFormat) { try await session.receive(bytes[unsupported]!) }
    guard case .blocked(let rejected, let missing) = try await session.receivedObjectStatus(at: child.root) else {
        Issue.record("The unsupported root's outcome belongs to that prerequisite"); return
    }
    #expect(rejected.count == 1 && rejected[0].object == unsupported.segmentID && missing == requirements)
    let selection = await session.selection, lane = await session.lane
    #expect(try await lane.perform { try $0.rows("SELECT 1 FROM rejected_objects WHERE object_id=?", [.blob(child.root.segmentID.bytes)]).isEmpty })
    _ = try snapshotReceipt(await session.persistGeneralSnapshot(capture: session.captureGeneralSnapshot()))
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    guard case .blocked = try await reopened.receivedObjectStatus(at: child.root) else { Issue.record("Blocking reason survives restart"); return }
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    #expect(try await reopened.lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(child.root.segmentID.bytes)]) } == [[.blob(child.objects[child.root]!)]])
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func snapshotRetentionConsumerRechecksExactParent(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let capture = try await session.captureGeneralSnapshot()
    let fixture = try await RetentionFixture.build(capture, protection: protection)
    let preview = try await fixture.preview(collection: capture.collection, protection: protection)
    let lane = await session.lane, selection = await session.selection
    let checked = try await CheckedSnapshotAcceptance.verify(preview, lane: lane, selection: selection, protection: protection)
    try await lane.perform { try checked.check(database: $0, selection: selection) }
    try await lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(initial.snapshot.segmentID.bytes)])
    }
    await #expect(throws: CanonicalEncodingError.lengthLimit) { try await lane.perform { try checked.check(database: $0, selection: selection) } }
    await #expect(throws: StorageError.integrity) { try await session.snapshot() }
    await lane.close()
}

@Test(arguments: [false, true])
func snapshotRetentionReconstructionSharesLogicalTraversal(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    var roots: [AcceptedSnapshotReceipt] = []
    for _ in 0..<16 { roots.append(try snapshotReceipt(await store.persistGeneralSnapshot(capture: store.captureGeneralSnapshot()))) }
    let lane = await store.lane
    try await lane.perform { $0.work = StorageWork() }
    let actual = try await store.rebuildCurrentRows()
    #expect(actual.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let work = try await lane.perform { try #require($0.work) }
    #expect(work.stages.values.reduce(0) { $0 + $1.graphLoads } == 1)
    #expect(work.stages.values.reduce(0) { $0 + $1.retentionParentChecks } == 2)
    let attempts = work.stages.values.flatMap { $0.traversalPayloadDecodes.values }
    #expect(attempts.count == 1 && attempts.allSatisfy { $0.values.allSatisfy { $0 == 1 } })
    #expect(work.stages.values.allSatisfy { $0.ancestors == 0 })
    try await assertRetentionClosure(store, expected: [roots.last!.snapshot.segmentID])
    try await store.quiesce()
}

/// Measures complete production encodings, returning opens and exceptional reconstruction separately.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_RETENTION_BENCHMARK"] == "1"), arguments: [false, true])
func snapshotRetentionProductionBenchmark(encrypted: Bool) async throws {
    func median(_ values: [UInt64]) -> UInt64 { values.sorted()[values.count / 2] }
    for size in [1, 8, 64, 256] {
        let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
        var captures: [UInt64] = [], saves: [UInt64] = []
        for _ in 0..<size {
            var start = DispatchTime.now().uptimeNanoseconds
            let capture = try await store.captureGeneralSnapshot()
            #expect(capture.retentionParents.count == 1)
            captures.append(DispatchTime.now().uptimeNanoseconds - start)
            let lane = await store.lane
            try await lane.perform { $0.work = StorageWork() }
            start = DispatchTime.now().uptimeNanoseconds
            _ = try snapshotReceipt(await store.persistGeneralSnapshot(capture: capture))
            saves.append(DispatchTime.now().uptimeNanoseconds - start)
            let work = try await lane.perform { try #require($0.work) }
            #expect(work.stages.values.reduce(0) { $0 + $1.retentionParentChecks } == 2)
            #expect(work.stages.values.allSatisfy { $0.ancestors == 0 })
        }
        let selection = await store.selection
        try await store.quiesce()
        var opens: [UInt64] = []
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let reopened = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: StorageWork())
            let state = try await reopened.snapshot()
            opens.append(DispatchTime.now().uptimeNanoseconds - start)
            #expect(state.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
            let work = try await reopened.lane.perform { try #require($0.work) }
            #expect(work.stages.values.reduce(0) { $0 + $1.retainedLeafChecks } == 1)
            #expect(work.stages.values.allSatisfy { $0.graphLoads == 0 && $0.historyReads == 0 && $0.ancestors == 0 })
            try await reopened.quiesce()
        }
        let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
        try await reopened.lane.perform { $0.work = StorageWork() }
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await reopened.rebuildCurrentRows()
        let rebuild = DispatchTime.now().uptimeNanoseconds - start
        let work = try await reopened.lane.perform { try #require($0.work) }
        let graphs = work.stages.values.reduce(0) { $0 + $1.graphLoads }
        let checks = work.stages.values.reduce(0) { $0 + $1.retentionParentChecks }
        #expect(graphs == 1 && checks == 2 && work.stages.values.allSatisfy { $0.ancestors == 0 })
        print("RETENTION_BENCH profile=\(encrypted ? "encrypted" : "public") snapshots=\(size) captureNS=\(median(captures)) saveNS=\(median(saves)) openNS=\(median(opens)) rebuildNS=\(rebuild) leaves=1 parentChecks=\(checks) graphs=\(graphs)")
        try await reopened.quiesce()
    }
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let cut = try await store.captureGeneralSnapshot()
    for _ in 0..<64 { _ = try await RetentionFixture.build(cut, protection: protection).deliver(to: store) }
    let capture = try await store.captureGeneralSnapshot()
    #expect(capture.retentionParents.count == 64)
    try await store.lane.perform { $0.work = StorageWork() }
    let start = DispatchTime.now().uptimeNanoseconds
    _ = try snapshotReceipt(await store.persistGeneralSnapshot(capture: capture))
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let work = try await store.lane.perform { try #require($0.work) }
    let checks = work.stages.values.reduce(0) { $0 + $1.retentionParentChecks }
    #expect(checks == 128 && work.stages.values.allSatisfy { $0.ancestors == 0 })
    print("RETENTION_FANIN profile=\(encrypted ? "encrypted" : "public") parents=64 saveNS=\(elapsed) parentChecks=\(checks) ancestors=0")
    let selection = await store.selection; try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: StorageWork())
    let counts = try await reopened.lane.perform { try #require($0.work) }
    #expect(counts.stages.values.reduce(0) { $0 + $1.retainedLeafChecks } == 1)
    try await reopened.quiesce()
}
