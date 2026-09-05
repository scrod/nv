// Isolated native mechanisms, not production NV codecs, repair or credentials.
// Synthetic keys/data only. Invoked by run-sqlcipher-variation-probe.py.
import Foundation
import CryptoKit
import Darwin

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let publicKey = Data(SHA256.hash(data: Data("NV public local database key\0v1\0".utf8)))
let ck = Data(0..<32)
let collection = Data(32..<48), keyID = Data(48..<64)
func privateKey(_ secret: Data, collection: Data = collection, keyID: Data = keyID) -> Data {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
        salt: collection + keyID, info: Data("NV private database key\0v1\0".utf8),
        outputByteCount: 32).withUnsafeBytes { Data($0) }
}
let encryptedKey = privateKey(ck)
func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
enum Failure: Error { case sqlite(Int32), incomplete }
func ok(_ code: Int32) throws { if code != SQLITE_OK { throw Failure.sqlite(code) } }
func open(_ url: URL, key: Data, create: Bool = false) throws -> OpaquePointer {
    var handle: OpaquePointer?
    try ok(sqlite3_open_v2(url.path, &handle,
        SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0), nil))
    let db = handle!
    do {
        let raw = "x'" + hex(key) + "'"
        try ok(raw.withCString { sqlite3_key(db, $0, Int32(raw.utf8.count)) })
        try sql(db, "PRAGMA cipher_compatibility=4; PRAGMA foreign_keys=ON; PRAGMA synchronous=FULL; PRAGMA fullfsync=ON; PRAGMA temp_store=MEMORY;")
        try sql(db, "SELECT count(*) FROM sqlite_schema") // setting the key alone proves nothing
        return db
    } catch { sqlite3_close(db); throw error }
}
func sql(_ db: OpaquePointer, _ sql: String) throws {
    try ok(sqlite3_exec(db, sql, nil, nil, nil))
}
func query(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    try ok(sqlite3_prepare_v2(db, sql, -1, &statement, nil)); return statement!
}
func scalar(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
    let q = try query(db, sql); defer { sqlite3_finalize(q) }
    let rc = sqlite3_step(q); guard rc == SQLITE_ROW else { throw Failure.sqlite(rc) }
    return sqlite3_column_int64(q, 0)
}
func read(_ db: OpaquePointer, _ sql: String) throws -> Data {
    let q = try query(db, sql); defer { sqlite3_finalize(q) }
    let rc = sqlite3_step(q); guard rc == SQLITE_ROW else { throw Failure.sqlite(rc) }
    return Data(bytes: sqlite3_column_blob(q, 0), count: Int(sqlite3_column_bytes(q, 0)))
}
func insert(_ db: OpaquePointer, id: Int, bytes: Data) throws {
    let q = try query(db, "INSERT INTO objects VALUES(?, ?, ?)"); defer { sqlite3_finalize(q) }
    try ok(sqlite3_bind_int(q, 1, Int32(id)))
    // SQLITE_TRANSIENT makes each bind own its copy.
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    try ok(bytes.withUnsafeBytes { sqlite3_bind_blob(q, 2, $0.baseAddress, Int32($0.count), transient) })
    let hash = digest(bytes)
    try ok(hash.withUnsafeBytes { sqlite3_bind_blob(q, 3, $0.baseAddress, Int32($0.count), transient) })
    let rc = sqlite3_step(q); guard rc == SQLITE_DONE else { throw Failure.sqlite(rc) }
}
func schema(_ db: OpaquePointer) throws {
    try sql(db, """
        PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        CREATE TABLE objects(id INTEGER PRIMARY KEY, bytes BLOB NOT NULL, hash BLOB NOT NULL);
        CREATE TABLE pin(id INTEGER PRIMARY KEY REFERENCES objects(id));
        CREATE TABLE private_state(id INTEGER PRIMARY KEY, payload BLOB NOT NULL, operation INTEGER REFERENCES objects(id));
        """)
}
func backup(_ db: OpaquePointer, to url: URL, key: Data) throws {
    let target = try open(url, key: key, create: true); defer { sqlite3_close(target) }
    guard let b = sqlite3_backup_init(target, "main", db, "main") else { throw Failure.sqlite(sqlite3_errcode(target)) }
    let step = sqlite3_backup_step(b, -1), finish = sqlite3_backup_finish(b)
    guard step == SQLITE_DONE else { throw Failure.sqlite(step) }; try ok(finish)
}
var checks = [String]()
func check(_ name: String, _ condition: Bool) {
    if !condition { FileHandle.standardError.write(Data("FAILED: \(name)\n".utf8)); exit(1) }
    checks.append(name)
}
func rejects(_ name: String, _ work: () throws -> Void) {
    do { try work(); fatalError("accepted invalid case: \(name)") }
    catch { checks.append(name) }
}
let fm = FileManager.default

