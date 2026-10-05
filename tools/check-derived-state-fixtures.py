#!/usr/bin/env python3
"""Independently assemble the nested equal/merge state references and identities."""
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
u32 = lambda n: struct.pack('>I', n)
text = lambda s: u32(len(s.encode())) + s.encode()


def value(body, modified):
    return b'\x01' + text('T') + text(body) + u32(0) + struct.pack('>dd', 1, modified)


def operation(n, body, parents, modified):
    header = bytes([n])*16 + bytes([5 if parents else 3, 1]) + bytes([n])*16 + b'\x01' + b'\x02'*16
    ids = lambda ps: u32(len(ps)) + b''.join(sorted(ps))
    payload = value(body, modified)
    return hashlib.sha256(b'NV operation\0v1\0' + header + ids(parents or [b'\x63'*32])
                          + ids(parents) + u32(len(payload)) + payload).digest()


def expected():
    base = operation(3, 'a\ngap\nz', [], 2)
    left = operation(4, 'A\ngap\nz', [base], 2)
    right = operation(5, 'a\ngap\nZ', [base], 8)
    equal = operation(6, 'A\ngap\nz', [base], 9)
    external = lambda index, identity: b'\0' + u32(0) + u32(index) + identity
    inputs = b''.join(external(index, identity) for identity, index in sorted([(left, 1), (right, 2)]))
    digest = hashlib.sha256(b'NV note value\0v1\0' + value('A\ngap\nZ', 8)).digest()
    identity = hashlib.sha256(b'NV derived merge\0v1\0' + b'\x01'*16 + b'\x02'*16
                              + b'\0\1' + u32(2) + b''.join(sorted([left, right])) + base + digest).digest()
    merged = b'\x04' + u32(2) + inputs + b'\0\1' + external(0, base) + digest + identity
    equal_digest = hashlib.sha256(b'NV note value\0v1\0' + value('A\ngap\nz', 9)).digest()
    equal_inputs = b''.join(external(index, identity) for identity, index in sorted([(left, 1), (equal, 2)]))
    equal_bytes = b'\x03' + u32(2) + equal_inputs + equal_digest
    assert len(merged) == 194 and len(equal_bytes) == 119
    return {k: v.hex() for k, v in dict(base=base, left=left, right=right, equal=equal,
             merged=merged, equal_state=equal_bytes, merged_digest=digest, equal_digest=equal_digest,
             merge_id=identity).items()}


if __name__ == '__main__':
    if '--print' in sys.argv:
        print(json.dumps(expected(), indent=2))
    else:
        fixture = ROOT/'NVStorage/Tests/NVStorageCoreTests/Fixtures/derived-state.json'
        assert json.loads(fixture.read_text()) == expected()
        print('PASS: independent 119-byte equal and 194-byte merged state fixtures')
