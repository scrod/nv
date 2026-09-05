----------------- MODULE UnresolvedVersionResolutionSafety -----------------
EXTENDS FiniteSets, Naturals
\* Shared member-disposition component, not a segment transport/restart proof.
\* For proposal 5, pendingHistoryDurable means an exact complete segment/parent
\* barrier supplied by the caller; this module does not establish that input.

CONSTANTS Policy,
    Versions, Version1, Version2, DuplicateVersion,
    NoteStates, InitialCurrentState, ConflictState1, ConflictState2,
    RecoveryIDs, RecoveryID1, RecoveryID2

ASSUME
    /\ Policy \in {"safe", "earlySavedResolution", "reuseRetiredCopy",
                   "chooseLaterMembers", "earlyChosenResolution"}
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
        pendingHistoryDurable |-> FALSE,
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
        deletedSharedPendingCopy |-> FALSE,
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
        IN /\ (Policy = "reuseRetiredCopy" \/ recoveryID \notin state.retiredCopyIDs)
           /\ state' = [state EXCEPT
            !.phase = "saving",
            !.pendingVersion = {version},
            !.pendingTargetState = noteState,
            !.pendingKind = "save",
            !.chosenBodyApplied = FALSE,
            !.pendingHistoryDurable = recoveryID \in state.durableCopyIDs,
            !.pendingFileInstalled = recoveryID \in state.installedCopyIDs
            ]

DurabilizeSavedCopy ==
    /\ state.phase = "saving"
    /\ ~state.pendingHistoryDurable
    /\ state' = [state EXCEPT
        !.copiedStates = @ \cup {state.pendingTargetState},
        !.durableCopyIDs = @ \cup {RecoveryID(state.pendingTargetState)},
        !.pendingHistoryDurable = TRUE
        ]

InstallSavedCopy ==
    /\ state.phase = "saving"
    /\ state.pendingHistoryDurable
    /\ ~state.pendingFileInstalled
    /\ state' = [state EXCEPT
        !.installedCopyIDs = @ \cup {RecoveryID(state.pendingTargetState)},
        !.pendingFileInstalled = TRUE
        ]

\* A completed disposition records historical evidence, not permanent copy
\* liveness. Deletion is legal before OR after disposition, including while a
\* duplicate member is using the same copy. Slot allocation is out of scope.
DeleteSavedCopy ==
    \E recoveryID \in state.durableCopyIDs:
        LET invalidatesPending == state.phase = "saving"
                /\ recoveryID = RecoveryID(state.pendingTargetState)
        IN state' = [state EXCEPT
            !.deletedSharedPendingCopy = @ \/ (invalidatesPending
                /\ state.pendingVersion = {DuplicateVersion}
                /\ Version1 \in state.savedResolvedVersions),
            !.retiredCopyIDs = @ \cup {recoveryID},
            !.durableCopyIDs = @ \ {recoveryID},
            !.installedCopyIDs = @ \ {recoveryID},
            !.phase = IF invalidatesPending THEN "selecting" ELSE @,
            !.pendingVersion = IF invalidatesPending THEN {} ELSE @,
            !.pendingKind = IF invalidatesPending THEN "none" ELSE @,
            !.pendingHistoryDurable = IF invalidatesPending THEN FALSE ELSE @,
            !.pendingFileInstalled = IF invalidatesPending THEN FALSE ELSE @
            ]

ResolveSavedMember ==
    /\ state.phase = "saving"
    /\ (Policy = "earlySavedResolution" \/
          (state.pendingHistoryDurable /\ state.pendingFileInstalled))
    /\ \E version \in state.pendingVersion \ state.resolvedVersions:
        state' = [state EXCEPT
            !.resolvedVersions = @ \cup {version},
            !.savedResolvedVersions = @ \cup {version},
            !.savedResolutionWitnesses =
                @ \cup {<<version, state.pendingTargetState>>}
            ]

