import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Records repair batch metadata while gates admit local work between real installation turns.
private actor RepairBatchObservations {
    private(set) var paths: [[String]] = []
    private(set) var largestBytes = 0
    func record(_ batch: RepositoryPublicationBatch) -> Int {
        paths.append(batch.locators.map(\.relativePath))
        largestBytes = max(largestBytes, batch.encodedByteCount)
        return paths.count
    }
}

@Test(.timeLimit(.minutes(5)), arguments: [false, true], [64, 256, 1024])
func repositoryRepairGrowthYieldsToSavesAndKeepsCapturedCut(encrypted: Bool, actions: Int) async throws {
    let fixture = try await GrowthHistoryFixtures.shared.fixture(encrypted: encrypted, actions: actions)
    let source = try await fixture.openSender(), selection = await source.selection
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let association = try await root.association(for: selection, id: .init(bytes: uuidBytes()))
    try await source.saveLocalAssociation(association, basedOn: source.localAssociation())
    await root.close(); try await source.quiesce()
    let first = ImprovementGate(), second = ImprovementGate(), publication = ImprovementGate()
    let observations = RepairBatchObservations(), start = ContinuousClock.now
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(repairBatch: { batch in
            #expect(batch.through == Int64(actions + 1))
            switch await observations.record(batch) {
            case 1: await first.hold()
            case 2: await second.hold()
            default: break
            }
        }, transport: .init(publication: { _ in await publication.hold() }), measuring: StorageWork())))
    defer { Task { await first.release(); await second.release(); await publication.release(); try? await owner.close() } }
    await first.wait()
    #expect(try await collectionBodies(owner) == ["E\(actions)", "untouched"])
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let editStart = ContinuousClock.now
    let edit = try requireReceipt(await owner.persist(owner.capture(kind: .savedEdit,
        changes: [.put(.init(birth: birth, generation: 1), testValue("saved during repair"))])))
    let editTime = editStart.duration(to: .now)
    await first.release(); await second.wait()
    let deleteStart = ContinuousClock.now
    let deleted = try requireReceipt(await owner.persist(owner.capture(kind: .deleteBatch,
        changes: [.delete(.init(birth: birth, generation: 2))])))
    let deleteTime = deleteStart.duration(to: .now)
    await second.release(); await owner.settleRepositoryRepair()
    await publication.wait()
    let elapsed = start.duration(to: .now)
    let expected = fixture.initial.objects.map { (ImmutableRepositoryLocator.segment($0.key).relativePath, $0.value) }
        + [(ImmutableRepositoryLocator.descriptor(fixture.initial.descriptor).relativePath, fixture.initial.descriptor.encodedBytes)]
        + fixture.history.map { (ImmutableRepositoryLocator.segment($0.locator).relativePath, $0.bytes) }
    guard case .complete(let through, let count) = await owner.repositoryRepairStatus() else {
        Issue.record("Finite save interference must leave complete captured repair")
        await publication.release(); try await owner.close(); return
    }
    #expect(through == Int64(actions + 1) && count == expected.count)
    let batches = await observations.paths, largestBytes = await observations.largestBytes
    #expect(batches.count == (expected.count + 15) / 16)
    #expect(batches.map(\.count).max() == 16 && largestBytes <= 4 * 1024 * 1024)
    #expect(batches.flatMap { $0 }.sorted() == expected.map(\.0).sorted())
    for (relative, bytes) in expected {
        #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/" + relative)) == Data(bytes))
    }
    for receipt in [edit, deleted] {
        #expect(!FileManager.default.fileExists(atPath: path + "/" + ImmutableRepositoryLocator.segment(receipt.object).relativePath))
    }
    #expect(try await collectionBodies(owner) == ["untouched"])
    let work = try #require(await owner.startupMeasurements()), counts = Array(work.stages.values)
    #expect(counts.reduce(0) { $0 + $1.graphLoads + $1.ancestors } == 0)
    #expect(counts.map(\.largestPublicationObjects).max() == 16)
    print("REPAIR-GROWTH encrypted=\(encrypted) actions=\(actions) objects=\(count) batches=\(batches.count) maxBytes=\(largestBytes) repair=\(elapsed) edit=\(editTime) delete=\(deleteTime)")
    let closing = Task { try await owner.close() }
    while true { if case .transition = await owner.decision() { break }; await Task.yield() }
    await publication.release(); try await closing.value
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string) == ["untouched"])
    for receipt in [edit, deleted] {
        let bytes = try await reopened.retainedObject(at: receipt.object)
        #expect(try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection,
            protection: fixture.protection, expectedLocator: receipt.object).locator == receipt.object)
    }
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get(), ["descriptor-directory", "descriptor-symlink", "keys-file", "version-file"])
func repositoryRepairInitialWrongKindOffersSaveAs(fixture: RepositoryLocalFixture, kind: String) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let relative: String
    switch kind {
    case "keys-file": relative = RepositoryProtocolDirectory.keys.relativePath
    case "version-file": relative = RepositoryProtocolDirectory.version.relativePath
    default: relative = ImmutableRepositoryLocator.descriptor(selection.descriptor).relativePath
    }
    let occupied = path + "/" + relative, marker = Data("preserve occupied descriptor evidence".utf8)
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: occupied).deletingLastPathComponent(), withIntermediateDirectories: true)
    let retained: String
    switch kind {
    case "descriptor-directory":
        try FileManager.default.createDirectory(atPath: occupied, withIntermediateDirectories: false)
        retained = occupied + "/child"
    case "descriptor-symlink":
        retained = path + "/external-target"
        try FileManager.default.createSymbolicLink(atPath: occupied, withDestinationPath: retained)
    default: retained = occupied
    }
    try marker.write(to: URL(fileURLWithPath: retained))
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path)))
    await owner.settleAcquisition(); await owner.settleRepositoryRepair()
    #expect(await owner.pendingRepositoryRequest()?.kind == .preserveRepositoryCollision)
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    #expect(try await owner.retryRepository(at: URL(fileURLWithPath: path)) == .same)
    #expect(await owner.pendingRepositoryRequest()?.kind == .preserveRepositoryCollision, "Retry preserves the occupied-entry decision")
    #expect(try Data(contentsOf: URL(fileURLWithPath: retained)) == marker)
    #expect(await owner.pendingProviderObject() == nil)
    try await owner.close()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get(), ["file", "directory", "symlink"])
