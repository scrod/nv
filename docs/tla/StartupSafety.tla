--------------------------- MODULE StartupSafety ---------------------------
EXTENDS FiniteSets, Naturals

\* FileVersions are immutable persistent version identifiers. catalogToken
\* values are opaque; Naturals and +1 only provide bounded fresh values.
\* checkpointArtifactIncarnation is likewise an opaque equality token. BOOLEAN
\* supplies only the original and one replacement incarnation, not an order.

CONSTANTS
    FileVersions,
    FileVersion1,
    FileVersion2,
    FileStates,
    FileState1,
    FileState2,
    CheckpointIDs,
    InitialCheckpoint,
    MaxCatalogToken,
    None

ASSUME
    /\ FileVersions = {FileVersion1, FileVersion2}
    /\ FileVersion1 # FileVersion2
    /\ {FileState1, FileState2} \subseteq FileStates
    /\ FileState1 # FileState2
    /\ InitialCheckpoint \in CheckpointIDs
    /\ MaxCatalogToken >= 2
    /\ None \notin CheckpointIDs
    /\ None \notin BOOLEAN

VARIABLE state

vars == <<state>>

CheckpointStatuses == {
    "current", "stale", "unmaterialized", "absent", "unavailable",
    "corrupt", "invalid"
}
ParentStatuses == {"current", "stale", "unavailable"}
ByteStatuses == {"complete", "unavailable", "corrupt"}
JournalStatuses == {"absent", "complete", "invalid", "unavailable"}
RebuildScopes == {"none", "exact", "currentVisible"}
Phases == {
    "checkingPause", "checkingCheckpoint", "materializing",
    "absentDecision", "recoveryChoices", "mandatory", "recoverLegacy",
    "recoverActive", "recoverRetained", "loaded", "journalCreating", "journalHeader",
    "journalClaimWritten", "journalReady", "editable", "rebuildGather",
    "rebuildFenced", "rebuildPrepared", "rebuildInstalled", "quit",
    "chooseRoot", "crashed"
}
Scenarios == {
    "currentClean", "currentLegacy", "currentBoth", "stale",
    "unmaterialized", "absentOwned", "absentExisting", "absentRebuild",
    "unavailableENOENT", "corruptRebuild", "invalidRebuildFallback",
    "offlineComplete",
    "offlineInvalidJournal", "pausedCurrent", "pausedFailure",
    "currentInvalidMandatory", "currentRetainedCovered",
    "currentRetainedMismatch", "offlineInvalidRetained"
}

InitialStatus(scenario) ==
    CASE scenario \in {"currentClean", "currentLegacy", "currentBoth",
            "pausedCurrent", "pausedFailure", "currentInvalidMandatory",
            "currentRetainedCovered", "currentRetainedMismatch"}
            -> "current"
      [] scenario \in {"stale", "offlineComplete",
                        "offlineInvalidJournal", "offlineInvalidRetained"}
            -> "stale"
      [] scenario = "unmaterialized" -> "unmaterialized"
      [] scenario \in {"absentOwned", "absentExisting", "absentRebuild"}
            -> "absent"
      [] scenario = "corruptRebuild" -> "corrupt"
      [] scenario = "invalidRebuildFallback" -> "invalid"
      [] OTHER -> "unavailable"

InitialParentStatus(scenario) ==
    IF scenario = "unavailableENOENT" THEN "unavailable" ELSE "current"

InitialBytes(scenario) ==
    CASE scenario \in {"unmaterialized", "absentOwned", "absentExisting",
                        "absentRebuild", "unavailableENOENT"} -> "unavailable"
      [] scenario = "corruptRebuild" -> "corrupt"
      [] OTHER -> "complete"

InitialLegacyStatus(scenario) ==
    IF scenario \in {"currentLegacy", "currentBoth", "offlineComplete"}
    THEN "complete"
    ELSE "absent"

InitialActiveStatus(scenario) ==
    CASE scenario \in {"currentBoth", "offlineComplete"} -> "complete"
      [] scenario \in {"offlineInvalidJournal", "currentInvalidMandatory"}
            -> "invalid"
      [] OTHER -> "absent"

InitialRetainedStatus(scenario) ==
    CASE scenario \in {"currentRetainedCovered", "currentRetainedMismatch"}
            -> "complete"
      [] scenario = "offlineInvalidRetained" -> "invalid"
      [] OTHER -> "absent"

InitiallyPaused(scenario) ==
    scenario \in {"pausedCurrent", "pausedFailure"}

InitialKnownFiles(scenario) ==
    IF scenario \in {"absentRebuild", "corruptRebuild",
                      "invalidRebuildFallback"}
    THEN {FileVersion1}
    ELSE {}

InitialStableUnsupported(scenario) ==
    scenario = "invalidRebuildFallback"

