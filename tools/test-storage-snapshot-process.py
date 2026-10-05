#!/usr/bin/env python3
"""Snapshot acceptance and interrupted construction through fresh SQLCipher processes."""
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
    artifacts = Path(tempfile.mkdtemp(prefix='nv-snapshot-process-'))
    print('Artifacts:', artifacts, flush=True)
    completed = []
    schedules = [
        ('normal', 'snapshot-save', None, None),
        ('page-retained', 'snapshot-candidate', (5, 1, -1), False),
        ('root-retained', 'snapshot-candidate', (5, 2, -1), False),
        ('acceptance-before-commit', 'snapshot-save', (4, 1, -1), False),
        ('acceptance-lost-callback', 'snapshot-save', (5, 1, -1), True),
        ('during-catch-up', 'snapshot-save', (6, 1, -1), True),
        ('after-catch-up', 'snapshot-save', (5, 2, -1), True),
        ('candidate-enospc', 'snapshot-candidate', (1, 1, 13), None),
        ('candidate-sync-eio', 'snapshot-candidate', (2, 1, 1034), None),
        ('acceptance-sync-eio', 'snapshot-save', (2, 1, 1034), None),
        ('sync-ambiguous', 'snapshot-candidate', (8, 1, 1034), None),
    ]
    for profile in ['public', 'encrypted']:
        for name, command, fault, committed in schedules:
            case = artifacts / f'{profile}-{name}'
            case.mkdir()
            directory, selection = case/'private', case/'selection.json'

            def invoke(command, *extra, code=0):
                run = subprocess.run([str(binary), command, str(directory), str(selection), *map(str, extra)],
                                     capture_output=True, text=True, timeout=60)
                assert run.returncode == code, (name, command, run.returncode, run.stderr)
                return json.loads(run.stdout) if run.stdout.strip() else None

            created = subprocess.run([str(binary), 'create', str(directory), profile],
                                     capture_output=True, text=True, timeout=60, check=True)
            selection.write_text(created.stdout)
            invoke('edit')
            before = invoke('dump')
            before_inspection = invoke('inspect')
            initial_ids = {row[0] for row in before_inspection['objects']}
            killed = fault is not None and fault[2] == -1
            result = invoke(command, *(fault or ()), code=86 if killed else 0)
            if fault and not killed:
                assert result['initial'] == 'pending' and result['hits'] == 1, result
                assert result['error'].startswith('database('), result
            surviving = invoke('inspect')
            # Inspect the real pre-reopen state: termination before acceptance leaves candidates,
            # while termination after COMMIT leaves the entire root/page batch accepted.
            new_objects = [row for row in surviving['objects'] if row[0] not in initial_ids]
            if killed:
                roots = [row for row in new_objects if int(row[1]) == 2]
                assert len(roots) == (0 if name == 'page-retained' else 1), new_objects
                assert all((row[5] != '') == committed for row in new_objects), new_objects
                if name != 'page-retained':
                    assert surviving['ready'] == ([] if committed else [[roots[0][0]]]), surviving['ready']
            if name == 'root-retained':
                invoke('open-crash', 6, 1, -1, code=86)
            # The child receives selection/unlock inputs, independent of expectations here.
            actual = invoke('dump')
            assert sorted(n['body'] for n in actual['notes']) == ['edited', 'untouched'], actual
            assert actual['context'] == before['context'], (name, actual)
            expected_snapshots = 0 if name == 'page-retained' else 1
            assert actual['through'] == 2 + expected_snapshots, actual
            report = invoke('inspect')
            (case/'inspection-before-reopen.json').write_text(json.dumps(surviving))
            (case/'inspection-after-reopen.json').write_text(json.dumps(report))
            inspected = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')],
                                       input=json.dumps(report), text=True, capture_output=True, timeout=60)
            assert inspected.returncode == 0, inspected.stderr
            checked = json.loads(inspected.stdout)
            assert checked['operations'] == 5 and checked['actions'] == 3, checked
            for table in ['operations', 'actions', 'members', 'operation_occurrences', 'action_occurrences']:
                assert report[table] == before_inspection[table], (name, table)
            assert len(checked['generalSnapshots']) == expected_snapshots, checked
            for snapshot in checked['generalSnapshots']:
                assert sorted(c['body'] for c in snapshot['cells']) == ['edited', 'untouched'], snapshot
                assert len(snapshot['cut']) == 5 and len(snapshot['pages']) == 1, snapshot
                assert len(report['frontier']) == 1 and report['frontier'][0][0].lower() == snapshot['root'], report['frontier']
            for row in surviving['objects']:
                assert any(later[:5] == row[:5] for later in report['objects']), (name, row)
            assert report['ready'] == [] and report['waiting'] == [], report
            assert (directory/'Collection.sqlite').read_bytes()[:16] != b'SQLite format 3\x00'
            if expected_snapshots:
                invoke('edit')
                assert invoke('dump')['through'] == 4
            completed.append({'case': case.name, 'fault': fault, 'independent': checked, 'result': result})
            (artifacts/'results.json').write_text(json.dumps(completed, indent=2))
            print('PASS:', case.name, flush=True)
    assert len(completed) == 22
    print('PASS: 22 fresh-process snapshot scenarios, both profiles', flush=True)


if __name__ == '__main__':
    main()
