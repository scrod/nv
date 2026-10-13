#!/usr/bin/env python3
"""Snapshot acceptance and interrupted construction through fresh SQLCipher processes."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import re
import shlex

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--retention-prefix', type=int, default=0, help='Commit this many covering roots before each fault schedule.')
    parser.add_argument('--ssh-target')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--remote-env', action='append', default=[])
    args = parser.parse_args()
    assert bool(args.ssh_target) == bool(args.ssh_key)
    assert all(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', v) for v in args.remote_env)
    binary = args.binary.absolute()
    assert 0 <= args.retention_prefix <= 256
    artifacts = Path(tempfile.mkdtemp(prefix='nv-snapshot-process-', dir='/tmp' if args.ssh_target else None))
    print('Artifacts:', artifacts, flush=True)
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=60',
           '-o', f'ControlPath={artifacts}/ssh-control']
    uploaded = set()

    def remote(command, **kw):
        return subprocess.run([*ssh, args.ssh_target, shlex.join(command)], **kw)

    def probe(*command):
        if not args.ssh_target:
            return subprocess.run([str(binary), *map(str, command)], capture_output=True, text=True, timeout=60)
        for argument in map(str, command):
            path = Path(argument)
            if path.is_file() and path.is_relative_to(artifacts) and argument not in uploaded:
                subprocess.run(['scp', *ssh[1:], str(path), f'{args.ssh_target}:{path}'], capture_output=True, check=True, timeout=30)
                uploaded.add(argument)
        return remote(['env', *args.remote_env, str(binary), *map(str, command)], capture_output=True, text=True, timeout=120)
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
            if args.ssh_target:
                remote(['mkdir', '-p', str(case)], capture_output=True, check=True, timeout=30)
            directory, selection = case/'private', case/'selection.json'

            def invoke(command, *extra, code=0):
                run = probe(command, directory, selection, *extra)
                assert run.returncode == code, (name, command, run.returncode, run.stderr)
                return json.loads(run.stdout) if run.stdout.strip() else None

            created = probe('create', directory, profile)
            assert created.returncode == 0, created.stderr
            selection.write_text(created.stdout)
            prior = invoke('snapshot-series', args.retention_prefix)['roots'] if args.retention_prefix else []
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
                invoke('publish-drain-crash', 6, 1, -1, code=86)
            publication_input = invoke('inspect')
            publication_through = max(int(row[5]) for row in publication_input['objects'] if row[5])
            # The child receives selection/unlock inputs, independent of expectations here.
            actual = invoke('publish-drain')
            assert actual['publishedThrough'] == publication_through, actual
            assert actual['publishedNotes'] == ['edited', 'untouched'], actual
            assert sorted(n['body'] for n in actual['notes']) == ['edited', 'untouched'], actual
            assert actual['context'] == before['context'], (name, actual)
            added_snapshot = 0 if name == 'page-retained' else 1
            expected_snapshots = args.retention_prefix + added_snapshot
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
            snapshots = checked['generalSnapshots']
            assert all(s['encoding'] == 1 and len(s['pages']) == 1 and len(s['retentionParents']) == 1 for s in snapshots), snapshots
            for snapshot in snapshots:
                earlier = snapshot['root'] in prior
                assert sorted(c['body'] for c in snapshot['cells']) == (['A', 'untouched'] if earlier else ['edited', 'untouched']), snapshot
                assert len(snapshot['cut']) == (4 if earlier else 5), snapshot
            if snapshots:
                roots = {s['root'] for s in snapshots}
                covered = {p for s in snapshots for p in s['retentionParents']}
                tips = roots - covered
                actual_tips = {r[0].lower() for r in report['frontier']}
                assert len(tips) == 1 and actual_tips & roots == tips, report['frontier']
                if added_snapshot:
                    assert actual_tips == tips, report['frontier']
                else:
                    assert report['frontier'] == before_inspection['frontier'], report['frontier']
                assert all(p in {r[0].lower() for r in report['objects'] if r[5]} for p in covered), report
            # Verify maximal coverage from SQL edges independently of the wire reader.
            accepted = {r[0].lower() for r in report['objects'] if r[5] and r[1] != '0'}
            prerequisites = {r[1].lower() for r in report['dependencies']}
            assert {r[0].lower() for r in report['frontier']} == accepted - prerequisites, report['frontier']
            for row in surviving['objects']:
                assert any(later[:5] == row[:5] for later in report['objects']), (name, row)
            assert report['ready'] == [] and report['waiting'] == [], report
            if args.ssh_target:
                header = remote(['python3', '-c', 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).open("rb").read(16).hex())', str(directory/'Collection.sqlite')], capture_output=True, text=True, check=True, timeout=30)
                prefix = bytes.fromhex(header.stdout.strip())
            else:
                prefix = (directory/'Collection.sqlite').read_bytes()[:16]
            assert prefix != b'SQLite format 3\x00'
            if added_snapshot:
                invoke('edit')
                assert invoke('dump')['through'] == 4 + args.retention_prefix
            completed.append({'case': case.name, 'fault': fault, 'independent': checked, 'result': result})
            (artifacts/'results.json').write_text(json.dumps(completed, indent=2))
            print('PASS:', case.name, flush=True)
    assert len(completed) == 22
    print('PASS: 22 fresh-process snapshot scenarios, both profiles', flush=True)


if __name__ == '__main__':
    main()
