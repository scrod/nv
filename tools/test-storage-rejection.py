#!/usr/bin/env python3
"""Exercise rejection transactions through real SQLCipher I/O and fresh openers."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-rejection-'))
    print('Artifacts:', artifacts, flush=True)
    results = []

    def call(command, *arguments, code=0, error=None):
        run = subprocess.run([str(args.binary.resolve()), command, *map(str, arguments)],
                             text=True, capture_output=True, timeout=45)
        assert run.returncode == code, (command, run.returncode, run.stdout, run.stderr)
        if error is not None:
            assert run.stderr.strip() == 'probe failed: ' + error, run.stderr
        return json.loads(run.stdout) if run.stdout.strip() else None

    for profile in ['public', 'encrypted']:
        schedules = [('before-reason', 9, -1, False), ('after-reason', 10, -1, False),
                     ('before-commit', 4, -1, False), ('after-commit', 5, -1, True),
                     ('write-eio', 1, 10, False), ('write-full', 1, 13, False),
                     ('sync-eio', 2, 1034, None), ('sync-result-lost', 8, 1034, None)]
        for name, event, fault, committed in schedules:
            case = artifacts / f'{profile}-{name}'
            case.mkdir()
            directory, selection, candidate = case/'private', case/'selection.json', case/'candidate.bin'
            selection.write_text(json.dumps(call('create', directory, profile)))
            before = call('inspect', directory, selection)
            count = 3 if fault >= 0 and event != 8 else 1
            failed = call('reject-fault', directory, selection, candidate, event, fault, count,
                          code=86 if fault < 0 else 0)
            if failed:
                assert failed['failures'] == [f'database({fault})'] * count, failed
            # Inspect surviving SQL state before allowing the production opener to drain it.
            during = call('inspect', directory, selection)
            (case/'before-recovery.json').write_text(json.dumps(during))
            identifier = hashlib.sha256(candidate.read_bytes()).hexdigest().upper()
            rejected = during['rejected'] == [[identifier, '1', '20']]
            retryable = during['ready'] == [[identifier]] and during['rejected'] == []
            assert rejected != retryable, during
            assert (during['ready'] == []) if rejected else retryable
            if committed is not None:
                assert rejected == committed, (name, during)
            envelope = next(o for o in during['objects'] if o[0] == identifier)
            assert bytes.fromhex(envelope[4]) == candidate.read_bytes() and envelope[5] == '', envelope
            for key in ['operations', 'actions', 'members', 'operation_occurrences', 'action_occurrences',
                        'dependencies', 'parents', 'predecessors', 'frontier', 'descriptors', 'private', 'cells', 'view']:
                assert during[key] == before[key], (name, key)
            assert during['integrity'] == [['ok']] and during['foreign_keys'] == []
            # The fresh opener receives only surviving storage and selection/unlock inputs.
            opened = call('dump', directory, selection)
            assert sorted(n['body'] for n in opened['notes']) == ['A', 'untouched'] and opened['through'] == 1
            settled = call('inspect', directory, selection)
            assert settled['ready'] == [] and settled['rejected'] == [[identifier, '1', '20']]
            call('receive-file', directory, selection, candidate, code=2, error='truncated')
            # An independently authored valid incoming object must progress after recovery.
            peer = case/'peer'
            peer_selection = case/'peer-selection.json'
            peer_selection.write_text(selection.read_text())
            # Same bootstrap bytes, independently owned private directory.
            shutil.copytree(directory, peer)
            saved = call('apply', peer, peer_selection, 'put', 1, 'unrelated incoming')
            incoming = case/'incoming.bin'
            incoming.write_bytes(bytes.fromhex(saved['envelope']))
            if name == 'before-reason':
                paused = case/'paused-receiver'
                shutil.copytree(directory, paused)
                call('receive-file', paused, selection, incoming, 5, 1, -1, code=86)
                waiting = call('inspect', paused, selection)
                incoming_id = hashlib.sha256(incoming.read_bytes()).hexdigest().upper()
                assert waiting['ready'] == [[incoming_id]]
                assert waiting['operations'] == settled['operations']
                resumed = call('dump', paused, selection)
                assert resumed['through'] == 2
                assert sorted(n['body'] for n in resumed['notes']) == ['unrelated incoming', 'untouched']
                repeated = call('dump', paused, selection)
                assert {k: v for k, v in repeated.items() if k != 'steps'} == {k: v for k, v in resumed.items() if k != 'steps'}
                results.append({'profile': profile, 'schedule': 'retained-ready-crash', 'sequence': 2})
            assert call('receive-file', directory, selection, incoming)['status'] == 'accepted'
            final = call('dump', directory, selection)
            assert sorted(n['body'] for n in final['notes']) == ['unrelated incoming', 'untouched'] and final['through'] == 2
            report = call('inspect', directory, selection)
            (case/'inspection.json').write_text(json.dumps(report))
            # The independent history oracle sees only accepted objects; rejected bytes were checked above.
            accepted = dict(report)
            accepted['objects'] = [o for o in report['objects'] if o[1] == '0' or o[5] != '']
            check = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')],
                                   input=json.dumps(accepted), text=True, capture_output=True, timeout=45)
            assert check.returncode == 0, check.stderr
            results.append({'profile': profile, 'schedule': name, 'rejected_before_reopen': rejected,
                            'failures': failed, 'independent': json.loads(check.stdout)})
            print('PASS:', case.name, flush=True)
    (artifacts/'results.json').write_text(json.dumps(results, indent=2))
    print('PASS:', len(results), 'rejection schedules', flush=True)


if __name__ == '__main__':
    main()
