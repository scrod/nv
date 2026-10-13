import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test func repositoryRootExcludesContendersAcrossObservationAndMove() async throws {
    let path = try emptyRepository(), moved = path + "-moved"
    let root = try await RepositoryRootSession.open(directory: path)
    let original = try await root.permission()
    try Data("original".utf8).write(to: URL(fileURLWithPath: path + "/note.txt"))
    for _ in 0..<3 {
        let entry = try await root.observe("note.txt", using: original)
        #expect(entry.kind == .regularFile && entry.byteCount == 8)
        await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    }
    try FileManager.default.moveItem(atPath: path, toPath: moved)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try Data("replacement".utf8).write(to: URL(fileURLWithPath: path + "/note.txt"))
    // The captured root still observes the held original through its descriptor.
    #expect(try await root.observe("note.txt", using: original).byteCount == 8)
    let replacement = try await RepositoryRootSession.open(directory: path)
    #expect(try await replacement.observe("note.txt", using: replacement.permission()).byteCount == 11)
    #expect(try await root.revalidate(candidate: path) == .different)
    await #expect(throws: RepositoryRootError.fenced) { try await root.permission() }
    #expect(try await root.revalidate(candidate: moved) == .same)
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.observe("note.txt", using: original) }
    #expect(try await root.observe("note.txt", using: root.permission()).byteCount == 8)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: moved) }
    await root.close(); await replacement.close()
    let next = try await RepositoryRootSession.open(directory: moved)
    await next.close()
}

@Test func rootPermissionRequiresItsIssuingSessionAndCurrentGeneration() async throws {
    let path = try emptyRepository(), otherPath = try emptyRepository()
    try Data([1]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let root = try await RepositoryRootSession.open(directory: path)
    let other = try await RepositoryRootSession.open(directory: otherPath)
    let permission = try await root.permission()
    await #expect(throws: RepositoryRootError.wrongContext) { try await other.observe("note.txt", using: permission) }
    await root.invalidate()
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.observe("note.txt", using: permission) }
    #expect(try await root.revalidate(candidate: path + "/missing") == .unavailable(ENOENT))
    await #expect(throws: RepositoryRootError.fenced) { try await root.permission() }
    #expect(try await root.revalidate(candidate: path) == .same)
    #expect(try await root.observe("note.txt", using: root.permission()).byteCount == 1)
    await root.close(); await root.close(); await other.close()
    await #expect(throws: RepositoryRootError.closed) { try await root.permission() }
}

@Test(arguments: ["link", "link/", "link/.", "file", "missing", "nul"])
func rootAcquisitionPreservesUnsafeOrUnavailableCandidates(kind: String) async throws {
    let parent = try emptyRepository(), target = try emptyRepository()
    var path = parent + "/candidate"
    switch kind {
    case "link", "link/", "link/.":
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        if kind != "link" { path += String(kind.dropFirst(4)) }
    case "file": try Data([7]).write(to: URL(fileURLWithPath: path))
    case "nul": path += "\0suffix"
    default: break
    }
    let expected: [RepositoryRootError]
    switch kind {
    case "link", "link/": expected = [.unavailable(ELOOP), .unavailable(ENOTDIR)]
    case "link/.": expected = [.unavailable(EINVAL)]
    case "file": expected = [.unavailable(ENOTDIR)]
    case "nul": expected = [.unsafePath]
    default: expected = [.unavailable(ENOENT)]
    }
    await #expect { try await RepositoryRootSession.open(directory: path) } throws: { error in
        guard let error = error as? RepositoryRootError else { return false }
        return expected.contains(error)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: target).isEmpty)
    if kind == "file" { #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data([7])) }
}

@Test(arguments: ["../outside", "/absolute", "a//b", "a/./b", "a/../b", "a\0hidden", ""])
func rootedObservationsRejectUnsafeRelativePaths(relative: String) async throws {
    let root = try await RepositoryRootSession.open(directory: emptyRepository())
    await #expect(throws: RepositoryRootError.unsafePath) { try await root.observe(relative, using: root.permission()) }
    await root.close()
}

@Test func rootedObservationsPreserveLeafSymlinksAndRejectTraversal() async throws {
    let path = try emptyRepository(), outside = try emptyRepository()
    try Data([8]).write(to: URL(fileURLWithPath: outside + "/note.txt"))
    try FileManager.default.createSymbolicLink(atPath: path + "/link", withDestinationPath: outside)
    let root = try await RepositoryRootSession.open(directory: path)
    #expect(try await root.observe("link", using: root.permission()).kind == .symbolicLink)
    await #expect(throws: RepositoryRootError.self) { try await root.observe("link/note.txt", using: root.permission()) }
    #expect(try Data(contentsOf: URL(fileURLWithPath: outside + "/note.txt")) == Data([8]))
    await root.close()
}