func repositoryRepairOccupiedDamageOffersSaveAsAndKeepsLocalEdits(fixture: RepositoryLocalFixture, kind: String) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let locator = try #require(fixture.initial.objects.keys.first)
    let relative = ImmutableRepositoryLocator.segment(locator).relativePath
    let occupied = path + "/" + relative, marker = Data("occupied source evidence".utf8)
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: occupied).deletingLastPathComponent(), withIntermediateDirectories: true)
    let retained: String
    switch kind {
    case "directory":
        try FileManager.default.createDirectory(atPath: occupied, withIntermediateDirectories: false)
        retained = occupied + "/child"
    case "symlink":
        retained = path + "/external-target"
        try FileManager.default.createSymbolicLink(atPath: occupied, withDestinationPath: retained)
    default: retained = occupied
    }
    try marker.write(to: URL(fileURLWithPath: retained))
    let originalIdentity = try FileManager.default.attributesOfItem(atPath: occupied)[.systemFileNumber] as? NSNumber
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path)))
    await owner.settleAcquisition(); await owner.settleRepositoryRepair()
    #expect(await owner.pendingRepositoryRequest()?.kind == .preserveRepositoryCollision)
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    let action = try await owner.capture(kind: .savedEdit,
        changes: [.put(.init(birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1), testValue("saved during collision"))])
    _ = try requireReceipt(await owner.persist(action))
    for _ in 0..<2 {
        #expect(try await owner.retryRepository(at: URL(fileURLWithPath: path)) == .same)
        await owner.settleRepositoryRepair()
        #expect(try Data(contentsOf: URL(fileURLWithPath: retained)) == marker)
        #expect(try FileManager.default.attributesOfItem(atPath: occupied)[.systemFileNumber] as? NSNumber == originalIdentity)
    }
    #expect(await owner.pendingProviderObject() == nil)
    try await owner.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["saved during collision", "untouched"])
    try await reopened.quiesce()
    let copy = try await RepositoryCopy.preserveAvailable(from: path, to: privateTempPath())
    if kind == "symlink" {
        #expect(copy.issues.contains { $0.path == relative })
    } else {
        let suffix = kind == "directory" ? "/child" : ""
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy.destination + "/" + relative + suffix)) == marker)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: retained)) == marker)
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairLatePublicationCollisionOffersSaveAs(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let seed = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let root = try await RepositoryRootSession.open(directory: path)
    guard case .complete = try await root.publish(seed.captureRepositoryPublication(), from: seed, using: root.permission()) else {
        throw StorageError.incomplete
    }
    await root.close(); try await seed.quiesce()
    let publication = ImprovementGate(), collision = ImprovementGate()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(transport: .init(
            publication: { _ in await publication.hold() },
            observation: { if case .paused(.file(.conflict)) = $0 { await collision.signal() } }))))
    await owner.settleAcquisition()
    _ = try await publishCollection(owner)
    await publication.wait()
    let locator = try #require(fixture.initial.objects.keys.first)
    let occupied = path + "/" + ImmutableRepositoryLocator.segment(locator).relativePath
    try Data([42]).write(to: URL(fileURLWithPath: occupied))
    await publication.release(); await collision.wait()
    #expect(await owner.pendingRepositoryRequest()?.kind == .preserveRepositoryCollision)
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    #expect(try Data(contentsOf: URL(fileURLWithPath: occupied)) == Data([42]))
    try await owner.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func repositoryRepairIntegratedActivationPreservesSourceAndReportsAmbiguity(fixture: RepositoryLocalFixture, failAfterInstall: Bool) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let store = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let shared = try await put("shared", birth: .init(bytes: .init(repeating: 1, count: 16)), generation: 1, session: store)
    let bytes = try await store.retainedObject(at: shared.object)
    let root = try await RepositoryRootSession.open(directory: path)
    guard case .complete = try await root.publish(store.captureRepositoryPublication(), from: store, using: root.permission()) else { throw StorageError.incomplete }
    await root.close()
    let privateEdit = try await put("unpublished", birth: .init(bytes: .init(repeating: 1, count: 16)), generation: 2, session: store)
    let association = try #require(await store.localAssociation().value)
    try await store.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(shared.object.segmentID.bytes)])
    }
    let evidence = try await store.preserveForRepair(to: privateTempPath())
    let original = try Data(contentsOf: URL(fileURLWithPath: selection.directory + "/Collection.sqlite"))
    let parent = try repositoryDirectory()
    let selected = try SelectedStoreRecordV1(association: association.id, store: selection.store, generation: .init(bytes: uuidBytes()))
    try Data(selected.encodedV1()).write(to: URL(fileURLWithPath: parent + "/Selected Store"))
    let selector = try await SelectedStoreOwner.open(directory: parent), before = try await selector.capture()
    if failAfterInstall { await selector.setFault { if $0 == .afterInstall { throw StorageError.database(10) } } }
    let outcome = try await CollectionSession.repairPrivateStore(primary: evidence, repository: URL(fileURLWithPath: path),
        to: privateTempPath(), protection: fixture.protection, using: selector, basedOn: before)
    let repairedSelection: LocalStoreSelection
    switch outcome {
    case .opened(let owner, let state):
        #expect(!failAfterInstall)
        repairedSelection = await owner.selection
        #expect(state.record?.store == repairedSelection.store)
        #expect(try await collectionBodies(owner) == ["unpublished", "untouched"])
        try await owner.close()
    case .activationPending(let replacement, .uncertain(let observed, let cause)):
        #expect(failAfterInstall && cause == .database(10))
        repairedSelection = replacement.selection
        #expect(observed?.store == repairedSelection.store)
        await selector.setFault { if $0 == .beforeDurability { throw StorageError.database(13) } }
        for _ in 0..<2 {
            guard case .uncertain(let stillSelected, let error) = try await replacement.resumeActivation(using: selector) else {
                Issue.record("Repeated barrier failure must retain ambiguous activation"); throw StorageError.incomplete
            }
            #expect(stillSelected == observed && error == .database(13))
        }
        await selector.setFault(nil)
        guard case .opened(let resumed, let finished) = try await CollectionSession.resumePrivateRepair(replacement,
            repository: URL(fileURLWithPath: path), using: selector) else {
            Issue.record("A retained activation must finish its exact barriers"); throw StorageError.incomplete
        }
        #expect(finished.record == observed)
        #expect(try await collectionBodies(resumed) == ["unpublished", "untouched"])
        try await resumed.close()
    default: Issue.record("Integrated repair misclassified verified selection outcome"); throw StorageError.incomplete
    }
    let reopened = try await LocalStoreSession.open(selection: repairedSelection, protection: fixture.protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["unpublished", "untouched"])
    #expect(try await reopened.retainedObject(at: shared.object) == bytes)
    #expect(try await !reopened.retainedObject(at: privateEdit.object).isEmpty)
    try await reopened.quiesce()
    #expect(try Data(contentsOf: URL(fileURLWithPath: selection.directory + "/Collection.sqlite")) == original)
    let independent = try SelectedStoreRecordV1.decodeV1(Array(Data(contentsOf: URL(fileURLWithPath: parent + "/Selected Store"))))
    #expect(independent.store == repairedSelection.store && independent.association == association.id)
    let released = try await RepositoryRootSession.open(directory: path); await released.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairIntegratedBusyPreservationRetainsAdmission(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let store = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let root = try await RepositoryRootSession.open(directory: path)
    let owner = try await CollectionSession.bindRepaired(store, root: root)
    await owner.settleRepositoryRepair()
    let through = try await store.snapshot().through
    try await store.reserveActivation(through: through)
    await #expect(throws: StorageError.busy) { try await owner.preserveForPrivateRepair(to: privateTempPath()) }
    await store.settleActivation()
    let remainsOpen: Bool
    switch await owner.decision() { case .ready, .editable: remainsOpen = true; default: remainsOpen = false }
    #expect(remainsOpen)
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    await owner.settleRepositoryRepair()
    await store.waitForRepairTestReceive()
    let evidence = try await owner.preserveForPrivateRepair(to: privateTempPath())
    #expect(evidence.selection.store == selection.store)
    guard case .closed = await owner.decision() else { throw StorageError.incomplete }
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func repositoryRepairConnectedActivationNamespaceRace(fixture: RepositoryLocalFixture, foreign: Bool) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let source = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let settings = try CollectionSettingsV1([.secureTextEntry(true), .confirmFileDeletion(false)])
    try await source.saveCollectionSettings(settings, basedOn: source.collectionSettings())
    let item = try PendingItemID(bytes: uuidBytes())
    func input(_ body: String) throws -> PendingSnapshotV1 {
        try .init(id: .init(bytes: uuidBytes()),
            scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
            presence: .present, path: .init(bytes: Array("external.txt".utf8)), observation: .init(codec: 1, bytes: [42]),
            source: Array(body.utf8), value: testValue(body))
    }
    let frozen = try input("frozen private choice"), latest = try input("latest private preview")
    try await source.retainPendingSnapshot(frozen, basedOn: source.pendingItem(item))
    let pending = try await source.preparePendingImport(basedOn: source.pendingItem(item), automatic: false)
    try await source.retainPendingSnapshot(latest, basedOn: source.pendingItem(item))
    let shared = try await put("shared before damage", birth: birth, generation: 1, session: source)
    let root = try await RepositoryRootSession.open(directory: path)
    guard case .complete = try await root.publish(source.captureRepositoryPublication(), from: source, using: root.permission()) else {
        throw StorageError.incomplete
    }
    await root.close()
    let missing = try #require(fixture.initial.objects.keys.first)
    try FileManager.default.moveItem(atPath: path + "/" + ImmutableRepositoryLocator.segment(missing).relativePath,
        toPath: path + "/preserved-provider-object")
    _ = try await put("unpublished before repair", birth: birth, generation: 2, session: source)
    let inventory = try await source.lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    let association = try #require(await source.localAssociation().value)
    try await source.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(shared.object.segmentID.bytes)])
    }
    let evidence = try await source.preserveForRepair(to: privateTempPath())
    let original = try Data(contentsOf: URL(fileURLWithPath: selection.directory + "/Collection.sqlite"))
    let selectedDirectory = try repositoryDirectory()
    let selected = try SelectedStoreRecordV1(association: association.id, store: selection.store, generation: .init(bytes: uuidBytes()))
    let selectedURL = URL(fileURLWithPath: selectedDirectory + "/Selected Store")
    try Data(selected.encodedV1()).write(to: selectedURL)
    let selector = try await SelectedStoreOwner.open(directory: selectedDirectory)
    guard case .opened(let repaired, let activation) = try await CollectionSession.repairPrivateStore(primary: evidence,
        repository: URL(fileURLWithPath: path), to: privateTempPath(), protection: fixture.protection,
        using: selector, basedOn: selector.capture()) else { throw StorageError.incomplete }
    let candidate = await repaired.selection
    try await repaired.close()
    #expect(activation.record?.store == candidate.store)
    let activatedBytes = try Data(contentsOf: selectedURL)
    // A later provider loss requires restoration from the newly selected private store.
    try FileManager.default.moveItem(atPath: path + "/NV Data", toPath: path + "/preserved-NV-Data")
    let prepared = ImprovementGate(), idle = ImprovementGate()
    let owner = try openedCollection(await CollectionSession.open(selection: candidate, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(
            repairPrepared: { _ in await prepared.hold() },
            transport: .init(observation: { if case .idle = $0 { await idle.signal() } }))))
    await prepared.wait()
    defer { Task { await prepared.release() } }
    #expect(try await collectionBodies(owner) == ["unpublished before repair", "untouched"])
    let action = try await owner.capture(kind: .savedEdit,
        changes: [.put(.init(birth: birth, generation: 3), testValue("saved during restored repair"))])
    let saved = try requireReceipt(await owner.persist(action))
    let descriptorPath = path + "/" + ImmutableRepositoryLocator.descriptor(selection.descriptor).relativePath
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: descriptorPath).deletingLastPathComponent(), withIntermediateDirectories: true)
    let contender: Data
    if foreign {
        let other = try InitialCollectionV1.build(collection: .init(bytes: .init(repeating: 9, count: 16)),
            notes: [], protection: .publicHash)
        contender = Data(other.descriptor.encodedBytes)
    } else { contender = Data(selection.descriptor.encodedBytes) }
    try contender.write(to: URL(fileURLWithPath: descriptorPath))
    await prepared.release(); await owner.settleRepositoryRepair()
    guard case .paused(.root(.unavailable(EEXIST))) = await owner.repositoryRepairStatus() else {
        Issue.record("The independently created namespace must stop the captured absent-name repair")
        try await owner.close(); return
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: descriptorPath)) == contender)
    #expect(try Data(contentsOf: selectedURL) == activatedBytes)
    #expect(try await collectionBodies(owner) == ["saved during restored repair", "untouched"])
    #expect(try await owner.retryRepository(at: URL(fileURLWithPath: path)) == .same)
    if foreign {
        #expect(await owner.pendingRepositoryRequest()?.kind == .preserveRepositoryCollision)
        #expect(try Data(contentsOf: URL(fileURLWithPath: descriptorPath)) == contender)
    } else {
        await idle.wait()
        #expect(await owner.pendingRepositoryRequest() == nil)
        for row in inventory {
            let bytes = try row[1].bytes
            if bytes == selection.descriptor.encodedBytes { continue }
            let envelope = try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: fixture.protection)
            let installed = path + "/" + ImmutableRepositoryLocator.segment(envelope.locator).relativePath
            #expect(try Data(contentsOf: URL(fileURLWithPath: installed)) == Data(bytes))
        }
        #expect(FileManager.default.fileExists(atPath: path + "/" + ImmutableRepositoryLocator.segment(saved.object).relativePath))
    }
    try await owner.close()
    let reopened = try await LocalStoreSession.open(selection: candidate, protection: fixture.protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["saved during restored repair", "untouched"])
    let actual = try await reopened.lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    for row in inventory { #expect(actual.contains(row)) }
    #expect(actual.count == inventory.count + 1)
    #expect(try await reopened.collectionSettings().value == settings)
    #expect(try await reopened.pendingItem(item).latest == latest.id)
    #expect(try await reopened.retainedPendingSnapshot(frozen.id) == frozen)
    #expect(try await reopened.retainedPendingSnapshot(latest.id) == latest)
    guard case .review(let retained) = try #require(await reopened.pendingRecovery(item).first) else { throw StorageError.incomplete }
    #expect(retained == pending.reservation)
    try await reopened.quiesce()
    #expect(try Data(contentsOf: URL(fileURLWithPath: selection.directory + "/Collection.sqlite")) == original)
    #expect(try Data(contentsOf: selectedURL) == activatedBytes)
}

