#!/usr/bin/env python3
"""Independent plaintext value, operation and derived-merge identity fixture."""
import hashlib
import json
from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[1]
u32 = lambda n: struct.pack('>I', n)
text = lambda s: u32(len(s.encode())) + s.encode()
value = lambda body, modified: b'\x01' + text('T') + text(body) + u32(0) + struct.pack('>dd', 1, modified)


def operation(n, body, parents, modified=2):
    payload = value(body, modified)
    header = bytes([n])*16 + bytes([5 if parents else 3, 1]) + bytes([n])*16 + b'\x01' + b'\x02'*16
    ids = lambda ps: u32(len(ps)) + b''.join(sorted(ps))
    preimage = b'NV operation\0v1\0' + header + ids(parents or [b'\x63'*32]) + ids(parents) + u32(len(payload)) + payload
    return hashlib.sha256(preimage).digest()


def main():
    base = operation(3, 'a\ngap\nz', [])
    left, right = operation(4, 'A\ngap\nz', [base]), operation(5, 'a\ngap\nZ', [base], 8)
    result = value('A\ngap\nZ', 8)
    digest = hashlib.sha256(b'NV note value\0v1\0' + result).digest()
    preimage = (b'NV derived merge\0v1\0' + b'\x01'*16 + b'\x02'*16 + struct.pack('>H', 1)
                + u32(2) + b''.join(sorted([left, right])) + base + digest)
    expected = dict(base=base, left=left, right=right, value=result, digest=digest,
                    preimage=preimage, identity=hashlib.sha256(preimage).digest())
    fixture = json.loads((ROOT/'NVStorage/Tests/NVStorageCoreTests/Fixtures/merge.json').read_text())
    assert fixture == {k: v.hex() for k, v in expected.items()}
    print('PASS: independent merge operation/value/identity fixture')


if __name__ == '__main__':
    main()
