import CSQLCipher
import CStorageIO
import Foundation
import NVStorageCore

public enum StorageError: Error, Equatable, Sendable {
    case ownership(Int32), database(Int32), unsupported, wrongContext, incomplete, integrity
    case closed, busy, staleCapture, limit
}

enum SQLValue: Equatable, Sendable {
    case integer(Int64), blob([UInt8]), text(String), null
    var bytes: [UInt8] { get throws { guard case .blob(let b) = self else { throw StorageError.integrity }; return b } }
    var number: Int64 { get throws { guard case .integer(let n) = self else { throw StorageError.integrity }; return n } }
}

/// Connection and directory lease confined to a single blocking-I/O queue.
/// Its private handles own C resources; statement borrows become copied Swift values.
@safe
final class Database {
    /// Live connection identity checked by acceptance evidence consumers.
    let incarnation = UUID()
    var presentationEpoch = UUID()
    var presentationPins: [NoteBirth: OperationID] = [:]
    /// Complete the cipher's extra initialization before any collection opens.
    private static let initialization = sqlite3_initialize()
    private var owner: OpaquePointer?
    private var handle: OpaquePointer?
    private var backup: PrivateBackupWork?
    private let executor: StorageExecutor
    private(set) var requiredHistoryDamaged = false
    fileprivate var diagnosisAttemptedThisTurn = false
    var work: StorageWork?
    var workStage: StorageWork.Stage = .preparation

