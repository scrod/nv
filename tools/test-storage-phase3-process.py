#!/usr/bin/env python3
"""Connected phase-3 histories, real process cuts, and independent wire/SQL observations."""
import argparse
import itertools
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
N, SENTINEL = '01'*16, '02'*16


class Case:
    def __init__(self, binary, directory, profile, base):
        self.binary, self.directory, self.trace = binary, directory, []
        directory.mkdir()
        result = self.run_raw(['seed-pair', directory, profile, base])
        for side, selection in result.items():
            (directory/(side+'.json')).write_text(selection)

    def run_raw(self, args, code=0):
        command = [str(self.binary), *map(str, args)]
        run = subprocess.run(command, capture_output=True, text=True, timeout=120)
        self.trace.append({'command': command, 'exit': run.returncode, 'stdout': run.stdout, 'stderr': run.stderr})
        (self.directory/'trace.json').write_text(json.dumps(self.trace, indent=2))
        assert run.returncode == code, self.trace[-1]
        return json.loads(run.stdout) if run.stdout.strip() else None

    def invoke(self, side, command, *extra, code=0):
        return self.run_raw([command, self.directory/side, self.directory/(side+'.json'), *extra], code)

    def inspect(self, side):
        # Reopen through production recovery before comparing the materialized prefix.
        # The child receives selection/unlock inputs; expected values stay in this process.
        opened = self.invoke(side, 'dump')
        report = self.invoke(side, 'inspect')
        checked = subprocess.run(['node', str(ROOT/'tools/inspect-storage-history.mjs')],
                                 input=json.dumps(report), capture_output=True, text=True, timeout=90)
        self.trace.append({'oracle': side, 'exit': checked.returncode, 'stdout': checked.stdout, 'stderr': checked.stderr})
        (self.directory/'trace.json').write_text(json.dumps(self.trace, indent=2))
        assert checked.returncode == 0, self.trace[-1]
        oracle = json.loads(checked.stdout)
        expected = {n['birth']: n['body'] for n in oracle['notes']}
        assert {n['birth']: n['body'] for n in opened['notes']} == expected
        assert expected.get(SENTINEL) == 'untouched'
        return report, oracle

    def command(self, side, kind, fault=None, **fields):
        request = self.directory/f'request-{len(self.trace)}.json'
        request.write_text(json.dumps({'kind': kind, **fields}))
        extra = [request]
        if fault: extra += list(fault)
        result = self.invoke(side, 'semantic', *extra, code=86 if fault and fault[2] == -1 else 0)
        if fault and fault[2] == -1:
            report, oracle = self.inspect(side)
            # Locate committed identity through complete observed membership, never an acknowledgment log.
            operations = oracle['operationRecords']
            if kind == 'put':
                candidates = [o for o in operations if o.get('value', {}).get('body') == fields['body']]
            elif kind == 'copy': candidates = [o for o in operations if o['tag'] == 7 and o['sourceRevision'] == fields['revision']]
            elif kind in ['undo', 'redo']:
                actions = [a for a in oracle['actionRecords'] if a['kind'] == (10 if kind == 'undo' else 11)]
                candidates = [o for o in operations if any(o['id'] in a['members'] for a in actions)]
            else: candidates = [o for o in operations if o['tag'] == 6 and o['birth'] == fields.get('birth', N)]
            if fault[0] == 4:
                assert not candidates, (kind, candidates)
                result = self.invoke(side, 'semantic', request)
            else:
                assert candidates, (kind, oracle)
                op = candidates[-1]
                occurrence = next(r for r in report['operations'] if r[0].lower() == op['id'])
                envelope = next(r[4].lower() for r in report['objects'] if r[0].lower() == occurrence[4].lower())
                result = {'envelope': envelope, 'operations': [op['id']], 'action': op['action'], 'births': [op['birth']], 'recovered_callback_loss': True}
        elif fault:
            assert result['initial'] == 'pending' and result['hits'] > 0, result
            assert result['error'].startswith('database('), result
        assert result and result.get('envelope'), result
        self.inspect(side)
        return result

    def deliver(self, side, object, fault=None):
        path = self.directory/f'envelope-{len(self.trace)}.segment'
        path.write_bytes(bytes.fromhex(object['envelope']))
        extra = [path, *(fault or ())]
        result = self.invoke(side, 'receive-file', *extra, code=86 if fault else 0)
        if fault:
            # A retained-but-unaccepted object resumes on its exact repeat; committed objects are idempotent.
            result = self.invoke(side, 'receive-file', path)
        self.inspect(side)
        return result

    def bodies(self, side):
        return {n['birth']: n['body'] for n in self.inspect(side)[1]['notes']}

    def second_recovery_cut(self, side):
        self.invoke(side, 'tamper', 'view')
        self.invoke(side, 'open-crash', 7, 1, -1, code=86)
        self.inspect(side)


