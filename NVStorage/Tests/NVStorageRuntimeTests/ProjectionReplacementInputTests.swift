import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
@testable import NVStorageRuntime

private struct ReplacementFixture {
    let store: LocalStoreSession
    let protection: ObjectProtectionV1
    let birth: NoteBirth
    let source: AcceptedProjectionV1
    let output: ProjectionOutputV1

    static func make(utf16: Bool = false, name: String = "Note.txt") async throws -> Self {
        let (initial, protection) = try testInitial(false), store = try await newSession(initial, protection)
        let selection = await store.selection, birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
        let association = try LocalAssociationV1(id: .init(bytes: Array(repeating: 13, count: 16)),
            scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
            bookmark: .init(codec: 1, bytes: [1,2,3]))
        try await store.saveLocalAssociation(association, basedOn: store.localAssociation())
        let old = try await intent(store, birth: birth, utf16: utf16, name: "Note.txt")
        let source = try AcceptedProjectionV1(output: old.output, physical: .init(codec: 1, bytes: [17]),
            encoding: nil, tags: nil, created: nil, modified: nil)
        let state = try #require(await store.projectionObservations(for: birth).value)
        let accepted = try ProjectionObservationsV1(profile: .plaintextFiles, scope: state.scope,
            association: state.association, birth: birth, accepted: source, intended: nil)
        // Seed passive prior observations; the input factory still validates both exact history bindings.
        try await store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
            [.blob(accepted.encodedV1()), .blob(key(birth))]) }
        _ = try await put("B", birth: birth, generation: 1, session: store)
        let next = try await intent(store, birth: birth, utf16: utf16, name: name)
        _ = try await store.freezeProjectionIntent(observations: store.projectionObservations(for: birth))
        return Self(store: store, protection: protection, birth: birth, source: source, output: next.output)
    }

    static func key(_ birth: NoteBirth) -> [UInt8] {
        Array(("projection/" + birth.bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()).utf8)
    }

    static func intent(_ store: LocalStoreSession, birth: NoteBirth, utf16: Bool, name: String) async throws -> PreparedProjectionIntent {
        let next = try await store.prepareProjectionIntent(for: birth,
            filename: .init(ExactUTF8(bytes: Array(name.utf8))), basedOn: store.snapshot(),
            observations: store.projectionObservations(for: birth), requestedEncoding: .init(rawValue: utf16 ? 10 : 4))
        try await store.retainProjectionIntent(next)
        return next
    }

    func prepare() async throws -> PreparedProjectionReplacement {
        try await store.prepareProjectionReplacement(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
    }

    func prepareRelocation() async throws -> PreparedProjectionRelocation {
        try await store.prepareProjectionRelocation(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
    }
}

@Test(arguments: [false, true])
func projectionRelocationInputRetainsBothExactGenerations(utf16: Bool) async throws {
    let f = try await ReplacementFixture.make(utf16: utf16, name: "Renamed.txt"), input = try await f.prepareRelocation()
    let old: [UInt8] = utf16 ? [255,254,65,0] : [65], next: [UInt8] = utf16 ? [255,254,66,0] : [66]
    #expect(input.source == f.source && input.output == f.output)
    #expect(input.sourceBytes == old && input.bytes == next && input.value.body.string == "B")
    _ = try await put("C", birth: f.birth, generation: 2, session: f.store)
    _ = try await ReplacementFixture.intent(f.store, birth: f.birth, utf16: utf16, name: "Later.txt")
    try await f.store.checkProjectionRelocation(input)
    let pending = try await f.store.projectionObservations(for: f.birth), selection = await f.store.selection
    #expect(pending.value?.frozen?.output == f.output && pending.value?.intended?.output != f.output)
    try await f.store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionRelocation(input) }
    let recovered = try await reopened.prepareProjectionRelocation(observations: reopened.projectionObservations(for: f.birth), basedOn: reopened.snapshot())
    #expect(recovered.sourceBytes == old && recovered.bytes == next && recovered.attempt != input.attempt)
    #expect(try await reopened.projectionObservations(for: f.birth).value == pending.value)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["C", "untouched"])
    try await reopened.quiesce()
}

@Test func projectionRelocationInputRequiresDifferentNameAndOwner() async throws {
    let same = try await ReplacementFixture.make(), moved = try await ReplacementFixture.make(name: "Renamed.txt")
    let input = try await moved.prepareRelocation()
    await #expect(throws: StorageError.wrongContext, "Relocation requires distinct source and output names") { try await same.prepareRelocation() }
    await #expect(throws: StorageError.wrongContext) { try await moved.prepare() }
    await #expect(throws: StorageError.wrongContext) { try await same.store.checkProjectionRelocation(input) }
    let state = try await moved.store.projectionObservations(for: moved.birth)
    await #expect(throws: StorageError.wrongContext) {
        try await same.store.prepareProjectionRelocation(observations: state, basedOn: same.store.snapshot())
    }
    try await same.store.quiesce(); try await moved.store.quiesce()
}

