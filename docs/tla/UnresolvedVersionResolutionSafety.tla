----------------- MODULE UnresolvedVersionResolutionSafety -----------------
EXTENDS FiniteSets, Naturals

CONSTANTS
    Versions, Version1, Version2, DuplicateVersion,
    NoteStates, InitialCurrentState, ConflictState1, ConflictState2,
    RecoveryIDs, RecoveryID1, RecoveryID2

ASSUME
    /\ Versions = {Version1, Version2, DuplicateVersion}
    /\ {InitialCurrentState, ConflictState1, ConflictState2} \subseteq NoteStates
    /\ Cardinality({InitialCurrentState, ConflictState1, ConflictState2}) = 3
    /\ {RecoveryID1, RecoveryID2} \subseteq RecoveryIDs
    /\ RecoveryID1 # RecoveryID2

VersionState(version) ==
    IF version \in {Version1, DuplicateVersion}
    THEN ConflictState1
    ELSE ConflictState2

RecoveryID(noteState) ==
    IF noteState = ConflictState1 THEN RecoveryID1 ELSE RecoveryID2

Phases == {"idle", "selecting", "saving", "using"}
Kinds == {"none", "save", "use"}

VARIABLE state

vars == <<state>>

Init ==
    state = [
        phase |-> "idle",
        providerVersions |-> {Version1, DuplicateVersion},
        readableVersions |-> Versions,
        snapshot |-> {},
        pendingVersion |-> {},
        pendingTargetState |-> InitialCurrentState,
        pendingKind |-> "none",
        chosenBodyApplied |-> FALSE,
        pendingWALDurable |-> FALSE,
        pendingFileInstalled |-> FALSE,
        currentState |-> InitialCurrentState,
        appliedChosenStates |-> {},
        copiedStates |-> {},
        durableCopyIDs |-> {},
        installedCopyIDs |-> {},
        retiredCopyIDs |-> {},
        durableCurrentStates |-> {},
        installedCurrentStates |-> {},
        resolvedVersions |-> {},
        savedResolvedVersions |-> {},
        chosenResolvedVersions |-> {},
        savedResolutionWitnesses |-> {},
        chosenResolutionWitnesses |-> {},
        removedVersions |-> {}
        ]

ProviderReportsAnotherVersion ==
    /\ \E version \in Versions \ state.providerVersions:
        state' = [state EXCEPT !.providerVersions = @ \cup {version}]

MakeUnreadable ==
    /\ \E version \in state.readableVersions:
        state' = [state EXCEPT !.readableVersions = @ \ {version}]

MakeReadable ==
    /\ \E version \in Versions \ state.readableVersions:
        state' = [state EXCEPT !.readableVersions = @ \cup {version}]

StartResolver ==
    /\ state.phase = "idle"
    /\ state.providerVersions \ state.resolvedVersions # {}
    /\ state' = [state EXCEPT
        !.phase = "selecting",
        !.snapshot = state.providerVersions \ state.resolvedVersions
        ]

CancelResolver ==
    /\ state.phase = "selecting"
    /\ state' = [state EXCEPT
        !.phase = "idle",
        !.snapshot = {}
        ]

BeginSaveAsNew ==
    /\ state.phase = "selecting"
    /\ \E version \in
            (state.snapshot \cap state.readableVersions) \ state.resolvedVersions:
        LET noteState == VersionState(version)
            recoveryID == RecoveryID(noteState)
        IN /\ recoveryID \notin state.retiredCopyIDs
           /\ state' = [state EXCEPT
            !.phase = "saving",
            !.pendingVersion = {version},
            !.pendingTargetState = noteState,
            !.pendingKind = "save",
            !.chosenBodyApplied = FALSE,
            !.pendingWALDurable = recoveryID \in state.durableCopyIDs,
            !.pendingFileInstalled = recoveryID \in state.installedCopyIDs
            ]

DurabilizeSavedCopy ==
    /\ state.phase = "saving"
    /\ ~state.pendingWALDurable
    /\ state' = [state EXCEPT
        !.copiedStates = @ \cup {state.pendingTargetState},
        !.durableCopyIDs = @ \cup {RecoveryID(state.pendingTargetState)},
        !.pendingWALDurable = TRUE
        ]

InstallSavedCopy ==
    /\ state.phase = "saving"
    /\ state.pendingWALDurable
    /\ ~state.pendingFileInstalled
    /\ state' = [state EXCEPT
        !.installedCopyIDs = @ \cup {RecoveryID(state.pendingTargetState)},
        !.pendingFileInstalled = TRUE
        ]

