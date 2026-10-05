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
        defer { password.withUnsafeMutableBytes { if let p = $0.baseAddress { unsafe secure_wipe_memory(p, $0.count) } } }
        guard password.count <= 1024 else { throw CanonicalEncodingError.lengthLimit }
        var output = [UInt8](repeating: 0, count: 32)
        defer { output.withUnsafeMutableBytes { if let p = $0.baseAddress { unsafe secure_wipe_memory(p, $0.count) } } }
        // Each C call borrows initialized buffers with their exact capacities until it returns.
        let code = password.withUnsafeBytes { p in salt.withUnsafeBytes { s in output.withUnsafeMutableBytes { o in
            unsafe argon2id_hash_raw(passes, memoryKiB, lanes, p.baseAddress, p.count,
                              s.baseAddress, s.count, o.baseAddress, o.count)
        } } }
        guard code == ARGON2_OK.rawValue else { throw CanonicalEncodingError.keyDerivationFailure }
        return SymmetricKey(data: output)
    }
}
