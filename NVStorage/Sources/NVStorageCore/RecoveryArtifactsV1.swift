import Crypto

public struct LocalAssociationID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct LocalStoreID: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

public struct SelectionGeneration: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws { self.bytes = try identifierBytes(bytes, count: 16) }
}

/// Checksummed selection of a local store for an association and generation.
/// Activation uses the expected-generation Foundation replacement protocol.
public struct SelectedStoreRecordV1: Equatable, Sendable {
    public let association: LocalAssociationID
    public let store: LocalStoreID
    public let generation: SelectionGeneration
    static let magic = Array("NVSEL1\r\n".utf8)
    static let domain = Array("NV local selection\0v1\0".utf8)
    public static let byteCount = 90

    public init(association: LocalAssociationID, store: LocalStoreID, generation: SelectionGeneration) {
        self.association = association
        self.store = store
        self.generation = generation
    }

    public func encodedV1() -> [UInt8] {
        let header = Self.magic + bigEndianBytes(UInt16(1)) + association.bytes + store.bytes + generation.bytes
        return header + Array(SHA256.hash(data: Self.domain + header))
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard bytes.count == byteCount else { throw CanonicalEncodingError.invalidPayload }
        var cursor = ByteCursor(bytes: bytes)
        guard try cursor.fixedBytes(8) == magic, try cursor.unsigned16() == 1 else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        let result = try Self(association: LocalAssociationID(bytes: cursor.fixedBytes(16)),
                              store: LocalStoreID(bytes: cursor.fixedBytes(16)),
                              generation: SelectionGeneration(bytes: cursor.fixedBytes(16)))
        guard try cursor.fixedBytes(32) == Array(SHA256.hash(data: domain + bytes.prefix(58))) else {
            throw CanonicalEncodingError.identityMismatch
        }
        return result
    }
}

/// Bech32m (BIP-350), HRP `nvrk`, version symbol 1, exactly 32 key bytes.
/// Explicit secret-key export/import with a checksum for detecting transcription errors.
/// The decoded key is subsequently checked against the selected collection's bootstrap.
public enum RecoveryKeyV1 {
    static let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    static let prefix = Array("nvrk".utf8)
    static let expandedPrefix = prefix.map { $0 >> 5 } + [0] + prefix.map { $0 & 31 }

    static func polymod(_ symbols: [UInt8]) -> UInt32 {
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var check: UInt32 = 1
        for symbol in symbols {
            let high = check >> 25
            check = ((check & 0x1ffffff) << 5) ^ UInt32(symbol)
            for i in 0..<5 where (high >> i) & 1 != 0 { check ^= generators[i] }
        }
        return check
    }

    /// Explicit export: callers must treat the returned string as a secret.
    public static func encode(_ key: SymmetricKey) throws -> String {
        guard key.bitCount == 256 else { throw CanonicalEncodingError.invalidPayload }
        var symbols: [UInt8] = [1]
        // The checked 256-bit key supplies all 32 bytes throughout this synchronous borrow.
        unsafe key.withUnsafeBytes { bytes in
            for start in stride(from: 0, to: 256, by: 5) {
                var value: UInt8 = 0
                for bit in start..<(start + 5) {
                    value <<= 1
                    if bit < 256 { unsafe value |= (bytes[bit / 8] >> (7 - bit % 8)) & 1 }
                }
                symbols.append(value)
            }
        }
        let check = polymod(expandedPrefix + symbols + [0, 0, 0, 0, 0, 0]) ^ 0x2bc830a3
        for shift in stride(from: 25, through: 0, by: -5) {
            symbols.append(UInt8((check >> shift) & 31))
        }
        return String(decoding: prefix + [49] + symbols.map { alphabet[Int($0)] }, as: UTF8.self)
    }

    public static func decode(_ text: String) throws -> SymmetricKey {
        // Bound before allocating a normalized copy; only ASCII paste whitespace is ignored.
        guard text.utf8.count <= 1024 else { throw CanonicalEncodingError.lengthLimit }
        let raw = text.utf8.filter { ![9, 10, 13, 32].contains($0) }
        guard raw.count == 64, raw.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              !(raw.contains(where: { (65...90).contains($0) }) && raw.contains(where: { (97...122).contains($0) })) else {
            throw CanonicalEncodingError.invalidPayload
        }
        let lower = raw.map { (65...90).contains($0) ? $0 + 32 : $0 }
        guard Array(lower.prefix(5)) == prefix + [49] else { throw CanonicalEncodingError.unsupportedFormat }
        let symbols = try lower.dropFirst(5).map { character -> UInt8 in
            guard let index = alphabet.firstIndex(of: character) else { throw CanonicalEncodingError.invalidPayload }
            return UInt8(index)
        }
        guard polymod(expandedPrefix + symbols) == 0x2bc830a3 else { throw CanonicalEncodingError.identityMismatch }
        guard symbols[0] == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        guard symbols[52] & 15 == 0 else { throw CanonicalEncodingError.invalidPayload }
        var bytes = [UInt8](repeating: 0, count: 32)
        for bit in 0..<256 {
            bytes[bit / 8] |= ((symbols[1 + bit / 5] >> (4 - bit % 5)) & 1) << (7 - bit % 8)
        }
        return SymmetricKey(data: bytes)
    }
}
