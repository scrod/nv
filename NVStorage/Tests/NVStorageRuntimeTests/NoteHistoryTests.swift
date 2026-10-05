import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

private func entries(_ query: HistoryQuery, in session: LocalStoreSession, limit: Int = 1) async throws -> [HistoryEntry] {
    var result: [HistoryEntry] = [], cursor: HistoryCursor?
    repeat {
        let page = try await session.history(for: query, after: cursor, limit: limit)
        result += page.entries; cursor = page.continuation
    } while cursor != nil
    return result
}

@Test(arguments: [false, true], [false, true])
func historySurvivesReorderedDeliveryAndReopen(encrypted: Bool, childFirst: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection)
    var receiver = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let original = try #require(try await source.snapshot().notes.first(where: { $0.birth == birth }))
    let edit = try await put("E", birth: birth, generation: 1, session: source)
    let edited = try await source.snapshot()
    let editID = try #require(edited.notes.first(where: { $0.birth == birth })).revision.id
    let capture = try CapturedActionGroup(snapshot: edited, kind: .deleteBatch,
        changes: [.delete(CapturedNoteGeneration(birth: birth, generation: 2))])
    let deletion = try requireReceipt(await source.persist(capture: capture))
    let deletionID = try #require(try await source.snapshot().context.operations.first).id
    let editBytes = try await source.retainedObject(at: edit.object)
    let deleteBytes = try await source.retainedObject(at: deletion.object)
    let selection = await receiver.selection
    if childFirst {
        guard case .waiting = try await receiver.receive(deleteBytes) else { Issue.record("missing edit must park Delete"); return }
        #expect(try await receiver.history(for: .deletions).entries.isEmpty)
        #expect(try await entries(.note(birth), in: receiver).map(\.operation) == [original.revision.id])
        try await receiver.quiesce()
        receiver = try await .open(selection: selection, protection: protection)
    }
    _ = try await receiver.receive(editBytes)
    _ = try await receiver.receive(deleteBytes)
    _ = try await receiver.receive(editBytes)
    // A different envelope retains the same logical revision once.
    let repackaged = try ObjectEnvelopeV1.seal(payload: ObjectEnvelopeV1.open(editBytes,
        collection: initial.descriptor.collection, protection: protection).payload, kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: Array(repeating: 91, count: 16)),
        sequence: 0, protection: protection)
    _ = try await receiver.receive(repackaged)
    try await receiver.quiesce()
    receiver = try await .open(selection: selection, protection: protection)
    let before = try await receiver.snapshot()
    #expect(before.notes.map(\.value.body.string) == ["untouched"])
    let revisions = try await entries(.note(birth), in: receiver)
    #expect(revisions.count == 3)
    #expect(Set(revisions.map(\.operation)) == [original.revision.id, editID, deletionID])
    var bodies: [OperationID: String] = [:]
    for entry in revisions {
        let preview = try await receiver.preview(entry)
        #expect(preview.action.id == entry.action)
        #expect(preview.action.members.contains(entry.operation))
        switch preview.state {
        case .value(let operation):
            bodies[operation.id] = operation.effect.noteValue?.body.string
            if operation.id == editID { #expect(operation.notePredecessors.ids == [original.revision.id]) }
        case .deleted(let operation, let prior):
            #expect(operation.id == deletionID)
            #expect(prior.id == editID)
            #expect(prior.effect.noteValue?.body.string == "E")
            #expect(preview.action.kind == .deleteBatch)
        case .deletedState: Issue.record("single saved edit has one prior revision")
        }
    }
    #expect(bodies == [original.revision.id: "A", editID: "E"])
    #expect(try await entries(.deletions, in: receiver).map(\.operation) == [deletionID])
    let after = try await receiver.snapshot()
    #expect(before.notes == after.notes && before.context == after.context && before.through == after.through)
    try await source.quiesce(); try await receiver.quiesce()
}