FileState(version) ==
    IF version = FileVersion1 THEN FileState1 ELSE FileState2

LegacyReady ==
    \/ state.legacyStatus = "absent"
    \/ state.legacyRecovered

ActiveReady ==
    \/ state.activeStatus = "absent"
    \/ state.activeRecovered

RetainedReady ==
    \/ state.retainedStatus = "absent"
    \/ /\ state.retainedStatus = "complete"
       /\ state.retainedCoverageMatches
    \/ state.retainedRecovered

MandatoryInputsUsable ==
    /\ state.legacyStatus \in {"absent", "complete"}
    /\ state.activeStatus \in {"absent", "complete"}
    /\ state.retainedStatus \in {"absent", "complete"}

CheckpointAcceptableForOffline ==
    /\ state.bytesStatus = "complete"
    /\ state.checkpointStatus \in {"current", "stale", "unmaterialized"}

RebuildSnapshotStable ==
    /\ state.rebuildSnapshot = state.rebuildSecondSnapshot
    /\ state.rebuildSnapshotCatalogToken = state.catalogToken
    /\ state.rebuildSecondCatalogToken = state.catalogToken

RebuildScopeQualified ==
    \/ /\ state.rebuildScope = "exact"
       /\ state.rebuildEnumerationComplete
    \/ /\ state.rebuildScope = "currentVisible"
       /\ state.rebuildStableUnsupported

RebuildExpectedCheckpointStatusMatches ==
    IF state.rebuildExpectedAbsence
    THEN state.checkpointStatus = "absent"
    ELSE state.checkpointStatus \in {"corrupt", "invalid"}

RebuildExpectedCheckpointIdentityMatches ==
    IF state.rebuildExpectedAbsence
    THEN state.rebuildExpectedCheckpointIncarnation = None
    ELSE state.rebuildExpectedCheckpointIncarnation =
            state.checkpointArtifactIncarnation

RebuildExpectedCheckpointMatches ==
    /\ RebuildExpectedCheckpointStatusMatches
    /\ RebuildExpectedCheckpointIdentityMatches

InitializeEmpty(explicit, checkpoint) ==
    [state EXCEPT
        !.phase = "loaded",
        !.explicitCreateConfirmed = explicit,
        !.newCollectionInitialized = TRUE,
        !.newCollectionCheckpointInstalled = TRUE,
        !.checkpointLoaded = TRUE,
        !.checkpointVerified = TRUE,
        !.liveStorePublished = TRUE,
        !.liveStore = {},
        !.lateExternalEvidence = @ \cup state.knownFileVersions,
        !.installedCheckpoint = checkpoint,
        !.usedCheckpointIDs = @ \cup {checkpoint},
        !.checkpointInstallCount[checkpoint] = @ + 1,
        !.initializationWitnesses = @ \cup
            {<<state.checkpointStatus = "absent",
               state.parentStatus = "current",
               state.rootCreatedThisOperation \/ explicit,
               state.checkpointStatus # "unavailable",
               checkpoint \notin state.usedCheckpointIDs>>}
                ]

