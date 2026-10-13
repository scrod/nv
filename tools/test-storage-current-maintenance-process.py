#!/usr/bin/env python3
"""Fresh-process compression/compaction faults with independent history and private-cut observations."""
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
    parser.add_argument('--ssh-target', help='Run children remotely with independent local history inspection.')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--remote-env', action='append', default=[])
    args = parser.parse_args()
    assert bool(args.ssh_target) == bool(args.ssh_key)
    assert all(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', value) for value in args.remote_env)
    binary = args.binary.absolute() if args.ssh_target else args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-current-maintenance-', dir='/tmp' if args.ssh_target else None))
    print('Artifacts:', artifacts, flush=True)
    results = []
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

    def encrypted_header(directory):
        path = directory / 'Collection.sqlite'
        if not args.ssh_target:
            return path.open('rb').read(16)
        result = remote(['python3', '-c', 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).open("rb").read(16).hex())', str(path)],
                        capture_output=True, text=True, check=True, timeout=30)
        return bytes.fromhex(result.stdout.strip())

    def call(command, directory, selection, *extra, code=0):
        run = probe(command, directory, selection, *extra)
        assert run.returncode == code, (command, code, run.returncode, run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else None

    def create(profile, name):
        case = artifacts / f'{profile}-{name}'; case.mkdir()
        if args.ssh_target:
            remote(['mkdir', '-p', str(case)], capture_output=True, check=True, timeout=30)
        directory, selection = case / 'private', case / 'selection.json'
        selection.write_text(json.dumps(call('current-seed', directory, profile)))
        call('private-seed', directory, selection)
        call('private-latest', directory, selection)
        return directory, selection

    def verify(directory, selection, before, changed=False):
        opened = call('dump', directory, selection)
        expected = ['\n'.join(f'Synthetic paragraph {p}: durable history, private storage, user actions and Unicode café 日本語; note {n}.'
                              for p in range(40)) for n in range(1, 33)]
        if changed: expected[0] = 'F after held VACUUM'
        assert sorted(n['body'] for n in opened['notes']) == sorted(expected)
        after = call('inspect', directory, selection)
        for table in ['private', 'descriptors', 'waiting', 'ready']:
            assert before[table] == after[table], table
        if not changed:
            for table in ['objects', 'operations', 'actions', 'members', 'operation_occurrences', 'action_occurrences',
                          'parents', 'predecessors', 'frontier', 'dependencies', 'view']:
                assert before[table] == after[table], table
        oracle = subprocess.run(['node', str(ROOT / 'tools/inspect-storage-history.mjs')], input=json.dumps(after),
                                text=True, capture_output=True, timeout=60)
        assert oracle.returncode == 0, oracle.stderr
        assert json.loads(oracle.stdout)['verified'] is True
        private = call('private-dump', directory, selection)
        assert private['latest'] == 'latest B' and private['reservations'][0]['status'] == 'review'
        assert len(private['payloads']) == 2
        assert encrypted_header(directory) != b'SQLite format 3\0'
        return after

    for profile in ['public', 'encrypted']:
        for name, event, ordinal, result, committed in [
            ('before-commit', 4, 1, -1, False), ('after-commit', 5, 1, -1, True),
            ('enospc', 1, 1, 13, False), ('eio', 2, 1, 1034, False),
        ]:
            directory, selection = create(profile, 'recode-' + name)
            before = call('inspect', directory, selection)
            outcome = call('current-recode', directory, selection, event, ordinal, result, code=86 if result == -1 else 0)
            if outcome: assert not outcome['recoded'] and outcome['hits'] == 1
            cut = call('inspect', directory, selection)
            assert bool(cut['dictionaries']) == committed
            assert (cut['cells'] != before['cells']) == committed
            verify(directory, selection, before)
            results.append({'profile': profile, 'scenario': 'recode-' + name, 'committed': committed})
            print('PASS:', profile, 'recode-' + name, flush=True)
        for name, event, result in [('normal', 0, 0), ('write-crash', 1, -1), ('sync-crash', 2, -1),
                                    ('enospc', 1, 13), ('eio', 2, 1034)]:
            directory, selection = create(profile, 'vacuum-' + name)
            assert call('current-recode', directory, selection)['recoded']
            before = call('inspect', directory, selection)
            outcome = call('current-vacuum', directory, selection, event, 1, result, code=86 if result == -1 else 0)
            if event and result != -1: assert outcome['vacuum'] == 'failed' and outcome['hits'] == 1
            if not event: assert outcome['vacuum'] == 'completed'
            after = verify(directory, selection, before)
            assert after['cells'] == before['cells'] and after['dictionaries'] == before['dictionaries']
            results.append({'profile': profile, 'scenario': 'vacuum-' + name})
            print('PASS:', profile, 'vacuum-' + name, flush=True)
        for ordinal in [1, 8, 32]:
            directory, selection = create(profile, f'vacuum-held-{ordinal}')
            before = call('inspect', directory, selection)
            outcome = call('current-vacuum-held-save', directory, selection, ordinal)
            # A held final WAL write can be past SQLite's interruption point. Both
            # settled results must precede the independent requested-save barrier.
            assert outcome['vacuum'] in ['interrupted', 'completed'] and outcome['hits'] == ordinal, outcome
            verify(directory, selection, before, changed=True)
            results.append({'profile': profile, 'scenario': f'vacuum-held-{ordinal}', **outcome})
            print('PASS:', profile, f'vacuum-held-{ordinal}', 'barrier ms', outcome['barrierNanoseconds'] / 1e6, flush=True)
    assert len(results) == 24
    (artifacts / 'results.json').write_text(json.dumps(results, indent=2))
    print('PASS: 24 independently checked fresh-process compression and VACUUM schedules', flush=True)


if __name__ == '__main__':
    main()
