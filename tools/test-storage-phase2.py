#!/usr/bin/env python3
"""Run the local storage qualification slice through the existing test entrypoints."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
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
    fixture_names = ['initial-bootstrap', 'initial-snapshot', 'recovery-artifact', 'current-state',
                     'restoration', 'merge', 'derived-state', 'connected-record', 'current-cell', 'general-snapshot', 'verification', 'private-record']
    for fixture in fixture_names:
        checker = ROOT/'tools'/f'check-{fixture}-fixtures.py'
        assert checker.is_file(), ('Missing fixture checker', checker)
    artifacts = Path(tempfile.mkdtemp(prefix='nv-storage-phase2-'))
    print('Artifacts:', artifacts, flush=True)
    os.environ['PKG_CONFIG_PATH'] = str(ROOT/'NVStorage/.deps/sqlcipher/lib/pkgconfig') + os.pathsep + os.environ.get('PKG_CONFIG_PATH', '')
    results = []

    def run(name, command, timeout=900):
        print('Running', name, flush=True)
        with (artifacts/(name+'.log')).open('w') as output:
            with subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                  start_new_session=True) as process:
                try:
                    code = process.wait(timeout=timeout)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait()
                    raise
        # Preserve raw logs; concurrent diagnostic streams can split a UTF-8 glyph.
        log = (artifacts/(name+'.log')).read_text(errors='replace')
        assert code == 0, (name, artifacts/(name+'.log'), log[-3000:])
        results.append({'name': name, 'command': command, 'returncode': code})
        return log

    schema = ROOT/'docs/impl-proposal-5/plan/sqlite-local-schema.sql'
    assert schema.read_bytes() == (ROOT/'NVStorage/Sources/NVStorageRuntime/Resources/SchemaV1.sql').read_bytes()
    # Each scheduling test arranges its own concurrent tasks and contested transitions.
    # Serial top-level execution gives their watchdogs a reproducible resource budget.
    suite = run('swift', ['make', '-C', 'tests', 'run-swift-storage', f'SWIFT_STORAGE_TEST_FLAGS=-c {args.configuration} --no-parallel'], timeout=1800)
    assert 'Build complete!' in suite and 'Build cancelled!' not in suite, 'SwiftPM must finish building the tested sources'
    required = {'ordinaryEditDeleteAndCreateReopen', 'oldCompletionPreservesNewerPendingWork',
                'privateRecordIndependentBytesAndBounds',
                'privateSettingsRebuildAndStaleGenerations', 'pendingImportLostReceiptSurvivesDeleteAndNewPreview',
                'pendingFailureIsolationAndNeutralCompletion', 'pendingCompetingReviewReusesBirthAndCommitsOnce',
                'preservedRepairWaitsForPendingReservationOwner',
                'backupCancellationSettlesReaderAndReservation',
                'backupReopensCapturedReadyHistoryWithoutMixingLaterWrites', 'backupRebuildsDerivedRowsAfterCapturedDelete',
                'pendingChangedAssociationAndNeutralFactoryReopen', 'privateHealthUsesActualOpeningBoundary',
                'neutralPendingRequiresFreshRepresentedState', 'neutralPendingWaitsForAcceptedDeleteMaterialization',
                'fixedPrivateBackupIncludesWALAndPendingCut', 'backupBudgetReleasesReaderAndKeepsSourceWritable',
                'complementaryRepairPreservesUnpublishedHistoryAndPrivateInputs',
                'repairedVerificationUsesMembershipRatherThanCopiedSequence',
                'encryptedPageSalvageKeepsIndependentCommittedRows', 'partialPrivateSalvageContinuesIndependentReads',
                'repairPreservesReceiveClassesAndWakesComplementedDependencies',
                'complementaryRepairKeepsConflictRestoreAndCausalRedo',
                'verifiedSelectionActivationAndFreshReopen',
                'selectionFaultKeepsBothStoresAndHonestReadback',
                'selectionRefusesWrongOwnerStaleRecordAndNewSourceWAL',
                'repositoryOnlyCopyPreservesLockedBytesMetadataAndUnknownFiles',
                'repositoryCopyReportsChangingOrUnsafeInputs',
                'activeRecoveryCopyIncludesUnpublishedHistoryAndKeepsPrivateBuffers',
                'explicitCurrentExportHasFreshBirthsAndUsableCredentials',
                'verificationRecipeLiteralLayout', 'verificationCancellationReplaysExactScope',
                'verificationFinalCheckKeepsFailedDiagnosisReplay', 'verificationAdmissionFailureStartsNoInspection',
                'verificationWrongConnectionCannotReusePermission', 'verificationResumesWithoutAnotherDelivery',
                'verificationSiblingSettlementPreservesOtherRequest', 'verificationFailedSettlementRetainsExactIdentity',
                'verificationRequiredStateRejectsInvalidReplay', 'traversalScopesAuditRepackagedOccurrencesOnce',
                'verificationAdmissionBoundPreservesOwnedRequests', 'verificationFinalGraphFailureSurvivesFailedDiagnosis',
                'verificationReplayIncludesAcceptedSnapshotPages',
                'batchedReaderMatchesRecordReferenceAndIndependentValues',
                'mixedOpeningRecoveryPreservesConnectedHistory',
                'compensationVerificationAdmissionFailurePreservesCommand',
                'traversalDetectsExactIndexedRelationshipDamage', 'recoveryGraphPreparationRechecksFinalContext',
                'materializationRoutingCoversEverySupportedVariant', 'returningOpenDecodesCurrentCellsOnce',
                'currentProvenanceKeepsValidNeighborsAndRejectsMixedClaims',
                'optionalReadySnapshotKeepsReturningOpenHistoryBounded', 'repeatedSnapshotsKeepReturningOpenLeafWorkBounded',
                'scopedCommandsAvoidUnrelatedHistoryBodies', 'packedBootstrapGraphDecodesEachEnvelopeOnce',
                'unappliedCompensationBatchesRecoverEveryAction', 'nonfrontierHistoryDamageSurvivesMarkerFailureAndRestart',
                'initialSnapshotLayoutsAndCommitments', 'initialFlatManifestNearestByteLimits',
                'packedBootstrapReadersAgreeOnCompleteGroups', 'bootstrapCandidateResumesExactIncompleteCommitment',
                'productionIncrementalBootstrapReopensEditable', 'bootstrapAndSnapshotPreserveIncidentalOrdinaryGroups',
                'reconstructionIncludesBranchesOnBothSidesOfSnapshotAcceptance',
        'reconstructionRepreparesAfterSaveAndPreservesLivePendingWork',
        'reconstructionRechecksSameHistoryEpochAndKeepsPrivateGenerations',
        'reconstructionKeepsBodyEqualContinuationAndUndoTargets',
        'reconstructionDistinguishesDisposableRowsFromRequiredLoss',
                'generalSnapshotLiteralLayoutsAndBounds', 'generalSnapshotCrossPageRecordsAndManifest',
                'generalSnapshotMissingPagesNameExactInputs', 'generalSnapshotAuthenticFramingDefects',
                'generalSnapshotCancellationPreservesExplicitOutcome', 'generalSnapshotCancellationBetweenPagesKeepsExactOutput',
                'generalSnapshotClaimsMatchRealHistory', 'generalSnapshotRejectsAuthenticWrongClaims',
                'generalSnapshotOldCutKeepsLaterBranchAndExactMissingHistory',
                'generalSnapshotCopiesPreserveDispositionAndRetirement', 'generalSnapshotActualConsumerChecksProfileAndLifecycle',
                'generalSnapshotRejectsPartialActionCut', 'generalSnapshotTransportMembershipKeepsUnrepresentedGroup',
                'generalSnapshotDetectsUnindexedAcceptedLeaf',
                'snapshotAcceptancePreservesValuesAndCompletePin', 'snapshotWorkYieldsToNewerOrdinarySave',
                'snapshotRetriesExactBytesAfterLostCompletion', 'snapshotCaptureAndRetryRequireTheIssuingOwner',
                'snapshotRootReadyRecoveryUsesRetainedExactCandidates', 'snapshotReadySemanticRejectionPreservesUnrelatedHistory',
                'snapshotCancellationRetainsCandidatesAndAllowsOrdinarySaving', 'snapshotRequiredPageDamageRevokesEditablePublication',
                'snapshotOptionalWorkAllowsDurableClose',
                'receivedSnapshotPermutationsRetainCompleteEvidence', 'receivedSnapshotDiscoversDeeperPagesAndUnacceptedHistory',
                'receivedSnapshotParkingRechecksConcurrentArrivals', 'receivedSnapshotRejectionPreservesSharedPagesAndHealthyHistory',
                'receivedSnapshotUnsupportedChildBlocksOnlyItsDependents', 'receivedSnapshotOptionalClosePreservesOwnedInputs',
                'receivedSnapshotCancellationPreservesRetryAndCurrent', 'receivedSnapshotRepeatedRecordingFailuresPreserveRetry',
                'receivedSnapshotRequiredDamageStaysBlockedDespiteMarkerFailure', 'receivedSnapshotContinuationClaimsPreserveCommandBehavior',
                'receivedSnapshotPreparationKeepsProgressAcrossLocalSaves', 'receivedSnapshotGrowingHistoryMeasuresCompleteWork',
                'receivedInitialSnapshotUsesCompleteBootstrapValidation',
                'receivedSnapshotWideHeadsKeepEveryBranch',
                'runtimeMergeBoundaryPreservesValidHistory', 'thirdWriterFencesPreparedMergeAndPreservesUnchosenHeads',
                'compensationCompletionPreservesNewerPendingGeneration',
                'derivedStateLiteralLayoutAndReconstruction', 'derivedStateMalformedEncodingAndLocalRebinding',
                'derivedStateExactEvidenceAndWrongContext', 'derivedStateChangedGraphAndUnchosenAlternatives',
                'derivedStateChecksUniqueBaseAndClaimKind',
                'mergeScalarLabelsAndDates', 'mergeGeneratedEditCoordinates', 'mergeExactTextAndLimits',
                'mergeGraphSelectionAndProvenance', 'mergeEqualHeadsAndRejectedGraphInputs',
                'mergeExhaustiveRootedDAGs', 'mergeLiteralIdentityFixture',
                'mergePreviewAcrossIndependentStores', 'mergePreviewDamageAndClosedOwner', 'mergePreviewRejectsDamagedMembership',
                'restorationPersistsExactEntryAcrossDeliveryAndReopen', 'concurrentRestoresKeepBothFreshBirths',
                'restorationBatchScopeContextAndOrdinaryCopies', 'restorationRejectsNearValidSources',
                'restorationNamesOneOfConcurrentDeletionActions',
                'literalRestorationActionAndCanonicalSources',
                'historySurvivesReorderedDeliveryAndReopen', 'historyPagesFreezeTheirPrefixAndCheckConsumers',
                'historyListingIsMetadataOnlyAndPreviewDetectsDamage', 'historyPreservesConcurrentBranchIdentities',
                'durableDependencyWakeupsAndRepackagedOperations', 'acceptanceAndOlderSettingsPreserveExactRetention',
                'ordinaryValidationUsesExactWriterBasisAndPreservesOriginForks', 'concurrentHistoryIsRetainedAndReopensEditable',
                'deleteCoverageRetractsOnlyUntouchedPreservation', 'independentAutomaticEditSurvivesLateCoverageAndRetirement',
                'reciprocalCopiesKeepSourceAndDurableDispositions', 'mergedDeleteRestoresExactStateAndSelectedPriorBranch',
                'sourceChoiceFencesConsentAndHistoryFieldsStayExplicit', 'orderedUndoRedoKeepsActualValuesAndRemainingTail',
                'concurrentCompensationsNoOpAndIndependentFamily', 'reviewedCompensationRejectsChangedScopeButAllowsUnrelatedWork',
                'concurrentDeleteUndoKeepsFreshBirthMappings', 'nativeRemainingEffectAndActualRedoSurviveReopen',
                'incomparableNativeCoveragePreservesRemainingFamily', 'connectedRecordLiteralLayoutsAndIdentities',
                'extendedCurrentCellsAndFullRestoreHaveIndependentBytes',
                'connectedCommandsRejectAuthenticatedNearValidClaims', 'completeNamedActionRejectsOneWrongMemberAtomically',
                'conflictCopySlotsVerifyStateAndRetainExactRetries', 'ordinaryIdentityCollisionPreservesFileAndSkipsRecoverySlot',
                'ordinaryConflictEditPreservesKnownUnchosenHeads', 'equalAutomaticKeyNeedsEverySourceCovered',
                'independentPreservationAdmissionFencesRetractionPublication', 'namedCompensationKeepsAllMembersAndRejectsStaleApproval',
                'discoveredRequiredHistoryDamageBlocksPreparedPublication',
                'ownedEncryptedCandidateBoundary', 'cipherSchemaRequiresIntegralHistoryTags', 'encryptedProtectionCrossesTaskBoundaries',
                'zstdProviderProfileRejectsOtherFrames', 'authenticatedZstdProfileChecks',
                'currentBasisAgreesWithFullValidation', 'currentBasisRejectsNearValidClaims',
                'currentBasisRequiresCompleteMaterialization', 'currentBasisPreservesBranchFrontiers',
                'currentBasisChecksHistoricalBirthReuse',
                'rejectedParkedChildPreservesIndependentProgress', 'receiveRejectionClassifiesOnlyDefiniteInputFailures',
                'historicalValidationYieldsToSaveAndRechecksHistory', 'catchUpCommitsOneCompletePrefixAtATime',
                'historyReadRejectsStalePrefix', 'actorAcceptanceRechecksAfterFinalHistoryRead',
                'abandonedDatabaseOwnerReleasesLeaseAndPreservesRows', 'malformedPayloadIsRetainedAndRejectedAcrossReopen',
                'databaseDisposalOnOwningQueueReleasesImmediately',
                'misaddressedReceiveDependencyIsIsolated',
                'validationResumesAfterTwoInterferingSaves', 'historyInterferenceRetainsItsOwnFailureCategory',
                'connectedParkedCopyResumesAfterFiniteSaveInterference',
                'rejectedPrerequisitesRemainDistinctFromMissingAndInvalidDescendants',
                'rejectionCleanupFailureKeepsRetryableBytes',
                'reopenRebuildsDamagedViewBeforeDrainingReadyHistory',
                'historicalRecoveryAdoptsAutomaticNoteAndKeepsSaving',
                'currentCreationDateAgreesAcrossIncrementalReductionAndRebuild',
                'specializedCaptureRequiresProvenanceBeforeAdmission',
                'typedCompensationPreservesReviewIntentAndContext', 'validatedBatchesRetainExactObjectMembership',
                'receiveRejectionMatchesIndependentCodes',
                'definitiveCaptureEncodingFailureReturnsInputWithoutBlockingSaves',
                'commandCalculationYieldsToLocalSave', 'commandCalculationChecksCloseAndCancellation',
                'changedNoteDuringCommandCalculationRequiresNewApproval',
                'undoQueryMatchesIndependentSmallGraphClosure', 'undoQueryLinearHistoryKeepsLatestCandidate',
                'undoQueryRejectsBrokenScopeGraph',
                'ordinarySaveWorkAcrossGrowingHistory', 'incrementalFrontierMatchesIndependentReachability'}
    discovered = set(re.findall(r'Test (\w+)\([^\n]*\) (?:started\.|(?:with [1-9][0-9]* test cases? )?(?:passed|failed) after [0-9]+(?:\.[0-9]+)? seconds\b)', suite))
    assert required.issubset(discovered) and re.search(r'Test run with [1-9][0-9]* tests .*passed', suite), 'Required Swift test discovery missing'
    probe_command = ['swift', 'build', '--build-system', 'native', '--package-path', str(ROOT/'NVStorage'),
                     '--configuration', args.configuration, '--product', 'NVStorageProbe']
    if sys.platform == 'linux':
        probe_command += ['--use-integrated-swift-driver', '--disable-build-manifest-caching',
                          '-Xswiftc', '-use-ld=lld', '-Xlinker', '-z', '-Xlinker', 'relro',
                          '-Xlinker', '-z', '-Xlinker', 'now']
    probe_log = run('probe-build', probe_command)
    assert "Build of product 'NVStorageProbe' complete!" in probe_log and 'cancelled!' not in probe_log, 'The qualified child must be built from current production sources'
    binary_dir = ROOT/'NVStorage/.build'/args.configuration
    # Child-process qualification uses one stable executable even during later builds.
    qualified = artifacts/'NVStorageProbe'
    shutil.copy2(binary_dir/'NVStorageProbe', qualified)
    for resource in [*binary_dir.glob('*.bundle'), *binary_dir.glob('*.resources')]:
        shutil.copytree(resource, artifacts/resource.name)
    if sys.platform == 'linux':
        run('elf-permissions', ['python3', 'tools/check-storage-elf.py', str(binary_dir/'NVStorageProbe')])
    run('zstd-writer', ['node', 'tools/check-zstd-frames.mjs', str(qualified)])
    run('process', ['python3', 'tools/test-storage-process.py', '--binary', str(qualified)])
    run('review-process', ['python3', 'tools/test-storage-review-process.py', '--binary', str(qualified)])
    run('disposal-process', ['python3', 'tools/test-storage-disposal-process.py', '--binary', str(qualified)])
    run('history-process', ['python3', 'tools/test-storage-history-process.py', '--binary', str(qualified)])
    run('snapshot-process', ['python3', 'tools/test-storage-snapshot-process.py', '--binary', str(qualified)])
    run('received-snapshot-process', ['python3', 'tools/test-storage-received-snapshot-process.py', '--binary', str(qualified)])
    run('bootstrap-reconstruction-process', ['python3', 'tools/test-storage-bootstrap-reconstruction-process.py', '--binary', str(qualified)])
    run('private-process', ['python3', 'tools/test-storage-private-process.py', '--binary', str(qualified)])
    run('restoration-process', ['python3', 'tools/test-storage-restoration-process.py', '--binary', str(qualified)])
    run('merge-process', ['python3', 'tools/test-storage-merge-process.py', '--binary', str(qualified)])
    run('phase3-process', ['python3', 'tools/test-storage-phase3-process.py', '--binary', str(qualified)], timeout=7200)
    run('generated', ['python3', 'tools/test-storage-generated.py', '--binary', str(qualified)])
    run('rejection', ['python3', 'tools/test-storage-rejection.py', '--binary', str(qualified)])
    run('cipher-cold-start', ['python3', 'tools/test-sqlcipher-cold-start.py'])
    run('core-types', ['python3', 'tools/test-swift-storage-types.py', '--modules', str(binary_dir/'Modules')])
    run('runtime-types', ['python3', 'tools/test-storage-runtime-types.py', '--modules', str(binary_dir/'Modules')])
    run('private-types', ['python3', 'tools/test-storage-private-types.py', '--modules', str(binary_dir/'Modules')])
    run('schema', ['make', '-C', 'tests', 'run-sqlite-schema'])
    for fixture in fixture_names:
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
        run('runtime-mutations', ['python3', 'tools/test-storage-runtime-mutations.py', '--configuration', args.configuration], timeout=14400)
    report = {'configuration': args.configuration, 'discovered': sorted(discovered), 'results': results,
              'schema_sha256': hashlib.sha256(schema.read_bytes()).hexdigest(),
              'qualification_limits': ['physical power loss', 'additional platform coverage requires the separate platform campaign', 'provider and UI integration',
                  'deferred scoped reads, repeated row decoding, optional snapshots and snapshot-root retention growth; see phase-4-improvements/benchmark-backlog.md']}
    (artifacts/'results.json').write_text(json.dumps(report, indent=2))
    print('PASS:', len(results), 'qualification commands;', len(discovered), 'Swift tests discovered', flush=True)


if __name__ == '__main__':
    main()
