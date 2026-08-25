----------------------------- MODULE QuitSafety -----------------------------
EXTENDS FiniteSets, Naturals

\* Admitted model mutations are operation IDs. A delete is an operation too.
\* LocalPersistentVersionIdentifiers are persistent version identifiers for
\* the installed checkpoint's local NSFileVersion snapshots.
CONSTANTS
    Edits,
    CheckpointIDs,
    LocalPersistentVersionIdentifiers,
    UploadRequestIDs,
    InitialCheckpoint,
    InitialLocalVersion,
    None

ASSUME
    /\ IsFiniteSet(Edits)
    /\ IsFiniteSet(CheckpointIDs)
    /\ IsFiniteSet(LocalPersistentVersionIdentifiers)
    /\ IsFiniteSet(UploadRequestIDs)
    /\ InitialCheckpoint \in CheckpointIDs
    /\ InitialLocalVersion \in LocalPersistentVersionIdentifiers
    /\ None \notin CheckpointIDs
    /\ None \notin LocalPersistentVersionIdentifiers
    /\ None \notin UploadRequestIDs

VARIABLE state

vars == <<state>>

Phases == {
    "running", "quiescing", "awaitingDecision", "barrier", "drained",
    "paused", "installed", "verified", "uploading", "resuming", "cleanup",
    "terminated", "aborted", "crashed"
}

RootKinds == {"local", "icloud", "otherProvider", "unknown"}
LegacyStatuses == {"idle", "pending", "uploaded", "complete"}
ConfirmationKinds == {"none", "explicit", "legacy"}

Init ==
    \E kind \in RootKinds:
    \E supported \in BOOLEAN:
    state = [
        phase |-> "running",
        rootKind |-> kind,
        controlsSupported |-> supported,
        live |-> {},
        pendingJournal |-> {},
        journal |-> {},
        durableHistory |-> {},
        fileCopies |-> {},
        frozen |-> {},
        stagedCheckpoint |-> {},
        durableCheckpoint |-> {},
        installedCheckpoint |-> InitialCheckpoint,
        usedCheckpointIDs |-> {InitialCheckpoint},
        checkpointInstallCount |-> [checkpoint \in CheckpointIDs |->
            IF checkpoint = InitialCheckpoint THEN 1 ELSE 0],
        verifiedCheckpoint |-> InitialCheckpoint,
        installedLocalVersion |-> InitialLocalVersion,
        verifiedLocalVersion |-> InitialLocalVersion,
        uploadRequest |-> None,
        requestCheckpoint |-> None,
        requestLocalVersion |-> None,
        explicitUploadAttempted |-> FALSE,
        explicitUploadFailed |-> FALSE,
        returnedRequest |-> None,
        returnedCheckpoint |-> None,
        returnedLocalVersion |-> None,
        confirmedCheckpoint |-> None,
        confirmationKind |-> "none",
        readbackCheckpoint |-> None,
        readbackLocalVersion |-> None,
        checkpointVerified |-> TRUE,
        syncPaused |-> FALSE,
        pauseAttempted |-> FALSE,
        pauseFailedBeforeAcquisition |-> FALSE,
        pauseEverSucceeded |-> FALSE,
        resumeAttempted |-> FALSE,
        resumeFailed |-> FALSE,
        postResumePhase |-> "verified",
        legacyStatus |-> "idle",
        legacyCheckpoint |-> None,
        legacyLocalVersion |-> None,
        legacyGeneration |-> 0,
        localWriteGeneration |-> 0,
        journalExists |-> TRUE,
        activeRecord |-> TRUE,
        journalDeletionQualified |-> FALSE,
        journalDeletionCheckpoint |-> None,
        installCount |-> 0,
        terminationRequests |-> 0,
        queuedCallbacks |-> {},
        discardedCallbacks |-> {},
        dirty |-> FALSE,
        sessionClosing |-> FALSE,
        presenterDrained |-> FALSE
        ]

