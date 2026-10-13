import Crypto

/// Exact byte coverage of one immutable data or index page.
public struct SnapshotPageRangeV1: Equatable, Sendable {
    public let locator: SegmentLocator
    public let offset: UInt64
    public let byteCount: UInt64
    public init(locator: SegmentLocator, offset: UInt64, byteCount: UInt64) throws {
        guard byteCount > 0, !offset.addingReportingOverflow(byteCount).overflow else { throw CanonicalEncodingError.lengthLimit }
        self.locator = locator; self.offset = offset; self.byteCount = byteCount
    }
    var encoded: [UInt8] { locator.encodedV1() + bigEndianBytes(offset) + bigEndianBytes(byteCount) }
    static func decode(_ cursor: inout ByteCursor) throws -> Self {
        try Self(locator: SegmentLocator.decode(&cursor), offset: cursor.unsigned64(), byteCount: cursor.unsigned64())
    }
}

/// Bounded leaves and index nodes for a complete snapshot state stream.
public struct GeneralSnapshotPageV1: Equatable, Sendable {
    public enum Contents: Equatable, Sendable {
        case data(offset: UInt64, bytes: [UInt8])
        case index([SnapshotPageRangeV1])
    }
    public let contents: Contents
    public init(_ contents: Contents) throws {
        switch contents {
        case .data(let offset, let bytes):
            guard !bytes.isEmpty, UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes - 23,
                  !offset.addingReportingOverflow(UInt64(bytes.count)).overflow else { throw CanonicalEncodingError.lengthLimit }
        case .index(let children):
            guard !children.isEmpty, UInt64(children.count) <= (ObjectLimitsV1.decodedPayloadBytes - 15) / 72 else { throw CanonicalEncodingError.lengthLimit }
            var end = children[0].offset
            var seen: Set<SegmentLocator> = []
            for child in children {
                guard child.offset == end, seen.insert(child.locator).inserted else { throw CanonicalEncodingError.noncanonicalSet }
                end = child.offset + child.byteCount
            }
        }
        self.contents = contents
    }
    public var offset: UInt64 {
        switch contents { case .data(let offset, _): offset; case .index(let children): children[0].offset }
    }
    public var byteCount: UInt64 {
        switch contents {
        case .data(_, let bytes): UInt64(bytes.count)
        case .index(let children): children.last!.offset + children.last!.byteCount - children[0].offset
        }
    }
    public func encodedV1() -> [UInt8] {
        var bytes = Array("NVGPG1\r\n".utf8) + bigEndianBytes(UInt16(1))
        switch contents {
        case .data(let offset, let data): bytes += [0] + bigEndianBytes(offset) + bigEndianBytes(UInt32(data.count)) + data
        case .index(let children):
            bytes += [1] + bigEndianBytes(UInt32(children.count))
            for child in children { bytes += child.encoded }
        }
        return bytes
    }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        guard UInt64(bytes.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        var cursor = ByteCursor(bytes: bytes)
        guard try cursor.fixedBytes(8) == Array("NVGPG1\r\n".utf8), try cursor.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        let result: Self
        switch try cursor.byte() {
        case 0: result = try Self(.data(offset: cursor.unsigned64(), bytes: cursor.lengthPrefixedBytes()))
        case 1:
            var children: [SnapshotPageRangeV1] = []
            for _ in 0..<(try cursor.count(minimumElementBytes: 72)) { children.append(try .decode(&cursor)) }
            result = try Self(.index(children))
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
        try cursor.requireEnd(); return result
    }
}

/// Canonical state-stream commitment, distinct from individual object identities.
public struct GeneralSnapshotDigestV1: Equatable, Sendable {
    public let bytes: [UInt8]
    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else { throw CanonicalEncodingError.invalidPayload }; self.bytes = bytes
    }
}

/// Canonical framing for logical state and retained snapshot dependencies.
private enum GeneralSnapshotFormatV1 {
    static let categoryCount = 8
    static let streamHeader = Array("NVGST1\r\n".utf8) + bigEndianBytes(UInt16(1))
    static let digestDomain = Array("NV general snapshot state\0v1\0".utf8)
}

