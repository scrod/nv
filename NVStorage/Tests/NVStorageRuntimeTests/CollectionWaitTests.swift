import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private struct StartupRemoteInput {
    let path: String
    let selection: LocalStoreSelection
    let locator: SegmentLocator
    let bytes: [UInt8]
    var file: URL { URL(fileURLWithPath: path + "/" + ImmutableRepositoryLocator.segment(locator).relativePath) }
}
private func startupRemoteInput(_ fixture: RepositoryLocalFixture) async throws -> StartupRemoteInput {
    let path = try repositoryDirectory(), selection = try await associatedSelection(fixture, repository: path)
    let remote = try await newSession(fixture.initial, fixture.protection)
    let receipt = try await put("remote R", birth: .init(bytes: Array(repeating: 1, count: 16)), generation: 1, session: remote)
    let bytes = try await remote.retainedObject(at: receipt.object)
    try await remote.quiesce()
    try deliverFile(fixture.initial.descriptor.encodedBytes,
        relative: ImmutableRepositoryLocator.descriptor(fixture.initial.descriptor).relativePath, to: path)
    try deliverFile(bytes, relative: ImmutableRepositoryLocator.segment(receipt.object).relativePath, to: path)
    return .init(path: path, selection: selection, locator: receipt.object, bytes: bytes)
}
private func waitingChoice(_ owner: CollectionSession) async throws -> WorkOfflineChoice {
    guard case .waiting(let choice) = await owner.decision() else { Issue.record("Real exact unread input must issue a startup choice"); throw StorageError.incomplete }
    return choice
}

private actor StartupMaterializationWitness {
    private(set) var requests = 0
    func record(_ event: RepositoryTransportObservation) {
        if case .materialization = event { requests += 1 }
    }
}

