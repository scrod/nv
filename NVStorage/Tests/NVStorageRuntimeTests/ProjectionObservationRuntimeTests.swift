import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
@testable import NVStorageRuntime

private func projectionAssociation(_ store: LocalStoreSession) async throws {
    let selection = await store.selection
    let value = try LocalAssociationV1(id: LocalAssociationID(bytes: Array(repeating: 13, count: 16)),
        scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
        bookmark: .init(codec: 1, bytes: [1,2,3]))
    try await store.saveLocalAssociation(value, basedOn: store.localAssociation())
}
private func prepareProjection(_ store: LocalStoreSession, birth: NoteBirth, name: String = "Note.txt") async throws -> PreparedProjectionIntent {
    try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array(name.utf8))),
        basedOn: store.snapshot(), observations: store.projectionObservations(for: birth))
}
private func projectionKey(_ birth: NoteBirth) -> [UInt8] {
    Array(("projection/" + birth.bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()).utf8)
}

private func encodedProjection(_ store: LocalStoreSession, _ birth: NoteBirth, _ name: String) async throws -> PreparedProjectionIntent {
    try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array(name.utf8))),
        basedOn: store.snapshot(), observations: store.projectionObservations(for: birth), requestedEncoding: .init(rawValue: 10))
}

private func projectionChunks(_ store: LocalStoreSession) async throws -> [[SQLValue]] {
    try await store.lane.perform { try $0.rows("SELECT group_key,generation,codec,payload FROM private_groups WHERE group_key>=? AND group_key<? ORDER BY group_key",
        [.blob(Array("projection-data/".utf8)), .blob(Array("projection-data0".utf8))]) }
}

@Test func projectionFrozenBytesRemainOwnedAfterLatestReplacement() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let a = try await encodedProjection(store, birth, "A.txt")
    try await store.retainProjectionIntent(a)
    _ = try await store.freezeProjectionIntent(observations: store.projectionObservations(for: birth))
    _ = try await put("B", birth: birth, generation: 1, session: store)
    let b = try await encodedProjection(store, birth, "B.txt")
    try await store.retainProjectionIntent(b)
    let chunks = try await projectionChunks(store)
    #expect(Set(try chunks.map { try $0[3].bytes }) == Set([[255,254,65,0], [255,254,66,0]]))
    #expect(chunks.count == 2)
    #expect(try await store.capturedProjectionBytes(a.output, observations: store.projectionObservations(for: birth)) == [255,254,65,0])
    try await store.quiesce()
}

@Test func projectionFrozenOutputPreservesSourceAcrossNewerIntentAndRestart() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), selection = await store.selection
    let a = try await encodedProjection(store, birth, "A.txt")
    try await store.retainProjectionIntent(a)
    let prior = try #require(await store.projectionObservations(for: birth).value)
    let accepted = try AcceptedProjectionV1(output: a.output, physical: .init(codec: 1, bytes: [17]),
        encoding: nil, tags: nil, created: nil, modified: nil)
    let observed = try ProjectionObservationsV1(profile: .plaintextFiles, scope: prior.scope,
        association: prior.association, birth: birth, accepted: accepted, intended: nil)
    // Seed a historical file observation to test its independent private byte ownership.
    try await store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
        [.blob(observed.encodedV1()), .blob(projectionKey(birth))]) }
    _ = try await put("B", birth: birth, generation: 1, session: store)
    let b = try await encodedProjection(store, birth, "B.txt")
    try await store.retainProjectionIntent(b)
    let held = try await store.freezeProjectionIntent(observations: store.projectionObservations(for: birth))
    #expect(held.value?.frozen?.output == b.output && held.value?.frozen?.source == accepted)
    _ = try await put("C", birth: birth, generation: 2, session: store)
    let c = try await encodedProjection(store, birth, "C.txt")
    try await store.retainProjectionIntent(c)
    _ = try await put("D", birth: birth, generation: 3, session: store)
    let d = try await encodedProjection(store, birth, "D.txt")
    try await store.retainProjectionIntent(d)
    let state = try await store.projectionObservations(for: birth)
    #expect(state.value?.frozen == held.value?.frozen)
    #expect(state.value?.accepted == accepted && state.value?.intended?.output == d.output)
    #expect(state.value?.intended?.source == accepted)
    let chunks = try await projectionChunks(store)
    #expect(Set(try chunks.map { try $0[3].bytes }) == Set([[255,254,65,0], [255,254,66,0], [255,254,68,0]]))
    await #expect(throws: StorageError.wrongContext) { try await store.capturedProjectionBytes(c.output, observations: state) }
    await #expect(throws: StorageError.busy) { try await store.freezeProjectionIntent(observations: state) }
    let deletion = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: birth, generation: 4))])
    _ = try requireReceipt(await store.persist(capture: deletion))
    let copy = try await store.preparePrivateStoreCopy(to: privateTempPath())
    try await copy.close(); try await store.quiesce()
    for selected in [selection, copy.selection] {
        let reopened = try await LocalStoreSession.open(selection: selected, protection: protection)
        let restored = try await reopened.projectionObservations(for: birth)
        #expect(restored.value == state.value)
        #expect(try await projectionChunks(reopened) == chunks)
        #expect(try await reopened.capturedProjectionBytes(b.output, observations: restored) == [255,254,66,0])
        #expect(try await reopened.capturedProjectionBytes(a.output, observations: restored) == [255,254,65,0])
        #expect(try await reopened.snapshot().notes.map(\.value.body.string) == ["untouched"])
        await #expect(throws: StorageError.wrongContext) { try await reopened.freezeProjectionIntent(observations: state) }
        try await reopened.quiesce()
    }
}

