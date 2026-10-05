#!/usr/bin/env python3
"""Bounded proposal-5 checks; exact named failures are controls, not proofs.

Uses only stdlib and an existing TLC jar. Each case gets a fresh temp directory;
logs, generated configurations and JSON results are retained there for review.
No depth/state constraints or simulation. Timeouts/parse errors never pass.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time


def cases():
    native = "NativeCausalUndoBridge"
    for scenario in ("linear", "partialWins", "completeWins"):
        yield (f"native-causal-{scenario}", native, "safe", scenario, 1, "Safety", False, False)
        yield (f"native-causal-converges-{scenario}", native, "safe", scenario, 1, "EventualAgreement", True, False)
    for policy, scenario, prop in (("anyComplete", "partialWins", "PartialStillAvailable"),
                                 ("wholeSpan", "linear", "PartialStillAvailable"),
                                 ("redoOriginal", "linear", "ActualRedo"),
                                 ("wrongInverse", "linear", "ActualInverse"),
                                 ("automaticFork", "partialWins", "ForkNeedsReview"),
                                 ("noOpConsumes", "completeWins", "NoOpKeepsIdentity")):
        yield (f"native-causal-reject-{policy}", native, policy, scenario, 1, prop, False, True)
    yield ("native-causal-partial-witness", native, "safe", "linear", 1, "NeverPartialChain", False, True)
    yield ("native-causal-fork-witness", native, "safe", "completeWins", 1, "NeverForkNoOpRecovered", False, True)
    fast = "SQLiteFastStartSafety"
    yield ("sqlite-fast-start", fast, "safe", "fast-start", 1, "Safety", False, False)
    for policy, prop, temporal in (
        ("omitDelete", "MaterializationExact", False),
        ("omitContext", "MaterializationExact", False),
        ("staleEpoch", "PublicationEpoch", True),
        ("staleStartup", "PublishedExact", False),
        ("ignoreDamage", "NoKnownDamagePublication", True),
    ):
        yield (f"sqlite-fast-start-reject-{policy}", fast, policy, "fast-start", 1, prop, temporal, True)
    for prop in ("NeverDeleteContext", "NeverReopened", "NeverRejectedAndRecovered"):
        yield (f"sqlite-fast-start-{prop}", fast, "safe", "fast-start", 1, prop, False, True)
    sqlite = "SQLiteCollectionSafety"
    for scenario in ("commit", "parked", "import", "combined"):
        yield (f"sqlite-collection-{scenario}", sqlite, "safe", scenario, 1, "Safety", False, False)
    for policy, scenario, prop, temporal in (
        ("earlyAck", "commit", "AcknowledgedRecoverable", False),
        ("noLink", "commit", "ObservationOwned", False),
        ("arrivalTail", "parked", "RecoveryExact", True),
        ("splitCoverage", "parked", "MaterializationTruth", False),
        ("staleReceipt", "import", "FreshReceipt", True),
        ("replayConsent", "import", "NoReplayedConsent", True),
        ("liveOnly", "import", "NoRepeatedImport", False),
        ("loseFrozen", "import", "InputsRetained", False),
        ("acceptOrphan", "parked", "DependencyClosed", False),
        ("splitCommit", "commit", "GroupAtomic", False),
        ("skipReady", "parked", "StartupDrained", True),
        ("noReady", "parked", "ReadyQueueExact", False),
    ):
        yield (f"sqlite-collection-reject-{policy}", sqlite, policy, scenario, 1, prop, temporal, True)
    for scenario, prop in (("commit", "NeverLostCallbackRecovery"), ("parked", "NeverParkedRecovery"),
                           ("import", "NeverDeletedSettlement"), ("import", "NeverFrozenAndLatest"),
                           ("import", "NeverPeerDeleteFirst")):
        yield (f"sqlite-collection-{prop}", sqlite, "safe", scenario, 1, prop, False, True)
    external = "ExternalRecoveryBridge"
    for scenario in ("import", "covered", "concurrent", "neutral"):
        yield (f"bridge-external-{scenario}", external, "safe", scenario, 1, "Safety", False, False)
    for policy, scenario, prop, temporal in (
        ("clobberLatest", "concurrent", "LatestRetained", False),
        ("earlyCleanup", "concurrent", "ReferencesHaveBytes", False),
        ("earlyPin", "import", "AcknowledgedRecoverable", False),
        ("liveOnlyLookup", "import", "NoRepeatedImport", False),
        ("replayConsent", "neutral", "AdmissionNeedsFreshDecision", True),
        ("staleReceipt", "concurrent", "ReceiptNeedsCurrentAuthority", True),
        ("dropAdmitted", "concurrent", "DeleteCannotCancelAdmission", True),
        ("dropNewPreview", "concurrent", "LatestRetained", False),
        ("reviveLink", "concurrent", "SettledLinkStaysTransferred", False),
    ):
        yield (f"bridge-external-reject-{policy}", external, policy, scenario, 1, prop, temporal, True)
    for scenario, prop in (("import", "NeverRecoveredDeletedImport"),
                           ("concurrent", "NeverKeptNewPreview"),
                           ("neutral", "NeverSettledNeutral"),
                           ("concurrent", "NeverRejectedStaleMetadata")):
        yield (f"bridge-external-{prop}", external, "safe", scenario, 1, prop, False, True)
    projection = "ProjectionRecoveryBridge"
    for scenario in ("edit", "rename", "delete", "restore"):
        yield (f"bridge-projection-{scenario}", projection, "safe", scenario, 1, "Safety", False, False)
    for policy, scenario, prop, temporal in (
        ("clearNewer", "edit", "NewerWorkRemainsPending", False),
        ("receiptIsAuthority", "rename", "AcceptedIsVerified", True),
        ("dropBackup", "edit", "ExternalBytesSurviveNV", False),
        ("removeChangedSource", "restore", "NoForeignRemoval", False),
        ("skipSource", "rename", "AcceptedIsVerified", True),
        ("regressReceipt", "rename", "AcceptedNeverRegresses", True),
        ("echoImport", "rename", "NoEchoImport", False),
        ("losePendingHistory", "delete", "PendingHistoryNotCanceled", True),
        ("loseOrphanBackup", "edit", "ExternalBytesSurviveNV", False),
        ("replayRemoval", "restore", "NoForeignRemoval", False),
    ):
        yield (f"bridge-projection-reject-{policy}", projection, policy, scenario, 1, prop, temporal, True)
    for scenario, prop in (("rename", "NeverSettledBWithCWaiting"),
                           ("rename", "NeverRebuiltWithoutReceipt"),
                           ("edit", "NeverPreservedDisplacedX"),
                           ("restore", "NeverRestoredDuringOldMove"),
                           ("rename", "NeverSettledAfterRestart")):
        yield (f"bridge-projection-{prop}", projection, "safe", scenario, 1, prop, False, True)
    compensation = "CompensationOverlapBridge"
    for scenario in ("overlap", "disjoint", "competing", "observing"):
        yield (f"bridge-compensation-{scenario}", compensation, "safe", scenario, 1, "Safety", False, False)
        yield (f"bridge-compensation-converges-{scenario}", compensation, "safe", scenario, 1,
               "EventualAgreement", True, False)
    for policy, scenario, prop, temporal in (
        ("staleAdmission", "overlap", "ExactAdmission", True),
        ("consumeAllHeads", "overlap", "UnchosenHeadsSurvive", True),
        ("lateRecapture", "overlap", "ImmutableMeaning", False),
        ("staleCompletion", "overlap", "CompletionDoesNotOverwrite", True),
        ("wrongInverse", "overlap", "ActualInverse", False),
        ("splitAction", "overlap", "WholeGroup", False),
        ("ignoreSibling", "competing", "CompetingNeedsReview", False),
        ("earlyPin", "overlap", "PinnedComplete", False),
        ("firstPairOnly", "disjoint", "DisjointTitleSurvives", False),
        ("stallReceive", "overlap", "EventualAgreement", True),
        ("noLocalReduction", "overlap", "EventualAgreement", True),
        ("frontierOnly", "overlap", "ExactAdmission", True),
        ("mergeUnsealed", "disjoint", "DerivedInputsDurable", False),
    ):
        yield (f"bridge-compensation-reject-{policy}", compensation, policy, scenario, 1, prop, temporal, True)
    for scenario, prop in (("overlap", "NeverCompletedOverlappingInverse"),
                           ("disjoint", "NeverKeptMergedTitle"),
                           ("competing", "NeverRetainedCompetingSibling"),
                           ("overlap", "NeverRejectedChangedFrontier"),
                           ("overlap", "NeverChangedCurrentWithoutHistory"),
                           ("disjoint", "NeverLearnedRemoteWhileUnsealed"),
                           ("overlap", "NeverRebuiltInstalledWithoutAck")):
        yield (f"bridge-compensation-{prop}", compensation, "safe", scenario, 1, prop, False, True)
    d = "ImmutableSegmentDurabilitySafety"
    s = "SegmentDeletionSafety"
    yield ("durability", d, "safe", "crash", 1, "Safety", False, False)
    yield ("reject-multiWriter", d, "multiWriter", "crash", 1, "OneAcceptanceWriter", False, True)
    yield ("offline", d, "safe", "offline", 1, "OfflineDurability", True, False)
    for scenario in ("concurrent", "ordered", "restore", "files"):
        for host in (1, 2):
            yield (f"{scenario}-crash{host}", s, "safe", scenario, host, "Safety", False, False)
    for scenario in ("concurrent", "ordered", "restore"):
        yield (f"{scenario}-converges", s, "safe", scenario, 1, "EventualAgreement", True, False)
    for scenario in ("orderedRestore", "mixed"):
        for host in (1, 2, 0):
            yield (f"{scenario}-crash{host}", s, "safe", scenario, host, "Safety", False, False)
        yield (f"{scenario}-both-converge", s, "safe", scenario, 0, "EventualAgreement", True, False)
    yield ("reject-onePassClosure", s, "onePassClosure", "orderedRestore", 2,
           "ApplicationHasDependencies", False, True)
    for prop in ("NeverParkedTransitiveDependency", "NeverAppliedAfterTransitiveDependency"):
        yield (prop, s, "safe", "orderedRestore", 2, prop, False, True)
    yield ("NeverRecoveredMixedOnBoth", s, "safe", "mixed", 0,
           "NeverRecoveredMixedOnBoth", False, True)
    yield ("reject-stallDelivery-rank", s, "stallDelivery", "concurrent", 0,
           "RankObligations", False, True)
    yield ("reject-stallDelivery-convergence", s, "stallDelivery", "concurrent", 0,
           "EventualAgreement", True, True)
    for policy, prop in (
        ("earlyAck", "AcknowledgedBytesSurvive"),
        ("materializationPrunes", "AcknowledgedBytesSurvive"),
        ("emptySerialize", "AcknowledgedBytesSurvive"),
        ("staleClear", "PendingLatestIsNotCleared"),
        ("snapshotOnly", "ReopenRetainsLatestAndUnchanged"),
    ):
        yield (f"reject-{policy}", d, policy, "crash", 1, prop, False, True)
    yield ("reject-providerGated", d, "providerGated", "offline", 1, "OfflineDurability", True, True)
    for policy, scenario, prop in (
        ("absenceDeletes", "files", "NoUnexplainedLogicalDeletion"),
        ("dropConflict", "concurrent", "ConcurrentEditIsPreserved"),
        ("reuseBirth", "restore", "RestorationSurvivesOldDeletion"),
        ("skipDependencies", "ordered", "ApplicationHasDependencies"),
        ("earlyDependentAck", "ordered", "AcknowledgedHistorySurvivesRestart"),
        ("snapshotOnly", "concurrent", "AcknowledgedHistorySurvivesRestart"),
        ("deleteReplacement", "files", "NoRemovalOfReplacement"),
        ("removeBeforeDurability", "files", "PhysicalRemovalFollowsDurableDelete"),
    ):
        yield (f"reject-{policy}-{scenario}", s, policy, scenario,
               1 if scenario == "files" or policy == "earlyDependentAck" else 2, prop, False, True)
    for prop in ("NeverRebuiltMaterialization", "NeverReceivedAfterWriterCrash", "NeverHandledStaleCompletion"):
        yield (prop, d, "safe", "crash", 1, prop, False, True)
    for scenario, prop in (
        ("concurrent", "NeverPreservedAcrossCrash"),
        ("restore", "NeverRestoredAcrossBothHosts"),
        ("ordered", "NeverReceivedBeforeParent"),
        ("files", "NeverKeptUnexplainedMissingNote"),
        ("files", "NeverRejectedReplacementRemoval"),
    ):
        yield (prop, s, "safe", scenario, 1, prop, False, True)
    yield ("reject-ackOnlyRecovery", d, "ackOnlyRecovery", "crash", 1,
           "ReopenIncludesUnacknowledgedInstall", False, True)
    yield ("NeverRecoveredWithoutCallback", d, "safe", "crash", 1,
           "NeverRecoveredWithoutCallback", False, True)
    b = "SegmentBootstrapSafety"
    for scenario in ("new", "returning", "local"):
        yield (f"bootstrap-{scenario}", b, "safe", scenario, 1, "Safety", False, False)
    yield ("bootstrap-local-progress", b, "safe", "local", 1, "LocalStartupProgress", True, False)
    for policy, scenario, prop in (
        ("rootOnly", "new", "PreviewHasPages"),
        ("emptyFallback", "new", "EditableHasCompleteImport"),
        ("skipTail", "returning", "LocalTailNotLost"),
        ("trustFilename", "new", "NoForeignAcceptance"),
        ("staleRoot", "returning", "PublishedUnderCurrentRoot"),
        ("rebuildSettings", "local", "RebuildCannotResetSettings"),
    ):
        yield (f"bootstrap-reject-{policy}", b, policy, scenario, 1, prop, False, True)
    yield ("bootstrap-reject-rebuildGated", b, "rebuildGated", "local", 1,
           "LocalStartupProgress", True, True)
    for scenario, prop in (("new", "NeverPreviewedIncompleteHistory"),
                           ("returning", "NeverReopenedWithTail"),
                           ("local", "NeverRebuiltCurrent")):
        yield (f"bootstrap-{prop}", b, "safe", scenario, 1, prop, False, True)
    a = "SegmentActionRecoverySafety"
    for scenario in ("edit", "bulk", "restore"):
        yield (f"action-{scenario}", a, "safe", scenario, 1, "Safety", False, False)
        yield (f"action-delivers-{scenario}", a, "safe", scenario, 1, "DurableActionsReachPeer", True, False)
    for policy, scenario, prop in (
        ("splitGroup", "bulk", "AtomicDurableGroup"),
        ("earlyAck", "edit", "AckHasCompleteEnvelope"),
        ("staleAdmission", "edit", "NoStaleAdmission"),
        ("overwriteRemote", "edit", "RemoteFieldPreserved"),
        ("partialBulk", "bulk", "NoPartialBulkUndo"),
        ("wrongBirth", "restore", "FreshBirthRedo"),
        ("staleCursor", "edit", "RecoveredEffectAndCursor"),
        ("ignorePortableUndo", "edit", "PeerHasPortableUndo"),
        ("snapshotOnly", "bulk", "RecoveredEffectAndCursor"),
        ("badRecord", "edit", "ActionRecordMatchesNoteValues"),
    ):
        yield (f"action-reject-{policy}", a, policy, scenario, 1, prop, False, True)
    yield ("action-reject-ackGatedDelivery", a, "ackGatedDelivery", "edit", 1,
           "DurableActionsReachPeer", True, True)
    for scenario, prop in (("bulk", "NeverRecoveredBeforeAck"),
                           ("restore", "NeverCompletedRedoOnBoth"),
                           ("edit", "NeverPreservedRemoteRename"),
                           ("bulk", "NeverRejectedInterveningEdit")):
        yield (f"action-{prop}", a, "safe", scenario, 1, prop, False, True)
    m = "SegmentMergeSafety"
    for scenario in ("merge", "third", "dominated", "ambiguous", "equal", "conflict"):
        yield (f"merge-{scenario}", m, "safe", scenario, 1, "Safety", False, False)
    yield ("merge-converges-merge", m, "safe", "merge", 1, "EventualAgreement", True, False)
    for policy, scenario, prop in (
        ("lastWriter", "merge", "IndependentFieldsSurvive"),
        ("arbitraryBase", "ambiguous", "UniqueBaseRequired"),
        ("pairwise", "third", "ThreeHeadsNotFolded"),
        ("stalePublish", "merge", "NoStalePublication"),
        ("dropParent", "merge", "UserEditRetainsBothInputs"),
        ("automaticWrite", "merge", "NoAutomaticOperations"),
        ("skipParents", "merge", "AllAcceptedParentsPresent"),
        ("stallDelivery", "merge", "ProgressAvailable"),
        ("consumeConflicts", "conflict", "OrdinaryEditTargetsCurrentOnly"),
        ("knowledgeSupersedes", "conflict", "UnchosenHeadSurvives"),
    ):
        yield (f"merge-reject-{policy}", m, policy, scenario, 1, prop, False, True)
    for scenario, prop in (("merge", "NeverMergedBothOrders"),
                           ("third", "NeverDelayedThirdHead"),
                           ("merge", "NeverReceivedEditBeforeParents"),
                           ("merge", "NeverAppliedDerivedEditOnPeer")):
        yield (f"merge-{prop}", m, "safe", scenario, 1, prop, False, True)
    yield ("merge-NeverEditedCurrentWithKnownConflict", m, "safe", "conflict", 1,
           "NeverEditedCurrentWithKnownConflict", False, True)
    copy = "NVConflictCopySafety"
    for scenario in ("reciprocal", "descendant", "copyEdit", "copyDelete"):
        yield (f"nv-copy-{scenario}", copy, "safe", scenario, 1, "Safety", False, False)
    yield ("nv-copy-progress", copy, "safe", "reciprocal", 1,
           "DurableRecordsReachBoth", True, False)
    for policy, scenario, prop in (
        ("subtractSource", "reciprocal", "OriginalNeverDisappears"),
        ("implicitKeep", "reciprocal", "CurrentIgnoresCopies"),
        ("coverAll", "reciprocal", "ExactDisposition"),
        ("coverDescendant", "descendant", "NewDescendantNeedsAttention"),
        ("forgetDeleted", "copyDelete", "CopyChangeDoesNotReopen"),
        ("earlyDisposition", "reciprocal", "DispositionHasDurableCopy"),
        ("recreateDeleted", "copyDelete", "LaterCopyValueSurvives"),
    ):
        yield (f"nv-copy-reject-{policy}", copy, policy, scenario, 1, prop, False, True)
    for scenario, prop in (("reciprocal", "NeverRecoveredReciprocal"),
                           ("descendant", "NeverSawNewDescendant"),
                           ("copyEdit", "NeverKeptModifiedCopy"),
                           ("copyDelete", "NeverKeptDeletedCopy"),
                           ("descendant", "NeverParkedChild")):
        yield (f"nv-copy-{prop}", copy, "safe", scenario, 1, prop, False, True)
    o = "SegmentDeletionOrderingSafety"
    for scenario in ("covered", "extension", "editedCopy", "explicitCopy", "awareness"):
        yield (f"ordering-{scenario}", o, "safe", scenario, 1, "Safety", False, False)
        yield (f"ordering-converges-{scenario}", o, "safe", scenario, 1, "EventualAgreement", True, False)
    for policy, scenario, prop in (
        ("stickyCopy", "covered", "CoveredEditIsHistoricalOnly"),
        ("perDeleteUnion", "covered", "CoveredEditIsHistoricalOnly"),
        ("coverDescendants", "extension", "UncoveredExtensionSurvives"),
        ("eraseIndependent", "editedCopy", "IndependentWorkSurvives"),
        ("knowledgeSupersedes", "awareness", "KnownAlternativeSurvives"),
    ):
        yield (f"ordering-reject-{policy}", o, policy, scenario, 1, prop, False, True)
    for scenario, prop in (("covered", "NeverRetractedAfterDisplay"),
                           ("extension", "NeverPreservedF"),
                           ("editedCopy", "NeverPreservedIndependentAfterRestart"),
                           ("explicitCopy", "NeverPreservedIndependentAfterRestart"),
                           ("awareness", "NeverPreservedKnownAlternativeAfterRestart")):
        yield (f"ordering-{scenario}-{prop}", o, "safe", scenario, 1, prop, False, True)
    p = "ProjectionStampSafety"
    for scenario in ("unique", "duplicate", "repair"):
        yield (f"stamp-{scenario}", p, "safe", scenario, 1, "Safety", False, False)
    for policy, scenario, prop in (
        ("stampAuthority", "unique", "AssociationNeedsHistory"),
        ("ignoreDigest", "unique", "AssociationNeedsExactBytes"),
        ("ignoreDuplicate", "duplicate", "CopiedStampIsNotIdentity"),
        ("uncheckedImport", "unique", "AutomaticBirthHasEligibleObservation"),
        ("uncheckedImport", "duplicate", "AutomaticBirthHasEligibleObservation"),
        ("uncheckedImport", "repair", "AutomaticBirthHasEligibleObservation"),
        ("aliasExplicit", "unique", "ExplicitBirthIsNotAliased"),
    ):
        yield (f"stamp-reject-{policy}-{scenario}", p, policy, scenario, 1, prop, False, True)
    for prop in ("NeverWaitedForSegment", "NeverAssociatedAfterHistory", "NeverRejectedSkew", "NeverKeptExplicitImport",
                 "NeverAutomaticallyImported", "NeverKeptAutomaticImport"):
        yield (f"stamp-{prop}", p, "safe", "unique", 1, prop, False, True)
    pending = "ExternalFileLifecycleSafety"
    for scenario in ("pending", "race", "repeatedCrash", "transition", "transitionPath", "placeholder", "unreadableKnown",
                     "initialWrite", "accounted", "multipleCandidates"):
        yield (f"external-file-{scenario}", pending, "safe", scenario, 1, "Safety", False, False)
    yield ("external-file-local-progress", pending, "safe", "pending", 1, "AdmittedAttemptSettles", True, False)
    for policy, scenario, prop in (
        ("earlyReference", "pending", "ReferencedSnapshotsDurable"),
        ("discardReadFailure", "pending", "ReferencedSnapshotsDurable"),
        ("replaceFrozen", "pending", "ExactAdmittedValue"),
        ("duplicateRetry", "pending", "NoRepeatedImport"),
        ("liveNoteLookup", "repeatedCrash", "NoRepeatedImport"),
        ("replayConsent", "pending", "NoReplayedConsent"),
        ("staleAdmission", "race", "NoStaleAdmission"),
        ("staleReceipt", "race", "NoStaleReceipt"),
        ("stickyPrior", "transition", "TransitionRule"),
        ("dropPrior", "transitionPath", "TransitionRule"),
        ("reuseOperation", "pending", "ReservedOperationMatchesInputs"),
    ):
        yield (f"external-file-reject-{policy}", pending, policy, scenario, 1, prop, False, True)
    yield ("external-file-reject-uiGated", pending, "uiGated", "pending", 1, "AdmittedAttemptSettles", True, True)
    for scenario, prop in (
        ("pending", "NeverReplacedPreviewWhilePinned"), ("pending", "NeverRetainedUnreadable"),
        ("pending", "NeverRecoveredBeforeReceipt"), ("pending", "NeverCommittedAfterClose"),
        ("pending", "NeverSettledReceipt"), ("transition", "NeverReleasedPriorProjection"),
        ("transition", "NeverOfferedPriorProjection"),
        ("repeatedCrash", "NeverResettledAfterTwoCrashes"),
        ("repeatedCrash", "NeverRecoveredRetiredWithoutReceipt"),
        ("pending", "NeverRepreparedUnusedBirth"),
    ):
        yield (f"external-file-{prop}", pending, "safe", scenario, 1, prop, False, True)
    reference = "PendingReferenceSafety"
    for scenario in ("first", "replace", "reservation"):
        yield (f"pending-reference-{scenario}", reference, "safe", scenario, 1, "Safety", False, False)
    for policy, scenario, prop in (
        ("earlyReference", "first", "EveryRecoverableReferenceHasBytes"),
        ("earlyCleanup", "replace", "EveryRecoverableReferenceHasBytes"),
        ("staleSwitch", "replace", "NoStaleReferenceSwitch"),
        ("forgetFrozen", "reservation", "FrozenInputSurvives"),
    ):
        yield (f"pending-reference-reject-{policy}", reference, policy, scenario, 1, prop, False, True)
    for scenario, prop in (("replace", "NeverRecoveredOld"), ("replace", "NeverRecoveredNew"),
                           ("replace", "NeverReleasedOld"), ("reservation", "NeverKeptFrozenAndNew")):
        yield (f"pending-reference-{prop}", reference, "safe", scenario, 1, prop, False, True)
    association = "ExternalAssociationSafety"
    for scenario in ("equal", "useCurrent", "useFile", "merge", "competing"):
        yield (f"association-{scenario}", association, "safe", scenario, 1, "Safety", False, False)
    for policy, scenario, prop in (
        ("staleAdmission", "useFile", "FreshAdmission"),
        ("doubleClaim", "competing", "OneRelationshipClaim"),
        ("earlyReceipt", "useFile", "ExactDurableReceipt"),
        ("staleReceipt", "useFile", "ExactDurableReceipt"),
        ("echoPut", "equal", "NoEchoOperation"),
        ("consumeAllHeads", "useFile", "NoImplicitHeadConsumption"),
        ("skipProjection", "useCurrent", "ExactDurableReceipt"),
        ("loseLocalField", "merge", "ExactOperationValue"),
        ("dropUnrelatedHead", "useFile", "UnrelatedHeadSurvives"),
    ):
        yield (f"association-reject-{policy}", association, policy, scenario, 1, prop, False, True)
    for scenario, prop in (
        ("equal", "NeverCompletedEqualWithoutPut"), ("useCurrent", "NeverInstalledChosenCurrent"),
        ("merge", "NeverMergedBothChanges"), ("useFile", "NeverPreservedUnrelatedHead"),
        ("useFile", "NeverRetainedAfterDelete"), ("competing", "NeverPreparedCompetingChoices"),
    ):
        yield (f"association-{prop}", association, "safe", scenario, 1, prop, False, True)
    transition = "ProjectionTransitionSafety"
    for scenario in ("edit", "rename", "format"):
        yield (f"projection-transition-{scenario}", transition, "safe", scenario, 1, "Safety", False, False)
    for policy, scenario, prop in (
        ("clearNewer", "edit", "NewerIntentRemainsPending"),
        ("skipSource", "rename", "ReceiptRequiresExactVerifiedTransition"),
        ("skipVerification", "edit", "ReceiptRequiresExactVerifiedTransition"),
        ("stalePublication", "rename", "ReceiptRequiresExactVerifiedTransition"),
    ):
        yield (f"projection-transition-reject-{policy}", transition, policy, scenario, 1, prop, False, True)
    for prop in ("NeverAcceptedOlderWhileNewerPending", "NeverFinishedNewest",
                 "NeverKeptPriorWhileSourcePending", "NeverReplacedActivePrior"):
        yield (f"projection-transition-{prop}", transition, "safe", "rename", 1, prop, False, True)
    r = "RepositoryCopySafety"
    yield ("repository-copy", r, "safe", "repository", 1, "Safety", False, False)
    yield ("repository-progress", r, "safe", "repository", 1, "RepositoryAloneSuffices", True, False)
    yield ("repository-reject-currentOnly", r, "currentOnly", "repository", 1, "HistoryNotFlattened", False, True)
    yield ("repository-reject-privateRequired", r, "privateRequired", "repository", 1, "RepositoryAloneSuffices", True, True)
    yield ("repository-NeverCopiedWithoutPrivateStore", r, "safe", "repository", 1, "NeverCopiedWithoutPrivateStore", False, True)
    repair = "RepositoryRepairSafety"
    for scenario in ("healthy", "providerAbsent", "providerPartial", "providerUnavailable",
                     "providerRemoteNewer", "providerUnmaterialized", "providerForeign",
                     "rootReplaced", "localAbsent", "localPartial", "localUnreadable",
                     "localUnwritable", "bothPartial", "bothMissing", "runningDisclosure",
                     "providerRootRace", "localRootRace", "localStoreRace"):
        yield (f"repair-{scenario}", repair, "safe", scenario, 1, "Safety", False, False)
    for scenario, prop in (("providerAbsent", "ProviderRepairCompletes"),
                           ("providerPartial", "ProviderRepairCompletes"),
                           ("localAbsent", "LocalRepairCompletes"),
                           ("localPartial", "LocalRepairCompletes"),
                           ("bothPartial", "BidirectionalRepairCompletes"),
                           ("providerUnavailable", "OfflineEditingAvailable"),
                           ("providerAbsent", "OfflineEditingAvailable")):
        yield (f"repair-progress-{scenario}-{prop}", repair, "safe", scenario, 1,
               prop, True, False)
    for policy, scenario, prop, temporal in (
        ("manualRestore", "providerAbsent", "ProviderRepairCompletes", True),
        ("offerOfflineAnyFailure", "providerUnavailable", "WorkOfflineOnlyForWithheldEvidence", False),
        ("overwriteForeign", "providerForeign", "ForeignEvidenceIsPreserved", False),
        ("claimIncomplete", "providerPartial", "ProviderClaimHasKnownClosure", False),
        ("fabricate", "bothMissing", "RepairUsesOnlyExactAvailableBytes", False),
        ("editWithoutClosure", "localPartial", "NoEditWithoutCompleteLocal", False),
        ("providerGatesEditing", "providerUnavailable", "OfflineEditingAvailable", True),
        ("staleRoot", "rootReplaced", "NoProviderUseWithoutAuthority", False),
        ("destructiveLocal", "localPartial", "LocalRepairPreservesOldEvidence", False),
        ("repairBeforeLocal", "bothPartial", "ProviderRepairUsesCompleteLocal", True),
        ("providerRevokesEditing", "runningDisclosure", "ActiveSessionRemainsEditable", False),
    ):
        yield (f"repair-reject-{policy}", repair, policy, scenario, 1, prop, temporal, True)
    for scenario, prop in (("providerRemoteNewer", "NeverOfferedWorkOffline"),
                           ("providerRemoteNewer", "NeverChoseWorkOffline"),
                           ("providerAbsent", "NeverBuiltProviderCopy"),
                           ("localAbsent", "NeverBuiltLocalCopy"),
                           ("providerUnavailable", "NeverWorkedOffline"),
                           ("providerPartial", "NeverActivatedProvider"),
                           ("runningDisclosure", "NeverContinuedEditingDuringDisclosure"),
                           ("providerRootRace", "NeverInterruptedProviderCopy"),
                           ("localRootRace", "NeverActivatedFromRetainedBuild"),
                           ("localStoreRace", "NeverInterruptedStoreCopy")):
        yield (f"repair-{prop}", repair, "safe", scenario, 1, prop, False, True)
    for policy, scenario, prop in (
        ("staleCopy", "providerRootRace", "ProviderEffectsHaveAuthority"),
        ("staleCopy", "localRootRace", "LocalCopiesHaveAvailableSource"),
        ("staleStore", "localStoreRace", "LocalRepairEffectsHaveStoreAuthority"),
    ):
        yield (f"repair-reject-{policy}-{scenario}", repair, policy, scenario, 1, prop, True, True)
    portable = "PortableCausalUndoSafety"
    for scenario in ("remote", "ordered", "concurrent", "undone", "redone",
                     "undoAgain", "latestUndone", "twoUndos", "redoFirst", "redoBoth",
                     "redoDescendant", "redoConcurrent", "redoBlockedThenUndone",
                     "redoBlockedThenRedone", "competingUndo", "competingRedo", "forkThenEdit",
                     "forkThenUndo", "forkThenRedo", "otherScope", "privateLoss"):
        yield (f"portable-{scenario}", portable, "safe", scenario, 1,
               "Safety", False, False)
    for scenario, prop in (("remote", "PeerCanUndoRemote"),
                           ("concurrent", "ConcurrentPeerCanReview"),
                           ("undone", "PeerCanRedoCompensation"),
                           ("privateLoss", "PrivateLossCanRebuildUndo")):
        yield (f"portable-progress-{scenario}-{prop}", portable, "safe", scenario, 1,
               prop, True, False)
    for policy, scenario, prop, temporal in (
        ("arrivalOrder", "concurrent", "DecisionMatchesRepository", False),
        ("localOnly", "remote", "DecisionMatchesRepository", False),
        ("ignoreScopeParents", "ordered", "DecisionMatchesRepository", False),
        ("staleCache", "ordered", "DecisionUsesCompleteIndex", False),
        ("eraseConcurrentRedo", "redoConcurrent", "DecisionMatchesRepository", False),
        ("privateCursor", "privateLoss", "PrivateLossCanRebuildUndo", True),
        ("originalAfterRedo", "redone", "RedoneTargetsActualCompensation", False),
        ("reviveClearedRedo", "redoBlockedThenRedone", "ClearedRedoStaysCleared", False),
        ("collapseCompeting", "competingRedo", "CompetingCompensationsRequireReview", False),
        ("scopeWideFork", "forkThenEdit", "DecisionMatchesRepository", False),
    ):
        yield (f"portable-reject-{policy}", portable, policy, scenario, 1,
               prop, temporal, True)
    for scenario, prop in (("ordered", "NeverSelectedCausalChild"),
                           ("concurrent", "NeverReviewedConcurrent"),
                           ("remote", "NeverSelectedRemoteAction"),
                           ("undone", "NeverSelectedRemoteCompensation"),
                           ("privateLoss", "NeverRebuiltAfterPrivateLoss"),
                           ("redone", "NeverSelectedRedoInverse"),
                           ("redoFirst", "NeverSelectedRemainingRedo"),
                           ("competingRedo", "NeverReviewedCompeting"),
                           ("forkThenRedo", "NeverContinuedPastOldFork")):
        yield (f"portable-{prop}", portable, "safe", scenario, 1,
               prop, False, True)
    execution = "ConcurrentUndoExecutionSafety"
    for scenario in ("review", "independent", "restore", "intervention"):
        yield (f"undo-execution-{scenario}", execution, "safe", scenario, 1, "Safety", False, False)
        yield (f"undo-execution-NeverCompletedOnBoth-{scenario}", execution, "safe", scenario, 1,
               "NeverCompletedOnBoth", False, True)
    yield ("undo-execution-progress", execution, "safe", "review", 1, "DurableReachesPeer", True, False)
    for policy, scenario, prop, temporal in (
        ("staleConsent", "intervention", "ExactAdmission", True),
        ("splitGroup", "review", "AtomicGroups", False),
        ("earlyAck", "review", "AckDurable", False),
        ("staleCompletion", "intervention", "ConcreteValues", False),
        ("dropSibling", "review", "KnownRetainsDurable", False),
        ("wrongBirth", "restore", "ConcreteValues", False),
        ("allowNoop", "review", "NoNoopRecords", False),
        ("omitParent", "independent", "ExactAdmission", True),
        ("dismissConsumes", "review", "PresentationPreserves", True),
    ):
        yield (f"undo-execution-reject-{policy}", execution, policy, scenario, 1, prop, temporal, True)
    for scenario, prop in (("intervention", "NeverRejectedStaleReview"),
                           ("review", "NeverBlockedNoop"),
                           ("review", "NeverReceivedChildFirst"),
                           ("review", "NeverRecoveredBeforeAck"),
                           ("intervention", "NeverAppliedDuringPending")):
        yield (f"undo-execution-{prop}", execution, "safe", scenario, 1, prop, False, True)
    u = "UndoHistoryHandoffSafety"
    for scenario in ("prefix", "title", "overlap", "delete", "conflict"):
        yield (f"undo-handoff-{scenario}", u, "safe", scenario, 1, "Safety", False, False)
    yield ("undo-handoff-progress", u, "safe", "prefix", 1, "EventuallyReadyAndSettled", True, False)
    for policy, scenario, prop in (
        ("replaceIndex", "prefix", "NewerActionRetained"),
        ("duplicateOwner", "prefix", "NoDuplicateOwner"),
        ("popFirst", "overlap", "RefusalDoesNotPop"),
        ("rawNative", "prefix", "RemoteIntentPreserved"),
        ("staleCommit", "prefix", "RemoteIntentPreserved"),
        ("unchecked", "overlap", "RemoteIntentPreserved"),
        ("splitRecord", "prefix", "DurableEffectMatchesPosition"),
        ("consumeConflict", "conflict", "RemoteIntentPreserved"),
    ):
        yield (f"undo-handoff-reject-{policy}", u, policy, scenario, 1, prop, False, True)
    for prop in ("NeverUndidNewThenOld", "NeverRecoveredCompensation",
                 "NeverPreservedRemoteUndo", "NeverRejectedInterveningRemote", "NeverRedidBoth"):
        yield (f"undo-handoff-{prop}", u, "safe", "prefix", 1, prop, False, True)
    yield ("undo-handoff-NeverRejectedRedoAfterRemote", u, "safe", "overlap", 1,
           "NeverRejectedRedoAfterRemote", False, True)
    v = "NativeUndoSpanSafety"
    yield ("undo-spans", v, "safe", "spans", 1, "Safety", False, False)
    yield ("undo-spans-progress", v, "safe", "spans", 1, "EventuallyDurable", True, False)
    for policy, prop in (("wholeSpan", "LiveRemainingEffect"), ("redoWholeSpan", "LiveRemainingEffect"),
                         ("splitCoverage", "DurableRemainingEffect"), ("staleClear", "NoLostPending")):
        yield (f"undo-spans-reject-{policy}", v, policy, "spans", 1, prop, False, True)
    for prop in ("NeverRecoveredPartial", "NeverCompletedStale", "NeverRedidPartial"):
        yield (f"undo-spans-{prop}", v, "safe", "spans", 1, prop, False, True)
    review = "ReviewedUndoSafety"
    for mode in ("undo", "redo", "history", "conflict"):
        yield (f"review-{mode}", review, "safe", mode, 1, "Safety", False, False)
    for mode in ("undo", "redo"):
        yield (f"review-progress-{mode}", review, "safe", mode, 1, "SettlesAdmitted", True, False)
    for policy, mode, prop, temporal in (
        ("asRecovery", "undo", "InvocationMeaning", False),
        ("asUndo", "history", "InvocationMeaning", False),
        ("clearTail", "undo", "RedoTailPreserved", False),
        ("popOnOpen", "undo", "PresentationPreserves", True),
        ("cancelPops", "redo", "PresentationPreserves", True),
        ("staleValue", "undo", "ExactAdmission", True),
        ("staleRoot", "undo", "ExactAdmission", True),
        ("overwriteOthers", "undo", "ReviewedScope", False),
        ("wrongInverse", "undo", "ActualInverse", False),
        ("wrongInverse", "redo", "ActualInverse", False),
        ("splitRecord", "undo", "DurableAgreement", False),
        ("clearOtherScope", "history", "OtherScopePreserved", False),
    ):
        yield (f"review-reject-{policy}-{mode}", review, policy, mode, 1, prop, temporal, True)
    for mode in ("undo", "redo"):
        for prop in ("NeverApproved", "NeverReversed"):
            yield (f"review-{prop}-{mode}", review, "safe", mode, 1, prop, False, True)
    for prop, mode in (("NeverCanceled", "undo"), ("NeverRejectedStale", "undo"),
                       ("NeverRecoveredBeforeAck", "undo"), ("NeverBranched", "history")):
        yield (f"review-{prop}", review, "safe", mode, 1, prop, False, True)
    shared = "SharedNoteViewOwnershipSafety"
    for scenario in ("lifecycle", "routing", "composition"):
        yield (f"shared-view-{scenario}", shared, "safe", scenario, 1, "Safety", False, False)
    yield ("shared-view-progress", shared, "safe", "lifecycle", 1, "EventuallyDurable", True, False)
    for policy, scenario, prop, temporal in (
        ("duplicateObserver", "lifecycle", "NoDuplicateActions", False),
        ("viewOwnsUndo", "lifecycle", "LiveAgreement", False),
        ("closeDropsPending", "lifecycle", "NoLostPending", False),
        ("lateBinding", "routing", "LiveAgreement", False),
        ("staleAdmission", "routing", "ExactAdmission", True),
        ("staleRender", "routing", "ViewBinding", False),
        ("draftCapture", "composition", "DurableAgreement", False),
        ("splitCursor", "lifecycle", "DurableAgreement", False),
        ("staleClear", "lifecycle", "NoLostPending", False),
    ):
        yield (f"shared-view-reject-{policy}", shared, policy, scenario, 1, prop, temporal, True)
    for scenario, prop in (
        ("lifecycle", "NeverUndidAfterDetach"), ("lifecycle", "NeverUndidAfterReopen"),
        ("routing", "NeverRejectedAdmission"), ("routing", "NeverRejectedUI"),
        ("routing", "NeverRejectedRemote"),
        ("lifecycle", "NeverRecoveredBeforeAck"), ("lifecycle", "NeverCompletedStale"),
        ("composition", "NeverSavedOtherNoteDuringDraft"),
    ):
        yield (f"shared-view-{prop}", shared, "safe", scenario, 1, prop, False, True)
    f = "SeparateFileDeletionSafety"
    yield ("file-component", f, "safe", "files", 1, "RemovalFollowsLocalDurability", False, False)
    yield ("file-reject-noBarrier", f, "noBarrier", "files", 1, "RemovalFollowsLocalDurability", False, True)
    yield ("file-NeverRemovedDurableOriginal", f, "safe", "files", 1, "NeverRemovedDurableOriginal", False, True)
    yield ("local-lane-independence", "LocalDurabilityLaneIndependence", "safe", "offline", 1,
           "AdmittedEditsBecomeDurableWithoutProviderFairness", True, False)
    current = "CurrentVisibleReconciliationSafety"
    yield ("shared-catalog", current, "safe", "current", 1, "ConfiguredChecks", False, False)
    for policy, prop, temporal in (
        ("skipDirtyFence", "CommitConsumedOnlyServicedDirtyGeneration", True),
        ("skipRepresentation", "PublishedInputsWereCurrentAndRepresented", False),
        ("publishAllFiles", "PublishedInputsWereCurrentAndRepresented", False),
        ("wrongPublishedOutput", "PublicationMatchesCapturedInputs", True),
    ):
        yield (f"shared-catalog-reject-{policy}", current, policy, "current", 1, prop, temporal, True)
    for prop in ("NeverPublishedRepresentedFile", "NeverRetainedLaterDirtyHint"):
        yield (f"shared-catalog-{prop}", current, "safe", "current", 1, prop, False, True)
    for model in ("UnresolvedVersionResolutionSafety", "CrossMachineConflictDispositionSafety"):
        yield (f"shared-apple-{model}", model, "safe", "apple", 1, "ConfiguredChecks", False, False)
    apple = "UnresolvedVersionResolutionSafety"
    for policy, prop, temporal in (
        ("earlySavedResolution", "SavedResolutionHasInstalledCopy", True),
        ("reuseRetiredCopy", "RetiredCopiesAreNeverReused", False),
        ("chooseLaterMembers", "ChosenResolutionUsesCapturedInstalledCurrent", True),
        ("earlyChosenResolution", "ChosenResolutionUsesCapturedInstalledCurrent", True),
    ):
        yield (f"shared-apple-reject-{policy}", apple, policy, "apple", 1, prop, temporal, True)
    for prop in ("NeverDeletedCompletedCopy", "NeverDeletedSharedPendingCopy"):
        yield (f"shared-apple-{prop}", apple, "safe", "apple", 1, prop, False, True)
    two_apple = "CrossMachineConflictDispositionSafety"
    for policy, prop in (
        ("saveAll", "SavedResolutionIsSelectedMemberOnly"),
        ("staleSaved", "SavedResolutionRequiresExactInstalledCopy"),
        ("earlySaved", "SavedResolutionRequiresExactInstalledCopy"),
        ("staleUse", "UseResolutionRequiresExactInstalledCurrent"),
    ):
        yield (f"shared-apple-two-reject-{policy}", two_apple, policy, "apple", 1, prop, True, True)
    for prop in ("NeverSavedOnBoth", "NeverParkedChangedCopy", "NeverKeptLaterMember"):
        yield (f"shared-apple-two-{prop}", two_apple, "safe", "apple", 1, prop, False, True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--java", required=True)
    p.add_argument("--jar", required=True)
    p.add_argument("--only", default="", help="case-name substring")
    p.add_argument("--model", default="", help="exact module name, independently of case-name selection")
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--full-temporal", action="store_true",
                   help="also run expensive direct three-head LTL check; timeouts still fail")
    args = p.parse_args()
    root = Path(tempfile.mkdtemp(prefix="nv-segment-tlc-"))
    print(f"Artifacts: {root}", flush=True)
    results = []
    selected_cases = list(cases())
    if args.full_temporal:
        selected_cases.append(("merge-converges-third", "SegmentMergeSafety", "safe", "third", 1,
                               "EventualAgreement", True, False))
    for name, model, policy, scenario, host, prop, temporal, expected_failure in selected_cases:
        if args.only not in name:
            continue
        if args.model and args.model != model:
            continue
        directory = root / name
        directory.mkdir()
        shutil.copyfile(Path(__file__).parent / f"{model}.tla", directory / f"{model}.tla")
        if model in ("PortableCausalUndoSafety", "ConcurrentUndoExecutionSafety", "CompensationOverlapBridge"):
            shutil.copyfile(Path(__file__).parent / "CausalUndoRules.tla", directory / "CausalUndoRules.tla")
        if model == "ExternalFileLifecycleSafety":
            shutil.copyfile(Path(__file__).parent / "ExternalImportPolicyLab.tla", directory / "ExternalImportPolicyLab.tla")
        if model == "SeparateFileDeletionSafety" and policy == "noBarrier":
            model_path = directory / f"{model}.tla"
            source = model_path.read_text()
            guard = "    /\\ state.deletionDurable\n"
            assert source.count(guard) == 1
            model_path.write_text(source.replace(guard, "", 1))
        spec = "LocalFairSpec" if temporal and model == "SegmentBootstrapSafety" else "FairSpec" if temporal else "Spec"
        config = f'SPECIFICATION {spec}\nCONSTANTS Policy = "{policy}" Scenario = "{scenario}"\n'
        if model == "SegmentDeletionSafety":
            config += f"CrashHost = {host}\n"
        config += "INVARIANT TypeOK\n"
        config += f'{"PROPERTY" if temporal else "INVARIANT"} {prop}\nCHECK_DEADLOCK FALSE\n'
        if model in ("SeparateFileDeletionSafety", "LocalDurabilityLaneIndependence",
                     "CurrentVisibleReconciliationSafety", "UnresolvedVersionResolutionSafety",
                     "CrossMachineConflictDispositionSafety"):
            config = (Path(__file__).parent / f"{model}.cfg").read_text()
            if model in ("CurrentVisibleReconciliationSafety", "UnresolvedVersionResolutionSafety",
                         "CrossMachineConflictDispositionSafety"):
                config = config.replace('Policy = "safe"', f'Policy = "{policy}"')
            if expected_failure:
                config = "\n".join(line for line in config.splitlines()
                                   if not line.startswith(("INVARIANT", "PROPERTY")))
                config += f'\nINVARIANT TypeOK\n{"PROPERTY" if temporal else "INVARIANT"} {prop}\n'
        if not expected_failure and model == "SegmentDeletionSafety":
            config += "INVARIANT EqualHistoriesAgree\n"
            config += "INVARIANT RankObligations\n"
            config += "PROPERTY AdvancingStepsDecreaseRank\nPROPERTY AuxiliaryPreservesRankAndAgreement\n"
            if temporal:
                config += "INVARIANT Safety\n"
        if temporal and not expected_failure and model in ("SegmentBootstrapSafety", "SegmentMergeSafety", "SegmentActionRecoverySafety", "SegmentDeletionOrderingSafety", "RepositoryCopySafety", "RepositoryRepairSafety", "PortableCausalUndoSafety", "NVConflictCopySafety", "NativeCausalUndoBridge"):
            config += "INVARIANT Safety\n"
        if model == "SegmentMergeSafety" and not expected_failure:
            if "INVARIANT Safety\n" not in config:
                config += "INVARIANT Safety\n"
            if "INVARIANT RankObligations\n" not in config:
                config += "INVARIANT RankObligations\n"
            config += "PROPERTY ProgressDecreasesRank\nPROPERTY EnvironmentDecreasesBudget\n"
        if model == "ReviewedUndoSafety" and not expected_failure:
            if "INVARIANT Safety\n" not in config:
                config += "INVARIANT Safety\n"
            config += "PROPERTY PresentationPreserves\nPROPERTY ExactAdmission\n"
        if model == "RepositoryRepairSafety" and not expected_failure:
            config += "PROPERTY ProviderRepairUsesCompleteLocal\nPROPERTY RepairEffectsAreFenced\n"
        if model == "ConcurrentUndoExecutionSafety" and not expected_failure:
            if "INVARIANT Safety\n" not in config:
                config += "INVARIANT Safety\n"
            config += "PROPERTY ExactAdmission\nPROPERTY RecoveryRebuilds\nPROPERTY PresentationPreserves\n"
        if model == "SharedNoteViewOwnershipSafety" and not expected_failure:
            if "INVARIANT Safety\n" not in config:
                config += "INVARIANT Safety\n"
            config += "PROPERTY PresentationPreserves\nPROPERTY ExactAdmission\nPROPERTY ExactRendering\n"
        bridge_properties = {
            "SQLiteFastStartSafety": ("PublicationEpoch", "NoKnownDamagePublication", "HistorySurvives"),
            "SQLiteCollectionSafety": ("RecoveryExact", "NoReplayedConsent", "FreshReceipt", "HistoryMonotonic", "StartupDrained"),
            "ExternalRecoveryBridge": ("AdmissionNeedsFreshDecision", "ReceiptNeedsCurrentAuthority", "DeleteCannotCancelAdmission"),
            "ProjectionRecoveryBridge": ("AcceptedIsVerified", "AcceptedNeverRegresses", "PendingHistoryNotCanceled", "RecoveryReconstructsLatest"),
            "CompensationOverlapBridge": ("ExactAdmission", "UnchosenHeadsSurvive", "CompletionDoesNotOverwrite"),
        }
        if model in bridge_properties and not expected_failure:
            if "INVARIANT Safety\n" not in config:
                config += "INVARIANT Safety\n"
            config += "".join(f"PROPERTY {p}\n" for p in bridge_properties[model])
        # SQLiteCollectionSafety.Safety already contains every named state
        # assertion; do not evaluate that same conjunction twice per state.
        combined_sqlite = model == "SQLiteCollectionSafety" and scenario == "combined"
        (directory / "case.cfg").write_text(config)
        start = time.monotonic()
        try:
            run = subprocess.run(
                [args.java, f"-Djava.io.tmpdir={directory}", "-Xmx4g" if combined_sqlite else "-Xmx1g", "-XX:+UseParallelGC", "-jar", str(Path(args.jar).resolve()),
                 "-workers", "4" if combined_sqlite else "2", "-lncheck", "final", "-coverage", "60", "-metadir", "states",
                 "-config", "case.cfg", f"{model}.tla"],
                cwd=directory, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, timeout=args.timeout)
            output, code = run.stdout, run.returncode
        except subprocess.TimeoutExpired as e:
            output = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
            code = None
        (directory / "tlc.log").write_text(output)
        stats = re.search(r"([\d,]+) states generated, ([\d,]+) distinct states found, ([\d,]+) states left on queue", output)
        complete = code == 0 and "Model checking completed. No error has been found." in output and stats and stats[3] == "0"
        failure = code not in (None, 0) and (
            (not temporal and f"Invariant {prop} is violated." in output) or
            (temporal and f"Action property {prop} is violated." in output) or
            (temporal and (f"Temporal property {prop} was violated." in output or
                           "Temporal properties were violated." in output) and
             "The following behavior constitutes a counter-example" in output))
        ok = bool(failure if expected_failure else complete)
        result = dict(name=name, passed=ok, expected="counterexample" if expected_failure else "exhaustive",
                      property=prop, exit=code, seconds=round(time.monotonic()-start, 2),
                      states=int(stats[2].replace(",", "")) if stats else None)
        results.append(result)
        print(json.dumps(result), flush=True)
        (root / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if not results:
        p.error("no matching cases")
    return 0 if all(r["passed"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
