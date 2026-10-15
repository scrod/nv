#!/usr/bin/env python3
"""Connected repository schedules with fresh owners and independent history observations."""
import argparse
import hashlib
import importlib.util
import itertools
import json
import platform
import random
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('phase3_process', ROOT/'tools/test-storage-phase3-process.py')
PHASE3 = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PHASE3)
N, SENTINEL = '01'*16, '02'*16


class ObservationFailure(AssertionError):
    """Names the independent predicate that rejected an observation."""


def require(value, predicate, detail=None):
    if not value:
        raise ObservationFailure(f'{predicate}: {detail}')


def check_manifest(selected, completed):
    require(bool(selected) and len(set(selected)) == len(selected), 'discovery', selected)
    require(len(set(completed)) == len(completed) and set(completed) == set(selected),
            'discovery', {'selected': selected, 'completed': completed})


def check_notes(actual, expected):
    values = {row['birth']: row['body'] for row in actual['notes']}
    require(len(values) == len(actual['notes']) and values == expected, 'current-values', (values, expected))


def check_inventory(report, expected, accepted=True):
    require(report['integrity'] == [['ok']] and report['foreign_keys'] == [], 'database-integrity')
    rows = {row[0].lower(): row for row in report['objects']}
    require(len(rows) == len(report['objects']), 'unique-object-membership')
    for identity, value in expected.items():
        require(identity in rows, 'retained-bytes', identity)
        row = rows[identity]
        require(bytes.fromhex(row[4]) == value and hashlib.sha256(value).hexdigest() == identity,
                'retained-bytes', identity)
        if accepted:
            require(row[5] != '', 'accepted-membership', identity)


def check_settled(opened, report):
    require(len(report['view']) == 1 and int(report['view'][0][1]) == opened['through'], 'coherent-view')
    accepted = [int(row[5]) for row in report['objects'] if row[5] != '']
    require(accepted and max(accepted) == opened['through'], 'coherent-history')


def check_fault(exit_code, expected_exit, hits=None):
    require(exit_code == expected_exit, 'reached-fault', (exit_code, expected_exit))
    if expected_exit != 86:
        require(hits == 1, 'reached-fault', hits)


def check_cut(report, identity, fault):
    """Distinguishes the two sides of a reached commit before retry can conceal its outcome."""
    check_inventory(report, {}, accepted=False)
    rows = [row for row in report['objects'] if row[0].lower() == identity]
    accepted = bool(rows and rows[0][5] != '')
    if fault[3] == 'parking':
        waits = [row for row in report['waiting'] if row[0].lower() == identity]
        require(not accepted and len(waits) == (2 if fault[0] == 5 else 0), 'parking-cut', waits)
    elif fault[0] in (4, 5):
        require(accepted == (fault[0] == 5), 'acceptance-cut', (accepted, fault))


def self_test():
    value = b'independent synthetic retained bytes'
    identity = hashlib.sha256(value).hexdigest()
    row = [identity, '1', '', '', value.hex(), '2']
    report = dict(integrity=[['ok']], foreign_keys=[], objects=[row], view=[['epoch', '2']])
    opened = dict(through=2, notes=[dict(birth=N, body='expected')])
    check_manifest(['a', 'b'], ['b', 'a'])
    check_notes(opened, {N: 'expected'})
    check_inventory(report, {identity: value})
    check_settled(opened, report)
    check_fault(86, 86)
    controls = [
        ('P57-H1', 'discovery', lambda: check_manifest(['a', 'b'], ['a'])),
        ('P57-H1', 'discovery', lambda: check_manifest([], [])),
        ('P57-H2', 'current-values', lambda: check_notes(opened, {N: 'lost edit'})),
        ('P57-H2', 'retained-bytes', lambda: check_inventory(report, {identity: value + b'changed'})),
        ('P57-H3', 'reached-fault', lambda: check_fault(0, 86)),
        ('P57-H3', 'reached-fault', lambda: check_fault(0, 0, 0)),
        ('P57-H4', 'coherent-view', lambda: check_settled(dict(opened, through=1), report)),
        ('P57-H4', 'coherent-history', lambda: check_settled(opened, dict(report, objects=[row[:5] + ['3']]))),
        ('P57-H5', 'retained-bytes', lambda: check_inventory(dict(report, objects=[]), {identity: value})),
        ('P57-H6', 'accepted-membership', lambda: check_inventory(dict(report, objects=[row[:5] + ['']]), {identity: value})),
        ('P57-H3', 'acceptance-cut', lambda: check_cut(report, identity, [4, 1, -1, 'acceptance'])),
        ('P57-H3', 'acceptance-cut', lambda: check_cut(dict(report, objects=[]), identity, [5, 1, -1, 'acceptance'])),
    ]
    for name, predicate, control in controls:
        try:
            control()
        except ObservationFailure as error:
            require(str(error).startswith(predicate + ':'), 'control-predicate', str(error))
        else:
            raise ObservationFailure(f'control-survived: {name}/{predicate}')
    print('PASS: observer controls; actual effect/progress witnesses remain separately required', flush=True)


