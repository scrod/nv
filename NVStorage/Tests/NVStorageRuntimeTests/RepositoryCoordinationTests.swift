import NVStorageTestSupport
#if canImport(Darwin)
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private struct CoordinationFailureCase: Sendable {
    let domain: String?
    let code: Int
    let expected: Int32
}

@Test(arguments: [
    CoordinationFailureCase(domain: nil, code: 0, expected: EIO),
    CoordinationFailureCase(domain: NSPOSIXErrorDomain, code: Int(EACCES), expected: EACCES),
    CoordinationFailureCase(domain: NSPOSIXErrorDomain, code: Int(ENOENT), expected: ENOENT),
    CoordinationFailureCase(domain: NSPOSIXErrorDomain, code: Int(ECANCELED), expected: ECANCELED),
    CoordinationFailureCase(domain: NSPOSIXErrorDomain, code: Int(ENOSPC), expected: ENOSPC),
    CoordinationFailureCase(domain: NSPOSIXErrorDomain, code: 0, expected: EIO),
    CoordinationFailureCase(domain: NSPOSIXErrorDomain, code: -Int(ENOENT), expected: EIO),
    CoordinationFailureCase(domain: NSPOSIXErrorDomain, code: Int.max, expected: EIO),
    CoordinationFailureCase(domain: NSPOSIXErrorDomain, code: Int.min, expected: EIO),
    CoordinationFailureCase(domain: NSCocoaErrorDomain, code: NSUserCancelledError, expected: ECANCELED),
    CoordinationFailureCase(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError, expected: ENOENT),
    CoordinationFailureCase(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, expected: ENOENT),
    CoordinationFailureCase(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, expected: EACCES),
    CoordinationFailureCase(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, expected: EACCES),
    CoordinationFailureCase(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError, expected: ENOSPC),
    CoordinationFailureCase(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError, expected: EROFS),
    CoordinationFailureCase(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, expected: EIO),
    CoordinationFailureCase(domain: NSCocoaErrorDomain, code: Int.max, expected: EIO),
    CoordinationFailureCase(domain: "unrecognized-provider", code: Int(ENOENT), expected: EIO),
    CoordinationFailureCase(domain: "unrecognized-provider", code: NSFileReadNoSuchFileError, expected: EIO),
    CoordinationFailureCase(domain: "", code: Int(ECANCELED), expected: EIO),
])
private func repositoryCoordinationFailureClassification(sample: CoordinationFailureCase) {
    let error = sample.domain.map {
        NSError(domain: $0, code: sample.code, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
            NSFilePathErrorKey: ["malformed": "synthetic-private-path"],
            NSLocalizedDescriptionKey: 42,
        ])
    }
    #expect(repositoryCoordinationCode(error) == sample.expected)
}

private actor CoordinationSignal {
    private(set) var count = 0
    private(set) var expired = false
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func signal() {
        count += 1
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        for (_, continuation) in ready { continuation.resume() }
    }
    func wait(_ count: Int = 1) async {
        if self.count < count { await withCheckedContinuation { waiters.append((count, $0)) } }
    }
    func expire() {
        expired = true
        let pending = waiters; waiters.removeAll()
        for (_, continuation) in pending { continuation.resume() }
    }
}

private func coordinationWatchdog(_ signal: CoordinationSignal, release: DispatchSemaphore) -> Task<Void, Never> {
    Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        await signal.expire(); release.signal()
    }
}

private final class CoordinationReplies: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var counts = [Int](repeating: 0, count: 4)
    func record(_ index: Int) { lock.withLock { unsafe counts[index] += 1 } }
    var snapshot: [Int] { lock.withLock { unsafe counts } }
}

