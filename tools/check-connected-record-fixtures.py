#!/usr/bin/env python3
"""Independent phase-3 layouts and identities using struct/hashlib and literal inputs."""
import hashlib
import json
from pathlib import Path
import struct
import sys

u32 = lambda n: struct.pack('>I', n)
u64 = lambda n: struct.pack('>Q', n)
opref = lambda index, byte: b'\0' + u32(0) + u32(index) + bytes([byte])*32
actref = lambda index, byte: b'\0' + u32(0) + u32(index) + bytes([byte])*16
local = b'\1' + u32(0)
birth, action, origin = bytes([3])*16, bytes([2])*16, bytes([8])*16
text = lambda value: u32(len(value)) + value
value = b'\1' + text(b'T') + text(b'hi') + u32(0) + struct.pack('>dd', 0, 1)
key = hashlib.sha256(b'NV unresolved recovery key\0v1\0' + birth + u64(2) + b'hi').digest()
automatic = hashlib.sha256(b'NV automatic conflict preservation\0v1\0' + birth + u64(1) + b'T' + u64(2) + b'hi' + u64(0)).digest()
def uuid(digest):
    result = bytearray(digest[:16]); result[6] = result[6] & 15 | 128; result[8] = result[8] & 63 | 128
    return bytes(result)
slot = uuid(hashlib.sha256(b'NV unresolved recovery slot\0v1\0' + key + u64(0)).digest())
def record(kind, target=birth, collection=False, before=None, tail=b''):
    before = b'\1' + opref(4, 7) if before is None else before
    return (action + origin + b'\0' + (b'\0' if collection else b'\1' + target) + u32(0)
            + bytes([kind]) + u32(1) + u32(0) + u32(1) + target + before + b'\1' + local + tail)
def operation(kind, target, payload):
    header = bytes([1])*16 + bytes([kind]) + b'\1' + action + b'\1' + target
    identity = hashlib.sha256(b'NV operation\0v1\0' + header + u32(1) + bytes([6])*32 + u32(0) + u32(len(payload)) + payload).digest()
    return identity + header + u32(1) + opref(0, 6) + u32(0) + u32(len(payload)) + payload
fixtures = {
    'key': key.hex(), 'automaticKey': automatic.hex(), 'slotBirth': slot.hex(), 'automaticBirth': uuid(automatic).hex(),
    'historical': record(7, tail=birth + opref(4, 7) + b'\1').hex(),
    'choice': record(8, tail=opref(5, 8) + u32(2) + opref(4, 7) + opref(5, 8)).hex(),
    'copy': record(9, target=slot, collection=True, before=b'\0', tail=birth + opref(4, 7) + key + u64(0) + b'\0').hex(),
    'undo': record(10, tail=u32(0) + actref(2, 5) + b'\1').hex(),
    'redo': record(11, tail=u32(0) + actref(2, 5) + b'\0').hex(),
    'native': record(12, tail=u32(2) + actref(1, 4) + b'\1' + local + b'\0' + actref(2, 5) + b'\1' + local + b'\0').hex(),
    'copyOperation': operation(7, slot, birth + bytes([7])*32 + key + u64(0) + b'\0' + value).hex(),
    'retireOperation': operation(8, slot, b'\1' + key + u64(0)).hex(),
    'adoptOperation': operation(9, uuid(automatic), birth + bytes([7])*32 + automatic + value).hex(),
    'automaticBefore': record(1, target=uuid(automatic), before=b'\5' + birth + automatic + opref(4, 7)).hex(),
}
if '--print' in sys.argv:
    print(json.dumps(fixtures, indent=2))
else:
    path = Path(__file__).resolve().parents[1] / 'NVStorage/Tests/NVStorageCoreTests/Fixtures/connected-records.json'
    assert json.loads(path.read_text()) == fixtures
    print('PASS: independently encoded history/choice/copy/compensation/coverage, automatic origin and retirement fixtures')
