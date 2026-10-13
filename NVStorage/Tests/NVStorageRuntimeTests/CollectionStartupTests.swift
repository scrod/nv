import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

func openedCollection(_ result: CollectionOpenOutcome) throws -> CollectionSession {
    guard case .opened(let owner) = result else { throw StorageError.incomplete }; return owner
}
func associatedSelection(_ fixture: RepositoryLocalFixture, repository: String) async throws -> LocalStoreSelection {
    let store = try await newSession(fixture.initial, fixture.protection), root = try await RepositoryRootSession.open(directory: repository)
    let selection = await store.selection
    let association = try await root.association(for: selection, id: .init(bytes: Array(repeating: 33, count: 16)))
    try await store.saveLocalAssociation(association, basedOn: store.localAssociation())
    await root.close(); try await store.quiesce()
    return selection
}
func publishCollection(_ owner: CollectionSession, generation: UInt64 = 0) async throws -> StoreSnapshot {
    try await owner.publish(owner.preparePublication(liveGeneration: generation), liveGeneration: generation) { $0 }
}
func collectionBodies(_ owner: CollectionSession) async throws -> [String] {
    try await publishCollection(owner).notes.map(\.value.body.string).sorted()
}

@Test func collectionStartupLiteralHealthDecisions() throws {
    let rows: [(StartupRepositoryHealth, Bool, Bool, StartupClassification)] = [
        (.pending, false, false, .ready), (.compatible, false, false, .ready),
        (.unavailable, false, false, .ready), (.foreign, false, false, .ready), (.repair, false, false, .ready),
        (.contention, false, false, .contention), (.contention, false, true, .contention),
        (.compatible, false, true, .wait), (.unavailable, false, true, .wait),
        (.pending, true, true, .editable), (.compatible, true, true, .editable),
        (.contention, true, true, .editable), (.repair, true, false, .editable)
    ]
    for (repository, published, absent, expected) in rows {
        #expect(classifyStartup(local: .ready, repository: repository, published: published, unreadAbsentLocally: absent) == expected)
        #expect(classifyStartup(local: .association, repository: repository, published: published, unreadAbsentLocally: absent) == .association)
    }
    let privateRows: [(StorageHealthCategory, StorageOpenPhase, StartupClassification)] = [
        (.entryUnavailable, .namespaceAndUnlock, .recovery(.privateState)),
        (.ownershipOrAccess, .namespaceAndUnlock, .recovery(.privateState)),
        (.contextMismatch, .headerAndPrivateGroups, .association),
        (.unsupportedFormat, .headerAndPrivateGroups, .recovery(.privateState)),
        (.unlockingOrDatabaseUnreadable, .namespaceAndUnlock, .recovery(.unlockOrInspectDatabase)),
        (.requiredStateIncomplete, .headerAndPrivateGroups, .recovery(.privateState)),
        (.requiredStateInvalid, .requiredHistory, .recovery(.requiredHistory)),
        (.requiredStateIncomplete, .requiredHistory, .recovery(.requiredHistory))
    ]
    for (category, phase, expected) in privateRows {
        let report = StorageHealthReport(directory: .init(kind: .directory, accessFailure: nil), database: nil,
            category: category, failure: .incomplete, phase: phase)
        for repository in [StartupRepositoryHealth.pending, .compatible, .contention, .unavailable] {
            #expect(classifyStartup(local: .failed(report), repository: repository, published: true, unreadAbsentLocally: true) == expected)
        }
    }
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupRequiresAssociationBeforeActualPublication(fixture: RepositoryLocalFixture) async throws {
    let store = try await newSession(fixture.initial, fixture.protection), selection = await store.selection
    try await store.quiesce()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection))
    guard case .recovery(let request) = await owner.decision() else { Issue.record("Missing association must require explicit selection"); return }
    #expect(request.kind == .association)
    await #expect(throws: StorageError.incomplete) { try await publishCollection(owner) }
    let path = try repositoryDirectory()
    try await owner.reopenRepository(at: URL(fileURLWithPath: path), descriptor: fixture.initial.descriptor)
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    #expect(await owner.pendingRepositoryRequest()?.kind == .automaticRepositoryRepair)
    let capture = try await owner.capture(kind: .savedEdit, changes: [.put(.init(birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1), testValue("integrated E"))])
    let saved = try requireReceipt(await owner.persist(capture))
    try await owner.close()
    let reopened = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection))
    #expect(try await collectionBodies(reopened) == ["integrated E", "untouched"])
    try await reopened.close()
    let independent = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await independent.retainedObject(at: saved.object).count > 156)
    #expect(try await independent.localAssociation().value?.scope.store == selection.store)
    try await independent.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupPublishesWhileRootAcquisitionIsHeld(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let gate = ImprovementGate()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(rootAcquired: { _ in await gate.hold() })))
    await gate.wait()
    #expect(try await collectionBodies(owner) == ["A", "untouched"], "A reached provider hold cannot gate healthy local publication")
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    await gate.release(); await owner.settleAcquisition()
    #expect(await owner.pendingRepositoryRequest()?.kind == .automaticRepositoryRepair)
    try await owner.close()
    let next = try await RepositoryRootSession.open(directory: path); await next.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupContentionAndFailureRemainScoped(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let contender = try await RepositoryRootSession.open(directory: path)
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection, repository: URL(fileURLWithPath: path)))
    await owner.settleAcquisition()
    guard case .contention = await owner.decision() else { Issue.record("Known root contention must remain explicit"); return }
    await #expect(throws: StorageError.incomplete) { try await publishCollection(owner) }
    await contender.close()
    try await owner.reopenRepository(at: URL(fileURLWithPath: path), descriptor: fixture.initial.descriptor)
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close()
    let offline = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path + "/absent")))
    await offline.settleAcquisition()
    #expect(try await collectionBodies(offline) == ["A", "untouched"])
    #expect(await offline.pendingProviderObject() == nil)
    try await offline.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupRejectsForeignAndStalePublication(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let otherSelection = try await associatedSelection(fixture, repository: path)
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection))
    let other = try openedCollection(await CollectionSession.open(selection: otherSelection, protection: fixture.protection))
    let prepared = try await owner.preparePublication(liveGeneration: 9)
    await #expect(throws: StorageError.wrongContext) { try await other.publish(prepared, liveGeneration: 9) { $0 } }
    await #expect(throws: StorageError.staleCapture) { try await owner.publish(prepared, liveGeneration: 10) { $0 } }
    await #expect(throws: StorageError.unsupported) { try await owner.publish(prepared, liveGeneration: 9) { _ -> Bool in throw StorageError.unsupported } }
    guard case .ready = await owner.decision() else { Issue.record("Throwing callback cannot mark startup editable"); return }
    try await owner.reopenRepository(at: URL(fileURLWithPath: path), descriptor: fixture.initial.descriptor)
    await #expect(throws: StorageError.wrongContext) { try await owner.publish(prepared, liveGeneration: 9) { $0 } }
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close(); try await other.close()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupPublicationReservationPreventsReassociation(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path), gate = ImprovementGate()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: nil, hooks: .init(beforePublication: { await gate.hold() })))
    let publishing = Task { try await publishCollection(owner) }
    await gate.wait()
    await #expect(throws: StorageError.busy) { try await owner.reopenRepository(at: URL(fileURLWithPath: path), descriptor: fixture.initial.descriptor) }
    await #expect(throws: StorageError.busy) { try await owner.close() }
    await gate.release()
    #expect(try await publishing.value.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await owner.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupRetryRetainsSameRootAndPreservesReplacement(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection, repository: URL(fileURLWithPath: path)))
    await owner.settleAcquisition()
    _ = try await publishCollection(owner)
    let moved = path + "-moved"
    try FileManager.default.moveItem(atPath: path, toPath: moved)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try Data([7, 8, 9]).write(to: URL(fileURLWithPath: path + "/foreign"))
    #expect(try await owner.retryRepository(at: URL(fileURLWithPath: path)) == .different)
    #expect(try await owner.retryRepository(at: URL(fileURLWithPath: moved)) == .same)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: moved) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: path) == ["foreign"])
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/foreign")) == Data([7, 8, 9]))
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupBindingFailureReadbackPreservesDurableState(fixture: RepositoryLocalFixture) async throws {
    let oldPath = try repositoryDirectory(), path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: oldPath)
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection, repository: nil,
        hooks: .init(afterBinding: { throw StorageError.database(10) })))
    await #expect(throws: StorageError.database(10)) {
        try await owner.reopenRepository(at: URL(fileURLWithPath: path), descriptor: fixture.initial.descriptor)
    }
    guard case .ready = await owner.decision() else { Issue.record("Independent readback already reconciled the committed binding"); return }
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close()
    let store = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let root = try await RepositoryRootSession.open(directory: path)
    #expect(try await root.matches(#require(await store.localAssociation().value)) == .same)
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    await root.close(); try await store.quiesce()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupReplacementAndForeignTargetPreserveHealthyPrivateHistory(fixture: RepositoryLocalFixture) async throws {
    let old = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: old)
    try FileManager.default.moveItem(atPath: old, toPath: old + ".original")
    try FileManager.default.createDirectory(atPath: old, withIntermediateDirectories: false)
    try Data([3, 2, 1]).write(to: URL(fileURLWithPath: old + "/NV Data"))
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: old)))
    await owner.settleAcquisition()
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    #expect(await owner.pendingRepositoryRequest()?.kind == .association)
    let capture = try await owner.capture(kind: .savedEdit,
        changes: [.put(.init(birth: .init(bytes: Array(repeating: 1, count: 16)), generation: 1), testValue("unpublished durable"))])
    let saved = try requireReceipt(await owner.persist(capture))
    await #expect(throws: StorageError.wrongContext) {
        try await owner.reopenRepository(at: URL(fileURLWithPath: old), descriptor: fixture.initial.descriptor)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: old + "/NV Data")) == Data([3, 2, 1]))
    try await owner.reopenRepository(at: URL(fileURLWithPath: old + ".original"), descriptor: fixture.initial.descriptor)
    #expect(try await collectionBodies(owner) == ["unpublished durable", "untouched"])
    try await owner.close()
    let independent = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await independent.retainedObject(at: saved.object).count > 156)
    #expect(try await independent.localAssociation().generation == 2)
    try await independent.quiesce()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupActualPrivateFailuresKeepTheirDiagnosticScope(fixture: RepositoryLocalFixture) async throws {
    for damaged in ["settings", "history", "view"] {
        let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
        let store = try await LocalStoreSession.open(selection: selection, protection: fixture.protection), lane = await store.lane
        try await lane.perform { db in
            switch damaged {
            case "settings": try db.run("DELETE FROM private_groups WHERE group_key=X'73657474696E6773'")
            case "history": try db.run("INSERT INTO private_groups VALUES(X'686973746F72792D64616D616765',1,1,X'')")
            default: try db.run("UPDATE current_notes SET cell=X'00'")
            }
        }
        try await store.quiesce()
        let outcome = await CollectionSession.open(selection: selection, protection: fixture.protection)
        if damaged == "view" {
            let owner = try openedCollection(outcome)
            #expect(try await collectionBodies(owner) == ["A", "untouched"])
            try await owner.close()
        } else {
            guard case .recovery = outcome else { Issue.record("A real required-state failure forbids editable opening"); return }
            #expect(outcome.recoveryRequest?.kind == .privateState)
        }
    }
}

