import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
@testable import NVStorageRuntime

private func sourceStamp(_ snapshot: StoreSnapshot, birth: NoteBirth, collection: CollectionID) throws -> ProjectionStampV1 {
    let cell = try #require(snapshot.notes.first { $0.birth == birth })
    let state: ProjectionStateReferenceV1
    switch cell.provenance {
    case .revision: state = .revision(cell.revision)
    case .derived(let derived): state = .derived(derived)
    case .automatic(let source): state = .automatic(source)
    }
    return try .init(profile: .plaintextFiles, collection: collection, birth: birth, format: .plaintext,
        digest: .compute(cell.value.body.bytes), state: state)
}

private func completeBinding(_ stamp: ProjectionStampV1) throws -> ProjectionBindingV1 {
    try .init(profile: .plaintextFiles, collection: stamp.collection, birth: stamp.birth,
        descriptor: .init(profile: .plaintextFiles, filename: .init(ExactUTF8(bytes: Array("Historical.txt".utf8))),
            format: stamp.format, digest: stamp.digest), state: stamp.state)
}

@Test(arguments: ["ordinary", "equal", "merged", "automatic"])
func projectionHistoryValidatesStandaloneAcceptedSources(_ variant: String) async throws {
    let (initial, protection) = try testInitial(false), left = try await newSession(initial, protection)
    let right = try await newSession(initial, protection), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    if variant != "ordinary" {
        let base = try await put("a\ngap\nz", birth: birth, generation: 1, session: left)
        _ = try await right.receive(left.retainedObject(at: base.object))
        if variant == "automatic" {
            let deletion = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .deleteBatch, changes: [.delete(.init(birth: birth, generation: 2))])
            _ = try requireReceipt(await left.persist(capture: deletion))
        } else { _ = try await put("A\ngap\nz", birth: birth, generation: 2, session: left) }
        let edit = try await put(variant == "equal" ? "A\ngap\nz" : "a\ngap\nZ", birth: birth, generation: 1, session: right)
        _ = try await left.receive(right.retainedObject(at: edit.object))
    }
    let snapshot = try await left.snapshot(), collection = initial.descriptor.collection
    let cell = try #require(snapshot.notes.first { variant == "automatic" ? $0.automatic != nil : $0.birth == birth })
    let stamp = try sourceStamp(snapshot, birth: cell.birth, collection: collection)
    try await left.lane.perform { $0.work = StorageWork() }
    guard case .checked(let checked) = try await left.projectionHistory(for: stamp, basedOn: snapshot) else { Issue.record("Complete accepted source must validate"); return }
    let value = try await left.projectionValue(from: checked, basedOn: snapshot)
    let expected = variant == "ordinary" ? "A" : variant == "equal" ? "A\ngap\nz" : variant == "merged" ? "A\ngap\nZ" : "a\ngap\nZ"
    #expect(value.body.string == expected && value == cell.value)
    #expect(checked.currentRelation == .matchesCurrent)
    guard case .checked(let complete) = try await left.projectionHistory(for: completeBinding(stamp), basedOn: snapshot) else {
        Issue.record("Complete binding must use the same source checks"); return
    }
    #expect(try await left.projectionValue(fromBinding: complete, basedOn: snapshot) == value)
    #expect(complete.currentRelation == .matchesCurrent)
    let counts = try await left.lane.perform { $0.work!.stages.values.flatMap { $0.traversalDecodes.values }.flatMap { $0.values } }
    #expect(!counts.isEmpty && counts.allSatisfy { $0 == 1 })
    if case .derived(let derived) = stamp.state {
        let wrong = try DerivedStateReferenceV1(kind: derived.kind, inputs: derived.inputReferences,
            result: NoteValueDigest(bytes: Array(repeating: 92, count: 32)), earlierOperations: [])
        let forged = try ProjectionStampV1(profile: .plaintextFiles, collection: stamp.collection, birth: stamp.birth,
            format: stamp.format, digest: stamp.digest, state: .derived(wrong))
        guard case .invalidClaim = try await left.projectionHistory(for: forged, basedOn: snapshot) else { Issue.record("invented derived result must fail"); return }
        #expect(try await left.snapshot().notes == snapshot.notes)
    }
    if variant != "automatic" {
        _ = try await put("later unrelated to old claim", birth: birth, generation: 3, session: left)
        let later = try await left.snapshot()
        guard case .checked(let old) = try await left.projectionHistory(for: stamp, basedOn: later) else { Issue.record("Later heads preserve valid historical source"); return }
        #expect(old.currentRelation == .differentCurrent)
        #expect(try await left.projectionValue(from: old, basedOn: later).body.string == expected)
        await #expect(throws: StorageError.staleCapture) { try await left.projectionValue(from: checked, basedOn: later) }
        let deletion = try CapturedActionGroup(snapshot: later, kind: .deleteBatch, changes: [.delete(.init(birth: birth, generation: 4))])
        _ = try requireReceipt(await left.persist(capture: deletion))
        let deleted = try await left.snapshot()
        guard case .checked(let oldDeleted) = try await left.projectionHistory(for: stamp, basedOn: deleted) else { Issue.record("logical deletion preserves history"); return }
        #expect(oldDeleted.currentRelation == .absent)
        #expect(try await left.projectionValue(from: oldDeleted, basedOn: deleted).body.string == expected)
    }
    try await left.quiesce(); try await right.quiesce()
}

