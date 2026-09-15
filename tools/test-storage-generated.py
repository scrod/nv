#!/usr/bin/env python3
"""Seeded production-path delivery/crash schedules with an independent command oracle."""
import argparse
import json
from pathlib import Path
import random
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--seeds', type=int, default=4)
    args = parser.parse_args()
    assert args.seeds > 0
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-storage-generated-'))
    print('Artifacts:', artifacts, flush=True)
    results = []
    cuts = [(4, 1, -1), (5, 1, -1), (5, 2, -1), (6, 1, -1), (1, 1, 10), (2, 1, 13)]
    reached = set()

    def invoke(command, directory, selection, *extra, allowed=(0,)):
        run = subprocess.run([str(binary), command, str(directory), str(selection), *map(str, extra)],
                             text=True, capture_output=True, timeout=90)
        assert run.returncode in allowed, (command, run.returncode, run.stderr)
        return run.returncode, json.loads(run.stdout) if run.stdout.strip() else None, run.stderr

    for profile in ['public', 'encrypted']:
        for error_code in [10, 13]:
            case = artifacts / f'{profile}-damage-marker-{error_code}'
            case.mkdir()
            directory, selection = case/'store', case/'selection.json'
            _, identity, _ = invoke('create', directory, profile)
            selection.write_text(json.dumps(identity))
            _, observed, _ = invoke('damage-fence-io', directory, selection, error_code)
            assert observed['known_damage_blocked_publication'] and observed['damage_marker_committed']
            code, _, error = invoke('dump', directory, selection, allowed=(2,))
            assert error.strip() == 'probe failed: integrity', error
            print('PASS: repeated damage-marker failure', profile, error_code, flush=True)
        for seed in range(args.seeds):
            rng = random.Random(seed)
            case = artifacts / f'{profile}-{seed}'
            case.mkdir()
            source, receiver, selection = case/'source', case/'receiver', case/'selection.json'
            _, identity, _ = invoke('create', source, profile)
            selection.write_text(json.dumps(identity))
            shutil.copytree(source, receiver)
            expected = {1: 'A', 2: 'untouched'}
            files = []
            commands = [('put', 1, f'E{seed}'), ('create', 3, f'C{seed}'),
                        ('put', rng.choice([1, 2, 3]), f'F{seed}'), ('delete', 3, ''),
                        ('put', 2, f'G{seed}')]
            for index, (kind, birth, body) in enumerate(commands):
                _, output, _ = invoke('apply', source, selection, kind, birth, body)
                envelope = case/f'{index}.segment'
                envelope.write_bytes(bytes.fromhex(output['envelope']))
                files.append(envelope)
                if kind == 'delete':
                    del expected[birth]
                else:
                    expected[birth] = body
            order = list(range(len(files)))
            rng.shuffle(order)
            order += [rng.randrange(len(files)) for _ in range(3)]
            trace = []
            for step, index in enumerate(order):
                cut = cuts[(seed + step) % len(cuts)]
                code, output, error = invoke('receive-file', receiver, selection, files[index], *cut, allowed=(0, 2, 86))
                if code == 2:
                    assert 'database(' in error, error
                if code == 86 or (output and output.get('hits', 0) >= cut[1]) or code == 2:
                    reached.add(cut)
                trace.append({'index': index, 'cut': cut, 'exit': code, 'output': output, 'error': error})
                # Repeat recovery cuts before the normal retry. These can occur even
                # when the interrupted process already committed its exact object.
                for _ in range(seed % 3):
                    invoke('open-crash', receiver, selection, 6, 1, -1, allowed=(0, 86))
                invoke('receive-file', receiver, selection, files[index])
            for envelope in files:
                invoke('receive-file', receiver, selection, envelope)
            _, actual, _ = invoke('dump', receiver, selection)
            expected_by_birth = {bytes([birth] * 16).hex(): body for birth, body in expected.items()}
            actual_by_birth = {n['birth']: n['body'] for n in actual['notes']}
            assert len(actual['notes']) == len(expected_by_birth) and actual_by_birth == expected_by_birth, (seed, actual, expected)
            assert actual['through'] == len(commands) + 1, actual
            _, report, _ = invoke('inspect', receiver, selection)
            inspection = case/'inspection.json'
            inspection.write_text(json.dumps(report))
            checked = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(report),
                                     text=True, capture_output=True, timeout=90)
            assert checked.returncode == 0, checked.stderr
            (case/'trace.json').write_text(json.dumps(trace, indent=2))
            results.append({'profile': profile, 'seed': seed, 'commands': commands,
                            'expected': expected, 'inspection': str(inspection), 'trace': str(case/'trace.json')})
            print('PASS:', profile, seed, flush=True)
    assert reached == set(cuts), ('Unreached fault classes', set(cuts) - reached)
    (artifacts/'results.json').write_text(json.dumps({'runs': results, 'reached': sorted(reached)}, indent=2))
    print('PASS:', len(results), 'generated schedules; all six fault classes reached; physical power loss remains separate')


if __name__ == '__main__':
    main()
