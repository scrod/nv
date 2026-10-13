#!/usr/bin/env python3
"""Fresh-process startup, selected bootstrap and association effects with independent SQL/byte observations."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def locator(row):
    encoded = bytes.fromhex(row[4])
    assert encoded[:8] == b'NVSEG1\r\n'
    assert encoded[48:64].hex() == row[2].lower()
    assert encoded[64:72].hex() == row[3].lower()
    return encoded[48:72] + hashlib.sha256(encoded).digest()


def object_path(row):
    loc = locator(row)
    return Path(f'NV Data/v1/segments/{loc[:16].hex()}/{int.from_bytes(loc[16:24], "big"):020d}-{loc[24:].hex()}.nvseg')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--probe-env', action='append', default=[])
    parser.add_argument('--history-observer-stdio', action='store_true',
                        help='Send independent inspection reports to a supervising decoder over stdio.')
    args = parser.parse_args()
    binary = args.binary.resolve()
    environment = os.environ.copy()
    for setting in args.probe_env:
        assert re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', setting)
        name, contents = setting.split('=', 1)
        environment[name] = contents
    artifacts = Path(tempfile.mkdtemp(prefix='nv-startup-process-'))
    print('Artifacts:', artifacts, flush=True)
    results = []
    observation = 0

    def probe(*words, code=0):
        run = subprocess.run([str(binary), *map(str, words)], capture_output=True, text=True,
                             env=environment, timeout=120)
        stem = f'{len(list(artifacts.glob("child-*.json"))):04d}'
        (artifacts/f'child-{stem}.json').write_text(json.dumps({
            'command': list(map(str, words)), 'code': run.returncode,
            'stdout': run.stdout, 'stderr': run.stderr}, indent=2))
        assert run.returncode == code, (words, run.returncode, run.stderr)
        return json.loads(run.stdout) if run.stdout.strip() else None

    def inspect(directory, selected):
        state = probe('inspect', directory, selected)
        assert state['integrity'] == [['ok']] and state['foreign_keys'] == [], state
        for row in state['objects']:
            assert hashlib.sha256(bytes.fromhex(row[4])).hexdigest() == row[0].lower()
        return state

    def verify_history(state):
        nonlocal observation
        if args.history_observer_stdio:
            observation += 1
            print(json.dumps(dict(history_observer=observation, report=state)), flush=True)
            reply = json.loads(input())
            assert reply == dict(history_observer=observation, valid=True), 'Independent history inspection failed'
            return
        checked = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(state),
                                 capture_output=True, text=True, timeout=60)
        assert checked.returncode == 0, checked.stderr
        assert json.loads(checked.stdout), 'The independent decoder must inspect retained history'

    def binding(state, directory, selected):
        rows = [r for r in state['private'] if bytes.fromhex(r[0]) == b'association']
        if not rows:
            return None
        assert len(rows) == 1
        row = rows[0]
        value = bytes.fromhex(row[3])
        assert value[:10] == b'NVASC1\r\n\0\1' and row[2] == '1'
        selection = json.loads(selected.read_text())
        assert value[42:58] == bytes(selection['store'])
        assert value[58:90] == hashlib.sha256(bytes(selection['descriptor'])).digest()
        count = int.from_bytes(value[94:98], 'big')
        assert len(value) == 98 + count and count >= 16
        stat = directory.stat()
        assert value[98:114] == stat.st_dev.to_bytes(8, 'big') + stat.st_ino.to_bytes(8, 'big')
        return int(row[1]), value

    def preserved(before, after):
        for field in ['objects', 'operations', 'actions', 'members', 'operation_occurrences',
                      'action_occurrences', 'dependencies', 'parents', 'predecessors', 'frontier', 'descriptors', 'cells']:
            assert before[field] == after[field], field
        settings = lambda s: [r for r in s['private'] if bytes.fromhex(r[0]) == b'settings']
        assert settings(before) == settings(after)
        verify_history(after)

    for profile in ['public', 'encrypted']:
        for schedule, fault in [
            ('valid', None),
            ('before-binding-commit', (4, 1, -1)),
            ('after-binding-commit', (5, 1, -1)),
            ('binding-write-failure', (1, 1, 13)),
            ('binding-sync-failure', (2, 1, 1034)),
        ]:
            case = artifacts/f'{profile}-{schedule}'; case.mkdir()
            directory, selected, repository = case/'private', case/'selection.json', case/'repository'
            repository.mkdir(); (repository/'unrelated.txt').write_bytes(b'preserve foreign working-tree input')
            probe('create', directory, profile, selected)
            before = inspect(directory, selected)
            unopened = probe('startup-open', directory, selected)
            assert unopened['notes'] is None and unopened['decision'].startswith('recovery('), unopened
            if fault and fault[2] < 0:
                probe('startup-bind', directory, selected, repository, *fault, code=86)
            else:
                reached = probe('startup-bind', directory, selected, repository, *(fault or ()))
                if fault:
                    assert reached['hits'] >= 1 and reached['failure'] is not None, reached
                else:
                    assert reached['failure'] is None and reached['decision'] == 'ready', reached
            surviving = inspect(directory, selected)
            preserved(before, surviving)
            rows = [r for r in surviving['private'] if bytes.fromhex(r[0]) == b'association']
            expected_bound = schedule in ['valid', 'after-binding-commit']
            assert bool(rows) == expected_bound, (schedule, rows)
            reopened = probe('startup-open', directory, selected)
            if expected_bound:
                assert reopened['decision'] == 'ready' and [n['body'] for n in reopened['notes']] == ['A', 'untouched']
                assert binding(surviving, repository, selected)[0] == 1
            else:
                assert reopened['notes'] is None and reopened['decision'].startswith('recovery(')
                # A second reached failure during recovery must preserve the same unbound inputs.
                failed_again = probe('startup-bind', directory, selected, repository, 1, 1, 13)
                assert failed_again['hits'] >= 1 and failed_again['failure'] is not None
                second = inspect(directory, selected)
                assert not [r for r in second['private'] if bytes.fromhex(r[0]) == b'association']
                preserved(before, second)
                healthy = probe('startup-bind', directory, selected, repository)
                assert healthy['failure'] is None and [n['body'] for n in healthy['notes']] == ['A', 'untouched']
            final = inspect(directory, selected)
            assert binding(final, repository, selected)[0] == 1
            preserved(before, final)
            assert (repository/'unrelated.txt').read_bytes() == b'preserve foreign working-tree input'
            assert not (repository/'NV Data').exists(), 'Reassociation must dispatch repair, rather than fabricate a repaired repository'
            results.append({'profile': profile, 'schedule': schedule})
            print('PASS:', case.name, flush=True)

        case = artifacts/f'{profile}-selected-preview-resume'; case.mkdir()
        source, selected = case/'source', case/'source.json'
        probe('create', source, profile, selected)
        before = inspect(source, selected)
        source_repository = case/'source-repository'; source_repository.mkdir()
        publication = probe('exchange-publish', source, selected, source_repository)
        repository = case/'selected-repository'; repository.mkdir()
        root = next(r for r in before['objects'] if r[1] == '2')
        initial_pages = [r for r in before['objects'] if r[1] == '3']
        descriptor = next(Path(p) for p in publication['paths'] if p.endswith('.nvkey'))
        for path in [descriptor, object_path(root), *map(object_path, initial_pages)]:
            (repository/path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_repository/path, repository/path)
        receiver, receiver_selected = case/'receiver', case/'receiver.json'
        receiver_selected.write_text(selected.read_text())
        preview = probe('startup-bootstrap', receiver, receiver_selected, repository, locator(root).hex(), 'preview', 'fresh')
        assert preview['readOnly'] and [n['body'] for n in preview['notes']] == ['A', 'untouched']
        incomplete = inspect(receiver, receiver_selected)
        assert incomplete['actions'] == [] and incomplete['operations'] == [] and incomplete['cells'] == []
        assert json.loads(receiver_selected.read_text())['store'] != json.loads(selected.read_text())['store']
        probe('startup-bootstrap', receiver, receiver_selected, repository, locator(root).hex(), 'complete', 'resume', code=2)
        for path in publication['paths']:
            (repository/path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_repository/path, repository/path)
        complete = probe('startup-bootstrap', receiver, receiver_selected, repository, locator(root).hex(), 'complete', 'resume')
        assert not complete['readOnly'] and [n['body'] for n in complete['notes']] == ['A', 'untouched']
        recovered = inspect(receiver, receiver_selected)
        assert recovered['actions'] == before['actions'] and recovered['operations'] == before['operations']
        assert {r[0]: r[:5] for r in recovered['objects']} == {r[0]: r[:5] for r in before['objects']}
        assert binding(recovered, repository, receiver_selected)[0] == 1
        verify_history(recovered)
        fresh = probe('startup-open', receiver, receiver_selected)
        assert [n['body'] for n in fresh['notes']] == ['A', 'untouched']
        results.append({'profile': profile, 'schedule': 'selected-preview-resume'})
        print('PASS:', case.name, flush=True)

        for intent in ['new', 'existing']:
            case = artifacts/f'{profile}-create-{intent}'; case.mkdir()
            repository, selected, directory = case/'repository', case/'selection.json', case/'private'
            if intent == 'existing':
                repository.mkdir(); (repository/'foreign.txt').write_bytes(b'preserved')
            created = probe('startup-create', directory, selected, repository, profile, intent)
            assert [n['body'] for n in created['notes']] == ['initial', 'untouched']
            fresh = probe('startup-open', directory, selected)
            assert [n['body'] for n in fresh['notes']] == ['initial', 'untouched']
            state = inspect(directory, selected)
            assert binding(state, repository, selected)[0] == 1
            verify_history(state)
            inventory = {str(p.relative_to(repository)): p.read_bytes() for p in repository.rglob('*') if p.is_file()}
            probe('startup-create', case/'other-private', case/'other.json', repository, profile, intent, code=2)
            assert inventory == {str(p.relative_to(repository)): p.read_bytes() for p in repository.rglob('*') if p.is_file()}
            assert not (case/'other-private').exists()
            if profile == 'encrypted':
                assert all(b'initial' not in body and b'untouched' not in body for body in inventory.values())
            results.append({'profile': profile, 'schedule': f'create-{intent}'})
            print('PASS:', case.name, flush=True)
        case = artifacts/f'{profile}-edit-delete-older-reassociation'; case.mkdir()
        directory, selected, original, older = case/'private', case/'selection.json', case/'original', case/'older'
        probe('startup-create', directory, selected, original, profile, 'new')
        edited = probe('startup-apply', directory, selected, 'put', 'surviving integrated edit')
        deleted = probe('startup-apply', directory, selected, 'delete', '')
        assert [n['body'] for n in deleted['notes']] == ['surviving integrated edit'] and deleted['through'] == 3
        before = inspect(directory, selected)
        assert all(any(locator(r).hex() == operation['object'] for r in before['objects'] if r[1] != '0') for operation in [edited, deleted])
        fresh = probe('startup-open', directory, selected)
        assert fresh['notes'] == deleted['notes'] and fresh['context'] == deleted['context']
        older.mkdir(); (older/'foreign.txt').write_bytes(b'preserve older selected root')
        changed = probe('startup-bind', directory, selected, older)
        assert changed['notes'] == deleted['notes'] and changed['context'] == deleted['context']
        after = inspect(directory, selected)
        preserved(before, after)
        assert binding(after, older, selected)[0] == 2
        again = probe('startup-open', directory, selected)
        assert again['notes'] == deleted['notes'] and again['context'] == deleted['context']
        assert (older/'foreign.txt').read_bytes() == b'preserve older selected root'
        results.append({'profile': profile, 'schedule': 'edit-delete-older-reassociation'})
        print('PASS:', case.name, flush=True)
    assert len(results) == 18
    (artifacts/'results.json').write_text(json.dumps(results, indent=2))
    print('PASS: 18 fresh-process startup, binding and selected-bootstrap schedules', flush=True)


if __name__ == '__main__':
    main()