/// Exercises the synchronous Foundation reply entrypoints after registration has ended.
private func exerciseLateReplies(_ presenter: any NSFilePresenter, counts: CoordinationReplies) {
    presenter.relinquishPresentedItem?(toReader: { reacquirer in reacquirer?(); counts.record(0) })
    presenter.relinquishPresentedItem?(toWriter: { reacquirer in reacquirer?(); counts.record(1) })
    presenter.savePresentedItemChanges?(completionHandler: { error in #expect(error == nil); counts.record(2) })
    presenter.accommodatePresentedItemDeletion?(completionHandler: { error in #expect(error == nil); counts.record(3) })
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryPresenterSeparatesOwnedWritesFromExternalHints(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory(), expected = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let presenter = try #require(NSFileCoordinator.filePresenters.first {
        $0.presentedItemURL?.resolvingSymlinksInPath().path == expected
    })
    let baseline = await root.discoveryInvalidation
    let object = try ImmutableRepositoryObject.descriptor(fixture.initial.descriptor,
        collection: fixture.initial.descriptor.collection, keyID: fixture.initial.descriptor.keyID)
    for repeated in [false, true] {
        guard case .verified(let installed) = try await root.install(object, for: fixture.initial.descriptor, using: permission) else {
            Issue.record("The initiating-presenter witness requires a complete exact installation"); await root.close(); return
        }
        #expect(installed.reusedExisting == repeated)
        await withCheckedContinuation { continuation in
            presenter.presentedItemOperationQueue.addOperation { continuation.resume() }
        }
        #expect(await root.discoveryInvalidation == baseline,
                "Owned creation and exact-byte retry leave discovery unchanged")
    }
    let file = URL(fileURLWithPath: path + "/external.txt"), bytes = Data("independent presenter input".utf8)
    var failure: NSError?
    NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: [], error: &failure) { actual in
        do { try bytes.write(to: actual) } catch { Issue.record("External companion write failed: \(error)") }
    }
    #expect(failure == nil)
    let signal = CoordinationSignal(), release = DispatchSemaphore(value: 0)
    let watchdog = coordinationWatchdog(signal, release: release)
    defer { watchdog.cancel(); release.signal() }
    while await root.discoveryInvalidation == baseline, await !signal.expired { await Task.yield() }
    #expect(await !signal.expired, "A separate coordinator still supplies a genuine external hint")
    #expect(try Data(contentsOf: file) == bytes)
    #expect(try await root.observe("external.txt", using: permission).byteCount == UInt64(bytes.count))
    await root.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func repositoryCoordinationCancellationBeforeEntry(cancel: Bool) async throws {
    let path = try repositoryDirectory()
    try Data([1, 2, 3]).write(to: URL(fileURLWithPath: path + "/note"))
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let requested = CoordinationSignal(), entered = CoordinationSignal(), release = DispatchSemaphore(value: 0)
    let watchdog = coordinationWatchdog(requested, release: release)
    defer { watchdog.cancel(); release.signal() }
    let observation = Task {
        try await root.observe("note", using: permission,
            beforeRead: { Task { await entered.signal() } },
            beforeCoordination: { Task { await requested.signal() }; release.wait() })
    }
    await requested.wait()
    #expect(await !requested.expired)
    if cancel { observation.cancel() }
    release.signal()
    if cancel {
        await #expect(throws: RepositoryRootError.unavailable(ECANCELED)) { try await observation.value }
        #expect(await entered.count == 0)
    } else {
        #expect(try await observation.value.byteCount == 3)
        await entered.wait(); #expect(await entered.count == 1)
    }
    #expect(await root.state == .active)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/note")) == Data([1, 2, 3]))
    #expect(try await root.observe("note", using: permission).byteCount == 3)
    await root.close()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func repositoryCoordinationEnteredReadPreservesEditDeleteAndReopen(fixture: RepositoryLocalFixture) async throws {
    let path = try repositoryDirectory()
    try Data([7]).write(to: URL(fileURLWithPath: path + "/note"))
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let entered = CoordinationSignal(), release = DispatchSemaphore(value: 0)
    let watchdog = coordinationWatchdog(entered, release: release)
    defer { watchdog.cancel(); release.signal() }
    let read = Task {
        try await root.observe("note", using: permission, beforeRead: {
            Task { await entered.signal() }; release.wait()
        })
    }
    await entered.wait()
    #expect(await !entered.expired)
    let local = try await newSession(fixture.initial, fixture.protection), selection = await local.selection
    let edited = try NoteBirth(bytes: .init(repeating: 1, count: 16)), deleted = try NoteBirth(bytes: .init(repeating: 2, count: 16))
    let edit = try await put("durable while accessor is entered", birth: edited, generation: 1, session: local)
    let capture = try await CapturedActionGroup(snapshot: local.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: deleted, generation: 2))])
    let deletion = try requireReceipt(await local.persist(capture: capture))
    let editBytes = try await local.retainedObject(at: edit.object)
    let deletionBytes = try await local.retainedObject(at: deletion.object)
    try await local.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let recovered = try await reopened.snapshot()
    #expect(recovered.notes.map(\.birth) == [edited])
    #expect(recovered.notes.map(\.value.body.string) == ["durable while accessor is entered"])
    #expect(try await reopened.retainedObject(at: edit.object) == editBytes)
    #expect(try await reopened.retainedObject(at: deletion.object) == deletionBytes)
    #expect(await !entered.expired, "Both local barriers and reopen finish while the actual accessor remains held")
    try await reopened.quiesce()
    read.cancel(); await root.invalidate()
    let close = Task { await root.close() }
    while await root.state == .fenced { await Task.yield() }
    #expect(await root.state == .closing)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    release.signal()
    await #expect(throws: RepositoryRootError.stalePermission) { try await read.value }
    await close.value
    #expect(await root.state == .closed)
    let next = try await RepositoryRootSession.open(directory: path)
    #expect(try await next.observe("note", using: next.permission()).byteCount == 1)
    await next.close()
}

