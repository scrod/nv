#!/usr/bin/env python3
"""Qualify rooted projection reads, creation, replacement and relocation with races and faults."""
import argparse
import base64
import errno
import importlib.util
import json
from pathlib import Path
import plistlib
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def crash_checks(artifacts, flags, sanitize):
    """Restart through fresh descriptors after each interrupted physical boundary."""
    for optimization in ['-O0', '-O2']:
        label = optimization[1:] + '-creation-process'
        binary = artifacts / label
        subprocess.run(flags + [optimization, '-fsanitize=' + sanitize,
                        str(ROOT / 'tests/ProjectionFilesCreateProcessProbe.c'), '-o', str(binary)], check=True)
        result = subprocess.run([str(binary), str(artifacts / (label + '-fixtures'))],
                                capture_output=True, text=True, timeout=30)
        (artifacts / (label + '.log')).write_text(result.stdout + result.stderr)
        assert result.returncode == 0, result.stderr
        assert 'PASS: projection creation 4 abrupt exits and 1 acknowledged companion; exact retry preserves occupied names' in result.stdout
        print('PASS:', label, flush=True)


def creation_checks(artifacts, source, flags, sanitize):
    """Require exact native effects and designated failures for weakened guards."""
    mutations = {
        'create-overwrite': [('destination, RENAME_EXCL)', 'destination, 0)'),
                             ('destination, 1U)', 'destination, 0U)')],
        'create-early-success': [('NV_PROJECTION_EVENT("projection-installed", stage->descriptor);',
                                 'effect->outcome = NV_PROJECTION_INSTALLED; return;')],
        'create-missing-tags': [('projection_check_attribute(fd, NV_PROJECTION_TAGS, metadata->tags)', '0')],
        'create-absent-metadata': [('        value->encoding.present == 1 && value->tags.present == 1 &&\n', '')],
        'create-final-name': [('if (projection_expected(&named, expected)) goto failed;', 'if (0) goto failed;')],
        'create-date-check': [
            ('if (!projection_dates_match(&before, metadata, whole_seconds))', 'if (!projection_dates_match(&before, metadata, whole_seconds) && 0)'),
            ('if (!projection_dates_match(&after, metadata, whole_seconds))', 'if (!projection_dates_match(&after, metadata, whole_seconds) && 0)')],
    }
    original = source.read_text()
    for optimization in ['-O0', '-O2']:
        variants = [('valid-create', source)]
        for name, changes in mutations.items():
            contents = original
            for before, after in changes:
                assert contents.count(before) == 1, name
                contents = contents.replace(before, after)
            candidate = artifacts / (name + '.c')
            candidate.write_text(contents)
            variants.append((name, candidate))
        for name, candidate in variants:
            label = optimization[1:] + '-' + name
            binary = artifacts / label
            subprocess.run(flags + [optimization, '-fsanitize=' + sanitize,
                            '-DNV_PROJECTION_SOURCE="' + str(candidate) + '"',
                            str(ROOT / 'tests/ProjectionFilesCreateProbe.c'), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary), str(artifacts / (label + '-fixtures'))],
                                    capture_output=True, text=True, timeout=30)
            (artifacts / (label + '.log')).write_text(result.stdout + result.stderr)
            if name == 'valid-create':
                assert result.returncode == 0, result.stderr
                assert 'PASS: projection exclusive creation 36 native scenarios' in result.stdout
            else:
                assertion = ('effect.outcome != NV_PROJECTION_STAGED' if name in ['create-missing-tags', 'create-absent-metadata', 'create-date-check']
                             else '(effect.outcome == NV_PROJECTION_INSTALLED) == succeeds')
                assert result.returncode != 0 and assertion in result.stderr, (name, result)
            print('PASS:', label, flush=True)


def foundation_checks(artifacts):
    """Observe namespace choices independently of Foundation's success return."""
    assert platform.system() == 'Darwin', 'Foundation qualification requires macOS'
    for source in ['ProjectionReplacementProbe', 'ProjectionReferenceRaceProbe']:
        subprocess.run(['clang', '-Wall', '-Wextra', '-Werror', '-fblocks',
                        str(ROOT / 'tests' / (source + '.m')), '-framework', 'Foundation',
                        '-o', str(artifacts / source)], check=True)
    for mode in ['default', 'new']:
        for repetition in range(20):
            folder = artifacts / ('metadata-' + mode + '-' + str(repetition))
            folder.mkdir()
            result = subprocess.run([str(artifacts / 'ProjectionReplacementProbe'), str(folder), mode],
                                    capture_output=True, text=True, timeout=30)
            (folder / 'stderr.log').write_text(result.stderr)
            assert result.returncode == 0, (folder, result.stderr)
            (folder / 'result.json').write_text(result.stdout)
            value = json.loads(result.stdout)
            assert value['entered'] and value['replaced'] and value['error'] == 0, value
            assert value['body'] == 'new' and value['backup'] == 'old' and value['stageIdentity'], value
            assert value['rawBody'] == 'new' and value['rawBackup'] == 'old' and value['backupReadError'] == 0, value
            assert (value['encoding'], value['tags'], value['stamp'], value['unrelated']) == (
                'new-encoding', 'new-tags', 'new-stamp', 'unrelated'), value
            assert (value['mtimeSeconds'], value['mtimeNanos']) == (1700000003, 234567890), value
            assert value['readerOld'] > 0 and value['readerNew'] > 0 and value['readerInconsistent'] == 0, value
    for mode in ['file', 'parent', 'path', 'relative', 'file-relative', 'cf-parent']:
        for race in ['leaf', 'root']:
            folder = artifacts / (mode + '-' + race)
            folder.mkdir()
            result = subprocess.run([str(artifacts / 'ProjectionReferenceRaceProbe'), str(folder), mode, race],
                                    capture_output=True, text=True, check=True, timeout=30)
            (folder / 'result.json').write_text(result.stdout)
            value = json.loads(result.stdout)
            assert value['entered'] and value['replaced'] and value['error'] == 0, value
            followed = mode == 'file' or (mode in ['relative', 'file-relative'] and race == 'root')
            expected = ('concurrent', 'new', 'absent', 'old') if followed else ('new', 'old', 'concurrent', 'absent')
            assert tuple(value[k] for k in ['current', 'movedOutside', 'rootBackup', 'outsideBackup']) == expected, value
    print('PASS: 40 Foundation metadata/reader cases and 12 exact reference/race outcomes', flush=True)
    folder = artifacts / 'late-backup-collision'
    folder.mkdir()
    result = subprocess.run([str(artifacts / 'ProjectionReferenceRaceProbe'), str(folder),
                             'file-relative', 'backup'], capture_output=True, text=True, check=True, timeout=30)
    (folder / 'result.json').write_text(result.stdout)
    value = json.loads(result.stdout)
    assert value['entered'] and value['replaced'] and value['error'] == 0, value
    assert tuple(value[k] for k in ['current', 'movedOutside', 'rootBackup', 'outsideBackup']) == (
        'new', 'absent', 'old', 'absent'), value
    print('OBSERVED: Foundation replaces a deliberately injected backup-name occupant; '
          'outside the adopted fresh-random-name assumption', flush=True)


