---------------- MODULE CrossMachineGenerationSafety ----------------
EXTENDS FiniteSets, Naturals

\* Focused two-generation refinement of CrossMachineDurability. The larger
\* glue model retains startup, preference, and note-delivery detail; this model
\* spends its state budget on two independently recoverable edits, two journal
\* generations, equality-only retained coverage, and reordered provider
\* checkpoint/journal delivery.

CONSTANTS
    Hosts, WriterHost, ReaderHost,
    Journals, Journal1, Journal2,
    CheckpointIDs, Checkpoint0, Checkpoint1, Checkpoint2, Checkpoint3,
    Edits, Edit1, Edit2, None

ASSUME
    /\ Hosts = {WriterHost, ReaderHost}
    /\ WriterHost # ReaderHost
    /\ Journals = {Journal1, Journal2}
    /\ Journal1 # Journal2
    /\ CheckpointIDs =
        {Checkpoint0, Checkpoint1, Checkpoint2, Checkpoint3}
    /\ Cardinality(CheckpointIDs) = 4
    /\ Edits = {Edit1, Edit2}
    /\ Edit1 # Edit2
    /\ None \notin Journals
    /\ None \notin CheckpointIDs

VARIABLE state

vars == <<state>>

Phases == {
    "firstOpen", "firstEdited", "firstInstalled",
    "firstRetainedWritten", "firstRetained", "secondOpen",
    "secondEdited", "secondInstalled", "advanceWritten",
    "recovering", "secondRecovered", "cleanupInstalled",
    "qualified", "cleaned", "postRemovalCrash", "writerLost"
}

CrashWindows == {
    "firstDemotionBeforeSync",
    "secondCheckpointBeforeAdvance",
    "retainedAdvanceBeforeSync",
    "localRemovalBeforeServerDeletion"
}

ExpectedJournalContent(journal) ==
    IF journal = Journal1 THEN {Edit1} ELSE {Edit2}

ReaderJournalEvidence(edit) ==
    \E journal \in Journals:
        /\ state.readerJournalPresent[journal]
        /\ edit \in state.readerJournalContent[journal]

WriterJournalEvidence(edit) ==
    \E journal \in Journals:
        /\ state.localJournalPresent[journal]
        /\ edit \in state.localJournalContent[journal]

ServerJournalEvidence(edit) ==
    \E journal \in Journals:
        /\ state.serverJournalPresent[journal]
        /\ edit \in state.serverJournalContent[journal]

RemoteRecoverable(edit) ==
    \/ edit \in state.serverCheckpointContent
    \/ ServerJournalEvidence(edit)
    \/ edit \in state.readerCheckpointContent
    \/ ReaderJournalEvidence(edit)
    \/ edit \in state.readerRepresented

Recoverable(edit) ==
    \/ /\ state.writerAvailable
       /\ \/ edit \in state.writerLive
          \/ edit \in state.localCheckpointContent
          \/ WriterJournalEvidence(edit)
    \/ RemoteRecoverable(edit)

