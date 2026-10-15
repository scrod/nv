#!/usr/bin/env python3
"""Reconstruct copied history in fresh processes with source storage unavailable and independent byte/SQL oracles."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-copy-process-'))
    print('Artifacts:', artifacts, flush=True)

    def probe(*command, code=0):
        result = subprocess.run([str(binary), *map(str, command)], capture_output=True, text=True, timeout=120)
        assert result.returncode == code, (command, result.returncode, result.stdout, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def inventory(directory):
        return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in directory.rglob('*') if p.is_file()}

    completed = []
    for profile in ['public', 'encrypted']:
        for schedule in ['normal', 'damaged-file', 'damaged-hierarchy', 'unavailable', 'lost-callback', 'hole']:
            case = artifacts/(profile + '-' + schedule)
            case.mkdir()
            private, selected, source, target = case/'private', case/'selection.json', case/'source', case/'target'
            selected.write_text(json.dumps(probe('create', private, profile)))
            for action in ['edit', 'delete', 'restore']:
                probe(action, private, selected)
            original = probe('inspect', private, selected)
            exported = probe('copy-saved', private, selected, case/'absent', source)
            assert exported['unmet'] == [] and exported['issues'][0]['path'] == '', exported
            exact = inventory(source)
            damaged = None
            if schedule == 'damaged-file':
                damaged = sorted(source.rglob('*.nvseg'))[0]
                damaged.write_bytes(b'preserved damaged source')
            elif schedule == 'damaged-hierarchy':
                (source/'NV Data').rename(case/'preserved-hierarchy')
                damaged = source/'NV Data'
                damaged.write_bytes(b'preserved damaged source')
            elif schedule == 'unavailable':
                source.rename(case/'unavailable-source')
            elif schedule == 'hole':
                missing = next(row[0].lower() for row in original['objects'] if row[1] == '1')
                removed = next(source.rglob('*-' + missing + '.nvseg'))
                del exact[str(removed.relative_to(source))]
                removed.rename(case/'preserved-missing-object')
            source_before = inventory(source) if source.exists() else {}
            source_inode = damaged.stat().st_ino if damaged else None
            if schedule == 'hole':
                copied = probe('copy-available', source, target)
                assert copied['completeInventory'] and copied['unmet'] == [], copied
            else:
                copied = probe('copy-saved-exit' if schedule == 'lost-callback' else 'copy-saved',
                               private, selected, source, target, code=86 if schedule == 'lost-callback' else 0)
                if copied:
                    assert copied['unmet'] == [], copied
                    assert copied['completeInventory'] == (schedule == 'normal'), copied
                    if damaged:
                        assert [x['path'] for x in copied['issues']] == [str(damaged.relative_to(source))], copied
            assert inventory(target) == exact, (profile, schedule, inventory(target), exact)
            assert (inventory(source) if source.exists() else {}) == source_before
            if damaged:
                assert damaged.stat().st_ino == source_inode and damaged.read_bytes() == b'preserved damaged source'
            private.rename(case/'preserved-source-private')
            if source.exists():
                source.rename(case/'preserved-source-repository')
            recovered = case/'recovered'
            recovered_selection = case/'recovered-selection.json'
            if profile == 'encrypted' and schedule == 'normal':
                probe('copy-bootstrap', target, case/'wrong-key-private', case/'wrong-key-selection.json', 'wrong password', code=2)
                assert not (case/'wrong-key-private').exists() and not (case/'wrong-key-selection.json').exists()
                assert inventory(target) == exact
            if schedule == 'hole':
                probe('copy-bootstrap', target, recovered, recovered_selection, 'probe password', code=2)
                assert not recovered_selection.exists(), 'Incomplete history became an editable copy'
            else:
                result = probe('copy-bootstrap', target, recovered, recovered_selection, 'probe password')
                assert sorted((n['birth'], n['body']) for n in result['notes']) == [('02'*16, 'untouched'), ('03'*16, 'edited')], result
                inspected = probe('inspect', recovered, recovered_selection)
                assert sorted(row[:5] for row in inspected['objects']) == sorted(row[:5] for row in original['objects'])
                for key in ['actions', 'members', 'operation_occurrences', 'action_occurrences', 'dependencies', 'parents', 'predecessors', 'restorations']:
                    assert inspected[key] == original[key], (schedule, key)
                oracle = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(inspected),
                                        capture_output=True, text=True, timeout=120)
                assert oracle.returncode == 0, oracle.stderr
                (case/'independent-history.json').write_text(oracle.stdout)
            completed.append(profile + '-' + schedule)
            print('PASS:', completed[-1], flush=True)
    for profile in ['public', 'encrypted']:
        for schedule in ['normal', 'activated-exit', 'private-before', 'private-after', 'private-enospc', 'private-eio']:
            case = artifacts/(profile + '-switch-' + schedule)
            case.mkdir()
            private, selected, source = case/'private', case/'selection.json', case/'source'
            selected.write_text(json.dumps(probe('create', private, profile)))
            probe('private-seed', private, selected)
            probe('private-latest', private, selected)
            probe('edit', private, selected)
            expected, original = probe('private-dump', private, selected), probe('inspect', private, selected)
            source.mkdir()
            (source/'NV Data').write_bytes(b'preserved damaged source')
            source_before = inventory(source)
            selection_parent = case/'selection-owner'
            selection_parent.mkdir()
            failed = schedule.startswith('private-')
            for attempt in range(2 if failed else 1):
                target, candidate = case/f'target-{attempt}', case/f'candidate-{attempt}'
                killed = schedule in ['activated-exit', 'private-before', 'private-after']
                result = probe('copy-switch', private, selected, source, target, candidate, selection_parent, schedule,
                               code=86 if killed else 0)
                if failed:
                    if result: assert result['switched'] is False and result['hits'] == 1, result
                    assert probe('private-dump', private, selected) == expected
                    record = (selection_parent/'Selected Store').read_bytes()
                    assert record[26:42] == bytes(json.loads(selected.read_text())['store'])
            if failed:
                target, candidate = case/'retry-target', case/'retry-candidate'
                result = probe('copy-switch', private, selected, source, target, candidate, selection_parent, 'normal')
            if result: assert result['switched'] and result['unmet'] == [], result
            record = (selection_parent/'Selected Store').read_bytes()
            recovery = json.loads(selected.read_text())
            recovery['store'] = list(record[26:42])
            assert recovery['store'] != json.loads(selected.read_text())['store']
            recovered_selection = case/'recovered-selection.json'
            recovered_selection.write_text(json.dumps(recovery))
            assert inventory(source) == source_before
            private.rename(case/'preserved-source-private')
            source.rename(case/'preserved-source-repository')
            actual = probe('private-dump', candidate, recovered_selection)
            assert actual == expected, (profile, schedule, actual, expected)
            inspected = probe('inspect', candidate, recovered_selection)
            for key in ['objects', 'actions', 'members', 'operation_occurrences', 'action_occurrences', 'dependencies', 'parents', 'predecessors']:
                assert inspected[key] == original[key], (schedule, key)
            oracle = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(inspected),
                                   capture_output=True, text=True, timeout=120)
            assert oracle.returncode == 0, oracle.stderr
            (case/'independent-history.json').write_text(oracle.stdout)
            portable = probe('copy-bootstrap', target, case/'portable-private', case/'portable-selection.json', 'probe password')
            assert sorted((n['birth'], n['body']) for n in portable['notes']) == [('01'*16, 'edited'), ('02'*16, 'untouched')]
            completed.append(profile + '-switch-' + schedule)
            print('PASS:', completed[-1], flush=True)
    assert len(completed) == 24
    print(json.dumps({'passed': completed}, indent=2))


if __name__ == '__main__':
    main()
