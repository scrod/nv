#!/usr/bin/env python3
"""Independent, complete public bootstrap bytes, assembled from the written tables.

One history object contains Genesis, two Imports in one atomic action and
ImportComplete. Two pages refer to that history. No Swift code is imported.
"""
import hashlib
import json
import struct
import sys
from pathlib import Path


def u16(n): return struct.pack(">H", n)
def u32(n): return struct.pack(">I", n)
def u64(n): return struct.pack(">Q", n)
def sha(b): return hashlib.sha256(b).digest()
def blob(b): return u32(len(b)) + b
def vector(items): return u32(len(items)) + b"".join(items)
def local(n): return b"\x01" + u32(n)
def external(n, identity): return b"\x00" + u32(0) + u32(n) + identity


collection, writer, import_id, action_id, origin = [bytes([n]) * 16 for n in range(1, 6)]
births = [bytes([6]) * 16, bytes([7]) * 16]
bodies = ["line 1\r\nline 2", "e\u0301 / \u00e9"]
values = [b"\x01" + blob(b"Title") + blob(body.encode()) + u32(0) + struct.pack(">dd", 0, 1)
          for body in bodies]
digest = sha(b"NV initial values\0v1\0" + u64(2) + b"".join(b + blob(v) for b, v in zip(births, values)))
ids, records = [], []


def operation(tag, payload, parents, birth=None):
    header = bytes([10 + len(records)]) * 16 + bytes([tag])
    header += b"\x01" + action_id if birth else b"\x00"
    header += b"\x01" + birth if birth else b"\x00"
    parents = sorted(parents, key=lambda n: ids[n])
    identity = sha(b"NV operation\0v1\0" + header + vector([ids[n] for n in parents]) + u32(0) + blob(payload))
    record = identity + header + vector([local(n) for n in parents]) + u32(0) + blob(payload)
    ids.append(identity)
    records.append(record)


operation(1, import_id + b"\x01" + u16(1) + u16(1) + u64(2) + digest, [])
for birth, note in zip(births, values):
    operation(4, note, [0], birth)
operation(2, import_id + u64(2) + digest, [1, 2])
action = action_id + origin + b"\x00\x00" + u32(0) + b"\x04" + vector([u32(1), u32(2)])
action += vector([birth + b"\x00\x01" + local(n) for birth, n in zip(births, [1, 2])])
history = b"NVCHG1\r\n" + u16(1) + u32(0) + vector([blob(record) for record in records]) + vector([blob(action)])
objects = []


def envelope(kind, payload):
    sequence = len(objects)
    header = b"NVSEG1\r\n" + u16(1) + bytes([kind, 0]) + u32(124)
    header += collection + bytes(16) + writer + u64(sequence) + bytes(16)
    header += bytes(8) + u64(len(payload)) + u64(len(payload)) + bytes(12)
    assert len(header) == 124
    data = header + payload + sha(b"NV object envelope\0v1\0" + header + payload)
    locator = writer + u64(sequence) + sha(data)
    objects.append({"locator": locator.hex(), "bytes": data.hex()})
    return locator


genesis = envelope(1, history)
table = vector([genesis])
pages = []
for n, (birth, note) in enumerate(zip(births, values)):
    page = b"NVSPG1\r\n" + u16(1) + import_id + u32(n) + table
    page += vector([birth + note + external(n + 1, ids[n + 1])])
    pages.append(u32(n) + envelope(3, page) + u32(1))
completion = external(3, ids[3])
root = b"NVSRT1\r\n" + u16(1) + import_id + u64(2) + digest + table + completion
root += vector([completion]) + vector(pages)
snapshot = envelope(2, root)
descriptor = b"NVKEY1\r\n" + u16(1) + b"\x01" + collection + bytes(16) + u16(1) + genesis
descriptor += bytes(1 + 4 * 4 + 16 + 12 + 4)
assert len(descriptor) == 150
descriptor += sha(b"NV public descriptor\0v1\0" + descriptor)
output = json.dumps({"collection": collection.hex(), "descriptor": descriptor.hex(),
                     "snapshot": snapshot.hex(), "completion": ids[3].hex(),
                     "actionID": action_id.hex(), "births": [b.hex() for b in births],
                     "bodies": bodies, "objects": objects}, indent=2) + "\n"
if "--print" in sys.argv:
    print(output, end="")
else:
    fixture = Path(__file__).resolve().parents[1] / "NVStorage/Tests/NVStorageCoreTests/Fixtures/initial-bootstrap.json"
    assert fixture.read_text() == output
    print("PASS: independent complete two-page/two-note bootstrap and action history")