private actor RootTurnSignal {
    private var arrived = false
    private(set) var expired = false
    private var waiter: CheckedContinuation<Void, Never>?
    func enter() { arrived = true; waiter?.resume(); waiter = nil }
    func wait() async { if !arrived { await withCheckedContinuation { waiter = $0 } } }
    func expire() { expired = true }
    var hasArrived: Bool { arrived }
}

/// Frozen bootstrap inputs keep password derivation outside timed ownership schedules.
struct RepositoryLocalFixture: Sendable, CustomStringConvertible {
    let encrypted: Bool
    let initial: InitialCollectionV1
    let protection: ObjectProtectionV1
    var description: String { encrypted ? "encrypted" : "public" }
    static let prepared: Result<[Self], Error> = Result {
        try [false, true].map { encrypted in
            let (initial, protection) = try testInitial(encrypted)
            return Self(encrypted: encrypted, initial: initial, protection: protection)
        }
    }
}

@Test func replacedEmptyRootFencesItsRetainedOwner() async throws {
    let parent = try emptyRepository(), path = parent + "/root", replacement = parent + "/replacement"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(atPath: replacement, withIntermediateDirectories: false)
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    // Replacing this newly created empty fixture supplies a real deletion event on the held object.
    try #require(unsafe rename(replacement, path) == 0)
    try Data([9]).write(to: URL(fileURLWithPath: path + "/replacement.txt"))
    await #expect(throws: RepositoryRootError.unavailable(ESTALE)) {
        try await root.observe("replacement.txt", using: permission)
    }
    #expect(await root.state == .fenced, "Delivered root loss fences effects rather than becoming child absence")
    #expect(try await root.revalidate(candidate: path) == .unavailable(ESTALE))
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.observe("replacement.txt", using: permission) }
    let next = try await RepositoryRootSession.open(directory: path)
    #expect(try await next.observe("replacement.txt", using: next.permission()).byteCount == 1)
    await root.close(); await next.close()
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/replacement.txt")) == Data([9]))
}