Init ==
    state = [
        phase |-> "firstOpen",
        acknowledged |-> {},
        writerLive |-> {},
        writerEditable |-> TRUE,
        writerAvailable |-> TRUE,

        activeClaims |-> {Journal1},
        retainedClaims |-> {},
        syncedRetainedClaims |-> {},
        retainedCoverage |-> [journal \in Journals |-> None],
        syncedRetainedCoverage |-> [journal \in Journals |-> None],

        localJournalPresent |-> [journal \in Journals |->
            journal = Journal1],
        localJournalContent |-> [journal \in Journals |-> {}],
        localCheckpointID |-> Checkpoint0,
        localCheckpointContent |-> {},
        representedJournals |-> {},
        receiptCheckpoint |-> None,
        receiptContent |-> {},
        receiptJournals |-> {},

        crashWindowsSeen |-> {},
        unreplicatedAtWriterLoss |-> {},
        qualifiedCheckpoint |-> None,
        localDeletionRequested |-> {},
        authorizedServerDeletions |-> {},

        serverCheckpointID |-> Checkpoint0,
        serverCheckpointContent |-> {},
        serverJournalPresent |-> [journal \in Journals |-> FALSE],
        serverJournalContent |-> [journal \in Journals |-> {}],
        serverDeletedJournals |-> {},

        checkpointEventPending |-> FALSE,
        journalCreateEventsPending |-> {},
        journalDeleteEventsPending |-> {},

        readerCheckpointID |-> Checkpoint0,
        readerCheckpointContent |-> {},
        readerJournalPresent |-> [journal \in Journals |-> FALSE],
        readerJournalContent |-> [journal \in Journals |-> {}],
        readerRepresented |-> {},
        readerObservedAcknowledged |-> {},
        readerDirty |-> FALSE,
        reorderedDeletionWitnesses |-> {}
        ]

AcknowledgeFirstEdit ==
    /\ state.phase = "firstOpen"
    /\ state.writerEditable
    /\ Journal1 \in state.activeClaims
    /\ state.localJournalPresent[Journal1]
    /\ state' = [state EXCEPT
        !.phase = "firstEdited",
        !.acknowledged = {Edit1},
        !.writerLive = {Edit1},
        !.localJournalContent[Journal1] = {Edit1}
        ]

InstallFirstCheckpoint ==
    /\ state.phase = "firstEdited"
    /\ state' = [state EXCEPT
        !.phase = "firstInstalled",
        !.writerEditable = FALSE,
        !.localCheckpointID = Checkpoint1,
        !.localCheckpointContent = state.writerLive,
        !.representedJournals = {Journal1},
        !.receiptCheckpoint = Checkpoint1,
        !.receiptContent = state.writerLive,
        !.receiptJournals = {Journal1}
        ]

WriteFirstRetainedClaim ==
    /\ state.phase = "firstInstalled"
    /\ Journal1 \in state.activeClaims
    /\ state' = [state EXCEPT
        !.phase = "firstRetainedWritten",
        !.retainedClaims = @ \cup {Journal1},
        !.retainedCoverage[Journal1] = Checkpoint1
        ]

SynchronizeFirstRetainedClaim ==
    /\ state.phase = "firstRetainedWritten"
    /\ state' = [state EXCEPT
        !.phase = "firstRetained",
        !.syncedRetainedClaims = state.retainedClaims,
        !.syncedRetainedCoverage = state.retainedCoverage
        ]

CrashBeforeFirstRetainedClaimSync ==
    /\ state.phase = "firstRetainedWritten"
    /\ "firstDemotionBeforeSync" \notin state.crashWindowsSeen
    /\ state' = [state EXCEPT
        !.phase = "firstInstalled",
        !.retainedClaims = state.syncedRetainedClaims,
        !.retainedCoverage = state.syncedRetainedCoverage,
        !.representedJournals = {},
        !.receiptCheckpoint = None,
        !.receiptContent = {},
        !.receiptJournals = {},
        !.crashWindowsSeen = @ \cup {"firstDemotionBeforeSync"}
        ]

OpenSecondGeneration ==
    /\ state.phase = "firstRetained"
    /\ Journal1 \in state.syncedRetainedClaims
    /\ state.syncedRetainedCoverage[Journal1] = Checkpoint1
    /\ ~state.localJournalPresent[Journal2]
    /\ state' = [state EXCEPT
        !.phase = "secondOpen",
        !.writerEditable = TRUE,
        !.activeClaims = {Journal2},
        !.localJournalPresent[Journal2] = TRUE,
        !.localJournalContent[Journal2] = {}
        ]

