#!/usr/bin/env python3
"""Fresh-process scoped queries with independent history observations on local or SSH test hosts."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('phase3_process', ROOT/'tools/test-storage-phase3-process.py')
phase3 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phase3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--ssh-target')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--remote-env', action='append', default=[])
    parser.add_argument('--artifact-parent', type=Path)
    args = parser.parse_args()
    assert bool(args.ssh_target) == bool(args.ssh_key)
    assert all(re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', value) for value in args.remote_env)
    artifacts = Path(tempfile.mkdtemp(prefix='nv-scoped-platform-', dir=args.artifact_parent or ('/tmp' if args.ssh_target else None)))
    print('Artifacts:', artifacts, flush=True)
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=60',
           '-o', f'ControlPath={artifacts}/ssh-control']
    binary = args.binary.absolute() if args.ssh_target else args.binary.resolve()

    class Case(phase3.Case):
        def __init__(self, directory, profile, base):
            if args.ssh_target:
                subprocess.run([*ssh, args.ssh_target, shlex.join(['mkdir', '-p', str(directory)])],
                               capture_output=True, check=True, timeout=30)
            super().__init__(binary, directory, profile, base)

        def run_raw(self, command, code=0):
            if not args.ssh_target:
                return super().run_raw(command, code)
            for value in map(str, command):
                source = Path(value)
                if source.is_file() and source.is_relative_to(artifacts):
                    subprocess.run(['scp', *ssh[1:], value, f'{args.ssh_target}:{value}'],
                                   capture_output=True, check=True, timeout=30)
            invocation = ['env', *args.remote_env, str(binary), *map(str, command)]
            run = subprocess.run([*ssh, args.ssh_target, shlex.join(invocation)],
                                 capture_output=True, text=True, timeout=120)
            self.trace.append({'command': invocation, 'exit': run.returncode, 'stdout': run.stdout, 'stderr': run.stderr})
            (self.directory/'trace.json').write_text(json.dumps(self.trace, indent=2))
            assert run.returncode == code, self.trace[-1]
            return json.loads(run.stdout) if run.stdout.strip() else None

    results = []
    for profile in ['public', 'encrypted']:
        c = Case(artifacts/f'{profile}-undo', profile, 'A')
        edit = c.command('left', 'put', body='E')
        assert c.invoke('left', 'candidates')['undo'] == [edit['action']]
        undone = c.command('left', 'undo')
        offered = c.invoke('left', 'candidates')
        assert offered['undo'] == [] and offered['redo'] == [undone['action']], offered
        redone = c.command('left', 'redo')
        assert c.bodies('left')[phase3.N] == 'E'
        assert c.invoke('left', 'candidates')['undo'] == [redone['action']]
        c.second_recovery_cut('left')
        assert c.invoke('left', 'candidates')['undo'] == [redone['action']]
        results.append(c.directory.name)
        print('PASS:', results[-1], flush=True)

        c = Case(artifacts/f'{profile}-native', profile, 'A')
        prior = c.command('left', 'put', body='B')
        later = c.command('left', 'put', body='C')
        native = c.command('left', 'native', steps=[{'body': 'B', 'coverage': [{'action': later['action'], 'complete': True}]}])
        offered = c.invoke('left', 'candidates')
        assert offered['undo'] == [prior['action']] and offered['redo'] == [native['action']], offered
        redone = c.command('left', 'redo')
        assert c.bodies('left')[phase3.N] == 'C'
        c.second_recovery_cut('left')
        assert c.invoke('left', 'candidates')['undo'] == [redone['action']]
        results.append(c.directory.name)
        print('PASS:', results[-1], flush=True)

        c = Case(artifacts/f'{profile}-copies', profile, 'A')
        phase3.copies_lifecycle(c, None)
        _, oracle = c.inspect('left')
        assert set(c.invoke('left', 'conflicts')['dispositions']) == set(oracle['dispositions'])
        results.append(c.directory.name)
        print('PASS:', results[-1], flush=True)
    assert len(results) == 6
    (artifacts/'results.json').write_text(json.dumps({'completed': results, 'schedule_count': len(results),
        'host': args.ssh_target or 'local', 'binary': str(binary),
        'observations': ['exact candidate IDs', 'native coverage', 'current bodies', 'global copied-source IDs',
                         'copy deletion', 'subsequent source edit', 'termination during reconstruction', 'independent envelope/SQL inspection'],
        'unqualified': ['physical power loss', 'provider publication', 'AppKit attribution']}, indent=2))
    print('PASS: six scoped-query process lifecycles, both profiles', flush=True)


if __name__ == '__main__':
    main()
