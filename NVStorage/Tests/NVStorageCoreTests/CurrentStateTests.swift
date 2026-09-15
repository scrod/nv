import Foundation
import NVStorageCore
import Testing

@Test func literalCurrentCellAndAuthoringContext() throws {
    let file = try #require(Bundle.module.url(forResource: "current-state", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    func data(_ name: String) throws -> [UInt8] {
        let s = Array(try #require(fixture[name])); return stride(from: 0, to: s.count, by: 2).map { UInt8(String(s[$0...$0+1]), radix: 16)! }
    }
    let bytes = try data("cell"), contextBytes = try data("context")
    let cell = try CurrentNoteCellV1.decodeV1(bytes), context = try AuthoringContextV1.decodeV1(contextBytes)
    #expect(cell.birth.bytes == Array(repeating: 1, count: 16))
    #expect(cell.value.body.string == "hi" && cell.value.title.string == "T")
    #expect(cell.value.created.secondsSinceReferenceDate == 0 && cell.value.modified.secondsSinceReferenceDate == 1)
    #expect(cell.revision.index.rawValue == 5 && cell.scopeFrontier[0].index.rawValue == 7)
    #expect(cell.revision.id.bytes == Array(repeating: 6, count: 32))
    #expect(cell.encodedV1() == bytes && context.encodedV1() == contextBytes)
    #expect(context.operations == [cell.revision] && context.collectionActions == cell.scopeFrontier)
    #expect(throws: CanonicalEncodingError.trailingBytes) { try CurrentNoteCellV1.decodeV1(bytes + [0]) }
    #expect(throws: CanonicalEncodingError.trailingBytes) { try AuthoringContextV1.decodeV1(contextBytes + [0]) }
    for n in bytes.indices { #expect(throws: (any Error).self) { try CurrentNoteCellV1.decodeV1(Array(bytes.prefix(n))) } }
    for n in contextBytes.indices { #expect(throws: (any Error).self) { try AuthoringContextV1.decodeV1(Array(contextBytes.prefix(n))) } }
    var badCount = contextBytes; badCount.replaceSubrange(10..<14, with: [255, 255, 255, 255])
    #expect(throws: CanonicalEncodingError.truncated) { try AuthoringContextV1.decodeV1(badCount) }
}