AcknowledgeSecondEdit ==
    /\ state.phase = "secondOpen"
    /\ state.writerEditable
    /\ Journal2 \in state.activeClaims
    /\ state.localJournalPresent[Journal2]
    /\ state' = [state EXCEPT
        !.phase = "secondEdited",
        !.acknowledged = @ \cup {Edit2},
        !.writerLive = @ \cup {Edit2},
        !.localJournalContent[Journal2] = {Edit2}
        ]

InstallSecondCheckpoint ==
    /\ state.phase = "secondEdited"
    /\ state.acknowledged = Edits
    /\ state' = [state EXCEPT
        !.phase = "secondInstalled",
        !.writerEditable = FALSE,
        !.localCheckpointID = Checkpoint2,
        !.localCheckpointContent = state.writerLive,
        !.representedJournals = Journals,
        !.receiptCheckpoint = Checkpoint2,
        !.receiptContent = state.writerLive,
        !.receiptJournals = Journals
        ]

CrashAfterSecondCheckpoint ==
    /\ state.phase = "secondInstalled"
    /\ "secondCheckpointBeforeAdvance" \notin state.crashWindowsSeen
    /\ state' = [state EXCEPT
        !.phase = "recovering",
        !.representedJournals = {},
        !.receiptCheckpoint = None,
        !.receiptContent = {},
        !.receiptJournals = {},
        !.crashWindowsSeen = @ \cup {"secondCheckpointBeforeAdvance"}
        ]

WriteRetainedAdvance ==
    /\ state.phase = "secondInstalled"
    /\ Journal1 \in state.syncedRetainedClaims
    /\ state.syncedRetainedCoverage[Journal1] = Checkpoint1
    /\ state' = [state EXCEPT
        !.phase = "advanceWritten",
        !.retainedCoverage[Journal1] = Checkpoint2
        ]

SynchronizeRetainedAdvance ==
    /\ state.phase = "advanceWritten"
    /\ state' = [state EXCEPT
        !.phase = "secondRecovered",
        !.syncedRetainedCoverage = state.retainedCoverage
        ]

CrashBeforeRetainedAdvanceSync ==
    /\ state.phase = "advanceWritten"
    /\ state.syncedRetainedCoverage[Journal1] = Checkpoint1
    /\ state.retainedCoverage[Journal1] = Checkpoint2
    /\ "retainedAdvanceBeforeSync" \notin state.crashWindowsSeen
    /\ state' = [state EXCEPT
        !.phase = "recovering",
        !.retainedCoverage = state.syncedRetainedCoverage,
        !.representedJournals = {},
        !.receiptCheckpoint = None,
        !.receiptContent = {},
        !.receiptJournals = {},
        !.crashWindowsSeen = @ \cup {"retainedAdvanceBeforeSync"}
        ]

RecoverEqualityOnlyMismatch ==
    /\ state.phase = "recovering"
    /\ Journal1 \in state.syncedRetainedClaims
    /\ state.retainedCoverage[Journal1] # state.localCheckpointID
    /\ state.localJournalContent[Journal1]
        \subseteq state.localCheckpointContent
    /\ state.localJournalContent[Journal2]
        \subseteq state.localCheckpointContent
    /\ state' = [state EXCEPT
        !.phase = "secondRecovered",
        !.representedJournals = Journals
        ]

InstallCleanupCheckpoint ==
    /\ state.phase = "secondRecovered"
    /\ state.representedJournals = Journals
    /\ state' = [state EXCEPT
        !.phase = "cleanupInstalled",
        !.localCheckpointID = Checkpoint3,
        !.localCheckpointContent = state.writerLive,
        !.receiptCheckpoint = Checkpoint3,
        !.receiptContent = state.writerLive,
        !.receiptJournals = Journals,
        !.retainedCoverage[Journal1] = Checkpoint3
        ]

UploadCurrentCheckpoint ==
    /\ state.writerAvailable
    /\ \/ state.serverCheckpointID # state.localCheckpointID
       \/ state.serverCheckpointContent # state.localCheckpointContent
    /\ state' = [state EXCEPT
        !.serverCheckpointID = state.localCheckpointID,
        !.serverCheckpointContent = state.localCheckpointContent,
        !.checkpointEventPending = TRUE
        ]

