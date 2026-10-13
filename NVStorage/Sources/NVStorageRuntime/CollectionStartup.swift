import Foundation
import NVStorageCore

/// The scope of the next recovery step, preserving healthy local work independently of transport.
public enum CollectionRecoveryKind: Equatable, Sendable {
    case unlockOrInspectDatabase, privateState, requiredHistory, association, chooseCollection
    case automaticRepositoryRepair, preserveRepositoryCollision, providerUnavailable
}

/// A headless request consumed by the repository repair or application presentation layer.
public struct CollectionRecoveryRequest: Sendable {
    public let kind: CollectionRecoveryKind
    public let failure: StorageError?
    fileprivate init(_ kind: CollectionRecoveryKind, failure: StorageError? = nil) {
        self.kind = kind; self.failure = failure
    }
}

/// A startup choice binds one named unread object to one owner and selection attempt.
public struct WorkOfflineChoice: Sendable {
    public let object: SegmentLocator
    fileprivate let owner: UUID
    fileprivate let attempt: UUID
    fileprivate init(_ object: SegmentLocator, owner: UUID, attempt: UUID) {
        self.object = object; self.owner = owner; self.attempt = attempt
    }
}

/// Closed startup outcomes describe local admission separately from provider repair status.
public enum CollectionStartupDecision: Sendable {
    case ready, editable
    case waiting(WorkOfflineChoice)
    case recovery(CollectionRecoveryRequest)
    case contention
    case transition
    case closed
}

public enum CollectionOpenOutcome: Sendable {
    case opened(CollectionSession)
    case recovery(StorageHealthReport)

    /// Maps an actual failed opener into the same decision boundary used by live sessions.
    public var recoveryRequest: CollectionRecoveryRequest? {
        guard case .recovery(let health) = self else { return nil }
        switch classifyStartup(local: .failed(health), repository: .pending, published: false, unreadAbsentLocally: false) {
        case .association: return .init(.association, failure: health.failure)
        case .recovery(let kind): return .init(kind, failure: health.failure)
        case .ready, .editable, .wait, .contention: return .init(.privateState, failure: health.failure)
        }
    }
}

/// A reduction retains the integrated selection and the existing store's checked view.
public struct CollectionPreparedPublication: Sendable {
    fileprivate let owner: UUID
    fileprivate let attempt: UUID
    fileprivate let model: PreparedModelChange
    fileprivate init(owner: UUID, attempt: UUID, model: PreparedModelChange) {
        self.owner = owner; self.attempt = attempt; self.model = model
    }
}

/// Ordinary capture retains the integrated admission generation through persistence.
public struct CollectionCapturedAction: Sendable {
    fileprivate let owner: UUID
    fileprivate let attempt: UUID
    fileprivate let action: CapturedActionGroup
    fileprivate init(owner: UUID, attempt: UUID, action: CapturedActionGroup) {
        self.owner = owner; self.attempt = attempt; self.action = action
    }
}

/// Independent health axes feed a deterministic decision before any permission is issued.
enum StartupLocalHealth: Sendable { case ready, association, failed(StorageHealthReport) }
enum StartupRepositoryHealth: Equatable, Sendable {
    case pending, compatible, unavailable, contention, foreign, repair
}
enum StartupClassification: Equatable, Sendable {
    case ready, editable, wait, association, contention, recovery(CollectionRecoveryKind)
}
func classifyStartup(local: StartupLocalHealth, repository: StartupRepositoryHealth,
                     published: Bool, unreadAbsentLocally: Bool) -> StartupClassification {
    switch local {
    case .association: return .association
    case .failed(let health):
        switch health.category {
        case .unlockingOrDatabaseUnreadable: return .recovery(.unlockOrInspectDatabase)
        case .contextMismatch: return .association
        case .requiredStateIncomplete, .requiredStateInvalid:
            return .recovery(health.phase == .requiredHistory ? .requiredHistory : .privateState)
        case .entryUnavailable, .ownershipOrAccess, .unsupportedFormat: return .recovery(.privateState)
        }
    case .ready:
        if published { return .editable }
        if repository == .contention { return .contention }
        if unreadAbsentLocally { return .wait }
        return .ready
    }
}