// A different process creates a password-free DB, commits into its WAL and dies.
// Its caller recovers it without a key file, original path, provider or Keychain.
if CommandLine.arguments.contains("--crash-child") {
    let db = try open(directory.appendingPathComponent("crashed.db"), key: publicKey, create: true)
    try schema(db)
    try insert(db, id: 1, bytes: Data("surviving committed text".utf8))
    try sql(db, "INSERT INTO pin VALUES(1)")
    kill(getpid(), SIGKILL)
    fatalError("SIGKILL failed")
}
let child = Process()
child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
child.arguments = [directory.path, "--crash-child"]
try child.run(); child.waitUntilExit()
check("child killed after durable commit", child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL)
let recoveredURL = directory.appendingPathComponent("renamed-public-copy.db")
for suffix in ["", "-wal"] {
    try fm.copyItem(at: directory.appendingPathComponent("crashed.db" + suffix),
                    to: URL(fileURLWithPath: recoveredURL.path + suffix))
}
let recovered = try open(recoveredURL, key: publicKey)
check("password-free copied WAL recovery without external secret", try read(recovered, "SELECT bytes FROM objects WHERE id=1") == Data("surviving committed text".utf8))
try ok(sqlite3_close(recovered))

check("database key domain separates public and protected", publicKey != encryptedKey)
check("collection binding", privateKey(ck, collection: Data(repeating: 0, count: 16)) != encryptedKey)
check("key identity binding", privateKey(ck, keyID: Data(repeating: 0, count: 16)) != encryptedKey)
check("wrong CK binding", privateKey(Data(repeating: 0, count: 32)) != encryptedKey)
let url = directory.appendingPathComponent("protected.db")
let db = try open(url, key: encryptedKey, create: true)
try schema(db)
let objects = [1: Data(repeating: 0x31, count: 32768),
               2: Data(repeating: 0x32, count: 32768),
               3: Data(repeating: 0x33, count: 32768)]
