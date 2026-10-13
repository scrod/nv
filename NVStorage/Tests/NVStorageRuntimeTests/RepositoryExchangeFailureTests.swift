import NVStorageTestSupport
import Foundation
import Crypto
import Testing
import NVStorageCore
@testable import NVStorageRuntime

actor RepositoryReadCounter {
    private(set) var count = 0
    func add() { count += 1 }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func repositoryExchangeChangedReadAndCancelledHandoffResumeWithoutHint(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let destination = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let saved = try await put("safe-save replacement", birth: birth, generation: 1, session: source)
    let bytes = try await source.retainedObject(at: saved.object), relative = ImmutableRepositoryLocator.segment(saved.object).relativePath
    try deliverFile(bytes, relative: relative, to: path)
    let observing = ImprovementGate()
    let changed = Task { try await root.discover(into: destination, opportunity: .foreground, budget: 64,
        hooks: RepositoryDiscoveryHooks(observed: { _ in await observing.hold() })) }
    await observing.wait()
    try deliverFile(bytes, relative: relative, to: path)
    await observing.release()
    let turn = try await changed.value
    #expect(turn.entries.contains { if case .unavailable(.changed) = $0.outcome { true } else { false } })
    #expect(try await destination.snapshot().through == 1)
    let delivering = ImprovementGate()
    let cancelled = Task { try await root.discover(into: destination, opportunity: .foreground, budget: 64,
        hooks: RepositoryDiscoveryHooks(delivered: { _ in await delivering.hold() })) }
    await delivering.wait(); cancelled.cancel(); await delivering.release()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await destination.retainedObject(at: saved.object) == bytes)
    _ = try await discoverPass(root, into: destination)
    #expect(try await destination.snapshot().notes.contains { $0.value.body.string == "safe-save replacement" })
    try await destination.quiesce(); try await source.quiesce(); await root.close()
}

@Test(arguments: [false, true], [false, true])
func repositoryExchangeHeldPublicationPreservesNewerLiveWork(encrypted: Bool, deleting: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let destination = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    var model = try await HeadlessModel(snapshot: destination.snapshot())
    // Equal visible contents still advance represented history and editing context.
    let remote = try await put("A", birth: birth, generation: 1, session: source)
    try await deliverFile(source.retainedObject(at: remote.object), relative: ImmutableRepositoryLocator.segment(remote.object).relativePath, to: path)
    _ = try await discoverPass(root, into: destination)
    let prepared = try await destination.prepareReduction(liveGeneration: 0)
    let pending = try deleting ? model.delete(birth) : model.put(testValue("newer live F"), birth: birth)
    let values = model.values, generations = model.pending
    await #expect(throws: StorageError.staleCapture) {
        try await destination.publish(prepared, liveGeneration: 1) { _ in
            Issue.record("Held remote publication reached the host after newer input")
        }
    }
    #expect(model.values == values && model.pending == generations && model.pending[birth] == pending)
    let capture = try await model.capture(birth, at: destination.snapshot())
    let receipt = try requireReceipt(await destination.persist(capture: capture))
    if !deleting { _ = try model.put(testValue("newer live G"), birth: birth) }
    try model.complete(receipt)
    #expect(deleting ? model.pending.isEmpty : model.pending[birth] != nil)
    #expect(deleting ? model.values[birth] == nil : model.values[birth]?.body.string == "newer live G")
    #expect(try await destination.retainedObject(at: remote.object) == source.retainedObject(at: remote.object))
    let published = try await destination.prepareReduction(liveGeneration: 2)
    let checked = try await destination.publish(published, liveGeneration: 2) { $0.notes }
    #expect(checked.contains { $0.birth == birth } == !deleting)
    #expect(deleting || checked.first { $0.birth == birth }?.value.body.string == "newer live F")
    try await destination.quiesce(); try await source.quiesce(); await root.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func repositoryExchangeInvalidatedHandoffRetainsAcceptedBytes(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let destination = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let saved = try await put("durable before root invalidation", birth: birth, generation: 1, session: source)
    let bytes = try await source.retainedObject(at: saved.object)
    try deliverFile(bytes, relative: ImmutableRepositoryLocator.segment(saved.object).relativePath, to: path)
    let gate = ImprovementGate()
    let held = Task { try await root.discover(into: destination, opportunity: .refresh, budget: 5,
        hooks: RepositoryDiscoveryHooks(delivered: { _ in await gate.hold() })) }
    await gate.wait()
    await #expect(throws: RepositoryRootError.busy) { try await root.discover(into: destination, opportunity: .foreground) }
    await root.invalidate(); await gate.release()
    await #expect(throws: RepositoryRootError.stalePermission) { try await held.value }
    #expect(try await destination.retainedObject(at: saved.object) == bytes)
    #expect(try await destination.snapshot().notes.contains { $0.value.body.string == "durable before root invalidation" })
    #expect(try await root.revalidate(candidate: path) == .same)
    let retried = try await discoverPass(root, into: destination)
    #expect(retried.contains { if case .unchangedAccepted(let id) = $0.outcome { id == saved.object.segmentID } else { false } })
    let turn = try await root.discover(into: destination, opportunity: .foreground)
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.validate(turn, for: source) }
    await root.close()
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.validate(turn, for: destination) }
    try await destination.quiesce(); try await source.quiesce()
}

