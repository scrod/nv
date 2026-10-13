import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

private func rowBirth(_ index: UInt8) throws -> NoteBirth { try NoteBirth(bytes: Array(repeating: index, count: 16)) }

@Test(arguments: [false, true])
func currentFramesReopenAndPreserveExactHistory(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let body = String(repeating: "A current note with Unicode: café, 日本語, e\u{301}.\n", count: 200)
    let receipt = try await put(body, birth: rowBirth(1), generation: 1, session: session)
    let bytes = try await session.retainedObject(at: receipt.object), before = try await session.snapshot(), lane = await session.lane
    let raw = try await lane.perform { try $0.rows("SELECT birth,cell FROM current_notes ORDER BY birth") }
    #expect(raw.count == 2 && raw.allSatisfy { (try? $0[1].bytes.starts(with: CurrentRowFrameV1.magic)) == true })
    let frame = try CurrentRowFrameV1(bytes: raw[0][1].bytes)
    #expect(frame.encoding == .zstd && frame.payload.count < body.utf8.count)
    let selection = await session.selection; try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let after = try await reopened.snapshot()
    #expect(after.notes == before.notes && after.context == before.context)
    #expect(after.notes.first { $0.birth == (try? rowBirth(1)) }?.value.body.string == body)
    #expect(try await reopened.retainedObject(at: receipt.object) == bytes)
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true], ["save", "epoch", "layout"])
func currentRecodeRejectsStalePreparation(encrypted: Bool, interference: String) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let snapshot = try await session.snapshot(), lane = await session.lane, gate = ImprovementGate()
    try await lane.perform { db in db.work = StorageWork(); db.work?.currentRowsPrepared = { await gate.hold() } }
    let attempt = Task { try await session.recodeCurrentRows(basedOn: snapshot, maximumRows: 1) }
    await gate.wait()
    if interference == "save" { _ = try await put("newer F", birth: rowBirth(1), generation: 1, session: session) }
    else if interference == "epoch" { _ = try await session.rebuildCurrentRows() }
    else {
        try await lane.perform { db in
            let row = try db.rows("SELECT birth,cell FROM current_notes ORDER BY birth LIMIT 1")[0]
            let cell = try db.currentCell(row[1].bytes)
            try db.run("UPDATE current_notes SET cell=? WHERE birth=?", [.blob(cell.encodedV1()), row[0]])
        }
    }
    await gate.release()
    await #expect(throws: StorageError.staleCapture) { try await attempt.value }
    #expect(try await session.snapshot().notes.map(\.value.body.string).sorted() == [interference == "save" ? "newer F" : "A", "untouched"])
    try await session.quiesce()
}

@Test(arguments: [false, true], ["missing", "digest", "cell"])
func currentDerivedDamageRebuildsWithoutPrivateOrHistoryLoss(encrypted: Bool, defect: String) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let receipt = try await put("durable E", birth: rowBirth(1), generation: 1, session: session)
    let retained = try await session.retainedObject(at: receipt.object)
    let expected = try await session.snapshot(), lane = await session.lane, selection = await session.selection
    try await session.saveEmptySettings(basedOn: session.settings())
    try await lane.perform { db in
        let row = try db.rows("SELECT birth,cell FROM current_notes ORDER BY birth LIMIT 1")[0]
        if defect == "cell" { try db.run("UPDATE current_notes SET cell=X'00' WHERE birth=?", [row[0]]) }
        else {
            var bytes = CurrentRowFrameV1.magic + [0,1,2,0,0,0,1,0,0,0,6] + Array(repeating: UInt8(9), count: 32)
            bytes += [0x28,0xb5,0x2f,0xfd,0x20,1]
            if defect == "digest" { try db.run("INSERT INTO current_dictionaries VALUES(?,?)", [.blob(Array(repeating: 9, count: 32)), .blob(Array(repeating: 1, count: 8))]) }
            try db.run("UPDATE current_notes SET cell=? WHERE birth=?", [.blob(bytes), row[0]])
        }
    }
    await lane.close()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes == expected.notes)
    #expect(try await reopened.settings().generation == 2)
    #expect(try await reopened.retainedObject(at: receipt.object) == retained)
    try await reopened.quiesce()
}