/// Fixed-size snapshot claim with eight manifest counts and a state commitment.
public struct GeneralSnapshotRootV1: Equatable, Sendable {
    public let bootstrapSnapshot: SegmentLocator
    public let tree: SnapshotPageRangeV1
    public let counts: [UInt64]
    public let digest: GeneralSnapshotDigestV1
    public init(bootstrapSnapshot: SegmentLocator, tree: SnapshotPageRangeV1, counts: [UInt64], digest: GeneralSnapshotDigestV1) throws {
        guard tree.offset == 0, tree.byteCount >= 10, counts.count == GeneralSnapshotFormatV1.categoryCount, counts[1] > 0 else { throw CanonicalEncodingError.invalidPayload }
        var total: UInt64 = 0
        for count in counts {
            let sum = total.addingReportingOverflow(count)
            guard !sum.overflow, sum.partialValue <= (tree.byteCount - 10) / 5 else { throw CanonicalEncodingError.lengthLimit }
            total = sum.partialValue
        }
        self.bootstrapSnapshot = bootstrapSnapshot; self.tree = tree; self.counts = counts; self.digest = digest
    }
    public func encodedV1() -> [UInt8] {
        var bytes = Array("NVGRT1\r\n".utf8) + bigEndianBytes(UInt16(1)) + bigEndianBytes(UInt16(1))
        bytes += bootstrapSnapshot.encodedV1() + tree.encoded
        for count in counts { bytes += bigEndianBytes(count) }
        return bytes + digest.bytes
    }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        var cursor = ByteCursor(bytes: bytes)
        guard try cursor.fixedBytes(8) == Array("NVGRT1\r\n".utf8),
              try cursor.unsigned16() == 1,
              try cursor.unsigned16() == 1 else { throw CanonicalEncodingError.unsupportedFormat }
        let bootstrap = try SegmentLocator.decode(&cursor), tree = try SnapshotPageRangeV1.decode(&cursor)
        var counts: [UInt64] = []
        for _ in 0..<GeneralSnapshotFormatV1.categoryCount { counts.append(try cursor.unsigned64()) }
        let digest = try GeneralSnapshotDigestV1(bytes: cursor.fixedBytes(32))
        try cursor.requireEnd()
        return try Self(bootstrapSnapshot: bootstrap, tree: tree, counts: counts, digest: digest)
    }
}

/// Portable value and continuation-index claims at one operation frontier.
public enum GeneralSnapshotRecordV1: Equatable, Sendable {
    case current(CurrentNoteCellV1)
    case frontier(StoredOperationReferenceV1)
    case scope(ActionScopeV1, StoredActionReferenceV1)
    case deleted(NoteBirth, StoredOperationReferenceV1)
    case retired(DeterministicConflictIdentityV1)
    case disposition(OperationID)
    case restored(source: NoteBirth, deletion: ActionID, action: ActionID, birth: NoteBirth)