try insert(db, id: 1, bytes: objects[1]!)
try sql(db, "INSERT INTO pin VALUES(1); PRAGMA wal_checkpoint(TRUNCATE);")
// Unique unpublished work and a frozen private input live only in the WAL.
try sql(db, "BEGIN IMMEDIATE")
try insert(db, id: 2, bytes: objects[2]!); try insert(db, id: 3, bytes: objects[3]!)
try sql(db, "INSERT INTO pin VALUES(2),(3); INSERT INTO private_state VALUES(1, x'70726576696577', 3); COMMIT;")
let backedURL = directory.appendingPathComponent("backup.db")
let backupReader = try open(url, key: encryptedKey)
try sql(backupReader, "BEGIN")
check("backup snapshot captured", try scalar(backupReader, "SELECT count(*) FROM objects") == 3)
// WAL permits continued editing while the backup holds its earlier read view.
try insert(db, id: 4, bytes: Data("edit after backup capture".utf8))
try sql(db, "INSERT INTO pin VALUES(4); UPDATE private_state SET payload=x'6e6577', operation=4 WHERE id=1")
try backup(backupReader, to: backedURL, key: encryptedKey)
try sql(backupReader, "COMMIT"); try ok(sqlite3_close(backupReader))
check("writer advances independently of captured backup", try scalar(db, "SELECT count(*) FROM objects") == 4)
let incompleteURL = directory.appendingPathComponent("main-file-only.db")
try fm.copyItem(at: url, to: incompleteURL)
let incomplete = try open(incompleteURL, key: encryptedKey)
check("main-file-only copy misses committed tail", try scalar(incomplete, "SELECT count(*) FROM objects") == 1)
try ok(sqlite3_close(incomplete)); try ok(sqlite3_close(db))
let backed = try open(backedURL, key: encryptedKey)
check("keyed backup includes full WAL", try scalar(backed, "SELECT count(*) FROM objects") == 3)
check("keyed backup includes private frozen input and link", try read(backed, "SELECT payload FROM private_state WHERE operation=3") == Data("preview".utf8))
check("keyed backup includes pin", try scalar(backed, "SELECT count(*) FROM pin") == 3)
try ok(sqlite3_close(backed))
rejects("public key cannot unlock protected store") { let d = try open(backedURL, key: publicKey); sqlite3_close(d) }
rejects("wrong collection cannot unlock protected store") { let d = try open(backedURL, key: privateKey(ck, collection: Data(repeating: 0, count: 16))); sqlite3_close(d) }

// Reuse the provider CK wrapping mechanism; no additional device wrapping key.
// These are mechanics-only descriptors, not the unfinished NV descriptor codec.
func wrappingKey(_ password: String, salt: Data) -> SymmetricKey {
    let input = Data(password.precomposedStringWithCanonicalMapping.utf8)
    var output = Data(count: 32)
    let rc = output.withUnsafeMutableBytes { out in input.withUnsafeBytes { input in salt.withUnsafeBytes { salt in
        argon2id_hash_raw(3, 65536, 4, input.baseAddress, input.count, salt.baseAddress, salt.count, out.baseAddress, out.count)
    } } }
    precondition(rc == ARGON2_OK.rawValue); return SymmetricKey(data: output)
}
let beforeWrap = digest(try Data(contentsOf: backedURL))
let aad = Data("MECHANICS TEST ONLY".utf8) + collection + keyID
for (index, password) in ["first synthetic password", "changed synthetic password"].enumerated() {
    let salt = Data(repeating: UInt8(index), count: 16)
    let key = wrappingKey(password, salt: salt)
    let wrapper = try AES.GCM.seal(ck, using: key, authenticating: aad).combined!
    let descriptor = directory.appendingPathComponent("wrapper-\(index)")
    try (salt + wrapper).write(to: descriptor, options: .withoutOverwriting)
    let saved = try Data(contentsOf: descriptor)
    let unwrapped = try AES.GCM.open(AES.GCM.SealedBox(combined: saved.dropFirst(16)),
        using: wrappingKey(password, salt: saved.prefix(16)), authenticating: aad)
    let reopened = try open(backedURL, key: privateKey(unwrapped))
    check("password route \(index) opens all retained objects", try scalar(reopened, "SELECT count(*) FROM objects") == 3)
    try ok(sqlite3_close(reopened))
    rejects("wrong password rejects wrapper \(index)") {
        _ = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapper), using: wrappingKey("wrong", salt: salt), authenticating: aad)
    }
}
check("rewrapping CK leaves database bytes unchanged", beforeWrap == digest(try Data(contentsOf: backedURL)))

