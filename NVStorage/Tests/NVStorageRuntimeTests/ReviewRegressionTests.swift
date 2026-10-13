import NVStorageTestSupport
import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

private func reviewBirth(_ byte: UInt8) throws -> NoteBirth {
    try .init(bytes: Array(repeating: byte, count: 16))
}
private func reviewAccepted(_ outcome: CommitOutcome) -> Bool {
    if case .accepted = outcome { true } else { false }
}

@Test(arguments: [false, true], [HistoryFieldsV1.body, .all])
func historicalRecoveryAdoptsAutomaticNoteAndKeepsSaving(encrypted: Bool, fields: HistoryFieldsV1) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection)
    let source = try reviewBirth(1), sentinel = try reviewBirth(2)
    let history = try #require(try await left.history(for: .note(source)).entries.first)
    let deletion = try await CapturedActionGroup(snapshot: left.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: source, generation: 1))])
    let deleted = try requireReceipt(await left.persist(capture: deletion))
    let edited = try await put("uncovered E", birth: source, generation: 1, session: right)
    _ = try await left.receive(right.retainedObject(at: edited.object))
    let automatic = try #require(try await left.snapshot().notes.first { $0.automatic != nil })
    let capture = try await left.recoverHistory(history, to: automatic.birth, generation: 2, fields: fields)
    let outcome = try await left.persist(capture: capture)
    #expect(reviewAccepted(outcome))
    let recovered = try requireReceipt(outcome)
    let bytes = try await left.retainedObject(at: recovered.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes,
        collection: initial.descriptor.collection, protection: protection).payload)
    #expect(payload.actions[0].action.kind == .historicalRecovery)
    #expect(payload.actions[0].action.affected[0].before == automatic.state)
    guard case .adoptAutomatic(_, let birth, let provenance, _) = payload.operations[0].operation.effect else {
        Issue.record("Recovery must independently author the automatic birth"); return
    }
    #expect(birth == automatic.birth && ActionStateV1.automatic(provenance) == automatic.state)
    let current = try #require(try await left.snapshot().notes.first { $0.birth == birth })
    #expect(current.value.body.string == "A" && current.automatic == nil)
    #expect(current.identity == automatic.identity)
    #expect(current.value.title == (fields.contains(.title) ? try testValue("A").title : automatic.value.title))
    _ = try await put("later unrelated edit", birth: sentinel, generation: 3, session: left)
    let coveringDelete = try await CapturedActionGroup(snapshot: right.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: source, generation: 2))])
    let covered = try requireReceipt(await right.persist(capture: coveringDelete))
    _ = try await left.receive(right.retainedObject(at: covered.object))
    _ = try await right.receive(left.retainedObject(at: deleted.object))
    _ = try await right.receive(bytes)
    for store in [left, right] {
        #expect(try await store.snapshot().notes.first { $0.birth == birth } == current)
        #expect(try await store.snapshot().notes.allSatisfy { $0.birth != source })
    }
    let selection = await left.selection
    try await left.quiesce(); try await right.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.first { $0.birth == birth } == current)
    #expect(try await reopened.snapshot().notes.first { $0.birth == sentinel }?.value.body.string == "later unrelated edit")
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func currentCreationDateAgreesAcrossIncrementalReductionAndRebuild(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try reviewBirth(1)
    var writer = try await newSession(initial, protection)
    let receiver = try await newSession(initial, protection)
    let entry = try #require(try await writer.history(for: .note(source)).entries.first)
    let original = try #require(try await writer.snapshot().notes.first { $0.birth == source })
    let rawValue = try PlaintextNoteValue(title: original.value.title, body: .init(bytes: Array("edited".utf8)),
        labels: original.value.labels, created: .init(secondsSinceReferenceDate: 10), modified: .init(secondsSinceReferenceDate: 2))
    let capture = try await CapturedActionGroup(snapshot: writer.snapshot(), kind: .savedEdit,
        changes: [.put(.init(birth: source, generation: 1), rawValue)])
    let receipt = try requireReceipt(await writer.persist(capture: capture))
    let bytes = try await writer.retainedObject(at: receipt.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(bytes,
        collection: initial.descriptor.collection, protection: protection).payload)
    #expect(payload.operations[0].operation.effect.noteValue == rawValue)
    _ = try await receiver.receive(bytes)
    let expected = try PlaintextNoteValue(title: rawValue.title, body: rawValue.body, labels: rawValue.labels,
        created: original.value.created, modified: rawValue.modified)
    for store in [writer, receiver] {
        #expect(try await store.snapshot().notes.first { $0.birth == source }?.value == expected)
        let graph = try await store.lane.retainedGraph(through: store.snapshot().through,
            selection: store.selection, protection: protection)
        #expect(try graph.currentCells(collection: initial.descriptor.collection).first { $0.birth == source }?.value == expected)
    }
    let copy = try await writer.recoverHistory(entry, to: reviewBirth(3), generation: 2, separate: true)
    let copied = try requireReceipt(await writer.persist(capture: copy))
    _ = try await receiver.receive(writer.retainedObject(at: copied.object))
    #expect(try await writer.snapshot().notes.first { $0.birth == source }?.value == expected)
    let followup = try await CapturedActionGroup(snapshot: writer.snapshot(), kind: .savedEdit,
        changes: [.put(.init(birth: source, generation: 3), rawValue)])
    _ = try requireReceipt(await writer.persist(capture: followup))
    #expect(try await writer.snapshot().notes.first { $0.birth == source }?.value == expected)
    let selection = await writer.selection
    try await writer.lane.perform { db in
        try db.run("UPDATE current_notes SET cell=? WHERE birth=?", [.blob([0]), .blob(source.bytes)])
    }
    try await writer.quiesce()
    writer = try await .open(selection: selection, protection: protection)
    #expect(try await writer.snapshot().notes.first { $0.birth == source }?.value == expected)
    try await writer.quiesce(); try await receiver.quiesce()
}