@Test func historyPagesFreezeTheirPrefixAndCheckConsumers() async throws {
    let (initial, protection) = try testInitial(false), session = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("E", birth: birth, generation: 1, session: session)
    let known = try await entries(.note(birth), in: session)
    let first = try await session.history(for: .note(birth), limit: 1)
    let cursor = try #require(first.continuation), entry = try #require(first.entries.first)
    for generation in 2...33 {
        _ = try await put("F\(generation)", birth: birth, generation: UInt64(generation), session: session)
    }
    var continued = first.entries, next: HistoryCursor? = cursor
    let lane = await session.lane
    func checkedPage(after cursor: HistoryCursor?) async throws -> HistoryPage {
        try await lane.perform { $0.work = StorageWork() }
        let page = try await session.history(for: .note(birth), after: cursor, limit: 1)
        let querySteps = try await lane.perform { db -> [Int] in
            let steps = db.work!.stages.values.flatMap { $0.statementSteps.filter { $0.key.hasPrefix("SELECT operation_id,birth,action_id") }.map(\.value) }
            db.work = nil; return steps
        }
        #expect(querySteps.count == 1 && querySteps[0] < 100)
        #expect(page.entries.count <= 1)
        return page
    }
    _ = try await checkedPage(after: nil)
    repeat {
        let page = try await checkedPage(after: next)
        continued += page.entries; next = page.continuation
    } while next != nil
    #expect(continued.map(\.operation) == known.map(\.operation))
    #expect(try await entries(.note(birth), in: session).count == 34)
    _ = try await session.preview(entry)
    await #expect(throws: StorageError.wrongContext) { try await session.history(for: .deletions, after: cursor) }
    for limit in [0, -1, 129, Int.max] {
        await #expect(throws: StorageError.limit) { try await session.history(for: .note(birth), limit: limit) }
    }
    let other = try await newSession(initial, protection)
    await #expect(throws: StorageError.wrongContext) { try await other.preview(entry) }
    await #expect(throws: StorageError.wrongContext) { try await other.history(for: .note(birth), after: cursor) }
    let selection = await session.selection
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.preview(entry) }
    await #expect(throws: StorageError.wrongContext) { try await reopened.history(for: .note(birth), after: cursor) }
    try await reopened.quiesce(); try await other.quiesce()
}

@Test func historyListingIsMetadataOnlyAndPreviewDetectsDamage() async throws {
    let (initial, protection) = try testInitial(false), session = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16)), lane = await session.lane
    _ = try await put("E", birth: birth, generation: 1, session: session)
    try await lane.perform { $0.work = StorageWork() }
    let listing = try await session.history(for: .note(birth))
    let work = try await lane.perform { db -> [StorageWork.Counts] in
        let counts = Array(db.work!.stages.values); db.work = nil; return counts
    }
    #expect(work.reduce(0) { $0 + $1.historyReads + $1.envelopeDecodes + $1.ancestors } == 0)
    #expect(listing.entries.count == 2)
    let initialEntry = try #require(listing.entries.first)
    // First check a valid companion before damaging exactly its representative envelope.
    _ = try await session.preview(initialEntry)
    try await lane.perform { db in
        let ref = try db.operationOccurrence(initialEntry.operation)
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(ref.locator.segmentID.bytes)])
    }
    await #expect(throws: CanonicalEncodingError.lengthLimit) { try await session.preview(initialEntry) }
    await #expect(throws: StorageError.integrity) { try await session.history(for: .note(birth)) }
    await #expect(throws: StorageError.integrity) { try await session.snapshot() }
    try await session.quiesce()
}

@Test(arguments: [false, true]) func historyPreservesConcurrentBranchIdentities(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let base = try #require(try await left.snapshot().notes.first { $0.birth == birth }).revision.id
    let a = try await put("left", birth: birth, generation: 1, session: left)
    let b = try await put("right", birth: birth, generation: 1, session: right)
    let leftID = try #require(try await left.snapshot().notes.first { $0.birth == birth }).revision.id
    let rightID = try #require(try await right.snapshot().notes.first { $0.birth == birth }).revision.id
    let bytes = try await right.retainedObject(at: b.object)
    _ = try await left.receive(bytes)
    guard case .accepted = try await left.receivedObjectStatus(at: b.object) else {
        Issue.record("valid competing action must remain accepted"); return
    }
    let listing = try await entries(.note(birth), in: left)
    #expect(Set(listing.map(\.operation)) == [base, leftID, rightID])
    var actual: [OperationID: String] = [:]
    for entry in listing where entry.operation != base {
        let preview = try await left.preview(entry)
        guard case .value(let op) = preview.state else { Issue.record("branch lost its value"); continue }
        #expect(op.notePredecessors.ids == [base])
        #expect(!op.causalParents.ids.contains(op.id == leftID ? rightID : leftID))
        actual[op.id] = op.effect.noteValue?.body.string
    }
    #expect(actual == [leftID: "left", rightID: "right"])
    #expect(try await left.retainedObject(at: a.object).isEmpty == false)
    #expect(try await left.retainedObject(at: b.object) == bytes)
    #expect(Set(try await left.snapshot().notes.first { $0.birth == birth }!.heads.map(\.id)) == [leftID, rightID])
    try await left.quiesce(); try await right.quiesce()
}
