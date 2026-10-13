import NVStorageTestSupport
import Foundation
import Crypto
import Testing
import NVStorageCore
@testable import NVStorageRuntime

func deliverFile(_ bytes: [UInt8], relative: String, to path: String) throws {
    let target = URL(fileURLWithPath: path + "/" + relative)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(bytes).write(to: target, options: .atomic)
}

func discoverPass(_ root: RepositoryRootSession, into store: LocalStoreSession,
                  budget: Int = 7) async throws -> [RepositoryDiscoveryEntry] {
    var entries: [RepositoryDiscoveryEntry] = []
    for _ in 0..<100_000 {
        let turn = try await root.discover(into: store, opportunity: .backgroundTurn, budget: budget)
        try await root.validate(turn, for: store)
        #expect(turn.entries.count <= budget)
        #expect(await root.listingResourceCount() <= 2)
        entries += turn.entries
        if turn.passEnded { return entries }
    }
    throw StorageError.limit
}

func discoverPass(_ root: RepositoryRootSession, into candidate: BootstrapCandidate) async throws -> [RepositoryDiscoveryEntry] {
    var entries: [RepositoryDiscoveryEntry] = []
    for _ in 0..<100_000 {
        let turn = try await root.discover(into: candidate, opportunity: .backgroundTurn, budget: 7)
        entries += turn.entries
        if turn.passEnded { return entries }
    }
    throw StorageError.limit
}

@Test(arguments: [false, true]) func repositoryExchangeBootstrapsCompleteHistoryAndTail(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let a = try repositoryDirectory(), aRoot = try await RepositoryRootSession.open(directory: a)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16)), deleted = try NoteBirth(bytes: .init(repeating: 2, count: 16))
    let edit = try await put("transported edit", birth: birth, generation: 1, session: source)
    let remove = try await CapturedActionGroup(snapshot: source.snapshot(), kind: .deleteBatch,
        changes: [.delete(CapturedNoteGeneration(birth: deleted, generation: 2))])
    let deletion = try requireReceipt(await source.persist(capture: remove))
    let paths = try await publishRepository(source, to: aRoot)
    let b = try repositoryDirectory(), bRoot = try await RepositoryRootSession.open(directory: b)
    // The provider first discloses only the actual descriptor and selected root.
    let descriptorPath = try #require(paths.first { $0.relativePath.hasSuffix(".nvkey") }).relativePath
    try deliverFile(Array(Data(contentsOf: URL(fileURLWithPath: a + "/" + descriptorPath))), relative: descriptorPath, to: b)
    let descriptorObservation = try await bRoot.observe(descriptorPath, using: bRoot.permission())
    guard case .contents(let contents) = try await bRoot.read(descriptorObservation, maximumBytes: 4096, using: bRoot.permission()) else { throw StorageError.incomplete }
    let descriptor = try BootstrapDescriptorV1.decodeV1(contents.bytes)
    let unlocked: ObjectProtectionV1 = try descriptor.keyID.map { try .encrypted(keyID: $0, key: descriptor.unwrap(passphrase: "synthetic")) } ?? .publicHash
    let selection = try LocalStoreSelection(directory: repositoryDirectory() + "/private", store: LocalStoreID(bytes: .init(repeating: 71, count: 16)), descriptor: descriptor)
    var candidate = try await BootstrapCandidate.create(selection: selection, snapshot: initial.snapshot, protection: unlocked)
    let rootPath = ImmutableRepositoryLocator.segment(initial.snapshot).relativePath
    try deliverFile(try #require(initial.objects[initial.snapshot]), relative: rootPath, to: b)
    let partial = try await discoverPass(bRoot, into: candidate)
    #expect(partial.contains { if case .received(let loc, .snapshotRoot, .retainedForAssembly) = $0.outcome { loc == initial.snapshot } else { false } })
    await #expect(throws: InitialBootstrapValidationError.self) { try await candidate.complete(snapshot: initial.snapshot) }
    try await candidate.close()
    candidate = try await BootstrapCandidate.resume(selection: selection, protection: unlocked)
    for locator in paths.reversed() {
        let bytes = try Array(Data(contentsOf: URL(fileURLWithPath: a + "/" + locator.relativePath)))
        try deliverFile(bytes, relative: locator.relativePath, to: b)
    }
    _ = try await discoverPass(bRoot, into: candidate)
    let destination = try await candidate.complete(snapshot: initial.snapshot)
    let recovered = try await destination.snapshot()
    #expect(recovered.notes.map(\.value.body.string) == ["transported edit"])
    #expect(recovered.notes.map(\.birth) == [birth])
    #expect(try await destination.retainedObject(at: edit.object) == source.retainedObject(at: edit.object))
    #expect(try await destination.retainedObject(at: deletion.object) == source.retainedObject(at: deletion.object))
    let lane = await destination.lane
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM actions")[0][0].number } == 4)
    let expectedContext = try await source.snapshot().context
    #expect(recovered.context == expectedContext)
    try await destination.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: unlocked)
    #expect(try await reopened.snapshot().notes == recovered.notes)
    #expect(try await reopened.snapshot().context == expectedContext)
    try await reopened.quiesce(); try await source.quiesce(); await aRoot.close(); await bRoot.close()
}

