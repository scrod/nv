import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionBootstrapRetriesNormalOpenAfterCommittedImport(fixture: RepositoryLocalFixture) async throws {
    let directory = try repositoryDirectory() + "/candidate"
    let selection = try LocalStoreSelection(directory: directory, store: .init(bytes: uuidBytes()), descriptor: fixture.initial.descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: fixture.initial.snapshot, protection: fixture.protection)
    for bytes in fixture.initial.objects.values { _ = try await candidate.retain(bytes) }
    let database = directory + "/Collection.sqlite"
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database) }
    await #expect(throws: (any Error).self) {
        try await candidate.complete(snapshot: fixture.initial.snapshot, beforeReopen: {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: database)
        })
    }
    #expect(try FileManager.default.attributesOfItem(atPath: database)[.posixPermissions] as? Int == 0)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: database)
    let reopened = try await candidate.complete(snapshot: fixture.initial.snapshot)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    for (locator, bytes) in fixture.initial.objects { #expect(try await reopened.retainedObject(at: locator) == bytes) }
    try await reopened.quiesce()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionBootstrapPreviewRequiresEveryPageAndCompleteDigest(fixture: RepositoryLocalFixture) async throws {
    let initial = fixture.initial, protection = fixture.protection, collection = initial.descriptor.collection
    let root = try InitialSnapshotRootV1.decodeV1(ObjectEnvelopeV1.open(#require(initial.objects[initial.snapshot]), collection: collection, protection: protection).payload)
    let selection = try LocalStoreSelection(directory: repositoryDirectory() + "/candidate", store: .init(bytes: uuidBytes()), descriptor: initial.descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: initial.snapshot, protection: protection)
    _ = try await candidate.retain(#require(initial.objects[initial.snapshot]))
    await #expect(throws: GeneralSnapshotError.missingObject(root.pages[0].locator)) { try await candidate.preview(snapshot: initial.snapshot) }
    for page in root.pages { _ = try await candidate.retain(#require(initial.objects[page.locator])) }
    let preview = try await candidate.preview(snapshot: initial.snapshot)
    #expect(preview.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    #expect(Set(preview.notes.map(\.birth)) == Set(try [1, 2].map { try NoteBirth(bytes: .init(repeating: $0, count: 16)) }))
    #expect(preview.collection == collection && preview.snapshot == initial.snapshot)
    await #expect(throws: InitialBootstrapValidationError.self) { try await candidate.complete(snapshot: initial.snapshot) }
    try await candidate.close()
    await #expect(throws: StorageError.incomplete) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    let resumed = try await BootstrapCandidate.resume(selection: selection, protection: protection)
    for bytes in initial.objects.values { _ = try await resumed.retain(bytes) }
    let complete = try await resumed.complete(snapshot: initial.snapshot)
    #expect(try await complete.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await complete.quiesce()

    let bad = try InitialSnapshotRootV1(importID: root.importID, initialCount: root.initialCount,
        digest: .init(bytes: Array(repeating: 99, count: 32)), dependencies: root.dependencies,
        completion: root.completion, frontier: root.frontier, pages: root.pages)
    let badBytes = try ObjectEnvelopeV1.seal(payload: bad.encodedV1(), kind: .snapshotRoot, collection: collection,
        writer: .init(bytes: uuidBytes()), sequence: 0, protection: protection)
    let badLocator = try ObjectEnvelopeV1.open(badBytes, collection: collection, protection: protection).locator
    let badSelection = try LocalStoreSelection(directory: repositoryDirectory() + "/candidate", store: .init(bytes: uuidBytes()), descriptor: initial.descriptor)
    let badCandidate = try await BootstrapCandidate.create(selection: badSelection, snapshot: badLocator, protection: protection)
    _ = try await badCandidate.retain(badBytes)
    for page in root.pages { _ = try await badCandidate.retain(#require(initial.objects[page.locator])) }
    await #expect(throws: InitialBootstrapValidationError.invalidSnapshot) { try await badCandidate.preview(snapshot: badLocator) }
    try await badCandidate.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionBootstrapGeneralPreviewKeepsHistoryClosureSeparate(fixture: RepositoryLocalFixture) async throws {
    let source = try await newSession(fixture.initial, fixture.protection)
    _ = try await put("latest", birth: .init(bytes: .init(repeating: 1, count: 16)), generation: 1, session: source)
    let receipt = try snapshotReceipt(await source.persistGeneralSnapshot(capture: source.captureGeneralSnapshot()))
    let selection = try LocalStoreSelection(directory: repositoryDirectory() + "/preview", store: .init(bytes: uuidBytes()), descriptor: fixture.initial.descriptor)
    let candidate = try await BootstrapCandidate.create(selection: selection, snapshot: nil, protection: fixture.protection)
    _ = try await candidate.retain(source.retainedObject(at: receipt.snapshot))
    for page in receipt.pages { _ = try await candidate.retain(source.retainedObject(at: page)) }
    let preview = try await candidate.preview(snapshot: receipt.snapshot)
    #expect(preview.notes.map(\.value.body.string).sorted() == ["latest", "untouched"])
    try await candidate.close()
    await #expect(throws: StorageError.incomplete) { try await LocalStoreSession.open(selection: selection, protection: fixture.protection) }
    try await source.quiesce()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func collectionBootstrapExplicitCreationPreservesOccupantsAndReopens(fixture: RepositoryLocalFixture, newDirectory: Bool) async throws {
    let parent = try repositoryDirectory(), repository = URL(fileURLWithPath: parent + "/notes")
    if !newDirectory { try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: false) }
    let privateDirectory = try repositoryDirectory() + "/store"
    let owner = try await CollectionSession.create(repository: repository,
        intent: newDirectory ? .createNewDirectory : .createInExistingDirectory, privateDirectory: privateDirectory,
        collection: fixture.initial.descriptor.collection,
        notes: [(NoteBirth(bytes: .init(repeating: 1, count: 16)), testValue("created"))],
        protection: fixture.protection, passphrase: fixture.initial.descriptor.keyID == nil ? nil : "synthetic")
    #expect(try await collectionBodies(owner) == ["created"])
    let selected = try await SelectedStoreOwner.open(directory: parent)
    guard case .activated(let state) = try await owner.activateFreshSelection(using: selected, basedOn: selected.capture()) else {
        Issue.record("Complete fresh store must activate through the actual selected-record consumer"); return
    }
    #expect(state.record != nil)
    try await owner.close()
    let selectedAgain = try await SelectedStoreOwner.open(directory: parent)
    #expect(try await selectedAgain.capture().record == state.record)
    try await selectedAgain.close()
    let keys = try FileManager.default.contentsOfDirectory(atPath: repository.path + "/NV Data/v1/keys")
    #expect(keys.count == 1)
    let inventory = try Data(contentsOf: repository.appendingPathComponent("NV Data/v1/keys/" + keys[0]))
    await #expect(throws: (any Error).self) {
        try await CollectionSession.create(repository: repository, intent: .createInExistingDirectory,
            privateDirectory: repositoryDirectory() + "/another", collection: fixture.initial.descriptor.collection,
            notes: [], protection: fixture.protection, passphrase: fixture.initial.descriptor.keyID == nil ? nil : "synthetic")
    }
    #expect(try Data(contentsOf: repository.appendingPathComponent("NV Data/v1/keys/" + keys[0])) == inventory)
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionBootstrapSelectedIntakeResumesWithoutElectingOtherCollections(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), descriptor = fixture.initial.descriptor
    try deliverFile(descriptor.encodedBytes, relative: ImmutableRepositoryLocator.descriptor(descriptor).relativePath, to: path)
    let initialRoot = try InitialSnapshotRootV1.decodeV1(ObjectEnvelopeV1.open(#require(fixture.initial.objects[fixture.initial.snapshot]),
        collection: descriptor.collection, protection: fixture.protection).payload)
    for locator in [fixture.initial.snapshot] + initialRoot.pages.map(\.locator) {
        try deliverFile(#require(fixture.initial.objects[locator]), relative: ImmutableRepositoryLocator.segment(locator).relativePath, to: path)
    }
    let entry = try await CollectionBootstrapSession.open(repository: URL(fileURLWithPath: path),
        privateDirectory: repositoryDirectory() + "/store", descriptor: descriptor, snapshot: fixture.initial.snapshot, protection: fixture.protection)
    var ended = false
    for _ in 0..<100 { if try await entry.discover(budget: 2).passEnded { ended = true; break } }
    #expect(ended)
    #expect(try await entry.preview().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    await #expect(throws: InitialBootstrapValidationError.self) { try await entry.complete() }
    let selection = await entry.selection
    try await entry.close()
    let unrelated = try InitialCollectionV1.build(collection: .init(bytes: Array(repeating: 77, count: 16)),
        notes: [(NoteBirth(bytes: Array(repeating: 7, count: 16)), testValue("other collection"))],
        protection: fixture.protection, passphrase: descriptor.keyID == nil ? nil : "synthetic")
    try deliverFile(unrelated.descriptor.encodedBytes, relative: ImmutableRepositoryLocator.descriptor(unrelated.descriptor).relativePath, to: path)
    for (locator, bytes) in fixture.initial.objects.merging(unrelated.objects, uniquingKeysWith: { first, _ in first }) {
        try deliverFile(bytes, relative: ImmutableRepositoryLocator.segment(locator).relativePath, to: path)
    }
    let resumed = try await CollectionBootstrapSession.resume(repository: URL(fileURLWithPath: path), selection: selection,
        snapshot: fixture.initial.snapshot, protection: fixture.protection)
    ended = false; var foreign = 0
    for _ in 0..<100 {
        let turn = try await resumed.discover(budget: 3)
        foreign += turn.entries.filter { if case .invalid(.wrongScope) = $0.outcome { true } else { false } }.count
        if turn.passEnded { ended = true; break }
    }
    #expect(ended && foreign > 0)
    let owner = try await resumed.complete()
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close()
    let independent = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let lane = await independent.lane
    #expect(try await lane.perform { try $0.rows("SELECT count(*) FROM accepted_objects") } == [[.integer(Int64(fixture.initial.objects.count + 1))]])
    #expect(try await independent.localAssociation().value?.scope.store == selection.store)
    try await independent.quiesce()
    #expect(try FileManager.default.contentsOfDirectory(atPath: path + "/NV Data/v1/keys").count == 2)
}
