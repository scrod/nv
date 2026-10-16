#!/usr/bin/env python3
"""Independent canonical Changes projection section and envelope preimages."""
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-transport.json'


def expected():
    def blob(value):
        return struct.pack('>I', len(value)) + value

    collection, birth = bytes([1])*16, bytes([2])*16
    locator = bytes([9])*16 + struct.pack('>Q', 7) + bytes([8])*32
    descriptor = b'NVPRD1\r\n\0\1' + blob(b'Note.txt') + b'\0\1' + hashlib.sha256(b'A\r\nZ').digest()
    binding = b'NVPBD1\r\n\0\1' + collection + birth + blob(descriptor)
    binding += struct.pack('>I', 1) + locator + b'\1\0' + struct.pack('>II', 0, 3) + bytes([3])*32
    absent = b'NVCHG1\r\n\0\1' + struct.pack('>I', 1) + locator + bytes(8)
    payload = absent + b'NVPRJ1\r\n' + struct.pack('>I', 1) + blob(binding)
    header = b'NVSEG1\r\n\0\1\1\0' + struct.pack('>I', 124) + collection + bytes(16)
    header += bytes([9])*16 + struct.pack('>Q', 8) + bytes(24)
    header += struct.pack('>QQ', len(payload), len(payload)) + bytes(12)
    envelope = header + payload + hashlib.sha256(b'NV object envelope\0v1\0' + header + payload).digest()
    return {name: data.hex() for name, data in {
        'absent': absent, 'binding': binding, 'payload': payload,
        'envelope': envelope, 'segment_id': hashlib.sha256(envelope).digest(),
    }.items()}


if __name__ == '__main__':
    values = expected()
    if '--write' in sys.argv:
        FIXTURE.write_text(json.dumps(values, indent=2) + '\n')
    elif '--print' in sys.argv:
        print(json.dumps(values, indent=2))
        sys.exit(0)
    assert json.loads(FIXTURE.read_text()) == values
    print('PASS: independent optional projection section and authenticated envelope preimages')