FinishSaveDisposition ==
    /\ state.phase = "saving"
    /\ state.pendingHistoryDurable
    /\ state.pendingFileInstalled
    /\ LET remaining == state.providerVersions \ state.resolvedVersions
       IN state' = [state EXCEPT
            !.phase = IF remaining = {} THEN "idle" ELSE "selecting",
            !.snapshot = remaining,
            !.pendingVersion = {},
            !.pendingTargetState = state.currentState,
            !.pendingKind = "none",
            !.chosenBodyApplied = FALSE,
            !.pendingHistoryDurable = FALSE,
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
        !.pendingHistoryDurable = FALSE,
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
            !.pendingHistoryDurable = FALSE,
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
    /\ ~state.pendingHistoryDurable
    /\ state' = [state EXCEPT
        !.durableCurrentStates = @ \cup {state.pendingTargetState},
        !.pendingHistoryDurable = TRUE
        ]

InstallChosenBody ==
    /\ state.phase = "using"
    /\ state.pendingHistoryDurable
    /\ ~state.pendingFileInstalled
    /\ state' = [state EXCEPT
        !.installedCurrentStates = @ \cup {state.pendingTargetState},
        !.pendingFileInstalled = TRUE
        ]

ResolveOneChosenMember ==
    /\ state.phase = "using"
    /\ (Policy = "earlyChosenResolution" \/
          (state.pendingHistoryDurable /\ state.pendingFileInstalled))
    /\ \E version \in
         (IF Policy = "chooseLaterMembers" THEN state.providerVersions ELSE state.snapshot)
             \ state.resolvedVersions:
        state' = [state EXCEPT
            !.resolvedVersions = @ \cup {version},
            !.chosenResolvedVersions = @ \cup {version},
            !.chosenResolutionWitnesses =
                @ \cup {<<version, state.pendingTargetState>>}
            ]

FinishUseDisposition ==
    /\ state.phase = "using"
    /\ state.pendingHistoryDurable
    /\ state.pendingFileInstalled
    /\ LET remaining == state.providerVersions \ state.resolvedVersions
       IN state' = [state EXCEPT
            !.phase = IF remaining = {} THEN "idle" ELSE "selecting",
            !.snapshot = remaining,
            !.pendingVersion = {},
            !.pendingTargetState = state.currentState,
            !.pendingKind = "none",
            !.chosenBodyApplied = FALSE,
            !.pendingHistoryDurable = FALSE,
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
    \/ DeleteSavedCopy
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
    /\ state.pendingHistoryDurable \in BOOLEAN
    /\ state.deletedSharedPendingCopy \in BOOLEAN
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
    [][(state'.savedResolvedVersions \ state.savedResolvedVersions # {}) =>
        /\ state.phase = "saving"
        /\ state.pendingHistoryDurable
        /\ state.pendingFileInstalled
        /\ RecoveryID(state.pendingTargetState) \in state.installedCopyIDs
        /\ RecoveryID(state.pendingTargetState) \in state.durableCopyIDs
        /\ state'.savedResolvedVersions \ state.savedResolvedVersions
              \subseteq state.pendingVersion]_vars

ChosenResolutionHasInstalledCurrent ==
    \A witness \in state.chosenResolutionWitnesses:
        /\ witness[1] \in state.chosenResolvedVersions
        /\ witness[2] \in state.installedCurrentStates
        /\ witness[2] \in state.durableCurrentStates

ChosenResolutionUsesCapturedInstalledCurrent ==
    [][(state'.chosenResolvedVersions \ state.chosenResolvedVersions # {}) =>
        /\ state.phase = "using"
        /\ state.pendingHistoryDurable
        /\ state.pendingFileInstalled
        /\ state.currentState = state.pendingTargetState
        /\ state.pendingTargetState \in state.installedCurrentStates
        /\ state.pendingTargetState \in state.durableCurrentStates
        /\ state'.chosenResolvedVersions \ state.chosenResolvedVersions
              \subseteq state.snapshot]_vars

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

NeverDeletedCompletedCopy ==
    ~\E version \in state.savedResolvedVersions:
        RecoveryID(VersionState(version)) \in state.retiredCopyIDs

NeverDeletedSharedPendingCopy ==
    ~state.deletedSharedPendingCopy

=============================================================================