def canonical(encoded):
    identity = hashlib.sha256(encoded).hexdigest()
    require(encoded[:8] == b'NVSEG1\r\n', 'segment-envelope')
    return Path(f'NV Data/v1/segments/{encoded[48:64].hex()}/{int.from_bytes(encoded[64:72], "big"):020d}-{identity}.nvseg')


class RepositoryCase(PHASE3.Case):
    """Routes the existing causal fixtures through actual rooted discovery and publication."""
    def __init__(self, binary, directory, profile, base='A'):
        super().__init__(binary, directory, profile, base)
        self.required = {}
        self.gates = []
        for side in ['left', 'right', 'third']:
            (directory/(side+'-repository')).mkdir()

    def repository(self, side):
        return self.directory/(side+'-repository')

    def inspect(self, side):
        report, oracle = super().inspect(side)
        opened = self.invoke(side, 'dump')
        check_settled(opened, report)
        return report, oracle

    def deliver(self, side, object, fault=None, renamed=False):
        encoded = bytes.fromhex(object['envelope'])
        identity = hashlib.sha256(encoded).hexdigest()
        self.required[identity] = encoded
        relative = canonical(encoded)
        if renamed:
            relative = relative.with_name('renamed-'+relative.name)
        target = self.repository(side)/relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            require(target.read_bytes() == encoded, 'test-delivery-collision')
        else:
            target.write_bytes(encoded)
        extra = [self.repository(side), *(fault or ())]
        self.invoke(side, 'exchange-discover', *extra, code=86 if fault else 0)
        if fault:
            at_cut = self.invoke(side, 'inspect')
            check_cut(at_cut, identity, fault)
            self.gates.append({'effect': 'process-exit', 'cut': list(fault), 'object': identity})
            # Recovery and the retry receive only surviving store and ordinary inputs.
            self.invoke(side, 'exchange-discover', self.repository(side))
        report, _ = self.inspect(side)
        check_inventory(report, {identity: encoded}, accepted=False)
        waits = [row for row in report['waiting'] if row[0].lower() == identity]
        return {'status': 'waiting' if waits else 'accepted', 'missing': len(waits)}

    def publish(self, side):
        result = self.invoke(side, 'exchange-publish', self.repository(side))
        report, _ = self.inspect(side)
        expected = {}
        for row in report['objects']:
            if row[1] == '0' or row[5] == '':
                continue
            encoded = bytes.fromhex(row[4])
            path = self.repository(side)/canonical(encoded)
            require(path.read_bytes() == encoded, 'published-exact-bytes', str(path))
            expected[row[0].lower()] = encoded
        require(expected and result['paths'], 'publication-progress')
        return expected


def dependency_fixture(c):
    left = c.command('left', 'put', body='Left')
    right = c.command('right', 'put', body='Right')
    c.deliver('left', right)
    child = c.command('left', 'copy', revision=right['operations'][0])
    return [left, right, child]


