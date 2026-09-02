------------------- MODULE CrossBoundaryDurabilitySafety -------------------
EXTENDS FiniteSets, Naturals

\* Small composition of exact-generation pending work, host-local WAL and note
\* installation, checkpoint-current contention, exact retry, crash/restart,
\* and WAL cleanup. "Remote" settlement aggregates note/removal/retirement work
\* derived from provider Current plus local WAL; bytes and Foundation are abstract.

CONSTANTS
    MaxGeneration, CheckpointVersions,
    Version0, Version1, Version2, None

ASSUME
    /\ MaxGeneration = 2
    /\ CheckpointVersions = {Version0, Version1, Version2}
    /\ Cardinality(CheckpointVersions) = 3
    /\ None \notin CheckpointVersions

Generations == 1..MaxGeneration

Phases == {
    "editing", "quiesced", "attempting", "merging",
    "mergeDurable", "mergeSettled", "retrying", "verified",
    "rejected", "closing", "deleting", "crashed", "closed"
}

NextVersion(version) ==
    CASE version = Version0 -> Version1
      [] version = Version1 -> Version2
      [] OTHER -> Version2

LatestGeneration(generations) ==
    IF MaxGeneration \in generations
      THEN MaxGeneration
      ELSE IF 1 \in generations THEN 1 ELSE 0

RecoveredGenerations(generation) ==
    IF generation = 0 THEN {} ELSE 1..generation

VARIABLE state

vars == <<state>>

Init ==
    state = [
        phase |-> "editing",
        admitted |-> {},
        latestAdmitted |-> 0,
        pendingGeneration |-> 0,
        walOutbox |-> {},
        walDurable |-> {},
        fileOutbox |-> {},
        fileGeneration |-> 0,
        maxFileGeneration |-> 0,
        walExists |-> TRUE,
        walOpen |-> TRUE,
        deletionDirectoryDurable |-> FALSE,

        providerVersion |-> Version0,
        providerHasRemote |-> FALSE,
        attemptExpectedVersion |-> None,
        attemptLocalGeneration |-> 0,
        capturedCurrentVersion |-> None,
        capturedRemote |-> FALSE,
        remoteWALDurable |-> FALSE,
        remoteFileInstalled |-> FALSE,
        remoteSettlementVersion |-> None,
        checkpointLocalGeneration |-> 0,
        checkpointHasRemote |-> FALSE,
        checkpointVerified |-> FALSE,
        checkpointWritten |-> FALSE,

        fileInstallWitnesses |-> {},
        cleanupWitnesses |-> {}
        ]

AdmitNextGeneration ==
    /\ state.phase = "editing"
    /\ state.latestAdmitted < MaxGeneration
    /\ LET generation == state.latestAdmitted + 1
       IN state' = [state EXCEPT
            !.admitted = @ \cup {generation},
            !.latestAdmitted = generation,
            !.pendingGeneration = generation
            ]

CapturePendingWAL ==
    /\ state.phase \in {"editing", "quiesced"}
    /\ state.pendingGeneration \in Generations
    /\ state.pendingGeneration \notin state.walOutbox
    /\ state.pendingGeneration \notin state.walDurable
    /\ state' = [state EXCEPT
        !.walOutbox = @ \cup {state.pendingGeneration}
        ]

CompleteWALGeneration(generation) ==
    /\ state.phase \in {"editing", "quiesced"}
    /\ generation \in state.walOutbox
    /\ state.walOpen
    /\ state' = [state EXCEPT
        !.walOutbox = @ \ {generation},
        !.walDurable = @ \cup {generation},
        !.pendingGeneration =
            IF @ = generation THEN 0 ELSE @
        ]

CapturePendingFile ==
    /\ state.phase \in {"editing", "quiesced"}
    /\ state.latestAdmitted \in Generations
    /\ state.latestAdmitted \notin state.fileOutbox
    /\ state.fileGeneration < state.latestAdmitted
    /\ state' = [state EXCEPT
        !.fileOutbox = @ \cup {state.latestAdmitted}
        ]

InstallCurrentFileGeneration(generation) ==
    /\ state.phase \in {"editing", "quiesced"}
    /\ generation \in state.fileOutbox
    /\ generation \in state.walDurable
    /\ generation = state.latestAdmitted
    /\ state' = [state EXCEPT
        !.fileOutbox = @ \ {generation},
        !.fileGeneration = generation,
        !.maxFileGeneration = generation,
        !.fileInstallWitnesses =
            @ \cup {<<generation, state.latestAdmitted>>}
        ]

