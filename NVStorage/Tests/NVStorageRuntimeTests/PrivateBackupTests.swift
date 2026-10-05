import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

@Test(arguments: [false, true])
func fixedPrivateBackupIncludesWALAndPendingCut(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let settings = try CollectionSettingsV1([.secureTextEntry(true), .confirmFileDeletion(false)])
    try await source.saveCollectionSettings(settings, basedOn: source.collectionSettings())
    let item = try PendingItemID(bytes: uuidBytes()), a = try await pendingInput(source, body: "pending A")
    try await source.retainPendingSnapshot(a, basedOn: source.pendingItem(item))
    _ = try await source.preparePendingImport(basedOn: source.pendingItem(item), automatic: false)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    _ = try await put("captured", birth: birth, generation: 1, session: source)
    let gate = ImprovementGate()
    try await source.lane.perform { $0.work = StorageWork(backupCaptured: { await gate.hold() }) }
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let backup = Task { try await source.backupPrivateStore(to: path, budget: PrivateBackupBudget(pagesPerTurn: 1)) }
    await gate.wait()
    let b = try await pendingInput(source, body: "new pending B")
    try await source.retainPendingSnapshot(b, basedOn: source.pendingItem(item))
    try await source.saveCollectionSettings(try CollectionSettingsV1([.secureTextEntry(false)]), basedOn: source.collectionSettings())
    _ = try await put("newer", birth: birth, generation: 2, session: source)
    #expect(try await source.snapshot().notes.contains { $0.value.body.string == "newer" })
    await gate.release()
    let result = try await backup.value
    #expect(result.through == 2)
    let destination = try await LocalStoreSession.open(selection: result.selection, protection: protection)
    #expect(try await destination.snapshot().notes.map(\.value.body.string).sorted() == ["captured", "untouched"])
    #expect(try await destination.collectionSettings().value == settings)
    #expect(try await destination.pendingItem(item).latest == a.id)
    #expect(try await destination.retainedPendingSnapshot(a.id) == a)
    guard case .review = try #require(await destination.pendingRecovery(item).first) else { Issue.record("reservation replayed as admission"); return }
    let rows = try await destination.lane.perform { try $0.rows("SELECT object_id FROM accepted_objects ORDER BY object_id") }
    #expect(rows.count == initial.objects.count + 2)
    try await destination.quiesce(); try await source.quiesce()
    if encrypted {
        let unlock = URL(fileURLWithPath: path).appendingPathComponent("unlock")
        let files = try FileManager.default.contentsOfDirectory(at: unlock, includingPropertiesForKeys: nil)
        let wrapper = try #require(files.first { $0.pathExtension == "nvkey" })
        let descriptor = try BootstrapDescriptorV1.decodeV1(Array(Data(contentsOf: wrapper)))
        let key = try descriptor.unwrap(passphrase: "synthetic")
        let normal = try ObjectProtectionV1.encrypted(keyID: #require(descriptor.keyID), key: key)
        let recovered = try await LocalStoreSession.open(selection: .init(directory: path, store: result.selection.store, descriptor: descriptor), protection: normal)
        #expect(try await recovered.snapshot().notes.map(\.value.body.string).sorted() == ["captured", "untouched"])
        try await recovered.quiesce()
    }
}

@Test(arguments: [false, true])
func backupBudgetReleasesReaderAndKeepsSourceWritable(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    await #expect(throws: StorageError.limit) {
        try await source.backupPrivateStore(to: path, budget: PrivateBackupBudget(pagesPerTurn: 1, maximumTurns: 1))
    }
    _ = try await put("after failed backup", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: source)
    let retryPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let result = try await source.backupPrivateStore(to: retryPath)
    #expect(result.through == 2)
    let destination = try await LocalStoreSession.open(selection: result.selection, protection: protection)
    #expect(try await destination.snapshot().notes.contains { $0.value.body.string == "after failed backup" })
    try await destination.quiesce(); try await source.quiesce()
}