def dependencies(c, order, cut, objects):
    c.invoke('third', 'exchange-discover', c.repository('third'))
    for position, index in enumerate(order):
        fault = None
        if position == 0 and cut != 'normal':
            phase = 'parking' if index == 2 else 'acceptance'
            fault = (4 if cut == 'before' else 5, 1, -1, phase)
        result = c.deliver('third', objects[index], fault)
        if position == 0 and index == 2:
            require(result == {'status': 'waiting', 'missing': 2}, 'both-prerequisites', result)
            c.gates.append({'effect': 'two-missing-prerequisites'})
    expected_ids = {hashlib.sha256(bytes.fromhex(obj['envelope'])).hexdigest(): bytes.fromhex(obj['envelope']) for obj in objects}
    for obj in objects:
        c.deliver('third', obj, renamed=True)
    report, oracle = c.inspect('third')
    check_inventory(report, expected_ids)
    require(not report['waiting'] and not report['ready'], 'dependency-settlement')
    require(sum(action['kind'] == 9 for action in oracle['actionRecords']) == 1, 'logical-once-copy')
    require(sorted(c.bodies('third').values()) == ['Left', 'Right', 'untouched'] or
            sorted(c.bodies('third').values()) == ['Right', 'Right', 'untouched'], 'preserved-copy-values')
    c.publish('third')


def compensation_fixture(c):
    edit = c.command('left', 'put', body='shared saved edit')
    c.deliver('right', edit)
    u = c.command('left', 'undo')
    v = c.command('right', 'undo')
    unrelated = c.invoke('third', 'apply', 'create', 4, 'independent third writer')
    return [edit, u, v, unrelated]


def reviewed_compensation(c, reverse, objects):
    edit, u, v, unrelated = objects
    for obj in ([v, u, edit] if reverse else [edit, u, v]): c.deliver('third', obj)
    require(c.bodies('third')[N] == 'A', 'concurrent-undo-values')
    candidates = c.invoke('third', 'candidates')
    require(candidates['redo_mode'] == 'review' and set(candidates['redo']) == {u['action'], v['action']},
            'competing-redo-candidates', candidates)
    r = c.command('third', 'redo', candidate=u['action'], review=True)
    require(c.bodies('third')[N] == 'shared saved edit', 'reviewed-redo-value')
    request = c.directory/'sibling-no-effect.json'
    request.write_text(json.dumps(dict(kind='redo', candidate=v['action'], review=True)))
    require(c.invoke('third', 'semantic', request) == {'initial': 'no-effect'}, 'sibling-compensation-no-effect')
    undo = c.command('third', 'undo', review=True)
    require(c.bodies('third')[N] == 'A', 'reviewed-undo-value')
    redo = c.command('third', 'redo', review=True)
    final = {N: 'shared saved edit', SENTINEL: 'untouched', '04'*16: 'independent third writer'}
    for side, missing in [('left', v), ('right', u)]:
        for obj in [redo, undo, r, unrelated, missing]: c.deliver(side, obj)
        check_notes(c.invoke(side, 'dump'), final)
        c.publish(side)
    c.second_recovery_cut('third')
    check_notes(c.invoke('third', 'dump'), final)
    _, oracle = c.inspect('third')
    for obj, before, after in [(r, 'A', 'shared saved edit'), (undo, 'shared saved edit', 'A'), (redo, 'A', 'shared saved edit')]:
        action = next(a for a in oracle['actionRecords'] if a['id'] == obj['action'])
        require(action['affected'][0]['beforeValue']['body'] == before and action['affected'][0]['afterValue']['body'] == after,
                'compensation-exact-captured-values')
    c.gates.append({'effect': 'actual-review-required-compensation'})


def lost_completion(c):
    e = c.command('left', 'put', body='historical E')
    f = c.command('left', 'put', body='durable F')
    c.deliver('right', e)
    encoded = bytes.fromhex(f['envelope'])
    target = c.repository('right')/canonical(encoded)
    target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(encoded)
    c.invoke('right', 'exchange-discover', c.repository('right'), 5, 1, -1, 'acceptance', code=86)
    raw = c.invoke('right', 'inspect')
    expected = {hashlib.sha256(bytes.fromhex(obj['envelope'])).hexdigest(): bytes.fromhex(obj['envelope']) for obj in [e, f]}
    check_inventory(raw, expected)
    require(int(raw['view'][0][1]) < max(int(row[5]) for row in raw['objects'] if row[5]), 'pending-materialization')
    c.invoke('right', 'open-crash', 7, 1, -1, 'materialization', code=86)
    c.gates += [{'effect': 'accepted-before-callback'}, {'effect': 'second-recovery-failure'}]
    c.inspect('right')
    check_notes(c.invoke('right', 'dump'), {N: 'durable F', SENTINEL: 'untouched'})
    c.deliver('right', f, renamed=True)
    c.publish('right')