Init ==
    \E scenario \in Scenarios:
        LET paused == InitiallyPaused(scenario)
            knownFiles == InitialKnownFiles(scenario)
        IN state = [
            scenario |-> scenario,
            phase |-> IF paused THEN "checkingPause" ELSE "checkingCheckpoint",
            checkpointStatus |-> InitialStatus(scenario),
            parentStatus |-> InitialParentStatus(scenario),
            bytesStatus |-> InitialBytes(scenario),
            rootCreatedThisOperation |-> scenario = "absentOwned",
            initiallyPaused |-> paused,
            syncPaused |-> paused,
            resumeAttempted |-> FALSE,
            resumeSucceeded |-> FALSE,
            syncControllerWillRetry |-> FALSE,
            freshnessEvaluated |-> FALSE,
            legacyStatus |-> InitialLegacyStatus(scenario),
            activeStatus |-> InitialActiveStatus(scenario),
            retainedStatus |-> InitialRetainedStatus(scenario),
            retainedCoverageMatches |->
                scenario = "currentRetainedCovered",
            legacyRecovered |-> FALSE,
            activeRecovered |-> FALSE,
            retainedRecovered |-> FALSE,
            checkpointGeneration |-> 0,
            checkpointArtifactIncarnation |-> FALSE,
            checkpointArtifactReplacementOccurred |-> FALSE,
            activeRecoveryWitnesses |-> {},
            retainedRecoveryWitnesses |-> {},
            recoveredWork |-> {},
            offlineRequested |-> FALSE,
            offlineStatusVisible |-> FALSE,
            checkpointLoaded |-> FALSE,
            checkpointVerified |-> FALSE,
            liveStorePublished |-> FALSE,
            liveStore |-> {},
            editable |-> FALSE,
            explicitCreateConfirmed |-> FALSE,
            newCollectionInitialized |-> FALSE,
            newCollectionCheckpointInstalled |-> FALSE,
            initializationWitnesses |-> {},
            loadWitnesses |-> {},
            recoveryEvidencePresent |-> TRUE,
            recoveryEvidencePreserved |-> TRUE,
            unclaimedJournalEvidencePresent |-> TRUE,
            knownFileVersions |-> knownFiles,
            catalogToken |-> 0,
            rebuildStableUnsupported |-> InitialStableUnsupported(scenario),
            rebuildScope |-> "none",
            rebuildEnumerationComplete |-> FALSE,
            rebuildSnapshot |-> {},
            rebuildSnapshotCatalogToken |-> 0,
            rebuildRead |-> {},
            rebuildUnreadable |-> {},
            rebuildCandidate |-> {},
            rebuildSecondSnapshot |-> {},
            rebuildSecondCatalogToken |-> 0,
            stagedRebuild |-> {},
            rebuildExpectedAbsence |-> FALSE,
            rebuildExpectedCheckpointIncarnation |-> None,
            rebuildInstallWitnesses |-> {},
            installedCheckpoint |-> InitialCheckpoint,
            usedCheckpointIDs |-> {InitialCheckpoint},
            checkpointInstallCount |-> [checkpoint \in CheckpointIDs |->
                IF checkpoint = InitialCheckpoint THEN 1 ELSE 0],
            rebuildPublished |-> FALSE,
            rebuildLimitedHistoryVisible |-> FALSE,
            rebuildWitnesses |-> {},
            freshJournalHeaderSynced |-> FALSE,
            freshJournalClaimWritten |-> FALSE,
            freshJournalClaimSynced |-> FALSE,
            lateExternalEvidence |-> {}
                ]

ResumePausedCheckpoint ==
    /\ state.phase = "checkingPause"
    /\ state.syncPaused
    /\ \/ state' = [state EXCEPT
            !.phase = "checkingCheckpoint",
            !.syncPaused = FALSE,
            !.resumeAttempted = TRUE,
            !.resumeSucceeded = TRUE
                ]
       \/ state' = [state EXCEPT
            !.phase = "recoveryChoices",
            !.resumeAttempted = TRUE,
            !.resumeSucceeded = FALSE,
            !.syncControllerWillRetry = TRUE
                ]

UseCurrentCheckpoint ==
    /\ state.phase = "checkingCheckpoint"
    /\ state.checkpointStatus = "current"
    /\ state.bytesStatus = "complete"
    /\ state' = [state EXCEPT
        !.phase = "mandatory",
        !.freshnessEvaluated = TRUE
                ]

RequestCheckpointMaterialization ==
    /\ state.phase = "checkingCheckpoint"
    /\ state.checkpointStatus \in {"stale", "unmaterialized"}
    /\ state' = [state EXCEPT
        !.phase = "materializing",
        !.freshnessEvaluated = TRUE
                ]

ClassifyCheckpointAbsence ==
    /\ state.phase = "checkingCheckpoint"
    /\ state.checkpointStatus = "absent"
    /\ state.parentStatus = "current"
    /\ state' = [state EXCEPT
        !.phase = "absentDecision",
        !.freshnessEvaluated = TRUE
                ]

FailClosedCheckpointClassification ==
    /\ state.phase = "checkingCheckpoint"
    /\ \/ state.checkpointStatus \in {"unavailable", "corrupt", "invalid"}
       \/ state.parentStatus # "current"
    /\ state' = [state EXCEPT
        !.phase = "recoveryChoices",
        !.freshnessEvaluated = TRUE
                ]

MaterializeCheckpoint ==
    /\ state.phase = "materializing"
    /\ \/ state' = [state EXCEPT
            !.phase = "mandatory",
            !.checkpointStatus = "current",
            !.bytesStatus = "complete"
                ]
       \/ state' = [state EXCEPT !.phase = "recoveryChoices"]

InitializeOwnedRoot ==
    /\ state.phase = "absentDecision"
    /\ state.rootCreatedThisOperation
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = InitializeEmpty(FALSE, checkpoint)

RequireExplicitCreation ==
    /\ state.phase = "absentDecision"
    /\ ~state.rootCreatedThisOperation
    /\ state' = [state EXCEPT !.phase = "recoveryChoices"]

ConfirmExplicitCreation ==
    /\ state.phase = "recoveryChoices"
    /\ state.checkpointStatus = "absent"
    /\ state.parentStatus = "current"
    /\ ~state.rootCreatedThisOperation
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = InitializeEmpty(TRUE, checkpoint)

