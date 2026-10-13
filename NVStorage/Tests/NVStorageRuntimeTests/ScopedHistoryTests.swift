import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Compares the selected reader with complete-history selection and exact current head references.
func expectScopedHistoryMatchesFull(_ store: LocalStoreSession, birth: NoteBirth) async throws {
    let snapshot = try await store.snapshot(), lane = await store.lane, selection = await store.selection
    let protection = await store.protection
    let graph = try await lane.retainedGraph(through: snapshot.through, selection: selection, protection: protection)
    for direction in [UndoDirectionV1.undo, .redo] {
        let expected = try CausalUndoV1.select(actions: Array(graph.actions.values), scope: .note(birth), direction: direction)
        let actual = try await store.undoCandidates(scope: .note(birth), direction: direction)
        #expect(actual.ids == expected.candidates && actual.mode == expected.mode)
    }
    if let cell = snapshot.notes.first(where: { $0.birth == birth }) {
        let copies = Set(graph.actions.values.compactMap { action -> OperationID? in
            if case .copy(_, let revision, _, _, _) = action.details { revision } else { nil }
        })
        let ids = Set(cell.heads.map(\.id)).subtracting(cell.represented.map(\.id)).subtracting(copies)
        let actual = try await store.conflicts(for: birth)
        #expect(actual.current == cell && actual.representedSeparately == copies)
        #expect(Set(actual.alternatives.map(\.id)) == ids)
        for record in actual.alternatives { #expect(record == graph.operations[record.id]) }
    }
}

@Test(arguments: [false, true], [false, true])
func scopedSharedEnvelopeKeepsCompleteGroupsAndDeletedScope(encrypted: Bool, delete: Bool) async throws {
    let (descriptor, root, objects, protection, _) = try sharedBootstrap(encrypted: encrypted, delete: delete)
    let selection = try LocalStoreSelection(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
        store: LocalStoreID(bytes: uuidBytes()), descriptor: descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: root, protection: protection)
    for bytes in objects.values { _ = try await candidate.retain(bytes) }
    let store = try await candidate.complete(snapshot: root), lane = await store.lane
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    try await lane.perform { $0.work = StorageWork() }
    let undo = try await store.undoCandidates(scope: .note(a), direction: .undo)
    #expect(undo.ids == [try ActionID(bytes: Array(repeating: 37, count: 16))])
    #expect(try await store.undoCandidates(scope: .note(b), direction: .undo).ids.isEmpty)
    let work = try await lane.perform { $0.work! }
    #expect(work.stages.values.reduce(0) { $0 + $1.historyReads } == 1)
    #expect(work.stages.values.flatMap { $0.traversalDecodes.values }.allSatisfy { $0.values.allSatisfy { $0 == 1 } })
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == (delete ? ["sentinel B"] : ["later E", "sentinel B"]))
    try await expectScopedHistoryMatchesFull(store, birth: a)
    try await expectScopedHistoryMatchesFull(store, birth: b)
    let collection = try await store.undoCandidates(scope: .collection, direction: .undo)
    #expect(collection.ids == [try ActionID(bytes: Array(repeating: 36, count: 16))])
    try await store.quiesce()
}

