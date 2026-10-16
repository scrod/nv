#!/usr/bin/env python3
"""Fresh-process projection acceptance with independently authored bytes and SQL observations."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-projection-transport-'))
    print('Artifacts:', artifacts, flush=True)

    def run(command, directory, selection, *extra, code=0):
        result = subprocess.run([str(binary), command, str(directory), str(selection), *map(str, extra)], capture_output=True, text=True, timeout=60)
        assert result.returncode == code, (command, result.returncode, result.stderr)
        return json.loads(result.stdout) if result.stdout.strip() else None

    def blob(value):
        return struct.pack('>I', len(value)) + value

    cases = [('success', None), ('before', (4, 1, -1)), ('after', (5, 1, -1)),
             ('enospc', (1, 1, 13)), ('eio', (2, 1, 1034))]
    for name, fault in cases:
        case = artifacts/name
        case.mkdir()
        directory, selection = case/'private', case/'selection.json'
        selection.write_text(json.dumps(run('create', directory, 'public')))
        saved = run('apply', directory, selection, 'put', 1, 'portable source')
        envelope = bytes.fromhex(saved['envelope'])
        assert envelope[88] == 0  # The ordinary probe's uncompressed envelope.
        source_id = hashlib.sha256(envelope).digest()
        locator = envelope[48:72] + source_id
        payload = envelope[124:-32]
        operation_start = 14 + struct.unpack('>I', payload[10:14])[0]*56
        assert struct.unpack('>I', payload[operation_start:operation_start+4])[0] == 1
        operation = payload[operation_start+8:operation_start+40]
        descriptor = b'NVPRD1\r\n\0\1' + blob(b'Probe.txt') + b'\0\1' + hashlib.sha256(b'portable source').digest()
        binding = b'NVPBD1\r\n\0\1' + envelope[16:32] + bytes([1])*16 + blob(descriptor)
        binding += struct.pack('>I', 1) + locator + b'\1\0' + bytes(8) + operation
        payload = b'NVCHG1\r\n\0\1' + struct.pack('>I', 1) + locator + bytes(8)
        payload += b'NVPRJ1\r\n' + struct.pack('>I', 1) + blob(binding)
        header = b'NVSEG1\r\n\0\1\1\0' + struct.pack('>I', 124) + envelope[16:32] + bytes(16)
        header += bytes([82])*16 + struct.pack('>Q', 1) + bytes(24) + struct.pack('>QQ', len(payload), len(payload)) + bytes(12)
        candidate = header + payload + hashlib.sha256(b'NV object envelope\0v1\0' + header + payload).digest()
        candidate_id = hashlib.sha256(candidate).hexdigest().upper()
        input_file = case/'incoming.object'
        input_file.write_bytes(candidate)
        before = run('inspect', directory, selection)
        if fault:
            result = run('receive-file', directory, selection, input_file, *fault, 'acceptance', code=86 if fault[2] == -1 else 0)
            if fault[2] != -1:
                assert result['status'] == 'failed' and result['hits'] >= 1, result
        else:
            assert run('receive-file', directory, selection, input_file)['status'] == 'accepted'
        interrupted = run('inspect', directory, selection)
        row = next(r for r in interrupted['objects'] if r[0] == candidate_id)
        assert bytes.fromhex(row[4]) == candidate
        committed = row[5] != ''
        if name != 'eio':
            assert committed == (name in ['success', 'after']), (name, row[5])
        if committed:
            assert int(row[5]) == saved['sequence'] + 1
            assert [candidate_id, source_id.hex().upper()] in interrupted['dependencies']
            assert any(r[0] == candidate_id for r in interrupted['frontier'])
            assert not any(r[0] == source_id.hex().upper() for r in interrupted['frontier'])
        else:
            assert not any(r[0] == candidate_id for r in interrupted['dependencies'])
            assert not any(r[0] == candidate_id for r in interrupted['frontier'])
            assert any(r[0] == source_id.hex().upper() for r in interrupted['frontier'])
            assert [candidate_id] in interrupted['ready']
        # The recovery child receives only ordinary selection/unlock inputs.
        state = run('dump', directory, selection)
        assert sorted(n['body'] for n in state['notes']) == ['portable source', 'untouched']
        assert state['through'] == saved['sequence'] + 1
        report = run('inspect', directory, selection)
        assert report['operations'] == before['operations'] and report['actions'] == before['actions']
        assert [candidate_id, source_id.hex().upper()] in report['dependencies']
        assert any(r[0] == candidate_id for r in report['frontier'])
        assert not any(r[0] == source_id.hex().upper() for r in report['frontier'])
        assert not any(bytes.fromhex(r[0]).startswith(b'projection/') for r in report['private'])
        assert run('receive-file', directory, selection, input_file)['sequence'] == state['through']
        (case/'inspection.json').write_text(json.dumps(report))
        checked = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(report), text=True, capture_output=True, timeout=60)
        assert checked.returncode == 0, checked.stderr
        assert json.loads(checked.stdout)['verified']
        print('PASS:', name, flush=True)
    print('PASS: 5 independently observed projection acceptance/recovery schedules', flush=True)


if __name__ == '__main__':
    main()
