import NVStorageTestSupport
import Foundation
import Crypto
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private func checkInventory(_ store: LocalStoreSession, at root: RepositoryRootSession,
                            limit: Int = 16) async throws -> [RepositoryInventoryCheck] {
    var cursor: RepositoryInventoryCursor?, checks: [RepositoryInventoryCheck] = []
    repeat {
        let batch = try await store.captureRepositoryInventory(continuing: cursor, limit: limit)
        let checked = try await root.checkInventory(batch, from: store)
        try await root.validate(checked, for: store)
        checks.append(checked); cursor = batch.continuation
    } while cursor != nil
    return checks
}

private actor InventoryEvents {
    private var checks: [RepositoryInventoryCheck] = []
    func record(_ event: RepositoryTransportObservation) {
        if case .inventory(let check) = event { checks.append(check) }
    }
    var healthy: Bool { checks.contains { $0.failures.isEmpty } }
    var first: RepositoryInventoryCheck? { checks.first }
    func completed(_ count: Int) -> Bool { checks.contains { $0.checkedCount == count && $0.failures.isEmpty } }
    func contains(_ failure: RepositoryFileFailure) -> Bool { checks.contains { $0.failures.contains(failure) } }
    func count(_ failure: RepositoryFileFailure) -> Int { checks.filter { $0.failures.contains(failure) }.count }
}

