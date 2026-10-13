import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true], [false, true])
func repositoryExchangeSharedBootstrapBeforeDescriptor(encrypted: Bool, deleting: Bool) async throws {
    let (descriptor, snapshot, objects, protection, _) = try sharedBootstrap(encrypted: encrypted, delete: deleting)
    let sourceSelection = try LocalStoreSelection(directory: repositoryDirectory() + "/source",
        store: LocalStoreID(bytes: uuidBytes()), descriptor: descriptor)
    let assembling = try await BootstrapCandidate.create(selection: sourceSelection, snapshot: snapshot, protection: protection)
    for bytes in objects.values { _ = try await assembling.retain(bytes) }
    let source = try await assembling.complete(snapshot: snapshot)
    let a = try repositoryDirectory(), aRoot = try await RepositoryRootSession.open(directory: a)
    let installed = try await publishRepository(source, to: aRoot)
    let b = try repositoryDirectory(), bRoot = try await RepositoryRootSession.open(directory: b)
    let selection = try LocalStoreSelection(directory: repositoryDirectory() + "/receiver",
        store: LocalStoreID(bytes: uuidBytes()), descriptor: descriptor)
    // Validated selection/unlock input can precede disclosure of its repository descriptor file.
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: snapshot, protection: protection)
    let rootPath = ImmutableRepositoryLocator.segment(snapshot).relativePath
    try deliverFile(try #require(objects[snapshot]), relative: rootPath, to: b)
    _ = try await discoverPass(bRoot, into: candidate)
    await #expect(throws: InitialBootstrapValidationError.self) { try await candidate.complete(snapshot: snapshot) }
    for path in installed where !path.relativePath.hasSuffix(".nvkey") {
        try deliverFile(Array(Data(contentsOf: URL(fileURLWithPath: a + "/" + path.relativePath))), relative: path.relativePath, to: b)
    }
    _ = try await discoverPass(bRoot, into: candidate)
    let destination = try await candidate.complete(snapshot: snapshot)
    let values = try await destination.snapshot().notes.map(\.value.body.string).sorted()
    #expect(values == (deleting ? ["sentinel B"] : ["later E", "sentinel B"]))
    let lane = await destination.lane
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM operations UNION ALL SELECT count(*) FROM actions") } == [[.integer(5)], [.integer(2)]])
    let membership = try await lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") }
    let descriptorPath = try #require(installed.first { $0.relativePath.hasSuffix(".nvkey") }).relativePath
    try deliverFile(descriptor.encodedBytes, relative: descriptorPath, to: b)
    let disclosed = try await discoverPass(bRoot, into: destination)
    #expect(disclosed.contains { if case .descriptor(let value) = $0.outcome { value.encodedBytes == descriptor.encodedBytes } else { false } })
    #expect(try await lane.perform { try $0.rows("SELECT object_id,seq FROM accepted_objects ORDER BY object_id") } == membership)
    #expect(try await destination.snapshot().context == source.snapshot().context)
    try await destination.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == values)
    try await reopened.quiesce(); try await source.quiesce(); await aRoot.close(); await bRoot.close()
}

@Test(arguments: [false, true])
func repositoryExchangeConcurrentCollectionsKeepExplicitSelection(encrypted: Bool) async throws {
    let (left, protection) = try testInitial(encrypted)
    let right = try InitialCollectionV1.build(collection: CollectionID(bytes: .init(repeating: 61, count: 16)),
        notes: [(NoteBirth(bytes: .init(repeating: 1, count: 16)), testValue("independent collection"))],
        protection: protection, passphrase: encrypted ? "synthetic" : nil)
    let a = try await newSession(left, protection), b = try await newSession(right, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    _ = try await publishRepository(a, to: root); _ = try await publishRepository(b, to: root)
    for initial in [left, right] {
        let selection = try LocalStoreSelection(directory: repositoryDirectory() + "/receiver",
            store: LocalStoreID(bytes: uuidBytes()), descriptor: initial.descriptor)
        let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: initial.snapshot, protection: protection)
        let entries = try await discoverPass(root, into: candidate)
        #expect(entries.contains { if case .invalid(.wrongScope) = $0.outcome { true } else { false } })
        let store = try await candidate.complete(snapshot: initial.snapshot)
        let expected = initial.descriptor.collection == left.descriptor.collection ? ["A", "untouched"] : ["independent collection"]
        #expect(try await store.snapshot().notes.map(\.value.body.string).sorted() == expected)
        let ids = try await store.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") }.map { try $0[0].bytes }
        #expect(Set(ids) == Set(initial.objects.keys.map(\.segmentID.bytes) + [initial.descriptor.descriptorID]))
        try await store.quiesce()
    }
    try await a.quiesce(); try await b.quiesce(); await root.close()
}
