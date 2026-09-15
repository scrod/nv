#!/usr/bin/env python3
"""Check ELF64 storage executables for W^X, a protected stack and RELRO."""
import argparse
from pathlib import Path
import struct


def check(data):
    assert data[:6] == b'\x7fELF\x02\x01', 'Expected little-endian ELF64'
    kind = struct.unpack_from('<H', data, 16)[0]
    assert kind == 3, 'Expected position-independent executable'
    offset = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    assert size == 56 and count > 0
    headers = [struct.unpack_from('<IIQQQQQQ', data, offset + i * size) for i in range(count)]
    loads = [h for h in headers if h[0] == 1]
    assert loads and all(h[1] & 3 != 3 for h in loads), 'Writable executable LOAD segment'
    assert any(h[1] & 1 for h in loads), 'Missing executable code'
    assert any(h[0] == 0x6474e551 and h[1] & 1 == 0 for h in headers), 'Missing non-executable stack'
    assert any(h[0] == 0x6474e552 and h[5] > 0 for h in headers), 'Missing RELRO'
    return offset, size, headers


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary', type=Path)
    args = parser.parse_args()
    data = args.binary.read_bytes()
    offset, size, headers = check(data)
    # A deliberately writable code mapping must be rejected by this observer.
    corrupted = bytearray(data)
    index = next(i for i, h in enumerate(headers) if h[0] == 1 and h[1] & 1)
    struct.pack_into('<I', corrupted, offset + index * size + 4, headers[index][1] | 2)
    try:
        check(corrupted)
    except AssertionError as failure:
        assert str(failure) == 'Writable executable LOAD segment'
    else:
        raise AssertionError('Permission-check negative control survived')
    print('PASS: PIE, W^X, non-executable stack, RELRO; RWX negative control rejected')
