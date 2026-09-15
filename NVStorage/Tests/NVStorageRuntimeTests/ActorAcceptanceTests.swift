import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Holds the first completed validation until an intervening local save finishes.
private actor ValidatedHistoryGate {
    var entered = false, released = false
    var observer: CheckedContinuation<Void, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; observer?.resume(); observer = nil
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func wait() async {
        if !entered { await withCheckedContinuation { observer = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func actorAcceptanceRechecksAfterFinalHistoryRead(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let remote = try await put("remote B", birth: b, generation: 1, session: source)
    let bytes = try await source.retainedObject(at: remote.object)
    _ = try await put("local A", birth: a, generation: 1, session: receiver)
    let lane = await receiver.lane, gate = ValidatedHistoryGate()
    try await lane.perform { db in
        db.work = StorageWork()
        db.work?.historyValidated = { await gate.hold() }
    }
    let receiving = Task { try await receiver.receive(bytes) }
    await gate.wait()
    let local = try await put("new A", birth: a, generation: 2, session: receiver)
    await gate.release()
    guard case .accepted(let sequence) = try await receiving.value else { Issue.record("Expected accepted remote B"); return }
    #expect(sequence == local.sequence + 1)
    #expect(try await lane.perform { $0.work![.validation].fullChecks } == 2)
    #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["new A", "remote B"])
    #expect(try await receiver.retainedObject(at: remote.object) == bytes)
    try await source.quiesce(); try await receiver.quiesce()
}