    /// Records failure while interpreting bytes positively identified as accepted history.
    func checkingRetainedHistory<T>(_ body: () throws -> T) throws -> T {
        guard let admitted = VerificationScope.current else {
            return try verifying(.history(acceptedThrough())) { try checkingRetainedHistory(body) }
        }
        try admitted.check(database: self)
        do { return try body() }
        catch {
            if error is CanonicalEncodingError { requiredHistoryDamaged = true }
            if let failure = error as? StorageError {
                switch failure {
                case .integrity, .incomplete: requiredHistoryDamaged = true
                case .database(let code) where code & 0xff == SQLITE_CORRUPT || code & 0xff == SQLITE_NOTADB:
                    requiredHistoryDamaged = true
                default: break
                }
            }
            throw error
        }
    }
    func requireHealthyHistory() throws {
        guard !requiredHistoryDamaged else { throw StorageError.integrity }
    }
    /// Preserves known damage across reopen when the private database can still commit.
    func recordRequiredHistoryDamage() throws {
        guard !diagnosisAttemptedThisTurn else { return }
        diagnosisAttemptedThisTurn = true
        try transaction {
            try run("INSERT INTO private_groups VALUES(?,1,1,?) ON CONFLICT(group_key) DO NOTHING",
                [.blob(Array("history-damage".utf8)), .blob([])])
            if let admitted = VerificationScope.current {
                try admitted.check(database: self)
                try run("DELETE FROM private_groups WHERE group_key=?", [.blob(admitted.record.key)])
            }
        }
    }
    init(directory: String, create: Bool, key: [UInt8], executor: StorageExecutor) throws {
        self.executor = executor
        executor.checkIsolation()
        guard key.count == 32, !directory.utf8.contains(0) else { throw StorageError.wrongContext }
        try check(Self.initialization)
        unsafe owner = nv_storage_owner_open(directory, create ? 1 : 0)
        guard let owner = unsafe owner else { throw StorageError.ownership(errno) }
        do {
            try unsafe check(sqlite3_open_v2(nv_storage_owner_database(owner), &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil))
            try configureCipher(key: key)
        } catch { close(); throw error }
    }
    private init(borrowing source: Database, key: [UInt8]) throws {
        executor = source.executor
        executor.checkIsolation()
        guard let sourceOwner = unsafe source.owner else { throw StorageError.closed }
        unsafe owner = nv_storage_owner_borrow(sourceOwner)
        guard let owner = unsafe owner else { throw StorageError.ownership(errno) }
        do {
            try unsafe check(sqlite3_open_v2(nv_storage_owner_database(owner), &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil))
            try configureCipher(key: key)
        } catch { close(); throw error }
    }
    private func configureCipher(key: [UInt8]) throws {
            try validateOwner()
            let digits = Array("0123456789abcdef".utf8)
            var hex: [UInt8] = Array("x'".utf8) + key.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] } + [39]
            try hex.withUnsafeBytes { try unsafe check(sqlite3_key(handle, $0.baseAddress, Int32($0.count))) }
            _ = hex.withUnsafeMutableBytes { unsafe $0.initializeMemory(as: UInt8.self, repeating: 0) }
            try unsafe check(sqlite3_extended_result_codes(handle, 1))
            try unsafe check(nv_sqlcipher_explicit_checkpoints(handle))
            let version = try rows("PRAGMA cipher_version")
            guard version == [[.text("4.19.0 community")]] || version == [[.text("4.19.0")]] else {
                throw StorageError.unsupported
            }
            try exec("PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA mmap_size=0; PRAGMA temp_store=MEMORY; PRAGMA wal_autocheckpoint=0; PRAGMA fullfsync=ON; PRAGMA checkpoint_fullfsync=ON;")
            guard try rows("PRAGMA journal_mode=WAL") == [[.text("wal")]],
                  try rows("PRAGMA foreign_keys") == [[.integer(1)]],
                  try rows("PRAGMA synchronous") == [[.integer(2)]],
                  try rows("PRAGMA wal_autocheckpoint") == [[.integer(0)]],
                  try rows("PRAGMA mmap_size") == [[.integer(0)]],
                  try rows("PRAGMA temp_store") == [[.integer(2)]] else { throw StorageError.unsupported }
            #if os(macOS)
            guard try rows("PRAGMA fullfsync") == [[.integer(1)]],
                      try rows("PRAGMA checkpoint_fullfsync") == [[.integer(1)]] else { throw StorageError.unsupported }
            #endif
    }
    deinit {
        // Complete any final borrowed-reader work before retiring its source connection.
        if let backup { executor.finishOnOwner { backup.close() } }
        unsafe executor.retire(handle: handle, owner: owner)
    }
    func close() {
        executor.checkIsolation()
        cancelPrivateBackup()
        if let handle = unsafe handle { unsafe sqlite3_close_v2(handle); unsafe self.handle = nil }
        if let owner = unsafe owner { unsafe nv_storage_owner_close(owner); unsafe self.owner = nil }
    }
    func validateOwner() throws {
        executor.checkIsolation()
        guard let owner = unsafe owner, unsafe handle != nil else { throw StorageError.closed }
        guard unsafe nv_storage_owner_validate(owner) == 0 else { throw StorageError.ownership(errno) }
    }
    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw StorageError.database(code) }
    }
    func exec(_ sql: String) throws {
        countWork { $0.statements += 1 }
        try validateOwner()
        try unsafe check(sqlite3_exec(handle, sql, nil, nil, nil))
    }
    func each(_ sql: String, _ args: [SQLValue] = [], visit: ([SQLValue]) throws -> Void) throws {
        countWork { $0.statements += 1; if sql.contains("WITH RECURSIVE") { $0.recursiveStatements += 1 } }
        try validateOwner()
        var statement: OpaquePointer?
        try unsafe check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        defer {
            countWork {
                let steps = unsafe Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
                $0.vmSteps += steps
                $0.statementSteps[sql, default: 0] += steps
                unsafe $0.fullScanSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
            }
            unsafe sqlite3_finalize(statement)
        }
        guard unsafe Int(sqlite3_bind_parameter_count(statement)) == args.count else { throw StorageError.integrity }
        // SQLite's transient destructor copies each borrowed value before its binding call returns.
        let transient = unsafe unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let n): try unsafe check(sqlite3_bind_int64(statement, index, n))
            case .null: try unsafe check(sqlite3_bind_null(statement, index))
            case .blob(let bytes):
                if bytes.isEmpty { try unsafe check(sqlite3_bind_zeroblob(statement, index, 0)) }
                else { try bytes.withUnsafeBytes { try unsafe check(sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64($0.count), transient)) } }
            case .text(let text): try unsafe check(sqlite3_bind_text(statement, index, text, -1, transient))
            }
        }
        while true {
            let rc = unsafe sqlite3_step(statement)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw StorageError.database(rc) }
            countWork { $0.rows += 1 }
            var row: [SQLValue] = []
            for column in 0..<(unsafe sqlite3_column_count(statement)) {
                switch unsafe sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: unsafe row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_NULL: row.append(.null)
                case SQLITE_TEXT:
                    guard let p = unsafe sqlite3_column_text(statement, column) else { throw StorageError.integrity }
                    unsafe row.append(.text(String(cString: p)))
                case SQLITE_BLOB:
                    let count = unsafe Int(sqlite3_column_bytes(statement, column))
                    guard count >= 0, count <= 67174556 else { throw StorageError.limit }
                    if count == 0 { row.append(.blob([])) }
                    else {
                        guard let p = unsafe sqlite3_column_blob(statement, column) else { throw StorageError.integrity }
                        // The row owns a copy before SQLite advances or finalizes this statement.
                        unsafe row.append(.blob(Array(UnsafeRawBufferPointer(start: p, count: count))))
                    }
                default: throw StorageError.integrity
                }
            }
            try visit(row)
        }
    }
    func run(_ sql: String, _ args: [SQLValue] = []) throws { try each(sql, args) { _ in } }
    func rows(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        var result: [[SQLValue]] = []; try each(sql, args) { result.append($0) }; return result
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try body(); try exec("COMMIT"); try validateOwner(); return result }
        catch { try? exec("ROLLBACK"); throw error }
    }
    func checkpoint() throws {
        try validateOwner()
        try unsafe check(sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil))
    }

    func installUnlockDescriptor(_ descriptor: BootstrapDescriptorV1) throws {
        guard descriptor.keyID != nil else { return }
        try validateOwner()
        let digits = Array("0123456789abcdef".utf8)
        let leaf = String(decoding: descriptor.descriptorID.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self) + ".nvkey"
        let bytes = descriptor.encodedBytes
        guard let owner = unsafe owner else { throw StorageError.closed }
        let stage = ".stage-" + UUID().uuidString
        let rc = bytes.withUnsafeBufferPointer { unsafe nv_storage_owner_descriptor(owner, leaf, stage, $0.baseAddress, UInt64($0.count)) }
        guard rc == 0 else { throw StorageError.ownership(errno) }
    }

    func beginPrivateBackup(directory: String, selection: LocalStoreSelection, key: [UInt8]) throws -> PrivateBackupCapture {
        guard backup == nil else { throw StorageError.busy }
        let reader = try Database(borrowing: self, key: key)
        let destination: Database
        do { destination = try Database(directory: directory, create: true, key: key, executor: executor) }
        catch { reader.close(); throw error }
        do {
            try reader.exec("BEGIN")
            try reader.validateHeader(store: selection.store, descriptor: selection.descriptor)
            let through = try reader.acceptedThrough()
            let groups = try reader.rows("SELECT group_key,generation,codec,payload FROM private_groups ORDER BY group_key")
            let pin = try reader.rows("SELECT object_id,locator FROM retained_frontier ORDER BY object_id")
            let meta = try reader.rows("SELECT epoch,reducer_version,through_seq,authoring_context FROM view_meta WHERE singleton=1")
            let current = try reader.rows("SELECT birth,cell FROM current_notes ORDER BY birth")
            let cut = try PrivateBackupCapture(through: through, groups: groups, pin: pin, current: current, view: meta,
                pending: reader.pendingPrivateFingerprint())
            guard let task = unsafe sqlite3_backup_init(destination.handle, "main", reader.handle, "main") else {
                throw StorageError.database(unsafe sqlite3_errcode(destination.handle))
            }
            unsafe backup = PrivateBackupWork(reader: reader, destination: destination, task: task)
            return cut
        } catch { reader.close(); destination.close(); throw error }
    }
    /// Copies bounded pages from a fixed read state; the primary writer stays available between turns.
    func stepPrivateBackup(pages: Int32) throws -> Bool {
        try validateOwner()
        guard let backup, pages > 0 else { throw StorageError.wrongContext }
        try backup.reader.validateOwner(); try backup.destination.validateOwner()
        let rc = unsafe sqlite3_backup_step(backup.task, pages)
        guard rc == SQLITE_OK || rc == SQLITE_DONE else { throw StorageError.database(rc) }
        if rc == SQLITE_DONE {
            let result = unsafe sqlite3_backup_finish(backup.task)
            unsafe backup.task = nil
            try check(result)
            try backup.destination.checkpoint()
            backup.reader.close(); backup.destination.close(); self.backup = nil
            return true
        }
        return false
    }
    func cancelPrivateBackup() { backup?.close(); backup = nil }
}

