import CArgon2
import Crypto
import Foundation

public enum Argon2idV1 {
    public static let memoryKiB: UInt32 = 65_536
    public static let passes: UInt32 = 3
    public static let lanes: UInt32 = 4

/// Derives a wrapping key with fixed resource parameters on a blocking worker.
    /// The runtime serializes unlock attempts on its dedicated worker queue.
    public static func wrappingKey(passphrase: String, salt: [UInt8]) throws -> SymmetricKey {
        guard salt.count == 16 else { throw CanonicalEncodingError.invalidPayload }
        var password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        defer { password.withUnsafeMutableBytes { if let p = $0.baseAddress { secure_wipe_memory(p, $0.count) } } }
        guard password.count <= 1024 else { throw CanonicalEncodingError.lengthLimit }
        var output = [UInt8](repeating: 0, count: 32)
        defer { output.withUnsafeMutableBytes { if let p = $0.baseAddress { secure_wipe_memory(p, $0.count) } } }
// Borrow the owning buffers for the duration of the synchronous C call.
        let code = password.withUnsafeBytes { p in salt.withUnsafeBytes { s in output.withUnsafeMutableBytes { o in
            argon2id_hash_raw(passes, memoryKiB, lanes, p.baseAddress, p.count,
                              s.baseAddress, s.count, o.baseAddress, o.count)
        } } }
        guard code == ARGON2_OK.rawValue else { throw CanonicalEncodingError.keyDerivationFailure }
        return SymmetricKey(data: output)
    }
}