@Test func projectionByteReleaseIsAtomicAndNoteScoped() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), other = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    _ = try await put("A", birth: other, generation: 1, session: store)
    let a = try await encodedProjection(store, birth, "One.txt")
    try await store.retainProjectionIntent(a)
    let twin = try await encodedProjection(store, other, "Two.txt")
    try await store.retainProjectionIntent(twin)
    #expect(try await projectionChunks(store).count == 2)
    _ = try await put("B", birth: birth, generation: 1, session: store)
    let b = try await encodedProjection(store, birth, "New.txt"), original = try await store.projectionObservations(for: birth)
    let before = try await projectionChunks(store)
    try await store.lane.perform { try $0.exec("CREATE TEMP TRIGGER release_fail BEFORE DELETE ON private_groups BEGIN SELECT RAISE(ABORT,'chunk release failure'); END") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) { try await store.retainProjectionIntent(b) }
        #expect(try await projectionChunks(store) == before)
        #expect(try await store.projectionObservations(for: birth).generation == original.generation)
        #expect(try await store.capturedProjectionBytes(a.output, observations: original) == [255,254,65,0])
    }
    try await store.lane.perform { try $0.exec("DROP TRIGGER release_fail") }
    try await store.retainProjectionIntent(b)
    let after = try await projectionChunks(store)
    #expect(after.count == 2)
    #expect(Set(try after.map { try $0[3].bytes }) == Set([[255,254,65,0], [255,254,66,0]]))
    #expect(try await store.capturedProjectionBytes(twin.output, observations: store.projectionObservations(for: other)) == [255,254,65,0])
    #expect(try await store.capturedProjectionBytes(b.output, observations: store.projectionObservations(for: birth)) == [255,254,66,0])
    let same = try await encodedProjection(store, birth, "SameBytes.txt")
    try await store.retainProjectionIntent(same)
    #expect(try await projectionChunks(store) == after)
    try await store.quiesce()
}