@Test(arguments: [false, true])
func specializedCaptureRequiresProvenanceBeforeAdmission(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let snapshot = try await store.snapshot(), source = try reviewBirth(1)
    let change = try CapturedNoteChange.put(.init(birth: source, generation: 1), testValue("replacement"))
    let revision = try #require(snapshot.notes.first { $0.birth == source }).revision.reference
    for fields in [UInt8(0), 8, 255] {
        #expect(throws: StorageError.staleCapture) {
            try CapturedActionGroup(snapshot: snapshot,
                intent: .historical(source: source, revision: revision, fields: .init(rawValue: fields)), changes: [change])
        }
    }
    #expect(await store.commitState.owned == nil)
    #expect(try await store.snapshot().through == snapshot.through)
    _ = try await put("valid companion", birth: source, generation: 2, session: store)
    try await store.quiesce()
}

@Test(arguments: [false, true])
func definitiveCaptureEncodingFailureReturnsInputWithoutBlockingSaves(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let snapshot = try await store.snapshot(), source = try reviewBirth(1)
    let invalid = try CapturedActionGroup(snapshot: snapshot, intent: .ordinary(.savedEdit),
        changes: [.put(.init(birth: source, generation: 1), testValue("wrong scope"))],
        scope: .note(reviewBirth(2)))
    guard case .pending(let handle, .integrity) = try await store.persist(capture: invalid) else {
        Issue.record("A definitively unencodable input must return its retry handle"); return
    }
    #expect(await store.commitState.owned == nil, "definitive encoding rejection returns ownership to the handle")
    #expect(try await store.snapshot().through == snapshot.through)
    guard case .pending(_, .integrity) = try await store.retry(commit: handle) else {
        Issue.record("Retry must preserve the rejected input's exact outcome"); return
    }
    #expect(await store.commitState.owned == nil)
    let saved = try await put("valid companion", birth: source, generation: 2, session: store)
    #expect(saved.sequence == snapshot.through + 1)
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.first { $0.birth == source }?.value.body.string == "valid companion")
    try await reopened.quiesce()
}