StartLegacyRecovery ==
    /\ state.phase = "mandatory"
    /\ state.legacyStatus = "complete"
    /\ ~state.legacyRecovered
    /\ state' = [state EXCEPT !.phase = "recoverLegacy"]

RecoverLegacyJournal ==
    /\ state.phase = "recoverLegacy"
    /\ state' = [state EXCEPT
        !.phase = "mandatory",
        !.legacyRecovered = TRUE,
        !.checkpointGeneration = @ + 1,
        !.recoveredWork = @ \cup {FileState2}
                ]

StartActiveRecovery ==
    /\ state.phase = "mandatory"
    /\ LegacyReady
    /\ state.activeStatus = "complete"
    /\ ~state.activeRecovered
    /\ state' = [state EXCEPT !.phase = "recoverActive"]

RecoverActiveJournal ==
    /\ state.phase = "recoverActive"
    /\ LegacyReady
    /\ state' = [state EXCEPT
        !.phase = "mandatory",
        !.activeRecovered = TRUE,
        !.activeRecoveryWitnesses = @ \cup
            {<<LegacyReady,
               state.legacyStatus = "absent" \/
                   /\ state.legacyRecovered
                   /\ state.checkpointGeneration > 0>>},
        !.recoveredWork = @ \cup {FileState2}
                ]

StartRetainedRecovery ==
    /\ state.phase = "mandatory"
    /\ LegacyReady
    /\ ActiveReady
    /\ state.retainedStatus = "complete"
    /\ ~state.retainedCoverageMatches
    /\ ~state.retainedRecovered
    /\ state' = [state EXCEPT !.phase = "recoverRetained"]

RecoverRetainedJournal ==
    /\ state.phase = "recoverRetained"
    /\ LegacyReady
    /\ ActiveReady
    /\ state' = [state EXCEPT
        !.phase = "mandatory",
        !.retainedRecovered = TRUE,
        !.retainedRecoveryWitnesses = @ \cup
            {<<LegacyReady, ActiveReady>>},
        !.checkpointGeneration = @ + 1,
        !.recoveredWork = @ \cup {FileState2}
                ]

RejectInvalidMandatoryInput ==
    /\ state.phase = "mandatory"
    /\ \/ state.legacyStatus \in {"invalid", "unavailable"}
       \/ state.activeStatus \in {"invalid", "unavailable"}
       \/ state.retainedStatus \in {"invalid", "unavailable"}
    /\ state' = [state EXCEPT !.phase = "recoveryChoices"]

FinishCheckpointLoad ==
    /\ state.phase = "mandatory"
    /\ state.bytesStatus = "complete"
    /\ LegacyReady
    /\ ActiveReady
    /\ RetainedReady
    /\ state' = [state EXCEPT
        !.phase = "loaded",
        !.checkpointLoaded = TRUE,
        !.checkpointVerified = TRUE,
        !.liveStorePublished = TRUE,
        !.liveStore = {FileState1} \cup state.recoveredWork,
        !.offlineStatusVisible = state.offlineRequested,
        !.loadWitnesses = @ \cup
            {<<state.bytesStatus = "complete", LegacyReady, ActiveReady,
               RetainedReady,
               ~state.offlineRequested \/ MandatoryInputsUsable>>}
                ]

ChooseWorkOffline ==
    /\ state.phase = "recoveryChoices"
    /\ CheckpointAcceptableForOffline
    /\ MandatoryInputsUsable
    /\ state' = [state EXCEPT
        !.phase = "mandatory",
        !.offlineRequested = TRUE,
        !.offlineStatusVisible = TRUE,
        !.syncControllerWillRetry = state.syncPaused \/
            state.syncControllerWillRetry
                ]

BeginRebuild ==
    /\ state.phase = "recoveryChoices"
    /\ state.checkpointStatus \in {"absent", "corrupt", "invalid"}
    /\ (state.checkpointStatus = "absent" => state.parentStatus = "current")
    /\ state.knownFileVersions # {}
    /\ \E scope \in {"exact", "currentVisible"}:
        /\ scope = IF state.rebuildStableUnsupported
                    THEN "currentVisible" ELSE "exact"
        /\ \E complete \in BOOLEAN:
            /\ scope = "currentVisible" => ~complete
            /\ state' = [state EXCEPT
                !.phase = "rebuildGather",
                !.rebuildScope = scope,
                !.rebuildEnumerationComplete = complete,
                !.rebuildSnapshot = state.knownFileVersions,
                !.rebuildSnapshotCatalogToken = state.catalogToken,
                !.rebuildRead = {},
                !.rebuildUnreadable = {},
                !.rebuildCandidate = {},
                !.rebuildSecondSnapshot = {},
                !.stagedRebuild = {},
                !.rebuildExpectedAbsence = state.checkpointStatus = "absent",
                !.rebuildExpectedCheckpointIncarnation =
                    IF state.checkpointStatus = "absent"
                    THEN None
                    ELSE state.checkpointArtifactIncarnation
                    ]

