import Crypto
import Foundation

/// Structurally checked collection/profile and Genesis references, with key-wrapping
/// data for encrypted collections. Unlock and history validation establish editability.
public struct BootstrapDescriptorV1: Sendable {
    public let collection: CollectionID
    public let keyID: CollectionKeyID?
    public let genesis: SegmentLocator
    public let encodedBytes: [UInt8]
    public var descriptorID: [UInt8] { Array(SHA256.hash(data: encodedBytes)) }
    private let salt: [UInt8]
    private let nonce: [UInt8]
    private static let magic = Array("NVKEY1\r\n".utf8)
    private static let wrapDomain = Array("NV key wrap\0v1\0".utf8)
    private static let publicDomain = Array("NV public descriptor\0v1\0".utf8)

    private static func header(collection: CollectionID, keyID: CollectionKeyID?, genesis: SegmentLocator,
                               salt: [UInt8], nonce: [UInt8]) -> [UInt8] {
        let encrypted = keyID != nil
        var bytes = magic + bigEndianBytes(UInt16(1)) + [encrypted ? 2 : 1] + collection.bytes
        bytes += keyID?.bytes ?? [UInt8](repeating: 0, count: 16)
        bytes += bigEndianBytes(UInt16(1)) + genesis.encodedV1()
        bytes += [encrypted ? 1 : 0] + bigEndianBytes(UInt32(encrypted ? 0x13 : 0))
        bytes += bigEndianBytes(UInt32(encrypted ? 65536 : 0))
        bytes += bigEndianBytes(UInt32(encrypted ? 3 : 0)) + bigEndianBytes(UInt32(encrypted ? 4 : 0))
        bytes += salt + nonce + bigEndianBytes(UInt32(encrypted ? 32 : 0))
        return bytes
    }

    public static func publicDescriptor(collection: CollectionID, genesis: SegmentLocator) throws -> Self {
        let header = header(collection: collection, keyID: nil, genesis: genesis,
                            salt: .init(repeating: 0, count: 16), nonce: .init(repeating: 0, count: 12))
        return try decodeV1(header + Array(SHA256.hash(data: publicDomain + header)))
    }

/// Wraps the existing collection key with a password-derived key and fresh salt/nonce
    /// on a blocking worker. Retain the exact result for retries; the collection key
    /// and its derived private-database key remain stable across password changes.
    public static func wrap(collection: CollectionID, keyID: CollectionKeyID, genesis: SegmentLocator,
                            collectionKey: SymmetricKey, passphrase: String) throws -> Self {
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) }
        let wrappingKey = try Argon2idV1.wrappingKey(passphrase: passphrase, salt: salt)
        return try wrap(collection: collection, keyID: keyID, genesis: genesis, collectionKey: collectionKey,
                        wrappingKey: wrappingKey, salt: salt, nonce: AES.GCM.Nonce())
    }

    private static func wrap(collection: CollectionID, keyID: CollectionKeyID, genesis: SegmentLocator,
                     collectionKey: SymmetricKey, wrappingKey: SymmetricKey, salt: [UInt8],
                     nonce: AES.GCM.Nonce) throws -> Self {
        guard collectionKey.bitCount == 256, wrappingKey.bitCount == 256, salt.count == 16 else {
            throw CanonicalEncodingError.invalidPayload
        }
        let header = header(collection: collection, keyID: keyID, genesis: genesis, salt: salt, nonce: Array(nonce))
        let box = try collectionKey.withUnsafeBytes {
            try AES.GCM.seal($0, using: wrappingKey, nonce: nonce, authenticating: wrapDomain + header)
        }
        return try decodeV1(header + Array(box.ciphertext) + Array(box.tag))
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard bytes.count <= 16384 else { throw CanonicalEncodingError.lengthLimit }
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == magic, try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        let profile = try c.byte()
        guard profile == 1 || profile == 2 else { throw CanonicalEncodingError.unsupportedFormat }
        let collection = try CollectionID(bytes: c.fixedBytes(16))
        let keyBytes = try c.fixedBytes(16)
        let keyID: CollectionKeyID?
        if profile == 1 {
            guard keyBytes == [UInt8](repeating: 0, count: 16) else { throw CanonicalEncodingError.wrongScope }
            keyID = nil
        } else { keyID = try CollectionKeyID(bytes: keyBytes) }
        guard try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        let genesis = try SegmentLocator.decode(&c)
        let kdf = try c.byte(), version = try c.unsigned32(), memory = try c.unsigned32()
        let passes = try c.unsigned32(), lanes = try c.unsigned32()
        guard kdf == (profile == 2 ? 1 : 0), version == (profile == 2 ? 0x13 : 0),
              memory == (profile == 2 ? 65536 : 0), passes == (profile == 2 ? 3 : 0),
              lanes == (profile == 2 ? 4 : 0) else { throw CanonicalEncodingError.unsupportedFormat }
        let salt = try c.fixedBytes(16), nonce = try c.fixedBytes(12), length = try c.unsigned32()
        if profile == 1 {
            guard length == 0, salt == [UInt8](repeating: 0, count: 16), nonce == [UInt8](repeating: 0, count: 12) else {
                throw CanonicalEncodingError.invalidPayload
            }
            guard try c.fixedBytes(32) == Array(SHA256.hash(data: publicDomain + bytes.prefix(150))) else {
                throw CanonicalEncodingError.authenticationFailure
            }
        } else {
            guard length == 32 else { throw CanonicalEncodingError.invalidPayload }
            _ = try c.fixedBytes(48)
        }
        try c.requireEnd()
        return Self(collection: collection, keyID: keyID, genesis: genesis, encodedBytes: bytes, salt: salt, nonce: nonce)
    }

    public func unwrap(passphrase: String) throws -> SymmetricKey {
        guard keyID != nil else { throw CanonicalEncodingError.wrongScope }
        return try unwrap(wrappingKey: Argon2idV1.wrappingKey(passphrase: passphrase, salt: salt))
    }

    func unwrap(wrappingKey: SymmetricKey) throws -> SymmetricKey {
        guard keyID != nil, wrappingKey.bitCount == 256 else { throw CanonicalEncodingError.wrongScope }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
            ciphertext: encodedBytes[150..<182], tag: encodedBytes[182..<198])
        do {
            return SymmetricKey(data: try AES.GCM.open(box, using: wrappingKey,
                authenticating: Self.wrapDomain + encodedBytes.prefix(150)))
        } catch { throw CanonicalEncodingError.authenticationFailure }
    }
}
