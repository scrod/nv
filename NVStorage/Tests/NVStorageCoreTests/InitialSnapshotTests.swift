import Foundation
import NVStorageCore
import Testing

private func decodeHex(_ text: String) -> [UInt8] {
    let c = Array(text)
    return stride(from: 0, to: c.count, by: 2).map { UInt8(String(c[$0...($0 + 1)]), radix: 16)! }
}

@Test func initialSnapshotLayoutsAndCommitments() throws {
    let url = try #require(Bundle.module.url(forResource: "initial-snapshot", withExtension: "json", subdirectory: "Fixtures"))
    let f = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: url))
    let pageBytes = decodeHex(try #require(f["page"]))
    let rootBytes = decodeHex(try #require(f["root"]))
    let page = try InitialSnapshotPageV1.decodeV1(pageBytes)
    #expect(try page.encodedV1() == pageBytes && page.rows.count == 1 && page.index == 0)
    #expect(page.rows[0].value.body.bytes == [66])
    let root = try InitialSnapshotRootV1.decodeV1(rootBytes)
    #expect(try root.encodedV1() == rootBytes && root.initialCount == 1 && root.pages.count == 1)
    #expect(try InitialSnapshotRootV1.checkedPayloadSize(dependencies: root.dependencies.entries.count,
        frontier: root.frontier.count, pages: root.pages.count) == UInt64(rootBytes.count))
    var hasher = InitialValuesHasherV1(expectedCount: 1)
    #expect(throws: CanonicalEncodingError.invalidPayload) { try hasher.finish() }
    try hasher.append(birth: page.rows[0].birth, value: page.rows[0].value)
    #expect(try hasher.finish() == root.digest)
    #expect(try hasher.finish().bytes == decodeHex(try #require(f["commitment"])))
    #expect(throws: CanonicalEncodingError.invalidPayload) { try hasher.append(birth: page.rows[0].birth, value: page.rows[0].value) }
    let emptyBytes = decodeHex(try #require(f["emptyRoot"]))
    let empty = try InitialSnapshotRootV1.decodeV1(emptyBytes)
    #expect(try empty.encodedV1() == emptyBytes && empty.pages.isEmpty && empty.initialCount == 0)
    #expect(try InitialValuesHasherV1(expectedCount: 0).finish() == empty.digest)
    for i in pageBytes.indices {
        #expect(throws: (any Error).self) { try InitialSnapshotPageV1.decodeV1(Array(pageBytes.prefix(i))) }
    }
    for i in rootBytes.indices {
        #expect(throws: (any Error).self) { try InitialSnapshotRootV1.decodeV1(Array(rootBytes.prefix(i))) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try InitialSnapshotPageV1.decodeV1(pageBytes + [0]) }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try InitialSnapshotRootV1.decodeV1(rootBytes + [0]) }
// The codec preserves declared import IDs and values for subsequent history validation.
    var falseDigest = rootBytes; falseDigest[34] ^= 1
    #expect(try InitialSnapshotRootV1.decodeV1(falseDigest).digest != root.digest)
    #expect(throws: CanonicalEncodingError.invalidPayload) {
        try InitialSnapshotRootV1(importID: root.importID, initialCount: 2, digest: root.digest,
            dependencies: root.dependencies, completion: root.completion, frontier: root.frontier, pages: root.pages)
    }
    #expect(throws: CanonicalEncodingError.noncanonicalSet) {
        try InitialSnapshotPageV1(importID: page.importID, index: 0, dependencies: page.dependencies, rows: page.rows + page.rows)
    }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try InitialSnapshotRowV1(birth: page.rows[0].birth, value: page.rows[0].value, importReference: .earlierLocal(index: OperationIndex(0)))
    }
}

@Test func initialFlatManifestNearestByteLimits() throws {
    // One completion dependency and one frontier consume 216 bytes before the 64-byte page entries.
    #expect(try InitialSnapshotRootV1.checkedPayloadSize(dependencies: 1, frontier: 1, pages: 1_048_572) == 67_108_824)
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try InitialSnapshotRootV1.checkedPayloadSize(dependencies: 1, frontier: 1, pages: 1_048_573)
    }
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try InitialSnapshotRootV1.checkedPayloadSize(dependencies: 1, frontier: 1, pages: -1)
    }
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try InitialSnapshotRootV1.checkedPayloadSize(dependencies: Int(UInt32.max) + 1, frontier: 1, pages: 0)
    }
}