RejectStaleFileCompletion(generation) ==
    /\ state.phase \in {"editing", "quiesced"}
    /\ generation \in state.fileOutbox
    /\ generation # state.latestAdmitted
    /\ state' = [state EXCEPT !.fileOutbox = @ \ {generation}]

Quiesce ==
    /\ state.phase = "editing"
    /\ state' = [state EXCEPT !.phase = "quiesced"]

BeginCheckpointAttempt ==
    /\ state.phase = "quiesced"
    /\ state.latestAdmitted \in Generations
    /\ state.pendingGeneration = 0
    /\ state.fileOutbox = {}
    /\ state.latestAdmitted \in state.walDurable
    /\ state.fileGeneration = state.latestAdmitted
    /\ state' = [state EXCEPT
        !.phase = "attempting",
        !.attemptExpectedVersion = state.providerVersion,
        !.attemptLocalGeneration = state.latestAdmitted
        ]

ProviderReplacesCheckpoint ==
    /\ state.phase = "attempting"
    /\ state.providerVersion = Version0
    /\ state' = [state EXCEPT
        !.providerVersion = NextVersion(@),
        !.providerHasRemote = TRUE
        ]

InstallUncontendedCheckpoint ==
    /\ state.phase = "attempting"
    /\ state.providerVersion = state.attemptExpectedVersion
    /\ state' = [state EXCEPT
        !.phase = "verified",
        !.checkpointLocalGeneration = state.attemptLocalGeneration,
        !.checkpointHasRemote = state.providerHasRemote,
        !.checkpointVerified = TRUE,
        !.checkpointWritten = TRUE
        ]

DetectCheckpointCurrentChanged ==
    /\ state.phase = "attempting"
    /\ state.providerVersion # state.attemptExpectedVersion
    /\ state' = [state EXCEPT
        !.phase = "merging",
        !.capturedCurrentVersion = state.providerVersion,
        !.capturedRemote = state.providerHasRemote
        ]

DurabilizeMergedRemote ==
    /\ state.phase = "merging"
    /\ state.capturedRemote
    /\ state' = [state EXCEPT
        !.phase = "mergeDurable",
        !.remoteWALDurable = TRUE,
        !.remoteSettlementVersion = state.capturedCurrentVersion
        ]

InstallMergedRemoteFile ==
    /\ state.phase = "mergeDurable"
    /\ state.remoteWALDurable
    /\ state.remoteSettlementVersion = state.capturedCurrentVersion
    /\ state' = [state EXCEPT
        !.phase = "mergeSettled",
        !.remoteFileInstalled = TRUE
        ]

BeginExactRetry ==
    /\ state.phase = "mergeSettled"
    /\ state.remoteWALDurable
    /\ state.remoteFileInstalled
    /\ state.remoteSettlementVersion = state.capturedCurrentVersion
    /\ state' = [state EXCEPT !.phase = "retrying"]

ProviderReplacesCheckpointAgain ==
    /\ state.phase = "retrying"
    /\ state.providerVersion = Version1
    /\ state' = [state EXCEPT
        !.providerVersion = NextVersion(@),
        !.providerHasRemote = TRUE
        ]

InstallExactRetry ==
    /\ state.phase = "retrying"
    /\ state.providerVersion = state.capturedCurrentVersion
    /\ state.remoteWALDurable
    /\ state.remoteFileInstalled
    /\ state.remoteSettlementVersion = state.capturedCurrentVersion
    /\ state' = [state EXCEPT
        !.phase = "verified",
        !.checkpointLocalGeneration = state.attemptLocalGeneration,
        !.checkpointHasRemote = state.capturedRemote,
        !.checkpointVerified = TRUE,
        !.checkpointWritten = TRUE
        ]

RejectStaleRetry ==
    /\ state.phase = "retrying"
    /\ state.providerVersion # state.capturedCurrentVersion
    /\ state' = [state EXCEPT !.phase = "rejected"]

CloseWAL ==
    /\ state.phase = "verified"
    /\ state.walOpen
    /\ state' = [state EXCEPT
        !.phase = "closing",
        !.walOpen = FALSE
        ]

