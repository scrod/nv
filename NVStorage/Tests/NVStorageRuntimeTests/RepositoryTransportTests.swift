import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
import Crypto
@testable import NVStorageRuntime

private enum TransportEvent: Sendable {
    case driver(RepositoryTransportObservation), attempt([ImmutableRepositoryLocator]), cut(Int64), held
}

private actor TransportWitness {
    private struct Waiter {
        let id: UUID
        let matches: @Sendable ([TransportEvent]) -> Bool
        let continuation: CheckedContinuation<Bool, Never>
        let timeout: Task<Void, Never>
    }
    private(set) var events: [TransportEvent] = []
    private var waiters: [Waiter] = []
    func record(_ event: TransportEvent) {
        events.append(event)
        let ready = waiters.filter { $0.matches(events) }
        waiters.removeAll { $0.matches(events) }
        for waiter in ready { waiter.timeout.cancel(); waiter.continuation.resume(returning: true) }
    }
    func wait(_ matches: @escaping @Sendable ([TransportEvent]) -> Bool) async -> Bool {
        if matches(events) { return true }
        let id = UUID(), timeout = Task {
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            expire(id)
        }
        return await withCheckedContinuation { waiters.append(.init(id: id, matches: matches, continuation: $0, timeout: timeout)) }
    }
    private func expire(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

private func idle(_ events: [TransportEvent]) -> Bool {
    events.contains { if case .driver(.idle) = $0 { true } else { false } }
}
private func discovered(_ locator: SegmentLocator, accepted: Bool, in events: [TransportEvent]) -> Bool {
    events.contains {
        guard case .driver(.discovery(let turn)) = $0 else { return false }
        return turn.entries.contains {
            guard case .received(let found, _, let outcome) = $0.outcome, found == locator else { return false }
            if accepted { if case .accepted = outcome { return true }; return false }
            if case .waiting = outcome { return true }; return false
        }
    }
}

private actor TransportScanReads {
    private(set) var counts: [String: Int] = [:]
    private(set) var maximumListingResources = 0
    func read(_ path: String) { counts[path, default: 0] += 1 }
    func observed(resources: Int) { maximumListingResources = max(maximumListingResources, resources) }
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryDriverCoalescesHintStormAcrossNestedPass(fixture: RepositoryLocalFixture) async throws {
    let source = try await newSession(fixture.initial, fixture.protection)
    let store = try await newSession(fixture.initial, fixture.protection), path = try repositoryDirectory()
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    var edits: [SegmentLocator] = []
    for generation in 1...24 {
        let saved = try await put("storm edit \(generation)", birth: birth, generation: UInt64(generation), session: source)
        edits.append(saved.object)
        try await deliverFile(source.retainedObject(at: saved.object),
            relative: ImmutableRepositoryLocator.segment(saved.object).relativePath, to: path)
    }
    let rejectedBytes = try ObjectEnvelopeV1.seal(payload: [], kind: .changes, collection: fixture.initial.descriptor.collection,
        writer: WriterEpoch(bytes: .init(repeating: 81, count: 16)), sequence: 0, protection: fixture.protection)
    let rejected = try ObjectEnvelopeV1.open(rejectedBytes, collection: fixture.initial.descriptor.collection,
        protection: fixture.protection).locator
    let rejectedPath = ImmutableRepositoryLocator.segment(rejected).relativePath
    try deliverFile(rejectedBytes, relative: rejectedPath, to: path)
    let root = try await RepositoryRootSession.open(directory: path), witness = TransportWitness()
#if canImport(Darwin)
    // This session's manual hints isolate the driver's coalescing from independent OS callbacks.
    let expected = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let presenter = try #require(NSFileCoordinator.filePresenters.first {
        $0.presentedItemURL?.resolvingSymlinksInPath().path == expected
    })
    NSFileCoordinator.removeFilePresenter(presenter)
#endif
    let gate = ImprovementGate(), reads = TransportScanReads()
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        await gate.release()
    }
    defer { watchdog.cancel(); Task { await gate.release() } }
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(discovery: .init(observed: { _ in
            await reads.observed(resources: root.listingResourceCount())
            await gate.hold()
        }, read: { await reads.read($0) }), observation: { await witness.record(.driver($0)) },
            idleNanoseconds: 300_000_000_000))
    await gate.wait()
    for _ in 0..<256 { await root.noteRepositoryChange() }
    try #require(await witness.wait { events in events.filter {
        if case .driver(.notification(.discovery)) = $0 { true } else { false }
    }.count == 256 }, "All injected hints reach the driver while the first read is held")
    #expect(await driver.status().discovery == .running)
    #expect(await reads.counts.isEmpty)
    await #expect(throws: RepositoryRootError.busy) { try await RepositoryTransportDriver.start(root: root, store: store) }
    await gate.release()
    try #require(await witness.wait(idle), "Nested discovery settles after the finite hint storm")
    let turns = await witness.events.compactMap { event -> RepositoryDiscoveryTurn? in
        if case .driver(.discovery(let turn)) = event { turn } else { nil }
    }
    #expect(turns.filter(\.passEnded).count == 2, "One interrupted pass and one coalesced follow-up")
    #expect(turns.count <= 16 && turns.allSatisfy { $0.entries.count <= 16 })
    #expect(turns.first?.capturedInvalidation == 0 && turns.last?.capturedInvalidation == 256)
    #expect(turns.allSatisfy { $0.latestInvalidation == 256 })
    let bodyReads = await reads.counts
    #expect(edits.allSatisfy { bodyReads[ImmutableRepositoryLocator.segment($0).relativePath] == 1 },
        "Accepted object bodies are read once across the two passes")
    #expect(bodyReads[rejectedPath] == 2, "The unchanged rejected neighbor remains observable on each pass")
    #expect(await reads.maximumListingResources <= 2)
    #expect(await root.listingResourceCount() == 0)
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["storm edit 24", "untouched"])
    #expect(try await store.snapshot().context == source.snapshot().context)
    let lane = await store.lane
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") } == [[.integer(26)]])
    #expect(try await lane.perform { try $0.rows("SELECT object_id FROM rejected_objects") } == [[.blob(rejected.segmentID.bytes)]])
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM object_waits") } == [[.integer(0)]])
    #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(rejected.segmentID.bytes)]) } == [[.blob(rejectedBytes)]])
    for locator in edits { #expect(try await store.retainedObject(at: locator) == source.retainedObject(at: locator)) }
    let selection = await store.selection
    await driver.stop(); await root.close(); try await store.quiesce()
    let nextRoot = try await RepositoryRootSession.open(directory: path)
    await nextRoot.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["storm edit 24", "untouched"])
    #expect(try await reopened.snapshot().context == source.snapshot().context)
    try await reopened.quiesce(); try await source.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryDriverRevisitsEmptyPassAndLatePrerequisite(fixture: RepositoryLocalFixture) async throws {
    let source = try await newSession(fixture.initial, fixture.protection)
    let destination = try await newSession(fixture.initial, fixture.protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), witness = TransportWitness()
#if canImport(Darwin)
    // Removing this test session's presenter makes late delivery exercise the ordinary revisit.
    let expected = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let presenter = try #require(NSFileCoordinator.filePresenters.first {
        $0.presentedItemURL?.resolvingSymlinksInPath().path == expected
    })
    NSFileCoordinator.removeFilePresenter(presenter)
    #expect(!NSFileCoordinator.filePresenters.contains { $0 === presenter })
