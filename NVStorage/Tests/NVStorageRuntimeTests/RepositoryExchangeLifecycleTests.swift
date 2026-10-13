import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true])
func repositoryExchangeReopenReusesCheckedObservations(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    var destination = try await newSession(initial, protection)
    let path = try repositoryDirectory(), birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    var root = try await RepositoryRootSession.open(directory: path)
    for generation in 1...4 {
        let saved = try await put("saved before reopen \(generation)", birth: birth, generation: UInt64(generation), session: source)
        try await deliverFile(source.retainedObject(at: saved.object),
            relative: ImmutableRepositoryLocator.segment(saved.object).relativePath, to: path)
    }
    _ = try await discoverPass(root, into: destination)
    let selection = await destination.selection, oldPermission = try await root.permission()
    try await destination.quiesce(); await root.close()
    destination = try await .open(selection: selection, protection: protection)
    root = try await .open(directory: path)
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await root.observe("NV Data", using: oldPermission)
    }
    let reads = RepositoryReadCounter()
    var ended = false
    while !ended {
        let turn = try await root.discover(into: destination, opportunity: .initialOpen, budget: 7,
            hooks: RepositoryDiscoveryHooks(read: { _ in await reads.add() }))
        try await root.validate(turn, for: destination)
        ended = turn.passEnded
    }
    #expect(await reads.count == 0, "Fresh rooted observations reuse persisted accepted-file hints after reopening")
    let newer = try await put("new after reopen", birth: birth, generation: 5, session: source)
    let locator = ImmutableRepositoryLocator.segment(newer.object)
    try await deliverFile(source.retainedObject(at: newer.object), relative: locator.relativePath, to: path)
    let entries = try await discoverPass(root, into: destination)
    #expect(entries.filter { if case .received(let value, _, .accepted) = $0.outcome { value == newer.object } else { false } }.count == 1)
    #expect(try await destination.snapshot().context == source.snapshot().context)
    try await destination.quiesce(); try await source.quiesce(); await root.close()
}

@Test(arguments: [false, true])
func repositoryExchangeOldBackupDeleteConcurrentEditAndFreshRestore(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    var original = try await newSession(initial, protection)
    let originalSelection = await original.selection, copyPath = try repositoryDirectory() + "/restored-private-backup"
    try await original.quiesce()
    try FileManager.default.copyItem(atPath: originalSelection.directory, toPath: copyPath)
    let copySelection = LocalStoreSelection(directory: copyPath, store: originalSelection.store, descriptor: originalSelection.descriptor)
    original = try await .open(selection: originalSelection, protection: protection)
    var restored = try await LocalStoreSession.open(selection: copySelection, protection: protection)
    let old = try NoteBirth(bytes: .init(repeating: 1, count: 16)), fresh = try NoteBirth(bytes: .init(repeating: 3, count: 16))
    let removed = try await CapturedActionGroup(snapshot: original.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: old, generation: 1))])
    let deletion = try requireReceipt(await original.persist(capture: removed))
    let edit = try await put("edited while unaware of Delete", birth: old, generation: 1, session: restored)
    #expect(deletion.object.writerEpoch != edit.object.writerEpoch)
    let deletedPayload = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(original.retainedObject(at: deletion.object),
        collection: initial.descriptor.collection, protection: protection).payload)
    let editedPayload = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(restored.retainedObject(at: edit.object),
        collection: initial.descriptor.collection, protection: protection).payload)
    #expect(deletedPayload.actions[0].action.origin != editedPayload.actions[0].action.origin)
    let a = try repositoryDirectory(), b = try repositoryDirectory()
    let aRoot = try await RepositoryRootSession.open(directory: a), bRoot = try await RepositoryRootSession.open(directory: b)
    let aFiles = try await publishRepository(original, to: aRoot), bFiles = try await publishRepository(restored, to: bRoot)
    for locator in aFiles { try deliverFile(Array(Data(contentsOf: URL(fileURLWithPath: a + "/" + locator.relativePath))), relative: locator.relativePath, to: b) }
    for locator in bFiles { try deliverFile(Array(Data(contentsOf: URL(fileURLWithPath: b + "/" + locator.relativePath))), relative: locator.relativePath, to: a) }
    _ = try await discoverPass(aRoot, into: original); _ = try await discoverPass(bRoot, into: restored)
    let left = try await original.snapshot(), right = try await restored.snapshot()
    #expect(left.notes == right.notes && left.context == right.context)
    #expect(!left.notes.contains { $0.birth == old })
    let preserved = try #require(left.notes.first { $0.automatic != nil })
    #expect(preserved.value.body.string == "edited while unaware of Delete" && preserved.birth != old)
    let deletedEntry = try #require(try await original.history(for: .recentlyDeleted).entries.first { $0.birth == old })
    let recovery = try await original.restoration(from: deletedEntry, as: CapturedNoteGeneration(birth: fresh, generation: 2))
    let captured = try await CapturedActionGroup(snapshot: original.snapshot(), restoring: [recovery])
    _ = try requireReceipt(await original.persist(capture: captured))
    let restoredFiles = try await publishRepository(original, to: aRoot)
    for locator in restoredFiles { try deliverFile(Array(Data(contentsOf: URL(fileURLWithPath: a + "/" + locator.relativePath))), relative: locator.relativePath, to: b) }
    _ = try await discoverPass(bRoot, into: restored)
    let complete = try await restored.snapshot()
    #expect(complete.notes.first { $0.birth == fresh }?.value.body.string == "A")
    #expect(complete.notes.first { $0.birth == preserved.birth }?.value.body.string == "edited while unaware of Delete")
    #expect(!complete.notes.contains { $0.birth == old })
    #expect(try await restored.history(for: .recentlyDeleted).entries.isEmpty)
    let membership = try await restored.lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") }
    try await restored.quiesce(); restored = try await .open(selection: copySelection, protection: protection)
    _ = try await discoverPass(bRoot, into: restored)
    #expect(try await restored.snapshot().notes == complete.notes)
    #expect(try await restored.lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") } == membership)
    try await original.quiesce(); try await restored.quiesce(); await aRoot.close(); await bRoot.close()
}

