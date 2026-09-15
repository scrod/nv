#!/usr/bin/env python3
"""Compile and exercise the isolated actor/SQLCipher ownership experiment."""
import os
import platform
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).with_name('ActorDatabaseProbe.swift')
ARTIFACTS = Path(tempfile.mkdtemp(prefix='nv-actor-prototype-'))
print(f'Artifacts: {ARTIFACTS}', flush=True)
deps = Path(os.environ.get('NV_SQLCIPHER_PREFIX', ROOT / 'NVStorage/.deps/sqlcipher'))
base = ['swiftc', '-swift-version', '6', '-strict-concurrency=complete', '-parse-as-library',
        '-module-cache-path', str(ARTIFACTS / 'module-cache'),
        '-I', str(ROOT / 'NVStorage/Sources/CSQLCipher'), '-I', str(deps / 'include'),
        '-L', str(deps / 'lib')]
link = ['-lsqlcipher']
if os.uname().sysname == 'Darwin':
    base += ['-target', f'{platform.machine()}-apple-macosx11.5']
    link += ['-framework', 'Security', '-framework', 'CoreFoundation']
else:
    link += ['-lcrypto', '-lm', '-ldl', '-lpthread']

for name, flags in [('debug', ['-Onone']), ('release', ['-O'])]:
    binary = ARTIFACTS / name
    build = subprocess.run(base + flags + [str(SOURCE), '-o', str(binary)] + link,
                           capture_output=True, text=True, timeout=120)
    (ARTIFACTS / f'{name}-build.log').write_text(build.stdout + build.stderr)
    if build.returncode:
        raise RuntimeError(build.stderr)
    result = subprocess.run([str(binary), str(ARTIFACTS / f'{name}.db')],
                            capture_output=True, text=True, timeout=30)
    (ARTIFACTS / f'{name}-run.log').write_text(result.stdout + result.stderr)
    assert result.returncode == 0 and result.stdout.startswith('PASS:'), result
    assert (ARTIFACTS / f'{name}.db').read_bytes()[:16] != b'SQLite format 3\0'
    print(name, result.stdout.strip(), flush=True)

for flag, marker, diagnostic in [
    ('PROBE_MUTATION', 'EXPECT_MUTATION_REJECTION', "actor-isolated property 'generation'"),
    ('PROBE_ESCAPE', 'EXPECT_ESCAPE_REJECTION', "non-Sendable 'Connection'-typed result")
]:
    line = next(i for i, text in enumerate(SOURCE.read_text().splitlines(), 1) if marker in text)
    result = subprocess.run(base + ['-c', '-D', flag, str(SOURCE), '-o', str(ARTIFACTS / f'{flag}.o')],
                            capture_output=True, text=True, timeout=60)
    (ARTIFACTS / f'{flag}.log').write_text(result.stdout + result.stderr)
    assert result.returncode != 0 and diagnostic in result.stderr, result.stderr
    assert f'{SOURCE}:{line}:' in result.stderr, result.stderr
    print('PASS:', flag, flush=True)
