#!/usr/bin/env python3
"""Qualify actual external Foundation callbacks through the production root and presenter."""
import argparse
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('mutation_helpers', ROOT/'tools/test-bootstrap-mutations.py')
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer', type=Path)
    parser.add_argument('--sanitize', default='')
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-apple-peer-', dir='/tmp'))
    print('Artifacts:', artifacts, flush=True)
    peer = args.peer or artifacts/'peer'
    if not args.peer:
        command = ['clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-g', '-O1',
                   '-framework', 'Foundation', str(ROOT/'tests/RepositoryCoordinationPeer.m'), '-o', str(peer)]
        if args.sanitize: command += ['-fno-omit-frame-pointer', '-fsanitize='+args.sanitize]
        subprocess.run(command, check=True)
    environment = dict(os.environ, NV_STORAGE_COORDINATION_PEER=str(peer.resolve()))
    test = 'repositoryIndependentCoordinatedPeer'
    with (artifacts/'result.log').open('w') as output:
        run = subprocess.run(['make', '-C', str(ROOT/'tests'), 'run-swift-storage',
            f'SWIFT_STORAGE_TEST_FLAGS=--filter {test} --no-parallel'], env=environment,
            stdout=output, stderr=subprocess.STDOUT, timeout=300)
    log = (artifacts/'result.log').read_text()
    assert run.returncode == 0 and test in helper.discovered(log) and f'Test {test}() passed' in log, log[-6000:]
    print('PASS: independent coordinated write/move, actual presenter opportunity, exact reads and ownership', flush=True)


if __name__ == '__main__': main()
