#!/usr/bin/env python3
"""Observe real keyed maintenance writes through the existing fault VFS, with an unkeyed control."""
import argparse
import json
import os
from pathlib import Path
import resource
import shlex
import subprocess
import tempfile
from qualification_reuse import CampaignReuse

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=ROOT / 'NVStorage/.deps/sqlcipher')
    parser.add_argument('--sanitize', choices=['address,undefined'])
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-maintenance-privacy-'))
    print('Artifacts:', artifacts, flush=True)
    env = dict(os.environ, PKG_CONFIG_PATH=str(prefix / 'lib/pkgconfig'))
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', '--static', 'sqlcipher'], env=env, text=True))
    flags = [str(prefix / 'lib/libsqlcipher.a') if flag == '-lsqlcipher' else flag for flag in flags]
    faults = (ROOT / 'NVStorage/Tests/Support/CStorageFaults/NVStorageFaults.c').read_text()
    # Job-scoped instrumentation preserves the actual VFS forwarding and fault edges.
    declaration = 'typedef struct { sqlite3_file file; sqlite3_file *real; } File;'
    assert faults.count(declaration) == 1
    faults = faults.replace(declaration, declaration.replace('} File;', 'int flags; } File;') + '''
static _Atomic int privateWrites, privateHits, privateTempWrites;
void nv_private_reset(void) { atomic_store(&privateWrites,0); atomic_store(&privateHits,0); atomic_store(&privateTempWrites,0); }
int nv_private_writes(void) { return atomic_load(&privateWrites); }
int nv_private_marker_hits(void) { return atomic_load(&privateHits); }
int nv_private_temp_writes(void) { return atomic_load(&privateTempWrites); }
static void observe_private(sqlite3_file *p, const void *bytes, int count) {
    static const unsigned char marker[] = "NVStoragePrivateWriteMarker-87cb9a934dae";
    const unsigned char *input = bytes;
    size_t length = sizeof(marker)-1;
    atomic_fetch_add(&privateWrites,1);
    if (((File *)p)->flags & (SQLITE_OPEN_TEMP_DB | SQLITE_OPEN_TRANSIENT_DB | SQLITE_OPEN_TEMP_JOURNAL | SQLITE_OPEN_SUBJOURNAL)) atomic_fetch_add(&privateTempWrites,1);
    for (size_t i=0; count>=0 && i+length<=(size_t)count; ++i) {
        if (!memcmp(input+i,marker,length)) { atomic_fetch_add(&privateHits,1); break; }
    }
}
''')
    write = '    int fault = hit(NV_FAULT_WRITE); if (fault) return fault;'
    opened = '    f->file.pMethods = &methods; return SQLITE_OK;'
    assert faults.count(write) == faults.count(opened) == 1
    faults = faults.replace(write, '    observe_private(p,b,n);\n' + write)
    faults = faults.replace(opened, '    f->flags = flags;\n' + opened)
    source, binary = artifacts / 'observed-vfs.c', artifacts / 'privacy'
    source.write_text(faults)
    common = ['clang', '-DSQLITE_HAS_CODEC', '-std=c11', '-g', '-O1', '-Wall', '-Wextra', '-Werror', '-Wconversion',
              '-Wsign-conversion', '-Wcast-align', '-pthread',
              '-I' + str(ROOT / 'NVStorage/Sources/CSQLMaintenance/include'),
              '-I' + str(ROOT / 'NVStorage/Tests/Support/CStorageFaults/include')]
    if args.sanitize:
        common += ['-fno-omit-frame-pointer', '-fsanitize=' + args.sanitize]
    CampaignReuse().build(common + [str(ROOT / 'tests/SQLMaintenancePrivacyProbe.c'), str(source),
                   str(ROOT / 'NVStorage/Sources/CSQLMaintenance/NVSQLMaintenance.c'), *flags, '-o', str(binary)],
                   [Path(__file__), source, ROOT/'tests/SQLMaintenancePrivacyProbe.c',
                    ROOT/'NVStorage/Sources/CSQLMaintenance', ROOT/'NVStorage/Tests/Support/CStorageFaults/include',
                    prefix/'include', prefix/'lib/libsqlcipher.a'], binary, artifacts)
    results = []
    # Two raw-key fixtures exercise this cipher boundary; Runtime tests cover actual profile derivation.
    for fixture, fault in [(k, f) for k in [1, 2] for f in [0, 778, 13]] + [(0, 0)]:
        name = f'{fixture}-{fault}'
        run = subprocess.run([str(binary), str(artifacts / (name + '.sqlite')), str(fixture), str(fault)],
                             capture_output=True, text=True, timeout=60,
                             preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_CORE, (0, 0)))
        (artifacts / (name + '.log')).write_text(run.stdout + run.stderr)
        if fixture == 0:
            assert run.returncode != 0 and 'nv_private_marker_hits() == 0' in run.stderr, (name, run.stdout, run.stderr)
        else:
            assert run.returncode == 0 and 'exact synthetic private values remain readable' in run.stdout, (name, run.stdout, run.stderr)
        results.append({'fixture': fixture, 'fault': fault, 'returncode': run.returncode})
        print('PASS:', 'unkeyed observation control' if fixture == 0 else name, flush=True)
    assert len(results) == 7
    (artifacts / 'results.json').write_text(json.dumps(results, indent=2))


if __name__ == '__main__':
    main()