DeleteSavedCopyBeforeResolution ==
    /\ state.phase = "saving"
    /\ state.pendingWALDurable
    /\ \E version \in state.pendingVersion \ state.resolvedVersions:
        LET recoveryID == RecoveryID(state.pendingTargetState)
        IN /\ recoveryID \notin
                    {RecoveryID(VersionState(resolved)):
                        resolved \in state.savedResolvedVersions}
           /\ state' = [state EXCEPT
                !.phase = "selecting",
                !.retiredCopyIDs = @ \cup {recoveryID},
                !.durableCopyIDs = @ \ {recoveryID},
                !.installedCopyIDs = @ \ {recoveryID},
                !.pendingVersion = {},
                !.pendingTargetState = state.currentState,
                !.pendingKind = "none",
                !.chosenBodyApplied = FALSE,
                !.pendingWALDurable = FALSE,
                !.pendingFileInstalled = FALSE
                ]

ResolveSavedMember ==
    /\ state.phase = "saving"
    /\ state.pendingWALDurable
    /\ state.pendingFileInstalled
    /\ \E version \in state.pendingVersion \ state.resolvedVersions:
        state' = [state EXCEPT
            !.resolvedVersions = @ \cup {version},
            !.savedResolvedVersions = @ \cup {version},
            !.savedResolutionWitnesses =
                @ \cup {<<version, state.pendingTargetState>>}
            ]

FinishSaveDisposition ==
    /\ state.phase = "saving"
    /\ state.pendingWALDurable
    /\ state.pendingFileInstalled
    /\ LET remaining == state.providerVersions \ state.resolvedVersions
       IN state' = [state EXCEPT
            !.phase = IF remaining = {} THEN "idle" ELSE "selecting",
            !.snapshot = remaining,
            !.pendingVersion = {},
            !.pendingTargetState = state.currentState,
            !.pendingKind = "none",
            !.chosenBodyApplied = FALSE,
            !.pendingWALDurable = FALSE,
            !.pendingFileInstalled = FALSE
            ]

BeginUseCurrent ==
    /\ state.phase = "selecting"
    /\ state' = [state EXCEPT
        !.phase = "using",
        !.pendingVersion = {},
        !.pendingTargetState = state.currentState,
        !.pendingKind = "use",
        !.chosenBodyApplied = TRUE,
        !.pendingWALDurable = FALSE,
        !.pendingFileInstalled = FALSE
        ]

BeginUseVersion ==
    /\ state.phase = "selecting"
    /\ \E version \in
            (state.snapshot \cap state.readableVersions) \ state.resolvedVersions:
        state' = [state EXCEPT
            !.phase = "using",
            !.pendingVersion = {version},
            !.pendingTargetState = VersionState(version),
            !.pendingKind = "use",
            !.chosenBodyApplied = FALSE,
            !.pendingWALDurable = FALSE,
            !.pendingFileInstalled = FALSE
            ]

ApplyChosenBody ==
    /\ state.phase = "using"
    /\ ~state.chosenBodyApplied
    /\ state' = [state EXCEPT
        !.currentState = state.pendingTargetState,
        !.appliedChosenStates = @ \cup {state.pendingTargetState},
        !.chosenBodyApplied = TRUE
        ]

DurabilizeChosenBody ==
    /\ state.phase = "using"
    /\ state.chosenBodyApplied
    /\ ~state.pendingWALDurable
    /\ state' = [state EXCEPT
        !.durableCurrentStates = @ \cup {state.pendingTargetState},
        !.pendingWALDurable = TRUE
        ]

InstallChosenBody ==
    /\ state.phase = "using"
    /\ state.pendingWALDurable
    /\ ~state.pendingFileInstalled
    /\ state' = [state EXCEPT
        !.installedCurrentStates = @ \cup {state.pendingTargetState},
        !.pendingFileInstalled = TRUE
        ]

ResolveOneChosenMember ==
    /\ state.phase = "using"
    /\ state.pendingWALDurable
    /\ state.pendingFileInstalled
    /\ \E version \in state.snapshot \ state.resolvedVersions:
        state' = [state EXCEPT
            !.resolvedVersions = @ \cup {version},
            !.chosenResolvedVersions = @ \cup {version},
            !.chosenResolutionWitnesses =
                @ \cup {<<version, state.pendingTargetState>>}
            ]