@Test(.timeLimit(.minutes(1)))
func repositoryPresenterRegistrationGettersAndLateReplies() async throws {
    let path = try repositoryDirectory(), expected = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    let root = try await RepositoryRootSession.open(directory: path)
    let matches = NSFileCoordinator.filePresenters.filter { $0.presentedItemURL?.resolvingSymlinksInPath().path == expected }
    #expect(matches.count == 1)
    let presenter = try #require(matches.first)
    let observed = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
        for _ in 0..<32 {
            group.addTask {
                (0..<16).allSatisfy { _ in
                    NSFileCoordinator.filePresenters.filter { $0.presentedItemURL?.resolvingSymlinksInPath().path == expected }.count == 1
                }
            }
        }
        var results: [Bool] = []
        for await value in group { results.append(value) }
        return results
    }
    #expect(observed.count == 32 && observed.allSatisfy { $0 })
    await root.close()
    #expect(presenter.presentedItemURL == nil)
    #expect(!NSFileCoordinator.filePresenters.contains { $0 === presenter })
    let invalidation = await root.discoveryInvalidation, replies = CoordinationReplies()
    exerciseLateReplies(presenter, counts: replies)
    #expect(replies.snapshot == [1, 1, 1, 1])
    #expect(await root.discoveryInvalidation == invalidation)
    #expect(await root.state == .closed)
    let successor = try await RepositoryRootSession.open(directory: path)
    await successor.close()
}

