#!/usr/bin/env python3
"""Finite receive scheduling/recovery checks with targeted controls and witnesses."""
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
    model = 'ReceiveResumptionSafety'
    invariants = ['CurrentValidation', 'ReadyAccounted', 'ClosedAfterOwnedWork',
                  'ReceiveReservation', 'CompletionHasAcceptance']
    properties = ['AcceptedHistoryPreserved', 'ReceiveCompletes', 'QuitSettles']
    for saves in [0, 2, 3]:
        yield dict(name=f'resumption-safe-{saves}', model=model, policy='safe',
                   constants=f'MaxSaves = {saves}', invariants=invariants,
                   properties=properties, fair=True, expected=None)
    for policy, prop, temporal in [
        ('lostWake', 'ReceiveCompletes', True), ('splitWait', 'ReceiveCompletes', True),
        ('waitPending', 'ReceiveCompletes', True), ('waitAlways', 'ReceiveCompletes', True),
        ('staleConsume', 'CurrentValidation', False), ('earlyClose', 'ClosedAfterOwnedWork', False),
        ('cancelDrops', 'ReceiveCompletes', True), ('loseReady', 'ReadyAccounted', False),
        ('returnBusy', 'ReceiveCompletes', True),
        ('lostQuitWake', 'QuitSettles', True), ('waitForQuit', 'ReceiveCompletes', True),
    ]:
        yield dict(name=f'resumption-mutation-{policy}', model=model, policy=policy,
                   constants='MaxSaves = 3', invariants=[] if temporal else [prop],
                   properties=[prop] if temporal else [], fair=temporal, expected=prop)
    for prop in ['NeverExhaustedAndFinished', 'NeverFinishedWithoutWait', 'NeverRewaited',
                 'NeverPendingAndFinished', 'NeverCancelledAndClosed', 'NeverQuitBusy']:
        yield dict(name=f'resumption-witness-{prop}', model=model, policy='safe',
                   constants='MaxSaves = 3', invariants=[prop], properties=[],
                   fair=False, expected=prop)
    model = 'ReceiveRejectionSafety'
    invariants = ['ExactInputRetained', 'QueueAccounted', 'EligibleHasReady',
                  'RejectedSettled', 'OwnRejectionOnly', 'AcceptedClosure', 'AcceptanceHasBytes',
                  'EffectsExactlyOnce', 'WaitEdgesJustified', 'SettledDiagnostics', 'DiagnosticSound']
    properties = ['HistoryPreserved', 'RejectionPreservesHistory', 'EligibleEventuallyAccepted', 'BadEventuallyRejected']
    def rejection(name, policy, topology, kind, crashes, failures, inv, props, expected=None):
        return dict(name='rejection-' + name, model=model, policy=policy,
                    constants=f'Topology = "{topology}" RootKind = "{kind}" MaxCrashes = {crashes} MaxFailures = {failures}',
                    invariants=inv, properties=props, fair=bool(props), expected=expected)
    for topology, kind, crashes, failures in [
        ('chain', 'unsupported', 0, 0), ('chain', 'invalid', 1, 1),
        ('chain', 'unsupported', 1, 1), ('chain', 'valid', 1, 1),
        ('multiple', 'valid', 1, 1), ('multiple', 'unsupported', 1, 1),
        ('chain', 'invalid', 1, 2),
        ('chain', 'invalid', 2, 2), ('multiple', 'valid', 2, 1),
    ]:
        yield rejection(f'safe-{topology}-{kind}-{crashes}-{failures}', 'safe', topology,
                        kind, crashes, failures, invariants, properties)
    for policy, topology, kind, prop in [
        ('splitReject', 'chain', 'invalid', 'RejectedSettled'),
        ('propagate', 'chain', 'unsupported', 'OwnRejectionOnly'),
        ('eraseBytes', 'chain', 'invalid', 'ExactInputRetained'),
        ('lostWake', 'multiple', 'valid', 'EligibleHasReady'),
        ('splitPark', 'multiple', 'valid', 'EligibleHasReady'),
        ('acceptBlocked', 'chain', 'unsupported', 'AcceptedClosure'),
        ('duplicateEffect', 'chain', 'valid', 'EffectsExactlyOnce'),
        ('dropReady', 'chain', 'invalid', 'QueueAccounted'),
        ('ioIsRejection', 'chain', 'valid', 'OwnRejectionOnly'),
        ('directOnly', 'chain', 'unsupported', 'SettledDiagnostics'),
    ]:
        yield rejection('mutation-' + policy, policy, topology, kind, 1, 1, [prop], [], prop)
    yield rejection('mutation-rejectAltersHistory', 'rejectAltersHistory', 'chain', 'invalid',
                    1, 1, [], ['RejectionPreservesHistory'], 'RejectionPreservesHistory')
    for prop, topology, kind, crashes, failures in [
        ('NeverBlockedChainAndIndependent', 'chain', 'unsupported', 1, 1),
        ('NeverPartialWake', 'multiple', 'valid', 1, 1),
        ('NeverRecoveredRejection', 'chain', 'invalid', 1, 1),
        ('NeverRecoveredValidChain', 'chain', 'valid', 1, 1),
        ('NeverFailedTwiceAndSettled', 'chain', 'invalid', 1, 2),
        ('NeverBothRejectionCrashCuts', 'chain', 'invalid', 2, 1),
        ('NeverLostRejectionCompletion', 'chain', 'invalid', 1, 1),
    ]:
        yield rejection('witness-' + prop, 'safe', topology, kind, crashes, failures, [prop], [], prop)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', required=True)
    parser.add_argument('--jar', type=Path, required=True)
    parser.add_argument('--only', default='')
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix='nv-receive-tla-'))
    print('Artifacts:', root, flush=True)
    results = []
    for case in cases():
        if args.only not in case['name']:
            continue
        directory = root / case['name']
        directory.mkdir()
        source = HERE / (case['model'] + '.tla')
        shutil.copyfile(source, directory / source.name)
        config = f'SPECIFICATION {"FairSpec" if case["fair"] else "Spec"}\n'
        config += f'CONSTANTS Policy = "{case["policy"]}" {case["constants"]}\n'
        config += 'INVARIANT TypeOK\n'
        config += ''.join('INVARIANT ' + p + '\n' for p in case['invariants'])
        config += ''.join('PROPERTY ' + p + '\n' for p in case['properties'])
        config += 'CHECK_DEADLOCK FALSE\n'
        (directory / 'case.cfg').write_text(config)
        started = time.monotonic()
        command = [args.java, '-Xmx1g', '-XX:+UseParallelGC', '-jar', str(args.jar.resolve()),
                   '-workers', '2', '-lncheck', 'final', '-coverage', '60',
                   '-metadir', 'states', '-config', 'case.cfg', source.name]
        try:
            run = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=args.timeout)
            output, code = run.stdout + run.stderr, run.returncode
        except subprocess.TimeoutExpired as error:
            output = error.stdout or ''
            if isinstance(output, bytes):
                output = output.decode(errors='replace')
            code = None
        (directory / 'tlc.log').write_text(output)
        stats = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue', output)
        complete = code == 0 and 'Model checking completed. No error has been found.' in output and stats and stats[3] == '0'
        prop = case['expected']
        failure = prop and code not in (None, 0) and (
            f'Invariant {prop} is violated.' in output or f'Action property {prop} is violated.' in output or
            (case['properties'] == [prop] and
             (f'Temporal property {prop} was violated.' in output or 'Temporal properties were violated.' in output) and
             'The following behavior constitutes a counter-example' in output))
        result = dict(name=case['name'], passed=bool(failure if prop else complete),
                      expected=prop or 'exhaustive', exit=code,
                      seconds=round(time.monotonic()-started, 2),
                      states=int(stats[2].replace(',', '')) if stats else None,
                      source_sha256=hashlib.sha256(source.read_bytes()).hexdigest())
        results.append(result)
        print(json.dumps(result), flush=True)
        (root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    if not results:
        parser.error('no matching cases')
    return 0 if all(r['passed'] for r in results) else 1


if __name__ == '__main__':
    raise SystemExit(main())
