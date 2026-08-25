------------------- MODULE ReconciliationFencingSafety --------------------
EXTENDS FiniteSets, Naturals, ReconciliationInterface

\* Versions are immutable persistent version identifiers. The provider catalog token
\* booleans encode equality with the transaction snapshot, not token ordering.
\* processedVersions records traversal only; representedVersions records
\* provider-version representation.

CONSTANTS
    Versions,
    RepresentativeVersion,
    Sessions,
    InitialSession,
    None

ASSUME
    /\ Cardinality(Versions) = 3
    /\ RepresentativeVersion \in Versions
    /\ Cardinality(Sessions) = 2
    /\ InitialSession \in Sessions
    /\ None \notin Sessions

Phases == {"idle", "processing", "fenced"}

VARIABLE state

vars == <<state>>

Init ==
    state = [
        activeSession |-> InitialSession,
        usedSessions |-> {InitialSession},
        sessionInstallCount |-> [session \in Sessions |->
            IF session = InitialSession THEN 1 ELSE 0],
        structuralChanged |-> FALSE,
        noteChanged |-> FALSE,
        catalogTokenChanged |-> FALSE,
        deliveredVersions |-> {},
        knownVersions |-> {},
        unreadableVersions |-> {},
        dirty |-> FALSE,
        phase |-> "idle",
        snapshotVersions |-> {},
        snapshotSession |-> None,
        enumerationComplete |-> FALSE,
        processedVersions |-> {},
        representedVersions |-> {},
        secondCatalogTokenChanged |-> FALSE,
        secondVersions |-> {},
        publishedRepresentedVersions |-> {},
        resolutionEligibleVersions |-> {},
        partialPreservedVersions |-> {},
        resolutionEligibilityWitnesses |-> {},
        completeCommitWitnesses |-> {},
        completeDirtyWitnesses |-> {},
        retryDirtyWitnesses |-> {},
        partialCommitWitnesses |-> {}
        ]

DeliverVersion ==
    /\ \E version \in Versions \ state.deliveredVersions:
        state' = [state EXCEPT
            !.deliveredVersions = @ \cup {version},
            !.knownVersions = @ \cup {version},
            !.catalogTokenChanged = state.phase # "idle",
            !.dirty = TRUE
        ]

ProviderCatalogTokenChangesWithoutVersionSet ==
    /\ state.phase \in {"processing", "fenced"}
    /\ ~state.catalogTokenChanged
    /\ state' = [state EXCEPT
        !.catalogTokenChanged = TRUE,
        !.dirty = TRUE
        ]

ProviderVersionSetChangesWithoutCatalogToken ==
    /\ state.phase \in {"processing", "fenced"}
    /\ \E version \in Versions \ state.deliveredVersions:
        state' = [state EXCEPT
            !.deliveredVersions = @ \cup {version},
            !.knownVersions = @ \cup {version},
            !.dirty = TRUE
            ]

MakeVersionUnreadable ==
    \E version \in state.knownVersions \ state.unreadableVersions:
        state' = [state EXCEPT
            !.unreadableVersions = @ \cup {version}
        ]

MakeVersionReadable ==
    \E version \in state.unreadableVersions:
        state' = [state EXCEPT
            !.unreadableVersions = @ \ {version}
        ]

StartTransaction ==
    /\ state.phase = "idle"
    /\ state.dirty
    /\ state.knownVersions # {}
    /\ \E complete \in BOOLEAN:
        state' = [state EXCEPT
            !.phase = "processing",
            !.snapshotVersions = state.knownVersions,
            !.snapshotSession = state.activeSession,
            !.structuralChanged = FALSE,
            !.noteChanged = FALSE,
            !.catalogTokenChanged = FALSE,
            !.enumerationComplete = complete,
            !.processedVersions = {},
            !.representedVersions = {},
            !.secondCatalogTokenChanged = FALSE,
            !.secondVersions = {}
        ]

ProcessReadableVersion ==
    /\ state.phase = "processing"
    /\ \E version \in
            state.snapshotVersions
                \ (state.processedVersions \cup state.unreadableVersions):
        \E represented \in
                IF version = RepresentativeVersion THEN BOOLEAN ELSE {TRUE}:
            state' = [state EXCEPT
                !.processedVersions = @ \cup {version},
                !.representedVersions =
                    IF represented THEN @ \cup {version} ELSE @
            ]

ChangeNoteInput ==
    /\ state.phase \in {"processing", "fenced"}
    /\ ~state.noteChanged
    /\ state' = [state EXCEPT !.noteChanged = TRUE]

ChangeStructuralInput ==
    /\ state.phase \in {"processing", "fenced"}
    /\ ~state.structuralChanged
    /\ state' = [state EXCEPT !.structuralChanged = TRUE]

ReplaceRootSessionIncarnation ==
    /\ state.phase \in {"processing", "fenced"}
    /\ \E session \in Sessions \ state.usedSessions:
        state' = [state EXCEPT
            !.activeSession = session,
            !.usedSessions = @ \cup {session},
            !.sessionInstallCount[session] = @ + 1,
            !.structuralChanged = TRUE,
            !.catalogTokenChanged = TRUE,
            !.knownVersions = {},
            !.dirty = TRUE
        ]

