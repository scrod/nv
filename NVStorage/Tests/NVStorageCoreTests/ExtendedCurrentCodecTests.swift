import Foundation
import NVStorageCore
import Testing

@Test func extendedCurrentCellsAndFullRestoreHaveIndependentBytes() throws {
    let url = try #require(Bundle.module.url(forResource: "current-cell-v2", withExtension: "json", subdirectory: "Fixtures"))
    let text = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    let fixture = try text.mapValues { value in
        let chars = Array(value)
        return try stride(from: 0, to: chars.count, by: 2).map { try #require(UInt8(String(chars[$0...$0+1]), radix: 16)) }
    }
    for name in ["equalCell", "mergedCell", "automaticCell", "recoveryCell"] {
        let bytes = try #require(fixture[name]), cell = try CurrentNoteCellV1.decodeV1(bytes)
        #expect(cell.encodedV1() == bytes)
        #expect(cell.value.body.string == (name == "equalCell" ? "A\ngap\nz" : name == "mergedCell" ? "A\ngap\nZ" : "hi"))
        #expect(cell.represented.count == (name == "equalCell" || name == "mergedCell" ? 2 : 1))
        #expect((cell.automatic != nil) == (name == "automaticCell"))
        #expect((cell.identity != nil) == (name == "automaticCell" || name == "recoveryCell"))
        for cut in bytes.indices {
            #expect(throws: (any Error).self) { try CurrentNoteCellV1.decodeV1(Array(bytes.prefix(cut))) }
        }
        #expect(throws: CanonicalEncodingError.trailingBytes) { try CurrentNoteCellV1.decodeV1(bytes + [0]) }
        var changed = bytes; changed[9] = 3
        #expect(throws: CanonicalEncodingError.unsupportedFormat) { try CurrentNoteCellV1.decodeV1(changed) }
    }
    let locator = SegmentLocator(writerEpoch: try WriterEpoch(bytes: Array(repeating: 9, count: 16)), sequence: 0,
        segmentID: try SegmentID(bytes: Array(repeating: 10, count: 32)))
    let dependencies = try DependencyLocatorTable([locator])
    let birth = try NoteBirth(bytes: Array(repeating: 3, count: 16)), action = try ActionID(bytes: Array(repeating: 2, count: 16))
    let value = try PlaintextNoteValue(title: .init(bytes: [84]), body: .init(bytes: [104,105]), labels: .init([]), created: .init(secondsSinceReferenceDate: 0), modified: .init(secondsSinceReferenceDate: 1))
    let op = try IdentifiedOperation(nonce: .init(bytes: Array(repeating: 1, count: 16)), effect: .create(action: action, birth: birth, value: value),
        causalParents: .init([.init(bytes: Array(repeating: 6, count: 32))]), notePredecessors: .init([]))
    for name in ["equalRestore", "automaticRestore"] {
        let bytes = try #require(fixture[name]), record = try ActionRecordV1.decodeV1(bytes, dependencies: dependencies, operations: [op], earlierActions: [])
        #expect(try record.encodedV1(dependencies: dependencies, operations: [op], earlierActions: []) == bytes)
        let source = try #require(record.action.restorations.first)
        #expect(source.priorState?.represented.contains(source.revision) == true)
        #expect(source.birth == birth && source.sourceBirth != birth)
        for cut in bytes.indices { #expect(throws: (any Error).self) { try ActionRecordV1.decodeV1(Array(bytes.prefix(cut)), dependencies: dependencies, operations: [op], earlierActions: []) } }
        #expect(throws: CanonicalEncodingError.trailingBytes) { try ActionRecordV1.decodeV1(bytes + [0], dependencies: dependencies, operations: [op], earlierActions: []) }
    }
}

@Test func currentProvenanceKeepsValidNeighborsAndRejectsMixedClaims() throws {
    let url = try #require(Bundle.module.url(forResource: "current-cell-v2", withExtension: "json", subdirectory: "Fixtures"))
    let text = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    func bytes(_ name: String) throws -> [UInt8] {
        let characters = Array(try #require(text[name]))
        return try stride(from: 0, to: characters.count, by: 2).map { try #require(UInt8(String(characters[$0...$0+1]), radix: 16)) }
    }
    let equalBytes = try bytes("equalCell"), automaticBytes = try bytes("automaticCell")
    let equal = try CurrentNoteCellV1.decodeV1(equalBytes), automatic = try CurrentNoteCellV1.decodeV1(automaticBytes)
    guard case .derived(let claim) = equal.provenance, case .automatic = automatic.provenance else {
        Issue.record("The independent fixtures must exercise the two extended provenance forms"); return
    }
    let companion = try CurrentNoteCellV1(birth: equal.birth, value: equal.value, represented: equal.represented,
        heads: equal.heads, provenance: .derived(claim), scopeFrontier: equal.scopeFrontier)
    #expect(companion.encodedV1() == equalBytes)
    #expect(throws: CanonicalEncodingError.invalidReference) {
        try CurrentNoteCellV1(birth: equal.birth, value: equal.value, represented: equal.represented,
            heads: equal.heads, provenance: .revision, scopeFrontier: equal.scopeFrontier)
    }
    // Independent V2 framing has a 141-byte automatic field followed by a 34-byte identity field.
    let mixed = Array(equalBytes.dropLast(2)) + Array(automaticBytes[(automaticBytes.count-175)..<(automaticBytes.count-34)]) + [0]
    #expect(throws: CanonicalEncodingError.invalidReference) { try CurrentNoteCellV1.decodeV1(mixed) }
    #expect(automatic.encodedV1() == automaticBytes)
}
