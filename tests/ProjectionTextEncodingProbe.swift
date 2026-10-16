import Foundation

// Records exact bytes from both public Foundation entry points used by Swift and legacy NV.
struct EncodingObservation: Encodable {
    let name: String
    let encoding: UInt
    let input: String
    let inputUTF8: [UInt8]
    let swiftBytes: [UInt8]?
    let nsStringBytes: [UInt8]?
    let decodedUTF8: [UInt8]?
}

let encodings: [(String, String.Encoding)] = [
    ("ascii", .ascii), ("utf8", .utf8), ("latin1", .isoLatin1), ("latin2", .isoLatin2),
    ("macRoman", .macOSRoman), ("cp1252", .windowsCP1252), ("shiftJIS", .shiftJIS),
    ("nonLossyASCII", .nonLossyASCII), ("utf16", .utf16), ("utf16LE", .utf16LittleEndian),
    ("utf16BE", .utf16BigEndian), ("utf32", .utf32), ("utf32LE", .utf32LittleEndian), ("utf32BE", .utf32BigEndian)
]
var observations: [EncodingObservation] = []
for (name, encoding) in encodings {
    for input in ["", "A\r\nZ", "é", "e\u{301}", "日本語", "😀", "A\0Z"] {
        let swift = input.data(using: encoding, allowLossyConversion: false)
        let legacy = (input as NSString).data(using: encoding.rawValue, allowLossyConversion: false)
        let decoded = swift.flatMap { String(data: $0, encoding: encoding) }
        observations.append(.init(name: name, encoding: encoding.rawValue, input: input,
            inputUTF8: Array(input.utf8), swiftBytes: swift.map(Array.init), nsStringBytes: legacy.map(Array.init),
            decodedUTF8: decoded.map { Array($0.utf8) }))
    }
}
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
print(String(decoding: try encoder.encode(observations), as: UTF8.self))
