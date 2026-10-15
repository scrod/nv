import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private func pendingInput(_ session: LocalStoreSession, body: String) async throws -> PendingSnapshotV1 {
    let selection = await session.selection
    return try .init(id: PendingSnapshotID(bytes: uuidBytes()),
        scope: .init(collection: selection.descriptor.collection, store: selection.store, descriptor: selection.descriptor.descriptorID),
        presence: .present, path: ExactUTF8(bytes: Array("external.txt".utf8)),
        observation: .init(codec: 1, bytes: [42]), source: Array(body.utf8), value: testValue(body))
}

private struct CopySwitchFixture {
    let owner: CollectionSession
    let store: LocalStoreSession
    let selector: SelectedStoreOwner
    let selected: SelectedStoreState
    let selectionDirectory: String
    let source: String
    let original: Data
    let protection: ObjectProtectionV1
    static func make(_ encrypted: Bool, hooks: CollectionStartupHooks = .init()) async throws -> Self {
        let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
        let source = try repositoryDirectory(), original = Data("preserved damaged source".utf8)
        try original.write(to: URL(fileURLWithPath: source + "/NV Data"))
        let root = try await RepositoryRootSession.open(directory: source)
        let owner = try await CollectionSession.bindFresh(store, root: root, hooks: hooks)
        #expect(try await collectionBodies(owner) == ["A", "untouched"])
        let directory = try repositoryDirectory(), first = try await SelectedStoreOwner.open(directory: directory)
        guard case .activated = try await owner.activateFreshSelection(using: first, basedOn: first.capture()) else {
            throw StorageError.incomplete
        }
        let selector = try await SelectedStoreOwner.open(directory: directory)
        return try await .init(owner: owner, store: store, selector: selector, selected: selector.capture(),
                              selectionDirectory: directory, source: source, original: original, protection: protection)
    }
    func selectedRecord() throws -> SelectedStoreRecordV1 {
        try .decodeV1(Array(Data(contentsOf: URL(fileURLWithPath: selectionDirectory + "/Selected Store"))))
    }
    func checkSource() throws {
        #expect(try Data(contentsOf: URL(fileURLWithPath: source + "/NV Data")) == original)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func collectionCopySwitchPreservesHistoryAndPrivateInputs(encrypted: Bool) async throws {
    let fixture = try await CopySwitchFixture.make(encrypted)
    let settings = try CollectionSettingsV1([.secureTextEntry(true)])
    try await fixture.store.saveCollectionSettings(settings, basedOn: fixture.store.collectionSettings())
    let item = try PendingItemID(bytes: uuidBytes()), frozen = try await pendingInput(fixture.store, body: "frozen selection")
    try await fixture.store.retainPendingSnapshot(frozen, basedOn: fixture.store.pendingItem(item))
    let reservation = try await fixture.store.preparePendingImport(basedOn: fixture.store.pendingItem(item), automatic: false)
    let latest = try await pendingInput(fixture.store, body: "latest contents")
    try await fixture.store.retainPendingSnapshot(latest, basedOn: fixture.store.pendingItem(item))
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let oldCapture = try await fixture.owner.capture(kind: .savedEdit, changes: [.put(.init(birth: birth, generation: 9), testValue("old callback"))])
    let inventory = try await fixture.store.lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") }
    let destination = privateTempPath()
    let result = try await fixture.owner.switchRepositoryAndSavedWork(to: destination, privateDirectory: privateTempPath(),
        using: fixture.selector, basedOn: fixture.selected)
    guard case .opened(let successor, let selected) = result.outcome else { Issue.record("complete copy did not activate"); return }
    #expect(result.copy.repository.unmetRequirements.isEmpty && result.copy.repository.issues.map(\.path) == ["NV Data"])
    #expect(result.copy.excludedPrivatePendingItems == 1)
    #expect(try fixture.selectedRecord() == selected.record)
    let oldSelection = await fixture.store.selection, selection = await successor.selection
    #expect(selection.store != oldSelection.store && selection.descriptor.encodedBytes == oldSelection.descriptor.encodedBytes)
    #expect(try await collectionBodies(successor) == ["A", "untouched"])
    await #expect(throws: StorageError.closed) { try await fixture.owner.persist(oldCapture) }
    await #expect(throws: StorageError.wrongContext) { try await successor.persist(oldCapture) }
    try fixture.checkSource()
    try await successor.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: fixture.protection)
    #expect(try await reopened.lane.perform { try $0.rows("SELECT object_id,encoded FROM objects ORDER BY object_id") } == inventory)
    #expect(try await reopened.collectionSettings().value == settings)
    #expect(try await reopened.pendingItem(item).latest == latest.id)
    #expect(try await reopened.retainedPendingSnapshot(frozen.id) == frozen)
    guard case .review(let id) = try #require(await reopened.pendingRecovery(item).first) else { throw StorageError.incomplete }
    #expect(id == reservation.reservation)
    let root = try await RepositoryRootSession.open(directory: destination)
    let association = try #require(await reopened.localAssociation().value)
    #expect(try await root.matches(association) == .same)
    await root.close()
    let newEdit = try await put("new owner", birth: birth, generation: 1, session: reopened)
    let old = try await LocalStoreSession.open(selection: oldSelection, protection: fixture.protection)
    let oldEdit = try await put("old independent store", birth: birth, generation: 1, session: old)
    #expect(newEdit.object.writerEpoch != oldEdit.object.writerEpoch)
    try await old.quiesce(); try await reopened.quiesce()
}

