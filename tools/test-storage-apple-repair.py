#!/usr/bin/env python3
"""Signed repair/Save As consumers with causal history and independent two-store reconstruction."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('transport_harness', ROOT/'tools/test-storage-apple-transport.py')
HARNESS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(HARNESS)


def retained(report):
    result = {}
    for row in report['objects']:
        identity, encoded = row[0].lower(), bytes.fromhex(row[4])
        assert hashlib.sha256(encoded).hexdigest() == identity
        assert row[1] == '0' or row[5] != '', ('Required object remains unaccepted', identity)
        assert identity not in result
        result[identity] = encoded
    assert result, 'The test must retain history'
    return result


def accepted(report, identity):
    assert report['integrity'] == [['ok']] and report['foreign_keys'] == []
    rows = [row for row in report['objects'] if row[0].lower() == identity]
    assert len(rows) <= 1
    if not rows: return False
    row = rows[0]
    assert hashlib.sha256(bytes.fromhex(row[4])).hexdigest() == identity
    return row[5] != ''


def canonical(identity, encoded):
    if encoded[:8] == b'NVKEY1\r\n':
        return f'NV Data/v1/keys/{identity}.nvkey'
    assert encoded[:8] == b'NVSEG1\r\n'
    return HARNESS.locator_path((encoded[48:72] + bytes.fromhex(identity)).hex())


def check_history(expected, actual):
    found = retained(actual)
    assert all(found.get(identity) == encoded for identity, encoded in expected.items())
    return found


def check_notes(state, expected):
    rows = state['notes']
    actual = {row['birth']: row['body'] for row in rows}
    assert len(actual) == len(rows) and actual == expected, (actual, expected)


def check_copy(report, expected, damaged):
    assert report['unmet'] == [] and report['completeInventory'] is False, report
    assert [issue['path'] for issue in report['issues']] == [damaged], report
    files = {row['path']: row['sha256'] for row in report['files']}
    assert len(files) == len(report['files'])
    for identity, encoded in expected.items():
        assert files.get(canonical(identity, encoded)) == identity, (identity, files)


def check_oracles():
    body = b'NVKEY1\r\nsynthetic oracle input'
    identity = hashlib.sha256(body).hexdigest()
    row = [identity, '0', '', '', body.hex(), '1']
    expected = retained({'objects': [row]})
    check_history(expected, {'objects': [row]})
    live_report = dict(integrity=[['ok']], foreign_keys=[], objects=[row])
    assert accepted(live_report, identity)
    assert not accepted(dict(live_report, objects=[row[:5] + ['']]), identity)
    assert not accepted(dict(live_report, objects=[]), identity)
    state = {'notes': [{'birth': '01'*16, 'body': 'expected'}]}
    check_notes(state, {'01'*16: 'expected'})
    report = dict(unmet=[], completeInventory=False, issues=[dict(path='damaged')],
                  files=[dict(path=canonical(identity, body), sha256=identity)])
    check_copy(report, expected, 'damaged')
    challenges = [
        lambda: check_history(expected, {'objects': []}),
        lambda: check_history(expected, {'objects': [row[:4] + ['00', '1']]}),
        lambda: check_history(expected, {'objects': [[identity, '1', '', '', body.hex(), '']]}),
        lambda: check_notes(state, {'01'*16: 'lost edit'}),
        lambda: check_copy(dict(report, issues=[]), expected, 'damaged'),
        lambda: check_copy(dict(report, files=[]), expected, 'damaged'),
    ]
    for challenge in challenges:
        try: challenge()
        except AssertionError: pass
        else: raise AssertionError('The qualification oracle accepted its negative control')
    print('PASS: exact history, accepted membership, independent notes and copy-report controls', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--local-binary', type=Path)
    parser.add_argument('--remote-binary', type=Path)
    parser.add_argument('--ssh-target')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--repository-parent', type=Path)
    parser.add_argument('--timeout', type=int, default=300)
    args = parser.parse_args()
    check_oracles()
    if args.self_test: return
    assert args.local_binary and bool(args.ssh_target) == bool(args.ssh_key) == bool(args.remote_binary)
    if args.ssh_target:
        assert args.repository_parent and args.repository_parent.is_absolute(), 'Live tests require an authorized synthetic parent'
    artifacts = Path(tempfile.mkdtemp(prefix='nv-p56-apple-repair-', dir='/tmp'))
    print('Artifacts:', artifacts, flush=True)
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', args.ssh_target] if args.ssh_target else None
    hosts = []
    for name, binary, connection in [('local', args.local_binary.resolve(), None),
                                     ('remote', args.remote_binary or args.local_binary.resolve(), ssh)]:
        traces = artifacts/name; traces.mkdir()
        hosts.append(HARNESS.Host(binary, traces, connection))
    local, remote = hosts
    script, plist = artifacts/'relay.py', artifacts/'Info.plist'
    shutil.copy2(ROOT/'tools/test-storage-apple-transport.py', script); remote.put(script, script)
    shutil.copy2(ROOT/'tests/NVStorageContract-Info.plist', plist); remote.put(plist, plist)
    apps = [artifacts/'Local.app', artifacts/'Remote.app']
    for host, app in zip(hosts, apps):
        host.run(['python3', script, '--make-app', host.binary, app, plist])
    repository = (args.repository_parent or artifacts)/('P56-'+uuid.uuid4().hex)
    repository.mkdir()
    live, results = [], []

    def stop(driver):
        driver.stop(); live.remove(driver)

    def exists(host, path):
        return json.loads(host.run(['python3', '-c',
            'import json,os,stat,sys\n'
            'try: present=stat.S_ISREG(os.stat(sys.argv[1]).st_mode)\n'
            'except FileNotFoundError: present=False\n'
            'print(json.dumps(present))', path]).stdout)

    try:
        for profile in ('public', 'encrypted'):
            case = artifacts/profile; case.mkdir()
            left, right = case/'left', case/'right'
            left_selection, right_selection = case/'left.json', case/'right.json'
            root = repository/profile; root.mkdir()
            (root/'foreign.txt').write_bytes(b'preserved unrelated input')
            peer_root = root if ssh else repository/(profile+'-peer')
            if not ssh: peer_root.mkdir()

            def delivery(origin, destination, operation):
                # Only the local companion simulates delivery; live runs observe the provider.
                if not ssh:
                    for file in (origin/'NV Data').rglob('*'):
                        if not file.is_file(): continue
                        target = destination/file.relative_to(origin)
                        if not target.exists():
                            target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(file, target)
                return operation()

            def controller(host, app, directory, selection, target, **configuration):
                driver = HARNESS.Driver(host, app, script, case, directory, selection, target, args.timeout,
                    entry_command='startup-controller', **configuration)
                live.append(driver)
                return driver

            def wait_notes(driver, expected, origin=None, destination=None):
                def observe():
                    return delivery(origin, destination, lambda: driver.call('state')) if origin else driver.call('state')
                state = HARNESS.eventually(observe, lambda s: {n['birth']: n['body'] for n in s.get('notes', [])} == expected,
                                          args.timeout, 'Exact expected current notes', diagnose=driver.diagnose)
                check_notes(state, expected)
                return state

            def published(driver):
                return HARNESS.eventually(lambda: driver.call('transport-status'), lambda s: s.get('publication') == 'idle',
                                          args.timeout, 'Local publication completion', diagnose=driver.diagnose)

            def semantic(host, directory, selection, **request):
                path = case/('action-'+uuid.uuid4().hex+'.json')
                path.write_text(json.dumps(request)); host.put(path, path)
                result = host.probe('semantic', directory, selection, path)
                assert result['initial'] == 'accepted', result
                return result

            source = controller(local, apps[0], left, left_selection, root, mode='create', profile=profile, intent='existing')
            wait_notes(source, {'01'*16: 'initial', '02'*16: 'untouched'}); published(source)
            initial = local.inspect(left, left_selection)
            initial_bytes = retained(initial)
            root_row = next(row for row in initial['objects'] if row[1] == '2')
            encoded = bytes.fromhex(root_row[4])
            snapshot = (encoded[48:72] + hashlib.sha256(encoded).digest()).hex()
            selected = json.loads(left_selection.read_text())

            def bootstrap(directory, selection, origin, destination, expected_bytes):
                selection.write_text(json.dumps(dict(selected, store=list(uuid.uuid4().bytes))))
                remote.put(selection, selection)
                names = [canonical(identity, data) for identity, data in expected_bytes.items()]
                HARNESS.eventually(lambda: delivery(origin, destination,
                    lambda: all(exists(remote, destination/name) for name in names)), bool,
                    args.timeout, 'Exact provider names visible on receiving Mac')
                joined = controller(remote, apps[1], directory, selection, destination, mode='bootstrap', snapshot=snapshot)
                HARNESS.eventually(lambda: joined.call('discover'), lambda s: s['passEnded'], args.timeout, 'Selected initial intake')
                preview = joined.call('preview'); assert preview['readOnly'] is True
                joined.call('complete')
                return joined

            peer = bootstrap(right, right_selection, root, peer_root, initial_bytes)
            wait_notes(peer, {'01'*16: 'initial', '02'*16: 'untouched'})
            marker = 'P56 synthetic secret '+uuid.uuid4().hex
            source.call('put', body=marker)
            wait_notes(peer, {'01'*16: marker, '02'*16: 'untouched'}, root, peer_root)
            stop(source)
            undone = semantic(local, left, left_selection, kind='undo')
            check_notes(local.probe('dump', left, left_selection), {'01'*16: 'initial', '02'*16: 'untouched'})
            redone = semantic(local, left, left_selection, kind='redo')
            source = controller(local, apps[0], left, left_selection, root, mode='open'); source.call('state'); published(source)
            # Exact accepted bytes establish delivery even when Undo/Redo leaves Current unchanged.
            for action in (undone, redone):
                identity = hashlib.sha256(bytes.fromhex(action['envelope'])).hexdigest()
                HARNESS.eventually(lambda: delivery(root, peer_root, lambda: remote.probe('inspect', right, right_selection)),
                    lambda s: accepted(s, identity), args.timeout, 'Compensation accepted on receiving Mac')
            stop(source)
            deletion = peer.call('delete', birth=1)
            published(peer); stop(peer)
            restored = semantic(remote, right, right_selection, kind='restore', source='01'*16, birth='03'*16)
            peer = controller(remote, apps[1], right, right_selection, peer_root, mode='open'); peer.call('state'); published(peer)
            source = controller(local, apps[0], left, left_selection, root, mode='open')
            expected = {'02'*16: 'untouched', '03'*16: marker}
            wait_notes(source, expected, peer_root, root)
            stop(peer); stop(source)
            before = local.inspect(left, left_selection); exact = retained(before)
            assert bytes.fromhex(deletion['object'])[24:].hex() in exact
            assert hashlib.sha256(bytes.fromhex(restored['envelope'])).hexdigest() in exact
            assert local.probe('recently-deleted', left, left_selection) == []

            # Preserve the complete synthetic namespace before exercising add-only reconstruction.
            preserved = repository/(profile+'-preserved-NV-Data')
            (root/'NV Data').rename(preserved)
            source = controller(local, apps[0], left, left_selection, root, mode='open')
            wait_notes(source, expected)
            repaired = HARNESS.eventually(lambda: source.call('state'), lambda s: s['repair'].startswith('complete('),
                args.timeout, 'Automatic complete missing-repository repair', diagnose=source.diagnose)
            assert repaired['decision'] == 'editable' and 'recovery' not in repaired
            stop(source)
            for identity, data in exact.items():
                name = canonical(identity, data)
                assert (root/name).read_bytes() == data
                assert (preserved/Path(name).relative_to('NV Data')).read_bytes() == data

            damaged_name = canonical(root_row[0].lower(), encoded)
            damaged = root/damaged_name
            damaged.write_bytes(b'preserved P56 damaged entry')
            damaged_inode = damaged.stat().st_ino
            source = controller(local, apps[0], left, left_selection, root, mode='open')
            wait_notes(source, expected)
            HARNESS.eventually(lambda: source.call('state'), lambda s: s.get('recovery') == 'preserveRepositoryCollision',
                args.timeout, 'Occupied damage offers Save As', diagnose=source.diagnose)
            new_body = marker+' after damage'
            saved = source.call('put', birth=3, body=new_body)
            expected = {'02'*16: 'untouched', '03'*16: new_body}
            wait_notes(source, expected)
            saved_history = retained(local.inspect(left, left_selection))
            assert bytes.fromhex(saved['object'])[24:].hex() in saved_history
            old_selection = left_selection.read_bytes()
            copy_only = repository/(profile+'-copy-only')
            check_copy(source.call('copy', repository=str(copy_only)), saved_history, damaged_name)
            assert left_selection.read_bytes() == old_selection
            selector = case/'selector'; selector.mkdir()
            for attempt in range(3):
                target, successor = repository/f'{profile}-switched-{attempt}', case/f'successor-{attempt}'
                switched = source.call('switch', repository=str(target), privateDirectory=str(successor), selectionDirectory=str(selector))
                if switched['outcome'] == 'opened': break
                assert switched['outcome'] == 'source-retained' and switched['cause'] in ('staleCapture', 'busy'), switched
                assert left_selection.read_bytes() == old_selection
                wait_notes(source, expected)
            else: raise AssertionError('Switch failed to progress after finite interference')
            check_copy(switched['copy'], saved_history, damaged_name)
            check_notes(switched['current'], expected)
            assert switched['store'] != bytes(selected['store']).hex()
            stop(source)
            assert damaged.read_bytes() == b'preserved P56 damaged entry' and damaged.stat().st_ino == damaged_inode
            assert (root/'foreign.txt').read_bytes() == (target/'foreign.txt').read_bytes() == b'preserved unrelated input'
            check_history(saved_history, local.inspect(successor, left_selection))
            assert (selector/'Selected Store').read_bytes()[26:42].hex() == switched['store']

            # Fresh peer storage receives history solely through the new provider repository.
            peer_copy = target if ssh else repository/(profile+'-copy-peer')
            if not ssh: peer_copy.mkdir()
            recovered, recovered_selection = case/'recovered', case/'recovered.json'
            peer = bootstrap(recovered, recovered_selection, target, peer_copy, saved_history)
            wait_notes(peer, expected, target, peer_copy); stop(peer)
            check_history(saved_history, remote.inspect(recovered, recovered_selection))
            assert remote.probe('recently-deleted', recovered, recovered_selection) == []
            undone = semantic(remote, recovered, recovered_selection, kind='undo', birth='03'*16)
            check_notes(remote.probe('dump', recovered, recovered_selection), {'02'*16: 'untouched', '03'*16: marker})
            redone = semantic(remote, recovered, recovered_selection, kind='redo', birth='03'*16)
            peer = controller(remote, apps[1], recovered, recovered_selection, peer_copy, mode='open'); peer.call('state'); published(peer)
            source = controller(local, apps[0], successor, left_selection, target, mode='open')
            wait_notes(source, expected, peer_copy, target)
            for action in (undone, redone):
                identity = hashlib.sha256(bytes.fromhex(action['envelope'])).hexdigest()
                HARNESS.eventually(lambda: delivery(peer_copy, target, lambda: local.probe('inspect', successor, left_selection)),
                    lambda s: accepted(s, identity), args.timeout, 'Post-switch compensation accepted by original Mac')
            stop(peer); stop(source)
            observations = []
            for host, directory, selection in [(local, successor, left_selection), (remote, recovered, recovered_selection)]:
                inspected = host.inspect(directory, selection)
                check_history(saved_history, inspected)
                check_notes(host.probe('dump', directory, selection), expected)
                observations.append(retained(inspected))
            assert observations[0] == observations[1]
            if profile == 'encrypted':
                for destination in (copy_only, target):
                    assert all(marker.encode() not in file.read_bytes() for file in destination.rglob('*') if file.is_file())
            results.append(dict(profile=profile, retained_objects=len(observations[0]), repaired_objects=len(exact),
                fresh_store=switched['store'], copied_birth='03'*16, restored_source='01'*16,
                preserved_damage=damaged_name, switch_attempts=attempt+1))
            (artifacts/'results.json').write_text(json.dumps(dict(results=results, repository=str(repository),
                live_provider=bool(ssh), signed='ad-hoc', launch='LaunchServices',
                unqualified=['production distribution', 'physical power loss', 'account full/offline induction']), indent=2))
            print('PASS:', profile, 'signed add-only repair, occupied Save As/switch, fresh peer history and portable Undo/Redo', flush=True)
        assert len(results) == 2
    finally:
        for driver in live:
            if driver.process.poll() is None:
                driver.process.stdin.close()
                try: driver.process.wait(timeout=15)
                except HARNESS.subprocess.TimeoutExpired:
                    driver.process.terminate(); driver.process.wait(timeout=15)


if __name__ == '__main__': main()