UserEdit ==
    /\ state.phase = "running"
    /\ \E edit \in Edits \ (state.live \cup state.queuedCallbacks):
        state' = [state EXCEPT
            !.live = @ \cup {edit},
            !.pendingJournal = @ \cup {edit}
        ]

QueueProviderCallback ==
    /\ state.phase \in {"running", "quiescing"}
    /\ ~state.sessionClosing
    /\ \E edit \in Edits \ (state.live \cup state.queuedCallbacks):
        state' = [state EXCEPT
            !.queuedCallbacks = @ \cup {edit},
            !.dirty = TRUE
        ]

FinishProviderCallback ==
    /\ state.phase \in {"running", "quiescing"}
    /\ ~state.sessionClosing
    /\ \E edit \in state.queuedCallbacks:
        state' = [state EXCEPT
            !.queuedCallbacks = @ \ {edit},
            !.live = @ \cup {edit},
            !.pendingJournal = @ \cup {edit},
            !.dirty = TRUE
        ]

ProviderNotification ==
    /\ state.phase \in {"running", "quiescing"}
    /\ ~state.sessionClosing
    /\ ~state.dirty
    /\ state' = [state EXCEPT !.dirty = TRUE]

SynchronizeJournal ==
    /\ state.phase \in {"running", "quiescing"}
    /\ state.pendingJournal # {}
    /\ state.journalExists
    /\ state' = [state EXCEPT
        !.journal = @ \cup state.pendingJournal,
        !.durableHistory = @ \cup state.pendingJournal,
        !.pendingJournal = {}
        ]

SettleSeparateFiles ==
    /\ state.phase \in {"running", "quiescing"}
    /\ state.fileCopies # state.live
    /\ state' = [state EXCEPT !.fileCopies = state.live]

FinishReconciliation ==
    /\ state.phase \in {"running", "quiescing"}
    /\ state.queuedCallbacks = {}
    /\ state.dirty
    /\ state' = [state EXCEPT !.dirty = FALSE]

BeginQuit ==
    /\ state.phase = "running"
    /\ state' = [state EXCEPT
        !.phase = "quiescing",
        !.terminationRequests = 1
        ]

PreinstallFailure ==
    /\ state.phase = "quiescing"
    /\ state' = [state EXCEPT !.phase = "awaitingDecision"]

RetryPreinstallWork ==
    /\ state.phase = "awaitingDecision"
    /\ state' = [state EXCEPT !.phase = "quiescing"]

QuitAnywayBeforeInstall ==
    /\ state.phase = "awaitingDecision"
    /\ state.installCount = 0
    /\ state' = [state EXCEPT !.phase = "aborted"]

ReachProviderBarrier ==
    /\ state.phase = "quiescing"
    /\ state.queuedCallbacks = {}
    /\ ~state.dirty
    /\ state.pendingJournal = {}
    /\ state.durableHistory = state.live
    /\ state.fileCopies = state.live
    /\ state' = [state EXCEPT
        !.phase = "barrier",
        !.frozen = state.live,
        !.sessionClosing = TRUE
        ]

LateCallbackAfterClose ==
    /\ state.sessionClosing
    /\ state.phase \notin {"terminated", "crashed"}
    /\ \E edit \in Edits \ state.discardedCallbacks:
        state' = [state EXCEPT !.discardedCallbacks = @ \cup {edit}]

DrainPresenter ==
    /\ state.phase = "barrier"
    /\ state.sessionClosing
    /\ state' = [state EXCEPT
        !.phase = "drained",
        !.presenterDrained = TRUE
        ]

PauseCheckpoint ==
    /\ state.phase = "drained"
    /\ state.rootKind = "icloud"
    /\ state.controlsSupported
    /\ ~state.syncPaused
    /\ state' = [state EXCEPT
        !.phase = "paused",
        !.syncPaused = TRUE,
        !.pauseAttempted = TRUE,
        !.pauseFailedBeforeAcquisition = FALSE,
        !.pauseEverSucceeded = TRUE,
        !.resumeAttempted = FALSE,
        !.resumeFailed = FALSE
        ]

