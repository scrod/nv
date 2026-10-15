import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Captures two successive history checks for an explicitly arranged finite interference schedule.
private actor ConnectedHistoryGates {
    let first = ImprovementGate(), second = ImprovementGate()
    private var checks = 0
    var secondEntered: Bool { checks >= 2 }
    func check() async {
        checks += 1
        if checks == 1 { await first.hold() }
        if checks == 2 { await second.hold() }
    }
}

/// The deadline bounds failure reporting; callers establish ordering through entered gates.
private func connectedEventually(_ predicate: () async throws -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(10)
    repeat {
        if try await predicate() { return true }
        try await Task.sleep(nanoseconds: 1_000_000)
    } while Date() < deadline
    return try await predicate()
}

extension LocalStoreSession {
    fileprivate var connectedValidationWait: Bool { receiving && inFlight && !drained.isEmpty }
}

/// Carries a save notification across every batch of an older fixed publication prefix.
@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func phase5PublicationFinishesPrefixThenFindsInterveningSave(fixture: RepositoryLocalFixture) async throws {
    let store = try await newSession(fixture.initial, fixture.protection)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    for generation in 1...4 {
        _ = try await put("existing \(generation)", birth: birth, generation: UInt64(generation), session: store)
    }
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    let prior = try await store.captureRepositoryPublication(maximumObjects: 64)
    #expect(prior.continuation == nil && prior.locators.count > 8)
    guard case .complete = try await root.publish(prior, from: store, using: root.permission()) else {
        throw StorageError.incomplete
    }
    _ = try await discoverPass(root, into: store, budget: 16)
#if canImport(Darwin)
    let expected = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let presenter = try #require(NSFileCoordinator.filePresenters.first {
        $0.presentedItemURL?.resolvingSymlinksInPath().path == expected
    })
    NSFileCoordinator.removeFilePresenter(presenter)
#endif
    let captured = ImprovementGate(), notified = ImprovementGate(), published = ImprovementGate()
    let driver = try await RepositoryTransportDriver.start(root: root, store: store,
        hooks: .init(publication: { batch in
            if batch.continuation != nil { await captured.hold() }
        }, observation: { event in
            if case .notification(.storeSettled) = event { await notified.signal() }
            if case .published(let batch) = event, batch.through > prior.through, !batch.locators.isEmpty {
                await published.signal()
            }
        }, idleNanoseconds: 300_000_000_000))
    defer { Task { await captured.release(); await driver.stop(); await root.close(); try? await store.quiesce() } }
    await captured.wait()
    let saved = try await put("save during an older multi-batch prefix", birth: birth, generation: 5, session: store)
    await notified.wait(); await captured.release()
    let file = URL(fileURLWithPath: path + "/" + ImmutableRepositoryLocator.segment(saved.object).relativePath)
    let installed = try await connectedEventually { FileManager.default.fileExists(atPath: file.path) }
    #expect(installed, "An intervening save remains demanded through the final continuation batch")
    if installed {
        await published.wait()
        #expect(try Array(Data(contentsOf: file)) == (try await store.retainedObject(at: saved.object)))
    }
    await driver.stop(); await root.close(); try await store.quiesce()
}