def replacement_checks(artifacts, source, sanitize, filesystems=()):
    """Checks the production adapter and exact rejection sites under real Foundation effects."""
    assert platform.system() == 'Darwin', 'Foundation replacement qualification requires macOS'
    apple = ROOT / 'NVStorage/Sources/CAppleFileAccess/NVAppleProjectionReplacement.m'
    core, adapter = source.read_text(), apple.read_text()
    mutations = {
        'replace-preflight': (source, [('int original = projection_open_previous(owner, destination, expected, previous, previous_count, &held);',
            'int original = openat(owner->directory, destination, O_RDONLY | O_NOFOLLOW);')],
            '(result.installation.outcome == NV_PROJECTION_INSTALLED) == (!before && !uncertain)'),
        'replace-backup-absence': (source, [('if (fstatat(owner->directory, backup, &occupied, AT_SYMLINK_NOFOLLOW) == 0) { errno = EEXIST; goto failed; }',
            'if (fstatat(owner->directory, backup, &occupied, AT_SYMLINK_NOFOLLOW) == 0) { errno = ENOENT; }')],
            '(result.installation.outcome == NV_PROJECTION_INSTALLED) == (!before && !uncertain)'),
        'replace-backup-mismatch': (source, [('equal ? NV_PROJECTION_BACKUP_EXPECTED : NV_PROJECTION_BACKUP_CHANGED',
            'equal ? NV_PROJECTION_BACKUP_EXPECTED : NV_PROJECTION_BACKUP_EXPECTED')],
            'result.backup_comparison == (scenario == LATE_TARGET ? NV_PROJECTION_BACKUP_CHANGED : NV_PROJECTION_BACKUP_EXPECTED)'),
        'replace-backup-name': (source, [('fstatat(owner->directory, backup, &named, AT_SYMLINK_NOFOLLOW) ||\n        projection_expected(&named, result->backup_words)',
            'fstatat(owner->directory, backup, &named, AT_SYMLINK_NOFOLLOW)')],
            '(result.installation.outcome == NV_PROJECTION_INSTALLED) == (!before && !uncertain)'),
        'replace-lost-error': (source, [('if (replacement_error || result->backup_comparison == NV_PROJECTION_BACKUP_UNCHECKED)',
            'if (result->backup_comparison == NV_PROJECTION_BACKUP_UNCHECKED)')],
            '(result.installation.outcome == NV_PROJECTION_INSTALLED) == (!before && !uncertain)'),
        'replace-namespace-anchor': (apple, [('[NSURL fileURLWithPath:name isDirectory:NO relativeToURL:(__bridge NSURL *)root]',
            '[(__bridge NSURL *)root URLByAppendingPathComponent:name]')],
            '(result.installation.outcome == NV_PROJECTION_INSTALLED) == (!before && !uncertain)'),
    }
    flags = ['clang', '-fobjc-arc', '-fblocks', '-g', '-Wall', '-Wextra', '-Werror',
             '-Wconversion', '-Wsign-conversion', '-Wcast-align', '-fno-omit-frame-pointer',
             '-I' + str(source.parent / 'include'), '-I' + str(source.parent), '-I' + str(apple.parent / 'include'),
             '-I' + str(apple.parent)]
    analysis = artifacts / 'apple-replacement-analysis.plist'
    subprocess.run(flags + ['--analyze', str(apple), '-o', str(analysis)], check=True)
    assert not plistlib.loads(analysis.read_bytes())['diagnostics']
    probes = []
    for optimization in ['-O0', '-O2']:
        for name in ['valid-replace'] + list(mutations):
            selected_core, selected_adapter, assertion = source, apple, ''
            if name in mutations:
                target, edits, assertion = mutations[name]
                content = core if target == source else adapter
                for old, new in edits:
                    assert content.count(old) == 1, name
                    content = content.replace(old, new)
                candidate = artifacts / (name + target.suffix)
                candidate.write_text(content)
                if target == source: selected_core = candidate
                else: selected_adapter = candidate
            label = optimization[1:] + '-' + name
            binary = artifacts / label
            subprocess.run(flags + [optimization, '-fsanitize=' + sanitize,
                '-DNV_PROJECTION_SOURCE="' + str(selected_core) + '"',
                '-DNV_APPLE_PROJECTION_SOURCE="' + str(selected_adapter) + '"',
                str(ROOT / 'tests/ProjectionFilesReplaceProbe.m'), '-framework', 'Foundation', '-o', str(binary)], check=True)
            probes.append((label, binary, assertion))
    run_replacement_probes(artifacts, artifacts, probes)
    if filesystems:
        spec = importlib.util.spec_from_file_location('projection_volumes', ROOT / 'tools/test-projection-create-process.py')
        volumes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(volumes)
        for filesystem in filesystems:
            folder = artifacts / ('volume-' + filesystem)
            folder.mkdir()
            with volumes.repository_volume(folder, filesystem) as mounted:
                run_replacement_probes(folder, mounted, probes)


def run_replacement_probes(artifacts, fixture_root, probes):
    """Reuse the same compiled checks on each volume, retaining every designated assertion."""
    for label, binary, assertion in probes:
        result = subprocess.run([str(binary), str(fixture_root / (label + '-fixtures'))],
                                capture_output=True, text=True, timeout=60)
        (artifacts / (label + '.log')).write_text(result.stdout + result.stderr)
        if not assertion:
            assert result.returncode == 0, result.stderr
            assert 'PASS: projection replacement 18 native/Foundation scenarios' in result.stdout
        else:
            assert result.returncode != 0 and assertion in result.stderr, (label, result)
        print('PASS:', label, flush=True)
        if not assertion:
            replacement_process_checks(binary, artifacts, fixture_root, label)


def replacement_process_checks(binary, artifacts, fixture_root, label):
    """Inspect surviving bytes in a fresh process after actual production boundaries exit abruptly."""
    boundaries = ['stage-prepared', 'before-foundation-replace', 'replacement-backup-read',
                  'projection-installed', 'projection-final-check']
    inspect = '''
import ctypes, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
libc = ctypes.CDLL(None, use_errno=True)
attribute = libc.fgetxattr
attribute.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
attribute.restype = ctypes.c_ssize_t
result = {}
for name in ['Note.txt', 'backup', 'other.txt']:
    path = root / name
    if not path.exists():
        result[name] = None
        continue
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        preserved = ctypes.create_string_buffer(64)
        count = attribute(fd, b'org.notationalvelocity.test-unrelated', preserved, 64, 0, 0)
        assert count == 4, (name, count, ctypes.get_errno())
        result[name] = {'bytes': os.read(fd, 128).hex(), 'mode': os.fstat(fd).st_mode & 0o777,
                        'unrelated': preserved.raw[:count].hex()}
    finally:
        os.close(fd)
print(json.dumps(result, sort_keys=True))
'''
    for late in [False, True]:
        for boundary in boundaries if not late else boundaries[2:]:
            name = label + '-crash-' + ('late-' if late else '') + boundary
            case = fixture_root / name
            result = subprocess.run([str(binary), str(case), boundary] + (['late-target'] if late else []),
                                    capture_output=True, text=True, timeout=30)
            (artifacts / (name + '.log')).write_text(result.stdout + result.stderr)
            assert result.returncode == 71, (name, result)
            result = subprocess.run([sys.executable, '-c', inspect, str(case / ('root-5' if late else 'root-0'))],
                                    capture_output=True, text=True, timeout=30)
            assert result.returncode == 0, (name, result.stderr)
            observed = json.loads(result.stdout)
            (artifacts / (name + '.json')).write_text(result.stdout)
            installed = boundary in boundaries[2:]

            def entry(body):
                return {'bytes': body.encode().hex(), 'mode': 0o640, 'unrelated': b'keep'.hex()}

            assert observed == {'Note.txt': entry('new' if installed else 'old'),
                                'backup': entry('concurrent' if late else 'old') if installed else None,
                                'other.txt': entry('old') if late else None}, (name, observed)
            print('PASS:', name, flush=True)


