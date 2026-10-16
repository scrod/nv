import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
@testable import NVStorageRuntime

private func transportBinding(_ cell: CurrentNoteCellV1, collection: CollectionID) throws -> ProjectionBindingV1 {
    let state: ProjectionStateReferenceV1
    switch cell.provenance {
    case .revision: state = .revision(cell.revision)
    case .derived(let derived): state = .derived(derived)
    case .automatic(let source): state = .automatic(source)
    }
    return try .init(profile: .plaintextFiles, collection: collection, birth: cell.birth,
        descriptor: .init(profile: .plaintextFiles, filename: .init(ExactUTF8(bytes: Array("Title.txt".utf8))),
            format: .plaintext, digest: .compute(cell.value.body.bytes)), state: state)
}

private func transportEnvelope(_ binding: ProjectionBindingV1, collection: CollectionID, protection: ObjectProtectionV1) throws -> (SegmentLocator, [UInt8]) {
    let payload = try ChangesPayloadV1(dependencies: binding.dependencies, operations: [], actions: [], projections: [binding])
    let bytes = try ObjectEnvelopeV1.seal(payload: payload.encodedV1(), kind: .changes, collection: collection,
        writer: WriterEpoch(bytes: Array(repeating: 82, count: 16)), sequence: 1, protection: protection)
    return try (ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator, bytes)
}

@Test func projectionDescriptionsReadExactAcceptedEnvelope() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let before = try await store.snapshot(), cell = try #require(before.notes.first)
    let binding = try transportBinding(cell, collection: initial.descriptor.collection)
    let (locator, bytes) = try transportEnvelope(binding, collection: binding.collection, protection: protection)
    #expect(try await store.projectionDescriptions(in: locator, basedOn: before) == nil)
    _ = try await store.receive(bytes)
    let snapshot = try await store.snapshot()
    #expect(try await store.projectionDescriptions(in: locator, basedOn: snapshot) == [binding])
    let wrong = SegmentLocator(writerEpoch: locator.writerEpoch, sequence: locator.sequence + 1, segmentID: locator.segmentID)
    await #expect(throws: StorageError.wrongContext) { try await store.projectionDescriptions(in: wrong, basedOn: snapshot) }
    await #expect(throws: StorageError.staleCapture) { try await store.projectionDescriptions(in: locator, basedOn: before) }
    #expect(try await store.projectionDescriptions(in: cell.revision.locator, basedOn: snapshot) == [])
    #expect(try await store.projectionObservations(for: cell.birth).value == nil)
    guard case .checked(let checked) = try await store.projectionHistory(for: binding, basedOn: snapshot) else { Issue.record("accepted binding source"); return }
    #expect(try await store.projectionValue(fromBinding: checked, basedOn: snapshot) == cell.value)
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.projectionDescriptions(in: locator, basedOn: reopened.snapshot()) == [binding])
    #expect(try await reopened.retainedObject(at: locator) == bytes)
    #expect(try await reopened.snapshot().notes == snapshot.notes)
    try await reopened.quiesce()
}

@Test(arguments: ["ordinary", "equal", "merged", "automatic"])
func projectionTransportAcceptsHistoryWithoutEditingNotes(_ variant: String) async throws {
    let (initial, protection) = try testInitial(false), source = try await newSession(initial, protection)
    let branch = try await newSession(initial, protection), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    var deliveries: [[UInt8]] = []
    if variant != "ordinary" {
        let base = try await put("a\ngap\nz", birth: birth, generation: 1, session: source)
        let bytes = try await source.retainedObject(at: base.object); deliveries.append(bytes)
        _ = try await branch.receive(bytes)
        let first: AcceptedHistoryReceipt
        if variant == "automatic" {
            first = try await requireReceipt(source.persist(capture: CapturedActionGroup(snapshot: source.snapshot(), kind: .deleteBatch,
                changes: [.delete(.init(birth: birth, generation: 2))])))
        } else { first = try await put("A\ngap\nz", birth: birth, generation: 2, session: source) }
        deliveries.append(try await source.retainedObject(at: first.object))
        let other = try await put(variant == "equal" ? "A\ngap\nz" : "a\ngap\nZ", birth: birth, generation: 1, session: branch)
        let otherBytes = try await branch.retainedObject(at: other.object); deliveries.append(otherBytes)
        _ = try await source.receive(otherBytes)
    }
    let sourceView = try await source.snapshot()
    let cell = try #require(sourceView.notes.first { variant == "automatic" ? $0.automatic != nil : $0.birth == birth })
    let binding = try transportBinding(cell, collection: initial.descriptor.collection)
    let (locator, bytes) = try transportEnvelope(binding, collection: initial.descriptor.collection, protection: protection)
    var receiver = try await newSession(initial, protection)
    for bytes in deliveries.reversed() { _ = try await receiver.receive(bytes) }
    let before = try await receiver.snapshot()
    let counts = try await receiver.lane.perform { try ($0.rows("SELECT * FROM operations"), $0.rows("SELECT * FROM actions")) }
    guard case .accepted(let sequence) = try await receiver.receive(bytes) else { Issue.record("complete portable source must accept"); return }
    #expect(sequence == before.through + 1)
    #expect(try await receiver.snapshot().notes == before.notes)
    let expected = variant == "ordinary" ? "A" : variant == "equal" ? "A\ngap\nz" : variant == "merged" ? "A\ngap\nZ" : "a\ngap\nZ"
    #expect(cell.value.body.string == expected)
    #expect(try await receiver.lane.perform { try ($0.rows("SELECT * FROM operations") == counts.0 && $0.rows("SELECT * FROM actions") == counts.1) })
    let evidence = try await receiver.lane.perform { db in
        (try db.rows("SELECT prerequisite FROM accepted_dependencies WHERE child=? ORDER BY prerequisite", [.blob(locator.segmentID.bytes)]),
         try db.rows("SELECT object_id FROM retained_frontier WHERE object_id=?", [.blob(locator.segmentID.bytes)]),
         try db.rows("SELECT group_key FROM private_groups WHERE group_key>=? AND group_key<?", [.blob(Array("projection/".utf8)), .blob(Array("projection0".utf8))]))
    }
    let expectedDependencies = binding.dependencies.entries.map { $0.segmentID.bytes }.sorted { $0.lexicographicallyPrecedes($1) }
    #expect(evidence.0 == expectedDependencies.map { [.blob($0)] })
    #expect(evidence.1 == [[.blob(locator.segmentID.bytes)]] && evidence.2.isEmpty)
    guard case .accepted(let duplicate) = try await receiver.receive(bytes) else { Issue.record("exact retry must accept"); return }
    #expect(duplicate == sequence)
    let selection = await receiver.selection
    try await receiver.quiesce(); receiver = try await .open(selection: selection, protection: protection)
    #expect(try await receiver.retainedObject(at: locator) == bytes)
    #expect(try await receiver.snapshot().notes == before.notes)
    #expect(try await receiver.rebuildCurrentRows().notes == before.notes)
    #expect(try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes, collection: binding.collection, protection: protection)).projections == [binding])
    try await receiver.quiesce(); try await source.quiesce(); try await branch.quiesce()
}