@Test func projectionFreezeChecksOwnerAndAtomicFailure() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    await #expect(throws: StorageError.incomplete) { try await store.freezeProjectionIntent(observations: store.projectionObservations(for: birth)) }
    let a = try await encodedProjection(store, birth, "A.txt")
    try await store.retainProjectionIntent(a)
    let before = try await store.projectionObservations(for: birth)
    let other = try await newSession(initial, protection)
    await #expect(throws: StorageError.wrongContext) { try await other.freezeProjectionIntent(observations: before) }
    try await other.quiesce()
    try await store.lane.perform { try $0.exec("CREATE TEMP TRIGGER freeze_fail BEFORE UPDATE ON private_groups BEGIN SELECT RAISE(ABORT,'freeze failure'); END") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) { try await store.freezeProjectionIntent(observations: before) }
        #expect(try await store.projectionObservations(for: birth).value == before.value)
    }
    try await store.lane.perform { try $0.exec("DROP TRIGGER freeze_fail") }
    let held = try await store.freezeProjectionIntent(observations: before)
    #expect(held.generation == before.generation + 1 && held.value?.frozen?.output == a.output)
    #expect(try await store.freezeProjectionIntent(observations: held).generation == held.generation)
    await #expect(throws: StorageError.staleCapture) { try await store.freezeProjectionIntent(observations: before) }
    let changed = try LocalAssociationV1(id: .init(bytes: Array(repeating: 44, count: 16)),
        scope: #require(before.value).scope, bookmark: .init(codec: 1, bytes: []))
    try await store.saveLocalAssociation(changed, basedOn: store.localAssociation())
    await #expect(throws: StorageError.staleCapture) { try await store.freezeProjectionIntent(observations: held) }
    #expect(try await store.projectionObservations(for: birth).value == held.value)
    try await store.quiesce()
}

@Test(arguments: [false, true]) func projectionOutputReadsOwnedHistoricalBytes(_ native: Bool) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), selection = await store.selection
    let prepared = try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array("Old.txt".utf8))),
        basedOn: store.snapshot(), observations: store.projectionObservations(for: birth),
        requestedEncoding: native ? .init(rawValue: 10) : .utf8)
    try await store.retainProjectionIntent(prepared)
    let expected: [UInt8] = native ? [0xff, 0xfe, 0x41, 0] : [0x41]
    #expect(try await store.projectionBytes(for: prepared.output, observations: store.projectionObservations(for: birth), basedOn: store.snapshot()) == expected)
    let deletion = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: birth, generation: 1))])
    _ = try requireReceipt(await store.persist(capture: deletion))
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let owned = try await reopened.projectionObservations(for: birth), snapshot = try await reopened.snapshot()
    #expect(snapshot.notes.map(\.value.body.string) == ["untouched"])
    #expect(try await reopened.projectionBytes(for: prepared.output, observations: owned, basedOn: snapshot) == expected)
    let other = try await newSession(initial, protection)
    await #expect(throws: StorageError.wrongContext) { try await other.projectionBytes(for: prepared.output, observations: owned, basedOn: other.snapshot()) }
    try await other.quiesce(); try await reopened.quiesce()
}

@Test func projectionOutputChecksUTF8DigestAndPrivateOwner() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), prepared = try await prepareProjection(store, birth: birth)
    try await store.retainProjectionIntent(prepared)
    let original = try await store.projectionObservations(for: birth), value = try #require(original.value)
    #expect(try await store.projectionBytes(for: prepared.output, observations: original, basedOn: store.snapshot()) == [0x41])
    let wrong = try ProjectionBindingV1(profile: .plaintextFiles, collection: prepared.output.binding.collection, birth: birth,
        descriptor: .init(profile: .plaintextFiles, filename: prepared.output.binding.descriptor.filename,
            format: .plaintext, digest: .compute([0x42])), state: prepared.output.binding.state)
    let output = try ProjectionOutputV1(generation: prepared.output.generation, encoding: .utf8, binding: wrong)
    await #expect(throws: StorageError.wrongContext) { try await store.projectionBytes(for: output, observations: original, basedOn: store.snapshot()) }
    let damaged = try ProjectionObservationsV1(profile: .plaintextFiles, scope: value.scope, association: value.association,
        birth: birth, accepted: nil, intended: .init(output: output, source: nil))
    try await store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
        [.blob(damaged.encodedV1()), .blob(projectionKey(birth))]) }
    await #expect(throws: StorageError.staleCapture) { try await store.projectionBytes(for: prepared.output, observations: original, basedOn: store.snapshot()) }
    await #expect(throws: StorageError.integrity) { try await store.projectionBytes(for: output, observations: store.projectionObservations(for: birth), basedOn: store.snapshot()) }
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await store.quiesce()
}