@Test(arguments: ["foreign", "birth", "locator", "index", "identity"])
func projectionHistoryRejectsClaimsWithoutPoisoningRetainedHistory(_ defect: String) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let snapshot = try await store.snapshot(), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let original = try sourceStamp(snapshot, birth: birth, collection: initial.descriptor.collection)
    guard case .revision(let ref) = original.state else { Issue.record("ordinary companion"); return }
    let locator = defect == "locator" ? SegmentLocator(writerEpoch: ref.locator.writerEpoch, sequence: ref.locator.sequence + 1, segmentID: ref.locator.segmentID) : ref.locator
    let state = try ProjectionStateReferenceV1.revision(.init(locator: locator,
        index: defect == "index" ? OperationIndex(UInt32.max) : ref.index,
        id: defect == "identity" ? OperationID(bytes: Array(repeating: 90, count: 32)) : ref.id))
    let claim = try ProjectionStampV1(profile: .plaintextFiles,
        collection: defect == "foreign" ? CollectionID(bytes: Array(repeating: 80, count: 16)) : original.collection,
        birth: defect == "birth" ? NoteBirth(bytes: Array(repeating: 3, count: 16)) : birth,
        format: .plaintext, digest: original.digest, state: state)
    let result = try await store.projectionHistory(for: claim, basedOn: snapshot)
    let classified: Bool
    switch (defect, result) {
    case ("foreign", .foreignCollection): classified = true
    case (_, .invalidClaim) where defect != "foreign": classified = true
    default: classified = false
    }
    #expect(classified, "Untrusted claim must receive its precise passive classification")
    let complete = try await store.projectionHistory(for: completeBinding(claim), basedOn: snapshot)
    switch (defect, complete) {
    case ("foreign", .foreignCollection): break
    case (_, .invalidClaim) where defect != "foreign": break
    default: Issue.record("Complete binding must retain the precise passive classification")
    }
    guard case .checked(let companion) = try await store.projectionHistory(for: original, basedOn: snapshot) else { Issue.record("valid companion survives rejected claim"); return }
    #expect(try await store.projectionValue(from: companion, basedOn: snapshot).body.string == "A")
    #expect(try await store.snapshot().through == 1)
    #expect(try await store.lane.perform { try $0.rows("SELECT * FROM private_groups WHERE group_key>=? AND group_key<?", [.blob(Array("verification/".utf8)), .blob(Array("verification0".utf8))]).isEmpty })
    try await store.quiesce()
}

