#!/usr/bin/env python3
"""Recover a delayed three-root chain using fresh processes and independent bytes."""
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
    parser.add_argument('--ssh-target')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--remote-env', action='append', default=[])
    args = parser.parse_args()
    assert bool(args.ssh_target) == bool(args.ssh_key)
    assert all(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', v) for v in args.remote_env)
    artifacts = Path(tempfile.mkdtemp(prefix='nv-retention-delivery-', dir='/tmp'))
    binary = args.binary.absolute()
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=60',
           '-o', f'ControlPath={artifacts}/ssh-control']
    uploaded = set()
    print('Artifacts:', artifacts, flush=True)

    def remote(command, **kw):
        return subprocess.run([*ssh, args.ssh_target, shlex.join(command)], **kw)

    def probe(*command, code=0):
        if args.ssh_target:
            for argument in map(str, command):
                path = Path(argument)
                if path.is_file() and path.is_relative_to(artifacts) and argument not in uploaded:
                    subprocess.run(['scp', *ssh[1:], str(path), f'{args.ssh_target}:{path}'], capture_output=True, check=True, timeout=30)
                    uploaded.add(argument)
            run = remote(['env', *args.remote_env, str(binary), *map(str, command)], capture_output=True, text=True, timeout=120)
        else:
            run = subprocess.run([str(binary), *map(str, command)], capture_output=True, text=True, timeout=120)
        assert run.returncode == code, (command, run.returncode, run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else None

    results = []
    for profile in ['public', 'encrypted']:
        for schedule in ['delayed', 'lost-callback', 'commit-eio']:
            case = artifacts/f'{profile}-{schedule}'
            case.mkdir()
            if args.ssh_target:
                remote(['mkdir', '-p', str(case)], capture_output=True, check=True, timeout=30)
            pair = probe('seed-pair', case, profile, 'A')
            selections = {}
            for side in ['left', 'right']:
                selections[side] = case/f'{side}.json'
                selections[side].write_text(pair[side])

            def invoke(side, command, *extra, code=0):
                return probe(command, case/side, selections[side], *extra, code=code)

            baseline = invoke('right', 'inspect')
            roots = invoke('left', 'snapshot-series', 3)['roots']
            source = invoke('left', 'inspect')
            inspected = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(source),
                                       capture_output=True, text=True, timeout=60, check=True)
            oracle = json.loads(inspected.stdout)
            snapshots = {s['root']: s for s in oracle['generalSnapshots']}
            assert len(snapshots) == 3
            parent = next(row[0].lower() for row in baseline['objects'] if row[1] == '2')
            for root in roots:
                assert snapshots[root]['retentionParents'] == [parent]
                parent = root
            files = {}
            for row in source['objects']:
                path = case/(row[0].lower()+'.object')
                path.write_bytes(bytes.fromhex(row[4])); files[row[0].lower()] = path

            # Admit newest pages/root first. Restart has neither an expected-note oracle
            # nor the source's callback log, and the parent remains positively absent.
            for root in reversed(roots[1:]):
                for page in snapshots[root]['pages']:
                    assert invoke('right', 'receive-file', files[page])['status'] == 'retained'
                assert invoke('right', 'receive-file', files[root])['status'] == 'waiting'
                report = invoke('right', 'inspect')
                assert all(row[5] == '' for row in report['objects'] if row[0].lower() in roots)
                assert report['frontier'] == baseline['frontier']
                assert invoke('right', 'publish-drain')['through'] == 1
            for page in snapshots[roots[0]]['pages']:
                invoke('right', 'receive-file', files[page])
            fault = (5, 1, -1, 'acceptance') if schedule == 'lost-callback' else (2, 1, 1034, 'acceptance') if schedule == 'commit-eio' else ()
            outcome = invoke('right', 'receive-file', files[roots[0]], *fault, code=86 if schedule == 'lost-callback' else 0)
            if schedule == 'commit-eio':
                assert outcome['status'] == 'failed' and outcome['hits'] == 1 and outcome['error'].startswith('database('), outcome
            surviving = invoke('right', 'inspect')
            accepted_roots = {r[0].lower() for r in surviving['objects'] if r[5] and r[0].lower() in roots}
            if schedule == 'lost-callback':
                assert accepted_roots == {roots[0]}, surviving
            elif schedule == 'commit-eio':
                assert accepted_roots in [set(), {roots[0]}], surviving
            else:
                assert accepted_roots == set(roots), surviving
            accepted = {r[0].lower() for r in surviving['objects'] if r[5] and r[1] != '0'}
            prerequisites = {r[1].lower() for r in surviving['dependencies']}
            assert {r[0].lower() for r in surviving['frontier']} == accepted - prerequisites, surviving
            for root in accepted_roots:
                unit = [r for r in surviving['objects'] if r[0].lower() in {root, *snapshots[root]['pages']}]
                assert len(unit) == 1 + len(snapshots[root]['pages']) and len({r[5] for r in unit}) == 1, unit
                assert all(p in accepted and [root.upper(), p.upper()] in surviving['dependencies'] for p in snapshots[root]['retentionParents'])
            actual = invoke('right', 'publish-drain')
            assert actual['through'] == 4 and actual['publishedNotes'] == ['A', 'untouched'], actual
            assert sorted(n['body'] for n in actual['notes']) == ['A', 'untouched']
            final = invoke('right', 'inspect')
            assert final['ready'] == [] and final['waiting'] == []
            assert [r[0].lower() for r in final['frontier']] == [roots[2]]
            assert final['operations'] == baseline['operations'] and final['actions'] == baseline['actions']
            for row in source['objects']:
                assert any(r[:5] == row[:5] for r in final['objects']), row[0]
            for root in roots:
                for parent in snapshots[root]['retentionParents']:
                    assert [root.upper(), parent.upper()] in final['dependencies']
            # Duplicate arrival preserves exact membership and does not repeat logical effects.
            assert invoke('right', 'receive-file', files[roots[2]])['status'] == 'accepted'
            assert invoke('right', 'dump')['through'] == 4
            # Disposable rows rebuild from the surviving complete closure in another process.
            invoke('right', 'tamper', 'cell')
            rebuilt = invoke('right', 'dump')
            assert sorted(n['body'] for n in rebuilt['notes']) == ['A', 'untouched'] and rebuilt['through'] == 4
            (case/'before-reopen.json').write_text(json.dumps(surviving))
            (case/'after-reopen.json').write_text(json.dumps(final))
            results.append({'profile': profile, 'schedule': schedule, 'roots': roots, 'outcome': outcome})
            (artifacts/'results.json').write_text(json.dumps(results, indent=2))
            print('PASS:', case.name, flush=True)
    assert len(results) == 6
    print('PASS: six delayed-parent/commit/restart schedules, both profiles', flush=True)


if __name__ == '__main__':
    main()
