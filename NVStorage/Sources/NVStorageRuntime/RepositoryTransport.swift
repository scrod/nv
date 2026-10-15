import Foundation
import NVStorageCore

/// Copied failure status for an owned transport attempt.
public enum RepositoryTransportFailure: Equatable, Sendable {
    case root(RepositoryRootError), file(RepositoryFileFailure), store(StorageError), deadline
}

/// Discovery and publication can pause independently while local saving remains available.
public enum RepositoryTransportWorkState: Equatable, Sendable {
    case idle, ready, running, waitingForOwner, retryScheduled, paused(RepositoryTransportFailure)
}

public struct RepositoryTransportStatus: Sendable {
    public let discovery: RepositoryTransportWorkState
    public let publication: RepositoryTransportWorkState
    public let materialization: RepositoryTransportWorkState?
    public let stopped: Bool
    fileprivate init(discovery: RepositoryTransportWorkState, publication: RepositoryTransportWorkState,
                     materialization: RepositoryTransportWorkState?, stopped: Bool) {
        self.discovery = discovery; self.publication = publication; self.stopped = stopped
        self.materialization = materialization
    }
}

/// Owner notifications coalesce ordinary opportunities and exact resource settlement.
enum RepositoryTransportSignal: Sendable {
    case discovery, rootSettled, storeSettled, rootFenced, rootAvailable, closed
}

enum RepositoryTransportWork: Sendable { case discovery, publication, materialization }

enum RepositoryTransportObservation: Sendable {
    case discovery(RepositoryDiscoveryTurn), published(PublishedRepositoryBatch)
    case inventory(RepositoryInventoryCheck)
    case inventoryDeferred
    case paused(RepositoryTransportFailure), waiting(RepositoryTransportWork), deadline, idle
    case notification(RepositoryTransportSignal)
    case materialization(SegmentLocator, RepositoryMaterializationRequest)
}

/// Qualification hooks surround the production driver and its actual consumers.
struct RepositoryTransportHooks: Sendable {
    var discovery = RepositoryDiscoveryHooks()
    var publication: (@Sendable (RepositoryPublicationBatch) async throws -> Void)?
    var installEntered: @Sendable (ImmutableRepositoryObject) -> Void = { _ in }
    var inventoryObserved: (@Sendable () async throws -> Void)?
    var observation: (@Sendable (RepositoryTransportObservation) async -> Void)?
    var idleNanoseconds: UInt64 = 30_000_000_000
    var retryNanoseconds: [UInt64] = [1_000_000_000, 4_000_000_000]
    var deadlineNanoseconds: UInt64 = 15_000_000_000
}

private struct TransportAttempt: Sendable {
    var firstStart: UInt64?
    var starts = 0
    func starting(at now: UInt64) -> Self { .init(firstStart: firstStart ?? now, starts: starts + 1) }
}

private enum TransportDemand: Sendable {
    enum WaitingOwner: Sendable { case root, store }
    case idle, ready(TransportAttempt), running(TransportAttempt, again: Bool)
    case waiting(TransportAttempt, owner: WaitingOwner), delayed(TransportAttempt, until: UInt64)
    case paused(RepositoryTransportFailure)

    var state: RepositoryTransportWorkState {
        switch self {
        case .idle: .idle
        case .ready: .ready
        case .running: .running
        case .waiting: .waitingForOwner
        case .delayed: .retryScheduled
        case .paused(let failure): .paused(failure)
        }
    }
    mutating func request(retrying: Bool) {
        switch self {
        case .idle: self = .ready(.init())
        case .paused where retrying: self = .ready(.init())
        case .running(let attempt, _): self = .running(attempt, again: true)
        case .ready, .waiting, .delayed, .paused: break
        }
    }
    var isReady: Bool { if case .ready = self { true } else { false } }
}