#endif
    let driver = try await RepositoryTransportDriver.start(root: root, store: destination,
        hooks: .init(observation: { await witness.record(.driver($0)) }, idleNanoseconds: 100_000_000))
    #expect(await witness.wait(idle))
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let parent = try await put("automatically found parent", birth: birth, generation: 1, session: source)
    let child = try await put("automatically found child", birth: birth, generation: 2, session: source)
    let childBytes = try await source.retainedObject(at: child.object), parentBytes = try await source.retainedObject(at: parent.object)
    try deliverFile(childBytes, relative: ImmutableRepositoryLocator.segment(child.object).relativePath, to: path)
    #expect(await witness.wait { discovered(child.object, accepted: false, in: $0) })
    #expect(try await destination.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let lane = await destination.lane
    #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(child.object.segmentID.bytes)]) } == [[.blob(childBytes)]])
    try deliverFile(parentBytes, relative: ImmutableRepositoryLocator.segment(parent.object).relativePath, to: path)
    #expect(await witness.wait { discovered(parent.object, accepted: true, in: $0) })
    // The parent arrival wakes the already retained child inside the ordinary receive path.
    #expect(try await destination.retainedObject(at: child.object) == childBytes)
    #expect(try await destination.snapshot().notes.map(\.value.body.string).sorted() == ["automatically found child", "untouched"])
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") } == [[.integer(4)]])
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM object_waits") } == [[.integer(0)]])
    let selection = await destination.selection, expectedContext = try await source.snapshot().context
    await driver.stop(); await root.close(); try await destination.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await reopened.snapshot().context == expectedContext)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["automatically found child", "untouched"])
    try await reopened.quiesce(); try await source.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryDriverSaveSettlementPublishesOnlyNewAcceptedBytes(fixture: RepositoryLocalFixture) async throws {
    let store = try await newSession(fixture.initial, fixture.protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), witness = TransportWitness()
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(observation: { await witness.record(.driver($0)) }, idleNanoseconds: 300_000_000_000))
    #expect(await witness.wait(idle))
    let lane = await store.lane, work = StorageWork()
    try await lane.perform { $0.work = work }
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let saved = try await put("automatic outgoing edit", birth: birth, generation: 1, session: store)
    #expect(await witness.wait { events in events.contains {
        if case .driver(.published(let batch)) = $0 { batch.locators.contains(.segment(saved.object)) } else { false }
    } })
    let bytes = try await store.retainedObject(at: saved.object)
    #expect(try Array(Data(contentsOf: URL(fileURLWithPath: path + "/" + ImmutableRepositoryLocator.segment(saved.object).relativePath))) == bytes)
    let batches = await witness.events.compactMap { event -> PublishedRepositoryBatch? in
        if case .driver(.published(let batch)) = event { batch } else { nil }
    }
    #expect(batches.filter { $0.locators.contains(.segment(saved.object)) }.count == 1)
    let later = batches.filter { $0.through > 1 }
    #expect(later.flatMap(\.locators).allSatisfy { $0 == .segment(saved.object) })
    await driver.stop(); #expect(await driver.status().stopped)
    await root.close(); try await store.quiesce()
}