def backup_fixture(c):
    backup = c.directory/'right-backup'
    shutil.copytree(c.directory/'right', backup)
    deleted = c.command('left', 'delete')
    first = c.command('right', 'put', body='later discarded by backup restoration')
    (c.directory/'right').rename(c.directory/'right-before-backup')
    shutil.copytree(backup, c.directory/'right')
    require(c.bodies('right') == {N: 'A', SENTINEL: 'untouched'}, 'undisclosed-delete')
    stale = c.command('right', 'put', body='offline old-birth edit')
    require(bytes.fromhex(first['envelope'])[48:64] != bytes.fromhex(stale['envelope'])[48:64], 'fresh-writer-after-backup')
    restored = c.command('left', 'restore', source=N, birth='03'*16)
    edit = c.command('left', 'put', birth='03'*16, body='fresh restored edit')
    c.invoke('third', 'apply', 'create', 4, 'independent third writer')
    c.publish('third')
    return [deleted, restored, edit, stale]


def restored_backup(c, reverse, incoming):
    deleted = incoming[0]
    for obj in reversed(incoming) if reverse else incoming:
        c.deliver('third', obj)
    actual = c.bodies('third')
    require(N not in actual and actual.get('03'*16) == 'fresh restored edit', 'fresh-birth-preservation', actual)
    require(sorted(actual.values()) == ['fresh restored edit', 'independent third writer', 'offline old-birth edit', 'untouched'],
            'old-birth-conflict-preservation', actual)
    report, oracle = c.inspect('third')
    require(any(row[0].lower() == N for row in report['restorations']), 'restoration-provenance')
    require(any(op['id'] == deleted['operations'][0] for op in oracle['operationRecords']), 'retained-delete')
    c.publish('third')


def clone_fixture(c, fixture, objects, sides):
    """Gives each delivery order separate writable copies of the same closed authored history."""
    for side in sides:
        (c.directory/side).rename(c.directory/(side+'-unused-seed'))
        shutil.copytree(fixture.directory/side, c.directory/side)
        shutil.copyfile(fixture.directory/(side+'.json'), c.directory/(side+'.json'))
        c.repository(side).rename(c.directory/(side+'-unused-repository'))
        shutil.copytree(fixture.repository(side), c.repository(side))
    c.gates.append(dict(effect='same-authored-fixture', fixture=str(fixture.directory),
        objects=[hashlib.sha256(bytes.fromhex(obj['envelope'])).hexdigest() for obj in objects]))


def wire_replay(binary, frozen, destination):
    """Replays exact allocated envelopes and process cuts from an independently checked seed store."""
    schedule = json.loads(frozen.read_text())
    origin = frozen.parent
    require(schedule['format'] == 1 and schedule['steps'], 'wire-schedule')
    for path, digest in schedule['inputs'].items():
        require(hashlib.sha256((origin/path).read_bytes()).hexdigest() == digest, 'frozen-input', path)
    destination.mkdir()
    c = RepositoryCase.__new__(RepositoryCase)
    c.binary, c.directory, c.trace, c.required, c.gates = binary, destination, [], {}, []
    shutil.copytree(origin/'replay-seed', destination/'receiver')
    shutil.copyfile(origin/'replay-selection.json', destination/'receiver.json')
    c.repository('receiver').mkdir()
    for step in schedule['steps']:
        encoded = (origin/step['file']).read_bytes()
        c.deliver('receiver', dict(envelope=encoded.hex()), step.get('fault'), step.get('renamed', False))
        if step.get('recovery_fault'):
            raise ObservationFailure('unsupported-recovery-cut-placement')
    report, _ = c.inspect('receiver')
    check_inventory(report, c.required)
    check_notes(c.invoke('receiver', 'dump'), schedule['expected'])
    require(not report['ready'] and not report['waiting'], 'generated-closure')
    require(len(report['actions']) == schedule['actions'], 'generated-logical-once')
    c.publish('receiver')
    (destination/'gates.json').write_text(json.dumps(c.gates, indent=2))
    return c


