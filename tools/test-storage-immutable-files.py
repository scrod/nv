#!/usr/bin/env python3
"""Exercise the native immutable installer with independent effects, cuts and loss rules."""
import argparse
import errno
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
RELATIVE = 'NV Data/v1/segments/writer/00000000000000000001-object.nvseg'


def compile_probe(output, source=ROOT, sanitize=None):
    flags = ['clang', '-std=c11', '-g', '-O1', '-Wall', '-Wextra', '-Werror', '-Wconversion',
             '-Wsign-conversion', '-Wcast-align', '-fno-omit-frame-pointer',
             '-I' + str(source/'NVStorage/Sources/CStorageIO/include')]
    if sanitize:
        flags += ['-fsanitize=' + sanitize]
    subprocess.run(flags + [str(source/'tests/RepositoryFilesIOProbe.c'), '-o', str(output)], check=True)


def inventory(root):
    result = {}
    for path in [root, *root.rglob('*')]:
        st = path.lstat()
        result[(st.st_dev, st.st_ino)] = path
    return result


def reply(child):
    ready, _, _ = select.select([child.stdout], [], [], 15)
    assert ready, 'Native effect gate was not reached'
    line = child.stdout.readline()
    assert line, ('Child exited before the intended gate', child.poll())
    return json.loads(line)


class Install:
    def __init__(self, binary, root, input_file, *, fault='', nth=1, code=errno.EIO, trace=True, stage=None, read=False, relative=RELATIVE, split=False):
        self.root = root
        self.stage = stage or '.nv-stage-' + str(uuid.uuid4())
        self.stderr = tempfile.TemporaryFile()
        self.child = subprocess.Popen([str(binary), str(root), str(input_file), relative,
            ('read-trace' if trace else 'read') if read else (('split-trace' if trace else 'split') if split else ('trace' if trace else 'quiet')), fault, str(nth), str(code), self.stage],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr, text=True, bufsize=1)
        self.events = []

    def step(self):
        value = reply(self.child)
        if 'event' in value:
            self.events.append(value)
        return value

    def release(self):
        self.child.stdin.write('\n'); self.child.stdin.flush()

    def finish(self, intervene=None):
        while True:
            value = self.step()
            if 'event' not in value:
                assert self.child.wait(timeout=15) == 0
                self.stderr.seek(0)
                diagnostic = self.stderr.read().decode()
                assert not diagnostic, diagnostic
                assert value['descriptor_delta'] == 0, ('Native operation leaked a descriptor', value)
                self.stderr.close()
                return value
            if intervene:
                intervene(self, value)
            self.release()

    def kill(self):
        self.child.kill(); assert self.child.wait(timeout=15) != 0
        self.stderr.close()


class NamespaceLossV1:
    """Exclusive rename preserves whole-file visibility; unsynced names may disappear.

    A successful directory fsync fixes that directory's current entry map. A file
    fsync fixes its bytes independently. The minimal-survival case drops every
    other new entry. No state from a callback or the expected-input oracle enters
    this model. Later-media damage belongs to a separate test.
    """
    def __init__(self, root, *, always_durable=False):
        self.root = root
        self.fixed_entries = {}
        self.fixed_files = {}
        self.pending_entries = {}
        self.always_durable = always_durable

    def observe(self, event):
        objects = inventory(self.root)
        key = (event['device'], event['inode'])
        path = objects.get(key)
        if path is None:
            return
        if event['event'] not in ['native-fsync', 'native-fullfsync'] and not self.always_durable:
            return
        if event['directory']:
            entries = {p.name: (p.lstat().st_dev, p.lstat().st_ino) for p in path.iterdir()}
            if sys.platform == 'darwin' and not self.always_durable: self.pending_entries[key] = entries
            else: self.fixed_entries[key] = entries
        elif path.is_file():
            if sys.platform != 'darwin' or event['event'] == 'native-fullfsync' or self.always_durable:
                self.fixed_files[key] = path.read_bytes()
            if event['event'] == 'native-fullfsync':
                self.fixed_entries.update(self.pending_entries); self.pending_entries.clear()

    def minimal_final(self):
        st = self.root.stat(); key = (st.st_dev, st.st_ino)
        for component in RELATIVE.split('/'):
            key = self.fixed_entries.get(key, {}).get(component)
            if key is None:
                return None
        return self.fixed_files.get(key)


