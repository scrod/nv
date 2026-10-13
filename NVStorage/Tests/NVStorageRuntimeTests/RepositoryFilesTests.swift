import Foundation
import Crypto
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private func fileFixture(_ encrypted: Bool, sequence: UInt64 = 1) throws -> (BootstrapDescriptorV1, ImmutableRepositoryObject, [UInt8], ObjectProtectionV1) {
    let collection = try CollectionID(bytes: .init(repeating: 11, count: 16))
    let writer = try WriterEpoch(bytes: .init(repeating: 12, count: 16))
    let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: try CollectionKeyID(bytes: .init(repeating: 13, count: 16)),
        key: SymmetricKey(data: [UInt8](repeating: 14, count: 32))) : .publicHash
    let bytes = try ObjectEnvelopeV1.seal(payload: Array("private contents\n".utf8), kind: .changes,
        collection: collection, writer: writer, sequence: sequence, protection: protection)
    let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
    let descriptor: BootstrapDescriptorV1
    if encrypted {
        descriptor = try .wrap(collection: collection, keyID: CollectionKeyID(bytes: .init(repeating: 13, count: 16)),
            genesis: locator, collectionKey: SymmetricKey(data: [UInt8](repeating: 14, count: 32)), passphrase: "fixture password")
    } else { descriptor = try .publicDescriptor(collection: collection, genesis: locator) }
    return (descriptor, try .envelope(bytes, locator: locator, collection: collection, protection: protection), bytes, protection)
}

private func fileRoot() throws -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nv-repository-files-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory.path
}

@Test(arguments: [false, true]) func repositoryFilesInstallReadRetryAndContext(encrypted: Bool) async throws {
    let (descriptor, object, bytes, _) = try fileFixture(encrypted), path = try fileRoot()
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let first = try await root.install(object, for: descriptor, using: permission)
    guard case .verified(let evidence) = first else { Issue.record("Complete installation required: \(first)"); await root.close(); return }
    #expect(!evidence.reusedExisting)
    try await root.validate(evidence, for: object, using: permission)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/" + object.locator.relativePath)) == Data(bytes))
    let observation = try await root.observe(object.locator.relativePath, using: permission)
    guard case .contents(let contents) = try await root.read(observation, maximumBytes: bytes.count, using: permission) else {
        Issue.record("Coherent exact read required"); await root.close(); return
    }
    #expect(contents.bytes == bytes)
    guard case .verified(let duplicate) = try await root.install(object, for: descriptor, using: permission) else {
        Issue.record("Exact equal retry required"); await root.close(); return
    }
    #expect(duplicate.reusedExisting)
    #expect(try FileManager.default.contentsOfDirectory(atPath: path) == ["NV Data"])
    let other = try await RepositoryRootSession.open(directory: fileRoot())
    await #expect(throws: RepositoryRootError.wrongContext) { try await other.validate(evidence, for: object, using: other.permission()) }
    let (_, otherObject, _, _) = try fileFixture(encrypted, sequence: 2)
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.validate(evidence, for: otherObject, using: permission) }
    await root.invalidate()
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.validate(evidence, for: object, using: permission) }
    await root.close(); await other.close()
}

@Test(arguments: ["different", "directory", "symlink", "hardlink", "intermediate"])
func repositoryFilesPreserveConflictingOccupants(kind: String) async throws {
    let (descriptor, object, _, _) = try fileFixture(false), path = try fileRoot()
    let target = URL(fileURLWithPath: path + "/" + object.locator.relativePath)
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    let foreign = URL(fileURLWithPath: path + "/foreign")
    try Data([9, 8, 7]).write(to: foreign)
    switch kind {
    case "directory": try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    case "symlink": try FileManager.default.createSymbolicLink(at: target, withDestinationURL: foreign)
    case "hardlink": try FileManager.default.linkItem(at: foreign, to: target)
    case "intermediate":
        let parent = target.deletingLastPathComponent()
        try FileManager.default.moveItem(at: parent, to: parent.appendingPathExtension("preserved"))
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: parent.appendingPathExtension("preserved"))
    default: try Data([9, 8, 7]).write(to: target)
    }
    let root = try await RepositoryRootSession.open(directory: path)
    let result = try await root.install(object, for: descriptor, using: root.permission())
    guard case .notInstalled(let failure) = result else { Issue.record("A preexisting occupant must preserve no-install outcome"); await root.close(); return }
    #expect([RepositoryFileFailure.conflict, .kindCollision, .hardLinked].contains(failure.reason))
    #expect(failure.retry.locator == object.locator)
    #expect(try Data(contentsOf: foreign) == Data([9, 8, 7]))
    if kind == "different" || kind == "hardlink" { #expect(try Data(contentsOf: target) == Data([9, 8, 7])) }
    await root.close()
}

