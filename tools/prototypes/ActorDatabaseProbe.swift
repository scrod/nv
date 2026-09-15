import Foundation
import Dispatch
import CSQLCipher

/// Executes actor jobs on the database's blocking-I/O queue.
final class DatabaseExecutor: SerialExecutor {
    let queue = DispatchQueue(label: "nv.prototype.database")
    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
    // UnownedJob supports the macOS 11 deployment target.
    func enqueue(_ job: UnownedJob) {
        queue.async { job.runSynchronously(on: self.asUnownedSerialExecutor()) }
    }
}

enum ProbeError: Error { case sql(Int32), stale, closed, cycle, missing, expectation }

/// Owns an encrypted SQLCipher connection for the isolated experiment.
final class Connection {
    private var handle: OpaquePointer?
    private let queue: DispatchQueue
    init(path: String, queue: DispatchQueue) throws {
        self.queue = queue
        dispatchPrecondition(condition: .onQueue(queue))
        try check(sqlite3_open_v2(path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil))
        try exec("PRAGMA key = 'synthetic-prototype-key'")
        guard try scalar("PRAGMA cipher_version") == 4 else { throw ProbeError.expectation }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA temp_store=MEMORY; PRAGMA mmap_size=0")
        try exec("CREATE TABLE IF NOT EXISTS history(id INTEGER PRIMARY KEY, parent INTEGER NOT NULL)")
    }
    deinit { if let handle { sqlite3_close_v2(handle) } }
    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw ProbeError.sql(result) }
    }
    func exec(_ sql: String) throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }
    func scalar(_ sql: String) throws -> Int {
        dispatchPrecondition(condition: .onQueue(queue))
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw ProbeError.sql(result) }
        return Int(sqlite3_column_int64(statement, 0))
    }
    func close() throws {
        dispatchPrecondition(condition: .onQueue(queue))
        try check(sqlite3_close(handle)); handle = nil
    }
}

/// Protects connection lifetime and complete synchronous database turns.
actor DatabaseOwner {
    nonisolated let executor = DatabaseExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private var connection: Connection?
    var generation = 0

    func open(_ path: String) throws {
        guard connection == nil else { throw ProbeError.expectation }
        let opened = try Connection(path: path, queue: executor.queue)
        generation = try opened.scalar("SELECT count(*) FROM history")
        connection = opened
    }
    private func database() throws -> Connection {
        guard let connection else { throw ProbeError.closed }; return connection
    }
    func count() throws -> Int { try database().scalar("SELECT count(*) FROM history") }
    func parent(of id: Int, through expected: Int) throws -> Int {
        let db = try database()
        guard generation == expected else { throw ProbeError.stale }
        guard try db.scalar("SELECT count(*) FROM history WHERE id=\(id)") == 1 else { throw ProbeError.missing }
        return try db.scalar("SELECT parent FROM history WHERE id=\(id)")
    }
    func append(through expected: Int? = nil) throws {
        let db = try database()
        if let expected, expected != generation { throw ProbeError.stale }
        try db.exec("BEGIN IMMEDIATE")
        do {
            try db.exec("INSERT INTO history VALUES(\(generation + 1),\(generation))")
            try db.exec("COMMIT")
            generation += 1
        } catch { try? db.exec("ROLLBACK"); throw error }
    }
    func close() throws { try database().close(); connection = nil }

    #if PROBE_ESCAPE
    func escapedConnection() throws -> Connection { try database() }
    #endif
}

/// Holds a traversal after its first read so a test can insert a competing save.
actor ReadGate {
    private var arrived = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func stop() async {
        await withCheckedContinuation { continuation in
            release = continuation; arrived = true
            observer?.resume(); observer = nil
        }
    }
    func wait() async {
        if !arrived { await withCheckedContinuation { observer = $0 } }
    }
    func resume() { release?.resume(); release = nil }
}

/// Traverses a synthetic linear history using asynchronous, generation-checked reads.
func ancestors(of head: Int, read: @Sendable (Int) async throws -> Int,
               firstRead: @Sendable () async -> Void = {}) async throws -> Set<Int> {
    var found: Set<Int> = [], current = head
    while current != 0 {
        guard found.insert(current).inserted else { throw ProbeError.cycle }
        current = try await read(current)
        if found.count == 1 { await firstRead() }
    }
    return found
}

func require(_ condition: Bool) throws { if !condition { throw ProbeError.expectation } }

@main struct Probe {
    static func main() async throws {
        let owner = DatabaseOwner(), path = CommandLine.arguments[1]
        #if PROBE_MUTATION
        owner.generation = 42 // EXPECT_MUTATION_REJECTION
        #endif
        #if PROBE_ESCAPE
        let leaked = try await owner.escapedConnection() // EXPECT_ESCAPE_REJECTION
        _ = try leaked.scalar("SELECT 1")
        #endif
        try await owner.open(path)
        for _ in 0..<64 { try await owner.append() }
        let before = try await ancestors(of: 64, read: { try await owner.parent(of: $0, through: 64) })
        try require(before == Set(1...64))

        let gate = ReadGate()
        let traversal = Task {
            try await ancestors(of: 64, read: { try await owner.parent(of: $0, through: 64) },
                                firstRead: { await gate.stop() })
        }
        await gate.wait()
        try await owner.append()
        try require(try await owner.count() == 65)
        await gate.resume()
        do { _ = try await traversal.value; throw ProbeError.expectation }
        catch ProbeError.stale { }

        // A save after the final read also invalidates the acceptance-time check.
        let refreshed = try await ancestors(of: 65, read: { try await owner.parent(of: $0, through: 65) })
        try require(refreshed == Set(1...65))
        try await owner.append()
        do { try await owner.append(through: 65); throw ProbeError.expectation }
        catch ProbeError.stale { }
        try require(try await owner.count() == 66)

        // Concurrent callers exercise synchronous transaction and generation updates.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<32 { group.addTask { try await owner.append() } }
            try await group.waitForAll()
        }
        try require(try await owner.count() == 98)
        try await owner.close()
        do { _ = try await owner.count(); throw ProbeError.expectation }
        catch ProbeError.closed { }
        try await owner.open(path)
        let reopened = try await ancestors(of: 98, read: { try await owner.parent(of: $0, through: 98) })
        try require(reopened == Set(1...98))
        try await owner.close()
        print("PASS: actor SQLCipher ownership, async traversal, intervening save, final fence, 32 concurrent saves, close/reopen")
    }
}