def qualify(binary, artifacts, *, cuts=True):
    input_file = artifacts/'retry-input'
    expected = bytes(range(256)) * 1024
    input_file.write_bytes(expected)
    serial = 0

    def fresh():
        nonlocal serial
        serial += 1
        root = artifacts/f'root-{serial}'; root.mkdir()
        return root

    def start(root, **kwargs): return Install(binary, root, input_file, **kwargs)
    def exact_or_absent(root):
        final = root/RELATIVE
        assert not final.exists() or final.read_bytes() == expected, 'Independent final visibility observed partial bytes'

    root = fresh(); model = NamespaceLossV1(root); run = start(root)
    def valid_observer(owner, event):
        exact_or_absent(root); model.observe(event)
        if (root/RELATIVE).exists():
            st = (root/RELATIVE).stat()
            assert model.fixed_files.get((st.st_dev, st.st_ino)) == expected, 'Final visibility requires a completed staged-file barrier'
    complete = run.finish(valid_observer)
    assert complete['outcome'] == 1 and complete['existing'] == 0, complete
    assert model.minimal_final() == expected, 'Installation evidence preceded required namespace/file barriers'
    assert sum(e['event'] == 'native-fsync' and e['directory'] for e in run.events) == 5
    assert len(list(root.iterdir())) == 1
    baseline_events = [e['event'] for e in run.events]
    print('PASS: complete-only visibility and actual file/nested-directory barriers', flush=True)

    for unsafe in ['/absolute', '../outside', 'NV Data/../outside', 'NV Data//v1/object',
                   'NV Data/./object', 'NV Data/' + 'x' * 256, 'a/b/c/d/e/f/g']:
        root = fresh()
        result = start(root, relative=unsafe).finish()
        assert result['outcome'] == 2 and result['error'] == errno.EINVAL, (unsafe, result)
        assert not list(root.iterdir()), ('Unsafe spelling created a protocol namespace', unsafe)
    print('PASS: seven raw path violations rejected before namespace effects', flush=True)

    # An equal independently written final has no prior barrier evidence.
    duplicate = fresh(); final = duplicate/RELATIVE; final.parent.mkdir(parents=True); final.write_bytes(expected)
    original_identity = (final.stat().st_dev, final.stat().st_ino)
    model = NamespaceLossV1(duplicate)
    run = start(duplicate); result = run.finish(lambda _, e: model.observe(e))
    assert result['outcome'] == 1 and result['existing'] == 1 and (final.stat().st_dev, final.stat().st_ino) == original_identity, 'Immutable retry must preserve an existing final'
    assert model.minimal_final() == expected, 'Equal-object shortcut omitted durability work'
    assert sum(e['event'] == 'native-fsync' and e['directory'] for e in run.events) == 5
    assert 'name-installed' not in [e['event'] for e in run.events]
    print('PASS: equal unbarriered final requires independent verification and barriers', flush=True)

    for kind in ['different', 'directory', 'symlink', 'hardlink', 'fifo', 'intermediate', 'stage']:
        root = fresh(); final = root/RELATIVE; final.parent.mkdir(parents=True)
        foreign = root/'foreign'; foreign.write_bytes(b'foreign evidence')
        stage = '.nv-stage-' + str(uuid.uuid4())
        if kind == 'different': final.write_bytes(b'foreign evidence')
        elif kind == 'directory': final.mkdir()
        elif kind == 'symlink': final.symlink_to(foreign)
        elif kind == 'hardlink': os.link(foreign, final)
        elif kind == 'fifo': os.mkfifo(final)
        elif kind == 'intermediate':
            final.parent.rename(final.parent.with_name('preserved'))
            final.parent.symlink_to(final.parent.with_name('preserved'))
        else: (root/stage).write_bytes(b'foreign evidence')
        before = {str(p.relative_to(root)): (p.lstat().st_dev, p.lstat().st_ino) for p in root.rglob('*')}
        result = start(root, stage=stage).finish()
        assert result['outcome'] != 1, ('Foreign occupant must never gain installation evidence', kind, result)
        assert foreign.read_bytes() == b'foreign evidence'
        after = {str(p.relative_to(root)): (p.lstat().st_dev, p.lstat().st_ino) for p in root.rglob('*')}
        assert before == after, (kind, 'foreign namespace changed')
    print('PASS: incompatible kinds, symlinks, hardlinks, FIFO and foreign stages preserved', flush=True)

    cases = [(name, 1, code, success) for name, code, success in [
        ('write-short', errno.EIO, True), ('pread-short', errno.EIO, True),
        ('write', errno.EINTR, True), ('pread', errno.EINTR, True), ('fsync', errno.EINTR, True),
        ('write-zero', errno.EIO, False), ('pread-zero', errno.EIO, False),
        ('write', errno.EIO, False), ('write', errno.ENOSPC, False), ('write', errno.EACCES, False),
        ('pread', errno.EIO, False), ('rename', errno.ENOTSUP, False), ('rename-lost-return', errno.EIO, False)]]
    cases += [('mkdir', n, errno.ENOSPC, False) for n in range(1, 5)]
    cases += [('fsync', n, errno.EIO, False) for n in range(1, 9)]
    if sys.platform == 'darwin': cases += [('fullfsync', n, errno.EIO, False) for n in range(1, 4)]
    for name, nth, code, success in cases:
        root = fresh(); run = start(root, fault=name, nth=nth, code=code)
        result = run.finish(lambda _, e: exact_or_absent(root))
        assert result['fault_count'] >= nth, ('fault was not exercised', name, nth, result)
        assert (result['outcome'] == 1) == success, (name, nth, result)
        if name == 'rename-lost-return':
            assert result['outcome'] == 3 and (root/RELATIVE).read_bytes() == expected
        assert start(root).finish()['outcome'] == 1, ('healthy explicit retry', name, nth)
        exact_or_absent(root)
    print(f'PASS: {len(cases)} short/EINTR/zero/I/O/space/access/ambiguous and nested/hardware-barrier schedules with retries', flush=True)

    for race in ['final-winner', 'equal-final-winner', 'compatible-directory-winner',
                 'nested-replacement', 'stage-replacement', 'late-final-replacement', 'root-move']:
        root = fresh(); current = root
        final = root/RELATIVE
        entered = False
        def interfere(owner, event):
            nonlocal entered, current
            if entered:
                return
            if race == 'root-move' and event['event'] == 'stage-created':
                moved = root.with_name(root.name + '-moved'); root.rename(moved); root.mkdir()
                current = moved; entered = True
            elif race == 'compatible-directory-winner' and event['event'] == 'directory-created':
                (root/'NV Data').rename(root/'preserved-created-directory')
                (root/'NV Data').mkdir()
                (root/'NV Data/foreign-marker').write_bytes(b'foreign directory winner'); entered = True
            elif race == 'stage-replacement' and event['event'] == 'stage-created':
                (root/owner.stage).rename(root/'owned-displaced')
                (root/owner.stage).write_bytes(b'foreign evidence'); entered = True
            elif event['event'] == 'stage-verified' and race in ['final-winner', 'equal-final-winner', 'nested-replacement']:
                if race in ['final-winner', 'equal-final-winner']:
                    final.write_bytes(expected if race == 'equal-final-winner' else b'foreign evidence')
                else:
                    final.parent.rename(final.parent.with_name('displaced-writer')); final.parent.mkdir()
                entered = True
            elif race == 'late-final-replacement' and event['event'] == 'final-verified':
                final.rename(final.with_name('displaced-object')); final.write_bytes(b'foreign evidence'); entered = True
        result = start(root).finish(interfere)
        assert entered, ('race gate was not reached', race, result, str(root))
        if race == 'equal-final-winner':
            assert result['outcome'] == 1 and result['existing'] == 1 and final.read_bytes() == expected
        elif race == 'compatible-directory-winner':
            assert result['outcome'] == 1 and final.read_bytes() == expected
            assert (root/'NV Data/foreign-marker').read_bytes() == b'foreign directory winner'
            assert (root/'preserved-created-directory').is_dir()
        elif race == 'root-move':
            assert result['outcome'] == 1 and (current/RELATIVE).read_bytes() == expected and not list(root.iterdir())
        else:
            assert result['outcome'] != 1, (race, result)
            if race in ['final-winner', 'late-final-replacement']: assert final.read_bytes() == b'foreign evidence'
            if race == 'stage-replacement':
                assert result['stage_retained'] == 1 and (root/'owned-displaced').read_bytes() == expected, 'Cleanup must preserve displaced foreign stage'
                assert next(p for p in root.iterdir() if p.name.startswith('.nv-stage-')).read_bytes() == b'foreign evidence'
    print('PASS: equal/contradictory final and compatible directory winners, nested/stage/final replacement and root moves', flush=True)

    # Repeated cleanup failure retains its exact stage and preserves the equal final.
    root = fresh(); final = root/RELATIVE; final.parent.mkdir(parents=True); final.write_bytes(expected)
    result = start(root, fault='cleanup', nth=-1).finish()
    assert result['outcome'] != 1 and result['stage_retained'] == 1 and result['cleanup_error'] == errno.EIO
    assert final.read_bytes() == expected
    assert start(root).finish()['outcome'] == 1
    print('PASS: repeated cleanup failure retains recoverable exact input', flush=True)

    if cuts:
        for cut in range(len(baseline_events)):
            root = fresh(); run = start(root); reached = None
            for n in range(cut + 1):
                reached = run.step()
                assert reached['event'] == baseline_events[n]
                exact_or_absent(root)
                if n < cut: run.release()
            run.kill()
            exact_or_absent(root)
            # A fresh native process sees disk and original sealed retry input, never callback state.
            result = start(root).finish()
            assert result['outcome'] == 1 and (root/RELATIVE).read_bytes() == expected, (cut, reached, result)
        print(f'PASS: {len(baseline_events)} pipe-confirmed process cuts and fresh-process exact retry', flush=True)

        for gate in ['stage-created', 'native-rename-succeeded', 'directory-synced']:
            root = fresh(); run = start(root)
            while True:
                event = run.step()
                assert 'event' in event, ('First recovery cut was not reached', gate)
                if event['event'] == gate: break
                run.release()
            run.kill(); exact_or_absent(root)
            failed = start(root, fault='fsync', nth=2).finish()
            assert failed['outcome'] != 1 and failed['fault_count'] >= 2, failed
            exact_or_absent(root)
            recovery = start(root)
            while True:
                event = recovery.step()
                assert 'event' in event, 'Second recovery cut was not reached'
                if event['event'] == 'final-verified': break
                recovery.release()
            recovery.kill(); exact_or_absent(root)
            assert start(root).finish()['outcome'] == 1
            assert (root/RELATIVE).read_bytes() == input_file.read_bytes() == expected
        print('PASS: three repeated crash/write-failure/crash/retry recovery schedules', flush=True)

    root = fresh(); assert start(root).finish()['outcome'] == 1
    (root/RELATIVE).write_bytes(b'later corruption')
    result = start(root).finish()
    assert result['outcome'] != 1 and (root/RELATIVE).read_bytes() == b'later corruption'
    assert input_file.read_bytes() == expected
    print('PASS: later corruption is preserved and distinguished from original installation', flush=True)

    for fault, code, expected_error in [('', 0, 0), ('pread-short', errno.EIO, 0), ('pread', errno.EINTR, 0),
            ('pread-zero', errno.EIO, errno.ESTALE), ('pread', errno.EIO, errno.EIO)]:
        root = fresh(); final = root/RELATIVE; final.parent.mkdir(parents=True); final.write_bytes(expected)
        result = start(root, read=True, fault=fault, code=code).finish()
        assert result['error'] == expected_error, ('bounded coherent read classification', fault, result)
        if not expected_error: assert bytes.fromhex(result['hex']) == expected
        if fault: assert result['fault_count'] >= 1
    for race in ['safe-save', 'truncate', 'same-vnode', 'root-move']:
        root = fresh(); final = root/RELATIVE; final.parent.mkdir(parents=True); final.write_bytes(expected)
        entered = False
        def read_interference(owner, event):
            nonlocal entered
            desired = 'read-complete' if race == 'truncate' else 'snapshot-captured'
            if entered or event['event'] != desired: return
            entered = True
            if race == 'root-move': root.rename(root.with_name(root.name+'-moved')); root.mkdir()
            elif race == 'safe-save':
                replacement = final.with_name('new-safe-save'); replacement.write_bytes(expected); replacement.replace(final)
            elif race == 'same-vnode': final.write_bytes(b'changed' + expected[7:])
            else:
                with final.open('r+b') as file: file.truncate(1)
        result = start(root, read=True).finish(read_interference)
        assert entered, ('coherent read interference not reached', race)
        if race == 'root-move': assert result['read_status'] == 0 and bytes.fromhex(result['hex']) == expected
        else: assert result['error'] == errno.ESTALE, (race, result)
    root = fresh(); final = root/RELATIVE; final.parent.mkdir(parents=True)
    with final.open('wb') as file: file.truncate(len(expected)+1)
    result = start(root, read=True).finish()
    assert result['error'] == errno.EFBIG and result['fault_count'] == 0
    root = fresh(); result = start(root, read=True).finish()
    assert result['error'] == errno.ENOENT
    root = fresh(); final = root/RELATIVE; final.parent.mkdir(parents=True); final.write_bytes(expected); final.chmod(0)
    try:
        result = start(root, read=True).finish()
        assert result['error'] == errno.EACCES, ('actual permission denial', result)
    finally: final.chmod(0o600)
    print('PASS: bounded coherent reads, short/EINTR/error/truncate/safe-save/permissions and root-move companions', flush=True)
    return baseline_events


