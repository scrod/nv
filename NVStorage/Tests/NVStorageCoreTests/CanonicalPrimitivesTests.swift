import NVStorageCore
import Testing

@Test func literalUTF8Fixtures() throws {
// Literal expected bytes independently fix the canonical scalar encodings.
    let cases: [([UInt8], [UInt8])] = [
        ([], [0, 0, 0, 0]),
        ([0x61, 0, 0x62], [0, 0, 0, 3, 0x61, 0, 0x62]),
        ([0xc3, 0xa9], [0, 0, 0, 2, 0xc3, 0xa9]),
        ([0x65, 0xcc, 0x81], [0, 0, 0, 3, 0x65, 0xcc, 0x81]),
        ([0x0d, 0x0a], [0, 0, 0, 2, 0x0d, 0x0a])
    ]
    for (plain, encoded) in cases {
        let value = try ExactUTF8(bytes: plain)
        #expect(value.encodedV1() == encoded)
        #expect(try ExactUTF8.decodeV1(encoded).bytes == plain)
        for cut in 0..<encoded.count {
            #expect(throws: CanonicalEncodingError.truncated) {
                try ExactUTF8.decodeV1(Array(encoded.prefix(cut)))
            }
        }
        #expect(throws: CanonicalEncodingError.trailingBytes) {
            try ExactUTF8.decodeV1(encoded + [0])
        }
    }
}

@Test func exactSpellingAndOwnedInput() throws {
    let composed = try ExactUTF8(bytes: [0xc3, 0xa9])
    let decomposed = try ExactUTF8(bytes: [0x65, 0xcc, 0x81])
    #expect(composed != decomposed)
    #expect(Set([composed, decomposed]).count == 2)
    #expect(composed.string == decomposed.string) // String's equality is deliberately different.
    var input: [UInt8] = [0x61]
    let frozen = try ExactUTF8(bytes: input)
    input[0] = 0x62
    #expect(frozen.bytes == [0x61])
}

@Test(arguments: [[UInt8]([0xc0, 0x80]), [0xed, 0xa0, 0x80], [0xf4, 0x90, 0x80, 0x80], [0xc3], [0xff]])
func strictUTF8(bytes: [UInt8]) {
    #expect(throws: CanonicalEncodingError.invalidUTF8) { try ExactUTF8(bytes: bytes) }
}

@Test func lengthsCannotDriveUncheckedAllocation() {
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try ExactUTF8.decodeV1([0xff, 0xff, 0xff, 0xff])
    }
    #expect(throws: CanonicalEncodingError.truncated) {
        try ExactUTF8.decodeV1([4, 0, 0, 0]) // Exactly the object cap, but no body.
    }
    #expect(throws: CanonicalEncodingError.lengthLimit) {
        try ExactUTF8.decodeV1([4, 0, 0, 1])
    }
    #expect(ObjectLimitsV1.decodedPayloadBytes == 67_108_864)
    #expect(ObjectLimitsV1.encodedPayloadBytes == 67_174_400)
}

@Test func literalDateFixtures() throws {
    let cases: [(Double, [UInt8])] = [
        (0, [0, 0, 0, 0, 0, 0, 0, 0]),
        (1, [0x3f, 0xf0, 0, 0, 0, 0, 0, 0]),
        (-1, [0xbf, 0xf0, 0, 0, 0, 0, 0, 0]),
        (0.5, [0x3f, 0xe0, 0, 0, 0, 0, 0, 0]),
        (Double.leastNonzeroMagnitude, [0, 0, 0, 0, 0, 0, 0, 1])
    ]
    for (seconds, encoded) in cases {
        let value = try DisplayDate(secondsSinceReferenceDate: seconds)
        #expect(value.encodedV1() == encoded)
        #expect(try DisplayDate.decodeV1(encoded).secondsSinceReferenceDate == seconds)
        for cut in 0..<8 {
            #expect(throws: CanonicalEncodingError.truncated) {
                try DisplayDate.decodeV1(Array(encoded.prefix(cut)))
            }
        }
        #expect(throws: CanonicalEncodingError.trailingBytes) {
            try DisplayDate.decodeV1(encoded + [0])
        }
    }
    #expect(try DisplayDate(secondsSinceReferenceDate: -0.0).encodedV1() == [0, 0, 0, 0, 0, 0, 0, 0])
    #expect(throws: CanonicalEncodingError.noncanonicalDate) {
        try DisplayDate.decodeV1([0x80, 0, 0, 0, 0, 0, 0, 0])
    }
}

@Test(arguments: [Double.infinity, -.infinity, .nan])
func invalidDates(seconds: Double) {
    #expect(throws: CanonicalEncodingError.invalidDate) {
        try DisplayDate(secondsSinceReferenceDate: seconds)
    }
}

@Test(arguments: [[UInt8]([0x7f, 0xf0, 0, 0, 0, 0, 0, 0]), [0xff, 0xf0, 0, 0, 0, 0, 0, 0], [0x7f, 0xf8, 0, 0, 0, 0, 0, 1]])
func invalidDateEncodings(bytes: [UInt8]) {
    #expect(throws: CanonicalEncodingError.invalidDate) { try DisplayDate.decodeV1(bytes) }
}
