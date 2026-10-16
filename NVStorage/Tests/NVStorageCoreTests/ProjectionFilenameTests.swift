import Foundation
import Testing
@testable import NVStorageCore

private func nameText(_ value: String) throws -> ExactUTF8 { try .init(bytes: Array(value.utf8)) }
private func outputLeaf(_ value: String) throws -> ProjectionLeafNameV1 { try .init(nameText(value)) }
private func names(extensions: [String] = ["txt"], current: String? = nil,
                   notes: [String] = [], disk: [String] = []) throws -> ProjectionFilenameV1 {
    try .init(extensions: .init(extensions: extensions.map(nameText), chosen: 0),
              current: current.map(outputLeaf), otherNotes: notes.map(outputLeaf), occupied: disk.map(nameText))
}

@Test(arguments: ["slash", "hidden", "extension-case", "extension-change", "other-format", "disk-only",
                  "series", "title-extension", "case-rename", "nfd", "alias", "extensionless", "reserved", "trailing-dot"])
func projectionFilenameIndependentCases(_ key: String) throws {
    struct Fixture: Decodable {
        let name: String, title: String, extensions: [String], current: String?
        let otherNotes: [String], occupied: [String], expected: String
    }
    let url = try #require(Bundle.module.url(forResource: "projection-filename", withExtension: "json", subdirectory: "Fixtures"))
    let fixture = try #require(JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)).first { $0.name == key })
    let policy = try names(extensions: fixture.extensions, current: fixture.current, notes: fixture.otherNotes, disk: fixture.occupied)
    #expect(try policy.filename(for: nameText(fixture.title)).spelling.bytes == Array(fixture.expected.utf8))
}

@Test(arguments: [246, 247, 248])
func projectionFilenameUTF16Budget(_ count: Int) throws {
    let result = try names().filename(for: nameText(String(repeating: "a", count: count)))
    #expect(result.spelling.string == String(repeating: "a", count: min(count, 247)) + ".txt")
    let scalarBoundary = try names().filename(for: nameText(String(repeating: "a", count: 246) + "😀"))
    #expect(scalarBoundary.spelling.string == String(repeating: "a", count: 246) + ".txt")
    let combiningBoundary = try names().filename(for: nameText(String(repeating: "a", count: 246) + "e\u{301}"))
    #expect(combiningBoundary.spelling.bytes == Array((String(repeating: "a", count: 246) + "e.txt").utf8))
}

@Test(arguments: ["same", "case", "normalization"])
func projectionFilenameRejectsAmbiguousInventory(_ kind: String) throws {
    let disk = kind == "same" ? ["Same.txt", "Same.txt"] : kind == "case" ? ["Same.txt", "same.txt"] : ["Café.txt", "Cafe\u{301}.txt"]
    #expect(throws: ProjectionFilenameError.ambiguousInventory) { try names(current: disk[0], disk: disk) }
}

@Test func projectionFilenameRejectsUnsafeInputs() throws {
    for title in ["", "a\0b"] {
        #expect(throws: ProjectionFilenameError.invalidTitle) { try names().filename(for: nameText(title)) }
    }
    for ext in ["/txt", "a/b", ".txt", "txt ", "a\0b"] {
        #expect(throws: ProjectionFilenameError.invalidExtension) { try names(extensions: [ext]) }
    }
    #expect(throws: ProjectionFilenameError.lengthLimit) {
        try names(extensions: [String(repeating: "x", count: 250)]).filename(for: nameText("a"))
    }
    let maximum = try names(extensions: [String(repeating: "x", count: 249)]).filename(for: nameText("ab"))
    #expect(maximum.spelling.string == "a." + String(repeating: "x", count: 249))
}

@Test(arguments: [64, 256, 1024])
func projectionFilenameUsesCapturedInventory(_ count: Int) throws {
    let occupied = ["Note.txt"] + (1...count).map { "NOTE.\($0).txt" }
    let policy = try names(disk: occupied)
    let result = try policy.filename(for: nameText("Note"))
    #expect(result.spelling.string == "Note.\(count + 1).txt")
    #expect(try policy.filename(for: nameText("Note")) == result)
}
