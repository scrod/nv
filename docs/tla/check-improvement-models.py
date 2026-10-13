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
    retention = 'SnapshotRetentionCoverageSafety'
    inv = ['ExactMembership', 'DependencyClosed', 'ExactEdges', 'MaximalFrontier', 'CoverageComplete', 'AcknowledgeDurable']
    safety = ['CapturedImmutable', 'RetainedPreserved', 'SnapshotNeutral', 'ParentRechecked']
    for scenario in ['sameCut', 'differentCut', 'unsupported', 'damage']:
        yield f'retention-{scenario}', retention, scenario, 'safe', inv, safety, None
    for policy, scenario, prop in [('unverified', 'unsupported', 'DependencyClosed'),
            ('clearAll', 'sameCut', 'MaximalFrontier'), ('omitDeps', 'sameCut', 'ExactEdges'),
            ('earlyAck', 'sameCut', 'AcknowledgeDurable'), ('loseBytes', 'sameCut', 'ExactMembership'),
            ('skipRecheck', 'damage', 'ParentRechecked')]:
        yield f'retention-reject-{policy}', retention, scenario, policy, [] if prop == 'ParentRechecked' else [prop], [prop] if prop == 'ParentRechecked' else [], prop
    for scenario, prop in [('sameCut', 'NeverIndependent'), ('differentCut', 'NeverDifferentCut'),
            ('sameCut', 'NeverLostCallback'), ('sameCut', 'NeverFanIn'), ('sameCut', 'NeverFaultThenProgress'),
            ('damage', 'NeverDamagedPreparation'), ('unsupported', 'NeverUnsupportedParentBlocked')]:
        yield f'retention-witness-{prop}', retention, scenario, 'safe', [prop], [], prop
    startup = 'OptionalReadyStartupSafety'
    inv = ['QueueAccounted', 'PublicationRequired']
    safety = ['PublicationExact', 'PublicationInputs', 'SnapshotValidated', 'SnapshotNeutral', 'AcceptedPreserved']
    for scenario in ['healthy', 'prerequisite', 'verify', 'damage', 'late', 'failure']:
        yield f'optional-startup-{scenario}', startup, scenario, 'safe', inv, safety + ['OptionalEventuallySettles', 'LateEventuallySettles'], None
    for policy, scenario, prop in [('hideRequired', 'healthy', 'PublicationRequired'),
            ('earlyPublish', 'healthy', 'PublicationExact'), ('skipVerification', 'verify', 'PublicationRequired'),
            ('lostKick', 'healthy', 'OptionalEventuallySettles'), ('lostWake', 'late', 'LateEventuallySettles'),
            ('loseReady', 'healthy', 'QueueAccounted'), ('unvalidatedSnapshot', 'healthy', 'SnapshotValidated')]:
        action = prop in safety or prop.endswith('Settles')
        yield f'optional-startup-reject-{policy}', startup, scenario, policy, [] if action else [prop], [prop] if action else [], prop
    for scenario, prop in [('healthy', 'NeverPublishedBeforeOptional'), ('healthy', 'NeverRequiredBehindOptional'),
            ('healthy', 'NeverRestartedAndSettled'), ('late', 'NeverWaitedAndResumed')]:
        yield f'optional-startup-witness-{prop}', startup, scenario, 'safe', [prop], [], prop
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
    maintenance = 'PrivateMaintenanceSafety'
    inv = ['BorrowOwned', 'SaveIsolation', 'LateCancellationScoped', 'AcknowledgmentDurable', 'ReopenExact']
    yield 'maintenance-safe', maintenance, 'maintenance', 'safe', inv, ['RequiredEventuallySettles'], None
    for policy, prop in [('prestartInterrupt', 'SaveIsolation'), ('reuseToken', 'LateCancellationScoped'),
                         ('earlyClose', 'BorrowOwned'), ('earlyAck', 'AcknowledgmentDurable'), ('wrongReopen', 'ReopenExact')]:
        yield f'maintenance-reject-{policy}', maintenance, 'maintenance', policy, [prop], [], prop
    for prop in ['NeverContestedSaveRecovered', 'NeverPrestartSaveThenLateCancel']:
        yield f'maintenance-witness-{prop}', maintenance, 'maintenance', 'safe', [prop], [], prop


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
        config = f'SPECIFICATION {"FairSpec" if any(p in props for p in ["EventuallyOpensOrBlocks", "EventuallyComplete", "RequiredEventuallySettles", "OptionalEventuallySettles", "LateEventuallySettles"]) else "Spec"}\n'
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
            # TLC may report its sole temporal obligation as a plural diagnostic.
            temporal_only = not error and not inv and props == [expected] and 'Error: Temporal properties were violated.' in output
            assert run.returncode != 0 and ((error and error[1] == expected) or temporal_only), (name, output[-5000:])
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