PauseCheckpointFailedBeforeAcquisition ==
    /\ state.phase = "drained"
    /\ state.rootKind = "icloud"
    /\ state.controlsSupported
    /\ ~state.pauseAttempted
    /\ state' = [state EXCEPT
        !.pauseAttempted = TRUE,
        !.pauseFailedBeforeAcquisition = TRUE
        ]

InstallCheckpoint ==
    /\ \/ state.phase = "paused"
       \/ /\ state.phase = "drained"
          /\ \/ state.rootKind # "icloud"
             \/ ~state.controlsSupported
             \/ state.pauseFailedBeforeAcquisition
    /\ state.presenterDrained
    /\ state.installCount = 0
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
       \E localVersion \in LocalPersistentVersionIdentifiers \ {state.installedLocalVersion}:
        state' = [state EXCEPT
            !.phase = "installed",
            !.stagedCheckpoint = state.frozen,
            !.installedCheckpoint = checkpoint,
            !.usedCheckpointIDs = @ \cup {checkpoint},
            !.checkpointInstallCount[checkpoint] = @ + 1,
            !.installedLocalVersion = localVersion,
            !.checkpointVerified = FALSE,
            !.confirmedCheckpoint = None,
            !.confirmationKind = "none",
            !.installCount = @ + 1,
            !.localWriteGeneration = @ + 1
        ]

VerifyExactCheckpoint ==
    /\ state.phase = "installed"
    /\ state.stagedCheckpoint = state.frozen
    /\ state' = [state EXCEPT
        !.phase = "verified",
        !.durableCheckpoint = state.stagedCheckpoint,
        !.verifiedCheckpoint = state.installedCheckpoint,
        !.verifiedLocalVersion = state.installedLocalVersion,
        !.checkpointVerified = TRUE
        ]

CheckpointVerificationFailed ==
    /\ state.phase = "installed"
    /\ state' = [state EXCEPT
        !.phase = IF state.syncPaused THEN "resuming" ELSE "aborted",
        !.postResumePhase = "aborted",
        !.checkpointVerified = FALSE,
        !.confirmedCheckpoint = None,
        !.confirmationKind = "none"
        ]

StartExplicitUpload ==
    /\ state.phase = "verified"
    /\ state.rootKind = "icloud"
    /\ state.syncPaused
    /\ state.checkpointVerified
    /\ \E request \in UploadRequestIDs:
        state' = [state EXCEPT
            !.phase = "uploading",
            !.uploadRequest = request,
            !.requestCheckpoint = state.installedCheckpoint,
            !.requestLocalVersion = state.installedLocalVersion,
            !.explicitUploadAttempted = TRUE,
            !.explicitUploadFailed = FALSE,
            !.returnedRequest = None,
            !.returnedCheckpoint = None,
            !.returnedLocalVersion = None
        ]

ExplicitUploadCallback ==
    /\ state.phase = "uploading"
    /\ \E returnedRequest \in UploadRequestIDs \cup {None}:
       \E returnedCheckpoint \in CheckpointIDs \cup {None}:
       \E returnedLocalVersion \in LocalPersistentVersionIdentifiers \cup {None}:
        LET matches ==
            /\ returnedRequest = state.uploadRequest
            /\ returnedCheckpoint = state.requestCheckpoint
            /\ returnedCheckpoint = state.installedCheckpoint
            /\ returnedCheckpoint = state.verifiedCheckpoint
            /\ returnedLocalVersion = state.requestLocalVersion
            /\ returnedLocalVersion = state.installedLocalVersion
            /\ returnedLocalVersion = state.verifiedLocalVersion
            /\ state.checkpointVerified
        IN state' = [state EXCEPT
            !.phase = "resuming",
            !.postResumePhase = "verified",
            !.returnedRequest = returnedRequest,
            !.returnedCheckpoint = returnedCheckpoint,
            !.returnedLocalVersion = returnedLocalVersion,
            !.explicitUploadFailed = ~matches,
            !.confirmedCheckpoint = IF matches THEN returnedCheckpoint ELSE None,
            !.confirmationKind = IF matches THEN "explicit" ELSE "none"
        ]