@Test(.timeLimit(.minutes(1))) func delayedContinuityCannotRestoreInvalidatedAdmission() async throws {
    let path = try emptyRepository(), root = try await RepositoryRootSession.open(directory: path)
    let entered = RootTurnSignal(), release = DispatchSemaphore(value: 0)
    let compare = Task {
        try await root.revalidate(candidate: path, beforeCompare: {
            Task { await entered.enter() }; release.wait()
        })
    }
    await entered.wait()
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        await entered.expire(); release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    await root.invalidate()
    await #expect(throws: RepositoryRootError.busy) { try await root.revalidate(candidate: path) }
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    #expect(await entered.expired == false)
    release.signal()
    await #expect(throws: RepositoryRootError.stalePermission) { try await compare.value }
    #expect(await root.state == .fenced)
    #expect(try await root.revalidate(candidate: path) == .same)
    await root.close()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func quiescingRootRetainsOwnershipUntilExplicitClose(fixture: RepositoryLocalFixture) async throws {
    let path = try emptyRepository()
    try Data([1]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let entered = RootTurnSignal(), settled = RootTurnSignal(), release = DispatchSemaphore(value: 0)
    let read = Task {
        try await root.observe("note.txt", using: permission, beforeRead: {
            Task { await entered.enter() }; release.wait()
        })
    }
    await entered.wait()
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        await entered.expire(); release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    let quiet = Task { await root.quiesce(); await settled.enter() }
    while await root.state == .active { await Task.yield() }
    #expect(await root.state == .fenced)
    let local = try await newSession(fixture.initial, fixture.protection)
    _ = try await put("saved during root quiescence", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: local)
    try await local.quiesce()
    #expect(await settled.hasArrived == false, "Quiescence settles only after entered root work returns")
    #expect(await entered.expired == false)
    quiet.cancel()
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    await #expect(throws: RepositoryRootError.fenced) { try await root.permission() }
    release.signal()
    await #expect(throws: RepositoryRootError.stalePermission) { try await read.value }
    await quiet.value
    await root.quiesce()
    #expect(await settled.hasArrived)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    #expect(try await root.revalidate(candidate: path) == .same)
    #expect(try await root.observe("note.txt", using: root.permission()).byteCount == 1)
    await root.close()
    let next = try await RepositoryRootSession.open(directory: path)
    await next.close()
}

@Test func cancellationBeforeRootAdmissionPreservesOwnership() async throws {
    let path = try emptyRepository(), root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission(), readStart = RootTurnSignal(), openStart = RootTurnSignal()
    let read = Task { await readStart.wait(); return try await root.observe("missing", using: permission) }
    let open = Task { await openStart.wait(); return try await RepositoryRootSession.open(directory: path) }
    read.cancel(); open.cancel()
    await readStart.enter(); await openStart.enter()
    await #expect(throws: CancellationError.self) { try await read.value }
    await #expect(throws: CancellationError.self) { try await open.value }
    #expect(await root.state == .active)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    await root.close()
}

@Test(arguments: try RepositoryLocalFixture.prepared.get())
func rootAndPrivateStoreRequireIndependentOwnership(fixture: RepositoryLocalFixture) async throws {
    let protection = fixture.protection, local = try await newSession(fixture.initial, protection)
    let selection = await local.selection, path = try emptyRepository()
    let root = try await RepositoryRootSession.open(directory: path)
    await #expect(throws: StorageError.ownership(EWOULDBLOCK)) {
        try await LocalStoreSession.open(selection: selection, protection: protection)
    }
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    await root.invalidate()
    _ = try await put("private owner remains usable", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: local)
    await root.close()
    await #expect(throws: StorageError.ownership(EWOULDBLOCK)) {
        try await LocalStoreSession.open(selection: selection, protection: protection)
    }
    try await local.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.contains { $0.value.body.string == "private owner remains usable" })
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: try RepositoryLocalFixture.prepared.get())
func heldRootWorkPreservesLocalDurabilityAndCloseOwnership(fixture: RepositoryLocalFixture) async throws {
    let path = try emptyRepository()
    try Data([2]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let root = try await RepositoryRootSession.open(directory: path), permission = try await root.permission()
    let entered = RootTurnSignal(), release = DispatchSemaphore(value: 0)
    let observation = Task {
        try await root.observe("note.txt", using: permission, beforeRead: {
            Task { await entered.enter() }
            release.wait()
        })
    }
    await entered.wait()
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        await entered.expire(); release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    await #expect(throws: RepositoryRootError.busy) { try await root.observe("note.txt", using: permission) }
    let protection = fixture.protection, local = try await newSession(fixture.initial, protection)
    let selection = await local.selection
    let receipt = try await put("saved while root held", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: local)
    #expect(receipt.sequence == 2)
    try await local.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.contains { $0.value.body.string == "saved while root held" })
    try await reopened.quiesce()
    let finishedWhileHeld = await !entered.expired
    #expect(finishedWhileHeld, "Local durability/reopen must finish while the root turn is held")
    if !finishedWhileHeld {
        _ = try? await observation.value
        await root.close()
        return
    }
    // Cancellation leaves entered work's descriptor owned until actual completion.
    observation.cancel()
    await root.invalidate()
    let close = Task { await root.close() }
    while await root.state == .fenced { await Task.yield() }
    #expect(await root.state == .closing)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    await #expect(throws: RepositoryRootError.closed) { try await root.permission() }
    release.signal()
    await #expect(throws: RepositoryRootError.stalePermission) { try await observation.value }
    await close.value
    let next = try await RepositoryRootSession.open(directory: path)
    await next.close()
}

@Test func missingChildPreservesOwnerWhileUnavailableRootCandidateFencesAdmission() async throws {
    let path = try emptyRepository(), moved = path + "-moved"
    let root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission()
    await #expect(throws: RepositoryRootError.unavailable(ENOENT)) { try await root.observe("missing", using: permission) }
    #expect(await root.state == .active)
    #expect(try await root.revalidate(candidate: path) == .same)
    let current = try await root.permission()
    try FileManager.default.moveItem(atPath: path, toPath: moved)
    await #expect(throws: RepositoryRootError.unavailable(ENOENT)) { try await root.observe("missing", using: current) }
    #expect(await root.state == .active)
    #expect(try await root.revalidate(candidate: path) == .unavailable(ENOENT))
    #expect(await root.state == .fenced, "Unavailable root continuity fences admission independently of child absence")
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.observe("missing", using: current) }
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    let replacement = try await RepositoryRootSession.open(directory: path)
    #expect(try await root.revalidate(candidate: path) == .different)
    #expect(await root.state == .fenced)
    #expect(try await root.revalidate(candidate: moved) == .same)
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.observe("missing", using: current) }
    await root.close(); await replacement.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func failedRootReadRechecksItsCapturedGeneration(rootLost: Bool) async throws {
    let path = try emptyRepository(), root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission(), entered = RootTurnSignal(), release = DispatchSemaphore(value: 0)
    let read = Task {
        try await root.observe("missing", using: permission, beforeRead: {
            Task { await entered.enter() }; release.wait()
        })
    }
    await entered.wait()
    defer { release.signal() }
    if rootLost {
        let replacement = try emptyRepository()
        try #require(unsafe rename(replacement, path) == 0)
    }
    await root.invalidate()
    release.signal()
    await #expect(throws: RepositoryRootError.stalePermission) { try await read.value }
    #expect(await root.state == .fenced)
    await root.close()
}