private actor PublicationFaults {
    let failures: Int
    private(set) var starts: [UInt64] = []
    private(set) var batches: [[ImmutableRepositoryLocator]] = []
    init(_ failures: Int) { self.failures = failures }
    func enter(_ batch: RepositoryPublicationBatch) throws {
        starts.append(DispatchTime.now().uptimeNanoseconds); batches.append(batch.locators)
        if starts.count <= failures { throw RepositoryRootError.unavailable(EIO) }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [2, 3])
func repositoryDriverRetriesExactBatchWithinBound(failures: Int) async throws {
    let fixture = try RepositoryLocalFixture.prepared.get()[0]
    let store = try await newSession(fixture.initial, fixture.protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), witness = TransportWitness(), faults = PublicationFaults(failures)
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(publication: { try await faults.enter($0); await witness.record(.attempt($0.locators)) },
            observation: { await witness.record(.driver($0)) }, idleNanoseconds: 300_000_000_000,
            // Use the production window for instrumented Foundation turns; the held-accessor test forces expiry.
            retryNanoseconds: [20_000_000, 40_000_000], deadlineNanoseconds: 15_000_000_000))
    for _ in 0..<32 { await root.noteRepositoryChange() }
    if failures == 3 {
        #expect(await witness.wait { $0.contains { if case .driver(.paused(.root(.unavailable(EIO)))) = $0 { true } else { false } } })
        #expect(await driver.status().publication == .paused(.root(.unavailable(EIO))))
        // An ordinary hint/idle opportunity preserves the exhausted attempt's status.
        await root.noteRepositoryChange(); await driver.revisit(.backgroundTurn)
        #expect(await faults.starts.count == 3)
        await driver.revisit(.refresh)
    }
    #expect(await witness.wait { $0.contains { if case .driver(.published(let batch)) = $0 { !batch.locators.isEmpty } else { false } } })
    let starts = await faults.starts, batches = await faults.batches
    #expect(starts.count == failures + 1)
    #expect(starts[1] - starts[0] >= 20_000_000 && starts[2] - starts[1] >= 40_000_000)
    #expect(batches.allSatisfy { $0 == batches[0] })
    let expected = try await store.captureRepositoryPublication(maximumObjects: 64).locators
    #expect(batches[0] == expected)
    for locator in expected { #expect(FileManager.default.fileExists(atPath: path + "/" + locator.relativePath)) }
    await driver.stop(); await root.close(); try await store.quiesce()
}

@Test(.timeLimit(.minutes(1)))
func repositoryDriverDeadlineRetainsEnteredWorkAndExactRetry() async throws {
    let fixture = try RepositoryLocalFixture.prepared.get()[0], witness = TransportWitness()
    let release = DispatchSemaphore(value: 0)
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    let store = try await newSession(fixture.initial, fixture.protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path)
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(publication: { batch in
            await witness.record(.attempt(batch.locators))
        }, installEntered: { object in
            if object.locator == .descriptor(fixture.initial.descriptor) {
                Task { await witness.record(.held) }
                release.wait(); release.signal()
            }
        }, observation: { await witness.record(.driver($0)) }, idleNanoseconds: 300_000_000_000,
            deadlineNanoseconds: 2_000_000_000))
    #expect(await witness.wait { $0.contains { if case .held = $0 { true } else { false } } })
    #expect(await witness.wait { $0.contains { if case .driver(.deadline) = $0 { true } else { false } } })
    #expect(await driver.status().publication == .running)
    #expect(await witness.events.filter { if case .attempt = $0 { true } else { false } }.count == 1)
    await #expect(throws: RepositoryRootError.busy) { try await RepositoryTransportDriver.start(root: root, store: store) }
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    release.signal()
    #expect(await witness.wait { $0.contains { if case .driver(.paused(.deadline)) = $0 { true } else { false } } })
    #expect(await driver.status().publication == .paused(.deadline))
    await driver.revisit(.refresh)
    #expect(await witness.wait { $0.contains { if case .driver(.published(let batch)) = $0 { !batch.locators.isEmpty } else { false } } })
    let attempts = await witness.events.compactMap { if case .attempt(let locators) = $0 { locators } else { nil as [ImmutableRepositoryLocator]? } }
    #expect(attempts.count == 2 && attempts[0] == attempts[1])
    await driver.stop()
    let next = try await RepositoryTransportDriver.start(root: root, store: store)
    await next.stop(); await root.close(); try await store.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryDriverReceiveSettlementResumesWithoutNewDelivery(fixture: RepositoryLocalFixture) async throws {
    let source = try await newSession(fixture.initial, fixture.protection), store = try await newSession(fixture.initial, fixture.protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path), witness = TransportWitness()
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(observation: { await witness.record(.driver($0)) }, idleNanoseconds: 300_000_000_000))
    #expect(await witness.wait(idle))
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let parent = try await put("held receive", birth: birth, generation: 1, session: source)
    let child = try await put("receive settled", birth: birth, generation: 2, session: source)
    let gate = ImprovementGate(), lane = await store.lane
    let work = StorageWork(receiveRetentionCompletion: { _ in await gate.hold() })
    try await lane.perform { $0.work = work }
    let receiving = Task { try await store.receive(source.retainedObject(at: parent.object)) }
    await gate.wait()
    try await deliverFile(source.retainedObject(at: child.object), relative: ImmutableRepositoryLocator.segment(child.object).relativePath, to: path)
    await driver.revisit(.refresh)
    #expect(await witness.wait { $0.contains { if case .driver(.waiting(.discovery)) = $0 { true } else { false } } })
    #expect(await driver.status().discovery == .waitingForOwner)
    await gate.release(); _ = try await receiving.value
    #expect(await witness.wait { discovered(child.object, accepted: true, in: $0) })
    #expect(try await store.retainedObject(at: child.object) == source.retainedObject(at: child.object))
    #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == ["receive settled", "untouched"])
    await driver.stop(); await root.close(); try await store.quiesce(); try await source.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryDriverRejectionWriteFailuresRetainInputAndResume(fixture: RepositoryLocalFixture) async throws {
    let store = try await newSession(fixture.initial, fixture.protection), selection = await store.selection
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path), witness = TransportWitness()
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(observation: { await witness.record(.driver($0)) }, idleNanoseconds: 300_000_000_000))
    #expect(await witness.wait(idle))
    let bytes = try ObjectEnvelopeV1.seal(payload: [], kind: .changes, collection: fixture.initial.descriptor.collection,
        writer: WriterEpoch(bytes: .init(repeating: 81, count: 16)), sequence: 0, protection: fixture.protection)
    let object = try ObjectEnvelopeV1.open(bytes, collection: fixture.initial.descriptor.collection, protection: fixture.protection).locator
    let failedID = object.segmentID.bytes.map { String(format: "%02x", $0) }.joined()
    let lane = await store.lane
    try await lane.perform {
        try $0.exec("CREATE TEMP TRIGGER fail_transport_rejection BEFORE DELETE ON ready_objects WHEN OLD.object_id=X'\(failedID)' BEGIN SELECT RAISE(ABORT,'synthetic rejection failure'); END")
    }
    try deliverFile(bytes, relative: ImmutableRepositoryLocator.segment(object).relativePath, to: path)
    for attempt in 1...2 {
        await driver.revisit(.refresh)
        #expect(await witness.wait { events in events.filter {
            if case .driver(.paused(.store(.database(1811)))) = $0 { true } else { false }
        }.count >= attempt })
        #expect(await driver.status().discovery == .paused(.store(.database(1811))))
        #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects JOIN ready_objects USING(object_id)") } == [[.blob(bytes)]])
        #expect(try await lane.perform { try $0.rows("SELECT object_id FROM rejected_objects") }.isEmpty)
        #expect(try await store.snapshot().through == 1)
        await root.noteRepositoryChange(); await driver.revisit(.backgroundTurn)
        #expect(await driver.status().discovery == .paused(.store(.database(1811))))
    }
    let saved = try await put("saved while rejection is paused", birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1, session: store)
    #expect(try await store.retainedObject(at: saved.object).count > 156)
    #expect(await driver.status().discovery == .paused(.store(.database(1811))))
    await driver.stop(); await lane.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let recoveredLane = await reopened.lane
    #expect(try await recoveredLane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(object.segmentID.bytes)]) } == [[.blob(bytes)]])
    #expect(try await recoveredLane.perform { try $0.rows("SELECT object_id FROM rejected_objects") } == [[.blob(object.segmentID.bytes)]])
    let next = try await RepositoryTransportDriver.start(root: root, store: reopened)
    let later = try await put("unrelated work resumed", birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 2, session: reopened)
    await next.stop()
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["unrelated work resumed", "untouched"])
    #expect(try await reopened.retainedObject(at: later.object).count > 156)
    try await reopened.quiesce(); await root.close()
}

