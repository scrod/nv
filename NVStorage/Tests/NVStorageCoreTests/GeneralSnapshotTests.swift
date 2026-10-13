import Crypto
import Foundation
import NVStorageCore
import Testing

private func snapshotFixture() throws -> [String: [UInt8]] {
    let url = try #require(Bundle.module.url(forResource: "general-snapshot", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    return try fixture.mapValues { value in
        let chars = Array(value)
        return try stride(from: 0, to: chars.count, by: 2).map { try #require(UInt8(String(chars[$0...$0+1]), radix: 16)) }
    }
}

private actor SnapshotObjects {
    let collection: CollectionID
    let protection: ObjectProtectionV1
    let writer: WriterEpoch
    var sequence: UInt64 = 0
    var objects: [SegmentLocator: [UInt8]] = [:]
    init(encrypted: Bool) throws {
        collection = try .init(bytes: Array(repeating: 20, count: 16))
        writer = try .init(bytes: Array(repeating: 21, count: 16))
        protection = try encrypted ? .encrypted(keyID: .init(bytes: Array(repeating: 22, count: 16)),
            key: SymmetricKey(data: [UInt8](repeating: 23, count: 32))) : .publicHash
    }
    func emit(_ kind: ProviderObjectKind, _ payload: [UInt8]) throws -> SegmentLocator {
        let bytes = try ObjectEnvelopeV1.seal(payload: payload, kind: kind, collection: collection,
            writer: writer, sequence: sequence, protection: protection, compress: true)
        sequence += 1
        let locator = try ObjectEnvelopeV1.open(bytes, collection: collection, protection: protection).locator
        objects[locator] = bytes; return locator
    }
}

@Test func generalSnapshotLiteralLayoutsAndBounds() throws {
    let f = try snapshotFixture(), rootBytes = try #require(f["root"])
    let root = try GeneralSnapshotRootV1.decodeV1(rootBytes)
    #expect(rootBytes.count == 236 && root.encodedV1() == rootBytes)
    #expect(root.counts == [1, 1, 2, 1, 1, 1, 1, 0])
    let stream = try #require(f["stream"])
    #expect(root.digest.bytes == f["digest"] && root.tree.byteCount == UInt64(stream.count))
    for name in ["dataPage", "indexPage"] {
        let bytes = try #require(f[name]), page = try GeneralSnapshotPageV1.decodeV1(bytes)
        #expect(page.encodedV1() == bytes && page.offset == 0 && page.byteCount == root.tree.byteCount)
        for cut in bytes.indices { #expect(throws: (any Error).self) { try GeneralSnapshotPageV1.decodeV1(Array(bytes.prefix(cut))) } }
        #expect(throws: CanonicalEncodingError.trailingBytes) { try GeneralSnapshotPageV1.decodeV1(bytes + [0]) }
        var unsupported = bytes; unsupported[9] = 2
        #expect(throws: CanonicalEncodingError.unsupportedFormat) { try GeneralSnapshotPageV1.decodeV1(unsupported) }
    }
    var records: [GeneralSnapshotRecordV1] = []
    for i in 1...8 {
        let bytes = try #require(f["record\(i)"]), record = try GeneralSnapshotRecordV1.decodeV1(bytes)
        #expect(try record.encodedV1() == bytes)
        for cut in bytes.indices { #expect(throws: (any Error).self) { try GeneralSnapshotRecordV1.decodeV1(Array(bytes.prefix(cut))) } }
        #expect(throws: CanonicalEncodingError.trailingBytes) { try GeneralSnapshotRecordV1.decodeV1(bytes + [0]) }
        records.append(record)
    }
    guard case .current(let cell) = records[0] else { Issue.record("missing current fixture"); return }
    #expect(cell.value.title.string == "T" && cell.value.body.string == "hi")
    #expect(cell.revision.index.rawValue == 5 && cell.scopeFrontier[0].index.rawValue == 7)
    #expect(try GeneralSnapshotV1.canonicalOrder(records.reversed()) == records)
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try GeneralSnapshotV1.canonicalOrder(records + [records[0]]) }
    for cut in rootBytes.indices { #expect(throws: (any Error).self) { try GeneralSnapshotRootV1.decodeV1(Array(rootBytes.prefix(cut))) } }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try GeneralSnapshotRootV1.decodeV1(rootBytes + [0]) }
    for version in [UInt8(0), 2] {
        for offset in [9, 11] {
            var unsupported = rootBytes; unsupported[offset] = version
            #expect(throws: CanonicalEncodingError.unsupportedFormat) { try GeneralSnapshotRootV1.decodeV1(unsupported) }
        }
    }
    var incompleteCounts = rootBytes
    incompleteCounts.removeSubrange(196..<204)
    #expect(throws: CanonicalEncodingError.truncated) { try GeneralSnapshotRootV1.decodeV1(incompleteCounts) }
    #expect(throws: CanonicalEncodingError.lengthLimit) { try SnapshotPageRangeV1(locator: root.tree.locator, offset: UInt64.max, byteCount: 1) }
    #expect(throws: CanonicalEncodingError.lengthLimit) { try GeneralSnapshotPageV1(.data(offset: 0, bytes: [])) }
    let second = try SnapshotPageRangeV1(locator: root.bootstrapSnapshot, offset: root.tree.byteCount + 1, byteCount: 1)
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try GeneralSnapshotPageV1(.index([root.tree, second])) }
    #expect(throws: CanonicalEncodingError.invalidPayload) {
        try GeneralSnapshotRootV1(bootstrapSnapshot: root.bootstrapSnapshot, tree: root.tree, counts: [1, 0, 2, 1, 1, 1, 1, 0], digest: root.digest)
    }
    #expect(throws: CanonicalEncodingError.invalidPayload) {
        try GeneralSnapshotRootV1(bootstrapSnapshot: root.bootstrapSnapshot, tree: root.tree, counts: Array(root.counts.dropLast()), digest: root.digest)
    }
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try GeneralSnapshotRootV1(bootstrapSnapshot: root.bootstrapSnapshot, tree: root.tree, counts: [UInt64.max, 1, 0, 0, 0, 0, 0, 0], digest: root.digest)
    }
}

