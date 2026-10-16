import Foundation
import Testing
@testable import NVStorageCore

private struct ProjectionFixture {
    let collection = try! CollectionID(bytes: Array(repeating: 1, count: 16))
    let birth = try! NoteBirth(bytes: Array(repeating: 2, count: 16))
    let digest = ProjectionBytesDigestV1.compute([0xef, 0xbb, 0xbf, 65, 13, 10, 90])

    func ref(_ n: UInt8, sequence: UInt64 = 7) throws -> StoredOperationReferenceV1 {
        try .init(locator: SegmentLocator(writerEpoch: WriterEpoch(bytes: Array(repeating: 9, count: 16)),
            sequence: sequence, segmentID: SegmentID(bytes: Array(repeating: 8, count: 32))),
            index: OperationIndex(UInt32(n)), id: OperationID(bytes: Array(repeating: n, count: 32)))
    }

    func state(_ name: String) throws -> ProjectionStateReferenceV1 {
        switch name {
        case "ordinary": return try .revision(ref(3))
        case "equal", "merged":
            let kind: DerivedStateReferenceV1.Kind = name == "equal" ? .equal :
                try .merged(base: ref(2).reference, id: MergeIDV1(bytes: Array(repeating: 6, count: 32)))
            return try .derived(.init(kind: kind, inputs: [ref(4).reference, ref(3).reference],
                result: NoteValueDigest(bytes: Array(repeating: 5, count: 32)), earlierOperations: []))
        default:
            return try .automatic(.init(birth: birth, revision: ref(3).reference,
                key: AutomaticConflictKeyV1(bytes: Array(repeating: 7, count: 32))))
        }
    }

    func stamp(_ state: ProjectionStateReferenceV1, profile: CollectionProfileV1 = .plaintextFiles) throws -> ProjectionStampV1 {
        let target: NoteBirth
        if case .automatic(let source) = state { target = try source.key.birth() } else { target = birth }
        return try .init(profile: profile, collection: collection, birth: target,
                         format: .plaintext, digest: digest, state: state)
    }

    func literals() throws -> [String: [UInt8]] {
        let url = try #require(Bundle.module.url(forResource: "projection-stamp", withExtension: "json", subdirectory: "Fixtures"))
        let strings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        return strings.mapValues { value in
            let chars = Array(value)
            return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
        }
    }
}

@Test(arguments: ["ordinary", "equal", "merged", "automatic"])
func projectionStampIndependentLayouts(_ name: String) throws {
    let f = ProjectionFixture(), stamp = try f.stamp(f.state(name)), literals = try f.literals()
    let bytes = try #require(literals[name])
    #expect(try stamp.encodedV1() == bytes)
    #expect(try ProjectionStampV1.decodeV1(bytes, profile: .plaintextFiles) == stamp)
    #expect(stamp.digest.bytes == literals["digest"])
    #expect(stamp.dependencies.entries == [try f.ref(3).locator])
    #expect(ProjectionStampV1.attributeName == "org.notationalvelocity.projection#S")
    for n in bytes.indices {
        #expect(throws: (any Error).self) { try ProjectionStampV1.decodeV1(Array(bytes.prefix(n)), profile: .plaintextFiles) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try ProjectionStampV1.decodeV1(bytes + [0], profile: .plaintextFiles) }
}

@Test func projectionStampExactDigestAndProfile() throws {
    let f = ProjectionFixture(), stamp = try f.stamp(f.state("ordinary"))
    #expect(f.digest != .compute(Array("A\nZ".utf8)))
    #expect(ProjectionBytesDigestV1.compute(Array("é".utf8)) != .compute(Array("e\u{301}".utf8)))
    #expect(ProjectionBytesDigestV1.compute([]) != .compute([0xef, 0xbb, 0xbf]))
    #expect(try ProjectionBytesDigestV1(bytes: Array(repeating: 0, count: 32)).bytes.count == 32)
    for size in [0, 31, 33] {
        #expect(throws: CanonicalEncodingError.invalidIdentifier) { try ProjectionBytesDigestV1(bytes: Array(repeating: 0, count: size)) }
    }
    let bytes = try stamp.encodedV1()
    #expect(throws: CanonicalEncodingError.wrongScope) { try ProjectionStampV1.decodeV1(bytes, profile: .encryptedSegments) }
    #expect(throws: CanonicalEncodingError.wrongScope) { try f.stamp(stamp.state, profile: .encryptedSegments) }
    #expect(throws: CanonicalEncodingError.wrongScope) {
        try ProjectionStampV1.prepare(profile: .encryptedSegments, collection: f.collection,
            birth: f.birth, format: .plaintext, digest: f.digest, state: stamp.state)
    }
}

