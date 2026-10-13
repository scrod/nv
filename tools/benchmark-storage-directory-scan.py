#!/usr/bin/env python3
"""Compare production legacy catalogs and repository discovery using identical real history files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repetitions', type=int, default=9)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    assert platform.system() == 'Darwin', 'The production legacy scanner uses macOS APIs'
    assert 3 <= args.repetitions <= 100
    artifacts = Path(tempfile.mkdtemp(prefix='nv-directory-scan-benchmark-'))
    print('Artifacts:', artifacts, flush=True)
    native = artifacts/'DirectoryScanBenchmark'
    sources = ['tests/DirectoryScanBenchmark.m', 'NVRootedDirectory.m', 'NSFileManager_NV.m', 'BufferUtils.c',
               'NVStorage/Sources/CStorageIO/NVRepositoryRoot.c', 'NVStorage/Sources/CStorageIO/NVRepositoryFiles.c']
    recorded_sources = sources + ['Notation_Prefix.pch', 'tools/benchmark-storage-directory-scan.py',
        'NVStorage/Tests/NVStorageRuntimeTests/RepositoryScanBenchmarkTests.swift',
        'NVStorage/Sources/NVStorageRuntime/RepositoryRoot.swift',
        'NVStorage/Sources/NVStorageRuntime/RepositoryDiscovery.swift',
        'NVStorage/Sources/NVStorageRuntime/HistoryDatabase.swift']
    compile_command = ['xcrun', 'clang', '-O2', '-g', '-fno-objc-arc', '-fblocks', '-mmacosx-version-min=11.5',
                       '-include', str(ROOT/'Notation_Prefix.pch'),
                       '-I'+str(ROOT), '-I'+str(ROOT/'NVStorage/Sources/CStorageIO/include'),
                       *[str(ROOT/source) for source in sources], '-framework', 'Cocoa', '-o', str(native)]
    compiled = subprocess.run(compile_command, capture_output=True, text=True)
    (artifacts/'compile.log').write_text(compiled.stdout + compiled.stderr)
    assert compiled.returncode == 0, compiled.stderr
    environment = os.environ.copy()
    environment['PKG_CONFIG_PATH'] = str(ROOT/'NVStorage/.deps/sqlcipher/lib/pkgconfig') + ':' + environment.get('PKG_CONFIG_PATH', '')
    environment['NV_STORAGE_SCAN_BENCHMARK_NATIVE'] = str(native)
    environment['NV_STORAGE_SCAN_BENCHMARK_REPETITIONS'] = str(args.repetitions)
    environment['NV_STORAGE_SCAN_BENCHMARK_RESULTS'] = str(artifacts)
    environment.setdefault('CLANG_MODULE_CACHE_PATH', str(artifacts/'module-cache'))
    command = ['swift', 'test', '--build-system', 'native', '--package-path', str(ROOT/'NVStorage'),
               '--configuration', 'release', '--disable-sandbox', '--jobs', '1', '--no-parallel',
               '--filter', 'repositoryDirectoryScanBenchmark']
    if args.skip_build:
        command.append('--skip-build')
    with (artifacts/'swift.log').open('w') as log:
        tested = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
    text = (artifacts/'swift.log').read_text()
    assert tested.returncode == 0, text[-12000:]
    rows = [json.loads(file.read_text()) for file in sorted(artifacts.glob('scan-*.json'))]
    assert {(row['profile'], row['history']) for row in rows} == {(profile, count) for profile in ['public', 'encrypted'] for count in [64, 256, 1024]}, text[-12000:]
    assert re.search(r'Test run with [1-9][0-9]* tests? .* passed', text), 'Required nonzero passing test discovery'
    assert not re.search(r'Expectation failed|recorded an issue|Test run .* failed', text), 'Measured companion must remain valid'
    for row in rows:
        assert row['sqlWorkInstrumentationDuringTiming'] is False
        assert row['native']['files'] == row['history']
        assert all(len(values) == args.repetitions for values in row['native']['samplesMilliseconds'].values())
        medians = {name: statistics.median(values) for name, values in row['native']['samplesMilliseconds'].items()}
        medians['discovery'] = statistics.median(row['discoveryMilliseconds'])
        row['mediansMilliseconds'] = medians
        assert len(row['discoveryMilliseconds']) == args.repetitions
        assert row['historicalBodyReads'] == row['verificationProviderBodyReads'] == 0
        print(row['profile'], row['history'], json.dumps(medians, sort_keys=True), 'SQL', sorted(set(row['sqlStatements'])), flush=True)
    # Larger enumeration-only fixtures isolate file count and writer-directory fan-out.
    synthetic = []
    for count, writers in [(1024, 64), (10000, 1)]:
        fixture = artifacts/f'native-{count}-{writers}'
        for writer in range(writers):
            (fixture/'NV Data/v1/segments'/f'{writer:032x}').mkdir(parents=True)
        for item in range(count):
            leaf = fixture/'NV Data/v1/segments'/f'{item % writers:032x}'/f'{item:020d}-{item:064x}.nvseg'
            leaf.write_bytes(b'Enumeration-only fixture\n')
        measured = subprocess.run([str(native), str(fixture), str(count), str(args.repetitions)],
                                  capture_output=True, text=True, check=True, timeout=120)
        row = json.loads(measured.stdout)
        assert row['files'] == count and row['writerDirectories'] == writers
        assert all(len(values) == args.repetitions for values in row['samplesMilliseconds'].values())
        row['mediansMilliseconds'] = {name: statistics.median(values) for name, values in row['samplesMilliseconds'].items()}
        synthetic.append(row)
        print('enumeration-only', count, 'writers', writers, json.dumps(row['mediansMilliseconds'], sort_keys=True), flush=True)
    result = {'platform': platform.platform(), 'compiler': subprocess.check_output(['swift', '--version'], text=True),
              'sources': {source: hashlib.sha256((ROOT/source).read_bytes()).hexdigest() for source in recorded_sources},
              'repetitions': args.repetitions, 'cache': 'warm; one unmeasured warmup for each algorithm',
              'rows': rows, 'enumerationOnlyFixtures': synthetic}
    (artifacts/'results.json').write_text(json.dumps(result, indent=2))
    print('PASS: six optimized same-file comparisons, independent inventories and zero-body-read discovery', flush=True)


if __name__ == '__main__':
    main()
