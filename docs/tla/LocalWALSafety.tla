--------------------------- MODULE LocalWALSafety ---------------------------
EXTENDS FiniteSets, Naturals

CONSTANTS Edits, Checkpoints, InitialCheckpoint, None

ASSUME
    /\ IsFiniteSet(Edits)
    /\ Edits # {}
    /\ IsFiniteSet(Checkpoints)
    /\ Cardinality(Checkpoints) >= 2
    /\ InitialCheckpoint \in Checkpoints
    /\ None \notin Checkpoints

Phases == {
    "editing", "quiesced", "installed", "verified",
    "deleting", "crashed", "recovering", "closed"
}

VARIABLE state

vars == <<state>>

Init ==
    state = [
        phase |-> "editing",
        walExists |-> TRUE,
        walOpen |-> TRUE,
        headerDurable |-> TRUE,
        admitted |-> {},
        appended |-> {},
        durable |-> {},
        noteFilesDurable |-> {},
        acceptedCheckpoint |-> InitialCheckpoint,
        installedCheckpoint |-> None,
        checkpointCoverage |-> {},
        checkpointVerified |-> FALSE,
        deletionDirectoryDurable |-> FALSE,
        providerStalled |-> FALSE,
        deletionWitnesses |-> {},
        closedWitnesses |-> {}
        ]

AdmitEdit ==
    /\ state.phase = "editing"
    /\ \E edit \in Edits \ state.admitted:
        state' = [state EXCEPT !.admitted = @ \cup {edit}]

AppendEdit ==
    /\ state.phase \in {"editing", "quiesced"}
    /\ state.walOpen
    /\ \E edit \in state.admitted \ state.appended:
        state' = [state EXCEPT !.appended = @ \cup {edit}]

SynchronizeEdit ==
    /\ state.phase \in {"editing", "quiesced"}
    /\ state.walOpen
    /\ \E edit \in state.appended \ state.durable:
        state' = [state EXCEPT !.durable = @ \cup {edit}]

SettleNoteFile ==
    /\ state.phase \in {"editing", "quiesced"}
    /\ \E edit \in state.admitted \ state.noteFilesDurable:
        state' = [state EXCEPT !.noteFilesDurable = @ \cup {edit}]

ProviderStalls ==
    /\ ~state.providerStalled
    /\ state' = [state EXCEPT !.providerStalled = TRUE]

Quiesce ==
    /\ state.phase = "editing"
    /\ state' = [state EXCEPT !.phase = "quiesced"]

InstallCheckpoint ==
    /\ state.phase \in {"quiesced", "recovering"}
    /\ state.admitted = state.durable
    /\ state.admitted = state.noteFilesDurable
    /\ \E checkpoint \in Checkpoints \ {state.acceptedCheckpoint}:
        state' = [state EXCEPT
            !.phase = "installed",
            !.installedCheckpoint = checkpoint,
            !.checkpointCoverage = state.admitted,
            !.checkpointVerified = FALSE
        ]

VerifyCheckpoint ==
    /\ state.phase = "installed"
    /\ state.installedCheckpoint # None
    /\ state.checkpointCoverage = state.admitted
    /\ state' = [state EXCEPT
        !.phase = "verified",
        !.acceptedCheckpoint = state.installedCheckpoint,
        !.checkpointVerified = TRUE
        ]

CloseWAL ==
    /\ state.phase = "verified"
    /\ state.walOpen
    /\ state' = [state EXCEPT !.walOpen = FALSE]

DeleteWAL ==
    /\ state.phase = "verified"
    /\ ~state.walOpen
    /\ state.walExists
    /\ state.checkpointVerified
    /\ state.durable \subseteq state.checkpointCoverage
    /\ state' = [state EXCEPT
        !.phase = "deleting",
        !.walExists = FALSE,
        !.deletionDirectoryDurable = FALSE,
        !.deletionWitnesses = @ \cup
            {<<state.checkpointVerified,
               state.durable \subseteq state.checkpointCoverage>>}
        ]

