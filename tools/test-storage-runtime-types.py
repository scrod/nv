#!/usr/bin/env python3
"""Construction and authority boundaries for ordinary and same-module runtime clients."""
import argparse
from pathlib import Path
import subprocess
import importlib.util

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('typechecks', ROOT / 'tools/test-swift-storage-types.py')
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def matches_expected(code, diagnostic, path, source, expected):
    alternatives = expected if isinstance(expected, tuple) else (expected,)
    return any(checker.matches_contract(code, diagnostic, path, source, text) for text in alternatives)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--modules', type=Path, required=True)
    parser.add_argument('--actors-only', action='store_true')
    args = parser.parse_args()
    visibility = ("'HistoryUnit' is inaccessible due to 'private' protection level",
                  "cannot find 'HistoryUnit' in scope")
    actor_await = ("actor-isolated instance method 'perform' cannot be called from outside of the actor",
                   "expression is 'async' but is not marked with 'await'")
    example_path, example = Path('/probe/Client.swift'), 'HistoryUnit.self // expected-error\n'
    for text in visibility:
        diagnostic = f'{example_path}:1:24: error: {text}'
        assert matches_expected(1, diagnostic, example_path, example, visibility)
        assert not matches_expected(0, diagnostic, example_path, example, visibility)
        assert not matches_expected(1, diagnostic.replace(':1:24:', ':2:24:'), example_path, example, visibility)
        assert not matches_expected(1, diagnostic.replace('HistoryUnit', 'MissingModule'), example_path, example, visibility)
    assert not matches_expected(1, 'compiler unavailable', example_path, example, visibility)
    for text in actor_await:
        diagnostic = f'{example_path}:1:24: error: {text}'
        assert matches_expected(1, diagnostic, example_path, example, actor_await)
        assert not matches_expected(0, diagnostic, example_path, example, actor_await)
        assert not matches_expected(1, diagnostic.replace(':1:24:', ':2:24:'), example_path, example, actor_await)
    assert not matches_expected(1, 'compiler unavailable', example_path, example, actor_await)
    print('PASS: exact visibility-diagnostic classifier self-checks', flush=True)
    modules = args.modules.resolve()
    valid = ('public runtime client', '''
func use(_ session: LocalStoreSession, _ capture: CapturedActionGroup) async throws -> CommitOutcome {
    try await session.persist(capture: capture)
}
func status(_ session: LocalStoreSession, _ locator: SegmentLocator) async throws -> Int {
    switch try await session.receivedObjectStatus(at: locator) {
    case .pendingValidation: return 1
    case .accepted: return 0
    case .waiting(let missing): return missing.count
    case .blocked(let roots, let unaccepted): return roots.count + unaccepted.count
    }
}
''', None)
    issuers = [
        ('commit handle issuer', '''
func wrong(_ c: CapturedActionGroup) { let _ = CommitHandle(session: UUID(), id: UUID(), capture: c) } // expected-error
''', "'CommitHandle' initializer is inaccessible due to 'fileprivate' protection level"),
        ('receipt issuer', '''
func wrong(_ r: AcceptedHistoryReceipt) {
    let _ = AcceptedHistoryReceipt(session: UUID(), store: r.store, sequence: r.sequence, object: r.object, covered: r.covered) // expected-error
}
''', "'AcceptedHistoryReceipt' initializer is inaccessible due to 'fileprivate' protection level"),
        ('prepared change issuer', '''
func wrong(_ s: StoreSnapshot) { let _ = PreparedModelChange(snapshot: s, liveGeneration: 1) } // expected-error
''', "'PreparedModelChange' initializer is inaccessible due to 'fileprivate' protection level"),
        ('snapshot issuer', '''
func wrong(_ s: StoreSnapshot) {
    let _ = StoreSnapshot(session: UUID(), store: s.store, through: s.through, viewEpoch: s.viewEpoch, notes: s.notes, context: s.context) // expected-error
}
''', "'StoreSnapshot' initializer is inaccessible due to 'fileprivate' protection level"),
        ('settings issuer', '''
func wrong(_ s: StoreSnapshot) { let _ = EmptySettingsState(generation: 1, store: s.store, session: UUID()) } // expected-error
''', "'EmptySettingsState' initializer is inaccessible due to 'fileprivate' protection level"),
    ]
    extra = [
        ('blocked diagnostic is not commit ownership', '''
func wrong(_ s: LocalStoreSession, _ b: RejectedPrerequisite) async throws {
    let _ = try await s.retry(commit: b) // expected-error
}
''', "cannot convert value of type 'RejectedPrerequisite' to expected argument type 'CommitHandle'"),
        ('checked history work issuer', '''
func wrong() { let _ = CheckedHistoryWork.self } // expected-error
''', "cannot find 'CheckedHistoryWork' in scope"),
        ('history input issuer', '''
func wrong() { let _ = HistoryUnit.self } // expected-error
''', "cannot find 'HistoryUnit' in scope"),
        ('checked current basis issuer', '''
func wrong() { let _ = CheckedCurrentBasis.self } // expected-error
''', "cannot find 'CheckedCurrentBasis' in scope"),
        ('capture generations immutable', '''
func wrong(_ input: CapturedActionGroup) { var c = input; c.covered = [] } // expected-error
''', "cannot assign to property: 'covered' is a 'let' constant"),
        ('receipt is not a retry handle', '''
func wrong(_ s: LocalStoreSession, _ r: AcceptedHistoryReceipt) async throws {
    let _ = try await s.retry(commit: r) // expected-error
}
''', "cannot convert value of type 'AcceptedHistoryReceipt' to expected argument type 'CommitHandle'"),
        ('receipt cannot be deserialized', '''
func decode<T: Decodable>(_ t: T.Type) {}
func wrong() { decode(AcceptedHistoryReceipt.self) } // expected-error
''', "requires that 'AcceptedHistoryReceipt' conform to 'Decodable'"),
        ('no fixed nonce sealer', '''
func wrong(_ c: CollectionID, _ w: WriterEpoch, _ p: ObjectProtectionV1) throws {
    let _ = try ObjectEnvelopeV1.seal(payload: [], kind: .changes, collection: c, writer: w, sequence: 0, protection: p, testNonce: nil) // expected-error
}
''', "extra argument 'testNonce' in call"),
    ]
    with checker.temporary_artifacts(prefix='nv-runtime-typecheck-') as tmp:
        command = ['swiftc', '-swift-version', '6', '-typecheck', '-I', str(modules), '-module-cache-path', tmp,
                   '-Xcc', '-I' + str(ROOT / 'NVStorage/.deps/sqlcipher/include')]
        for p in [modules.parent / 'CArgon2.build/module.modulemap', modules.parent / 'CStorageIO.build/module.modulemap',
                  ROOT / 'NVStorage/Sources/CSQLCipher/module.modulemap', modules.parent / 'CZstd.build/module.modulemap']:
            assert p.is_file(), p
            command.extend(['-Xcc', '-fmodule-map-file=' + str(p)])
        runtime = sorted((ROOT / 'NVStorage/Sources/NVStorageRuntime').glob('*.swift'))
        runtime += [modules.parent / 'NVStorageRuntime.build/DerivedSources/resource_bundle_accessor.swift']
        count = 0
        for same in ([] if args.actors_only else [False, True]):
            for name, source, error in [valid] + issuers + extra:
                if same and name == 'history input issuer':
                    error = visibility
                if same and name == 'checked current basis issuer':
                    error = tuple(s.replace('HistoryUnit', 'CheckedCurrentBasis') for s in visibility)
                if same and name == 'checked history work issuer':
                    error = tuple(s.replace('HistoryUnit', 'CheckedHistoryWork') for s in visibility)
                path = Path(tmp) / 'Client.swift'
                source = 'import Foundation\nimport NVStorageCore\n' + ('' if same else 'import NVStorageRuntime\n') + source
                path.write_text(source)
                cmd = command + (['-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime', *map(str, runtime)] if same else []) + [str(path)]
                run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
                assert matches_expected(run.returncode, run.stderr, path, source, error), (name, run.stderr)
                print('PASS:', 'same-module' if same else 'ordinary', name, flush=True); count += 1
        assert count == (0 if args.actors_only else 28)
        # Same-module callers exercise actor and connection boundaries directly.
        actor_cases = [
            ('actor caller', '''
func use(_ owner: DatabaseLane) async throws -> Int64 {
    try await owner.perform { try $0.acceptedThrough() }
}
''', None),
            ('actor access requires await', '''
func wrong(_ owner: DatabaseLane) async throws {
    let _ = try owner.perform { try $0.acceptedThrough() } // expected-error
}
''', actor_await),
            ('connection stays owned', '''
func wrong(_ owner: DatabaseLane) async throws {
    let _ = try await owner.perform { $0 } // expected-error
}
''', "type 'Database' does not conform to the 'Sendable' protocol"),
            ('transaction turn stays synchronous', '''
func wrong(_ owner: DatabaseLane) async throws {
    let _ = try await owner.perform { db in await Task.yield(); return try db.acceptedThrough() } // expected-error
}
''', "cannot pass function of type '@Sendable (Database) async throws -> Int64' to parameter expecting synchronous function type"),
        ]
        for name, source, error in actor_cases:
            path = Path(tmp) / 'Client.swift'
            source = 'import Foundation\nimport NVStorageCore\n' + source
            path.write_text(source)
            # Emit SIL as well as type-checking to include region-isolation diagnostics.
            cmd = [x for x in command if x != '-typecheck'] + ['-emit-sil', '-o', str(Path(tmp)/'probe.sil'),
                '-whole-module-optimization', '-package-name', 'nvstorage', '-module-name', 'NVStorageRuntime',
                *map(str, runtime), str(path)]
            run = subprocess.run(cmd, text=True, capture_output=True, timeout=60)
            assert matches_expected(run.returncode, run.stderr, path, source, error), (name, run.stderr)
            print('PASS: same-module', name, flush=True); count += 1
        assert count == (4 if args.actors_only else 32)


if __name__ == '__main__':
    main()