@Test func projectionStampRejectsMalformedClaims() throws {
    let f = ProjectionFixture(), original = try f.stamp(f.state("ordinary")).encodedV1()
    func decode(_ bytes: [UInt8]) throws -> ProjectionStampV1 { try .decodeV1(bytes, profile: .plaintextFiles) }
    for offset in [0, 9, 43] {
        var bad = original; bad[offset] = 99
        #expect(throws: CanonicalEncodingError.unsupportedFormat) { try decode(bad) }
    }
    var bad = original; bad[136] = 99
    #expect(throws: CanonicalEncodingError.invalidDiscriminant) { try decode(bad) }
    bad = original; bad.replaceSubrange(76..<80, with: [255, 255, 255, 255])
    #expect(throws: CanonicalEncodingError.truncated) { try decode(bad) }
    bad = original; bad[141] = 1
    #expect(throws: CanonicalEncodingError.invalidReference) { try decode(bad) }
    bad = original; bad.replaceSubrange(10..<26, with: Array(repeating: 0, count: 16))
    #expect(throws: CanonicalEncodingError.invalidIdentifier) { try decode(bad) }
    let automatic = try f.stamp(f.state("automatic")).encodedV1()
    bad = automatic; bad[26] ^= 1
    #expect(throws: CanonicalEncodingError.invalidReference) { try decode(bad) }
    let local = try ProjectionStateReferenceV1.automatic(.init(birth: f.birth,
        revision: .earlierLocal(index: OperationIndex(0)), key: AutomaticConflictKeyV1(bytes: Array(repeating: 7, count: 32))))
    #expect(throws: CanonicalEncodingError.invalidReference) { try f.stamp(local) }
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try ProjectionStampV1.prepare(profile: .plaintextFiles, collection: f.collection, birth: f.birth,
            format: .plaintext, digest: f.digest, state: local)
    }
}

@Test func projectionStampRequiresExactDependencySet() throws {
    let f = ProjectionFixture(), stamp = try f.stamp(f.state("ordinary")), bytes = try stamp.encodedV1()
    let extra = try f.ref(3, sequence: 8).locator.encodedV1()
    var bad = Array(bytes.prefix(76)) + [0, 0, 0, 2] + Array(bytes[80..<136]) + extra + Array(bytes[136...])
    #expect(throws: CanonicalEncodingError.noncanonicalSet, "Unused locators are rejected") { try ProjectionStampV1.decodeV1(bad, profile: .plaintextFiles) }
    bad.replaceSubrange(136..<192, with: bytes[80..<136])
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try ProjectionStampV1.decodeV1(bad, profile: .plaintextFiles) }
    let equal = try f.stamp(f.state("equal")).encodedV1()
    bad = equal; bad.replaceSubrange(141..<223, with: Array(equal[182..<223]) + Array(equal[141..<182]))
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try ProjectionStampV1.decodeV1(bad, profile: .plaintextFiles) }
    bad = equal; bad.replaceSubrange(182..<223, with: equal[141..<182])
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try ProjectionStampV1.decodeV1(bad, profile: .plaintextFiles) }
}

@Test(arguments: [4_095, 4_096, 4_097])
func projectionStampBoundedCompleteOmission(_ size: Int) throws {
    let f = ProjectionFixture()
    let (count, locators) = size == 4_095 ? (82, 11) : size == 4_096 ? (67, 22) : (52, 33)
    let refs = try (1...count).map { try f.ref(UInt8($0), sequence: UInt64($0 % locators)).reference }
    let derived = try DerivedStateReferenceV1(kind: .equal, inputs: refs,
        result: NoteValueDigest(bytes: Array(repeating: 5, count: 32)), earlierOperations: [])
    #expect(117 + 56 * locators + 41 * count == size)
    let prepared = try ProjectionStampV1.prepare(profile: .plaintextFiles, collection: f.collection,
        birth: f.birth, format: .plaintext, digest: f.digest, state: .derived(derived))
    if size > 4_096 {
        #expect(prepared == .omittedOversized)
        #expect(throws: CanonicalEncodingError.lengthLimit) { try f.stamp(.derived(derived)) }
    } else {
        guard case .stamp(let stamp) = prepared else { Issue.record("Complete in-bound claim was omitted"); return }
        let bytes = try stamp.encodedV1()
        #expect(bytes.count == size)
        #expect(try ProjectionStampV1.decodeV1(bytes, profile: .plaintextFiles).state == .derived(derived))
    }
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try ProjectionStampV1.decodeV1(Array(repeating: 0, count: 4_097), profile: .plaintextFiles)
    }
}

@Test(arguments: [false, true])
func projectionStampRetainsDerivedReconstruction(_ equal: Bool) async throws {
    let f = try DerivedFixture(equal: equal), claim = try f.claim(equal: equal)
    let stamp = try ProjectionStampV1(profile: .plaintextFiles, collection: f.graph.collection,
        birth: f.graph.birth, format: .plaintext, digest: .compute(Array("output".utf8)), state: .derived(claim))
    let decoded = try ProjectionStampV1.decodeV1(stamp.encodedV1(), profile: .plaintextFiles)
    guard case .derived(let restored) = decoded.state else { Issue.record("Derived source was lost"); return }
    let reconstructed = try await f.reconstruct(restored)
    #expect(reconstructed.value.value.body.string == (equal ? "A\ngap\nz" : "A\ngap\nZ"))
    await #expect(throws: CanonicalEncodingError.missingDependency) {
        try await restored.reconstruct(collection: f.graph.collection, birth: f.graph.birth,
            history: f.history, earlierOperations: [], at: f.enclosing, resolve: { _ in nil })
    }
}
