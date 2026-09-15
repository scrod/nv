#!/usr/bin/env python3
"""Qualify SQLCipher ASan instrumentation and run the real Runtime against that archive."""
import argparse
import os
import re
from pathlib import Path
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, required=True)
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
            '-Xswiftc', '-strict-memory-safety', '--filter', 'NVStorageRuntimeTests'], env=env, stdout=output, stderr=subprocess.STDOUT)
    log = (artifacts/'runtime.log').read_text()
    assert result.returncode == 0 and re.search(r'Test run with [1-9][0-9]* tests(?: in [0-9]+ suites)? passed', log), log[-5000:]
    print('PASS: instrumented-cipher Runtime suite', flush=True)


if __name__ == '__main__':
    main()