/// Qualification gates bracket real startup and binding effects while production uses immediate turns.
struct CollectionStartupHooks: Sendable {
    var rootAcquired: (@Sendable (RepositoryRootSession) async -> Void)?
    var beforeBinding: (@Sendable () async throws -> Void)?
    var afterBinding: (@Sendable () async throws -> Void)?
    var beforePublication: (@Sendable () async throws -> Void)?
    var beforeNamedTransportAdoption: (@Sendable () async -> Void)?
    var transport = RepositoryTransportHooks()
    var measuring: StorageWork?
}

private enum StartupPhase: Sendable {
    case ready, editable, association, contention
    case waiting(DisclosedRepositoryObject)
    case publishing, transitioning, bindingPending(AssociationTransition), closed
}
private enum AcquiredStartupRoot: Sendable {
    case owned(RepositoryRootSession), failed(RepositoryRootError)
}

/// The sole unsettled association owns both resources until durable readback decides adoption.
private struct AssociationTransition: Sendable {
    let source: RepositoryRootSession?
    let transport: RepositoryTransportDriver?
    let target: RepositoryRootSession
    let before: LocalAssociationState
    let value: LocalAssociationV1
    let wasEditable: Bool
}
private enum StartupTransport: Sendable {
    case idle, attaching, attached(RepositoryTransportDriver)
    var driver: RepositoryTransportDriver? { if case .attached(let value) = self { value } else { nil } }
}