@Test(.timeLimit(.minutes(1))) func projectionOutputFencesConcurrentPrivateIntent() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), first = try await prepareProjection(store, birth: birth)
    try await store.retainProjectionIntent(first)
    let owned = try await store.projectionObservations(for: birth), snapshot = try await store.snapshot()
    #expect(try await store.projectionBytes(for: first.output, observations: owned, basedOn: snapshot) == [0x41])
    let next = try await prepareProjection(store, birth: birth, name: "Newer.txt"), gate = ImprovementGate()
    try await store.lane.perform { $0.work = StorageWork(); $0.work?.querySelected = { await gate.hold() } }
    let reading = Task { try await store.projectionBytes(for: first.output, observations: owned, basedOn: snapshot) }
    await gate.wait()
    try await store.retainProjectionIntent(next)
    await gate.release()
    await #expect(throws: StorageError.staleCapture) { try await reading.value }
    #expect(try await store.projectionObservations(for: birth).value?.intended?.output == next.output)
    #expect(try await store.snapshot().through == snapshot.through)
    try await store.quiesce()
}

@Test func projectionIntentRetainsSelectedFilename() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), snapshot = try await store.snapshot()
    let current = try #require(snapshot.notes.first { $0.birth == birth })
    let selection = await store.selection
    let names = try ProjectionFilenameV1(extensions: .init(extensions: [.init(bytes: Array("txt".utf8))], chosen: 0),
        current: nil, otherNotes: [], occupied: [.init(bytes: Array("title.txt".utf8))])
    let filename = try names.filename(for: current.value.title)
    #expect(filename.spelling.string == "Title.1.txt")
    let prepared = try await store.prepareProjectionIntent(for: birth, filename: filename,
        basedOn: snapshot, observations: store.projectionObservations(for: birth))
    try await store.retainProjectionIntent(prepared)
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let stored = try #require(await reopened.projectionObservations(for: birth).value?.intended?.output.binding)
    #expect(stored.descriptor.filename.spelling.string == "Title.1.txt")
    #expect(stored.descriptor.digest == .compute(Array("A".utf8)))
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await reopened.quiesce()
}

@Test func projectionIntentPreservesAcceptedAcrossFailureAndReopen() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), selection = await store.selection
    let first = try await prepareProjection(store, birth: birth)
    #expect(first.output.binding.descriptor.digest == .compute(Array("A".utf8)))
    let physical = try PassivePlatformRecordV1(codec: 1, bytes: [9]), emptyTags = try PassivePlatformRecordV1(codec: 1, bytes: [])
    let accepted = try AcceptedProjectionV1(output: first.output, physical: physical, encoding: nil, tags: emptyTags, created: nil, modified: nil)
    let association = try #require(await store.localAssociation().value)
    let observed = try ProjectionObservationsV1(profile: .plaintextFiles, scope: association.scope, association: association.id,
        birth: birth, accepted: accepted, intended: nil)
    // Seed a passive earlier observation; physical receipt issuance belongs to the rooted adapter tests.
    try await store.lane.perform { try $0.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(projectionKey(birth)), .blob(observed.encodedV1())]) }
    let baseline = try await store.lane.perform { try $0.rows("SELECT * FROM private_groups WHERE group_key=?", [.blob(projectionKey(birth))]) }
    _ = try await put("new B", birth: birth, generation: 1, session: store)
    let next = try await prepareProjection(store, birth: birth, name: "Renamed.txt")
    try await store.lane.perform { try $0.exec("CREATE TEMP TRIGGER projection_fail BEFORE UPDATE ON private_groups BEGIN SELECT RAISE(ABORT,'private write failure'); END") }
    await #expect(throws: (any Error).self) { try await store.retainProjectionIntent(next) }
    #expect(try await store.lane.perform { try $0.rows("SELECT * FROM private_groups WHERE group_key=?", [.blob(projectionKey(birth))]) } == baseline)
    try await store.lane.perform { try $0.exec("DROP TRIGGER projection_fail") }
    try await store.retainProjectionIntent(next)
    let b = try #require(await store.projectionObservations(for: birth).value)
    #expect(b.accepted == accepted && b.intended?.source == accepted)
    #expect(b.intended?.output.generation == 2 && b.intended?.output.binding.descriptor.filename.spelling.string == "Renamed.txt")
    let sameView = try await prepareProjection(store, birth: birth, name: "Newest.txt")
    try await store.retainProjectionIntent(sameView)
    await #expect(throws: StorageError.staleCapture) { try await store.retainProjectionIntent(next) }
    let latest = try await store.projectionObservations(for: birth)
    #expect(latest.value?.accepted == accepted && latest.value?.intended?.output.generation == 3)
    let copied = try await store.preparePrivateStoreCopy(to: privateTempPath())
    try await copied.close()
    let sibling = try await LocalStoreSession.open(selection: copied.selection, protection: protection)
    #expect(try await sibling.projectionObservations(for: birth).value == latest.value)
    try await sibling.retainProjectionIntent(prepareProjection(sibling, birth: birth))
    #expect(try await sibling.projectionObservations(for: birth).value?.accepted == accepted)
    try await sibling.quiesce()
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.projectionObservations(for: birth).value == latest.value)
    await #expect(throws: StorageError.wrongContext) { try await reopened.retainProjectionIntent(sameView) }
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["new B", "untouched"])
    try await reopened.quiesce()
}

