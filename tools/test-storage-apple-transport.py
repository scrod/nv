#!/usr/bin/env python3
"""Signed production-driver exchange, independent local recovery and optional real two-Mac iCloud delivery."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import weakref

ROOT = Path(__file__).resolve().parents[1]
LINE_BUFFERS = weakref.WeakKeyDictionary()


def read_line(stream, timeout=60):
    pending = LINE_BUFFERS.setdefault(stream, bytearray())
    deadline = time.monotonic()+timeout
    with selectors.DefaultSelector() as selector:
        selector.register(stream, selectors.EVENT_READ)
        while b'\n' not in pending:
            assert selector.select(max(0, deadline-time.monotonic())), 'The owned harness did not reach its next boundary'
            chunk = os.read(stream.fileno(), 65536)
            assert chunk, 'The owned harness exited before reporting its next boundary'
            pending.extend(chunk)
    line, _, remainder = pending.partition(b'\n')
    pending[:] = remainder
    return json.loads(line)


def check_line_reader():
    incoming, outgoing = os.pipe()
    try:
        os.write(outgoing, b'{"boundary":1}\n{"boundary":2}\n')
        with os.fdopen(incoming, 'rb') as stream:
            incoming = None
            assert read_line(stream, .1) == {'boundary': 1}
            assert read_line(stream, .1) == {'boundary': 2}
    finally:
        if incoming is not None: os.close(incoming)
        os.close(outgoing)


def sample_owned(pid, config):
    subprocess.run(['/usr/bin/sample', str(pid), '2', '1', '-file', str(config)+'.sample'],
                   stdout=sys.stderr, stderr=sys.stderr, timeout=15)


def make_app(binary, app, plist):
    binary, app, plist = map(Path, (binary, app, plist))
    assert not app.exists(), 'A fresh harness destination is required'
    executable = app/'Contents/MacOS/NVStorageProbe'
    executable.parent.mkdir(parents=True)
    shutil.copy2(binary, executable)
    shutil.copy2(plist, app/'Contents/Info.plist')
    shutil.copytree(binary.parent/'NVStorage_NVStorageRuntime.bundle', app/'Contents/Resources/NVStorage_NVStorageRuntime.bundle')
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True, capture_output=True)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True, capture_output=True)


def relay(config, app):
    config = Path(config)
    values = json.loads(config.read_text())
    for name in ('input', 'output'):
        os.mkfifo(values[name], 0o600)
    incoming = os.fdopen(os.open(values['input'], os.O_RDWR), 'wb', buffering=0)
    outgoing = os.fdopen(os.open(values['output'], os.O_RDWR), 'rb', buffering=0)
    launched = subprocess.Popen(['open', '-n', '-W', app, '--args', values.get('entry_command', 'exchange-driver'), str(config)],
                                stdout=subprocess.DEVNULL, stderr=sys.stderr)
    pid = None
    try:
        initial = read_line(outgoing)
        assert initial['state'] == 'launched'
        pid = initial['pid']
        print(json.dumps(initial), file=sys.stderr, flush=True)
        while initial['state'] != 'running':
            try:
                initial = read_line(outgoing, timeout=values.get('startup_timeout', 60))
            except AssertionError:
                sample_owned(pid, config)
                raise
            print(json.dumps(initial), file=sys.stderr, flush=True)
        print(json.dumps(initial), flush=True)
        for line in sys.stdin:
            incoming.write(line.encode())
            try:
                result = read_line(outgoing)
            except AssertionError:
                sample_owned(pid, config)
                raise
            print(json.dumps(result), flush=True)
            if result.get('state') == 'stopped':
                assert launched.wait(timeout=60) == 0
                pid = None
                break
    finally:
        if pid is not None:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
        incoming.close(); outgoing.close()
        if launched.poll() is None: launched.terminate()


class Host:
    def __init__(self, binary, artifacts, ssh=None):
        self.binary, self.artifacts, self.ssh = Path(binary), artifacts, ssh
        self.trace = []

    def command(self, words):
        words = list(map(str, words))
        return [*self.ssh, shlex.join(words)] if self.ssh else words

    def run(self, words, check=True, timeout=120):
        run = subprocess.run(self.command(words), capture_output=True, text=True, timeout=timeout)
        self.trace.append(dict(command=list(map(str, words)), code=run.returncode, stdout=run.stdout, stderr=run.stderr))
        (self.artifacts/('remote-trace.json' if self.ssh else 'local-trace.json')).write_text(json.dumps(self.trace, indent=2))
        if check: assert run.returncode == 0, self.trace[-1]
        return run

    def probe(self, *words, check=True):
        run = self.run([self.binary, *words], check=check)
        return json.loads(run.stdout) if run.returncode == 0 else None

    def put(self, source, destination):
        if not self.ssh:
            assert Path(source).resolve() == Path(destination).resolve()
            return
        self.run(['mkdir', '-p', Path(destination).parent])
        # Transfers contain harness source/configuration and normal selection inputs.
        subprocess.run(['scp', *self.ssh[1:-1], str(source), f'{self.ssh[-1]}:{destination}'],
                       capture_output=True, check=True, timeout=120)

    def exists(self, path):
        return json.loads(self.run(['python3', '-c', 'import json,os,sys; print(json.dumps(os.path.isdir(sys.argv[1])))', path]).stdout)

    def inspect(self, directory, selection):
        result = self.probe('inspect', directory, selection)
        assert result['integrity'] == [['ok']] and result['foreign_keys'] == []
        oracle = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')], input=json.dumps(result),
                                capture_output=True, text=True, check=True, timeout=120)
        assert json.loads(oracle.stdout)
        for row in result['objects']:
            assert hashlib.sha256(bytes.fromhex(row[4])).hexdigest() == row[0].lower()
        return result


class Driver:
    def __init__(self, host, app, script, case, directory, selection, repository, startup_timeout=60, **configuration):
        invocation = directory.name + '-' + uuid.uuid4().hex
        config = case/(invocation + '-control.json')
        config.write_text(json.dumps(dict(directory=str(directory), selection=str(selection), repository=str(repository),
            input=str(config)+'.input', output=str(config)+'.output', startup_timeout=startup_timeout, **configuration)))
        host.put(config, config)
        self.host, self.config = host, config
        self.process = subprocess.Popen(host.command(['python3', script, '--relay', config, '--app', app]),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=(case/(invocation+'-relay.stderr')).open('w'), text=True)
        self.trace = [read_line(self.process.stdout, timeout=startup_timeout+15)]
        self.path = case/(invocation+'-driver-trace.json')
        self.path.write_text(json.dumps(self.trace, indent=2))

    def call(self, command, **values):
        request = dict(command=command, **values)
        self.process.stdin.write(json.dumps(request)+'\n'); self.process.stdin.flush()
        result = read_line(self.process.stdout)
        self.trace.append(dict(request=request, result=result))
        self.path.write_text(json.dumps(self.trace, indent=2))
        assert result.get('state') != 'failed', result
        return result

    def stop(self):
        assert self.call('stop') == {'state': 'stopped'}
        assert self.process.wait(timeout=60) == 0

    def settle(self, timeout):
        """Waits for current-row catch-up before joining finite transport work for semantic observation."""
        config = json.loads(self.config.read_text())
        eventually(lambda: self.host.probe('inspect', config['directory'], config['selection']),
            current_rows_caught_up, timeout, 'Accepted history materialized before observation')
        self.call('pause-transport')

    def diagnose(self):
        self.host.run(['/usr/bin/sample', str(self.trace[0]['pid']), '2', '1', '-file',
                       str(self.config)+'.sample'], check=False, timeout=15)


def eventually(operation, matches, timeout, label, diagnose=None):
    deadline = time.monotonic() + timeout
    while True:
        result = operation()
        if matches(result): return result
        if time.monotonic() >= deadline:
            if diagnose: diagnose()
            raise AssertionError((label, result))
        time.sleep(0.5)


def locator_path(encoded):
    raw = bytes.fromhex(encoded)
    assert len(raw) == 56
    return f'NV Data/v1/segments/{raw[:16].hex()}/{int.from_bytes(raw[16:24], "big"):020d}-{raw[24:].hex()}.nvseg'


def current_rows_caught_up(report):
    assert report['integrity'] == [['ok']] and report['foreign_keys'] == []
    accepted = [int(row[5]) for row in report['objects'] if row[5] != '']
    assert accepted and len(report['view']) == 1
    return int(report['view'][0][1]) == max(accepted)


def main():
    if not __debug__: raise SystemExit('Qualification requires Python assertions')
    check_line_reader()
    companion = dict(integrity=[['ok']], foreign_keys=[], objects=[['id', 1, '', '', '', '2']], view=[['epoch', '2']])
    assert current_rows_caught_up(companion)
    assert not current_rows_caught_up(dict(companion, view=[['epoch', '1']]))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true', help='Check buffered replies and accepted/current-prefix observation companions.')
    parser.add_argument('--relay', type=Path)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--make-app', nargs=3)
    parser.add_argument('--local-binary', type=Path)
    parser.add_argument('--remote-binary', type=Path)
    parser.add_argument('--ssh-target')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--repository-parent', type=Path)
    parser.add_argument('--timeout', type=int, default=300)
    args = parser.parse_args()
    if args.self_test:
        print('PASS: buffered replies and current-prefix observation companions')
        return
    if args.make_app: make_app(*args.make_app); return
    if args.relay: relay(args.relay, str(args.app)); return
    assert args.local_binary and bool(args.ssh_target) == bool(args.ssh_key)
    assert bool(args.ssh_target) == bool(args.remote_binary)
    if args.ssh_target: assert args.repository_parent, 'Live-provider tests require an explicitly selected fixture parent'
    artifacts = Path(tempfile.mkdtemp(prefix='nv-p54-apple-transport-', dir='/tmp'))
    print('Artifacts:', artifacts, flush=True)
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', args.ssh_target] if args.ssh_target else None
    local, remote = Host(args.local_binary.resolve(), artifacts), Host(args.remote_binary or args.local_binary.resolve(), artifacts, ssh)
    script = artifacts/'transport-driver.py'
    shutil.copy2(__file__, script)
    remote.put(script, script)
    plist = artifacts/'Info.plist'
    shutil.copy2(ROOT/'tests/NVStorageContract-Info.plist', plist); remote.put(plist, plist)
    apps = [artifacts/'Local.app', artifacts/'Remote.app']
    for host, app in zip((local, remote), apps):
        host.run(['python3', script, '--make-app', host.binary, app, plist])
    repository = (args.repository_parent or artifacts)/('P54-'+uuid.uuid4().hex)
    repository.mkdir()
    results = []
    for profile in ('public', 'encrypted'):
        case = artifacts/profile; case.mkdir()
        left, right = case/'left', case/'right'
        left_selection, right_selection = case/'left.json', case/'right.json'
        selected = local.probe('create', left, profile, left_selection)
        right_selection.write_text(json.dumps(dict(selected, store=list(uuid.uuid4().bytes))))
        remote.put(right_selection, right_selection)
        initial = local.inspect(left, left_selection)
        root_row = next(row for row in initial['objects'] if row[1] == '2')
        encoded = bytes.fromhex(root_row[4])
        root_locator = (encoded[48:72] + hashlib.sha256(encoded).digest()).hex()
        root = repository/profile; root.mkdir()
        peer_root = root
        if not ssh:
            peer_root = repository/(profile+'-peer'); peer_root.mkdir()
        def delivery(operation):
            if not ssh:
                for origin, destination in ((root, peer_root), (peer_root, root)):
                    for file in origin.rglob('*'):
                        relative = file.relative_to(origin)
                        if relative.parts[0] != 'NV Data' or not file.is_file(): continue
                        target = destination/relative
                        if not target.exists():
                            target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(file, target)
            return operation()
        source = Driver(local, apps[0], script, case, left, left_selection, root, args.timeout)
        eventually(lambda: delivery(lambda: remote.exists(peer_root)), bool, args.timeout, 'Provider directory visibility')
        bootstrap_mode = 'create'
        diagnostic_due = 0
        def bootstrap():
            nonlocal bootstrap_mode, diagnostic_due
            if time.monotonic() >= diagnostic_due:
                status = source.call('state')
                assert not status['publication'].startswith('paused('), ('Source publication paused', status)
                diagnostic_due = time.monotonic()+10
            result = delivery(lambda: remote.probe('exchange-bootstrap', right, right_selection, peer_root, root_locator, bootstrap_mode, check=False))
            bootstrap_mode = 'resume'
            return result
        joined = eventually(bootstrap, lambda result: result is not None, args.timeout, 'Selected bootstrap closure')
        assert sorted(note['body'] for note in joined['notes']) == ['A', 'untouched']
        peer = Driver(remote, apps[1], script, case, right, right_selection, peer_root, args.timeout)
        expected_bytes = {}
        def remember(receipt):
            if 'object' in receipt:
                expected_bytes[bytes.fromhex(receipt['object'])[24:].hex()] = receipt['envelope']
            return receipt
        marker = 'P54 synthetic secret '+uuid.uuid4().hex
        first = remember(source.call('put', body=marker))
        creation = remember(source.call('create', birth=3, body='new left note'))
        eventually(lambda: delivery(lambda: peer.call('accepted')), lambda result:
            locator_path(creation['object']) in result['paths'], args.timeout, 'Automatic left-to-right acceptance')
        peer.settle(args.timeout)
        state = peer.call('state')
        assert sorted(note['body'] for note in state['notes']) == sorted([marker, 'new left note', 'untouched'])
        peer.call('resume-transport')
        remember(peer.call('put', body='right saved edit'))
        removal = remember(peer.call('delete', birth=2))
        eventually(lambda: delivery(lambda: source.call('accepted')), lambda result:
            locator_path(removal['object']) in result['paths'], args.timeout, 'Automatic right-to-left edit/Delete acceptance',
            diagnose=lambda: print('Publication source at deadline:', peer.call('state'), flush=True))
        source.settle(args.timeout)
        assert sorted(note['body'] for note in source.call('state')['notes']) == ['new left note', 'right saved edit']
        source.call('resume-transport')
        root1, root2 = source.call('snapshot-save'), source.call('snapshot-save')
        eventually(lambda: delivery(lambda: peer.call('accepted')), lambda result: locator_path(root2['root']) in result['paths'], args.timeout, 'Snapshot and retention-parent acceptance')
        for driver in (source, peer): driver.settle(args.timeout)
        a = remember(source.call('put', body='left overlapping edit'))
        b = remember(peer.call('put', body='right overlapping edit'))
        for driver in (source, peer): driver.call('resume-transport')
        for driver, receipt in ((source, b), (peer, a)):
            eventually(lambda: delivery(lambda: driver.call('accepted')), lambda result: locator_path(receipt['object']) in result['paths'], args.timeout, 'Concurrent branch acceptance')
        for driver in (source, peer): driver.settle(args.timeout)
        left_conflicts, right_conflicts = source.call('conflicts'), peer.call('conflicts')
        assert left_conflicts == right_conflicts and len(left_conflicts['heads']) == 2 and left_conflicts['alternatives']
        assert source.call('state')['notes'] == peer.call('state')['notes']
        deletion = remember(source.call('delete', birth=3))
        overlap = remember(peer.call('put', birth=3, body='preserved overlapping deletion'))
        for driver in (source, peer): driver.call('resume-transport')
        for driver, receipt in ((source, overlap), (peer, deletion)):
            eventually(lambda: delivery(lambda: driver.call('accepted')), lambda result: locator_path(receipt['object']) in result['paths'], args.timeout, 'Delete/edit history acceptance')
        for driver in (source, peer): driver.settle(args.timeout)
        for driver in (source, peer):
            state = driver.call('state')
            assert '03'*16 not in [note['birth'] for note in state['notes']]
            assert 'preserved overlapping deletion' in [note['body'] for note in state['notes']]
        capabilities = [driver.call('provider') for driver in (source, peer)]
        selected_status = source.call('availability', relative=locator_path(first['object']))
        final_states = [driver.call('state') for driver in (source, peer)]
        candidates = [driver.call('undo-candidates') for driver in (source, peer)]
        assert final_states[0]['notes'] == final_states[1]['notes'] and candidates[0] == candidates[1]
        source.stop(); peer.stop()
        inventories = [host.inspect(directory, selection) for host, directory, selection in
            ((local, left, left_selection), (remote, right, right_selection))]
        for inventory in inventories:
            objects = {row[0].lower(): row[4] for row in inventory['objects']}
            for identity, envelope in expected_bytes.items(): assert objects[identity].lower() == envelope.lower()
            for encoded_root in (root1['root'], root2['root']): assert bytes.fromhex(encoded_root)[24:].hex() in objects
        assert {row[0] for row in inventories[0]['objects'] if row[5]} == {row[0] for row in inventories[1]['objects'] if row[5]}
        assert {row[0] for row in inventories[0]['operations']} == {row[0] for row in inventories[1]['operations']}
        assert {row[0] for row in inventories[0]['actions']} == {row[0] for row in inventories[1]['actions']}
        reopened = [host.probe('dump', directory, selection) for host, directory, selection in
            ((local, left, left_selection), (remote, right, right_selection))]
        for result, expected in zip(reopened, final_states):
            assert result['notes'] == expected['notes'] and result['context'] == expected['context']
        if profile == 'encrypted':
            assert all(marker.encode() not in file.read_bytes() for file in root.rglob('*') if file.is_file())
        results.append(dict(profile=profile, provider=capabilities, selected=selected_status,
            objects=len(inventories[0]['objects']), conflict_heads=left_conflicts['heads'], undo=candidates))
        (artifacts/'results.json').write_text(json.dumps(dict(results=results, repository=str(repository),
            live_provider=bool(ssh), signed='ad-hoc', launch='LaunchServices',
            unqualified=['account full/offline induction', 'physical power loss', 'production distribution signing']), indent=2))
        print('PASS:', profile, 'signed automatic bidirectional delivery, snapshots, conflicts, Delete/edit, exact retention and fresh reopen', flush=True)
    assert len(results) == 2


if __name__ == '__main__': main()
