#!/usr/bin/env python3
"""Independent Restore action layout; literal IDs distinguish every source field."""
import json
import struct
from pathlib import Path

u32 = lambda n: struct.pack('>I', n)
external = lambda index, identity: b'\0' + u32(0) + u32(index) + identity
deletion = external(2, bytes([5])*16)
revision = external(4, bytes([7])*32)
value = (bytes([2])*16 + bytes([8])*16 + b'\0\0' + u32(1) + deletion
         + b'\x06' + u32(1) + u32(0) + u32(1) + bytes([3])*16 + b'\0\1\1' + u32(0)
         + u32(1) + bytes([3])*16 + bytes([4])*16 + deletion + revision + b'\0')
assert len(value) == 202
path = Path(__file__).resolve().parents[1] / 'NVStorage/Tests/NVStorageCoreTests/Fixtures/restoration.json'
assert json.loads(path.read_text()) == {'action': value.hex()}
print('PASS: independent 202-byte Restore action fixture')
