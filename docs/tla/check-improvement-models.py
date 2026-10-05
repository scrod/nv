#!/usr/bin/env python3
"""Exhaustive verification/recovery refinements with exact mutations and witnesses."""
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
    verification = 'VerificationRecoverySafety'
    inv = ['InspectionAdmitted', 'DiscoveredProtected', 'ReopenPublicationGated']
    for scenario in ['healthy', 'bytes', 'late']:
        yield f'verification-{scenario}', verification, scenario, 'safe', inv, ['SiblingPreserved', 'EventuallyOpensOrBlocks', 'CancelledEventuallySettled'], None
    for policy, scenario, prop in [('noAdmission', 'late', 'InspectionAdmitted'),
            ('earlySettlement', 'late', 'DiscoveredProtected'), ('settleSibling', 'late', 'SiblingPreserved'),
            ('skipReplay', 'late', 'ReopenPublicationGated')]:
        yield f'verification-reject-{policy}', verification, scenario, policy, [] if prop == 'SiblingPreserved' else [prop], [prop] if prop == 'SiblingPreserved' else [], prop
    for scenario, prop in [('late', 'NeverFailedDiagnosisReplayed'), ('late', 'NeverSiblingThenLateFailure'), ('healthy', 'NeverHealthyReplay')]:
        yield f'verification-witness-{prop}', verification, scenario, 'safe', [prop], [], prop
    recovery = 'CoalescedRecoverySafety'
    yield 'recovery-safe', recovery, 'coalesced', 'safe', ['RowsAndContextExact', 'PrivateSettingsPreserved', 'PublicationExact'], ['InstallationFresh', 'HistoryPreserved', 'EventuallyComplete'], None
    for policy, prop in [('omitUndo', 'RowsAndContextExact'), ('staleTarget', 'InstallationFresh'),
                         ('staleEpoch', 'InstallationFresh'), ('resetSettings', 'PrivateSettingsPreserved')]:
        yield f'recovery-reject-{policy}', recovery, 'coalesced', policy, [] if prop == 'InstallationFresh' else [prop], [prop] if prop == 'InstallationFresh' else [], prop
    for prop in ['NeverCoalesced', 'NeverRejectedThenRecovered', 'NeverTwoCrashesRecovered']:
        yield f'recovery-witness-{prop}', recovery, 'coalesced', 'safe', [prop], [], prop


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--java', required=True)
    parser.add_argument('--jar', type=Path, required=True)
    parser.add_argument('--only', default='')
    parser.add_argument('--timeout', type=int, default=180)
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-improvements-tla-'))
    print('Artifacts:', artifacts, flush=True)
    results = []
    for name, module, scenario, policy, inv, props, expected in cases():
        if args.only not in name:
            continue
        directory = artifacts/name
        directory.mkdir()
        source = HERE/f'{module}.tla'
        shutil.copyfile(source, directory/source.name)
        (directory/'MC.tla').write_text(f'---- MODULE MC ----\nEXTENDS {module}\nPolicyValue == "{policy}"\nScenarioValue == "{scenario}"\n====\n')
        config = f'SPECIFICATION {"FairSpec" if "EventuallyOpensOrBlocks" in props or "EventuallyComplete" in props else "Spec"}\n'
        config += 'CONSTANTS Policy <- PolicyValue Scenario <- ScenarioValue\nINVARIANT TypeOK\n'
        config += ''.join(f'INVARIANT {x}\n' for x in inv) + ''.join(f'PROPERTY {x}\n' for x in props)
        config += 'CHECK_DEADLOCK FALSE\n'
        (directory/'case.cfg').write_text(config)
        started = time.monotonic()
        command = [args.java, '-Xmx1g', '-XX:+UseParallelGC', '-jar', str(args.jar.resolve()), '-workers', '2',
                   '-lncheck', 'final', '-coverage', '60', '-metadir', 'states', '-config', 'case.cfg', 'MC.tla']
        run = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=args.timeout)
        output = run.stdout + run.stderr
        (directory/'output.log').write_text(output)
        error = re.search(r'(?:Invariant|Temporal property|Action property) (\w+) is violated', output)
        if expected:
            assert run.returncode != 0 and error and error[1] == expected, (name, output[-5000:])
        else:
            assert run.returncode == 0 and 'Model checking completed. No error has been found.' in output, (name, output[-5000:])
        states = re.search(r'([\d,]+) states generated, ([\d,]+) distinct states found', output)
        assert states and int(states[2].replace(',', '')) > 1, (name, 'Nonzero state discovery required')
        results.append({'name': name, 'expected': expected, 'states': states[2], 'seconds': time.monotonic()-started,
                        'sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'command': command})
        (artifacts/'results.json').write_text(json.dumps(results, indent=2))
        print('PASS:', name, 'states='+states[2], flush=True)
    assert results, 'No model/configuration discovered'


if __name__ == '__main__':
    main()
