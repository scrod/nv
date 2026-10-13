#!/usr/bin/env python3
"""Fresh-process public Swift installation/readback for both provider profiles."""
import argparse
import hashlib
import json
import os
import stat
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--probe-env', action='append', default=[])
    parser.add_argument('--long-root', action='store_true', help='Exercise real coordinated effects beyond PATH_MAX.')
    args = parser.parse_args()
    environment = os.environ.copy()
    for setting in args.probe_env:
        name, contents = setting.split('=', 1); environment[name] = contents
    artifacts = Path(tempfile.mkdtemp(prefix='nv-immutable-swift-process-'))
    print('Artifacts:', artifacts, flush=True)
    binary = args.binary.resolve()
    def command(*words):
        result = subprocess.run([str(binary), *map(str, words)], capture_output=True, text=True, env=environment, timeout=60)
        assert result.returncode == 0, (words, result.returncode, result.stderr)
        return json.loads(result.stdout)
    for profile in ['public', 'encrypted']:
        fixtures = artifacts/(profile+'-inputs'); root = artifacts/(profile+'-root'); root.mkdir()
        descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        if args.long_root:
            for index in range(24):
                component = str(index) + '-' + 'x' * 190
                os.mkdir(component, dir_fd=descriptor)
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY, dir_fd=descriptor)
                os.close(descriptor); descriptor = child; root /= component
            assert len(os.fsencode(root)) > 4096
        def read_owned(relative):
            parent = os.dup(descriptor)
            try:
                components = relative.split('/')
                for component in components[:-1]:
                    child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                    os.close(parent); parent = child
                file = os.open(components[-1], os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent)
                try:
                    chunks = []
                    while chunk := os.read(file, 65536): chunks.append(chunk)
                    return b''.join(chunks)
                finally: os.close(file)
            finally: os.close(parent)
        def files_owned(parent, prefix=''):
            result = []
            for name in os.listdir(parent):
                relative = prefix + name
                mode = os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode
                if stat.S_ISDIR(mode):
                    child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                    try: result += files_owned(child, relative + '/')
                    finally: os.close(child)
                else:
                    assert stat.S_ISREG(mode), 'Unexpected non-file repository entry'
                    result.append(relative)
            return result
        prepared = command('files-prepare', fixtures, profile)
        sealed = (fixtures/'sealed.fixture').read_bytes()
        # Derive the destination independently from the encoded header and exact bytes.
        assert sealed[:8] == b'NVSEG1\r\n' and int.from_bytes(sealed[12:16], 'big') == 124
        writer = sealed[48:64].hex()
        sequence = int.from_bytes(sealed[64:72], 'big')
        expected_path = f'NV Data/v1/segments/{writer}/{sequence:020d}-{hashlib.sha256(sealed).hexdigest()}.nvseg'
        assert prepared['path'] == expected_path, (prepared['path'], expected_path)
        first = command('files-install', fixtures, root)
        assert first['state'] == 'verified' and not first['existing']
        assert first['path'] == expected_path
        assert read_owned(expected_path) == sealed
        fresh = command('files-read', fixtures, root)
        assert fresh['state'] == 'read' and bytes.fromhex(fresh['hex']) == sealed
        assert fresh['payload'] == 'independent subprocess fixture\n'
        assert command('files-install', fixtures, root)['existing']
        if profile == 'encrypted':
            assert b'independent subprocess fixture' not in sealed
            assert all(b'independent subprocess fixture' not in read_owned(path) for path in files_owned(descriptor))
        assert os.listdir(descriptor) == ['NV Data']
        os.close(descriptor)
        print('PASS:', profile, 'public typed API / independent disk bytes / fresh exec / exact retry / privacy', flush=True)


if __name__ == '__main__': main()