UploadJournal(journal) ==
    /\ journal \in Journals
    /\ state.writerAvailable
    /\ state.localJournalPresent[journal]
    /\ \/ ~state.serverJournalPresent[journal]
       \/ state.serverJournalContent[journal]
            # state.localJournalContent[journal]
    /\ state' = [state EXCEPT
        !.serverJournalPresent[journal] = TRUE,
        !.serverJournalContent[journal] =
            state.localJournalContent[journal],
        !.journalCreateEventsPending = @ \cup {journal}
        ]

QualifyCleanupCheckpoint ==
    /\ state.phase = "cleanupInstalled"
    /\ state.writerAvailable
    /\ state.serverCheckpointID = state.receiptCheckpoint
    /\ state.serverCheckpointContent = state.receiptContent
    /\ state.localCheckpointContent = state.receiptContent
    /\ state.receiptCheckpoint = Checkpoint3
    /\ state.receiptJournals = Journals
    /\ \A journal \in Journals:
        state.localJournalContent[journal]
            \subseteq state.serverCheckpointContent
    /\ state' = [state EXCEPT
        !.phase = "qualified",
        !.qualifiedCheckpoint = Checkpoint3
        ]

RemoveCoveredLocalJournal(journal) ==
    /\ state.phase = "qualified"
    /\ state.writerAvailable
    /\ journal \in state.receiptJournals
    /\ state.localJournalPresent[journal]
    /\ state.qualifiedCheckpoint = state.receiptCheckpoint
    /\ state.localJournalContent[journal]
        \subseteq state.serverCheckpointContent
    /\ state' = [state EXCEPT
        !.localJournalPresent[journal] = FALSE,
        !.localDeletionRequested = @ \cup {journal},
        !.authorizedServerDeletions = @ \cup {journal}
        ]

CrashAfterLocalJournalRemoval ==
    \* The accepted local removal has already created provider-side work. Its
    \* captured authorization survives this process crash even though the
    \* in-memory receipt does not.
    /\ state.phase = "qualified"
    /\ state.localDeletionRequested # {}
    /\ "localRemovalBeforeServerDeletion" \notin state.crashWindowsSeen
    /\ state' = [state EXCEPT
        !.phase = "postRemovalCrash",
        !.representedJournals = {},
        !.receiptCheckpoint = None,
        !.receiptContent = {},
        !.receiptJournals = {},
        !.qualifiedCheckpoint = None,
        !.crashWindowsSeen = @ \cup {"localRemovalBeforeServerDeletion"}
        ]

AcceptServerJournalDeletion(journal) ==
    /\ journal \in state.localDeletionRequested
    /\ journal \in state.authorizedServerDeletions
    /\ state.serverJournalPresent[journal]
    /\ state.serverCheckpointID = Checkpoint3
    /\ state.serverJournalContent[journal]
        \subseteq state.serverCheckpointContent
    /\ state' = [state EXCEPT
        !.serverJournalPresent[journal] = FALSE,
        !.serverDeletedJournals = @ \cup {journal},
        !.journalDeleteEventsPending = @ \cup {journal}
        ]

FinishCleanup ==
    /\ state.phase = "qualified"
    /\ \A journal \in Journals:
        ~state.localJournalPresent[journal]
    /\ state' = [state EXCEPT !.phase = "cleaned"]

LoseWriterMachine ==
    /\ state.writerAvailable
    /\ state.phase \notin {"firstOpen", "firstEdited"}
    /\ state' = [state EXCEPT
        !.phase = "writerLost",
        !.writerAvailable = FALSE,
        !.writerEditable = FALSE,
        !.unreplicatedAtWriterLoss =
            {edit \in state.acknowledged: ~RemoteRecoverable(edit)},
        !.writerLive = {},
        !.activeClaims = {},
        !.retainedClaims = {},
        !.syncedRetainedClaims = {},
        !.localJournalPresent =
            [journal \in Journals |-> FALSE],
        !.localJournalContent =
            [journal \in Journals |-> {}],
        !.localCheckpointContent = {}
        ]

