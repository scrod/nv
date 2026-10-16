import Foundation

/// Byte-exact spelling of a structurally valid direct-child projection filename.
/// Filesystem representability and current occupancy are checked by the rooted adapter.
public struct ProjectionLeafNameV1: Equatable, Hashable, Sendable {
    public let spelling: ExactUTF8

    public init(_ spelling: ExactUTF8) throws {
        let bytes = spelling.bytes
        guard !bytes.isEmpty, !bytes.contains(0), !bytes.contains(47),
              bytes != [46], bytes != [46, 46] else {
            throw CanonicalEncodingError.invalidPayload
        }
        let name = spelling.string
        for reserved in ["NV Data", "Notes & Settings", "Interim Note-Changes"] {
            guard name.compare(reserved, options: .caseInsensitive) != .orderedSame else {
                throw CanonicalEncodingError.invalidPayload
            }
        }
        self.spelling = spelling
    }

    /// Separates exact spelling from NV's case-insensitive filename collision comparison.
    public enum Comparison: Equatable, Sendable {
        case exact, alias, distinct
    }

    public func compare(to other: Self) -> Comparison {
        if spelling == other.spelling { return .exact }
        return spelling.string.compare(other.spelling.string, options: .caseInsensitive) == .orderedSame
            ? .alias : .distinct
    }
}

/// Portable description of the intended filename, format and exact encoded output.
/// History and physical consumers establish applicability in their own checked context.
public struct ProjectionDescriptorV1: Equatable, Sendable {
    private static let magic = Array("NVPRD1\r\n".utf8)
    public let filename: ProjectionLeafNameV1
    public let format: ProjectionContentFormatV1
    public let digest: ProjectionBytesDigestV1

    public init(profile: CollectionProfileV1, filename: ProjectionLeafNameV1,
                format: ProjectionContentFormatV1, digest: ProjectionBytesDigestV1) throws {
        guard profile == .plaintextFiles else { throw CanonicalEncodingError.wrongScope }
        guard 48 + UInt64(filename.spelling.bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        self.filename = filename; self.format = format; self.digest = digest
    }

    public func encodedV1() -> [UInt8] {
        Self.magic + bigEndianBytes(UInt16(1)) + filename.spelling.encodedV1()
            + bigEndianBytes(format.rawValue) + digest.bytes
    }

    public static func decodeV1(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        guard profile == .plaintextFiles else { throw CanonicalEncodingError.wrongScope }
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        var cursor = ByteCursor(bytes: bytes)
        guard try cursor.fixedBytes(8) == magic, try cursor.unsigned16() == 1 else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        let filename = try ProjectionLeafNameV1(cursor.text())
        guard let format = try ProjectionContentFormatV1(rawValue: cursor.unsigned16()) else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        let digest = try ProjectionBytesDigestV1(bytes: cursor.fixedBytes(32))
        try cursor.requireEnd()
        return try Self(profile: profile, filename: filename, format: format, digest: digest)
    }
}