@Test func repositoryFilesReadDistinguishesChangesLimitsAndAbsence() async throws {
    let path = try fileRoot(), file = URL(fileURLWithPath: path + "/note")
    try Data([1, 2, 3]).write(to: file)
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let original = try await root.observe("note", using: permission)
    if case .unavailable(let reason) = try await root.read(original, maximumBytes: 2, using: permission) { #expect(reason == .sizeLimit) }
    else { Issue.record("Size limit required before allocation") }
    try Data([4, 5, 6]).write(to: file, options: .atomic)
    if case .unavailable(let reason) = try await root.read(original, maximumBytes: 3, using: permission) { #expect(reason == .changed) }
    else { Issue.record("Replaced observation must change") }
    try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("preserved"))
    if case .unavailable(let reason) = try await root.inspect("note", using: permission) { #expect(reason == .absent) }
    else { Issue.record("Missing entry must remain absence") }
    let other = try await RepositoryRootSession.open(directory: fileRoot())
    await #expect(throws: RepositoryRootError.wrongContext) { try await other.read(original, maximumBytes: 3, using: other.permission()) }
    await root.close(); await other.close()
}

@Test func repositoryFilesShallowListingResumesAndRejectsStaleCursor() async throws {
    let path = try fileRoot(), directory = URL(fileURLWithPath: path + "/NV Data/v1/segments")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for i in 0..<519 { try Data([1]).write(to: directory.appendingPathComponent("untrusted-\(i)")) }
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    var page = try await root.list(.segments, budget: 7, using: permission)
    let first = try #require(page.continuation)
    var names = page.names
    page = try await root.list(.segments, continuing: first, budget: 7, using: permission)
    names += page.names
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.list(.segments, continuing: first, budget: 7, using: permission) }
    while let cursor = page.continuation {
        #expect(page.names.count <= 7)
        page = try await root.list(.segments, continuing: cursor, budget: 7, using: permission)
        names += page.names
    }
    #expect(Set(names.map { String(decoding: $0.bytes, as: UTF8.self) }) == Set((0..<519).map { "untrusted-\($0)" }))
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.list(.keys, continuing: first, using: permission) }
    await root.invalidate()
    #expect(try await root.revalidate(candidate: path) == .same)
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.list(.segments, continuing: first, using: root.permission()) }
    await root.close()
}

@Test func repositoryFilesCheckedObjectRejectsWrongProfileLocatorAndCollection() throws {
    let (descriptor, _, bytes, protection) = try fileFixture(false)
    let locator = try ObjectEnvelopeV1.open(bytes, collection: descriptor.collection, protection: protection).locator
    let wrongCollection = try CollectionID(bytes: .init(repeating: 88, count: 16))
    #expect(throws: CanonicalEncodingError.self) { try ImmutableRepositoryObject.envelope(bytes, locator: locator, collection: wrongCollection, protection: protection) }
    #expect(throws: CanonicalEncodingError.self) { try ImmutableRepositoryObject.descriptor(descriptor, collection: wrongCollection, keyID: nil) }
    let wrong = SegmentLocator(writerEpoch: locator.writerEpoch, sequence: 999, segmentID: locator.segmentID)
    #expect(throws: CanonicalEncodingError.self) { try ImmutableRepositoryObject.envelope(bytes, locator: wrong, collection: descriptor.collection, protection: protection) }
    #expect(throws: CanonicalEncodingError.self) { try ImmutableRepositoryObject.envelope(bytes, locator: locator, collection: descriptor.collection,
        protection: .encrypted(keyID: CollectionKeyID(bytes: .init(repeating: 1, count: 16)), key: SymmetricKey(size: .bits256))) }
}

