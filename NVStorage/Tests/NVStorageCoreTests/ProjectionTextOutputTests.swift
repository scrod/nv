import Foundation
import Testing
@testable import NVStorageCore

@Test func projectionTextMatchesRecordedLegacyMatrix() throws {
    struct Entry: Decodable {
        let name: String
        let encoding: UInt64
        let input: [UInt8]
        let macos: [UInt8]?
        let linux: [UInt8]?
    }
    let url = try #require(Bundle.module.url(forResource: "projection-text-output", withExtension: "json", subdirectory: "Fixtures"))
    let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
    #expect(entries.count == 98 && Set(entries.map(\.encoding)).count == 14)
    for entry in entries {
        let captured: [UInt8]?
        #if os(macOS)
        captured = entry.macos
        #else
        captured = entry.linux
        #endif
        let expected = captured ?? entry.input
        let prepared = PreparedProjectionTextV1.prepare(try .init(bytes: entry.input), requested: try .init(rawValue: entry.encoding))
        #expect(prepared.bytes == expected, "Exact captured legacy representation: \(entry.name), input \(entry.input)")
        #expect(prepared.encoding.rawValue == (captured == nil ? 4 : entry.encoding))
    }
}

@Test(arguments: ["", "A\r\nZ", "é", "e\u{301}", "日本", "😀", "a\0b"])
func projectionTextUTF8PreservesExactInput(_ text: String) throws {
    let body = try ExactUTF8(bytes: Array(text.utf8))
    let prepared = PreparedProjectionTextV1.prepare(body, requested: .utf8)
    #expect(prepared.encoding == .utf8 && prepared.bytes == Array(text.utf8))
}

@Test func projectionTextRequestedEncodingAndPromotion() throws {
    func output(_ text: String, _ encoding: UInt64) throws -> PreparedProjectionTextV1 {
        PreparedProjectionTextV1.prepare(try .init(bytes: Array(text.utf8)), requested: try .init(rawValue: encoding))
    }
    #expect(try output("é", 30).bytes == [0x8e]) // NSString Mac Roman, independently mapped by Python.
    #expect(try output("A\r\nZ", 10).bytes == [255,254,65,0,13,0,10,0,90,0])
    let promotion = try output("日本😀", 1)
    #expect(promotion.encoding == .utf8 && promotion.bytes == Array("日本😀".utf8))
    #expect(try output("", 1).bytes.isEmpty)
    #expect(try output("a\0b", 1).bytes == [97,0,98])
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ProjectionEncodingV1(rawValue: 0) }
}

@Test func projectionTextCapturedOutputIndependentEncoding() throws {
    let url = try #require(Bundle.module.url(forResource: "projection-observations", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    func literal(_ key: String) throws -> [UInt8] {
        let chars = Array(try #require(fixture[key]))
        return stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0+1]), radix: 16)! }
    }
    let binding = try ProjectionBindingV1.decodeV1(literal("captured_binding"), profile: .plaintextFiles)
    let expected = try ProjectionOutputV1(generation: 1, encoding: .captured(encoding: .init(rawValue: 10), byteCount: 10), binding: binding)
    let bytes = try literal("captured_output")
    #expect(try expected.encoded() == bytes)
    #expect(try ProjectionOutputV1.decode(bytes, profile: .plaintextFiles) == expected)
    #expect(binding.descriptor.digest == .compute([255,254,65,0,13,0,10,0,90,0]))
    for n in bytes.indices { #expect(throws: (any Error).self) { try ProjectionOutputV1.decode(Array(bytes.prefix(n)), profile: .plaintextFiles) } }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ProjectionOutputV1(generation: 1, encoding: .captured(encoding: .utf8, byteCount: 0), binding: binding) }
    #expect(throws: CanonicalEncodingError.invalidPayload) { try ProjectionOutputV1(generation: 1, encoding: .captured(encoding: .init(rawValue: 10), byteCount: UInt64.max), binding: binding) }
}
