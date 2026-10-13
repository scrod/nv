import NVStorageTestSupport
import Foundation
import Testing
import NVStorageCore
@testable import NVStorageRuntime

func selectionFixture(_ encrypted: Bool) async throws -> (PrivateRepairEvidence, VerifiedReplacement, ObjectProtectionV1, String, SelectedStoreRecordV1) {
    let (initial, protection) = try testInitial(encrypted), session = try await newSession(initial, protection)
    _ = try await put("selected E", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 1, session: session)
    let s = await session.selection, id = try LocalAssociationID(bytes: uuidBytes())
    let association = try LocalAssociationV1(id: id, scope: PrivateRecordScopeV1(collection: s.descriptor.collection,
        store: s.store, descriptor: s.descriptor.descriptorID), bookmark: PassivePlatformRecordV1(codec: 1, bytes: [42]))
    try await session.saveLocalAssociation(association, basedOn: session.localAssociation())
    let record = try SelectedStoreRecordV1(association: id, store: s.store, generation: SelectionGeneration(bytes: uuidBytes()))
    let parent = privateTempPath()
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: false)
    try Data(record.encodedV1()).write(to: URL(fileURLWithPath: parent).appendingPathComponent("Selected Store"))
    let evidence = try await session.preserveForRepair(to: privateTempPath())
    let replacement = try await LocalStoreSession.buildVerifiedReplacement(to: privateTempPath(), primary: evidence, protection: protection)
    return (evidence, replacement, protection, parent, record)
}

@Test(arguments: [false, true])
func verifiedSelectionActivationAndFreshReopen(encrypted: Bool) async throws {
    let (source, replacement, protection, parent, original) = try await selectionFixture(encrypted)
    let owner = try await SelectedStoreOwner.open(directory: parent)
    await #expect(throws: (any Error).self) { try await SelectedStoreOwner.open(directory: parent) }
    let state = try await owner.capture()
    #expect(state.record == original)
    let result = try await replacement.activate(using: owner, basedOn: state)
    guard case .activated(let selected) = result else { Issue.record("verified cutover was not acknowledged"); return }
    let actual = try SelectedStoreRecordV1.decodeV1(Array(Data(contentsOf: URL(fileURLWithPath: parent).appendingPathComponent("Selected Store"))))
    #expect(actual == selected.record && actual.store == replacement.selection.store)
    #expect(actual.generation != original.generation && actual.association == original.association)
    let preserved = try FileManager.default.contentsOfDirectory(atPath: parent).filter {
        try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: parent).appendingPathComponent($0).path)[.type] as? FileAttributeType == .typeRegular && $0 != "Selected Store"
    }
    #expect(try preserved.contains { try Data(contentsOf: URL(fileURLWithPath: parent).appendingPathComponent($0)) == Data(original.encodedV1()) })
    try await replacement.close()
    let opened = try await LocalStoreSession.open(selection: replacement.selection, protection: protection)
    #expect(try await opened.snapshot().notes.map(\.value.body.string).sorted() == ["selected E", "untouched"])
    #expect(try await opened.localAssociation().value?.id == original.association)
    try await opened.quiesce()
    let old = try await LocalStoreSession.open(selection: source.selection, protection: protection)
    #expect(try await old.snapshot().notes.map(\.value.body.string).contains("selected E"))
    try await old.quiesce()
}

@Test(arguments: [false, true], [SelectionCut.beforeInstall, .afterInstall, .afterDurability])
func selectionFaultKeepsBothStoresAndHonestReadback(encrypted: Bool, cut: SelectionCut) async throws {
    let (source, replacement, protection, parent, original) = try await selectionFixture(encrypted)
    let owner = try await SelectedStoreOwner.open(directory: parent), state = try await owner.capture()
    await owner.setFault { if $0 == cut { throw StorageError.database(10) } }
    let result = try await replacement.activate(using: owner, basedOn: state)
    switch (cut, result) {
    case (.beforeInstall, .unchanged(let unchanged, _)): #expect(unchanged.record == original)
    case (.afterInstall, .uncertain), (.afterDurability, .uncertain): break
    default: Issue.record("fault result misstated selection durability")
    }
    let actual = try SelectedStoreRecordV1.decodeV1(Array(Data(contentsOf: URL(fileURLWithPath: parent).appendingPathComponent("Selected Store"))))
    #expect(actual.store == (cut == .beforeInstall ? original.store : replacement.selection.store))
    try await replacement.close()
    for selection in [source.selection, replacement.selection] {
        let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["selected E", "untouched"])
        try await reopened.quiesce()
    }
}

@Test(arguments: [false, true])
func selectionRefusesWrongOwnerStaleRecordAndNewSourceWAL(encrypted: Bool) async throws {
    let (source, replacement, protection, parent, original) = try await selectionFixture(encrypted)
    let otherDirectory = privateTempPath()
    try FileManager.default.createDirectory(atPath: otherDirectory, withIntermediateDirectories: false)
    let other = try await SelectedStoreOwner.open(directory: otherDirectory), wrong = try await other.capture()
    let owner = try await SelectedStoreOwner.open(directory: parent), state = try await owner.capture()
    await #expect(throws: StorageError.wrongContext) { try await replacement.activate(using: owner, basedOn: wrong) }
    let changed = try SelectedStoreRecordV1(association: original.association, store: original.store,
        generation: SelectionGeneration(bytes: uuidBytes()))
    let path = URL(fileURLWithPath: parent).appendingPathComponent("Selected Store")
    try Data(changed.encodedV1()).write(to: path, options: .atomic)
    await #expect(throws: StorageError.staleCapture) { try await replacement.activate(using: owner, basedOn: state) }
    let current = try await owner.capture()
    let newSource = try await LocalStoreSession.open(selection: source.selection, protection: protection)
    _ = try await put("new source WAL", birth: NoteBirth(bytes: Array(repeating: 1, count: 16)), generation: 2, session: newSource)
    // Preserve the WAL to exercise the journal observation rather than a checkpointed main-file change.
    try await newSource.closeForPreservedRepair()
    await #expect(throws: StorageError.staleCapture) { try await replacement.activate(using: owner, basedOn: current) }
    #expect(try SelectedStoreRecordV1.decodeV1(Array(Data(contentsOf: path))) == changed)
    try await replacement.close(); try await other.close()
}