@Test(arguments: [false, true])
func scopedWorkStaysFixedAcrossUnrelatedHistory(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let saved = try await put("selected E", birth: a, generation: 1, session: store)
    let payload = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(store.retainedObject(at: saved.object), collection: initial.descriptor.collection, protection: protection).payload)
    let expected = payload.actions[0].action.id, lane = await store.lane
    var count = 0, baseline: (sql: Int, scans: Int)?
    for target in [64, 256, 1024] {
        while count < target { count += 1; _ = try await put("unrelated \(count)", birth: b, generation: UInt64(count), session: store) }
        try await lane.perform { $0.work = StorageWork() }
        let start = DispatchTime.now().uptimeNanoseconds
        #expect(try await store.undoCandidates(scope: .note(a), direction: .undo).ids == [expected])
        #expect(try await store.conflicts(for: a).alternatives.isEmpty)
        let work = try await lane.perform { $0.work! }, counts = work.stages.values
        let reads = counts.reduce(0) { $0 + $1.historyReads }, statements = counts.reduce(0) { $0 + $1.statements }
        #expect(reads == 1 && counts.reduce(0) { $0 + $1.envelopeDecodes } == 1)
        #expect(counts.reduce(0) { $0 + $1.graphLoads } == 0)
        let scans = counts.reduce(0) { $0 + $1.fullScanSteps }
        for stage in counts {
            for (sql, steps) in stage.statementScanSteps where steps > 0 {
                // Header catalog checks and the fixed current-note capture have bounded scans.
                #expect(sql.contains("FROM sqlite_schema") || sql == "SELECT birth,cell FROM current_notes ORDER BY rowid")
            }
        }
        if let baseline { #expect(statements == baseline.sql && scans == baseline.scans) }
        else { baseline = (statements, scans) }
        print("SCOPED_QUERY encrypted=\(encrypted) unrelated=\(target) reads=\(reads) sql=\(statements) ns=\(DispatchTime.now().uptimeNanoseconds - start)")
    }
    try await expectScopedHistoryMatchesFull(store, birth: a)
    try await store.quiesce()
}

@Test(arguments: [false, true], ["occurrence", "parent", "scope", "member", "address", "missing"])
func scopedQueryRejectsSelectedEvidenceDamage(encrypted: Bool, defect: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), lane = await store.lane, selection = await store.selection
    _ = try await put("E", birth: birth, generation: 1, session: store)
    let saved = try await put("F", birth: birth, generation: 2, session: store)
    try await expectScopedHistoryMatchesFull(store, birth: birth)
    try await lane.perform { db in
        try db.exec("PRAGMA foreign_keys=OFF")
        switch defect {
        case "occurrence": try db.run("DELETE FROM operation_occurrences WHERE object_id=?", [.blob(saved.object.segmentID.bytes)])
        case "parent": try db.run("DELETE FROM operation_parents WHERE child IN (SELECT operation_id FROM operations WHERE source_object=?)", [.blob(saved.object.segmentID.bytes)])
        case "scope": try db.run("DELETE FROM action_scope_parents WHERE child IN (SELECT action_id FROM actions WHERE source_object=?)", [.blob(saved.object.segmentID.bytes)])
        case "member": try db.run("DELETE FROM action_members WHERE action_id IN (SELECT action_id FROM actions WHERE source_object=?)", [.blob(saved.object.segmentID.bytes)])
        case "address": try db.run("UPDATE actions SET source_index=99 WHERE source_object=?", [.blob(saved.object.segmentID.bytes)])
        default: try db.run("DELETE FROM objects WHERE object_id=?", [.blob(saved.object.segmentID.bytes)])
        }
        try db.exec("PRAGMA foreign_keys=ON")
    }
    // Missing retained bytes and contradictory indexed records have distinct recovery diagnostics.
    let failure: StorageError = defect == "missing" ? .incomplete : .integrity
    await #expect(throws: failure) { try await store.undoCandidates(scope: .note(birth), direction: .undo) }
    await #expect(throws: StorageError.integrity) { try await store.snapshot() }
    await lane.close()
    await #expect(throws: StorageError.integrity) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}

@Test(arguments: [false, true])
func scopedMissingNoteKeepsExplicitOutcomeAndHealthyStore(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), missing = try NoteBirth(bytes: Array(repeating: 99, count: 16))
    await #expect(throws: StorageError.incomplete) { try await store.conflicts(for: missing) }
    #expect(try await store.undoCandidates(scope: .note(missing), direction: .undo).ids.isEmpty)
    let capture = try await CapturedActionGroup(snapshot: store.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: birth, generation: 1))])
    _ = try requireReceipt(await store.persist(capture: capture))
    await #expect(throws: StorageError.incomplete) { try await store.conflicts(for: birth) }
    try await expectScopedHistoryMatchesFull(store, birth: birth)
    _ = try await put("save after missing-note query", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 1, session: store)
    #expect(try await store.snapshot().notes.map(\.value.body.string) == ["save after missing-note query"])
    try await store.quiesce()
}

