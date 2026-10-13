#!/usr/bin/env python3
"""Qualify split native installation effects with independent namespaces and failure cuts."""
import argparse
import errno
import importlib.util
import os
from pathlib import Path
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('immutable_files', ROOT / 'tools/test-storage-immutable-files.py')
NATIVE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NATIVE)


def qualify(binary, artifacts):
    expected = bytes(range(256)) * 16
    input_file = artifacts / 'exact-retry-input'
    input_file.write_bytes(expected)
    serial = 0
    checks = 0

    def fresh():
        nonlocal serial
        serial += 1
        path = artifacts / f'owned-{serial}'
        path.mkdir()
        return path

    def install(root, **kwargs):
        return NATIVE.Install(binary, root, input_file, split=True, **kwargs)

    def complete(root):
        value = install(root).finish()
        assert value['outcome'] == 1, value
        assert (root / NATIVE.RELATIVE).read_bytes() == expected
        assert not list(root.glob('.nv-stage-*')), 'Successful installation left an owned stage'
        return value

    root = fresh()
    operation = install(root)
    persistence = NATIVE.NamespaceLossV1(root)
    value = operation.finish(lambda _, event: persistence.observe(event))
    assert value['outcome'] == 1 and persistence.minimal_final() == expected
    assert (root / NATIVE.RELATIVE).read_bytes() == expected
    assert complete(root)['existing'] == 1
    checks += 1
    print('PASS: split creation/staging/install, exact-existing retry and independent barrier observer')

    for alteration in ['equal-replacement', 'different-replacement', 'same-file-edit']:
        root = fresh()
        operation = install(root)
        changed = False

        def replace_stage(op, event):
            nonlocal changed
            if event['event'] != 'stage-prepared':
                return
            changed = True
            stage = root / op.stage
            if alteration == 'same-file-edit':
                stage.write_bytes(expected + b'changed')
            else:
                stage.rename(root / 'preserved-stage')
                stage.write_bytes(expected if alteration == 'equal-replacement' else b'foreign stage')

        result = operation.finish(replace_stage)
        assert changed and result['outcome'] == 3 and result['error'] == errno.ESTALE, result
        assert result['stage_retained'] == 1
        assert not (root / NATIVE.RELATIVE).exists()
        stage = root / operation.stage
        assert stage.exists(), 'A changed stage must remain available to its owner'
        if alteration != 'same-file-edit':
            assert (root / 'preserved-stage').read_bytes() == expected
        retry = install(root).finish()
        assert retry['outcome'] == 1 and (root / NATIVE.RELATIVE).read_bytes() == expected
        assert stage.exists(), 'Retry consumed a different attempt\'s stage'
        checks += 1
    print('PASS: equal/different stage replacement and same-file editing preserve displaced input and reject installation')

    for alteration in ['metadata-only', 'same-size-edit', 'additional-link', 'unlinked-replacement']:
        root = fresh(); operation = install(root)
        changed = False
        def alter_held_stage(op, event):
            nonlocal changed
            if event['event'] != 'stage-prepared': return
            changed = True
            stage = root/op.stage
            if alteration == 'metadata-only':
                before = stage.stat()
                os.utime(stage, ns=(before.st_atime_ns, before.st_mtime_ns+1_000_000))
            elif alteration == 'same-size-edit': stage.write_bytes(b'X'*len(expected))
            elif alteration == 'additional-link': os.link(stage, root/'preserved-link')
            else:
                original = stage.stat().st_ino
                stage.unlink(); stage.write_bytes(expected)
                assert stage.stat().st_ino != original, 'The held descriptor prevents reuse of its original inode'
        result = operation.finish(alter_held_stage)
        assert changed
        if alteration == 'metadata-only':
            assert result['outcome'] == 1 and (root/NATIVE.RELATIVE).read_bytes() == expected, result
        else:
            assert result['outcome'] == 3 and result['error'] in (errno.ESTALE, errno.EEXIST), result
            assert result['stage_retained'] == 1 and (root/operation.stage).exists()
            assert not (root/NATIVE.RELATIVE).exists(), 'Changed or displaced input cannot become the final object'
        checks += 1
    print('PASS: metadata-only changes retain exact byte verification; equal-size edits, links and unlinked replacements are preserved')

    root = fresh()
    operation = install(root)
    altered = False

    def replace_parent(op, event):
        nonlocal altered
        if event['event'] != 'stage-verified' or not any(e['event'] == 'stage-prepared' for e in op.events):
            return
        parent = (root / NATIVE.RELATIVE).parent
        parent.rename(parent.with_name('preserved-writer'))
        parent.mkdir()
        (parent / 'foreign').write_bytes(b'foreign')
        altered = True

    result = operation.finish(replace_parent)
    assert altered and result['outcome'] == 3 and result['error'] == errno.ESTALE, result
    assert not (root / NATIVE.RELATIVE).exists()
    assert ((root / NATIVE.RELATIVE).parent / 'foreign').read_bytes() == b'foreign'
    checks += 1
    print('PASS: parent replacement after final-path capture prevents installation into the replacement')

    schedules = [('write', 1, errno.EIO), ('write', 1, errno.ENOSPC), ('fsync', 1, errno.EIO),
                 ('fsync', 1, errno.EINTR), ('mkdir', 1, errno.EACCES), ('rename', 1, errno.EIO),
                 ('rename-lost-return', 1, errno.EIO), ('write-short', -1, 0), ('pread-short', -1, 0)]
    if NATIVE.sys.platform == 'darwin':
        schedules += [('fullfsync', 1, errno.EIO), ('fullfsync', 2, errno.EIO)]
    for fault, nth, code in schedules:
        root = fresh()
        result = install(root, fault=fault, nth=nth, code=code).finish()
        final = root / NATIVE.RELATIVE
        assert not final.exists() or final.read_bytes() == expected
        assert result['fault_count'] > 0, (fault, result)
        if fault not in ['write-short', 'pread-short'] and code != errno.EINTR:
            assert result['outcome'] != 1, (fault, result)
        retry = install(root).finish()
        assert retry['outcome'] == 1 and final.read_bytes() == expected, (fault, retry)
        assert input_file.read_bytes() == expected
        checks += 1
    print(f'PASS: {len(schedules)} split-stage I/O, short-transfer, EINTR, space, permission and ambiguous-rename schedules')

    for cut in ['stage-prepared', 'native-rename-succeeded', 'installation-verified']:
        root = fresh()
        operation = install(root)
        while True:
            event = operation.step()
            assert 'event' in event, (cut, event)
            if event['event'] == cut:
                operation.kill()
                break
            operation.release()
        final = root / NATIVE.RELATIVE
        assert not final.exists() or final.read_bytes() == expected
        assert install(root).finish()['outcome'] == 1
        assert final.read_bytes() == expected
        checks += 1
    print('PASS: fresh-process retries after stage completion, actual rename and lost verified completion')
    assert checks == 9 + len(schedules) + 3, checks
    print(f'PASS: {checks} independently observed split-install scenarios')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sanitize', choices=['address,undefined', 'thread'])
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-coordinated-install-'))
    print('Artifacts:', artifacts, flush=True)
    binary = artifacts / 'native-probe'
    NATIVE.compile_probe(binary, sanitize=args.sanitize)
    qualify(binary, artifacts)


if __name__ == '__main__':
    main()