@Test(arguments: [false, true]) func repositoryExchangeFindsLateLowerSequenceWithoutHint(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    var destination = try await newSession(initial, protection)
    let path = try repositoryDirectory()
    var root = try await RepositoryRootSession.open(directory: path)
    await root.noteRepositoryChange()
    _ = try await discoverPass(root, into: destination)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let parent = try await put("parent", birth: birth, generation: 1, session: source)
    let child = try await put("child", birth: birth, generation: 2, session: source)
    #expect(child.object.sequence > parent.object.sequence)
    try await deliverFile(source.retainedObject(at: child.object), relative: ImmutableRepositoryLocator.segment(child.object).relativePath, to: path)
    let first = try await discoverPass(root, into: destination)
    #expect(first.contains { if case .received(let loc, _, .waiting(let needs)) = $0.outcome { loc == child.object && needs.contains { $0.locator == parent.object } } else { false } })
    #expect(try await destination.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let selection = await destination.selection
    try await destination.quiesce(); await root.close()
    destination = try await LocalStoreSession.open(selection: selection, protection: protection)
    root = try await RepositoryRootSession.open(directory: path)
    try await deliverFile(source.retainedObject(at: parent.object), relative: ImmutableRepositoryLocator.segment(parent.object).relativePath, to: path)
    let renamed = RepositoryProtocolDirectory.writer(child.object.writerEpoch).relativePath + "/provider-conflict-copy.nvseg"
    try await deliverFile(source.retainedObject(at: child.object), relative: renamed, to: path)
    // Foreground and subsequent bounded turns are ordinary opportunities; no new hint is sent.
    _ = try await root.discover(into: destination, opportunity: .foreground, budget: 1)
    _ = try await discoverPass(root, into: destination)
    #expect(try await destination.snapshot().notes.map(\.value.body.string).sorted() == ["child", "untouched"])
    #expect(try await destination.snapshot().context == source.snapshot().context)
    let lane = await destination.lane
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM actions")[0][0].number } == 4)
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM object_waits")[0][0].number } == 0)
    let all = try await publishRepository(destination, to: root)
    let sourceIDs = try await source.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") }
    #expect(try await lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") } == sourceIDs)
    #expect(all.count == initial.objects.count + 3)
    try await source.quiesce(); try await destination.quiesce(); await root.close()
}

@Test(arguments: [false, true]) func repositoryExchangeHintsRecheckReplacementAndEqualBodyContext(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let destination = try await newSession(initial, protection), path = try repositoryDirectory()
    let root = try await RepositoryRootSession.open(directory: path), birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let first = try await put("same body", birth: birth, generation: 1, session: source)
    let relative = ImmutableRepositoryLocator.segment(first.object).relativePath
    try await deliverFile(source.retainedObject(at: first.object), relative: relative, to: path)
    _ = try await discoverPass(root, into: destination)
    let before = try await destination.snapshot()
    let unchanged = try await discoverPass(root, into: destination)
    #expect(unchanged.contains { if case .unchangedAccepted(let id) = $0.outcome { id == first.object.segmentID } else { false } })
    let second = try await put("same body", birth: birth, generation: 2, session: source)
    // A provider-renamed envelope can occupy an older canonical-looking filename.
    try await deliverFile(source.retainedObject(at: second.object), relative: relative, to: path)
    let replacement = try await discoverPass(root, into: destination)
    #expect(replacement.contains { if case .received(let loc, _, .accepted) = $0.outcome { loc == second.object } else { false } })
    let after = try await destination.snapshot()
    #expect(after.notes.map(\.value) == before.notes.map(\.value))
    #expect(after.context != before.context)
    #expect(after.notes.map(\.represented) != before.notes.map(\.represented))
    let lane = await destination.lane
    try await lane.perform { try $0.run("UPDATE private_groups SET payload=zeroblob(96) WHERE substr(group_key,1,16)=?", [.blob(Array("repository-seen/".utf8))]) }
    let repaired = try await discoverPass(root, into: destination)
    #expect(repaired.contains { if case .received(let loc, _, .accepted) = $0.outcome { loc == second.object } else { false } })
    #expect(try await destination.snapshot().through == after.through)
    try await source.quiesce(); try await destination.quiesce(); await root.close()
}