private extension LocalStoreSession {
    /// Waits for the publication-triggered receive owner to settle before the next preservation attempt.
    func waitForRepairTestReceive() async {
        while receiving { await withCheckedContinuation { drained.append($0) } }
    }
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairIntegratedPreservationClosesOldAdmission(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection))
    _ = try await publishCollection(owner)
    let action = try await owner.capture(kind: .savedEdit,
        changes: [.put(.init(birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1), testValue("saved before preservation"))])
    _ = try requireReceipt(await owner.persist(action))
    let preserved = try await owner.preserveForPrivateRepair(to: privateTempPath())
    guard case .closed = await owner.decision() else { throw StorageError.incomplete }
    await #expect(throws: StorageError.closed) { try await owner.persist(action) }
    let replacement = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: preserved, protection: fixture.protection)
    try await replacement.close()
    let independent = try await LocalStoreSession.open(selection: replacement.selection, protection: fixture.protection)
    #expect(try await independent.snapshot().notes.map(\.value.body.string).sorted() == ["saved before preservation", "untouched"])
    try await independent.quiesce()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairComplementsPrivateLossWithoutLosingUnpublishedWork(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let store = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let shared = try await put("shared", birth: birth, generation: 1, session: store)
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let batch = try await store.captureRepositoryPublication()
    guard case .complete = try await root.publish(batch, from: store, using: permission) else { throw StorageError.incomplete }
    let unpublished = try await put("private newer", birth: birth, generation: 2, session: store)
    let unpublishedBytes = try await store.retainedObject(at: unpublished.object)
    let sharedBytes = try await store.retainedObject(at: shared.object)
    let settings = try CollectionSettingsV1([.confirmFileDeletion(false)])
    try await store.saveCollectionSettings(settings, basedOn: store.collectionSettings())
    let item = try PendingItemID(bytes: uuidBytes())
    let pending = try PendingSnapshotV1(id: .init(bytes: uuidBytes()),
        scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
        presence: .present, path: .init(bytes: Array("external.txt".utf8)), observation: .init(codec: 1, bytes: [42]),
        source: Array("only private pending".utf8), value: testValue("only private pending"))
    try await store.retainPendingSnapshot(pending, basedOn: store.pendingItem(item))
    try await store.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(shared.object.segmentID.bytes)])
    }
    let evidence = try await store.preserveForRepair(to: privateTempPath())
    #expect(evidence.unavailableCommittedObjects == [shared.object.segmentID.bytes])
    let source = try await root.repairSource(for: fixture.initial.descriptor)
    let restored = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence,
        repositories: [source], protection: fixture.protection)
    #expect(await root.listingResourceCount() == 0)
    try await restored.close()
    let opened = try await LocalStoreSession.open(selection: restored.selection, protection: fixture.protection)
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["private newer", "untouched"])
    #expect(try await opened.retainedObject(at: shared.object) == sharedBytes)
    #expect(try await opened.retainedObject(at: unpublished.object) == unpublishedBytes)
    #expect(try await opened.collectionSettings().value == settings)
    #expect(try await opened.retainedPendingSnapshot(pending.id) == pending)
    #expect(try await opened.pendingItem(item).latest == pending.id)
    #expect(!FileManager.default.fileExists(atPath: path + "/" + ImmutableRepositoryLocator.segment(unpublished.object).relativePath))
    try await opened.quiesce()
    await root.invalidate()
    await #expect(throws: RepositoryRootError.stalePermission) {
        try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence,
            repositories: [source], protection: fixture.protection)
    }
    await root.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get(), ["intact", "changed", "missing", "permission", "cancelled"])
