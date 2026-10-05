#!/usr/bin/env python3
"""Fresh-process and real SQLCipher/VFS checks. Recovery receives selection only."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--defer-independent-inspection', action='store_true',
                        help='retain every SQL/envelope report for inspection on a host with Node Argon2 support')
    args = parser.parse_args()
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-storage-process-'))
    print(f'Artifacts: {artifacts}', flush=True)
    results = []

    def invoke(command, directory, selection, *extra, code=0, error=None):
        run = subprocess.run([str(binary), command, str(directory), str(selection), *map(str, extra)],
                             text=True, capture_output=True, timeout=45)
        assert run.returncode == code, (command, code, run.returncode, run.stderr)
        if error is not None:
            assert run.stderr.strip() == 'probe failed: ' + error, (command, error, run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else None

    def create(name, profile):
        case = artifacts / f'{profile}-{name}'
        case.mkdir()
        directory, selection = case / 'private', case / 'selection.json'
        data = invoke('create', directory, profile)
        selection.write_text(json.dumps(data))
        return directory, selection

    def verify(directory, selection, bodies, seq):
        # Opener receives neither this oracle nor a commit/acknowledgment log.
        state = invoke('dump', directory, selection)
        assert sorted(n['body'] for n in state['notes']) == sorted(bodies), state
        assert state['through'] == seq, state
        report = invoke('inspect', directory, selection)
        report_path = directory.parent / f'inspection-{len(results)}.json'
        report_path.write_text(json.dumps(report))
        independent = 'pending separate inspection'
        if not args.defer_independent_inspection:
            checked = subprocess.run(['node', str(ROOT / 'tools/inspect-storage-history.mjs')],
                                     input=json.dumps(report), text=True, capture_output=True, timeout=45)
            assert checked.returncode == 0, checked.stderr
            independent = json.loads(checked.stdout)
        # Both profiles use encrypted private pages, including plaintext provider mode.
        assert (directory / 'Collection.sqlite').read_bytes()[:16] != b'SQLite format 3\x00'
        results.append({'case': directory.parent.name, 'sequence': seq, 'independent': independent,
                        'inspection': str(report_path.relative_to(artifacts))})
        print('PASS:', directory.parent.name, flush=True)
        return state

    for profile in ['public', 'encrypted']:
        for round in range(4):
            case = artifacts / f'{profile}-cold-start-{round}'
            case.mkdir()
            cold = invoke('cold-batch', case, profile)
            assert cold == {'cold_opens_and_reopens': 16}, cold
            results.append({'case': case.name, **cold})
            print('PASS:', case.name, flush=True)
        for name, event, ordinal, complete, phase in [
            ('creation-before-schema', 4, 1, False, 'retention'), ('creation-header-only', 5, 1, False, 'retention'),
            ('creation-partial-retention', 5, 2, False, 'retention'), ('creation-before-history', 4, 1, False, 'acceptance'),
            ('creation-history-committed', 5, 1, True, 'acceptance'), ('creation-during-view', 7, 1, True, 'retention'),
        ]:
            case = artifacts / f'{profile}-{name}'
            case.mkdir()
            directory, selection = case / 'private', case / 'selection.json'
            invoke('create', directory, profile, selection, event, ordinal, -1, phase, code=86)
            if complete:
                verify(directory, selection, ['A', 'untouched'], 1)
            else:
                invoke('dump', directory, selection, code=2, error='incomplete')
                results.append({'case': case.name, 'incomplete_creation_rejected': True})
                print('PASS:', case.name, flush=True)
        directory, selection = create('ordinary', profile)
        verify(directory, selection, ['A', 'untouched'], 1)
        assert invoke('edit', directory, selection)['initial'] == 'accepted'
        verify(directory, selection, ['edited', 'untouched'], 2)
        assert invoke('delete', directory, selection)['initial'] == 'accepted'
        verify(directory, selection, ['untouched'], 3)
        # Process termination is separate from injected I/O failure and later corruption.
        for name, event, ordinal, committed in [
            ('before-commit', 4, 1, False), ('after-commit-before-callback', 5, 1, True),
            ('during-materialization', 6, 1, True), ('during-current-insert', 7, 1, True),
            ('after-materialization', 5, 2, True),
        ]:
            directory, selection = create(name, profile)
            invoke('edit', directory, selection, event, ordinal, -1, 'acceptance', code=86)
            verify(directory, selection, ['edited' if committed else 'A', 'untouched'], 2 if committed else 1)
        for name, event, result in [('write-full', 1, 13), ('sync-eio', 2, 1034), ('sync-completion-ambiguous', 8, 1034), ('busy', 3, 5)]:
            directory, selection = create(name, profile)
            outcome = invoke('edit', directory, selection, event, 1, result, 'acceptance')
            assert outcome['initial'] == 'pending' and outcome['hits'] == 1, outcome
            assert outcome['error'].startswith('database('), outcome
            verify(directory, selection, ['edited', 'untouched'], 2)
        directory, selection = create('simulated-uncommitted-tail-loss', profile)
        invoke('truncate-wal', directory, selection)
        invoke('edit', directory, selection, 1, 4, -1, 'acceptance', code=86)
        wal = directory / 'Collection.sqlite-wal'
        tail = wal.read_bytes()
        page_size = int.from_bytes(tail[8:12], 'big')
        assert page_size >= 512 and len(tail) >= 32 + 24 + page_size
        # Preserve committed verification admission and discard the interrupted save's tail.
        frame_size = 24 + page_size
        complete_frames = list(range(32, len(tail) - frame_size + 1, frame_size))
        commits = [p + frame_size for p in complete_frames if int.from_bytes(tail[p + 4:p + 8], 'big') != 0]
        committed_end = commits[-1] if commits else 32
        assert committed_end < len(tail) and any(p >= committed_end for p in complete_frames)
        assert all(int.from_bytes(tail[p + 4:p + 8], 'big') == 0 for p in complete_frames if p >= committed_end)
        with wal.open('r+b') as file:
            file.truncate(committed_end)
        verify(directory, selection, ['A', 'untouched'], 1)
        for newer in ['edit', 'delete']:
            directory, selection = create('held-cancel-' + newer, profile)
            held = invoke('held-completion', directory, selection, newer)
            assert held['cancelled_waiter_committed'] and held['newer_pending'] and held['sequence'] == 2
            verify(directory, selection, ['edited', 'untouched'], 2)
        directory, selection = create('owner-loss-during-commit', profile)
        held = invoke('held-owner-loss', directory, selection)
        assert held == {'lost_owner_not_acknowledged': True, 'recovered_exact_commit': True}, held
        verify(directory, selection, ['edited', 'untouched'], 2)
        directory, selection = create('invalid-view-with-accepted-tail', profile)
        invoke('edit', directory, selection, 5, 1, -1, 'acceptance', code=86)
        invoke('tamper', directory, selection, 'cell')
        verify(directory, selection, ['edited', 'untouched'], 2)
        for damage in ['cell', 'view', 'prefix']:
            directory, selection = create('rebuild-' + damage, profile)
            invoke('edit', directory, selection)
            before = invoke('inspect', directory, selection)
            invoke('tamper', directory, selection, damage)
            # Terminate another process inside reconstruction, then retry normally.
            invoke('open-crash', directory, selection, 7, 1, -1, code=86)
            verify(directory, selection, ['edited', 'untouched'], 2)
            after = invoke('inspect', directory, selection)
            assert before['objects'] == after['objects'] and before['private'] == after['private']
        for damage in ['settings', 'bootstrap', 'pin', 'settings-version', 'history-missing', 'history-corrupt']:
            directory, selection = create('required-' + damage, profile)
            invoke('tamper', directory, selection, damage)
            error = 'unsupported' if damage == 'settings-version' else 'integrity' if damage == 'history-corrupt' else 'incomplete'
            invoke('dump', directory, selection, code=2, error=error)
            results.append({'case': directory.parent.name, 'required_state_rejected': True})
            print('PASS:', directory.parent.name, flush=True)
        directory, selection = create('indexed-startup', profile)
        small = invoke('dump', directory, selection)['steps']
        invoke('seed-empty', directory, selection, 160)
        large = verify(directory, selection, ['A', 'untouched'], 161)['steps']
        assert large <= small + 100, (small, large)
        results[-1]['startup_vm_steps'] = [small, large]
        directory, selection = create('discovered-history-damage', profile)
        health = invoke('damage-fence', directory, selection)
        assert health == {'incoming_rejection_preserved_health': True, 'known_damage_blocked_publication': True,
                          'damage_marker_committed': True}, health
        invoke('dump', directory, selection, code=2, error='integrity')
        results.append({'case': directory.parent.name, **health, 'fresh_reopen_rejected': True})
        print('PASS:', directory.parent.name, flush=True)
    assert len(results) == 76
    (artifacts / 'results.json').write_text(json.dumps(results, indent=2))
    suffix = '; independent envelope inspection PENDING' if args.defer_independent_inspection else ''
    print(f'PASS: {len(results)} fresh-process checks; physical power loss NOT qualified{suffix}', flush=True)


if __name__ == '__main__':
    main()
