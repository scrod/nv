#!/usr/bin/env python3
"""Recompute merge evidence in a fresh process from accepted envelopes after callback loss."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    binary = parser.parse_args().binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-merge-process-'))
    print('Artifacts:', artifacts, flush=True)
    count = 0
    for profile in ['public', 'encrypted']:
        # Receive commits retained bytes, the ready-work check, then acceptance.
        for crash in [0, 1, 3]:
            case = artifacts / f'{profile}-{crash}'
            case.mkdir()
            made = subprocess.run([str(binary), 'merge-pair', str(case), profile], capture_output=True, text=True, timeout=90, check=True)
            pair = json.loads(made.stdout)
            for side in ['left', 'right']:
                (case/(side+'.json')).write_text(pair[side]['selection'])
                (case/(side+'.segment')).write_bytes(bytes.fromhex(pair[side]['envelope']))
            results = []
            for side, other in [('left', 'right'), ('right', 'left')]:
                cmd = [str(binary), 'receive-file', str(case/side), str(case/(side+'.json')), str(case/(other+'.segment'))]
                if crash: cmd += ['5', str(crash), '-1']
                received = subprocess.run(cmd, text=True, capture_output=True, timeout=90)
                assert received.returncode == (86 if crash else 0), received.stderr
                if crash == 1:
                    recovery = subprocess.run(cmd[:-3], text=True, capture_output=True, timeout=90)
                    assert recovery.returncode == 0, recovery.stderr
                opened = subprocess.run([str(binary), 'dump', str(case/side), str(case/(side+'.json'))],
                                        text=True, capture_output=True, timeout=90, check=True)
                assert [n['body'] for n in json.loads(opened.stdout)['notes']] == ['A\ngap\nZ']
                read = subprocess.run([str(binary), 'merge-inspect', str(case/side), str(case/(side+'.json'))],
                                      text=True, capture_output=True, timeout=90, check=True)
                result = json.loads(read.stdout)
                assert result['body'] == 'A\ngap\nZ'
                assert result['heads'] == sorted([pair['left']['head'], pair['right']['head']])
                assert result['operations'] == 3 and result['actions'] == '3', result
                digest = hashlib.sha256(b'NV note value\0v1\0' + bytes.fromhex(result['value'])).digest()
                preimage = (b'NV derived merge\0v1\0' + bytes.fromhex(result['collection']) + bytes.fromhex(result['birth'])
                            + struct.pack('>HI', 1, 2) + b''.join(bytes.fromhex(h) for h in result['heads'])
                            + bytes.fromhex(result['base']) + digest)
                assert bytes.fromhex(result['preimage']) == preimage
                assert result['identity'] == hashlib.sha256(preimage).hexdigest()
                (case/(side+'-result.json')).write_text(json.dumps(result, indent=2))
                results.append(result)
            assert results[0] == results[1]
            edited = subprocess.run([str(binary), 'edit', str(case/'left'), str(case/'left.json')],
                                    text=True, capture_output=True, timeout=90, check=True)
            after = subprocess.run([str(binary), 'dump', str(case/'left'), str(case/'left.json')],
                                   text=True, capture_output=True, timeout=90, check=True)
            assert [n['body'] for n in json.loads(after.stdout)['notes']] == ['edited']
            count += 1
            print('PASS:', case.name, flush=True)
    assert count == 6
    print('PASS: six fresh-process merge-evidence schedules, both profiles')


if __name__ == '__main__':
    main()
