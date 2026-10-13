#!/usr/bin/env python3
"""Qualify immutable installation, genuine image ENOSPC and detach/remount separately."""
import argparse
import errno
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
spec = importlib.util.spec_from_file_location('immutable', ROOT/'tools/test-storage-immutable-files.py')
immutable = importlib.util.module_from_spec(spec); spec.loader.exec_module(immutable)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--filesystem', action='append', choices=['APFS', 'APFSX', 'HFS+', 'HFSX', 'ExFAT'])
    args = parser.parse_args()
    if sys.platform != 'darwin': parser.error('This actual-volume job uses macOS hdiutil')
    artifacts = Path(tempfile.mkdtemp(prefix='nv-immutable-volumes-', dir='/tmp')).resolve()
    print('Artifacts:', artifacts, flush=True)
    binary = artifacts/'native-installer'; immutable.compile_probe(binary)
    observations = []

    def command(argv):
        result = subprocess.run(argv, capture_output=True, timeout=60)
        with (artifacts/'commands.log').open('ab') as log:
            log.write((' '.join(argv) + '\n').encode() + result.stdout + result.stderr)
        assert result.returncode == 0, (argv, result.stderr)
        return result.stdout

    for index, fs in enumerate(args.filesystem or ['APFS', 'APFSX', 'HFS+', 'HFSX', 'ExFAT']):
        image = artifacts/f'image-{index}.sparseimage'; mount = artifacts/f'mount-{index}'; mount.mkdir()
        command(['hdiutil', 'create', '-size', '192m', '-type', 'SPARSE', '-fs',
                 {'APFSX': 'Case-sensitive APFS', 'HFSX': 'Case-sensitive HFS+'}.get(fs, fs),
                 '-volname', f'NVFILES{index}', str(image)])
        device = None

        def attach():
            nonlocal device
            data = plistlib.loads(command(['hdiutil', 'attach', '-plist', '-owners', 'off', '-nobrowse',
                '-noautoopen', '-mountpoint', str(mount), str(image)]))
            device = next(e['dev-entry'] for e in data['system-entities'] if re.fullmatch(r'/dev/disk[0-9]+', e.get('dev-entry', '')))
            assert any(e.get('mount-point') == str(mount) for e in data['system-entities'])
            return device

        try:
            device = attach()
            details = plistlib.loads(command(['diskutil', 'info', '-plist', str(mount)]))
            assert details['FilesystemType'] == {'APFS': 'apfs', 'APFSX': 'apfs', 'HFS+': 'hfs', 'HFSX': 'hfs', 'ExFAT': 'exfat'}[fs]
            (mount/'CaseWitness').write_bytes(b'case')
            assert (mount/'casewitness').exists() == (fs not in ['APFSX', 'HFSX'])
            root = mount/'root'; root.mkdir()
            retry = artifacts/f'retry-{index}'; retry.write_bytes(bytes(range(256))*1024)
            run = immutable.Install(binary, root, retry)
            observed = run.finish()
            (artifacts/f'events-{index}.json').write_text(json.dumps(run.events, indent=2)+'\n')
            if observed['outcome'] != 1:
                assert observed['error'] in [errno.ENOTSUP, errno.EOPNOTSUPP, errno.EINVAL, errno.ENOSYS], observed
                observations.append({'filesystem': fs, 'exclusive_installation': 'unsupported', 'result': observed})
                print('CAPABILITY GAP:', fs, observed, flush=True)
                continue
            final = root/immutable.RELATIVE
            assert final.read_bytes() == retry.read_bytes()
            assert immutable.Install(binary, root, retry).finish()['existing'] == 1
            directories = [root, root/'NV Data', root/'NV Data/v1', root/'NV Data/v1/segments', final.parent]
            assert sum(e['event'] == 'native-fsync' and e['directory'] for e in run.events) == len(directories)
            # Preserve the created final across an actual unmount/remount cycle.
            command(['hdiutil', 'detach', device]); device = None
            device = attach()
            assert final.read_bytes() == retry.read_bytes()
            assert immutable.Install(binary, root, retry).finish()['outcome'] == 1
            # Fill only this freshly created bounded image, keeping protocol directories established.
            filler = mount/'owned-space-witness'
            saw_full = False
            with filler.open('wb', buffering=0) as file:
                # A failed 1 MiB allocation leaves a small metadata reserve. The installer
                # then requests 8 MiB, so its genuine ENOSPC is independently exercised.
                for size in [1024*1024]:
                    block = bytes(size)
                    for _ in range(4096 if size < 1024*1024 else 256):
                        try:
                            amount = file.write(block)
                            assert amount > 0, 'Zero-progress fill cannot qualify ENOSPC'
                        except OSError as error:
                            assert error.errno == errno.ENOSPC, error; saw_full = True; break
                try: os.fsync(file.fileno())
                except OSError as error:
                    assert error.errno == errno.ENOSPC, error; saw_full = True
            assert saw_full, 'The bounded image never reached actual ENOSPC'
            # A fresh writer directory is pre-created before filling; use an absent final leaf afterward.
            space_retry = artifacts/f'space-retry-{index}'; space_retry.write_bytes(bytes(range(256))*32768)
            full_run = subprocess.run([str(binary), str(root), str(space_retry),
                immutable.RELATIVE + '-new', 'quiet', '', '1', str(errno.EIO), '.nv-stage-full-image'],
                text=True, capture_output=True, timeout=30)
            assert full_run.returncode == 0, full_run.stderr
            failure = json.loads(full_run.stdout)
            assert failure['outcome'] != 1 and failure['error'] == errno.ENOSPC, failure
            assert final.read_bytes() == retry.read_bytes()
            # Reclaim only the explicitly owned filler to qualify successful recovery from real fullness.
            with filler.open('r+b', buffering=0) as file: file.truncate(0); os.fsync(file.fileno())
            recovered = subprocess.run([str(binary), str(root), str(space_retry), immutable.RELATIVE + '-new',
                'quiet', '', '1', str(errno.EIO), '.nv-stage-retry-image'], text=True, capture_output=True, timeout=30)
            assert recovered.returncode == 0 and json.loads(recovered.stdout)['outcome'] == 1, recovered
            assert (root/(immutable.RELATIVE + '-new')).read_bytes() == space_retry.read_bytes()
            observations.append({'filesystem': fs, 'exclusive_installation': 'qualified', 'nested_barriers': True,
                                 'equal_retry': True, 'detach_remount': True, 'genuine_ENOSPC_retry': True})
            print('PASS:', fs, 'native exclusive installation / barriers / remount / genuine ENOSPC / retry', flush=True)
        finally:
            if device: command(['hdiutil', 'detach', '-force', device])
    (artifacts/'observations.json').write_text(json.dumps(observations, indent=2) + '\n')
    assert len(observations) == len(args.filesystem or ['APFS', 'APFSX', 'HFS+', 'HFSX', 'ExFAT'])


if __name__ == '__main__': main()
