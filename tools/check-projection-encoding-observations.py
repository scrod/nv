#!/usr/bin/env python3
"""Compare the complete exploratory Foundation encoding matrix against independent bytes.

This exploratory checker preserves failed API and cross-platform equivalence claims.
"""
import argparse
import json
from pathlib import Path

NAMES = ['ascii', 'utf8', 'latin1', 'latin2', 'macRoman', 'cp1252', 'shiftJIS',
         'nonLossyASCII', 'utf16', 'utf16LE', 'utf16BE', 'utf32', 'utf32LE', 'utf32BE']
VALUES = ['', 'A\r\nZ', 'é', 'e\u0301', '日本語', '😀', 'A\0Z']


def read(path):
    rows = json.loads(path.read_text())
    assert len(rows) == len(NAMES) * len(VALUES), 'Incomplete encoding matrix'
    result = {(r['name'], r['input']): r for r in rows}
    assert set(result) == {(n, v) for n in NAMES for v in VALUES}, 'Missing/duplicate cases'
    for (name, value), row in result.items():
        assert row['inputUTF8'] == list(value.encode('utf-8')), 'Input differs from literal fixture'
        if name == 'utf8':
            assert row['swiftBytes'] == row['nsStringBytes'] == row['inputUTF8'] == row['decodedUTF8']
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('observations', type=Path)
    parser.add_argument('--compare', type=Path)
    parser.add_argument('--api', choices=['both', 'swift', 'nsstring'], default='both')
    args = parser.parse_args()
    first = read(args.observations)
    print(f'PASS: {len(first)} exact inputs, complete matrix, independent UTF-8 bytes')
    failures = []
    if args.api == 'both':
        for key, row in first.items():
            if row.get('swiftBytes') != row.get('nsStringBytes'):
                failures.append(('entry-point', key))
                print('Different API outputs:', repr(key), row.get('swiftBytes'), row.get('nsStringBytes'))
    # Python supplies an independent mapping for precomposed Mac Roman é.
    row = first['macRoman', 'é']
    for api in ['swiftBytes', 'nsStringBytes']:
        expected = list('é'.encode('mac_roman'))
        print('Mac Roman independent reference:', expected, api, row.get(api))
        if (args.api == 'both' or api == ('swiftBytes' if args.api == 'swift' else 'nsStringBytes')) and row.get(api) != expected:
            failures.append(('independent-mac-roman', api))
    if args.compare:
        second = read(args.compare)
        for key, left in first.items():
            right = second[key]
            assert left['encoding'] == right['encoding'], 'Encoding identifiers differ'
            fields = ['swiftBytes', 'nsStringBytes'] if args.api == 'both' else ['swiftBytes' if args.api == 'swift' else 'nsStringBytes']
            for field in fields:
                if left.get(field) != right.get(field):
                    failures.append(('platform', key, field))
                    print('Different platform output:', repr(key), field, left.get(field), right.get(field))
    assert not failures, f'{len(failures)} failed exact-byte expectations ({args.api})'
    print(f'PASS: exact-byte expectations for {args.api}')


if __name__ == '__main__':
    main()