/// Joins durable two-parent parking, reopening, rooted delivery and save-completion resumption.
@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func phase5DriverResumesRestartedDependencyAfterFiniteSaves(fixture: RepositoryLocalFixture) async throws {
    let left = try await newSession(fixture.initial, fixture.protection)
    let right = try await newSession(fixture.initial, fixture.protection)
    let initialReceiver = try await newSession(fixture.initial, fixture.protection)
    let a = try NoteBirth(bytes: .init(repeating: 1, count: 16)), b = try NoteBirth(bytes: .init(repeating: 2, count: 16))
    let l = try await put("Left", birth: a, generation: 1, session: left)
    let r = try await put("Right", birth: a, generation: 1, session: right)
    _ = try await left.receive(right.retainedObject(at: r.object))
    let revision = try #require(try await right.snapshot().notes.first { $0.birth == a }).revision.id
    let copy = try await left.copyVersion(for: a, revision: revision, generation: 2)
    let child = try requireReceipt(await left.persist(capture: copy))
    let childBytes = try await left.retainedObject(at: child.object)
    let path = try repositoryDirectory(), firstRoot = try await RepositoryRootSession.open(directory: path)
    try deliverFile(childBytes, relative: ImmutableRepositoryLocator.segment(child.object).relativePath, to: path)
    _ = try await discoverPass(firstRoot, into: initialReceiver, budget: 1)
    guard case .waiting(let both) = try await initialReceiver.receivedObjectStatus(at: child.object) else {
        throw StorageError.incomplete
    }
    #expect(Set(both) == [.acceptedHistory(l.object), .acceptedHistory(r.object)])
    try await deliverFile(left.retainedObject(at: l.object), relative: ImmutableRepositoryLocator.segment(l.object).relativePath, to: path)
    _ = try await discoverPass(firstRoot, into: initialReceiver, budget: 1)
    let selection = await initialReceiver.selection
    await firstRoot.close(); try await initialReceiver.quiesce()
    let receiver = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    guard case .waiting(let remaining) = try await receiver.receivedObjectStatus(at: child.object) else {
        throw StorageError.incomplete
    }
    #expect(remaining == [.acceptedHistory(r.object)])
    #expect(try await receiver.lane.perform {
        try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(child.object.segmentID.bytes)])
    } == [[.blob(childBytes)]])
    try await deliverFile(right.retainedObject(at: r.object), relative: ImmutableRepositoryLocator.segment(r.object).relativePath, to: path)
    let root = try await RepositoryRootSession.open(directory: path)
#if canImport(Darwin)
    let expected = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let presenter = try #require(NSFileCoordinator.filePresenters.first {
        $0.presentedItemURL?.resolvingSymlinksInPath().path == expected
    })
    NSFileCoordinator.removeFilePresenter(presenter)
#endif
    let checks = ConnectedHistoryGates(), completion = ImprovementGate(), accepted = ImprovementGate()
    defer { Task { await checks.first.release(); await checks.second.release(); await completion.release() } }
    let lane = await receiver.lane
    try await lane.perform { db in
        db.work = StorageWork(); db.work?.historyCheck = { await checks.check() }
        db.work?.acceptanceCompletion = { locator in if locator == child.object { await accepted.signal() } }
    }
    let driver = try await RepositoryTransportDriver.start(root: root, store: receiver,
        hooks: .init(idleNanoseconds: 300_000_000_000))
    await checks.first.wait()
    print("P57 driver entered history pass one")
    let first = try await put("local 1", birth: b, generation: 1, session: receiver)
    print("P57 driver first save committed")
    await checks.first.release()
    try #require(try await connectedEventually { await checks.secondEntered },
        "Interrupted rooted validation must start its second checked attempt")
    let capture = try await CapturedActionGroup(snapshot: receiver.snapshot(), kind: .savedEdit,
        changes: [.put(.init(birth: b, generation: 2), testValue("local 2"))])
    try await lane.perform { db in
        db.work?.acceptanceCompletion = { locator in
            if locator == child.object { await accepted.signal() }
            else if locator != r.object { await completion.hold() }
        }
    }
    let saving = Task { try requireReceipt(await receiver.persist(capture: capture)) }
    await completion.wait(); await checks.second.release()
    print("P57 driver second save committed; callback held")
    try #require(try await connectedEventually { await receiver.connectedValidationWait },
        "The actual repository receiver must postpone on the second finite save")
    await completion.release(); let second = try await saving.value
    await accepted.wait()
    print("P57 driver child accepted")
    try #require(try await connectedEventually {
        try await lane.perform { db in
            try db.rows("SELECT 1 FROM view_meta WHERE singleton=1 AND through_seq=(SELECT MAX(seq) FROM acceptance_batches)") == [[.integer(1)]]
        }
    }, "Save completion resumes and materializes rooted input without another hint or revisit")
    await driver.stop()
    #expect(try await receiver.snapshot().notes.first { $0.birth == copy.covered[0].birth }?.value.body.string == "Right")
    #expect(try await receiver.snapshot().notes.first { $0.birth == b }?.value.body.string == "local 2")
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM object_waits") } == [[.integer(0)]])
    for receipt in [first, second, child] {
        #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM accepted_objects WHERE object_id=?", [.blob(receipt.object.segmentID.bytes)]) } == [[.integer(1)]])
    }
    await root.close(); try await receiver.quiesce()
    print("P57 driver settled")
    let final = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await final.retainedObject(at: child.object) == childBytes)
    #expect(try await final.snapshot().notes.first { $0.birth == copy.covered[0].birth }?.value.body.string == "Right")
    #expect(try await final.snapshot().notes.first { $0.birth == b }?.value.body.string == "local 2")
    try await final.quiesce(); try await left.quiesce(); try await right.quiesce()
}

