import Foundation
import Testing
import NVStorageCore
import NVStorageRuntime

func requireReceipt(_ outcome: CommitOutcome) throws -> AcceptedHistoryReceipt {
    switch outcome {
    case .accepted(let receipt): return receipt
    case .pending(_, let error): Issue.record("Commit remained pending: \(error)"); throw error
    }
}

@Test(arguments: [false, true]) func ordinaryEditDeleteAndCreateReopen(encrypted: Bool) async throws {
    let (initial, protection) = try testInitial(encrypted)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let session = try await LocalStoreSession.create(directory: path, initial: initial, protection: protection)
    let first = try await session.snapshot()
    let a = try #require(first.notes.first(where: { $0.value.body.string == "A" }))
    let editGeneration = try CapturedNoteGeneration(birth: a.birth, generation: 1)
    let edit = try CapturedActionGroup(snapshot: first, kind: .savedEdit, changes: [.put(editGeneration, testValue("edited"))])
    let receipt = try requireReceipt(await session.persist(capture: edit))
    #expect(receipt.covered == [editGeneration])
    #expect(receipt.sequence == 2)
    let second = try await session.snapshot()
    #expect(second.notes.map(\.value.body.string).sorted() == ["edited", "untouched"])
    let deletionGeneration = try CapturedNoteGeneration(birth: a.birth, generation: 2)
    let deletion = try CapturedActionGroup(snapshot: second, kind: .deleteBatch, changes: [.delete(deletionGeneration)])
    let deleted = try requireReceipt(await session.persist(capture: deletion))
    #expect(deleted.sequence == 3)
    let selection = await session.selection
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    let third = try await reopened.snapshot()
    #expect(third.notes.map(\.value.body.string) == ["untouched"])
    #expect(third.through == 3)
    #expect(third.context.operations.count == 1)
    let newBirth = try NoteBirth(bytes: Array(repeating: 17, count: 16))
    let creation = try CapturedActionGroup(snapshot: third, kind: .createImportBatch,
        changes: [.create(CapturedNoteGeneration(birth: newBirth, generation: 3), testValue("new"))])
    _ = try requireReceipt(await reopened.persist(capture: creation))
    let final = try await reopened.snapshot()
    #expect(final.notes.map(\.value.body.string).sorted() == ["new", "untouched"])
    try await reopened.quiesce()
}

@Test func wrongStoreAndOldSessionCapturesAreRejectedByPersist() async throws {
    let (initial, protection) = try testInitial(false)
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let session = try await LocalStoreSession.create(directory: path, initial: initial, protection: protection)
    let first = try await session.snapshot(), birth = try #require(first.notes.first).birth
    let capture = try CapturedActionGroup(snapshot: first, kind: .savedEdit,
        changes: [.put(CapturedNoteGeneration(birth: birth, generation: 1), testValue("captured"))])
    let otherPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let other = try await LocalStoreSession.create(directory: otherPath, initial: initial, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await other.persist(capture: capture) }
    try await other.quiesce()
    let selection = await session.selection
    try await session.quiesce()
    let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
    await #expect(throws: StorageError.wrongContext) { try await reopened.persist(capture: capture) }
    try await reopened.quiesce()
}