@Test(arguments: [false, true]) func repositoryFilesDelayedCompletionRetainsEffectsAndOwnedRoot(close: Bool) async throws {
    let (descriptor, object, bytes, _) = try fileFixture(false), path = try fileRoot()
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let reached = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let release = DispatchSemaphore(value: 0)
    let operation = Task { try await root.install(object, for: descriptor, using: permission, beforeInstall: {}, afterInstall: {
        reached.continuation.yield(())
        #expect(release.wait(timeout: .now() + 15) == .success, "Delayed installation gate must be released")
    }) }
    var iterator = reached.stream.makeAsyncIterator()
    _ = await iterator.next()
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/" + object.locator.relativePath)) == Data(bytes))
    operation.cancel()
    let closing: Task<Void, Never>?
    if close {
        closing = Task { await root.close() }
        for _ in 0..<10000 { if await root.state == .closing { break }; await Task.yield() }
        #expect(await root.state == .closing)
        await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    } else { closing = nil; await root.invalidate() }
    release.signal()
    let completed = try await operation.value
    let staleCompletion: Bool
    if case .uncertain = completed { staleCompletion = true } else { staleCompletion = false }
    #expect(staleCompletion, "An invalidated installation retains uncertain effects and exact retry input")
    guard case .uncertain(let failure) = completed else { await root.close(); return }
    #expect(failure.reason == .staleContext)
    #expect(failure.retry.locator == object.locator)
    await closing?.value
    await root.close()
    let reopened = try await RepositoryRootSession.open(directory: path)
    guard case .verified(let evidence) = try await reopened.install(failure.retry, for: descriptor, using: reopened.permission()) else {
        Issue.record("A fresh owned retry must verify surviving exact bytes"); await reopened.close(); return
    }
    #expect(evidence.reusedExisting)
    await reopened.close()
}

@Test func repositoryFilesDescriptorScopeAndDiscoveryIdentity() async throws {
    let (descriptor, object, bytes, protection) = try fileFixture(false), path = try fileRoot()
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let other = try BootstrapDescriptorV1.publicDescriptor(collection: CollectionID(bytes: .init(repeating: 20, count: 16)), genesis: descriptor.genesis)
    await #expect(throws: RepositoryRootError.wrongContext) { try await root.install(object, for: other, using: permission) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: path).isEmpty)
    let descriptorObject = try ImmutableRepositoryObject.descriptor(descriptor, collection: descriptor.collection, keyID: descriptor.keyID)
    guard case .verified = try await root.install(descriptorObject, for: descriptor, using: permission),
          case .verified = try await root.install(object, for: descriptor, using: permission) else {
        Issue.record("Both immutable kinds require real installation"); await root.close(); return
    }
    let writerDirectory = RepositoryProtocolDirectory.writer(descriptor.genesis.writerEpoch)
    let renamed = "provider renamed duplicate.nvseg"
    let original = URL(fileURLWithPath: path + "/" + object.locator.relativePath)
    try Data(bytes).write(to: original.deletingLastPathComponent().appendingPathComponent(renamed))
    let page = try await root.list(writerDirectory, using: permission)
    let discovered = try #require(page.names.first { String(decoding: $0.bytes, as: UTF8.self) == renamed })
    let observed = try await root.observe(discovered.relativePath(in: writerDirectory), using: permission)
    guard case .contents(let contents) = try await root.read(observed, maximumBytes: bytes.count, using: permission) else {
        Issue.record("Renamed bytes require exact bounded read"); await root.close(); return
    }
    #expect(try ObjectEnvelopeV1.open(contents.bytes, collection: descriptor.collection, protection: protection).locator == descriptor.genesis)
    await root.close()
}

@Test func repositoryFilesChangedListingRetainsRootOwnership() async throws {
    let path = try fileRoot(), directory = URL(fileURLWithPath: path + "/NV Data/v1/keys")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data([1]).write(to: directory.appendingPathComponent("old"))
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let first = try await root.list(.keys, budget: 1, using: permission)
    let cursor = try #require(first.continuation)
    try FileManager.default.moveItem(at: directory, to: directory.appendingPathExtension("preserved"))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try Data([2]).write(to: directory.appendingPathComponent("new"))
    await #expect(throws: RepositoryRootError.unavailable(ESTALE)) { try await root.list(.keys, continuing: cursor, using: permission) }
    #expect(await root.state == .active)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    let fresh = try await root.list(.keys, using: permission)
    #expect(fresh.names.map { String(decoding: $0.bytes, as: UTF8.self) } == ["new"])
    #expect(try Data(contentsOf: directory.appendingPathExtension("preserved").appendingPathComponent("old")) == Data([1]))
    await root.close()
}