CancelExplicitPath ==
    /\ state.phase = "verified"
    /\ state.syncPaused
    /\ state' = [state EXCEPT
        !.phase = "resuming",
        !.postResumePhase = "verified",
        !.explicitUploadAttempted = TRUE,
        !.explicitUploadFailed = TRUE,
        !.confirmedCheckpoint = None,
        !.confirmationKind = "none"
        ]

AttemptResume ==
    /\ state.phase = "resuming"
    /\ state.syncPaused
    /\ \/ state' = [state EXCEPT
            !.phase = state.postResumePhase,
            !.syncPaused = FALSE,
            !.resumeAttempted = TRUE,
            !.resumeFailed = FALSE
        ]
       \/ state' = [state EXCEPT
            !.phase = "aborted",
            !.resumeAttempted = TRUE,
            !.resumeFailed = TRUE
        ]

BeginLegacyQualification ==
    /\ state.phase = "verified"
    /\ state.rootKind = "icloud"
    /\ ~state.syncPaused
    /\ state.confirmedCheckpoint = None
    /\ ~state.explicitUploadAttempted
    /\ state.legacyStatus = "idle"
    /\ state' = [state EXCEPT
        !.legacyStatus = "pending",
        !.legacyCheckpoint = state.installedCheckpoint,
        !.legacyLocalVersion = state.installedLocalVersion,
        !.legacyGeneration = state.localWriteGeneration
        ]

ObserveLegacyUploaded ==
    /\ state.phase = "verified"
    /\ state.legacyStatus = "pending"
    /\ state' = [state EXCEPT !.legacyStatus = "uploaded"]

LegacyExactReadback ==
    /\ state.phase = "verified"
    /\ state.legacyStatus = "uploaded"
    /\ \E readbackCheckpoint \in CheckpointIDs \cup {None}:
       \E readbackLocalVersion \in LocalPersistentVersionIdentifiers \cup {None}:
        LET matches ==
            /\ state.localWriteGeneration = state.legacyGeneration
            /\ readbackCheckpoint = state.legacyCheckpoint
            /\ readbackCheckpoint = state.installedCheckpoint
            /\ readbackCheckpoint = state.verifiedCheckpoint
            /\ readbackLocalVersion = state.legacyLocalVersion
            /\ readbackLocalVersion = state.installedLocalVersion
            /\ readbackLocalVersion = state.verifiedLocalVersion
            /\ state.checkpointVerified
        IN state' = [state EXCEPT
            !.legacyStatus = "complete",
            !.readbackCheckpoint = readbackCheckpoint,
            !.readbackLocalVersion = readbackLocalVersion,
            !.confirmedCheckpoint = IF matches THEN readbackCheckpoint ELSE None,
            !.confirmationKind = IF matches THEN "legacy" ELSE "none"
        ]

InterveningLocalCheckpointWrite ==
    /\ state.phase = "verified"
    /\ state.legacyStatus \in {"pending", "uploaded"}
    /\ state.localWriteGeneration = state.legacyGeneration
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
       \E localVersion \in LocalPersistentVersionIdentifiers \ {state.installedLocalVersion}:
        state' = [state EXCEPT
            !.installedCheckpoint = checkpoint,
            !.usedCheckpointIDs = @ \cup {checkpoint},
            !.checkpointInstallCount[checkpoint] = @ + 1,
            !.verifiedCheckpoint = checkpoint,
            !.installedLocalVersion = localVersion,
            !.verifiedLocalVersion = localVersion,
            !.localWriteGeneration = @ + 1,
            !.confirmedCheckpoint = None,
            !.confirmationKind = "none"
        ]

