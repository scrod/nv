#!/usr/bin/env python3
"""Run the local storage qualification slice through the existing test entrypoints."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import subprocess
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='debug')
    parser.add_argument('--mutations', action='store_true')
    args = parser.parse_args()
    artifacts = Path(tempfile.mkdtemp(prefix='nv-storage-phase2-'))
    print('Artifacts:', artifacts, flush=True)
    os.environ['PKG_CONFIG_PATH'] = str(ROOT/'NVStorage/.deps/sqlcipher/lib/pkgconfig') + os.pathsep + os.environ.get('PKG_CONFIG_PATH', '')
    results = []

    def run(name, command, timeout=900):
        print('Running', name, flush=True)
        with (artifacts/(name+'.log')).open('w') as output:
            result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
        log = (artifacts/(name+'.log')).read_text()
        assert result.returncode == 0, (name, artifacts/(name+'.log'), log[-3000:])
        results.append({'name': name, 'command': command, 'returncode': result.returncode})
        return log

    schema = ROOT/'docs/impl-proposal-5/plan/sqlite-local-schema.sql'
    assert schema.read_bytes() == (ROOT/'NVStorage/Sources/NVStorageRuntime/Resources/SchemaV1.sql').read_bytes()
    suite = run('swift', ['make', '-C', 'tests', 'run-swift-storage', f'SWIFT_STORAGE_TEST_FLAGS=-c {args.configuration}'])
    required = {'ordinaryEditDeleteAndCreateReopen', 'oldCompletionPreservesNewerPendingWork',
                'durableDependencyWakeupsAndRepackagedOperations', 'acceptanceAndOlderSettingsPreserveExactRetention',
                'ordinaryValidationUsesExactWriterBasisAndPreservesOriginForks', 'concurrentHistoryIsRetainedButRequiresLaterReducer',
                'discoveredRequiredHistoryDamageBlocksPreparedPublication',
                'ownedEncryptedCandidateBoundary', 'encryptedProtectionCrossesTaskBoundaries',
                'zstdProviderProfileRejectsOtherFrames', 'authenticatedZstdProfileChecks',
                'currentBasisAgreesWithFullValidation', 'currentBasisRejectsNearValidClaims',
                'currentBasisRequiresCompleteMaterialization', 'currentBasisPreservesBranchFrontiers',
                'currentBasisChecksHistoricalBirthReuse',
                'rejectedParkedChildPreservesIndependentProgress', 'receiveRejectionClassifiesOnlyDefiniteInputFailures',
                'historicalValidationYieldsToSaveAndRechecksHistory', 'catchUpCommitsOneCompletePrefixAtATime',
                'historyReadRejectsStalePrefix', 'actorAcceptanceRechecksAfterFinalHistoryRead',
                'abandonedDatabaseOwnerReleasesLeaseAndPreservesRows', 'malformedPayloadIsRetainedAndRejectedAcrossReopen',
                'misaddressedReceiveDependencyIsIsolated',
                'validationResumesAfterTwoInterferingSaves', 'historyInterferenceRetainsItsOwnFailureCategory',
                'rejectedPrerequisitesRemainDistinctFromMissingAndInvalidDescendants',
                'rejectionCleanupFailureKeepsRetryableBytes',
                'reopenRebuildsDamagedViewBeforeDrainingReadyHistory',
                'ordinarySaveWorkAcrossGrowingHistory', 'incrementalFrontierMatchesIndependentReachability'}
    discovered = set(re.findall(r'Test (\w+)\([^\n]*\)(?: started\.|(?: with [0-9]+ test cases)? passed after)', suite))
    assert required.issubset(discovered) and re.search(r'Test run with [1-9][0-9]* tests .*passed', suite), 'Required Swift test discovery missing'
    binary_dir = ROOT/'NVStorage/.build'/args.configuration
    # Child-process qualification uses one stable executable even during later builds.
    qualified = artifacts/'NVStorageProbe'
    shutil.copy2(binary_dir/'NVStorageProbe', qualified)
    if sys.platform == 'linux':
        run('elf-permissions', ['python3', 'tools/check-storage-elf.py', str(binary_dir/'NVStorageProbe')])
    run('zstd-writer', ['node', 'tools/check-zstd-frames.mjs', str(qualified)])
    run('process', ['python3', 'tools/test-storage-process.py', '--binary', str(qualified)])
    run('generated', ['python3', 'tools/test-storage-generated.py', '--binary', str(qualified)])
    run('rejection', ['python3', 'tools/test-storage-rejection.py', '--binary', str(qualified)])
    run('cipher-cold-start', ['python3', 'tools/test-sqlcipher-cold-start.py'])
    run('core-types', ['python3', 'tools/test-swift-storage-types.py', '--modules', str(binary_dir/'Modules')])
    run('runtime-types', ['python3', 'tools/test-storage-runtime-types.py', '--modules', str(binary_dir/'Modules')])
    run('schema', ['make', '-C', 'tests', 'run-sqlite-schema'])
    for fixture in ['initial-bootstrap', 'initial-snapshot', 'recovery-artifact', 'current-state']:
        run(fixture, ['python3', f'tools/check-{fixture}-fixtures.py'])
    run('envelopes', ['node', 'tools/check-envelope-fixtures.mjs'])
    run('descriptors', ['node', 'tools/check-envelope-fixtures.mjs', '--descriptors'])
    for name, source, includes in [
        ('owner-c', 'NVStorage/Sources/CStorageIO/NVStorageIO.c', ['NVStorage/Sources/CStorageIO/include']),
        ('fault-c', 'NVStorage/Tests/Support/CStorageFaults/NVStorageFaults.c',
         ['NVStorage/Tests/Support/CStorageFaults/include', 'NVStorage/.deps/sqlcipher/include'])
    ]:
        run(name, ['clang', '-std=c11', '-Wall', '-Wextra', '-Wconversion', '-Werror', '-fsyntax-only', source, *['-I'+p for p in includes]])
    if args.mutations:
        run('zstd-mutations', ['python3', 'tools/test-zstd-mutations.py', '--configuration', args.configuration], timeout=1800)
        run('bootstrap-mutations', ['python3', 'tools/test-bootstrap-mutations.py', '--configuration', args.configuration], timeout=1800)
        run('runtime-mutations', ['python3', 'tools/test-storage-runtime-mutations.py', '--configuration', args.configuration], timeout=1800)
    report = {'configuration': args.configuration, 'discovered': sorted(discovered), 'results': results,
              'schema_sha256': hashlib.sha256(schema.read_bytes()).hexdigest(),
              'qualification_limits': ['physical power loss', 'additional platform coverage requires the separate platform campaign', 'provider and UI integration']}
    (artifacts/'results.json').write_text(json.dumps(report, indent=2))
    print('PASS:', len(results), 'qualification commands;', len(discovered), 'Swift tests discovered', flush=True)


if __name__ == '__main__':
    main()
