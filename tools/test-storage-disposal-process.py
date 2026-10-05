#!/usr/bin/env python3
"""Abandoned owners release their leases before orderly exit; fresh reopen verifies each saved value."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def inspect_report(report, body, action_count):
    oracle = subprocess.run(['node', str(Path(__file__).resolve().parent/'inspect-storage-history.mjs')],
                            input=json.dumps(report), capture_output=True, text=True, timeout=120)
    assert oracle.returncode == 0, oracle.stderr
    reduced = json.loads(oracle.stdout)
    assert len(reduced['notes']) == 2 and {row['body'] for row in reduced['notes']} == {body, 'untouched'}, reduced
    assert len(reduced['actionRecords']) == action_count, reduced


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--repetitions', type=int, default=30)
    parser.add_argument('--defer-independent-inspection', action='store_true')
    parser.add_argument('--inspect-artifacts', type=Path)
    args = parser.parse_args()
    if args.inspect_artifacts:
        artifacts = args.inspect_artifacts.resolve()
        manifest = json.loads((artifacts/'inspections.json').read_text())
        assert manifest['repetitions'] > 0
        reports = manifest['reports']
        assert len(reports) == 2 * (manifest['repetitions'] + 7), 'Incomplete exit/reopen inspection inventory'
        assert len({row['file'] for row in reports}) == len(reports)
        for row in reports:
            inspect_report(json.loads((artifacts/row['file']).read_text()), row['body'], row['actions'])
        print('PASS:', len(reports), 'independent disposal/recovery history inspections', flush=True)
        return
    if args.binary is None: parser.error('--binary is required for process execution')
    assert args.repetitions > 0
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-disposal-process-'))
    print('Artifacts:', artifacts, flush=True)
    trace, reports = [], []

    def inspect(inspected, body, action_count):
        name = 'inspection-%03d.json' % len(reports)
        (artifacts/name).write_text(json.dumps(inspected))
        reports.append({'file': name, 'body': body, 'actions': action_count})
        if not args.defer_independent_inspection:
            inspect_report(inspected, body, action_count)

    def run(*command):
        result = subprocess.run([str(binary), *map(str, command)], capture_output=True, text=True, timeout=120)
        trace.append({'command': list(map(str, command)), 'exit': result.returncode,
                      'stdout': result.stdout, 'stderr': result.stderr})
        (artifacts/'trace.json').write_text(json.dumps(trace, indent=2))
        assert result.returncode == 0, trace[-1]
        return json.loads(result.stdout)

    for profile in ['public', 'encrypted']:
        directory, selection = artifacts/profile, artifacts/(profile+'.json')
        run('create', directory, profile, selection)
        # A normally quiesced writer is the valid companion for abandoned-session exits.
        modes = ['quiesce'] + ['abandon'] * args.repetitions
        for index, mode in enumerate(modes):
            body = f'{profile} durable exit {index}'
            args_for_save = ['abandon-session', directory, selection, body]
            if mode == 'quiesce': args_for_save.append('quiesce')
            run(*args_for_save)
            opened = run('dump', directory, selection)
            assert len(opened['notes']) == 2 and {row['body'] for row in opened['notes']} == {body, 'untouched'}, opened
            inspected = run('inspect', directory, selection)
            inspect(inspected, body, index + 3)
        for mode in ['write-error', 'full'] * 3:
            candidate = f'{profile} failed close {len(trace)}'
            result = run('abandon-session', directory, selection, candidate, mode)
            assert result == {'pending': True, 'close': 'busy'}, result
            opened = run('dump', directory, selection)
            assert len(opened['notes']) == 2 and {row['body'] for row in opened['notes']} == {body, 'untouched'}, opened
            inspected = run('inspect', directory, selection)
            inspect(inspected, body, args.repetitions + 3)
        print('PENDING INSPECTION:' if args.defer_independent_inspection else 'PASS:',
              profile, args.repetitions, 'abandoned normal exits and fresh-process recovery', flush=True)
    (artifacts/'inspections.json').write_text(json.dumps({'repetitions': args.repetitions, 'reports': reports}, indent=2))


if __name__ == '__main__':
    main()
