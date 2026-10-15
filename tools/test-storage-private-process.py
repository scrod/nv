#!/usr/bin/env python3
"""Fresh-process pending/backup/repair recovery with independent SQL and exact-byte observations."""
import argparse
import base64
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
    parser.add_argument('--ssh-target', help='Run real children remotely with independent local history inspection.')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--remote-env', action='append', default=[])
    parser.add_argument('--only', help='Run schedule names containing this substring.')
    args = parser.parse_args()
    assert bool(args.ssh_target) == bool(args.ssh_key)
    assert all(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', value) for value in args.remote_env)
    binary = args.binary.absolute() if args.ssh_target else args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-private-process-', dir='/tmp' if args.ssh_target else None))
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

    def make_directory(path):
        path.mkdir()
        if args.ssh_target:
            remote(['mkdir', '-p', str(path)], capture_output=True, check=True, timeout=30)

    def read_bytes(path):
        if not args.ssh_target:
            return path.read_bytes()
        return remote(['cat', str(path)], capture_output=True, check=True, timeout=30).stdout

    def exists(path):
        if not args.ssh_target:
            return path.exists()
        result = remote(['test', '-e', str(path)], capture_output=True, timeout=30)
        assert result.returncode in [0, 1], result.stderr
        return result.returncode == 0

    completed = []
    for profile in ['public', 'encrypted']:
        schedules = [('latest-before', 'latest', (4, 1, -1)), ('latest-after', 'latest', (5, 1, -1)),
                     ('latest-enospc', 'latest', (1, 1, 13)), ('latest-eio', 'latest', (2, 1, 1034)),
                     ('settlement-before', 'settlement', (4, 1, -1)), ('settlement-after', 'settlement', (5, 1, -1)),
                     ('settlement-enospc', 'settlement', (1, 1, 13)), ('settlement-eio', 'settlement', (2, 1, 1034)),
                     ('backup', 'backup', None), ('backup-enospc', 'backup-fault', (1, 1, 13)),
                     ('backup-eio', 'backup-fault', (2, 1, 1034)), ('repair-private-before', 'repair-fault', 'private-before'),
                     ('repair-private-after', 'repair-fault', 'private-after'), ('repair-private-enospc', 'repair-fault', 'private-enospc'),
                     ('repair-private-eio', 'repair-fault', 'private-eio'), ('connected-repair', 'repair', 'normal'),
                     ('repair-verified', 'repair', 'verified'),
                     ('repair-activated', 'repair', 'activated'), ('repair-closed', 'repair', 'closed'), ('repair', 'repair', 'normal'),
                     ('integrated-private-before', 'integrated-repair-fault', 'private-before'),
                     ('integrated-private-after', 'integrated-repair-fault', 'private-after'),
                     ('integrated-private-enospc', 'integrated-repair-fault', 'private-enospc'),
                     ('integrated-private-eio', 'integrated-repair-fault', 'private-eio'),
                     ('integrated-repair', 'integrated-repair', 'normal'),
                     ('integrated-activated', 'integrated-repair', 'activated')]
        for name, kind, fault in schedules:
            if args.only and args.only not in name:
                continue
            case = artifacts/(profile + '-' + name)
            make_directory(case)
            directory, selection = case/'private', case/'selection.json'
            created = probe('create', directory, profile)
            assert created.returncode == 0, created.stderr
            selection.write_text(created.stdout)

            def invoke(command, *extra, code=0, source=directory, inputs=selection):
                result = probe(command, source, inputs, *extra)
                assert result.returncode == code, (name, command, result.returncode, result.stderr)
                return json.loads(result.stdout) if result.stdout.strip() else None

            seed = invoke('private-seed')
            before = invoke('private-dump')
            if kind == 'latest':
                for _ in range(2):
                    killed = fault[2] == -1
                    result = invoke('private-latest', *fault, code=86 if killed else 0)
                    if not killed:
                        assert result['retained'] is False and result['hits'] == 1, result
                    actual = invoke('private-dump')
                    assert actual['latest'] in ['frozen A', 'latest B'] and actual['settings'] == before['settings'], actual
                    assert len(actual['reservations']) == 1 and actual['reservations'][0]['status'] == 'review', actual
                    assert any(row[0].lower() == seed['snapshot'] for row in actual['payloads']), actual
                    if name == 'latest-before': assert actual['latest'] == 'frozen A', actual
                    if name == 'latest-after': assert actual['latest'] == 'latest B', actual
                invoke('private-latest')
                assert invoke('private-dump')['latest'] == 'latest B'
            elif kind == 'settlement':
                invoke('private-import', 5, 1, -1, code=86)
                imported = invoke('private-dump')
                assert imported['reservations'][0]['status'] == 'committed', imported
                assert imported['reservations'][0]['birth'] == seed['birth'], imported
                invoke('private-latest')
                invoke('private-delete')
                killed = fault[2] == -1
                result = invoke('private-settle', *fault, code=86 if killed else 0)
                if not killed: assert result['settled'] is False and result['hits'] == 1, result
                actual = invoke('private-dump')
                assert sorted(n['body'] for n in actual['notes']) == ['A', 'untouched'], actual
                assert actual['latest'] == 'latest B', actual
                if actual['reservations']:
                    # Fail another attempt without another delivery; then recover the exact same committed Import.
                    invoke('private-settle', 4, 1, -1, code=86)
                    assert invoke('private-dump')['reservations'][0]['status'] == 'committed'
                    invoke('private-settle')
                settled = invoke('private-dump')
                assert settled['reservations'] == [] and len(settled['settlements']) == 1, settled
                assert settled['settlements'][0][1].lower() == seed['birth'] and settled['settlements'][0][2], settled
                # A crash after settlement and before optional cleanup may retain the now-unreferenced A payload.
                assert settled['latest'] == 'latest B' and 1 <= len(settled['payloads']) <= 2, settled
                assert len(settled['payloads']) == 1 or any(row[0].lower() == seed['snapshot'] for row in settled['payloads']), settled
                inspection = invoke('inspect')
                assert len(inspection['actions']) == 4 and len(inspection['operations']) == 6, inspection
                oracle = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(inspection), capture_output=True, text=True, timeout=120)
                assert oracle.returncode == 0, oracle.stderr
                (case/'independent-history.json').write_text(oracle.stdout)
            else:
                if kind.endswith('repair-fault') or name == 'connected-repair' or kind.startswith('integrated-'):
                    invoke('private-import', 5, 1, -1, code=86)
                    invoke('private-latest')
                    invoke('private-delete')
                invoke('edit')
                expected = invoke('private-dump')
                original = invoke('inspect')
                if kind in ['backup', 'backup-fault']:
                    if kind == 'backup-fault':
                        for attempt in range(2):
                            failed = invoke('private-backup', case/f'failed-backup-{attempt}', *fault)
                            assert failed['copied'] is False and failed['hits'] == 1, failed
                            assert invoke('private-dump') == expected
                        invoke('edit')
                        expected, original = invoke('private-dump'), invoke('inspect')
                    result = invoke('private-backup', case/'backup')
                    copied_selection = case/'backup-selection.json'
                    copied_selection.write_bytes(base64.b64decode(result['selection']))
                    actual = invoke('private-dump', source=case/'backup', inputs=copied_selection)
                    inspect = invoke('inspect', source=case/'backup', inputs=copied_selection)
                else:
                    repair_command = 'private-repair-integrated' if kind.startswith('integrated-') else 'private-repair'
                    repair = case/'repair'
                    make_directory(repair)
                    if kind.endswith('repair-fault'):
                        killed = fault in ['private-before', 'private-after']
                        failed = invoke(repair_command, repair, fault, code=86 if killed else 0)
                        if not killed: assert failed['built'] is False and failed['hits'] == 1, failed
                        assert not exists(repair/'selection.json')
                        selected = read_bytes(repair/'Selected Store')
                        assert selected[26:42] == bytes(json.loads(selection.read_text())['store'])
                        assert invoke('private-dump')['notes'] == expected['notes']
                        retry = case/'repair-second-failure'
                        make_directory(retry)
                        failed = invoke(repair_command, retry, 'private-enospc')
                        assert failed['built'] is False and failed['hits'] == 1, failed
                        assert not exists(retry/'selection.json')
                        repair = case/'repair-success'
                        make_directory(repair)
                        fault = 'normal'
                    invoke(repair_command, repair, fault, code=0 if fault == 'normal' else 86)
                    candidate_selection = repair/'selection.json'
                    candidate = json.loads(read_bytes(candidate_selection))
                    selected = read_bytes(repair/'Selected Store')
                    assert len(selected) == 90
                    expected_store = json.loads(selection.read_text())['store'] if fault == 'verified' else candidate['store']
                    assert selected[26:42] == bytes(expected_store), selected.hex()
                    actual = invoke('private-dump', source=repair/'candidate', inputs=candidate_selection)
                    inspect = invoke('inspect', source=repair/'candidate', inputs=candidate_selection)
                    # Both source and candidate remain ordinarily reopenable after every cut.
                    assert invoke('private-dump')['notes'] == expected['notes']
                assert actual['notes'] == expected['notes'] and actual['settings'] == expected['settings'], actual
                assert actual['latest'] == expected['latest'] and actual['reservations'] == expected['reservations'], actual
                assert actual['payloads'] == expected['payloads'], actual
                assert {tuple(row[:5]) for row in inspect['objects']} == {tuple(row[:5]) for row in original['objects']}, inspect
                assert inspect['integrity'] == [['ok']] and inspect['foreign_keys'] == [], inspect
                oracle = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(inspect), capture_output=True, text=True, timeout=120)
                assert oracle.returncode == 0, oracle.stderr
                (case/'independent-history.json').write_text(oracle.stdout)
            completed.append(profile + '-' + name)
            print('PASS:', completed[-1], flush=True)
            (artifacts/'results.json').write_text(json.dumps(completed, indent=2))
    expected_count = 2 * sum(not args.only or args.only in name for name, _, _ in schedules)
    assert expected_count > 0 and len(completed) == expected_count


if __name__ == '__main__':
    main()
