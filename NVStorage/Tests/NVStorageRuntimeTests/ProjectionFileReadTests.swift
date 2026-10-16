import Foundation
import Testing
import NVStorageCore
import NVStorageTestSupport
@testable import NVStorageRuntime

@Test(arguments: [[], Array("exact\r\nbody".utf8)])
func projectionFileReadRetainsExactBytes(bytes: [UInt8]) async throws {
    let path = try emptyRepository()
    try Data(bytes).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission()
    let observation = try await root.observe("note.txt", using: permission)
    let result = try await root.readProjection(observation, maximumBytes: bytes.count, using: permission)
    guard case .snapshot(let snapshot) = result else { Issue.record("Expected exact projection snapshot"); return }
    #expect(snapshot.bytes == bytes)
    #expect(snapshot.name.spelling.string == "note.txt")
    #expect(snapshot.encoding == .absent && snapshot.tags == .absent && snapshot.stamp == .absent)
    #expect(snapshot.modified.nanoseconds < 1_000_000_000)
    // Native encodings can expand a legal canonical body beyond one history object's size.
    guard case .snapshot(let expandedBudget) = try await root.readProjection(observation,
        maximumBytes: 128 * 1024 * 1024, using: permission) else {
        Issue.record("Caller-selected encoded-file budget must remain usable"); return
    }
    #expect(expandedBudget.bytes == bytes)
    #if canImport(Darwin)
    #expect(snapshot.created != nil)
    #else
    #expect(snapshot.created == nil)
    #endif
    await root.close()
}

@Test func projectionFileReadRejectsChangedContextAndOversize() async throws {
    let path = try emptyRepository(), otherPath = try emptyRepository()
    let file = URL(fileURLWithPath: path + "/note.txt")
    try Data([1, 2]).write(to: file)
    let root = try await RepositoryRootSession.open(directory: path)
    let other = try await RepositoryRootSession.open(directory: otherPath)
    let permission = try await root.permission()
    let observation = try await root.observe("note.txt", using: permission)
    if case .unavailable(.sizeLimit) = try await root.readProjection(observation, maximumBytes: 1, using: permission) {}
    else { Issue.record("Exact size bound must reject before reading") }
    await #expect(throws: RepositoryRootError.wrongContext) {
        try await other.readProjection(observation, maximumBytes: 2, using: other.permission())
    }
    try Data([3, 4]).write(to: file, options: .atomic)
    if case .unavailable(.changed) = try await root.readProjection(observation, maximumBytes: 2, using: permission) {}
    else { Issue.record("Changed physical item must reject captured observation") }
    let current = try await root.observe("note.txt", using: permission)
    guard case .snapshot(let snapshot) = try await root.readProjection(current, maximumBytes: 2, using: permission) else {
        Issue.record("Changed-item companion must succeed"); return
    }
    #expect(snapshot.bytes == [3, 4])
    await root.invalidate()
    await #expect(throws: RepositoryRootError.stalePermission) {
        try await root.readProjection(current, maximumBytes: 2, using: permission)
    }
    await root.close(); await other.close()
}

@Test(arguments: ["directory", "symlink", "hardlink"], [0, 1024])
func projectionFileReadPreservesUnsupportedOccupants(kind: String, maximum: Int) async throws {
    let path = try emptyRepository(), file = path + "/note.txt", original = path + "/original.txt"
    try Data([8]).write(to: URL(fileURLWithPath: original))
    switch kind {
    case "directory": try FileManager.default.createDirectory(atPath: file, withIntermediateDirectories: false)
    case "symlink": try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: original)
    default: try FileManager.default.linkItem(atPath: original, toPath: file)
    }
    let root = try await RepositoryRootSession.open(directory: path)
    let permit = try await root.permission()
    let observed = try await root.observe("note.txt", using: permit)
    if case .unavailable(let failure) = try await root.readProjection(observed, maximumBytes: maximum, using: permit) {
        #expect(failure == (kind == "hardlink" ? .hardLinked : .kindCollision))
    } else { Issue.record("Unsupported occupant must remain unread") }
    #expect(try Data(contentsOf: URL(fileURLWithPath: original)) == Data([8]))
    await root.close()
}

@Test(.timeLimit(.minutes(1))) func projectionFileReadOwnsEnteredWorkThroughClose() async throws {
    let path = try emptyRepository()
    try Data([7]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission()
    let observation = try await root.observe("note.txt", using: permission)
    let entered = ImprovementGate(), release = DispatchSemaphore(value: 0)
    let read = Task {
        try await root.readProjection(observation, maximumBytes: 1, using: permission, beforeRead: {
            Task { await entered.signal() }; release.wait()
        })
    }
    await entered.wait()
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        Issue.record("Entered read did not settle before watchdog"); release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    await #expect(throws: RepositoryRootError.busy) {
        try await root.readProjection(observation, maximumBytes: 1, using: permission)
    }
    let close = Task { await root.close() }
    while await root.state == .active { await Task.yield() }
    #expect(await root.state == .closing)
    await #expect(throws: RepositoryRootError.contention) { try await RepositoryRootSession.open(directory: path) }
    read.cancel(); release.signal()
    await #expect(throws: RepositoryRootError.stalePermission) { try await read.value }
    await close.value
    #expect(await root.state == .closed)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/note.txt")) == Data([7]))
}

@Test func projectionFileReadFollowsOwnedRootMove() async throws {
    let path = try emptyRepository(), moved = path + "-moved"
    try Data([9]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission()
    let observation = try await root.observe("note.txt", using: permission)
    try FileManager.default.moveItem(atPath: path, toPath: moved)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    try Data([3]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    guard case .snapshot(let snapshot) = try await root.readProjection(observation, maximumBytes: 1, using: permission) else {
        Issue.record("Owned root must retain exact read after movement"); return
    }
    #expect(snapshot.bytes == [9])
    #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/note.txt")) == Data([3]))
    await root.close()
}

@Test(.timeLimit(.minutes(1))) func projectionFileReadCancellationFencesPublication() async throws {
    let path = try emptyRepository()
    try Data([7]).write(to: URL(fileURLWithPath: path + "/note.txt"))
    let root = try await RepositoryRootSession.open(directory: path)
    let permission = try await root.permission()
    let observation = try await root.observe("note.txt", using: permission)
    let entered = ImprovementGate(), release = DispatchSemaphore(value: 0)
    let read = Task {
        try await root.readProjection(observation, maximumBytes: 1, using: permission, beforeRead: {
            Task { await entered.signal() }; release.wait()
        })
    }
    await entered.wait()
    let watchdog = Task {
        do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
        Issue.record("Cancelled read did not settle before watchdog"); release.signal()
    }
    defer { watchdog.cancel(); release.signal() }
    read.cancel()
    await #expect(throws: RepositoryRootError.busy) {
        try await root.readProjection(observation, maximumBytes: 1, using: permission)
    }
    release.signal()
    await #expect(throws: CancellationError.self) { try await read.value }
    guard case .snapshot(let companion) = try await root.readProjection(observation, maximumBytes: 1, using: permission) else {
        Issue.record("Fresh read must succeed after the cancelled attempt settles"); return
    }
    #expect(companion.bytes == [7])
    await root.close()
}
