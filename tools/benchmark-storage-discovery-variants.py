#!/usr/bin/env python3
"""Replay frozen original, metadata-only, lookup-only and combined checked bundles on identical files."""
import argparse
import json
import os
from pathlib import Path
import re
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def replay(artifacts, rounds):
    """Rotate preserved builds after compilation, using identical quiesced stores and files."""
    launcher = artifacts/'launcher'
    subprocess.run(['clang', '-O2', '-Wall', '-Wextra', '-Werror', str(ROOT/'tests/StorageSwiftTestingLauncher.c'), '-o', str(launcher)], check=True)
    developer = Path(subprocess.check_output(['xcode-select', '-p'], text=True).strip())
    platform = developer/'Platforms/MacOSX.platform/Developer'
    environment = dict(os.environ, NV_STORAGE_DISCOVERY_VARIANTS=str(artifacts),
        DYLD_FRAMEWORK_PATH=str(platform/'Library/Frameworks'),
        DYLD_LIBRARY_PATH=str(platform/'usr/lib'))
    variants = ['combined', 'original', 'lookup-only', 'metadata-only']
    rows = {}
    for turn in range(rounds):
        order = variants[turn % 4:] + variants[:turn % 4]
        for variant in order:
            bundle = artifacts/(variant+'.xctest')/'Contents/MacOS/NVStoragePackageTests'
            assert bundle.is_file(), bundle
            environment['NV_STORAGE_DISCOVERY_VARIANT'] = variant
            path = artifacts/f'replay-{turn}-{variant}.log'
            with path.open('w') as output:
                run = subprocess.run([str(launcher), '--test-bundle-path', str(bundle), '--testing-library', 'swift-testing',
                    '--no-parallel', '--filter', 'repositoryDiscoveryVariantReplay'], env=environment, stdout=output, stderr=subprocess.STDOUT, timeout=600)
            log = path.read_text(errors='backslashreplace')
            assert run.returncode == 0 and re.search(r'Test run with [1-9][0-9]* tests? .* passed', log), (variant, log[-5000:])
            for profile in ['public', 'encrypted']:
                row = json.loads((artifacts/(variant+'-'+profile+'.json')).read_text())
                assert row['samePhysicalFixtures'] and row['expectedObjects'] == 1024
                key = (variant, profile)
                if key not in rows:
                    rows[key] = row
                    for measurement in row['measurements']: measurement['samplesMilliseconds'] = []
                current = json.loads((artifacts/(variant+'-'+profile+'.json')).read_text())
                for expected, actual in zip(rows[key]['measurements'], current['measurements'], strict=True):
                    assert (expected['files'], expected['budget']) == (actual['files'], actual['budget'])
                    assert len(actual['samplesMilliseconds']) == 9
                    expected['samplesMilliseconds'] += actual['samplesMilliseconds']
            print('PASS: compilation-free replay', turn, variant, flush=True)
    for row in rows.values():
        row['repetitions'] = rounds * 9
        for measurement in row['measurements']:
            assert len(measurement['samplesMilliseconds']) == rounds * 9
            measurement['medianMilliseconds'] = statistics.median(measurement['samplesMilliseconds'])
        print(row['variant'], row['profile'], [(m['files'], m['budget'], round(m['medianMilliseconds'], 3)) for m in row['measurements']], flush=True)
    assert len(rows) == 8
    (artifacts/'replay-results.json').write_text(json.dumps(dict(rows=list(rows.values()), rounds=rounds,
        compilationDuringReplay=False, variantOrder='rotated each round', samePhysicalFixtures=True), indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--replay-only', type=Path, required=True, help='Repeat an existing four-bundle comparison without compiling between samples.')
    parser.add_argument('--replay-rounds', type=int, default=3)
    args = parser.parse_args()
    assert 1 <= args.replay_rounds <= 9
    replay(args.replay_only.absolute(), args.replay_rounds)


if __name__ == '__main__':
    main()
