--------------------------- MODULE StartupSafety ---------------------------
EXTENDS FiniteSets, Naturals

\* FileVersions are immutable persistent version identifiers. catalogToken
\* values are opaque; Naturals and +1 only provide bounded fresh values.

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

VARIABLE state

vars == <<state>>

CheckpointStatuses == {
    "current", "stale", "unmaterialized", "absent", "unavailable",
    "corrupt"
}
ParentStatuses == {"current", "stale", "unavailable"}
ByteStatuses == {"complete", "unavailable", "corrupt"}
JournalStatuses == {"absent", "complete", "invalid", "unavailable"}
Phases == {
    "checkingPause", "checkingCheckpoint", "materializing",
    "absentDecision", "recoveryChoices", "mandatory", "recoverLegacy",
    "recoverActive", "loaded", "journalCreating", "journalHeader",
    "journalClaimWritten", "journalReady", "editable", "rebuildGather",
    "rebuildFenced", "rebuildPrepared", "rebuildInstalled", "quit",
    "chooseRoot", "crashed"
}
Scenarios == {
    "currentClean", "currentLegacy", "currentBoth", "stale",
    "unmaterialized", "absentOwned", "absentExisting",
    "unavailableENOENT", "corruptRebuild", "offlineComplete",
    "offlineInvalidJournal", "pausedCurrent", "pausedFailure",
    "currentInvalidMandatory"
}

InitialStatus(scenario) ==
    CASE scenario \in {"currentClean", "currentLegacy", "currentBoth",
            "pausedCurrent", "pausedFailure", "currentInvalidMandatory"}
            -> "current"
      [] scenario \in {"stale", "offlineComplete",
                        "offlineInvalidJournal"} -> "stale"
      [] scenario = "unmaterialized" -> "unmaterialized"
      [] scenario \in {"absentOwned", "absentExisting"} -> "absent"
      [] scenario = "corruptRebuild" -> "corrupt"
      [] OTHER -> "unavailable"

InitialParentStatus(scenario) ==
    IF scenario = "unavailableENOENT" THEN "unavailable" ELSE "current"

InitialBytes(scenario) ==
    CASE scenario \in {"unmaterialized", "absentOwned", "absentExisting",
                        "unavailableENOENT"} -> "unavailable"
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

InitiallyPaused(scenario) ==
    scenario \in {"pausedCurrent", "pausedFailure"}

InitialKnownFiles(scenario) ==
    IF scenario = "corruptRebuild" THEN {FileVersion1} ELSE {}

FileState(version) ==
    IF version = FileVersion1 THEN FileState1 ELSE FileState2

LegacyReady ==
    \/ state.legacyStatus = "absent"
    \/ state.legacyRecovered

ActiveReady ==
    \/ state.activeStatus = "absent"
    \/ state.activeRecovered

MandatoryInputsUsable ==
    /\ state.legacyStatus \in {"absent", "complete"}
    /\ state.activeStatus \in {"absent", "complete"}

RebuildSnapshotStable ==
    /\ state.rebuildSnapshot = state.rebuildSecondSnapshot
    /\ state.rebuildSnapshotCatalogToken = state.catalogToken
    /\ state.rebuildSecondCatalogToken = state.catalogToken

