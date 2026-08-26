------------------- MODULE CurrentVisibleFallbackSafety -------------------
EXTENDS FiniteSets, Naturals, ReconciliationInterface

\* This model begins after the required historical/nonlocal NSFileVersion
\* operation returned a documented stable unsupported result. That API-result
\* classification is an environmental obligation. initialResolutionEligibility
\* represents eligibility earned by any earlier complete exact transaction;
\* current-visible fallback must leave it unchanged.

CONSTANTS
    Versions,
    RepresentativeVersion,
    Sessions,
    InitialSession,
    MaxGeneration,
    None

ASSUME
    /\ Cardinality(Versions) = 3
    /\ RepresentativeVersion \in Versions
    /\ Cardinality(Sessions) = 2
    /\ InitialSession \in Sessions
    /\ MaxGeneration = 2
    /\ None \notin Sessions

Phases == {"idle", "processing", "fenced"}

VARIABLE state

vars == <<state>>

Init ==
    \E eligible \in SUBSET Versions:
        state = [
            activeSession |-> InitialSession,
            usedSessions |-> {InitialSession},
            unsupportedSessions |-> {InitialSession},
            fallbackSelected |-> TRUE,
            knownVersions |-> {RepresentativeVersion},
            unreadableVersions |-> {},
            dirtyGeneration |-> 0,
            dirty |-> TRUE,
            phase |-> "idle",
            servicingGeneration |-> 0,
            snapshotVersions |-> {},
            snapshotSession |-> None,
            processedVersions |-> {},
            representedVersions |-> {},
            catalogChanged |-> FALSE,
            structuralChanged |-> FALSE,
            noteChanged |-> FALSE,
            secondCatalogChanged |-> FALSE,
            secondVersions |-> {},
            initialResolutionEligibility |-> eligible,
            resolutionEligibleVersions |-> eligible,
            publishedRepresentedVersions |-> {},
            commitWitnesses |-> {},
            dirtyWitnesses |-> {},
            eligibilityWitnesses |-> {}
        ]

DeliverVersion ==
    /\ state.dirtyGeneration < MaxGeneration
    /\ \E version \in Versions \ state.knownVersions:
        state' = [state EXCEPT
            !.knownVersions = @ \cup {version},
            !.dirtyGeneration = @ + 1,
            !.dirty = TRUE,
            !.catalogChanged = state.phase # "idle"
        ]

ProviderCatalogChanges ==
    /\ state.phase \in {"processing", "fenced"}
    /\ ~state.catalogChanged
    /\ state.dirtyGeneration < MaxGeneration
    /\ state' = [state EXCEPT
        !.catalogChanged = TRUE,
        !.dirtyGeneration = @ + 1,
        !.dirty = TRUE
        ]

MakeVersionUnreadable ==
    /\ \E version \in state.knownVersions \ state.unreadableVersions:
        state' = [state EXCEPT
            !.unreadableVersions = @ \cup {version}
        ]

MakeVersionReadable ==
    /\ \E version \in state.unreadableVersions:
        state' = [state EXCEPT
            !.unreadableVersions = @ \ {version}
        ]

BeginFallback ==
    /\ state.phase = "idle"
    /\ state.dirty
    /\ state.knownVersions # {}
    /\ state.fallbackSelected
    /\ state.activeSession \in state.unsupportedSessions
    /\ state' = [state EXCEPT
        !.phase = "processing",
        !.servicingGeneration = state.dirtyGeneration,
        !.snapshotVersions = state.knownVersions,
        !.snapshotSession = state.activeSession,
        !.processedVersions = {},
        !.representedVersions = {},
        !.catalogChanged = FALSE,
        !.structuralChanged = FALSE,
        !.noteChanged = FALSE,
        !.secondCatalogChanged = FALSE,
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

\* Same-authority root moves are stuttering; authority changes replace the session
\* and require exact capability discovery again.
ReplaceRootSession ==
    /\ \E session \in Sessions \ state.usedSessions:
        state' = [state EXCEPT
            !.activeSession = session,
            !.usedSessions = @ \cup {session},
            !.fallbackSelected = FALSE,
            !.dirty = TRUE,
            !.structuralChanged = state.phase # "idle",
            !.catalogChanged = state.phase # "idle"
        ]

ObserveStableUnsupported ==
    /\ state.phase = "idle"
    /\ ~state.fallbackSelected
    /\ state.activeSession \notin state.unsupportedSessions
    /\ state' = [state EXCEPT
        !.unsupportedSessions = @ \cup {state.activeSession},
        !.fallbackSelected = TRUE
        ]

TakeSecondFence ==
    /\ state.phase = "processing"
    /\ state.processedVersions \cup
        (state.snapshotVersions \cap state.unreadableVersions)
        = state.snapshotVersions
    /\ state' = [state EXCEPT
        !.phase = "fenced",
        !.secondCatalogChanged = state.catalogChanged,
        !.secondVersions = state.knownVersions
        ]

StableCurrentVisibleFence ==
    /\ state.snapshotVersions # {}
    /\ state.snapshotVersions \cap state.unreadableVersions = {}
    /\ ExactProviderFence(
        FALSE, state.secondCatalogChanged,
        state.snapshotVersions, state.secondVersions)
    /\ UnchangedModelFence(
        state.snapshotSession, state.activeSession,
        FALSE, state.structuralChanged,
        FALSE, state.noteChanged)
    /\ AllSelectedRepresented(
        state.snapshotVersions, state.representedVersions)
    /\ state.dirtyGeneration = state.servicingGeneration

