#!/usr/bin/env python3
"""Independent fresh-process bootstrap and atomic snapshot reconstruction failure schedules."""
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
    parser.add_argument('--ssh-target', help='Run children on a user-owned test host and inspect returned history locally.')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--remote-env', action='append', default=[])
    parser.add_argument('--artifact-parent', type=Path, help='Existing parent available locally and on the remote host.')
    args = parser.parse_args()
    assert bool(args.ssh_target) == bool(args.ssh_key), 'Remote execution requires its target and SSH key'
    assert all(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', value) for value in args.remote_env)
    binary = args.binary.absolute() if args.ssh_target else args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-s34-process-', dir=args.artifact_parent or ('/tmp' if args.ssh_target else None)))
    print('Artifacts:', artifacts, flush=True)
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=60',
           '-o', f'ControlPath={artifacts}/ssh-control']
    uploaded = set()

    def remote(command, **kwargs):
        return subprocess.run([*ssh, args.ssh_target, shlex.join(command)], **kwargs)

    def probe(*command):
        if not args.ssh_target:
            return subprocess.run([str(binary), *map(str, command)], capture_output=True, text=True, timeout=180)
        for argument in map(str, command):
            source = Path(argument)
            if source.is_file() and source.is_relative_to(artifacts) and argument not in uploaded:
                subprocess.run(['scp', *ssh[1:], str(source), f'{args.ssh_target}:{source}'], capture_output=True, check=True, timeout=30)
                uploaded.add(argument)
        return remote(['env', *args.remote_env, str(binary), *map(str, command)], capture_output=True, text=True, timeout=180)

    def make_case(case):
        case.mkdir()
        if args.ssh_target:
            remote(['mkdir', '-p', str(case)], capture_output=True, check=True, timeout=30)

    def read_bytes(path):
        if not args.ssh_target:
            return path.read_bytes()
        return remote(['cat', str(path)], capture_output=True, check=True, timeout=30).stdout

    def encrypted_header(directory):
        path = directory/'Collection.sqlite'
        if not args.ssh_target:
            return path.open('rb').read(16)
        run = remote(['python3', '-c', 'import pathlib,sys; print(pathlib.Path(sys.argv[1]).open("rb").read(16).hex())', str(path)],
                     capture_output=True, text=True, check=True, timeout=30)
        return bytes.fromhex(run.stdout.strip())

    results = []
    for profile in ['public', 'encrypted']:
        # Faults target real acceptance and derived transactions, separately from input retention.
        for fault in [None, (4, 1, -1), (5, 1, -1), (7, 1, -1), (6, 1, -1), (5, 2, -1)]:
            case = artifacts / f'bootstrap-{profile}-{fault}'
            make_case(case)
            directory, selection, inputs = case/'private', case/'selection.json', case/'input'

            def call(command, *extra, code=0):
                run = probe(command, directory, selection, *extra)
                assert run.returncode == code, (command, fault, run.returncode, run.stderr)
                return json.loads(run.stdout) if run.stdout.strip() else None

            seeded = probe('bootstrap-seed', directory, profile, selection, inputs, '64')
            assert seeded.returncode == 0, seeded.stderr
            # Neither a root by itself nor an incomplete import issues a session.
            manifest = json.loads(read_bytes(inputs/'manifest.json'))
            call('bootstrap-retain', inputs, manifest['objects'][manifest['root']])
            call('bootstrap-complete', inputs, code=2)
            assert call('inspect')['operations'] == []
            call('bootstrap-retain', inputs)
            phase = ('acceptance',) if fault and fault[0] in [4, 5] else ()
            if fault == (5, 2, -1):
                call('bootstrap-complete', inputs, 5, 1, -1, 'materialization', code=86)
            else:
                call('bootstrap-complete', inputs, *(fault or ()), *phase, code=86 if fault else 0)
            surviving = call('inspect')
            committed = fault is None or fault[0] != 4
            assert len(surviving['operations']) == (66 if committed else 0), surviving['operations']
            assert len(surviving['actions']) == (22 if committed else 0), surviving['actions']
            # Fail a second recovery after losing the first acceptance completion.
            if fault == (5, 1, -1):
                call('open-crash', 7, 1, -1, code=86)
            call('bootstrap-complete', inputs)
            actual, report = call('dump'), call('inspect')
            assert sorted(n['body'] for n in actual['notes']) == sorted(f'initial-{n}' for n in range(64))
            assert actual['through'] == 1 and len(report['operations']) == 66
            inspected = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(report),
                                       capture_output=True, text=True, timeout=180)
            assert inspected.returncode == 0, inspected.stderr
            checked = json.loads(inspected.stdout)
            assert checked['operations'] == 66 and checked['actions'] == 22, checked
            for row in surviving['objects']:
                assert any(later[:5] == row[:5] for later in report['objects']), (row, report['objects'])
            assert encrypted_header(directory) != b'SQLite format 3\x00'
            results.append({'case': case.name, 'fault': fault, 'independent': checked})
            (artifacts/'results.json').write_text(json.dumps(results, indent=2))
            print('PASS:', case.name, flush=True)
        for fault in [None, (4, 1, -1), (5, 1, -1), (7, 1, -1), (6, 1, -1), (1, 1, 13), (2, 1, 1034)]:
            case = artifacts / f'reconstruction-{profile}-{fault}'
            make_case(case)
            directory, selection = case/'private', case/'selection.json'

            def call(command, *extra, code=0):
                run = probe(command, directory, selection, *extra)
                assert run.returncode == code, (command, fault, run.returncode, run.stderr)
                return json.loads(run.stdout) if run.stdout.strip() else None

            created = probe('create', directory, profile)
            assert created.returncode == 0, created.stderr
            selection.write_text(created.stdout)
            call('snapshot-save')
            call('edit')
            before, initial = call('dump'), call('inspect')
            call('invalidate-view')
            private = call('inspect')['private']
            if fault:
                phase = ('materialization',) if fault[0] in [1, 2, 4, 5] else ()
                call('open-crash', *fault, *phase, code=86 if fault[2] == -1 else 2)
                if fault == (7, 1, -1):
                    call('open-crash', 6, 1, -1, code=86)
            actual, report = call('dump'), call('inspect')
            assert sorted(n['body'] for n in actual['notes']) == ['edited', 'untouched']
            assert actual['context'] == before['context'] and actual['through'] == before['through']
            for table in ['objects', 'operations', 'actions', 'members', 'parents', 'predecessors', 'frontier', 'dependencies', 'descriptors']:
                assert report[table] == initial[table], (fault, table)
            assert report['private'] == private, (fault, report['private'], private)
            assert report['view'][0][0] != initial['view'][0][0], 'A replacement issues a fresh view epoch'
            assert report['cells'] == initial['cells']
            # The recovered context must author a real follow-on change, not merely render text.
            call('apply', 'put', 2, 'after-reconstruction')
            assert sorted(n['body'] for n in call('dump')['notes']) == ['after-reconstruction', 'edited']
            results.append({'case': case.name, 'fault': fault, 'history_preserved': True, 'private_preserved': True})
            (artifacts/'results.json').write_text(json.dumps(results, indent=2))
            print('PASS:', case.name, flush=True)
    assert len(results) == 26
    (artifacts/'results.json').write_text(json.dumps(results, indent=2))
    print('PASS: 26 fresh-process S3/S4 scenarios, both encrypted private-store profiles', flush=True)


if __name__ == '__main__':
    main()
