// Canonical scalar encodings. See docs/impl-proposal-5/plan/first-save-reopen-contract.md.
// Bounded byte decoding and canonical encodings for exact text and display dates.
import Foundation

public enum CanonicalEncodingError: Error, Equatable, Sendable {
    case truncated
    case trailingBytes
    case lengthLimit
    case invalidUTF8
    case invalidDate
    case noncanonicalDate
    case noncanonicalLabels
    case unsupportedFormat
    case invalidIdentifier
    case invalidDiscriminant
    case noncanonicalSet
    case invalidReference
    case invalidOperation
    case identityMismatch
    case invalidAction
    case invalidPayload
    case wrongScope
    case authenticationFailure
    case keyDerivationFailure
// The referenced evidence is unavailable; park dependent work until it arrives.
    case missingDependency
}

public enum ObjectLimitsV1 {
    public static let decodedPayloadBytes: UInt64 = 64 * 1024 * 1024
    public static let encodedPayloadBytes: UInt64 = decodedPayloadBytes + 64 * 1024
}

// Reads bounded fields from an owned byte buffer, checking lengths and element
// counts against the remaining input before allocating decoded values.
struct ByteCursor {
    let bytes: [UInt8]
    private(set) var offset = 0
    var remaining: Int { bytes.count - offset }

    mutating func byte() throws -> UInt8 {
        guard remaining > 0 else { throw CanonicalEncodingError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func fixedBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw CanonicalEncodingError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func unsigned16() throws -> UInt16 {
        let high = try byte()
        return try UInt16(high) << 8 | UInt16(byte())
    }

    mutating func unsigned32() throws -> UInt32 {
        guard remaining >= 4 else { throw CanonicalEncodingError.truncated }
        var result: UInt32 = 0
        for _ in 0..<4 {
            result = (result << 8) | UInt32(bytes[offset])
            offset += 1
        }
        return result
    }

    mutating func unsigned64() throws -> UInt64 {
        guard remaining >= 8 else { throw CanonicalEncodingError.truncated }
        var result: UInt64 = 0
        for _ in 0..<8 {
            result = (result << 8) | UInt64(bytes[offset])
            offset += 1
        }
        return result
    }

    mutating func lengthPrefixedBytes() throws -> [UInt8] {
        let count = UInt64(try unsigned32())
        guard count <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        guard count <= UInt64(remaining) else { throw CanonicalEncodingError.truncated }
        let end = offset + Int(count) // Bounded by the already allocated input.
        let value = Array(bytes[offset..<end])
        offset = end
        return value
    }

    mutating func count(minimumElementBytes: Int) throws -> Int {
        let count = UInt64(try unsigned32())
        guard count <= UInt64(remaining / minimumElementBytes) else {
            throw CanonicalEncodingError.truncated
        }
        return Int(count)
    }

    func requireEnd() throws {
        guard remaining == 0 else { throw CanonicalEncodingError.trailingBytes }
    }

    mutating func text() throws -> ExactUTF8 {
        try ExactUTF8(bytes: lengthPrefixedBytes())
    }

    mutating func date() throws -> DisplayDate {
        let bits = try unsigned64()
        guard bits != 0x8000_0000_0000_0000 else {
            throw CanonicalEncodingError.noncanonicalDate
        }
        return try DisplayDate(secondsSinceReferenceDate: Double(bitPattern: bits))
    }
}

func bigEndianBytes(_ value: UInt16) -> [UInt8] {
    [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
}

func bigEndianBytes(_ value: UInt32) -> [UInt8] {
    (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

func bigEndianBytes(_ value: UInt64) -> [UInt8] {
    (0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
}

/// Validated UTF-8 spelling with byte-exact equality and hashing.
/// Empty strings, embedded NUL and distinct canonically equivalent spellings survive.
public struct ExactUTF8: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            throw CanonicalEncodingError.invalidUTF8
        }
        self.bytes = bytes
    }

/// Decodes text for presentation; protocol identity uses the stored UTF-8 bytes.
    public var string: String { String(decoding: bytes, as: UTF8.self) }

    public func encodedV1() -> [UInt8] {
        bigEndianBytes(UInt32(bytes.count)) + bytes
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes + 4 else {
            throw CanonicalEncodingError.lengthLimit
        }
        var cursor = ByteCursor(bytes: bytes)
        let value = try Self(bytes: cursor.lengthPrefixedBytes())
        try cursor.requireEnd()
        return value
    }
}

/// Finite binary64 seconds from 2001-01-01T00:00:00Z, retaining legacy date precision.
/// Preserves note creation/modification timestamps for display.
public struct DisplayDate: Equatable, Hashable, Sendable {
    public let secondsSinceReferenceDate: Double

    public init(secondsSinceReferenceDate seconds: Double) throws {
        guard seconds.isFinite else { throw CanonicalEncodingError.invalidDate }
        self.secondsSinceReferenceDate = seconds == 0 ? 0 : seconds
    }

    public func encodedV1() -> [UInt8] {
        bigEndianBytes(secondsSinceReferenceDate.bitPattern)
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        var cursor = ByteCursor(bytes: bytes)
        let value = try cursor.date()
        try cursor.requireEnd()
        return value
    }
}