DeleteCoveredWAL ==
    /\ state.phase = "closing"
    /\ state.walExists
    /\ state.checkpointVerified
    /\ state.checkpointLocalGeneration >= LatestGeneration(state.walDurable)
    /\ state.fileGeneration >= LatestGeneration(state.walDurable)
    /\ (~state.capturedRemote \/
            (state.checkpointHasRemote /\ state.remoteFileInstalled))
    /\ state' = [state EXCEPT
        !.phase = "deleting",
        !.walExists = FALSE,
        !.deletionDirectoryDurable = FALSE,
        !.cleanupWitnesses = @ \cup
            {<<state.checkpointVerified,
               state.checkpointLocalGeneration
                    >= LatestGeneration(state.walDurable),
               state.fileGeneration >= LatestGeneration(state.walDurable),
               ~state.capturedRemote \/
                    (state.checkpointHasRemote /\ state.remoteFileInstalled)>>}
        ]

SynchronizeRecoveryDirectory ==
    /\ state.phase = "deleting"
    /\ ~state.walExists
    /\ state' = [state EXCEPT
        !.phase = "closed",
        !.deletionDirectoryDurable = TRUE
        ]

Crash ==
    /\ state.phase \notin {"crashed", "closed"}
    /\ \E restored \in BOOLEAN:
        /\ (state.phase = "deleting" \/ restored = state.walExists)
        /\ state' = [state EXCEPT
            !.phase = "crashed",
            !.walExists = restored,
            !.walOpen = FALSE,
            !.pendingGeneration = 0,
            !.walOutbox = {},
            !.fileOutbox = {},
            !.deletionDirectoryDurable = FALSE
            ]

RestartWithWAL ==
    /\ state.phase = "crashed"
    /\ state.walExists
    /\ LET recovered == LatestGeneration(state.walDurable)
           recoveredRemoteWAL ==
                state.capturedRemote
                    /\ state.remoteWALDurable
                    /\ state.capturedCurrentVersion = state.providerVersion
                    /\ state.remoteSettlementVersion = state.providerVersion
           recoveredRemoteFile ==
                recoveredRemoteWAL /\ state.remoteFileInstalled
       IN state' = [state EXCEPT
            !.phase =
                IF state.checkpointVerified
                  THEN "verified"
                  ELSE IF state.providerHasRemote
                    THEN IF ~recoveredRemoteWAL
                      THEN "merging"
                      ELSE IF ~recoveredRemoteFile
                        THEN "mergeDurable"
                        ELSE "mergeSettled"
                    ELSE "quiesced",
            !.walOpen = TRUE,
            !.latestAdmitted = recovered,
            !.admitted = RecoveredGenerations(recovered),
            !.attemptExpectedVersion = None,
            !.attemptLocalGeneration = recovered,
            !.capturedCurrentVersion =
                IF state.providerHasRemote
                  THEN state.providerVersion ELSE None,
            !.capturedRemote = state.providerHasRemote,
            !.remoteWALDurable = recoveredRemoteWAL,
            !.remoteFileInstalled = recoveredRemoteFile,
            !.remoteSettlementVersion =
                IF recoveredRemoteWAL
                  THEN state.remoteSettlementVersion ELSE None
            ]

RestartAfterDeletedWAL ==
    /\ state.phase = "crashed"
    /\ ~state.walExists
    /\ state.checkpointVerified
    /\ state.checkpointLocalGeneration >= LatestGeneration(state.walDurable)
    /\ state' = [state EXCEPT !.phase = "deleting"]

