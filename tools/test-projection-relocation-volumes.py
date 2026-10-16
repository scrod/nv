#!/usr/bin/env python3
"""Qualify the built Swift mutable-file bridge on independent native volumes."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('projection_volumes', ROOT/'tools/test-projection-create-process.py')
volumes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(volumes)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    parser.add_argument('--filesystems', nargs='+', choices=['APFS', 'APFSX', 'HFS+', 'HFSX'],
                        default=['APFSX', 'HFS+', 'HFSX'])
    parser.add_argument('--metadata-mutation', action='store_true',
                        help='Run the isolated complete-metadata control on each selected HFS volume.')
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('This qualification requires native macOS filesystems and Foundation.')
    artifacts = Path(tempfile.mkdtemp(prefix='nv-projection-relocation-volumes-'))
    print('Artifacts:', artifacts, flush=True)
    for filesystem in args.filesystems:
        folder = artifacts/filesystem
        folder.mkdir()
        with volumes.repository_volume(folder, filesystem) as mounted:
            environment = os.environ.copy()
            environment['NV_P62_REPOSITORY_PARENT'] = str(mounted)
            if filesystem in ['HFS+', 'HFSX']:
                environment['NV_P62_REQUIRE_COARSE_METADATA'] = '1'
            else:
                environment.pop('NV_P62_REQUIRE_COARSE_METADATA', None)
            result = subprocess.run(['make', '-C', str(ROOT/'tests'), 'run-swift-storage',
                'SWIFT_STORAGE_TEST_FLAGS=-c ' + args.configuration + ' --skip-build --no-parallel --filter '
                "'projectionRelocationInstallsExactOutputAndRecovers|projectionInstallationChecksCompleteMetadata'"],
                env=environment, capture_output=True, text=True, timeout=180)
            (folder/'swift.log').write_text(result.stdout + result.stderr)
            assert result.returncode == 0, (filesystem, folder/'swift.log')
            for marker in ['with 8 test cases passed', 'with 12 test cases passed', 'Test run with 2 tests']:
                assert marker in result.stdout, (filesystem, marker, folder/'swift.log')
            assert 'recorded an issue' not in result.stdout
            print('PASS:', filesystem, '8 relocation and 12 complete-metadata cases', flush=True)
            if args.metadata_mutation and filesystem in ['HFS+', 'HFSX']:
                result = subprocess.run([sys.executable, str(ROOT/'tools/test-storage-runtime-mutations.py'),
                    '--configuration', args.configuration, '--only', 'p62-output-complete-metadata'],
                    env=environment, capture_output=True, text=True, timeout=600)
                (folder/'metadata-mutation.log').write_text(result.stdout + result.stderr)
                assert result.returncode == 0 and 'targeted runtime failure' in result.stdout, folder/'metadata-mutation.log'
                print('PASS:', filesystem, 'complete-metadata mutation', flush=True)


if __name__ == '__main__':
    main()
