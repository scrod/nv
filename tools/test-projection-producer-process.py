#!/usr/bin/env python3
"""Inspect locally produced descriptions and their atomic acceptance across fresh-process failures."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import time
import statistics

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--retention-growth', action='store_true', help='Measure repeated metadata-only descriptions with fixed note history.')
    args = parser.parse_args()
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-projection-producer-'))
    print('Artifacts:', artifacts, flush=True)
    if args.retention_growth:
        measure_growth(binary, artifacts)
        return
    for name, fault in [('success', None), ('before', (4, 1, -1)), ('after', (5, 1, -1)),
                        ('enospc', (1, 1, 13)), ('eio', (2, 1, 1034))]:
        case = artifacts/name
        case.mkdir()
        directory, selection = case/'private', case/'selection.json'

        def run(command, *extra, code=0):
            selected = 'public' if command == 'create' else str(selection)
            result = subprocess.run([str(binary), command, str(directory), selected, *map(str, extra)],
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == code, (command, result.returncode, result.stderr)
            return json.loads(result.stdout) if result.stdout.strip() else None

        selection.write_text(json.dumps(run('create')))
        source = run('apply', 'put', 1, 'producer source')
        assert run('private-projection-write', 'Producer.txt')['retained']
        assert run('private-projection-description')['accepted']
        before = run('inspect')
        prior_sequence = source['sequence'] + 1
        prior_description = next(r for r in before['objects'] if r[5] == str(prior_sequence))
        if fault:
            result = run('private-projection-description', *fault, code=86 if fault[2] == -1 else 0)
            if fault[2] != -1:
                assert result['accepted'] is False and result['hits'] >= 1, result
        else:
            assert run('private-projection-description')['accepted']
        observed = run('inspect')
        prior_ids = {r[0] for r in before['objects']}
        candidates = [r for r in observed['objects'] if r[0] not in prior_ids]
        assert len(candidates) == 1
        row = candidates[0]
        encoded = bytes.fromhex(row[4])
        identity = hashlib.sha256(encoded).hexdigest().upper()
        assert row[0] == identity and encoded[88] == 0
        assert encoded[-32:] == hashlib.sha256(b'NV object envelope\0v1\0' + encoded[:-32]).digest()
        payload = encoded[124:-32]
        assert payload[:14] == b'NVCHG1\r\n\0\1' + struct.pack('>I', 2)
        parent = bytes.fromhex(source['envelope'])
        locator = parent[48:72] + hashlib.sha256(parent).digest()
        prior_bytes = bytes.fromhex(prior_description[4])
        prior_locator = prior_bytes[48:72] + hashlib.sha256(prior_bytes).digest()
        assert payload[14:126] == b''.join(sorted([locator, prior_locator]))
        assert payload[126:146] == bytes(8) + b'NVPRJ1\r\n' + struct.pack('>I', 1)
        binding_size = struct.unpack('>I', payload[146:150])[0]
        binding = payload[150:]
        assert len(binding) == binding_size
        assert binding[:42] == b'NVPBD1\r\n\0\1' + encoded[16:32] + bytes([1])*16
        descriptor_size = struct.unpack('>I', binding[42:46])[0]
        expected_descriptor = b'NVPRD1\r\n\0\1' + struct.pack('>I', 12) + b'Producer.txt' + b'\0\1'
        expected_descriptor += hashlib.sha256(b'producer source').digest()
        assert binding[46:46+descriptor_size] == expected_descriptor
        source_payload = parent[124:-32]
        operation_start = 14 + struct.unpack('>I', source_payload[10:14])[0]*56
        operation_id = source_payload[operation_start+8:operation_start+40]
        assert binding[46+descriptor_size:] == struct.pack('>I', 1) + locator + b'\1\0' + bytes(8) + operation_id
        committed = row[5] != ''
        if name != 'eio':
            assert committed == (name in ['success', 'after'])
        previous_private = {r[0]: r for r in before['private']}
        assert [r for r in observed['private'] if r[0] in previous_private] == before['private']
        reminders = [r for r in observed['private'] if r[0] not in previous_private]
        assert len(reminders) <= 1
        selected = json.loads(selection.read_text())
        verification = b'NVVRFY1\n' + bytes(selected['store']) + encoded[16:32]
        verification += hashlib.sha256(bytes(selected['descriptor'])).digest() + b'\2' + struct.pack('>Q', prior_sequence)
        for reminder in reminders:
            key = bytes.fromhex(reminder[0])
            assert key.startswith(b'verification/') and len(key) == len(b'verification/') + 16
            assert reminder[1:3] == ['1', '1'] and bytes.fromhex(reminder[3]) == verification
        if name in ['before', 'after']:
            assert len(reminders) == 1
        assert observed['operations'] == before['operations'] and observed['actions'] == before['actions']
        if committed:
            assert int(row[5]) == prior_sequence + 1
            assert [identity, hashlib.sha256(parent).hexdigest().upper()] in observed['dependencies']
            assert [identity, prior_description[0]] in observed['dependencies']
            assert not any(r[0] == prior_description[0] for r in observed['frontier'])
            assert any(r[0] == identity for r in observed['frontier'])
        else:
            assert [identity] in observed['ready']
            assert not any(r[0] == identity for r in observed['dependencies'])
            assert observed['frontier'] == before['frontier']
        # Reopening uses only the surviving store and ordinary selection/unlock data.
        reopened = run('dump')
        assert reopened['through'] == prior_sequence + 1
        assert sorted(n['body'] for n in reopened['notes']) == ['producer source', 'untouched']
        final = run('inspect')
        retained = next(r for r in final['objects'] if r[0] == identity)
        assert bytes.fromhex(retained[4]) == encoded and int(retained[5]) == reopened['through']
        assert any(r[0] == identity for r in final['frontier'])
        assert not any(r[0] == hashlib.sha256(parent).hexdigest().upper() for r in final['frontier'])
        assert not any(r[0] == prior_description[0] for r in final['frontier'])
        assert next(r for r in final['objects'] if r[0] == prior_description[0]) == prior_description
        assert not any(r[0] == identity for r in final['ready'])
        assert final['private'] == before['private'] and final['operations'] == before['operations'] and final['actions'] == before['actions']
        checked = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(final),
                                 text=True, capture_output=True, timeout=60)
        assert checked.returncode == 0 and json.loads(checked.stdout)['verified'], checked.stderr
        (case/'inspection.json').write_text(json.dumps(final))
        print('PASS:', name, flush=True)
    print('PASS: 5 locally produced exact-description recovery schedules', flush=True)


def measure_growth(binary, artifacts):
    directory, selection = artifacts/'private', artifacts/'selection.json'

    def run(command, *extra):
        selected = 'public' if command == 'create' else str(selection)
        result = subprocess.run([str(binary), command, str(directory), selected, *map(str, extra)],
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, (command, result.returncode, result.stderr)
        return json.loads(result.stdout)

    selection.write_text(json.dumps(run('create')))
    run('apply', 'put', 1, 'fixed source')
    assert run('private-projection-write', 'Producer.txt')['retained']
    baseline = run('inspect')
    results = []
    for count in range(1, 65):
        assert run('private-projection-description')['accepted']
        if count not in [1, 8, 64]:
            continue
        inspected = run('inspect')
        assert inspected['actions'] == baseline['actions'] and inspected['operations'] == baseline['operations']
        assert inspected['private'] == baseline['private']
        assert len(inspected['frontier']) == len(baseline['frontier'])
        assert len(inspected['objects']) == len(baseline['objects']) + count
        elapsed = []
        for _ in range(3):
            started = time.monotonic()
            state = run('dump')
            elapsed.append((time.monotonic() - started)*1000)
            assert sorted(n['body'] for n in state['notes']) == ['fixed source', 'untouched']
        results.append({'descriptions': count, 'startup_leaves': len(inspected['frontier']),
                        'whole_child_open_median_ms': statistics.median(elapsed)})
        print(json.dumps(results[-1]), flush=True)
    (artifacts/'growth.json').write_text(json.dumps(results, indent=2))
    print('PASS: repeated descriptions retain every envelope with bounded startup leaves.', flush=True)


if __name__ == '__main__':
    main()