ReadRebuildVersion ==
    /\ state.phase = "rebuildGather"
    /\ \E version \in
            state.rebuildSnapshot \
                (state.rebuildRead \cup state.rebuildUnreadable):
        state' = [state EXCEPT
            !.rebuildRead = @ \cup {version},
            !.rebuildCandidate = @ \cup {FileState(version)}
                ]

MarkRebuildVersionUnreadable ==
    /\ state.phase = "rebuildGather"
    /\ \E version \in
            state.rebuildSnapshot \
                (state.rebuildRead \cup state.rebuildUnreadable):
        state' = [state EXCEPT
            !.rebuildUnreadable = @ \cup {version}
                ]

TakeRebuildFence ==
    /\ state.phase = "rebuildGather"
    /\ state.rebuildRead \cup state.rebuildUnreadable = state.rebuildSnapshot
    /\ state' = [state EXCEPT
        !.phase = "rebuildFenced",
        !.rebuildSecondSnapshot = state.knownFileVersions,
        !.rebuildSecondCatalogToken = state.catalogToken
                ]

DeliverFileVersion ==
    /\ state.phase \notin {"quit", "chooseRoot", "crashed"}
    /\ state.catalogToken < MaxCatalogToken
    /\ \E version \in FileVersions \ state.knownFileVersions:
        state' = [state EXCEPT
            !.knownFileVersions = @ \cup {version},
            !.catalogToken = @ + 1,
            !.lateExternalEvidence =
                IF state.newCollectionInitialized
                THEN @ \cup {version} ELSE @
                ]

AppearCheckpointDuringAbsentRebuild ==
    /\ state.phase \in {"rebuildGather", "rebuildFenced", "rebuildPrepared"}
    /\ state.rebuildExpectedAbsence
    /\ state.checkpointStatus = "absent"
    /\ state' = [state EXCEPT
        !.checkpointStatus = "current",
        !.bytesStatus = "complete"
                ]

ReplaceUnacceptableCheckpointDuringRebuild ==
    /\ state.phase \in {"rebuildGather", "rebuildFenced", "rebuildPrepared"}
    /\ ~state.rebuildExpectedAbsence
    /\ state.checkpointStatus \in {"corrupt", "invalid"}
    /\ ~state.checkpointArtifactReplacementOccurred
    /\ state' = [state EXCEPT
        !.checkpointArtifactIncarnation = ~@,
        !.checkpointArtifactReplacementOccurred = TRUE
                ]

RejectChangedRebuildPredecessor ==
    /\ state.phase \in {"rebuildGather", "rebuildFenced", "rebuildPrepared"}
    /\ ~RebuildExpectedCheckpointMatches
    /\ state' = [state EXCEPT !.phase = "checkingCheckpoint"]

RetryRebuild ==
    /\ state.phase \in {"rebuildFenced", "rebuildPrepared",
                         "rebuildInstalled"}
    /\ \/ ~RebuildScopeQualified
       \/ state.rebuildUnreadable # {}
       \/ ~RebuildSnapshotStable
    /\ \E complete \in BOOLEAN:
        /\ state.rebuildScope = "currentVisible" => ~complete
        /\ state' = [state EXCEPT
                !.phase = "rebuildGather",
                !.rebuildEnumerationComplete = complete,
                !.rebuildSnapshot = state.knownFileVersions,
                !.rebuildSnapshotCatalogToken = state.catalogToken,
                !.rebuildRead = {},
                !.rebuildUnreadable = {},
                !.rebuildCandidate = {},
                !.rebuildSecondSnapshot = {},
                !.stagedRebuild = {}
                    ]

PrepareStableRebuild ==
    /\ state.phase = "rebuildFenced"
    /\ RebuildScopeQualified
    /\ state.rebuildUnreadable = {}
    /\ state.rebuildRead = state.rebuildSnapshot
    /\ RebuildSnapshotStable
    /\ state.rebuildCandidate =
        {FileState(version): version \in state.rebuildSnapshot}
    /\ state' = [state EXCEPT !.phase = "rebuildPrepared"]

InstallRebuildCheckpoint ==
    /\ state.phase = "rebuildPrepared"
    /\ RebuildSnapshotStable
    /\ RebuildExpectedCheckpointMatches
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = [state EXCEPT
            !.phase = "rebuildInstalled",
            !.installedCheckpoint = checkpoint,
            !.usedCheckpointIDs = @ \cup {checkpoint},
            !.checkpointInstallCount[checkpoint] = @ + 1,
            !.stagedRebuild = state.rebuildCandidate,
            !.rebuildInstallWitnesses = @ \cup
                {<<state.rebuildExpectedAbsence,
                   RebuildExpectedCheckpointStatusMatches,
                   RebuildExpectedCheckpointIdentityMatches>>}
                ]