@Test(arguments: ["delete", "association", "source", "frozen"])
func projectionRelocationInputRejectsChangedApplicability(change: String) async throws {
    let f = try await ReplacementFixture.make(name: "Renamed.txt"), input = try await f.prepareRelocation()
    switch change {
    case "delete":
        let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
            changes: [.delete(.init(birth: f.birth, generation: 2))])
        _ = try requireReceipt(await f.store.persist(capture: deletion))
    case "association":
        let prior = try await f.store.localAssociation(), value = try #require(prior.value)
        let changed = try LocalAssociationV1(id: value.id, scope: value.scope, bookmark: .init(codec: 1, bytes: [9]))
        try await f.store.saveLocalAssociation(changed, basedOn: prior)
    default:
        let prior = try #require(await f.store.projectionObservations(for: f.birth).value)
        let source = try AcceptedProjectionV1(output: f.source.output, physical: .init(codec: 1, bytes: [33]),
            encoding: nil, tags: nil, created: nil, modified: nil)
        let changed = try ProjectionObservationsV1(profile: .plaintextFiles, scope: prior.scope, association: prior.association,
            birth: prior.birth, accepted: change == "source" ? source : prior.accepted,
            intended: prior.intended, frozen: change == "frozen" ? nil : prior.frozen)
        try await f.store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
            [.blob(changed.encodedV1()), .blob(ReplacementFixture.key(f.birth))]) }
    }
    await #expect(throws: StorageError.staleCapture) { try await f.store.checkProjectionRelocation(input) }
    try await f.store.quiesce()
}

@Test(arguments: [false, true], ["occurrence", "bytes"])
func projectionRelocationInputVerifiesSourceHistory(utf16: Bool, damage: String) async throws {
    let f = try await ReplacementFixture.make(utf16: utf16, name: "Renamed.txt")
    #expect(try await f.prepareRelocation().source == f.source)
    let ref = try #require(f.source.output.binding.occurrences.first)
    try await f.store.lane.perform { db in
        if damage == "bytes" {
            try db.exec("DROP TRIGGER objects_no_update")
            try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(ref.locator.segmentID.bytes)])
        } else {
            try db.exec("PRAGMA foreign_keys=OFF")
            try db.run("DELETE FROM operation_occurrences WHERE object_id=? AND record_index=?",
                [.blob(ref.locator.segmentID.bytes), .integer(Int64(ref.index.rawValue))])
            try db.exec("PRAGMA foreign_keys=ON")
        }
    }
    if damage == "bytes" {
        await #expect(throws: CanonicalEncodingError.lengthLimit) { try await f.prepareRelocation() }
    } else {
        await #expect(throws: StorageError.integrity) { try await f.prepareRelocation() }
    }
    await #expect(throws: StorageError.integrity) { try await f.store.snapshot() }
    await f.store.lane.close()
}

@Test func projectionRelocationReservationSurvivesRestartAndNewerWork() async throws {
    let f = try await ReplacementFixture.make(utf16: true, name: "Renamed.txt"), input = try await f.prepareRelocation()
    let root = input.association.bookmark, source = input.source.physical
    let reserved = try await f.store.reserveProjectionRelocation(input, root: root, source: source)
    #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == reserved.record)
    try await f.store.checkProjectionRelocationReservation(reserved)
    #expect(reserved.record.operation == .relocation && reserved.record.transition.output == f.output && reserved.record.transition.source == f.source)
    #expect(reserved.record.root == root && reserved.record.source == source)
    let rows = try await f.store.lane.perform { try $0.rows("SELECT generation,codec,payload FROM private_groups WHERE group_key=?",
        [.blob(Array(("projection-replacement/" + String(repeating: "01", count: 16)).utf8))]) }
    #expect(rows == [[.integer(1), .integer(1), .blob(try reserved.record.encodedV1())]])
    _ = try await put("C", birth: f.birth, generation: 2, session: f.store)
    _ = try await ReplacementFixture.intent(f.store, birth: f.birth, utf16: true, name: "Later.txt")
    try await f.store.checkProjectionRelocationReservation(reserved)
    await #expect(throws: StorageError.busy) { try await f.store.reserveProjectionRelocation(input, root: root, source: source) }
    let recovery = try await f.store.prepareProjectionRelocationRecovery(for: f.birth)
    #expect(recovery.record == reserved.record && recovery.sourceBytes == [255,254,65,0] && recovery.outputBytes == [255,254,66,0])
    await #expect(throws: StorageError.wrongContext) { try await f.store.prepareProjectionReplacementRecovery(for: f.birth) }
    let selection = await f.store.selection, copy = try await f.store.preparePrivateStoreCopy(to: privateTempPath())
    try await copy.close(); try await f.store.quiesce()
    for selected in [selection, copy.selection] {
        let reopened = try await LocalStoreSession.open(selection: selected, protection: f.protection)
        let current = try await reopened.prepareProjectionRelocationRecovery(for: f.birth)
        #expect(current.record == reserved.record && current.sourceBytes == recovery.sourceBytes && current.outputBytes == recovery.outputBytes)
        await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionRelocationRecovery(recovery) }
        await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionRelocationReservation(reserved) }
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["C", "untouched"])
        try await reopened.quiesce()
    }
}