CommitFallback ==
    /\ state.phase = "fenced"
    /\ state.fallbackSelected
    /\ StableCurrentVisibleFence
    /\ state' = [state EXCEPT
        !.phase = "idle",
        !.dirty = FALSE,
        !.publishedRepresentedVersions =
            @ \cup state.snapshotVersions,
        !.commitWitnesses = @ \cup
            {<<state.fallbackSelected,
               state.snapshotVersions \cap state.unreadableVersions = {},
               ~state.secondCatalogChanged,
               state.snapshotVersions = state.secondVersions,
               state.snapshotSession = state.activeSession,
               ~state.structuralChanged,
               ~state.noteChanged,
               AllSelectedRepresented(
                    state.snapshotVersions, state.representedVersions),
               state.dirtyGeneration = state.servicingGeneration>>},
        !.dirtyWitnesses = @ \cup
            {<<state.dirtyGeneration = state.servicingGeneration, FALSE>>},
        !.eligibilityWitnesses = @ \cup
            {<<state.resolutionEligibleVersions,
               state.resolutionEligibleVersions>>},
        !.snapshotVersions = {},
        !.snapshotSession = None,
        !.processedVersions = {},
        !.representedVersions = {},
        !.secondCatalogChanged = FALSE,
        !.secondVersions = {}
        ]

RetryFallback ==
    /\ state.phase = "fenced"
    /\ ~StableCurrentVisibleFence
    /\ state' = [state EXCEPT
        !.phase = "idle",
        !.dirty = TRUE,
        !.snapshotVersions = {},
        !.snapshotSession = None,
        !.processedVersions = {},
        !.representedVersions = {},
        !.secondCatalogChanged = FALSE,
        !.secondVersions = {}
        ]

Next ==
    \/ DeliverVersion
    \/ ProviderCatalogChanges
    \/ MakeVersionUnreadable
    \/ MakeVersionReadable
    \/ BeginFallback
    \/ ProcessReadableVersion
    \/ ChangeNoteInput
    \/ ChangeStructuralInput
    \/ ReplaceRootSession
    \/ ObserveStableUnsupported
    \/ TakeSecondFence
    \/ CommitFallback
    \/ RetryFallback

InternalProgress ==
    ProcessReadableVersion \/ TakeSecondFence \/ CommitFallback
        \/ RetryFallback

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(BeginFallback)
    /\ WF_vars(InternalProgress)

TypeOK ==
    /\ state.activeSession \in Sessions
    /\ state.usedSessions \subseteq Sessions
    /\ state.unsupportedSessions \subseteq state.usedSessions
    /\ state.fallbackSelected \in BOOLEAN
    /\ state.knownVersions \subseteq Versions
    /\ state.unreadableVersions \subseteq Versions
    /\ state.dirtyGeneration \in 0..MaxGeneration
    /\ state.dirty \in BOOLEAN
    /\ state.phase \in Phases
    /\ state.servicingGeneration \in 0..MaxGeneration
    /\ state.snapshotVersions \subseteq Versions
    /\ state.snapshotSession \in Sessions \cup {None}
    /\ state.processedVersions \subseteq Versions
    /\ state.representedVersions \subseteq Versions
    /\ state.catalogChanged \in BOOLEAN
    /\ state.structuralChanged \in BOOLEAN
    /\ state.noteChanged \in BOOLEAN
    /\ state.secondCatalogChanged \in BOOLEAN
    /\ state.secondVersions \subseteq Versions
    /\ state.initialResolutionEligibility \subseteq Versions
    /\ state.resolutionEligibleVersions \subseteq Versions
    /\ state.publishedRepresentedVersions \subseteq Versions
    /\ state.commitWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN
            \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.dirtyWitnesses \subseteq (BOOLEAN \X BOOLEAN)
    /\ state.eligibilityWitnesses \subseteq
        ((SUBSET Versions) \X (SUBSET Versions))

EveryFallbackCommitHadStableCurrentFences ==
    state.commitWitnesses \subseteq
        {<<TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE>>}

FallbackNeverChangesResolutionEligibility ==
    /\ state.resolutionEligibleVersions =
        state.initialResolutionEligibility
    /\ \A witness \in state.eligibilityWitnesses:
        witness[1] = witness[2]

FallbackRequiresStableUnsupportedResult ==
    state.fallbackSelected =>
        state.activeSession \in state.unsupportedSessions

FallbackConsumedOnlyItsServicedGeneration ==
    state.dirtyWitnesses \subseteq {<<TRUE, FALSE>>}

PublishedFallbackInputsWereRepresented ==
    state.publishedRepresentedVersions \subseteq
        state.knownVersions

EligibleDirtyFallbackEventuallyStartsOrIsRevoked ==
    /\ state.phase = "idle"
    /\ state.dirty
    /\ state.knownVersions # {}
    /\ state.fallbackSelected
    /\ state.activeSession \in state.unsupportedSessions
    ~> \/ state.phase # "idle"
       \/ ~state.dirty
       \/ ~state.fallbackSelected

ActiveFallbackEventuallyEnds ==
    state.phase # "idle" ~> state.phase = "idle"

=============================================================================