private enum NewerPendingAction: CaseIterable, Sendable {
    case edit, equalBody, delete
    var body: String? {
        switch self { case .edit: "newer F"; case .equalBody: "saved E"; case .delete: nil }
    }
}

/// Joins the actual acceptance barrier, delayed receipt, rooted receive and host publication.
@Test(.timeLimit(.minutes(1)), arguments: [false, true], NewerPendingAction.allCases)
private func phase5DelayedReceiptPreservesPendingAcrossReceive(encrypted: Bool, newer: NewerPendingAction) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let store = try await newSession(initial, protection), peer = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16)), other = try NoteBirth(bytes: .init(repeating: 2, count: 16))
    let rootPath = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: rootPath)
    let basis = try await store.snapshot(), lane = await store.lane
    var model = HeadlessModel(snapshot: basis)
    let e = try model.put(testValue("saved E"), birth: birth), capture = try model.capture(birth, at: basis)
    let gate = ImprovementGate()
    try await lane.perform { db in
        db.work = StorageWork(); db.work?.acceptanceCompletion = { _ in await gate.hold() }
    }
    let saving = Task { try requireReceipt(await store.persist(capture: capture)) }
    await gate.wait()
    defer { Task { await gate.release() } }
    let accepted = try await lane.perform { try $0.rows("SELECT MAX(seq) FROM accepted_objects") }
    #expect(accepted == [[.integer(2)]], "The actual barrier precedes the held completion")
    let f = try newer.body.map { try model.put(testValue($0), birth: birth) } ?? model.delete(birth)
    #expect(f != e && model.pending[birth] == f)
    await gate.release()
    let saved = try await saving.value
    try model.complete(saved)
    #expect(saved.covered == [e] && model.pending[birth] == f)
    #expect(model.values[birth]?.body.string == newer.body)
    let encodedE = try await store.retainedObject(at: saved.object)
    let operation = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(encodedE,
        collection: initial.descriptor.collection, protection: protection).payload).operations[0].operation
    #expect(operation.effect.noteValue?.body.string == "saved E")
    let remote = try await put("remote unrelated R", birth: other, generation: 1, session: peer)
    try await deliverFile(peer.retainedObject(at: remote.object),
        relative: ImmutableRepositoryLocator.segment(remote.object).relativePath, to: rootPath)
    _ = try await discoverPass(root, into: store, budget: 1)
    let prepared = try await store.prepareReduction(liveGeneration: e.generation)
    await #expect(throws: StorageError.staleCapture) {
        try await store.publish(prepared, liveGeneration: f.generation) { _ in
            Issue.record("Stale publication reached the host callback")
        }
    }
    #expect(model.pending[birth] == f && model.values[birth]?.body.string == newer.body)
    let finalCapture = try await model.capture(birth, at: store.snapshot())
    let finalReceipt = try requireReceipt(await store.persist(capture: finalCapture))
    try model.complete(finalReceipt)
    #expect(model.pending.isEmpty)
    let current = try await store.snapshot()
    #expect(current.notes.first { $0.birth == birth }?.value.body.string == newer.body)
    #expect(current.notes.first { $0.birth == other }?.value.body.string == "remote unrelated R")
    #expect(try await store.retainedObject(at: saved.object) == encodedE)
    _ = try await publishRepository(store, to: root)
    let selection = await store.selection
    await root.close(); try await store.quiesce(); try await peer.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes == current.notes)
    #expect(try await reopened.retainedObject(at: saved.object) == encodedE)
    try await reopened.quiesce()
}