@Test func projectionCompleteBindingSupportsWideAcceptedSources() async throws {
    let (initial, protection) = try testInitial(false), receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    var expected: Set<OperationID> = []
    for _ in 0..<48 {
        let writer = try await newSession(initial, protection)
        let edit = try await put("same concurrent text", birth: birth, generation: 1, session: writer)
        let bytes = try await writer.retainedObject(at: edit.object)
        let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection))
        #expect(payload.operations.count == 1)
        expected.insert(try #require(payload.operations.first).operation.id)
        _ = try await receiver.receive(bytes)
        try await writer.quiesce()
    }
    let snapshot = try await receiver.snapshot(), cell = try #require(snapshot.notes.first { $0.birth == birth })
    guard case .derived(let state) = cell.provenance else { Issue.record("All concurrent equal heads must remain represented"); return }
    #expect(Set(state.references.compactMap { if case .external(_, _, let id) = $0 { id } else { nil } }) == expected)
    let binding = try ProjectionBindingV1(profile: .plaintextFiles, collection: initial.descriptor.collection, birth: birth,
        descriptor: .init(profile: .plaintextFiles, filename: .init(ExactUTF8(bytes: Array("Wide.txt".utf8))),
            format: .plaintext, digest: .compute(Array("same concurrent text".utf8))), state: .derived(state))
    #expect(try binding.encodedV1().count > 4_096)
    guard case .omittedOversized = try ProjectionStampV1.prepare(profile: .plaintextFiles, collection: binding.collection,
        birth: binding.birth, format: binding.descriptor.format, digest: binding.descriptor.digest, state: binding.state) else {
        Issue.record("The forty-eight-source companion must exercise complete stamp omission"); return
    }
    try await receiver.lane.perform { $0.work = StorageWork() }
    guard case .checked(let checked) = try await receiver.projectionHistory(for: binding, basedOn: snapshot) else {
        Issue.record("The complete description must remain usable when its stamp is omitted"); return
    }
    #expect(try await receiver.projectionValue(fromBinding: checked, basedOn: snapshot).body.string == "same concurrent text")
    #expect(checked.currentRelation == .matchesCurrent && checked.binding == binding)
    let counts = try await receiver.lane.perform { $0.work!.stages.values.flatMap { $0.traversalDecodes.values }.flatMap { $0.values } }
    #expect(counts.count == 49 && counts.allSatisfy { $0 == 1 })
    try await receiver.quiesce()
}

@Test(.timeLimit(.minutes(1))) func projectionCompleteBindingFencesConsumersAndReadCompletion() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), snapshot = try await store.snapshot()
    let binding = try completeBinding(sourceStamp(snapshot, birth: birth, collection: initial.descriptor.collection))
    guard case .checked(let checked) = try await store.projectionHistory(for: binding, basedOn: snapshot) else { Issue.record("valid binding"); return }
    #expect(try await store.projectionValue(fromBinding: checked, basedOn: snapshot).body.string == "A")
    let other = try await newSession(initial, protection)
    await #expect(throws: StorageError.wrongContext) { try await other.projectionValue(fromBinding: checked, basedOn: other.snapshot()) }
    let gate = ImprovementGate()
    try await store.lane.perform { $0.work = StorageWork(); $0.work?.querySelected = { await gate.hold() } }
    let read = Task { try await store.projectionHistory(for: binding, basedOn: snapshot) }
    await gate.wait()
    _ = try await put("newer", birth: birth, generation: 1, session: store)
    await gate.release()
    await #expect(throws: StorageError.staleCapture) { try await read.value }
    await #expect(throws: StorageError.staleCapture) { try await store.projectionValue(fromBinding: checked, basedOn: snapshot) }
    await #expect(throws: StorageError.staleCapture) { try await store.projectionValue(fromBinding: checked, basedOn: store.snapshot()) }
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.projectionValue(fromBinding: checked, basedOn: reopened.snapshot()) }
    guard case .checked(let historical) = try await reopened.projectionHistory(for: binding, basedOn: reopened.snapshot()) else { Issue.record("historical binding after restart"); return }
    #expect(historical.currentRelation == .differentCurrent)
    #expect(try await reopened.projectionValue(fromBinding: historical, basedOn: reopened.snapshot()).body.string == "A")
    try await reopened.quiesce(); try await other.quiesce()
}

