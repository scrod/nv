#!/usr/bin/env python3
"""Qualify SQLCipher ASan instrumentation and run the real Runtime against that archive."""
import argparse
import json
import os
import re
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def completed_tests(log):
    return re.search(r'Test run with [1-9][0-9]* tests?(?: in [0-9]+ suites?)? passed', log) is not None


def main():
    assert completed_tests('Test run with 81 tests in 1 suite passed after 1.0 seconds.')
    assert completed_tests('Test run with 81 tests in 2 suites passed after 1.0 seconds.')
    assert not completed_tests('Test run with 0 tests in 1 suite passed after 1.0 seconds.')
    assert not completed_tests('Test run with 81 tests in 1 suite failed after 1.0 seconds.')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--filter', default='NVStorageRuntimeTests')
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    archive = prefix/'lib/libsqlcipher.a'
    symbols = subprocess.check_output(['nm', '-u', str(archive)], text=True)
    assert '__asan_report_load' in symbols, 'Cipher archive is not ASan instrumented'
    artifacts = Path(tempfile.mkdtemp(prefix='nv-cipher-sanitizer-'))
    print('Artifacts:', artifacts, flush=True)
    env = dict(os.environ, PKG_CONFIG_PATH=str(prefix/'lib/pkgconfig'))
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', '--static', 'sqlcipher'], env=env, text=True))
    flags = [str(archive) if flag == '-lsqlcipher' else flag for flag in flags]
    executable = artifacts/'probe'
    subprocess.run(['clang', '-g', '-O1', '-fno-omit-frame-pointer', '-fsanitize=address',
                    str(ROOT/'tests/sqlcipher-sanitizer-probe.c'), *flags, '-o', str(executable)], check=True)
    valid = subprocess.run([str(executable)], capture_output=True, text=True)
    assert valid.returncode == 0, valid.stderr
    invalid = subprocess.run([str(executable), 'expired-handle'], capture_output=True, text=True)
    (artifacts/'negative.log').write_text(invalid.stderr)
    assert invalid.returncode != 0 and 'AddressSanitizer: heap-use-after-free' in invalid.stderr, invalid.stderr
    assert 'sqlite3_total_changes' in invalid.stderr, invalid.stderr
    print('PASS: SQLCipher instrumentation, valid handle and targeted expired-handle control', flush=True)
    with (artifacts/'runtime.log').open('w') as output:
        result = subprocess.run(['swift', 'test', '--build-system', 'native', '--package-path', str(ROOT/'NVStorage'),
            '--scratch-path', str(ROOT/'NVStorage/.build-cipher-asan'), '--sanitize', 'address',
            '--no-parallel', '--filter', args.filter], env=env, stdout=output, stderr=subprocess.STDOUT)
    log = (artifacts/'runtime.log').read_text()
    (artifacts/'results.json').write_text(json.dumps({'runtime_returncode': result.returncode,
        'positive_test_completion': completed_tests(log), 'filter': args.filter,
        'cipher_archive': str(archive)}, indent=2))
    assert result.returncode == 0 and completed_tests(log), log[-5000:]
    print('PASS: instrumented-cipher Runtime suite', flush=True)


if __name__ == '__main__':
    main()