def merge_lifecycle(c, fault, concurrent):
    l = c.command('left', 'put', body='A\ngap\nz')
    r = c.command('right', 'put', body='a\ngap\nZ')
    c.deliver('left', r); c.deliver('right', l)
    assert c.bodies('left')[N] == c.bodies('right')[N] == 'A\ngap\nZ'
    e = c.command('left', 'put', body='explicit E')
    if not concurrent: c.deliver('right', e)
    d = c.command('right', 'delete')
    c.deliver('left', d, fault)
    if concurrent: c.deliver('right', e)
    for side in ['left', 'right']:
        notes = c.bodies(side)
        assert N not in notes
        assert sorted(notes.values()) == (['explicit E', 'untouched'] if concurrent else ['untouched'])
        _, oracle = c.inspect(side)
        edit = next(o for o in oracle['operationRecords'] if o.get('value', {}).get('body') == 'explicit E')
        assert set(edit['pred']) == {l['operations'][0], r['operations'][0]}
        action = next(a for a in oracle['actionRecords'] if a['id'] == edit['action'])
        assert action['affected'][0]['before'][0] == 4
    c.second_recovery_cut('left')


def preservation_lifecycle(c, fault):
    d0 = c.command('left', 'delete')
    e = c.command('right', 'put', body='uncovered E')
    c.deliver('left', e)
    auto = next(n for n in c.inspect('left')[1]['notes'] if n['automatic'])
    assert auto['birth'] != N and auto['body'] == 'uncovered E'
    p = c.command('left', 'put', fault, birth=auto['birth'], body='independent P')
    d1 = c.command('right', 'delete')
    c.deliver('right', d0)
    assert c.bodies('right') == {SENTINEL: 'untouched'}
    c.deliver('left', d1); c.deliver('right', p)
    for side in ['left', 'right']:
        assert c.bodies(side) == {SENTINEL: 'untouched', auto['birth']: 'independent P'}
    c.second_recovery_cut('left')
    retired = c.command('left', 'delete', birth=auto['birth'])
    c.deliver('right', retired); c.deliver('right', p)
    assert c.bodies('right') == {SENTINEL: 'untouched'}
    _, oracle = c.inspect('right')
    assert any(d['tag'] == 0 and d['key'] == auto['automatic']['key'] for d in oracle['retired'])


def copies_lifecycle(c, fault):
    l = c.command('left', 'put', body='Left')
    r = c.command('right', 'put', body='Right')
    c.deliver('left', r); c.deliver('right', l)
    original = c.bodies('left')[N]
    lc = c.command('left', 'copy', fault, revision=r['operations'][0])
    rc = c.command('right', 'copy', revision=l['operations'][0])
    c.deliver('left', rc); c.deliver('right', lc)
    for side in ['left', 'right']:
        assert c.bodies(side)[N] == original and len(c.bodies(side)) == 4
        assert c.invoke(side, 'conflicts')['alternatives'] == []
        assert set(c.inspect(side)[1]['dispositions']) == {l['operations'][0], r['operations'][0]}
    deleted = c.command('left', 'delete', birth=lc['births'][0]); c.deliver('right', deleted)
    c.second_recovery_cut('left')
    t = c.command('right', 'put', body='Third')
    c.deliver('left', t)
    for side in ['left', 'right']:
        assert lc['births'][0] not in c.bodies(side)
        conflict = c.invoke(side, 'conflicts')
        assert set(conflict['alternatives']) == set(conflict['heads']) - set(conflict['represented']) - set(conflict['dispositions'])
        assert t['operations'][0] not in conflict['dispositions']


