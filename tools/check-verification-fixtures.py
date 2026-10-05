#!/usr/bin/env python3
"""Check independently authored private-verification byte vectors and framing."""
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / 'docs/impl-proposal-5/plan/phase-4-improvements/verification-fixtures.json'


def main():
    fixture = json.loads(PATH.read_text())
    assert fixture['codec'] == fixture['generation'] == 1
    key = bytes.fromhex(fixture['keyHex'])
    context = bytes.fromhex(fixture['contextHex'])
    assert len(key) == 29 and key[:13] == b'verification/' and len(context) == 64
    assert len(context[:16]) == len(context[16:32]) == 16 and len(context[32:]) == 32
    assert [v['tag'] for v in fixture['variants']] == [1, 2, 3]
    for vector in fixture['variants']:
        payload = bytes.fromhex(vector['payloadHex'])
        assert payload[:8] == b'NVVRFY1\n' and payload[8:72] == context
        assert payload[72] == vector['tag']
        if vector['tag'] == 2:
            assert len(payload) == 81
            assert struct.unpack('>Q', payload[73:])[0] == fixture['historyThrough']
        else:
            assert len(payload) == 129
            assert payload[73:89].hex() == fixture['writerHex']
            assert struct.unpack('>Q', payload[89:97])[0] == fixture['sequence']
            assert payload[97:].hex() == fixture['segmentHex']
    print('PASS: 3 independent private-verification layouts')


if __name__ == '__main__':
    main()
