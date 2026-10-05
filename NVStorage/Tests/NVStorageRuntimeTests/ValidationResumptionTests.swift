import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

/// Suspends captured history checks while the database and preparation workers remain available.
actor HistoryCheckGate {
    private var entered = 0, released = 0
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private var checks: [(Int, CheckedContinuation<Void, Never>)] = []
    func check() async {
        entered += 1
        let pass = entered
        let ready = observers.filter { $0.0 <= entered }
        observers.removeAll { $0.0 <= entered }
        for (_, observer) in ready { observer.resume() }
        if pass <= 2 && released < pass { await withCheckedContinuation { checks.append((pass, $0)) } }
    }
    func waitFor(_ pass: Int) async {
        await withCheckedContinuation { continuation in
            if entered >= pass { continuation.resume() } else { observers.append((pass, continuation)) }
        }
    }
    func release(_ pass: Int) {
        released = pass
        let ready = checks.filter { $0.0 <= released }; checks.removeAll { $0.0 <= released }
        for (_, check) in ready { check.resume() }
    }
}

/// Holds delivery of a committed local result while freeing the database writer.
private actor AcceptanceGate {
    var entered = false, released = false
    var observers: [CheckedContinuation<Void, Never>] = []
    var completion: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        let ready = observers; observers.removeAll()
        for observer in ready { observer.resume() }
        if !released { await withCheckedContinuation { completion = $0 } }
    }
    func wait() async {
        if !entered { await withCheckedContinuation { observers.append($0) } }
    }
    func release() { released = true; completion?.resume(); completion = nil }
}

enum ResumptionExit: CaseIterable, Sendable { case alreadyFinished, active, cancel, quiesce, pendingCommit }

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func connectedParkedCopyResumesAfterFiniteSaveInterference(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let left = try await newSession(initial, protection), right = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let l = try await put("Left", birth: a, generation: 1, session: left), r = try await put("Right", birth: a, generation: 1, session: right)
    _ = try await left.receive(right.retainedObject(at: r.object))
    let rID = try #require(try await right.snapshot().notes.first { $0.birth == a }).revision.id
    let copy = try await left.copyVersion(for: a, revision: rID, generation: 2)
    let child = try requireReceipt(await left.persist(capture: copy)), childBytes = try await left.retainedObject(at: child.object)
    guard case .waiting(let both) = try await receiver.receive(childBytes) else { Issue.record("The copy must actually park"); return }
    #expect(Set(both) == [.acceptedHistory(l.object), .acceptedHistory(r.object)])
    _ = try await receiver.receive(left.retainedObject(at: l.object))
    guard case .waiting(let last) = try await receiver.receivedObjectStatus(at: child.object) else { Issue.record("One prerequisite must keep the copy parked"); return }
    #expect(last == [.acceptedHistory(r.object)])
    let lane = await receiver.lane, history = HistoryCheckGate(), completion = AcceptanceGate()
    defer { Task { await history.release(2) } }
    try await lane.perform { db in db.work = StorageWork(); db.work?.historyCheck = { await history.check() } }
    let bytes = try await right.retainedObject(at: r.object)
    let receiving = Task { try await receiver.receive(bytes) }
    await history.waitFor(1)
    _ = try await put("local 1", birth: b, generation: 1, session: receiver)
    await history.release(1); await history.waitFor(2)
    let captured = try await CapturedActionGroup(snapshot: receiver.snapshot(), kind: .savedEdit, changes: [.put(.init(birth: b, generation: 2), testValue("local 2"))])
    try await lane.perform { db in db.work?.acceptanceCompletion = { _ in await completion.hold() } }
    let saving = Task { try await receiver.persist(capture: captured) }
    await completion.wait(); await history.release(2)
    try #require(try await eventually { await receiver.validationWaitIsRegistered }, "The postponed receive must be waiting on the finite save")
    await completion.release(); _ = try requireReceipt(await saving.value)
    try #require(try await eventually { await receiver.receiveFinished }, "The complete copy must resume without another delivery")
    if case .accepted = try await receiving.value {} else { Issue.record("The final prerequisite must accept") }
    if case .accepted = try await receiver.receivedObjectStatus(at: child.object) {} else { Issue.record("Its durable wakeup must also accept the copy") }
    #expect(try await receiver.snapshot().notes.first { $0.birth == copy.covered[0].birth }?.value.body.string == "Right")
    #expect(try await receiver.snapshot().notes.first { $0.birth == b }?.value.body.string == "local 2")
    let members = try await lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") }
    let repackaged = try ObjectEnvelopeV1.seal(payload: ObjectEnvelopeV1.open(childBytes, collection: initial.descriptor.collection, protection: protection).payload,
        kind: .changes, collection: initial.descriptor.collection, writer: .init(bytes: Array(repeating: 73, count: 16)), sequence: 0, protection: protection)
    _ = try await receiver.receive(repackaged)
    #expect(try await lane.perform { try $0.rows("SELECT COUNT(*) FROM actions") } == members)
    #expect(try await receiver.retainedObject(at: child.object) == childBytes)
    let selection = await receiver.selection; try await receiver.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes.first { $0.birth == copy.covered[0].birth }?.value.body.string == "Right")
    try await reopened.quiesce(); try await left.quiesce(); try await right.quiesce()
}