def compensation_lifecycle(c, fault):
    a = c.command('left', 'put', body='Groceries'); c.deliver('right', a)
    u = c.command('left', 'undo')
    # Generate only finite valid concurrent histories; record every offered envelope.
    for attempt in range(16):
        x = c.command('right', 'put', body='Errands'); c.deliver('left', x)
        if c.bodies('left')[N] == 'Errands': break
    else: return False
    c.deliver('right', u)
    r = c.command('left', 'redo', fault, candidate=u['action'], review=True)
    _, after_r = c.inspect('left')
    r_op = next(o for o in after_r['operationRecords'] if o['id'] == r['operations'][0])
    assert r_op['value']['body'] == 'Groceries'
    assert set(next(n for n in after_r['notes'] if n['birth'] == N)['heads']) == {u['operations'][0], r['operations'][0]}
    # R returns to the common base while U is an unchosen live alternative.
    # The normal one-sided merge therefore settles to Shopping, with both inputs.
    assert c.bodies('left')[N] == 'Shopping'
    s = c.command('left', 'undo', review=True)
    assert c.bodies('left')[N] == 'Errands'
    t = c.command('left', 'redo', review=True)
    assert c.bodies('left')[N] == 'Shopping'
    for object in [r, s, t]: c.deliver('right', object)
    c.second_recovery_cut('right')
    _, oracle = c.inspect('right')
    for command, old, new in [(r, 'Errands', 'Groceries'), (s, 'Shopping', 'Errands'), (t, 'Errands', 'Shopping')]:
        action = next(a for a in oracle['actionRecords'] if a['id'] == command['action'])
        effect = action['affected'][0]
        assert effect['beforeValue']['body'] == old
        assert effect['afterValue']['body'] == new
    return True


def dependency_orders(c, order):
    l = c.command('left', 'put', body='Left'); r = c.command('right', 'put', body='Right')
    c.deliver('left', r)
    child = c.command('left', 'copy', revision=r['operations'][0])
    objects = [l, r, child]
    for position, index in enumerate(order):
        result = c.deliver('third', objects[index])
        if position == 0 and index == 2:
            assert result['status'] == 'waiting' and result['missing'] == 2
        c.invoke('third', 'dump')
    assert len(c.bodies('third')) == 3
    for object in objects: c.deliver('third', object)
    _, oracle = c.inspect('third')
    assert sum(a['kind'] == 9 for a in oracle['actionRecords']) == 1
    report, _ = c.inspect('third')
    assert report['waiting'] == [] and report['ready'] == []


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-phase3-process-'))
    print('Artifacts:', artifacts, flush=True)
    records, prefixes = [], []
    # Full products are used only for the small delivery graph. These are selected failure schedules.
    for profile in ['public', 'encrypted']:
        receive_cuts = [None] if args.smoke else [None, (5, 1, -1), (5, 3, -1)]
        for concurrent in [False, True]:
            for cut in receive_cuts:
                name = f'{profile}-L1-{concurrent}-{cut}'
                c = Case(args.binary.resolve(), artifacts/name, profile, 'a\ngap\nz')
                merge_lifecycle(c, cut, concurrent); records.append(name)
                print('PASS:', name, flush=True)
        save_cuts = [None] if args.smoke else [None, (4, 1, -1), (5, 1, -1), (1, 1, 10), (1, 1, 13), (3, 1, 5)]
        for label, base, lifecycle in [('L2', 'A', preservation_lifecycle), ('L3', 'A', copies_lifecycle), ('L4', 'Shopping', compensation_lifecycle)]:
            for cut in save_cuts:
                name = f'{profile}-{label}-{cut}'
                for witness in range(64 if label == 'L4' else 1):
                    c = Case(args.binary.resolve(), artifacts/f'{name}-witness-{witness}', profile, base)
                    if lifecycle(c, cut) is not False: break
                    prefixes.append({'schedule': name, 'directory': str(c.directory),
                        'reason': 'Valid finite history selected a different stable Current; fixed Errands review cut was not reached'})
                    print('VALID PREFIX (different stable Current):', name, witness, flush=True)
                else: raise AssertionError(f'Missing complete fixed-value L4 witness: {name}')
                records.append(name)
                print('PASS:', name, flush=True)
        for order in ([tuple([2, 0, 1])] if args.smoke else itertools.permutations(range(3))):
            name = f'{profile}-dependencies-{order}'
            c = Case(args.binary.resolve(), artifacts/name, profile, 'A')
            dependency_orders(c, order); records.append(name)
            print('PASS:', name, flush=True)
    expected = 12 if args.smoke else 60
    assert len(records) == expected, len(records)
    (artifacts/'results.json').write_text(json.dumps({'completed': records, 'schedule_count': len(records),
        'nonwitness_prefixes': prefixes, 'nonwitness_prefix_count': len(prefixes),
        'fault_classes': ['process termination', 'EIO', 'ENOSPC', 'busy', 'derived-row corruption'],
        'bounds': 'three writers; finite lifecycle actions; six delivery orders; L4 permits at most 64 fresh collections with at most 16 concurrent Errands updates per collection',
        'unqualified': ['physical power loss', 'provider publication', 'physical projections', 'AppKit attribution']}, indent=2))
    print('PASS:', len(records), 'connected fresh-process schedules, independent wire/SQL oracle, both profiles', flush=True)


if __name__ == '__main__':
    main()
