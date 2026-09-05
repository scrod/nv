---------------- MODULE CurrentVisibleReconciliationSafety ----------------
EXTENDS FiniteSets, Naturals

CONSTANTS Files, RepresentativeFile, Sessions, InitialSession, MaxGeneration, None, Policy

ASSUME
    /\ IsFiniteSet(Files)
    /\ Cardinality(Files) = 3
    /\ RepresentativeFile \in Files
    /\ Cardinality(Sessions) = 2
    /\ InitialSession \in Sessions
    /\ MaxGeneration = 2
    /\ None \notin Sessions
    /\ Policy \in {"safe", "skipDirtyFence", "skipRepresentation", "publishAllFiles", "wrongPublishedOutput"}

Phases == {"idle", "reading", "fenced"}

VARIABLE state

vars == <<state>>

Init ==
    state = [
        activeSession |-> InitialSession,
        usedSessions |-> {InitialSession},
        currentFiles |-> {RepresentativeFile},
        unreadableFiles |-> {},
        dirtyGeneration |-> 0,
        dirty |-> TRUE,
        phase |-> "idle",
        servicedGeneration |-> 0,
        snapshotFiles |-> {},
        snapshotSession |-> None,
        processedFiles |-> {},
        representedFiles |-> {},
        catalogChanged |-> FALSE,
        structuralChanged |-> FALSE,
        noteChanged |-> FALSE,
        secondFiles |-> {},
        publishedFiles |-> {},
        commitWitnesses |-> {},
        publicationWitnesses |-> {}
        ]

DeliverCurrentFile ==
    /\ state.dirtyGeneration < MaxGeneration
    /\ \E file \in Files \ state.currentFiles:
        state' = [state EXCEPT
            !.currentFiles = @ \cup {file},
            !.dirtyGeneration = @ + 1,
            !.dirty = TRUE,
            !.catalogChanged = state.phase # "idle"
        ]

RemoveCurrentFile ==
    /\ state.dirtyGeneration < MaxGeneration
    /\ \E file \in state.currentFiles:
        state' = [state EXCEPT
            !.currentFiles = @ \ {file},
            !.dirtyGeneration = @ + 1,
            !.dirty = TRUE,
            !.catalogChanged = state.phase # "idle"
        ]

\* A delivered invalidation can arrive after the serviced generation without
\* changing this fixture's file set. It must not be cleared by older work.
DeliverDirtyHint ==
    /\ state.dirtyGeneration < MaxGeneration
    /\ state' = [state EXCEPT !.dirtyGeneration = @ + 1, !.dirty = TRUE]

MakeUnreadable ==
    /\ \E file \in state.currentFiles \ state.unreadableFiles:
        state' = [state EXCEPT !.unreadableFiles = @ \cup {file}]

MakeReadable ==
    /\ \E file \in state.unreadableFiles:
        state' = [state EXCEPT !.unreadableFiles = @ \ {file}]

BeginTransaction ==
    /\ state.phase = "idle"
    /\ state.dirty
    /\ state' = [state EXCEPT
        !.phase = "reading",
        !.servicedGeneration = state.dirtyGeneration,
        !.snapshotFiles = state.currentFiles,
        !.snapshotSession = state.activeSession,
        !.processedFiles = {},
        !.representedFiles = {},
        !.catalogChanged = FALSE,
        !.structuralChanged = FALSE,
        !.noteChanged = FALSE,
        !.secondFiles = {}
        ]

ProcessReadableFile ==
    /\ state.phase = "reading"
    /\ \E file \in
            state.snapshotFiles
                \ (state.processedFiles \cup state.unreadableFiles):
        \E represented \in
                IF file = RepresentativeFile THEN BOOLEAN ELSE {TRUE}:
            state' = [state EXCEPT
                !.processedFiles = @ \cup {file},
                !.representedFiles =
                    IF represented THEN @ \cup {file} ELSE @
            ]

ChangeStructuralInput ==
    /\ state.phase \in {"reading", "fenced"}
    /\ ~state.structuralChanged
    /\ state' = [state EXCEPT !.structuralChanged = TRUE]

ChangeNoteInput ==
    /\ state.phase \in {"reading", "fenced"}
    /\ ~state.noteChanged
    /\ state' = [state EXCEPT !.noteChanged = TRUE]

ReplaceRootSession ==
    /\ \E session \in Sessions \ state.usedSessions:
        state' = [state EXCEPT
            !.activeSession = session,
            !.usedSessions = @ \cup {session},
            !.dirty = TRUE,
            !.catalogChanged = state.phase # "idle",
            !.structuralChanged = state.phase # "idle"
        ]

TakeSecondCatalog ==
    /\ state.phase = "reading"
    /\ state.processedFiles \cup
        (state.snapshotFiles \cap state.unreadableFiles)
        = state.snapshotFiles
    /\ state' = [state EXCEPT
        !.phase = "fenced",
        !.secondFiles = state.currentFiles
        ]

