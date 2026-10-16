import Foundation

/// Requested NSString encoding identifier captured with the note's output settings.
public struct ProjectionEncodingV1: Equatable, Sendable {
    public let rawValue: UInt64
    public static let utf8 = Self(unchecked: 4)
    public init(rawValue: UInt64) throws {
        guard rawValue > 0 else { throw CanonicalEncodingError.invalidPayload }
        self.rawValue = rawValue
    }
    private init(unchecked: UInt64) { rawValue = unchecked }
}

/// Exact output of the legacy lossless-request/UTF-8-promotion policy.
public struct PreparedProjectionTextV1: Sendable {
    public let encoding: ProjectionEncodingV1
    public let bytes: [UInt8]
    private init(encoding: ProjectionEncodingV1, bytes: [UInt8]) {
        self.encoding = encoding; self.bytes = bytes
    }
    public static func prepare(_ body: ExactUTF8, requested: ProjectionEncodingV1) -> Self {
        if requested == .utf8 { return Self(encoding: .utf8, bytes: body.bytes) }
        if let native = UInt(exactly: requested.rawValue),
           let data = (body.string as NSString).data(using: native, allowLossyConversion: false) {
            return Self(encoding: requested, bytes: Array(data))
        }
        return Self(encoding: .utf8, bytes: body.bytes)
    }
}
