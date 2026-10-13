#!/usr/bin/env python3
"""Bounded accessor/driver schedules, assertion-specific controls and progress witnesses."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def cases():
    safety = ['ResourcesThroughReturn', 'OriginalRootOnly', 'ExactPublication', 'ApplicableCompletion', 'ReceiveOnce']
    progress = ['DurablePreserved', 'LateInputProgress', 'SavedOutputProgress', 'CloseSettles']
    for scenario in ('steady', 'move', 'close', 'restart', 'busy', 'failure'):
        yield 'safe-'+scenario, scenario, 'safe', safety, progress, None
    for policy, scenario, assertion in (
        ('earlyRelease', 'close', 'ResourcesThroughReturn'),
        ('wrongRoot', 'move', 'OriginalRootOnly'),
        ('staleReceipt', 'move', 'ApplicableCompletion'),
        ('advanceFailed', 'failure', 'ExactPublication'),
        ('onlyHint', 'steady', 'LateInputProgress'),
        ('lostOwnerWake', 'busy', 'LateInputProgress')):
        temporal = assertion == 'LateInputProgress'
        yield 'reject-'+policy, scenario, policy, [] if temporal else [assertion], [assertion] if temporal else [], assertion
    for scenario, assertion in (
        ('steady', 'NeverLateAfterEmpty'), ('steady', 'NeverSaveWhileEntered'),
        ('busy', 'NeverResumedAfterWait'), ('restart', 'NeverRestartedThenComplete'),
        ('move', 'NeverMovedThenComplete')):
        yield 'witness-'+assertion, scenario, 'safe', [assertion], [], assertion


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', required=True)
    parser.add_argument('--jar', type=Path, required=True)
    parser.add_argument('--only', default='')
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-accessor-driver-tla-', dir='/tmp'))
    print('Artifacts:', artifacts, flush=True)
    results = []
    for name, scenario, policy, invariants, properties, expected in cases():
        if args.only not in name: continue
        case = artifacts/name; case.mkdir()
        source = HERE/'RepositoryAccessorDriverSafety.tla'
        shutil.copy2(source, case/source.name)
        (case/'MC.tla').write_text('---- MODULE MC ----\nEXTENDS RepositoryAccessorDriverSafety\n'
            f'PolicyValue == "{policy}"\nScenarioValue == "{scenario}"\n====\n')
        config = ('SPECIFICATION FairSpec\n' if properties else 'SPECIFICATION Spec\n')
        config += 'CONSTANTS Policy <- PolicyValue Scenario <- ScenarioValue\nINVARIANT TypeOK\n'
        config += ''.join('INVARIANT '+v+'\n' for v in invariants)
        config += ''.join('PROPERTY '+v+'\n' for v in properties)+'CHECK_DEADLOCK FALSE\n'
        (case/'case.cfg').write_text(config)
        run = subprocess.run([args.java, '-Xmx1g', '-XX:+UseParallelGC', '-jar', str(args.jar.resolve()),
            '-workers', '2', '-lncheck', 'final', '-coverage', '60', '-metadir', 'states', '-config', 'case.cfg', 'MC.tla'],
            cwd=case, text=True, capture_output=True, timeout=args.timeout)
        output = run.stdout+run.stderr; (case/'output.log').write_text(output)
        violation = re.search(r'(?:Invariant|Temporal property|Action property) (\w+) (?:is|was) violated', output)
        if expected:
            temporal = not invariants and properties == [expected] and 'Error: Temporal properties were violated.' in output
            assert run.returncode != 0 and ((violation and violation[1] == expected) or temporal), (name, output[-6000:])
        else:
            assert run.returncode == 0 and 'Model checking completed. No error has been found.' in output, (name, output[-6000:])
        states = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found', output)
        assert states and int(states[2].replace(',', '')) > 1, (name, 'Nonzero discovery required')
        results.append(dict(name=name, states=states[2], expected=expected,
                            sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest()))
        (artifacts/'results.json').write_text(json.dumps(results, indent=2))
        print('PASS:', name, states[2], flush=True)
    assert results and (args.only or len(results) == 17)


if __name__ == '__main__': main()