def generated(c, seed):
    """Three writers author at most eight actions; replay freezes identities as well as ordering."""
    rng = random.Random(seed)
    shutil.copytree(c.directory/'third', c.directory/'replay-seed')
    shutil.copyfile(c.directory/'third.json', c.directory/'replay-selection.json')
    expected = {N: 'A', SENTINEL: 'untouched'}
    births = {'left': N, 'right': '03'*16, 'third': '04'*16}
    objects = []
    for side, byte in [('left', 1), ('right', 3), ('third', 4)]:
        body = f'seed {seed} {side} first'
        obj = c.invoke(side, 'apply', 'put' if side == 'left' else 'create', byte, body)
        objects.append(obj); expected[births[side]] = body
    for index in range(3, 8):
        side = rng.choice([s for s, birth in births.items() if birth in expected])
        deleting = index >= 6 and rng.choice([False, True])
        body = f'seed {seed} action {index} {side}'
        objects.append(c.command(side, 'delete' if deleting else 'put', birth=births[side], **({} if deleting else {'body': body})))
        if deleting: del expected[births[side]]
        else: expected[births[side]] = body
    if seed % 2:
        snapshot = c.invoke('left', 'snapshot-save')
        report, _ = c.inspect('left')
        selected = set(snapshot['pages'] + [snapshot['root']])
        objects += [dict(envelope=row[4]) for row in report['objects'] if row[0].lower() in selected]
    first = objects.pop(rng.randrange(3))
    rng.shuffle(objects)
    objects.insert(0, first)
    payloads = c.directory/'wire'; payloads.mkdir()
    steps = []
    for index, obj in enumerate(objects):
        encoded = bytes.fromhex(obj['envelope'])
        name = f'wire/{hashlib.sha256(encoded).hexdigest()}.nvseg'
        (c.directory/name).write_bytes(encoded)
        step = {'file': name}
        if index == 0 and seed % 3:
            step['fault'] = [4 if seed % 3 == 1 else 5, 1, -1, 'acceptance']
        steps.append(step)
    # Exact renamed repeats challenge physical-name changes and logical idempotency.
    steps += [dict(step, renamed=True, fault=None) for step in rng.sample(steps, min(3, len(steps)))]
    files = [p for p in (c.directory/'replay-seed').rglob('*') if p.is_file()]
    files += [c.directory/'replay-selection.json', *payloads.iterdir()]
    schedule = dict(format=1, seed=seed, steps=steps, expected=expected, actions=10,
                    inputs={str(p.relative_to(c.directory)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files})
    frozen = c.directory/'wire-schedule.json'; frozen.write_text(json.dumps(schedule, indent=2))
    replayed = wire_replay(c.binary, frozen, c.directory/'execution')
    c.gates = replayed.gates


def input_inventory():
    paths = [ROOT/'NVStorage/Package.swift', ROOT/'NVStorage/Package.resolved', ROOT/'tests/Makefile']
    for folder in ['NVStorage/Sources', 'NVStorage/Tests', 'NVStorage/Vendor', 'tools']:
        paths += [p for p in (ROOT/folder).rglob('*') if p.is_file() and '__pycache__' not in p.parts]
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(paths)) if p.is_file()}


