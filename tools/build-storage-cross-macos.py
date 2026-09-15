#!/usr/bin/env python3
"""Build an Intel/macOS 11.5 probe from the pinned SQLCipher amalgamation.

All generated files remain in a fresh /tmp directory. The existing dependency
builder supplies the revision-checked amalgamation; this cross build needs no
configure, make, system installation, or cleanup step.
"""
import json
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PIN = 'c4b275a47932888216bade83aff2bbc73df0ff85'


def main():
    dependency = ROOT / 'NVStorage/.deps/sqlcipher'
    revision = subprocess.check_output(['git', '-C', str(dependency / 'source'), 'rev-parse', 'HEAD'], text=True).strip()
    assert revision == PIN, revision
    subprocess.run(['git', '-C', str(dependency / 'source'), 'diff', '--exit-code'], check=True)
    subprocess.run(['git', '-C', str(dependency / 'source'), 'diff', '--cached', '--exit-code'], check=True)
    work = Path(tempfile.mkdtemp(prefix='nv-storage-intel-', dir='/tmp'))
    print(f'Artifacts: {work}', flush=True)
    for child in ['include', 'lib/pkgconfig', 'build']:
        (work / child).mkdir(parents=True)
    shutil.copy2(dependency / 'build/sqlite3.h', work / 'include/sqlite3.h')
    command = ['xcrun', 'clang', '-arch', 'x86_64', '-mmacosx-version-min=11.5', '-O2',
               '-DSQLITE_HAS_CODEC', '-DSQLITE_EXTRA_INIT=sqlcipher_extra_init',
               '-DSQLITE_EXTRA_SHUTDOWN=sqlcipher_extra_shutdown', '-DSQLCIPHER_CRYPTO_CC',
               '-DSQLITE_THREADSAFE=1', '-DSQLITE_TEMP_STORE=3', '-DSQLITE_OMIT_LOAD_EXTENSION=1',
               '-DSQLITE_ENABLE_MATH_FUNCTIONS', '-DSQLITE_ENABLE_PERCENTILE',
               '-c', str(dependency / 'build/sqlite3.c'), '-o', str(work / 'build/sqlite3.o')]
    subprocess.run(command, check=True)
    subprocess.run(['xcrun', 'ar', 'rcs', str(work / 'lib/libsqlcipher.a'), str(work / 'build/sqlite3.o')], check=True)
    (work / 'lib/pkgconfig/sqlcipher.pc').write_text(
        f'prefix={work}\nlibdir=${{prefix}}/lib\nincludedir=${{prefix}}/include\n'
        'Name: sqlcipher\nDescription: pinned NV Intel qualification build\nVersion: 4.19.0\n'
        'Libs: -L${libdir} -lsqlcipher -framework Security -framework CoreFoundation\nCflags: -I${includedir}\n')
    sources = {name: hashlib.sha256((dependency / 'build' / name).read_bytes()).hexdigest()
               for name in ['sqlite3.c', 'sqlite3.h']}
    (work / 'build-manifest.json').write_text(json.dumps(
        {'sqlcipher_revision': revision, 'amalgamation_sha256': sources, 'compile': command}, indent=2))
    print(f'PKG_CONFIG_PATH={work}/lib/pkgconfig', flush=True)


if __name__ == '__main__':
    main()
