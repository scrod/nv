#!/usr/bin/env python3
"""Confirm the pinned extra-init boundary without changing cipher return values."""
from pathlib import Path
import platform
import subprocess
import tempfile
from qualification_reuse import CampaignReuse

root = Path(__file__).resolve().parents[1]
dependency = root / 'NVStorage/.deps/sqlcipher'
artifacts = Path(tempfile.mkdtemp(prefix='nv-sqlcipher-cold-start-'))
print('Artifacts:', artifacts, flush=True)
common = ['clang', '-O1', '-DSQLITE_HAS_CODEC', '-DSQLITE_THREADSAFE=1', '-DSQLITE_TEMP_STORE=3',
          '-DSQLITE_EXTRA_INIT=nv_test_extra_init', '-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown',
          '-I' + str(dependency / 'include')]
crypto = ['-DSQLCIPHER_CRYPTO_CC', '-framework', 'Security', '-framework', 'CoreFoundation'] if platform.system() == 'Darwin' else ['-DSQLCIPHER_CRYPTO_OPENSSL', '-lcrypto', '-ldl', '-lpthread', '-lm']
source = root / 'tests/SQLCipherColdStartProbe.c'
subprocess.run(['clang', '-DSQLITE_HAS_CODEC', '-std=c11', '-Wall', '-Wextra', '-Wconversion', '-Werror',
                '-fsyntax-only', '-I' + str(dependency / 'include'), str(source)], check=True)
binary = artifacts / 'probe'
CampaignReuse().build([*common, str(dependency / 'build/sqlite3.c'), str(source), *crypto, '-o', str(binary)],
    [Path(__file__), source, dependency/'build/sqlite3.c', dependency/'include'], binary, artifacts)
for mode in ['before', 'after']:
    result = subprocess.run([str(binary), mode], text=True, capture_output=True, timeout=30)
    (artifacts / (mode + '.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, (mode, result.stdout, result.stderr)
    print(mode, result.stdout.strip(), flush=True)
print('PASS: delayed extra-init negative and completed-init valid companion', flush=True)