    public var tag: UInt8 {
        switch self { case .current: 1; case .frontier: 2; case .scope: 3; case .deleted: 4; case .retired: 5; case .disposition: 6; case .restored: 7 }
    }
    private static func scopeBytes(_ scope: ActionScopeV1) -> [UInt8] {
        switch scope { case .collection: [0]; case .note(let birth): [1] + birth.bytes }
    }
    var key: [UInt8] {
        switch self {
        case .current(let cell): [tag] + cell.birth.bytes
        case .frontier(let ref): [tag] + ref.id.bytes
        case .scope(let scope, let ref): [tag] + Self.scopeBytes(scope) + ref.id.bytes
        case .deleted(let birth, let ref): [tag] + birth.bytes + ref.id.bytes
        case .retired(let identity): [tag] + identity.encoded
        case .disposition(let id): [tag] + id.bytes
        case .restored(let source, let deletion, let action, let birth): [tag] + source.bytes + deletion.bytes + action.bytes + birth.bytes
        }
    }
    public func encodedV1() throws -> [UInt8] {
        let payload: [UInt8]
        switch self {
        case .current(let cell): payload = cell.encodedV1()
        case .frontier(let ref): payload = ref.encoded()
        case .scope(let scope, let ref): payload = Self.scopeBytes(scope) + ref.encoded()
        case .deleted(let birth, let ref): payload = birth.bytes + ref.encoded()
        case .retired(let identity): payload = identity.encoded
        case .disposition(let id): payload = id.bytes
        case .restored(let source, let deletion, let action, let birth): payload = source.bytes + deletion.bytes + action.bytes + birth.bytes
        }
        guard UInt64(payload.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        return [tag] + bigEndianBytes(UInt32(payload.count)) + payload
    }
    public static func decodeV1(_ bytes: [UInt8]) throws -> Self {
        var cursor = ByteCursor(bytes: bytes)
        let tag = try cursor.byte(), payload = try cursor.lengthPrefixedBytes()
        guard UInt64(payload.count) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
        try cursor.requireEnd(); return try decode(tag: tag, payload: payload)
    }
    static func decode(tag: UInt8, payload: [UInt8]) throws -> Self {
        var cursor = ByteCursor(bytes: payload)
        let result: Self
        switch tag {
        case 1: return try .current(CurrentNoteCellV1.decodeV1(payload))
        case 2: result = try .frontier(.decode(&cursor))
        case 3:
            let scope: ActionScopeV1
            switch try cursor.byte() { case 0: scope = .collection; case 1: scope = try .note(NoteBirth(bytes: cursor.fixedBytes(16))); default: throw CanonicalEncodingError.invalidDiscriminant }
            result = try .scope(scope, .decode(&cursor))
        case 4: result = try .deleted(NoteBirth(bytes: cursor.fixedBytes(16)), .decode(&cursor))
        case 5: result = try .retired(.decode(&cursor))
        case 6: result = try .disposition(OperationID(bytes: cursor.fixedBytes(32)))
        case 7: result = try .restored(source: NoteBirth(bytes: cursor.fixedBytes(16)), deletion: ActionID(bytes: cursor.fixedBytes(16)), action: ActionID(bytes: cursor.fixedBytes(16)), birth: NoteBirth(bytes: cursor.fixedBytes(16)))
        default: throw CanonicalEncodingError.invalidDiscriminant
        }
        try cursor.requireEnd(); return result
    }
    public var operationReferences: [StoredOperationReferenceV1] {
        switch self {
        case .frontier(let ref), .deleted(_, let ref): [ref]
        case .current(let cell):
            cell.represented + cell.heads + (cell.derived?.references.compactMap {
                if case .external(let locator, let index, let id) = $0 { StoredOperationReferenceV1(locator: locator, index: index, id: id) } else { nil }
            } ?? [])
        default: []
        }
    }
    public var actionReferences: [StoredActionReferenceV1] {
        switch self { case .scope(_, let ref): [ref]; case .current(let cell): cell.scopeFrontier; default: [] }
    }
}

public enum GeneralSnapshotError: Error, Equatable, Sendable {
    case missingObject(SegmentLocator)
    case invalidManifest, invalidState
}

/// Fully assembled profile-protected preview with complete pages and direct history references.
public struct GeneralSnapshotPreviewV1: Sendable {
    public let collection: CollectionID
    public let snapshot: SegmentLocator
    public let root: GeneralSnapshotRootV1
    public let records: [GeneralSnapshotRecordV1]
    public let pages: Set<SegmentLocator>
    /// Exact addresses named by the records and bootstrap locator; ancestry is resolved by the semantic verifier.
    public let historyLocators: Set<SegmentLocator>
    /// Exact snapshot roots whose accepted object closures this manifest preserves.
    public let retentionParents: [SegmentLocator]
    public var requiredLocators: Set<SegmentLocator> { historyLocators.union(retentionParents) }
    private let rootBytes: [UInt8]
    private init(collection: CollectionID, snapshot: SegmentLocator, root: GeneralSnapshotRootV1,
                 records: [GeneralSnapshotRecordV1], retentionParents: [SegmentLocator], pages: Set<SegmentLocator>, rootBytes: [UInt8]) {
        self.collection = collection; self.snapshot = snapshot; self.root = root; self.records = records; self.pages = pages
        self.rootBytes = rootBytes
        self.retentionParents = retentionParents
        historyLocators = Set(records.flatMap { $0.operationReferences.map(\.locator) + $0.actionReferences.map(\.locator) } + [root.bootstrapSnapshot])
    }
    public static func read(snapshot: SegmentLocator, collection: CollectionID, protection: ObjectProtectionV1,
                            recordsPerTurn: Int = 64, didYield: (@Sendable (Int) async -> Void)? = nil,
                            read: @escaping @Sendable (SegmentLocator) async throws -> [UInt8]?) async throws -> Self {
        guard recordsPerTurn > 0 else { throw CanonicalEncodingError.lengthLimit }
        try Task.checkCancellation()
        guard let bytes = try await read(snapshot) else { throw GeneralSnapshotError.missingObject(snapshot) }
        let object = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: snapshot)
        guard object.kind == .snapshotRoot else { throw CanonicalEncodingError.invalidReference }
        let root = try GeneralSnapshotRootV1.decodeV1(object.payload)
        var reader = SnapshotStreamReader(root: root, collection: collection, protection: protection, read: read)
        guard try await reader.bytes(10) == GeneralSnapshotFormatV1.streamHeader else { throw CanonicalEncodingError.unsupportedFormat }
        var records: [GeneralSnapshotRecordV1] = [], parents: [SegmentLocator] = []
        var counts = [UInt64](repeating: 0, count: GeneralSnapshotFormatV1.categoryCount), previous: [UInt8]?
        var processed = 0
        while reader.remaining > 0 {
            try Task.checkCancellation()
            var frame = ByteCursor(bytes: try await reader.bytes(5))
            let tag = try frame.byte(), length = try frame.unsigned32()
            guard tag >= 1, Int(tag) <= GeneralSnapshotFormatV1.categoryCount else { throw CanonicalEncodingError.invalidDiscriminant }
            guard UInt64(length) <= ObjectLimitsV1.decodedPayloadBytes else { throw CanonicalEncodingError.lengthLimit }
            let payload = try await reader.bytes(Int(length)), key: [UInt8]
            if tag == 8 {
                let parent = try SegmentLocator.decodeV1(payload)
                key = [tag] + parent.encodedV1(); parents.append(parent)
            } else {
                let record = try GeneralSnapshotRecordV1.decode(tag: tag, payload: payload)
                key = record.key; records.append(record)
            }
            if let previous, !previous.lexicographicallyPrecedes(key) { throw CanonicalEncodingError.noncanonicalSet }
            previous = key; counts[Int(tag) - 1] += 1
            guard counts[Int(tag) - 1] <= root.counts[Int(tag) - 1] else { throw GeneralSnapshotError.invalidState }
            processed += 1
            if processed % recordsPerTurn == 0 { await didYield?(processed); await Task.yield() }
        }
        guard counts == root.counts, Array(reader.hash.finalize()) == root.digest.bytes,
              reader.pending.isEmpty, reader.chunkOffset == reader.chunk.count else { throw GeneralSnapshotError.invalidState }
        return Self(collection: collection, snapshot: snapshot, root: root, records: records,
                    retentionParents: parents, pages: reader.seen, rootBytes: bytes)
    }