InitializeEmpty(explicit) ==
    [state EXCEPT
        !.phase = "loaded",
        !.explicitCreateConfirmed = explicit,
        !.newCollectionInitialized = TRUE,
        !.checkpointLoaded = TRUE,
        !.checkpointVerified = TRUE,
        !.liveStorePublished = TRUE,
        !.liveStore = {},
        !.lateExternalEvidence = @ \cup state.knownFileVersions,
        !.initializationWitnesses = @ \cup
            {<<state.checkpointStatus = "absent",
               state.parentStatus = "current",
               state.rootCreatedThisOperation \/ explicit,
               state.checkpointStatus # "unavailable">>}
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
            legacyRecovered |-> FALSE,
            activeRecovered |-> FALSE,
            checkpointGeneration |-> 0,
            activeRecoveryWitnesses |-> {},
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
            initializationWitnesses |-> {},
            loadWitnesses |-> {},
            recoveryEvidencePresent |-> TRUE,
            recoveryEvidencePreserved |-> TRUE,
            unclaimedJournalEvidencePresent |-> TRUE,
            knownFileVersions |-> knownFiles,
            catalogToken |-> 0,
            rebuildEnumerationComplete |-> FALSE,
            rebuildSnapshot |-> {},
            rebuildSnapshotCatalogToken |-> 0,
            rebuildRead |-> {},
            rebuildUnreadable |-> {},
            rebuildCandidate |-> {},
            rebuildSecondSnapshot |-> {},
            rebuildSecondCatalogToken |-> 0,
            stagedRebuild |-> {},
            installedCheckpoint |-> InitialCheckpoint,
            usedCheckpointIDs |-> {InitialCheckpoint},
            checkpointInstallCount |-> [checkpoint \in CheckpointIDs |->
                IF checkpoint = InitialCheckpoint THEN 1 ELSE 0],
            rebuildPublished |-> FALSE,
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
    /\ \/ state.checkpointStatus \in {"unavailable", "corrupt"}
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
    /\ state' = InitializeEmpty(FALSE)

RequireExplicitCreation ==
    /\ state.phase = "absentDecision"
    /\ ~state.rootCreatedThisOperation
    /\ state' = [state EXCEPT !.phase = "recoveryChoices"]

ConfirmExplicitCreation ==
    /\ state.phase = "recoveryChoices"
    /\ state.checkpointStatus = "absent"
    /\ state.parentStatus = "current"
    /\ ~state.rootCreatedThisOperation
    /\ state' = InitializeEmpty(TRUE)

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

RejectInvalidMandatoryInput ==
    /\ state.phase = "mandatory"
    /\ \/ state.legacyStatus \in {"invalid", "unavailable"}
       \/ state.activeStatus \in {"invalid", "unavailable"}
    /\ state' = [state EXCEPT !.phase = "recoveryChoices"]

FinishCheckpointLoad ==
    /\ state.phase = "mandatory"
    /\ state.bytesStatus = "complete"
    /\ LegacyReady
    /\ ActiveReady
    /\ state' = [state EXCEPT
        !.phase = "loaded",
        !.checkpointLoaded = TRUE,
        !.checkpointVerified = TRUE,
        !.liveStorePublished = TRUE,
        !.liveStore = {FileState1} \cup state.recoveredWork,
        !.offlineStatusVisible = state.offlineRequested,
        !.loadWitnesses = @ \cup
            {<<state.bytesStatus = "complete", LegacyReady, ActiveReady,
               ~state.offlineRequested \/ MandatoryInputsUsable>>}
                ]

ChooseWorkOffline ==
    /\ state.phase = "recoveryChoices"
    /\ state.bytesStatus = "complete"
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
    /\ state.checkpointStatus = "corrupt"
    /\ state.knownFileVersions # {}
    /\ \E complete \in BOOLEAN:
        state' = [state EXCEPT
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

RetryRebuild ==
    /\ state.phase \in {"rebuildFenced", "rebuildPrepared",
                         "rebuildInstalled"}
    /\ \/ ~state.rebuildEnumerationComplete
       \/ state.rebuildUnreadable # {}
       \/ ~RebuildSnapshotStable
    /\ \E complete \in BOOLEAN:
        state' = [state EXCEPT
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
    /\ state.rebuildEnumerationComplete
    /\ state.rebuildUnreadable = {}
    /\ state.rebuildRead = state.rebuildSnapshot
    /\ RebuildSnapshotStable
    /\ state.rebuildCandidate =
        {FileState(version): version \in state.rebuildSnapshot}
    /\ state' = [state EXCEPT !.phase = "rebuildPrepared"]

InstallRebuildCheckpoint ==
    /\ state.phase = "rebuildPrepared"
    /\ RebuildSnapshotStable
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = [state EXCEPT
            !.phase = "rebuildInstalled",
            !.installedCheckpoint = checkpoint,
            !.usedCheckpointIDs = @ \cup {checkpoint},
            !.checkpointInstallCount[checkpoint] = @ + 1,
            !.stagedRebuild = state.rebuildCandidate
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
        !.rebuildWitnesses = @ \cup
            {<<state.rebuildEnumerationComplete,
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
    \/ RejectInvalidMandatoryInput
    \/ FinishCheckpointLoad
    \/ ChooseWorkOffline
    \/ BeginRebuild
    \/ ReadRebuildVersion
    \/ MarkRebuildVersionUnreadable
    \/ TakeRebuildFence
    \/ DeliverFileVersion
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
        \/ RecoverActiveJournal \/ RejectInvalidMandatoryInput
        \/ FinishCheckpointLoad

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(ResumePausedCheckpoint)
    /\ WF_vars(StartupInternalProgress)
    /\ WF_vars(ReadRebuildVersion)
    /\ WF_vars(TakeRebuildFence)
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
    /\ state.legacyRecovered \in BOOLEAN
    /\ state.activeRecovered \in BOOLEAN
    /\ state.checkpointGeneration \in Nat
    /\ state.activeRecoveryWitnesses \subseteq (BOOLEAN \X BOOLEAN)
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
    /\ state.initializationWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.loadWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.recoveryEvidencePresent \in BOOLEAN
    /\ state.recoveryEvidencePreserved \in BOOLEAN
    /\ state.unclaimedJournalEvidencePresent \in BOOLEAN
    /\ state.knownFileVersions \subseteq FileVersions
    /\ state.catalogToken \in 0..MaxCatalogToken
    /\ state.rebuildEnumerationComplete \in BOOLEAN
    /\ state.rebuildSnapshot \subseteq FileVersions
    /\ state.rebuildSnapshotCatalogToken \in 0..MaxCatalogToken
    /\ state.rebuildRead \subseteq FileVersions
    /\ state.rebuildUnreadable \subseteq FileVersions
    /\ state.rebuildCandidate \subseteq FileStates
    /\ state.rebuildSecondSnapshot \subseteq FileVersions
    /\ state.rebuildSecondCatalogToken \in 0..MaxCatalogToken
    /\ state.stagedRebuild \subseteq FileStates
    /\ state.installedCheckpoint \in CheckpointIDs
    /\ state.usedCheckpointIDs \subseteq CheckpointIDs
    /\ state.checkpointInstallCount \in [CheckpointIDs -> 0..1]
    /\ state.rebuildPublished \in BOOLEAN
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

MandatoryRecoveryPrecedesPublication ==
    \A witness \in state.loadWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]

LegacyRecoveryPrecedesActiveRecovery ==
    \A witness \in state.activeRecoveryWitnesses:
        /\ witness[1]
        /\ witness[2]

OfflineEditingRequiresEveryMandatoryInput ==
    /\ state.editable
    /\ state.offlineRequested
    => /\ state.bytesStatus = "complete"
       /\ LegacyReady
       /\ ActiveReady
       /\ state.offlineStatusVisible

EditingRequiresVerifiedStoreAndFreshJournal ==
    state.editable =>
        /\ state.liveStorePublished
        /\ state.checkpointLoaded
        /\ state.checkpointVerified
        /\ state.freshJournalHeaderSynced
        /\ state.freshJournalClaimWritten
        /\ state.freshJournalClaimSynced

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
    /\ state.scenario = "corruptRebuild"
    /\ ~state.rebuildPublished
    => ~state.liveStorePublished

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
    ~> state.phase \in {"rebuildFenced", "recoveryChoices", "crashed"}

=============================================================================
