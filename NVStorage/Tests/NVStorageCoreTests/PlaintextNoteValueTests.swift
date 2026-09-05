import NVStorageCore
import Testing

@Test func literalNoteValueFixture() throws {
    // Format 1, title "A", body "b\n", labels {"Work", "work"}, dates 0 and 1.
    let bytes: [UInt8] = [
        1, 0, 0, 0, 1, 0x41, 0, 0, 0, 2, 0x62, 0x0a,
        0, 0, 0, 2, 0, 0, 0, 4, 0x57, 0x6f, 0x72, 0x6b,
        0, 0, 0, 4, 0x77, 0x6f, 0x72, 0x6b,
        0, 0, 0, 0, 0, 0, 0, 0, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0
    ]
    let value = try PlaintextNoteValue(
        title: ExactUTF8(bytes: [0x41]), body: ExactUTF8(bytes: [0x62, 0x0a]),
        labels: CanonicalLabels([ExactUTF8(bytes: Array("work".utf8)), ExactUTF8(bytes: Array("Work".utf8))]),
        created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 1))
    #expect(value.encodedV1() == bytes)
    #expect(try PlaintextNoteValue.decodeV1(bytes) == value)
    for cut in 0..<bytes.count {
        #expect(throws: CanonicalEncodingError.truncated) {
            try PlaintextNoteValue.decodeV1(Array(bytes.prefix(cut)))
        }
    }
    #expect(throws: CanonicalEncodingError.trailingBytes) {
        try PlaintextNoteValue.decodeV1(bytes + [0])
    }
    var reversedLabels = bytes
    reversedLabels[20] = 0x77
    reversedLabels[28] = 0x57
    #expect(throws: CanonicalEncodingError.noncanonicalLabels) {
        try PlaintextNoteValue.decodeV1(reversedLabels)
    }
    var duplicateLabels = bytes
    duplicateLabels[28] = 0x57
    #expect(throws: CanonicalEncodingError.noncanonicalLabels) {
        try PlaintextNoteValue.decodeV1(duplicateLabels)
    }
    var unsupported = bytes
    unsupported[0] = 2
    #expect(throws: CanonicalEncodingError.unsupportedFormat) {
        try PlaintextNoteValue.decodeV1(unsupported)
    }
}

@Test func labelsPreserveSpellingWithoutImportingHostIndexEquality() throws {
    let labels = try CanonicalLabels([ExactUTF8(bytes: [0xc3, 0xa9]), ExactUTF8(bytes: [0x65, 0xcc, 0x81])])
    #expect(labels.entries.map(\.bytes) == [[0x65, 0xcc, 0x81], [0xc3, 0xa9]])
    #expect(throws: CanonicalEncodingError.noncanonicalLabels) {
        try CanonicalLabels([ExactUTF8(bytes: [0x61]), ExactUTF8(bytes: [0x61])])
    }
    #expect(throws: CanonicalEncodingError.noncanonicalLabels) {
        try CanonicalLabels([ExactUTF8(bytes: [])])
    }
}

@Test func noteLimitIncludesAllFields() throws {
    // The complete empty-title/empty-label record has 29 bytes of overhead.
    // Literal limit: independent of the production constant and size formula.
    let limit = 67_108_864
    let title = try ExactUTF8(bytes: [])
    let labels = try CanonicalLabels([])
    let date = try DisplayDate(secondsSinceReferenceDate: 0)
    for count in [limit - 30, limit - 29] {
        let value = try PlaintextNoteValue(title: title,
            body: ExactUTF8(bytes: Array(repeating: 0x61, count: count)),
            labels: labels, created: date, modified: date)
        #expect(value.encodedV1().count == count + 29)
    }
    let tooLarge = try ExactUTF8(bytes: Array(repeating: 0x61, count: limit - 28))
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try PlaintextNoteValue(title: title, body: tooLarge, labels: labels, created: date, modified: date)
    }
}

@Test func emptyBodyIsAValueAndAttackerLabelCountCannotAllocate() throws {
    let empty = try PlaintextNoteValue(title: ExactUTF8(bytes: []), body: ExactUTF8(bytes: []),
        labels: CanonicalLabels([]), created: DisplayDate(secondsSinceReferenceDate: 0),
        modified: DisplayDate(secondsSinceReferenceDate: 0))
    let expected: [UInt8] = [1] + Array(repeating: 0, count: 28)
    #expect(empty.encodedV1() == expected)
    #expect(try PlaintextNoteValue.decodeV1(expected) == empty)
    let later = try PlaintextNoteValue(title: empty.title, body: empty.body, labels: empty.labels,
        created: empty.created, modified: DisplayDate(secondsSinceReferenceDate: 1))
    #expect(later != empty)
    #expect(later.encodedV1() != empty.encodedV1())
    #expect(later.hasSameEditableFields(as: empty))
    let edited = try PlaintextNoteValue(title: empty.title, body: ExactUTF8(bytes: [0x61]),
        labels: empty.labels, created: empty.created, modified: empty.modified)
    #expect(!edited.hasSameEditableFields(as: empty))
    let renamed = try PlaintextNoteValue(title: ExactUTF8(bytes: [0x61]), body: empty.body,
        labels: empty.labels, created: empty.created, modified: empty.modified)
    let tagged = try PlaintextNoteValue(title: empty.title, body: empty.body,
        labels: CanonicalLabels([ExactUTF8(bytes: [0x61])]), created: empty.created, modified: empty.modified)
    #expect(!renamed.hasSameEditableFields(as: empty))
    #expect(!tagged.hasSameEditableFields(as: empty))
    var malformed = expected
    malformed.replaceSubrange(9..<13, with: [0xff, 0xff, 0xff, 0xff])
    #expect(throws: CanonicalEncodingError.truncated) {
        try PlaintextNoteValue.decodeV1(malformed)
    }
}