@Test(.timeLimit(.minutes(1)))
func repositoryDriverRootFencingPreservesExactBatchAndNewSave() async throws {
    let fixture = try RepositoryLocalFixture.prepared.get()[0], witness = TransportWitness()
    let path = try repositoryDirectory(), moved = path + "-moved", release = DispatchSemaphore(value: 0)
    let store = try await newSession(fixture.initial, fixture.protection), root = try await RepositoryRootSession.open(directory: path)
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(publication: {
            await witness.record(.attempt($0.locators)); await witness.record(.cut($0.through))
        }, installEntered: { object in
            if object.locator == .descriptor(fixture.initial.descriptor) {
                Task { await witness.record(.held) }; release.wait(); release.signal()
            }
        }, observation: { await witness.record(.driver($0)) }, idleNanoseconds: 300_000_000_000))
    #expect(await witness.wait { $0.contains { if case .held = $0 { true } else { false } } })
    await root.invalidate()
    let fenceDeadline = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    while await driver.status().publication != .paused(.root(.fenced)),
          DispatchTime.now().uptimeNanoseconds < fenceDeadline { await Task.yield() }
    try #require(await driver.status().publication == .paused(.root(.fenced)), "The driver consumes fencing before revalidation")
    let saved = try await put("newer local work across root move", birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1, session: store)
    try FileManager.default.moveItem(atPath: path, toPath: moved)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try Data([99]).write(to: URL(fileURLWithPath: path + "/replacement"))
    release.signal()
    #expect(await root.state == .fenced)
    var continuity: RepositoryRootContinuity?
    while continuity == nil {
        do { continuity = try await root.revalidate(candidate: moved) }
        catch RepositoryRootError.busy { await Task.yield(); continue }
    }
    #expect(continuity == .same)
    #expect(await witness.wait { $0.contains {
        if case .driver(.published(let batch)) = $0 { batch.locators.contains(.segment(saved.object)) } else { false }
    } })
    let attempts = await witness.events.compactMap { if case .attempt(let value) = $0 { value } else { nil as [ImmutableRepositoryLocator]? } }
    #expect(attempts.count >= 3 && attempts[0] == attempts[1])
    let cuts = await witness.events.compactMap { if case .cut(let value) = $0 { value } else { nil as Int64? } }
    #expect(cuts.count >= 3 && cuts[0] == 1 && cuts[1] == cuts[0] && cuts.last == 2)
    let expected = try await store.retainedObject(at: saved.object)
    #expect(try Array(Data(contentsOf: URL(fileURLWithPath: moved + "/" + ImmutableRepositoryLocator.segment(saved.object).relativePath))) == expected)
    #expect(try FileManager.default.contentsOfDirectory(atPath: path) == ["replacement"])
    #expect(try Array(Data(contentsOf: URL(fileURLWithPath: path + "/replacement"))) == [99])
    await driver.stop(); await root.close(); try await store.quiesce()
}
