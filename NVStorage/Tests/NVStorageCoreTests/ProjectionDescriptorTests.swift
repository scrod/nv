import Foundation
import Testing
@testable import NVStorageCore

private func leaf(_ name: String) throws -> ProjectionLeafNameV1 {
    try .init(ExactUTF8(bytes: Array(name.utf8)))
}

@Test(arguments: ["nfc", "nfd", "empty"])
func projectionDescriptorIndependentLayouts(_ key: String) throws {
    let name = key == "empty" ? "Empty.txt" : (key == "nfc" ? "Café.1.txt" : "Cafe\u{301}.1.txt")
    let body = key == "empty" ? [] : Array("A\r\nZ".utf8)
    let descriptor = try ProjectionDescriptorV1(profile: .plaintextFiles, filename: leaf(name),
        format: .plaintext, digest: .compute(body))
    let url = try #require(Bundle.module.url(forResource: "projection-descriptor", withExtension: "json", subdirectory: "Fixtures"))
    let literals = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    let chars = Array(try #require(literals[key]))
    let bytes = stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
    #expect(descriptor.encodedV1() == bytes)
    let parsed = try ProjectionDescriptorV1.decodeV1(bytes, profile: .plaintextFiles)
    #expect(parsed.filename.spelling.bytes == Array(name.utf8))
    #expect(parsed.format == .plaintext && parsed.digest == .compute(body))
    for end in bytes.indices {
        #expect(throws: (any Error).self) { try ProjectionDescriptorV1.decodeV1(Array(bytes.prefix(end)), profile: .plaintextFiles) }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) {
        try ProjectionDescriptorV1.decodeV1(bytes + [0], profile: .plaintextFiles)
    }
}

@Test func projectionLeafExactSpellingAndAliases() throws {
    let composed = try leaf("Café.txt"), decomposed = try leaf("Cafe\u{301}.txt")
    #expect(composed != decomposed)
    #expect(Set([composed, decomposed]).count == 2)
    #expect(composed.compare(to: decomposed) == .alias)
    #expect(composed.compare(to: composed) == .exact)
    #expect(try composed.compare(to: leaf("CAFÉ.TXT")) == .alias)
    #expect(try composed.compare(to: leaf("Cafe.txt")) == .distinct)
    for name in ["a:b.txt", "a\\b.txt", "..title.txt", "NV Data.txt", "Notes & Settings.txt", "🙂.txt"] {
        #expect(try leaf(name).spelling.bytes == Array(name.utf8))
    }
}

@Test(arguments: ["", ".", "..", "/a", "a/b", "a/../b", "a\0b", "NV Data", "nv data",
                  "Notes & Settings", "NOTES & SETTINGS", "Interim Note-Changes", "INTERIM NOTE-CHANGES"])
func projectionLeafRejectsUnsafeNames(_ name: String) throws {
    #expect(throws: CanonicalEncodingError.invalidPayload) { try leaf(name) }
    let path = Array(name.utf8)
    let bytes = Array("NVPRD1\r\n".utf8) + [0, 1] + bigEndianBytes(UInt32(path.count)) + path
        + [0, 1] + Array(repeating: UInt8(0), count: 32)
    #expect(throws: CanonicalEncodingError.invalidPayload) {
        try ProjectionDescriptorV1.decodeV1(bytes, profile: .plaintextFiles)
    }
}

@Test func projectionDescriptorRejectsMalformedAndWrongProfile() throws {
    let name = try leaf("a.txt")
    let descriptor = try ProjectionDescriptorV1(profile: .plaintextFiles, filename: name,
        format: .plaintext, digest: .compute([]))
    let original = descriptor.encodedV1()
    for offset in [0, 9, 20] {
        var bad = original; bad[offset] = 99
        #expect(throws: CanonicalEncodingError.unsupportedFormat) {
            try ProjectionDescriptorV1.decodeV1(bad, profile: .plaintextFiles)
        }
    }
    var bad = original; bad.replaceSubrange(10..<14, with: [255, 255, 255, 255])
    #expect(throws: CanonicalEncodingError.lengthLimit) { try ProjectionDescriptorV1.decodeV1(bad, profile: .plaintextFiles) }
    bad = original; bad.replaceSubrange(10..<14, with: bigEndianBytes(UInt32(ObjectLimitsV1.decodedPayloadBytes)))
    #expect(throws: CanonicalEncodingError.truncated) { try ProjectionDescriptorV1.decodeV1(bad, profile: .plaintextFiles) }
    bad = original; bad[14] = 255
    #expect(throws: CanonicalEncodingError.invalidUTF8) { try ProjectionDescriptorV1.decodeV1(bad, profile: .plaintextFiles) }
    #expect(throws: CanonicalEncodingError.wrongScope) {
        try ProjectionDescriptorV1(profile: .encryptedSegments, filename: name, format: .plaintext, digest: .compute([]))
    }
    #expect(throws: CanonicalEncodingError.wrongScope) {
        try ProjectionDescriptorV1.decodeV1(original, profile: .encryptedSegments)
    }
}

@Test func projectionDescriptorUsesExistingPayloadBound() throws {
    let limit = Int(ObjectLimitsV1.decodedPayloadBytes)
    for length in [limit - 49, limit - 48] {
        let name = try ProjectionLeafNameV1(ExactUTF8(bytes: Array(repeating: 97, count: length)))
        let descriptor = try ProjectionDescriptorV1(profile: .plaintextFiles, filename: name,
            format: .plaintext, digest: .compute([]))
        #expect(descriptor.encodedV1().count == length + 48)
    }
    let large = try ProjectionLeafNameV1(ExactUTF8(bytes: Array(repeating: 97, count: limit - 47)))
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try ProjectionDescriptorV1(profile: .plaintextFiles, filename: large, format: .plaintext, digest: .compute([]))
    }
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try ProjectionDescriptorV1.decodeV1(Array(repeating: 0, count: limit + 1), profile: .plaintextFiles)
    }
}