def relocation_checks(artifacts, source, sanitize, filesystems=()):
    """Check original preservation, exact output and public-rename API grants."""
    assert platform.system() == 'Darwin', 'Projection relocation requires the macOS metadata adapter'
    apple = ROOT / 'NVStorage/Sources/CAppleFileAccess/NVAppleProjectionReplacement.m'
    relocation = ('void nv_projection_relocate(', '#ifndef NV_PROJECTION_CLEANUP_UNLINK')
    final = ('static void projection_finish_install(', '/* Installs a stage')
    adapter = ('void NVAppleRelocateProjection(', 'void NVAppleReplaceProjection(')
    outcome = '(result.replacement.installation.outcome==NV_PROJECTION_INSTALLED)==success'
    mutations = {
        'relocate-exclusive': (source, None, [('destination, RENAME_EXCL)', 'destination, 0)')], outcome),
        'relocate-destination': (source, relocation, [('if (projection_expected(&destination_state, expected->words))', 'if (0)')], 'source_moves==0'),
        'relocate-granted-stage': (source, relocation, [('if (fstat(prepared_descriptor, &granted_stage) || projection_expected(&granted_stage, stage->expected)) goto failed;',
            '(void)prepared_descriptor; (void)granted_stage;')], outcome),
        'relocate-stage-after-capture': (source, relocation, [
            ('if (fstat(stage->descriptor, &held) || projection_expected(&held, stage->expected) ||\n        projection_stage_named(stage) || projection_verify_output(stage->descriptor, bytes, count, metadata,\n            stage->whole_seconds, stage->stamp_error, stage->finder_tags_error, &held)) effect->error = errno;',
             'if (0) effect->error = errno;')], 'installed==(physical_output && scenario!=LOST_INSTALL_RETURN)'),
        'relocate-source-metadata': (source, None, [('if (!projection_moved_equal(expected, before))', 'if (0)')], 'source_moves==0'),
        'relocate-restore-overwrite': (source, relocation, [('if (!projection_rename_exclusive(owner->directory, backup, owner->directory, source))',
            'if (!renameat(owner->directory, backup, owner->directory, source))')], 'count==(ssize_t)strlen(body) && !memcmp(bytes,body,(size_t)count)'),
        'relocate-final-name': (source, final, [
            ('held.st_dev != named.st_dev || held.st_ino != named.st_ino || ', ''),
            ('if (projection_expected(&named, expected)) goto failed;', 'if (0) goto failed;')], outcome),
        'relocate-final-metadata': (source, final, [
            ('if (projection_verify_output(stage->descriptor, bytes, count, metadata,\n        stage->whole_seconds, stage->stamp_error, stage->finder_tags_error, &held)) goto failed;',
             '(void)bytes; (void)count; (void)metadata; if (fstat(stage->descriptor, &held)) goto failed;')], outcome),
        'relocate-move-notice': (apple, adapter, [
            ('if (result->replacement.installation.outcome == NV_PROJECTION_INSTALLED)\n                        [coordinator itemAtURL:actualSource didMoveToURL:actualDestination];', '')],
            'coordinator.notices==(NSUInteger)(success || scenario==POST_ACCESSOR_ERROR)'),
    }
    flags = ['clang', '-fobjc-arc', '-fblocks', '-g', '-Wall', '-Wextra', '-Werror',
             '-Wconversion', '-Wsign-conversion', '-Wcast-align', '-fno-omit-frame-pointer',
             '-I' + str(source.parent/'include'), '-I' + str(source.parent),
             '-I' + str(apple.parent/'include'), '-I' + str(apple.parent)]
    analysis = artifacts/'relocation-apple-analysis.plist'
    subprocess.run(flags + ['--analyze', str(apple), '-o', str(analysis)], check=True)
    assert not plistlib.loads(analysis.read_bytes())['diagnostics']
    probes = []
    for optimization in ['-O0', '-O2']:
        for name in ['valid-relocate'] + list(mutations):
            core, bridge, assertion = source, apple, None
            if name in mutations:
                target, scope, changes, assertion = mutations[name]
                text = target.read_text()
                start = text.index(scope[0]) if scope else 0
                end = text.index(scope[1], start) if scope else len(text)
                part = text[start:end]
                for before, after in changes:
                    assert part.count(before) == 1, name
                    part = part.replace(before, after)
                candidate = artifacts/(name + target.suffix)
                candidate.write_text(text[:start] + part + text[end:])
                if target == source: core = candidate
                else: bridge = candidate
            label = optimization[1:] + '-' + name
            binary = artifacts/label
            subprocess.run(flags + [optimization, '-fsanitize=' + sanitize,
                '-DNV_PROJECTION_SOURCE="' + str(core) + '"', '-DNV_APPLE_PROJECTION_SOURCE="' + str(bridge) + '"',
                str(ROOT/'tests/ProjectionFilesRelocateProbe.m'), '-framework', 'Foundation', '-o', str(binary)], check=True)
            probes.append((label, binary, assertion))
    run_relocation_probes(artifacts, artifacts, probes)
    if filesystems:
        spec = importlib.util.spec_from_file_location('projection_volumes', ROOT/'tools/test-projection-create-process.py')
        volumes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(volumes)
        for filesystem in filesystems:
            folder = artifacts/('volume-' + filesystem)
            folder.mkdir()
            with volumes.repository_volume(folder, filesystem) as mounted:
                run_relocation_probes(folder, mounted, probes)


def run_relocation_probes(artifacts, fixture_root, probes):
    """Preserve every companion and designated failure on each selected volume."""
    for label, binary, assertion in probes:
        result = subprocess.run([str(binary), str(fixture_root/(label + '-fixtures'))], capture_output=True, text=True, timeout=60)
        (artifacts/(label + '.log')).write_text(result.stdout + result.stderr)
        if assertion:
            assert result.returncode != 0 and assertion in result.stderr, (label, result.stderr)
        else:
            assert result.returncode == 0 and 'PASS: projection relocation 35 native/Foundation scenarios' in result.stdout, result.stderr
            relocation_process_checks(binary, artifacts, fixture_root, label)
        print('PASS:', label, flush=True)