enum CopySwitchInterference: CaseIterable, Sendable { case none, edit, settings, pending, rollback }

private actor CopyInventoryEvents {
    private(set) var checked = 0
    private(set) var deferred = 0
    private var heldIdle = false
    var opportunities: Int { checked + deferred }
    func record(_ event: RepositoryTransportObservation) -> Bool {
        switch event {
        case .inventory(let result):
            #expect(result.failures.isEmpty)
            if result.checkedCount > 0 { checked += 1 }
        case .inventoryDeferred: deferred += 1
        case .idle where checked > 0 && !heldIdle:
            heldIdle = true; return true
        default: break
        }
        return false
    }
}

private func waitCopyInventory(_ condition: @Sendable () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while try await !condition() {
        try #require(ContinuousClock.now < deadline, "The owned inventory opportunity must settle")
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], ["quiet", "edit", "cancel"])
func collectionCopySwitchDefersOptionalInventory(encrypted: Bool, interference: String) async throws {
    let (initial, protection) = try testInitial(encrypted), store = try await newSession(initial, protection)
    let path = try repositoryDirectory(), root = try await RepositoryRootSession.open(directory: path)
    _ = try await publishRepository(store, to: root)
    let gate = ImprovementGate(), warm = ImprovementGate(), events = CopyInventoryEvents()
    defer { Task { await gate.release(); await warm.release() } }
    let owner = try await CollectionSession.bindFresh(store, root: root,
        hooks: .init(copySwitchPrepared: { await gate.hold() }, transport: .init(
            observation: { if await events.record($0) { await warm.hold() } }, idleNanoseconds: 20_000_000)))
    let selectionDirectory = try repositoryDirectory(), first = try await SelectedStoreOwner.open(directory: selectionDirectory)
    guard case .activated = try await owner.activateFreshSelection(using: first, basedOn: first.capture()) else { throw StorageError.incomplete }
    let selector = try await SelectedStoreOwner.open(directory: selectionDirectory), selected = try await selector.capture()
    #expect(try await collectionBodies(owner) == ["A", "untouched"])
    await warm.wait()
    let destination = privateTempPath()
    let switching = Task { try await owner.switchRepositoryAndSavedWork(to: destination, privateDirectory: privateTempPath(),
        using: selector, basedOn: selected) }
    await gate.wait()
    let before = await events.opportunities
    let writes = try await store.lane.perform { try $0.rows("SELECT total_changes()") }
    await warm.release()
    try await waitCopyInventory { await events.opportunities > before }
    #expect(try await store.lane.perform { try $0.rows("SELECT total_changes()") } == writes,
            "Optional inventory preserves a quiet copy's exact source cut")
    #expect(await events.deferred > 0)
    if interference == "edit" {
        let birth = try NoteBirth(bytes: .init(repeating: 1, count: 16))
        let capture = try await owner.capture(kind: .savedEdit,
            changes: [.put(.init(birth: birth, generation: 1), testValue("saved while copying"))])
        _ = try requireReceipt(await owner.persist(capture))
    } else if interference == "cancel" { switching.cancel() }
    let checks = await events.checked
    await gate.release()
    let result = try await switching.value
    if interference != "quiet" {
        guard case .sourceRetained(let cause) = result.outcome else {
            Issue.record("Interrupted preparation must retain its source: \(result.outcome)"); return
        }
        #expect(cause == (interference == "edit" ? .staleCapture : .cancelled))
        #expect(try SelectedStoreRecordV1.decodeV1(Array(Data(contentsOf:
            URL(fileURLWithPath: selectionDirectory + "/Selected Store")))) == selected.record)
        try await waitCopyInventory { await events.checked > checks }
        let expected = interference == "edit" ? ["saved while copying", "untouched"] : ["A", "untouched"]
        #expect(try await collectionBodies(owner) == expected)
        let selection = await store.selection
        try await owner.close(); try await selector.close()
        let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == expected)
        try await reopened.quiesce()
        return
    }
    guard case .opened(let successor, _) = result.outcome else {
        Issue.record("A quiet source must progress despite periodic inventory: \(result.outcome)")
        try await owner.close(); try await selector.close(); return
    }
    #expect(try await collectionBodies(successor) == ["A", "untouched"])
    for (locator, bytes) in initial.objects {
        let relative = ImmutableRepositoryLocator.segment(locator).relativePath
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination + "/" + relative)) == Data(bytes))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path + "/" + relative)) == Data(bytes))
    }
    try await successor.close()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func collectionCopySwitchKeepsCompetingPreparationScoped(encrypted: Bool, holdReceive: Bool) async throws {
    let gate = ImprovementGate()
    let fixture = try await CopySwitchFixture.make(encrypted, hooks: .init(copySwitchPrepared: { await gate.hold() }))
    let first = Task { try await fixture.owner.switchRepositoryAndSavedWork(to: privateTempPath(), privateDirectory: privateTempPath(),
        using: fixture.selector, basedOn: fixture.selected) }
    await gate.wait()
    defer { Task { await gate.release() } }
    let second = try await fixture.owner.switchRepositoryAndSavedWork(to: privateTempPath(), privateDirectory: privateTempPath(),
        using: fixture.selector, basedOn: fixture.selected)
    let retained = if case .sourceRetained(.busy) = second.outcome { true } else { false }
    #expect(retained, "The earlier preparation retains its admission reservation")
    guard retained else { return }
    #expect(try fixture.selectedRecord() == fixture.selected.record)
    await #expect(throws: StorageError.busy) { try await fixture.owner.retryRepository(at: URL(fileURLWithPath: fixture.source)) }
    let receive = ImprovementGate()
    defer { Task { await receive.release() } }
    if holdReceive {
        try await waitCopyInventory { await fixture.store.transportReady() }
        try await fixture.store.lane.perform { $0.work = StorageWork(publishedReceiveStart: { await receive.hold() }) }
    }
    #expect(try await collectionBodies(fixture.owner) == ["A", "untouched"])
    // Publication starts the ordinary receive owner; control its settlement before source retirement.
    if holdReceive { await receive.wait() }
    else { try await waitCopyInventory { await fixture.store.transportReady() } }
    await gate.release()
    var result = try await first.value
    if holdReceive {
        guard case .sourceRetained(.busy) = result.outcome else {
            Issue.record("Entered receive work must retain the source: \(result.outcome)"); return
        }
        #expect(try fixture.selectedRecord() == fixture.selected.record)
        try fixture.checkSource()
        await receive.release()
        try await waitCopyInventory { await fixture.store.transportReady() }
        result = try await fixture.owner.switchRepositoryAndSavedWork(to: privateTempPath(), privateDirectory: privateTempPath(),
            using: fixture.selector, basedOn: fixture.selected)
    }
    guard case .opened(let successor, _) = result.outcome else {
        Issue.record("The retained preparation must finish: \(result.outcome)")
        try await fixture.owner.close(); try await fixture.selector.close(); return
    }
    #expect(try await collectionBodies(successor) == ["A", "untouched"])
    try await successor.close(); try fixture.checkSource()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], CopySwitchInterference.allCases)
