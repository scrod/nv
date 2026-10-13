#!/usr/bin/env python3
"""Exchange real repository files in both directions between independent OS hosts."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local-binary', type=Path, required=True)
    parser.add_argument('--remote-binary', type=Path, required=True)
    parser.add_argument('--ssh-target', required=True)
    parser.add_argument('--ssh-key', type=Path, required=True)
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-cross-host-repository-', dir='/tmp'))
    print('Artifacts:', artifacts, flush=True)
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=60',
           '-o', f'ControlPath={artifacts}/ssh-control']
    trace, results = [], []

    def transfer(command):
        subprocess.run(command, capture_output=True, check=True, timeout=120)

    def remote_command(words):
        return [*ssh, args.ssh_target, shlex.join(list(map(str, words)))]

    def probe(remote, *words, code=0):
        command = [str(args.remote_binary if remote else args.local_binary.resolve()), *map(str, words)]
        if remote:
            transfer(remote_command(['mkdir', '-p', str(Path(words[1]).parent)]))
            for value in words:
                path = Path(str(value))
                if path.is_relative_to(artifacts) and path.is_file():
                    transfer(['scp', *ssh[1:], str(path), f'{args.ssh_target}:{path}'])
            command = remote_command(command)
        run = subprocess.run(command, capture_output=True, text=True, timeout=120)
        trace.append(dict(remote=remote, arguments=list(map(str, words)), code=run.returncode,
                          stdout=run.stdout, stderr=run.stderr))
        (artifacts/'trace.json').write_text(json.dumps(trace, indent=2))
        assert run.returncode == code, trace[-1]
        return json.loads(run.stdout) if run.stdout.strip() else None

    def mirror(repository, receiving=False):
        transfer(remote_command(['mkdir', '-p', str(repository)]))
        local, remote = str(repository)+'/', f'{args.ssh_target}:{repository}/'
        transfer(['rsync', '-a', '-e', shlex.join(ssh),
                  remote if receiving else local, local if receiving else remote])

    def inspect(remote, directory, selection):
        state = probe(remote, 'inspect', directory, selection)
        assert state['integrity'] == [['ok']] and state['foreign_keys'] == []
        for row in state['objects']:
            assert hashlib.sha256(bytes.fromhex(row[4])).hexdigest() == row[0].lower()
        oracle = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')],
                                input=json.dumps(state), capture_output=True, text=True, check=True, timeout=60)
        assert json.loads(oracle.stdout)
        return state

    for profile in ['public', 'encrypted']:
        case = artifacts/profile; case.mkdir()
        source, receiver, repository = case/'source', case/'receiver', case/'repository'
        selected, remote_selected = case/'source.json', case/'receiver.json'
        selection = probe(False, 'create', source, profile, selected)
        assert selection['store'] != list(range(16))
        remote_selected.write_text(json.dumps(dict(selection, store=list(range(16)))))
        probe(False, 'apply', source, selected, 'put', 1, 'cross-host edit')
        probe(False, 'apply', source, selected, 'delete', 2, '')
        baseline = inspect(False, source, selected)
        assert len(baseline['actions']) == 4
        repository.mkdir()
        published = probe(False, 'exchange-publish', source, selected, repository)
        initial_root = next(row for row in baseline['objects'] if row[1] == '2')
        encoded = bytes.fromhex(initial_root[4])
        root_locator = (encoded[48:72] + hashlib.sha256(encoded).digest()).hex()
        root_relative = next(path for path in published['paths'] if path.endswith(initial_root[0].lower()+'.nvseg'))
        partial = case/'partial'; (partial/Path(root_relative).parent).mkdir(parents=True)
        shutil.copyfile(repository/root_relative, partial/root_relative)
        mirror(partial)
        probe(True, 'exchange-bootstrap', receiver, remote_selected, partial, root_locator, 'create', code=2)
        mirror(repository)
        completed = probe(True, 'exchange-bootstrap', receiver, remote_selected, repository, root_locator, 'resume')
        assert [note['body'] for note in completed['notes']] == ['cross-host edit']
        first = inspect(True, receiver, remote_selected)
        assert first['actions'] == baseline['actions'] and first['operations'] == baseline['operations']
        assert {r[0]: r[:5] for r in first['objects']} == {r[0]: r[:5] for r in baseline['objects']}
        fresh = probe(True, 'dump', receiver, remote_selected)
        assert fresh['notes'] == completed['notes'] and fresh['context'] == completed['context']

        probe(True, 'apply', receiver, remote_selected, 'put', 1, 'cross-host return')
        probe(True, 'exchange-publish', receiver, remote_selected, repository)
        mirror(repository, receiving=True)
        returned = probe(False, 'exchange-discover', source, selected, repository)
        assert [note['body'] for note in returned['notes']] == ['cross-host return']
        local = inspect(False, source, selected)
        remote = inspect(True, receiver, remote_selected)
        assert len(local['actions']) == 5 and len(local['operations']) == len(baseline['operations']) + 1
        assert local['actions'] == remote['actions'] and local['operations'] == remote['operations']
        assert {r[0]: r[:5] for r in local['objects']} == {r[0]: r[:5] for r in remote['objects']}
        assert {r[0] for r in baseline['objects']} <= {r[0] for r in local['objects']}
        assert local['ready'] == remote['ready'] == [] and local['waiting'] == remote['waiting'] == []
        fresh_local = probe(False, 'dump', source, selected)
        fresh_remote = probe(True, 'dump', receiver, remote_selected)
        assert fresh_local['notes'] == fresh_remote['notes'] == returned['notes']
        assert fresh_local['context'] == fresh_remote['context'] == returned['context']
        if profile == 'encrypted':
            assert all(b'cross-host' not in path.read_bytes() for path in repository.rglob('*') if path.is_file())
        results.append(dict(profile=profile, objects=len(local['objects']), actions=len(local['actions'])))
        print('PASS:', profile, 'bootstrap, edit/Delete, reverse edit and fresh reopen on both hosts', flush=True)
    assert len(results) == 2
    (artifacts/'results.json').write_text(json.dumps(dict(remote=args.ssh_target, cases=results), indent=2))


if __name__ == '__main__':
    main()