/// Joins checked local startup with physical association and independently scheduled provider work.
public actor CollectionSession {
    public var selection: LocalStoreSelection { store.selection }
    private let identity = UUID()
    private var attempt = UUID()
    private let store: LocalStoreSession
    private var root: RepositoryRootSession?
    private var acquisition: Task<Void, Never>?
    private var acquired: AcquiredStartupRoot?
    private var transport: StartupTransport = .idle
    private var phase: StartupPhase
    private var repositoryHealth: StartupRepositoryHealth = .pending
    private var repositoryRequest: CollectionRecoveryRequest?
    private var association: LocalAssociationState
    private var operations = 0
    private var deferredDisclosure: DisclosedRepositoryObject?
    private let hooks: CollectionStartupHooks

    private init(store: LocalStoreSession, association: LocalAssociationState, hooks: CollectionStartupHooks) {
        self.store = store; self.association = association; self.hooks = hooks
        phase = association.value == nil ? .association : .ready
    }

    /// Opens complete local history first; root acquisition proceeds without a provider launch barrier.
    public static func open(selection: LocalStoreSelection, protection: ObjectProtectionV1,
                            repository: URL? = nil) async -> CollectionOpenOutcome {
        await open(selection: selection, protection: protection, repository: repository, hooks: .init())
    }
    static func open(selection: LocalStoreSelection, protection: ObjectProtectionV1,
                     repository: URL?, hooks: CollectionStartupHooks) async -> CollectionOpenOutcome {
        let result = await LocalStoreSession.openDiagnosing(selection: selection, protection: protection, measuring: hooks.measuring)
        switch result {
        case .recoveryRequired(let health): return .recovery(health)
        case .opened(let store):
            do {
                let owner = try await CollectionSession(store: store, association: store.localAssociation(), hooks: hooks)
                if let repository { await owner.acquire(repository) }
                return .opened(owner)
            } catch {
                try? await store.quiesce()
                return await .recovery(.requiredStateFailure(selection: selection, failure: classify(error)))
            }
        }
    }

    private func acquire(_ url: URL) {
        let captured = attempt, hooks = hooks
        acquisition = Task { [weak self] in
            let result: AcquiredStartupRoot
            do {
                let root = try await RepositoryRootSession.open(directory: url)
                await hooks.rootAcquired?(root)
                result = .owned(root)
            } catch { result = .failed(error as? RepositoryRootError ?? .unavailable(EIO)) }
            guard let self else { if case .owned(let root) = result { await root.close() }; return }
            await self.receiveAcquisition(result, attempt: captured)
        }
    }
    private func receiveAcquisition(_ result: AcquiredStartupRoot, attempt captured: UUID) async {
        defer { acquisition = nil }
        guard captured == attempt else { if case .owned(let root) = result { await root.close() }; return }
        switch phase {
        case .closed: if case .owned(let root) = result { await root.close() }
        case .publishing, .transitioning, .bindingPending: acquired = result
        case .ready, .editable, .association, .contention, .waiting:
            acquired = result
            await consumeAcquisition()
        }
    }
    private func consumeAcquisition() async {
        guard let result = acquired else { return }
        acquired = nil
        operations += 1; defer { operations -= 1 }
        switch result {
        case .failed(let error):
            repositoryHealth = error == .contention ? .contention : .unavailable
            repositoryRequest = .init(.providerUnavailable)
            if error == .contention, case .ready = phase { phase = .contention }
        case .owned(let root):
            guard let value = association.value else { self.root = root; return }
            do {
                guard try await root.matches(value) == .same else {
                    repositoryHealth = .foreign; repositoryRequest = .init(.association)
                    self.root = nil; await root.close(); return
                }
                self.root = root
                try await inspectRepository(root)
                await attachIfApplicable()
            } catch {
                if self.root == nil { await root.close() }
                repositoryHealth = .unavailable; repositoryRequest = .init(.providerUnavailable)
            }
        }
    }

    /// Returns a truthful scoped decision; provider status remains separately inspectable while editing.
    public func decision() -> CollectionStartupDecision {
        switch phase {
        case .publishing, .transitioning, .bindingPending: return .transition
        case .closed: return .closed
        case .ready, .editable, .association, .contention, .waiting:
            let local: StartupLocalHealth = phase.needsAssociation ? .association : .ready
            switch classifyStartup(local: local, repository: repositoryHealth,
                published: phase.isEditable, unreadAbsentLocally: phase.disclosure != nil) {
            case .ready: return .ready
            case .editable: return .editable
            case .association: return .recovery(.init(.association))
            case .contention: return .contention
            case .recovery(let kind): return .recovery(.init(kind))
            case .wait:
                guard let evidence = phase.disclosure else { return .recovery(.init(.privateState)) }
                return .waiting(.init(evidence.locator, owner: identity, attempt: attempt))
            }
        }
    }
    public func pendingRepositoryRequest() -> CollectionRecoveryRequest? { repositoryRequest }
    public func transportStatus() async -> RepositoryTransportStatus? { await transport.driver?.status() }
    func settleAcquisition() async { if let acquisition { await acquisition.value } }
    /// Copied measurements let qualification observe startup's existing database work.
    func startupMeasurements() async throws -> StorageWork? { try await store.lane.perform { $0.work } }
    public func pendingProviderObject() -> SegmentLocator? {
        if case .waiting(let evidence) = phase { return evidence.locator }
        return deferredDisclosure?.locator
    }

    public func preparePublication(liveGeneration: UInt64) async throws -> CollectionPreparedPublication {
        try requirePublication()
        let captured = attempt
        try await checkLocalAdmission()
        let model = try await store.prepareReduction(liveGeneration: liveGeneration)
        guard captured == attempt else { throw StorageError.staleCapture }
        try requirePublication()
        return .init(owner: identity, attempt: captured, model: model)
    }
    /// Reserves association adoption through the synchronous checked host callback and its settlement.
    public func publish<T: Sendable>(_ prepared: CollectionPreparedPublication, liveGeneration: UInt64,
                                    apply: @escaping @Sendable (StoreSnapshot) throws -> T) async throws -> T {
        try requirePublication()
        guard prepared.owner == identity, prepared.attempt == attempt else { throw StorageError.wrongContext }
        let previous = phase
        phase = .publishing
        do {
            try await checkLocalAdmission()
            try await hooks.beforePublication?()
            let value = try await store.publish(prepared.model, liveGeneration: liveGeneration, apply: apply)
            phase = .editable
            await consumeAcquisition()
            await attachIfApplicable()
            return value
        } catch {
            phase = previous
            await consumeAcquisition()
            throw error
        }
    }

    public func capture(kind: OrdinaryActionKind, changes: [CapturedNoteChange]) async throws -> CollectionCapturedAction {
        try requireEditable()
        let captured = attempt
        let snapshot = try await store.snapshot()
        try requireEditable()
        guard attempt == captured else { throw StorageError.staleCapture }
        return try .init(owner: identity, attempt: captured, action: CapturedActionGroup(snapshot: snapshot, kind: kind, changes: changes))
    }
    public func persist(_ capture: CollectionCapturedAction) async throws -> CommitOutcome {
        try requireEditable()
        guard capture.owner == identity, capture.attempt == attempt else { throw StorageError.wrongContext }
        operations += 1; defer { operations -= 1 }
        return try await store.persist(capture: capture.action)
    }
    public func retry(_ handle: CommitHandle) async throws -> CommitOutcome {
        try requireEditable()
        operations += 1; defer { operations -= 1 }
        return try await store.retry(commit: handle)
    }

    /// Activates a complete fresh selection through the existing expected-current record boundary.
    public func activateFreshSelection(using owner: SelectedStoreOwner, basedOn state: SelectedStoreState) async throws -> StoreActivationOutcome {
        try requirePublication()
        operations += 1; defer { operations -= 1 }
        try await checkLocalAdmission()
        return try await store.verifiedFreshSelection().activate(using: owner, basedOn: state)
    }

    /// Checks one already disclosed canonical name without introducing a collection-wide discovery gate.
    public func considerProviderObject(_ locator: SegmentLocator) async throws {
        guard let root, association.value != nil, repositoryHealth == .compatible else { throw StorageError.wrongContext }
        try requireStable()
        let captured = attempt
        operations += 1; defer { operations -= 1 }
        let disclosed = try await root.disclosure(at: locator)
        guard attempt == captured else { throw StorageError.staleCapture }
        switch disclosed {
        case .readable(let bytes):
            let selection = store.selection, protection = store.protection
            let actual = try await store.lane.historyWork {
                try ObjectEnvelopeV1.open(bytes, collection: selection.descriptor.collection, protection: protection).locator
            }
            guard actual == locator else { throw StorageError.integrity }
            _ = try await store.receive(bytes)
            if case .waiting(let old) = phase, old.locator == locator { phase = .ready }
            if deferredDisclosure?.locator == locator { deferredDisclosure = nil }
        case .unread(let evidence):
            guard try await !hasLocalObject(locator) else { return }
            try await transport.driver?.refreshNamedInput(evidence)
            if case .ready = phase { phase = .waiting(evidence) }
            else { deferredDisclosure = evidence }
        case .unavailable: break
        }
    }

    /// Releases only this initial named wait, retaining the evidence for normal transport reconciliation.
    public func workOffline(_ choice: WorkOfflineChoice) async throws {
        guard choice.owner == identity, choice.attempt == attempt else { throw StorageError.wrongContext }
        guard case .waiting(let evidence) = phase, evidence.locator == choice.object, let root else { throw StorageError.staleCapture }
        operations += 1; defer { operations -= 1 }
        try await checkLocalAdmission()
        do {
            switch try await root.recheckDisclosure(evidence) {
            case .unread: break
            case .readable:
                phase = .ready
                try await considerProviderObject(evidence.locator)
                throw StorageError.staleCapture
            case .unavailable:
                deferredDisclosure = evidence; phase = .ready
                throw StorageError.staleCapture
            }
        } catch RepositoryRootError.busy {
            // The same live disclosure releases local editing while its provider accessor remains owned.
            try await root.validateDisclosureContext(evidence)
        }
        if try await hasLocalObject(evidence.locator) { phase = .ready; throw StorageError.staleCapture }
        guard choice.attempt == attempt, case .waiting(let current) = phase, current.locator == choice.object else { throw StorageError.staleCapture }
        deferredDisclosure = evidence
        phase = .ready
    }

    /// Starts one bounded named-input attempt on transport's existing worker and timer.
    public func requestWaitingBytes() async throws {
        guard case .waiting(let evidence) = phase, let root else { throw StorageError.staleCapture }
        operations += 1; defer { operations -= 1 }
        if let driver = transport.driver { await driver.revisit(.refresh); return }
        guard case .idle = transport else { throw StorageError.busy }
        let captured = attempt
        transport = .attaching
        do {
            let driver = try await RepositoryTransportDriver.start(root: root, store: store, hooks: hooks.transport,
                waiting: evidence, namedSettled: { [weak self] locator in await self?.namedInputSettled(locator, root: root) })
            await hooks.beforeNamedTransportAdoption?()
            guard captured == attempt, self.root === root else { await driver.stop(); throw StorageError.staleCapture }
            transport = .attached(driver)
            await attachIfApplicable()
        } catch { transport = .idle; throw error }
    }

    private func namedInputSettled(_ locator: SegmentLocator, root source: RepositoryRootSession) {
        guard root === source else { return }
        if case .waiting(let evidence) = phase, evidence.locator == locator { phase = .ready }
        if deferredDisclosure?.locator == locator { deferredDisclosure = nil }
    }

    /// Retry restores permissions only for the continuously held directory after positive comparison.
    public func retryRepository(at candidate: URL) async throws -> RepositoryRootContinuity {
        try reserveTransition()
        let previous = phaseBeforeTransition
        let previousAttempt = attempt
        defer { phaseBeforeTransition = nil }
        do {
            guard let root else { throw RepositoryRootError.fenced }
            let continuity = try await root.revalidate(candidate: candidate.path)
            attempt = UUID()
            phase = previous?.isEditable == true ? .editable : (association.value == nil ? .association : .ready)
            if continuity == .same {
                try await inspectRepository(root)
                if let evidence = previous?.disclosure {
                    if repositoryHealth == .compatible { try await considerProviderObject(evidence.locator) }
                    else { deferredDisclosure = evidence }
                }
                await transport.driver?.revisit(.refresh)
                await attachIfApplicable()
            } else {
                if let evidence = previous?.disclosure { deferredDisclosure = evidence }
                repositoryHealth = .unavailable; repositoryRequest = .init(.providerUnavailable)
            }
            return continuity
        } catch {
            let rootIsActive = await root?.state == .active
            if attempt != previousAttempt || !rootIsActive {
                if let evidence = previous?.disclosure { deferredDisclosure = evidence }
                phase = previous?.isEditable == true ? .editable : (association.value == nil ? .association : .ready)
                repositoryHealth = .unavailable; repositoryRequest = .init(.providerUnavailable)
            } else { phase = previous ?? .ready }
            throw error
        }
    }

    private var phaseBeforeTransition: StartupPhase?
    /// Explicitly binds this complete collection to a selected directory, preserving its private history.
    public func reopenRepository(at candidate: URL, descriptor: BootstrapDescriptorV1) async throws {
        guard descriptor.encodedBytes == store.selection.descriptor.encodedBytes else { throw StorageError.wrongContext }
        try reserveTransition()
        let previous = phaseBeforeTransition ?? .association
        let oldRoot = root, oldDriver = transport.driver
        var selected: RepositoryRootSession?
        var binding: AssociationTransition?
        var settledPhase: StartupPhase?
        do {
            if let oldRoot {
                do {
                    if try await oldRoot.revalidate(candidate: candidate.path) == .same { selected = oldRoot }
                } catch RepositoryRootError.busy {
                    // A separately owned target can prepare while the old accessor retains its original resource.
                }
            }
            if selected == nil { selected = try await RepositoryRootSession.open(directory: candidate) }
            guard let selected else { throw StorageError.incomplete }
            try await inspectRepository(selected)
            guard repositoryHealth == .compatible || repositoryHealth == .repair else { throw StorageError.wrongContext }
            if let oldRoot, oldRoot !== selected { await oldRoot.invalidate() }
            try Task.checkCancellation()
            try await checkLocalAdmission(requireAssociation: false)
            let current = try await store.localAssociation()
            let id = try current.value?.id ?? LocalAssociationID(bytes: uuidBytes())
            let value = try await selected.association(for: store.selection, id: id)
            let transition = AssociationTransition(source: oldRoot, transport: oldDriver, target: selected,
                before: current, value: value, wasEditable: previous.isEditable)
            try await hooks.beforeBinding?()
            try Task.checkCancellation()
            binding = transition
            do { try await store.saveLocalAssociation(value, basedOn: current) }
            catch {
                // SQL readback distinguishes a committed effect from a known unchanged binding.
                settledPhase = try await settleBinding(transition)
                binding = nil
                throw error
            }
            settledPhase = try await settleBinding(transition)
            binding = nil
            try await hooks.afterBinding?()
            try await inspectRepository(selected)
            phase = settledPhase ?? .association
            phaseBeforeTransition = nil
            await attachIfApplicable()
            await consumeAcquisition()
        } catch {
            if let binding {
                phase = .bindingPending(binding)
                repositoryRequest = .init(.association, failure: classify(error))
            } else if let settledPhase {
                phase = settledPhase
            } else if case .transitioning = phase {
                if let selected, selected !== oldRoot { await selected.close() }
                phase = previous
            }
            phaseBeforeTransition = nil
            throw error
        }
    }

    /// Reconciles the existing SQL binding after an ambiguous completion without repeating the write.
    public func resumeReassociation() async throws {
        guard case .bindingPending(let binding) = phase else { throw StorageError.staleCapture }
        phase = .transitioning
        do {
            let stable = try await settleBinding(binding)
            if root === binding.target { try await inspectRepository(binding.target) }
            phase = stable
            await attachIfApplicable()
        } catch { phase = .bindingPending(binding); throw error }
    }

    private func settleBinding(_ binding: AssociationTransition) async throws -> StartupPhase {
        let durable = try await store.localAssociation()
        if durable.value == binding.value, durable.generation == binding.before.generation + 1 {
            association = durable; attempt = UUID()
            await binding.transport?.stop(); transport = .idle
            if let source = binding.source, source !== binding.target { await source.close() }
            root = binding.target
            return binding.wasEditable ? .editable : .ready
        } else if durable.value == binding.before.value, durable.generation == binding.before.generation {
            if binding.target !== binding.source { await binding.target.close() }
            association = durable
            return binding.wasEditable ? .editable : (durable.value == nil ? .association : .ready)
        } else { throw StorageError.wrongContext }
    }

    /// Terminal teardown retains the reservation until every owned store/root effect has settled.
    public func close() async throws {
        try requireStable()
        guard operations == 0 else { throw StorageError.busy }
        let previous = phase
        phase = .transitioning
        do {
            acquisition?.cancel()
            if let acquisition { await acquisition.value }
            if case .owned(let unadopted) = acquired { await unadopted.close() }
            acquired = nil
            await transport.driver?.stop(); transport = .idle
            try await store.quiesce()
            await root?.close(); root = nil
            phase = .closed
        } catch { phase = previous; throw error }
    }

    private func reserveTransition() throws {
        try requireStable()
        guard operations == 0, acquisition == nil else { throw StorageError.busy }
        phaseBeforeTransition = phase; phase = .transitioning
    }
    private func requireStable() throws {
        switch phase {
        case .publishing, .transitioning, .bindingPending: throw StorageError.busy
        case .closed: throw StorageError.closed
        case .ready, .editable, .association, .contention, .waiting: break
        }
    }
    private func requirePublication() throws {
        switch decision() {
        case .ready, .editable: return
        case .transition: throw StorageError.busy
        case .closed: throw StorageError.closed
        case .recovery, .contention, .waiting: throw StorageError.incomplete
        }
    }
    private func requireEditable() throws {
        try requireStable()
        guard case .editable = phase else { throw StorageError.incomplete }
    }
    private func checkLocalAdmission(requireAssociation: Bool = true) async throws {
        let selection = store.selection
        try await store.lane.perform { db in
            try db.requireHealthyHistory()
            try db.validateRequiredPrivateGroups(store: selection.store, descriptor: selection.descriptor)
        }
        let current = try await store.localAssociation()
        if requireAssociation { guard current.value == association.value, current.generation == association.generation,
            current.value != nil else { throw StorageError.wrongContext } }
    }
    private func hasLocalObject(_ locator: SegmentLocator) async throws -> Bool {
        let selection = store.selection, protection = store.protection
        return try await store.lane.perform { db in
            try db.requireHealthyHistory()
            if try db.acceptedEnvelope(locator, collection: selection.descriptor.collection, protection: protection) != nil { return true }
            return try db.snapshotCandidate(locator, collection: selection.descriptor.collection, protection: protection) != nil
        }
    }
    private func inspectRepository(_ root: RepositoryRootSession) async throws {
        let permission = try await root.permission()
        switch try await root.inspect("NV Data", using: permission) {
        case .unavailable(.absent): repositoryHealth = .repair; repositoryRequest = .init(.automaticRepositoryRepair)
        case .unavailable: repositoryHealth = .unavailable; repositoryRequest = .init(.providerUnavailable)
        case .observed(let entry):
            guard entry.kind == .directory else {
                repositoryHealth = .foreign; repositoryRequest = .init(.preserveRepositoryCollision); return
            }
            let descriptor = store.selection.descriptor
            let path = ImmutableRepositoryLocator.descriptor(descriptor).relativePath
            switch try await root.inspect(path, using: permission) {
            case .unavailable(.absent): repositoryHealth = .repair; repositoryRequest = .init(.automaticRepositoryRepair)
            case .unavailable: repositoryHealth = .unavailable; repositoryRequest = .init(.providerUnavailable)
            case .observed(let observed):
                switch try await root.read(observed, maximumBytes: 16384, using: permission) {
                case .contents(let data) where data.bytes == descriptor.encodedBytes:
                    repositoryHealth = .compatible; repositoryRequest = nil
                case .contents: repositoryHealth = .foreign; repositoryRequest = .init(.preserveRepositoryCollision)
                case .unavailable: repositoryHealth = .unavailable; repositoryRequest = .init(.providerUnavailable)
                }
            }
        }
    }
    private func attachIfApplicable() async {
        guard case .editable = phase, repositoryHealth == .compatible, let root else { return }
        if let driver = transport.driver { await driver.allowPublication(); return }
        guard case .idle = transport else { return }
        let captured = attempt
        transport = .attaching; operations += 1
        defer { operations -= 1 }
        do {
            let driver = try await RepositoryTransportDriver.start(root: root, store: store, hooks: hooks.transport)
            guard attempt == captured, self.root === root else { await driver.stop(); transport = .idle; return }
            transport = .attached(driver)
        } catch { transport = .idle; repositoryRequest = .init(.providerUnavailable, failure: classify(error)) }
    }

    /// Adopts a complete normally reopened bootstrap while its independently acquired root stays owned.
    static func bindFresh(_ store: LocalStoreSession, root: RepositoryRootSession) async throws -> CollectionSession {
        let current = try await store.localAssociation()
        if let existing = current.value {
            guard try await root.matches(existing) == .same else { throw StorageError.wrongContext }
        } else {
            let value = try await root.association(for: store.selection, id: .init(bytes: uuidBytes()))
            do { try await store.saveLocalAssociation(value, basedOn: current) }
            catch {
                guard try await store.localAssociation().value == value else { throw error }
            }
        }
        let owner = try await CollectionSession(store: store, association: store.localAssociation(), hooks: .init())
        await owner.adopt(root)
        return owner
    }
    private func adopt(_ root: RepositoryRootSession) async {
        self.root = root
        do { try await inspectRepository(root) }
        catch { repositoryHealth = .unavailable; repositoryRequest = .init(.providerUnavailable) }
    }
}

private extension StartupPhase {
    var isEditable: Bool { if case .editable = self { true } else { false } }
    var needsAssociation: Bool { if case .association = self { true } else { false } }
    var disclosure: DisclosedRepositoryObject? { if case .waiting(let value) = self { value } else { nil } }
}
