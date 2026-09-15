import Foundation
import Crypto
import NVStorageCore
import NVStorageRuntime
import Testing

func testValue(_ body: String) throws -> PlaintextNoteValue {
    try PlaintextNoteValue(title: ExactUTF8(bytes: Array("Title".utf8)), body: ExactUTF8(bytes: Array(body.utf8)),
        labels: CanonicalLabels([]), created: DisplayDate(secondsSinceReferenceDate: 0), modified: DisplayDate(secondsSinceReferenceDate: 1))
}
func testInitial(_ encrypted: Bool) throws -> (InitialCollectionV1, ObjectProtectionV1) {
    let protection: ObjectProtectionV1 = encrypted ? .encrypted(keyID: try CollectionKeyID(bytes: Array(repeating: 3, count: 16)),
        key: SymmetricKey(data: Array(repeating: 4, count: 32))) : .publicHash
    let collection = try CollectionID(bytes: Array(repeating: 1, count: 16))
    let notes = try [(NoteBirth(bytes: Array(repeating: 1, count: 16)), testValue("A")),
                     (NoteBirth(bytes: Array(repeating: 2, count: 16)), testValue("untouched"))]
    return (try InitialCollectionV1.build(collection: collection, notes: notes, protection: protection, passphrase: encrypted ? "synthetic" : nil), protection)
}

@Test(arguments: [false, true]) func bootstrapCommitsAndReopens(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let session = try await LocalStoreSession.create(directory: path, initial: initial, protection: protection)
    let captured = try await session.snapshot()
    #expect(captured.through == 1)
    #expect(captured.notes.map(\.value.body.string).sorted() == ["A", "untouched"])
    let selection = await session.selection
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let recovered = try await reopened.snapshot()
    #expect(recovered.notes == captured.notes)
    #expect(recovered.context == captured.context)
    try await reopened.quiesce()
    let wrong = LocalStoreSelection(directory: path, store: try LocalStoreID(bytes: Array(repeating: 90, count: 16)), descriptor: initial.descriptor)
    await #expect(throws: StorageError.wrongContext) { _ = try await LocalStoreSession.open(selection: wrong, protection: protection) }
}