@Test(arguments: [false, true])
func repositoryExchangeReopenedOwnerRejectsPreviousTurn(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path)
    let selection: LocalStoreSelection, oldSession: UUID, turn: RepositoryDiscoveryTurn
    do {
        let receiver = try await newSession(initial, protection)
        selection = await receiver.selection; oldSession = await receiver.incarnation
        turn = try await root.discover(into: receiver, opportunity: .foreground, budget: 1)
        try await root.validate(turn, for: receiver)
        try await receiver.quiesce()
        await #expect(throws: StorageError.closed) { try await root.validate(turn, for: receiver) }
    }
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let reopenedSession = await reopened.incarnation
    #expect(reopenedSession != oldSession)
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.validate(turn, for: reopened) }
    let fresh = try await root.discover(into: reopened, opportunity: .foreground, budget: 16)
    try await root.validate(fresh, for: reopened)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await reopened.quiesce(); await root.close()
}

@Test(arguments: [false, true])
func repositoryExchangeMultiplePrerequisitesAndRepackagedOperations(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), left = try await newSession(initial, protection)
    let right = try await newSession(initial, protection), source = try await newSession(initial, protection)
    let destination = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path)
    let a = try await put("left parent", birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1, session: left)
    let b = try await put("right parent", birth: NoteBirth(bytes: .init(repeating: 2, count: 16)), generation: 1, session: right)
    _ = try await source.receive(left.retainedObject(at: a.object)); _ = try await source.receive(right.retainedObject(at: b.object))
    let child = try await put("joined child", birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 2, session: source)
    let bytes = try await source.retainedObject(at: child.object)
    try deliverFile(bytes, relative: ImmutableRepositoryLocator.segment(child.object).relativePath, to: path)
    let waiting = try await discoverPass(root, into: destination)
    #expect(waiting.contains { if case .received(_, _, .waiting(let missing)) = $0.outcome {
        missing.contains(.acceptedHistory(a.object)) && missing.contains(.acceptedHistory(b.object))
    } else { false } })
    try await deliverFile(right.retainedObject(at: b.object), relative: ImmutableRepositoryLocator.segment(b.object).relativePath, to: path)
    _ = try await discoverPass(root, into: destination)
    guard case .waiting(let remaining) = try await destination.receivedObjectStatus(at: child.object) else {
        Issue.record("One arriving prerequisite must leave the other required parent outstanding"); return
    }
    #expect(remaining == [.acceptedHistory(a.object)])
    try await deliverFile(left.retainedObject(at: a.object), relative: ImmutableRepositoryLocator.segment(a.object).relativePath, to: path)
    _ = try await discoverPass(root, into: destination)
    let before = try await destination.snapshot()
    #expect(before.notes.map(\.value.body.string).sorted() == ["joined child", "right parent"])
    let opened = try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection)
    let repackaged = try ObjectEnvelopeV1.seal(payload: opened.payload, kind: .changes, collection: initial.descriptor.collection,
        writer: WriterEpoch(bytes: .init(repeating: 89, count: 16)), sequence: 0, protection: protection)
    let repackLocator = try ObjectEnvelopeV1.open(repackaged, collection: initial.descriptor.collection, protection: protection).locator
    try deliverFile(repackaged, relative: RepositoryProtocolDirectory.writer(repackLocator.writerEpoch).relativePath + "/renamed-copy", to: path)
    _ = try await discoverPass(root, into: destination)
    let after = try await destination.snapshot(), lane = await destination.lane
    #expect(after.notes == before.notes && after.context == before.context && after.through == before.through + 1)
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") } == [[.integer(5)]])
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM action_occurrences WHERE object_id=?", [.blob(repackLocator.segmentID.bytes)]) } == [[.integer(1)]])
    #expect(try await destination.retainedObject(at: repackLocator) == repackaged)
    for store in [left, right, source, destination] { try await store.quiesce() }; await root.close()
}

