#!/usr/bin/env python3
"""Challenge the actual C registry with held SQL progress and exact negative controls."""
import argparse
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
from qualification_reuse import CampaignReuse

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=ROOT / 'NVStorage/.deps/sqlcipher')
    parser.add_argument('--sanitize', choices=['address,undefined', 'thread'])
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-maintenance-c-'))
    print('Artifacts:', artifacts, flush=True)
    env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'))
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', '--static', 'sqlcipher'], env=env, text=True))
    flags = [str(prefix / 'lib/libsqlcipher.a') if f == '-lsqlcipher' else f for f in flags]
    common = ['clang', '-std=c11', '-g', '-O1', '-Wall', '-Wextra', '-Werror', '-Wconversion',
              '-Wsign-conversion', '-Wcast-align', '-pthread', '-I' + str(ROOT / 'NVStorage/Sources/CSQLMaintenance/include')]
    if args.sanitize: common += ['-fno-omit-frame-pointer', '-fsanitize=' + args.sanitize]
    source = ROOT / 'NVStorage/Sources/CSQLMaintenance/NVSQLMaintenance.c'
    original = source.read_text()
    mutations = [('valid', original, None)]
    if not args.sanitize:
        mutations += [('pre-start-interrupt', original.replace('if (work->running) sqlite3_interrupt', 'sqlite3_interrupt'),
                       'save.result == SQLITE_OK'),
                      ('lost-running-cancellation', original.replace('atomic_store_explicit(&work->cancelled, 1, memory_order_relaxed);', 'if (!work->running) atomic_store_explicit(&work->cancelled, 1, memory_order_relaxed);').replace('if (work->running) sqlite3_interrupt(work->connection);', '(void)work;'),
                       'vacuum.result == SQLITE_INTERRUPT')]
    reuse = CampaignReuse()
    headers = [ROOT/'NVStorage/Sources/CSQLMaintenance/include', prefix/'include', Path(__file__)]
    for name, code, expected in mutations:
        generated = artifacts / (name + '.c'); generated.write_text(code)
        obj, binary = artifacts / (name + '.o'), artifacts / name
        reuse.build(common + ['-include', str(ROOT / 'tests/SQLMaintenanceInterpose.h'), '-c', str(generated),
                                *[f for f in flags if f.startswith('-I')], '-o', str(obj)],
                    [generated, ROOT/'tests/SQLMaintenanceInterpose.h', *headers], obj, artifacts)
        reuse.build(common + [str(ROOT / 'tests/SQLMaintenanceProbe.c'), str(obj), *flags, '-o', str(binary)],
                    [ROOT/'tests/SQLMaintenanceProbe.c', obj, prefix/'lib/libsqlcipher.a', *headers], binary, artifacts)
        run = subprocess.run([str(binary)], text=True, capture_output=True, timeout=30)
        (artifacts / (name + '.log')).write_text(run.stdout + run.stderr)
        if expected:
            assert run.returncode != 0 and expected in run.stderr, (name, run.stdout, run.stderr)
        else:
            assert run.returncode == 0 and 'PASS:' in run.stdout, (name, run.stdout, run.stderr)
        print('PASS:', name, flush=True)


if __name__ == '__main__':
    main()
