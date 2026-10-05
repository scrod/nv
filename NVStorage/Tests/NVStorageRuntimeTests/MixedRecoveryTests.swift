import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Exercises rich actions and duplicate retention in one unpublished recovery suffix.
@Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func mixedOpeningRecoveryPreservesConnectedHistory(encrypted: Bool, failedInstall: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let writer = try await newSession(initial, protection), branch = try await newSession(initial, protection)
    let third = try await newSession(initial, protection)
    let receiver = try await newSession(initial, protection), lane = await receiver.lane, selection = await receiver.selection
    let source = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let fresh = try NoteBirth(bytes: Array(repeating: 3, count: 16))
    let extras = try [4, 5].map { try NoteBirth(bytes: Array(repeating: UInt8($0), count: 16)) }
    var saved: [(SegmentLocator, [UInt8])] = []
    func envelope(_ receipt: AcceptedHistoryReceipt, in store: LocalStoreSession) async throws -> (SegmentLocator, [UInt8]) {
        (receipt.object, try await store.retainedObject(at: receipt.object))
    }
    let left = try await put("Left", birth: source, generation: 1, session: writer)
    saved.append(try await envelope(left, in: writer))
    let right = try await put("Right", birth: source, generation: 1, session: branch)
    saved.append(try await envelope(right, in: branch))
    let other = try await put("Third", birth: source, generation: 1, session: third)
    saved.append(try await envelope(other, in: third))
    _ = try await writer.receive(saved[1].1)
    _ = try await writer.receive(saved[2].1)
    let leftRevision = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(saved[0].1,
        collection: initial.descriptor.collection, protection: protection).payload).operations[0].operation.id
    let rightRevision = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(saved[1].1,
        collection: initial.descriptor.collection, protection: protection).payload).operations[0].operation.id
    let thirdRevision = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(saved[2].1,
        collection: initial.descriptor.collection, protection: protection).payload).operations[0].operation.id
    let copy = try await writer.copyVersion(for: source, revision: rightRevision, generation: 2)
    let copyBirth = try #require(copy.covered.first).birth
    saved.append(try await envelope(requireReceipt(await writer.persist(capture: copy)), in: writer))
    let choice = try await writer.chooseVersion(for: source, revision: leftRevision, generation: 3)
    saved.append(try await envelope(requireReceipt(await writer.persist(capture: choice)), in: writer))
    for birth in [copyBirth, source] {
        let deletion = try await CapturedActionGroup(snapshot: writer.snapshot(), kind: .deleteBatch,
            changes: [.delete(.init(birth: birth, generation: 4))])
        saved.append(try await envelope(requireReceipt(await writer.persist(capture: deletion)), in: writer))
    }
    let entry = try #require(try await writer.history(for: .deletions).entries.first { $0.birth == source })
    let restore = try await writer.restoration(from: entry, as: .init(birth: fresh, generation: 5))
    let restoring = try await CapturedActionGroup(snapshot: writer.snapshot(), restoring: [restore])
    let restored = try await envelope(requireReceipt(await writer.persist(capture: restoring)), in: writer)
    saved.append(restored)
    #expect(try await writer.snapshot().notes.first { $0.birth == fresh }?.value.body.string == "Left")
    saved.append(try await envelope(put("restored edit", birth: fresh, generation: 6, session: writer), in: writer))
    let adding = try await CapturedActionGroup(snapshot: writer.snapshot(), kind: .createImportBatch,
        changes: extras.enumerated().map { try .create(.init(birth: $0.element, generation: 7), testValue("extra-\($0.offset)")) })
    saved.append(try await envelope(requireReceipt(await writer.persist(capture: adding)), in: writer))
    let removing = try await CapturedActionGroup(snapshot: writer.snapshot(), kind: .deleteBatch,
        changes: extras.map { try .delete(.init(birth: $0, generation: 8)) })
    saved.append(try await envelope(requireReceipt(await writer.persist(capture: removing)), in: writer))
    let repeatedPayload = try ObjectEnvelopeV1.open(restored.1, collection: initial.descriptor.collection, protection: protection).payload
    let duplicate = try ObjectEnvelopeV1.seal(payload: repeatedPayload, kind: .changes,
        collection: initial.descriptor.collection, writer: WriterEpoch(bytes: uuidBytes()), sequence: 0, protection: protection)
    let duplicateLocator = try ObjectEnvelopeV1.open(duplicate, collection: initial.descriptor.collection, protection: protection).locator
    saved.append((duplicateLocator, duplicate))
    _ = try await writer.receive(duplicate)
    try await receiver.saveEmptySettings(basedOn: receiver.settings())
    let privateBefore = try await lane.perform { try $0.rows("SELECT group_key,codec,generation,payload FROM private_groups ORDER BY group_key") }
    for (locator, bytes) in saved {
        _ = try await lane.acceptScheduled(bytes, locator: locator, selection: selection, protection: protection)
    }
    let acceptedBefore = try await lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") }
    let rowsBefore = try await lane.perform { try $0.rows("SELECT birth,cell FROM current_notes ORDER BY birth") }
    let viewBefore = try await lane.perform { try $0.rows("SELECT * FROM view_meta") }
    #expect(try await lane.perform { try $0.rows("SELECT through_seq FROM view_meta") } == [[.integer(1)]])
    if failedInstall {
        try await lane.perform { try $0.exec("CREATE TRIGGER fail_recovery_insert BEFORE INSERT ON current_notes BEGIN SELECT RAISE(ABORT,'injected current-row installation failure'); END") }
    }
    let expected = try await writer.snapshot()
    await lane.close()
    if failedInstall {
        for attempt in 0..<2 {
            await #expect(throws: StorageError.database(1811)) {
                try await LocalStoreSession.open(selection: selection, protection: protection)
            }
            let inspection = DatabaseLane()
            try await inspection.open(directory: selection.directory, create: false,
                key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
            try await inspection.perform { db in
                try db.validateHeader(store: selection.store, descriptor: selection.descriptor)
                #expect(try db.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") == acceptedBefore)
                #expect(try db.rows("SELECT birth,cell FROM current_notes ORDER BY birth") == rowsBefore)
                #expect(try db.rows("SELECT * FROM view_meta") == viewBefore)
                let groups = try db.rows("SELECT group_key,codec,generation,payload FROM private_groups ORDER BY group_key")
                #expect(try groups.filter { try !$0[0].bytes.starts(with: VerificationRecord.prefix) } == privateBefore)
                #expect(try groups.filter { try $0[0].bytes.starts(with: VerificationRecord.prefix) }.count == 1)
                if attempt == 1 { try db.exec("DROP TRIGGER fail_recovery_insert") }
            }
            await inspection.close()
        }
    }
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection, measuring: StorageWork())
    let reopenedLane = await reopened.lane, actual = try await reopened.snapshot()
    let openingWork = try await reopenedLane.perform { $0.work! }
    #expect(openingWork.stages.values.reduce(0) { $0 + $1.graphLoads } == (failedInstall ? 2 : 1))
    #expect(actual.notes == expected.notes && actual.context == expected.context && actual.through == expected.through)
    #expect(Dictionary(uniqueKeysWithValues: actual.notes.map { ($0.birth, $0.value.body.string) }) == [
        try NoteBirth(bytes: Array(repeating: 2, count: 16)): "untouched", fresh: "restored edit"])
    #expect(try await reopened.settings().generation == 2)
    #expect(try await reopenedLane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") } == acceptedBefore)
    #expect(try await reopenedLane.perform { try $0.rows("SELECT group_key,codec,generation,payload FROM private_groups ORDER BY group_key") } == privateBefore)
    let graph = try await reopenedLane.retainedGraph(through: actual.through, selection: selection, protection: protection)
    let state = try CollectionReductionV1.compute(collection: initial.descriptor.collection,
        operations: Array(graph.operations.values), actions: Array(graph.actions.values))
    let identity = try DeterministicConflictIdentityV1.recovery(ConflictRecoveryKeyV1.compute(source: source, body: testValue("Right").body), slot: 0)
    #expect(state.retired.contains(identity) && state.dispositions.contains(rightRevision))
    #expect(graph.operations[leftRevision]?.effect.noteValue?.body.string == "Left")
    #expect(graph.operations[rightRevision]?.effect.noteValue?.body.string == "Right")
    #expect(graph.operations[thirdRevision]?.effect.noteValue?.body.string == "Third")
    let sourceHistory = try await reopened.history(for: .note(source)).entries
    #expect(Set(sourceHistory.map(\.operation)).isSuperset(of: [leftRevision, rightRevision, thirdRevision]))
    #expect(try await reopened.history(for: .recentlyDeleted).entries.allSatisfy { $0.birth != source })
    let restoredEntry = try #require(try await reopened.history(for: .note(fresh)).entries.first { graph.actions[$0.action]?.kind == .restoreBatch })
    #expect(try await reopened.preview(restoredEntry).action.restorations.first?.sourceBirth == source)
    let undo = try await reopened.prepareCompensation(scope: .note(fresh), direction: .undo)
    guard case .automatic = undo else { Issue.record("The restored edit must remain eligible for ordinary Undo"); return }
    for (locator, bytes) in saved { #expect(try await reopened.retainedObject(at: locator) == bytes) }
    #expect(graph.actions.count == 2 + saved.count - 1)
    try await reopened.quiesce(); try await writer.quiesce(); try await branch.quiesce(); try await third.quiesce()
}