def relocation_process_checks(binary, artifacts, fixture_root, label):
    """Inspect actual surviving public/backup files in a fresh independent participant."""
    boundaries = ['relocation-before-capture', 'relocation-captured', 'before-exclusive-create',
                  'relocation-after-install', 'relocation-final', 'projection-final-check']
    inspect = '''import ctypes, errno, json, os, sys
from pathlib import Path
root = Path(sys.argv[1])
libc = ctypes.CDLL(None, use_errno=True)
attribute = libc.fgetxattr
attribute.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
attribute.restype = ctypes.c_ssize_t
observed = {}
for name in ['Note.txt', 'Moved.txt', 'backup']:
    path = root/name
    if path.exists():
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        try:
            unrelated = ctypes.create_string_buffer(64)
            count = attribute(fd, b'org.notationalvelocity.test-unrelated', unrelated, 64, 0, 0)
            assert count == 4, (name, count, ctypes.get_errno())
            metadata = []
            for key in [b'com.apple.TextEncoding', b'com.apple.metadata:kMDItemOMUserTags']:
                raw = ctypes.create_string_buffer(64)
                count = attribute(fd, key, raw, 64, 0, 0)
                if count < 0:
                    assert ctypes.get_errno() == errno.ENOATTR, (name, key, ctypes.get_errno())
                    metadata.append(None)
                else: metadata.append(raw.raw[:count].hex())
            observed[name] = {'bytes': os.read(fd, 64).hex(), 'mode': os.fstat(fd).st_mode & 0o777,
                              'unrelated': unrelated.raw[:4].hex(), 'metadata': metadata}
        finally: os.close(fd)
    else: observed[name] = None
print(json.dumps(observed, sort_keys=True))
'''
    for boundary in boundaries:
        name = label + '-crash-' + boundary
        fixture = fixture_root/name
        result = subprocess.run([str(binary), str(fixture), boundary], capture_output=True, text=True, timeout=30)
        (artifacts/(name + '.log')).write_text(result.stdout + result.stderr)
        assert result.returncode == 71 and 'PASS:' not in result.stdout, (name, result.stderr)
        checked = subprocess.run([sys.executable, '-c', inspect, str(fixture/'root-0')], capture_output=True, text=True, timeout=30)
        assert checked.returncode == 0, (name, checked.stderr)
        (artifacts/(name + '.json')).write_text(checked.stdout)
        def value(body, output=False):
            return {'bytes': body.encode().hex(), 'mode': 0o640, 'unrelated': b'keep'.hex(),
                    'metadata': [b'UTF-8;134217984'.hex(), bytes([0,255,17]).hex()] if output else [None,None]}
        captured = boundary != 'relocation-before-capture'
        installed = boundary in boundaries[3:]
        assert json.loads(checked.stdout) == {'Note.txt': None if captured else value('old'),
            'Moved.txt': value('new', True) if installed else None, 'backup': value('old') if captured else None}, (name, checked.stdout)
        print('PASS:', name, flush=True)


def source_checks(artifacts, source, flags, sanitize, filesystems=(), foundation=False):
    """Qualify 33 source scenarios, ten controls and four crash cuts per optimization and volume."""
    original = source.read_text()
    variants = {
        'source-before-bytes': ('if (!projection_moved_equal(expected, before))', 'if (0)'),
        'source-preflight-metadata': ('if (!projection_moved_equal(expected, before))',
            'if (before->count != expected->count || (before->count && memcmp(before->bytes, expected->bytes, (size_t)before->count)))'),
        'source-inode-lease': ('NV_PROJECTION_EVENT("source-before-quarantine", lease);',
            'close(lease); lease = -1; NV_PROJECTION_EVENT("source-before-quarantine", lease);'),
        'source-transfer-lifetime': ('if (retained) { *retained = fd; fd = -1; }',
            'if (retained) { *retained = fd; }'),
        'source-borrowed-identity': ('if (fstat(lease, &pinned) || projection_expected(&pinned, before->words))', 'if (fstat(lease, &pinned))'),
        'source-moved-identity': ('!memcmp(a->words, b->words, 7 * sizeof(uint64_t))',
            'a->words[0] == b->words[0] && !memcmp(a->words + 3, b->words + 3, 4 * sizeof(uint64_t))'),
        'source-moved-tags': ('projection_attribute_equal(a->tags, b->tags)', '1'),
        'source-restore-overwrite': ('NV_PROJECTION_SOURCE_RENAME(owner->directory, recovery, owner->directory, source)',
            'OverwritingRename(owner->directory, recovery, owner->directory, source)'),
        'source-final-artifact': ('if (result->outcome == NV_PROJECTION_SOURCE_CAPTURED &&',
            'if (0 && result->outcome == NV_PROJECTION_SOURCE_CAPTURED &&'),
        'source-unavailable-name': ('else failure = errno;',
            'else { result->source_state = NV_PROJECTION_NAME_ABSENT; failure = errno; }'),
    }
    probes = []
    cases = [('valid-source', None)] + list(variants.items())
    flavors = [('', [])]
    if foundation and platform.system() == 'Darwin':
        flavors.append(('coordinated-', ['-x', 'objective-c', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'CoreFoundation',
            '-I' + str(ROOT/'NVStorage/Sources/CAppleFileAccess/include'),
            '-I' + str(ROOT/'NVStorage/Sources/CAppleFileAccess'), '-DNV_PROJECTION_COORDINATED=1']))
    for flavor, extra in flavors:
        flavor_cases = list(cases)
        if flavor == 'coordinated-':
            flavor_cases += [
                ('source-move-notice', ('if (notify) notify(context, 0, 1);', 'if (0 && notify) notify(context, 0, 1);')),
                ('source-restore-notice', ('if (notify) notify(context, 1, 1);', 'if (0 && notify) notify(context, 1, 1);')),
            ]
        for optimization in ['-O0', '-O2']:
            for name, changes in flavor_cases:
                selected = source
                if changes is not None:
                    before, after = changes
                    content = original
                    if name in ['source-move-notice', 'source-restore-notice']:
                        start = original.index('void nv_projection_quarantine_source(')
                        end = original.index('static int projection_cleanup_name(', start)
                        part = original[start:end]
                        assert part.count(before) == 1, name
                        content = original[:start] + part.replace(before, after) + original[end:]
                    else:
                        assert original.count(before) == 1, name
                        content = original.replace(before, after)
                    selected = artifacts/(name + '.c')
                    selected.write_text(content)
                label = optimization[1:] + '-' + flavor + name
                binary = artifacts/label
                subprocess.run(flags + extra + [optimization, '-fsanitize=' + sanitize,
                    '-DNV_PROJECTION_SOURCE="' + str(selected) + '"',
                    str(ROOT/'tests/ProjectionFilesSourceProbe.c'), '-o', str(binary)], check=True)
                probes.append((label, binary, name))
    run_source_probes(artifacts, artifacts, probes)
    if filesystems:
        spec = importlib.util.spec_from_file_location('source_volumes', ROOT/'tools/test-projection-create-process.py')
        volumes = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(volumes)
        for filesystem in filesystems:
            folder = artifacts/('source-volume-' + filesystem)
            folder.mkdir()
            with volumes.repository_volume(folder, filesystem) as mounted:
                run_source_probes(folder, mounted, probes)


