import Foundation
import Crypto
import Testing
import NVStorageCore
@testable import NVStorageRuntime

enum PrivateHealthCase: CaseIterable { case absentDirectory, absentDatabase, folder, symlink, permission, wrongKey, wrongContext, settingsVersion, settingsBytes, derivedRows, history, pending }

@Test(arguments: [false, true], PrivateHealthCase.allCases)
func privateHealthUsesActualOpeningBoundary(encrypted: Bool, fault: PrivateHealthCase) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let original = await session.selection
    var selection = original, key = protection
    let path = original.directory + "/Collection.sqlite", fs = FileManager.default
    var pending: PendingItemID?
    switch fault {
    case .settingsVersion: try await session.lane.perform { try $0.run("UPDATE private_groups SET codec=99 WHERE group_key=?", [.blob(Array("settings".utf8))]) }
    case .settingsBytes: try await session.lane.perform { try $0.run("UPDATE private_groups SET codec=2,payload=? WHERE group_key=?", [.blob([0]), .blob(Array("settings".utf8))]) }
    case .derivedRows: try await session.lane.perform { try $0.run("UPDATE current_notes SET cell=?", [.blob([0])]) }
    case .history:
        try await session.lane.perform { db in
            try db.exec("DROP TRIGGER objects_no_update")
            try db.run("UPDATE objects SET encoded=? WHERE kind=2", [.blob([0])])
        }
    case .pending:
        let item = try PendingItemID(bytes: uuidBytes()), input = try await pendingInput(session, body: "isolated")
        try await session.retainPendingSnapshot(input, basedOn: session.pendingItem(item))
        _ = try await session.preparePendingImport(basedOn: session.pendingItem(item), automatic: false)
        try await session.lane.perform { try $0.run("UPDATE pending_reservations SET codec=99 WHERE item_id=?", [.blob(item.bytes)]) }
        pending = item
    default: break
    }
    try await session.quiesce()
    switch fault {
    case .absentDirectory: selection = .init(directory: privateTempPath(), store: original.store, descriptor: original.descriptor)
    case .absentDatabase: try fs.moveItem(atPath: path, toPath: path + ".preserved")
    case .folder:
        try fs.moveItem(atPath: path, toPath: path + ".preserved")
        try fs.createDirectory(atPath: path, withIntermediateDirectories: false)
    case .symlink:
        try fs.moveItem(atPath: path, toPath: path + ".preserved")
        try fs.createSymbolicLink(atPath: path, withDestinationPath: path + ".preserved")
    case .permission: try fs.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path)
    case .wrongKey:
        key = .encrypted(keyID: try initial.descriptor.keyID ?? CollectionKeyID(bytes: Array(repeating: 7, count: 16)),
            key: SymmetricKey(data: Array(repeating: 19, count: 32)))
    case .wrongContext: selection = try .init(directory: original.directory, store: LocalStoreID(bytes: uuidBytes()), descriptor: original.descriptor)
    default: break
    }
    defer { if fault == .permission { try? fs.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) } }
    let outcome = await LocalStoreSession.openDiagnosing(selection: selection, protection: key)
    switch fault {
    case .derivedRows, .pending:
        guard case .opened(let opened) = outcome else { Issue.record("repairable/isolated failure blocked the whole collection"); return }
        #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
        if let pending {
            guard case .blocked(_, .unsupported) = try #require(await opened.pendingRecovery(pending).first) else { Issue.record("pending corruption lost its scope"); return }
            _ = try await put("unrelated save", birth: NoteBirth(bytes: Array(repeating: 2, count: 16)), generation: 1, session: opened)
        }
        try await opened.quiesce()
    default:
        guard case .recoveryRequired(let report) = outcome else { Issue.record("required failure produced an editable store"); return }
        switch fault {
        case .absentDirectory:
            #expect(report.directory.kind == .absent && report.database == nil && report.category == .entryUnavailable)
            #expect(!fs.fileExists(atPath: selection.directory))
        case .absentDatabase: #expect(report.database?.kind == .absent && !fs.fileExists(atPath: path))
        case .folder: #expect(report.database?.kind == .directory && report.category == .entryUnavailable)
        case .symlink: #expect(report.database?.kind == .symlink && report.category == .entryUnavailable)
        case .permission: #expect(report.category == .ownershipOrAccess && report.phase == .namespaceAndUnlock)
        case .wrongKey: #expect(report.category == .unlockingOrDatabaseUnreadable)
        case .wrongContext: #expect(report.category == .contextMismatch && report.phase == .headerAndPrivateGroups)
        case .settingsVersion: #expect(report.category == .unsupportedFormat && report.phase == .headerAndPrivateGroups)
        case .settingsBytes: #expect(report.category == .requiredStateInvalid && report.phase == .headerAndPrivateGroups)
        case .history: #expect(report.category == .requiredStateInvalid && report.phase == .requiredHistory)
        default: break
        }
    }
}

