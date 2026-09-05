#!/usr/bin/env python3
"""Candidate per-collection SQLite protocol; synthetic private DBs/files only.

Actual crash/reopen tests plus named implementation mutation controls. Does not
test power loss, production codecs, causal merge, Apple coordination or UI.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import tempfile


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sqlcipher-build', type=Path)
    args = p.parse_args()
    out = Path(tempfile.mkdtemp(prefix='nv-sqlite-protocol-'))
    binary = out / 'probe'
    link = ['-lsqlite3'] if not args.sqlcipher_build else [
        '-DNV_SQLCIPHER_PROBE', '-DSQLITE_HAS_CODEC', '-I', str(args.sqlcipher_build),
        str(args.sqlcipher_build / 'libsqlite3.a'), '-framework', 'Security', '-framework', 'CoreFoundation']
    subprocess.run(['clang', '-O2', '-std=c11', '-Wall', '-Wextra', '-Werror',
                    str(Path(__file__).with_name('SQLiteCollectionProtocolProbe.c')), *link, '-o', str(binary)], check=True)
    result = {'engine': 'sqlcipher-raw' if args.sqlcipher_build else 'system-sqlite', 'checks': [], 'controls': []}
    env = dict(os.environ, NV_PROBE_KEY_MODE='raw' if args.sqlcipher_build else 'none')
    print(f'Artifacts: {out}', flush=True)

    def run(*cmd, policy='safe', cut='none', error=None):
        proc = subprocess.run([str(binary), *map(str, cmd)], env=dict(env, NV_PROTOCOL_POLICY=policy, NV_PROTOCOL_CUT=cut),
                              capture_output=True, text=True, timeout=30)
        with (out / 'calls.jsonl').open('a') as f:
            f.write(json.dumps(dict(cmd=list(map(str, cmd)), policy=policy, cut=cut, code=proc.returncode,
                                   stdout=proc.stdout, stderr=proc.stderr))+'\n')
        if error:
            assert proc.returncode != 0 and error in proc.stderr, proc
            return None
        assert proc.returncode == 0, (cmd, proc.stdout, proc.stderr)
        return json.loads(proc.stdout)

    def interrupt(cmd, cut, intervention=None, policy='safe'):
        proc = subprocess.Popen([str(binary), *map(str, cmd)], env=dict(env, NV_PROTOCOL_CUT=cut, NV_PROTOCOL_POLICY=policy),
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as sel:
                sel.register(proc.stdout, selectors.EVENT_READ)
                assert sel.select(timeout=30), (cmd, cut)
                line = proc.stdout.readline().strip()
            assert line == f'READY {cut}', (cmd, cut, line)
            if intervention:
                intervention()
                stdout, stderr = proc.communicate('\n', timeout=30)
                assert proc.returncode == 0, (stdout, stderr)
            else:
                proc.kill(); proc.wait(timeout=10)
                assert proc.returncode == -signal.SIGKILL
        finally:
            if proc.poll() is None:
                proc.kill(); proc.wait(timeout=10)
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                if not stream.closed:
                    stream.close()

    serial = 0
    def fixture(mode):
        nonlocal serial
        serial += 1
        d = out / str(serial); d.mkdir()
        db, file = d/'private.db', d/'source.txt'
        run('source', file, 4); run('init', db, mode, file)
        return db, file

    def tx(db, file, kind, **kw):
        return run('transaction', db, kind, file, **kw)

    def check(name, db, expected):
        # Recovery never consults the runner's expected result or prior process.
        actual = run('recover', db)
        for key, value in expected.items():
            assert actual[key] == value, (name, key, actual, expected)
        result['checks'].append(dict(name=name, actual=actual))

    for mode in ('WAL', 'DELETE'):
        for cut in ('after-object', 'after-application', 'before-commit', 'after-commit', 'vfs-write', 'vfs-sync', 'write-full'):
            db, file = fixture(mode); tx(db,file,'reserve')
            if cut == 'write-full':
                assert tx(db,file,'import',cut=cut)['full']
            else:
                interrupt(['transaction', db, 'import', file], cut)
            expected = {'latest':1, 'frozen':1, 'receipts':0}
            if cut not in ('vfs-write','vfs-sync'):
                committed = cut == 'after-commit'
                expected.update(imported=int(committed), status=int(committed), values=[4 if committed else 0,0,7])
            actual = run('recover',db)
            # Ambiguous interrupted COMMIT may recover old or new, never halves.
            assert (actual['imported'],actual['status'],actual['values'][0]) in ((0,0,0),(1,1,4))
            check(f'{mode}/import/{cut}',db,expected)

        for cut in ('after-payload','before-commit','after-commit','write-full'):
            db,file=fixture(mode); tx(db,file,'reserve'); run('source',file,8)
            if cut == 'write-full': tx(db,file,'preview',cut=cut)
            else: interrupt(['transaction',db,'preview',file],cut)
            check(f'{mode}/preview/{cut}',db,{'latest':2 if cut=='after-commit' else 1,'frozen':1,'imported':0})

        # C arrived before the snapshot, P arrives after it; crash at acceptance.
        for cut in ('before-commit','after-commit'):
            db,file=fixture(mode); tx(db,file,'parent')
            interrupt(['transaction',db,'child',file],cut)
            # Even the pre-commit cut leaves C ready after durable P; reopen
            # must accept that complete local work before publishing note state.
            check(f'{mode}/parked/{cut}',db,{'values':[0,2,7]})
            tx(db,file,'child'); tx(db,file,'child')  # idempotent acceptance
            check(f'{mode}/parked/retry/{cut}',db,{'through':3,'values':[0,2,7]})

        for cut in ('recovery-after-apply','recovery-after-commit'):
            db,file=fixture(mode); tx(db,file,'parent')
            interrupt(['recover',db],cut)
            check(f'{mode}/crash-during-ready-drain/{cut}',db,{'through':3,'values':[0,2,7]})
        db,file=fixture(mode); tx(db,file,'parent')
        assert run('recover',db,policy='skip-ready')['values'] != [0,2,7]
        result['controls'].append(f'{mode}/skip-ready')
        db,file=fixture(mode); tx(db,file,'parent',policy='no-ready')
        assert run('recover',db)['values'] != [0,2,7]
        result['controls'].append(f'{mode}/no-ready')
        for cut in ('before-commit','after-commit'):
            db,file=fixture(mode)
            interrupt(['transaction',db,'parent',file],cut)
            check(f'{mode}/parent-and-queue/{cut}',db,{'values':[0,2 if cut=='after-commit' else 0,7]})

        for cache_op in ('cache','drop-cache','foreign-cache'):
            db,file=fixture(mode); tx(db,file,'reserve'); tx(db,file,'import'); tx(db,file,cache_op)
            tx(db,file,'delete')
            check(f'{mode}/{cache_op}',db,{'values':[0,0,7],'deleted':1,'status':1})

        # A committed import, a newer pending preview, then a crash in settlement.
        for cut in ('after-receipt','before-commit','after-commit'):
            db,file=fixture(mode); tx(db,file,'reserve')
            interrupt(['transaction',db,'import',file],'after-commit')
            check(f'{mode}/lost-import-callback',db,{'imported':1,'status':1})
            interrupt(['settle',db,file],cut)
            completed = cut=='after-commit'
            check(f'{mode}/receipt/{cut}',db,{'status':2 if completed else 1,'receipts':int(completed),
                                           'frozen':0 if completed else 1})
            run('settle',db,file)
            tx(db,file,'delete')
            for i in range(3):
                check(f'{mode}/repeated-reopen-deleted/{cut}/{i}',db,{'imported':1,'status':2,'values':[0,0,7]})

        for intervention in ('edit','replace-equal','delete','root'):
            db,file=fixture(mode); tx(db,file,'reserve'); tx(db,file,'import')
            def change():
                if intervention=='edit': run('source',file,8); tx(db,file,'preview')
                elif intervention=='replace-equal':
                    displaced=file.with_suffix('.original'); file.rename(displaced); shutil.copyfile(displaced,file)
                else: tx(db,file,intervention)
            interrupt(['settle',db,file],'after-verify',change)
            check(f'{mode}/stale/{intervention}',db,{'associated':0,'imported':1})
            run('settle',db,file)
            check(f'{mode}/retry-stale/{intervention}',db,{'associated':0,'imported':1})
            if intervention=='edit':
                check(f'{mode}/independent-preview',db,{'latest':2,'frozen':1,'status':1})
                tx(db,file,'delete'); run('settle',db,file)
                check(f'{mode}/delete-settlement-preserves-preview',db,{'latest':2,'frozen':0,'status':2})

        db,file=fixture(mode); tx(db,file,'reserve'); tx(db,file,'import')
        run('settle',db,file,cut='write-full')
        check(f'{mode}/receipt-storage-full',db,{'receipts':0,'frozen':1,'status':1,'imported':1})
        run('settle',db,file)
        check(f'{mode}/receipt-storage-retry',db,{'receipts':1,'frozen':0,'status':2,'imported':1})

        db,file=fixture(mode); tx(db,file,'reserve')
        interrupt(['transaction',db,'import',file],'after-object',lambda:run('source',file,8))
        tx(db,file,'preview'); run('settle',db,file)
        check(f'{mode}/source-changes-after-admission',db,{'values':[4,0,7],'latest':2,'frozen':1,'associated':0,'status':1})

        # One consistent read transaction captures both values and coverage;
        # compression/publication can lag another acceptance transaction.
        db,file=fixture(mode); tx(db,file,'parent')
        interrupt(['delayed-cache',db],'after-capture',lambda:tx(db,file,'child'))
        check(f'{mode}/delayed-cache',db,{'values':[0,2,7],'through':3})
        db,file=fixture(mode); tx(db,file,'parent')
        interrupt(['delayed-cache',db],'after-capture',lambda:tx(db,file,'child'),policy='split-coverage')
        assert run('recover',db)['values'] != [0,2,7]
        result['controls'].append(f'{mode}/split-coverage')
        if mode=='WAL':
            # WAL permits the other writer to commit while our read transaction
            # is still between value extraction and coverage extraction.
            db,file=fixture(mode); tx(db,file,'parent')
            interrupt(['delayed-cache',db],'after-values',lambda:tx(db,file,'child'))
            check(f'{mode}/consistent-read-during-writer',db,{'values':[0,2,7],'through':3})
            db,file=fixture(mode); tx(db,file,'parent')
            interrupt(['delayed-cache',db],'after-values',lambda:tx(db,file,'child'),policy='split-read')
            assert run('recover',db)['values'] != [0,2,7]
            result['controls'].append(f'{mode}/split-read')

        db,file=fixture(mode); tx(db,file,'parent'); tx(db,file,'cache'); tx(db,file,'child')
        interrupt(['transaction',db,'cache',file],'before-commit')
        check(f'{mode}/failed-cache-rebuild',db,{'values':[0,2,7],'through':3})

        # One connected trace: lost import callback, old captured snapshot,
        # ready-but-unaccepted C, later Delete, newer preview and a replaced
        # root. Two further crashes must not lose C or repeat the deleted I.
        db,file=fixture(mode); tx(db,file,'reserve')
        interrupt(['transaction',db,'import',file],'after-commit'); tx(db,file,'parent')
        def overlapping_changes():
            tx(db,file,'delete'); run('source',file,8)
            tx(db,file,'preview'); tx(db,file,'root')
        interrupt(['delayed-cache',db],'after-capture',overlapping_changes)
        interrupt(['recover',db],'recovery-after-apply')
        expected={'values':[0,2,7],'through':5,'status':1,'latest':2,'frozen':1,'associated':0}
        check(f'{mode}/combined/ready-recovery',db,expected)
        interrupt(['settle',db,file],'before-commit')
        check(f'{mode}/combined/receipt-rollback',db,expected)
        run('settle',db,file); tx(db,file,'drop-cache')
        check(f'{mode}/combined/settled-rebuild',db,dict(expected,status=2,frozen=0,cache_used=0))

        for mutation in ('insert-order','replay-consent','live-only','forget-link','stale-receipt'):
            db,file=fixture(mode); tx(db,file,'reserve')
            if mutation=='insert-order':
                tx(db,file,'parent'); tx(db,file,'child')
                assert run('recover',db,policy=mutation)['values'] != [0,2,7]
            elif mutation=='replay-consent':
                assert run('recover',db,policy=mutation)['status'] != 0
            elif mutation=='live-only':
                tx(db,file,'import'); tx(db,file,'delete')
                assert run('recover',db,policy=mutation)['status'] != 1
            elif mutation=='forget-link':
                tx(db,file,'import',policy=mutation)
                run('recover',db,error='!imported || pending || receipts')
            else:
                tx(db,file,'import'); run('source',file,8)
                run('settle',db,file,policy=mutation)
                assert run('recover',db)['associated'] != 0
            result['controls'].append(f'{mode}/{mutation}')
        (out/'results.json').write_text(json.dumps(result,indent=2)+'\n')
        print(f'{mode}: checks passed',flush=True)
    print(f"PASS: {len(result['checks'])} observations; {len(result['controls'])} designated mutations: {out/'results.json'}")


if __name__ == '__main__':
    main()