    /// Reopens the exact root under the consuming collection's protection context.
    public func checkProtection(collection: CollectionID, protection: ObjectProtectionV1) throws {
        _ = try ObjectEnvelopeV1.open(rootBytes, collection: collection, protection: protection, expectedLocator: snapshot)
    }
}

/// Iterative manifest traversal and record reads crossing bounded data leaves.
private struct SnapshotStreamReader {
    let collection: CollectionID
    let protection: ObjectProtectionV1
    let read: @Sendable (SegmentLocator) async throws -> [UInt8]?
    var pending: [SnapshotPageRangeV1]
    var seen: Set<SegmentLocator> = []
    var remaining: UInt64
    var chunk: [UInt8] = []
    var chunkOffset = 0
    var hash = SHA256()
    init(root: GeneralSnapshotRootV1, collection: CollectionID, protection: ObjectProtectionV1,
         read: @escaping @Sendable (SegmentLocator) async throws -> [UInt8]?) {
        self.collection = collection; self.protection = protection; self.read = read
        pending = [root.tree]; remaining = root.tree.byteCount; hash.update(data: GeneralSnapshotFormatV1.digestDomain)
    }
    mutating func bytes(_ count: Int) async throws -> [UInt8] {
        guard count >= 0, UInt64(count) <= remaining else { throw CanonicalEncodingError.truncated }
        var output: [UInt8] = []; output.reserveCapacity(count)
        while output.count < count {
            if chunkOffset == chunk.count { try await nextChunk() }
            let take = min(count - output.count, chunk.count - chunkOffset)
            output.append(contentsOf: chunk[chunkOffset..<(chunkOffset + take)]); chunkOffset += take
        }
        remaining -= UInt64(count); hash.update(data: output); return output
    }
    private mutating func nextChunk() async throws {
        while let range = pending.popLast() {
            try Task.checkCancellation()
            guard seen.insert(range.locator).inserted else { throw GeneralSnapshotError.invalidManifest }
            guard let bytes = try await read(range.locator) else { throw GeneralSnapshotError.missingObject(range.locator) }
            let object = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection, expectedLocator: range.locator)
            guard object.kind == .snapshotPage else { throw CanonicalEncodingError.invalidReference }
            let page = try GeneralSnapshotPageV1.decodeV1(object.payload)
            guard page.offset == range.offset, page.byteCount == range.byteCount else { throw GeneralSnapshotError.invalidManifest }
            switch page.contents {
            case .data(_, let bytes): chunk = bytes; chunkOffset = 0; return
            case .index(let children): pending.append(contentsOf: children.reversed())
            }
        }
        throw CanonicalEncodingError.truncated
    }
}

