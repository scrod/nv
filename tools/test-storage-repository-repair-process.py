#!/usr/bin/env python3
"""Complementary private/provider recovery across process failures, checked by independent bytes and SQL."""
import argparse
import errno
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def check_installation_failure(result, schedule):
    code = {'private-enospc': 13, 'private-eio': 1034}[schedule]
    assert result['built'] is False and result['hits'] == 1, result
    assert result['error'] == f'database({code})', result


def object_path(row):
    encoded = bytes.fromhex(row[4])
    assert encoded[:8] == b'NVSEG1\r\n'
    assert encoded[48:64].hex() == row[2].lower()
    assert encoded[64:72].hex() == row[3].lower()
    identity = hashlib.sha256(encoded).hexdigest()
    assert identity == row[0].lower()
    return Path(f'NV Data/v1/segments/{row[2].lower()}/{int(row[3], 16):020d}-{identity}.nvseg')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--only', help='Run schedule names containing this substring.')
    args = parser.parse_args()
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-repair-process-'))
    print('Artifacts:', artifacts, flush=True)
    observation = 0

    def probe(*words, code=0):
        nonlocal observation
        observation += 1
        run = subprocess.run([str(binary), *map(str, words)], capture_output=True, text=True, timeout=120)
        (artifacts/f'child-{observation:04d}.json').write_text(json.dumps({
            'command': list(map(str, words)), 'code': run.returncode,
            'stdout': run.stdout, 'stderr': run.stderr}, indent=2))
        assert run.returncode == code, (words, run.returncode, run.stdout, run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else None

    def durable_inventory(directory):
        return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in directory.rglob('*') if p.is_file() and p.name != 'Collection.sqlite-shm'}

    def verify_history(report, path):
        checked = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')],
                                 input=json.dumps(report), capture_output=True, text=True, timeout=120)
        assert checked.returncode == 0, checked.stderr
        assert json.loads(checked.stdout), 'Independent history decoding must produce observations'
        path.write_text(checked.stdout)

    schedules = ['normal', 'private-before', 'private-after', 'private-enospc', 'private-eio', 'activated',
                 'provider-permission', 'provider-occupied', 'provider-complete-exit']
    if os.geteuid() == 0 and (not args.only or args.only in 'provider-permission'):
        parser.error('The real permission-denial schedule requires a non-root test user.')
    completed = []
    for profile in ['public', 'encrypted']:
        for schedule in schedules:
            if args.only and args.only not in schedule:
                continue
            case = artifacts/(profile + '-' + schedule)
            case.mkdir()
            private, selected, repository, selector = (case/name for name in ['private', 'selection.json', 'repository', 'selector'])
            repository.mkdir(); selector.mkdir()
            selected.write_text(json.dumps(probe('create', private, profile)))
            seed = probe('private-seed', private, selected)
            probe('private-import', private, selected, 5, 1, -1, code=86)
            probe('private-latest', private, selected)
            probe('private-delete', private, selected)
            probe('edit', private, selected)
            probe('private-bind-repository', private, selected, repository, selector)
            probe('exchange-publish', private, selected, repository)
            published = probe('inspect', private, selected)
            damaged = [row for row in published['objects'] if row[1] == '1'][-1]
            damage_input = case/'diagnosed-object'
            damage_input.write_bytes(bytes.fromhex(damaged[4]))
            missing = next(row for row in published['objects'] if row[1] == '3')
            missing_path = object_path(missing)
            (repository/missing_path).rename(case/'preserved-provider-object')
            request = case/'new-edit.json'
            request.write_text(json.dumps({'kind': 'put', 'body': 'unpublished-after-copy'}))
            new_edit = probe('semantic', private, selected, request)
            expected = probe('private-dump', private, selected)
            original = probe('inspect', private, selected)
            verify_history(original, case/'before-history.json')
            assert sorted(n['body'] for n in expected['notes']) == ['unpublished-after-copy', 'untouched']
            assert expected['latest'] == 'latest B' and expected['reservations'][0]['status'] == 'committed'
            assert expected['reservations'][0]['birth'] == seed['birth']
            assert len(expected['payloads']) == 2
            assert not any(p.name.endswith(hashlib.sha256(bytes.fromhex(new_edit['envelope'])).hexdigest() + '.nvseg')
                           for p in repository.rglob('*.nvseg'))
            diagnosed = probe('diagnose-old-damage', private, selected, damage_input, code=86)
            assert diagnosed == {'nonfrontier': True, 'live_publication_blocked': True, 'marker_failed': True}
            damaged_state = probe('inspect', private, selected)
            damaged_rows = {row[0]: row for row in damaged_state['objects']}
            assert damaged_rows[damaged[0]][4] == '00'
            reminders = [row for row in damaged_state['private'] if bytes.fromhex(row[0]).startswith(b'verification/')]
            assert reminders, 'The failed diagnosis must leave durable verification work'
            assert (repository/object_path(damaged)).read_bytes() == bytes.fromhex(damaged[4])
            source_bytes = durable_inventory(private)
            provider_bytes = {str(p.relative_to(repository)): p.read_bytes() for p in repository.rglob('*') if p.is_file()}
            selected_before = (selector/'Selected Store').read_bytes()
            attempt = case/'attempt'
            attempt.mkdir()
            if schedule.startswith(('private-', 'provider-')):
                first_fault = schedule if schedule.startswith('private-') else 'private-eio'
                failed = probe('private-repair-complementary', private, selected, repository, selector, attempt, first_fault,
                               code=86 if first_fault in ['private-before', 'private-after'] else 0)
                if failed is not None:
                    check_installation_failure(failed, first_fault)
                assert (selector/'Selected Store').read_bytes() == selected_before
                assert durable_inventory(private) == source_bytes
                second = case/'second-failure'
                second.mkdir()
                failed = probe('private-repair-complementary', private, selected, repository, selector, second, 'private-enospc')
                check_installation_failure(failed, 'private-enospc')
                assert (selector/'Selected Store').read_bytes() == selected_before
                assert durable_inventory(private) == source_bytes
                attempt = case/'recovered'
                attempt.mkdir()
            result = probe('private-repair-complementary', private, selected, repository, selector, attempt,
                           'activated' if schedule == 'activated' else 'normal', code=86 if schedule == 'activated' else 0)
            if result is not None:
                assert result['built'] and result['missingPrivate'] == [damaged[0].lower()], result
            assert durable_inventory(private) == source_bytes, 'Recovery must preserve the damaged original and its journal'
            assert {str(p.relative_to(repository)): p.read_bytes() for p in repository.rglob('*') if p.is_file()} == provider_bytes
            selected_bytes = (selector/'Selected Store').read_bytes()
            assert len(selected_bytes) == 90 and selected_bytes != selected_before
            inputs = json.loads(selected.read_text())
            inputs['store'] = list(selected_bytes[26:42])
            candidate_inputs = attempt/'reopen.json'
            candidate_inputs.write_text(json.dumps(inputs))
            candidate = attempt/'candidate'
            actual = probe('private-dump', candidate, candidate_inputs)
            assert actual == expected, 'Required private state and current notes must survive together'
            reconstructed = probe('inspect', candidate, candidate_inputs)
            assert {tuple(row[:5]) for row in reconstructed['objects']} == {tuple(row[:5]) for row in original['objects']}
            assert reconstructed['integrity'] == [['ok']] and reconstructed['foreign_keys'] == []
            assert not any(bytes.fromhex(row[0]).startswith(b'verification/') for row in reconstructed['private'])
            verify_history(reconstructed, case/'reconstructed-history.json')
            if schedule.startswith('provider-'):
                # A second repository loss follows successful private activation. Every original copy stays available.
                preserved = case/'provider-before-second-loss'
                (repository/'NV Data').rename(preserved)
                preserved_bytes = durable_inventory(preserved)
                occupied = None
                if schedule == 'provider-occupied':
                    descriptors = list(preserved.glob('v1/keys/*'))
                    assert len(descriptors) == 1
                    occupied = repository/'NV Data'/descriptors[0].relative_to(preserved)
                    occupied.parent.mkdir(parents=True)
                    occupied.write_bytes(b'preserved damaged descriptor')
                    occupied_identity = occupied.stat().st_ino
                if schedule == 'provider-permission':
                    original_mode = repository.stat().st_mode & 0o7777
                    repository.chmod(0o500)
                try:
                    if schedule != 'provider-complete-exit':
                        for failure in range(2):
                            body = f'saved-through-provider-failure-{failure}'
                            stopped = probe('collection-repair', candidate, candidate_inputs, repository, 'save', body)
                            if occupied:
                                assert stopped['repair'] == 'preserved', stopped
                                assert stopped['recovery'] == 'preserveRepositoryCollision', stopped
                                assert occupied.read_bytes() == b'preserved damaged descriptor'
                                assert occupied.stat().st_ino == occupied_identity
                            else:
                                assert stopped['repair'] == 'paused' and stopped['boundary'] == 'root', stopped
                                assert stopped['nativeError'] == errno.EACCES, stopped
                                assert stopped['recovery'] == 'automaticRepositoryRepair', stopped
                                assert not (repository/'NV Data').exists(), 'Denied creation cannot masquerade as repair'
                            assert sorted(n['body'] for n in stopped['notes']) == [body, 'untouched']
                            # A fresh process receives normal selection/unlock inputs and checks private state independently.
                            after_failure = probe('private-dump', candidate, candidate_inputs)
                            assert {key: value for key, value in after_failure.items() if key != 'notes'} == {
                                key: value for key, value in expected.items() if key != 'notes'}
                            assert sorted(n['body'] for n in after_failure['notes']) == [body, 'untouched']
                            failed_inventory = probe('inspect', candidate, candidate_inputs)
                            assert stopped['saved'] in {row[0].lower() for row in failed_inventory['objects']}
                            assert {tuple(row[:5]) for row in reconstructed['objects']} <= {
                                tuple(row[:5]) for row in failed_inventory['objects']}
                            assert (selector/'Selected Store').read_bytes() == selected_bytes
                            assert durable_inventory(private) == source_bytes
                            assert durable_inventory(preserved) == preserved_bytes
                finally:
                    if schedule == 'provider-permission':
                        repository.chmod(original_mode)
                if occupied:
                    occupied.rename(case/'preserved-damaged-descriptor')
                # The next open is the only trigger for automatic repair.
                repaired = probe('collection-repair', candidate, candidate_inputs, repository,
                                 'complete-exit' if schedule == 'provider-complete-exit' else 'normal', '',
                                 code=86 if schedule == 'provider-complete-exit' else 0)
                reconstructed = probe('inspect', candidate, candidate_inputs)
                assert reconstructed['integrity'] == [['ok']] and reconstructed['foreign_keys'] == []
                assert {tuple(row[:5]) for row in original['objects']} <= {
                    tuple(row[:5]) for row in reconstructed['objects']}
                assert len(reconstructed['objects']) == len(original['objects']) + (0 if schedule == 'provider-complete-exit' else 2)
                if repaired:
                    assert repaired['repair'] == 'complete' and 'recovery' not in repaired, repaired
                    assert repaired['objects'] == len(reconstructed['objects']), repaired
                    assert sorted(n['body'] for n in repaired['notes']) == ['saved-through-provider-failure-1', 'untouched']
                else:
                    assert probe('private-dump', candidate, candidate_inputs) == expected
                verify_history(reconstructed, case/'after-provider-repair-history.json')
                assert (selector/'Selected Store').read_bytes() == selected_bytes
                assert durable_inventory(preserved) == preserved_bytes
                if occupied:
                    assert (case/'preserved-damaged-descriptor').read_bytes() == b'preserved damaged descriptor'
                    assert (case/'preserved-damaged-descriptor').stat().st_ino == occupied_identity
            else:
                # The ordinary bounded publisher repairs missing entries from the reconstructed store.
                probe('exchange-publish', candidate, candidate_inputs, repository)
            for row in reconstructed['objects']:
                if row[1] != '0':
                    assert (repository/object_path(row)).read_bytes() == bytes.fromhex(row[4])
            for path, value in provider_bytes.items():
                assert (repository/path).read_bytes() == value
            for path in repository.rglob('*'):
                if path.is_file():
                    value = path.read_bytes()
                    assert b'latest B' not in value, 'A private pending preview must stay private'
                    if profile == 'encrypted':
                        assert all(marker not in value for marker in [b'frozen A', b'unpublished-after-copy', b'saved-through-provider-failure'])
            assert durable_inventory(private) == source_bytes
            completed.append(profile + '-' + schedule)
            (artifacts/'results.json').write_text(json.dumps(completed, indent=2))
            print('PASS:', completed[-1], flush=True)
    expected_count = 2 * sum(not args.only or args.only in name for name in schedules)
    assert expected_count > 0 and len(completed) == expected_count


if __name__ == '__main__':
    main()