// Damage an actual encrypted overflow page, then salvage independent rows.
let damagedURL = directory.appendingPathComponent("damaged-evidence.db")
try fm.copyItem(at: backedURL, to: damagedURL)
let locator = try open(damagedURL, key: encryptedKey)
let page = try scalar(locator, "SELECT pageno FROM dbstat WHERE name='objects' AND pagetype='overflow' ORDER BY path LIMIT 1")
let size = try scalar(locator, "PRAGMA page_size")
try ok(sqlite3_close(locator))
let handle = try FileHandle(forUpdating: damagedURL)
let offset = UInt64((page - 1) * size + 128)
try handle.seek(toOffset: offset)
let old = try handle.read(upToCount: 1)!
try handle.seek(toOffset: offset); try handle.write(contentsOf: Data([old[0] ^ 1]))
try handle.synchronize(); try handle.close()
let damagedHash = digest(try Data(contentsOf: damagedURL))
let workURL = directory.appendingPathComponent("salvage-working-copy.db")
try fm.copyItem(at: damagedURL, to: workURL)
var survivors = [Int: Data](), damaged = [Int]()
for id in 1...3 {
    do {
        // A codec/page error can poison the pager on this connection. Independent
        // salvage queries use a fresh keyed handle; a failed scan is not total loss.
        let work = try open(workURL, key: encryptedKey)
        defer { sqlite3_close(work) }
        let bytes = try read(work, "SELECT bytes FROM objects WHERE id=\(id)")
        let hash = try read(work, "SELECT hash FROM objects WHERE id=\(id)")
        guard digest(bytes) == hash else { throw Failure.incomplete }
        survivors[id] = bytes
    } catch { damaged.append(id) }
}
FileHandle.standardError.write(Data("salvage: damaged=\(damaged), survivors=\(survivors.keys.sorted()), page=\(page)\n".utf8))
check("damaged history detected while independent unpublished row survives", damaged == [1] && survivors[3] == objects[3])
let work = try open(workURL, key: encryptedKey)
let pending = try read(work, "SELECT payload FROM private_state WHERE operation=3")
let required = Set(1...3) // fixture oracle; real repair obtains surviving pin/known evidence
func complete(_ rows: [Int: Data], pending: Data?) -> Bool {
    Set(rows.keys) == required && rows.allSatisfy { objects[$0.key] == $0.value }
        && pending == Data("preview".utf8)
}
check("partial salvage cannot claim complete repair", !complete(survivors, pending: pending))
survivors[1] = objects[1] // exact provider copy; provider does not possess unpublished id=3
check("complementary union covers required state", complete(survivors, pending: pending))
var omitted = survivors; omitted.removeValue(forKey: 3)
check("provider-only rebuild cannot discard unpublished edit", !complete(omitted, pending: pending))
check("history-only rebuild cannot discard private input", !complete(survivors, pending: nil))
var falseBytes = survivors; falseBytes[1] = Data("fabricated".utf8)
check("candidate bytes need semantic identity validation", !complete(falseBytes, pending: pending))
try ok(sqlite3_close(work))
let repairedURL = directory.appendingPathComponent("fresh-sibling.db")
let repaired = try open(repairedURL, key: encryptedKey, create: true)
try schema(repaired); try sql(repaired, "BEGIN IMMEDIATE")
for id in survivors.keys.sorted() { try insert(repaired, id: id, bytes: survivors[id]!) }
try sql(repaired, "INSERT INTO pin VALUES(1),(2),(3); INSERT INTO private_state VALUES(1,x'70726576696577',3); COMMIT;")
try ok(sqlite3_close(repaired))
let verified = try open(repairedURL, key: encryptedKey)
check("fresh sibling independently reopens with retained pin", try scalar(verified, "SELECT count(*) FROM pin") == 3)
check("fresh sibling preserves unpublished bytes", try read(verified, "SELECT bytes FROM objects WHERE id=3") == objects[3])
check("fresh sibling preserves private input", try read(verified, "SELECT payload FROM private_state WHERE operation=3") == pending)
try ok(sqlite3_close(verified))
check("damaged original unchanged by repair", damagedHash == digest(try Data(contentsOf: damagedURL)))
let result: [String: Any] = ["checks": checks, "count": checks.count,
    "public_key_vector": hex(publicKey), "encrypted_key_vector": hex(encryptedKey),
    "damaged_object_ids": damaged]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