@Test(arguments: ["view", "association", "store", "encrypted"])
func projectionIntentRejectsIncompatibleContext(_ change: String) async throws {
    let (initial, protection) = try testInitial(change == "encrypted"), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    if change == "encrypted" {
        await #expect(throws: StorageError.unsupported) { try await prepareProjection(store, birth: birth) }
    } else {
        let prepared = try await prepareProjection(store, birth: birth)
        if change == "view" {
            _ = try await put("later", birth: birth, generation: 1, session: store)
            await #expect(throws: StorageError.staleCapture, "Changed current view fences the private write") { try await store.retainProjectionIntent(prepared) }
        } else if change == "association" {
            try await projectionAssociation(store)
            await #expect(throws: StorageError.staleCapture) { try await store.retainProjectionIntent(prepared) }
        } else {
            let other = try await newSession(initial, protection)
            await #expect(throws: StorageError.wrongContext) { try await other.retainProjectionIntent(prepared) }
            try await other.quiesce()
        }
    }
    #expect(try await store.projectionObservations(for: birth).value == nil)
    try await store.quiesce()
}

@Test(arguments: ["ordinary", "equal", "merged", "automatic"])
func projectionIntentChecksRealRetainedVariants(_ variant: String) async throws {
    let (initial, protection) = try testInitial(false), left = try await newSession(initial, protection)
    try await projectionAssociation(left)
    let right = try await newSession(initial, protection), birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    if variant != "ordinary" {
        let base = try await put("a\ngap\nz", birth: birth, generation: 1, session: left)
        _ = try await right.receive(left.retainedObject(at: base.object))
        if variant == "automatic" {
            let deletion = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .deleteBatch, changes: [.delete(.init(birth: birth, generation: 2))])
            _ = try requireReceipt(await left.persist(capture: deletion))
        } else { _ = try await put("A\ngap\nz", birth: birth, generation: 2, session: left) }
        let remote = try await put(variant == "equal" ? "A\ngap\nz" : "a\ngap\nZ", birth: birth, generation: 1, session: right)
        _ = try await left.receive(right.retainedObject(at: remote.object))
    }
    let current = try #require(await left.snapshot().notes.first { variant == "automatic" ? $0.automatic != nil : $0.birth == birth })
    let expected = variant == "ordinary" ? "A" : variant == "equal" ? "A\ngap\nz" : variant == "merged" ? "A\ngap\nZ" : "a\ngap\nZ"
    #expect(current.value.body.string == expected)
    try await left.lane.perform { $0.work = StorageWork() }
    let prepared = try await prepareProjection(left, birth: current.birth)
    #expect(prepared.output.binding.descriptor.digest == .compute(Array(expected.utf8)))
    let count = try await left.lane.perform { $0.work!.stages.values.reduce(0) { $0 + $1.envelopeDecodes } }
    #expect(count == prepared.output.binding.dependencies.entries.count)
    try await left.retainProjectionIntent(prepared)
    #expect(try await left.projectionObservations(for: current.birth).value?.intended?.output == prepared.output)
    try await left.quiesce(); try await right.quiesce()
}

