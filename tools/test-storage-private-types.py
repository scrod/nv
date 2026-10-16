#!/usr/bin/env python3
"""Challenge private-state, repair and copy evidence through ordinary and sibling clients."""
import argparse
import importlib.util
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('checks', ROOT/'tools/test-swift-storage-types.py')
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modules', type=Path, required=True)
    parser.add_argument('--batch-size', type=checks.batch_size, default=8,
                        help='Maximum compatible negative clients per compile; 1 preserves isolated checking.')
    args = parser.parse_args()
    modules = args.modules.resolve()
    cases = [('production companions', '''
func use(_ s: LocalStoreSession, _ item: PendingItemID, _ replacement: VerifiedReplacement,
         _ owner: SelectedStoreOwner, _ state: SelectedStoreState, _ target: String) async throws {
    let settings = try await s.collectionSettings()
    try await s.saveCollectionSettings(settings.value, basedOn: settings)
    let prepared = try await s.preparePendingImport(basedOn: s.pendingItem(item), automatic: false)
    _ = try await s.persistPendingAction(prepared)
    _ = try await s.backupPrivateStore(to: target)
    _ = try await replacement.activate(using: owner, basedOn: state)
    _ = try await replacement.resumeActivation(using: owner)
    _ = try await CollectionSession.resumePrivateRepair(replacement, using: owner)
    _ = try await RepositoryCopy.preserveAvailable(from: target, to: target + "-copy")
}
func ownedCopy(_ store: LocalStoreSession, _ root: RepositoryRootSession, _ target: String) async throws {
    _ = try await RepositoryCopy.preserveAvailable(from: root, to: target)
    _ = try await store.copyRepositoryAndSavedWork(from: root, to: target)
}
func integratedCopy(_ collection: CollectionSession, _ target: String) async throws {
    _ = try await collection.copyRepositoryAndSavedWork(to: target)
}
func integratedSwitch(_ collection: CollectionSession, _ owner: SelectedStoreOwner,
                      _ state: SelectedStoreState, _ target: String) async throws {
    _ = try await collection.switchRepositoryAndSavedWork(to: target, privateDirectory: target + "-private", using: owner, basedOn: state)
    _ = try await collection.resumeCopySwitch()
}
func replacementAttemptIdentity(_ value: ProjectionReplacementAttemptID) -> ProjectionReplacementAttemptID { value }
func projection(_ store: LocalStoreSession, _ birth: NoteBirth, _ name: ProjectionLeafNameV1) async throws {
    let previous = try await store.projectionObservations(for: birth)
    let prepared = try await store.prepareProjectionIntent(for: birth, filename: name,
        basedOn: store.snapshot(), observations: previous)
    try await store.retainProjectionIntent(prepared)
    _ = try await store.freezeProjectionIntent(observations: store.projectionObservations(for: birth))
    _ = try await store.prepareProjectionCreation(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
    _ = try await store.prepareProjectionReplacement(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
    _ = try await store.pendingProjectionReplacement(for: birth)
}
func projectionHistory(_ store: LocalStoreSession, _ stamp: ProjectionStampV1) async throws {
    let snapshot = try await store.snapshot()
    if case .checked(let history) = try await store.projectionHistory(for: stamp, basedOn: snapshot) {
        _ = try await store.projectionValue(from: history, basedOn: snapshot)
    }
}
func completeProjectionHistory(_ store: LocalStoreSession, _ binding: ProjectionBindingV1) async throws {
    let snapshot = try await store.snapshot()
    if case .checked(let history) = try await store.projectionHistory(for: binding, basedOn: snapshot) {
        _ = try await store.projectionValue(fromBinding: history, basedOn: snapshot)
    }
}
func projectionProducer(_ store: LocalStoreSession, _ output: ProjectionOutputV1) async throws {
    let handle = try await store.prepareProjectionDescription(for: output,
        observations: store.projectionObservations(for: output.binding.birth), basedOn: store.snapshot())
    switch try await store.persistProjectionDescription(handle) {
    case .accepted(let receipt): _ = receipt.object
    case .pending(let retry, _): _ = try await store.persistProjectionDescription(retry)
    }
}
''', None)]
    cases.append(('replacement attempt and note birth roles', '''
func wrong(_ birth: NoteBirth) { let _: ProjectionReplacementAttemptID = birth } // expected-error
''', "cannot convert value of type 'NoteBirth' to specified type 'ProjectionReplacementAttemptID'"))
    cases.append(('source and replacement attempt roles', '''
func wrong(_ value: ProjectionReplacementAttemptID) { let _: ProjectionSourceAttemptID = value } // expected-error
''', "cannot convert value of type 'ProjectionReplacementAttemptID' to specified type 'ProjectionSourceAttemptID'"))
    for name, expression, parameters in [
        ('CollectionSettingsState', 'generation: 1, value: v, store: s.store, session: UUID()', '_ s: LocalStoreSelection, _ v: CollectionSettingsV1'),
        ('LocalAssociationState', 'generation: 1, value: nil, store: s.store, session: UUID()', '_ s: LocalStoreSelection'),
        ('ProjectionObservationState', 'birth: b, generation: 1, value: nil, store: s.store, session: UUID()', '_ s: LocalStoreSelection, _ b: NoteBirth'),
        ('PreparedProjectionIntent', 'output: o, bytes: [], snapshot: s, previous: p, association: a, associationGeneration: 1, connection: UUID()', '_ o: ProjectionOutputV1, _ s: StoreSnapshot, _ p: ProjectionObservationState, _ a: LocalAssociationV1'),
        ('PreparedProjectionCreation', 'output: o, bytes: [], value: v, association: a, associationGeneration: 1, snapshot: s, connection: UUID()', '_ o: ProjectionOutputV1, _ v: PlaintextNoteValue, _ a: LocalAssociationV1, _ s: StoreSnapshot'),
        ('PreparedProjectionReplacement', 'output: o, bytes: [], value: v, source: p, sourceBytes: [], association: a, associationGeneration: 1, snapshot: s, connection: UUID()', '_ o: ProjectionOutputV1, _ v: PlaintextNoteValue, _ p: AcceptedProjectionV1, _ a: LocalAssociationV1, _ s: StoreSnapshot'),
        ('ProjectionDescriptionHandle', 'object: l, binding: b, bytes: [], store: s, session: UUID()', '_ l: SegmentLocator, _ b: ProjectionBindingV1, _ s: LocalStoreID'),
        ('AcceptedProjectionDescriptionReceipt', 'handle: h, sequence: 1', '_ h: ProjectionDescriptionHandle'),
        ('CheckedProjectionHistory', 'stamp: p, value: v, snapshot: s, connection: UUID()', '_ p: ProjectionStampV1, _ v: PlaintextNoteValue, _ s: StoreSnapshot'),
        ('CheckedProjectionBindingHistory', 'binding: p, value: v, snapshot: s, connection: UUID()', '_ p: ProjectionBindingV1, _ v: PlaintextNoteValue, _ s: StoreSnapshot'),
        ('PendingItemState', 'id: id, generation: 1, latest: nil, store: s.store, session: UUID()', '_ s: LocalStoreSelection, _ id: PendingItemID'),
        ('PreparedPendingAction', 'reservation: r, capture: c', '_ r: PendingReservationV1, _ c: CapturedActionGroup'),
        ('PendingSettlement', 'record: r', '_ r: PendingSettlementV1'),
        ('CompletePrivateBackup', 'selection: s, through: 1', '_ s: LocalStoreSelection'),
        ('PrivateRepairEvidence', 'selection: s, workingDirectory: "x", accepted: [], objects: [], privateTables: [:], bootstrap: s.descriptor.genesis, missing: [], observation: []', '_ s: LocalStoreSelection'),
        ('PartialPrivateSalvage', 'directory: "x", failures: [:], objects: 0, committed: 0', ''),
        ('VerifiedReplacement', 'candidate: c, selection: s, through: 1, sources: []', '_ c: LocalStoreSession, _ s: LocalStoreSelection'),
        ('SelectedStoreState', 'record: nil, owner: UUID(), parent: []', ''),
        ('RepositoryCopyResult', 'destination: "x", files: [], issues: [], requirements: []', ''),
        ('ActiveRepositoryCopy', 'repository: r, through: 1, pending: 0, receipts: []', '_ r: RepositoryCopyResult'),
        ('CollectionCopySwitchResult', 'copy: c, outcome: .sourceRetained(cause: .incomplete)', '_ c: ActiveRepositoryCopy'),
        ('RepositoryRepairSourceIssue', 'sourceIndex: 0, path: "x", failure: .store(.integrity)', ''),
        ('CurrentCollectionExport', 'selection: s, repository: r, births: []', '_ s: LocalStoreSelection, _ r: RepositoryCopyResult'),
    ]:
        cases.append((name + ' issuer', f'func wrong({parameters}) {{ _ = {name}({expression}) }} // expected-error\n',
                      f"'{name}' initializer is inaccessible due to 'fileprivate' protection level"))
    cases.append(('health versus replacement', '''
func take(_ r: VerifiedReplacement) {}
func wrong(_ report: StorageHealthReport) { take(report) } // expected-error
''', "cannot convert value of type 'StorageHealthReport' to expected argument type 'VerifiedReplacement'"))
    cases.append(('passive output versus checked intent', '''
func wrong(_ store: LocalStoreSession, _ output: ProjectionOutputV1) async throws {
    try await store.retainProjectionIntent(output) // expected-error
}
''', "cannot convert value of type 'ProjectionOutputV1' to expected argument type 'PreparedProjectionIntent'"))
    cases.append(('immutable projection output', '''
func wrong(_ prepared: inout PreparedProjectionIntent, _ output: ProjectionOutputV1) {
    prepared.output = output // expected-error
}
''', "cannot assign to property: 'output' is a 'let' constant"))
    cases.append(('passive observation versus frozen owner', '''
func wrong(_ store: LocalStoreSession, _ value: ProjectionObservationsV1) async throws {
    _ = try await store.freezeProjectionIntent(observations: value) // expected-error
}
''', "cannot convert value of type 'ProjectionObservationsV1' to expected argument type 'ProjectionObservationState'"))
    cases.append(('immutable frozen output', '''
func wrong(_ value: inout ProjectionObservationsV1) {
    value.frozen = nil // expected-error
}
''', "cannot assign to property: 'frozen' is a 'let' constant"))
    cases.append(('immutable prepared projection bytes', '''
func wrong(_ prepared: inout PreparedProjectionIntent) {
    prepared.bytes = [0] // expected-error
}
''', "cannot assign to property: 'bytes' is a 'let' constant"))
    cases.append(('passive stamp versus checked history', '''
func wrong(_ store: LocalStoreSession, _ stamp: ProjectionStampV1, _ snapshot: StoreSnapshot) async throws {
    _ = try await store.projectionValue(from: stamp, basedOn: snapshot) // expected-error
}
''', "cannot convert value of type 'ProjectionStampV1' to expected argument type 'CheckedProjectionHistory'"))
    cases.append(('projection contents require checked consumer', '''
func wrong(_ history: CheckedProjectionHistory) { _ = history.value } // expected-error
''', "'value' is inaccessible due to 'private' protection level"))
    cases.append(('passive binding versus checked history', '''
func wrong(_ store: LocalStoreSession, _ binding: ProjectionBindingV1, _ snapshot: StoreSnapshot) async throws {
    _ = try await store.projectionValue(fromBinding: binding, basedOn: snapshot) // expected-error
}
''', "cannot convert value of type 'ProjectionBindingV1' to expected argument type 'CheckedProjectionBindingHistory'"))
    cases.append(('binding contents require checked consumer', '''
func wrong(_ history: CheckedProjectionBindingHistory) { _ = history.value } // expected-error
''', "'value' is inaccessible due to 'private' protection level"))
    cases.append(('immutable checked binding', '''
func wrong(_ history: inout CheckedProjectionBindingHistory, _ binding: ProjectionBindingV1) {
    history.binding = binding // expected-error
}
''', "cannot assign to property: 'binding' is a 'let' constant"))
    cases.append(('private producer bytes', '''
func wrong(_ handle: ProjectionDescriptionHandle) { _ = handle.bytes } // expected-error
''', "'bytes' is inaccessible due to 'fileprivate' protection level"))
    cases.append(('immutable producer locator', '''
func wrong(_ handle: inout ProjectionDescriptionHandle, _ locator: SegmentLocator) {
    handle.object = locator // expected-error
}
''', "cannot assign to property: 'object' is a 'let' constant"))
    cases.append(('description versus saved action receipt', '''
func saved(_ receipt: AcceptedHistoryReceipt) {}
func wrong(_ receipt: AcceptedProjectionDescriptionReceipt) { saved(receipt) } // expected-error
''', "cannot convert value of type 'AcceptedProjectionDescriptionReceipt' to expected argument type 'AcceptedHistoryReceipt'"))
    cases.append(('repair object reference visibility', '''
func wrong() { _ = RepairObjectReference.self } // expected-error
''', ("cannot find 'RepairObjectReference' in scope", "'RepairObjectReference' is inaccessible due to 'fileprivate' protection level")))
    cases.append(('projection retention evidence visibility', '''
func wrong() { _ = CheckedProjectionCoverage.self } // expected-error
''', ("cannot find 'CheckedProjectionCoverage' in scope", "'CheckedProjectionCoverage' is inaccessible due to 'private' protection level")))
    with checks.temporary_artifacts(prefix='nv-private-typecheck-') as tmp:
        command = ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-strict-memory-safety',
                   '-warnings-as-errors', '-typecheck', '-I', str(modules),
                   '-module-cache-path', checks.compiler_cache_path('swiftc', modules, tmp),
                   '-Xcc', '-I' + str(ROOT/'NVStorage/.deps/sqlcipher/include'),
                   '-Xcc', '-I' + str(ROOT/'NVStorage/Sources/CStorageIO/include')]
        if sys.platform == 'darwin':
            apple = modules.parent/'CAppleFileAccess.build/module.modulemap'
            assert apple.is_file(), apple
            command += ['-Xcc', '-fmodule-map-file=' + str(apple)]
        for path in [modules.parent/'CArgon2.build/module.modulemap', modules.parent/'CStorageIO.build/module.modulemap',
                     modules.parent/'CSQLMaintenance.build/module.modulemap',
                     modules.parent/'CZstd.build/module.modulemap', ROOT/'NVStorage/Sources/CSQLCipher/module.modulemap']:
            assert path.is_file(), path
            command += ['-Xcc', '-fmodule-map-file=' + str(path)]
        runtime = sorted((ROOT/'NVStorage/Sources/NVStorageRuntime').glob('*.swift'))
        runtime += [modules.parent/'NVStorageRuntime.build/DerivedSources/resource_bundle_accessor.swift']
        completed = 0
        for same in [False, True]:
            selected = list(cases)
            if same:
                for name, expression, parameters in [
                    ('PendingAdmissionBinding', 'item: i, generation: 1, reservation: r', '_ i: PendingItemID, _ r: PendingReservationV1'),
                    ('VerifiedActivationInput', 'candidate: s, association: a, sources: []', '_ s: LocalStoreSelection, _ a: LocalAssociationID'),
                    ('CapturedRepositoryHistory', 'source: s, beginning: c, through: 1, requirements: []', '_ s: LocalStoreSession, _ c: RepositoryPublicationCursor'),
                    ('PrivateBackupSourceCut', 'connection: UUID(), changes: 0', ''),
                    ('CapturedPrivateBackup', 'result: b, session: UUID(), cut: c', '_ b: CompletePrivateBackup, _ c: PrivateBackupSourceCut'),
                    ('PreparedPrivateStoreCopy', 'candidate: c, through: 1, backup: b', '_ c: LocalStoreSession, _ b: CapturedPrivateBackup'),
                    ('ActivationSource', 'selection: s, observation: []', '_ s: LocalStoreSelection'),
                    ('RootCopyAccess', 'root: r, destination: "x"', '_ r: RepositoryRootSession'),
                    ('ReservedProjectionReplacement', 'record: r, input: i', '_ r: ProjectionReplacementAttemptV1, _ i: PreparedProjectionReplacement'),
                    ('UninstalledProjectionReplacement', 'r', '_ r: ReservedProjectionReplacement'),
                    ('ProjectionReplacementReceipt', 'file: f, displaced: f, reserved: r, sourceMatched: true, native: fatalError()', '_ f: ProjectionFileSnapshot, _ r: ReservedProjectionReplacement'),
                    ('ProjectionReplacementRecoveryInput', 'record: r, sourceBytes: [], outputBytes: [], store: s, session: UUID(), connection: UUID()', '_ r: ProjectionReplacementAttemptV1, _ s: LocalStoreID'),
                    ('ProjectionReplacementInspection', 'current: .unavailable(.absent), backup: .unavailable(.absent), input: i, permission: p', '_ i: ProjectionReplacementRecoveryInput, _ p: RepositoryRootPermission'),
                    ('PreparedProjectionRelocation', 'output: o, bytes: [], value: v, source: p, sourceBytes: [], association: a, associationGeneration: 1, snapshot: s, connection: UUID()', '_ o: ProjectionOutputV1, _ v: PlaintextNoteValue, _ p: AcceptedProjectionV1, _ a: LocalAssociationV1, _ s: StoreSnapshot'),
                    ('ReservedProjectionRelocation', 'record: r, input: i', '_ r: ProjectionReplacementAttemptV1, _ i: PreparedProjectionRelocation'),
                    ('UncapturedProjectionRelocation', 'r', '_ r: ReservedProjectionRelocation'),
                    ('ProjectionRelocationReceipt', 'file: f, displaced: f, source: .unavailable(.absent), original: fatalError(), reserved: r, native: fatalError()', '_ f: ProjectionFileSnapshot, _ r: ReservedProjectionRelocation'),
                    ('ProjectionRelocationFailure', 'reason: .changed, reserved: r, original: fatalError(), native: fatalError()', '_ r: ReservedProjectionRelocation'),
                    ('ProjectionRelocationRecoveryInput', 'record: r, sourceBytes: [], outputBytes: [], store: s, session: UUID(), connection: UUID()', '_ r: ProjectionReplacementAttemptV1, _ s: LocalStoreID'),
                    ('ProjectionRelocationInspection', 'source: .unavailable(.absent), current: .unavailable(.absent), backup: .unavailable(.absent), input: i, permission: p', '_ i: ProjectionRelocationRecoveryInput, _ p: RepositoryRootPermission'),
                    ('PreparedProjectionDeletion', 'birth: b, source: p, bytes: [], association: a, capture: c, snapshot: s, observations: o, associationGeneration: 1, connection: UUID()', '_ b: NoteBirth, _ p: AcceptedProjectionV1, _ a: LocalAssociationV1, _ c: CapturedActionGroup, _ s: StoreSnapshot, _ o: ProjectionObservationState'),
                    ('CapturedProjectionDeleteSource', 'input: i, source: s, lease: fatalError()', '_ i: PreparedProjectionDeletion, _ s: ProjectionFileSnapshot'),
                    ('AuthorizedProjectionDeletion', 'original: c, deletion: a, receipt: r', '_ c: CapturedProjectionDeleteSource, _ a: StoredActionReferenceV1, _ r: AcceptedHistoryReceipt'),
                    ('ReservedProjectionSource', 'record: r, authorization: a', '_ r: ProjectionSourceAttemptV1, _ a: AuthorizedProjectionDeletion'),
                    ('UncapturedProjectionSource', 'r', '_ r: ReservedProjectionSource'),
                    ('ProjectionSourceRecoveryInput', 'record: r, bytes: [], store: s, session: UUID(), connection: UUID()', '_ r: ProjectionSourceAttemptV1, _ s: LocalStoreID'),
                    ('ProjectionSourceEffect', 'record: r, source: .unavailable(.absent), reason: nil', '_ r: ProjectionSourceAttemptV1'),
                    ('ProjectionSourceRemovalReceipt', 'effect: e, reserved: r, permission: p', '_ e: ProjectionSourceEffect, _ r: ReservedProjectionSource, _ p: RepositoryRootPermission'),
                    ('ProjectionSourceInspection', 'source: .unavailable(.absent), cleanup: .unavailable(.absent), input: i, permission: p', '_ i: ProjectionSourceRecoveryInput, _ p: RepositoryRootPermission'),
                    ('ProjectionCleanupSnapshot', 'record: r, observation: o, value: fatalError()', '_ r: ProjectionSourceAttemptV1, _ o: RepositoryEntryObservation'),
                ]:
                    diagnostic = ("'RootCopyAccess' is inaccessible due to 'private' protection level", "cannot find 'RootCopyAccess' in scope") if name == 'RootCopyAccess' else f"'{name}' initializer is inaccessible due to 'fileprivate' protection level"
                    selected.append((name + ' issuer', f'func wrong({parameters}) {{ _ = {name}({expression}) }} // expected-error\n', diagnostic))
                selected += [
                    ('replacement cannot authorize relocation', '''
func wrong(_ root: RepositoryRootSession, _ store: LocalStoreSession, _ input: PreparedProjectionReplacement, _ file: ProjectionFileSnapshot, _ permission: RepositoryRootPermission) async throws {
    _ = try await root.relocateProjection(input, source: file, from: store, using: permission, maximumDisplacedBytes: 1024) // expected-error
}
''', "cannot convert value of type 'PreparedProjectionReplacement' to expected argument type 'PreparedProjectionRelocation'"),
                    ('relocation cannot authorize replacement', '''
func wrong(_ root: RepositoryRootSession, _ store: LocalStoreSession, _ input: PreparedProjectionRelocation, _ file: ProjectionFileSnapshot, _ permission: RepositoryRootPermission) async throws {
    _ = try await root.replaceProjection(input, source: file, from: store, using: permission, maximumDisplacedBytes: 1024) // expected-error
}
''', "cannot convert value of type 'PreparedProjectionRelocation' to expected argument type 'PreparedProjectionReplacement'"),
                    ('recovery cannot authorize relocation', '''
func wrong(_ root: RepositoryRootSession, _ store: LocalStoreSession, _ input: ProjectionRelocationRecoveryInput, _ file: ProjectionFileSnapshot, _ permission: RepositoryRootPermission) async throws {
    _ = try await root.relocateProjection(input, source: file, from: store, using: permission, maximumDisplacedBytes: 1024) // expected-error
}
''', "cannot convert value of type 'ProjectionRelocationRecoveryInput' to expected argument type 'PreparedProjectionRelocation'"),
                    ('passive attempt cannot retire relocation', '''
func wrong(_ store: LocalStoreSession, _ record: ProjectionReplacementAttemptV1) async throws {
    try await store.retireProjectionRelocation(record) // expected-error
}
''', "cannot convert value of type 'ProjectionReplacementAttemptV1' to expected argument type 'UncapturedProjectionRelocation'"),
                    ('relocation receipt source lease', 'func wrong(_ r: ProjectionRelocationReceipt) { _ = r.original } // expected-error\n',
                     "'original' is inaccessible due to 'private' protection level"),
                    ('relocation failure source lease', 'func wrong(_ r: ProjectionRelocationFailure) { _ = r.original } // expected-error\n',
                     "'original' is inaccessible due to 'private' protection level"),
                    ('immutable relocation input', '''
func wrong(_ input: inout PreparedProjectionRelocation) { input.bytes = [0] } // expected-error
''', "cannot assign to property: 'bytes' is a 'let' constant"),
                    ('live relocation and read-only recovery consumers', '''
func use(_ root: RepositoryRootSession, _ store: LocalStoreSession, _ file: ProjectionFileSnapshot, _ permission: RepositoryRootPermission, _ birth: NoteBirth) async throws {
    let input = try await store.prepareProjectionRelocation(observations: store.projectionObservations(for: birth), basedOn: store.snapshot())
    if case .installed(let receipt) = try await root.relocateProjection(input, source: file, from: store, using: permission, maximumDisplacedBytes: 1024) {
        try await root.validate(receipt, for: input, from: store, using: permission)
    }
    let recovery = try await store.prepareProjectionRelocationRecovery(for: birth)
    let inspection = try await root.inspectProjectionRelocation(recovery, from: store, maximumBytes: 1024, using: permission)
    try await root.validate(inspection, for: recovery, from: store, using: permission)
}
''', None),
                    ('removal reservation accessor', 'func wrong(_ c: ProjectionSourceRemovalReceipt) { _ = c.reserved } // expected-error\n',
                     "'reserved' is inaccessible due to 'fileprivate' protection level"),
                    ('original capture identity confinement', 'func wrong(_ c: CapturedProjectionDeleteSource) { _ = c.sameCapture(as: c) } // expected-error\n',
                     "'sameCapture' is inaccessible due to 'fileprivate' protection level"),
                    ('recovery cannot authorize removal', '''
func wrong(_ root: RepositoryRootSession, _ store: LocalStoreSession, _ input: ProjectionSourceRecoveryInput, _ permission: RepositoryRootPermission) async throws {
    _ = try await root.removeProjectionSource(input, from: store, using: permission, maximumBytes: 1024) // expected-error
}
''', "cannot convert value of type 'ProjectionSourceRecoveryInput' to expected argument type 'AuthorizedProjectionDeletion'"),
                    ('passive attempt cannot authorize retirement', '''
func wrong(_ store: LocalStoreSession, _ record: ProjectionSourceAttemptV1) async throws {
    try await store.retireProjectionSource(record) // expected-error
}
''', "cannot convert value of type 'ProjectionSourceAttemptV1' to expected argument type 'UncapturedProjectionSource'"),
                    ('live original removal consumer', '''
func use(_ root: RepositoryRootSession, _ store: LocalStoreSession, _ deletion: AuthorizedProjectionDeletion, _ permission: RepositoryRootPermission) async throws {
    switch try await root.removeProjectionSource(deletion, from: store, using: permission, maximumBytes: 1024) {
    case .removed(let receipt): try await root.validate(receipt, for: deletion, from: store, using: permission)
    case .notRemoved(let effect), .uncertain(let effect): _ = effect.record
    }
}
''', None),
                    ('source descriptor accessor', 'func wrong(_ c: CapturedProjectionDeleteSource) { _ = c.withDescriptor { $0 } } // expected-error\n',
                     "'withDescriptor' is inaccessible due to 'fileprivate' protection level"),
                    ('source descriptor owner', 'func wrong(_ c: CapturedProjectionDeleteSource) { _ = c.lease } // expected-error\n',
                     "'lease' is inaccessible due to 'private' protection level"),
                ]
            else:
                selected.append(('replacement reservation visibility',
                    'func wrong() { _ = ReservedProjectionReplacement.self } // expected-error\n',
                    "cannot find 'ReservedProjectionReplacement' in scope"))
                for name in ['UninstalledProjectionReplacement', 'ProjectionReplacementReceipt', 'ProjectionReplacementRecoveryInput', 'ProjectionReplacementInspection',
                             'PreparedProjectionRelocation', 'ReservedProjectionRelocation', 'UncapturedProjectionRelocation',
                             'ProjectionRelocationReceipt', 'ProjectionRelocationFailure', 'ProjectionRelocationResult',
                             'ProjectionRelocationRecoveryInput', 'ProjectionRelocationInspection',
                             'PreparedProjectionDeletion', 'CapturedProjectionDeleteSource', 'AuthorizedProjectionDeletion',
                             'ReservedProjectionSource', 'UncapturedProjectionSource', 'ProjectionSourceRecoveryInput', 'ProjectionSourceEffect',
                             'ProjectionSourceInspection', 'ProjectionSourceRemovalReceipt', 'ProjectionSourceRemovalResult',
                             'ProjectionCleanupSnapshot', 'ProjectionCleanupReadResult']:
                    selected.append((name + ' visibility', f'func wrong() {{ _ = {name}.self }} // expected-error\n',
                        f"cannot find '{name}' in scope"))
                for name in ['capturedPrivateBackup', 'preparePrivateStoreCopy']:
                    selected.append((name + ' internal consumer',
                        f'func wrong(_ s: LocalStoreSession) async throws {{ _ = try await s.{name}(to: "x") }} // expected-error\n',
                        f"'{name}' is inaccessible due to 'internal' protection level"))
            for name in ['ProjectionSourceLease', 'ProjectionSourceRead']:
                expected = (f"'{name}' is inaccessible due to 'private' protection level", f"cannot find '{name}' in scope")
                selected.append((name + ' file confinement', f'func wrong() {{ _ = {name}.self }} // expected-error\n', expected))
            clients = [(name, 'import Foundation\nimport NVStorageCore\n' + ('' if same else 'import NVStorageRuntime\n') + source, expected)
                       for name, source, expected in selected]
            cmd = command + (['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, runtime)] if same else [])
            completed += checks.run_probes(cmd, clients, Path(tmp)/('same' if same else 'ordinary'),
                label='same-module' if same else 'ordinary', timeout=120, maximum=args.batch_size)
    assert completed == 160, completed


if __name__ == '__main__':
    main()
