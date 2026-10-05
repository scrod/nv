#!/usr/bin/env python3
"""Fresh-process history reads, independently checked against SQL and exact envelopes."""
import argparse
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
    artifacts = Path(tempfile.mkdtemp(prefix='nv-history-process-'))
    print('Artifacts:', artifacts, flush=True)
    count = 0
    for profile in ['public', 'encrypted']:
        for lost_callback in [False, True]:
            case = artifacts / f'{profile}-{lost_callback}'
            case.mkdir()
            directory, selection = case/'private', case/'selection.json'

            def invoke(command, *extra, code=0):
                run = subprocess.run([str(binary), command, str(directory), str(selection), *map(str, extra)],
                                     capture_output=True, text=True, timeout=60)
                assert run.returncode == code, (command, run.returncode, run.stderr)
                return json.loads(run.stdout) if run.stdout.strip() else None

            create = subprocess.run([str(binary), 'create', str(directory), profile],
                                    capture_output=True, text=True, timeout=60, check=True)
            selection.write_text(create.stdout)
            invoke('edit')
            if lost_callback:
                invoke('delete', 5, 1, -1, 'acceptance', code=86)  # terminate after the history commit, before callback
            else:
                invoke('delete')
            # This opener receives only selection/unlock inputs, never the expected history.
            actual = invoke('history')
            report = invoke('inspect')
            (case/'history.json').write_text(json.dumps(actual, indent=2))
            (case/'inspection.json').write_text(json.dumps(report))
            inspected = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')],
                                       input=json.dumps(report), text=True, capture_output=True, timeout=60)
            assert inspected.returncode == 0, inspected.stderr
            rows = [r for r in report['operations'] if r[2].lower() == '01'*16]
            ids = {int(r[1]): r[0].lower() for r in rows}
            assert len(rows) == 3 and set(ids) == {4, 5, 6}, rows
            values = {row['id']: row for row in actual['history']}
            assert len(values) == 3 and set(values) == set(ids.values()), actual
            assert values[ids[4]]['body'] == 'A' and values[ids[4]]['prior'] == '', actual
            assert values[ids[5]]['body'] == 'edited' and values[ids[5]]['predecessors'] == [ids[4]], actual
            assert values[ids[6]]['body'] == 'edited' and values[ids[6]]['prior'] == ids[5], actual
            assert actual['deletions'] == [ids[6]] and actual['through'] == 3, actual
            assert [n['body'] for n in invoke('dump')['notes']] == ['untouched']
            # Rebuild derived current rows and query again through a different process.
            invoke('tamper', 'view')
            assert invoke('history') == actual
            count += 1
            print('PASS:', case.name, flush=True)
    assert count == 4
    print('PASS: four fresh-process history scenarios, both profiles', flush=True)


if __name__ == '__main__':
    main()