def run_source_probes(artifacts, fixture_root, probes):
    """Run identical native checks and independent crash inspections on each selected volume."""
    for label, binary, name in probes:
        run = subprocess.run([str(binary), str(fixture_root/(label + '-fixtures'))], capture_output=True, text=True, timeout=30)
        (artifacts/(label + '.log')).write_text(run.stdout + run.stderr)
        if name == 'valid-source':
            assert run.returncode == 0 and 'PASS: projection source quarantine 33 native scenarios' in run.stdout, run.stderr
            boundaries = [('source-before-quarantine', 0, b'original', None),
                ('source-quarantined', 0, None, b'original'),
                ('source-before-restore', 3, None, b'concurrent'),
                ('source-final-check', 0, None, b'original')]
            for boundary, case, current, recovery in boundaries:
                fixture = fixture_root/(label + '-crash-' + boundary)
                child = subprocess.run([str(binary), str(fixture), boundary], capture_output=True, text=True, timeout=30)
                (artifacts/(fixture.name + '.log')).write_text(child.stdout + child.stderr)
                assert child.returncode == 71, (boundary, child.stderr)
                root = fixture/f'case-{case}'
                for leaf, expected in [('Note.txt', current), ('recovery', recovery)]:
                    path = root/leaf
                    assert path.read_bytes() == expected if expected is not None else not path.exists(), (boundary, leaf)
                if case == 3:
                    assert (root/'saved.txt').read_bytes() == b'original'
        else:
            intended = ('notified_moves == successful_moves' if name in ['source-move-notice', 'source-restore-notice'] else
                'fcntl(descriptor, F_GETFD) >= 0' if name == 'source-transfer-lifetime' else
                'result.outcome == NV_PROJECTION_SOURCE_RETAINED' if name == 'source-restore-overwrite' else
                'fstat(fd, &pinned) == 0 && S_ISREG(pinned.st_mode)' if name == 'source-inode-lease' else
                'result.outcome == NV_PROJECTION_SOURCE_NO_EFFECT && rename_calls == 0' if name in ['source-before-bytes', 'source-preflight-metadata'] else
                'result.source_state == NV_PROJECTION_NAME_UNAVAILABLE && result.artifact_state == NV_PROJECTION_NAME_PRESENT' if name == 'source-unavailable-name' else
                '(result.outcome == NV_PROJECTION_SOURCE_CAPTURED) == captures')
            assert run.returncode != 0 and intended in run.stderr, (name, run.stderr)
        print('PASS:', label, flush=True)


def cleanup_checks(artifacts, source, flags, sanitize, filesystems=(), foundation=False):
    """Check exact owned-artifact removal and all prior no-effect/uncertain classifications."""
    original = source.read_text()
    controls = {
        'cleanup-content': ('if (!projection_moved_equal(expected, observed))', 'if (0)'),
        'cleanup-metadata': ('if (!projection_moved_equal(expected, observed))',
            'if (observed->count != expected->count || (observed->count && memcmp(observed->bytes, expected->bytes, (size_t)observed->count)))'),
        'cleanup-descriptor': ('if (fstat(descriptor, &held) || projection_expected(&held, observed->words))', 'if (fstat(descriptor, &held))'),
        'cleanup-final-name': ('if (fstatat(owner->directory, artifact, &named, AT_SYMLINK_NOFOLLOW) || projection_expected(&named, observed->words))', 'if (0)'),
        'cleanup-captured-content': ('if (read || !projection_moved_equal(expected, captured))', 'if (read)'),
        'cleanup-directory-owner': ('result->directory_created = 1;', 'result->directory_created = 0;'),
        'cleanup-private-final-name': ('(result->artifact_state != NV_PROJECTION_NAME_ABSENT || result->captured_state != NV_PROJECTION_NAME_ABSENT)',
                                       '(result->artifact_state != NV_PROJECTION_NAME_ABSENT)'),
        'cleanup-root': ('if (nv_root_validate(owner)) {\n        result->root_lost = 1; result->error = errno;\n        if (result->outcome != NV_PROJECTION_CLEANUP_NO_EFFECT)',
                         'if (0) {\n        result->root_lost = 1; result->error = errno;\n        if (result->outcome != NV_PROJECTION_CLEANUP_NO_EFFECT)'),
        'cleanup-unavailable': ('else { result->error = errno; if (result->outcome != NV_PROJECTION_CLEANUP_NO_EFFECT)',
                               'else { result->artifact_state = NV_PROJECTION_NAME_ABSENT; result->error = errno; if (result->outcome != NV_PROJECTION_CLEANUP_NO_EFFECT)'),
    }
    if platform.system() == 'Darwin':
        controls['cleanup-private-acl'] = ('int result = acl_set_fd(directory, empty), saved = errno;',
                                           'int result = 0, saved = errno;')
    probes = []
    flavors = [('', [])]
    if foundation and platform.system() == 'Darwin':
        flavors.append(('coordinated-', ['-x','objective-c','-fobjc-arc','-framework','Foundation','-framework','CoreFoundation',
            '-I' + str(ROOT/'NVStorage/Sources/CAppleFileAccess/include'),
            '-I' + str(ROOT/'NVStorage/Sources/CAppleFileAccess'), '-DNV_PROJECTION_COORDINATED=1']))
    for flavor, extra in flavors:
        selected_controls = [('valid-cleanup',None)] + list(controls.items())
        apple = ROOT/'NVStorage/Sources/CAppleFileAccess/NVAppleProjectionReplacement.m'
        if flavor:
            selected_controls += [
                ('cleanup-coordinate-options', ('options:NSFileCoordinatorWritingForDeleting\n        writingItemAtURL:child', 'options:0\n        writingItemAtURL:child')),
                ('cleanup-accessor-url', ('!NVAppleNamespaceHasRoot((__bridge CFURLRef)actual, root, (__bridge CFStringRef)name)', '![actual isFileURL]')),
                ('cleanup-accessor-destination', ('!NVAppleNamespaceHasRoot((__bridge CFURLRef)to, root, (__bridge CFStringRef)[directory stringByAppendingPathComponent:@"item"])', '![to isFileURL]')),
            ]
        for optimization in ['-O0','-O2']:
            for name, change in selected_controls:
                selected = source; arguments = []
                if change:
                    before, after = change
                    wrapper = name in ['cleanup-coordinate-options','cleanup-accessor-url','cleanup-accessor-destination']
                    text = apple.read_text() if wrapper else original
                    if wrapper:
                        start = text.index('void NVAppleRemoveProjectionSource(')
                        end = text.index('void NVAppleReplaceProjection(', start)
                        selected_text = text[start:end]
                        assert selected_text.count(before) == 1, name
                        text = text[:start] + selected_text.replace(before,after) + text[end:]
                    else:
                        assert text.count(before) == 1, name
                        text = text.replace(before,after)
                    candidate = artifacts/(name+('.m' if wrapper else '.c')); candidate.write_text(text)
                    if wrapper: arguments = ['-DNV_PROJECTION_APPLE_SOURCE="'+str(candidate)+'"']
                    else: selected = candidate
                label = optimization[1:]+'-'+flavor+name; binary=artifacts/label
                subprocess.run(flags+extra+arguments+[optimization,'-fsanitize='+sanitize,
                    '-DNV_PROJECTION_SOURCE="'+str(selected)+'"',str(ROOT/'tests/ProjectionFilesCleanupProbe.c'),'-o',str(binary)],check=True)
                probes.append((label,binary,name))
    run_cleanup_probes(artifacts,artifacts,probes)
    if filesystems:
        spec=importlib.util.spec_from_file_location('cleanup_volumes',ROOT/'tools/test-projection-create-process.py')
        volumes=importlib.util.module_from_spec(spec); spec.loader.exec_module(volumes)
        for filesystem in filesystems:
            folder=artifacts/('cleanup-volume-'+filesystem); folder.mkdir()
            with volumes.repository_volume(folder,filesystem) as mounted: run_cleanup_probes(folder,mounted,probes)