func repositoryRepairRechecksCapturedSource(fixture: RepositoryLocalFixture, change: String) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let store = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let edit = try await put("repository-only repair input", birth: birth, generation: 1, session: store)
    let bytes = try await store.retainedObject(at: edit.object)
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    guard case .complete = try await root.publish(store.captureRepositoryPublication(), from: store, using: permission) else {
        throw StorageError.incomplete
    }
    try await store.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(edit.object.segmentID.bytes)])
    }
    let evidence = try await store.preserveForRepair(to: privateTempPath())
    #expect(evidence.unavailableCommittedObjects == [edit.object.segmentID.bytes])
    let source = try await root.repairSource(for: fixture.initial.descriptor)
    let url = URL(fileURLWithPath: path + "/" + ImmutableRepositoryLocator.segment(edit.object).relativePath)
    let gate = ImprovementGate()
    let attempt = Task {
        try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence,
            repositories: [source], protection: fixture.protection, work: .init(prepared: { await gate.hold() }))
    }
    await gate.wait()
    switch change {
    case "changed":
        var damaged = bytes; damaged[damaged.count - 1] ^= 1
        try Data(damaged).write(to: url)
    case "missing": try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("preserved"))
    case "permission": await root.invalidate()
    case "cancelled": attempt.cancel()
    default: break
    }
    await gate.release()
    if change == "intact" {
        let result = try await attempt.value
        try await result.close()
        let reopened = try await LocalStoreSession.open(selection: result.selection, protection: fixture.protection)
        #expect(try await reopened.retainedObject(at: edit.object) == bytes)
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["repository-only repair input", "untouched"])
        try await reopened.quiesce()
    } else {
        do {
            let result = try await attempt.value
            try await result.close()
            Issue.record("Changed or revoked repair source issued activation evidence")
        } catch {
            switch change {
            case "changed": #expect(error is CanonicalEncodingError)
            case "missing": #expect(error as? RepositoryRepairSourceError == .unavailable(path: ImmutableRepositoryLocator.segment(edit.object).relativePath, reason: .absent))
            case "permission": #expect(error as? RepositoryRootError == .stalePermission)
            case "cancelled": #expect(error is CancellationError)
            default: Issue.record("Unexpected repair case")
            }
        }
    }
    #expect(await root.listingResourceCount() == 0)
    await root.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairRejectsMisnamedComplementAndMissingClosure(fixture: RepositoryLocalFixture) async throws {
    let store = try await newSession(fixture.initial, fixture.protection)
    let lost = try await put("missing", birth: .init(bytes: .init(repeating: 1, count: 16)), generation: 1, session: store)
    let bytes = try await store.retainedObject(at: lost.object)
    try await store.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([1]), .blob(lost.object.segmentID.bytes)])
    }
    let evidence = try await store.preserveForRepair(to: privateTempPath())
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let source = try await root.repairSource(for: fixture.initial.descriptor), destination = privateTempPath()
    await #expect(throws: StorageError.incomplete) {
        try await LocalStoreSession.buildVerifiedReplacement(to: destination, primary: evidence,
            repositories: [source], protection: fixture.protection)
    }
    #expect(!FileManager.default.fileExists(atPath: destination))
    let wrong = try SegmentLocator(writerEpoch: .init(bytes: uuidBytes()), sequence: lost.object.sequence, segmentID: lost.object.segmentID)
    let file = path + "/" + ImmutableRepositoryLocator.segment(wrong).relativePath
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: file).deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: URL(fileURLWithPath: file))
    await #expect(throws: StorageError.integrity) {
        try await LocalStoreSession.buildVerifiedReplacement(to: destination, primary: evidence,
            repositories: [source], protection: fixture.protection)
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data(bytes))
    #expect(!FileManager.default.fileExists(atPath: destination))
    #expect(await root.listingResourceCount() == 0)
    await root.close()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairRespondsToLateDiscoveryWithoutAnotherEvent(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let seed = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let batch = try await seed.captureRepositoryPublication()
    guard case .complete = try await root.publish(batch, from: seed, using: permission) else { throw StorageError.incomplete }
    await root.close(); try await seed.quiesce()
    let discovery = ImprovementGate(), repair = ImprovementGate()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(repairPrepared: { _ in await repair.hold() },
            transport: .init(discovery: .init(observed: { _ in await discovery.hold() })))))
    await owner.settleAcquisition()
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    await discovery.wait()
    try FileManager.default.moveItem(atPath: path + "/NV Data", toPath: path + "/preserved")
    await discovery.release(); await repair.wait()
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    await repair.release(); await owner.settleRepositoryRepair()
    guard case .complete = await owner.repositoryRepairStatus() else { throw StorageError.incomplete }
    for (locator, bytes) in fixture.initial.objects {
        #expect(try Array(Data(contentsOf: URL(fileURLWithPath: path + "/" + ImmutableRepositoryLocator.segment(locator).relativePath))) == bytes)
    }
    try await owner.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairContinuesAfterDamagedComplementWithExplicitReport(fixture: RepositoryLocalFixture) async throws {
    let store = try await newSession(fixture.initial, fixture.protection)
    let lost = try await put("recovered from second source", birth: .init(bytes: .init(repeating: 1, count: 16)), generation: 1, session: store)
    let bytes = try await store.retainedObject(at: lost.object)
    try await store.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(lost.object.segmentID.bytes)])
    }
    let evidence = try await store.preserveForRepair(to: privateTempPath())
    let first = try repositoryDirectory(), second = try repositoryDirectory()
    let relative = ImmutableRepositoryLocator.segment(lost.object).relativePath
    for (directory, contents) in [(first, [UInt8](repeating: 42, count: 160)), (second, bytes)] {
        let target = URL(fileURLWithPath: directory + "/" + relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents).write(to: target)
    }
    let bad = try await RepositoryRootSession.open(directory: first), good = try await RepositoryRootSession.open(directory: second)
    let sources = try await [bad.repairSource(for: fixture.initial.descriptor), good.repairSource(for: fixture.initial.descriptor)]
    let rebuilt = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence,
        repositories: sources, protection: fixture.protection)
    #expect(rebuilt.repositoryIssues.count == 1)
    #expect(rebuilt.repositoryIssues.first?.sourceIndex == 0 && rebuilt.repositoryIssues.first?.path == relative)
    #expect(await bad.listingResourceCount() == 0)
    #expect(await good.listingResourceCount() == 0)
    try await rebuilt.close()
    let opened = try await LocalStoreSession.open(selection: rebuilt.selection, protection: fixture.protection)
    #expect(try await opened.retainedObject(at: lost.object) == bytes)
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["recovered from second source", "untouched"])
    try await opened.quiesce()
    #expect(try Data(contentsOf: URL(fileURLWithPath: first + "/" + relative)) == Data(repeating: 42, count: 160))
    #expect(try Data(contentsOf: URL(fileURLWithPath: second + "/" + relative)) == Data(bytes))
    await bad.close(); await good.close()
}

