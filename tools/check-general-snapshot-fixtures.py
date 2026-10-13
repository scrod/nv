#!/usr/bin/env python3
"""Independent v1 layouts for snapshot state and paged retention parents."""
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
        +b''.join(u64(n) for n in [1,1,2,1,1,1,1,0])+digest)
fixtures = {'root': root.hex(), 'dataPage': page.hex(), 'indexPage': index.hex(),
            'stream': stream.hex(), 'digest': digest.hex()}
fixtures.update({f'record{i+1}': r.hex() for i,r in enumerate(records)})
parents = [locator, bytes([14])*16 + u64(15) + bytes([16])*32]
retention_records = [b'\10'+blob(parent) for parent in parents]
stream_with_parents = b'NVGST1\r\n'+u16(1)+b''.join(records + retention_records)
digest_with_parents = hashlib.sha256(b'NV general snapshot state\0v1\0'+stream_with_parents).digest()
root_with_parents = (b'NVGRT1\r\n'+u16(1)+u16(1)+locator+locator+u64(0)+u64(len(stream_with_parents))
                    +b''.join(u64(n) for n in [1,1,2,1,1,1,1,2])+digest_with_parents)
fixtures.update({'rootWithParents': root_with_parents.hex(), 'streamWithParents': stream_with_parents.hex(),
                 'digestWithParents': digest_with_parents.hex(),
                 'dataPageWithParents': (b'NVGPG1\r\n'+u16(1)+b'\0'+u64(0)+blob(stream_with_parents)).hex(),
                 'retentionParent1': retention_records[0].hex(), 'retentionParent2': retention_records[1].hex()})
if '--print' in sys.argv:
    print(json.dumps(fixtures, indent=2))
else:
    path = ROOT/'NVStorage/Tests/NVStorageCoreTests/Fixtures/general-snapshot.json'
    assert json.loads(path.read_text()) == fixtures
    assert len(root) == len(root_with_parents) == 236
    print('PASS: independent v1 roots with empty/populated parents, pages and eight manifest categories')