StableCurrentVisibleFence ==
    /\ state.snapshotFiles \cap state.unreadableFiles = {}
    /\ ~state.catalogChanged
    /\ state.snapshotFiles = state.secondFiles
    /\ state.snapshotSession = state.activeSession
    /\ ~state.structuralChanged
    /\ ~state.noteChanged
    /\ (state.snapshotFiles \subseteq state.representedFiles \/ Policy = "skipRepresentation")
    /\ (state.dirtyGeneration = state.servicedGeneration \/ Policy = "skipDirtyFence")

Commit ==
    /\ state.phase = "fenced"
    /\ StableCurrentVisibleFence
    /\ state' = [state EXCEPT
        !.phase = "idle",
        !.dirty = FALSE,
        !.publishedFiles = IF Policy \in {"publishAllFiles", "wrongPublishedOutput"}
            THEN Files ELSE state.snapshotFiles,
        !.commitWitnesses = @ \cup
            {<<state.snapshotFiles \cap state.unreadableFiles = {},
               ~state.catalogChanged,
               state.snapshotFiles = state.secondFiles,
               state.snapshotSession = state.activeSession,
               ~state.structuralChanged,
               ~state.noteChanged,
               state.snapshotFiles \subseteq state.representedFiles,
               state.dirtyGeneration = state.servicedGeneration>>},
        !.publicationWitnesses = @ \cup
            {<<IF Policy = "publishAllFiles" THEN Files ELSE state.snapshotFiles,
               state.snapshotFiles, state.representedFiles, state.secondFiles>>},
        !.snapshotFiles = {},
        !.snapshotSession = None,
        !.processedFiles = {},
        !.representedFiles = {},
        !.secondFiles = {}
        ]

Retry ==
    /\ state.phase = "fenced"
    /\ ~StableCurrentVisibleFence
    /\ state' = [state EXCEPT
        !.phase = "idle",
        !.dirty = TRUE,
        !.snapshotFiles = {},
        !.snapshotSession = None,
        !.processedFiles = {},
        !.representedFiles = {},
        !.secondFiles = {}
        ]

Next ==
    \/ DeliverCurrentFile
    \/ RemoveCurrentFile
    \/ DeliverDirtyHint
    \/ MakeUnreadable
    \/ MakeReadable
    \/ BeginTransaction
    \/ ProcessReadableFile
    \/ ChangeStructuralInput
    \/ ChangeNoteInput
    \/ ReplaceRootSession
    \/ TakeSecondCatalog
    \/ Commit
    \/ Retry

InternalProgress == ProcessReadableFile \/ TakeSecondCatalog \/ Commit \/ Retry

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(BeginTransaction)
    /\ WF_vars(InternalProgress)

TypeOK ==
    /\ state.activeSession \in Sessions
    /\ state.usedSessions \subseteq Sessions
    /\ state.currentFiles \subseteq Files
    /\ state.unreadableFiles \subseteq Files
    /\ state.dirtyGeneration \in 0..MaxGeneration
    /\ state.dirty \in BOOLEAN
    /\ state.phase \in Phases
    /\ state.servicedGeneration \in 0..MaxGeneration
    /\ state.snapshotFiles \subseteq Files
    /\ state.snapshotSession \in Sessions \cup {None}
    /\ state.processedFiles \subseteq Files
    /\ state.representedFiles \subseteq Files
    /\ state.catalogChanged \in BOOLEAN
    /\ state.structuralChanged \in BOOLEAN
    /\ state.noteChanged \in BOOLEAN
    /\ state.secondFiles \subseteq Files
    /\ state.publishedFiles \subseteq Files
    /\ state.commitWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN
            \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.publicationWitnesses \subseteq
        ((SUBSET Files) \X (SUBSET Files) \X (SUBSET Files) \X (SUBSET Files))

EveryCommitHadStableCurrentVisibleEvidence ==
    state.commitWitnesses \subseteq
        {<<TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE>>}

CommitConsumedOnlyServicedDirtyGeneration ==
    [][(state.dirty /\ ~state'.dirty) =>
        /\ state.phase = "fenced"
        /\ state.servicedGeneration = state.dirtyGeneration
        /\ state'.dirtyGeneration = state.dirtyGeneration]_vars

PublishedInputsWereCurrentAndRepresented ==
    \A w \in state.publicationWitnesses:
        /\ w[1] = w[2]
        /\ w[1] \subseteq w[3]
        /\ w[2] = w[4]

\* Unlike the historical tuple above, inspect the actual published post-state.
\* A witness copied from a preparation expression cannot certify its output.
PublicationMatchesCapturedInputs ==
    [][((state.dirty /\ ~state'.dirty) \/
         state'.publishedFiles # state.publishedFiles) =>
        /\ state.phase = "fenced"
        /\ state'.publishedFiles = state.snapshotFiles
        /\ state'.publishedFiles \subseteq state.representedFiles
        /\ state'.publishedFiles = state.secondFiles
        /\ state'.publishedFiles = state.currentFiles]_vars

ActiveTransactionEventuallyEnds ==
    state.phase # "idle" ~> state.phase = "idle"

NeverPublishedRepresentedFile == state.publicationWitnesses = {}
NeverRetainedLaterDirtyHint == ~(state.phase = "fenced" /\ state.dirty
    /\ state.dirtyGeneration > state.servicedGeneration /\ ~state.catalogChanged)

=============================================================================
