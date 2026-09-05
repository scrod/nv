#!/usr/bin/env python3
"""Bounded UUID-policy experiments, reachability witnesses, and mutations.

Uses disposable copies and keeps assertion-specific logs.
Expected counterexamples are hypothesis rejections, not successful policies.
Timeouts, parser failures, and unrelated assertion failures never count.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

LAB = "UUIDAssociationLab"
CAUSAL = "CausalIncarnationSafety"
INTENT = "DeletionIntentTransportSafety"
HANDSHAKE = "LiveBindingHandshake"
COMPOSITION = "BindingIntentComposition"
RETIREMENT = "IntentRetirementLab"
COADD_INTENT = "CoAddIntentLab"
COADD_SLOT = "CoAddSlotLab"
COADD_LATE = "CoAddLateHistoryLab"
COADD_REVALIDATE = "CoAddRevalidationLab"
EXTERNAL_POLICY = "ExternalImportPolicyLab"
EXTERNAL_ADMIT = "ExternalImportAdmissionLab"
TEMPORAL = {"EveryAttemptTerminates", "EventuallyBound", "EventuallyFinished",
            "EventuallyReceived", "EventuallyApplied", "DurableImportsReachBoth", "PublicRecordsReachBoth",
            "AllPassesFinish", "AdmittedAttemptFinishes", "DisclosedProjectionSettles"}


def experiments():
    # model, label, policy, mode, assertion, expected outcome, mutations
    for scenario in ("lateHistory", "lateDelete", "stampFirst", "fileRace", "metadataRace",
                     "rootRace", "historyRace", "noteRace", "crash", "edit"):
        yield EXTERNAL_ADMIT, scenario + "-safety", "targeted", scenario, "Safety", "pass", []
    for scenario in ("lateDelete", "crash", "edit"):
        yield EXTERNAL_ADMIT, scenario + "-progress", "targeted", scenario, "DurableImportsReachBoth", "pass", []
    yield EXTERNAL_ADMIT, "local-completion", "targeted", "lateHistory", "AdmittedAttemptFinishes", "pass", []
    yield EXTERNAL_ADMIT, "disclosed-history-completion", "targeted", "stampFirst", "DisclosedProjectionSettles", "pass", []
    yield EXTERNAL_ADMIT, "replace-captured-body", "targeted", "fileRace", "AcknowledgedBytesRetained", "counterexample", [
        ('!.saved["b"]=s.capturedBody, !.phase="installed"',
         '!.saved["b"]=s.capturedBody, !.values["b"]="changed", !.phase="installed"')]
    yield EXTERNAL_ADMIT, "no-history-wakeup", "targeted", "stampFirst", "DisclosedProjectionSettles", "counterexample", [
        ('Reobserve == /\\ ~s.down', 'Reobserve == /\\ FALSE /\\ ~s.down')]
    for policy, scenario, assertion in (
        ("noFileFence", "fileRace", "ExactFileAdmission"),
        ("noFileFence", "metadataRace", "ExactFileAdmission"),
        ("noRootFence", "rootRace", "ExactRootAdmission"),
        ("noHistoryFence", "historyRace", "ExactHistoryAdmission"),
        ("noNoteFence", "noteRace", "ExactNoteAdmission"),
        ("aliasLate", "lateHistory", "NoRetroactiveAlias"),
        ("aliasLate", "lateDelete", "IndependentBirthSurvives"),
        ("equalMeansSame", "lateHistory", "IndependentBirthSurvives"),
        ("earlyPublish", "crash", "PublishedIsDurable"),
        ("forgetRecovery", "crash", "AcknowledgedImportsRecover"),
        ("stall", "lateHistory", "AdmittedAttemptFinishes"),
    ):
        yield EXTERNAL_ADMIT, scenario + "-" + assertion, policy, scenario, assertion, "counterexample", []
    for scenario, assertion in (
        ("lateHistory", "NeverImported"), ("lateHistory", "NeverLateDuplicate"),
        ("lateDelete", "NeverPreservedAfterDelete"), ("edit", "NeverRecoveredEdit"),
        ("stampFirst", "NeverWaitedForHistory"), ("lateDelete", "NeverParkedChild"),
        ("fileRace", "NeverRejectedRace"), ("metadataRace", "NeverRejectedRace"),
        ("rootRace", "NeverRejectedRace"), ("historyRace", "NeverRejectedRace"),
        ("noteRace", "NeverRejectedRace"), ("stampFirst", "NeverAssociatedInstead"),
        ("stampFirst", "NeverWaitedThenAssociated"),
        ("fileRace", "NeverKeptAdmittedSnapshot"),
    ):
        yield EXTERNAL_ADMIT, scenario + "-" + assertion, "targeted", scenario, assertion, "counterexample", []
    yield EXTERNAL_POLICY, "survey", "sweep", "all", None, "pass", []
    for policy in ("targeted", "historyPair", "eventPair", "similarityPair", "blanket", "automatic"):
        yield EXTERNAL_POLICY, "survey", policy, "all", None, "pass", []
        yield EXTERNAL_POLICY, "safety", policy, "all", "Safety", "pass", []
        yield EXTERNAL_POLICY, "healthy", policy, "all", "HealthyNotesNotOffered", "pass", []
        yield EXTERNAL_POLICY, "existing-paths", policy, "all", "ExistingAutomaticPathsRetained", "pass", []
        yield EXTERNAL_POLICY, "asymmetric-hints", policy, "all", "HintIndependentClassification", (
            "counterexample" if policy in {"eventPair", "similarityPair"} else "pass"), []
        for assertion in ("NoUnnecessaryQuestions", "EveryRepairOffered"):
            expected = "pass" if (policy, assertion) in {
                ("automatic", "NoUnnecessaryQuestions"), ("blanket", "EveryRepairOffered")} else "counterexample"
            yield EXTERNAL_POLICY, assertion, policy, "all", assertion, expected, []
    for assertion in ("CommonRepairsOffered", "UnrelatedNoiseDoesNotPrompt", "NoPooledEvidence"):
        yield EXTERNAL_POLICY, assertion, "targeted", "all", assertion, "pass", []
    for scenario in ("contradictoryLocalStamp", "contradictoryLocalDescriptor"):
        yield EXTERNAL_POLICY, scenario, "targeted", scenario, "ContradictoryLocalStampIsAmbiguous", "pass", []
    yield EXTERNAL_POLICY, "local-overrides-stamp", "localOverridesStamp", "contradictoryLocalStamp", "ContradictoryLocalStampIsAmbiguous", "counterexample", []
    yield EXTERNAL_POLICY, "ambiguous-descriptors", "targeted", "ambiguousDescriptors", "AmbiguousDescriptorsNeedReview", "pass", []
    yield EXTERNAL_POLICY, "ambiguous-fallthrough", "ambiguousFallsThrough", "ambiguousDescriptors", "AmbiguousDescriptorsNeedReview", "counterexample", []
    for policy, scenario, assertion in (
        ("voteIdentity", "samePathAndCreated", "AutomaticAssociationNeedsEvidence"),
        ("pooledVotes", "splitVotes", "NoPooledEvidence"),
        ("targeted", "all", "NeverDecided"),
        ("targeted", "all", "NeverOfferedBoth"),
        ("targeted", "all", "NeverReachedIndistinguishablePair"),
    ):
        yield EXTERNAL_POLICY, assertion, policy, scenario, assertion, "counterexample", []
    yield EXTERNAL_POLICY, "remove-repair-gate", "targeted", "healthySameBody", "HealthyNotesNotOffered", "counterexample", [
        ('Targeted == Rule({1,3},1,TRUE)', 'Targeted == Rule({1,3},1,FALSE)')]
    yield EXTERNAL_POLICY, "unknown-history-is-new", "targeted", "missingSegment", "KnownExceptionsRespected", "counterexample", [
        ('-> Answer("history",{})', '-> Answer("new",{})')]
    yield EXTERNAL_POLICY, "resurrect-deleted-descriptor", "targeted", "deletedDescriptor", "KnownExceptionsRespected", "counterexample", [
        ('-> Answer("restoration",{})', '-> Answer("new",{})')]
    yield EXTERNAL_POLICY, "disable-known-path", "targeted", "currentDescriptor", "ExistingAutomaticPathsRetained", "counterexample", [
        ('[] Cardinality(Strong(o))=1 ->', '[] FALSE /\\ Cardinality(Strong(o))=1 ->')]
    for policy in ("scan", "historyFirst", "priority", "hinted"):
        for scenario in ("safeSave", "rename", "asymmetric", "roundTrip", "reuse", "duplicate",
                         "gap", "fileRace", "rootRace", "historyRace", "staleStamp", "missingHistory", "hintStorm"):
            yield COADD_REVALIDATE, scenario + "-safety", policy, scenario, "Safety", "pass", []
        for scenario in ("safeSave", "rename", "asymmetric", "roundTrip", "gap"):
            yield COADD_REVALIDATE, scenario + "-ux", policy, scenario, "StableProjectionAccepted", "pass", []
        for scenario in ("safeSave", "gap", "missingHistory", "historyRace", "hintStorm"):
            yield COADD_REVALIDATE, scenario + "-progress", policy, scenario, "AllPassesFinish", "pass", []
        expected = "counterexample" if policy == "hinted" else "pass"
        yield COADD_REVALIDATE, "hintStorm-ux", policy, "hintStorm", "StableProjectionAccepted", expected, []
        yield COADD_REVALIDATE, "safeSave-work", policy, "safeSave", "OnePassForStableProjection", expected, []
    for policy, scenario, assertion, expected in (
        ("sticky", "safeSave", "StableProjectionAccepted", "counterexample"),
        ("sticky", "safeSave", "AllPassesFinish", "pass"),
        ("eventEpoch", "asymmetric", "SameHistorySameEpisode", "counterexample"),
        ("quietTrust", "reuse", "AssociationNeedsApplicableState", "counterexample"),
        ("hintAuthority", "duplicate", "NoDuplicateAssociation", "counterexample"),
        ("hintOnly", "asymmetric", "CompleteInspection", "counterexample"),
        ("hintOnly", "gap", "StableProjectionAccepted", "counterexample"),
        ("noFileFence", "fileRace", "ExactFileFence", "counterexample"),
        ("noRootFence", "rootRace", "ExactRootFence", "counterexample"),
        ("noHistoryFence", "historyRace", "ExactHistoryFence", "counterexample"),
        ("scan", "rename", "NeverHintFirst", "pass"),
        ("hinted", "rename", "NeverHintFirst", "counterexample"),
        ("hinted", "asymmetric", "NeverAsymmetricAgreement", "counterexample"),
        ("hinted", "safeSave", "NeverRecoveredFalseAlarm", "counterexample"),
        ("hinted", "roundTrip", "NeverRecoveredFalseAlarm", "counterexample"),
        ("hinted", "reuse", "NeverReviewedReuse", "counterexample"),
        ("hinted", "gap", "NeverGapFallback", "counterexample"),
        ("hinted", "missingHistory", "NeverWaitedForHistory", "counterexample"),
        ("hinted", "historyRace", "NeverAcceptedNewEpisode", "counterexample"),
        ("hinted", "fileRace", "NeverRetriedFile", "counterexample"),
        ("hinted", "rootRace", "NeverRetriedRoot", "counterexample"),
        ("hinted", "historyRace", "NeverRetriedHistory", "counterexample"),
        ("hinted", "hintStorm", "NeverExhaustedFromHints", "counterexample"),
        ("priority", "rename", "NeverHintFirst", "counterexample"),
        ("historyFirst", "rename", "NeverHintFirst", "counterexample"),
        ("priority", "hintStorm", "NeverExhaustedFromHints", "pass"),
        ("historyFirst", "missingHistory", "NeverDependencyFirst", "pass"),
        ("priority", "missingHistory", "NeverDependencyFirst", "counterexample"),
        ("priority", "staleStamp", "NeverReviewedStaleStamp", "counterexample"),
    ):
        yield COADD_REVALIDATE, scenario + "-" + assertion, policy, scenario, assertion, expected, []
    yield COADD_REVALIDATE, "ignore-duplicate", "priority", "duplicate", "NoDuplicateAssociation", "counterexample", [
        ('Cardinality(copies)<=1', 'TRUE')]
    yield COADD_REVALIDATE, "ignore-stale-stamp", "priority", "staleStamp", "AssociationNeedsApplicableState", "counterexample", [
        ('f.stamp \\in {r,2}', 'TRUE')]
    yield COADD_REVALIDATE, "ignore-body", "priority", "reuse", "AssociationNeedsApplicableState", "counterexample", [
        ('f.present /\\ f.body=0 /\\', 'f.present /\\')]
    yield COADD_REVALIDATE, "skip-finish", "priority", "safeSave", "AllPassesFinish", "counterexample", [
        ('Commit(h) == /\\ s.phase[h]="prepared"', 'Commit(h) == /\\ FALSE /\\ s.phase[h]="prepared"')]
    for policy in ("fresh", "slot", "exact", "consent"):
        for scenario in ("sameFile", "sharedEdited", "hiddenCopy", "differentPaths",
                         "differentEpochs", "forceNew", "ordinaryCreates", "consentedCopies",
                         "caseAmbiguous", "changingFile"):
            expected = "counterexample" if policy in {"slot", "exact"} and scenario == "hiddenCopy" else "pass"
            yield COADD_INTENT, scenario + "-safety", policy, scenario, "Safety", expected, []
    for policy, scenario, assertion, expected in (
        ("path", "differentEpochs", "NoFalseJoin", "counterexample"),
        ("path", "forceNew", "FreshIntentRespected", "counterexample"),
        ("fresh", "sameFile", "CommonFileUnified", "counterexample"),
        ("slot", "sameFile", "CommonFileUnified", "pass"),
        ("slot", "sharedEdited", "CommonFileUnified", "pass"),
        ("exact", "sameFile", "CommonFileUnified", "pass"),
        ("exact", "sharedEdited", "CommonFileUnified", "counterexample"),
        ("consent", "sameFile", "CommonFileUnified", "counterexample"),
        ("consent", "consentedCopies", "CommonFileUnified", "pass"),
        ("noFence", "changingFile", "NoStaleAdmission", "counterexample"),
        ("oneValue", "sameFile", "AllRevisionInputsRetained", "counterexample"),
        ("consent", "consentedCopies", "NeverUnified", "counterexample"),
        ("exact", "sharedEdited", "NeverSeparated", "counterexample"),
        ("consent", "consentedCopies", "NeverRecoveredImports", "counterexample"),
        ("exact", "changingFile", "NeverRetriedChangedFile", "counterexample"),
        ("consent", "consentedCopies", "DurableImportsReachBoth", "pass"),
    ):
        yield COADD_INTENT, scenario + "-" + assertion, policy, scenario, assertion, expected, []
    for scenario in ("deleteReuse", "renameReuse", "duplicateRelease", "unrelated", "aba",
                     "occupiedRace", "concurrentOccupants", "renameHintOnly"):
        yield COADD_SLOT, scenario + "-safety", "episode", scenario, "Safety", "pass", []
    for policy, scenario, assertion, expected in (
        ("path", "deleteReuse", "DifferentEpisodesStayDistinct", "counterexample"),
        ("releaseIDs", "duplicateRelease", "SameEpisodeSharesToken", "counterexample"),
        ("wholeHistory", "unrelated", "SameEpisodeSharesToken", "counterexample"),
        ("occupant", "aba", "DifferentEpisodesStayDistinct", "counterexample"),
        ("singleRelease", "duplicateRelease", "Safety", "pass"),
        ("singleRelease", "duplicateRelease", "NoUnnecessaryRefusal", "counterexample"),
        ("noFence", "occupiedRace", "FreshLocalEvidence", "counterexample"),
        ("oneOccupant", "concurrentOccupants", "NoKnownOccupantForgotten", "counterexample"),
        ("localEvents", "deleteReuse", "SameEpisodeSharesToken", "counterexample"),
        ("eventRelease", "renameHintOnly", "NoKnownOccupantForgotten", "counterexample"),
        ("episode", "renameHintOnly", "NeverDeferredRenameHint", "counterexample"),
        ("episode", "duplicateRelease", "NeverSharedAfterDifferentReleases", "counterexample"),
        ("episode", "aba", "NeverSeparatedABA", "counterexample"),
        ("episode", "unrelated", "NeverIgnoredUnrelatedHistory", "counterexample"),
        ("episode", "occupiedRace", "NeverRejectedNewOccupant", "counterexample"),
        ("episode", "renameReuse", "NeverSharedReuse", "counterexample"),
        ("episode", "concurrentOccupants", "NeverSharedAfterAllOccupantsReleased", "counterexample"),
    ):
        yield COADD_SLOT, scenario + "-" + assertion, policy, scenario, assertion, expected, []
    for scenario in ("staleEcho", "hiddenRestore", "explicitRestore", "knownDelete", "observeImport", "lateEdit"):
        yield COADD_LATE, scenario + "-safety", "causal", scenario, "Safety", "pass", []
    for scenario in ("staleEcho", "hiddenRestore", "explicitRestore", "knownDelete"):
        yield COADD_LATE, scenario + "-safety", "review", scenario, "Safety", "pass", []
    yield COADD_LATE, "wrong-pending-copy", "review", "staleEcho", "ReviewBytesPreserved", "counterexample", [
        ('!.freshValue="original"', '!.freshValue="wrong"')]
    yield COADD_LATE, "forget-recovered-import", "causal", "staleEcho", "RecoveredHistoryRetained", "counterexample", [
        ('!.known[2]=s.durable[2]', '!.known[2]=s.durable[2] \\ {"b"}')]
    for policy, scenario, assertion, expected in (
        ("fresh", "staleEcho", "Safety", "pass"),
        ("birthDelete", "staleEcho", "ConcurrentImportPreserved", "counterexample"),
        ("equalMeansObserved", "staleEcho", "NoEqualPayloadCoverageGuess", "counterexample"),
        ("revive", "observeImport", "OldBirthStaysDeleted", "counterexample"),
        ("fresh", "staleEcho", "NoStaleEchoAsNote", "counterexample"),
        ("causal", "staleEcho", "NoStaleEchoAsNote", "counterexample"),
        ("review", "staleEcho", "NoStaleEchoAsNote", "pass"),
        ("review", "hiddenRestore", "HiddenRestoreAutomatic", "counterexample"),
        ("causal", "hiddenRestore", "HiddenRestoreAutomatic", "pass"),
        ("birthDelete", "staleEcho", "NoStaleEchoAsNote", "pass"),
        ("causal", "staleEcho", "NeverRecoveredPreservation", "counterexample"),
        ("review", "staleEcho", "NeverRecoveredFreshChoice", "counterexample"),
        ("causal", "lateEdit", "NeverPreservedUnseenEdit", "counterexample"),
        ("causal", "observeImport", "NeverParkedDelete", "counterexample"),
        ("review", "hiddenRestore", "NeverAskedThenRestored", "counterexample"),
        ("causal", "knownDelete", "NeverImportedAfterKnownDelete", "counterexample"),
        ("causal", "observeImport", "NeverHonoredObservedDelete", "counterexample"),
        ("causal", "lateEdit", "PublicRecordsReachBoth", "pass"),
        ("review", "staleEcho", "PublicRecordsReachBoth", "pass"),
    ):
        yield COADD_LATE, scenario + "-" + assertion, policy, scenario, assertion, expected, []
    for scenario in ("current", "staleRead"):
        yield RETIREMENT, scenario + "-safety", "pinnedSnapshot", scenario, "Safety", "pass", []
    yield RETIREMENT, "no-retirement", "retain", "current", "NeverCollectedAll", "pass", []
    for policy, scenario, assertion in (
            ("maxAck", "current", "NoAckForUnseenOperation"),
            ("retain", "current", "NoBackupResurrection"),
            ("acksOnly", "current", "NoNewcomerHistoryLoss"),
            ("acksOnly", "current", "RetiredHistoryStillAvailable"),
            ("snapshot", "current", "NoBackupResurrection"),
            ("snapshot", "staleRead", "NoNewcomerHistoryLoss")):
        yield RETIREMENT, scenario + "-" + assertion, policy, scenario, assertion, "counterexample", []
    for assertion in ("NeverCollectedAll", "NeverRejoinedAfterCollection",
                      "NeverBootstrappedAfterCollection", "NeverRejectedStaleSnapshot"):
        yield RETIREMENT, "witness-" + assertion, "pinnedSnapshot", "staleRead", assertion, "counterexample", []
    yield RETIREMENT, "trust-stale-bootstrap", "pinnedSnapshot", "staleRead", "NoNewcomerHistoryLoss", "counterexample", [
        ('r.fetched /\\ r.observed = Events', 'r.fetched')]
    yield RETIREMENT, "resume-before-bootstrap", "pinnedSnapshot", "staleRead", "NoBackupResurrection", "counterexample", [
        ('!.ready = Policy # "pinnedSnapshot"', '!.ready = TRUE')]
    for scenario in ("lifecycle", "copy", "retarget", "offline"):
        yield COMPOSITION, scenario + "-safety", "guarded", scenario, "Safety", "pass", []
    for policy, scenario, assertion in (
            ("tagBinding", "copy", "NoWrongIncarnationDeletion"),
            ("unfencedBinding", "retarget", "NoWrongIncarnationDeletion"),
            ("guarded", "relay", "NoWrongIncarnationDeletion"),
            ("guarded", "hiddenRestore", "NoWrongIncarnationDeletion"),
            ("reuseBirth", "lifecycle", "NoWrongIncarnationDeletion"),
            ("volatileReceipt", "lifecycle", "NoForgottenReceipt"),
            ("earlyCleanup", "clean", "NoForgottenOutbox"),
            ("noPublicationFence", "lifecycle", "NoWrongIncarnationDeletion"),
            ("noEditPreservation", "lifecycle", "NoLostDurableEdit")):
        yield COMPOSITION, scenario + "-" + assertion, policy, scenario, assertion, "counterexample", []
    for policy, assertion, expected in (
            ("guarded", "EventuallyReceived", "pass"), ("guarded", "EventuallyApplied", "pass"),
            ("trashOnly", "Safety", "pass"), ("trashOnly", "EventuallyReceived", "counterexample"),
            ("deferBinding", "Safety", "pass"), ("deferBinding", "EventuallyApplied", "counterexample")):
        yield COMPOSITION, "clean-" + assertion, policy, "clean", assertion, expected, []
    for assertion in ("NeverApplied", "NeverPreservedEdit", "NeverRecoveredDecision",
                      "NeverKeptRestoration", "NeverReplayedConsumedIntent"):
        yield COMPOSITION, "witness-" + assertion, "guarded", "lifecycle", assertion, "counterexample", []
    yield COMPOSITION, "witness-NeverEditedWhileUnbound", "guarded", "copy", "NeverEditedWhileUnbound", "counterexample", []
    yield COMPOSITION, "forget-recovered-alias", "guarded", "lifecycle", "DurableAliasesSurvive", "counterexample", [
        ('!.down = FALSE, !.note = s.wal,', '!.down = FALSE, !.note = [s.wal EXCEPT !.aliases = {2}],')]
    for scenario in ("clean", "copy", "retarget", "offline"):
        yield HANDSHAKE, scenario + "-safety", "fenced", scenario, "NoFalseBinding", "pass", []
    for policy, scenario in (("tag", "copy"), ("challenge", "retarget"),
                             ("reusedNonce", "stale"), ("fenced", "relay")):
        yield HANDSHAKE, scenario + "-rejection", policy, scenario, "NoFalseBinding", "counterexample", []
    for policy, scenario, expected in (("fenced", "clean", "pass"),
                                        ("defer", "clean", "counterexample"),
                                        ("fenced", "offline", "counterexample")):
        yield HANDSHAKE, scenario + "-progress", policy, scenario, "EventuallyBound", expected, []
    for scenario, assertion in (("clean", "NeverBound"), ("copy", "NeverParked"),
                                ("relay", "NeverBoundAfterRelay"), ("retarget", "NeverCopiedAfterAck")):
        yield HANDSHAKE, scenario + "-witness-" + assertion, "fenced", scenario, assertion, "counterexample", []
    yield HANDSHAKE, "remove-endpoint-fence", "fenced", "retarget", "NoFalseBinding", "counterexample", [
        ('Policy # "fenced" \\/ b.anchor = b.handle', 'TRUE')]
    yield HANDSHAKE, "reuse-attempt-nonce", "fenced", "stale", "NoFalseBinding", "counterexample", [
        ('Nonce == IF Policy = "reusedNonce" THEN 1 ELSE 2', 'Nonce == 1')]
    yield INTENT, "baseline", "retain", "close", None, "pass", []
    for policy, assertion in (("forgetOnPurge", "NoForgottenAcceptedIntent"),
                              ("ignoreBirth", "NoOldIntentDeletesRestoration")):
        yield INTENT, assertion, policy, "close", assertion, "counterexample", []
    for assertion in ("NeverAppliedAfterArtifactLoss", "NeverRecoveredReceipt",
                      "NeverMissedPurgedIntent", "NeverPreservedRestoration"):
        yield INTENT, "witness-" + assertion, "retain", "close", assertion, "counterexample", []
    yield INTENT, "forget-durable-receipt", "retain", "close", "NoForgottenAcceptedIntent", "counterexample", [
        ('!.down = TRUE, !.live = 0, !.captured = 0,', '!.down = TRUE, !.live = 0, !.captured = 0, !.receipt = 0,')]
    yield INTENT, "delete-on-absence", "retain", "close", "NoUnexplainedDeletion", "counterexample", [
        ('s.live # 0 /\\ s.receipt = 1', 's.live # 0'),
        ('Policy = "ignoreBirth" \\/ s.live = s.receipt', 'Policy = "ignoreBirth" \\/ s.live = 1')]
    yield LAB, "current-snapshot-baseline", "currentSnapshot", "close", None, "pass", []
    yield LAB, "reject-portable-provider-equality", "providerEquality", "close", "NoFalseSeparation", "counterexample", []
    for assertion in ("NeverJoined", "NeverSeparated", "NeverDeferredIndependentImport", "NeverReopened"):
        yield LAB, "witness-" + assertion, "currentSnapshot", "close", assertion, "counterexample", []
    yield LAB, "trust-remote-claims", "currentSnapshot", "close", "NoFalseJoin", "counterexample", [
        ('IF o.sameObservationFrame /\\ o.leftScope = o.rightScope /\\',
         'IF TRUE /\\ o.leftScope = o.rightScope /\\'),
        ('[] c = "hiddenCopy" -> [BaseObservation EXCEPT !.rightID = 1,',
         '[] c = "hiddenCopy" -> [BaseObservation EXCEPT !.rightScope = 1, !.rightItem = 11, !.rightID = 1,')]
    for scenario in ("restore", "gap"):
        yield CAUSAL, scenario + "-baseline", "causal", scenario, None, "pass", []
    for policy, scenario, assertion in (
            ("uuidDelete", "restore", "NoLostProtectedBirth"),
            ("dropContext", "restore", "NoResurrectionAfterObservedRemoval"),
            ("registerOnly", "restore", "NoResurrectionAfterObservedRemoval"),
            ("maxClock", "gap", "NoLostProtectedBirth")):
        yield CAUSAL, assertion, policy, scenario, assertion, "counterexample", []
    for scenario, assertion in (("restore", "NeverPreservedFreshRestore"),
                                ("gap", "NeverMergedUnseenBirths"),
                                ("restore", "NeverRecoveredDeletion")):
        yield CAUSAL, "witness-" + assertion, "causal", scenario, assertion, "counterexample", []
    yield CAUSAL, "reuse-birth", "causal", "restore", "NoResurrectionAfterObservedRemoval", "counterexample", [
        ('after == Envelope({2},{1,2},s.replica[2].deleted)', 'after == Envelope({1},{1},s.replica[2].deleted)')]
    yield CAUSAL, "delete-all-births", "causal", "restore", "NoLostProtectedBirth", "counterexample", [
        (r'kept == s.replica[1].live \ {1}', 'kept == {}')]
    yield CAUSAL, "drop-exchange", "causal", "gap", "CompleteExchangeAgrees", "counterexample", [
        ('after == Merge(s.replica[h],other)', 'after == s.replica[h]')]
    yield LAB, "baseline", "evidence", "close", None, "pass", []
    for policy in ("database", "xattr", "minimum", "fingerprint", "aliases",
                   "incarnation", "omission", "evidence"):
        for assertion in ("NoFalseJoin", "NoFalseSeparation", "NoFalseDeletion"):
            holds = (policy == "evidence" or
                     (policy == "incarnation" and assertion == "NoFalseSeparation"))
            yield LAB, assertion, policy, "close", assertion, "pass" if holds else "counterexample", []
    for assertion in ("NeverJoined", "NeverSeparated", "NeverDeleted", "NeverPreservedEdit",
                      "NeverKeptRestored", "NeverReopened", "NoDeferral"):
        yield LAB, "witness-" + assertion, "evidence", "close", assertion, "counterexample", []
    # Mutate mechanics; keep the independent assertions unchanged.
    yield LAB, "trust-copied-proof", "evidence", "close", "NoFalseJoin", "counterexample", [
        ('o.proof = "same" -> "join"', 'o.proof # "unknown" -> "join"')]
    yield LAB, "false-positive-proof-input", "evidence", "close", "NoFalseJoin", "counterexample", [
        ('[] c \\in {"unknownSharedTag","copiedTagNewUUID"} ->\n       [BaseObservation EXCEPT !.leftTag = 2, !.rightTag = 2]',
         '[] c \\in {"unknownSharedTag","copiedTagNewUUID"} ->\n       [BaseObservation EXCEPT !.leftTag = 2, !.rightTag = 2, !.proof = "same"]')]
    yield LAB, "ignore-fence", "evidence", "close", "NoStalePublication", "counterexample", [
        ('Publish ==\n /\\ s.phase = "prepared" /\\ s.fence = s.capturedFence',
         'Publish ==\n /\\ s.phase = "prepared"')]
    yield LAB, "drop-delete-edit-copy", "evidence", "close", "NoPayloadLoss", "counterexample", [
        ('IF o.leftBody # o.baseBody THEN {{"L"}} ELSE {}', '{}')]
    yield LAB, "empty-checkpoint", "evidence", "close", "CheckpointMatchesPublication", "counterexample", [
        ('!.checkpoint = s.durableGroups', '!.checkpoint = {}')]
    yield LAB, "drop-deferred-inputs", "evidence", "close", "DeferredAndRejectedRetainInputs", "counterexample", [
        ('!.phase = "deferred"]', '!.phase = "deferred", !.captured = BaseObservation]')]
    yield LAB, "stall-unknown-evidence", "evidence", "close", "EveryAttemptTerminates", "counterexample", [
        ('Defer ==\n /\\ s.phase = "prepared"', 'Defer ==\n /\\ FALSE /\\ s.phase = "prepared"')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default="java")
    parser.add_argument("--jar", required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--only", help="Run labels containing this substring")
    args = parser.parse_args()
    source = Path(__file__).resolve().parent
    output = Path(tempfile.mkdtemp(prefix="notation-tla-uuid-"))
    print(f"Results: {output}", flush=True)
    results = []
    for model, label, policy, mode, assertion, expected, mutations in experiments():
        label = f"{model}-{policy}-{label}"
        if args.only and args.only not in label:
            continue
        directory = output / label
        directory.mkdir()
        body = (source / f"{model}.tla").read_text()
        for before, after in mutations:
            if body.count(before) != 1:
                raise AssertionError(f"{label}: mutation must match exactly once: {before!r}")
            body = body.replace(before, after, 1)
        (directory / f"{model}.tla").write_text(body)
        if model == COMPOSITION:
            (directory / f"{HANDSHAKE}.tla").write_text((source / f"{HANDSHAKE}.tla").read_text())
        if model == EXTERNAL_ADMIT:
            (directory / f"{EXTERNAL_POLICY}.tla").write_text((source / f"{EXTERNAL_POLICY}.tla").read_text())
        if assertion:
            kind = "PROPERTY" if assertion in TEMPORAL else "INVARIANT"
            spec = "FairSpec" if assertion in TEMPORAL else "Spec"
            config = f'CONSTANT Policy = "{policy}"\n'
            if model in {CAUSAL, HANDSHAKE, COMPOSITION, RETIREMENT, COADD_INTENT, COADD_SLOT, COADD_LATE, COADD_REVALIDATE, EXTERNAL_POLICY, EXTERNAL_ADMIT}:
                config += f'CONSTANT Scenario = "{mode}"\n'
            config += f"SPECIFICATION {spec}\nINVARIANT TypeOK\n{kind} {assertion}\nCHECK_DEADLOCK FALSE\n"
        else:
            config = (source / f"{model}.cfg").read_text()
            if model == EXTERNAL_POLICY:
                config = config.replace('Policy = "sweep"', f'Policy = "{policy}"')
            if model == LAB:
                config = config.replace('Policy = "evidence"', f'Policy = "{policy}"')
            if model == CAUSAL:
                config = config.replace('Scenario = "restore"', f'Scenario = "{mode}"')
        (directory / f"{model}.cfg").write_text(config)
        command = [args.java, "-Xmx1g", "-XX:+UseParallelGC", "-jar", str(args.jar.resolve()),
                   "-workers", "4", "-lncheck", "final", "-coverage", "60",
                   "-metadir", str(directory / "states"), "-config", f"{model}.cfg", f"{model}.tla"]
        with (directory / "tlc.log").open("w") as log:
            completed = subprocess.run(command, cwd=directory, stdout=log,
                                       stderr=subprocess.STDOUT, timeout=args.timeout)
        text = (directory / "tlc.log").read_text()
        counts = re.findall(r"(\d+) states generated, (\d+) distinct states found, 0 states left on queue", text)
        exhaustive = (completed.returncode == 0 and counts and
                      "Model checking completed. No error has been found." in text)
        violation = assertion and re.search(
            rf"(?:Invariant|Action property) {re.escape(assertion)}\b.*violated", text)
        # There is exactly ONE temporal property in this configuration.
        if assertion in TEMPORAL:
            violation = ("Temporal properties were violated" in text and
                         "The following behavior constitutes a counter-example" in text)
        outcome = "pass" if exhaustive else "counterexample" if violation and completed.returncode else "error"
        result = dict(model=model, label=label, policy=policy, assertion=assertion,
                      expected=expected, outcome=outcome, counts=counts[-1] if exhaustive else None)
        results.append(result)
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        if outcome != expected:
            raise AssertionError(f"{label}: expected {expected}, got {outcome}; see {directory}")
        if model == EXTERNAL_POLICY and not assertion:
            rows = re.findall(r'<<"NV_IMPORT_SURVEY",\s*(\d+),\s*(\d+),\s*(TRUE|FALSE),\s*'
                              r'(\d+),\s*(\d+),\s*(\d+),\s*(\d+)>>', text)
            survey = [dict(mask=int(m), threshold=int(t), repairGate=g == "TRUE",
                           extraQuestions=int(q), missedRepairs=int(r), missedCore=int(c), noisyQuestions=int(n))
                      for m, t, g, q, r, c, n in sorted(set(rows))]
            assert len(survey) == (22528 if policy == "sweep" else 1), f"Incomplete policy survey: {len(survey)} rows"
            costs = {(r["extraQuestions"], r["missedRepairs"]) for r in survey}
            pareto = {p for p in costs if not any(q != p and q[0] <= p[0] and q[1] <= p[1] for q in costs)}
            for row in survey:
                row["pareto"] = (row["extraQuestions"], row["missedRepairs"]) in pareto
            (directory / "survey.json").write_text(json.dumps(survey, indent=2) + "\n")
            print(f"SURVEY {len(survey)} rules; question/missed-repair frontier: {sorted(pareto)}", flush=True)
        if not assertion:
            dead = re.findall(r"^<([^>]+)>: 0:0$", text, re.MULTILINE)
            if model == CAUSAL and mode == "gap":
                dead = [name for name in dead if not name.startswith(("DeleteOriginal ", "RestoreFresh "))]
            if dead:
                raise AssertionError(f"{label}: unexercised actions: {dead}")
        print(f"{outcome.upper()} {label}", flush=True)
    if not results:
        raise AssertionError("No experiments selected")
    print(f"All {len(results)} expected outcomes verified; logs and traces: {output}", flush=True)


if __name__ == "__main__":
    main()
