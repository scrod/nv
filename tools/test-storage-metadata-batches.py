#!/usr/bin/env python3
"""Qualify production metadata parsing, exact fields, capability fallback and failure fences."""
import argparse
import errno
from pathlib import Path
import os
import subprocess
import shutil
import stat
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', choices=['address,undefined', 'thread', 'none'], default='address,undefined')
    parser.add_argument('--mutations', action='store_true', help='Challenge production guards in isolated native source copies.')
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-metadata-batches-'))
    print('Artifacts:', artifacts, flush=True)
    flags = ['clang', '-std=c11', '-g', '-O1', '-Wall', '-Wextra', '-Werror', '-Wconversion', '-Wsign-conversion', '-Wcast-align',
             '-fno-omit-frame-pointer', '-I' + str(ROOT/'NVStorage/Sources/CStorageIO/include')]
    if args.sanitize != 'none':
        flags += ['-fsanitize=' + args.sanitize]
    binary = artifacts/'metadata'
    subprocess.run(flags + [str(ROOT/'tests/RepositoryMetadataProbe.c'), '-o', str(binary)], check=True)
    modes = ['bulk', 'portable', 'child-error', 'ancestor']
    if sys.platform == 'darwin':
        modes += ['unsupported', 'io', 'missing-attrs', 'parser']
    count = 0
    for mode in modes:
        for budget in [1, 2, 16, 64]:
            directory = artifacts/(mode + '-' + str(budget))
            leaves = directory/'NV Data/v1/keys'; leaves.mkdir(parents=True)
            for index in range(71):
                (leaves/f'file-{index}').write_bytes(bytes([index]) * (index + 1))
            (leaves/('x' * 255)).write_bytes(b'long')
            (leaves/('é' * 60)).write_bytes(b'unicode')
            raw = os.fsencode(leaves) + b'/invalid-\xff'
            try:
                fd = os.open(raw, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, b'raw'); os.close(fd)
            except OSError as error:
                assert sys.platform == 'darwin' and error.errno in [errno.EPERM, errno.EILSEQ, errno.EINVAL], error
                print('CAPABILITY: filesystem rejects invalid-UTF8 creation:', error.errno, flush=True)
            (leaves/'unavailable').write_bytes(b'preserve')
            (leaves/'directory').mkdir()
            os.symlink('file-0', leaves/'symlink')
            os.link(leaves/'file-1', leaves/'hardlink')
            os.mkfifo(leaves/'fifo')
            expected = {os.fsencode(name).hex() for name in os.listdir(leaves)}
            result = subprocess.run([str(binary), str(directory), mode, str(budget)], text=True, capture_output=True, timeout=60)
            (directory/'result.log').write_text(result.stdout + result.stderr)
            assert result.returncode == 0 and 'PASS:' in result.stdout, (mode, budget, result.stdout, result.stderr)
            if mode not in ['ancestor', 'io', 'parser']:
                found = [line.split()[1] for line in result.stdout.splitlines() if line.startswith('LEAF ')]
                assert len(found) == len(expected) and set(found) == expected, (mode, budget, 'exact raw-name inventory', found, expected)
            print('PASS:', mode, 'budget', budget, flush=True); count += 1
    assert count == len(modes) * 4 and count >= 16
    if args.mutations:
        mutants = [('post-ancestor', 'ancestor',
            'return listing_check(owner, listing);\n}\n\nint nv_root_metadata_refresh',
            'return 0;\n}\n\nint nv_root_metadata_refresh',
            'Ancestor replacement prevents issuing batch evidence')]
        if sys.platform == 'darwin':
            mutants += [('required-attributes', 'missing-attrs',
                '(record.returned.commonattr & requested.commonattr) != requested.commonattr ||', '0 ||',
                'Missing attributes obtain fresh per-entry observations'),
                ('io-as-capability', 'io',
                 'errno != ENOTSUP && errno != ENOSYS && errno != EINVAL',
                 'errno != ENOTSUP && errno != ENOSYS && errno != EINVAL && errno != EIO',
                 'I/O failure retains failure meaning')]
        for name, mode, before, after, assertion in mutants:
            candidate = artifacts/('mutant-' + name)
            for relative in ['tests/RepositoryMetadataProbe.c',
                'NVStorage/Sources/CStorageIO/NVRepositoryFiles.c', 'NVStorage/Sources/CStorageIO/NVRepositoryRoot.c',
                'NVStorage/Sources/CStorageIO/NVRepositoryRootInternal.h', 'NVStorage/Sources/CStorageIO/include/NVRepositoryRoot.h']:
                target = candidate/relative; target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT/relative, target)
            source = candidate/'NVStorage/Sources/CStorageIO/NVRepositoryFiles.c'
            text = source.read_text(); assert text.count(before) == 1, name
            source.write_text(text.replace(before, after, 1))
            executable = candidate/'metadata'
            subprocess.run(flags + [str(candidate/'tests/RepositoryMetadataProbe.c'), '-o', str(executable)], check=True)
            # Give both runs fresh identical inputs, including namespace-changing race controls.
            control, fixture = candidate/'control', candidate/'fixture'
            def copy_fixture(source, destination):
                if stat.S_ISFIFO(os.stat(source, follow_symlinks=False).st_mode):
                    os.mkfifo(destination); return destination
                return shutil.copy2(source, destination)
            shutil.copytree(artifacts/'bulk-16', control, symlinks=True, copy_function=copy_fixture)
            shutil.copytree(artifacts/'bulk-16', fixture, symlinks=True, copy_function=copy_fixture)
            companion = subprocess.run([str(binary), str(control), mode, '16'], text=True, capture_output=True, timeout=60)
            assert companion.returncode == 0 and 'PASS:' in companion.stdout, (name, companion)
            result = subprocess.run([str(executable), str(fixture), mode, '16'],
                text=True, capture_output=True, timeout=60)
            (candidate/'result.log').write_text(result.stdout + result.stderr)
            assert result.returncode == 1 and 'ASSERT: '+assertion in result.stderr, (name, result)
            print('PASS: targeted native mutation', name, flush=True)


if __name__ == '__main__':
    main()