DeleteJournal ==
    /\ state.phase = "verified"
    /\ state.journalExists
    /\ state.checkpointVerified
    /\ state.durableHistory \subseteq state.durableCheckpoint
    /\ LET qualified ==
        \/ state.rootKind = "local"
        \/ /\ state.rootKind = "icloud"
           /\ ~state.syncPaused
           /\ state.confirmedCheckpoint = state.installedCheckpoint
           /\ state.confirmedCheckpoint = state.verifiedCheckpoint
       IN /\ qualified
          /\ state' = [state EXCEPT
                !.phase = "cleanup",
                !.journalExists = FALSE,
                !.journal = {},
                !.journalDeletionQualified = qualified,
                !.journalDeletionCheckpoint = state.verifiedCheckpoint
             ]

ClearActiveRecord ==
    /\ state.phase = "cleanup"
    /\ ~state.journalExists
    /\ state.activeRecord
    /\ state' = [state EXCEPT
        !.phase = "terminated",
        !.activeRecord = FALSE
        ]

QuitAnywayAfterInstall ==
    /\ state.phase = "verified"
    /\ ~state.syncPaused
    /\ state.journalExists
    /\ state' = [state EXCEPT !.phase = "aborted"]

ReentrantTerminate ==
    /\ state.phase \notin {"running", "terminated", "crashed"}
    /\ state.terminationRequests < 2
    /\ state' = [state EXCEPT !.terminationRequests = @ + 1]

Crash ==
    /\ state.phase \notin {"terminated", "crashed"}
    /\ state' = [state EXCEPT
        !.phase = "crashed",
        !.live = state.durableCheckpoint \cup
            (IF state.journalExists THEN state.journal ELSE {}),
        !.pendingJournal = {},
        !.queuedCallbacks = {}
        ]

Next ==
    \/ UserEdit
    \/ QueueProviderCallback
    \/ FinishProviderCallback
    \/ ProviderNotification
    \/ SynchronizeJournal
    \/ SettleSeparateFiles
    \/ FinishReconciliation
    \/ BeginQuit
    \/ PreinstallFailure
    \/ RetryPreinstallWork
    \/ QuitAnywayBeforeInstall
    \/ ReachProviderBarrier
    \/ LateCallbackAfterClose
    \/ DrainPresenter
    \/ PauseCheckpoint
    \/ PauseCheckpointFailedBeforeAcquisition
    \/ InstallCheckpoint
    \/ VerifyExactCheckpoint
    \/ CheckpointVerificationFailed
    \/ StartExplicitUpload
    \/ ExplicitUploadCallback
    \/ CancelExplicitPath
    \/ AttemptResume
    \/ BeginLegacyQualification
    \/ ObserveLegacyUploaded
    \/ LegacyExactReadback
    \/ InterveningLocalCheckpointWrite
    \/ DeleteJournal
    \/ ClearActiveRecord
    \/ QuitAnywayAfterInstall
    \/ ReentrantTerminate
    \/ Crash

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(SynchronizeJournal)
    /\ WF_vars(FinishProviderCallback)
    /\ WF_vars(FinishReconciliation)
    /\ WF_vars(DrainPresenter)
    /\ WF_vars(AttemptResume)