/// A watchdog observes the required state; the gates arrange the schedule.
private func eventually(_ condition: () async -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if await condition() { return true }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    return await condition()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], ResumptionExit.allCases)
func validationResumesAfterTwoInterferingSaves(encrypted: Bool, exit: ResumptionExit) async throws {
    let holdLastCompletion = exit != .alreadyFinished
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), receiver = try await newSession(initial, protection)
    let a = try NoteBirth(bytes: Array(repeating: 1, count: 16)), b = try NoteBirth(bytes: Array(repeating: 2, count: 16))
    let remote = try await put("remote", birth: b, generation: 1, session: source)
    let bytes = try await source.retainedObject(at: remote.object)
    _ = try await put("local 0", birth: a, generation: 1, session: receiver)
    let lane = await receiver.lane, history = HistoryCheckGate(), completion = AcceptanceGate()
    defer { Task { await history.release(2) } }
    try await lane.perform { db in
        db.work = StorageWork()
        db.work?.historyCheck = { await history.check() }
    }
    let receiving = Task { try await receiver.receive(bytes) }
    await history.waitFor(1)
    let first = try await put("local 1", birth: a, generation: 2, session: receiver)
    await history.release(1)
    await history.waitFor(2)
    let capture = try await CapturedActionGroup(snapshot: receiver.snapshot(), kind: .savedEdit,
        changes: [.put(CapturedNoteGeneration(birth: a, generation: 3), testValue("local 2"))])
    if holdLastCompletion {
        try await lane.perform { db in
            db.work?.acceptanceCompletion = { locator in
                if locator != remote.object {
                    await completion.hold()
                    if exit == .pendingCommit { throw StorageError.database(10) }
                }
            }
        }
    }
    let saving = Task { try await receiver.persist(capture: capture) }
    if holdLastCompletion { await completion.wait() }
    else { _ = try requireReceipt(await saving.value) }
    await history.release(2)
    var closing: Task<Void, Error>?
    if holdLastCompletion {
        var waiting = try await eventually { await receiver.validationWaitIsRegistered }
        try #require(waiting, "receive must wait for the active save after exhausting both checks")
        // A shared completion notification may arrive while a save remains active.
        await receiver.signalWaitersWhileSaveIsActive()
        waiting = try await eventually { await receiver.validationWaitIsRegistered }
        try #require(waiting, "a woken receiver must recheck active save work")
        await #expect(throws: StorageError.busy) { try await receiver.receive(bytes) }
        #expect(try await lane.perform { try $0.rows("SELECT object_id FROM ready_objects") } == [[.blob(remote.object.segmentID.bytes)]])
        guard case .pendingValidation = try await receiver.receivedObjectStatus(at: remote.object) else {
            Issue.record("retained ready input must report pending validation"); return
        }
        if exit == .cancel { receiving.cancel() }
        if exit == .quiesce || exit == .pendingCommit {
            closing = Task { try await receiver.quiesce() }
            let registered = try await eventually { await receiver.closeWaitIsRegistered }
            try #require(registered, "quiesce must own its wait before completion is released")
        }
        await completion.release()
    }
    let saved = try await saving.value
    let completed = try await eventually { await receiver.receiveFinished }
    try #require(completed, "owned receive must resume from save completion alone")
    guard case .accepted(let sequence) = try await receiving.value else {
        Issue.record("postponed receive must complete without another arrival"); return
    }
    #expect(sequence == 5)
    if exit == .quiesce {
        try await closing?.value
    } else {
        #expect(try await lane.perform { $0.work![.validation].fullChecks } == 3)
        #expect(try await receiver.snapshot().notes.map(\.value.body.string).sorted() == ["local 2", "remote"])
    }
    if exit == .pendingCommit {
        guard case .pending(let handle, .database(10)) = saved else { Issue.record("lost completion must preserve retry ownership"); return }
        await #expect(throws: StorageError.busy) { try await closing?.value }
        try await lane.perform { $0.work?.acceptanceCompletion = nil }
        let recovered = try requireReceipt(await receiver.retry(commit: handle))
        #expect(recovered.sequence == 4)
    } else { #expect(try requireReceipt(saved).sequence == 4) }
    let selection = await receiver.selection
    try await receiver.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    for (actionSequence, expected) in [(first.sequence, "local 1"), (Int64(4), "local 2")] {
        let reopenLane = await reopened.lane
        let retained = try await reopenLane.perform { db in
            try db.rows("SELECT encoded FROM objects JOIN accepted_objects USING(object_id) WHERE seq=?", [.integer(actionSequence)])[0][0].bytes
        }
        let p = try ChangesPayloadV1.decodeV1(ObjectEnvelopeV1.open(retained,
            collection: initial.descriptor.collection, protection: protection).payload)
        guard case .put(_, _, let v) = p.operations[0].operation.effect else { Issue.record("local edit missing"); return }
        #expect(v.body.string == expected)
    }
    #expect(try await reopened.snapshot().through == 5)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["local 2", "remote"])
    #expect(try await reopened.retainedObject(at: remote.object) == bytes)
    try await reopened.quiesce(); try await source.quiesce()
}

extension LocalStoreSession {
    fileprivate var receiveFinished: Bool { !receiving }
    fileprivate var validationWaitIsRegistered: Bool { receiving && inFlight && !drained.isEmpty }
    fileprivate var closeWaitIsRegistered: Bool { quiescing && drained.count >= 2 }
    fileprivate func signalWaitersWhileSaveIsActive() {
        let waiting = drained; drained.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

@Test func historyInterferenceRetainsItsOwnFailureCategory() {
    #expect(classify(HistoryValidationInterrupted.historyAdvanced) == .busy)
    #expect(ReceiveRejection(HistoryValidationInterrupted.historyAdvanced) == nil)
    for code: Int32 in [5, 10, 13] {
        #expect(classify(StorageError.database(code)) == .database(code))
        #expect(ReceiveRejection(StorageError.database(code)) == nil)
    }
}