private func waitInventory(_ condition: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
    while try await !condition() {
        try #require(ContinuousClock.now < deadline, "The actual background condition must settle")
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

private actor InventoryPublicationFault {
    private var first = true
    func enter() throws {
        if first { first = false; throw RepositoryRootError.unavailable(EIO) }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func repositoryInventoryLeavesUnpublishedWorkOwned(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let events = InventoryEvents(), fault = InventoryPublicationFault()
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(publication: { _ in try await fault.enter() },
            observation: { await events.record($0) }, idleNanoseconds: 300_000_000_000,
            // The retry lies beyond the attempt deadline, leaving a deterministic paused publisher.
            retryNanoseconds: [30_000_000_000, 30_000_000_000], deadlineNanoseconds: 15_000_000_000))
    try await waitInventory { await events.first != nil }
    let first = try #require(await events.first)
    #expect(first.checkedCount == 0 && first.failures.isEmpty)
    #expect(await driver.status().publication == .paused(.root(.unavailable(EIO))))
    await driver.revisit(.refresh)
    try await waitInventory { await events.completed(initial.objects.count + 1) }
    for (locator, bytes) in initial.objects {
        #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/" + ImmutableRepositoryLocator.segment(locator).relativePath)) == Data(bytes))
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/" + ImmutableRepositoryLocator.descriptor(initial.descriptor).relativePath)) == Data(initial.descriptor.encodedBytes))
    await driver.stop(); await root.close(); try await store.quiesce()
}

@Test(arguments: [false, true], ["healthy", "missing", "corrupt", "directory", "symlink", "hardlink", "misnamed"])
func repositoryInventoryChecksCanonicalNames(encrypted: Bool, damage: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    _ = try await publishRepository(store, to: root)
    let before = try await checkInventory(store, at: root)
    #expect(before.flatMap(\.failures).isEmpty)
    #expect(before.reduce(0) { $0 + $1.checkedCount } == initial.objects.count + 1)
    let locator = try #require(initial.objects.keys.first), bytes = try #require(initial.objects[locator])
    let file = path + "/" + ImmutableRepositoryLocator.segment(locator).relativePath
    let preserved = path + "/original"
    if damage != "healthy" { try FileManager.default.moveItem(atPath: file, toPath: preserved) }
    switch damage {
    case "corrupt": try Data([1, 2, 3]).write(to: URL(fileURLWithPath: file))
    case "directory": try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
    case "symlink": try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: preserved)
    case "hardlink": try FileManager.default.linkItem(atPath: preserved, toPath: file)
    case "misnamed":
        let other = try #require(initial.objects.first { $0.key != locator })
        try Data(other.value).write(to: URL(fileURLWithPath: file))
        // Ordinary discovery can validate this object while its filename still names a different accepted object.
        var ended = false
        while !ended { ended = try await root.discover(into: store, opportunity: .backgroundTurn).passEnded }
    default: break
    }
    let extra = path + "/" + RepositoryProtocolDirectory.keys.relativePath + "/unrelated-invalid"
    try Data([99]).write(to: URL(fileURLWithPath: extra))
    let after = try await checkInventory(store, at: root)
    let failures = after.flatMap(\.failures)
    switch damage {
    case "healthy": #expect(failures.isEmpty && after.reduce(0) { $0 + $1.readCount } == 0)
    case "missing": #expect(failures == [.absent])
    case "corrupt", "misnamed": #expect(failures == [.conflict])
    case "hardlink": #expect(failures == [.hardLinked])
    default: #expect(failures == [.kindCollision])
    }
    if damage != "healthy" { #expect(try Data(contentsOf: URL(fileURLWithPath: preserved)) == Data(bytes)) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: extra)) == Data([99]))
    #expect(await root.listingResourceCount() == 0)
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    #expect(try await store.retainedObject(at: locator) == bytes)
    await root.close(); try await store.quiesce()
}

@Test(arguments: [false, true])
func repositoryInventoryBindsPrefixStoreAndSession(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let other = try await newSession(initial, protection)
    let root = try await RepositoryRootSession.open(directory: repositoryDirectory())
    _ = try await publishRepository(store, to: root)
    let batch = try await store.captureRepositoryInventory(limit: 1)
    let cursor = try #require(batch.continuation)
    await #expect(throws: StorageError.wrongContext) { try await other.captureRepositoryInventory(continuing: cursor) }
    await #expect(throws: StorageError.wrongContext) { try await root.checkInventory(batch, from: other) }
    let check = try await root.checkInventory(batch, from: store)
    let otherRoot = try await RepositoryRootSession.open(directory: repositoryDirectory())
    await #expect(throws: RepositoryRootError.wrongContext) { try await otherRoot.validate(check, for: store) }
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    _ = try await put("after captured inventory", birth: birth, generation: 1, session: store)
    let published = try await store.captureRepositoryInventory(through: 1)
    let installed = try await root.checkInventory(published, from: store)
    #expect(installed.checkedCount == initial.objects.count + 1 && installed.failures.isEmpty)
    let empty = try await root.checkInventory(store.captureRepositoryInventory(through: 0), from: store)
    #expect(empty.checkedCount == 0 && empty.failures.isEmpty)
    await #expect(throws: StorageError.staleCapture) { try await store.captureRepositoryInventory(through: 3) }
    let partial = try await store.captureRepositoryPublication(maximumObjects: 1)
    #expect(partial.continuation?.inventoryThrough == 0)
    let complete = try await store.captureRepositoryPublication(maximumObjects: 64)
    #expect(complete.nextPass?.inventoryThrough == 2)
    var next: RepositoryInventoryCursor? = cursor, count = check.checkedCount
    repeat {
        let old = try await store.captureRepositoryInventory(continuing: next, limit: 1)
        let observed = try await root.checkInventory(old, from: store)
        #expect(observed.failures.isEmpty)
        count += observed.checkedCount; next = old.continuation
    } while next != nil
    #expect(count == initial.objects.count + 1)
    let fresh = try await checkInventory(store, at: root)
    #expect(fresh.reduce(0) { $0 + $1.checkedCount } == count + 1)
    #expect(fresh.flatMap(\.failures) == [.absent])
    let selection = await store.selection
    try await store.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.captureRepositoryInventory(continuing: cursor) }
    await #expect(throws: StorageError.wrongContext) { try await root.validate(check, for: reopened) }
    try await reopened.quiesce(); try await other.quiesce(); await root.close(); await otherRoot.close()
}

@Test(arguments: [false, true], ["file", "root", "cancel"])
func repositoryInventoryRejectsChangedObservation(encrypted: Bool, change: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    _ = try await publishRepository(store, to: root)
    let names = initial.objects.map { ($0.key.segmentID.bytes, ImmutableRepositoryLocator.segment($0.key).relativePath) }
        + [(initial.descriptor.descriptorID, ImmutableRepositoryLocator.descriptor(initial.descriptor).relativePath)]
    let selectedPath = path + "/" + (try #require(names.sorted { $0.0.lexicographicallyPrecedes($1.0) }.first)).1
    let batch = try await store.captureRepositoryInventory(limit: 1)
    let gate = ImprovementGate()
    let checking = Task { try await root.checkInventory(batch, from: store, observed: { await gate.hold() }) }
    await gate.wait()
    switch change {
    case "file": try Data([6, 7, 8]).write(to: URL(fileURLWithPath: selectedPath))
    case "root": await root.invalidate()
    default: checking.cancel()
    }
    await gate.release()
    switch change {
    case "file":
        let checked = try await checking.value
        #expect(checked.failures == [.changed])
        let retried = try await checkInventory(store, at: root)
        #expect(retried.flatMap(\.failures) == [.conflict])
    case "root": await #expect(throws: RepositoryRootError.stalePermission) { try await checking.value }
    default: await #expect(throws: CancellationError.self) { try await checking.value }
    }
    #expect(await root.listingResourceCount() == 0)
    await root.close(); try await store.quiesce()
}

@Test(arguments: [false, true], [64, 256, 1024])
func repositoryInventoryWarmWorkIsBounded(encrypted: Bool, actions: Int) async throws {
    let fixture = try await GrowthHistoryFixtures.shared.fixture(encrypted: encrypted, actions: actions)
    let store = try await fixture.openSender(), path = try repositoryDirectory()
    try deliverFile(fixture.initial.descriptor.encodedBytes,
        relative: ImmutableRepositoryLocator.descriptor(fixture.initial.descriptor).relativePath, to: path)
    for (locator, bytes) in fixture.initial.objects {
        try deliverFile(bytes, relative: ImmutableRepositoryLocator.segment(locator).relativePath, to: path)
    }
    for object in fixture.history {
        try deliverFile(object.bytes, relative: ImmutableRepositoryLocator.segment(object.locator).relativePath, to: path)
    }
    let root = try await RepositoryRootSession.open(directory: path)
    #expect(try await checkInventory(store, at: root).flatMap(\.failures).isEmpty)
    let lane = await store.lane
    try await lane.perform { $0.work = StorageWork() }
    _ = await root.measureMetadata(true)
    let start = ContinuousClock.now
    let checks = try await checkInventory(store, at: root)
    let elapsed = start.duration(to: .now)
    let work = try await lane.perform { db in let work = db.work!; db.work = nil; return work }
    let metadata = try #require(await root.measureMetadata(false))
    #expect(checks.flatMap(\.failures).isEmpty && checks.allSatisfy { $0.checkedCount <= 16 && $0.readCount == 0 })
    let expected = fixture.initial.objects.count + 1 + actions
    #expect(checks.reduce(0) { $0 + $1.checkedCount } == expected)
    #expect(metadata.largestBatch <= 16 && metadata.statCalls == expected && metadata.bodyReads == 0)
    #expect(work.stages.values.reduce(0) { $0 + $1.historyReads + $1.envelopeDecodes + $1.ancestors } == 0)
    #expect(await root.listingResourceCount() == 0)
    print("INVENTORY encrypted=\(encrypted) actions=\(actions) objects=\(expected) batches=\(checks.count) metadata=\(metadata.statCalls) bodies=0 elapsed=\(elapsed)")
    await root.close(); try await store.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func collectionInventoryRepairsMissingAndPreservesDamage(fixture: RepositoryLocalFixture, occupied: Bool) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let events = InventoryEvents()
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(transport: .init(
            observation: { await events.record($0) }, idleNanoseconds: 50_000_000))))
    await owner.settleAcquisition()
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await waitInventory { await events.healthy }
#if canImport(Darwin)
    // Disable this root's presenter to exercise periodic progress without another event or incoming object.
    let expected = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let presenter = try #require(NSFileCoordinator.filePresenters.first {
        $0.presentedItemURL?.resolvingSymlinksInPath().path == expected
    })
    NSFileCoordinator.removeFilePresenter(presenter)
#endif
    let locator = try #require(fixture.initial.objects.keys.first), bytes = try #require(fixture.initial.objects[locator])
    let file = path + "/" + ImmutableRepositoryLocator.segment(locator).relativePath
    let preserved = path + "/preserved-original"
    try FileManager.default.moveItem(atPath: file, toPath: preserved)
    let damage = Data([13, 14, 15])
    if occupied { try damage.write(to: URL(fileURLWithPath: file)) }
    try await waitInventory { await events.contains(occupied ? .conflict : .absent) }
    if occupied {
        try await waitInventory { await owner.pendingRepositoryRequest()?.kind == .preserveRepositoryCollision }
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == damage)
        let copied = try await owner.copyRepositoryAndSavedWork(to: privateTempPath())
        #expect(copied.repository.unmetRequirements.isEmpty)
        #expect(copied.repository.issues.contains { $0.path == ImmutableRepositoryLocator.segment(locator).relativePath })
        #expect(try Data(contentsOf: URL(fileURLWithPath: copied.repository.destination + "/" + ImmutableRepositoryLocator.segment(locator).relativePath)) == Data(bytes))
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == damage)
    } else {
        try await waitInventory { (try? Data(contentsOf: URL(fileURLWithPath: file))) == Data(bytes) }
        await owner.settleRepositoryRepair()
        guard case .complete = await owner.repositoryRepairStatus() else { throw StorageError.incomplete }
    }
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let capture = try await owner.capture(kind: .savedEdit, changes: [.put(.init(birth: birth, generation: 1), testValue("still editable"))])
    _ = try requireReceipt(await owner.persist(capture))
    #expect(try await collectionBodies(owner) == ["still editable", "untouched"])
    #expect(try Data(contentsOf: URL(fileURLWithPath: preserved)) == Data(bytes))
    await owner.settleRepositoryRepair(); try await owner.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["still editable", "untouched"])
    #expect(try await reopened.retainedObject(at: locator) == bytes)
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func repositoryInventoryRetriesFailedBatchAndResumesExplicitly(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let events = InventoryEvents()
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(observation: { await events.record($0) }, idleNanoseconds: 50_000_000,
                     retryNanoseconds: [10_000_000, 20_000_000]))
    try await waitInventory { await events.healthy }
    let locator = try #require(initial.objects.keys.first), bytes = try #require(initial.objects[locator])
    let file = path + "/" + ImmutableRepositoryLocator.segment(locator).relativePath
    try FileManager.default.moveItem(atPath: file, toPath: path + "/original")
    try await waitInventory { await driver.status().discovery == .paused(.file(.absent)) }
    #expect(await events.count(.absent) == 3, "The initial attempt and both bounded retries check the same failed batch")
    #expect(await driver.status().publication == .paused(.file(.absent)))
    #expect(!FileManager.default.fileExists(atPath: file))
    try Data(bytes).write(to: URL(fileURLWithPath: file))
    await driver.revisit(.refresh)
    try await waitInventory {
        let state = await driver.status()
        return state.discovery == .idle && state.publication == .idle
    }
    #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data(bytes))
    #expect(await root.listingResourceCount() == 0)
    await driver.stop(); await root.close(); try await store.quiesce()
}