@Test func projectionHistoryWaitsForExactAcceptedInputAndRetainsRejectionReason() async throws {
    let (initial, protection) = try testInitial(false), source = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("remote", birth: birth, generation: 1, session: source)
    let stamp = try await sourceStamp(source.snapshot(), birth: birth, collection: initial.descriptor.collection)
    guard case .waiting(let inputs) = try await receiver.projectionHistory(for: stamp, basedOn: receiver.snapshot()) else { Issue.record("missing source must wait"); return }
    #expect(inputs == [edit.object])
    _ = try await receiver.receive(source.retainedObject(at: edit.object))
    guard case .checked(let accepted) = try await receiver.projectionHistory(for: stamp, basedOn: receiver.snapshot()) else { Issue.record("delivered source must validate"); return }
    #expect(try await receiver.projectionValue(from: accepted, basedOn: receiver.snapshot()).body.string == "remote")
    let future = try ObjectEnvelopeV1.seal(payload: Array("NVCHG1\r\n".utf8) + [0, 2], kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 84, count: 16)), sequence: 0, protection: protection)
    let locator = try ObjectEnvelopeV1.open(future, collection: initial.descriptor.collection, protection: protection).locator
    await #expect(throws: CanonicalEncodingError.unsupportedFormat) { try await receiver.receive(future) }
    let blocked = try ProjectionStampV1(profile: .plaintextFiles, collection: stamp.collection, birth: stamp.birth,
        format: stamp.format, digest: stamp.digest,
        state: .revision(.init(locator: locator, index: OperationIndex(0), id: OperationID(bytes: Array(repeating: 91, count: 32)))))
    let selection = await receiver.selection
    for round in 0..<2 {
        guard case .blocked(let reasons, let missing) = try await receiver.projectionHistory(for: blocked, basedOn: receiver.snapshot()) else { Issue.record("unsupported prerequisite keeps its reason"); return }
        #expect(missing == [locator] && reasons.count == 1)
        #expect(reasons.first?.object == locator.segmentID && reasons.first?.reason == .unsupportedFormat)
        #expect(try await receiver.retainedObject(at: edit.object) == source.retainedObject(at: edit.object))
        if round == 0 { try await receiver.quiesce(); receiver = try await LocalStoreSession.open(selection: selection, protection: protection) }
    }
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["remote", "untouched"])
    try await receiver.quiesce(); try await source.quiesce()
}

@Test(.timeLimit(.minutes(1))) func projectionHistoryFencesConcurrentHistoryAndEvidenceConsumers() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let snapshot = try await store.snapshot(), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let stamp = try sourceStamp(snapshot, birth: birth, collection: initial.descriptor.collection)
    guard case .checked(let original) = try await store.projectionHistory(for: stamp, basedOn: snapshot) else { Issue.record("valid source"); return }
    let other = try await newSession(initial, protection)
    await #expect(throws: StorageError.wrongContext) { try await other.projectionValue(from: original, basedOn: other.snapshot()) }
    let gate = ImprovementGate()
    try await store.lane.perform { $0.work = StorageWork(); $0.work?.querySelected = { await gate.hold() } }
    let reading = Task { try await store.projectionHistory(for: stamp, basedOn: snapshot) }
    await gate.wait()
    _ = try await put("newer", birth: birth, generation: 1, session: store)
    await gate.release()
    await #expect(throws: StorageError.staleCapture) { try await reading.value }
    await #expect(throws: StorageError.staleCapture) { try await store.projectionValue(from: original, basedOn: snapshot) }
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.projectionValue(from: original, basedOn: reopened.snapshot()) }
    guard case .checked(let old) = try await reopened.projectionHistory(for: stamp, basedOn: reopened.snapshot()) else { Issue.record("fresh evidence must preserve old contents"); return }
    #expect(try await reopened.projectionValue(from: old, basedOn: reopened.snapshot()).body.string == "A")
    #expect(try await reopened.snapshot().notes.first { $0.birth == birth }?.value.body.string == "newer")
    try await reopened.quiesce(); try await other.quiesce()
}

