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

@Test(arguments: [false, true], [SelectionCut.beforeInstall, .afterInstall, .beforeDurability, .afterDurability])
func selectionFaultKeepsBothStoresAndHonestReadback(encrypted: Bool, cut: SelectionCut) async throws {
    let (source, replacement, protection, parent, original) = try await selectionFixture(encrypted)
    let owner = try await SelectedStoreOwner.open(directory: parent), state = try await owner.capture()
    await owner.setFault { if $0 == cut { throw StorageError.database(10) } }
    let result = try await replacement.activate(using: owner, basedOn: state)
    switch (cut, result) {
    case (.beforeInstall, .unchanged(let unchanged, _)): #expect(unchanged.record == original)
    case (.afterInstall, .uncertain), (.beforeDurability, .uncertain), (.afterDurability, .uncertain): break
    default: Issue.record("fault result misstated selection durability")
    }
    let actual = try SelectedStoreRecordV1.decodeV1(Array(Data(contentsOf: URL(fileURLWithPath: parent).appendingPathComponent("Selected Store"))))
    #expect(actual.store == (cut == .beforeInstall ? original.store : replacement.selection.store))
    if cut != .beforeInstall {
        await #expect(throws: (any Error).self) { try await LocalStoreSession.open(selection: source.selection, protection: protection) }
    }
    try await owner.close()
    try await replacement.close()
    for selection in [source.selection, replacement.selection] {
        let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["selected E", "untouched"])
        try await reopened.quiesce()
    }
}

@Test(arguments: [false, true])
func selectionResumptionChecksPhysicalIdentityAndCandidate(encrypted: Bool) async throws {
    let (_, replacement, _, parent, _) = try await selectionFixture(encrypted)
    let owner = try await SelectedStoreOwner.open(directory: parent), state = try await owner.capture()
    await owner.setFault { if $0 == .afterInstall { throw StorageError.database(10) } }
    guard case .uncertain(let expected, _) = try await replacement.activate(using: owner, basedOn: state) else {
        throw StorageError.incomplete
    }
    let bytes = try #require(expected).encodedV1()
    let (_, wrong, _, _, _) = try await selectionFixture(encrypted)
    await #expect(throws: StorageError.wrongContext) { try await wrong.resumeActivation(using: owner) }
    try await wrong.close()
    await #expect(throws: StorageError.busy) { try await owner.capture() }
    await #expect(throws: (any Error).self) { try await SelectedStoreOwner.open(directory: parent) }
    let destination = URL(fileURLWithPath: parent + "/Selected Store")
    // An identical-byte replacement exercises the held installed item's physical identity.
    try Data(bytes).write(to: destination, options: .atomic)
    await owner.setFault(nil)
    let result = try await replacement.resumeActivation(using: owner)
    let refused: Bool
    if case .uncertain(let observed, _) = result {
        refused = true
        #expect(observed == expected)
    } else {
        refused = false
    }
    #expect(refused)
    #expect(try Data(contentsOf: destination) == Data(bytes))
    try await owner.close(); try await replacement.close()
    let fresh = try await SelectedStoreOwner.open(directory: parent)
    #expect(try await fresh.capture().record == expected)
    try await fresh.close()
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

enum SelectionCancellation: CaseIterable, Sendable {
    case beforeCall, beforeInstall, afterInstall, pendingResumption
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true], SelectionCancellation.allCases)
func selectionCancellationPreservesEffectBoundary(encrypted: Bool, cut: SelectionCancellation) async throws {
    let (source, replacement, protection, parent, original) = try await selectionFixture(encrypted)
    let sourceURL = URL(fileURLWithPath: source.selection.directory + "/Collection.sqlite")
    let sourceBytes = try Data(contentsOf: sourceURL)
    let selectedURL = URL(fileURLWithPath: parent + "/Selected Store")
    let owner = try await SelectedStoreOwner.open(directory: parent), before = try await owner.capture()
    await owner.setFault { point in
        if (cut == .beforeInstall && point == .beforeInstall) || (cut == .afterInstall && point == .afterInstall) {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        if cut == .pendingResumption && point == .afterInstall { throw StorageError.database(10) }
    }
    let attempt = Task {
        if cut == .beforeCall { withUnsafeCurrentTask { $0?.cancel() } }
        return try await replacement.activate(using: owner, basedOn: before)
    }
    let result = await attempt.result
    switch cut {
    case .beforeCall:
        let cancelled = if case .failure(let error) = result { error is CancellationError } else { false }
        #expect(cancelled, "Cancellation before selection admission preserves the original selection")
        guard cancelled else {
            try await owner.close(); try await replacement.close(); return
        }
        #expect(try await owner.capture().record == original)
    case .beforeInstall:
        let unchanged = if case .success(.unchanged) = result { true } else { false }
        #expect(unchanged, "Cancellation at the final pre-install check leaves selection unchanged")
        guard case .success(.unchanged(let state, let error)) = result else {
            try await owner.close(); try await replacement.close(); return
        }
        #expect(state.record == original && error == .cancelled)
    case .afterInstall:
        guard case .success(.activated(let state)) = result else {
            Issue.record("An admitted selection effect must finish its durability checks")
            try await owner.close(); try await replacement.close(); return
        }
        #expect(state.record?.store == replacement.selection.store)
    case .pendingResumption:
        guard case .success(.uncertain(let observed, _)) = result else { throw StorageError.incomplete }
        #expect(observed?.store == replacement.selection.store)
        await owner.setFault(nil)
        let retry = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await replacement.resumeActivation(using: owner)
        }
        let retryResult = await retry.result
        let cancelled = if case .failure(let error) = retryResult { error is CancellationError } else { false }
        #expect(cancelled, "Cancelled resumption retains the pending selection for another attempt")
        guard cancelled else {
            try await owner.close(); try await replacement.close(); return
        }
        await #expect(throws: StorageError.busy) { try await owner.capture() }
        await #expect(throws: (any Error).self) { try await LocalStoreSession.open(selection: source.selection, protection: protection) }
        #expect(try SelectedStoreRecordV1.decodeV1(Array(Data(contentsOf: selectedURL))) == observed)
        guard case .activated(let resumed) = try await replacement.resumeActivation(using: owner) else { throw StorageError.incomplete }
        #expect(resumed.record == observed)
    }
    let actual = try SelectedStoreRecordV1.decodeV1(Array(Data(contentsOf: selectedURL)))
    if cut == .beforeCall || cut == .beforeInstall {
        #expect(actual.store == original.store)
    } else {
        #expect(actual.store == replacement.selection.store)
    }
    try await owner.close(); try await replacement.close()
    #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    for selection in [source.selection, replacement.selection] {
        let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["selected E", "untouched"])
        try await reopened.quiesce()
    }
}