Next ==
    \/ AdmitNextGeneration
    \/ CapturePendingWAL
    \/ \E generation \in Generations: CompleteWALGeneration(generation)
    \/ CapturePendingFile
    \/ \E generation \in Generations: InstallCurrentFileGeneration(generation)
    \/ \E generation \in Generations: RejectStaleFileCompletion(generation)
    \/ Quiesce
    \/ BeginCheckpointAttempt
    \/ ProviderReplacesCheckpoint
    \/ InstallUncontendedCheckpoint
    \/ DetectCheckpointCurrentChanged
    \/ DurabilizeMergedRemote
    \/ InstallMergedRemoteFile
    \/ BeginExactRetry
    \/ ProviderReplacesCheckpointAgain
    \/ InstallExactRetry
    \/ RejectStaleRetry
    \/ CloseWAL
    \/ DeleteCoveredWAL
    \/ SynchronizeRecoveryDirectory
    \/ Crash
    \/ RestartWithWAL
    \/ RestartAfterDeletedWAL

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state.phase \in Phases
    /\ state.admitted \subseteq Generations
    /\ state.latestAdmitted \in 0..MaxGeneration
    /\ state.pendingGeneration \in 0..MaxGeneration
    /\ state.walOutbox \subseteq Generations
    /\ state.walDurable \subseteq Generations
    /\ state.fileOutbox \subseteq Generations
    /\ state.fileGeneration \in 0..MaxGeneration
    /\ state.maxFileGeneration \in 0..MaxGeneration
    /\ state.walExists \in BOOLEAN
    /\ state.walOpen \in BOOLEAN
    /\ state.deletionDirectoryDurable \in BOOLEAN
    /\ state.providerVersion \in CheckpointVersions
    /\ state.providerHasRemote \in BOOLEAN
    /\ state.attemptExpectedVersion \in CheckpointVersions \cup {None}
    /\ state.attemptLocalGeneration \in 0..MaxGeneration
    /\ state.capturedCurrentVersion \in CheckpointVersions \cup {None}
    /\ state.capturedRemote \in BOOLEAN
    /\ state.remoteWALDurable \in BOOLEAN
    /\ state.remoteFileInstalled \in BOOLEAN
    /\ state.remoteSettlementVersion \in CheckpointVersions \cup {None}
    /\ state.checkpointLocalGeneration \in 0..MaxGeneration
    /\ state.checkpointHasRemote \in BOOLEAN
    /\ state.checkpointVerified \in BOOLEAN
    /\ state.checkpointWritten \in BOOLEAN
    /\ state.fileInstallWitnesses \subseteq Generations \X Generations
    /\ state.cleanupWitnesses
        \subseteq BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN

StaleWALCompletionNeverClearsNewerPendingGeneration ==
    [][\A generation \in Generations:
        CompleteWALGeneration(generation)
            /\ state.pendingGeneration \in Generations
            /\ state.pendingGeneration # generation
        => state'.pendingGeneration = state.pendingGeneration]_vars

StaleFileCompletionNeverInstallsOverNewerGeneration ==
    /\ state.fileInstallWitnesses \subseteq
        {<<generation, generation>>: generation \in Generations}
    /\ state.fileGeneration = state.maxFileGeneration

LatestWALDurableGenerationRemainsRecoverable ==
    LET generation == LatestGeneration(state.walDurable)
    IN generation = 0 \/
        \/ (state.walExists /\ generation \in state.walDurable)
        \/ state.fileGeneration >= generation
        \/ (state.checkpointVerified /\
                state.checkpointLocalGeneration >= generation)

CheckpointCurrentChangedNeverWrites ==
    [][DetectCheckpointCurrentChanged =>
        state'.checkpointWritten = state.checkpointWritten]_vars

CheckpointRemoteRequiresDurableInstalledRepresentation ==
    state.checkpointHasRemote =>
        /\ state.remoteWALDurable
        /\ state.remoteFileInstalled
        /\ state.remoteSettlementVersion = state.providerVersion

RemoteSettlementEvidenceIsCoherent ==
    /\ state.remoteFileInstalled => state.remoteWALDurable
    /\ state.remoteWALDurable =>
        /\ state.capturedRemote
        /\ state.remoteSettlementVersion = state.capturedCurrentVersion
    /\ ~state.remoteWALDurable => state.remoteSettlementVersion = None

RetryRequiresDurableAndInstalledMerge ==
    state.phase \in {"retrying", "verified", "closing", "deleting", "closed"}
        /\ state.capturedRemote
        => /\ state.remoteWALDurable
           /\ state.remoteFileInstalled
           /\ state.remoteSettlementVersion = state.capturedCurrentVersion

WALCleanupRequiresCompleteVerifiedCoverage ==
    state.cleanupWitnesses \subseteq {<<TRUE, TRUE, TRUE, TRUE>>}

ClosedRequiresDurableWALDeletion ==
    state.phase = "closed" =>
        /\ ~state.walExists
        /\ state.deletionDirectoryDurable
        /\ state.cleanupWitnesses # {}

=============================================================================