@Test(arguments: ["bytes", "occurrence", "member", "locator"])
func projectionHistoryDiagnosesActualRetainedDamage(_ damage: String) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let snapshot = try await store.snapshot(), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let stamp = try sourceStamp(snapshot, birth: birth, collection: initial.descriptor.collection)
    guard case .revision(let ref) = stamp.state else { Issue.record("ordinary companion"); return }
    guard case .checked = try await store.projectionHistory(for: stamp, basedOn: snapshot) else { Issue.record("healthy companion"); return }
    try await store.lane.perform { db in
        try db.exec("PRAGMA foreign_keys=OFF")
        if damage == "bytes" || damage == "locator" {
            try db.exec("DROP TRIGGER objects_no_update")
            if damage == "bytes" { try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(ref.locator.segmentID.bytes)]) }
            else { try db.run("UPDATE objects SET writer_epoch=? WHERE object_id=?", [.blob(Array(repeating: 99, count: 16)), .blob(ref.locator.segmentID.bytes)]) }
        } else if damage == "occurrence" {
            try db.run("DELETE FROM operation_occurrences WHERE object_id=? AND record_index=?", [.blob(ref.locator.segmentID.bytes), .integer(Int64(ref.index.rawValue))])
        } else { try db.run("DELETE FROM action_members") }
        try db.exec("PRAGMA foreign_keys=ON")
    }
    if damage == "bytes" {
        await #expect(throws: CanonicalEncodingError.lengthLimit) { try await store.projectionHistory(for: stamp, basedOn: snapshot) }
    } else if damage == "locator" {
        await #expect(throws: CanonicalEncodingError.identityMismatch) { try await store.projectionHistory(for: stamp, basedOn: snapshot) }
    } else {
        await #expect(throws: StorageError.integrity) { try await store.projectionHistory(for: stamp, basedOn: snapshot) }
    }
    await #expect(throws: StorageError.integrity) { try await store.snapshot() }
    await store.lane.close()
}

@Test func projectionHistoryRepackagingPreservesLogicalCurrent() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let saved = try await put("exactly once", birth: birth, generation: 1, session: store)
    let original = try await sourceStamp(store.snapshot(), birth: birth, collection: initial.descriptor.collection)
    guard case .revision(let ref) = original.state else { Issue.record("ordinary source"); return }
    let opened = try await ObjectEnvelopeV1.open(store.retainedObject(at: saved.object), collection: original.collection, protection: protection)
    let repacked = try ObjectEnvelopeV1.seal(payload: opened.payload, kind: .changes, collection: original.collection,
        writer: WriterEpoch(bytes: Array(repeating: 95, count: 16)), sequence: 0, protection: protection)
    let locator = try ObjectEnvelopeV1.open(repacked, collection: original.collection, protection: protection).locator
    _ = try await store.receive(repacked)
    let claim = try ProjectionStampV1(profile: .plaintextFiles, collection: original.collection, birth: birth,
        format: original.format, digest: original.digest, state: .revision(.init(locator: locator, index: ref.index, id: ref.id)))
    let snapshot = try await store.snapshot()
    guard case .checked(let checked) = try await store.projectionHistory(for: claim, basedOn: snapshot) else { Issue.record("accepted equivalent occurrence"); return }
    #expect(checked.currentRelation == .matchesCurrent)
    #expect(try await store.projectionValue(from: checked, basedOn: snapshot).body.string == "exactly once")
    #expect(try await store.lane.perform { try $0.rows("SELECT count(*) FROM operations WHERE operation_id=?", [.blob(ref.id.bytes)]) } == [[.integer(1)]])
    try await store.quiesce()
}

@Test func projectionHistoryEncryptedProfileRejectsPlaintextConsumer() async throws {
    let (initial, protection) = try testInitial(true), store = try await newSession(initial, protection)
    let snapshot = try await store.snapshot(), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let stamp = try sourceStamp(snapshot, birth: birth, collection: initial.descriptor.collection)
    await #expect(throws: StorageError.unsupported) { try await store.projectionHistory(for: stamp, basedOn: snapshot) }
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await store.quiesce()
}
