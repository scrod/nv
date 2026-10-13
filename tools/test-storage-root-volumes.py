#!/usr/bin/env python3
"""Exercise the production root owner across disposable macOS volume lifecycles."""
import argparse
import errno
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('root_process', ROOT / 'tools/test-storage-root-process.py')
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)


def approved_deep_hfs_refusal(filesystem, deep_root, code, stdout, diagnostic):
    """Recognize the approved fresh deep-HFS+ reference-acquisition limitation."""
    return (filesystem == 'HFS+' and deep_root and code == 2 and stdout == ''
            and diagnostic == f'probe failed: unavailable({errno.ESTALE})\n')


def check_acquisition_outcomes():
    """Challenge every condition used to distinguish a safe refusal from failed qualification."""
    valid = ('HFS+', True, 2, '', f'probe failed: unavailable({errno.ESTALE})\n')
    assert approved_deep_hfs_refusal(*valid)
    alternatives = [(0, 'APFS'), (0, 'APFSX'), (0, 'HFSX'), (0, 'ExFAT'),
                    (1, False), (2, 0), (2, -9), (3, '{"state":"owned"}\n'),
                    (4, f'probe failed: unavailable({errno.EIO})\n'),
                    (4, f'probe failed: unavailable({errno.EACCES})\n'),
                    (4, 'probe failed: contention\n'), (4, valid[4] + 'another failure\n')]
    for index, value in alternatives:
        candidate = list(valid)
        candidate[index] = value
        assert not approved_deep_hfs_refusal(*candidate), candidate
    print('PASS: 13 exact acquisition-outcome controls', flush=True)


def open_directory(path):
    """Open an absolute fixture directory through individual path components."""
    assert path.is_absolute()
    descriptor = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in path.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def contender_rooted(path, blocked):
    """Test independent exclusion after either ordinary or deep-root remount."""
    descriptor = open_directory(path)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            assert blocked, 'Unexpected ownership contention'
        else:
            assert not blocked, 'Independent contender acquired a supposedly held root'
    finally:
        os.close(descriptor)


def read_rooted(path):
    """Read the independent byte witness through individually opened path components."""
    descriptor = open_directory(path.parent)
    try:
        leaf = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=descriptor)
        try:
            with os.fdopen(leaf, 'rb', closefd=False) as source:
                return source.read()
        finally:
            os.close(leaf)
    finally:
        os.close(descriptor)


