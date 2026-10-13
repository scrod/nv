#!/usr/bin/env python3
"""Check the two-entry metadata/partial-handoff companion and its precise controls."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', required=True)
    parser.add_argument('--jar', type=Path, required=True)
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-metadata-tla-', dir='/tmp'))
    print('Artifacts:', artifacts, flush=True)
    invariants = ['RetainedExact', 'AcceptedClosure', 'LogicalOnce', 'ApplicableResult',
                  'CompleteTail', 'TailStreamAlive', 'FreshSelectedObservation']
    cases = [('safe', 'safe', invariants, ['EventuallyLatest', 'AcceptedPreserved'], None)]
    cases += [('reject-'+policy, policy, [predicate], [], predicate) for policy, predicate in [
        ('dropTail', 'CompleteTail'), ('staleResult', 'ApplicableResult'), ('loseRetained', 'RetainedExact'),
        ('oldAttributes', 'FreshSelectedObservation'), ('closeEOF', 'TailStreamAlive')]]
    cases += [('witness-'+predicate, 'safe', [predicate], [], predicate) for predicate in [
        'NeverPartialFailureThenProgress', 'NeverRestartThenProgress', 'NeverChangedTailThenProgress']]
    results = []
    for name, policy, inv, props, expected in cases:
        directory = artifacts/name; directory.mkdir()
        source = HERE/'RepositoryMetadataBatchSafety.tla'; shutil.copyfile(source, directory/source.name)
        (directory/'MC.tla').write_text('---- MODULE MC ----\nEXTENDS RepositoryMetadataBatchSafety\n'
                                      f'PolicyValue == "{policy}"\n====\n')
        config = 'SPECIFICATION ' + ('FairSpec' if props else 'Spec') + '\nCONSTANT Policy <- PolicyValue\nINVARIANT TypeOK\n'
        config += ''.join('INVARIANT '+value+'\n' for value in inv)
        config += ''.join('PROPERTY '+value+'\n' for value in props) + 'CHECK_DEADLOCK FALSE\n'
        (directory/'case.cfg').write_text(config)
        run = subprocess.run([args.java, '-Xmx1g', '-XX:+UseParallelGC', '-jar', str(args.jar.resolve()),
            '-workers', '2', '-lncheck', 'final', '-coverage', '60', '-metadir', 'states', '-config', 'case.cfg', 'MC.tla'],
            cwd=directory, text=True, capture_output=True, timeout=180)
        output = run.stdout + run.stderr; (directory/'output.log').write_text(output)
        if expected:
            assert run.returncode != 0 and re.search(r'Invariant '+expected+r' is violated', output), (name, output[-6000:])
        else:
            assert run.returncode == 0 and 'Model checking completed. No error has been found.' in output, (name, output[-6000:])
        states = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found', output)
        assert states and int(states[2].replace(',', '')) > 1, (name, 'Nonzero discovery required')
        results.append(dict(name=name, states=states[2], expected=expected,
                            sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest()))
        print('PASS:', name, states[2], flush=True)
        (artifacts/'results.json').write_text(json.dumps(results, indent=2))
    assert len(results) == 9


if __name__ == '__main__':
    main()