SynchronizeRecoveryDirectory ==
    /\ state.phase = "deleting"
    /\ ~state.walExists
    /\ state' = [state EXCEPT
        !.phase = "closed",
        !.deletionDirectoryDurable = TRUE,
        !.closedWitnesses = @ \cup
            {<<state.checkpointVerified,
               state.durable \subseteq state.checkpointCoverage,
               TRUE>>}
        ]

Crash ==
    /\ state.phase \notin {"crashed", "closed"}
    /\ \E restored \in BOOLEAN:
        /\ restored = state.walExists \/ state.phase = "deleting"
        /\ state' = [state EXCEPT
            !.phase = "crashed",
            !.walExists = restored,
            !.walOpen = FALSE,
            !.deletionDirectoryDurable = FALSE
            ]

Restart ==
    /\ state.phase = "crashed"
    /\ state' = [state EXCEPT !.phase = "recovering"]

RecognizeCoveredWAL ==
    /\ state.phase = "recovering"
    /\ state.walExists
    /\ state.checkpointVerified
    /\ state.durable \subseteq state.checkpointCoverage
    /\ state' = [state EXCEPT !.phase = "verified"]

RecoverMissingPostDeleteWAL ==
    /\ state.phase = "recovering"
    /\ ~state.walExists
    /\ state.checkpointVerified
    /\ state.durable \subseteq state.checkpointCoverage
    /\ state' = [state EXCEPT !.phase = "deleting"]

Next ==
    \/ AdmitEdit
    \/ AppendEdit
    \/ SynchronizeEdit
    \/ SettleNoteFile
    \/ ProviderStalls
    \/ Quiesce
    \/ InstallCheckpoint
    \/ VerifyCheckpoint
    \/ CloseWAL
    \/ DeleteWAL
    \/ SynchronizeRecoveryDirectory
    \/ Crash
    \/ Restart
    \/ RecognizeCoveredWAL
    \/ RecoverMissingPostDeleteWAL

LocalProgress ==
    AppendEdit \/ SynchronizeEdit \/ SettleNoteFile \/ InstallCheckpoint
        \/ VerifyCheckpoint \/ CloseWAL \/ DeleteWAL
        \/ SynchronizeRecoveryDirectory \/ RecognizeCoveredWAL
        \/ RecoverMissingPostDeleteWAL

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(LocalProgress)

TypeOK ==
    /\ state.phase \in Phases
    /\ state.walExists \in BOOLEAN
    /\ state.walOpen \in BOOLEAN
    /\ state.headerDurable \in BOOLEAN
    /\ state.admitted \subseteq Edits
    /\ state.appended \subseteq Edits
    /\ state.durable \subseteq Edits
    /\ state.noteFilesDurable \subseteq Edits
    /\ state.acceptedCheckpoint \in Checkpoints
    /\ state.installedCheckpoint \in Checkpoints \cup {None}
    /\ state.checkpointCoverage \subseteq Edits
    /\ state.checkpointVerified \in BOOLEAN
    /\ state.deletionDirectoryDurable \in BOOLEAN
    /\ state.providerStalled \in BOOLEAN

DurabilityStagesAreMonotonic ==
    state.durable \subseteq state.appended
    /\ state.appended \subseteq state.admitted

WALDeletionRequiredVerifiedCoverage ==
    state.deletionWitnesses \subseteq {<<TRUE, TRUE>>}

ClosedStateRequiredDurableDeletion ==
    state.closedWitnesses \subseteq {<<TRUE, TRUE, TRUE>>}

EveryDurableEditRemainsRecoverable ==
    state.durable \subseteq
        IF state.walExists
          THEN state.appended
          ELSE state.checkpointCoverage

ProviderStallDoesNotChangeLocalDurabilityState ==
    state.providerStalled => state.headerDurable

=============================================================================