@Test func projectionRelocationReservationFailureKeepsFrozenInputs() async throws {
    let f = try await ReplacementFixture.make(name: "Renamed.txt"), input = try await f.prepareRelocation()
    let before = try await f.store.projectionObservations(for: f.birth)
    let root = input.association.bookmark, source = input.source.physical, foreign = try PassivePlatformRecordV1(codec: 1, bytes: [99])
    await #expect(throws: StorageError.wrongContext) { try await f.store.reserveProjectionRelocation(input, root: foreign, source: source) }
    await #expect(throws: StorageError.wrongContext) { try await f.store.reserveProjectionRelocation(input, root: root, source: foreign) }
    try await f.store.lane.perform { try $0.exec("CREATE TEMP TRIGGER reservation_fail BEFORE INSERT ON private_groups BEGIN SELECT RAISE(ABORT,'reservation failure'); END") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) { try await f.store.reserveProjectionRelocation(input, root: root, source: source) }
        #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == nil)
        #expect(try await f.store.projectionObservations(for: f.birth).value == before.value)
    }
    try await f.store.lane.perform { try $0.exec("DROP TRIGGER reservation_fail") }
    let reserved = try await f.store.reserveProjectionRelocation(input, root: root, source: source)
    let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: f.birth, generation: 2))])
    _ = try requireReceipt(await f.store.persist(capture: deletion))
    await #expect(throws: StorageError.staleCapture) { try await f.store.checkProjectionRelocationReservation(reserved) }
    #expect(try await f.store.prepareProjectionRelocationRecovery(for: f.birth).record == reserved.record)
    try await f.store.quiesce()
}

@Test(arguments: [false, true])
func projectionReplacementInputRetainsBothExactGenerations(utf16: Bool) async throws {
    let f = try await ReplacementFixture.make(utf16: utf16), input = try await f.prepare()
    let old: [UInt8] = utf16 ? [255,254,65,0] : [65], next: [UInt8] = utf16 ? [255,254,66,0] : [66]
    #expect(input.source == f.source && input.output == f.output)
    #expect(input.sourceBytes == old && input.bytes == next && input.value.body.string == "B")
    _ = try await put("C", birth: f.birth, generation: 2, session: f.store)
    _ = try await ReplacementFixture.intent(f.store, birth: f.birth, utf16: utf16, name: "Later.txt")
    try await f.store.checkProjectionReplacement(input)
    let pending = try await f.store.projectionObservations(for: f.birth), selection = await f.store.selection
    #expect(pending.value?.frozen?.output == f.output && pending.value?.intended?.output != f.output)
    try await f.store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: f.protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionReplacement(input) }
    let recovered = try await reopened.prepareProjectionReplacement(observations: reopened.projectionObservations(for: f.birth), basedOn: reopened.snapshot())
    #expect(recovered.sourceBytes == old && recovered.bytes == next && recovered.attempt != input.attempt)
    #expect(try await reopened.projectionObservations(for: f.birth).value == pending.value)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["C", "untouched"])
    try await reopened.quiesce()
}

