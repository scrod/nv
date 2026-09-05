/// Canonical stored label tokens, preserving each label's exact spelling.
/// Tokens retain spelling. Ordering and equality use exact UTF-8 bytes.
public struct CanonicalLabels: Equatable, Hashable, Sendable {
    public let entries: [ExactUTF8]
    let encodedByteCount: UInt64

    public init(_ entries: [ExactUTF8]) throws {
        var size: UInt64 = 4
        for entry in entries {
            guard !entry.bytes.isEmpty else { throw CanonicalEncodingError.noncanonicalLabels }
            size += 4 + UInt64(entry.bytes.count)
            guard size <= ObjectLimitsV1.decodedPayloadBytes else {
                throw CanonicalEncodingError.lengthLimit
            }
        }
        let sorted = entries.sorted { $0.bytes.lexicographicallyPrecedes($1.bytes) }
        for index in sorted.indices.dropFirst() {
            guard sorted[index - 1] != sorted[index] else {
                throw CanonicalEncodingError.noncanonicalLabels
            }
        }
        self.entries = sorted
        self.encodedByteCount = size
    }

    func encodedV1() -> [UInt8] {
        var bytes = bigEndianBytes(UInt32(entries.count))
        for entry in entries { bytes += entry.encodedV1() }
        return bytes
    }

    static func decode(_ cursor: inout ByteCursor) throws -> Self {
        let count = UInt64(try cursor.unsigned32())
        // Each nonempty token needs at least four length bytes and one text byte.
        guard count <= UInt64(cursor.remaining / 5) else {
            throw CanonicalEncodingError.truncated
        }
        var entries: [ExactUTF8] = []
        for _ in 0..<count {
            let next = try cursor.text()
            guard !next.bytes.isEmpty else { throw CanonicalEncodingError.noncanonicalLabels }
            if let previous = entries.last {
                guard previous.bytes.lexicographicallyPrecedes(next.bytes) else {
                    throw CanonicalEncodingError.noncanonicalLabels
                }
            }
            entries.append(next)
        }
        return try Self(entries)
    }
}

/// A complete stored note value: title, body, labels and display timestamps.
public struct PlaintextNoteValue: Equatable, Hashable, Sendable {
    private static let formatTag: UInt8 = 1
    public let title: ExactUTF8
    public let body: ExactUTF8
    public let labels: CanonicalLabels
    public let created: DisplayDate
    public let modified: DisplayDate
    let encodedByteCount: UInt64

    /// Content comparison for the reducer; dates remain in exact stored-value equality.
    /// The reducer must separately keep birth creation time and fold display modification time.
    public func hasSameEditableFields(as other: Self) -> Bool {
        title == other.title && body == other.body && labels == other.labels
    }

    public init(title: ExactUTF8, body: ExactUTF8, labels: CanonicalLabels,
                created: DisplayDate, modified: DisplayDate) throws {
        let size = 1 + 4 + UInt64(title.bytes.count) + 4 + UInt64(body.bytes.count)
            + labels.encodedByteCount + 16
        guard size <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        self.title = title
        self.body = body
        self.labels = labels
        self.created = created
        self.modified = modified
        self.encodedByteCount = size
    }

    public func encodedV1() -> [UInt8] {
        var bytes: [UInt8] = [Self.formatTag]
        bytes += title.encodedV1()
        bytes += body.encodedV1()
        bytes += labels.encodedV1()
        bytes += created.encodedV1()
        bytes += modified.encodedV1()
        return bytes
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else {
            throw CanonicalEncodingError.lengthLimit
        }
        var cursor = ByteCursor(bytes: bytes)
        let value = try decode(&cursor)
        try cursor.requireEnd()
        return value
    }

    static func decode(_ cursor: inout ByteCursor) throws -> Self {
        guard try cursor.byte() == Self.formatTag else { throw CanonicalEncodingError.unsupportedFormat }
        return try Self(title: cursor.text(), body: cursor.text(),
                             labels: CanonicalLabels.decode(&cursor),
                             created: cursor.date(), modified: cursor.date())
    }
}
