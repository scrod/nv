import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true])
func traversalScopesAuditRepackagedOccurrencesOnce(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, selection = await session.selection
    let edit = try await put("new body", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    let opened = try ObjectEnvelopeV1.open(await session.retainedObject(at: edit.object), collection: selection.descriptor.collection, protection: protection)
    let duplicate = try ObjectEnvelopeV1.seal(payload: opened.payload, kind: .changes, collection: selection.descriptor.collection,
        writer: WriterEpoch(bytes: uuidBytes()), sequence: 0, protection: protection)
    let locator = try ObjectEnvelopeV1.open(duplicate, collection: selection.descriptor.collection, protection: protection).locator
    _ = try await session.receive(duplicate)
    let through = try await session.snapshot().through
    try await lane.perform { $0.work = StorageWork() }
    let ordinary = try await CheckedHistoryTraversal.read(through: through, scope: .representatives, lane: lane, selection: selection, protection: protection)
    let representativeWork = try await lane.perform { $0.work! }
    let representativeVisits = representativeWork.stages.values.flatMap { $0.traversalDecodes.values }
    try #require(representativeVisits.count == 1)
    #expect(representativeVisits[0][locator.segmentID] == nil)
    try await lane.perform { $0.work = StorageWork() }
    let audited = try await CheckedHistoryTraversal.read(through: through, scope: .allOccurrences, lane: lane, selection: selection, protection: protection)
    let work = try await lane.perform { $0.work! }, visits = work.stages.values.flatMap { $0.traversalDecodes.values }
    let payloadVisits = work.stages.values.flatMap { $0.traversalPayloadDecodes.values }
    try #require(visits.count == 1 && payloadVisits.count == 1)
    #expect(visits[0][locator.segmentID] == 1 && visits[0] == payloadVisits[0])
    #expect(visits[0].values.allSatisfy { $0 == 1 })
    #expect(audited.graph.operations == ordinary.graph.operations && audited.graph.actions == ordinary.graph.actions)
    let payload = try ChangesPayloadV1.decodeV1(opened.payload)
    let reference = StoredOperationReferenceV1(locator: locator, index: OperationIndex(0), id: payload.operations[0].operation.id)
    try await lane.perform { try audited.checkReferences(locator: locator, operations: [reference], actions: [], database: $0, selection: selection) }
    let wrong = StoredOperationReferenceV1(locator: locator, index: OperationIndex(99), id: reference.id)
    await #expect(throws: GeneralSnapshotError.invalidState) {
        try await lane.perform { try audited.checkReferences(locator: locator, operations: [wrong], actions: [], database: $0, selection: selection) }
    }
    let foreign = try await newSession(initial, protection), foreignLane = await foreign.lane, foreignSelection = await foreign.selection
    await #expect(throws: StorageError.wrongContext) {
        try await foreignLane.perform { try audited.checkReferences(locator: locator, operations: [reference], actions: [], database: $0, selection: foreignSelection) }
    }
    #expect(try await foreign.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await foreign.quiesce()
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == ["new body", "untouched"])
    try await session.quiesce()
}

@Test(arguments: [false, true], ["occurrence", "parent", "member", "scope"])
func traversalDetectsExactIndexedRelationshipDamage(encrypted: Bool, defect: String) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, selection = await session.selection
    _ = try await put("E", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    _ = try await put("F", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 2, session: session)
    try await lane.perform { db in
        switch defect {
        case "occurrence":
            try db.run("INSERT INTO operation_occurrences SELECT object_id,99,(SELECT operation_id FROM operation_occurrences other WHERE other.object_id!=original.object_id LIMIT 1) FROM operation_occurrences original LIMIT 1")
        case "parent": try db.run("DELETE FROM operation_parents WHERE (child,parent) IN (SELECT child,parent FROM operation_parents LIMIT 1)")
        case "scope": try db.run("DELETE FROM action_scope_parents WHERE (child,parent) IN (SELECT child,parent FROM action_scope_parents LIMIT 1)")
        default:
            try db.exec("PRAGMA foreign_keys=OFF")
            try db.run("DELETE FROM action_members WHERE (action_id,ordinal) IN (SELECT action_id,ordinal FROM action_members LIMIT 1)")
            try db.exec("PRAGMA foreign_keys=ON")
        }
    }
    await #expect(throws: StorageError.integrity) { try await lane.snapshotHistoryGraph(through: 3, selection: selection, protection: protection) }
    await #expect(throws: StorageError.integrity) { try await session.snapshot() }
    await lane.close()
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], ["history", "epoch", "settings"])
func recoveryGraphPreparationRechecksFinalContext(encrypted: Bool, interference: String) async throws {
    let (initial, protection) = try testInitial(encrypted), writer = try await newSession(initial, protection), reader = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), lane = await reader.lane, selection = await reader.selection
    var objects: [[UInt8]] = []
    let edit = try await put("E", birth: birth, generation: 1, session: writer)
    objects.append(try await writer.retainedObject(at: edit.object))
    for direction in [UndoDirectionV1.undo, .redo] {
        guard case .automatic(let command) = try await writer.prepareCompensation(scope: .note(birth), direction: direction) else { Issue.record("Expected real compensation"); return }
        let receipt = try requireReceipt(await writer.applyCompensation(command)); objects.append(try await writer.retainedObject(at: receipt.object))
    }
    for bytes in objects {
        let locator = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection).locator
        _ = try await lane.acceptScheduled(bytes, locator: locator, selection: selection, protection: protection)
    }
    let gate = ImprovementGate()
    try await lane.perform { db in db.work = StorageWork(); db.work?.recoveryPrepared = { await gate.hold() } }
    let attempt = Task { try await CatchUpScope.$purpose.withValue(.opening) { try await lane.catchUp(selection: selection, protection: protection) } }
    await gate.wait()
    if interference == "history" {
        let next = try await put("F", birth: birth, generation: 2, session: writer)
        _ = try await lane.acceptScheduled(writer.retainedObject(at: next.object), locator: next.object, selection: selection, protection: protection)
    } else if interference == "epoch" {
        try await lane.perform { try $0.run("UPDATE view_meta SET epoch=?", [.blob(uuidBytes())]) }
    } else {
        try await reader.saveEmptySettings(basedOn: reader.settings())
    }
    await gate.release(); try await attempt.value
    #expect(try await reader.snapshot().notes.map(\.value.body.string).sorted() == [interference == "history" ? "F" : "E", "untouched"])
    let work = try await lane.perform { $0.work! }
    #expect(work.stages.values.reduce(0) { $0 + $1.graphLoads } == (interference == "settings" ? 1 : 2))
    if interference == "settings" { #expect(try await reader.settings().generation == 2) }
    let next = try await reader.prepareCompensation(scope: .note(birth), direction: .undo)
    guard case .automatic = next else { Issue.record("Recovery lost the next Undo candidate"); return }
    try await reader.quiesce(); try await writer.quiesce()
}