def cases(seeds=4):
    result = []
    for profile in ['public', 'encrypted']:
        for order in itertools.permutations(range(3)):
            for cut in ['normal', 'before', 'after']:
                result.append(dict(id=f'{profile}-S1-dependencies-{"".join(map(str, order))}-{cut}',
                                   profile=profile, family='S1', kind='dependencies', order=list(order), cut=cut))
        result.append(dict(id=f'{profile}-S1-lost-completion', profile=profile, family='S1', kind='lost-completion'))
        for reverse in [False, True]:
            result.append(dict(id=f'{profile}-S5-backup-restore-{reverse}', profile=profile, family='S5', kind='backup', reverse=reverse))
        result.append(dict(id=f'{profile}-S5-reciprocal-copies', profile=profile, family='S5', kind='copies'))
        for reverse in [False, True]:
            result.append(dict(id=f'{profile}-S5-reviewed-compensation-{reverse}', profile=profile, family='S5', kind='compensation', reverse=reverse))
        for seed in range(seeds):
            result.append(dict(id=f'{profile}-generated-{seed}', profile=profile, family='generated', kind='generated', seed=seed))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--only', action='append', default=[], help='Exact case ID; repeat to select cases.')
    parser.add_argument('--family', choices=['S1', 'S5', 'generated'])
    parser.add_argument('--seeds', type=int, choices=[4, 16], default=4)
    parser.add_argument('--replay', type=Path, help='Repeat selected logical cases; new authored identities are recorded.')
    parser.add_argument('--replay-wire', type=Path, help='Replay exact frozen bytes, initial store and cuts from a generated wire-schedule.json.')
    args = parser.parse_args()
    require(__debug__, 'python-assertions-enabled')
    self_test()
    if args.self_test:
        return
    if args.replay_wire:
        require(args.binary is not None and args.binary.is_file(), 'probe-binary')
        parent = Path(tempfile.mkdtemp(prefix='nv-p57-wire-', dir='/tmp'))
        wire_replay(args.binary.resolve(), args.replay_wire.resolve(), parent/'execution')
        print('PASS: exact wire replay; artifacts:', parent, flush=True)
        return
    selected = cases(args.seeds)
    if args.replay:
        replay = json.loads(args.replay.read_text())['selected']
        require(all(case in selected for case in replay), 'supported-replay-manifest')
        selected = replay
    if args.only:
        require(set(args.only) <= {case['id'] for case in selected}, 'requested-discovery', args.only)
        selected = [case for case in selected if case['id'] in args.only]
    if args.family:
        selected = [case for case in selected if case['family'] == args.family]
    require(bool(selected), 'requested-discovery')
    print(json.dumps(selected, indent=2), flush=True)
    if args.list:
        return
    require(args.binary is not None and args.binary.is_file(), 'probe-binary')
    binary = args.binary.resolve()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-p57-connected-', dir='/tmp'))
    inputs = input_inventory()
    provenance = dict(inputs=inputs, binary=str(binary), sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                      platform=platform.platform(), machine=platform.machine())
    manifest = dict(selected=selected, completed=[], provenance=provenance)
    (artifacts/'manifest.json').write_text(json.dumps(manifest, indent=2))
    print('Artifacts:', artifacts, flush=True)
    fixtures = {}
    for case in selected:
        require(hashlib.sha256(binary.read_bytes()).hexdigest() == provenance['sha256'], 'stable-probe-binary')
        c = RepositoryCase(binary, artifacts/case['id'], case['profile'])
        if case['kind'] in ('dependencies', 'backup', 'compensation'):
            key = (case['kind'], case['profile'])
            if key not in fixtures:
                fixture = RepositoryCase(binary, artifacts/('fixture-'+'-'.join(key)), case['profile'])
                construct = dict(dependencies=dependency_fixture, backup=backup_fixture, compensation=compensation_fixture)[case['kind']]
                objects = construct(fixture)
                for side in ['left', 'right', 'third']: fixture.inspect(side)
                (fixture.directory/'authored-history.json').write_text(json.dumps(objects, indent=2))
                fixtures[key] = (fixture, objects)
            fixture, objects = fixtures[key]
            clone_fixture(c, fixture, objects, ['third'] if case['kind'] == 'dependencies' else ['left', 'right', 'third'])
            if case['kind'] == 'dependencies': dependencies(c, case['order'], case['cut'], objects)
            elif case['kind'] == 'backup': restored_backup(c, case['reverse'], objects)
            else: reviewed_compensation(c, case['reverse'], objects)
        elif case['kind'] == 'lost-completion':
            lost_completion(c)
        elif case['kind'] == 'copies':
            PHASE3.copies_lifecycle(c, None)
            c.publish('left'); c.publish('right')
        elif case['kind'] == 'generated':
            generated(c, case['seed'])
        else:
            raise ObservationFailure('unsupported-schedule')
        (c.directory/'gates.json').write_text(json.dumps(c.gates, indent=2))
        manifest['completed'].append(case['id'])
        (artifacts/'manifest.json').write_text(json.dumps(manifest, indent=2))
        print('PASS:', case['id'], flush=True)
    require(input_inventory() == inputs, 'stable-source-inputs')
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == provenance['sha256'], 'stable-probe-binary')
    check_manifest([case['id'] for case in selected], manifest['completed'])
    print('PASS:', len(selected), 'connected repository schedules; source/binary/manifest checks complete', flush=True)


if __name__ == '__main__':
    main()