@Test(arguments: ["identity", "index", "foreign", "encrypted"])
func projectionTransportRejectsClaimsBeforeAcceptance(_ defect: String) async throws {
    let (initial, protection) = try testInitial(defect == "encrypted"), store = try await newSession(initial, protection)
    let before = try await store.snapshot(), original = try transportBinding(#require(before.notes.first), collection: initial.descriptor.collection)
    guard case .revision(let ref) = original.state else { Issue.record("ordinary source"); return }
    let claim = try ProjectionBindingV1(profile: .plaintextFiles,
        collection: defect == "foreign" ? CollectionID(bytes: Array(repeating: 90, count: 16)) : original.collection,
        birth: original.birth, descriptor: original.descriptor,
        state: .revision(.init(locator: ref.locator, index: defect == "index" ? OperationIndex(UInt32.max) : ref.index,
            id: defect == "identity" ? OperationID(bytes: Array(repeating: 90, count: 32)) : ref.id)))
    let (locator, bytes) = try transportEnvelope(claim, collection: initial.descriptor.collection, protection: protection)
    await #expect(throws: defect == "foreign" || defect == "encrypted" ? CanonicalEncodingError.wrongScope : .invalidReference) { try await store.receive(bytes) }
    #expect(try await store.snapshot().through == before.through)
    #expect(try await store.snapshot().notes == before.notes)
    #expect(try await store.lane.perform { try $0.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]).isEmpty })
    #expect(try await store.lane.perform { try $0.rows("SELECT encoded FROM objects JOIN rejected_objects USING(object_id) WHERE object_id=?", [.blob(locator.segmentID.bytes)]) } == [[.blob(bytes)]])
    _ = try await put("healthy companion", birth: original.birth, generation: 1, session: store)
    try await store.quiesce()
}

@Test func projectionTransportParkingAndAcceptanceRollbackSurviveReopen() async throws {
    let (initial, protection) = try testInitial(false), source = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("source history", birth: birth, generation: 1, session: source)
    let binding = try await transportBinding(#require(source.snapshot().notes.first { $0.birth == birth }), collection: initial.descriptor.collection)
    let (locator, bytes) = try transportEnvelope(binding, collection: binding.collection, protection: protection)
    var receiver = try await newSession(initial, protection)
    guard case .waiting(let requirements) = try await receiver.receive(bytes) else { Issue.record("missing source parks"); return }
    #expect(requirements == [.acceptedHistory(edit.object)])
    let selection = await receiver.selection
    try await receiver.quiesce(); receiver = try await .open(selection: selection, protection: protection)
    let hex = locator.segmentID.bytes.map { String(format: "%02x", $0) }.joined()
    try await receiver.lane.perform { try $0.exec("CREATE TEMP TRIGGER fail_projection_accept BEFORE INSERT ON accepted_dependencies WHEN NEW.child=X'\(hex)' BEGIN SELECT RAISE(ABORT,'projection qualification'); END") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) { try await receiver.receive(source.retainedObject(at: edit.object)) }
        let state = try await receiver.lane.perform { db in
            (try db.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(locator.segmentID.bytes)]),
             try db.rows("SELECT encoded FROM objects JOIN ready_objects USING(object_id) WHERE object_id=?", [.blob(locator.segmentID.bytes)]),
             try db.rows("SELECT 1 FROM retained_frontier WHERE object_id=?", [.blob(edit.object.segmentID.bytes)]))
        }
        #expect(state.0.isEmpty && state.1 == [[.blob(bytes)]] && state.2 == [[.integer(1)]])
    }
    try await receiver.quiesce(); receiver = try await .open(selection: selection, protection: protection)
    guard case .accepted = try await receiver.receivedObjectStatus(at: locator) else { Issue.record("restart drains exact retained input"); return }
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["source history", "untouched"])
    #expect(try await receiver.retainedObject(at: locator) == bytes)
    try await receiver.quiesce(); try await source.quiesce()
}