DeliverCheckpointToReader ==
    /\ state.checkpointEventPending
    /\ state' = [state EXCEPT
        !.checkpointEventPending = FALSE,
        !.readerCheckpointID = state.serverCheckpointID,
        !.readerCheckpointContent = state.serverCheckpointContent,
        !.readerObservedAcknowledged = state.acknowledged,
        !.readerDirty = state.acknowledged
            \ state.readerRepresented # {}
        ]

DeliverJournalToReader(journal) ==
    /\ journal \in state.journalCreateEventsPending
    /\ state.serverJournalPresent[journal]
    /\ state' = [state EXCEPT
        !.journalCreateEventsPending = @ \ {journal},
        !.readerJournalPresent[journal] = TRUE,
        !.readerJournalContent[journal] =
            state.serverJournalContent[journal],
        !.readerObservedAcknowledged = state.acknowledged,
        !.readerDirty = state.acknowledged
            \ state.readerRepresented # {}
        ]

DeliverJournalDeletionToReader(journal) ==
    /\ journal \in state.journalDeleteEventsPending
    /\ state' = [state EXCEPT
        !.journalDeleteEventsPending = @ \ {journal},
        !.readerJournalPresent[journal] = FALSE,
        !.readerObservedAcknowledged = state.acknowledged,
        !.readerDirty = state.acknowledged
            \ state.readerRepresented # {},
        !.reorderedDeletionWitnesses =
            IF ExpectedJournalContent(journal)
                \subseteq state.readerCheckpointContent
            THEN @
            ELSE @ \cup {journal}
        ]

ReconcileReaderEdit(edit) ==
    /\ edit \in Edits \ state.readerRepresented
    /\ \/ edit \in state.readerCheckpointContent
       \/ ReaderJournalEvidence(edit)
    /\ state' = [state EXCEPT
        !.readerRepresented = @ \cup {edit},
        !.readerDirty =
            state.acknowledged
                \ (state.readerRepresented \cup {edit}) # {}
        ]

WriterStep ==
    \/ AcknowledgeFirstEdit
    \/ InstallFirstCheckpoint
    \/ WriteFirstRetainedClaim
    \/ SynchronizeFirstRetainedClaim
    \/ CrashBeforeFirstRetainedClaimSync
    \/ OpenSecondGeneration
    \/ AcknowledgeSecondEdit
    \/ InstallSecondCheckpoint
    \/ CrashAfterSecondCheckpoint
    \/ WriteRetainedAdvance
    \/ SynchronizeRetainedAdvance
    \/ CrashBeforeRetainedAdvanceSync
    \/ RecoverEqualityOnlyMismatch
    \/ InstallCleanupCheckpoint
    \/ QualifyCleanupCheckpoint
    \/ CrashAfterLocalJournalRemoval
    \/ FinishCleanup
    \/ LoseWriterMachine
    \/ \E journal \in Journals: RemoveCoveredLocalJournal(journal)

ProviderStep ==
    \/ UploadCurrentCheckpoint
    \/ \E journal \in Journals:
        UploadJournal(journal)
        \/ AcceptServerJournalDeletion(journal)
        \/ DeliverJournalToReader(journal)
        \/ DeliverJournalDeletionToReader(journal)
    \/ DeliverCheckpointToReader

ReaderStep ==
    \E edit \in Edits: ReconcileReaderEdit(edit)