@Test(arguments: ["occurrence", "member", "bytes", "codec", "private"])
func projectionObservationsClassifyDamage(_ defect: String) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), selection = await store.selection
    let prepared = try await prepareProjection(store, birth: birth)
    try await store.retainProjectionIntent(prepared)
    let ref = try #require(prepared.output.binding.occurrences.first)
    try await store.lane.perform { db in
        try db.exec("PRAGMA foreign_keys=OFF")
        switch defect {
        case "occurrence": try db.run("DELETE FROM operation_occurrences WHERE object_id=? AND record_index=?", [.blob(ref.locator.segmentID.bytes), .integer(Int64(ref.index.rawValue))])
        case "member": try db.run("DELETE FROM action_members")
        case "bytes":
            try db.exec("DROP TRIGGER objects_no_update")
            try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(ref.locator.segmentID.bytes)])
        case "codec": try db.run("UPDATE private_groups SET codec=99 WHERE group_key=?", [.blob(projectionKey(birth))])
        default: try db.run("UPDATE private_groups SET payload=? WHERE group_key=?", [.blob([0]), .blob(projectionKey(birth))])
        }
        try db.exec("PRAGMA foreign_keys=ON")
    }
    if ["occurrence", "member", "bytes"].contains(defect) {
        await #expect(throws: (any Error).self) { try await prepareProjection(store, birth: birth) }
        await #expect(throws: StorageError.integrity) { try await store.snapshot() }
    }
    await store.lane.close()
    let failure: StorageError = defect == "codec" ? .unsupported : .integrity
    await #expect(throws: failure) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}

@Test(arguments: [false, true])
func projectionObservationsRepairUnionPreservesOrRefuses(conflicting: Bool) async throws {
    let (initial, protection) = try testInitial(false)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    try await projectionAssociation(left); try await projectionAssociation(right)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let encoded = try await right.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array("Right.txt".utf8))),
        basedOn: right.snapshot(), observations: right.projectionObservations(for: birth), requestedEncoding: .init(rawValue: 10))
    try await right.retainProjectionIntent(encoded)
    if conflicting { try await left.retainProjectionIntent(prepareProjection(left, birth: birth, name: "Left.txt")) }
    let expected = try await right.projectionObservations(for: birth).value
    let first = try await left.preserveForRepair(to: privateTempPath()), second = try await right.preserveForRepair(to: privateTempPath())
    for reversed in [false, true] {
        let primary = reversed ? second : first, complement = reversed ? first : second
        if conflicting {
            await #expect(throws: StorageError.incomplete) {
                try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: primary,
                    complementary: [complement], protection: protection)
            }
        } else {
            let replacement = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: primary,
                complementary: [complement], protection: protection)
            try await replacement.close()
            let opened = try await LocalStoreSession.open(selection: replacement.selection, protection: protection)
            #expect(try await opened.projectionObservations(for: birth).value == expected)
            #expect(try await opened.capturedProjectionBytes(encoded.output, observations: opened.projectionObservations(for: birth)) == [255,254,65,0])
            try await opened.quiesce()
        }
    }
}

