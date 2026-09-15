import Crypto

/// Incrementally hashes the birth-sorted initial note set for its import commitment.
public struct InitialValuesHasherV1 {
    private var hash = SHA256()
    private let expectedCount: UInt64
    private var count: UInt64 = 0
    private var lastBirth: NoteBirth?

    public init(expectedCount: UInt64) {
        self.expectedCount = expectedCount
        hash.update(data: Array("NV initial values\0v1\0".utf8) + bigEndianBytes(expectedCount))
    }
    public mutating func append(birth: NoteBirth, value: PlaintextNoteValue) throws {
        guard count < expectedCount else { throw CanonicalEncodingError.invalidPayload }
        if let lastBirth, !lastBirth.bytes.lexicographicallyPrecedes(birth.bytes) { throw CanonicalEncodingError.noncanonicalSet }
        hash.update(data: birth.bytes + bigEndianBytes(UInt32(value.encodedByteCount)))
        hash.update(data: value.encodedV1())
        count += 1; lastBirth = birth
    }
    public func finish() throws -> InitialValuesDigest {
        guard count == expectedCount else { throw CanonicalEncodingError.invalidPayload }
        return try InitialValuesDigest(bytes: Array(hash.finalize()))
    }
}

public struct InitialSnapshotRowV1: Equatable, Sendable {
    public let birth: NoteBirth
    public let value: PlaintextNoteValue
    public let importReference: OperationReference
    public init(birth: NoteBirth, value: PlaintextNoteValue, importReference: OperationReference) throws {
        guard case .external = importReference else { throw CanonicalEncodingError.invalidReference }
        self.birth = birth; self.value = value; self.importReference = importReference
    }
}

/// An indexed page of birth-sorted initial values and their exact Import references.
/// Bootstrap validation checks these rows against reconstructed import history.
public struct InitialSnapshotPageV1: Equatable, Sendable {
    public let importID: ImportID
    public let index: UInt32
    public let dependencies: DependencyLocatorTable
    public let rows: [InitialSnapshotRowV1]

    public init(importID: ImportID, index: UInt32, dependencies: DependencyLocatorTable,
                rows: [InitialSnapshotRowV1]) throws {
        guard !rows.isEmpty else { throw CanonicalEncodingError.invalidPayload }
        let sorted = rows.sorted { $0.birth.bytes.lexicographicallyPrecedes($1.birth.bytes) }
        var size: UInt64 = 8 + 2 + 16 + 4 + 4 + 56 * UInt64(dependencies.entries.count) + 4
        for i in sorted.indices {
            if i > 0 && sorted[i - 1].birth == sorted[i].birth { throw CanonicalEncodingError.noncanonicalSet }
            size += 16 + sorted[i].value.encodedByteCount + sorted[i].importReference.encodedByteCount
            guard size <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
            if case .external(let locator, _, _) = sorted[i].importReference { _ = try dependencies.index(of: locator) }
        }
        self.importID = importID; self.index = index; self.dependencies = dependencies; self.rows = sorted
    }

    public func encodedV1() throws -> [UInt8] {
        var bytes = Array("NVSPG1\r\n".utf8) + bigEndianBytes(UInt16(1)) + importID.bytes + bigEndianBytes(index)
        bytes += dependencies.encodedV1() + bigEndianBytes(UInt32(rows.count))
        for row in rows {
            bytes += row.birth.bytes + row.value.encodedV1()
            bytes += try row.importReference.encoded(dependencies: dependencies)
        }
        return bytes
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == Array("NVSPG1\r\n".utf8), try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        let id = try ImportID(bytes: c.fixedBytes(16)), index = try c.unsigned32()
        let dependencies = try DependencyLocatorTable.decode(&c), count = try c.count(minimumElementBytes: 86)
        var rows: [InitialSnapshotRowV1] = []
        for _ in 0..<count {
            rows.append(try InitialSnapshotRowV1(birth: NoteBirth(bytes: c.fixedBytes(16)),
                value: PlaintextNoteValue.decode(&c), importReference: OperationReference.decode(&c, dependencies: dependencies)))
        }
        try c.requireEnd()
        let result = try Self(importID: id, index: index, dependencies: dependencies, rows: rows)
        guard rows == result.rows else { throw CanonicalEncodingError.noncanonicalSet }
        return result
    }
}

