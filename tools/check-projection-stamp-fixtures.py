#!/usr/bin/env python3
"""Independently assemble advisory projection-stamp bytes and exact byte digests."""
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
u16 = lambda n: struct.pack('>H', n)
u32 = lambda n: struct.pack('>I', n)
u64 = lambda n: struct.pack('>Q', n)


def expected():
    locator = b'\x09' * 16 + u64(7) + b'\x08' * 32
    digest = hashlib.sha256(b'\xef\xbb\xbfA\r\nZ').digest()
    header = b'NVPRJ1\r\n' + u16(1) + b'\x01' * 16
    tail = u16(1) + digest + u32(1) + locator
    reference = lambda index, identity: b'\0' + u32(0) + u32(index) + bytes([identity]) * 32
    ordinary = header + b'\x02' * 16 + tail + b'\x01' + reference(3, 3)
    equal = header + b'\x02' * 16 + tail + b'\x03' + u32(2) + reference(3, 3) + reference(4, 4) + b'\x05' * 32
    merged = header + b'\x02' * 16 + tail + b'\x04' + u32(2) + reference(3, 3) + reference(4, 4)
    merged += u16(1) + reference(2, 2) + b'\x05' * 32 + b'\x06' * 32
    automatic_birth = bytearray(b'\x07' * 16)
    automatic_birth[6] = 0x87
    automatic_birth[8] = 0x87
    automatic = header + automatic_birth + tail + b'\x02' + b'\x02' * 16 + b'\x07' * 32 + reference(3, 3)
    assert [len(x) for x in (ordinary, equal, merged, automatic)] == [178, 255, 330, 226]
    return {k: v.hex() for k, v in dict(digest=digest, ordinary=ordinary, equal=equal,
                                      merged=merged, automatic=automatic).items()}


if __name__ == '__main__':
    if '--print' in sys.argv:
        print(json.dumps(expected(), indent=2))
    else:
        fixture = ROOT / 'NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-stamp.json'
        assert json.loads(fixture.read_text()) == expected()
        print('PASS: independent ordinary/equal/merged/automatic stamp layouts and exact byte digest')
