#!/usr/bin/env python3
"""Signed integrated startup, selected bootstrap, local admission and explicit two-root reassociation."""
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--local-binary', type=Path, required=True)
    parser.add_argument('--remote-binary', type=Path)
    parser.add_argument('--ssh-target')
    parser.add_argument('--ssh-key', type=Path)
    parser.add_argument('--repository-parent', type=Path)
    parser.add_argument('--timeout', type=int, default=300)
    args = parser.parse_args()
    assert bool(args.ssh_target) == bool(args.ssh_key) == bool(args.remote_binary)
    if args.ssh_target:
        assert args.repository_parent, 'Live tests require an explicitly authorized synthetic parent'
    artifacts = Path(tempfile.mkdtemp(prefix='nv-p55-apple-startup-', dir='/tmp'))
    print('Artifacts:', artifacts, flush=True)
    ssh = ['ssh', '-i', str(args.ssh_key), '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
           '-o', 'ConnectTimeout=10', args.ssh_target] if args.ssh_target else None
    local = HARNESS.Host(args.local_binary.resolve(), artifacts)
    remote = HARNESS.Host(args.remote_binary or args.local_binary.resolve(), artifacts, ssh)
    script, plist = artifacts/'relay.py', artifacts/'Info.plist'
    shutil.copy2(ROOT/'tools/test-storage-apple-transport.py', script); remote.put(script, script)
    shutil.copy2(ROOT/'tests/NVStorageContract-Info.plist', plist); remote.put(plist, plist)
    apps = [artifacts/'Local.app', artifacts/'Remote.app']
    for host, app in zip((local, remote), apps):
        host.run(['python3', script, '--make-app', host.binary, app, plist])
    repository = (args.repository_parent or artifacts)/('P55-'+uuid.uuid4().hex)
    repository.mkdir()
    results = []

    def exists_file(host, file):
        observation = '''import json,os,stat,sys
try:
    present=stat.S_ISREG(os.stat(sys.argv[1]).st_mode)
except FileNotFoundError:
    present=False
print(json.dumps(present))
'''
        return json.loads(host.run(['python3', '-c', observation, file]).stdout)

    for profile in ('public', 'encrypted'):
        case = artifacts/profile; case.mkdir()
        left, right = case/'left', case/'right'
        left_selection, right_selection = case/'left.json', case/'right.json'
        root = repository/profile
        root.mkdir(); (root/'foreign.txt').write_bytes(b'preserved unrelated input')
        peer_root = root if ssh else repository/(profile+'-peer')
        if not ssh:
            peer_root.mkdir()

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

        def controller(host, app, directory, selection, target, **configuration):
            return HARNESS.Driver(host, app, script, case, directory, selection, target, args.timeout,
                                  entry_command='startup-controller', **configuration)

        source = controller(local, apps[0], left, left_selection, root, mode='create', profile=profile, intent='existing')
        first = source.call('state')
        assert [n['body'] for n in first['notes']] == ['initial', 'untouched'], first
        HARNESS.eventually(lambda: source.call('transport-status'), lambda s: s.get('publication') == 'idle', args.timeout,
                          'Initial automatic publication', diagnose=source.diagnose)
        initial = local.inspect(left, left_selection)
        snapshot_row = next(r for r in initial['objects'] if r[1] == '2')
        sealed = bytes.fromhex(snapshot_row[4])
        snapshot = (sealed[48:72] + hashlib.sha256(sealed).digest()).hex()
        initial_segments = [bytes.fromhex(r[4]) for r in initial['objects'] if r[1] != '0']
        assert initial_segments and all(encoded[:8] == b'NVSEG1\r\n' for encoded in initial_segments)
        initial_paths = [HARNESS.locator_path((encoded[48:72]+hashlib.sha256(encoded).digest()).hex())
                         for encoded in initial_segments]
        descriptor_paths = [str(file.relative_to(root)) for file in root.rglob('*.nvkey')]
        assert len(descriptor_paths) == 1
        HARNESS.eventually(lambda: delivery(lambda: all(exists_file(remote, peer_root/p) for p in initial_paths)), bool,
                          args.timeout, 'Exact bootstrap names visible on the selected host')
        HARNESS.eventually(lambda: delivery(lambda: all(exists_file(remote, peer_root/p) for p in descriptor_paths)), bool,
                          args.timeout, 'Exact selected descriptor visible on the selected host')
        selected = json.loads(left_selection.read_text())
        right_selection.write_text(json.dumps(dict(selected, store=list(uuid.uuid4().bytes))))
        remote.put(right_selection, right_selection)
        peer = controller(remote, apps[1], right, right_selection, peer_root, mode='bootstrap', snapshot=snapshot)
        HARNESS.eventually(lambda: peer.call('discover'), lambda s: s['passEnded'], args.timeout, 'Bounded selected intake')
        preview = peer.call('preview')
        assert preview['readOnly'] and [n['body'] for n in preview['notes']] == ['initial', 'untouched'], preview
        completed = peer.call('complete')
        assert [n['body'] for n in completed['notes']] == ['initial', 'untouched'] and completed['through'] == 1
        actual_selected = json.loads(remote.run(['python3', '-c', 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))', right_selection]).stdout)
        assert actual_selected['store'] != selected['store']
        marker = 'P55 synthetic secret '+uuid.uuid4().hex
        edit = source.call('put', body=marker)
        HARNESS.eventually(lambda: delivery(lambda: peer.call('state')),
                          lambda s: sorted(n['body'] for n in s.get('notes', [])) == sorted([marker, 'untouched']), args.timeout, 'Integrated remote edit')
        deletion = peer.call('delete', birth=2)
        HARNESS.eventually(lambda: delivery(lambda: source.call('state')),
                          lambda s: [n['body'] for n in s.get('notes', [])] == [marker], args.timeout, 'Integrated remote Delete')
        peer.stop()
        addition = source.call('create', birth=3, body='lagging receiver input')
        HARNESS.eventually(lambda: source.call('transport-status'), lambda s: s.get('publication') == 'idle', args.timeout,
                          'Local barrier followed by publication', diagnose=source.diagnose)
        HARNESS.eventually(lambda: delivery(lambda: exists_file(remote, peer_root/HARNESS.locator_path(addition['object']))), bool,
                          args.timeout, 'Named new provider object')
        peer = controller(remote, apps[1], right, right_selection, peer_root, mode='open', evict=addition['object'])
        # Retry positively revalidates the retained owner after any actual eviction notification.
        retried = HARNESS.eventually(lambda: peer.call('retry'), lambda s: 'continuity' in s, args.timeout, 'Retained-root Retry')
        assert retried['continuity'] == 'same', retried
        disclosed = HARNESS.eventually(lambda: peer.call('consider', locator=addition['object']), lambda s: 'decision' in s,
                                      args.timeout, 'Applicable exact named observation')
        offered = disclosed['decision'].startswith('waiting(')
        if offered:
            peer.call('waiting-bytes')
            offline = peer.call('offline')
            assert 'notes' in offline or offline.get('unavailable') == 'staleCapture', offline
        else:
            assert disclosed['decision'] == 'ready', disclosed
        state = HARNESS.eventually(lambda: delivery(lambda: peer.call('state')),
            lambda s: sorted(n['body'] for n in s.get('notes', [])) == sorted([marker, 'lagging receiver input']), args.timeout, 'Delayed evidence settles without another delivery')
        # The older selected copy contains the initial history only. Reassociation preserves all private newer history.
        older = case/'older-root'; older.mkdir()
        (older/'foreign.txt').write_bytes(b'preserve selected older copy')
        for relative in initial_paths:
            target = older/relative; target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(root/relative, target); remote.put(target, target)
        for file in root.rglob('*.nvkey'):
            target = older/file.relative_to(root); target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target); remote.put(target, target)
        remote.put(older/'foreign.txt', older/'foreign.txt')
        rebound = peer.call('reopen', repository=str(older))
        assert rebound['notes'] == state['notes'] and rebound['context'] == state['context']
        peer.stop(); final = source.call('state'); source.stop()
        assert final['notes'] == state['notes']
        inventories = [host.inspect(directory, selection) for host, directory, selection in
                       ((local, left, left_selection), (remote, right, right_selection))]
        required = {bytes.fromhex(r['object'])[24:].hex() for r in (edit, deletion, addition)}
        for inventory in inventories:
            assert required <= {r[0].lower() for r in inventory['objects']}
        expected = [{r[0].lower(): r[4].lower() for r in inventory['objects']} for inventory in inventories]
        for identity in required: assert expected[0][identity] == expected[1][identity]
        for host, directory, selection, current in ((local, left, left_selection, final), (remote, right, right_selection, rebound)):
            reopened = host.probe('startup-open', directory, selection)
            assert reopened['notes'] == [dict(birth=n['birth'], body=n['body']) for n in current['notes']]
            assert reopened['context'] == current['context']
        assert (root/'foreign.txt').read_bytes() == b'preserved unrelated input'
        if profile == 'encrypted':
            assert all(marker.encode() not in file.read_bytes() for file in root.rglob('*') if file.is_file())
        results.append(dict(profile=profile, observed_startup_wait=offered, eviction=peer.trace[0].get('eviction'),
                            objects=[len(s['objects']) for s in inventories], prior_readonly_preview=True,
                            local_store_ids=[selected['store'], actual_selected['store']]))
        (artifacts/'results.json').write_text(json.dumps(dict(results=results, repository=str(repository), live_provider=bool(ssh),
            signed='ad-hoc', launch='LaunchServices', unqualified=['default production distribution', 'account full/offline induction', 'physical power loss']), indent=2))
        print('PASS:', profile, 'signed integrated startup/bootstrap, exact delivery, Retry, older-root Re-open and fresh exec', flush=True)
    assert len(results) == 2


if __name__ == '__main__': main()