def move_deep(root, mount):
    """Move the owned root below a descriptor-created path exceeding both platform path limits."""
    deep = mount / 'long'
    deep.mkdir()
    descriptor = os.open(deep, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    parent = os.open(mount, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for index in range(24):
            component = str(index) + '-' + 'x' * 190
            os.mkdir(component, dir_fd=descriptor)
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
            deep /= component
        os.rename(root.name, 'deep-root', src_dir_fd=parent, dst_dir_fd=descriptor)
    finally:
        os.close(descriptor)
        os.close(parent)
    result = deep / 'deep-root'
    assert len(os.fsencode(result)) > 4096
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--check-outcomes', action='store_true', help='Run the host-free safe-refusal classification controls.')
    parser.add_argument('--filesystem', action='append', choices=['APFS', 'APFSX', 'HFS+', 'HFSX', 'ExFAT'])
    parser.add_argument('--probe-env', action='append', default=[])
    parser.add_argument('--deep-root', action='store_true',
                        help='Require deep coordinated reads; report the approved exact HFS+ fresh-open refusal separately.')
    args = parser.parse_args()
    check_acquisition_outcomes()
    if args.check_outcomes:
        return
    if args.binary is None:
        parser.error('--binary is required for volume qualification')
    if sys.platform != 'darwin':
        parser.error('This qualification uses macOS hdiutil; run the portable process driver on Linux.')
    binary = str(args.binary.resolve())
    environment = os.environ.copy()
    for value in args.probe_env:
        if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*=.*', value):
            parser.error('--probe-env requires NAME=VALUE')
        name, contents = value.split('=', 1)
        environment[name] = contents
    artifacts = Path(tempfile.mkdtemp(prefix='nv-root-volumes-')).resolve()
    print('Artifacts:', artifacts, flush=True)
    observations = []

    def command(arguments):
        run = subprocess.run(arguments, capture_output=True, timeout=60)
        with (artifacts / 'commands.log').open('ab') as log:
            log.write((' '.join(arguments) + '\n').encode() + run.stdout + run.stderr)
        assert run.returncode == 0, (arguments, run.returncode, run.stderr.decode(errors='replace'))
        return run.stdout

    for index, filesystem in enumerate(args.filesystem or ['APFS', 'APFSX', 'HFS+', 'HFSX', 'ExFAT']):
        image = artifacts / f'fixture-{index}.sparseimage'
        mount = artifacts / f'mount-{index}'
        mount.mkdir()
        format_name = {'APFSX': 'Case-sensitive APFS', 'HFSX': 'Case-sensitive HFS+'}.get(filesystem, filesystem)
        command(['hdiutil', 'create', '-size', '192m', '-type', 'SPARSE',
                 '-fs', format_name, '-volname', f'NVROOT{index}', str(image)])
        device = None
        holders = []

        def attach():
            nonlocal device
            data = plistlib.loads(command(['hdiutil', 'attach', '-plist', '-owners', 'off',
                                         '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(image)]))
            entries = data['system-entities']
            selected = next(e['dev-entry'] for e in entries if re.fullmatch(r'/dev/disk[0-9]+', e.get('dev-entry', '')))
            device = selected
            assert any(e.get('mount-point') == str(mount) for e in entries), entries
            return selected

        def hold(path, allow_deep_hfs_refusal=False):
            diagnostic = artifacts / f'{index}-holder-{len(holders)}.stderr'
            with diagnostic.open('w') as log:
                owner = subprocess.Popen([binary, 'root-hold', str(path)], text=True, stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, stderr=log, env=environment)
            holders.append(owner)
            reply = None
            try:
                reply = processes.read_reply(owner)
                assert reply == {'state': 'owned'}
            except AssertionError as failure:
                if owner.poll() is not None:
                    message = diagnostic.read_text(errors='replace')
                    remaining = owner.stdout.read()
                    if (allow_deep_hfs_refusal and reply is None
                            and approved_deep_hfs_refusal(filesystem, args.deep_root, owner.returncode,
                                                         remaining, message)):
                        return None
                    raise AssertionError((filesystem, 'root acquisition', owner.returncode,
                                          message)) from failure
                raise
            return owner

        def close(owner):
            assert processes.request(owner, 'close') == {'state': 'closed'}
            assert owner.wait(timeout=15) == 0

        try:
            device = attach()
            details = plistlib.loads(command(['diskutil', 'info', '-plist', str(mount)]))
            expected_type = {'APFS': 'apfs', 'APFSX': 'apfs', 'HFS+': 'hfs', 'HFSX': 'hfs', 'ExFAT': 'exfat'}[filesystem]
            assert details.get('FilesystemType') == expected_type, details
            root = mount / 'root'
            root.mkdir()
            note = root / 'note.txt'
            (root / 'CaseProbe').write_bytes(b'case witness')
            assert (root / 'caseprobe').exists() == (filesystem not in ['APFSX', 'HFSX'])
            with note.open('wb') as file:
                file.write(b'preserved across forced detach')
                file.flush()
                os.fsync(file.fileno())
            owner = hold(root)
            baseline = processes.request(owner, 'fd-count')
            contender_rooted(root, True)
            assert processes.request(owner, 'observe', 'note.txt') == {'kind': 1, 'bytes': 30}
            assert processes.request(owner, 'quiesce') == {'state': 'fenced'}
            contender_rooted(root, True)
            assert processes.request(owner, 'compare', root) == {'continuity': 'same', 'state': 'active'}
            assert processes.request(owner, 'fd-count') == baseline

            # The Foundation reference follows the owned object rather than its former selected path.
            moved = mount / 'moved-root'
            root.rename(moved)
            root.mkdir()
            replacement = root / 'note.txt'
            replacement.write_bytes(b'preserved independent replacement')
            contender_rooted(moved, True)
            contender_rooted(root, False)
            assert processes.request(owner, 'read', 'note.txt') == {'hex': b'preserved across forced detach'.hex()}
            assert processes.request(owner, 'compare', root) == {'continuity': 'different', 'state': 'fenced'}
            assert processes.request(owner, 'compare', moved) == {'continuity': 'same', 'state': 'active'}
            assert replacement.read_bytes() == b'preserved independent replacement'
            root = moved
            note = root / 'note.txt'
            if args.deep_root:
                root = move_deep(root, mount)
                note = root / 'note.txt'
                assert read_rooted(note) == b'preserved across forced detach'
                observed = processes.request(owner, 'read', 'note.txt')
                assert observed == {'hex': b'preserved across forced detach'.hex()}, (filesystem, 'deep coordinated read', observed)
                assert processes.request(owner, 'compare', root) == {'continuity': 'same', 'state': 'active'}
                print('PASS:', filesystem, 'deep same-object move and coordinated exact read', flush=True)

            # This force detach targets only the exact device returned for this fresh image.
            command(['hdiutil', 'detach', '-force', device])
            device = None
            loss = processes.request(owner, 'observe', 'note.txt')
            assert loss == {'error': f'unavailable({errno.ESTALE})'}, loss
            assert processes.request(owner, 'state') == {'state': 'fenced'}
            device = attach()
            assert read_rooted(note) == b'preserved across forced detach'
            root_descriptor = open_directory(root)
            try:
                before_identity = os.fstat(root_descriptor)
                before_names = sorted(os.listdir(root_descriptor))
            finally:
                os.close(root_descriptor)
            successor = hold(root, allow_deep_hfs_refusal=args.deep_root and filesystem == 'HFS+')
            fresh_deep = 'not requested'
            if args.deep_root and successor is not None:
                fresh_deep = 'passed'
                print('PASS:', filesystem, 'fresh deep acquisition after remount', flush=True)
            assert processes.request(owner, 'compare', root) == {
                'continuity': f'unavailable({errno.ESTALE})', 'state': 'fenced'}
            close(owner)
            if successor is not None:
                contender_rooted(root, True)
                assert processes.request(successor, 'observe', 'note.txt') == {'kind': 1, 'bytes': 30}
                close(successor)
            else:
                fresh_deep = 'approved limitation: fresh deep HFS+ reference unavailable (ESTALE)'
                root_descriptor = open_directory(root)
                try:
                    after_identity = os.fstat(root_descriptor)
                    assert (after_identity.st_dev, after_identity.st_ino) == (before_identity.st_dev, before_identity.st_ino)
                    assert sorted(os.listdir(root_descriptor)) == before_names
                finally:
                    os.close(root_descriptor)
                assert read_rooted(note) == b'preserved across forced detach'
                assert read_rooted(root / 'CaseProbe') == b'case witness'
                assert replacement.read_bytes() == b'preserved independent replacement'
                print('LIMITATION:', filesystem, 'fresh deep acquisition safely refused; identity, bytes and namespace preserved', flush=True)
            contender_rooted(root, False)
            observations.append({'requestedFilesystem': filesystem,
                                 'actualFilesystem': details.get('FilesystemType'),
                                 'filesystemName': details.get('FilesystemName'),
                                 'sameObjectMove': 'passed',
                                 'deepSameObjectMove': 'passed' if args.deep_root else 'not requested',
                                 'freshDeepAcquisition': fresh_deep,
                                 'detachRemount': 'passed'})
            print('PASS:', filesystem, 'same-object move, exact read, replacement preservation and forced detach/remount', flush=True)
        finally:
            for holder in holders:
                if holder.poll() is None:
                    holder.kill()
                    holder.wait(timeout=15)
                for stream in [holder.stdin, holder.stdout]:
                    stream.close()
            if device is not None:
                command(['hdiutil', 'detach', device])
            (artifacts / 'results.json').write_text(json.dumps(observations, indent=2) + '\n')


if __name__ == '__main__':
    main()
