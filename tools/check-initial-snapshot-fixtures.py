#!/usr/bin/env python3
"""Independent initial snapshot layout/commitment oracle. No production Swift imports."""
import hashlib
import json
import struct
import sys
from pathlib import Path

u32 = lambda n: struct.pack(">I", n)
u64 = lambda n: struct.pack(">Q", n)
locator = bytes([1])*16 + u64(7) + bytes([3])*32
table = u32(1) + locator
birth = bytes([2])*16
value = b"\x01" + u32(1) + b"T" + u32(1) + b"B" + u32(0) + struct.pack(">dd", 0, 0)
op = b"\x00" + u32(0) + u32(2) + bytes([4])*32
complete = b"\x00" + u32(0) + u32(3) + bytes([5])*32
import_id = bytes([8])*16
commitment = hashlib.sha256(b"NV initial values\0v1\0" + u64(1) + birth + u32(len(value)) + value).digest()
empty = hashlib.sha256(b"NV initial values\0v1\0" + u64(0)).digest()
page = b"NVSPG1\r\n\x00\x01" + import_id + u32(0) + table + u32(1) + birth + value + op
page_locator = bytes([1])*16 + u64(8) + bytes([6])*32
root = b"NVSRT1\r\n\x00\x01" + import_id + u64(1) + commitment + table + complete + u32(1) + complete + u32(1) + u32(0) + page_locator + u32(1)
empty_root = b"NVSRT1\r\n\x00\x01" + import_id + u64(0) + empty + table + complete + u32(1) + complete + u32(0)
output = json.dumps({"page":page.hex(), "root":root.hex(), "emptyRoot":empty_root.hex(),
                     "value":value.hex(), "commitment":commitment.hex(), "emptyCommitment":empty.hex()}, indent=2)+"\n"
if "--print" in sys.argv:
    print(output, end="")
else:
    fixture = Path(__file__).resolve().parents[1] / "NVStorage/Tests/NVStorageCoreTests/Fixtures/initial-snapshot.json"
    assert fixture.read_text() == output
    print("PASS: independent initial snapshot page/root/empty-root and commitments")
