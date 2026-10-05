#!/usr/bin/env python3
"""Restore barriers and fresh-process visibility, checked against exact retained bytes."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-restoration-process-'))
    print('Artifacts:', artifacts, flush=True)
    # Termination before commit, lost callback, materialization crash, actual VFS I/O failure.
    schedules = [('normal', None), ('before', (4, 1, -1)), ('after', (5, 1, -1)),
                 ('materialize', (7, 1, -1)), ('write-failure', (1, 1, 10)), ('full', (1, 1, 13))]
    count = 0
    for profile in ['public', 'encrypted']:
        for name, fault in schedules:
            case = artifacts / f'{profile}-{name}'
            case.mkdir()
            directory, selection = case/'private', case/'selection.json'

            def invoke(command, *extra, code=0):
                run = subprocess.run([str(binary), command, str(directory), str(selection), *map(str, extra)],
                                     capture_output=True, text=True, timeout=90)
                assert run.returncode == code, (command, run.returncode, run.stderr)
                return json.loads(run.stdout) if run.stdout.strip() else None

            created = subprocess.run([str(binary), 'create', str(directory), profile],
                                     capture_output=True, text=True, timeout=90, check=True)
            selection.write_text(created.stdout)
            invoke('edit'); invoke('delete')
            old = invoke('recently-deleted')
            assert len(old) == 1 and old[0]['birth'] == '01'*16
            phase = ('acceptance',) if name in ['before', 'after'] else ()
            result = invoke('restore', *(fault or ()), *phase, code=86 if fault and fault[2] == -1 else 0)
            if name == 'before':
                assert invoke('recently-deleted') == old
                assert [n['body'] for n in invoke('dump')['notes']] == ['untouched']
                assert invoke('inspect')['restorations'] == []
                invoke('restore')
            if name in ['write-failure', 'full']:
                assert result['initial'] == 'pending' and result['hits'] > 0, result
                assert result['source_visible_before_retry'], result
            assert invoke('recently-deleted') == []
            assert {n['birth']: n['body'] for n in invoke('dump')['notes']} == {'02'*16: 'untouched', '03'*16: 'edited'}
            report = invoke('inspect')
            assert len(report['restorations']) == 1
            assert report['restorations'][0][:2] == [('01'*16).upper(), old[0]['action'].upper()]
            check = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(report),
                                   text=True, capture_output=True, timeout=90)
            assert check.returncode == 0, check.stderr
            (case/'inspection.json').write_text(json.dumps(report))
            invoke('tamper', 'view')
            assert invoke('recently-deleted') == []
            invoke('delete-restored')
            current = invoke('recently-deleted')
            assert len(current) == 1 and current[0]['birth'] == '03'*16, current
            assert invoke('inspect')['restorations'] == report['restorations']
            count += 1
            print('PASS:', case.name, flush=True)
    assert count == 12
    print('PASS: 12 Restore recovery schedules, both profiles', flush=True)


if __name__ == '__main__':
    main()
