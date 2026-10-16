#!/usr/bin/env python3
"""Independent history-binding and private observation wire vectors."""
import hashlib
import json
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'NVStorage/Tests/NVStorageCoreTests/Fixtures/projection-observations.json'


def expected():
    def blob(value):
        return struct.pack('>I', len(value)) + value

    def optional(value):
        return b'\0' if value is None else b'\1' + blob(value)

    collection, birth = bytes([1])*16, bytes([2])*16
    locator = bytes([9])*16 + struct.pack('>Q', 7) + bytes([8])*32
    descriptor = b'NVPRD1\r\n' + struct.pack('>H', 1) + blob(b'Note.txt')
    descriptor += struct.pack('>H', 1) + hashlib.sha256(b'A\r\nZ').digest()
    binding = b'NVPBD1\r\n' + struct.pack('>H', 1) + collection + birth + blob(descriptor)
    binding += struct.pack('>I', 1) + locator + b'\1\0' + struct.pack('>II', 0, 3) + bytes([3])*32
    output = struct.pack('>QB', 1, 1) + blob(binding)
    platform = struct.pack('>I', 1) + blob(b'physical')
    metadata = struct.pack('>I', 1) + blob(b'')
    accepted_absent = blob(output) + platform + b'\0'*4
    accepted_empty = blob(output) + platform + optional(metadata)*4
    output2 = struct.pack('>QB', 2, 1) + blob(binding)
    intended = blob(output2) + optional(accepted_empty)
    output3 = struct.pack('>QB', 3, 1) + blob(binding)
    latest = blob(output3) + optional(accepted_empty)
    captured_bytes = b'\xff\xfe' + 'A\r\nZ'.encode('utf-16-le')
    captured_binding = binding.replace(hashlib.sha256(b'A\r\nZ').digest(), hashlib.sha256(captured_bytes).digest())
    captured_output = struct.pack('>QBQQ', 1, 2, 10, len(captured_bytes)) + blob(captured_binding)
    header = b'NVPOB1\r\n' + struct.pack('>H', 1) + collection + bytes([4])*16 + bytes([5])*32 + bytes([6])*16 + birth
    settled = blob(output2) + struct.pack('>I', 1) + blob(b'installed') + b'\0'*4
    settlement = b'NVPSL1\r\n' + struct.pack('>H', 1) + collection + bytes([4])*16 + bytes([5])*32 + bytes([6])*16
    settlement += struct.pack('>Q', 11) + blob(intended) + blob(settled) + optional(struct.pack('>I', 1) + blob(b'source accounted'))
    attempt = b'NVPRA1\r\n' + struct.pack('>H', 1) + collection + bytes([4])*16 + bytes([5])*32 + bytes([6])*16
    attempt += bytes.fromhex('07070707070747078707070707070707') + blob(intended)
    attempt += struct.pack('>I', 1) + blob(b'root') + struct.pack('>I', 1) + blob(b'fresh source')
    moved_descriptor = b'NVPRD1\r\n' + struct.pack('>H', 1) + blob(b'Renamed.txt')
    moved_descriptor += struct.pack('>H', 1) + hashlib.sha256(b'A\r\nZ').digest()
    moved_binding = b'NVPBD1\r\n' + struct.pack('>H', 1) + collection + birth + blob(moved_descriptor)
    moved_binding += struct.pack('>I', 1) + locator + b'\1\0' + struct.pack('>II', 0, 3) + bytes([3])*32
    moved_output = struct.pack('>QB', 2, 1) + blob(moved_binding)
    moved_transition = blob(moved_output) + optional(accepted_empty)
    relocation = b'NVPRA1\r\n' + struct.pack('>H', 1) + collection + bytes([4])*16 + bytes([5])*32 + bytes([6])*16
    relocation += bytes.fromhex('07070707070747078707070707070707') + blob(moved_transition)
    relocation += struct.pack('>I', 1) + blob(b'root') + struct.pack('>I', 1) + blob(b'fresh source')
    source_attempt = b'NVSRC1\r\n' + struct.pack('>H', 1) + collection + bytes([4])*16 + bytes([5])*32 + bytes([6])*16
    source_attempt += bytes.fromhex('07070707070747078707070707070707')
    source_attempt += locator + struct.pack('>I', 2) + bytes([12])*16 + blob(accepted_empty)
    source_attempt += struct.pack('>I', 1) + blob(b'root') + struct.pack('>I', 1) + blob(b'fresh source')
    return {key: value.hex() for key, value in {
        'binding': binding, 'empty': header + b'\0\0\0',
        'absent': header + optional(accepted_absent) + b'\0\0',
        'present_empty': header + optional(accepted_empty) + b'\0\0',
        'transition': header + optional(accepted_empty) + optional(intended) + b'\0',
        'frozen': header + optional(accepted_empty) + optional(intended) + optional(intended),
        'newer': header + optional(accepted_empty) + optional(latest) + optional(intended),
        'captured_binding': captured_binding, 'captured_output': captured_output,
        'settlement': settlement, 'replacement_attempt': attempt, 'relocation_attempt': relocation, 'source_attempt': source_attempt,
    }.items()}


if __name__ == '__main__':
    values = expected()
    if '--write' in sys.argv:
        FIXTURE.write_text(json.dumps(values, indent=2) + '\n')
    assert json.loads(FIXTURE.read_text()) == values
    print('PASS: independent projection bindings, absent/empty metadata and captured source obligations')
