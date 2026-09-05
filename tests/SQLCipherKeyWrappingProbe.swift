// Cryptographic mechanics probe, NOT the production credential/backup format.
// The device wrapping key is in memory: this does not qualify signed Keychain
// policy, credential deletion, metadata crash ordering, or secure erasure.
import Foundation
import CryptoKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let database = directory.appendingPathComponent("always-encrypted.db")
let storeID = UUID().uuidString
let master = SymmetricKey(size: .bits256)
let deviceWrappingKey = SymmetricKey(size: .bits256)
let masterBytes = master.withUnsafeBytes { Data($0) }
let rawKey = "x'" + masterBytes.map { String(format: "%02x", $0) }.joined() + "'"
let aad = Data(("NV SQLCipher WRAPPING EXPERIMENT ONLY\0" + storeID).utf8)
var timings: [Double] = []

func passwordKey(_ password: String, salt: Data) -> SymmetricKey {
    let bytes = Data(password.precomposedStringWithCanonicalMapping.utf8)
    var output = Data(count: 32)
    let begin = ProcessInfo.processInfo.systemUptime
    let rc = output.withUnsafeMutableBytes { out in
        bytes.withUnsafeBytes { input in
            salt.withUnsafeBytes { salt in
                argon2id_hash_raw(3, 65536, 4, input.baseAddress, input.count,
                                  salt.baseAddress, salt.count, out.baseAddress, out.count)
            }
        }
    }
    precondition(rc == ARGON2_OK.rawValue)
    timings.append((ProcessInfo.processInfo.systemUptime - begin) * 1000)
    return SymmetricKey(data: output)
}
func openDatabase(create: Bool, key: String) throws {
    var db: OpaquePointer?
    let flags = create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
    precondition(sqlite3_open_v2(database.path, &db, flags, nil) == SQLITE_OK)
    defer { precondition(sqlite3_close(db) == SQLITE_OK) }
    precondition(key.withCString { sqlite3_key(db, $0, Int32(key.utf8.count)) } == SQLITE_OK)
    if create {
        precondition(sqlite3_exec(db, "PRAGMA synchronous=EXTRA; PRAGMA fullfsync=ON; CREATE TABLE notes(body TEXT); INSERT INTO notes VALUES('synthetic wrapping fixture');", nil, nil, nil) == SQLITE_OK)
    }
    var query: OpaquePointer?
    precondition(sqlite3_prepare_v2(db, "SELECT body FROM notes", -1, &query, nil) == SQLITE_OK)
    defer { sqlite3_finalize(query) }
    precondition(sqlite3_step(query) == SQLITE_ROW)
    precondition(String(cString: sqlite3_column_text(query, 0)) == "synthetic wrapping fixture")
}
func seal(_ key: SymmetricKey) throws -> Data {
    try AES.GCM.seal(masterBytes, using: key, authenticating: aad).combined!
}
func unlock(_ wrapper: Data, key: SymmetricKey, context: Data? = nil) throws -> String {
    let data = try AES.GCM.open(AES.GCM.SealedBox(combined: wrapper), using: key,
                                authenticating: context ?? aad)
    precondition(data == masterBytes)
    return "x'" + data.map { String(format: "%02x", $0) }.joined() + "'"
}
func assertRejected(_ work: () throws -> String) {
    do { _ = try work(); fatalError("invalid wrapper was accepted") } catch { }
}
try openDatabase(create: true, key: rawKey)
let initialHash = SHA256.hash(data: try Data(contentsOf: database))
let deviceWrapper = try seal(deviceWrappingKey)
try openDatabase(create: false, key: unlock(deviceWrapper, key: deviceWrappingKey))
let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
let first = passwordKey("synthetic first password", salt: salt)
let firstWrapper = try seal(first)
try openDatabase(create: false, key: unlock(firstWrapper, key: first))
let nextSalt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
let next = passwordKey("synthetic changed password", salt: nextSalt)
let nextWrapper = try seal(next)
try openDatabase(create: false, key: unlock(nextWrapper, key: next))
assertRejected { try unlock(nextWrapper, key: passwordKey("wrong password", salt: nextSalt)) }
assertRejected { try unlock(nextWrapper, key: next, context: Data("different store".utf8)) }
var damaged = nextWrapper; damaged[damaged.count - 1] ^= 1
assertRejected { try unlock(damaged, key: next) }
// Removing the password requirement returns to the device unlock route, not
// plaintext database pages. Old retained wrappers still unlock the same key.
let disabledWrapper = try seal(deviceWrappingKey)
try openDatabase(create: false, key: unlock(disabledWrapper, key: deviceWrappingKey))
try openDatabase(create: false, key: unlock(firstWrapper, key: first))
let finalHash = SHA256.hash(data: try Data(contentsOf: database))
precondition(initialHash == finalHash)
let result: [String: Any] = ["password_set_changed_removed": true, "database_unchanged": true,
    "wrong_password_rejected": true, "wrong_scope_rejected": true, "tampering_rejected": true,
    "old_wrapper_still_unlocks": true, "argon2id_64MiB_t3_p4_ms": timings,
    "wrapper_bytes": nextWrapper.count, "salt_bytes": nextSalt.count]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