TypeOK ==
    /\ state.phase \in Phases
    /\ state.rootKind \in RootKinds
    /\ state.controlsSupported \in BOOLEAN
    /\ state.live \subseteq Edits
    /\ state.pendingJournal \subseteq Edits
    /\ state.journal \subseteq Edits
    /\ state.durableHistory \subseteq Edits
    /\ state.fileCopies \subseteq Edits
    /\ state.frozen \subseteq Edits
    /\ state.stagedCheckpoint \subseteq Edits
    /\ state.durableCheckpoint \subseteq Edits
    /\ state.installedCheckpoint \in CheckpointIDs
    /\ state.usedCheckpointIDs \subseteq CheckpointIDs
    /\ state.checkpointInstallCount \in [CheckpointIDs -> 0..1]
    /\ state.verifiedCheckpoint \in CheckpointIDs
    /\ state.installedLocalVersion \in LocalPersistentVersionIdentifiers
    /\ state.verifiedLocalVersion \in LocalPersistentVersionIdentifiers
    /\ state.uploadRequest \in UploadRequestIDs \cup {None}
    /\ state.requestCheckpoint \in CheckpointIDs \cup {None}
    /\ state.requestLocalVersion \in LocalPersistentVersionIdentifiers \cup {None}
    /\ state.explicitUploadAttempted \in BOOLEAN
    /\ state.explicitUploadFailed \in BOOLEAN
    /\ state.returnedRequest \in UploadRequestIDs \cup {None}
    /\ state.returnedCheckpoint \in CheckpointIDs \cup {None}
    /\ state.returnedLocalVersion \in LocalPersistentVersionIdentifiers \cup {None}
    /\ state.confirmedCheckpoint \in CheckpointIDs \cup {None}
    /\ state.confirmationKind \in ConfirmationKinds
    /\ state.readbackCheckpoint \in CheckpointIDs \cup {None}
    /\ state.readbackLocalVersion \in LocalPersistentVersionIdentifiers \cup {None}
    /\ state.checkpointVerified \in BOOLEAN
    /\ state.syncPaused \in BOOLEAN
    /\ state.pauseAttempted \in BOOLEAN
    /\ state.pauseFailedBeforeAcquisition \in BOOLEAN
    /\ state.pauseEverSucceeded \in BOOLEAN
    /\ state.resumeAttempted \in BOOLEAN
    /\ state.resumeFailed \in BOOLEAN
    /\ state.postResumePhase \in {"verified", "aborted"}
    /\ state.legacyStatus \in LegacyStatuses
    /\ state.legacyCheckpoint \in CheckpointIDs \cup {None}
    /\ state.legacyLocalVersion \in LocalPersistentVersionIdentifiers \cup {None}
    /\ state.legacyGeneration \in 0..1
    /\ state.localWriteGeneration \in 0..2
    /\ state.journalExists \in BOOLEAN
    /\ state.activeRecord \in BOOLEAN
    /\ state.journalDeletionQualified \in BOOLEAN
    /\ state.journalDeletionCheckpoint \in CheckpointIDs \cup {None}
    /\ state.installCount \in 0..2
    /\ state.terminationRequests \in 0..2
    /\ state.queuedCallbacks \subseteq Edits
    /\ state.discardedCallbacks \subseteq Edits
    /\ state.dirty \in BOOLEAN
    /\ state.sessionClosing \in BOOLEAN
    /\ state.presenterDrained \in BOOLEAN

DurableWorkIsAlwaysRecoverable ==
    state.durableHistory \subseteq
        (state.durableCheckpoint \cup
            (IF state.journalExists THEN state.journal ELSE {}))

JournalCleanupIsHistoricallyQualified ==
    ~state.journalExists =>
        /\ state.journalDeletionQualified
        /\ state.journalDeletionCheckpoint = state.verifiedCheckpoint
        /\ state.checkpointVerified
        /\ state.durableHistory \subseteq state.durableCheckpoint
        /\ \/ state.rootKind = "local"
           \/ /\ state.rootKind = "icloud"
              /\ state.confirmedCheckpoint = state.journalDeletionCheckpoint
              /\ ~state.syncPaused

ExactConfirmationNamesCurrentCheckpoint ==
    state.confirmedCheckpoint # None =>
        /\ state.checkpointVerified
        /\ state.confirmedCheckpoint = state.installedCheckpoint
        /\ state.confirmedCheckpoint = state.verifiedCheckpoint
        /\ state.installedLocalVersion = state.verifiedLocalVersion