VerifyAndPublishRebuild ==
    /\ state.phase = "rebuildInstalled"
    /\ RebuildSnapshotStable
    /\ state.stagedRebuild = state.rebuildCandidate
    /\ state.installedCheckpoint # InitialCheckpoint
    /\ state' = [state EXCEPT
        !.phase = "loaded",
        !.bytesStatus = "complete",
        !.checkpointLoaded = TRUE,
        !.checkpointVerified = TRUE,
        !.liveStorePublished = TRUE,
        !.liveStore = state.stagedRebuild,
        !.rebuildPublished = TRUE,
        !.rebuildLimitedHistoryVisible =
            state.rebuildScope = "currentVisible",
        !.rebuildWitnesses = @ \cup
            {<<RebuildScopeQualified,
               state.rebuildUnreadable = {},
               state.rebuildRead = state.rebuildSnapshot,
               RebuildSnapshotStable,
               state.stagedRebuild = state.rebuildCandidate>>}
                ]

CancelRebuild ==
    /\ state.phase \in {"rebuildGather", "rebuildFenced",
                         "rebuildPrepared", "rebuildInstalled"}
    /\ ~state.liveStorePublished
    /\ state' = [state EXCEPT !.phase = "recoveryChoices"]

CreateFreshJournal ==
    /\ state.phase = "loaded"
    /\ state.checkpointLoaded
    /\ state.checkpointVerified
    /\ state' = [state EXCEPT !.phase = "journalCreating"]

SynchronizeFreshJournalHeader ==
    /\ state.phase = "journalCreating"
    /\ state' = [state EXCEPT
        !.phase = "journalHeader",
        !.freshJournalHeaderSynced = TRUE
                ]

PublishFreshJournalClaim ==
    /\ state.phase = "journalHeader"
    /\ state.freshJournalHeaderSynced
    /\ state' = [state EXCEPT
        !.phase = "journalClaimWritten",
        !.freshJournalClaimWritten = TRUE
                ]

SynchronizeFreshJournalClaim ==
    /\ state.phase = "journalClaimWritten"
    /\ state.freshJournalClaimWritten
    /\ state' = [state EXCEPT
        !.phase = "journalReady",
        !.freshJournalClaimSynced = TRUE
                ]

EnableEditing ==
    /\ state.phase = "journalReady"
    /\ state.liveStorePublished
    /\ state.checkpointVerified
    /\ state.freshJournalHeaderSynced
    /\ state.freshJournalClaimSynced
    /\ state' = [state EXCEPT
        !.phase = "editable",
        !.editable = TRUE
                ]

QuitStartup ==
    /\ state.phase = "recoveryChoices"
    /\ state' = [state EXCEPT !.phase = "quit"]

ChooseAnotherRoot ==
    /\ state.phase = "recoveryChoices"
    /\ state' = [state EXCEPT !.phase = "chooseRoot"]

Crash ==
    /\ state.phase \notin {"quit", "chooseRoot", "crashed"}
    /\ state' = [state EXCEPT
        !.phase = "crashed",
        !.editable = FALSE
                ]

Next ==
    \/ ResumePausedCheckpoint
    \/ UseCurrentCheckpoint
    \/ RequestCheckpointMaterialization
    \/ ClassifyCheckpointAbsence
    \/ FailClosedCheckpointClassification
    \/ MaterializeCheckpoint
    \/ InitializeOwnedRoot
    \/ RequireExplicitCreation
    \/ ConfirmExplicitCreation
    \/ StartLegacyRecovery
    \/ RecoverLegacyJournal
    \/ StartActiveRecovery
    \/ RecoverActiveJournal
    \/ StartRetainedRecovery
    \/ RecoverRetainedJournal
    \/ RejectInvalidMandatoryInput
    \/ FinishCheckpointLoad
    \/ ChooseWorkOffline
    \/ BeginRebuild
    \/ ReadRebuildVersion
    \/ MarkRebuildVersionUnreadable
    \/ TakeRebuildFence
    \/ DeliverFileVersion
    \/ AppearCheckpointDuringAbsentRebuild
    \/ ReplaceUnacceptableCheckpointDuringRebuild
    \/ RejectChangedRebuildPredecessor
    \/ RetryRebuild
    \/ PrepareStableRebuild
    \/ InstallRebuildCheckpoint
    \/ VerifyAndPublishRebuild
    \/ CancelRebuild
    \/ CreateFreshJournal
    \/ SynchronizeFreshJournalHeader
    \/ PublishFreshJournalClaim
    \/ SynchronizeFreshJournalClaim
    \/ EnableEditing
    \/ QuitStartup
    \/ ChooseAnotherRoot
    \/ Crash