ReplaceRootSessionIncarnationWithSameInputs ==
    /\ state.phase \in {"processing", "fenced"}
    /\ \E session \in Sessions \ state.usedSessions:
        state' = [state EXCEPT
            !.activeSession = session,
            !.usedSessions = @ \cup {session},
            !.sessionInstallCount[session] = @ + 1,
            !.dirty = TRUE
            ]

TakeSecondFence ==
    /\ state.phase = "processing"
    /\ state.processedVersions \cup
        (state.snapshotVersions \cap state.unreadableVersions)
        = state.snapshotVersions
    /\ state' = [state EXCEPT
        !.phase = "fenced",
        !.secondCatalogTokenChanged = state.catalogTokenChanged,
        !.secondVersions = state.knownVersions
        ]

CurrentExactProviderFence ==
    ExactProviderFence(
        FALSE, state.secondCatalogTokenChanged,
        state.snapshotVersions, state.secondVersions)

CurrentUnchangedModelFence ==
    UnchangedModelFence(
        state.snapshotSession, state.activeSession,
        FALSE, state.structuralChanged,
        FALSE, state.noteChanged)

CurrentCompleteFence ==
    CompleteFence(
        state.snapshotVersions, state.unreadableVersions,
        state.enumerationComplete,
        FALSE, state.secondCatalogTokenChanged, state.secondVersions,
        state.snapshotSession, state.activeSession,
        FALSE, state.structuralChanged,
        FALSE, state.noteChanged,
        state.representedVersions)

CurrentPartialProviderEvidence ==
    PartialProviderEvidence(
        state.snapshotVersions, state.unreadableVersions,
        state.enumerationComplete,
        FALSE, state.secondCatalogTokenChanged, state.secondVersions)

CommitCompleteTransaction ==
    /\ state.phase = "fenced"
    /\ CurrentCompleteFence
    /\ LET mustRemainDirty ==
                \/ state.catalogTokenChanged # state.secondCatalogTokenChanged
                \/ state.knownVersions # state.secondVersions
           nextDirty == IF mustRemainDirty THEN TRUE ELSE FALSE
       IN state' = [state EXCEPT
            !.phase = "idle",
            !.publishedRepresentedVersions = @ \cup state.snapshotVersions,
            !.resolutionEligibleVersions = @ \cup state.snapshotVersions,
            !.resolutionEligibilityWitnesses =
                @ \cup (state.snapshotVersions \X {"complete"}),
            !.dirty = nextDirty,
            !.completeDirtyWitnesses = @ \cup
                {<<mustRemainDirty, nextDirty>>},
            !.completeCommitWitnesses = @ \cup
                {<<state.snapshotVersions # {},
                   state.enumerationComplete,
                   state.snapshotVersions \cap state.unreadableVersions = {},
                   ~state.secondCatalogTokenChanged,
                   state.snapshotVersions = state.secondVersions,
                   state.snapshotSession = state.activeSession,
                   ~state.structuralChanged,
                   ~state.noteChanged,
                   AllSelectedRepresented(
                        state.snapshotVersions, state.representedVersions)>>},
            !.structuralChanged = FALSE,
            !.noteChanged = FALSE,
            !.catalogTokenChanged = FALSE,
            !.snapshotVersions = {},
            !.snapshotSession = None,
            !.enumerationComplete = FALSE,
            !.processedVersions = {},
            !.representedVersions = {},
            !.secondCatalogTokenChanged = FALSE,
            !.secondVersions = {}
        ]

CommitPartialPreservation ==
    /\ state.phase = "fenced"
    /\ CurrentPartialProviderEvidence
    /\ CurrentUnchangedModelFence
    /\ LET nextDirty == TRUE
       IN state' = [state EXCEPT
            !.phase = "idle",
            !.publishedRepresentedVersions = @ \cup state.representedVersions,
            !.partialPreservedVersions = @ \cup state.representedVersions,
            !.dirty = nextDirty,
            !.retryDirtyWitnesses = @ \cup {<<TRUE, nextDirty>>},
            !.partialCommitWitnesses = @ \cup
                {<<CurrentPartialProviderEvidence,
                   state.snapshotSession = state.activeSession,
                   ~state.structuralChanged,
                   ~state.noteChanged>>},
            !.structuralChanged = FALSE,
            !.noteChanged = FALSE,
            !.catalogTokenChanged = FALSE,
            !.snapshotVersions = {},
            !.snapshotSession = None,
            !.enumerationComplete = FALSE,
            !.processedVersions = {},
            !.representedVersions = {},
            !.secondCatalogTokenChanged = FALSE,
            !.secondVersions = {}
            ]

