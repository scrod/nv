#!/usr/bin/env python3
"""Real repository transport, fresh bootstrap and interrupted receive with independent observations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--probe-env', action='append', default=[])
    parser.add_argument('--ssh-target')
    parser.add_argument('--ssh-key', type=Path)
    args = parser.parse_args()
    environment = os.environ.copy()
    for setting in args.probe_env:
        assert re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', setting)
        name, contents = setting.split('=', 1); environment[name] = contents
    assert bool(args.ssh_target) == bool(args.ssh_key)
    binary = args.binary.absolute() if args.ssh_target else args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-repository-exchange-', dir='/tmp' if args.ssh_target else None))
    print('Artifacts:', artifacts, flush=True)
    results = []
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=60',
           '-o', f'ControlPath={artifacts}/ssh-control']

    def transport(command):
        subprocess.run(command, capture_output=True, check=True, timeout=120)

    def mirror(repository, receiving=False):
        transport([*ssh, args.ssh_target, shlex.join(['mkdir', '-p', str(repository)])])
        local, remote = str(repository)+'/', f'{args.ssh_target}:{repository}/'
        transport(['rsync', '-a', '-e', shlex.join(ssh),
                   remote if receiving else local, local if receiving else remote])

    def probe(*words, code=0):
        command = [str(binary), *map(str, words)]
        if args.ssh_target:
            parent = Path(words[1]) if words[0] == 'seed-pair' else Path(words[1]).parent
            transport([*ssh, args.ssh_target, shlex.join(['mkdir', '-p', str(parent)])])
            for word in words:
                path = Path(str(word))
                if path.is_file() and path.is_relative_to(artifacts):
                    transport(['scp', *ssh[1:], str(path), f'{args.ssh_target}:{path}'])
            if words[0] in ['exchange-publish', 'exchange-discover', 'exchange-bootstrap']:
                mirror(Path(words[3]))
            command = [*ssh, args.ssh_target, shlex.join(['env', *args.probe_env, str(binary), *map(str, words)])]
        run = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=120)
        assert run.returncode == code, (words, run.returncode, run.stderr)
        result = json.loads(run.stdout) if run.stdout.strip() else None
        if args.ssh_target and code == 0:
            if words[0] == 'create': Path(words[3]).write_text(json.dumps(result))
            if words[0] == 'exchange-publish': mirror(Path(words[3]), receiving=True)
        return result

    def inspect(directory, selection):
        state = probe('inspect', directory, selection)
        assert state['integrity'] == [['ok']] and state['foreign_keys'] == [], state
        for row in state['objects']:
            assert hashlib.sha256(bytes.fromhex(row[4])).hexdigest() == row[0].lower(), row[0]
        return state

    def locator(row):
        encoded = bytes.fromhex(row[4])
        assert encoded[:8] == b'NVSEG1\r\n'
        assert encoded[48:64].hex() == row[2].lower() and encoded[64:72].hex() == row[3].lower()
        return encoded[48:72] + hashlib.sha256(encoded).digest()

    def object_path(row):
        loc = locator(row)
        return Path(f'NV Data/v1/segments/{loc[:16].hex()}/{int.from_bytes(loc[16:24], "big"):020d}-{loc[24:].hex()}.nvseg')

    def deliver(source, target, relative):
        destination = target/relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source/relative, destination)

    def independent(state):
        run = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(state),
                             capture_output=True, text=True, check=True, timeout=60)
        return json.loads(run.stdout)

    for profile in ['public', 'encrypted']:
        # Source and receiver receive independent physical directories and local identities.
        case = artifacts/(profile+'-bootstrap'); case.mkdir()
        selected = case/'source.json'
        selection = probe('create', case/'source', profile, selected)
        baseline = inspect(case/'source', selected)
        initial_root = next(row for row in baseline['objects'] if row[1] == '2')
        probe('apply', case/'source', selected, 'put', 1, 'file-exchange-edit')
        probe('apply', case/'source', selected, 'delete', 2, '')
        source = inspect(case/'source', selected)
        assert len(source['actions']) == 4
        source_repo = case/'source-repo'; source_repo.mkdir()
        published = probe('exchange-publish', case/'source', selected, source_repo)
        assert len(published['paths']) == len(source['objects'])
        for row in source['objects']:
            if row[1] != '0':
                assert (source_repo/object_path(row)).read_bytes() == bytes.fromhex(row[4])
        receiver_repo = case/'receiver-repo'; receiver_repo.mkdir()
        receiver_selection = case/'receiver.json'
        receiver_selection.write_text(json.dumps(dict(selection, store=list(range(16)))))
        descriptor_path = next(Path(p) for p in published['paths'] if p.endswith('.nvkey'))
        deliver(source_repo, receiver_repo, descriptor_path)
        deliver(source_repo, receiver_repo, object_path(initial_root))
        # Retained selected root without its closure remains explicitly incomplete across exec.
        probe('exchange-bootstrap', case/'receiver', receiver_selection, receiver_repo, locator(initial_root).hex(), 'create', code=2)
        incomplete = inspect(case/'receiver', receiver_selection)
        assert incomplete['actions'] == [] and incomplete['cells'] == []
        assert len(incomplete['view']) == 1 and incomplete['view'][0][1] == '0'
        probe('dump', case/'receiver', receiver_selection, code=2)
        assert any(r[0] == initial_root[0] and r[4] == initial_root[4] and r[5] == '' for r in incomplete['objects'])
        for relative in reversed(published['paths']):
            deliver(source_repo, receiver_repo, relative)
        complete = probe('exchange-bootstrap', case/'receiver', receiver_selection, receiver_repo, locator(initial_root).hex(), 'resume')
        fresh = probe('dump', case/'receiver', receiver_selection)
        expected = probe('dump', case/'source', selected)
        assert (fresh['through'], fresh['notes'], fresh['context']) == (expected['through'], expected['notes'], expected['context'])
        assert complete['notes'] == fresh['notes'] and complete['context'] == fresh['context']
        assert [n['body'] for n in fresh['notes']] == ['file-exchange-edit']
        receiver = inspect(case/'receiver', receiver_selection)
        assert receiver['actions'] == source['actions'] and receiver['operations'] == source['operations']
        assert {r[0]: r[:5] for r in receiver['objects']} == {r[0]: r[:5] for r in source['objects']}
        oracle = independent(receiver)
        assert oracle, 'Independent history decoder must inspect the complete admitted closure'
        republished = probe('exchange-publish', case/'receiver', receiver_selection, receiver_repo)
        assert set(republished['paths']) == set(published['paths'])
        if profile == 'encrypted':
            assert all(b'file-exchange-edit' not in p.read_bytes() for p in receiver_repo.rglob('*') if p.is_file())
        (case/'source-inspection.json').write_text(json.dumps(source))
        (case/'receiver-inspection.json').write_text(json.dumps(receiver))
        results.append({'profile': profile, 'schedule': 'bootstrap-and-tail', 'objects': len(receiver['objects'])})
        print('PASS:', case.name, flush=True)

        for schedule, fault in [
            ('before-retention-commit', (4, 1, -1, 'retention')),
            ('after-retention-commit', (5, 1, -1, 'retention')),
            ('after-acceptance-before-callback', (5, 1, -1, 'acceptance')),
            ('during-materialization-and-recovery', (7, 1, -1, 'materialization')),
            ('acceptance-sync-error', (2, 1, 1034, 'acceptance')),
        ]:
            case = artifacts/(profile+'-'+schedule); case.mkdir()
            pair = probe('seed-pair', case, profile, 'A')
            selections = {}
            for side in ['left', 'right']:
                selections[side] = case/(side+'.json'); selections[side].write_text(pair[side])
            repository = case/'repository'; repository.mkdir()
            # An early empty pass is followed by ordinary foreground discovery, with no hint.
            empty = probe('exchange-discover', case/'right', selections['right'], repository)
            assert sorted(n['body'] for n in empty['notes']) == ['A', 'untouched']
            probe('apply', case/'left', selections['left'], 'put', 1, 'crash-safe incoming')
            source = inspect(case/'left', selections['left'])
            candidate = next(r for r in source['objects'] if r[5] == '2')
            relative = object_path(candidate)
            destination = repository/relative; destination.parent.mkdir(parents=True); destination.write_bytes(bytes.fromhex(candidate[4]))
            failure = probe('exchange-discover', case/'right', selections['right'], repository, *fault,
                            code=2 if schedule == 'acceptance-sync-error' else 86)
            if schedule == 'acceptance-sync-error':
                assert failure['status'] == 'failed' and failure['error'] == 'database(1034)' and failure['hits'] > 0, failure
            surviving = inspect(case/'right', selections['right'])
            row = next((r for r in surviving['objects'] if r[0] == candidate[0]), None)
            if schedule == 'before-retention-commit':
                assert row is None
            else:
                assert row and row[:5] == candidate[:5]
                if schedule == 'after-retention-commit': assert row[5] == '' and [row[0]] in surviving['ready']
                if schedule in ['after-acceptance-before-callback', 'during-materialization-and-recovery']: assert row[5] == '2'
            if schedule == 'during-materialization-and-recovery':
                probe('open-crash', case/'right', selections['right'], 7, 1, -1, 'materialization', code=86)
                second = inspect(case/'right', selections['right'])
                assert second['objects'] == surviving['objects'] and second['actions'] == surviving['actions']
            final = probe('exchange-discover', case/'right', selections['right'], repository)
            assert sorted(n['body'] for n in final['notes']) == ['crash-safe incoming', 'untouched']
            fresh = probe('dump', case/'right', selections['right'])
            expected = probe('dump', case/'left', selections['left'])
            assert fresh['notes'] == expected['notes'] and fresh['context'] == expected['context'] and fresh['through'] == 2
            recovered = inspect(case/'right', selections['right'])
            assert recovered['actions'] == source['actions'] and recovered['operations'] == source['operations']
            assert {r[0]: r[:5] for r in recovered['objects']} == {r[0]: r[:5] for r in source['objects']}
            assert recovered['ready'] == [] and recovered['waiting'] == [] and recovered['rejected'] == []
            assert destination.read_bytes() == bytes.fromhex(candidate[4])
            independent(recovered)
            (case/'interrupted-inspection.json').write_text(json.dumps(surviving))
            (case/'recovered-inspection.json').write_text(json.dumps(recovered))
            results.append({'profile': profile, 'schedule': schedule, 'objects': len(recovered['objects'])})
            print('PASS:', case.name, flush=True)
        (artifacts/'results.json').write_text(json.dumps(results, indent=2))
    assert len(results) == 12
    print('PASS: 12 fresh-process actual-file bootstrap, receive and recovery schedules', flush=True)


if __name__ == '__main__':
    main()