StartupInternalProgress ==
    StartLegacyRecovery \/ RecoverLegacyJournal \/ StartActiveRecovery
        \/ RecoverActiveJournal \/ StartRetainedRecovery
        \/ RecoverRetainedJournal \/ RejectInvalidMandatoryInput
        \/ FinishCheckpointLoad

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(ResumePausedCheckpoint)
    /\ WF_vars(StartupInternalProgress)
    /\ WF_vars(ReadRebuildVersion)
    /\ WF_vars(TakeRebuildFence)
    /\ WF_vars(RejectChangedRebuildPredecessor)
    /\ WF_vars(CreateFreshJournal)
    /\ WF_vars(SynchronizeFreshJournalHeader)
    /\ WF_vars(PublishFreshJournalClaim)
    /\ WF_vars(SynchronizeFreshJournalClaim)
    /\ WF_vars(EnableEditing)

TypeOK ==
    /\ state.scenario \in Scenarios
    /\ state.phase \in Phases
    /\ state.checkpointStatus \in CheckpointStatuses
    /\ state.parentStatus \in ParentStatuses
    /\ state.bytesStatus \in ByteStatuses
    /\ state.rootCreatedThisOperation \in BOOLEAN
    /\ state.initiallyPaused \in BOOLEAN
    /\ state.syncPaused \in BOOLEAN
    /\ state.resumeAttempted \in BOOLEAN
    /\ state.resumeSucceeded \in BOOLEAN
    /\ state.syncControllerWillRetry \in BOOLEAN
    /\ state.freshnessEvaluated \in BOOLEAN
    /\ state.legacyStatus \in JournalStatuses
    /\ state.activeStatus \in JournalStatuses
    /\ state.retainedStatus \in JournalStatuses
    /\ state.retainedCoverageMatches \in BOOLEAN
    /\ state.legacyRecovered \in BOOLEAN
    /\ state.activeRecovered \in BOOLEAN
    /\ state.retainedRecovered \in BOOLEAN
    /\ state.checkpointGeneration \in Nat
    /\ state.checkpointArtifactIncarnation \in BOOLEAN
    /\ state.checkpointArtifactReplacementOccurred \in BOOLEAN
    /\ state.activeRecoveryWitnesses \subseteq (BOOLEAN \X BOOLEAN)
    /\ state.retainedRecoveryWitnesses \subseteq (BOOLEAN \X BOOLEAN)
    /\ state.recoveredWork \subseteq FileStates
    /\ state.offlineRequested \in BOOLEAN
    /\ state.offlineStatusVisible \in BOOLEAN
    /\ state.checkpointLoaded \in BOOLEAN
    /\ state.checkpointVerified \in BOOLEAN
    /\ state.liveStorePublished \in BOOLEAN
    /\ state.liveStore \subseteq FileStates
    /\ state.editable \in BOOLEAN
    /\ state.explicitCreateConfirmed \in BOOLEAN
    /\ state.newCollectionInitialized \in BOOLEAN
    /\ state.newCollectionCheckpointInstalled \in BOOLEAN
    /\ state.initializationWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.loadWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.recoveryEvidencePresent \in BOOLEAN
    /\ state.recoveryEvidencePreserved \in BOOLEAN
    /\ state.unclaimedJournalEvidencePresent \in BOOLEAN
    /\ state.knownFileVersions \subseteq FileVersions
    /\ state.catalogToken \in 0..MaxCatalogToken
    /\ state.rebuildStableUnsupported \in BOOLEAN
    /\ state.rebuildScope \in RebuildScopes
    /\ state.rebuildEnumerationComplete \in BOOLEAN
    /\ state.rebuildSnapshot \subseteq FileVersions
    /\ state.rebuildSnapshotCatalogToken \in 0..MaxCatalogToken
    /\ state.rebuildRead \subseteq FileVersions
    /\ state.rebuildUnreadable \subseteq FileVersions
    /\ state.rebuildCandidate \subseteq FileStates
    /\ state.rebuildSecondSnapshot \subseteq FileVersions
    /\ state.rebuildSecondCatalogToken \in 0..MaxCatalogToken
    /\ state.stagedRebuild \subseteq FileStates
    /\ state.rebuildExpectedAbsence \in BOOLEAN
    /\ state.rebuildExpectedCheckpointIncarnation \in BOOLEAN \cup {None}
    /\ state.rebuildInstallWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.installedCheckpoint \in CheckpointIDs
    /\ state.usedCheckpointIDs \subseteq CheckpointIDs
    /\ state.checkpointInstallCount \in [CheckpointIDs -> 0..1]
    /\ state.rebuildPublished \in BOOLEAN
    /\ state.rebuildLimitedHistoryVisible \in BOOLEAN
    /\ state.rebuildWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.freshJournalHeaderSynced \in BOOLEAN
    /\ state.freshJournalClaimWritten \in BOOLEAN
    /\ state.freshJournalClaimSynced \in BOOLEAN
    /\ state.lateExternalEvidence \subseteq FileVersions