/// Fixed database cut checked before ordinary recovery processes its captured work.
struct PrivateBackupCapture: Sendable {
    let through: Int64
    let groups: [[SQLValue]]
    let pin: [[SQLValue]]
    let current: [[SQLValue]]
    let view: [[SQLValue]]
    let pending: [UInt8]
}

@safe
private final class PrivateBackupWork {
    let reader: Database
    let destination: Database
    var task: OpaquePointer?
    init(reader: Database, destination: Database, task: OpaquePointer) {
        self.reader = reader; self.destination = destination; unsafe self.task = task
    }
    func close() {
        if let task = unsafe task { unsafe sqlite3_backup_finish(task); unsafe self.task = nil }
        reader.close(); destination.close()
    }
}

/// Runs actor jobs on a dedicated blocking-I/O execution resource.
final class StorageExecutor: SerialExecutor {
    private let queue: DispatchQueue
    private let queueIdentity = DispatchSpecificKey<UInt8>()
    init(label: String, qos: DispatchQoS = .unspecified) {
        queue = DispatchQueue(label: label, qos: qos)
        queue.setSpecific(key: queueIdentity, value: 1)
    }
    func asUnownedSerialExecutor() -> UnownedSerialExecutor { unsafe UnownedSerialExecutor(ordinary: self) }
    // The unowned-job entrypoint supports the macOS 11 concurrency runtime.
    func enqueue(_ job: UnownedJob) {
        queue.async { unsafe job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
    fileprivate func checkIsolation() { dispatchPrecondition(condition: .onQueue(queue)) }

    /// Finishes final C-handle disposal on the owning queue before destruction returns.
    fileprivate func retire(handle: OpaquePointer?, owner: OpaquePointer?) {
        guard unsafe handle != nil || owner != nil else { return }
        let retired = unsafe RetiredHandles(handle: handle, owner: owner)
        if DispatchQueue.getSpecific(key: queueIdentity) == 1 { unsafe retired.release() }
        else { synchronizeRelease { unsafe retired.release() } }
    }
    func retireSelection(_ owner: OpaquePointer?) {
        guard let owner = unsafe owner else { return }
        let retired = unsafe RetiredSelection(owner: owner)
        finishOnOwner { unsafe retired.release() }
    }
    func retireSource(_ owner: OpaquePointer?) {
        guard let owner = unsafe owner else { return }
        let retired = unsafe RetiredHandles(handle: nil, owner: owner)
        finishOnOwner { unsafe retired.release() }
    }
    func retireRepository(_ owner: OpaquePointer?) {
        guard let owner = unsafe owner else { return }
        let retired = unsafe RetiredRepository(owner: owner)
        finishOnOwner { unsafe retired.release() }
    }
    func finishOnOwner(_ release: () -> Void) {
        if DispatchQueue.getSpecific(key: queueIdentity) == 1 { release() }
        else { synchronizeRelease(release) }
    }

    /// Borrows the final release closure until disposal finishes on the owning queue.
    private func synchronizeRelease(_ release: () -> Void) {
        queue.sync { self.checkIsolation(); release() }
    }

    /// Immutable, release-only C handles transferred exactly once by Database.deinit.
    @unsafe
    private struct RetiredHandles {
        let handle: OpaquePointer?
        let owner: OpaquePointer?
        func release() {
            if let handle = unsafe handle { unsafe sqlite3_close_v2(handle) }
            if let owner = unsafe owner { unsafe nv_storage_owner_close(owner) }
        }
    }
    @unsafe
    private struct RetiredSelection {
        let owner: OpaquePointer
        func release() { unsafe nv_selection_close(owner) }
    }
    @unsafe
    private struct RetiredRepository {
        let owner: OpaquePointer
        func release() { unsafe nv_repository_close(owner) }
    }
}

/// Performs envelope preparation independently of the connection owner.
private actor HistoryWorker {
    nonisolated let executor = StorageExecutor(label: "org.notationalvelocity.storage.history", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    func perform<T: Sendable>(_ work: @Sendable () throws -> T) rethrows -> T { try work() }
}

/// Actor ownership of the connection and complete synchronous database turns.
actor DatabaseLane {
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.local")
    nonisolated var unownedExecutor: UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }
    private var database: Database?
    private let history = HistoryWorker()
    var verificationReplayContext: (LocalStoreSelection, ObjectProtectionV1)?
    /// Prepares one envelope on the separate history worker.
    nonisolated func historyWork<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await history.perform(work)
    }

    /// Gives a suspended history traversal one generation-checked database turn.
    func historyRead<T: Sendable>(through: Int64, _ read: @Sendable (Database) throws -> T) throws -> T {
        try perform { db in
            try db.validateOwner()
            guard try db.acceptedThrough() == through else { throw StorageError.staleCapture }
            return try db.measuring(.validation) { try read(db) }
        }
    }
    func prepare<T: Sendable>(_ work: @Sendable () throws -> T) rethrows -> T { try work() }
    func perform<T: Sendable>(_ work: @Sendable (Database) throws -> T) throws -> T {
        guard let db = database else { throw StorageError.closed }
        db.diagnosisAttemptedThisTurn = false
        let start = db.work == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        defer {
            if start != 0 {
                let duration = DispatchTime.now().uptimeNanoseconds - start
                db.countWork { $0.writerTurns += 1; $0.maxWriterNanoseconds = max($0.maxWriterNanoseconds, duration) }
            }
        }
        do {
            try db.requireHealthyHistory()
            let result = try work(db)
            try db.requireHealthyHistory()
            return result
        } catch {
            if db.requiredHistoryDamaged { try? db.recordRequiredHistoryDamage() }
            throw error
        }
    }
    func open(directory: String, create: Bool, key: [UInt8]) throws {
        guard database == nil else { throw StorageError.busy }
        database = try Database(directory: directory, create: create, key: key, executor: executor)
    }
    func close() { verificationReplayContext = nil; database?.close(); database = nil }
}