def run_cleanup_probes(artifacts, fixture_root, probes):
    """Inspect preserved bytes independently, including two abrupt physical boundaries."""
    for label,binary,name in probes:
        run=subprocess.run([str(binary),str(fixture_root/(label+'-fixtures'))],capture_output=True,text=True,timeout=30)
        (artifacts/(label+'.log')).write_text(run.stdout+run.stderr)
        if name=='valid-cleanup':
            count = 37 if 'coordinated-' in label else 33
            assert run.returncode==0 and f'PASS: projection owned source cleanup {count} native scenarios' in run.stdout,run.stderr
            for boundary,expected in [('source-cleanup-checked',b'original'),('source-cleanup-captured',b'original'),
                                      ('source-cleanup-private-checked',b'original'),('source-cleanup-unlinked',None)]:
                fixture=fixture_root/(label+'-crash-'+boundary)
                child=subprocess.run([str(binary),str(fixture),boundary],capture_output=True,text=True,timeout=30)
                (artifacts/(fixture.name+'.log')).write_text(child.stdout+child.stderr)
                assert child.returncode==71,(boundary,child.stderr)
                path=fixture/'case-0'/('recovery.cleanup/item' if boundary in ['source-cleanup-captured','source-cleanup-private-checked'] else 'recovery')
                assert path.read_bytes()==expected if expected is not None else not path.exists()
                assert not (fixture/'case-0'/'Note.txt').exists()
        else:
            assertion = ('ContainsBody(root_fd,"modified",3)' if name=='cleanup-captured-content'
                         else 'result.directory_created==owned_directory' if name=='cleanup-directory-owner'
                         else 'acl_get_entry(acl,ACL_FIRST_ENTRY,&entry)==-1 && errno==EINVAL' if name=='cleanup-private-acl'
                         else 'result.artifact_state==NV_PROJECTION_NAME_UNAVAILABLE && result.error==EACCES' if name=='cleanup-unavailable'
                         else 'result.root_lost' if name=='cleanup-root'
                         else 'options==NSFileCoordinatorWritingForDeleting && toOptions==0' if name=='cleanup-coordinate-options'
                         else '(result.outcome==NV_PROJECTION_CLEANUP_UNCERTAIN)==uncertain' if name in ['cleanup-content','cleanup-metadata','cleanup-descriptor','cleanup-final-name']
                         else '(result.outcome==NV_PROJECTION_CLEANUP_REMOVED)==removed')
            assert run.returncode!=0 and assertion in run.stderr,(name,run.stderr)
        print('PASS:',label,flush=True)


def check_presenter_result(value):
    """Check visible bytes and the editor's own subsequent save destination."""
    mode, policy = value['mode'], value['policy']
    before, after = value['editorBeforeSave'], value['editorAfterSave']
    files = lambda key: {name: base64.b64decode(body, validate=True) for name, body in value[key].items()}
    prior, later = files('filesBeforeSave'), files('filesAfterSave')
    if mode.startswith('move-public') and '-foreign-' not in mode:
        assert not before['closed'] and 'requested-delete' not in before['events'], 'public-move-keeps-editor'
    if mode.startswith('relocate') and '-foreign-' not in mode:
        assert not before['closed'] and 'requested-delete' not in before['events'], 'relocate-keeps-editor'
    if not (value['caseAliases'] and mode in ['relocate-case','control-case']):
        assert value['movesDelivered'], 'presenter-move-delivery'
    assert files('foreignFiles') == {}, 'foreign-namespace-preserved'
    if '-foreign-' in mode:
        assert value['outcome'] == 0 and value['error'] == errno.ESTALE, 'foreign-grant-rejected'
        if mode.startswith('delete-direct'): assert value['directoryCreated'] == 0, 'foreign-grant-no-owned-directory'
        assert prior == {'Note.txt': b'old'} and later == {'Note.txt': b'later'}, 'foreign-grant-no-effect'
        assert not before['closed'], 'foreign-grant-editor'
        return
    if mode.startswith('relocate'):
        assert before['dirty'] == ('dirty' if policy == 'dirty' else None), 'relocate-preserves-draft'
        target = 'note.txt' if mode.endswith('-case') else 'Note.html' if mode.endswith('-format') else 'Moved.txt'
        if mode.endswith('-occupied'):
            assert value['outcome'] == 1 and value['error'] == errno.EEXIST, 'relocate-occupied-refusal'
            assert value['moveNotices'] == 0 and before['url'].endswith('/Note.txt'), 'relocate-occupied-source'
            peer = value['destinationEditor']
            assert not peer['closed'] and 'requested-delete' not in peer['events'] and peer['url'].endswith('/Moved.txt'), 'relocate-occupied-peer'
            assert prior == {'Note.txt': b'old', target: b'foreign'} and later == {'Note.txt': b'later', target: b'foreign'}, 'relocate-occupied-preservation'
        else:
            assert value['outcome'] == 2 and value['error'] == 0, 'relocate-output'
            assert value['moveNotices'] == 1, 'relocate-explicit-notice'
            assert value['namesDestinationBefore'] and value['namesDestinationAfter'], 'relocate-current-file-identity'
            if value['caseAliases']:
                assert mode == 'relocate-case' and all(p['url'].endswith(('/note.txt','/Note.txt')) for p in [before,after]), 'relocate-case-alias-url'
            else:
                assert before['events'].count('move') == 1, 'relocate-presenter-notice'
                assert before['url'].endswith('/'+target) and after['url'].endswith('/'+target), 'relocate-final-url'
            assert prior == {target: b'new', 'backup': b'old'} and later == {target: b'later', 'backup': b'old'}, 'relocate-later-save'
    elif mode.startswith('update'):
        assert value['outcome'] == 2 and value['error'] == 0, 'ordinary-output'
        assert prior == {'Note.txt': b'new', 'backup': b'old'}, 'ordinary-retained-input'
        assert not before['closed'] and 'requested-delete' not in before['events'], 'update-keeps-editor'
        assert before['dirty'] == ('dirty' if policy == 'dirty' else None), 'update-preserves-draft'
        assert later == {'Note.txt': b'later', 'backup': b'old'}, 'update-later-save'
    elif mode.startswith('move-public'):
        assert before['dirty'] == ('dirty' if policy == 'dirty' else None), 'public-move-preserves-draft'
        if mode.endswith('-occupied'):
            assert value['outcome'] == 0 and value['error'] == errno.EEXIST, 'public-move-collision'
            assert value['moveNotices'] == 0, 'public-move-collision-no-notice'
            assert before['url'].endswith('/Note.txt'), 'public-move-collision-url'
            assert prior == {'Note.txt': b'old', 'Moved.txt': b'foreign'}, 'public-move-collision-preservation'
            assert later == {'Note.txt': b'later', 'Moved.txt': b'foreign'}, 'public-move-collision-later-save'
        else:
            assert value['outcome'] == 1 and value['error'] == 0, 'public-move-output'
            assert value['moveNotices'] == 1 and before['events'].count('move') == 1, 'public-move-notification'
            assert before['url'].endswith('/Moved.txt') and after['url'].endswith('/Moved.txt'), 'public-move-final-url'
            assert prior == {'Moved.txt': b'old'} and later == {'Moved.txt': b'later'}, 'public-move-later-save'
    elif mode.startswith('delete-direct'):
        assert value['directoryCreated'] == (0 if policy in ['dirty','refuse'] else 1), 'delete-directory-ownership'
        assert value['moveNotices'] == 0, 'delete-keeps-private-paths-private'
        assert before['url'].endswith('/Note.txt') and after['url'].endswith('/Note.txt'), 'delete-editor-url'
        assert 'requested-delete' in before['events'], 'delete-presenter-notified'
        if mode.endswith('-unlink-error'):
            assert value['outcome'] == 2 and value['error'] == errno.EIO, 'delete-failed-removal-uncertain'
            assert prior == {'recovery.cleanup/item': b'old'}, 'delete-failed-removal-retained'
            assert before['closed'] == (policy == 'normal'), 'delete-failed-removal-editor'
            assert later == ({'recovery.cleanup/item': b'old'} if policy == 'normal' else
                             {'recovery.cleanup/item': b'old', 'Note.txt': b'later'}), 'delete-failed-removal-later-save'
        elif policy == 'dirty':
            assert value['outcome'] == 0 and value['error'] == errno.ESTALE, 'delete-rechecks-saved-draft'
            assert prior == later == {'Note.txt': b'dirty'}, 'delete-preserves-saved-draft'
            assert before['closed'], 'delete-dirty-editor-choice'
        elif policy == 'refuse':
            assert value['outcome'] == 0 and value['error'] == errno.ECANCELED, 'delete-refusal'
            assert prior == {'Note.txt': b'old'} and later == {'Note.txt': b'later'}, 'delete-refusal-bytes'
            assert not before['closed'], 'delete-refusal-editor'
        else:
            assert value['outcome'] == 1 and value['error'] == 0 and prior == {}, 'delete-output'
            assert before['closed'] == (policy == 'normal'), 'delete-editor-choice'
            assert later == ({} if policy == 'normal' else {'Note.txt': b'later'}), 'delete-later-save'
    elif mode == 'control-move':
        assert value['outcome'] == 1 and value['error'] == 0, 'control-move-output'
        assert before['url'].endswith('/Moved.txt') and not before['closed'], 'control-move-editor'
        assert prior == {'Moved.txt': b'old'} and later == {'Moved.txt': b'later'}, 'control-move-save'
    elif mode == 'control-case':
        assert value['outcome'] == 1 and value['error'] == 0 and value['moveNotices'] == 1, 'control-case-output'
        assert not before['closed'] and before['dirty'] == ('dirty' if policy == 'dirty' else None), 'control-case-editor'
        assert value['namesDestinationBefore'] and value['namesDestinationAfter'], 'control-case-identity'
        if not value['caseAliases']:
            assert before['events'].count('move') == 1 and before['url'].endswith('/note.txt'), 'control-case-distinct-url'
        assert prior == {'note.txt': b'old'} and later == {'note.txt': b'later'}, 'control-case-save'
    elif mode == 'control-delete':
        assert value['outcome'] == 1 and value['error'] == 0 and prior == {}, 'control-delete-output'
        assert before['closed'] == (policy == 'normal'), 'control-delete-editor'
        assert later == ({} if policy == 'normal' else {'Note.txt': b'later'}), 'control-delete-save'
    else:
        raise AssertionError('unrecognized-presenter-scenario')


