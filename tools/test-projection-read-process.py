#!/usr/bin/env python3
"""Observe the rooted projection reader through fresh production-client processes."""
import argparse
import errno
import json
import os
from pathlib import Path
import platform
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
process_helpers = runpy.run_path(str(ROOT / 'tools/test-storage-root-process.py'))
read_reply, request = process_helpers['read_reply'], process_helpers['request']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--directory', type=Path, help='Existing parent for fresh synthetic fixtures.')
    parser.add_argument('--probe-env', action='append', default=[])
    args = parser.parse_args()
    binary = str(args.binary.resolve())
    environment = os.environ.copy()
    for entry in args.probe_env:
        name, separator, value = entry.partition('=')
        assert separator and name, '--probe-env requires NAME=VALUE'
        environment[name] = value
    artifacts = Path(tempfile.mkdtemp(prefix='nv-projection-read-process-', dir=args.directory))
    print('Artifacts:', artifacts, flush=True)
    root = artifacts / 'root'
    root.mkdir()
    note = root / 'Note.txt'
    original = b'before\x00\xff\r\n'
    note.write_bytes(original)
    note.chmod(0o640)
    prefix = '' if platform.system() == 'Darwin' else 'user.'
    attributes = {'encoding': ('com.apple.TextEncoding', b'UTF-8;134217984'),
                  'tags': ('com.apple.metadata:kMDItemOMUserTags', b'\xff\x00raw tags'),
                  'finderTags': ('com.apple.metadata:_kMDItemUserTags', b''),
                  'stamp': ('org.notationalvelocity.projection#S', b'raw stamp')}
    def set_attribute(path, key, contents):
        if platform.system() == 'Darwin':
            subprocess.run(['xattr', '-wx', key, contents.hex(), str(path)], check=True)
        else:
            os.setxattr(path, prefix + key, contents)
    for key, contents in attributes.values():
        set_attribute(note, key, contents)
    mtime = 1700000003234567890
    os.utime(note, ns=(mtime, mtime))
    (root / 'Empty.txt').write_bytes(b'')
    owners = []
    checks = 0

    def passed(name):
        nonlocal checks
        checks += 1
        print('PASS:', name, flush=True)

    def open_owner(path):
        with (artifacts / f'owner-{len(owners)}.stderr').open('w') as errors:
            process = subprocess.Popen([binary, 'root-hold', str(path)], text=True, env=environment,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
        owners.append(process)
        assert read_reply(process) == {'state': 'owned'}
        return process

    def check_original(value):
        assert value['hex'] == original.hex() and value['name'] == 'Note.txt', value
        assert value['permissions'] == 0o640, value
        # The fixture's stat is the independent oracle on filesystems with coarser timestamps.
        observed = note.stat().st_mtime_ns
        assert (value['modifiedSeconds'], value['modifiedNanoseconds']) == divmod(observed, 10**9), value
        for field, (_, contents) in attributes.items():
            assert value[field] == {'state': 'present', 'hex': contents.hex()}, value

    try:
        owner = open_owner(root)
        baseline = request(owner, 'fd-count')
        for _ in range(4):
            check_original(request(owner, 'read-projection', 'Note.txt'))
        assert request(owner, 'fd-count') == baseline
        passed('exact body/raw attributes/permissions/timestamps and descriptor lifetime')

        empty = request(owner, 'read-projection', 'Empty.txt')
        assert empty['hex'] == '' and all(empty[k] == {'state': 'absent'} for k in attributes), empty
        passed('empty file remains distinct from absent attributes and missing data')

        assert request(owner, 'capture-projection', 'Note.txt') == {'state': 'captured'}
        replacement = root / 'Replacement.txt'
        replacement.write_bytes(b'after---\n')
        displaced = artifacts / 'preserved-original.txt'
        note.rename(displaced)
        replacement.rename(note)
        assert request(owner, 'read-captured-projection') == {'unavailable': 'changed'}
        assert request(owner, 'read-projection', 'Note.txt')['hex'] == b'after---\n'.hex()
        assert displaced.read_bytes() == original
        passed('replacement invalidates captured observation; fresh companion reads new bytes')

        assert request(owner, 'capture-projection', 'Note.txt') == {'state': 'captured'}
        set_attribute(note, attributes['tags'][0], b'new metadata')
        assert request(owner, 'read-captured-projection') == {'unavailable': 'changed'}
        assert request(owner, 'read-projection', 'Note.txt')['tags'] == {'state': 'present', 'hex': b'new metadata'.hex()}
        passed('metadata-only change invalidates the exact earlier observation')

        (root / 'Directory.txt').mkdir()
        (root / 'Link.txt').symlink_to('Note.txt')
        os.link(note, root / 'Hard.txt')
        for name, failure in [('Directory.txt', 'kindCollision'), ('Link.txt', 'kindCollision'), ('Hard.txt', 'hardLinked')]:
            assert request(owner, 'read-projection', name) == {'unavailable': failure}
        assert request(owner, 'read-projection', 'Missing.txt') == {'error': f'unavailable({errno.ENOENT})'}
        assert note.read_bytes() == b'after---\n'
        # Move the extra link outside the tested root, retaining the fixture and its identity.
        (root / 'Hard.txt').rename(artifacts / 'preserved-hardlink.txt')
        passed('wrong kinds, symbolic links, hard links and absence preserve existing bytes')

        moved = artifacts / 'moved-root'
        root.rename(moved)
        root.mkdir()
        (root / 'Empty.txt').write_bytes(b'foreign root')
        assert request(owner, 'read-projection', 'Empty.txt')['hex'] == ''
        assert (root / 'Empty.txt').read_bytes() == b'foreign root'
        passed('held owner follows moved directory and preserves replacement pathname')

        assert request(owner, 'capture-projection', 'Empty.txt') == {'state': 'captured'}
        assert request(owner, 'invalidate') == {'state': 'fenced'}
        assert request(owner, 'read-captured-projection') == {'error': 'stalePermission'}
        assert request(owner, 'close') == {'state': 'closed'}
        assert owner.wait(timeout=15) == 0
        passed('revoked generation cannot publish a captured file')

        successor = open_owner(moved)
        assert request(successor, 'read-projection', 'Empty.txt')['hex'] == ''
        assert request(successor, 'close') == {'state': 'closed'}
        assert successor.wait(timeout=15) == 0
        assert displaced.read_bytes() == original
        assert (moved / 'Note.txt').read_bytes() == b'after---\n'
        passed('fresh process reacquires ownership and reads surviving files')
        assert checks == 8
        print('PASS: 8 production projection-read process scenarios', flush=True)
    finally:
        for owner in owners:
            if owner.poll() is None:
                owner.kill()
                owner.wait(timeout=15)


if __name__ == '__main__':
    main()
