#!/usr/bin/env python3
"""Received snapshot retention, parking and acceptance in independent SQLCipher processes."""
import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--ssh-target', help='Run the probe on this user-owned test host; inspect returned bytes locally.')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--remote-env', action='append', default=[])
    parser.add_argument('--artifact-parent', type=Path, help='Existing parent directory available locally and, for SSH runs, on the test host.')
    args = parser.parse_args()
    assert bool(args.ssh_target) == bool(args.ssh_key), 'Remote execution requires a target and its SSH key'
    assert all(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', value) for value in args.remote_env)
    binary = args.binary.absolute() if args.ssh_target else args.binary.resolve()
    parent = args.artifact_parent or ('/tmp' if args.ssh_target else None)
    artifacts = Path(tempfile.mkdtemp(prefix='nv-received-snapshot-process-', dir=parent))
    print('Artifacts:', artifacts, flush=True)
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=60',
           '-o', f'ControlPath={artifacts}/ssh-control']
    uploaded = set()

    def remote(command, **kwargs):
        return subprocess.run([*ssh, args.ssh_target, shlex.join(command)], **kwargs)

    def probe(*command):
        if not args.ssh_target:
            return subprocess.run([str(binary), *map(str, command)], capture_output=True, text=True, timeout=120)
        for argument in map(str, command):
            source = Path(argument)
            if source.is_file() and source.is_relative_to(artifacts) and argument not in uploaded:
                subprocess.run(['scp', *ssh[1:], str(source), f'{args.ssh_target}:{source}'], capture_output=True, check=True, timeout=30)
                uploaded.add(argument)
        return remote(['env', *args.remote_env, str(binary), *map(str, command)], capture_output=True, text=True, timeout=120)
    schedules = [
        ('root-first', 'root', False, False, None),
        ('pages-first', 'root', True, False, None),
        ('history-first', 'root', False, True, None),
        ('retention-before-commit', 'root', False, False, (4, 1, -1, 'retention')),
        ('retention-lost-callback', 'root', False, False, (5, 1, -1, 'retention')),
        ('parking-begin', 'root', False, False, (11, 1, -1, 'parking')),
        ('parking-before-commit', 'root', False, False, (4, 1, -1, 'parking')),
        ('parking-after-commit', 'root', False, False, (5, 1, -1, 'parking')),
        ('acceptance-before-commit', 'root', True, True, (4, 1, -1, 'acceptance')),
        ('acceptance-lost-callback', 'root', True, True, (5, 1, -1, 'acceptance')),
        ('during-materialization', 'root', True, True, (6, 1, -1, 'retention')),
        ('rejection-begin', 'bad', False, True, (9, 1, -1, 'rejection')),
        ('rejection-cleanup', 'bad', False, True, (10, 1, -1, 'rejection')),
        ('rejection-before-commit', 'bad', False, True, (4, 1, -1, 'rejection')),
        ('rejection-after-commit', 'bad', False, True, (5, 1, -1, 'rejection')),
        ('retention-enospc', 'root', False, False, (1, 1, 13, 'retention')),
        ('parking-sync-eio', 'root', False, False, (2, 1, 1034, 'parking')),
        ('rejection-sync-eio', 'bad', False, True, (2, 1, 1034, 'rejection')),
        ('acceptance-sync-eio', 'root', True, True, (2, 1, 1034, 'acceptance')),
        ('acceptance-sync-ambiguous', 'root', True, True, (8, 1, 1034, 'acceptance')),
    ]
    results = []
    for profile in ['public', 'encrypted']:
        for name, role, pages_first, history_first, fault in schedules:
            case = artifacts / f'{profile}-{name}'
            case.mkdir()
            if args.ssh_target: remote(['mkdir', '-p', str(case)], capture_output=True, check=True, timeout=30)
            created = probe('seed-pair', case, profile, 'A')
            assert created.returncode == 0, created.stderr
            pair = json.loads(created.stdout)
            selected = {}
            for side in ['left', 'right']:
                selected[side] = case / f'{side}.json'
                selected[side].write_text(pair[side])

            def invoke(side, command, *extra, code=0):
                run = probe(command, case/side, selected[side], *extra)
                assert run.returncode == code, (name, command, run.returncode, run.stdout, run.stderr)
                return json.loads(run.stdout) if run.stdout.strip() else None

            edit = invoke('left', 'apply', 'put', 1, 'E')
            history = case/'E.object'
            history.write_bytes(bytes.fromhex(edit['envelope']))
            manifest = invoke('left', 'snapshot-export', case/'incoming')
            by_id = {row['id']: row for row in manifest['files']}
            root_file, bad_file = by_id[manifest['root']]['file'], by_id[manifest['bad']]['file']
            pages = [row for row in manifest['files'] if row['kind'] == '3']
            assert len(pages) > 2, pages
            baseline = invoke('right', 'inspect')
            if history_first:
                assert invoke('right', 'receive-file', history)['status'] == 'accepted'
            if pages_first:
                for page in pages:
                    assert invoke('right', 'receive-file', page['file'])['status'] == 'retained'
            input_file = root_file if role == 'root' else bad_file
            killed = fault is not None and fault[2] == -1
            outcome = invoke('right', 'receive-file', input_file, *(fault or ()), code=86 if killed else 0)
            if fault and not killed:
                assert outcome['status'] == 'failed' and outcome['hits'] >= 1, outcome
                assert outcome['error'].startswith('database('), outcome
            surviving = invoke('right', 'inspect')
            (case/'before-reopen.json').write_text(json.dumps(surviving))
            root_row = next((row for row in surviving['objects'] if row[0].lower() == manifest['root']), None)
            if name == 'retention-before-commit':
                assert root_row is None, surviving
            if name == 'retention-lost-callback':
                assert root_row and root_row[5] == '' and [root_row[0]] in surviving['ready'], surviving
            if name in ['parking-begin', 'parking-before-commit']:
                assert root_row and surviving['waiting'] == [] and [root_row[0]] in surviving['ready'], surviving
            if name == 'parking-after-commit':
                assert root_row and surviving['waiting'] and [root_row[0]] not in surviving['ready'], surviving
            if name in ['acceptance-lost-callback', 'during-materialization']:
                assert root_row and root_row[5] != '', surviving
                batch = [row for row in surviving['objects'] if row[0].lower() in {manifest['root'], *(p['id'] for p in pages)}]
                assert len(batch) == len(pages) + 1 and len({row[5] for row in batch}) == 1, batch
            if name == 'acceptance-before-commit':
                assert root_row and root_row[5] == '' and all(row[5] == '' for row in surviving['objects'] if row[1] == '3' and row[0].lower() in by_id), surviving
            if name in ['parking-before-commit', 'rejection-before-commit', 'acceptance-before-commit']:
                mode = 'parking' if name.startswith('parking') else 'rejection' if name.startswith('rejection') else 'acceptance'
                cut = 11 if mode == 'parking' else 10 if mode == 'rejection' else 4
                invoke('right', 'publish-drain-crash', cut, 1, -1, mode, code=86)
            # Recovery knows only surviving storage and the normal selection/password.
            recovered = invoke('right', 'publish-drain')
            assert sorted(row['body'] for row in recovered['notes']) == (['E', 'untouched'] if history_first else ['A', 'untouched']), recovered
            assert recovered['publishedNotes'] == (['E', 'untouched'] if history_first else ['A', 'untouched']), recovered
            if name == 'acceptance-before-commit':
                assert recovered['publishedThrough'] == 2 and recovered['through'] == 3, recovered
            if role == 'bad':
                report = invoke('right', 'inspect')
                rejected = [row for row in report['rejected'] if row[0].lower() == manifest['bad']]
                assert len(rejected) == 1 and rejected[0][2] == '20', report
            for page in pages:
                invoke('right', 'receive-file', page['file'])
            if not history_first:
                invoke('right', 'receive-file', history)
            assert invoke('right', 'receive-file', root_file)['status'] == 'accepted'
            final = invoke('right', 'dump')
            assert sorted(row['body'] for row in final['notes']) == ['E', 'untouched'] and final['through'] == 3, final
            report = invoke('right', 'inspect')
            (case/'after-reopen.json').write_text(json.dumps(report))
            checked = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(report),
                                     text=True, capture_output=True, timeout=120)
            assert checked.returncode == 0, checked.stderr
            observed = json.loads(checked.stdout)
            assert observed['operations'] == 5 and observed['actions'] == 3 and len(observed['generalSnapshots']) == 1, observed
            assert sorted(c['body'] for c in observed['generalSnapshots'][0]['cells']) == ['E', 'untouched'], observed
            assert report['ready'] == [] and report['waiting'] == [], report
            assert report['private'] == baseline['private'], (name, report['private'])
            for row in surviving['objects']:
                assert any(later[:5] == row[:5] for later in report['objects']), (name, row)
            page_ids = {p['id'] for p in pages}
            retained = [row for row in report['objects'] if row[0].lower() in page_ids | {manifest['root']}]
            assert len(retained) == len(page_ids) + 1 and len({row[5] for row in retained}) == 1, retained
            invoke('right', 'apply', 'put', 2, 'Further edit')
            assert sorted(row['body'] for row in invoke('right', 'dump')['notes']) == ['E', 'Further edit']
            if args.ssh_target:
                header = remote(['python3', '-c', 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).open("rb").read(16).hex())', str(case/'right/Collection.sqlite')], capture_output=True, text=True, check=True, timeout=30)
                prefix = bytes.fromhex(header.stdout.strip())
            else: prefix = (case/'right/Collection.sqlite').read_bytes()[:16]
            assert prefix != b'SQLite format 3\x00'
            results.append({'case': case.name, 'fault': fault, 'outcome': outcome, 'observed': observed})
            (artifacts/'results.json').write_text(json.dumps(results, indent=2))
            print('PASS:', case.name, flush=True)
    assert len(results) == 40
    print('PASS: 40 received-snapshot process schedules, both profiles', flush=True)


if __name__ == '__main__':
    main()
