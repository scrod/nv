#!/usr/bin/env python3
"""Bounded snapshot/bootstrap bridge: safety, progress, reached paths and guard mutations."""
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
INVARIANTS = ['ExactAcceptance', 'ClosedHistory', 'CompleteInitial', 'ExactRows', 'ExactContinuation',
              'PrivatePreserved', 'PendingPreserved', 'PublicationFence']


def cases():
    for mode, shared, delete, crashes in [('bootstrap', False, True, 0), ('bootstrap', False, True, 2),
            ('reconstruction', False, True, 0), ('reconstruction', True, True, 0),
            ('reconstruction', False, False, 0), ('reconstruction', True, False, 1)]:
        yield f'safe-{mode}-{shared}-{delete}-{crashes}', mode, shared, delete, crashes, 'safe', INVARIANTS, ['HistoryPreserved', 'InstallCurrent', 'Completes'], None
    for policy, prop, mode in [('earlyBootstrap', 'ExactAcceptance', 'bootstrap'), ('skipTail', 'ExactRows', 'bootstrap'),
            ('sequenceTail', 'ExactRows', 'reconstruction'), ('objectTail', 'ExactRows', 'reconstruction'),
            ('staleInstall', 'InstallCurrent', 'reconstruction'), ('staleEpoch', 'InstallCurrent', 'reconstruction'),
            ('stalePublish', 'PublicationFence', 'reconstruction'),
            ('clearPending', 'PendingPreserved', 'reconstruction'), ('resetPrivate', 'PrivatePreserved', 'reconstruction')]:
        temporal = prop == 'InstallCurrent'
        yield 'mutation-'+policy, mode, True, True, 0, policy, [] if temporal else [prop], [prop] if temporal else [], prop
    for prop in ['NeverEarlyBranch', 'NeverSharedGroup', 'NeverStaleRefused', 'NeverSameHistoryEpoch', 'NeverTwoCrashes']:
        yield 'witness-'+prop, 'reconstruction' if prop != 'NeverTwoCrashes' else 'bootstrap', True, True, 2 if prop == 'NeverTwoCrashes' else 0, 'safe', [prop], [], prop


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', required=True)
    parser.add_argument('--jar', type=Path, required=True)
    parser.add_argument('--only', default='')
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-reconstruction-tla-'))
    print('Artifacts:', artifacts, flush=True)
    source = HERE/'SnapshotReconstructionSafety.tla'
    results = []
    for name, mode, shared, delete, crashes, policy, inv, props, expected in cases():
        if args.only not in name:
            continue
        directory = artifacts/name
        directory.mkdir()
        shutil.copyfile(source, directory/source.name)
        # Model values and finite workloads live in the specialization module.
        module = ('---- MODULE MC ----\nEXTENDS SnapshotReconstructionSafety\n'
                  f'ModeValue == "{mode}"\nSharedValue == {str(shared).upper()}\nDeleteValue == {str(delete).upper()}\n'
                  f'CrashesValue == {crashes}\nPolicyValue == "{policy}"\n====\n')
        (directory/'MC.tla').write_text(module)
        config = f'SPECIFICATION {"FairSpec" if props else "Spec"}\n'
        config += ('CONSTANTS Mode <- ModeValue SharedEnvelope <- SharedValue DeleteTail <- DeleteValue '
                   'MaxCrashes <- CrashesValue Policy <- PolicyValue\nINVARIANT TypeOK\n')
        config += ''.join('INVARIANT '+x+'\n' for x in inv)
        config += ''.join('PROPERTY '+x+'\n' for x in props)
        config += 'CHECK_DEADLOCK FALSE\n'
        (directory/'case.cfg').write_text(config)
        started = time.monotonic()
        command = [args.java, '-Xmx1g', '-XX:+UseParallelGC', '-jar', str(args.jar.resolve()),
                   '-workers', '2', '-lncheck', 'final', '-coverage', '60', '-metadir', 'states', '-config', 'case.cfg', 'MC.tla']
        run = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=args.timeout)
        output = run.stdout+run.stderr
        (directory/'output.log').write_text(output)
        error = re.search(r'(?:Invariant|Temporal property|Action property) ([A-Za-z0-9_]+) is violated', output)
        if expected:
            assert run.returncode != 0 and error and error[1] == expected, (name, output[-5000:])
        else:
            assert run.returncode == 0 and 'Model checking completed. No error has been found.' in output, (name, output[-5000:])
        states = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found', output)
        assert states and int(states[2].replace(',', '')) > 1, (name, 'nonzero state discovery required')
        results.append({'name': name, 'expected': expected, 'states': states[2], 'seconds': time.monotonic()-started,
                        'sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'command': command})
        (artifacts/'results.json').write_text(json.dumps(results, indent=2))
        print('PASS:', name, 'states='+states[2], flush=True)
    assert results, 'No model/configuration discovered'


if __name__ == '__main__':
    main()