/// Streams canonical records into bounded leaves, then folds index levels and emits a root.
public enum GeneralSnapshotV1 {
    /// Orders one complete set of claims by their semantic record keys.
    public static func canonicalOrder(_ records: [GeneralSnapshotRecordV1]) throws -> [GeneralSnapshotRecordV1] {
        let sorted = records.sorted { $0.key.lexicographicallyPrecedes($1.key) }
        for pair in zip(sorted, sorted.dropFirst()) {
            guard pair.0.key != pair.1.key else { throw CanonicalEncodingError.noncanonicalSet }
        }
        return sorted
    }
    public static func write(records: [GeneralSnapshotRecordV1], bootstrapSnapshot: SegmentLocator,
                             retentionParents: [SegmentLocator] = [],
                             chunkBytes: Int = 256 * 1024, fanout: Int = 128,
                             emit: @Sendable (ProviderObjectKind, [UInt8]) async throws -> SegmentLocator) async throws -> SegmentLocator {
        guard chunkBytes > 0, UInt64(chunkBytes) <= ObjectLimitsV1.decodedPayloadBytes - 23,
              fanout >= 2, UInt64(fanout) <= (ObjectLimitsV1.decodedPayloadBytes - 15) / 72 else { throw CanonicalEncodingError.lengthLimit }
        var levels: [[SnapshotPageRangeV1]] = [], offset: UInt64 = 0, buffer: [UInt8] = [], hash = SHA256()
        let parents = retentionParents.sorted { $0.encodedV1().lexicographicallyPrecedes($1.encodedV1()) }
        guard Set(parents).count == parents.count else { throw CanonicalEncodingError.noncanonicalSet }
        hash.update(data: GeneralSnapshotFormatV1.digestDomain)
        var counts = [UInt64](repeating: 0, count: GeneralSnapshotFormatV1.categoryCount), previous: [UInt8]?
        func parent(_ children: [SnapshotPageRangeV1]) async throws -> SnapshotPageRangeV1 {
            let page = try GeneralSnapshotPageV1(.index(children))
            return try SnapshotPageRangeV1(locator: await emit(.snapshotPage, page.encodedV1()), offset: page.offset, byteCount: page.byteCount)
        }
        func append(_ range: SnapshotPageRangeV1, level: Int) async throws {
            var range = range, level = level
            while true {
                if levels.count <= level { levels.append([]) }
                levels[level].append(range)
                guard levels[level].count == fanout else { return }
                range = try await parent(levels[level]); levels[level] = []; level += 1
            }
        }
        func flush() async throws {
            guard !buffer.isEmpty else { return }
            let page = try GeneralSnapshotPageV1(.data(offset: offset, bytes: buffer))
            let end = offset.addingReportingOverflow(UInt64(buffer.count))
            guard !end.overflow else { throw CanonicalEncodingError.lengthLimit }
            let ref = try SnapshotPageRangeV1(locator: await emit(.snapshotPage, page.encodedV1()), offset: offset, byteCount: UInt64(buffer.count))
            offset = end.partialValue; buffer = []; try await append(ref, level: 0)
        }
        func write(_ bytes: [UInt8]) async throws {
            hash.update(data: bytes)
            var position = 0
            while position < bytes.count {
                try Task.checkCancellation()
                let count = min(chunkBytes - buffer.count, bytes.count - position)
                buffer.append(contentsOf: bytes[position..<(position + count)]); position += count
                if buffer.count == chunkBytes { try await flush() }
            }
        }
        try await write(GeneralSnapshotFormatV1.streamHeader)
        for record in records {
            try Task.checkCancellation()
            if let previous, !previous.lexicographicallyPrecedes(record.key) { throw CanonicalEncodingError.noncanonicalSet }
            previous = record.key; counts[Int(record.tag) - 1] += 1
            try await write(record.encodedV1())
        }
        for parent in parents {
            try Task.checkCancellation()
            counts[7] += 1
            try await write([8] + bigEndianBytes(UInt32(56)) + parent.encodedV1())
        }
        try await flush()
        var level = 0
        while level < levels.count {
            if !levels[level].isEmpty {
                if levels[level].count == 1, levels.dropFirst(level + 1).allSatisfy(\.isEmpty) {
                    let root = try GeneralSnapshotRootV1(bootstrapSnapshot: bootstrapSnapshot, tree: levels[level][0], counts: counts,
                        digest: GeneralSnapshotDigestV1(bytes: Array(hash.finalize())))
                    try Task.checkCancellation(); return try await emit(.snapshotRoot, root.encodedV1())
                }
                let ref = try await parent(levels[level]); levels[level] = []; try await append(ref, level: level + 1)
            }
            level += 1
        }
        throw GeneralSnapshotError.invalidManifest
    }
}
