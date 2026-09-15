#!/usr/bin/env python3
"""Independent private-cell/authoring-context layouts; no Swift encoder dependency."""
import json
import struct
from pathlib import Path

u32 = lambda n: struct.pack('>I', n)
value = b'\x01' + u32(1) + b'T' + u32(2) + b'hi' + u32(0) + struct.pack('>dd', 0, 1)
locator = bytes([2]) * 16 + struct.pack('>Q', 3) + bytes([4]) * 32
operation = locator + u32(5) + bytes([6]) * 32
action = locator + u32(7) + bytes([8]) * 16
cell = b'NVCEL1\r\n\x00\x01' + bytes([1]) * 16 + u32(len(value)) + value + operation + u32(1) + action
context = b'NVCTX1\r\n\x00\x01' + u32(1) + operation + u32(1) + action
assert len(value) == 32 and len(cell) == 234 and len(context) == 186
path = Path(__file__).resolve().parents[1] / 'NVStorage/Tests/NVStorageCoreTests/Fixtures/current-state.json'
assert json.loads(path.read_text()) == {name: data.hex() for name, data in
                                      [('value', value), ('locator', locator), ('cell', cell), ('context', context)]}
print('PASS: independent current-cell and authoring-context fixtures')