func collectionCopySwitchRefusesNewSourceWork(encrypted: Bool, interference: CopySwitchInterference) async throws {
    let gate = ImprovementGate()
    let fixture = try await CopySwitchFixture.make(encrypted, hooks: .init(copySwitchPrepared: { await gate.hold() }))
    let destination = privateTempPath(), candidate = privateTempPath()
    let switching = Task { try await fixture.owner.switchRepositoryAndSavedWork(to: destination, privateDirectory: candidate,
        using: fixture.selector, basedOn: fixture.selected) }
    await gate.wait()
    defer { Task { await gate.release() } }
    await #expect(throws: StorageError.busy) { try await fixture.owner.close() }
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let pendingCapture = try await fixture.owner.capture(kind: .savedEdit, changes: [.put(.init(birth: birth, generation: 2), testValue("after refusal"))])
    switch interference {
    case .none: _ = try await fixture.store.collectionSettings()
    case .edit:
        let deletion = try await fixture.owner.capture(kind: .deleteBatch, changes: [.delete(.init(birth: birth, generation: 1))])
        _ = try requireReceipt(await fixture.owner.persist(deletion))
    case .settings:
        try await fixture.store.saveCollectionSettings(try .init([.secureTextEntry(true)]), basedOn: fixture.store.collectionSettings())
    case .pending:
        let item = try PendingItemID(bytes: uuidBytes()), latest = try await pendingInput(fixture.store, body: "later pending")
        try await fixture.store.retainPendingSnapshot(latest, basedOn: fixture.store.pendingItem(item))
    case .rollback:
        await #expect(throws: StorageError.incomplete) {
            try await fixture.store.lane.perform { db in
                try db.transaction {
                    try db.run("INSERT INTO private_groups VALUES(?,1,1,?)", [.blob(Array("rollback-switch".utf8)), .blob([])])
                    throw StorageError.incomplete
                }
            }
        }
    }
    await gate.release()
    let result = try await switching.value
    if interference == .none {
        guard case .opened(let successor, _) = result.outcome else { Issue.record("unchanged source failed to progress"); return }
        #expect(try await collectionBodies(successor) == ["A", "untouched"])
        try await successor.close()
    } else {
        let retained = if case .sourceRetained = result.outcome { true } else { false }
        #expect(retained, "New source work remains selected")
        guard case .sourceRetained(let cause) = result.outcome else { return }
        #expect(cause == .staleCapture)
        #expect(try fixture.selectedRecord() == fixture.selected.record)
        #expect(try await collectionBodies(fixture.owner) == (interference == .edit ? ["untouched"] : ["A", "untouched"]))
        if interference != .edit { _ = try requireReceipt(await fixture.owner.persist(pendingCapture)) }
        let retried = try await fixture.owner.switchRepositoryAndSavedWork(to: privateTempPath(), privateDirectory: privateTempPath(),
            using: fixture.selector, basedOn: fixture.selected)
        guard case .opened(let successor, _) = retried.outcome else { Issue.record("quiet retry did not progress"); return }
        #expect(try await collectionBodies(successor) == (interference == .edit ? ["untouched"] : ["after refusal", "untouched"]))
        try await successor.close()
    }
    try fixture.checkSource()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], [SelectionCut.beforeInstall, .afterInstall, .beforeDurability, .afterDurability])