@Test(arguments: [false, true])
func backupCancellationSettlesReaderAndReservation(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let gate = ImprovementGate()
    try await source.lane.perform { $0.work = StorageWork(backupCaptured: { await gate.hold() }) }
    let backup = Task { try await source.backupPrivateStore(to: privateTempPath()) }
    await gate.wait()
    await #expect(throws: StorageError.busy) { try await source.backupPrivateStore(to: privateTempPath()) }
    backup.cancel(); await gate.release()
    await #expect(throws: CancellationError.self) { try await backup.value }
    try await source.lane.perform { $0.work = nil }
    _ = try await put("saved after cancellation", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: source)
    let copied = try await source.backupPrivateStore(to: privateTempPath())
    let reopened = try await LocalStoreSession.open(selection: copied.selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["saved after cancellation", "untouched"])
    try await reopened.quiesce(); try await source.quiesce()
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func backupReopensCapturedReadyHistoryWithoutMixingLaterWrites(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let source = try await newSession(initial, protection), peer = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let edit = try await put("retained ready edit", birth: birth, generation: 1, session: peer)
    let bytes = try await peer.retainedObject(at: edit.object), gate = ImprovementGate()
    try await source.lane.perform { $0.work = StorageWork(receiveRetentionCompletion: { _ in await gate.hold() }) }
    let receiving = Task { try await source.receive(bytes) }
    await gate.wait()
    let copy: CompletePrivateBackup
    do { copy = try await source.backupPrivateStore(to: privateTempPath()) }
    catch {
        await gate.release(); _ = try? await receiving.value
        try? await source.quiesce(); try? await peer.quiesce(); throw error
    }
    #expect(copy.through == 1)
    #expect(try await source.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let reopened = try await LocalStoreSession.open(selection: copy.selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["retained ready edit", "untouched"])
    #expect(try await reopened.retainedObject(at: edit.object) == bytes)
    _ = try await put("later source edit", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 1, session: source)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["retained ready edit", "untouched"])
    await gate.release(); _ = try await receiving.value
    try await reopened.quiesce(); try await source.quiesce(); try await peer.quiesce()
}

@Test(arguments: [false, true])
func backupRebuildsDerivedRowsAfterCapturedDelete(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), source = try await newSession(initial, protection)
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    let capture = try await CapturedActionGroup(snapshot: source.snapshot(), kind: .deleteBatch,
        changes: [.delete(.init(birth: birth, generation: 1))])
    try await source.lane.perform { try $0.exec("CREATE TEMP TRIGGER refuse_backup_delete BEFORE DELETE ON current_notes BEGIN SELECT RAISE(ABORT,'held Delete materialization'); END") }
    _ = try requireReceipt(await source.persist(capture: capture))
    #expect(try await source.lane.perform { try $0.rows("SELECT through_seq FROM view_meta") } == [[.integer(1)]])
    #expect(try await source.lane.perform { try $0.acceptedThrough() } == 2)
    let copied: CompletePrivateBackup
    do { copied = try await source.backupPrivateStore(to: privateTempPath()) }
    catch {
        try await source.lane.perform { try $0.exec("DROP TRIGGER refuse_backup_delete") }
        try await source.lane.catchUp(selection: source.selection, protection: protection)
        try await source.quiesce(); throw error
    }
    #expect(copied.through == 2)
    let reopened = try await LocalStoreSession.open(selection: copied.selection, protection: protection)
    #expect(try await reopened.snapshot().notes.map(\.value.body.string) == ["untouched"])
    #expect(try await reopened.history(for: .recentlyDeleted).entries.map(\.birth) == [birth])
    try await source.lane.perform { try $0.exec("DROP TRIGGER refuse_backup_delete") }
    try await source.lane.catchUp(selection: source.selection, protection: protection)
    try await reopened.quiesce(); try await source.quiesce()
}
