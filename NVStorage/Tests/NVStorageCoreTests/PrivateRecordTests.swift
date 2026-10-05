import Foundation
import Testing
import NVStorageCore

@Test func privateRecordIndependentBytesAndBounds() throws {
    let file = try #require(Bundle.module.url(forResource: "private-records", withExtension: "json", subdirectory: "Fixtures"))
    let strings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    let literals = try strings.mapValues { string in
        let chars = Array(string)
        return try stride(from: 0, to: chars.count, by: 2).map { try #require(UInt8(String(chars[$0...$0+1]), radix: 16)) }
    }
    let decoders: [String: ([UInt8]) throws -> [UInt8]] = [
        "settings": { try CollectionSettingsV1.decodeV1($0).encodedV1() },
        "association": { try LocalAssociationV1.decodeV1($0).encodedV1() },
        "snapshot": { try PendingSnapshotV1.decodeV1($0).encodedV1() },
        "reservation": { try PendingReservationV1.decodeV1($0).encodedV1() },
        "neutralReservation": { try PendingReservationV1.decodeV1($0).encodedV1() }
    ]
    for (name, decode) in decoders {
        let bytes = try #require(literals[name])
        #expect(try decode(bytes) == bytes)
        for cut in bytes.indices { #expect(throws: (any Error).self) { try decode(Array(bytes.prefix(cut))) } }
        #expect(throws: CanonicalEncodingError.trailingBytes) { try decode(bytes + [0]) }
        var unsupported = bytes; unsupported[9] = 2
        #expect(throws: CanonicalEncodingError.unsupportedFormat) { try decode(unsupported) }
    }
    let settings = try CollectionSettingsV1.decodeV1(#require(literals["settings"]))
    #expect(settings.fields.count == 5)
    #expect(settings.fields[1] == .secureTextEntry(true))
    let snapshot = try PendingSnapshotV1.decodeV1(#require(literals["snapshot"]))
    #expect(snapshot.source == Array("body".utf8) && snapshot.value.body.string == "body")
    #expect(snapshot.path.string == "T.txt" && snapshot.scope.store.bytes == Array(repeating: 2, count: 16))
    let currentFile = try #require(Bundle.module.url(forResource: "current-cell-v2", withExtension: "json", subdirectory: "Fixtures"))
    let currentLiterals = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: currentFile))
    let characters = Array(try #require(currentLiterals["equalCell"]))
    let currentBytes = try stride(from: 0, to: characters.count, by: 2).map { try #require(UInt8(String(characters[$0...$0+1]), radix: 16)) }
    let cell = try CurrentNoteCellV1.decodeV1(currentBytes)
    let neutral = try PendingReservationV1.decodeV1(#require(literals["neutralReservation"]))
    #expect(neutral.effect == .neutral(try PendingNeutralStateV1(cell: cell)))
    #expect(throws: CanonicalEncodingError.noncanonicalSet) { try CollectionSettingsV1([.secureTextEntry(true), .secureTextEntry(false)]) }
    #expect(throws: CanonicalEncodingError.unsupportedFormat) { try CollectionSettingsV1([.storageFormat(4)]) }
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try RememberedCursorV1(birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), anchor: UInt64.max, length: 1)
    }
}