private actor RootController {
    private let root: RepositoryRootSession
    init(_ root: RepositoryRootSession) { self.root = root }
    func observe(_ permission: RepositoryRootPermission) async throws -> RepositoryEntryObservation {
        try await root.observe("note.txt", using: permission)
    }
    func close() async { await root.close() }
}

private func handOffRoot(_ path: String) async throws -> (RootController, RepositoryRootPermission) {
    let root = try await RepositoryRootSession.open(directory: path)
    return (RootController(root), try await root.permission())
}

@Test func rootOwnershipSurvivesControllerHandoff() async throws {
    let path = try emptyRepository()
    try Data([5]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let (controller, permission) = try await handOffRoot(path)
    for _ in 0..<3 {
        #expect(try await controller.observe(permission).byteCount == 1)
        await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    }
    await controller.close()
    let next = try await RepositoryRootSession.open(directory: path)
    await next.close()
}

@Test func inaccessibleRootCandidateFencesUntilPositiveContinuityReturns() async throws {
    let parent = try emptyRepository(), path = parent + "/root"
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try Data([4]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission()
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: parent)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent) }
    #expect(try await root.observe("note.txt", using: permission).byteCount == 1)
    #expect(try await root.revalidate(candidate: path) == .unavailable(EACCES))
    #expect(await root.state == .fenced)
    await #expect(throws: RepositoryRootError.stalePermission) { try await root.observe("note.txt", using: permission) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    #expect(try await root.revalidate(candidate: path) == .same)
    #expect(try await root.observe("note.txt", using: root.permission()).byteCount == 1)
    await root.close()
}

@Test func unreadableChildPreservesContinuousRootOwnership() async throws {
    let path = try emptyRepository(), locked = path + "/locked"
    try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: false)
    try Data([3]).write(to: URL(fileURLWithPath: locked + "/note.txt"))
    let root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission()
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
    await #expect(throws: RepositoryRootError.unavailable(EACCES)) { try await root.observe("locked/note.txt", using: permission) }
    #expect(await root.state == .active)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked)
    #expect(try await root.observe("locked/note.txt", using: permission).byteCount == 1)
    await root.close()
}

@Test(.timeLimit(.minutes(1))) func repeatedConcurrentClosePreservesEnteredRootWork() async throws {
    let path = try emptyRepository()
    try Data([1]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    for _ in 0..<8 {
        let root = try await RepositoryRootSession.open(directory: path)
        let permission = try await root.permission()
        let entered = RootTurnSignal(), release = DispatchSemaphore(value: 0)
        let read = Task {
            try await root.observe("note.txt", using: permission, beforeRead: {
                Task { await entered.enter() }; release.wait()
            })
        }
        await entered.wait()
        let watchdog = Task {
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            await entered.expire(); release.signal()
        }
        defer { watchdog.cancel(); release.signal() }
        let first = Task { await root.close() }
        while await root.state == .active { await Task.yield() }
        #expect(await root.state == .closing, "Close remains in progress while entered work owns the root")
        let second = Task { await root.close() }
        first.cancel(); second.cancel(); read.cancel()
        await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
        release.signal()
        await #expect(throws: RepositoryRootError.stalePermission) { try await read.value }
        await first.value; await second.value
        #expect(await root.state == .closed)
        #expect(await entered.expired == false)
    }
    let next = try await RepositoryRootSession.open(directory: path)
    await next.close()
}

private func scopedRootOwner(_ path: String) async throws {
    let root = try await RepositoryRootSession.open(directory: path)
    _ = try await root.observe("note.txt", using: root.permission())
}

@Test func abandonedRootOwnerReleasesAfterEnteredWorkReturns() async throws {
    let path = try emptyRepository()
    try Data([1]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    try await scopedRootOwner(path)
    let next = try await RepositoryRootSession.open(directory: path)
    await next.close()
}
