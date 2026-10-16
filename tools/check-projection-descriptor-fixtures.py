#!/usr/bin/env python3
"""Independently assemble exact-path projection descriptors from their field contract."""
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]


def expected():
    result = {}
    for key, name, body in [('nfc', 'Caf\u00e9.1.txt', b'A\r\nZ'),
                            ('nfd', 'Cafe\u0301.1.txt', b'A\r\nZ'),
                            ('empty', 'Empty.txt', b'')]:
        name = name.encode('utf-8')
        value = b'NVPRD1\r\n' + struct.pack('>HI', 1, len(name)) + name
        value += struct.pack('>H', 1) + hashlib.sha256(body).digest()
        assert len(value) == 48 + len(name)
        result[key] = value.hex()
    return result


if __name__ == '__main__':
    if '--print' in sys.argv:
        print(json.dumps(expected(), indent=2))
    else:
        fixture = ROOT / 'NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-descriptor.json'
        assert json.loads(fixture.read_text()) == expected()
        print('PASS: independent exact-path projection descriptors, including empty output')