private actor StartupRootWitness {
    private(set) var root: RepositoryRootSession?
    private(set) var expired = false
    func acquired(_ root: RepositoryRootSession) { self.root = root }
    func expire() { expired = true }
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupPublicationDuringNamedAttachmentEnablesTransport(fixture: RepositoryLocalFixture) async throws {
    let input = try await startupRemoteInput(fixture), adoption = ImprovementGate()
    defer { Task { await adoption.release() } }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: input.file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path) }
    var hooks = CollectionStartupHooks()
    hooks.beforeNamedTransportAdoption = { await adoption.hold() }
    let owner = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: input.path), hooks: hooks))
    await owner.settleAcquisition(); try await owner.considerProviderObject(input.locator)
    let choice = try await waitingChoice(owner)
    let attaching = Task { try await owner.requestWaitingBytes() }
    await adoption.wait()
    try await owner.workOffline(choice)
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    let capture = try await owner.capture(kind: .savedEdit,
        changes: [.put(.init(birth: .init(bytes: Array(repeating: 2, count: 16)), generation: 1), testValue("saved during attachment"))])
    let receipt = try requireReceipt(await owner.persist(capture))
    let file = input.path + "/" + ImmutableRepositoryLocator.segment(receipt.object).relativePath
    #expect(!FileManager.default.fileExists(atPath: file))
    await adoption.release(); try await attaching.value
    var published = false
    for _ in 0..<500 {
        if FileManager.default.fileExists(atPath: file) { published = true; break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(published, "A successfully published collection enables its attaching named worker without another notification")
    #expect(await owner.pendingProviderObject() == input.locator)
    try await owner.close()
    let independent = try await LocalStoreSession.open(selection: input.selection, protection: fixture.protection)
    #expect(try await independent.snapshot().notes.map(\.value.body.string).sorted() == ["A", "saved during attachment"])
    if published { #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == Data(await independent.retainedObject(at: receipt.object))) }
    try await independent.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func collectionStartupOfflineProceedsWithLiveHeldAccessor(fixture: RepositoryLocalFixture, invalidate: Bool) async throws {
    let input = try await startupRemoteInput(fixture), witness = StartupRootWitness(), entered = ImprovementGate()
    let release = DispatchSemaphore(value: 0)
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        await witness.expire(); release.signal(); await entered.release()
    }
    defer { watchdog.cancel(); release.signal(); Task { await entered.release() } }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: input.file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path) }
    let owner = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: input.path), hooks: .init(rootAcquired: { await witness.acquired($0) })))
    await owner.settleAcquisition(); try await owner.considerProviderObject(input.locator)
    let choice = try await waitingChoice(owner), root = try #require(await witness.root)
    let permission = try await root.permission()
    let accessor = Task {
        try await root.observe(ImmutableRepositoryLocator.descriptor(fixture.initial.descriptor).relativePath, using: permission,
            beforeRead: { Task { await entered.hold() }; release.wait() })
    }
    await entered.wait()
    #expect(await !witness.expired)
    if invalidate {
        await root.invalidate()
        await #expect(throws: RepositoryRootError.stalePermission) { try await owner.workOffline(choice) }
        #expect(await owner.pendingProviderObject() == input.locator)
    } else {
        try await owner.workOffline(choice)
        #expect(try await collectionBodies(owner) == ["A", "untouched"])
        let capture = try await owner.capture(kind: .savedEdit,
            changes: [.put(.init(birth: .init(bytes: Array(repeating: 2, count: 16)), generation: 1), testValue("saved with held provider"))])
        _ = try requireReceipt(await owner.persist(capture))
        #expect(await !witness.expired, "Publication and the local save complete before the actual accessor returns")
        #expect(await owner.pendingProviderObject() == input.locator)
        await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: input.path) }
    }
    release.signal(); await entered.release()
    if invalidate { await #expect(throws: RepositoryRootError.stalePermission) { try await accessor.value } }
    else { #expect(try await accessor.value.kind == .regularFile) }
    #expect(await !witness.expired)
    try await owner.close()
    #expect(try FileManager.default.attributesOfItem(atPath: input.file.path)[.posixPermissions] as? Int == 0)
    let independent = try await LocalStoreSession.open(selection: input.selection, protection: fixture.protection)
    #expect(try await independent.snapshot().notes.map(\.value.body.string).sorted() ==
        (invalidate ? ["A", "untouched"] : ["A", "saved with held provider"]))
    try await independent.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupSameRootRetryRetainsNamedCompletionRouting(fixture: RepositoryLocalFixture) async throws {
    let input = try await startupRemoteInput(fixture), witness = StartupMaterializationWitness()
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: input.file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path) }
    let resumed = ImprovementGate()
    defer { Task { await resumed.release() } }
    var hooks = CollectionStartupHooks()
    hooks.transport.retryNanoseconds = [20_000_000, 40_000_000]
    hooks.transport.observation = { event in
        await witness.record(event)
        if case .materialization = event, await witness.requests == 4 { await resumed.hold() }
    }
    let owner = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: input.path), hooks: hooks))
    await owner.settleAcquisition(); try await owner.considerProviderObject(input.locator)
    let oldChoice = try await waitingChoice(owner)
    try await owner.requestWaitingBytes()
    var paused = false
    for _ in 0..<500 {
        if case .paused = await owner.transportStatus()?.materialization { paused = true; break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(paused)
    #expect(await witness.requests == 3)
    #expect(try await owner.retryRepository(at: URL(fileURLWithPath: input.path)) == .same)
    await #expect(throws: StorageError.wrongContext) { try await owner.workOffline(oldChoice) }
    var fourth = false
    for _ in 0..<500 {
        if await witness.requests == 4 { fourth = true; break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(fourth, "Fresh root disclosure resumes the reused named worker after Retry")
    guard fourth else { try await owner.close(); return }
    await resumed.wait()
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path)
    await resumed.release()
    var ready = false
    for _ in 0..<500 {
        if case .ready = await owner.decision() { ready = true; break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(ready, "The reused worker settles the current wait after same-root Retry without another delivery")
    #expect(await witness.requests == 4)
    guard ready else { try await owner.close(); return }
    #expect(try await collectionBodies(owner) == ["remote R", "untouched"])
    try await owner.close()
    let independent = try await LocalStoreSession.open(selection: input.selection, protection: fixture.protection)
    #expect(try await independent.retainedObject(at: input.locator) == input.bytes)
    try await independent.quiesce()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func collectionStartupUnavailableRetryPreservesPendingDisclosure(fixture: RepositoryLocalFixture, replace: Bool) async throws {
    let input = try await startupRemoteInput(fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: input.file.path)
    var retainedFile = input.file
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: retainedFile.path) }
    let owner = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: input.path)))
    await owner.settleAcquisition(); try await owner.considerProviderObject(input.locator)
    let oldChoice = try await waitingChoice(owner)
    if replace {
        let moved = input.path + "-moved"
        try FileManager.default.moveItem(atPath: input.path, toPath: moved)
        retainedFile = URL(fileURLWithPath: moved + "/" + ImmutableRepositoryLocator.segment(input.locator).relativePath)
        try FileManager.default.createDirectory(atPath: input.path, withIntermediateDirectories: false)
        #expect(try await owner.retryRepository(at: URL(fileURLWithPath: input.path)) == .different)
    } else {
        let descriptor = input.path + "/" + ImmutableRepositoryLocator.descriptor(fixture.initial.descriptor).relativePath
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: descriptor)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: descriptor) }
        #expect(try await owner.retryRepository(at: URL(fileURLWithPath: input.path)) == .same)
    }
    #expect(await owner.pendingProviderObject() == input.locator)
    await #expect(throws: StorageError.wrongContext) { try await owner.workOffline(oldChoice) }
    #expect(try await collectionBodies(owner) == ["A", "untouched"], "Generic unavailability preserves healthy local publication")
    try await owner.close()
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: retainedFile.path)
    #expect(try Data(contentsOf: retainedFile) == Data(input.bytes))
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupPublicationWaitsForAcceptedCurrentRows(fixture: RepositoryLocalFixture) async throws {
    let input = try await startupRemoteInput(fixture), prepared = ImprovementGate()
    defer { Task { await prepared.release() } }
    var work = StorageWork(); work.currentRowsPrepared = { await prepared.hold() }
    let owner = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: input.path), hooks: .init(measuring: work)))
    await owner.settleAcquisition()
    let receiving = Task { try await owner.considerProviderObject(input.locator) }
    await prepared.wait()
    await #expect(throws: StorageError.staleCapture) { try await publishCollection(owner) }
    await prepared.release(); try await receiving.value
    #expect(try await collectionBodies(owner) == ["remote R", "untouched"])
    try await owner.close()
    let independent = try await LocalStoreSession.open(selection: input.selection, protection: fixture.protection)
    #expect(try await independent.retainedObject(at: input.locator) == input.bytes)
    #expect(try await independent.snapshot().notes.map(\.value.body.string).sorted() == ["remote R", "untouched"])
    try await independent.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func collectionStartupNamedMaterializationIsBoundedAndResumesWithoutDelivery(fixture: RepositoryLocalFixture, arrive: Bool) async throws {
    let input = try await startupRemoteInput(fixture), witness = StartupMaterializationWitness(), first = ImprovementGate()
    defer { Task { await first.release() } }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: input.file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path) }
    var hooks = CollectionStartupHooks()
    hooks.transport.retryNanoseconds = [20_000_000, 40_000_000]
    hooks.transport.observation = { event in
        await witness.record(event)
        if case .materialization = event, await witness.requests == 1 { await first.hold() }
    }
    let owner = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: input.path), hooks: hooks))
    await owner.settleAcquisition()
    try await owner.considerProviderObject(input.locator)
    let choice = try await waitingChoice(owner)
    try await owner.requestWaitingBytes()
    await first.wait()
    #expect(await owner.transportStatus()?.publication == .idle)
    #expect(!FileManager.default.fileExists(atPath: input.path + "/" + ImmutableRepositoryLocator.segment(fixture.initial.snapshot).relativePath))
    if arrive { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path) }
    await first.release()
    var settled = false
    for _ in 0..<500 {
        if arrive, case .ready = await owner.decision() { settled = true; break }
        if !arrive, case .paused = await owner.transportStatus()?.materialization { settled = true; break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    #expect(settled, "The existing worker must accept readable bytes or exhaust the exact bounded attempt")
    if arrive {
        #expect(await witness.requests == 1)
        await #expect(throws: StorageError.staleCapture) { try await owner.workOffline(choice) }
        #expect(try await collectionBodies(owner) == ["remote R", "untouched"])
    } else {
        #expect(await witness.requests == 3)
        try await owner.workOffline(choice)
        #expect(try await collectionBodies(owner) == ["A", "untouched"])
        let capture = try await owner.capture(kind: .savedEdit,
            changes: [.put(.init(birth: .init(bytes: Array(repeating: 2, count: 16)), generation: 1), testValue("saved while waiting"))])
        _ = try requireReceipt(await owner.persist(capture))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(await witness.requests == 3, "Save and root-settlement notifications preserve an exhausted named attempt")
        #expect(await owner.pendingProviderObject() == input.locator)
    }
    try await owner.close()
    let independent = try await LocalStoreSession.open(selection: input.selection, protection: fixture.protection)
    if arrive { #expect(try await independent.retainedObject(at: input.locator) == input.bytes) }
    else { #expect(try await independent.snapshot().notes.map(\.value.body.string).sorted() == ["A", "saved while waiting"]) }
    try await independent.quiesce()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func collectionStartupExactUnreadChoiceRechecksBytesAndRemainsScoped(fixture: RepositoryLocalFixture, arrive: Bool) async throws {
    let input = try await startupRemoteInput(fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: input.file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path) }
    let owner = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: input.path)))
    await owner.settleAcquisition()
    try await owner.considerProviderObject(input.locator)
    let choice = try await waitingChoice(owner)
    #expect(choice.object == input.locator)
    await #expect(throws: StorageError.incomplete) { try await publishCollection(owner) }
    if arrive {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path)
        await #expect(throws: StorageError.staleCapture) { try await owner.workOffline(choice) }
        #expect(try await collectionBodies(owner) == ["remote R", "untouched"])
    } else {
        try await owner.workOffline(choice)
        #expect(await owner.pendingProviderObject() == input.locator)
        #expect(try await collectionBodies(owner) == ["A", "untouched"])
        let capture = try await owner.capture(kind: .createImportBatch,
            changes: [.create(.init(birth: .init(bytes: Array(repeating: 5, count: 16)), generation: 1), testValue("offline durable"))])
        let saved = try requireReceipt(await owner.persist(capture))
        #expect(saved.covered.count == 1)
    }
    await #expect(throws: StorageError.staleCapture) { try await owner.workOffline(choice) }
    try await owner.close()
    let store = try await LocalStoreSession.open(selection: input.selection, protection: fixture.protection)
    let lane = await store.lane
    #expect(try await lane.perform { try $0.rows("SELECT encoded FROM objects WHERE object_id=?", [.blob(input.locator.segmentID.bytes)]) } ==
        (arrive ? [[.blob(input.bytes)]] : []))
    if !arrive { #expect(try FileManager.default.attributesOfItem(atPath: input.file.path)[.posixPermissions] as? Int == 0) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path)
    #expect(try Data(contentsOf: input.file) == Data(input.bytes), "The offline choice grants no file mutation")
    try await store.quiesce()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupLateAndAlreadyRetainedUnreadInputsPreserveEditing(fixture: RepositoryLocalFixture) async throws {
    let input = try await startupRemoteInput(fixture)
    let known = fixture.initial.snapshot, knownFile = URL(fileURLWithPath: input.path + "/" + ImmutableRepositoryLocator.segment(known).relativePath)
    try deliverFile(#require(fixture.initial.objects[known]), relative: ImmutableRepositoryLocator.segment(known).relativePath, to: input.path)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: knownFile.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: knownFile.path) }
    let owner = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: input.path)))
    await owner.settleAcquisition()
    try await owner.considerProviderObject(known)
    let ready: Bool
    if case .ready = await owner.decision() { ready = true } else { ready = false }
    #expect(ready, "Retained exact bytes avoid a redundant provider wait")
    guard ready else { try await owner.close(); return }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: input.file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path) }
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.considerProviderObject(input.locator)
    let editable: Bool
    if case .editable = await owner.decision() { editable = true } else { editable = false }
    #expect(editable, "Late evidence preserves an already editable session")
    guard editable else { try await owner.close(); return }
    let capture = try await owner.capture(kind: .savedEdit,
        changes: [.put(.init(birth: .init(bytes: Array(repeating: 2, count: 16)), generation: 1), testValue("local"))])
    _ = try requireReceipt(await owner.persist(capture))
    try await owner.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupChoiceRejectsOtherOwnerAndChangedSelection(fixture: RepositoryLocalFixture) async throws {
    let input = try await startupRemoteInput(fixture), another = try await startupRemoteInput(fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: input.file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path) }
    let first = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection, repository: URL(fileURLWithPath: input.path)))
    let second = try openedCollection(await CollectionSession.open(selection: another.selection, protection: fixture.protection))
    await first.settleAcquisition(); try await first.considerProviderObject(input.locator)
    let choice = try await waitingChoice(first)
    await #expect(throws: StorageError.wrongContext) { try await second.workOffline(choice) }
    do { try await first.reopenRepository(at: URL(fileURLWithPath: repositoryDirectory()), descriptor: fixture.initial.descriptor) }
    catch { Issue.record("Explicit new-root binding failed: \(error)"); throw error }
    await #expect(throws: StorageError.wrongContext) { try await first.workOffline(choice) }
    #expect(try await collectionBodies(first) == ["A", "untouched"])
    try await first.close(); try await second.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get(), [false, true])
