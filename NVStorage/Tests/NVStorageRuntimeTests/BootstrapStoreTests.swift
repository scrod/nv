import NVStorageTestSupport
import Foundation
import Crypto
import NVStorageCore
import NVStorageRuntime
import Testing

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
