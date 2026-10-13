#!/usr/bin/env python3
"""Measure complete production discovery and separately named metadata/query components."""
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
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--existing-results', type=Path, help='Reuse a completed Swift diagnostic and its preserved fixtures')
    args = parser.parse_args()
    assert platform.system() == 'Darwin', 'The bulk-metadata candidate uses Darwin APIs'
    artifacts = args.existing_results or Path(tempfile.mkdtemp(prefix='nv-discovery-work-'))
    print('Artifacts:', artifacts, flush=True)
    sources = ['tests/RepositoryDiscoveryBatchBenchmark.c', 'NVStorage/Sources/CStorageIO/NVRepositoryRoot.c',
               'NVStorage/Sources/CStorageIO/NVRepositoryFiles.c']
    native = artifacts / 'RepositoryDiscoveryBatchBenchmark'
    command = ['xcrun', 'clang', '-O2', '-g', '-Wall', '-Wextra', '-Werror', '-mmacosx-version-min=11.5',
               '-I'+str(ROOT/'NVStorage/Sources/CStorageIO/include'), str(ROOT/sources[0]), str(ROOT/sources[1]), '-o', str(native)]
    compiled = subprocess.run(command, capture_output=True, text=True)
    (artifacts/'compile.log').write_text(compiled.stdout + compiled.stderr)
    assert compiled.returncode == 0, compiled.stderr
    if args.existing_results is None:
        environment = os.environ.copy()
        environment.update(NV_STORAGE_DISCOVERY_ANALYSIS=str(artifacts),
                           PKG_CONFIG_PATH=str(ROOT/'NVStorage/.deps/sqlcipher/lib/pkgconfig')+':'+environment.get('PKG_CONFIG_PATH', ''))
        environment.setdefault('CLANG_MODULE_CACHE_PATH', str(artifacts/'module-cache'))
        command = ['swift', 'test', '--build-system', 'native', '--package-path', str(ROOT/'NVStorage'),
                   '--configuration', 'release', '--disable-sandbox', '--jobs', '1', '--no-parallel',
                   '--filter', 'repositoryDiscoveryWorkAnalysis']
        if args.skip_build:
            command.append('--skip-build')
        with (artifacts/'swift.log').open('w') as log:
            result = subprocess.run(command, env=environment, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
        assert result.returncode == 0, (artifacts/'swift.log').read_text()[-12000:]
    log = (artifacts/'swift.log').read_text()
    assert re.search(r'Test run with [1-9][0-9]* tests? .* passed', log), 'Required nonzero passing discovery'
    assert not re.search(r'Expectation failed|recorded an issue|Test run .* failed', log), 'Passing diagnostic companion'
    rows = [json.loads(path.read_text()) for path in sorted(artifacts.glob('sql-*.json'))]
    assert {(row['profile'], row['files']) for row in rows} == {(p, n) for p in ['public', 'encrypted'] for n in [64, 256, 1024]}
    native_rows = []
    for row in rows:
        assert row['repetitions'] == 9 and all(len(v) == 9 for v in row['samplesMilliseconds'].values())
        if row.get('productionBatched'):
            statements_per_batch = 1 if row.get('connectionContextReused') else 13
            assert sum(row['sqlStatementCalls'].values()) == statements_per_batch * row['hintBatches']
            assert row['metadata']['bodyReads'] == 0 and row['metadata']['largestBatch'] <= 64
        else:
            assert sum(row['sqlStatementCalls'].values()) == 14 * row['files']
        row['mediansMilliseconds'] = {name: statistics.median(v) for name, v in row['samplesMilliseconds'].items()}
        print(row['profile'], row['files'], json.dumps(row['mediansMilliseconds'], sort_keys=True), flush=True)
        if row['files'] != 1024:
            continue
        repository = Path(row['repository'])
        writers = list((repository/'NV Data/v1/segments').iterdir())
        assert len(writers) == 1 and writers[0].is_dir()
        with (artifacts/f"native-{row['profile']}-1024.json").open('w') as output:
            subprocess.run([str(native), str(repository), str(writers[0].relative_to(repository)), '9'], stdout=output, check=True)
        measured = json.loads((artifacts/f"native-{row['profile']}-1024.json").read_text())
        assert measured['files'] == 1024 and measured['exactObservationWords'] == 9
        assert all(len(v) == 9 for v in measured['samplesMilliseconds'].values())
        measured['profile'] = row['profile']
        measured['mediansMilliseconds'] = {name: statistics.median(v) for name, v in measured['samplesMilliseconds'].items()}
        native_rows.append(measured)
        print('native', row['profile'], json.dumps(measured['mediansMilliseconds'], sort_keys=True), flush=True)
    sources += ['NVStorage/Tests/NVStorageRuntimeTests/RepositoryDiscoveryAnalysisTests.swift',
                'NVStorage/Sources/NVStorageRuntime/RepositoryDiscovery.swift', 'NVStorage/Sources/NVStorageRuntime/RepositoryRoot.swift',
                'NVStorage/Sources/NVStorageRuntime/HistoryDatabase.swift', 'NVStorage/Sources/NVStorageRuntime/Database.swift',
                'NVStorage/Sources/CStorageIO/NVStorageIO.c', 'tools/benchmark-storage-discovery-work.py']
    result = dict(platform=platform.platform(), compiler=subprocess.check_output(['swift', '--version'], text=True),
                  sources={s: hashlib.sha256((ROOT/s).read_bytes()).hexdigest() for s in sources},
                  rows=rows, native=native_rows, cache='warm', productionBatched=all(row.get('productionBatched') for row in rows),
                  limitations='Warm synthetic repository sweeps; native and SQL components are separate timings; no cold/provider or universal latency guarantee')
    (artifacts/'results.json').write_text(json.dumps(result, indent=2))
    print('PASS: both profiles, all three sizes, exact metadata and accepted identities', flush=True)


if __name__ == '__main__':
    main()