/// Coalesces repository opportunities using existing cursors, accepted bytes and owner notifications.
public actor RepositoryTransportDriver {
    private enum Lifecycle { case attaching, active, fenced, stopping, stopped }
    private enum DiscoveryPhase { case directory, inventory(RepositoryInventoryCursor?) }
    private typealias Work = RepositoryTransportWork
    private let identity = UUID()
    private let root: RepositoryRootSession
    private let store: LocalStoreSession
    private let hooks: RepositoryTransportHooks
    private var lifecycle: Lifecycle = .attaching
    private var discovery: TransportDemand = .ready(.init())
    private var discoveryPhase: DiscoveryPhase = .directory
    private var publication: TransportDemand = .ready(.init())
    private var publicationCursor: RepositoryPublicationCursor?
    private var ownedPublication: RepositoryPublicationBatch?
    private var worker: Task<Void, Never>?
    private var wakeup: (UUID, Task<Void, Never>)?
    private var idleDue: UInt64 = 0
    private var deadlineExpired = false
    private var publicationAllowed = true
    private var namedInput: (DisclosedRepositoryObject, TransportDemand)?
    private let namedSettled: (@Sendable (SegmentLocator) async -> Void)?
    private let repositoryObserved: (@Sendable (RepositoryTransportObservation) async -> Void)?
    private let inventoryAllowed: (@Sendable () async -> Bool)?

    private init(root: RepositoryRootSession, store: LocalStoreSession, hooks: RepositoryTransportHooks,
                 waiting: DisclosedRepositoryObject?, namedSettled: (@Sendable (SegmentLocator) async -> Void)?,
                 repositoryObserved: (@Sendable (RepositoryTransportObservation) async -> Void)?,
                 inventoryAllowed: (@Sendable () async -> Bool)?) {
        self.root = root; self.store = store; self.hooks = hooks
        self.namedSettled = namedSettled
        self.repositoryObserved = repositoryObserved
        self.inventoryAllowed = inventoryAllowed
        if let waiting {
            publicationAllowed = false; discovery = .idle; publication = .idle
            namedInput = (waiting, .ready(.init()))
        }
    }

    public static func start(root: RepositoryRootSession, store: LocalStoreSession) async throws -> RepositoryTransportDriver {
        try await start(root: root, store: store, hooks: .init())
    }

    static func start(root: RepositoryRootSession, store: LocalStoreSession,
                      hooks: RepositoryTransportHooks, waiting: DisclosedRepositoryObject? = nil,
                      namedSettled: (@Sendable (SegmentLocator) async -> Void)? = nil,
                      repositoryObserved: (@Sendable (RepositoryTransportObservation) async -> Void)? = nil,
                      inventoryAllowed: (@Sendable () async -> Bool)? = nil) async throws -> RepositoryTransportDriver {
        guard hooks.idleNanoseconds > 0, hooks.retryNanoseconds.count == 2,
              hooks.retryNanoseconds.allSatisfy({ $0 > 0 }), hooks.deadlineNanoseconds > 0 else { throw StorageError.limit }
        try Task.checkCancellation()
        let driver = RepositoryTransportDriver(root: root, store: store, hooks: hooks, waiting: waiting,
            namedSettled: namedSettled, repositoryObserved: repositoryObserved, inventoryAllowed: inventoryAllowed), owner = driver.identity
        let signal: @Sendable (RepositoryTransportSignal) -> Void = { [weak driver] signal in
            Task { await driver?.notified(signal) }
        }
        do {
            try await root.attachTransport(owner, signal: signal)
            try await store.attachTransport(owner, signal: signal)
            try Task.checkCancellation()
            try await driver.activate()
            return driver
        } catch {
            await driver.stop()
            await root.detachTransport(owner); await store.detachTransport(owner)
            throw error
        }
    }

    deinit {
        worker?.cancel(); wakeup?.1.cancel()
        let root = root, store = store, identity = identity
        Task { await root.detachTransport(identity); await store.detachTransport(identity) }
    }

    private func activate() throws {
        guard lifecycle == .attaching else { throw StorageError.closed }
        lifecycle = .active; schedule()
    }

    public func status() -> RepositoryTransportStatus {
        .init(discovery: discovery.state, publication: publication.state,
              materialization: namedInput?.1.state,
              stopped: lifecycle == .stopping || lifecycle == .stopped)
    }

    /// Successful checked publication enables ordinary transport on the already owned worker.
    func allowPublication() {
        guard lifecycle == .active, !publicationAllowed else { return }
        publicationAllowed = true
        discovery.request(retrying: false); publication.request(retrying: false)
        schedule()
    }

    /// Refreshes the same named demand after the collection positively rechecks its physical root.
    func refreshNamedInput(_ evidence: DisclosedRepositoryObject) async throws {
        guard lifecycle == .active, namedInput?.0.locator == evidence.locator else { return }
        try await root.validateDisclosureContext(evidence)
        guard lifecycle == .active, let input = namedInput, input.0.locator == evidence.locator else { return }
        namedInput = (evidence, input.1)
    }

    /// A foreground or explicit refresh starts another bounded attempt using retained inputs.
    public func revisit(_ opportunity: RepositoryDiscoveryOpportunity) {
        guard lifecycle == .active else { return }
        let retrying: Bool
        switch opportunity { case .foreground, .refresh: retrying = true; case .initialOpen, .saveSettled, .backgroundTurn: retrying = false }
        if publicationAllowed { discovery.request(retrying: retrying); publication.request(retrying: retrying) }
        namedInput?.1.request(retrying: retrying)
        schedule()
    }

    /// Stops admission and joins the actual owned work before detaching its notifications.
    public func stop() async {
        guard lifecycle != .stopped else { return }
        lifecycle = .stopping
        cancelWakeup(); worker?.cancel()
        let entered = worker
        await root.detachTransport(identity); await store.detachTransport(identity)
        await entered?.value
        lifecycle = .stopped
    }

    private func notified(_ signal: RepositoryTransportSignal) async {
        guard lifecycle != .stopping, lifecycle != .stopped else { return }
        switch signal {
        case .closed: await stop(); return
        case .rootFenced, .rootAvailable:
            let current = await root.state
            guard lifecycle != .stopping, lifecycle != .stopped else { return }
            switch current {
            case .active:
                if lifecycle == .fenced {
                    lifecycle = .active
                    discoveryPhase = .directory
                    discovery = .ready(.init()); publication = .ready(.init())
                    if !publicationAllowed { discovery = .idle; publication = .idle }
                    if let input = namedInput { namedInput = (input.0, .ready(.init())) }
                }
            case .fenced:
                lifecycle = .fenced; cancelWakeup(); worker?.cancel()
                discovery = .paused(.root(.fenced)); publication = .paused(.root(.fenced))
                if let input = namedInput { namedInput = (input.0, .paused(.root(.fenced))) }
            case .closing, .closed: await stop(); return
            }
        case .discovery:
            if publicationAllowed { discovery.request(retrying: false) }
        case .rootSettled:
            if case .waiting(let attempt, .root) = discovery { discovery = .ready(attempt) }
            if case .waiting(let attempt, .root) = publication { publication = .ready(attempt) }
            if case .waiting(let attempt, .root) = namedInput?.1 { namedInput?.1 = .ready(attempt) }
        case .storeSettled:
            if case .waiting(let attempt, .store) = discovery { discovery = .ready(attempt) }
            if publicationAllowed { publication.request(retrying: false) }
            if case .waiting(let attempt, .store) = publication { publication = .ready(attempt) }
            if case .waiting(let attempt, .store) = namedInput?.1 { namedInput?.1 = .ready(attempt) }
        }
        schedule()
        await hooks.observation?(.notification(signal))
    }

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    private func cancelWakeup() { wakeup?.1.cancel(); wakeup = nil }

    private func schedule() {
        guard lifecycle == .active, worker == nil else { return }
        if discovery.isReady || publication.isReady || namedInput?.1.isReady == true {
            cancelWakeup()
            worker = Task { [weak self] in await self?.run() }
            return
        }
        var dates: [UInt64] = []
        if publicationAllowed, case .idle = discovery { dates.append(idleDue) }
        for demand in [discovery, publication] + (namedInput.map { [$0.1] } ?? []) {
            if case .delayed(_, let due) = demand { dates.append(due) }
        }
        if let due = dates.min() { armWakeup(at: due, deadline: false) }
    }

    private func armWakeup(at due: UInt64, deadline: Bool) {
        cancelWakeup()
        let token = UUID(), delay = due > Self.now ? due - Self.now : 0
        wakeup = (token, Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            await self?.woke(token, deadline: deadline)
        })
    }

    private func woke(_ token: UUID, deadline: Bool) async {
        guard wakeup?.0 == token, lifecycle == .active else { return }
        wakeup = nil
        if deadline {
            deadlineExpired = true; worker?.cancel()
            await hooks.observation?(.deadline); return
        }
        let now = Self.now
        if publicationAllowed, case .idle = discovery, idleDue <= now { discovery = .ready(.init()) }
        if case .delayed(let attempt, let due) = discovery, due <= now { discovery = .ready(attempt) }
        if case .delayed(let attempt, let due) = publication, due <= now { publication = .ready(attempt) }
        if case .delayed(let attempt, let due) = namedInput?.1, due <= now { namedInput?.1 = .ready(attempt) }
        schedule()
    }

    private func run() async {
        defer { cancelWakeup(); worker = nil; schedule() }
        while lifecycle == .active, !Task.isCancelled {
            guard discovery.isReady || publication.isReady || namedInput?.1.isReady == true else { break }
            if publication.isReady { await perform(.publication) }
            if lifecycle == .active, !Task.isCancelled, namedInput?.1.isReady == true { await perform(.materialization) }
            if lifecycle == .active, !Task.isCancelled, discovery.isReady { await perform(.discovery) }
            await Task.yield()
        }
        if lifecycle == .active { await hooks.observation?(.idle) }
    }

    private func demand(_ work: Work) -> TransportDemand {
        switch work { case .discovery: discovery; case .publication: publication; case .materialization: namedInput?.1 ?? .idle }
    }
    private func set(_ demand: TransportDemand, for work: Work) {
        switch work { case .discovery: discovery = demand; case .publication: publication = demand; case .materialization: namedInput?.1 = demand }
    }

    private func perform(_ work: Work) async {
        guard case .ready(let prior) = demand(work) else { return }
        set(.running(prior, again: false), for: work)
        if work == .discovery, case .inventory = discoveryPhase,
           let inventoryAllowed, await !inventoryAllowed() {
            guard lifecycle == .active, !Task.isCancelled else { return }
            // Preserve the next batch and retry budget for the existing periodic opportunity.
            set(.delayed(prior, until: Self.now &+ hooks.idleNanoseconds), for: work)
            await hooks.observation?(.inventoryDeferred)
            return
        }
        guard lifecycle == .active, !Task.isCancelled, case .running(_, let again) = demand(work) else { return }
        let attempt = prior.starting(at: Self.now)
        set(.running(attempt, again: again), for: work)
        deadlineExpired = false
        armWakeup(at: (attempt.firstStart ?? Self.now) &+ hooks.deadlineNanoseconds, deadline: true)
        do {
            switch work {
            case .materialization:
                guard let input = namedInput?.0 else { throw StorageError.staleCapture }
                switch try await root.recheckDisclosure(input) {
                case .readable(let bytes):
                    let selection = store.selection, protection = store.protection
                    _ = try await store.lane.historyWork {
                        try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection,
                            expectedLocator: input.locator)
                    }
                    _ = try await store.receive(bytes)
                    try finishDeadline()
                    guard lifecycle == .active else { return }
                    namedInput = nil
                    await namedSettled?(input.locator)
                case .unread(let current):
                    let request = try await root.materialize(current)
                    try finishDeadline()
                    guard lifecycle == .active else { return }
                    await hooks.observation?(.materialization(current.locator, request))
                    await failed(.root(.unavailable(EAGAIN)), work: work, attempt: attempt)
                case .unavailable(let failure):
                    try finishDeadline()
                    await failed(.file(failure), work: work, attempt: attempt)
                }
            case .publication:
                let batch: RepositoryPublicationBatch
                if let ownedPublication { batch = ownedPublication }
                else {
                    batch = try await store.captureRepositoryPublication(continuing: publicationCursor,
                        maximumObjects: 8, byteBudget: 1024 * 1024)
                    ownedPublication = batch
                }
                try await hooks.publication?(batch)
                try Task.checkCancellation()
                let permission = try await root.permission()
                switch try await root.publish(batch, from: store, using: permission, beforeInstall: hooks.installEntered) {
                case .incomplete(_, let failure):
                    try finishDeadline()
                    await failed(.file(failure.reason), work: work, attempt: attempt)
                case .complete(let published):
                    try await root.validate(published, from: store, using: permission)
                    try finishDeadline()
                    guard lifecycle == .active else { return }
                    let again: Bool
                    if case .running(_, let requested) = publication { again = requested } else { return }
                    publicationCursor = batch.continuation ?? batch.nextPass
                    ownedPublication = nil
                    // An indexed empty pass closes the drain after every frozen prefix,
                    // including saves notified during an earlier continuation batch.
                    publication = !batch.locators.isEmpty || again ? .ready(.init()) : .idle
                    if !published.locators.isEmpty { discovery.request(retrying: false) }
                    await hooks.observation?(.published(published))
                }
            case .discovery:
                if case .inventory(let cursor) = discoveryPhase {
                    let batch = try await store.captureRepositoryInventory(continuing: cursor,
                        through: publicationCursor?.inventoryThrough ?? 0)
                    let checked = try await root.checkInventory(batch, from: store, observed: hooks.inventoryObserved)
                    try await root.validate(checked, for: store)
                    try finishDeadline()
                    guard lifecycle == .active else { return }
                    let again: Bool
                    if case .running(_, let requested) = discovery { again = requested } else { return }
                    let failure = checked.failures.first { $0 == .conflict || $0 == .kindCollision || $0 == .hardLinked }
                        ?? checked.failures.first
                    if let failure { publication = .paused(.file(failure)) }
                    else {
                        discoveryPhase = batch.continuation.map { .inventory($0) } ?? .directory
                        discovery = batch.continuation != nil || again ? .ready(.init()) : .idle
                        if batch.continuation == nil { idleDue = Self.now &+ hooks.idleNanoseconds }
                    }
                    await hooks.observation?(.inventory(checked))
                    await repositoryObserved?(.inventory(checked))
                    if let failure, lifecycle == .active {
                        await failed(.file(failure), work: work, attempt: attempt)
                    }
                    return
                }
                let turn = try await root.discover(into: store, opportunity: .backgroundTurn, budget: 16, hooks: hooks.discovery)
                try await root.validate(turn, for: store)
                try finishDeadline()
                guard lifecycle == .active else { return }
                let again: Bool
                if case .running(_, let requested) = discovery { again = requested } else { return }
                if turn.passEnded && !again && turn.latestInvalidation == turn.capturedInvalidation { discoveryPhase = .inventory(nil) }
                discovery = .ready(.init())
                await hooks.observation?(.discovery(turn))
                await repositoryObserved?(.discovery(turn))
            }
        } catch {
            cancelWakeup()
            guard lifecycle == .active else { return }
            if deadlineExpired { await failed(.deadline, work: work, attempt: attempt); return }
            if error as? RepositoryRootError == .busy || error as? StorageError == .busy {
                let owner: TransportDemand.WaitingOwner = error as? RepositoryRootError == .busy ? .root : .store
                set(.waiting(prior, owner: owner), for: work)
                // Recheck after registration so an earlier settlement notification remains effective.
                let ready: Bool
                switch owner { case .root: ready = await root.transportReady(); case .store: ready = await store.transportReady() }
                if lifecycle == .active, ready, case .waiting = demand(work) { set(.ready(prior), for: work) }
                await hooks.observation?(.waiting(work))
                return
            }
            if error as? RepositoryRootError == .stalePermission, await root.state == .active {
                guard lifecycle == .active else { return }
                if work == .materialization {
                    guard let input = namedInput?.0 else { return }
                    do { try await root.validateDisclosureContext(input) }
                    catch { await failed(.root(.stalePermission), work: work, attempt: attempt); return }
                }
                set(.ready(.init()), for: work); return
            }
            if let root = error as? RepositoryRootError { await failed(.root(root), work: work, attempt: attempt) }
            else { await failed(.store(classify(error)), work: work, attempt: attempt) }
        }
    }

    private func finishDeadline() throws {
        cancelWakeup()
        if deadlineExpired || Task.isCancelled { throw CancellationError() }
    }

    private func failed(_ failure: RepositoryTransportFailure, work: Work, attempt: TransportAttempt) async {
        await repositoryObserved?(.paused(failure))
        guard lifecycle == .active else { return }
        let retryable: Bool
        switch failure {
        case .root(.unavailable), .file(.io), .file(.changed), .file(.absent): retryable = true
        case .root, .file, .store, .deadline: retryable = false
        }
        let now = Self.now, first = attempt.firstStart ?? now
        if retryable, attempt.starts <= hooks.retryNanoseconds.count {
            let due = now &+ hooks.retryNanoseconds[attempt.starts - 1]
            if due < first &+ hooks.deadlineNanoseconds {
                set(.delayed(attempt, until: due), for: work); return
            }
        }
        set(.paused(failure), for: work)
        if case .store = failure {
            discovery = .paused(failure); publication = .paused(failure)
            if let input = namedInput { namedInput = (input.0, .paused(failure)) }
        }
        await hooks.observation?(.paused(failure))
    }
}