def loss_controls():
    # These controls challenge the observer, independently of any production success flag.
    base = Path(tempfile.mkdtemp(prefix='nv-namespace-model-controls-'))
    (base/RELATIVE).parent.mkdir(parents=True); (base/RELATIVE).write_bytes(b'complete')
    root_stat = base.stat(); final_stat = (base/RELATIVE).stat()
    unconstrained = NamespaceLossV1(base)
    assert unconstrained.minimal_final() is None, 'Unsynchronized names must be allowed to disappear'
    defects_caught = []
    for defect in ['always-durable', 'omitted-directory', 'partial-final']:
        try:
            if defect == 'always-durable':
                broken = NamespaceLossV1(base, always_durable=True)
                for path in [base, *base.rglob('*')]:
                    st = path.stat()
                    broken.observe({'event': 'unbarriered', 'device': st.st_dev, 'inode': st.st_ino, 'directory': path.is_dir()})
                assert broken.minimal_final() is None, 'Always-durable observer concealed permitted loss'
            elif defect == 'omitted-directory':
                broken = NamespaceLossV1(base)
                broken.observe({'event': 'native-fsync', 'device': final_stat.st_dev, 'inode': final_stat.st_ino, 'directory': False})
                assert broken.minimal_final() == b'complete', 'Durability assertion catches absent directory barriers'
            else:
                (base/RELATIVE).write_bytes(b'part')
                assert (base/RELATIVE).read_bytes() == b'complete', 'Independent complete-only observer catches visible-final copying'
        except AssertionError:
            defects_caught.append(defect)
    assert defects_caught == ['always-durable', 'omitted-directory', 'partial-final']
    assert root_stat.st_ino > 0
    print('PASS: loss/visibility observer rejects all three designated observer defects', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--sanitize', choices=['address,undefined', 'thread'])
    parser.add_argument('--artifacts-parent', type=Path)
    parser.add_argument('--without-cuts', action='store_true')
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-immutable-files-', dir=args.artifacts_parent))
    print('Artifacts:', artifacts, flush=True)
    binary = args.binary.resolve() if args.binary else artifacts/'native-installer'
    if not args.binary: compile_probe(binary, sanitize=args.sanitize)
    qualify(binary, artifacts, cuts=not args.without_cuts)
    loss_controls()


if __name__ == '__main__':
    main()