@Test(arguments: [false, true])
func repositoryExchangePagedSnapshotWaitsAcrossRestart(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    var destination = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let body = String(repeating: "paged revision ", count: 40_000)
    _ = try await put(body, birth: birth, generation: 1, session: source)
    let receipt = try snapshotReceipt(await source.persistGeneralSnapshot(capture: source.captureGeneralSnapshot()))
    let preview = try await GeneralSnapshotPreviewV1.read(snapshot: receipt.snapshot,
        collection: initial.descriptor.collection, protection: protection) { try await source.retainedObject(at: $0) }
    try #require(receipt.pages.count >= 4)
    var leaves: [SegmentLocator] = []
    for page in receipt.pages {
        let opened = try await ObjectEnvelopeV1.open(source.retainedObject(at: page),
            collection: initial.descriptor.collection, protection: protection)
        if case .data = try GeneralSnapshotPageV1.decodeV1(opened.payload).contents { leaves.append(page) }
    }
    let held = try #require(leaves.sorted { $0.sequence < $1.sequence }.first)
    let a = try repositoryDirectory(), aRoot = try await RepositoryRootSession.open(directory: a)
    let paths = try await publishRepository(source, to: aRoot)
    let b = try repositoryDirectory(), bRoot = try await RepositoryRootSession.open(directory: b)
    let rootPath = ImmutableRepositoryLocator.segment(receipt.snapshot).relativePath
    let rootBytes = try await source.retainedObject(at: receipt.snapshot)
    try deliverFile(rootBytes, relative: rootPath, to: b)
    let partial = try await discoverPass(bRoot, into: destination)
    #expect(partial.contains { if case .received(let locator, .snapshotRoot, .waiting) = $0.outcome { locator == receipt.snapshot } else { false } })
    let rootID = SQLValue.blob(receipt.snapshot.segmentID.bytes)
    #expect(try await destination.lane.perform { try $0.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [rootID]) }.isEmpty)
    #expect(try await destination.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let selection = await destination.selection
    try await destination.quiesce()
    destination = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.incomplete) { try await destination.retainedObject(at: receipt.snapshot) }
    #expect(try await destination.lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [rootID]) } == [[.blob(rootBytes)]])
    let heldPath = ImmutableRepositoryLocator.segment(held).relativePath
    for path in paths where path.relativePath != rootPath && path.relativePath != heldPath {
        try deliverFile(Array(Data(contentsOf: URL(fileURLWithPath: a + "/" + path.relativePath))), relative: path.relativePath, to: b)
    }
    _ = try await discoverPass(bRoot, into: destination)
    #expect(try await destination.snapshot().notes.map(\.value.body.string).sorted() == [body, "untouched"])
    let lane = await destination.lane
    #expect(try await lane.perform { try $0.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [rootID]) }.isEmpty)
    #expect(try await lane.perform { try $0.rows("SELECT 1 FROM object_waits WHERE child=? AND prerequisite=?",
        [rootID, .blob(held.segmentID.bytes)]) } == [[.integer(1)]])
    try await deliverFile(source.retainedObject(at: held), relative: heldPath, to: b)
    _ = try await discoverPass(bRoot, into: destination)
    #expect(try await lane.perform { try $0.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [rootID]) } == [[.integer(1)]])
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") } == [[.integer(5)], [.integer(3)]])
    let expectedEdges = Set(preview.requiredLocators.map(\.segmentID)).union([preview.root.tree.locator.segmentID])
    #expect(try await lane.perform {
        try Set($0.rows("SELECT prerequisite FROM accepted_dependencies WHERE child=?", [rootID]).map { try SegmentID(bytes: $0[0].bytes) })
    } == expectedEdges)
    #expect(try await destination.retainedObject(at: receipt.snapshot) == rootBytes)
    #expect(Set(preview.pages) == receipt.pages)
    for page in receipt.pages {
        #expect(try await lane.perform { try $0.rows("SELECT 1 FROM accepted_objects WHERE object_id=?", [.blob(page.segmentID.bytes)]) } == [[.integer(1)]])
        #expect(try await destination.retainedObject(at: page) == source.retainedObject(at: page))
    }
    #expect(try await destination.snapshot().notes == source.snapshot().notes)
    #expect(try await destination.snapshot().context == source.snapshot().context)
    try await destination.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == [body, "untouched"])
    #expect(try await reopened.snapshot().context == source.snapshot().context)
    try await reopened.quiesce(); try await source.quiesce(); await aRoot.close(); await bRoot.close()
}