DiscardTransaction ==
    /\ state.phase = "fenced"
    /\ LET nextDirty == TRUE
       IN state' = [state EXCEPT
            !.phase = "idle",
            !.dirty = nextDirty,
            !.retryDirtyWitnesses = @ \cup {<<TRUE, nextDirty>>},
            !.structuralChanged = FALSE,
            !.noteChanged = FALSE,
            !.catalogTokenChanged = FALSE,
            !.snapshotVersions = {},
            !.snapshotSession = None,
            !.enumerationComplete = FALSE,
            !.processedVersions = {},
            !.representedVersions = {},
            !.secondCatalogTokenChanged = FALSE,
            !.secondVersions = {}
            ]

Next ==
    \/ DeliverVersion
    \/ ProviderCatalogTokenChangesWithoutVersionSet
    \/ ProviderVersionSetChangesWithoutCatalogToken
    \/ MakeVersionUnreadable
    \/ MakeVersionReadable
    \/ StartTransaction
    \/ ProcessReadableVersion
    \/ ChangeNoteInput
    \/ ChangeStructuralInput
    \/ ReplaceRootSessionIncarnation
    \/ ReplaceRootSessionIncarnationWithSameInputs
    \/ TakeSecondFence
    \/ CommitCompleteTransaction
    \/ CommitPartialPreservation
    \/ DiscardTransaction

InternalTransactionProgress ==
    ProcessReadableVersion \/ TakeSecondFence \/ CommitCompleteTransaction
        \/ CommitPartialPreservation \/ DiscardTransaction

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(StartTransaction)
    /\ WF_vars(InternalTransactionProgress)

TypeOK ==
    /\ state.activeSession \in Sessions
    /\ state.usedSessions \subseteq Sessions
    /\ state.sessionInstallCount \in [Sessions -> 0..1]
    /\ state.structuralChanged \in BOOLEAN
    /\ state.noteChanged \in BOOLEAN
    /\ state.catalogTokenChanged \in BOOLEAN
    /\ state.deliveredVersions \subseteq Versions
    /\ state.knownVersions \subseteq Versions
    /\ state.unreadableVersions \subseteq Versions
    /\ state.dirty \in BOOLEAN
    /\ state.phase \in Phases
    /\ state.snapshotVersions \subseteq Versions
    /\ state.snapshotSession \in Sessions \cup {None}
    /\ state.enumerationComplete \in BOOLEAN
    /\ state.processedVersions \subseteq Versions
    /\ state.representedVersions \subseteq Versions
    /\ state.secondCatalogTokenChanged \in BOOLEAN
    /\ state.secondVersions \subseteq Versions
    /\ state.publishedRepresentedVersions \subseteq Versions
    /\ state.resolutionEligibleVersions \subseteq Versions
    /\ state.partialPreservedVersions \subseteq Versions
    /\ state.resolutionEligibilityWitnesses
        \subseteq (Versions \X {"complete"})
    /\ state.completeCommitWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN
            \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.completeDirtyWitnesses \subseteq (BOOLEAN \X BOOLEAN)
    /\ state.retryDirtyWitnesses \subseteq (BOOLEAN \X BOOLEAN)
    /\ state.partialCommitWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)

RoutineCandidatesWereDelivered ==
    /\ state.knownVersions \subseteq state.deliveredVersions
    /\ state.snapshotVersions \subseteq state.deliveredVersions

ProcessedVersionsComeFromSnapshot ==
    /\ state.processedVersions \subseteq state.snapshotVersions
    /\ state.representedVersions \subseteq state.processedVersions

EveryCompleteCommitHadAllFences ==
    state.completeCommitWitnesses \subseteq
        {<<TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE>>}

EveryPartialCommitWasConservative ==
    state.partialCommitWitnesses \subseteq
        {<<TRUE, TRUE, TRUE, TRUE>>}

EveryCompleteCommitSetCorrectDirtyState ==
    state.completeDirtyWitnesses \subseteq
        {<<FALSE, FALSE>>, <<TRUE, TRUE>>}

EveryRetryPathKeptDirty ==
    state.retryDirtyWitnesses \subseteq {<<TRUE, TRUE>>}

ResolutionEligibilityHasExactCompleteWitness ==
    state.resolutionEligibleVersions =
        {witness[1]: witness \in state.resolutionEligibilityWitnesses}

ResolutionEligibilityAndPartialPreservationAreTrackedSeparately ==
    /\ state.resolutionEligibleVersions \subseteq state.publishedRepresentedVersions
    /\ state.partialPreservedVersions \subseteq state.publishedRepresentedVersions

LateProviderChangeKeepsDirty ==
    /\ state.phase = "fenced"
    /\ \/ state.catalogTokenChanged # state.secondCatalogTokenChanged
       \/ state.knownVersions # state.secondVersions
    => state.dirty

RootSessionIncarnationsAreNeverReused ==
    \A session \in Sessions:
        state.sessionInstallCount[session] <= 1

DirtyKnownWorkEventuallyStarts ==
    /\ state.phase = "idle"
    /\ state.dirty
    /\ state.knownVersions # {}
    ~> \/ state.phase # "idle"
       \/ ~state.dirty
       \/ state.knownVersions = {}

ActiveTransactionEventuallyEnds ==
    state.phase # "idle" ~> state.phase = "idle"

=============================================================================