@Test func projectionReplacementInputRequiresSameNamedSourceAndOwner() async throws {
    let f = try await ReplacementFixture.make(), other = try await ReplacementFixture.make(name: "Renamed.txt")
    let input = try await f.prepare()
    await #expect(throws: StorageError.wrongContext) { try await other.store.checkProjectionReplacement(input) }
    await #expect(throws: StorageError.wrongContext) { try await other.prepare() }
    await #expect(throws: StorageError.wrongContext) {
        try await f.store.prepareProjectionCreation(observations: f.store.projectionObservations(for: f.birth), basedOn: f.store.snapshot())
    }
    let state = try await f.store.projectionObservations(for: f.birth)
    await #expect(throws: StorageError.wrongContext) {
        try await other.store.prepareProjectionReplacement(observations: state, basedOn: other.store.snapshot())
    }
    try await f.store.quiesce(); try await other.store.quiesce()
}

@Test(arguments: ["delete", "association", "source", "frozen"])
func projectionReplacementInputRejectsChangedApplicability(change: String) async throws {
    let f = try await ReplacementFixture.make(), input = try await f.prepare()
    switch change {
    case "delete":
        let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
            changes: [.delete(.init(birth: f.birth, generation: 2))])
        _ = try requireReceipt(await f.store.persist(capture: deletion))
    case "association":
        let prior = try await f.store.localAssociation(), value = try #require(prior.value)
        let changed = try LocalAssociationV1(id: value.id, scope: value.scope, bookmark: .init(codec: 1, bytes: [9]))
        try await f.store.saveLocalAssociation(changed, basedOn: prior)
    default:
        let prior = try #require(await f.store.projectionObservations(for: f.birth).value)
        let source = try AcceptedProjectionV1(output: f.source.output, physical: .init(codec: 1, bytes: [33]),
            encoding: nil, tags: nil, created: nil, modified: nil)
        let changed = try ProjectionObservationsV1(profile: .plaintextFiles, scope: prior.scope, association: prior.association,
            birth: prior.birth, accepted: change == "source" ? source : prior.accepted,
            intended: prior.intended, frozen: change == "frozen" ? nil : prior.frozen)
        try await f.store.lane.perform { try $0.run("UPDATE private_groups SET generation=generation+1,payload=? WHERE group_key=?",
            [.blob(changed.encodedV1()), .blob(ReplacementFixture.key(f.birth))]) }
    }
    await #expect(throws: StorageError.staleCapture) { try await f.store.checkProjectionReplacement(input) }
    try await f.store.quiesce()
}

@Test(arguments: [false, true], ["occurrence", "bytes"])
func projectionReplacementInputVerifiesSourceHistory(utf16: Bool, damage: String) async throws {
    let f = try await ReplacementFixture.make(utf16: utf16)
    let healthy = try await f.prepare()
    #expect(healthy.source == f.source)
    let ref = try #require(f.source.output.binding.occurrences.first)
    try await f.store.lane.perform { db in
        if damage == "bytes" {
            try db.exec("DROP TRIGGER objects_no_update")
            try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(ref.locator.segmentID.bytes)])
        } else {
            try db.exec("PRAGMA foreign_keys=OFF")
            try db.run("DELETE FROM operation_occurrences WHERE object_id=? AND record_index=?",
                [.blob(ref.locator.segmentID.bytes), .integer(Int64(ref.index.rawValue))])
            try db.exec("PRAGMA foreign_keys=ON")
        }
    }
    if damage == "bytes" {
        await #expect(throws: CanonicalEncodingError.lengthLimit) { try await f.prepare() }
    } else {
        await #expect(throws: StorageError.integrity) { try await f.prepare() }
    }
    await #expect(throws: StorageError.integrity) { try await f.store.snapshot() }
    await f.store.lane.close()
}

@Test func projectionReplacementReservationSurvivesRestartAndNewerWork() async throws {
    let f = try await ReplacementFixture.make(utf16: true), input = try await f.prepare()
    let root = try PassivePlatformRecordV1(codec: 1, bytes: [19]), source = try PassivePlatformRecordV1(codec: 1, bytes: [20])
    let reserved = try await f.store.reserveProjectionReplacement(input, root: root, source: source)
    #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == reserved.record)
    try await f.store.checkProjectionReplacementReservation(reserved)
    #expect(reserved.record.transition.output == f.output && reserved.record.transition.source == f.source)
    #expect(reserved.record.root == root && reserved.record.source == source)
    #expect(reserved.record.attempt.bytes[6] >> 4 == 4 && reserved.record.attempt.bytes[8] >> 6 == 2)
    let rows = try await f.store.lane.perform { try $0.rows("SELECT generation,codec,payload FROM private_groups WHERE group_key=?",
        [.blob(Array(("projection-replacement/" + String(repeating: "01", count: 16)).utf8))]) }
    #expect(rows == [[.integer(1), .integer(1), .blob(try reserved.record.encodedV1())]])
    _ = try await put("C", birth: f.birth, generation: 2, session: f.store)
    _ = try await ReplacementFixture.intent(f.store, birth: f.birth, utf16: true, name: "Later.txt")
    try await f.store.checkProjectionReplacementReservation(reserved)
    await #expect(throws: StorageError.busy) { try await f.store.reserveProjectionReplacement(input, root: root, source: source) }
    let selection = await f.store.selection, copy = try await f.store.preparePrivateStoreCopy(to: privateTempPath())
    try await copy.close(); try await f.store.quiesce()
    for selected in [selection, copy.selection] {
        let reopened = try await LocalStoreSession.open(selection: selected, protection: f.protection)
        #expect(try await reopened.pendingProjectionReplacement(for: f.birth) == reserved.record)
        let state = try await reopened.projectionObservations(for: f.birth)
        #expect(try await reopened.capturedProjectionBytes(f.output, observations: state) == [255,254,66,0])
        #expect(try await reopened.capturedProjectionBytes(f.source.output, observations: state) == [255,254,65,0])
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["C", "untouched"])
        await #expect(throws: StorageError.wrongContext) { try await reopened.checkProjectionReplacementReservation(reserved) }
        try await reopened.quiesce()
    }
}

