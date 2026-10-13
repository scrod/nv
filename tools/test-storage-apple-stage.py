#!/usr/bin/env python3
"""Check a held stage across actual Foundation grants and inspect its exact installed bytes."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository-parent', type=Path)
    parser.add_argument('--sanitize', choices=['address,undefined', 'thread'])
    parser.add_argument('--mutations', action='store_true',
                        help='Require the unverified-path mutation to fail on a selected fallback-capable HFS+ parent.')
    args = parser.parse_args()
    assert sys.platform == 'darwin', 'Foundation qualification requires macOS'
    if args.mutations and not args.repository_parent:
        parser.error('--mutations requires an explicitly selected HFS+ fixture parent')
    artifacts = Path(tempfile.mkdtemp(prefix='nv-apple-stage-', dir='/tmp'))
    print('Artifacts:', artifacts, flush=True)
    flags = ['clang', '-g', '-O1', '-Wall', '-Wextra', '-Werror', '-Wconversion',
             '-Wsign-conversion', '-Wcast-align', '-fno-omit-frame-pointer',
             '-I'+str(ROOT/'NVStorage/Sources/CStorageIO/include'),
             '-I'+str(ROOT/'NVStorage/Sources/CAppleFileAccess/include'),
             '-I'+str(ROOT/'NVStorage/Sources/CAppleFileAccess')]
    bridge = ROOT/'NVStorage/Sources/CAppleFileAccess/NVAppleFileAccess.m'
    subprocess.run([*flags, '-fobjc-arc', '--analyze', str(bridge), '-o', str(artifacts/'bridge-analysis.plist')], check=True)
    if args.sanitize: flags += ['-fsanitize='+args.sanitize]
    objects = []
    for name in ('NVRepositoryRoot', 'NVRepositoryFiles'):
        output = artifacts/(name+'.o'); objects.append(output)
        subprocess.run([*flags, '-std=c11', '-c', str(ROOT/f'NVStorage/Sources/CStorageIO/{name}.c'), '-o', str(output)], check=True)
    binary = artifacts/'probe'
    subprocess.run([*flags, '-fobjc-arc', str(ROOT/'tests/RepositoryAppleInstallProbe.m'), str(bridge),
                    *map(str, objects), '-framework', 'Foundation', '-o', str(binary)], check=True)
    fixtures = [artifacts/'local']
    fixtures[0].mkdir()
    if args.repository_parent:
        assert args.repository_parent.is_dir(), 'Use an existing, explicitly selected fixture parent'
        fixtures.append(Path(tempfile.mkdtemp(prefix='P54-stage-', dir=args.repository_parent)))
    results = []
    for index, fixture in enumerate(fixtures):
        run = subprocess.run([str(binary), str(fixture)], capture_output=True, text=True, timeout=60)
        (artifacts/f'grant-{index}.log').write_text(run.stdout+run.stderr)
        assert run.returncode == 0, (run.returncode, run.stdout, run.stderr)
        events = [json.loads(line) for line in run.stdout.splitlines()]
        assert any(row.get('phase') == 'reference' and row.get('unrelated_preserves_owner') is True for row in events)
        prepared = next(row for row in events if row.get('phase') == 'prepared')
        entered = next(row for row in events if row.get('phase') == 'entered')
        complete = next(row for row in events if row.get('phase') == 'complete')
        assert any(row.get('source_matches') == row.get('destination_matches') == 1 for row in events)
        assert prepared['outcome'] == complete['outcome'] == 1
        assert prepared['words'][:5] == entered['words'][:5]
        assert (fixture/'diagnostic.nvseg').read_bytes() == b'NV synthetic coordinated stage diagnostic'
        assert not list(fixture.glob('.nv-stage-*'))
        results.append(dict(fixture=str(fixture), metadata_changed=prepared['words'][5:] != entered['words'][5:]))
        print('PASS:', 'selected parent' if index else 'local', 'held identity, actual grants and exact bytes', flush=True)
    if args.mutations:
        source = bridge.read_text()
        changes = {
            'if (!same && nv_root_compare(owner, selectedPath) == 1) {': 'if (!same) {',
            '        same = resolved && nv_root_compare(owner, resolved.fileSystemRepresentation) == 1;':
                '        same = resolved != nil;',
        }
        for original, altered in changes.items():
            assert source.count(original) == 1, ('Mutation anchor changed', original)
            source = source.replace(original, altered)
        mutant_source = artifacts/'unverified-path.m'
        mutant_source.write_text(source)
        mutant = artifacts/'unverified-path'
        subprocess.run([*flags, '-fobjc-arc', str(ROOT/'tests/RepositoryAppleInstallProbe.m'), str(mutant_source),
                        *map(str, objects), '-framework', 'Foundation', '-o', str(mutant)], check=True)
        fixture = Path(tempfile.mkdtemp(prefix='P54-path-mutant-', dir=args.repository_parent))
        run = subprocess.run([str(mutant), str(fixture)], capture_output=True, text=True, timeout=60)
        (artifacts/'unverified-path.log').write_text(run.stdout+run.stderr)
        events = [json.loads(line) for line in run.stdout.splitlines()]
        assert run.returncode == 7 and events == [{'phase': 'reference', 'unrelated_preserves_owner': False}], (
            'The real fallback must reach and reject the wrong-root reference', run.returncode, run.stdout, run.stderr)
        assert list(fixture.iterdir()) == [], 'The failed reference check precedes every stage/native write'
        results.append(dict(mutation='unverified-path', intendedAssertion='passed'))
        print('PASS: unverified candidate fails the intended root-binding assertion before every write', flush=True)
    (artifacts/'results.json').write_text(json.dumps(results, indent=2))


if __name__ == '__main__': main()
