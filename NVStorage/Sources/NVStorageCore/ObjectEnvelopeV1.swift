import Crypto
import Foundation

public enum ProviderObjectKind: UInt8, Sendable {
    case changes = 1, snapshotRoot = 2, snapshotPage = 3
}

/// Compression tags in the authenticated version-1 provider header.
public enum ObjectCompressionV1: UInt8, Sendable {
    case none = 0, zstd = 1
}

public enum ObjectProtectionV1: Sendable {
    case publicHash
    case encrypted(keyID: CollectionKeyID, key: SymmetricKey)

    var suite: UInt8 { if case .publicHash = self { 0 } else { 1 } }
    var keyIDBytes: [UInt8] {
        if case .encrypted(let id, _) = self { id.bytes } else { .init(repeating: 0, count: 16) }
    }
}

/// Verified envelope identity and bounded decoded payload: public-profile hashes
/// detect corruption, while encrypted-profile authentication verifies possession of the key.
public struct OpenedObjectV1: Sendable {
    public let kind: ProviderObjectKind
    public let locator: SegmentLocator
    public let payload: [UInt8]

    // Only the envelope implementation in this file may issue verified bytes.
    fileprivate init(kind: ProviderObjectKind, locator: SegmentLocator, payload: [UInt8]) {
        self.kind = kind; self.locator = locator; self.payload = payload
    }
}

public enum ObjectEnvelopeV1 {
    static let magic = Array("NVSEG1\r\n".utf8)
    static let domain = Array("NV object envelope\0v1\0".utf8)

    static func objectKey(_ key: SymmetricKey, collection: CollectionID, keyID: CollectionKeyID,
                          kind: ProviderObjectKind, writer: WriterEpoch) throws -> SymmetricKey {
        guard key.bitCount == 256 else { throw CanonicalEncodingError.invalidPayload }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: collection.bytes + keyID.bytes,
            info: Array("NV object key\0v1\0".utf8) + [kind.rawValue] + writer.bytes + [UInt8](repeating: 0, count: 16),
            outputByteCount: 32)
    }

/// Seals immutable bytes for publication and exact retransmission. The runtime
    /// allocates epochs/sequences and retains this result across ambiguous completions.
    public static func seal(payload: [UInt8], kind: ProviderObjectKind, collection: CollectionID,
                            writer: WriterEpoch, sequence: UInt64, protection: ObjectProtectionV1,
                            compress: Bool = false) throws -> [UInt8] {
        guard UInt64(payload.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        let compression: ObjectCompressionV1 = compress ? .zstd : .none
        let encoded = try compress ? ZstdFrameV1.compress(payload) : payload
        guard UInt64(encoded.count) <= ObjectLimitsV1.encodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        let nonce: AES.GCM.Nonce? = protection.suite == 1 ? AES.GCM.Nonce() : nil
        let nonceBytes = nonce.map { Array($0) } ?? [UInt8](repeating: 0, count: 12)
        var header = magic + bigEndianBytes(UInt16(1)) + [kind.rawValue, protection.suite] + bigEndianBytes(UInt32(124))
        header += collection.bytes + protection.keyIDBytes + writer.bytes + bigEndianBytes(sequence)
        header += [UInt8](repeating: 0, count: 16) + [compression.rawValue] + [UInt8](repeating: 0, count: 7)
        header += bigEndianBytes(UInt64(encoded.count)) + bigEndianBytes(UInt64(payload.count)) + nonceBytes
        switch protection {
        case .publicHash: return header + encoded + Array(SHA256.hash(data: domain + header + encoded))
        case .encrypted(let id, let key):
            let derived = try objectKey(key, collection: collection, keyID: id, kind: kind, writer: writer)
            let box = try AES.GCM.seal(encoded, using: derived, nonce: nonce, authenticating: domain + header)
            return header + Array(box.ciphertext) + Array(box.tag)
        }
    }

    public static func open(_ bytes: [UInt8], collection: CollectionID, protection: ObjectProtectionV1,
                            expectedLocator: SegmentLocator? = nil) throws -> OpenedObjectV1 {
        guard bytes.count >= 124 + 16,
              UInt64(bytes.count) <= 124 + ObjectLimitsV1.encodedPayloadBytes + 32 else {
            throw CanonicalEncodingError.lengthLimit
        }
        var cursor = ByteCursor(bytes: bytes)
        guard try cursor.fixedBytes(8) == magic, try cursor.unsigned16() == 1,
              let kind = ProviderObjectKind(rawValue: try cursor.byte()) else { throw CanonicalEncodingError.unsupportedFormat }
        let suite = try cursor.byte()
        guard suite <= 1 else { throw CanonicalEncodingError.unsupportedFormat }
        guard try cursor.unsigned32() == 124 else { throw CanonicalEncodingError.invalidPayload }
        guard suite == protection.suite, try cursor.fixedBytes(16) == collection.bytes,
              try cursor.fixedBytes(16) == protection.keyIDBytes else { throw CanonicalEncodingError.wrongScope }
        let writer = try WriterEpoch(bytes: cursor.fixedBytes(16))
        let sequence = try cursor.unsigned64()
        guard try cursor.fixedBytes(16) == [UInt8](repeating: 0, count: 16) else { throw CanonicalEncodingError.wrongScope }
        guard let compression = ObjectCompressionV1(rawValue: try cursor.byte()) else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        guard try cursor.fixedBytes(7) == [UInt8](repeating: 0, count: 7) else { throw CanonicalEncodingError.invalidPayload }
        let encodedLength = try cursor.unsigned64(), plainLength = try cursor.unsigned64()
        guard encodedLength <= ObjectLimitsV1.encodedPayloadBytes, plainLength <= ObjectLimitsV1.decodedPayloadBytes,
              encodedLength + (suite == 0 ? 32 : 16) == UInt64(cursor.remaining - 12) else { throw CanonicalEncodingError.lengthLimit }
        let nonce = try cursor.fixedBytes(12)
        if suite == 0 && nonce != [UInt8](repeating: 0, count: 12) { throw CanonicalEncodingError.invalidPayload }
        if compression == .none && encodedLength != plainLength { throw CanonicalEncodingError.invalidPayload }
        let locator = try SegmentLocator(writerEpoch: writer, sequence: sequence, segmentID: SegmentID(bytes: Array(SHA256.hash(data: bytes))))
        if let expectedLocator, expectedLocator != locator { throw CanonicalEncodingError.identityMismatch }
        let encoded = try cursor.fixedBytes(Int(encodedLength))
        let clear: [UInt8]
        switch protection {
        case .publicHash:
            guard try cursor.fixedBytes(32) == Array(SHA256.hash(data: domain + bytes.prefix(124) + encoded)) else { throw CanonicalEncodingError.authenticationFailure }
            clear = encoded
        case .encrypted(let id, let key):
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: encoded, tag: cursor.fixedBytes(16))
            let derived = try objectKey(key, collection: collection, keyID: id, kind: kind, writer: writer)
            do { clear = Array(try AES.GCM.open(box, using: derived, authenticating: domain + bytes.prefix(124))) }
            catch { throw CanonicalEncodingError.authenticationFailure }
        }
        try cursor.requireEnd()
        let payload = try compression == .zstd ? ZstdFrameV1.expand(clear, count: Int(plainLength)) : clear
        return OpenedObjectV1(kind: kind, locator: locator, payload: payload)
    }

}