PausedCheckpointPrecedesFreshnessEvaluation ==
    /\ state.initiallyPaused
    /\ state.freshnessEvaluated
    => /\ state.resumeAttempted
       /\ state.resumeSucceeded
       /\ ~state.syncPaused

InitializationRequiresAuthoritativeAbsenceAndConsent ==
    \A witness \in state.initializationWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]

NewCollectionCheckpointPrecedesEditing ==
    state.newCollectionInitialized =>
        /\ state.newCollectionCheckpointInstalled
        /\ state.installedCheckpoint # InitialCheckpoint
        /\ state.checkpointLoaded
        /\ state.checkpointVerified

MandatoryRecoveryPrecedesPublication ==
    \A witness \in state.loadWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]

LegacyRecoveryPrecedesActiveRecovery ==
    \A witness \in state.activeRecoveryWitnesses:
        /\ witness[1]
        /\ witness[2]

LegacyAndActiveRecoveryPrecedeRetainedRecovery ==
    \A witness \in state.retainedRecoveryWitnesses:
        /\ witness[1]
        /\ witness[2]

OfflineEditingRequiresEveryMandatoryInput ==
    /\ state.editable
    /\ state.offlineRequested
    => /\ state.bytesStatus = "complete"
       /\ LegacyReady
       /\ ActiveReady
       /\ RetainedReady
       /\ state.offlineStatusVisible

EditingRequiresVerifiedStoreAndFreshJournal ==
    state.editable =>
        /\ state.liveStorePublished
        /\ state.checkpointLoaded
        /\ state.checkpointVerified
        /\ state.freshJournalHeaderSynced
        /\ state.freshJournalClaimWritten
        /\ state.freshJournalClaimSynced
        /\ (state.newCollectionInitialized =>
               state.newCollectionCheckpointInstalled)

StableCompleteRebuildIsTheOnlyRebuildPublication ==
    /\ state.rebuildPublished => state.rebuildWitnesses # {}
    /\ \A witness \in state.rebuildWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]

RebuildImportsEverySnapshottedReadableState ==
    state.rebuildPublished =>
        {FileState(version): version \in state.rebuildSnapshot}
            \subseteq state.liveStore

NoPartialRebuildStoreIsPublished ==
    /\ state.scenario \in {"corruptRebuild", "invalidRebuildFallback"}
    /\ ~state.rebuildPublished
    => ~state.liveStorePublished

ExactRebuildRequiresCompleteEnumeration ==
    /\ state.rebuildPublished
    /\ state.rebuildScope = "exact"
    => state.rebuildEnumerationComplete

CurrentVisibleRebuildRequiresStableUnsupportedAndStatus ==
    /\ state.rebuildPublished
    /\ state.rebuildScope = "currentVisible"
    => /\ state.rebuildStableUnsupported
       /\ state.rebuildLimitedHistoryVisible

EveryRebuildInstallMatchedExpectedCheckpoint ==
    \A witness \in state.rebuildInstallWitnesses:
        /\ witness[2]
        /\ witness[3]

AbsentCheckpointRebuildUsedExpectedAbsence ==
    /\ state.scenario = "absentRebuild"
    /\ state.rebuildPublished
    => \E witness \in state.rebuildInstallWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]

RecoveryEvidenceIsNeverConsumedByStartup ==
    /\ state.recoveryEvidencePresent
    /\ state.unclaimedJournalEvidencePresent
    /\ state.recoveryEvidencePreserved

LateArrivalsAfterCreationRemainExternalEvidence ==
    /\ state.lateExternalEvidence \subseteq state.knownFileVersions
    /\ state.newCollectionInitialized =>
        state.knownFileVersions \subseteq state.lateExternalEvidence

CheckpointIDsAreNeverReused ==
    \A checkpoint \in CheckpointIDs:
        state.checkpointInstallCount[checkpoint] <= 1

PausedStartupProgress ==
    state.phase = "checkingPause"
    ~> state.phase \in {"checkingCheckpoint", "recoveryChoices", "crashed"}

FreshJournalProgress ==
    state.phase = "journalCreating"
    ~> state.phase \in {"editable", "crashed"}

RebuildGatherProgress ==
    state.phase = "rebuildGather"
    ~> state.phase \in
        {"rebuildFenced", "checkingCheckpoint", "recoveryChoices", "crashed"}

=============================================================================
