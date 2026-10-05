import Foundation
import NVStorageCore
@testable import NVStorageRuntime
import Testing

/// Holds the real command worker until the test has observed a completed competing operation.
private final class CommandGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var timedOut = false
    func block() {
        condition.lock(); defer { condition.unlock() }
        entered = true; condition.broadcast()
        let deadline = Date().addingTimeInterval(15)
        while !released {
            if !condition.wait(until: deadline) { timedOut = true; return }
        }
    }
    func waitForEntry() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                self.condition.lock()
                let deadline = Date().addingTimeInterval(15)
                while !self.entered {
                    if !self.condition.wait(until: deadline) { break }
                }
                let entered = self.entered
                self.condition.unlock(); continuation.resume(returning: entered)
            }
        }
    }
    var held: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered && !released && !timedOut
    }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

private enum ScheduledCommand: CaseIterable, Sendable { case candidates, prepare, apply, native, conflicts, copy }
private func schedulingBirth(_ byte: UInt8) throws -> NoteBirth { try .init(bytes: Array(repeating: byte, count: 16)) }

@Suite(.serialized)
struct CommandSchedulingTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], ScheduledCommand.allCases)
    private func commandCalculationYieldsToLocalSave(encrypted: Bool, command: ScheduledCommand) async throws {
        let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
        let source = try schedulingBirth(1), sentinel = try schedulingBirth(2)
        let saved = try await put("local source", birth: source, generation: 1, session: store)
        let decoded = try await ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(store.retainedObject(at: saved.object),
            collection: initial.descriptor.collection, protection: protection).payload)
        let action = decoded.actions[0].action.id, revision = decoded.operations[0].operation.id
        if command == .conflicts || command == .copy {
            let other = try await newSession(initial, protection)
            let remote = try await put("remote source", birth: source, generation: 1, session: other)
            _ = try await store.receive(other.retainedObject(at: remote.object)); try await other.quiesce()
        }
        let prepared = command == .apply ? try await store.prepareCompensation(scope: .note(source), direction: .undo) : nil
        let before = try await store.snapshot(), gate = CommandGate()
        try await store.lane.perform { $0.work = StorageWork(commandCheck: { gate.block() }) }
        defer { gate.release() }
        let calculation = Task {
            switch command {
            case .candidates:
                let result = try await store.undoCandidates(scope: .note(source), direction: .undo)
                #expect(result.ids == [action] && result.mode == .automatic)
            case .prepare:
                guard case .automatic(let result) = try await store.prepareCompensation(scope: .note(source), direction: .undo) else {
                    Issue.record("Expected a complete proposal"); return
                }
                #expect(result.proposal.candidate == action)
            case .apply:
                guard case .automatic(let proposal) = prepared else { Issue.record("Expected the frozen automatic command"); return }
                guard case .pending(_, .staleCapture) = try await store.applyCompensation(proposal) else {
                    Issue.record("The intervening save must fence the old acceptance prefix"); return
                }
            case .native:
                let capture = try await store.nativeCompensation(for: source,
                    steps: [.init(value: testValue("A"), coverage: [.init(action: action, complete: true)])], generation: 2)
                guard case .pending(_, .staleCapture) = try await store.persist(capture: capture) else {
                    Issue.record("The intervening save must fence the old acceptance prefix"); return
                }
            case .conflicts:
                let conflicts = try await store.conflicts(for: source)
                #expect(conflicts.current == before.notes.first { $0.birth == source })
                #expect(conflicts.alternatives.count == 1)
            case .copy:
                let capture = try await store.copyVersion(for: source, revision: revision, generation: 2)
                guard case .pending(_, .staleCapture) = try await store.persist(capture: capture) else {
                    Issue.record("The intervening save must fence the old acceptance prefix"); return
                }
            }
        }
        try #require(await gate.waitForEntry())
        let independent = try await put("saved during command", birth: sentinel, generation: 2, session: store)
        #expect(gate.held)
        #expect(try await store.snapshot().notes.first { $0.birth == sentinel }?.value.body.string == "saved during command")
        gate.release(); try await calculation.value
        #expect(try await store.snapshot().through >= independent.sequence)
        #expect(try await store.snapshot().notes.first { $0.birth == sentinel }?.value.body.string == "saved during command")
        #expect(try await store.snapshot().notes.first { $0.birth == source } == before.notes.first { $0.birth == source })
        // An explicit retry captures the new global prefix while retaining the unchanged selected intent.
        switch command {
        case .apply:
            guard case .automatic(let proposal) = prepared else { Issue.record("Expected the frozen automatic command"); return }
            _ = try requireReceipt(await store.applyCompensation(proposal))
        case .native:
            let fresh = try await store.nativeCompensation(for: source,
                steps: [.init(value: testValue("A"), coverage: [.init(action: action, complete: true)])], generation: 2)
            _ = try requireReceipt(await store.persist(capture: fresh))
        case .copy:
            let fresh = try await store.copyVersion(for: source, revision: revision, generation: 2)
            _ = try requireReceipt(await store.persist(capture: fresh))
        default: break
        }
        try await store.quiesce()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func commandCalculationChecksCloseAndCancellation(encrypted: Bool, closing: Bool) async throws {
        let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
        let birth = try schedulingBirth(1)
        _ = try await put("eligible", birth: birth, generation: 1, session: store)
        let gate = CommandGate(), through = try await store.snapshot().through
        try await store.lane.perform { $0.work = StorageWork(commandCheck: { gate.block() }) }
        defer { gate.release() }
        let query = Task { try await store.prepareCompensation(scope: .note(birth), direction: .undo) }
        try #require(await gate.waitForEntry())
        if closing { try await store.quiesce() } else { query.cancel() }
        #expect(gate.held)
        gate.release()
        if closing { await #expect(throws: StorageError.closed) { try await query.value } }
        else {
            await #expect(throws: CancellationError.self) { try await query.value }
            #expect(try await store.snapshot().through == through)
            _ = try await put("save after cancellation", birth: birth, generation: 2, session: store)
            try await store.quiesce()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func changedNoteDuringCommandCalculationRequiresNewApproval(encrypted: Bool) async throws {
        let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
        let birth = try schedulingBirth(1)
        _ = try await put("eligible", birth: birth, generation: 1, session: store)
        guard case .automatic(let proposal) = try await store.prepareCompensation(scope: .note(birth), direction: .undo) else {
            Issue.record("Expected a complete proposal"); return
        }
        let gate = CommandGate()
        try await store.lane.perform { $0.work = StorageWork(commandCheck: { gate.block() }) }
        defer { gate.release() }
        let command = Task { try await store.applyReviewedCompensation(proposal.forReview()) }
        try #require(await gate.waitForEntry())
        let newer = try await put("newer input", birth: birth, generation: 2, session: store)
        #expect(gate.held)
        gate.release()
        guard case .pending(_, .staleCapture) = try await command.value else {
            Issue.record("A changed note must invalidate the old command capture"); return
        }
        #expect(try await store.snapshot().through == newer.sequence)
        #expect(try await store.snapshot().notes.first { $0.birth == birth }?.value.body.string == "newer input")
        _ = try await put("next valid save", birth: birth, generation: 3, session: store)
        try await store.quiesce()
    }
}
