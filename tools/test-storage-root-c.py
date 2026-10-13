#!/usr/bin/env python3
"""Qualify production rooted C lifetime/failure handling with strict diagnostics."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', choices=['address,undefined', 'thread'], default='address,undefined')
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-root-c-'))
    print('Artifacts:', artifacts, flush=True)
    flags = ['clang', '-std=c11', '-g', '-O1', '-Wall', '-Wextra', '-Werror',
             '-Wconversion', '-Wsign-conversion', '-Wcast-align',
             '-I' + str(ROOT / 'NVStorage/Sources/CStorageIO/include')]
    source = ROOT / 'NVStorage/Sources/CStorageIO/NVRepositoryRoot.c'
    subprocess.run(flags + ['--analyze', str(source), '-o', str(artifacts / 'analysis.plist')], check=True)
    binary = artifacts / 'root-io'
    subprocess.run(flags + ['-fno-omit-frame-pointer', '-fsanitize=' + args.sanitize,
                           str(ROOT / 'tests/RepositoryRootIOProbe.c'), '-o', str(binary)], check=True)
    result = subprocess.run([str(binary), str(artifacts / 'root')], capture_output=True, text=True, timeout=30)
    (artifacts / 'result.log').write_text(result.stdout + result.stderr)
    assert result.returncode == 0 and 'PASS: production root allocation/failure/borrow/release loops' in result.stdout, result
    print(result.stdout.strip(), flush=True)


if __name__ == '__main__':
    main()
