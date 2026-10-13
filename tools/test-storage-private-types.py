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
    _ = try await RepositoryCopy.preserveAvailable(from: target, to: target + "-copy")
}
''', None)]
    for name, expression, parameters in [
        ('CollectionSettingsState', 'generation: 1, value: v, store: s.store, session: UUID()', '_ s: LocalStoreSelection, _ v: CollectionSettingsV1'),
        ('LocalAssociationState', 'generation: 1, value: nil, store: s.store, session: UUID()', '_ s: LocalStoreSelection'),
        ('PendingItemState', 'id: id, generation: 1, latest: nil, store: s.store, session: UUID()', '_ s: LocalStoreSelection, _ id: PendingItemID'),
        ('PreparedPendingAction', 'reservation: r, capture: c', '_ r: PendingReservationV1, _ c: CapturedActionGroup'),
        ('CompletePrivateBackup', 'selection: s, through: 1', '_ s: LocalStoreSelection'),
        ('PrivateRepairEvidence', 'selection: s, workingDirectory: "x", accepted: [], objects: [], privateTables: [:], bootstrap: s.descriptor.genesis, missing: [], observation: []', '_ s: LocalStoreSelection'),
        ('PartialPrivateSalvage', 'directory: "x", failures: [:], objects: 0, committed: 0', ''),
        ('VerifiedReplacement', 'candidate: c, selection: s, through: 1, sources: []', '_ c: LocalStoreSession, _ s: LocalStoreSelection'),
        ('SelectedStoreState', 'record: nil, owner: UUID(), parent: []', ''),
        ('RepositoryCopyResult', 'destination: "x", files: [], issues: [], requirements: []', ''),
        ('CurrentCollectionExport', 'selection: s, repository: r, births: []', '_ s: LocalStoreSelection, _ r: RepositoryCopyResult'),
    ]:
        cases.append((name + ' issuer', f'func wrong({parameters}) {{ _ = {name}({expression}) }} // expected-error\n',
                      f"'{name}' initializer is inaccessible due to 'fileprivate' protection level"))
    cases.append(('health versus replacement', '''
func take(_ r: VerifiedReplacement) {}
func wrong(_ report: StorageHealthReport) { take(report) } // expected-error
''', "cannot convert value of type 'StorageHealthReport' to expected argument type 'VerifiedReplacement'"))
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
                    ('CapturedRepositoryHistory', 'through: 1, objects: []', ''),
                ]:
                    selected.append((name + ' issuer', f'func wrong({parameters}) {{ _ = {name}({expression}) }} // expected-error\n',
                                     f"'{name}' initializer is inaccessible due to 'fileprivate' protection level"))
            clients = [(name, 'import Foundation\nimport NVStorageCore\n' + ('' if same else 'import NVStorageRuntime\n') + source, expected)
                       for name, source, expected in selected]
            cmd = command + (['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, runtime)] if same else [])
            completed += checks.run_probes(cmd, clients, Path(tmp)/('same' if same else 'ordinary'),
                label='same-module' if same else 'ordinary', timeout=120, maximum=args.batch_size)
        assert completed == 29, completed


if __name__ == '__main__':
    main()
