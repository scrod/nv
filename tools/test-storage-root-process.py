#!/usr/bin/env python3
"""Independent process/descriptor witnesses for the production P5.1 root owner."""
import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import tempfile


def read_reply(process):
    with selectors.DefaultSelector() as ready:
        ready.register(process.stdout, selectors.EVENT_READ)
        assert ready.select(15), 'Root probe did not reach its next reported boundary'
    line = process.stdout.readline()
    assert line, ('Root probe exited before reply', process.poll())
    return json.loads(line)


def request(process, command, argument=None):
    process.stdin.write(json.dumps(dict(command=command, argument=str(argument) if argument is not None else None)) + '\n')
    process.stdin.flush()
    return read_reply(process)


def contender(path, blocked):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            assert blocked, 'Unexpected ownership contention'
        else:
            assert not blocked, 'Independent contender acquired a supposedly held root'
    finally:
        os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--probe-env', action='append', default=[], help='Set NAME=VALUE directly on each probe child.')
    args = parser.parse_args()
    environment = os.environ.copy()
    for value in args.probe_env:
        if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', value):
            parser.error('--probe-env requires NAME=VALUE')
        name, contents = value.split('=', 1)
        environment[name] = contents
    binary = str(args.binary.resolve())
    artifacts = Path(tempfile.mkdtemp(prefix='nv-root-process-'))
    print('Artifacts:', artifacts, flush=True)
    processes = []

    def hold(path):
        with (artifacts / f'holder-{len(processes)}.stderr').open('w') as diagnostic:
            p = subprocess.Popen([binary, 'root-hold', str(path)], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=diagnostic, text=True, env=environment)
        processes.append(p)
        assert read_reply(p) == {'state': 'owned'}
        return p

    try:
        root = artifacts / 'root'
        root.mkdir()
        (root / 'note.txt').write_bytes(b'original')
        identity_marker = bytes(range(16))
        (root / 'collection-identity.bin').write_bytes(identity_marker)
        owner = hold(root)
        status = request(owner, 'availability', 'note.txt')
        assert status['residency'] == 'materialized', status
        assert request(owner, 'read', 'note.txt') == {'hex': b'original'.hex()}
        provider = request(owner, 'provider')
        assert provider['provider'] in ['identified', 'unknown', 'unsupported'] and provider['state'] == 'active', provider
        print('PASS: selected availability, exact coordinated read and supplemental forward identity preserve active ownership', flush=True)
        baseline = request(owner, 'fd-count')
        for n in range(4):
            (root / f'child-{n}').mkdir()
            assert request(owner, 'observe', 'note.txt') == {'kind': 1, 'bytes': 8}
            assert request(owner, 'observe', f'child-{n}')['kind'] == 2
            assert {'note.txt', 'collection-identity.bin', f'child-{n}'}.issubset(p.name for p in root.iterdir())
            contender(root, True)
        assert request(owner, 'fd-count') == baseline, 'Rooted observations leaked child descriptors'
        other = subprocess.run([binary, 'root-try', str(root)], text=True, capture_output=True, timeout=15, env=environment)
        assert other.returncode == 0 and json.loads(other.stdout) == {'state': 'contention'}, other.stderr
        print('PASS: independent exec and descriptor contenders remain excluded after child/scan closure', flush=True)

        moved = artifacts / 'moved'
        root.rename(moved)
        root.mkdir()
        (root / 'note.txt').write_bytes(b'replacement')
        (root / 'collection-identity.bin').write_bytes(identity_marker)
        assert (moved / 'collection-identity.bin').read_bytes() == (root / 'collection-identity.bin').read_bytes()
        contender(moved, True)
        contender(root, False)
        assert request(owner, 'observe', 'note.txt') == {'kind': 1, 'bytes': 8}
        assert request(owner, 'compare', root) == {'continuity': 'different', 'state': 'fenced'}
        assert request(owner, 'observe', 'note.txt') == {'error': 'stalePermission'}
        assert request(owner, 'compare', moved) == {'continuity': 'same', 'state': 'active'}
        assert request(owner, 'observe-old', 'note.txt') == {'error': 'stalePermission'}
        assert request(owner, 'observe', 'note.txt') == {'kind': 1, 'bytes': 8}
        assert request(owner, 'quiesce') == {'state': 'fenced'}
        contender(moved, True)
        assert request(owner, 'observe', 'note.txt') == {'error': 'stalePermission'}
        assert request(owner, 'compare', moved) == {'continuity': 'same', 'state': 'active'}
        contender(moved, True)
        assert (root / 'note.txt').read_bytes() == b'replacement'
        assert request(owner, 'close') == {'state': 'closed'}
        assert owner.wait(timeout=15) == 0
        contender(moved, False)
        print('PASS: move/handoff retains the original lock; replacement and stale permissions stay distinct', flush=True)

        killed = hold(moved)
        contender(moved, True)
        killed.kill()
        assert killed.wait(timeout=15) < 0
        contender(moved, False)
        successor = subprocess.run([binary, 'root-try', str(moved)], text=True, capture_output=True, timeout=15, env=environment)
        assert successor.returncode == 0 and json.loads(successor.stdout) == {'state': 'acquired'}, successor.stderr
        print('PASS: pipe-confirmed holder termination releases the actual directory object', flush=True)
        assert (moved / 'note.txt').read_bytes() == b'original'
        assert set(p.name for p in root.iterdir()) == {'note.txt', 'collection-identity.bin'}
        print('PASS: original bytes and replacement bytes survive; ownership creates no child lock file', flush=True)

        lost = artifacts / 'empty-owned-root'
        fresh = artifacts / 'empty-replacement'
        lost.mkdir()
        fresh.mkdir()
        removed_owner = hold(lost)
        fresh.rename(lost)
        (lost / 'new.txt').write_bytes(b'preserved replacement')
        loss = request(removed_owner, 'observe', 'new.txt')
        assert loss == {'error': f'unavailable({errno.ESTALE})'}, loss
        assert request(removed_owner, 'state') == {'state': 'fenced'}
        contender(lost, False)
        assert request(removed_owner, 'compare', lost) == {'continuity': f'unavailable({errno.ESTALE})', 'state': 'fenced'}
        assert request(removed_owner, 'observe-old', 'new.txt') == {'error': 'stalePermission'}
        assert request(removed_owner, 'close') == {'state': 'closed'}
        assert removed_owner.wait(timeout=15) == 0
        assert (lost / 'new.txt').read_bytes() == b'preserved replacement'
        print('PASS: actual empty-root replacement fences the retained original and preserves its successor', flush=True)

        long_root = artifacts / 'long'
        long_root.mkdir()
        descriptor = os.open(long_root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for index in range(24):
                component = str(index) + '-' + 'x' * 190
                os.mkdir(component, dir_fd=descriptor)
                next_descriptor = os.open(component, os.O_RDONLY | os.O_DIRECTORY, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = next_descriptor
                long_root /= component
            note = os.open('note.txt', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=descriptor)
            try:
                assert os.write(note, b'long-root') == 9
            finally:
                os.close(note)
        finally:
            os.close(descriptor)
        assert len(str(long_root).encode()) > 4096
        long_owner = hold(long_root)
        assert request(long_owner, 'observe', 'note.txt') == {'kind': 1, 'bytes': 9}
        assert request(long_owner, 'read', 'note.txt') == {'hex': b'long-root'.hex()}
        availability = request(long_owner, 'availability', 'note.txt')
        assert availability['management'] == 'unknown' and availability['residency'] in ('materialized', 'unknown')
        provider = request(long_owner, 'provider')
        assert provider['state'] == 'active' and provider['provider'] in ('unknown', 'unsupported')
        assert request(long_owner, 'compare', long_root) == {'continuity': 'same', 'state': 'active'}
        assert request(long_owner, 'close') == {'state': 'closed'}
        assert long_owner.wait(timeout=15) == 0
        print('PASS: initial acquisition and same-object revalidation exceed PATH_MAX', flush=True)
    finally:
        for process in processes:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=15)
            for stream in [process.stdin, process.stdout, process.stderr]:
                if stream is not None:
                    stream.close()


if __name__ == '__main__':
    main()