func collectionStartupAmbiguousBindingUsesDurableReadback(fixture: RepositoryLocalFixture, repeatFailure: Bool) async throws {
    let old = try repositoryDirectory(), target = try repositoryDirectory(), marker = URL(fileURLWithPath: try repositoryDirectory() + "/fault")
    let selection = try await associatedSelection(fixture, repository: old)
    var work = StorageWork()
    work.databaseBoundary = { boundary in
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        switch boundary {
        case .committed: throw StorageError.database(10)
        case .returning: if repeatFailure { throw StorageError.database(13) }
        case .committing: break
        }
    }
    let owner = try openedCollection(await CollectionSession.open(selection: selection, protection: fixture.protection, repository: nil,
        hooks: .init(beforeBinding: { try Data([1]).write(to: marker) }, measuring: work)))
    await #expect(throws: StorageError.database(repeatFailure ? 13 : 10)) {
        try await owner.reopenRepository(at: URL(fileURLWithPath: target), descriptor: fixture.initial.descriptor)
    }
    if repeatFailure {
        guard case .transition = await owner.decision() else { Issue.record("Failed binding readback keeps exactly one unsettled transition"); return }
        await #expect(throws: StorageError.busy) { try await owner.reopenRepository(at: URL(fileURLWithPath: old), descriptor: fixture.initial.descriptor) }
        await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: target) }
        // Moving the test trigger ends only the fault; surviving database bytes decide adoption.
        try FileManager.default.moveItem(at: marker, to: marker.appendingPathExtension("settled"))
        try await owner.resumeReassociation()
    } else {
        try FileManager.default.moveItem(at: marker, to: marker.appendingPathExtension("settled"))
    }
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close()
    let independent = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    let root = try await RepositoryRootSession.open(directory: target)
    #expect(try await root.matches(#require(await independent.localAssociation().value)) == .same)
    #expect(try await independent.localAssociation().generation == 2)
    await root.close(); try await independent.quiesce()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func collectionStartupOfflineCannotOverrideFailedPrivateRecheck(fixture: RepositoryLocalFixture) async throws {
    let input = try await startupRemoteInput(fixture)
    let marker = URL(fileURLWithPath: try repositoryDirectory() + "/read-fault")
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: input.file.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path) }
    var work = StorageWork()
    work.databaseBoundary = { boundary in
        if case .returning = boundary, FileManager.default.fileExists(atPath: marker.path) { throw StorageError.database(13) }
    }
    let owner = try openedCollection(await CollectionSession.open(selection: input.selection, protection: fixture.protection,
        repository: URL(fileURLWithPath: input.path), hooks: .init(measuring: work)))
    await owner.settleAcquisition(); try await owner.considerProviderObject(input.locator)
    let choice = try await waitingChoice(owner)
    try Data([1]).write(to: marker)
    await #expect(throws: StorageError.database(13)) { try await owner.workOffline(choice) }
    #expect(await owner.pendingProviderObject() == input.locator)
    guard case .waiting = await owner.decision() else { Issue.record("Failed private recheck preserves the scoped wait"); return }
    try FileManager.default.moveItem(at: marker, to: marker.appendingPathExtension("settled"))
    try await owner.workOffline(choice)
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    try await owner.close()
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.file.path)
    #expect(try Data(contentsOf: input.file) == Data(input.bytes))
}