/// Holds optional validation past real collection publication while required incoming work is caught up.
@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func phase5CollectionPublishesBeforeOptionalValidation(fixture: RepositoryLocalFixture, failCallback: Bool) async throws {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let preparing = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let peer = try await newSession(fixture.initial, fixture.protection)
    let lane = await preparing.lane
    try await lane.perform { db in
        db.work = StorageWork()
        db.work?.snapshotCandidateCompletion = { locator in
            let kind = try await lane.perform {
                try $0.rows("SELECT kind FROM objects WHERE object_id=?", [.blob(locator.segmentID.bytes)])[0][0].number
            }
            if kind == 2 { throw StorageError.database(10) }
        }
    }
    guard case .pending = try await preparing.persistGeneralSnapshot(capture: preparing.captureGeneralSnapshot()) else {
        throw StorageError.incomplete
    }
    let queued = try await lane.perform { try $0.rows("SELECT writer_epoch,sequence,object_id,encoded FROM objects JOIN ready_objects USING(object_id)") }
    try #require(queued.count == 1)
    let optional = try SegmentLocator.decodeV1(queued[0][0].bytes + queued[0][1].bytes + queued[0][2].bytes)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let incoming = try await put("required E", birth: birth, generation: 1, session: peer)
    let bytes = try await peer.retainedObject(at: incoming.object)
    let envelope = try ObjectEnvelopeV1.open(bytes, collection: fixture.initial.descriptor.collection, protection: fixture.protection)
    try await lane.perform { db in try db.transaction { try db.retainCandidate(bytes, opened: envelope, ready: true) } }
    await lane.close()
    let background = ImprovementGate(), acquisition = ImprovementGate(), optionalAccepted = ImprovementGate()
    defer { Task { await background.release(); await acquisition.release() } }
    var work = StorageWork(); work.publishedReceiveStart = { await background.hold() }
    work.acceptanceCompletion = { locator in if locator == optional { await optionalAccepted.signal() } }
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: path), hooks: .init(rootAcquired: { _ in await acquisition.hold() }, measuring: work)))
    await acquisition.wait()
    if failCallback {
        await #expect(throws: StorageError.unsupported) {
            try await owner.publish(owner.preparePublication(liveGeneration: 0), liveGeneration: 0) { _ -> Bool in
                throw StorageError.unsupported
            }
        }
        guard case .ready = await owner.decision() else { throw StorageError.incomplete }
    }
    let published = try await publishCollection(owner)
    #expect(published.notes.map(\.value.body.string).sorted() == ["required E", "untouched"])
    await background.wait()
    guard case .editable = await owner.decision() else { throw StorageError.incomplete }
    let f = try await owner.capture(kind: .savedEdit, changes: [.put(.init(birth: birth, generation: 1), testValue("local F"))])
    _ = try requireReceipt(await owner.persist(f))
    #expect(try await collectionBodies(owner) == ["local F", "untouched"])
    await background.release()
    await optionalAccepted.wait()
    await acquisition.release()
    await owner.settleAcquisition()
    try await owner.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await reopened.retainedObject(at: optional) == queued[0][3].bytes)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["local F", "untouched"])
    #expect(try await reopened.lane.perform { try $0.rows("SELECT COUNT(*) FROM ready_objects UNION ALL SELECT COUNT(*) FROM object_waits") } == [[.integer(0)], [.integer(0)]])
    try await reopened.quiesce(); try await peer.quiesce()
}