FinishUseDisposition ==
    /\ state.phase = "using"
    /\ state.pendingWALDurable
    /\ state.pendingFileInstalled
    /\ LET remaining == state.providerVersions \ state.resolvedVersions
       IN state' = [state EXCEPT
            !.phase = IF remaining = {} THEN "idle" ELSE "selecting",
            !.snapshot = remaining,
            !.pendingVersion = {},
            !.pendingTargetState = state.currentState,
            !.pendingKind = "none",
            !.chosenBodyApplied = FALSE,
            !.pendingWALDurable = FALSE,
            !.pendingFileInstalled = FALSE
            ]

Next ==
    \/ ProviderReportsAnotherVersion
    \/ MakeUnreadable
    \/ MakeReadable
    \/ StartResolver
    \/ CancelResolver
    \/ BeginSaveAsNew
    \/ DurabilizeSavedCopy
    \/ InstallSavedCopy
    \/ DeleteSavedCopyBeforeResolution
    \/ ResolveSavedMember
    \/ FinishSaveDisposition
    \/ BeginUseCurrent
    \/ BeginUseVersion
    \/ ApplyChosenBody
    \/ DurabilizeChosenBody
    \/ InstallChosenBody
    \/ ResolveOneChosenMember
    \/ FinishUseDisposition

DispositionProgress ==
    DurabilizeSavedCopy \/ InstallSavedCopy \/ ResolveSavedMember
        \/ FinishSaveDisposition \/ ApplyChosenBody
        \/ DurabilizeChosenBody \/ InstallChosenBody
        \/ ResolveOneChosenMember \/ FinishUseDisposition

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(DispositionProgress)

TypeOK ==
    /\ state.phase \in Phases
    /\ state.providerVersions \subseteq Versions
    /\ state.readableVersions \subseteq Versions
    /\ state.snapshot \subseteq Versions
    /\ state.pendingVersion \subseteq Versions
    /\ Cardinality(state.pendingVersion) <= 1
    /\ state.pendingTargetState \in NoteStates
    /\ state.pendingKind \in Kinds
    /\ state.chosenBodyApplied \in BOOLEAN
    /\ state.pendingWALDurable \in BOOLEAN
    /\ state.pendingFileInstalled \in BOOLEAN
    /\ state.currentState \in NoteStates
    /\ state.appliedChosenStates \subseteq NoteStates
    /\ state.copiedStates \subseteq NoteStates
    /\ state.durableCopyIDs \subseteq RecoveryIDs
    /\ state.installedCopyIDs \subseteq RecoveryIDs
    /\ state.retiredCopyIDs \subseteq RecoveryIDs
    /\ state.durableCurrentStates \subseteq NoteStates
    /\ state.installedCurrentStates \subseteq NoteStates
    /\ state.resolvedVersions \subseteq Versions
    /\ state.savedResolvedVersions \subseteq Versions
    /\ state.chosenResolvedVersions \subseteq Versions
    /\ state.removedVersions \subseteq Versions

NoUndisclosedResolution ==
    state.resolvedVersions \subseteq state.providerVersions

ProviderHistoryIsNeverRemoved == state.removedVersions = {}

ResolutionIsExplicitlyPartitioned ==
    state.resolvedVersions =
        state.savedResolvedVersions \cup state.chosenResolvedVersions

SavedResolutionHasInstalledCopy ==
    \A witness \in state.savedResolutionWitnesses:
        /\ witness[1] \in state.savedResolvedVersions
        /\ RecoveryID(witness[2]) \in state.installedCopyIDs
        /\ RecoveryID(witness[2]) \in state.durableCopyIDs

ChosenResolutionHasInstalledCurrent ==
    \A witness \in state.chosenResolutionWitnesses:
        /\ witness[1] \in state.chosenResolvedVersions
        /\ witness[2] \in state.installedCurrentStates
        /\ witness[2] \in state.durableCurrentStates

EverySavedResolutionHasWitness ==
    state.savedResolvedVersions =
        {witness[1]: witness \in state.savedResolutionWitnesses}

EveryChosenResolutionHasWitness ==
    state.chosenResolvedVersions =
        {witness[1]: witness \in state.chosenResolutionWitnesses}

CopiesAreDeterministicAndIdempotent ==
    /\ state.durableCopyIDs \cup state.retiredCopyIDs =
        {RecoveryID(noteState): noteState \in state.copiedStates}
    /\ state.installedCopyIDs \subseteq state.durableCopyIDs

RetiredCopiesAreNeverReused ==
    /\ state.retiredCopyIDs \cap state.durableCopyIDs = {}
    /\ state.retiredCopyIDs \cap state.installedCopyIDs = {}

CurrentBodyChangesOnlyThroughChoice ==
    state.currentState \in {InitialCurrentState} \cup state.appliedChosenStates

=============================================================================
