#!/usr/bin/env python3
"""Run the local storage qualification slice through the existing test entrypoints."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import sys
import subprocess
import shutil
import tempfile
import time
from qualification_reuse import CAMPAIGN_ENV, CampaignReuse

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--configuration', choices=['debug', 'release', 'both'], default='debug')
    parser.add_argument('--reuse-directory', type=Path,
                        help='Share verified builds, independent check results and compiler caches within this campaign.')
    parser.add_argument('--mutations', action='store_true')
    parser.add_argument('--scratch-path', type=Path, help='Use an isolated Swift build directory for this qualification campaign.')
    parser.add_argument('--suite-timeout', type=int, default=3600,
                        help='Whole Swift-suite resource budget in seconds; individual test watchdogs remain unchanged.')
    parser.add_argument('--compiler-suite-timeout', type=int, default=3600,
                        help='Per compiler-campaign resource budget in seconds; individual probe deadlines and checks remain unchanged.')
    args = parser.parse_args()
    if args.suite_timeout < 1:
        parser.error('--suite-timeout must be positive')
    if args.compiler_suite_timeout < 1:
        parser.error('--compiler-suite-timeout must be positive')
    fixture_names = ['initial-bootstrap', 'initial-snapshot', 'recovery-artifact', 'current-state',
                     'restoration', 'merge', 'derived-state', 'connected-record', 'current-cell', 'general-snapshot', 'verification', 'private-record']
    for fixture in fixture_names:
        checker = ROOT/'tools'/f'check-{fixture}-fixtures.py'
        assert checker.is_file(), ('Missing fixture checker', checker)
    artifacts = Path(tempfile.mkdtemp(prefix='nv-storage-phase2-'))
    print('Artifacts:', artifacts, flush=True)
    os.environ['PKG_CONFIG_PATH'] = str(ROOT/'NVStorage/.deps/sqlcipher/lib/pkgconfig') + os.pathsep + os.environ.get('PKG_CONFIG_PATH', '')
    reuse = CampaignReuse(args.reuse_directory or artifacts/'reuse')
    os.environ[CAMPAIGN_ENV] = str(reuse.directory)
    independent_inputs = [ROOT/'tools', ROOT/'tests', ROOT/'NVStorage/Sources', ROOT/'NVStorage/Tests',
                          ROOT/'NVStorage/Vendor', ROOT/'NVStorage/.deps/sqlcipher/include',
                          ROOT/'docs/impl-proposal-5/plan']
    results = []

    def run(name, command, timeout=900):
        print('Running', name, flush=True)
        path = artifacts/(name+'.log')
        started = time.monotonic()

        def execute():
            with path.open('w') as output:
                with subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                      start_new_session=True) as process:
                    try:
                        code = process.wait(timeout=timeout)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGTERM)
                        process.wait()
                        raise
            assert code == 0, (name, path, path.read_text(errors='replace')[-3000:])

        execute()
        # Preserve raw logs; concurrent diagnostic streams can split a UTF-8 glyph.
        log = path.read_text(errors='replace')
        results.append({'name': name, 'command': command, 'returncode': 0,
                        'seconds': time.monotonic()-started, 'reused': False})
        return log

    if args.configuration == 'both':
        for configuration in ('debug', 'release'):
            command = [sys.executable, str(Path(__file__).resolve()), '--configuration', configuration,
                       '--reuse-directory', str(reuse.directory), '--suite-timeout', str(args.suite_timeout),
                       '--compiler-suite-timeout', str(args.compiler_suite_timeout)]
            if args.scratch_path:
                command += ['--scratch-path', str(args.scratch_path.resolve())]
            if args.mutations:
                command.append('--mutations')
            run(configuration, command, timeout=args.suite_timeout + 4*args.compiler_suite_timeout + 28800)
        (artifacts/'results.json').write_text(json.dumps({'configuration': 'both', 'results': results,
            'reuse_directory': str(reuse.directory)}, indent=2))
        print('PASS: complete debug and release campaigns; shared exact independent evidence', flush=True)
        return

    schema = ROOT/'docs/impl-proposal-5/plan/sqlite-local-schema.sql'
    assert schema.read_bytes() == (ROOT/'NVStorage/Sources/NVStorageRuntime/Resources/SchemaV1.sql').read_bytes()
    run('qualification-reuse', ['python3', 'tools/test-qualification-reuse.py'])
    run('maintenance-c', ['python3', 'tools/test-sql-maintenance.py'])
    run('maintenance-privacy', ['python3', 'tools/test-sql-maintenance-privacy.py'])
    # Each scheduling test arranges its own concurrent tasks and contested transitions.
    # Serial top-level execution gives their watchdogs a reproducible resource budget.
    test_flags = f'-c {args.configuration} --no-parallel'
    if args.scratch_path:
        test_flags += ' --scratch-path ' + shlex.quote(str(args.scratch_path.resolve()))
    suite = run('swift', ['make', '-C', 'tests', 'run-swift-storage', 'SWIFT_STORAGE_TEST_FLAGS=' + test_flags], timeout=args.suite_timeout)
    assert 'Build complete!' in suite and 'Build cancelled!' not in suite, 'SwiftPM must finish building the tested sources'
    required = {'ordinaryEditDeleteAndCreateReopen', 'oldCompletionPreservesNewerPendingWork',
                'connectionContextReusesFixedChecks', 'connectionCandidateChecksRequireCompleteBootstrap',
                'connectionOwnershipChecksFenceResultsAndPermitExactRetry', 'connectionDelayedCommitKeepsHistoricalReceipt',
                'connectionReconstructionRechecksRequiredPrivateInputs',
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
                'privateCurrentFrameIndependentBytesAndBounds', 'privateCurrentDictionaryDigestAndTrainingBounds',
                'privateCurrentDictionaryIndependentFrameAndBinding', 'currentFramesReopenAndPreserveExactHistory',
                'currentRecodeRejectsStalePreparation', 'currentDerivedDamageRebuildsWithoutPrivateOrHistoryLoss',
                'openingCaptureRechecksNewHistoryAndSamePrefixView',
                'currentDictionaryMixedRowsBackupAndBoundedLoading', 'currentRecodeRollbackPreservesDictionaryAndLogicalCut',
                'privateCurrentDictionaryWorkingSetStreamsManyGenerations',
                'vacuumPreservesCompletePrivateCutAndFreshReopen', 'resumedSaveCancelsPreparedVacuumAndKeepsExactReceipt',
                'vacuumCancellationAndCloseRetainOwnerUntilSettled', 'vacuumBudgetsSkipWithoutChangingRequiredState',
                'vacuumRequestRequiresIssuingConnectionBeforeRetirement', 'currentRecodeRejectsForeignSnapshotBeforeWorkerAdmission',
                'currentSchemaVersionRejectsPreservedDevelopmentInputs',
                'currentProvenanceKeepsValidNeighborsAndRejectsMixedClaims',
                'optionalReadySnapshotKeepsReturningOpenHistoryBounded', 'repeatedSnapshotsKeepReturningOpenLeafWorkBounded',
                'scopedCommandsAvoidUnrelatedHistoryBodies', 'packedBootstrapGraphDecodesEachEnvelopeOnce',
                'startupSelectsRequiredWorkBehindOptional', 'optionalStartupRequiresSuccessfulHostPublication', 'deferredSnapshotCloseKeepsExactReadyWork',
                'deferredRejectionWriteFailuresKeepExactInputAcrossRestart',
                'unfinishedVerificationRemainsRequiredWithOptionalQueue',
                'publishedDrainResumesAfterFiniteSaveInterference', 'startupFollowsParkedChangesToRequiredSnapshot',
                'scopedSharedEnvelopeKeepsCompleteGroupsAndDeletedScope', 'scopedWorkStaysFixedAcrossUnrelatedHistory',
                'scopedQueryRejectsSelectedEvidenceDamage', 'scopedMissingNoteKeepsExplicitOutcomeAndHealthyStore', 'scopedEvidenceRequiresExactConsumerAndConnection',
                'scopedQueryKeepsCapturedPrefixAcrossHistoryArrival', 'returningSchemaRequiresCopyIndexWithoutRebuilding',
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
                'generalSnapshotPagedRetentionLayouts', 'generalSnapshotAuthenticRetentionDefects',
                'snapshotRetentionSequentialCoverageSurvivesRestart', 'snapshotRetentionStaleCaptureKeepsConcurrentRoot',
                'snapshotRetentionDelayedParentsWakeAfterRestart', 'snapshotRetentionOldCutCanCoverNewerCut',
                'snapshotRetentionWideFanInAndEmptyParentRoots', 'snapshotRetentionRejectsInvalidParentEvidence',
                'snapshotRetentionUnsupportedParentBlocksWithoutRejectingChild', 'snapshotRetentionConsumerRechecksExactParent',
                'snapshotRetentionReconstructionSharesLogicalTraversal',
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
                'ordinarySaveWorkAcrossGrowingHistory', 'incrementalFrontierMatchesIndependentReachability',
                'collectionStartupLiteralHealthDecisions', 'collectionStartupRequiresAssociationBeforeActualPublication',
                'collectionStartupPublishesWhileRootAcquisitionIsHeld', 'collectionStartupContentionAndFailureRemainScoped',
                'collectionStartupRejectsForeignAndStalePublication', 'collectionStartupPublicationReservationPreventsReassociation',
                'collectionStartupRetryRetainsSameRootAndPreservesReplacement', 'collectionStartupBindingFailureReadbackPreservesDurableState',
                'collectionStartupReplacementAndForeignTargetPreserveHealthyPrivateHistory',
                'collectionStartupActualPrivateFailuresKeepTheirDiagnosticScope', 'collectionStartupPassiveBindingChecksMovedAndReplacedCandidates',
                'collectionStartupUsesOneCurrentCaptureAcrossGrowingAncestors', 'collectionStartupExactUnreadChoiceRechecksBytesAndRemainsScoped',
                'collectionStartupLateAndAlreadyRetainedUnreadInputsPreserveEditing', 'collectionStartupChoiceRejectsOtherOwnerAndChangedSelection',
                'collectionStartupAmbiguousBindingUsesDurableReadback', 'collectionStartupOfflineCannotOverrideFailedPrivateRecheck',
                'collectionStartupNamedMaterializationIsBoundedAndResumesWithoutDelivery',
                'collectionStartupSameRootRetryRetainsNamedCompletionRouting',
                'collectionStartupOfflineProceedsWithLiveHeldAccessor',
                'collectionStartupUnavailableRetryPreservesPendingDisclosure',
                'collectionStartupPublicationWaitsForAcceptedCurrentRows',
                'collectionStartupPublicationDuringNamedAttachmentEnablesTransport',
                'collectionBootstrapPreviewRequiresEveryPageAndCompleteDigest', 'collectionBootstrapGeneralPreviewKeepsHistoryClosureSeparate',
                'collectionBootstrapExplicitCreationPreservesOccupantsAndReopens',
                'collectionBootstrapSelectedIntakeResumesWithoutElectingOtherCollections', 'collectionBootstrapRetriesNormalOpenAfterCommittedImport'}
    if sys.platform == 'darwin':
        required.add('collectionStartupReassociationRetainsEnteredAccessorThroughSettlement')
        required.add('repositoryPresenterSeparatesOwnedWritesFromExternalHints')
    discovered = set(re.findall(r'Test (\w+)\([^\n]*\) (?:started\.|(?:with [1-9][0-9]* test cases? )?(?:passed|failed) after [0-9]+(?:\.[0-9]+)? seconds\b)', suite))
    assert required.issubset(discovered) and re.search(r'Test run with [1-9][0-9]* tests .*passed', suite), 'Required Swift test discovery missing'
    probe_command = ['swift', 'build', '--build-system', 'native', '--package-path', str(ROOT/'NVStorage'),
                     '--configuration', args.configuration, '--product', 'NVStorageProbe']
    if args.scratch_path:
        probe_command += ['--scratch-path', str(args.scratch_path.resolve())]
    if sys.platform == 'linux':
        probe_command += ['--use-integrated-swift-driver', '--disable-build-manifest-caching',
                          '-Xswiftc', '-use-ld=lld', '-Xlinker', '-z', '-Xlinker', 'relro',
                          '-Xlinker', '-z', '-Xlinker', 'now']
    probe_log = run('probe-build', probe_command)
    assert "Build of product 'NVStorageProbe' complete!" in probe_log and 'cancelled!' not in probe_log, 'The qualified child must be built from current production sources'
    binary_dir = (args.scratch_path.resolve() if args.scratch_path else ROOT/'NVStorage/.build')/args.configuration
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
    run('snapshot-retention-process', ['python3', 'tools/test-storage-snapshot-process.py', '--binary', str(qualified), '--retention-prefix', '3'])
    run('snapshot-retention-delivery', ['python3', 'tools/test-storage-retention-delivery.py', '--binary', str(qualified)])
    # Forty recovery schedules each retain their own 120-second child watchdog.
    run('received-snapshot-process', ['python3', 'tools/test-storage-received-snapshot-process.py', '--binary', str(qualified)], timeout=3600)
    run('bootstrap-reconstruction-process', ['python3', 'tools/test-storage-bootstrap-reconstruction-process.py', '--binary', str(qualified)])
    run('private-process', ['python3', 'tools/test-storage-private-process.py', '--binary', str(qualified)])
    run('current-maintenance-process', ['python3', 'tools/test-storage-current-maintenance-process.py', '--binary', str(qualified)])
    run('restoration-process', ['python3', 'tools/test-storage-restoration-process.py', '--binary', str(qualified)])
    run('merge-process', ['python3', 'tools/test-storage-merge-process.py', '--binary', str(qualified)])
    run('phase3-process', ['python3', 'tools/test-storage-phase3-process.py', '--binary', str(qualified)], timeout=7200)
    run('scoped-process', ['python3', 'tools/test-storage-scoped-platform.py', '--binary', str(qualified)])
    run('startup-process', ['python3', 'tools/test-storage-startup-process.py', '--binary', str(qualified)])
    run('generated', ['python3', 'tools/test-storage-generated.py', '--binary', str(qualified)])
    run('rejection', ['python3', 'tools/test-storage-rejection.py', '--binary', str(qualified)])
    run('cipher-cold-start', ['python3', 'tools/test-sqlcipher-cold-start.py'])
    run('core-types', ['python3', 'tools/test-swift-storage-types.py', '--modules', str(binary_dir/'Modules')], timeout=args.compiler_suite_timeout)
    run('runtime-types', ['python3', 'tools/test-storage-runtime-types.py', '--modules', str(binary_dir/'Modules')], timeout=args.compiler_suite_timeout)
    run('private-types', ['python3', 'tools/test-storage-private-types.py', '--modules', str(binary_dir/'Modules')], timeout=args.compiler_suite_timeout)
    run('root-types', ['python3', 'tools/test-storage-root-types.py', '--modules', str(binary_dir/'Modules')], timeout=args.compiler_suite_timeout)
    independent_jobs = [('schema', ['make', '-C', 'tests', 'run-sqlite-schema'])]
    independent_jobs += [('compiler-probe-batches', ['python3', 'tools/test-compiler-probe-batches.py'])]
    independent_jobs += [('storage-test-targets', ['python3', 'tools/test-storage-test-targets.py', '--describe'])]
    independent_jobs += [(fixture, ['python3', f'tools/check-{fixture}-fixtures.py']) for fixture in fixture_names]
    independent_jobs += [('envelopes', ['node', 'tools/check-envelope-fixtures.mjs']),
                         ('private-current', ['node', 'tools/check-private-current-fixtures.mjs']),
                         ('descriptors', ['node', 'tools/check-envelope-fixtures.mjs', '--descriptors'])]
    for name, source, includes in [
        ('owner-c', 'NVStorage/Sources/CStorageIO/NVStorageIO.c', ['NVStorage/Sources/CStorageIO/include']),
        ('fault-c', 'NVStorage/Tests/Support/CStorageFaults/NVStorageFaults.c',
         ['NVStorage/Tests/Support/CStorageFaults/include', 'NVStorage/.deps/sqlcipher/include'])
    ]:
        independent_jobs.append((name, ['clang', '-std=c11', '-Wall', '-Wextra', '-Wconversion', '-Werror',
                                       '-fsyntax-only', source, *['-I'+p for p in includes]]))
    bundle = artifacts/'independent-checks.json'

    def execute_independent():
        for name, command in independent_jobs:
            run(name, command)
        bundle.write_text(json.dumps({name: base64.b64encode((artifacts/(name+'.log')).read_bytes()).decode()
                                     for name, _ in independent_jobs}))

    evidence = reuse.check(['independent-checks', json.dumps(independent_jobs), 'qualification-timeout=900'],
                           independent_inputs, ['python3', 'clang', 'node', 'make', 'swiftc'], bundle, execute_independent)
    if evidence['reused']:
        logs = json.loads(bundle.read_text())
        assert set(logs) == {name for name, _ in independent_jobs}, 'Every independent check needs its exact evidence'
        for name, command in independent_jobs:
            (artifacts/(name+'.log')).write_bytes(base64.b64decode(logs[name], validate=True))
            results.append({'name': name, 'command': command, 'returncode': 0, **evidence})
            print('REUSE: independent check', name, flush=True)
    else:
        for result in results[-len(independent_jobs):]:
            result.update(evidence)
    if args.mutations:
        run('zstd-mutations', ['python3', 'tools/test-zstd-mutations.py', '--configuration', args.configuration], timeout=1800)
        run('bootstrap-mutations', ['python3', 'tools/test-bootstrap-mutations.py', '--configuration', args.configuration], timeout=1800)
        run('runtime-mutations', ['python3', 'tools/test-storage-runtime-mutations.py', '--configuration', args.configuration], timeout=14400)
    report = {'configuration': args.configuration, 'discovered': sorted(discovered), 'results': results,
              'reuse_directory': str(reuse.directory),
              'schema_sha256': hashlib.sha256(schema.read_bytes()).hexdigest(),
              'qualification_limits': ['physical power loss', 'additional platform coverage requires the separate platform campaign', 'provider and UI integration',
                  'independent concurrent snapshot frontiers; automatic VACUUM and geometry/read-ahead remain unqualified; see phase-4-improvements/benchmark-backlog.md']}
    (artifacts/'results.json').write_text(json.dumps(report, indent=2))
    print('PASS:', len(results), 'qualification commands;', len(discovered), 'Swift tests discovered', flush=True)


if __name__ == '__main__':
    main()
