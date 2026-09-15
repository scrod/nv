#!/usr/bin/env python3
"""Independent fixed recovery vectors; no production Swift imports or secrets."""
import hashlib
import struct


def recovery_key(key):
    # BIP-173/BIP-350 polynomial; bit-string packing is independent of Swift's loop.
    alphabet = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
    bits = "".join(f"{b:08b}" for b in key) + "0000"
    data = [1] + [int(bits[i:i+5], 2) for i in range(0, 260, 5)]
    hrp = "nvrk"
    values = [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp] + data + [0]*6
    check = 1
    for value in values:
        top = check >> 25
        check = ((check & 0x1ffffff) << 5) ^ value
        for i, generator in enumerate([0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]):
            if (top >> i) & 1:
                check ^= generator
    check ^= 0x2bc830a3
    return hrp + "1" + "".join(alphabet[i] for i in data + [(check >> (5*(5-i))) & 31 for i in range(6)])


def selection():
    header = b"NVSEL1\r\n" + struct.pack(">H", 1) + bytes([1])*16 + bytes([2])*16 + bytes([3])*16
    return header + hashlib.sha256(b"NV local selection\0v1\0" + header).digest()


if __name__ == "__main__":
    from pathlib import Path
    fixture = Path(__file__).resolve().parents[1] / "NVStorage/Tests/NVStorageCoreTests/RecoveryArtifactsTests.swift"
    source = fixture.read_text()
    for value in [selection().hex(), recovery_key(bytes(range(32))), recovery_key(bytes(32))]:
        assert value in source, f"missing/different independent fixture: {value}"
    print("PASS: selected-store SHA-256 and two Bech32m fixtures independently reproduced")
