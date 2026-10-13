import Foundation
import Testing
@testable import NVStorageCore

private func rowFixture(_ file: String, _ key: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: file, withExtension: "json", subdirectory: "Fixtures"))
    let values = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    let hex = Array(try #require(values[key]))
    return stride(from: 0, to: hex.count, by: 2).map { UInt8(String(hex[$0...$0+1]), radix: 16)! }
}

@Test func privateCurrentFrameIndependentBytesAndBounds() throws {
    let canonical = try rowFixture("current-state", "cell"), frame = try rowFixture("private-current-frame", "frame")
    let decoder = try CurrentRowDecoderV1()
    let expected = try CurrentNoteCellV1.decodeV1(canonical)
    let actual = try decoder.decode(frame) { _ in throw CanonicalEncodingError.missingDependency }
    #expect(actual == expected)
    #expect(actual.value.title.string == "T" && actual.value.body.string == "hi")
    #expect(actual.birth.bytes == [UInt8](repeating: 1, count: 16))
    let raw = Array("NVROW1\r\n".utf8) + [0,1,0,0,0,0,234,0,0,0,234] + canonical
    #expect(try decoder.decode(raw) { _ in throw CanonicalEncodingError.missingDependency } == expected)
    #expect(try decoder.decode(canonical) { _ in throw CanonicalEncodingError.missingDependency } == expected)
    for cut in frame.indices {
        #expect(throws: (any Error).self) { try decoder.decode(Array(frame.prefix(cut))) { _ in throw CanonicalEncodingError.missingDependency } }
    }
    for index in [8,9,10,11,12,13,14,15,16,17,18,19,20,21,22] {
        var bad = frame; bad[index] ^= 0xff
        #expect(throws: (any Error).self) { try decoder.decode(bad) { _ in throw CanonicalEncodingError.missingDependency } }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try decoder.decode(frame + [0]) { _ in throw CanonicalEncodingError.missingDependency } }
    var reserved = frame; reserved[23] |= 0x08
    #expect(throws: CanonicalEncodingError.invalidPayload) { try decoder.decode(reserved) { _ in throw CanonicalEncodingError.missingDependency } }
    let encoded = try CurrentRowEncoderV1().encode(expected)
    #expect(try decoder.decode(encoded) { _ in throw CanonicalEncodingError.missingDependency } == expected)
    #expect(encoded.count <= raw.count)
    let source = Array(frame.dropFirst(19))
    func compressedFrame(_ payload: [UInt8], expanded: UInt32 = 234) -> [UInt8] {
        func word(_ value: UInt32) -> [UInt8] {
            [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
             UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
        return Array("NVROW1\r\n".utf8) + [0,1,1] + word(expanded) + word(UInt32(payload.count)) + payload
    }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try decoder.decode(compressedFrame(source + source)) { _ in throw CanonicalEncodingError.missingDependency } }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try decoder.decode(compressedFrame([0x50,0x2a,0x4d,0x18,0,0,0,0])) { _ in throw CanonicalEncodingError.missingDependency } }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try decoder.decode(compressedFrame(source, expanded: 235)) { _ in throw CanonicalEncodingError.missingDependency } }
    let unknownSize = [UInt8](source.prefix(4)) + [0,0] + source.dropFirst(6)
    #expect(throws: CanonicalEncodingError.invalidPayload) { try decoder.decode(compressedFrame(unknownSize)) { _ in throw CanonicalEncodingError.missingDependency } }
    let excessiveWindow = [UInt8](source.prefix(4)) + [0,0x88] + source.dropFirst(6)
    #expect(throws: CanonicalEncodingError.lengthLimit) { try decoder.decode(compressedFrame(excessiveWindow)) { _ in throw CanonicalEncodingError.missingDependency } }
}

@Test func privateCurrentDictionaryDigestAndTrainingBounds() throws {
    let bodies = (0..<256).map { Array("A synthetic note about safe local storage, complete history and portable values. Sample \($0).".utf8) }
    let dictionary = try #require(try CurrentRowDictionaryV1.train(bodies: bodies))
    #expect(dictionary.bytes.count <= 8192 && dictionary.digest.count == 32 && dictionary.frameID != 0)
    #expect(try CurrentRowDictionaryV1.train(bodies: Array(bodies.prefix(7))) == nil)
    let oversized = [UInt8](repeating: 65, count: 8 * 1024 * 1024 + 1)
    #expect(try CurrentRowDictionaryV1.train(bodies: [oversized]) == nil)
    #expect(try CurrentRowDictionaryV1.train(bodies: Array(bodies.prefix(1024)) + [oversized])?.bytes == dictionary.bytes)
    #expect(throws: (any Error).self) { try CurrentRowDictionaryV1(bytes: [0,0,0,0,0,0,0,0]) }
}

@Test func privateCurrentDictionaryWorkingSetStreamsManyGenerations() throws {
    let original = try rowFixture("private-current-dictionary", "dictionary")
    let canonical = try CurrentNoteCellV1.decodeV1(rowFixture("current-state", "cell"))
    let decoder = try CurrentRowDecoderV1(), plain = try rowFixture("private-current-frame", "frame")
    var values: [CurrentRowDictionaryV1] = [], frames: [[UInt8]] = []
    for index in UInt8(1)...6 {
        var bytes = original; bytes[4] = index
        let dictionary = try CurrentRowDictionaryV1(bytes: bytes)
        let frame = try CurrentRowEncoderV1(dictionary: dictionary).encode(canonical)
        #expect(try CurrentRowFrameV1(bytes: frame).encoding == .dictionary)
        values.append(dictionary); frames.append(frame)
    }
    var loads = 0
    for _ in 0..<2 {
        for frame in frames {
            let actual = try decoder.decode(frame) { digest in
                loads += 1; return try #require(values.first { $0.digest == digest })
            }
            #expect(actual == canonical)
            #expect(try decoder.decode(plain) { _ in throw CanonicalEncodingError.missingDependency } == canonical)
            #expect(try decoder.decode(CurrentRowEncoderV1.raw(canonical)) { _ in throw CanonicalEncodingError.missingDependency } == canonical)
        }
    }
    #expect(loads == 12)
}

@Test func privateCurrentDictionaryIndependentFrameAndBinding() throws {
    let bytes = try rowFixture("private-current-dictionary", "dictionary"), frame = try rowFixture("private-current-dictionary", "frame")
    let dictionary = try CurrentRowDictionaryV1(bytes: bytes), decoder = try CurrentRowDecoderV1()
    let expected = try CurrentNoteCellV1.decodeV1(rowFixture("current-state", "cell"))
    var loads = 0
    for _ in 0..<8 {
        let result = try decoder.decode(frame) { digest in loads += 1; #expect(digest == dictionary.digest); return dictionary }
        #expect(result == expected)
    }
    #expect(loads == 1)
    var wrongDigest = frame; wrongDigest[19] ^= 1
    #expect(throws: CanonicalEncodingError.identityMismatch) { try decoder.decode(wrongDigest) { _ in dictionary } }
    var wrongID = frame; wrongID[56] ^= 1
    #expect(throws: (any Error).self) { try decoder.decode(wrongID) { _ in dictionary } }
    #expect(throws: CanonicalEncodingError.missingDependency) {
        try CurrentRowDecoderV1().decode(frame) { _ in throw CanonicalEncodingError.missingDependency }
    }
}