@Test(arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func collectionStartupPassiveBindingChecksMovedAndReplacedCandidates(fixture: RepositoryLocalFixture, replace: Bool) async throws {
    let path = try repositoryDirectory(), moved = path + ".moved"
    let selection = try await associatedSelection(fixture, repository: path)
    try FileManager.default.moveItem(atPath: path, toPath: moved)
    if replace {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
        try Data([8, 9]).write(to: URL(fileURLWithPath: path + "/foreign"))
    }
    let store = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let association = try #require(await store.localAssociation().value)
    try await store.quiesce()
    let original = try await RepositoryRootSession.open(directory: moved)
    let continuity = try await original.matches(association)
    if !replace { #expect(continuity == .same) }
    await original.close()
    if replace {
        let replacement = try await RepositoryRootSession.open(directory: path)
        #expect(try await replacement.matches(association) == .different)
        await replacement.close()
    }
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: moved)))
    await owner.settleAcquisition()
    if continuity == .same {
        #expect(await owner.pendingRepositoryRequest()?.kind == .automaticRepositoryRepair)
    } else {
        #expect(replace, "A bookmark may select the replacement path; independent comparison still prevents adoption")
        #expect(await owner.pendingRepositoryRequest()?.kind == .association)
        try await owner.reopenRepository(at: URL(fileURLWithPath: moved), descriptor: selection.descriptor)
        #expect(await owner.pendingRepositoryRequest()?.kind == .automaticRepositoryRepair)
    }
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close()
    if replace { #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/foreign")) == Data([8, 9])) }
}