@Test(arguments: [false, true])
func scopedEvidenceRequiresExactConsumerAndConnection(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), other = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    _ = try await put("E", birth: birth, generation: 1, session: store)
    let snapshot = try await store.snapshot(), lane = await store.lane, selection = await store.selection
    let checked = try await CheckedQueryHistory.read(scope: .undo(birth), snapshot: snapshot, session: snapshot.session,
        lane: lane, selection: selection, protection: protection)
    let foreign = try await newSession(initial, protection), foreignSnapshot = try await foreign.snapshot(), foreignSelection = await foreign.selection
    await #expect(throws: StorageError.wrongContext) {
        try await foreign.lane.perform { try checked.undoActions(for: birth, snapshot: foreignSnapshot, database: $0, selection: foreignSelection) }
    }
    await #expect(throws: StorageError.wrongContext) {
        try await lane.perform { try checked.undoActions(for: other, snapshot: snapshot, database: $0, selection: selection) }
    }
    await #expect(throws: StorageError.wrongContext) {
        try await lane.perform { try checked.conflicts(for: birth, snapshot: snapshot, database: $0, selection: selection) }
    }
    await #expect(throws: StorageError.wrongContext) {
        try await CheckedQueryHistory.read(scope: .undo(birth), snapshot: snapshot, session: UUID(), lane: lane, selection: selection, protection: protection)
    }
    _ = try await put("F", birth: other, generation: 1, session: store)
    let newer = try await store.snapshot()
    await #expect(throws: StorageError.wrongContext) {
        try await lane.perform { try checked.undoActions(for: birth, snapshot: newer, database: $0, selection: selection) }
    }
    #expect(try await lane.perform { try checked.undoActions(for: birth, snapshot: snapshot, database: $0, selection: selection).count } == 1)
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext, "The reopened connection requires freshly issued evidence") {
        try await reopened.lane.perform { try checked.undoActions(for: birth, snapshot: snapshot, database: $0, selection: selection) }
    }
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["E", "F"])
    try await reopened.quiesce(); try await foreign.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func scopedQueryKeepsCapturedPrefixAcrossHistoryArrival(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), lane = await store.lane
    let first = try await put("E", birth: birth, generation: 1, session: store)
    let oldID = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(store.retainedObject(at: first.object), collection: initial.descriptor.collection, protection: protection).payload).actions[0].action.id
    let pause = ImprovementGate()
    try await lane.perform { $0.work = StorageWork(); $0.work?.querySelected = { await pause.hold() } }
    let query = Task { try await store.undoCandidates(scope: .note(birth), direction: .undo) }
    await pause.wait()
    let next = try await put("F", birth: birth, generation: 2, session: store)
    let newID = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(store.retainedObject(at: next.object), collection: initial.descriptor.collection, protection: protection).payload).actions[0].action.id
    await pause.release()
    #expect(try await query.value.ids == [oldID])
    #expect(try await store.undoCandidates(scope: .note(birth), direction: .undo).ids == [newID])
    #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "F")
    try await store.quiesce()
}

@Test(arguments: [false, true], [false, true])
func returningSchemaRequiresCopyIndexWithoutRebuilding(encrypted: Bool, contradictory: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let lane = await store.lane, selection = await store.selection
    try await lane.perform { db in
        try db.exec("DROP INDEX actions_conflict_copies")
        if contradictory { try db.exec("CREATE INDEX actions_conflict_copies ON actions(first_seq, action_id) WHERE kind=1") }
    }
    await lane.close()
    await #expect(throws: StorageError.incomplete) { try await LocalStoreSession.open(selection: selection, protection: protection) }
}