def presenter_checks(artifacts, flags, sanitize):
    """Use real protocol participants, exact byte oracles and intent/URL mutations."""
    assert platform.system() == 'Darwin', 'Foundation presenter qualification requires macOS'
    apple = ROOT / 'NVStorage/Sources/CAppleFileAccess/NVAppleProjectionReplacement.m'
    original = apple.read_text()
    ordinary = 'writingItemAtURL:(__bridge NSURL *)requested options:0 error:&error'
    deletion = 'options:NSFileCoordinatorWritingForDeleting\n        writingItemAtURL:child'
    remove = 'nv_projection_remove_source(owner, source, recovery, expected, maximum, descriptor, result);'
    cases = [('update', p) for p in ['normal', 'dirty', 'refuse']]
    cases += [('delete-direct', p) for p in ['normal', 'dirty', 'refuse', 'keep']]
    cases += [('update-path', 'normal'), ('delete-direct-path', 'normal'), ('delete-direct-path', 'keep')]
    cases += [('control-delete', p) for p in ['normal', 'keep']] + [('control-move', 'normal')]
    cases += [('delete-direct-foreign-source', 'keep'), ('delete-direct-foreign-destination', 'keep'),
              ('update-foreign-destination', 'normal')]
    cases += [('delete-direct-unlink-error', p) for p in ['normal', 'keep']]
    cases += [('move-public', p) for p in ['normal', 'dirty', 'refuse', 'keep']]
    cases += [('move-public-path', 'normal'), ('move-public-occupied', 'normal')]
    cases += [('move-public-foreign-source', 'normal'), ('move-public-foreign-destination', 'normal')]
    cases += [('relocate', p) for p in ['normal', 'dirty', 'refuse', 'keep']]
    cases += [(mode, 'normal') for mode in ['relocate-case', 'relocate-format', 'relocate-path', 'relocate-occupied',
                                         'relocate-foreign-source', 'relocate-foreign-destination']]
    cases += [('control-case', p) for p in ['normal', 'dirty']]
    variants = [
        ('valid', None, cases, None),
        ('ordinary-replacement', (ordinary, ordinary.replace('options:0', 'options:NSFileCoordinatorWritingForReplacing')),
         [('update', 'normal')], 'update-keeps-editor'),
        ('delete-move', (deletion, deletion.replace('ForDeleting', 'ForMoving')),
         [('delete-direct', 'normal')], 'delete-presenter-notified'),
        ('delete-private-notice', (remove, remove + '\n            [coordinator itemAtURL:actual willMoveToURL:to];\n            [coordinator itemAtURL:actual didMoveToURL:to];'),
         [('delete-direct', 'keep')], 'delete-keeps-private-paths-private'),
        ('literal-url', ('!NVAppleNamespaceHasRoot((__bridge CFURLRef)to, root, (__bridge CFStringRef)leaf)',
                        '![to isEqual:(__bridge NSURL *)requested]'),
         [('update-path', 'normal')], 'ordinary-output'),
        ('public-move-delete', ('options:NSFileCoordinatorWritingForMoving\n        writingItemAtURL:(__bridge NSURL *)to',
                               'options:NSFileCoordinatorWritingForDeleting\n        writingItemAtURL:(__bridge NSURL *)to'),
         [('move-public', 'normal')], 'public-move-keeps-editor'),
        ('public-move-notice', ('if (completed) [coordinator itemAtURL:oldURL didMoveToURL:newURL];',
                               'if (completed) (void)newURL;'),
         [('move-public', 'normal')], 'public-move-notification'),
        ('relocate-replacing-destination', ('writingItemAtURL:(__bridge NSURL *)to options:0 error:&error byAccessor:^(NSURL *actualSource, NSURL *actualDestination)',
            'writingItemAtURL:(__bridge NSURL *)to options:NSFileCoordinatorWritingForReplacing error:&error byAccessor:^(NSURL *actualSource, NSURL *actualDestination)'),
         [('relocate-case', 'normal')], 'relocate-keeps-editor'),
    ]
    flags = flags + ['-x', 'objective-c', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'CoreFoundation',
                     '-I' + str(apple.parent / 'include'), '-I' + str(apple.parent)]
    for optimization in ['-O0', '-O2']:
        for name, change, scenarios, expected in variants:
            selected = apple
            if change:
                before, after = change
                start = original.index('void NVAppleQuarantineProjection(') if name.startswith('public-move-') else 0
                end = original.index('void NVAppleRemoveProjectionSource(', start) if name.startswith('public-move-') else len(original)
                part = original[start:end]
                assert part.count(before) == 1, name
                selected = artifacts / (name + '.m')
                selected.write_text(original[:start] + part.replace(before, after) + original[end:])
            label = optimization[1:] + '-presenter-' + name
            binary = artifacts / label
            subprocess.run(flags + [optimization, '-fsanitize=' + sanitize,
                '-DNV_APPLE_PROJECTION_SOURCE="' + str(selected) + '"',
                str(ROOT / 'tests/ProjectionFilesPresenterProbe.m'), '-o', str(binary)], check=True)
            for mode, policy in scenarios:
                scenario = label + '-' + mode + '-' + policy
                result = subprocess.run([str(binary), str(artifacts / scenario), mode, policy],
                    capture_output=True, text=True, timeout=30)
                (artifacts / (scenario + '.json')).write_text(result.stdout)
                (artifacts / (scenario + '.stderr')).write_text(result.stderr)
                assert result.returncode == 0, (scenario, result.stderr)
                try:
                    check_presenter_result(json.loads(result.stdout))
                except AssertionError as failure:
                    assert expected and str(failure) == expected, (scenario, str(failure), expected)
                else:
                    assert expected is None, ('mutation escaped', scenario)
                print('PASS:', scenario, 'targeted rejection' if expected else 'exact companion', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', default='address,undefined', choices=['address,undefined', 'thread'])
    parser.add_argument('--only', choices=['all', 'read', 'create', 'crash', 'replace', 'relocate', 'source', 'cleanup', 'presenter', 'foundation'], default='all',
                        help='Select a complete unchanged campaign for targeted qualification reuse.')
    parser.add_argument('--foundation', action='store_true', help='Also run local APFS replacement capability witnesses on macOS.')
    parser.add_argument('--filesystems', nargs='+', choices=['APFS', 'APFSX', 'HFS+', 'HFSX', 'ExFAT'], default=[],
                        help='Reuse the selected mutable-file binaries and all controls on disposable note volumes.')
    args = parser.parse_args()
    if args.filesystems and (platform.system() != 'Darwin' or args.only not in ['all', 'replace', 'relocate', 'source', 'cleanup']):
        parser.error('--filesystems requires the macOS replacement/source campaign')
    artifacts = Path(tempfile.mkdtemp(prefix='nv-projection-files-c-'))
    print('Artifacts:', artifacts, flush=True)
    source = ROOT / 'NVStorage/Sources/CStorageIO/NVProjectionFiles.c'
    flags = ['clang', '-std=c11', '-g', '-Wall', '-Wextra', '-Werror', '-Wconversion',
             '-Wsign-conversion', '-Wcast-align', '-fno-omit-frame-pointer',
             '-I' + str(source.parent / 'include'), '-I' + str(source.parent)]
    subprocess.run(flags + ['--analyze', str(source), '-o', str(artifacts / 'analysis.plist')], check=True)
    assert not plistlib.loads((artifacts / 'analysis.plist').read_bytes())['diagnostics']
    if args.only in ['all', 'read']:
        read_checks(artifacts, source, flags, args.sanitize)
    if args.only in ['all', 'create']:
        creation_checks(artifacts, source, flags, args.sanitize)
    if args.only in ['all', 'crash']:
        crash_checks(artifacts, flags, args.sanitize)
    if args.only in ['all', 'source']:
        source_checks(artifacts, source, flags, args.sanitize, args.filesystems, args.foundation)
    if args.only in ['all', 'cleanup']:
        cleanup_checks(artifacts, source, flags, args.sanitize, args.filesystems, args.foundation)
    if args.only == 'replace' or (args.only == 'all' and platform.system() == 'Darwin'):
        replacement_checks(artifacts, source, args.sanitize, args.filesystems)
    if args.only == 'relocate' or (args.only == 'all' and platform.system() == 'Darwin'):
        relocation_checks(artifacts, source, args.sanitize, args.filesystems)
    if args.only == 'presenter' or (args.only == 'all' and platform.system() == 'Darwin'):
        presenter_checks(artifacts, flags, args.sanitize)
    if args.foundation or args.only == 'foundation':
        foundation_checks(artifacts)


def read_checks(artifacts, source, flags, sanitize):
    mutations = {
        'lost-name-check': ('if (fstatat(directory, leaf, &after, AT_SYMLINK_NOFOLLOW) || projection_expected(&after, expected)) goto done;',
                            '/* targeted negative control: skip named-item verification */'),
        'lost-revision-check': ('memcmp(actual, expected, sizeof(actual))',
                                'memcmp(actual, expected, 5 * sizeof(uint64_t))'),
    }
    original = source.read_text()
    for optimization in ['-O0', '-O2']:
        variants = [('valid', source)]
        for name, (old, new) in mutations.items():
            assert original.count(old) == 1, name
            candidate = artifacts / (name + '.c')
            candidate.write_text(original.replace(old, new))
            variants.append((name, candidate))
        for retaining in [False, True]:
            for name, candidate in variants:
                label = optimization[1:] + ('-retaining-' if retaining else '-') + name
                binary = artifacts / label
                subprocess.run(flags + [optimization, '-fsanitize=' + sanitize,
                               '-DNV_PROJECTION_RETAIN_READ=' + str(int(retaining)),
                               '-DNV_PROJECTION_SOURCE="' + str(candidate) + '"',
                               str(ROOT / 'tests/ProjectionFilesReadProbe.c'), '-o', str(binary)], check=True)
                result = subprocess.run([str(binary), str(artifacts / (label + '-root'))],
                                        capture_output=True, text=True, timeout=30)
                (artifacts / (label + '.log')).write_text(result.stdout + result.stderr)
                if name == 'valid':
                    assert result.returncode == 0, result.stderr
                    assert 'PASS: projection coherent read 15 native assertions/cases' in result.stdout
                else:
                    assert result.returncode != 0 and 'result == expected_result' in result.stderr, result
                print('PASS:', label, flush=True)
if __name__ == '__main__':
    main()
