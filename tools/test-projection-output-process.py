#!/usr/bin/env python3
"""Independent exact-output/private-owner observations across child-process failures."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--export-cross-host', type=Path)
    mode.add_argument('--check-cross-host', type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve()
    if args.export_cross_host or args.check_cross_host:
        case = (args.export_cross_host or args.check_cross_host).resolve()
        directory, selection = case/'private', case/'selection.json'

        def cross(command, *extra):
            result = subprocess.run([str(binary), command, str(directory), 'public' if command == 'create' else str(selection), *map(str, extra)],
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, (command, result.returncode, result.stderr)
            return json.loads(result.stdout)

        if args.export_cross_host:
            case.mkdir()
            selection.write_text(json.dumps(cross('create')))
            cross('apply', 'put', 1, 'e\u0301')
            assert cross('private-projection-macroman-write', 'Captured.txt')['retained']
        observed = cross('private-projection-encoded-read')
        assert bytes.fromhex(observed['bytes']) == bytes([0x8e])
        assert sorted(observed['notes']) == ['e\u0301', 'untouched']
        (case/'observed.json').write_text(json.dumps(observed, indent=2))
        print('PASS: exact Mac-produced NFD/Mac-Roman bytes and original note spelling survive reopening')
        return
    artifacts = Path(tempfile.mkdtemp(prefix='nv-projection-output-'))
    print('Artifacts:', artifacts, flush=True)
    faults = [('success', None), ('before', (4, 1, -1)), ('after', (5, 1, -1)),
              ('enospc', (1, 1, 13)), ('eio', (2, 1, 1034))]
    for frozen, name, fault in [(frozen, name, fault) for frozen in [False, True] for name, fault in faults]:
        case = artifacts/(("frozen-" if frozen else "") + name)
        case.mkdir()
        directory, selection = case/'private', case/'selection.json'

        def invoke(command, *extra, code=0):
            selected = 'public' if command == 'create' else str(selection)
            result = subprocess.run([str(binary), command, str(directory), selected, *map(str, extra)],
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == code, (command, result.returncode, result.stderr)
            return json.loads(result.stdout) if result.stdout.strip() else None

        selection.write_text(json.dumps(invoke('create')))
        assert invoke('private-projection-encoded-write', 'Before.txt')['retained']
        if frozen:
            assert invoke('private-projection-freeze')['retained']
        before = invoke('private-projection-encoded-read')
        old_bytes = b'\xff\xfe' + 'A'.encode('utf-16-le')
        new_bytes = b'\xff\xfe' + 'Bé'.encode('utf-16-le')
        assert bytes.fromhex(before['bytes']) == old_bytes
        invoke('apply', 'put', 1, 'Bé')
        if fault:
            result = invoke('private-projection-encoded-write', 'After.txt', *fault, code=86 if fault[2] == -1 else 0)
            if fault[2] != -1:
                assert result['retained'] is False and result['hits'] == 1, result
        else:
            assert invoke('private-projection-encoded-write', 'After.txt')['retained']
        observed = invoke('private-projection-encoded-read')
        committed = observed['filename'] == 'After.txt'
        if name != 'eio':
            assert committed == (name in ['success', 'after'])
        assert observed['generation'] == (2 if committed else 1)
        assert observed['notes'] == ['Bé', 'untouched']
        assert bytes.fromhex(observed['bytes']) == (new_bytes if committed else old_bytes)
        chunks = {bytes.fromhex(row[0]).decode(): bytes.fromhex(row[3]) for row in observed['private']
                  if bytes.fromhex(row[0]).startswith(b'projection-data/')}
        owners = ([old_bytes] if frozen or not committed else []) + ([new_bytes] if committed else [])
        expected = {'projection-data/' + '01'*16 + '/' + hashlib.sha256(data).hexdigest() + '/0000000000000000': data for data in owners}
        assert chunks == expected, (name, chunks, expected)
        assert observed['frozen'] == (old_bytes.hex() if frozen else None)
        if not committed:
            assert observed['private'] == before['private']
        (case/'observed.json').write_text(json.dumps(observed, indent=2))
        assert invoke('private-projection-encoded-write', 'Final.txt')['retained']
        final = invoke('private-projection-encoded-read')
        assert final['filename'] == 'Final.txt' and bytes.fromhex(final['bytes']) == new_bytes
        assert final['notes'] == ['Bé', 'untouched']
        print('PASS:', case.name, flush=True)
    print('PASS: 10 exact encoded-output/private-owner recovery schedules', flush=True)
    for name, fault in faults:
        case = artifacts/('freeze-' + name)
        case.mkdir()
        directory, selection = case/'private', case/'selection.json'
        selection.write_text(json.dumps(invoke('create')))
        assert invoke('private-projection-encoded-write', 'Before.txt')['retained']
        before = invoke('private-projection-encoded-read')
        if fault:
            result = invoke('private-projection-freeze', *fault, code=86 if fault[2] == -1 else 0)
            if fault[2] != -1:
                assert result['retained'] is False and result['hits'] == 1, result
        else:
            assert invoke('private-projection-freeze')['retained']
        observed = invoke('private-projection-encoded-read')
        committed = observed['frozen'] is not None
        if name != 'eio':
            assert committed == (name in ['success', 'after'])
        assert observed['frozen'] == (old_bytes.hex() if committed else None)
        assert observed['privateGeneration'] == (2 if committed else 1)
        assert observed['bytes'] == old_bytes.hex() and observed['notes'] == ['A', 'untouched']
        if not committed:
            assert observed['private'] == before['private']
        assert invoke('private-projection-freeze')['retained']
        assert invoke('private-projection-encoded-read')['frozen'] == old_bytes.hex()
        (case/'observed.json').write_text(json.dumps(observed, indent=2))
        print('PASS: freeze-' + name, flush=True)
    case = artifacts/'utf8-after-delete'
    case.mkdir()
    directory, selection = case/'private', case/'selection.json'

    def utf8(command, *extra):
        selected = 'public' if command == 'create' else str(selection)
        result = subprocess.run([str(binary), command, str(directory), selected, *map(str, extra)],
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, (command, result.returncode, result.stderr)
        return json.loads(result.stdout)

    selection.write_text(json.dumps(utf8('create')))
    utf8('apply', 'put', 1, 'e\u0301日本')
    assert utf8('private-projection-write', 'UTF8.txt')['retained']
    utf8('apply', 'delete', 1, '')
    observed = utf8('private-projection-encoded-read')
    assert bytes.fromhex(observed['bytes']) == 'e\u0301日本'.encode('utf-8')
    assert observed['notes'] == ['untouched']
    assert not any(bytes.fromhex(row[0]).startswith(b'projection-data/') for row in observed['private'])
    (case/'observed.json').write_text(json.dumps(observed, indent=2))
    print('PASS: exact historical UTF-8 output after logical deletion in fresh processes', flush=True)


if __name__ == '__main__':
    main()