func collectionCopySwitchSettlesSelectionFailures(encrypted: Bool, cut: SelectionCut) async throws {
    let fixture = try await CopySwitchFixture.make(encrypted), destination = privateTempPath()
    await fixture.selector.setFault { if $0 == cut { throw StorageError.database(10) } }
    let result = try await fixture.owner.switchRepositoryAndSavedWork(to: destination, privateDirectory: privateTempPath(),
        using: fixture.selector, basedOn: fixture.selected)
    if cut == .beforeInstall {
        guard case .sourceRetained = result.outcome else { Issue.record("known unchanged selection lost the source"); return }
        #expect(try fixture.selectedRecord() == fixture.selected.record)
        #expect(try await collectionBodies(fixture.owner) == ["A", "untouched"])
        try await fixture.owner.close()
    } else {
        guard case .activationPending = result.outcome else { Issue.record("ambiguous selection was acknowledged"); return }
        await #expect(throws: (any Error).self) { try await LocalStoreSession.open(selection: fixture.store.selection, protection: fixture.protection) }
        await #expect(throws: (any Error).self) { try await RepositoryRootSession.open(directory: fixture.source) }
        await #expect(throws: (any Error).self) { try await RepositoryRootSession.open(directory: destination) }
        await #expect(throws: StorageError.busy) { try await fixture.owner.preparePublication(liveGeneration: 0) }
        await fixture.selector.setFault { if $0 == .beforeDurability { throw StorageError.database(10) } }
        guard case .activationPending = try await fixture.owner.resumeCopySwitch().outcome else { Issue.record("repeat failure lost pending attempt"); return }
        await fixture.selector.setFault(nil)
        let resumed = try await fixture.owner.resumeCopySwitch()
        guard case .opened(let successor, let selected) = resumed.outcome else { Issue.record("settled selection failed to progress"); return }
        #expect(try fixture.selectedRecord() == selected.record)
        #expect(try await collectionBodies(successor) == ["A", "untouched"])
        try await successor.close()
    }
    try fixture.checkSource()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func collectionCopySwitchRechecksDestinationAndSelectionOwner(encrypted: Bool) async throws {
    let destination = privateTempPath()
    let fixture = try await CopySwitchFixture.make(encrypted, hooks: .init(repositoryCopyCaptured: { path in
        if path == "NV Data" {
            let names = FileManager.default.enumerator(atPath: destination)?.allObjects as? [String] ?? []
            if let leaf = names.sorted().first(where: { $0.hasSuffix(".nvseg") }) {
                try? Data("changed after copy".utf8).write(to: URL(fileURLWithPath: destination + "/" + leaf))
            }
        }
    }))
    let copied = try await fixture.owner.switchRepositoryAndSavedWork(to: destination, privateDirectory: privateTempPath(),
        using: fixture.selector, basedOn: fixture.selected)
    let retained = if case .sourceRetained = copied.outcome { true } else { false }
    #expect(retained, "Changed destination cannot authorize selection")
    guard case .sourceRetained = copied.outcome else { return }
    #expect(try fixture.selectedRecord() == fixture.selected.record)
    #expect(try await collectionBodies(fixture.owner) == ["A", "untouched"])
    let otherDirectory = try repositoryDirectory(), other = try await SelectedStoreOwner.open(directory: otherDirectory)
    let wrongOwner = try await fixture.owner.switchRepositoryAndSavedWork(to: privateTempPath(), privateDirectory: privateTempPath(),
        using: other, basedOn: fixture.selected)
    guard case .sourceRetained(let cause) = wrongOwner.outcome else { Issue.record("wrong selection owner changed selection"); return }
    #expect(cause == .wrongContext)
    #expect(try fixture.selectedRecord() == fixture.selected.record)
    #expect(try await collectionBodies(fixture.owner) == ["A", "untouched"])
    try await fixture.owner.close(); try await fixture.selector.close(); try await other.close()
    try fixture.checkSource()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func collectionCopySwitchClosePreservesRestartInputs(encrypted: Bool) async throws {
    let fixture = try await CopySwitchFixture.make(encrypted), destination = privateTempPath(), candidate = privateTempPath()
    await fixture.selector.setFault { if $0 == .beforeDurability { throw StorageError.database(10) } }
    let copied = try await fixture.owner.switchRepositoryAndSavedWork(to: destination, privateDirectory: candidate,
        using: fixture.selector, basedOn: fixture.selected)
    guard case .activationPending = copied.outcome else { Issue.record("selection fault lost retained attempt"); return }
    try await fixture.owner.close()
    let actual = try fixture.selectedRecord(), old = await fixture.store.selection
    #expect(actual.store != old.store)
    let selected = LocalStoreSelection(directory: candidate, store: actual.store, descriptor: old.descriptor)
    let reopened = try openedCollection(await CollectionSession.open(selection: selected, protection: fixture.protection,
        repository: URL(fileURLWithPath: destination)))
    await reopened.settleAcquisition()
    #expect(try await collectionBodies(reopened) == ["A", "untouched"])
    try await reopened.close()
    let original = try await LocalStoreSession.open(selection: old, protection: fixture.protection)
    #expect(try await original.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await original.quiesce(); try fixture.checkSource()
}