@Test(arguments: [false, true])
func repositoryExchangeRejectionFailureAndBlockedNeighbors(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    var destination = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    func envelope(_ payload: [UInt8], writer: UInt8) throws -> ([UInt8], SegmentLocator) {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: .changes, collection: initial.descriptor.collection,
            writer: WriterEpoch(bytes: .init(repeating: writer, count: 16)), sequence: 0, protection: protection)
        return (bytes, try ObjectEnvelopeV1.open(bytes, collection: initial.descriptor.collection, protection: protection).locator)
    }
    let malformed = try envelope([], writer: 81)
    try deliverFile(malformed.0, relative: ImmutableRepositoryLocator.segment(malformed.1).relativePath, to: path)
    let lane = await destination.lane, selection = await destination.selection
    try await lane.perform { try $0.exec("CREATE TEMP TRIGGER fail_repository_rejection BEFORE DELETE ON ready_objects BEGIN SELECT RAISE(ABORT,'repository rejection failure'); END") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) { try await discoverPass(root, into: destination) }
        #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects JOIN ready_objects USING(object_id)") } == [[.blob(malformed.0)]])
        #expect(try await lane.perform { try $0.rows("SELECT object_id FROM rejected_objects") }.isEmpty)
        #expect(try await destination.snapshot().through == 1)
    }
    // Abrupt connection loss preserves the actual retryable durable queue.
    await lane.close()
    destination = try await LocalStoreSession.open(selection: selection, protection: protection)
    let future = try envelope(Array("NVCHG1\r\n".utf8) + [0, 2], writer: 82)
    let saved = try await put("unrelated progress", birth: NoteBirth(bytes: .init(repeating: 1, count: 16)), generation: 1, session: source)
    let good = try await source.retainedObject(at: saved.object)
    let payload = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(good, collection: initial.descriptor.collection, protection: protection).payload)
    let descendant = try envelope(ChangesPayloadV1(dependencies: DependencyLocatorTable(payload.dependencies.entries + [future.1, malformed.1]),
        operations: payload.operations, actions: payload.actions).encodedV1(), writer: 83)
    for (bytes, locator) in [future, descendant, (good, saved.object)] {
        try deliverFile(bytes, relative: ImmutableRepositoryLocator.segment(locator).relativePath, to: path)
    }
    try deliverFile([0, 1, 2], relative: RepositoryProtocolDirectory.writer(future.1.writerEpoch).relativePath + "/unsealed-neighbor", to: path)
    let foreign = try ObjectEnvelopeV1.seal(payload: [], kind: .changes, collection: CollectionID(bytes: .init(repeating: 94, count: 16)),
        writer: future.1.writerEpoch, sequence: 9, protection: protection)
    try deliverFile(foreign, relative: RepositoryProtocolDirectory.writer(future.1.writerEpoch).relativePath + "/foreign-neighbor", to: path)
    let entries = try await discoverPass(root, into: destination)
    #expect(entries.contains { if case .rejected(.unsupportedFormat) = $0.outcome { true } else { false } })
    #expect(entries.filter { if case .invalid = $0.outcome { true } else { false } }.count == 2)
    guard case .blocked(let roots, _) = try await destination.receivedObjectStatus(at: descendant.1) else {
        Issue.record("Rejected prerequisites must retain the blocked descendant's reason"); return
    }
    #expect(Set(roots.map(\.object)) == Set([future.1.segmentID, malformed.1.segmentID]))
    #expect(roots.first { $0.object == future.1.segmentID }?.reason == .unsupportedFormat)
    #expect(try await destination.lane.perform {
        try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(descendant.1.segmentID.bytes)])
    } == [[.blob(descendant.0)]])
    #expect(try await destination.snapshot().notes.map(\.value.body.string).sorted() == ["unrelated progress", "untouched"])
    let membership = try await destination.lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") }
    try await destination.quiesce(); destination = try await LocalStoreSession.open(selection: selection, protection: protection)
    _ = try await discoverPass(root, into: destination)
    #expect(try await destination.lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") } == membership)
    try await destination.quiesce(); try await source.quiesce(); await root.close()
}

@Test(arguments: [false, true])
func repositoryExchangeHintWriteFailurePreservesExactAcceptance(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let destination = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let saved = try await put("accepted despite failed observation bookkeeping", birth: birth, generation: 1, session: source)
    let bytes = try await source.retainedObject(at: saved.object), relative = ImmutableRepositoryLocator.segment(saved.object).relativePath
    try deliverFile(bytes, relative: relative, to: path)
    let lane = await destination.lane
    try await lane.perform { try $0.exec("CREATE TEMP TRIGGER fail_seen BEFORE INSERT ON private_groups WHEN substr(NEW.group_key,1,16)=X'7265706F7369746F72792D7365656E2F' BEGIN SELECT RAISE(ABORT,'hint failure'); END") }
    for _ in 0..<2 {
        await #expect(throws: StorageError.database(1811)) { try await discoverPass(root, into: destination) }
        #expect(try await destination.snapshot().through == 2)
        #expect(try await destination.retainedObject(at: saved.object) == bytes)
    }
    try await lane.perform { try $0.exec("DROP TRIGGER fail_seen") }
    _ = try await discoverPass(root, into: destination)
    let counter = RepositoryReadCounter()
    var ended = false
    while !ended {
        let turn = try await root.discover(into: destination, opportunity: .backgroundTurn, budget: 7,
            hooks: RepositoryDiscoveryHooks(read: { _ in await counter.add() }))
        ended = turn.passEnded
    }
    #expect(await counter.count == 0)
    #expect(try await destination.snapshot().through == 2)
    try await source.quiesce(); try await destination.quiesce(); await root.close()
}
