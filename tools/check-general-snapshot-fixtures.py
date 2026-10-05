#!/usr/bin/env python3
"""Independent literal layouts for all seven general-snapshot record classes."""
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
u16 = lambda n: struct.pack('>H', n)
u32 = lambda n: struct.pack('>I', n)
u64 = lambda n: struct.pack('>Q', n)
blob = lambda b: u32(len(b)) + b
locator = bytes([2])*16 + u64(3) + bytes([4])*32
operation = locator + u32(5) + bytes([6])*32
action = locator + u32(7) + bytes([8])*16
birth = bytes([1])*16
value = b'\1' + blob(b'T') + blob(b'hi') + u32(0) + struct.pack('>dd', 0, 1)
cell = b'NVCEL1\r\n' + u16(1) + birth + blob(value) + operation + u32(1) + action
payloads = [(1, cell), (2, operation), (3, b'\0'+action), (3, b'\1'+birth+action),
            (4, birth+operation), (5, b'\0'+bytes([9])*32), (6, bytes([10])*32),
            (7, birth+bytes([11])*16+bytes([12])*16+bytes([13])*16)]
records = [bytes([tag])+blob(payload) for tag,payload in payloads]
stream = b'NVGST1\r\n'+u16(1)+b''.join(records)
digest = hashlib.sha256(b'NV general snapshot state\0v1\0'+stream).digest()
page = b'NVGPG1\r\n'+u16(1)+b'\0'+u64(0)+blob(stream)
index = b'NVGPG1\r\n'+u16(1)+b'\1'+u32(1)+locator+u64(0)+u64(len(stream))
root = (b'NVGRT1\r\n'+u16(1)+u16(1)+locator+locator+u64(0)+u64(len(stream))
        +b''.join(u64(n) for n in [1,1,2,1,1,1,1])+digest)
fixtures = {'root': root.hex(), 'dataPage': page.hex(), 'indexPage': index.hex(),
            'stream': stream.hex(), 'digest': digest.hex()}
fixtures.update({f'record{i+1}': r.hex() for i,r in enumerate(records)})
if '--print' in sys.argv:
    print(json.dumps(fixtures, indent=2))
else:
    path = ROOT/'NVStorage/Tests/NVStorageCoreTests/Fixtures/general-snapshot.json'
    assert json.loads(path.read_text()) == fixtures
    assert len(root) == 228
    print('PASS: independent general root, data/index pages and all seven record layouts')