@Test(arguments: ["utf16", "macroman", "fallback", "empty"])
func projectionEncodedOutputSurvivesReopen(_ mode: String) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), selection = await store.selection
    let body = mode == "utf16" ? "e\u{301}\r\n😀\0" : mode == "macroman" ? "é" : mode == "empty" ? "" : "日本😀"
    let id: UInt64 = mode == "utf16" ? 10 : mode == "macroman" ? 30 : 1
    let expected: [UInt8] = mode == "utf16" ? [255,254,101,0,1,3,13,0,10,0,61,216,0,222,0,0]
        : mode == "macroman" ? [142] : mode == "empty" ? [] : Array(body.utf8)
    _ = try await put(body, birth: birth, generation: 1, session: store)
    let prepared = try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array("Encoded.txt".utf8))),
        basedOn: store.snapshot(), observations: store.projectionObservations(for: birth), requestedEncoding: .init(rawValue: id))
    #expect(prepared.bytes == expected)
    #expect(prepared.output.binding.descriptor.digest == .compute(expected))
    try await store.retainProjectionIntent(prepared)
    let copied = try await store.preparePrivateStoreCopy(to: privateTempPath())
    try await copied.close(); try await store.quiesce()
    for selected in [selection, copied.selection] {
        let reopened = try await LocalStoreSession.open(selection: selected, protection: protection)
        let state = try await reopened.projectionObservations(for: birth)
        #expect(state.value?.intended?.output == prepared.output)
        if mode == "fallback" {
            #expect(prepared.output.encoding == .utf8)
            #expect(try await reopened.lane.perform { try $0.rows("SELECT 1 FROM private_groups WHERE group_key>=? AND group_key<?", [.blob(Array("projection-data/".utf8)), .blob(Array("projection-data0".utf8))]) }.isEmpty)
        } else {
            #expect(try await reopened.capturedProjectionBytes(prepared.output, observations: state) == expected)
        }
        #expect(try await reopened.snapshot().notes.first { $0.birth == birth }?.value.body.bytes == Array(body.utf8))
        try await reopened.quiesce()
    }
}

@Test func projectionEncodedChunksCommitWithTheirOwner() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), body = String(repeating: "A", count: 600_000)
    _ = try await put(body, birth: birth, generation: 1, session: store)
    let prepared = try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array("Large.txt".utf8))),
        basedOn: store.snapshot(), observations: store.projectionObservations(for: birth), requestedEncoding: .init(rawValue: 10))
    let expected: [UInt8] = [255,254] + (0..<600_000).flatMap { _ -> [UInt8] in [65,0] }
    #expect(prepared.bytes == expected)
    let selection = await store.selection
    try await store.lane.perform { db in
        try db.exec("CREATE TEMP TRIGGER output_fail BEFORE INSERT ON private_groups WHEN NEW.group_key=X'\(projectionKey(birth).map { String(format: "%02x", $0) }.joined())' BEGIN SELECT RAISE(ABORT,'owner failure after chunks'); END")
    }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) { try await store.retainProjectionIntent(prepared) }
        #expect(try await store.projectionObservations(for: birth).value == nil)
        #expect(try await store.lane.perform { try $0.rows("SELECT 1 FROM private_groups WHERE group_key>=? AND group_key<?", [.blob(Array("projection-data/".utf8)), .blob(Array("projection-data0".utf8))]) }.isEmpty)
    }
    try await store.lane.perform { try $0.exec("DROP TRIGGER output_fail") }
    try await store.retainProjectionIntent(prepared)
    let sizes = try await store.lane.perform { try $0.rows("SELECT length(payload) FROM private_groups WHERE group_key>=? AND group_key<? ORDER BY group_key", [.blob(Array("projection-data/".utf8)), .blob(Array("projection-data0".utf8))]) }
    #expect(sizes == [[.integer(1_048_576)], [.integer(151_426)]])
    let old = try await store.projectionObservations(for: birth)
    let next = try await prepareProjection(store, birth: birth)
    try await store.retainProjectionIntent(next)
    await #expect(throws: StorageError.staleCapture) { try await store.capturedProjectionBytes(prepared.output, observations: old) }
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.projectionObservations(for: birth).value?.intended?.output == next.output)
    try await reopened.quiesce()
}