enum ComplementarySourceCondition: CaseIterable, Equatable, Sendable {
    case healthy, inaccessibleHierarchy, occupiedHierarchy, unreadableObject, unrelatedDamage
}

@Test(.timeLimit(.minutes(2)), arguments: try RepositoryLocalFixture.prepared.get(),
      ComplementarySourceCondition.allCases.flatMap { condition in [false, true].map { (condition, $0) } })
func repositoryRepairReportsSourceAccessAndRequiresCompleteUnion(fixture: RepositoryLocalFixture,
    scenario: (ComplementarySourceCondition, Bool)) async throws {
    let (condition, hasComplement) = scenario
    let store = try await newSession(fixture.initial, fixture.protection)
    let lost = try await put("exact complementary action", birth: .init(bytes: .init(repeating: 1, count: 16)), generation: 1, session: store)
    let bytes = try await store.retainedObject(at: lost.object)
    try await store.lane.perform { db in
        try db.exec("DROP TRIGGER objects_no_update")
        try db.run("UPDATE objects SET encoded=? WHERE object_id=?", [.blob([0]), .blob(lost.object.segmentID.bytes)])
    }
    let evidence = try await store.preserveForRepair(to: privateTempPath())
    #expect(evidence.unavailableCommittedObjects == [lost.object.segmentID.bytes])
    let first = try repositoryDirectory(), second = try repositoryDirectory()
    let relative = ImmutableRepositoryLocator.segment(lost.object).relativePath
    for directory in [first, second] {
        let file = URL(fileURLWithPath: directory + "/" + relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: file)
    }
    let bad = try await RepositoryRootSession.open(directory: first), good = try await RepositoryRootSession.open(directory: second)
    let selected = try await [bad.repairSource(for: fixture.initial.descriptor), good.repairSource(for: fixture.initial.descriptor)]
    let version = first + "/" + RepositoryProtocolDirectory.version.relativePath
    let file = first + "/" + relative
    var inaccessible: String?
    var extra: URL?
    defer { if let inaccessible { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inaccessible) } }
    let expectedPaths: [String], expectedFailure: RepositoryFileFailure?
    let preservedMarker = Data("preserved occupied hierarchy".utf8)
    switch condition {
    case .healthy, .unrelatedDamage:
        expectedPaths = []; expectedFailure = nil
        if condition == .unrelatedDamage {
            let unrelated = try SegmentLocator(writerEpoch: lost.object.writerEpoch, sequence: lost.object.sequence + 1,
                segmentID: .init(bytes: .init(repeating: 0xab, count: 32)))
            let path = URL(fileURLWithPath: first + "/" + ImmutableRepositoryLocator.segment(unrelated).relativePath)
            try preservedMarker.write(to: path); extra = path
        }
    case .inaccessibleHierarchy:
        expectedPaths = [RepositoryProtocolDirectory.keys.relativePath, RepositoryProtocolDirectory.segments.relativePath]
        expectedFailure = .io(EACCES)
        inaccessible = version
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: version)
    case .occupiedHierarchy:
        expectedPaths = [RepositoryProtocolDirectory.keys.relativePath, RepositoryProtocolDirectory.segments.relativePath]
        expectedFailure = .kindCollision
        try FileManager.default.moveItem(atPath: version, toPath: first + "/preserved-version")
        try preservedMarker.write(to: URL(fileURLWithPath: version))
    case .unreadableObject:
        expectedPaths = [relative]; expectedFailure = .io(EACCES)
        inaccessible = file
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file)
    }
    let destination = privateTempPath(), sources = hasComplement ? selected : Array(selected.prefix(1))
    if let expectedFailure, !hasComplement {
        await #expect(throws: RepositoryRepairSourceError.unavailable(path: expectedPaths[0], reason: expectedFailure)) {
            try await LocalStoreSession.buildVerifiedReplacement(to: destination, primary: evidence,
                repositories: sources, protection: fixture.protection)
        }
        #expect(!FileManager.default.fileExists(atPath: destination), "Incomplete required history cannot initialize a candidate")
    } else {
        let rebuilt = try await LocalStoreSession.buildVerifiedReplacement(to: destination, primary: evidence,
            repositories: sources, protection: fixture.protection)
        #expect(rebuilt.repositoryIssues.map(\.path).sorted() == expectedPaths.sorted())
        #expect(rebuilt.repositoryIssues.allSatisfy { $0.sourceIndex == 0 && $0.failure == expectedFailure.map(RepositoryTransportFailure.file) })
        try await rebuilt.close()
        let reopened = try await LocalStoreSession.open(selection: rebuilt.selection, protection: fixture.protection)
        #expect(try await reopened.retainedObject(at: lost.object) == bytes)
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["exact complementary action", "untouched"])
        try await reopened.quiesce()
    }
    #expect(await bad.listingResourceCount() == 0)
    #expect(await good.listingResourceCount() == 0)
    if let inaccessible {
        let permissions = try FileManager.default.attributesOfItem(atPath: inaccessible)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0, "Repair preserves the source permissions")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inaccessible)
    }
    if condition == .occupiedHierarchy {
        #expect(try Data(contentsOf: URL(fileURLWithPath: version)) == preservedMarker)
        let suffix = String(relative.dropFirst(RepositoryProtocolDirectory.version.relativePath.count))
        #expect(try Data(contentsOf: URL(fileURLWithPath: first + "/preserved-version" + suffix)) == Data(bytes))
    } else {
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data(bytes))
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: second + "/" + relative)) == Data(bytes))
    if let extra { #expect(try Data(contentsOf: extra) == preservedMarker) }
    await bad.close(); await good.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func repositoryRepairReaderKeepsLostPermissionTerminal(fixture: RepositoryLocalFixture, close: Bool) async throws {
    let directory = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: directory)
    let source = try await root.repairSource(for: fixture.initial.descriptor)
    let reader = try RepositoryRepairReader(source: source, descriptor: fixture.initial.descriptor,
        protection: fixture.protection, missing: [fixture.initial.snapshot.segmentID.bytes])
    if close { await root.close() } else { await root.invalidate() }
    await #expect(throws: RepositoryRootError.stalePermission) { try await reader.next() }
    #expect(await reader.issues.isEmpty)
    try await reader.close()
    #expect(await root.listingResourceCount() == 0)
    await root.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func repositoryRepairReaderPreservesCancellationAfterListing(fixture: RepositoryLocalFixture, exhausted: Bool) async throws {
    let root = try await RepositoryRootSession.open(directory: repositoryDirectory())
    let source = try await root.repairSource(for: fixture.initial.descriptor)
    let reader = try RepositoryRepairReader(source: source, descriptor: fixture.initial.descriptor,
        protection: fixture.protection, missing: [fixture.initial.snapshot.segmentID.bytes])
    if exhausted { #expect(try await reader.next() == nil) }
    let entered = ImprovementGate()
    let cancelled = Task { await entered.hold(); return try await reader.next() }
    await entered.wait(); cancelled.cancel(); await entered.release()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await reader.issues.isEmpty)
    try await reader.close()
    #expect(await root.listingResourceCount() == 0)
    await root.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairNamespaceRejectsWrongOwnerAndStaleAttempt(fixture: RepositoryLocalFixture) async throws {
    let a = try await RepositoryRootSession.open(directory: repositoryDirectory())
    let b = try await RepositoryRootSession.open(directory: repositoryDirectory())
    let permission = try await a.permission(), other = try await b.permission()
    await #expect(throws: RepositoryRootError.wrongContext) { try await b.createRepairNamespace(using: permission) }
    let held = try await a.createRepairNamespace(using: permission)
    await #expect(throws: RepositoryRootError.wrongContext) { try await b.endRepairNamespace(held) }
    await #expect(throws: RepositoryRootError.busy) { try await a.createRepairNamespace(using: permission) }
    let otherHeld = try await b.createRepairNamespace(using: other)
    try await a.endRepairNamespace(held)
    await #expect(throws: RepositoryRootError.wrongContext) { try await a.endRepairNamespace(held) }
    try await b.endRepairNamespace(otherHeld)
    await a.close(); await b.close()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairClosePreservesPartialOutputForFreshRetry(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let gate = ImprovementGate()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(repairBatch: { _ in await gate.hold() })))
    await gate.wait()
    let closing = Task { try await owner.close() }
    while true {
        if case .transition = await owner.decision() { break }
        await Task.yield()
    }
    await gate.release(); try await closing.value
    #expect(try FileManager.default.contentsOfDirectory(atPath: path + "/NV Data").isEmpty)
    let reopened = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path)))
    await reopened.settleAcquisition(); await reopened.settleRepositoryRepair()
    guard case .complete = await reopened.repositoryRepairStatus() else { throw StorageError.incomplete }
    #expect(try await collectionBodies(reopened) == ["A", "untouched"])
    try await reopened.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairChecksWholePrefixAndRetainsNewerWork(fixture: RepositoryLocalFixture) async throws {
    let source = try await newSession(fixture.initial, fixture.protection)
    let checked = try await source.prepareRepositoryRepair(maximumObjects: 1)
    #expect(checked.through == 1)
    #expect(checked.objectCount == fixture.initial.objects.count + 1)
    let saved = try await put("newer than repair", birth: .init(bytes: .init(repeating: 1, count: 16)), generation: 1, session: source)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission()
    var cursor: RepositoryPublicationCursor?, bytes = Set<[UInt8]>(), ids = Set<String>()
    repeat {
        let batch = try await source.captureRepositoryRepair(checked, continuing: cursor, maximumObjects: 1)
        #expect(batch.through == 1 && batch.locators.count == 1)
        guard case .complete = try await root.publish(batch, from: source, using: permission) else { throw StorageError.incomplete }
        for locator in batch.locators {
            ids.insert(locator.relativePath)
            bytes.insert(try Array(Data(contentsOf: URL(fileURLWithPath: path + "/" + locator.relativePath))))
        }
        cursor = batch.continuation
    } while cursor != nil
    #expect(bytes == Set(Array(fixture.initial.objects.values) + [fixture.initial.descriptor.encodedBytes]))
    #expect(!ids.contains(ImmutableRepositoryLocator.segment(saved.object).relativePath))
    let other = try await newSession(fixture.initial, fixture.protection)
    await #expect(throws: StorageError.wrongContext) { try await other.captureRepositoryRepair(checked) }
    let selection = await source.selection
    try await source.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.captureRepositoryRepair(checked) }
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["newer than repair", "untouched"])
    try await reopened.quiesce(); try await other.quiesce(); await root.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairRejectsMissingLastObjectBeforeIssuingCoverage(fixture: RepositoryLocalFixture) async throws {
    let source = try await newSession(fixture.initial, fixture.protection), lane = await source.lane
    _ = try await source.prepareRepositoryRepair(maximumObjects: 1)
    let lost = try await lane.perform { db in
        let id = try db.rows("SELECT object_id FROM accepted_objects WHERE object_id<>? ORDER BY seq DESC,object_id DESC LIMIT 1",
            [.blob(fixture.initial.descriptor.descriptorID)])[0][0].bytes
        try db.run("PRAGMA foreign_keys=OFF")
        try db.run("DELETE FROM objects WHERE object_id=?", [.blob(id)])
        try db.run("PRAGMA foreign_keys=ON")
        return id
    }
    await #expect(throws: StorageError.integrity) { try await source.prepareRepositoryRepair(maximumObjects: 1) }
    let selection = await source.selection
    try await source.quiesce()
    let inspection = DatabaseLane()
    try await inspection.open(directory: selection.directory, create: false,
        key: PrivateDatabaseKeyV1.derive(collection: fixture.initial.descriptor.collection, protection: fixture.protection))
    #expect(try await inspection.perform { try $0.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(lost)]) } == [[.integer(1)]])
    #expect(try await inspection.perform { try $0.rows("SELECT payload FROM private_groups WHERE group_key=?",
        [.blob(Array("history-damage".utf8))]) } == [[.blob([])]])
    await inspection.close()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairAutomaticallyRestoresWithoutBlockingLocalSave(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let gate = ImprovementGate()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(repairPrepared: { _ in await gate.hold() })))
    await gate.wait()
    #expect(!FileManager.default.fileExists(atPath: path + "/NV Data"))
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    let capture = try await owner.capture(kind: .savedEdit, changes: [.put(.init(birth: .init(bytes: .init(repeating: 1, count: 16)), generation: 1), testValue("saved during repair"))])
    let saved = try requireReceipt(await owner.persist(capture))
    await gate.release(); await owner.settleRepositoryRepair()
    guard case .complete(let through, let count) = await owner.repositoryRepairStatus() else {
        Issue.record("Complete automatic repair must acknowledge its exact captured inventory"); try await owner.close(); return
    }
    #expect(through == 1 && count == fixture.initial.objects.count + 1)
    for (locator, expected) in fixture.initial.objects {
        let file = path + "/" + ImmutableRepositoryLocator.segment(locator).relativePath
        #expect(try Array(Data(contentsOf: URL(fileURLWithPath: file))) == expected)
    }
    #expect(try Array(Data(contentsOf: URL(fileURLWithPath: path + "/" + ImmutableRepositoryLocator.descriptor(fixture.initial.descriptor).relativePath))) == fixture.initial.descriptor.encodedBytes)
    try await owner.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["saved during repair", "untouched"])
    #expect(try await reopened.retainedObject(at: saved.object).count > 156)
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairPreservesNamespaceRaceWinner(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let gate = ImprovementGate()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(repairPrepared: { _ in await gate.hold() })))
    await gate.wait()
    try FileManager.default.createDirectory(atPath: path + "/NV Data", withIntermediateDirectories: false)
    try Data([9, 8, 7]).write(to: URL(fileURLWithPath: path + "/NV Data/foreign"))
    await gate.release(); await owner.settleRepositoryRepair()
    guard case .paused(.root(.unavailable(EEXIST))) = await owner.repositoryRepairStatus() else {
        Issue.record("An occupied namespace must reject the captured absent-name repair"); try await owner.close(); return
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: path + "/NV Data") == ["foreign"])
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/NV Data/foreign")) == Data([9, 8, 7]))
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryRepairFencesReplacedNamespaceBetweenBatches(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let gate = ImprovementGate()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(repairBatch: { _ in await gate.hold() })))
    await gate.wait()
    try FileManager.default.moveItem(atPath: path + "/NV Data", toPath: path + "/original")
    try FileManager.default.createDirectory(atPath: path + "/NV Data", withIntermediateDirectories: false)
    try Data([3, 4]).write(to: URL(fileURLWithPath: path + "/NV Data/foreign"))
    await gate.release(); await owner.settleRepositoryRepair()
    #expect(try FileManager.default.contentsOfDirectory(atPath: path + "/NV Data") == ["foreign"])
    guard case .paused(.file(.changed)) = await owner.repositoryRepairStatus() else {
        Issue.record("Repair must retain its original directory across turns"); try await owner.close(); return
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/NV Data/foreign")) == Data([3, 4]))
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close()
}
