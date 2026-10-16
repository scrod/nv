import Crypto

/// SHA-256 of the exact encoded bytes of one plaintext projection.
public struct ProjectionBytesDigestV1: Equatable, Hashable, Sendable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw CanonicalEncodingError.invalidIdentifier }
        self.bytes = bytes
    }

    public static func compute(_ bytes: [UInt8]) -> Self {
        Self(digest: SHA256.hash(data: bytes))
    }

    private init(digest: SHA256.Digest) { bytes = Array(digest) }
}

/// Content semantics carried by the advisory projection stamp.
public enum ProjectionContentFormatV1: UInt16, Sendable {
    case plaintext = 1
}

/// Complete source claims for an ordinary, derived or automatically preserved value.
public enum ProjectionStateReferenceV1: Equatable, Sendable {
    case revision(StoredOperationReferenceV1)
    case derived(DerivedStateReferenceV1)
    case automatic(AutomaticSourceReferenceV1)

    var references: [OperationReference] {
        switch self {
        case .revision(let source): [source.reference]
        case .derived(let source): source.references
        case .automatic(let source): [source.revision]
        }
    }

    var encodedByteCount: UInt64 {
        switch self {
        case .revision: 42
        case .derived(let source): source.encodedByteCount
        case .automatic(let source): 1 + source.encodedByteCount
        }
    }

    func encoded(_ dependencies: DependencyLocatorTable) throws -> [UInt8] {
        switch self {
        case .revision(let source): return try [1] + source.reference.encoded(dependencies: dependencies)
        case .derived(let source): return try source.encodedV1(dependencies: dependencies, earlierOperations: [])
        case .automatic(let source): return try [2] + source.encoded(dependencies)
        }
    }
}

/// A complete bounded stamp, or the explicit omission of an oversized source claim.
public enum ProjectionStampPreparationV1: Equatable, Sendable {
    case stamp(ProjectionStampV1)
    case omittedOversized
}

/// Canonical advisory claims supplied to history and current-file association checks.
public struct ProjectionStampV1: Equatable, Sendable {
    public static let attributeName = "org.notationalvelocity.projection#S"
    public static let maximumBytes = 4_096
    private static let magic = Array("NVPRJ1\r\n".utf8)

    public let collection: CollectionID
    public let birth: NoteBirth
    public let format: ProjectionContentFormatV1
    public let digest: ProjectionBytesDigestV1
    public let state: ProjectionStateReferenceV1
    public let dependencies: DependencyLocatorTable

    public init(profile: CollectionProfileV1, collection: CollectionID, birth: NoteBirth,
                format: ProjectionContentFormatV1, digest: ProjectionBytesDigestV1,
                state: ProjectionStateReferenceV1) throws {
        guard profile == .plaintextFiles else { throw CanonicalEncodingError.wrongScope }
        let references = state.references
        for reference in references {
            guard case .external = reference else {
                throw CanonicalEncodingError.invalidReference
            }
        }
        if case .automatic(let source) = state {
            guard try source.key.birth() == birth else { throw CanonicalEncodingError.invalidReference }
        }
        guard 80 + state.encodedByteCount <= UInt64(Self.maximumBytes) else {
            throw CanonicalEncodingError.lengthLimit
        }
        let locators = Set(references.compactMap { reference -> SegmentLocator? in
            if case .external(let locator, _, _) = reference { locator } else { nil }
        })
        let size = 80 + UInt64(locators.count) * 56 + state.encodedByteCount
        guard size <= UInt64(Self.maximumBytes) else { throw CanonicalEncodingError.lengthLimit }
        self.collection = collection; self.birth = birth; self.format = format
        self.digest = digest; self.state = state
        dependencies = try DependencyLocatorTable(Array(locators))
    }

    /// Preserves the complete source set while classifying optional size-based omission.
    public static func prepare(profile: CollectionProfileV1, collection: CollectionID, birth: NoteBirth,
                               format: ProjectionContentFormatV1, digest: ProjectionBytesDigestV1,
                               state: ProjectionStateReferenceV1) throws -> ProjectionStampPreparationV1 {
        do {
            return try .stamp(Self(profile: profile, collection: collection, birth: birth,
                                   format: format, digest: digest, state: state))
        } catch CanonicalEncodingError.lengthLimit { return .omittedOversized }
    }

    public func encodedV1() throws -> [UInt8] {
        var bytes = Self.magic + bigEndianBytes(UInt16(1)) + collection.bytes + birth.bytes
        bytes += bigEndianBytes(format.rawValue) + digest.bytes + dependencies.encodedV1()
        bytes += try state.encoded(dependencies)
        return bytes
    }

    public static func decodeV1(_ bytes: [UInt8], profile: CollectionProfileV1) throws -> Self {
        guard profile == .plaintextFiles else { throw CanonicalEncodingError.wrongScope }
        guard bytes.count <= maximumBytes else { throw CanonicalEncodingError.lengthLimit }
        var cursor = ByteCursor(bytes: bytes)
        guard try cursor.fixedBytes(8) == magic, try cursor.unsigned16() == 1 else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        let collection = try CollectionID(bytes: cursor.fixedBytes(16))
        let birth = try NoteBirth(bytes: cursor.fixedBytes(16))
        guard let format = try ProjectionContentFormatV1(rawValue: cursor.unsigned16()) else {
            throw CanonicalEncodingError.unsupportedFormat
        }
        let digest = try ProjectionBytesDigestV1(bytes: cursor.fixedBytes(32))
        let dependencies = try DependencyLocatorTable.decode(&cursor)
        let tag = try cursor.byte()
        let state: ProjectionStateReferenceV1
        switch tag {
        case 1:
            guard case .external(let locator, let index, let id) = try OperationReference.decode(&cursor, dependencies: dependencies) else {
                throw CanonicalEncodingError.invalidReference
            }
            state = .revision(.init(locator: locator, index: index, id: id))
        case 2: state = try .automatic(.decode(&cursor, dependencies: dependencies))
        case 3, 4: state = try .derived(.decode(&cursor, dependencies: dependencies, earlierOperations: [], tag: tag))
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
        try cursor.requireEnd()
        let result = try Self(profile: profile, collection: collection, birth: birth,
                              format: format, digest: digest, state: state)
        guard result.dependencies == dependencies else { throw CanonicalEncodingError.noncanonicalSet }
        return result
    }
}