@Test(.timeLimit(.minutes(3)), arguments: [false, true])
func currentDictionaryMixedRowsBackupAndBoundedLoading(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let expected = try (1...64).map { index in
        let body = (0..<40).map { "Synthetic paragraph \($0): durable history, private storage, user actions and Unicode café 日本語; note \(index)." }.joined(separator: "\n")
        return try (rowBirth(UInt8(index)), testValue(body))
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let session = try await LocalStoreSession.create(directory: directory, collection: initial.descriptor.collection,
        notes: expected, protection: protection, passphrase: encrypted ? "synthetic" : nil)
    let snapshot = try await session.snapshot(), lane = await session.lane
    let next = try await session.recodeCurrentRows(basedOn: snapshot, maximumRows: 32, trainDictionary: true)
    #expect(next == (try rowBirth(32)))
    let rowCounts = try await lane.perform { db in
        try db.rows("SELECT cell FROM current_notes ORDER BY birth").map { try CurrentRowFrameV1(bytes: $0[0].bytes).encoding }
    }
    #expect(rowCounts.contains(.dictionary) && rowCounts.contains(.zstd))
    let dictionaryCount = try await lane.perform { try $0.rows("SELECT count(*) FROM current_dictionaries")[0][0].number }
    #expect(dictionaryCount == 1)
    // Only dictionaries referenced by captured rows participate in the load.
    try await lane.perform { db in
        for n in 1...32 { try db.run("INSERT INTO current_dictionaries VALUES(?,?)", [.blob(Array(repeating: UInt8(n), count: 32)), .blob(Array(repeating: 0, count: 8))]) }
        db.work = StorageWork()
    }
    let current = try await session.snapshot()
    #expect(Dictionary(uniqueKeysWithValues: current.notes.map { ($0.birth, $0.value) }) == Dictionary(uniqueKeysWithValues: expected))
    let work = try await lane.perform { $0.work! }
    #expect(work.stages.values.reduce(0) { $0 + $1.dictionaryLoads } == 1)
    let backup = try await session.backupPrivateStore(to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
    let copy = try await LocalStoreSession.open(selection: backup.selection, protection: protection)
    #expect(try await copy.snapshot().notes == current.notes)
    try await copy.quiesce()
    let selection = await session.selection; try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    #expect(try await reopened.snapshot().notes == current.notes)
    try await reopened.verifyCompletePrivateState()
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func currentRecodeRollbackPreservesDictionaryAndLogicalCut(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let before = try await session.snapshot(), lane = await session.lane
    let raw = try await lane.perform { try $0.rows("SELECT birth,cell FROM current_notes ORDER BY birth") }
    try await lane.perform { try $0.exec("CREATE TEMP TRIGGER fail_current_encoding BEFORE UPDATE ON current_notes BEGIN SELECT RAISE(ABORT,'encoding storage failed'); END") }
    await #expect(throws: (any Error).self) { try await session.recodeCurrentRows(basedOn: before) }
    #expect(try await lane.perform { try $0.rows("SELECT birth,cell FROM current_notes ORDER BY birth") } == raw)
    #expect(try await session.snapshot().notes == before.notes)
    #expect(try await session.snapshot().context == before.context)
    try await lane.perform { try $0.exec("DROP TRIGGER fail_current_encoding") }
    _ = try await session.recodeCurrentRows(basedOn: before)
    #expect(try await session.snapshot().notes == before.notes)
    try await session.quiesce()
}

@Test(arguments: [false, true])
func openingCaptureRechecksNewHistoryAndSamePrefixView(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let selection = await session.selection; try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection), lane = await reopened.lane
    // A same-prefix reconstruction changes the publication epoch before first handoff.
    let fresh = try await reopened.rebuildCurrentRows()
    let epoch = try await lane.perform { try $0.rows("SELECT epoch FROM view_meta WHERE singleton=1")[0][0].bytes }
    #expect(fresh.viewEpoch == epoch)
    #expect(fresh.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let receipt = try await put("F", birth: rowBirth(1), generation: 1, session: reopened)
    let change = try await reopened.prepareReduction(liveGeneration: 7)
    try await lane.perform { try $0.run("UPDATE view_meta SET epoch=?", [.blob(uuidBytes())]) }
    await #expect(throws: StorageError.staleCapture) { try await reopened.publish(change, liveGeneration: 7) { $0.notes.count } }
    #expect(try await reopened.snapshot().through == receipt.sequence)
    try await reopened.quiesce()
}

@Test(arguments: [false, true])
func currentRecodeRejectsForeignSnapshotBeforeWorkerAdmission(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted), left = try await newSession(initial, protection)
    let right = try await newSession(initial, protection), captured = try await left.snapshot()
    let lane = await right.lane
    try await lane.perform { $0.work = StorageWork() }
    await #expect(throws: StorageError.wrongContext) { try await right.recodeCurrentRows(basedOn: captured) }
    #expect(try await lane.perform { $0.work!.stages.values.reduce(0) { $0 + $1.currentCellDecodes } } == 0)
    #expect(try await right.snapshot().notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    try await left.quiesce(); try await right.quiesce()
}

@Test(arguments: [false, true], [1, 2, 4])
func currentSchemaVersionRejectsPreservedDevelopmentInputs(encrypted: Bool, version: Int) async throws {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    let lane = await session.lane, selection = await session.selection
    let queries = ["SELECT * FROM store_header", "SELECT object_id,encoded FROM objects ORDER BY object_id",
                   "SELECT * FROM private_groups ORDER BY group_key", "SELECT birth,cell FROM current_notes ORDER BY birth"]
    let before = try await lane.perform { db in
        try db.transaction {
            try db.exec("ALTER TABLE store_header RENAME TO preserved_header; CREATE TABLE store_header AS SELECT * FROM preserved_header")
            try db.run("UPDATE store_header SET schema_version=?", [.integer(Int64(version))])
        }
        return try queries.map { try db.rows($0) }
    }
    await lane.close()
    await #expect(throws: StorageError.unsupported) { try await LocalStoreSession.open(selection: selection, protection: protection) }
    let reader = DatabaseLane()
    try await reader.open(directory: selection.directory, create: false,
                          key: PrivateDatabaseKeyV1.derive(collection: selection.descriptor.collection, protection: protection))
    #expect(try await reader.perform { db in try queries.map { try db.rows($0) } } == before)
    await reader.close()
}
