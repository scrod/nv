#!/usr/bin/env python3
"""Fresh-process observation of superseded history damage and repeated diagnosis-write failure."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-storage-review-process-'))
    print('Artifacts:', artifacts, flush=True)
    results = []

    def call(command, directory, selection, *extra, code=0):
        run = subprocess.run([str(binary), command, str(directory), str(selection), *map(str, extra)],
                             capture_output=True, text=True, timeout=60)
        assert run.returncode == code, (command, code, run.returncode, run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else None

    for profile in ['public', 'encrypted']:
        for ordinal in [1, 2]:
            interrupted = artifacts/f'healthy-{profile}-{ordinal}'
            interrupted.mkdir()
            owned, selected = interrupted/'private', interrupted/'selection.json'
            selected.write_text(json.dumps(call('create', owned, profile)))
            saved = call('apply', owned, selected, 'put', 1, 'retained old edit')
            envelope = interrupted/'old.object'
            envelope.write_bytes(bytes.fromhex(saved['envelope']))
            call('apply', owned, selected, 'put', 1, 'latest edit')
            before = call('inspect', owned, selected)
            call('verify-interrupt', owned, selected, envelope, 5, ordinal, -1, code=86)
            pending = [row for row in call('inspect', owned, selected)['private'] if bytes.fromhex(row[0]).startswith(b'verification/')]
            assert len(pending) == (1 if ordinal == 1 else 0), pending
            if ordinal == 1:
                for _ in range(2):
                    assert call('verify-recovery-failure', owned, selected) == {'recovery_write_failed': True}
                    assert [row for row in call('inspect', owned, selected)['private'] if bytes.fromhex(row[0]).startswith(b'verification/')] == pending
            actual, after = call('dump', owned, selected), call('inspect', owned, selected)
            assert sorted(n['body'] for n in actual['notes']) == ['latest edit', 'untouched']
            for table in ['objects', 'operations', 'actions', 'members', 'parents', 'predecessors', 'frontier', 'dependencies', 'descriptors']:
                assert before[table] == after[table], (table, before[table], after[table])
            assert not [row for row in after['private'] if bytes.fromhex(row[0]).startswith(b'verification/')]
            results.append({'profile': profile, 'healthy_interruption': ordinal, 'repeated_recovery_failure': ordinal == 1})
            print('PASS: healthy verification interruption', profile, ordinal, flush=True)
        case = artifacts / profile
        case.mkdir()
        directory, selection = case/'private', case/'selection.json'
        selection.write_text(json.dumps(call('create', directory, profile)))
        old = call('apply', directory, selection, 'put', 1, 'old E')
        old_file = case/'old.object'
        old_file.write_bytes(bytes.fromhex(old['envelope']))
        call('apply', directory, selection, 'put', 1, 'current F')
        healthy = call('dump', directory, selection)
        assert sorted(n['body'] for n in healthy['notes']) == ['current F', 'untouched']
        diagnosed = call('diagnose-old-damage', directory, selection, old_file, code=86)
        assert diagnosed == {'nonfrontier': True, 'live_publication_blocked': True, 'marker_failed': True}
        # The child opener receives selection/unlock inputs, without the diagnosis or expected-note oracle.
        reopened = subprocess.run([str(binary), 'dump', str(directory), str(selection)],
                                  capture_output=True, text=True, timeout=60)
        assert reopened.returncode == 2 and reopened.stderr.strip() == 'probe failed: integrity', reopened.stderr
        outcome = 'resolved: restart conservatively blocked known history damage'
        results.append({'profile': profile, **diagnosed, 'reopen_outcome': outcome})
        print(outcome, profile, flush=True)
    assert len(results) == 6
    (artifacts/'results.json').write_text(json.dumps(results, indent=2))
    print('PASS: 6 fresh-process verification schedules, including repeated real write failures', flush=True)


if __name__ == '__main__':
    main()