@Test(arguments: ["missing", "changed", "codec", "wrong-store"])
func projectionEncodedBytesRejectDamagedOrForeignInputs(_ defect: String) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), selection = await store.selection
    let prepared = try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array("Bytes.txt".utf8))),
        basedOn: store.snapshot(), observations: store.projectionObservations(for: birth), requestedEncoding: .init(rawValue: 10))
    try await store.retainProjectionIntent(prepared)
    let state = try await store.projectionObservations(for: birth)
    #expect(try await store.capturedProjectionBytes(prepared.output, observations: state) == [255,254,65,0])
    if defect == "wrong-store" {
        let other = try await newSession(initial, protection)
        await #expect(throws: StorageError.wrongContext) { try await other.capturedProjectionBytes(prepared.output, observations: state) }
        try await other.quiesce(); try await store.quiesce(); return
    }
    try await store.lane.perform { db in
        let key = try #require(db.rows("SELECT group_key FROM private_groups WHERE group_key>=? AND group_key<?", [.blob(Array("projection-data/".utf8)), .blob(Array("projection-data0".utf8))]).first?.first)
        if defect == "missing" { try db.run("DELETE FROM private_groups WHERE group_key=?", [key]) }
        else if defect == "codec" { try db.run("UPDATE private_groups SET codec=99 WHERE group_key=?", [key]) }
        else { try db.run("UPDATE private_groups SET payload=? WHERE group_key=?", [.blob([255,254,66,0]), key]) }
    }
    await store.lane.close()
    if defect == "changed" {
        let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
        await #expect(throws: StorageError.integrity) { try await reopened.capturedProjectionBytes(prepared.output, observations: reopened.projectionObservations(for: birth)) }
        await #expect(throws: StorageError.wrongContext) { try await reopened.capturedProjectionBytes(prepared.output, observations: state) }
        try await reopened.quiesce()
    } else {
        await #expect(throws: defect == "codec" ? StorageError.unsupported : .integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    }
}

@Test(arguments: [524_286, 524_287, 524_288])
func projectionEncodedChunkBoundaries(_ characters: Int) async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put(String(repeating: "A", count: characters), birth: birth, generation: 1, session: store)
    let prepared = try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array("Boundary.txt".utf8))),
        basedOn: store.snapshot(), observations: store.projectionObservations(for: birth), requestedEncoding: .init(rawValue: 10))
    try await store.retainProjectionIntent(prepared)
    let sizes = try await store.lane.perform { try $0.rows("SELECT length(payload) FROM private_groups WHERE group_key>=? AND group_key<? ORDER BY group_key", [.blob(Array("projection-data/".utf8)), .blob(Array("projection-data0".utf8))]) }
    let expected: [[SQLValue]] = characters == 524_286 ? [[.integer(1_048_574)]]
        : characters == 524_287 ? [[.integer(1_048_576)]] : [[.integer(1_048_576)], [.integer(2)]]
    #expect(sizes == expected)
    let bytes = try await store.capturedProjectionBytes(prepared.output, observations: store.projectionObservations(for: birth))
    #expect(bytes.count == 2 + 2 * characters && Array(bytes.prefix(2)) == [255,254])
    #expect(stride(from: 2, to: bytes.count, by: 2).allSatisfy { bytes[$0] == 65 && bytes[$0+1] == 0 })
    try await store.quiesce()
}

@Test func projectionEncodedReadFencesConcurrentIntent() async throws {
    let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
    try await projectionAssociation(store)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let prepared = try await store.prepareProjectionIntent(for: birth, filename: .init(ExactUTF8(bytes: Array("Before.txt".utf8))),
        basedOn: store.snapshot(), observations: store.projectionObservations(for: birth), requestedEncoding: .init(rawValue: 10))
    try await store.retainProjectionIntent(prepared)
    let state = try await store.freezeProjectionIntent(observations: store.projectionObservations(for: birth)), gate = ImprovementGate()
    #expect(try await store.capturedProjectionBytes(prepared.output, observations: state) == [255,254,65,0])
    try await store.lane.perform { $0.work = StorageWork(); $0.work?.querySelected = { await gate.hold() } }
    let reading = Task { try await store.capturedProjectionBytes(prepared.output, observations: state) }
    await gate.wait()
    try await store.retainProjectionIntent(prepareProjection(store, birth: birth, name: "Later.txt"))
    await gate.release()
    await #expect(throws: StorageError.staleCapture) { try await reading.value }
    #expect(try await store.projectionObservations(for: birth).value?.intended?.output.binding.descriptor.filename.spelling.string == "Later.txt")
    try await store.quiesce()
}
