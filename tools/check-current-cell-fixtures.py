#!/usr/bin/env python3
"""Independent extended current rows and full-state Restore action layouts."""
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
u32 = lambda n: struct.pack('>I', n)
u64 = lambda n: struct.pack('>Q', n)
blob = lambda b: u32(len(b)) + b
value = lambda title, body, created, modified: b'\1' + blob(title) + blob(body) + u32(0) + struct.pack('>dd', created, modified)
external = lambda index, identity: b'\0' + u32(0) + u32(index) + identity
locator = bytes([9])*16 + u64(7) + bytes([8])*32
stored = lambda index, identity: locator + u32(index) + identity
spec = importlib.util.spec_from_file_location('derived', ROOT/'tools/check-derived-state-fixtures.py')
derived = importlib.util.module_from_spec(spec)
spec.loader.exec_module(derived)
d = {k: bytes.fromhex(v) for k, v in derived.expected().items()}

def uuid(digest):
    b = bytearray(digest[:16]); b[6] = b[6] & 15 | 128; b[8] = b[8] & 63 | 128
    return bytes(b)

def cell(birth, note, refs, heads, claim=None, automatic=None, identity=None):
    first = sorted(refs, key=lambda r: r[-32:])[0]
    vectors = b''.join(u32(len(rs)) + b''.join(sorted(rs, key=lambda r: r[-32:])) for rs in [refs, heads])
    nested = b'\0' if claim is None else b'\1' + u32(1) + locator + blob(claim)
    return (b'NVCEL1\r\n\0\2' + birth + blob(note) + first + u32(0) + vectors + nested
            + (b'\0' if automatic is None else b'\1' + automatic)
            + (b'\0' if identity is None else b'\1' + identity))

source = bytes([3])*16
original = value(b'T', b'hi', 0, 1)
automatic_key = hashlib.sha256(b'NV automatic conflict preservation\0v1\0' + source + u64(1) + b'T' + u64(2) + b'hi' + u64(0)).digest()
recovery_key = hashlib.sha256(b'NV unresolved recovery key\0v1\0' + source + u64(2) + b'hi').digest()
automatic_birth = uuid(automatic_key)
recovery_birth = uuid(hashlib.sha256(b'NV unresolved recovery slot\0v1\0' + recovery_key + u64(0)).digest())
single = stored(4, bytes([7])*32)
deletion = external(2, bytes([5])*16)
def restored(prior, deleted_birth):
    return (bytes([2])*16 + bytes([8])*16 + b'\0\0' + u32(1) + deletion
            + b'\6' + u32(1) + u32(0) + u32(1) + source + b'\0\1\1' + u32(0)
            + u32(1) + source + deleted_birth + deletion + external(4, bytes([7])*32) + b'\1' + prior)
equal_prior = b'\3' + u32(2) + external(4, bytes([7])*32) + external(5, bytes([8])*32) + hashlib.sha256(b'NV note value\0v1\0' + original).digest()
automatic_prior = b'\5' + source + automatic_key + external(4, bytes([7])*32)
fixtures = {
    'equalCell': cell(bytes([2])*16, value(b'T', b'A\ngap\nz', 1, 9), [stored(1,d['left']), stored(2,d['equal'])], [stored(1,d['left']), stored(2,d['equal'])], d['equal_state']),
    'mergedCell': cell(bytes([2])*16, value(b'T', b'A\ngap\nZ', 1, 8), [stored(1,d['left']), stored(2,d['right'])], [stored(1,d['left']), stored(2,d['right'])], d['merged']),
    'automaticCell': cell(automatic_birth, value(b'T (conflict)', b'hi', 0, 1), [single], [single], automatic=source+automatic_key+single, identity=b'\0'+automatic_key),
    'recoveryCell': cell(recovery_birth, value(b'T (conflict)', b'hi', 0, 1), [single], [single], identity=b'\1'+recovery_key+u64(0)),
    'equalRestore': restored(equal_prior, bytes([4])*16),
    'automaticRestore': restored(automatic_prior, automatic_birth),
}
fixtures = {k: v.hex() for k,v in fixtures.items()}
if '--print' in sys.argv:
    print(json.dumps(fixtures, indent=2))
else:
    assert json.loads((ROOT/'NVStorage/Tests/NVStorageCoreTests/Fixtures/current-cell-v2.json').read_text()) == fixtures
    print('PASS: independent equal/merged/automatic/recovery cells and complete-state Restore records')
