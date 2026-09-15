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
final class Database {
    /// Complete the cipher's extra initialization before any collection opens.
    private static let initialization = sqlite3_initialize()
    private var owner: OpaquePointer?
    private var handle: OpaquePointer?
    private let executor: StorageExecutor
    private(set) var requiredHistoryDamaged = false
    var work: StorageWork?
    var workStage: StorageWork.Stage = .preparation

    /// Records failure while interpreting bytes positively identified as accepted history.
    func checkingRetainedHistory<T>(_ body: () throws -> T) throws -> T {
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
        try transaction {
            try run("INSERT INTO private_groups VALUES(?,1,1,?) ON CONFLICT(group_key) DO NOTHING",
                [.blob(Array("history-damage".utf8)), .blob([])])
        }
    }
    init(directory: String, create: Bool, key: [UInt8], executor: StorageExecutor) throws {
        self.executor = executor
        executor.checkIsolation()
        guard key.count == 32, !directory.utf8.contains(0) else { throw StorageError.wrongContext }
        try check(Self.initialization)
        owner = nv_storage_owner_open(directory, create ? 1 : 0)
        guard let owner else { throw StorageError.ownership(errno) }
        do {
            try check(sqlite3_open_v2(nv_storage_owner_database(owner), &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil))
            try validateOwner()
            let digits = Array("0123456789abcdef".utf8)
            var hex: [UInt8] = Array("x'".utf8) + key.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] } + [39]
            try hex.withUnsafeBytes { try check(sqlite3_key(handle, $0.baseAddress, Int32($0.count))) }
            _ = hex.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
            try check(sqlite3_extended_result_codes(handle, 1))
            try check(nv_sqlcipher_explicit_checkpoints(handle))
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
        } catch { close(); throw error }
    }
    deinit { executor.retire(handle: handle, owner: owner) }
    func close() {
        executor.checkIsolation()
        if let handle { sqlite3_close_v2(handle); self.handle = nil }
        if let owner { nv_storage_owner_close(owner); self.owner = nil }
    }
    func validateOwner() throws {
        executor.checkIsolation()
        guard let owner, handle != nil else { throw StorageError.closed }
        guard nv_storage_owner_validate(owner) == 0 else { throw StorageError.ownership(errno) }
    }
    private func check(_ code: Int32) throws {
        guard code == SQLITE_OK else { throw StorageError.database(code) }
    }
    func exec(_ sql: String) throws {
        countWork { $0.statements += 1 }
        try validateOwner()
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }
    func each(_ sql: String, _ args: [SQLValue] = [], visit: ([SQLValue]) throws -> Void) throws {
        countWork { $0.statements += 1; if sql.contains("WITH RECURSIVE") { $0.recursiveStatements += 1 } }
        try validateOwner()
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        defer {
            countWork {
                let steps = Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_VM_STEP, 0))
                $0.vmSteps += steps
                $0.statementSteps[sql, default: 0] += steps
                $0.fullScanSteps += Int(sqlite3_stmt_status(statement, SQLITE_STMTSTATUS_FULLSCAN_STEP, 0))
            }
            sqlite3_finalize(statement)
        }
        guard Int(sqlite3_bind_parameter_count(statement)) == args.count else { throw StorageError.integrity }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let n): try check(sqlite3_bind_int64(statement, index, n))
            case .null: try check(sqlite3_bind_null(statement, index))
            case .blob(let bytes):
                if bytes.isEmpty { try check(sqlite3_bind_zeroblob(statement, index, 0)) }
                else { try bytes.withUnsafeBytes { try check(sqlite3_bind_blob64(statement, index, $0.baseAddress, UInt64($0.count), transient)) } }
            case .text(let text): try check(sqlite3_bind_text(statement, index, text, -1, transient))
            }
        }
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw StorageError.database(rc) }
            countWork { $0.rows += 1 }
            var row: [SQLValue] = []
            for column in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, column)))
                case SQLITE_NULL: row.append(.null)
                case SQLITE_TEXT:
                    guard let p = sqlite3_column_text(statement, column) else { throw StorageError.integrity }
                    row.append(.text(String(cString: p)))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, column))
                    guard count >= 0, count <= 67174556 else { throw StorageError.limit }
                    if count == 0 { row.append(.blob([])) }
                    else {
                        guard let p = sqlite3_column_blob(statement, column) else { throw StorageError.integrity }
                        row.append(.blob(Array(UnsafeRawBufferPointer(start: p, count: count))))
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
        try check(sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil))
    }
}

/// Runs actor jobs on a dedicated blocking-I/O execution resource.
final class StorageExecutor: SerialExecutor {
    private let queue: DispatchQueue
    init(label: String, qos: DispatchQoS = .unspecified) { queue = DispatchQueue(label: label, qos: qos) }
    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
    // The unowned-job entrypoint supports the macOS 11 concurrency runtime.
    func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
    fileprivate func checkIsolation() { dispatchPrecondition(condition: .onQueue(queue)) }

    /// Transfers final C-handle disposal to the same queue after exclusive Swift ownership ends.
    fileprivate func retire(handle: OpaquePointer?, owner: OpaquePointer?) {
        guard handle != nil || owner != nil else { return }
        let retired = RetiredHandles(handle: handle, owner: owner)
        queue.async { self.checkIsolation(); retired.release() }
    }

    /// Immutable, release-only C handles transferred exactly once by Database.deinit.
    private struct RetiredHandles: @unchecked Sendable {
        let handle: OpaquePointer?
        let owner: OpaquePointer?
        func release() {
            if let handle { sqlite3_close_v2(handle) }
            if let owner { nv_storage_owner_close(owner) }
        }
    }
}

/// Performs envelope preparation independently of the connection owner.
private actor HistoryWorker {
    nonisolated let executor = StorageExecutor(label: "org.notationalvelocity.storage.history", qos: .utility)
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    func perform<T: Sendable>(_ work: @Sendable () throws -> T) rethrows -> T { try work() }
}

/// Actor ownership of the connection and complete synchronous database turns.
actor DatabaseLane {
    nonisolated private let executor = StorageExecutor(label: "org.notationalvelocity.storage.local")
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var database: Database?
    private let history = HistoryWorker()
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
    func close() { database?.close(); database = nil }
}