Next == WriterStep \/ ProviderStep \/ ReaderStep

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state.phase \in Phases
    /\ state.acknowledged \subseteq Edits
    /\ state.writerLive \subseteq Edits
    /\ state.writerEditable \in BOOLEAN
    /\ state.writerAvailable \in BOOLEAN
    /\ state.activeClaims \subseteq Journals
    /\ state.retainedClaims \subseteq Journals
    /\ state.syncedRetainedClaims \subseteq Journals
    /\ state.retainedCoverage
        \in [Journals -> CheckpointIDs \cup {None}]
    /\ state.syncedRetainedCoverage
        \in [Journals -> CheckpointIDs \cup {None}]
    /\ state.localJournalPresent \in [Journals -> BOOLEAN]
    /\ state.localJournalContent \in [Journals -> SUBSET Edits]
    /\ state.localCheckpointID \in CheckpointIDs
    /\ state.localCheckpointContent \subseteq Edits
    /\ state.representedJournals \subseteq Journals
    /\ state.receiptCheckpoint \in CheckpointIDs \cup {None}
    /\ state.receiptContent \subseteq Edits
    /\ state.receiptJournals \subseteq Journals
    /\ state.crashWindowsSeen \subseteq CrashWindows
    /\ state.unreplicatedAtWriterLoss \subseteq Edits
    /\ state.qualifiedCheckpoint \in CheckpointIDs \cup {None}
    /\ state.localDeletionRequested \subseteq Journals
    /\ state.authorizedServerDeletions \subseteq Journals
    /\ state.serverCheckpointID \in CheckpointIDs
    /\ state.serverCheckpointContent \subseteq Edits
    /\ state.serverJournalPresent \in [Journals -> BOOLEAN]
    /\ state.serverJournalContent \in [Journals -> SUBSET Edits]
    /\ state.serverDeletedJournals \subseteq Journals
    /\ state.checkpointEventPending \in BOOLEAN
    /\ state.journalCreateEventsPending \subseteq Journals
    /\ state.journalDeleteEventsPending \subseteq Journals
    /\ state.readerCheckpointID \in CheckpointIDs
    /\ state.readerCheckpointContent \subseteq Edits
    /\ state.readerJournalPresent \in [Journals -> BOOLEAN]
    /\ state.readerJournalContent \in [Journals -> SUBSET Edits]
    /\ state.readerRepresented \subseteq Edits
    /\ state.readerObservedAcknowledged \subseteq Edits
    /\ state.readerDirty \in BOOLEAN
    /\ state.reorderedDeletionWitnesses \subseteq Journals

EveryGuaranteedAcknowledgedEditHasRecoverableEvidence ==
    \A edit \in state.acknowledged \ state.unreplicatedAtWriterLoss:
        Recoverable(edit)

WriterLossExemptionIsExplicit ==
    state.unreplicatedAtWriterLoss # {} => ~state.writerAvailable

ServerDeletionRequiresExactCoveringCheckpoint ==
    \A journal \in state.serverDeletedJournals:
        /\ journal \in state.authorizedServerDeletions
        /\ state.serverCheckpointID = Checkpoint3
        /\ ExpectedJournalContent(journal)
            \subseteq state.serverCheckpointContent

QualificationNamesTheExactCleanupReceipt ==
    state.qualifiedCheckpoint # None =>
        /\ state.qualifiedCheckpoint = state.receiptCheckpoint
        /\ state.qualifiedCheckpoint = state.serverCheckpointID
        /\ state.serverCheckpointContent = state.receiptContent
        /\ state.receiptJournals = Journals

ReorderedDeletionCannotLoseItsJournalEdit ==
    \A journal \in state.reorderedDeletionWitnesses:
        \A edit \in ExpectedJournalContent(journal): Recoverable(edit)

ReaderObservedOmissionRemainsVisible ==
    \A edit \in state.readerObservedAcknowledged:
        /\ edit \notin state.readerRepresented
        /\ edit \notin state.readerCheckpointContent
        /\ ~ReaderJournalEvidence(edit)
        => state.readerDirty

=============================================================================
