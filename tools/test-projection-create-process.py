#!/usr/bin/env python3
"""Fresh-process frozen-history creation with independent disk and private-state oracles."""
import argparse
from contextlib import contextmanager
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile


@contextmanager
def repository_volume(artifacts, filesystem):
    """Keep private SQL on the host while testing note output on a disposable volume."""
    if filesystem is None:
        yield artifacts
        return

    def command(arguments):
        result = subprocess.run(arguments, capture_output=True, timeout=60)
        with (artifacts/'volume-commands.log').open('ab') as log:
            log.write((' '.join(map(str, arguments)) + '\n').encode() + result.stdout + result.stderr)
        assert result.returncode == 0, (arguments, result.returncode, result.stderr)
        return result.stdout

    image, mount = artifacts/'notes.sparseimage', artifacts/'volume'
    mount.mkdir()
    format_name = {'APFSX': 'Case-sensitive APFS', 'HFSX': 'Case-sensitive HFS+'}.get(filesystem, filesystem)
    size = '512m' if filesystem == 'ExFAT' else '192m'
    command(['hdiutil', 'create', '-size', size, '-type', 'SPARSE',
             '-fs', format_name, '-volname', 'NVP6CREATE', str(image)])
    device = None
    try:
        ownership = 'off' if filesystem == 'ExFAT' else 'on'
        entries = plistlib.loads(command(['hdiutil', 'attach', '-plist', '-owners', ownership,
            '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(image)]))['system-entities']
        device = next(e['dev-entry'] for e in entries if re.fullmatch(r'/dev/disk[0-9]+', e.get('dev-entry', '')))
        assert any(Path(e['mount-point']).resolve() == mount.resolve()
                   for e in entries if 'mount-point' in e), entries
        info = command(['diskutil', 'info', '-plist', str(mount)])
        (artifacts/'volume.plist').write_bytes(info)
        expected = {'APFS': 'apfs', 'APFSX': 'apfs', 'HFS+': 'hfs', 'HFSX': 'hfs', 'ExFAT': 'exfat'}[filesystem]
        assert plistlib.loads(info)['FilesystemType'] == expected
        (mount/'CaseProbe').write_bytes(b'case witness')
        assert (mount/'caseprobe').exists() == (filesystem not in ['APFSX', 'HFSX'])
        yield mount
    finally:
        if device is not None:
            command(['hdiutil', 'detach', device])


def run_cases(binary, artifacts, repository_parent, filesystem):
    """Apply the same recovery and collision assertions to every selected filesystem."""
    cases = ['normal', 'missing-callback', 'newer-intent', 'collision', 'fractional-dates'] if sys.platform == 'darwin' else ['unsupported']
    for name in cases:
        case = artifacts/name
        case.mkdir()
        repository = repository_parent/(name + '-notes')
        repository.mkdir()
        private, selection = case/'private', case/'selection.json'

        def invoke(command, *extra, code=0):
            profile = 'public-fractional' if name == 'fractional-dates' else 'public'
            result = subprocess.run([str(binary), command, str(private),
                profile if command == 'create' else str(selection), *map(str, extra)],
                capture_output=True, text=True, timeout=60)
            assert result.returncode == code, (command, result.returncode, result.stderr)
            return json.loads(result.stdout) if result.stdout.strip() else None

        selection.write_text(json.dumps(invoke('create')))
        assert invoke('private-projection-create', repository, 'prepare') == {'prepared': True}
        expected = b'\xff\xfeA\x00'
        if name == 'newer-intent':
            invoke('apply', 'put', 1, 'C')
            assert invoke('private-projection-encoded-write', 'New.txt')['retained']
        if name == 'collision':
            (repository/'Note.txt').write_bytes(b'foreign')
        before = invoke('private-projection-encoded-read')
        observed = invoke('private-projection-create', repository,
            'exit-after-install' if name == 'missing-callback' else 'install-dates' if name == 'fractional-dates' else 'install',
            code=86 if name == 'missing-callback' else 0)
        (case/'creation-result.json').write_text(json.dumps(observed))
        after = invoke('private-projection-encoded-read')
        assert after == before, (before, after)
        assert bytes.fromhex(after['frozen']) == expected
        if name == 'unsupported':
            assert observed == {'state': 'notInstalled', 'reason': 'unsupported(95)'}, observed
            assert not (repository/'Note.txt').exists()
        else:
            if name == 'missing-callback':
                assert observed is None
            elif name == 'collision':
                assert observed == {'state': 'notInstalled', 'reason': 'conflict'}, observed
            elif name == 'fractional-dates':
                birth_ns, modified_ns = (0, 0) if filesystem in ['HFS+', 'HFSX'] else (125_000_000, 750_000_000)
                assert observed == {'state': 'verified', 'bytes': expected.hex(),
                    'createdSeconds': 978_307_200, 'createdNanoseconds': birth_ns,
                    'modifiedSeconds': 978_307_201, 'modifiedNanoseconds': modified_ns}, observed
                info = (repository/'Note.txt').stat()
                assert info.st_mtime_ns == 978_307_201_000_000_000 + modified_ns
                assert info.st_birthtime == 978_307_200 + birth_ns / 1_000_000_000
            else:
                assert observed == {'state': 'verified', 'bytes': expected.hex()}, observed
            assert (repository/'Note.txt').read_bytes() == (b'foreign' if name == 'collision' else expected)
            retry = invoke('private-projection-create', repository, 'install')
            assert retry == {'state': 'notInstalled', 'reason': 'conflict'}, retry
        assert invoke('private-projection-encoded-read') == after
        assert after['notes'] == (['C', 'untouched'] if name == 'newer-intent' else ['A', 'untouched'])
        print('PASS:', name, flush=True)
    print(f'PASS: {len(cases)} fresh-process creation schedules', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--filesystem', choices=['APFS', 'APFSX', 'HFS+', 'HFSX', 'ExFAT'],
        help='Run the unchanged cases with note roots on a disposable macOS disk image.')
    parser.add_argument('--native-probe', type=Path,
        help='Also run an already-built ProjectionFilesCreateProbe with its complete native assertions.')
    parser.add_argument('--native-crash-probe', type=Path,
        help='Also run an already-built ProjectionFilesCreateProcessProbe with its five process schedules.')
    args = parser.parse_args()
    if args.filesystem is not None and sys.platform != 'darwin':
        parser.error('--filesystem requires macOS hdiutil')
    artifacts = Path(tempfile.mkdtemp(prefix='nv-projection-create-process-')).resolve()
    print('Artifacts:', artifacts, flush=True)
    with repository_volume(artifacts, args.filesystem) as repository_parent:
        run_cases(args.binary.resolve(), artifacts, repository_parent, args.filesystem)
        native = [
            ('native-cases', args.native_probe, 'PASS: projection exclusive creation 36 native scenarios'),
            ('native-crashes', args.native_crash_probe, 'PASS: projection creation 4 abrupt exits and 1 acknowledged companion; exact retry preserves occupied names')]
        for name, probe, expected in native:
            if probe is None:
                continue
            result = subprocess.run([str(probe.resolve()), str(repository_parent/name)],
                capture_output=True, text=True, timeout=30)
            (artifacts/(name + '.log')).write_text(result.stdout + result.stderr)
            assert result.returncode == 0, (result.returncode, result.stderr)
            assert expected in result.stdout
            print(expected, flush=True)


if __name__ == '__main__':
    main()