ExplicitConfirmationMatchedRequest ==
    state.confirmationKind = "explicit" =>
        /\ state.returnedRequest = state.uploadRequest
        /\ state.returnedCheckpoint = state.requestCheckpoint
        /\ state.returnedCheckpoint = state.installedCheckpoint
        /\ state.returnedLocalVersion = state.requestLocalVersion
        /\ state.returnedLocalVersion = state.installedLocalVersion

LegacyConfirmationFollowedExactTransition ==
    state.confirmationKind = "legacy" =>
        /\ state.legacyStatus = "complete"
        /\ state.localWriteGeneration = state.legacyGeneration
        /\ state.readbackCheckpoint = state.legacyCheckpoint
        /\ state.readbackCheckpoint = state.installedCheckpoint
        /\ state.readbackLocalVersion = state.legacyLocalVersion
        /\ state.readbackLocalVersion = state.installedLocalVersion

FailedExplicitPathRetainsRecoveryEvidence ==
    state.explicitUploadFailed =>
        /\ state.explicitUploadAttempted
        /\ state.confirmedCheckpoint = None
        /\ state.confirmationKind = "none"
        /\ state.legacyStatus = "idle"
        /\ state.journalExists

TerminalPausedPathAttemptedResume ==
    /\ state.pauseEverSucceeded
    /\ state.phase \in {"aborted", "terminated"}
    /\ state.syncPaused
    => state.resumeAttempted

ActiveRecordClearsAfterJournal ==
    ~state.activeRecord => ~state.journalExists

UnqualifiedRootsRetainJournal ==
    state.rootKind \in {"otherProvider", "unknown"} => state.journalExists

CheckpointInstalledAtMostOnceDespiteReentry ==
    state.installCount <= 1

CheckpointIDsAreNeverReused ==
    \A checkpoint \in CheckpointIDs:
        state.checkpointInstallCount[checkpoint] <= 1

InstalledCheckpointHadStableDrainedBarrier ==
    state.installCount = 1 =>
        /\ state.presenterDrained
        /\ state.sessionClosing
        /\ state.queuedCallbacks = {}
        /\ ~state.dirty
        /\ state.frozen \subseteq state.durableHistory
        /\ state.fileCopies = state.frozen
        /\ state.pendingJournal = {}

SupportedICloudInstallAttemptedPause ==
    /\ state.installCount = 1
    /\ state.rootKind = "icloud"
    /\ state.controlsSupported
    => /\ state.pauseAttempted
       /\ (state.pauseEverSucceeded \/
           state.pauseFailedBeforeAcquisition)

PostCloseModelIsFrozen ==
    /\ state.sessionClosing
    /\ state.phase # "crashed"
    => state.live = state.frozen

PresenterDrainsOnlyAfterClose ==
    state.presenterDrained => state.sessionClosing

DurabilityProgress ==
    /\ state.phase \in {"running", "quiescing"}
    /\ state.pendingJournal # {}
    ~> \/ state.pendingJournal = {}
       \/ state.phase \notin {"running", "quiescing"}

CallbackProgress ==
    /\ state.phase \in {"running", "quiescing"}
    /\ state.queuedCallbacks # {}
    ~> \/ state.queuedCallbacks = {}
       \/ state.phase \notin {"running", "quiescing"}

DirtyFollowupProgress ==
    /\ state.phase \in {"running", "quiescing"}
    /\ state.dirty
    /\ state.queuedCallbacks = {}
    ~> \/ ~state.dirty
       \/ state.queuedCallbacks # {}
       \/ state.phase \notin {"running", "quiescing"}

ResumeProgress ==
    state.phase = "resuming"
    ~> state.resumeAttempted \/ state.phase = "crashed"

=============================================================================