@Test func projectionReplacementReservationFailureKeepsFrozenInputs() async throws {
    let f = try await ReplacementFixture.make(), input = try await f.prepare(), before = try await f.store.projectionObservations(for: f.birth)
    let root = try PassivePlatformRecordV1(codec: 1, bytes: [19]), source = try PassivePlatformRecordV1(codec: 1, bytes: [20])
    try await f.store.lane.perform { try $0.exec("CREATE TEMP TRIGGER reservation_fail BEFORE INSERT ON private_groups BEGIN SELECT RAISE(ABORT,'reservation failure'); END") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) { try await f.store.reserveProjectionReplacement(input, root: root, source: source) }
        #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == nil)
        #expect(try await f.store.projectionObservations(for: f.birth).value == before.value)
    }
    try await f.store.lane.perform { try $0.exec("DROP TRIGGER reservation_fail") }
    let reserved = try await f.store.reserveProjectionReplacement(input, root: root, source: source)
    let deletion = try await CapturedActionGroup(snapshot: f.store.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: f.birth, generation: 2))])
    _ = try requireReceipt(await f.store.persist(capture: deletion))
    await #expect(throws: StorageError.staleCapture) { try await f.store.checkProjectionReplacementReservation(reserved) }
    #expect(try await f.store.pendingProjectionReplacement(for: f.birth) == reserved.record)
    try await f.store.quiesce()
}

@Test(arguments: ["codec", "payload", "key", "frozen"])
func projectionReplacementReservationRejectsDamagedRecovery(_ damage: String) async throws {
    let f = try await ReplacementFixture.make(), input = try await f.prepare()
    let reserved = try await f.store.reserveProjectionReplacement(input,
        root: .init(codec: 1, bytes: [19]), source: .init(codec: 1, bytes: [20]))
    try await f.store.verifyCompletePrivateState()
    let key = Array(("projection-replacement/" + String(repeating: "01", count: 16)).utf8)
    try await f.store.lane.perform { db in
        switch damage {
        case "codec": try db.run("UPDATE private_groups SET codec=99 WHERE group_key=?", [.blob(key)])
        case "payload": try db.run("UPDATE private_groups SET payload=? WHERE group_key=?", [.blob([0]), .blob(key)])
        case "key": try db.run("UPDATE private_groups SET group_key=? WHERE group_key=?",
            [.blob(Array(("projection-replacement/" + String(repeating: "02", count: 16)).utf8)), .blob(key)])
        default:
            let row = try #require(try db.privateGroup("projection/" + String(repeating: "01", count: 16)))
            let state = try ProjectionObservationsV1.decodeV1(row[2].bytes, profile: .plaintextFiles)
            let changed = try ProjectionObservationsV1(profile: .plaintextFiles, scope: state.scope,
                association: state.association, birth: state.birth, accepted: state.accepted, intended: state.intended)
            try db.run("UPDATE private_groups SET payload=? WHERE group_key=?", [.blob(changed.encodedV1()), .blob(ReplacementFixture.key(state.birth))])
        }
    }
    let selection = await f.store.selection
    let expected: StorageError = damage == "codec" ? .unsupported : .integrity
    await #expect(throws: expected) { try await f.store.verifyCompletePrivateState() }
    await f.store.lane.close()
    await #expect(throws: expected) { try await LocalStoreSession.open(selection: selection, protection: f.protection) }
    #expect(reserved.record.transition.output == f.output)
}