@Test(arguments: [false, true], [false, true])
func selectionClosedCandidatePreservesPendingExclusion(encrypted: Bool, installed: Bool) async throws {
    let (source, replacement, protection, parent, original) = try await selectionFixture(encrypted)
    let owner = try await SelectedStoreOwner.open(directory: parent), before = try await owner.capture()
    let savedEvidence = replacement
    var expected = original
    if installed {
        await owner.setFault { if $0 == .afterInstall { throw StorageError.database(10) } }
        guard case .uncertain(let observed, _) = try await replacement.activate(using: owner, basedOn: before) else {
            throw StorageError.incomplete
        }
        expected = try #require(observed)
    }
    try await replacement.close(); try await replacement.close()
    if installed {
        await #expect(throws: StorageError.closed) { try await savedEvidence.resumeActivation(using: owner) }
        await #expect(throws: StorageError.busy) { try await owner.capture() }
        await #expect(throws: (any Error).self) { try await LocalStoreSession.open(selection: source.selection, protection: protection) }
    } else {
        await #expect(throws: StorageError.closed) { try await savedEvidence.activate(using: owner, basedOn: before) }
        #expect(try await owner.capture().record == original)
    }
    #expect(try SelectedStoreRecordV1.decodeV1(Array(Data(contentsOf: URL(fileURLWithPath: parent + "/Selected Store")))) == expected)
    try await owner.close(); try await owner.close()
    let nextOwner = try await SelectedStoreOwner.open(directory: parent)
    #expect(try await nextOwner.capture().record == expected)
    try await nextOwner.close()
    for selection in [source.selection, replacement.selection] {
        let reopened = try await LocalStoreSession.open(selection: selection, protection: protection)
        #expect(try await reopened.snapshot().notes.map(\.value.body.string).sorted() == ["selected E", "untouched"])
        try await reopened.quiesce()
    }
}