@Test(.timeLimit(.minutes(10)), arguments: [false, true])
func repositoryExchangeUnchangedHistoryReadWorkRemainsBounded(encrypted: Bool) async throws {
    let first = try await GrowthHistoryFixtures.shared.fixture(encrypted: encrypted, actions: 64)
    let (initial, protection) = (first.initial, first.protection)
    var source = try await first.openSender()
    let destination = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    var size = 0
    for target in [64, 256, 1024] {
        let history = try await GrowthHistoryFixtures.shared.fixture(encrypted: encrypted, actions: target)
        if target != 64 { try await source.quiesce(); source = try await history.openSender() }
        while size < target {
            let saved = history.history[size]
            size += 1
            try deliverFile(saved.bytes, relative: ImmutableRepositoryLocator.segment(saved.locator).relativePath, to: path)
        }
        _ = try await discoverPass(root, into: destination)
        let reads = RepositoryReadCounter(), start = ContinuousClock.now
        var ended = false, turns = 0
        while !ended {
            let turn = try await root.discover(into: destination, opportunity: .backgroundTurn, budget: 16,
                hooks: RepositoryDiscoveryHooks(read: { _ in await reads.add() }))
            try await root.validate(turn, for: destination)
            #expect(turn.entries.count <= 16)
            #expect(await root.listingResourceCount() <= 2)
            ended = turn.passEnded; turns += 1
        }
        #expect(await reads.count == 0, "Unchanged accepted files consume observations rather than historical body reads")
        #expect(try await destination.snapshot().context == source.snapshot().context)
        print("DISCOVERY-WORK history=\(target) bodyReads=\(await reads.count) turns=\(turns) elapsed=\(start.duration(to: .now))")
    }
    let saved = try await GrowthHistoryFixtures.shared.fixture(encrypted: encrypted, actions: 1024).following
    try deliverFile(saved.bytes, relative: ImmutableRepositoryLocator.segment(saved.locator).relativePath, to: path)
    let reads = RepositoryReadCounter()
    var ended = false
    while !ended {
        let turn = try await root.discover(into: destination, opportunity: .saveSettled, budget: 16,
            hooks: RepositoryDiscoveryHooks(read: { _ in await reads.add() }))
        ended = turn.passEnded
    }
    #expect(await reads.count == 1)
    #expect(try await destination.snapshot().notes.first { $0.birth == birth }?.value.body.string == "one new file")
    try await destination.quiesce(); try await source.quiesce(); await root.close()
}