@Test(arguments: [false, true])
func neutralPendingRequiresFreshRepresentedState(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let item = try PendingItemID(bytes: uuidBytes()), input = try await pendingInput(session, body: "A")
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    try await session.retainPendingSnapshot(input, basedOn: session.pendingItem(item))
    guard case .neutral(let r) = try await session.preparePendingAssociation(basedOn: session.pendingItem(item), birth: birth, generation: 1) else { Issue.record("neutral preparation authored an edit"); return }
    _ = try await put("new Current", birth: birth, generation: 2, session: session)
    await #expect(throws: StorageError.staleCapture) {
        try await session.completePendingAssociation(r.id, basedOn: session.pendingItem(item)) { _, _ in Issue.record("stale neutral evidence reached physical consumer"); return try PassivePlatformRecordV1(codec: 1, bytes: []) }
    }
    #expect(try await session.retainedPendingSnapshot(input.id) == input)
    #expect(try await session.pendingSettlement(item: item, snapshot: input.id) == nil)
    try await session.quiesce()
}

@Test(arguments: [false, true])
func neutralPendingWaitsForAcceptedDeleteMaterialization(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let item = try PendingItemID(bytes: uuidBytes()), input = try await pendingInput(session, body: "A")
    let birth = try NoteBirth(bytes: Array(repeating: 1, count: 16))
    try await session.retainPendingSnapshot(input, basedOn: session.pendingItem(item))
    guard case .neutral(let reservation) = try await session.preparePendingAssociation(
        basedOn: session.pendingItem(item), birth: birth, generation: 1) else { Issue.record("equal input authored an edit"); return }
    try await session.lane.perform {
        try $0.exec("CREATE TEMP TRIGGER fail_current_delete BEFORE DELETE ON current_notes BEGIN SELECT RAISE(ABORT,'held materialization'); END")
    }
    let deletion = try await CapturedActionGroup(snapshot: session.snapshot(), kind: .deleteBatch,
        changes: [.delete(CapturedNoteGeneration(birth: birth, generation: 2))])
    _ = try requireReceipt(await session.persist(capture: deletion))
    #expect(try await session.lane.perform { try $0.acceptedThrough() } == 2)
    #expect(try await session.lane.perform { try $0.rows("SELECT through_seq FROM view_meta") } == [[.integer(1)]])
    await #expect(throws: StorageError.incomplete) {
        try await session.completePendingAssociation(reservation.id, basedOn: session.pendingItem(item)) { _, _ in
            Issue.record("outdated Current reached the physical consumer")
            return try PassivePlatformRecordV1(codec: 1, bytes: [])
        }
    }
    #expect(try await session.retainedPendingSnapshot(input.id) == input)
    #expect(try await session.pendingSettlement(item: item, snapshot: input.id) == nil)
    try await session.lane.perform { try $0.exec("DROP TRIGGER fail_current_delete") }
    try await session.lane.catchUp(selection: session.selection, protection: protection)
    await #expect(throws: StorageError.staleCapture) {
        try await session.completePendingAssociation(reservation.id, basedOn: session.pendingItem(item)) { _, _ in
            Issue.record("deleted Current reached the physical consumer")
            return try PassivePlatformRecordV1(codec: 1, bytes: [])
        }
    }
    #expect(try await session.snapshot().notes.map(\.value.body.string) == ["untouched"])
    try await session.quiesce()
}