@Test(arguments: [false, true], [1, 17, 262144])
func generalSnapshotCrossPageRecordsAndManifest(encrypted: Bool, chunk: Int) async throws {
    let f = try snapshotFixture(), fixtureRoot = try GeneralSnapshotRootV1.decodeV1(#require(f["root"]))
    let records = try (1...8).map { try GeneralSnapshotRecordV1.decodeV1(#require(f["record\($0)"])) }
    let sink = try SnapshotObjects(encrypted: encrypted)
    let snapshot = try await GeneralSnapshotV1.write(records: records, bootstrapSnapshot: fixtureRoot.bootstrapSnapshot,
        chunkBytes: chunk, fanout: 2, emit: { try await sink.emit($0, $1) })
    let map = await sink.objects
    let preview = try await GeneralSnapshotPreviewV1.read(snapshot: snapshot, collection: sink.collection, protection: sink.protection, read: { map[$0] })
    #expect(preview.records == records && preview.root.counts == fixtureRoot.counts)
    #expect(preview.root.digest == fixtureRoot.digest && preview.root.encodedV1().count == 236)
    #expect(preview.retentionParents.isEmpty && preview.requiredLocators == preview.historyLocators)
    #expect(preview.pages == Set(map.keys).subtracting([snapshot]))
    #expect(preview.historyLocators == [fixtureRoot.bootstrapSnapshot])
    if chunk < 20 { #expect(preview.pages.count > 40) }
    try preview.checkProtection(collection: sink.collection, protection: sink.protection)
    #expect(throws: CanonicalEncodingError.wrongScope) {
        try preview.checkProtection(collection: .init(bytes: Array(repeating: 99, count: 16)), protection: sink.protection)
    }
    if encrypted {
        #expect(throws: CanonicalEncodingError.authenticationFailure) {
            try preview.checkProtection(collection: sink.collection,
                protection: .encrypted(keyID: .init(bytes: Array(repeating: 22, count: 16)), key: SymmetricKey(data: [UInt8](repeating: 99, count: 32))))
        }
    }
}

@Test(arguments: [false, true], [1, 17, 262144])
func generalSnapshotPagedRetentionLayouts(encrypted: Bool, chunk: Int) async throws {
    let f = try snapshotFixture(), root = try GeneralSnapshotRootV1.decodeV1(#require(f["rootWithParents"]))
    #expect(root.counts == [1, 1, 2, 1, 1, 1, 1, 2])
    #expect(root.encodedV1() == f["rootWithParents"] && root.encodedV1().count == 236)
    for cut in root.encodedV1().indices {
        #expect(throws: (any Error).self) { try GeneralSnapshotRootV1.decodeV1(Array(root.encodedV1().prefix(cut))) }
    }
    let records = try (1...8).map { try GeneralSnapshotRecordV1.decodeV1(#require(f["record\($0)"])) }
    let parents = try (1...2).map { try SegmentLocator.decodeV1(Array(#require(f["retentionParent\($0)"]).dropFirst(5))) }
    let sink = try SnapshotObjects(encrypted: encrypted)
    let snapshot = try await GeneralSnapshotV1.write(records: records, bootstrapSnapshot: root.bootstrapSnapshot,
        retentionParents: parents.reversed(), chunkBytes: chunk, fanout: 2, emit: { try await sink.emit($0, $1) })
    let map = await sink.objects
    let preview = try await GeneralSnapshotPreviewV1.read(snapshot: snapshot, collection: sink.collection, protection: sink.protection, read: { map[$0] })
    #expect(preview.root.digest.bytes == f["digestWithParents"])
    #expect(preview.root.counts == root.counts && preview.root.tree.byteCount == root.tree.byteCount)
    #expect(preview.records == records && preview.retentionParents == parents)
    #expect(preview.historyLocators == [root.bootstrapSnapshot] && preview.requiredLocators == Set(parents))
    #expect(preview.pages == Set(map.keys).subtracting([snapshot]))
    await #expect(throws: CanonicalEncodingError.noncanonicalSet) {
        try await GeneralSnapshotV1.write(records: records, bootstrapSnapshot: root.bootstrapSnapshot,
            retentionParents: parents + [parents[0]], emit: { try await sink.emit($0, $1) })
    }
}

@Test(arguments: [false, true], ["order", "duplicate", "counts", "length", "version-zero", "version-two"])
func generalSnapshotAuthenticRetentionDefects(encrypted: Bool, fault: String) async throws {
    let f = try snapshotFixture(), base = try GeneralSnapshotRootV1.decodeV1(#require(f["rootWithParents"]))
    let prefix = Array(try #require(f["streamWithParents"]).dropLast(122))
    var first = try #require(f["retentionParent1"]), second = try #require(f["retentionParent2"])
    if fault == "length" { first[4] = 55; first.removeLast() }
    var stream = prefix + (fault == "order" ? second + first : first + (fault == "duplicate" ? first : second))
    if fault == "version-zero" { stream[9] = 0 }
    if fault == "version-two" { stream[9] = 2 }
    var counts = base.counts; if fault == "counts" { counts[7] = 1 }
    let sink = try SnapshotObjects(encrypted: encrypted)
    let page = try await sink.emit(.snapshotPage, GeneralSnapshotPageV1(.data(offset: 0, bytes: stream)).encodedV1())
    let root = try GeneralSnapshotRootV1(bootstrapSnapshot: base.bootstrapSnapshot,
        tree: .init(locator: page, offset: 0, byteCount: UInt64(stream.count)), counts: counts,
        digest: .init(bytes: Array(SHA256.hash(data: Array("NV general snapshot state\0v1\0".utf8) + stream))))
    let snapshot = try await sink.emit(.snapshotRoot, root.encodedV1()), map = await sink.objects
    let expected: any Error
    switch fault {
    case "order", "duplicate": expected = CanonicalEncodingError.noncanonicalSet
    case "length": expected = CanonicalEncodingError.truncated
    case "version-zero", "version-two": expected = CanonicalEncodingError.unsupportedFormat
    default: expected = GeneralSnapshotError.invalidState
    }
    await #expect { try await GeneralSnapshotPreviewV1.read(snapshot: snapshot, collection: sink.collection, protection: sink.protection, read: { map[$0] }) }
        throws: { String(reflecting: $0) == String(reflecting: expected) }
}

@Test(arguments: [false, true]) func generalSnapshotMissingPagesNameExactInputs(encrypted: Bool) async throws {
    let f = try snapshotFixture(), root = try GeneralSnapshotRootV1.decodeV1(#require(f["root"]))
    let records = try (1...8).map { try GeneralSnapshotRecordV1.decodeV1(#require(f["record\($0)"])) }
    let sink = try SnapshotObjects(encrypted: encrypted)
    let snapshot = try await GeneralSnapshotV1.write(records: records, bootstrapSnapshot: root.bootstrapSnapshot,
        chunkBytes: 64, fanout: 3, emit: { try await sink.emit($0, $1) })
    let all = await sink.objects
    for missing in all.keys {
        let partial = all.filter { $0.key != missing }
        await #expect(throws: GeneralSnapshotError.missingObject(missing)) {
            try await GeneralSnapshotPreviewV1.read(snapshot: snapshot, collection: sink.collection, protection: sink.protection, read: { partial[$0] })
        }
    }
    let complete = try await GeneralSnapshotPreviewV1.read(snapshot: snapshot, collection: sink.collection, protection: sink.protection, read: { all[$0] })
    #expect(complete.records == records)
}

@Test(arguments: [false, true], ["digest", "counts", "range", "order", "tag"])
func generalSnapshotAuthenticFramingDefects(encrypted: Bool, fault: String) async throws {
    let f = try snapshotFixture(), fixtureRoot = try GeneralSnapshotRootV1.decodeV1(#require(f["root"]))
    var stream = try #require(f["stream"])
    if fault == "order" { stream = Array(stream.prefix(10)) + (try #require(f["record2"])) + (try #require(f["record1"])) + Array(stream.dropFirst(10 + (try #require(f["record1"])).count + (try #require(f["record2"])).count)) }
    if fault == "tag" { stream[10] = 99 }
    var digest = Array(SHA256.hash(data: Array("NV general snapshot state\0v1\0".utf8) + stream))
    if fault == "digest" { digest[0] ^= 1 }
    let sink = try SnapshotObjects(encrypted: encrypted)
    let leaf = try await sink.emit(.snapshotPage, GeneralSnapshotPageV1(.data(offset: 0, bytes: stream)).encodedV1())
    var counts = fixtureRoot.counts; if fault == "counts" { counts[0] += 1 }
    let root = try GeneralSnapshotRootV1(bootstrapSnapshot: fixtureRoot.bootstrapSnapshot,
        tree: .init(locator: leaf, offset: 0, byteCount: UInt64(stream.count + (fault == "range" ? 1 : 0))),
        counts: counts, digest: .init(bytes: digest))
    let snapshot = try await sink.emit(.snapshotRoot, root.encodedV1()), map = await sink.objects
    let expected: any Error = fault == "order" ? CanonicalEncodingError.noncanonicalSet : fault == "tag" ? CanonicalEncodingError.invalidDiscriminant :
        fault == "range" ? GeneralSnapshotError.invalidManifest : GeneralSnapshotError.invalidState
    await #expect { try await GeneralSnapshotPreviewV1.read(snapshot: snapshot, collection: sink.collection, protection: sink.protection, read: { map[$0] }) } throws: { String(reflecting: $0) == String(reflecting: expected) }
}

@Test func generalSnapshotCancellationPreservesExplicitOutcome() async throws {
    let sink = try SnapshotObjects(encrypted: false), f = try snapshotFixture()
    let root = try GeneralSnapshotRootV1.decodeV1(#require(f["root"]))
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await GeneralSnapshotV1.write(records: [], bootstrapSnapshot: root.bootstrapSnapshot,
            emit: { try await sink.emit($0, $1) })
    }
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await sink.objects.isEmpty)
}

private actor SnapshotEmissionGate {
    var held = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var release: CheckedContinuation<Void, Never>?
    func holdFirst() async {
        guard !held else { return }; held = true
        let arrived = waiters; waiters = []; for waiter in arrived { waiter.resume() }
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilHeld() async {
        if !held { await withCheckedContinuation { waiters.append($0) } }
    }
    func proceed() { release?.resume(); release = nil }
}

@Test(.timeLimit(.minutes(1))) func generalSnapshotCancellationBetweenPagesKeepsExactOutput() async throws {
    let f = try snapshotFixture(), sink = try SnapshotObjects(encrypted: true), gate = SnapshotEmissionGate()
    let root = try GeneralSnapshotRootV1.decodeV1(#require(f["root"]))
    let records = try (1...8).map { try GeneralSnapshotRecordV1.decodeV1(#require(f["record\($0)"])) }
    let task = Task {
        try await GeneralSnapshotV1.write(records: records, bootstrapSnapshot: root.bootstrapSnapshot, chunkBytes: 1,
            emit: { kind, payload in
                let locator = try await sink.emit(kind, payload)
                await gate.holdFirst(); return locator
            })
    }
    await gate.waitUntilHeld(); task.cancel(); await gate.proceed()
    await #expect(throws: CancellationError.self) { try await task.value }
    let surviving = await sink.objects
    #expect(surviving.count == 1)
    for (locator, bytes) in surviving {
        #expect(try ObjectEnvelopeV1.open(bytes, collection: sink.collection, protection: sink.protection, expectedLocator: locator).kind == .snapshotPage)
    }
}