@available(macOS 14.4, *)
@Test(.timeLimit(.minutes(1)))
func repositoryPresenterEvictionRepliesAndRequiresPositiveRevalidation() async throws {
    let path = try repositoryDirectory(), expected = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    try Data([9]).write(to: URL(fileURLWithPath: path + "/note"))
    let root = try await RepositoryRootSession.open(directory: path), old = try await root.permission()
    let presenter = try #require(NSFileCoordinator.filePresenters.first {
        $0.presentedItemURL?.resolvingSymlinksInPath().path == expected
    })
    let replied = CoordinationSignal(), release = DispatchSemaphore(value: 0)
    let watchdog = coordinationWatchdog(replied, release: release)
    defer { watchdog.cancel(); release.signal() }
    presenter.accommodatePresentedItemEviction?(completionHandler: { error in
        #expect(error == nil); Task { await replied.signal() }
    })
    await replied.wait()
    while await root.state == .active, await !replied.expired { await Task.yield() }
    #expect(await !replied.expired)
    #expect(await root.state == .fenced)
    #expect(presenter.presentedItemURL == nil)
    #expect(!NSFileCoordinator.filePresenters.contains { $0 === presenter })
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.observe("note", using: old) }
    #expect(try await root.revalidate(candidate: path) == .same)
    #expect(await root.state == .active)
    #expect(NSFileCoordinator.filePresenters.filter {
        $0.presentedItemURL?.resolvingSymlinksInPath().path == expected
    }.count == 1)
    #expect(try await root.observe("note", using: root.permission()).byteCount == 1)
    await root.close()
    #expect(presenter.presentedItemURL == nil)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/note")) == Data([9]))
}
@Test(.enabled(if: ProcessInfo.processInfo.environment["NV_STORAGE_COORDINATION_PEER"] != nil), .timeLimit(.minutes(1)))
func repositoryIndependentCoordinatedPeer() async throws {
    let executable = try #require(ProcessInfo.processInfo.environment["NV_STORAGE_COORDINATION_PEER"])
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    try Data("before".utf8).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let baseline = await root.discoveryInvalidation
    func peer(_ arguments: [String]) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
        try child.run(); child.waitUntilExit()
        #expect(child.terminationReason == .exit && child.terminationStatus == 0)
    }
    try peer(["write", path + "/note.txt", "independent coordinated edit"])
    let expired = CoordinationSignal(), release = DispatchSemaphore(value: 0)
    let watchdog = coordinationWatchdog(expired, release: release)
    defer { watchdog.cancel(); release.signal() }
    while await root.discoveryInvalidation == baseline, await !expired.expired { await Task.yield() }
    #expect(await !expired.expired, "Actual independent writer supplies a presenter opportunity")
    let expected = Array("independent coordinated edit".utf8)
    let permission = try await root.permission(), observation = try await root.observe("note.txt", using: permission)
    guard case .contents(let first) = try await root.read(observation, maximumBytes: 64, using: permission) else {
        Issue.record("Coordinated peer bytes remain independently readable"); await root.close(); return
    }
    #expect(first.bytes == expected)
    let moved = path + "-moved"
    try peer(["move", path, moved])
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try Data("replacement preserved".utf8).write(to: URL(fileURLWithPath: path + "/note.txt"))
    #expect(try await root.revalidate(candidate: moved) == .same)
    let next = try await root.permission(), movedObservation = try await root.observe("note.txt", using: next)
    guard case .contents(let current) = try await root.read(movedObservation, maximumBytes: 64, using: next) else {
        Issue.record("The actual moved root retains its original bytes"); await root.close(); return
    }
    #expect(current.bytes == expected)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: moved) }
    let replacement = try await RepositoryRootSession.open(directory: path); await replacement.close()
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/note.txt")) == Data("replacement preserved".utf8))
    await root.close()
    let successor = try await RepositoryRootSession.open(directory: moved); await successor.close()
}
@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func collectionStartupReassociationRetainsEnteredAccessorThroughSettlement(fixture: RepositoryLocalFixture, cancel: Bool) async throws {
    let old = try repositoryDirectory(), target = try repositoryDirectory()
    let marker = URL(fileURLWithPath: try repositoryDirectory() + "/binding")
    let selection = try await associatedSelection(fixture, repository: old)
    let setup = try await RepositoryRootSession.open(directory: old)
    let descriptor = try ImmutableRepositoryObject.descriptor(fixture.initial.descriptor,
        collection: fixture.initial.descriptor.collection, keyID: fixture.initial.descriptor.keyID)
    guard case .verified = try await setup.install(descriptor, for: fixture.initial.descriptor, using: setup.permission()) else {
        Issue.record("The entered-accessor companion requires a compatible repository"); return
    }
    await setup.close()
    let entered = CoordinationSignal(), committed = CoordinationSignal(), release = DispatchSemaphore(value: 0)
    let firstEntry = DispatchSemaphore(value: 1), watchdog = coordinationWatchdog(entered, release: release)
    defer { watchdog.cancel(); release.signal(); firstEntry.signal() }
    var work = StorageWork()
    work.databaseBoundary = { boundary in
        if case .committed = boundary, FileManager.default.fileExists(atPath: marker.path) {
            Task { await committed.signal() }
        }
    }
    var hooks = CollectionStartupHooks(beforeBinding: { try Data([1]).write(to: marker) }, measuring: work)
    hooks.transport.installEntered = { _ in
        if firstEntry.wait(timeout: .now()) == .success {
            Task { await entered.signal() }; release.wait()
        }
    }
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: old), hooks: hooks))
    await owner.settleAcquisition()
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    await entered.wait()
    #expect(await !entered.expired)
    let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
    let edit = try await owner.capture(kind: .savedEdit, changes: [.put(.init(birth: birth, generation: 9), testValue("saved during old accessor"))])
    let receipt = try requireReceipt(await owner.persist(edit))
    #expect(await !entered.expired, "Local durability completes while a real provider accessor remains entered")
    let transition = Task { try await owner.reopenRepository(at: URL(fileURLWithPath: target), descriptor: fixture.initial.descriptor) }
    await committed.wait()
    #expect(await !entered.expired)
    guard case .transition = await owner.decision() else { Issue.record("Committed binding remains unsettled until old accessor return"); release.signal(); try await transition.value; return }
    await #expect(throws: StorageError.busy) { try await owner.reopenRepository(at: URL(fileURLWithPath: old), descriptor: fixture.initial.descriptor) }
    await #expect(throws: StorageError.busy) { try await owner.close() }
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: old) }
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: target) }
    if cancel { transition.cancel() }
    release.signal()
    if cancel {
        do { try await transition.value }
        catch { #expect(error is CancellationError || (error as? RepositoryRootError) == .unavailable(ECANCELED)) }
    } else { try await transition.value }
    #expect(try await collectionBodies(owner) == ["saved during old accessor", "untouched"])
    let released = try await RepositoryRootSession.open(directory: old); await released.close()
    try await owner.close()
    let independent = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let targetOwner = try await RepositoryRootSession.open(directory: target)
    #expect(try await independent.localAssociation().generation == 2)
    #expect(try await targetOwner.matches(#require(await independent.localAssociation().value)) == .same)
    #expect(try await independent.retainedObject(at: receipt.object).count > 156)
    #expect(try await independent.snapshot().notes.map(\.value.body.string) == ["saved during old accessor", "untouched"])
    await targetOwner.close(); try await independent.quiesce()
}
#endif
