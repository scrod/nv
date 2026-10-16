#!/usr/bin/env python3
"""Independent framing for supported settings, observations and pending ownership."""
import json
import hashlib
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
u16 = lambda n: struct.pack('>H', n)
u32 = lambda n: struct.pack('>I', n)
u64 = lambda n: struct.pack('>Q', n)
blob = lambda b: u32(len(b)) + b
header = lambda s: s.encode('ascii') + u16(1)
platform = u32(1) + blob(b'observed')
scope = bytes([1])*16 + bytes([2])*16 + bytes([3])*32
note = b'\1' + blob(b'T') + blob(b'body') + u32(0) + struct.pack('>dd', 0, 1)
settings = header('NVSET1\r\n') + u32(5) + u16(1)+u64(0) + u16(2)+b'\1' + u16(3)+b'\0'
settings += u16(4)+platform + u16(7)+u32(1)+bytes([4])*16+u64(2)+u64(1)
fixtures = {
    'settings': settings,
    'association': header('NVASC1\r\n') + bytes([5])*16 + scope + platform,
    'snapshot': header('NVPAY1\r\n') + bytes([6])*16 + scope + b'\1' + blob(b'T.txt') + platform + blob(b'body') + blob(note),
    'reservation': header('NVRSV1\r\n') + bytes([7])*16 + bytes([6])*16 + b'\2' + bytes([4])*16 + bytes([8])*32 + bytes([9])*16 + bytes([10])*16 + bytes([11])*32,
}
cell = bytes.fromhex(json.loads((ROOT/'NVStorage/Tests/NVStorageCoreTests/Fixtures/current-cell-v2.json').read_text())['equalCell'])
value_size = struct.unpack('>I', cell[26:30])[0]
value = cell[30:30+value_size]
# The canonical value digest includes exact stored text, labels and display dates.
value_digest = hashlib.sha256(b'NV note value\0v1\0' + value).digest()
fixtures['neutralReservation'] = header('NVRSV1\r\n') + bytes([7])*16 + bytes([6])*16 + b'\4' + bytes([2])*16
fixtures['neutralReservation'] += hashlib.sha256(b'NV pending Current\0v1\0' + cell).digest() + value_digest
settlement_header = header('NVPST1\r\n') + scope + bytes([12])*16
fixtures['consumedSettlement'] = settlement_header + blob(fixtures['reservation']) + b'\1' + blob(platform) + b'\1' + bytes([13])*16
fixtures['neutralSettlement'] = settlement_header + blob(fixtures['neutralReservation']) + b'\1' + blob(platform) + b'\0'
projection = bytes.fromhex(json.loads((ROOT/'NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-observations.json').read_text())['settlement'])
fixtures['projectionSettlement'] = settlement_header + blob(fixtures['neutralReservation']) + b'\2' + blob(projection) + b'\0'
fixtures = {k: v.hex() for k, v in fixtures.items()}
if '--write' in sys.argv:
    (ROOT/'NVStorage/Tests/NVStorageCoreTests/Fixtures/private-records.json').write_text(json.dumps(fixtures, indent=2) + '\n')
if '--print' in sys.argv:
    print(json.dumps(fixtures, indent=2))
else:
    assert json.loads((ROOT/'NVStorage/Tests/NVStorageCoreTests/Fixtures/private-records.json').read_text()) == fixtures
    print('PASS: independent private settings/association/snapshot/reservation bytes')
