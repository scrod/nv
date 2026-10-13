#!/usr/bin/env python3
"""Bounded repository discovery with exact failures and difficult-path witnesses."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent


def cases():
    invariants = ['RetainedExact', 'DependencyClosed', 'LogicalOnce', 'ValuesExact', 'TurnApplicable']
    for scenario in ['late', 'renamed']:
        yield 'safe-'+scenario, scenario, 'safe', invariants, ['AcceptedPreserved', 'DisclosedEventuallyAccepted'], None
    for policy, scenario, invariant in [
        ('onlyHint', 'late', 'DisclosedEventuallyAccepted'),
        ('highWater', 'late', 'DisclosedEventuallyAccepted'),
        ('loseParent', 'late', 'DisclosedEventuallyAccepted'),
        ('skipRenamed', 'renamed', 'DisclosedEventuallyAccepted'),
        ('loseRetained', 'late', 'RetainedExact'),
        ('staleTurn', 'late', 'TurnApplicable'),
        ('duplicateEffects', 'late', 'LogicalOnce'),
        ('skipParents', 'late', 'DependencyClosed'),
    ]:
        temporal = invariant == 'DisclosedEventuallyAccepted'
        yield 'reject-'+policy, scenario, policy, [] if temporal else [invariant], [invariant] if temporal else [], invariant
    for invariant in ['NeverEmptyThenProgress', 'NeverRestartedThenProgress', 'NeverWaitedThenProgress',
                      'NeverStaleFinish', 'NeverReadFailureThenProgress']:
        yield 'witness-'+invariant, 'late', 'safe', [invariant], [], invariant


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', required=True)
    parser.add_argument('--jar', type=Path, required=True)
    parser.add_argument('--only', default='')
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-discovery-tla-', dir='/tmp'))
    print('Artifacts:', artifacts, flush=True)
    results = []
    for name, scenario, policy, inv, props, expected in cases():
        if args.only not in name: continue
        directory = artifacts/name; directory.mkdir()
        source = HERE/'RepositoryDiscoverySafety.tla'; shutil.copyfile(source, directory/source.name)
        (directory/'MC.tla').write_text('---- MODULE MC ----\nEXTENDS RepositoryDiscoverySafety\n'
            f'PolicyValue == "{policy}"\nScenarioValue == "{scenario}"\n====\n')
        config = ('SPECIFICATION FairSpec\n' if props else 'SPECIFICATION Spec\n')
        config += 'CONSTANTS Policy <- PolicyValue Scenario <- ScenarioValue\nINVARIANT TypeOK\n'
        config += ''.join('INVARIANT '+v+'\n' for v in inv) + ''.join('PROPERTY '+v+'\n' for v in props)
        config += 'CHECK_DEADLOCK FALSE\n'
        (directory/'case.cfg').write_text(config)
        start = time.monotonic()
        run = subprocess.run([args.java, '-Xmx1g', '-XX:+UseParallelGC', '-jar', str(args.jar.resolve()),
            '-workers', '2', '-lncheck', 'final', '-coverage', '60', '-metadir', 'states', '-config', 'case.cfg', 'MC.tla'],
            cwd=directory, text=True, capture_output=True, timeout=args.timeout)
        output = run.stdout + run.stderr; (directory/'output.log').write_text(output)
        violation = re.search(r'(?:Invariant|Temporal property|Action property) (\w+) (?:is|was) violated', output)
        if expected:
            temporal_only = not inv and props == [expected] and 'Error: Temporal properties were violated.' in output
            assert run.returncode != 0 and ((violation and violation[1] == expected) or temporal_only), (name, output[-6000:])
        else:
            assert run.returncode == 0 and 'Model checking completed. No error has been found.' in output, (name, output[-6000:])
        states = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found', output)
        assert states and int(states[2].replace(',', '')) > 1, (name, 'Nonzero discovery required')
        results.append(dict(name=name, states=states[2], expected=expected, seconds=time.monotonic()-start,
                            sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest()))
        (artifacts/'results.json').write_text(json.dumps(results, indent=2))
        print('PASS:', name, states[2], flush=True)
    assert results and (args.only or len(results) == 15)


if __name__ == '__main__':
    main()