public struct InitialSnapshotPageReferenceV1: Equatable, Sendable {
    public let index: UInt32
    public let locator: SegmentLocator
    public let rowCount: UInt32
    public init(index: UInt32, locator: SegmentLocator, rowCount: UInt32) {
        self.index = index; self.locator = locator; self.rowCount = rowCount
    }
}

public struct InitialSnapshotRootV1: Equatable, Sendable {
    public let importID: ImportID
    public let initialCount: UInt64
    public let digest: InitialValuesDigest
    public let dependencies: DependencyLocatorTable
    public let completion: OperationReference
    public let frontier: [OperationReference]
    public let pages: [InitialSnapshotPageReferenceV1]

    public init(importID: ImportID, initialCount: UInt64, digest: InitialValuesDigest,
                dependencies: DependencyLocatorTable, completion: OperationReference,
                frontier: [OperationReference], pages: [InitialSnapshotPageReferenceV1]) throws {
        guard !frontier.isEmpty, case .external = completion else { throw CanonicalEncodingError.invalidReference }
        let refs = try frontier.map { ref -> (OperationReference, OperationID) in
            guard case .external(let locator, _, let id) = ref else { throw CanonicalEncodingError.invalidReference }
            _ = try dependencies.index(of: locator)
            return (ref, id)
        }.sorted { $0.1.bytes.lexicographicallyPrecedes($1.1.bytes) }
        guard Set(refs.map(\.1)).count == refs.count,
              refs.contains(where: { $0.0 == completion }) else { throw CanonicalEncodingError.noncanonicalSet }
        let size: UInt64 = 8 + 2 + 16 + 8 + 32 + 4 + 56 * UInt64(dependencies.entries.count)
            + 41 + 4 + 41 * UInt64(frontier.count) + 4 + 64 * UInt64(pages.count)
        guard size <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        var count: UInt64 = 0
        for (i, page) in pages.enumerated() {
            guard UInt64(page.index) == UInt64(i), page.rowCount > 0 else { throw CanonicalEncodingError.invalidPayload }
            count += UInt64(page.rowCount)
        }
        guard count == initialCount, Set(pages.map(\.locator)).count == pages.count else { throw CanonicalEncodingError.invalidPayload }
        self.importID = importID; self.initialCount = initialCount; self.digest = digest; self.dependencies = dependencies
        self.completion = completion; self.frontier = refs.map(\.0); self.pages = pages
    }

    public func encodedV1() throws -> [UInt8] {
        var bytes = Array("NVSRT1\r\n".utf8) + bigEndianBytes(UInt16(1)) + importID.bytes
        bytes += bigEndianBytes(initialCount) + digest.bytes + dependencies.encodedV1()
        bytes += try completion.encoded(dependencies: dependencies)
        bytes += bigEndianBytes(UInt32(frontier.count))
        for ref in frontier { bytes += try ref.encoded(dependencies: dependencies) }
        bytes += bigEndianBytes(UInt32(pages.count))
        for page in pages { bytes += bigEndianBytes(page.index) + page.locator.encodedV1() + bigEndianBytes(page.rowCount) }
        return bytes
    }

    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        var c = ByteCursor(bytes: bytes)
        guard try c.fixedBytes(8) == Array("NVSRT1\r\n".utf8), try c.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        let id = try ImportID(bytes: c.fixedBytes(16)), count = try c.unsigned64()
        let digest = try InitialValuesDigest(bytes: c.fixedBytes(32)), dependencies = try DependencyLocatorTable.decode(&c)
        let completion = try OperationReference.decode(&c, dependencies: dependencies)
        let frontCount = try c.count(minimumElementBytes: 41)
        var frontier: [OperationReference] = []
        for _ in 0..<frontCount { frontier.append(try OperationReference.decode(&c, dependencies: dependencies)) }
        let pageCount = try c.count(minimumElementBytes: 64)
        var pages: [InitialSnapshotPageReferenceV1] = []
        for _ in 0..<pageCount {
            pages.append(try InitialSnapshotPageReferenceV1(index: c.unsigned32(), locator: SegmentLocator.decode(&c), rowCount: c.unsigned32()))
        }
        try c.requireEnd()
        let result = try Self(importID: id, initialCount: count, digest: digest, dependencies: dependencies,
                              completion: completion, frontier: frontier, pages: pages)
        guard result.frontier == frontier else { throw CanonicalEncodingError.noncanonicalSet }
        return result
    }
}
