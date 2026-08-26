-------------------- MODULE CrossMachineDurability -----------------------
EXTENDS FiniteSets, Naturals

\* Glue model for the distributed boundary between the detailed one-host
\* journal/quit/startup models and the reconciliation models. It deliberately
\* contains one acknowledged edit and two distinguished Macs. Local replicas
\* and current-host preferences are host-indexed; provider authority is
\* separate. Cross-file provider events may be delivered in any order.

CONSTANTS
    Hosts, WriterHost, ReaderHost,
    Journals, WriterJournal, ReaderJournal,
    CheckpointIDs, InitialCheckpoint, NewCheckpoint,
    Edit, None

ASSUME
    /\ Hosts = {WriterHost, ReaderHost}
    /\ WriterHost # ReaderHost
    /\ Journals = {WriterJournal, ReaderJournal}
    /\ WriterJournal # ReaderJournal
    /\ CheckpointIDs = {InitialCheckpoint, NewCheckpoint}
    /\ InitialCheckpoint # NewCheckpoint
    /\ None \notin Hosts
    /\ None \notin Journals
    /\ None \notin CheckpointIDs
    /\ Edit # None

VARIABLE state

vars == <<state>>

Events == {"checkpoint", "journalCreate", "journalDelete", "note"}
Phases == {"running", "closed", "checking"}
EditSet == {Edit}

OwnJournal(host) ==
    IF host = WriterHost THEN WriterJournal ELSE ReaderJournal

Represented(host) ==
    \/ Edit \in state.live[host]
    \/ Edit \in state.conflicts[host]

LocalEditEvidence(host) ==
    \/ /\ state.localWriterJournalPresent[host]
       /\ Edit \in state.localWriterJournalContent[host]
    \/ Edit \in state.localCheckpointContent[host]
    \/ Edit \in state.localNoteContent[host]
    \/ Represented(host)

ServerEditEvidence ==
    \/ /\ state.serverWriterJournalPresent
       /\ Edit \in state.serverWriterJournalContent
    \/ Edit \in state.serverCheckpointContent
    \/ Edit \in state.serverNoteContent

EditRecoverable ==
    ServerEditEvidence
    \/ \E host \in Hosts: LocalEditEvidence(host)

MandatoryOwnedJournalCovered(host) ==
    \/ host # WriterHost
    \/ ~state.localWriterJournalPresent[host]
    \/ state.localWriterJournalContent[host]
        \subseteq state.localCheckpointContent[host]

HostPreferencesUnchangedExcept(host) ==
    \A other \in Hosts \ {host}:
        /\ state'.activeClaims[other] = state.activeClaims[other]
        /\ state'.syncedActiveClaims[other]
            = state.syncedActiveClaims[other]
        /\ state'.retainedClaims[other] = state.retainedClaims[other]
        /\ state'.syncedRetainedClaims[other]
            = state.syncedRetainedClaims[other]
        /\ state'.retainedCoverage[other]
            = state.retainedCoverage[other]
        /\ state'.syncedRetainedCoverage[other]
            = state.syncedRetainedCoverage[other]

AllPreferencesUnchanged ==
    /\ state'.activeClaims = state.activeClaims
    /\ state'.syncedActiveClaims = state.syncedActiveClaims
    /\ state'.retainedClaims = state.retainedClaims
    /\ state'.syncedRetainedClaims = state.syncedRetainedClaims
    /\ state'.retainedCoverage = state.retainedCoverage
    /\ state'.syncedRetainedCoverage = state.syncedRetainedCoverage

Init ==
    state = [
        editAcknowledged |-> FALSE,
        phase |-> [host \in Hosts |-> "running"],
        editable |-> [host \in Hosts |-> TRUE],
        offline |-> [host \in Hosts |-> FALSE],
        dirty |-> [host \in Hosts |-> FALSE],
        live |-> [host \in Hosts |-> {}],
        conflicts |-> [host \in Hosts |-> {}],

        \* Each Mac has an unrelated current-host active claim. Only the
        \* writer's journal participates in this edit's shared lifecycle; the
        \* reader claim is a non-vacuous sentinel for preference isolation.
        activeClaims |-> [host \in Hosts |-> {OwnJournal(host)}],
        syncedActiveClaims |-> [host \in Hosts |-> {OwnJournal(host)}],
        retainedClaims |-> [host \in Hosts |-> {}],
        syncedRetainedClaims |-> [host \in Hosts |-> {}],
        retainedCoverage |-> [host \in Hosts |-> None],
        syncedRetainedCoverage |-> [host \in Hosts |-> None],

        localWriterJournalPresent |-> [host \in Hosts |->
            host = WriterHost],
        localWriterJournalContent |-> [host \in Hosts |-> {}],
        localJournalGeneration |-> [host \in Hosts |->
            IF host = WriterHost THEN 1 ELSE 0],
        localCheckpointID |-> [host \in Hosts |-> InitialCheckpoint],
        localCheckpointContent |-> [host \in Hosts |-> {}],
        localCheckpointGeneration |-> [host \in Hosts |-> 0],
        localNoteContent |-> [host \in Hosts |-> {}],
        localNoteGeneration |-> [host \in Hosts |-> 0],
        noteWritePending |-> FALSE,

        receiptCheckpoint |-> [host \in Hosts |-> None],
        receiptMembers |-> [host \in Hosts |-> {}],
        uploadQualified |-> [host \in Hosts |-> FALSE],

        serverCheckpointID |-> InitialCheckpoint,
        serverCheckpointContent |-> {},
        serverCheckpointGeneration |-> 0,
        serverWriterJournalPresent |-> FALSE,
        serverWriterJournalContent |-> {},
        serverWriterJournalEverUploaded |-> FALSE,
        serverWriterJournalDeleteAccepted |-> FALSE,
        serverNoteContent |-> {},
        serverNoteGeneration |-> 0,
        deleteRequested |-> FALSE,

        pendingEvents |-> [host \in Hosts |-> {}],
        observedEvents |-> [host \in Hosts |-> {}],
        reorderedDeleteObserved |-> FALSE
        ]

AcknowledgeWriterEdit(host) ==
    /\ host = WriterHost
    /\ state.phase[host] = "running"
    /\ state.editable[host]
    /\ ~state.editAcknowledged
    /\ state.localWriterJournalPresent[host]
    /\ WriterJournal \in state.syncedActiveClaims[host]
    /\ state' = [state EXCEPT
        !.editAcknowledged = TRUE,
        !.live[host] = @ \cup {Edit},
        !.localWriterJournalContent[host] = @ \cup {Edit},
        !.noteWritePending = TRUE
        ]

SettleWriterNote(host) ==
    /\ host = WriterHost
    /\ state.noteWritePending
    /\ state.editAcknowledged
    /\ state' = [state EXCEPT
        !.localNoteContent[host] = @ \cup {Edit},
        !.localNoteGeneration[host] = 1,
        !.noteWritePending = FALSE
        ]

InstallWriterCheckpoint(host) ==
    /\ host = WriterHost
    /\ state.editAcknowledged
    /\ ~state.noteWritePending
    /\ Edit \in state.localNoteContent[host]
    /\ Edit \in state.localWriterJournalContent[host]
    /\ state.receiptCheckpoint[host] = None
    /\ state' = [state EXCEPT
        !.localCheckpointID[host] = NewCheckpoint,
        !.localCheckpointContent[host] = state.live[host],
        !.localCheckpointGeneration[host] = 1,
        !.receiptCheckpoint[host] = NewCheckpoint,
        !.receiptMembers[host] =
            IF state.localWriterJournalContent[host]
                \subseteq state.live[host]
            THEN {WriterJournal}
            ELSE {}
        ]

QualifyExactCheckpointUpload(host) ==
    /\ host = WriterHost
    /\ ~state.uploadQualified[host]
    /\ state.receiptCheckpoint[host] # None
    /\ state.serverCheckpointID = state.receiptCheckpoint[host]
    /\ state.serverCheckpointContent
        = state.localCheckpointContent[host]
    /\ WriterJournal \in state.receiptMembers[host]
    /\ state.localWriterJournalContent[host]
        \subseteq state.serverCheckpointContent
    /\ state' = [state EXCEPT !.uploadQualified[host] = TRUE]

WriteRetainedClaim(host) ==
    /\ host = WriterHost
    /\ ~state.uploadQualified[host]
    /\ state.receiptCheckpoint[host] # None
    /\ WriterJournal \in state.activeClaims[host]
    /\ WriterJournal \notin state.retainedClaims[host]
    /\ state' = [state EXCEPT
        !.retainedClaims[host] = @ \cup {WriterJournal},
        !.retainedCoverage[host] = state.receiptCheckpoint[host]
        ]

SynchronizeRetainedPreferences(host) ==
    /\ \/ state.syncedRetainedClaims[host]
            # state.retainedClaims[host]
       \/ state.syncedRetainedCoverage[host]
            # state.retainedCoverage[host]
    /\ state' = [state EXCEPT
        !.syncedRetainedClaims[host] = state.retainedClaims[host],
        !.syncedRetainedCoverage[host] = state.retainedCoverage[host]
        ]

RemoveDemotedActiveClaim(host) ==
    /\ host = WriterHost
    /\ WriterJournal \in state.activeClaims[host]
    /\ WriterJournal \in state.syncedRetainedClaims[host]
    /\ state.syncedRetainedCoverage[host]
        = state.receiptCheckpoint[host]
    /\ state' = [state EXCEPT
        !.activeClaims[host] = @ \ {WriterJournal}
        ]

SynchronizeActivePreferences(host) ==
    /\ state.syncedActiveClaims[host] # state.activeClaims[host]
    /\ state' = [state EXCEPT
        !.syncedActiveClaims[host] = state.activeClaims[host]
        ]

RemoveLocalWriterJournal(host) ==
    /\ host = WriterHost
    /\ state.uploadQualified[host]
    /\ state.localWriterJournalPresent[host]
    /\ WriterJournal \in state.receiptMembers[host]
    /\ state.localWriterJournalContent[host]
        \subseteq state.serverCheckpointContent
    /\ state' = [state EXCEPT
        !.localWriterJournalPresent[host] = FALSE,
        !.localJournalGeneration[host] = 2,
        !.deleteRequested = TRUE
        ]

ClearDeletedWriterClaims(host) ==
    /\ host = WriterHost
    /\ state.deleteRequested
    /\ ~state.localWriterJournalPresent[host]
    /\ WriterJournal \in
        (state.activeClaims[host] \cup state.retainedClaims[host])
    /\ state' = [state EXCEPT
        !.activeClaims[host] = @ \ {WriterJournal},
        !.retainedClaims[host] = @ \ {WriterJournal},
        !.retainedCoverage[host] = None
        ]

BeginStartup(host) ==
    /\ state.phase[host] = "closed"
    /\ state' = [state EXCEPT !.phase[host] = "checking"]

StartFromCurrentCheckpoint(host) ==
    /\ state.phase[host] = "checking"
    /\ MandatoryOwnedJournalCovered(host)
    /\ state.localCheckpointID[host] = state.serverCheckpointID
    /\ state.localCheckpointContent[host]
        = state.serverCheckpointContent
    /\ state.localCheckpointGeneration[host]
        = state.serverCheckpointGeneration
    /\ state' = [state EXCEPT
        !.phase[host] = "running",
        !.editable[host] = TRUE,
        !.offline[host] = FALSE,
        !.live[host] = state.localCheckpointContent[host],
        !.dirty[host] =
            IF state.observedEvents[host] # {}
                /\ Edit \notin state.localCheckpointContent[host]
            THEN TRUE ELSE @
        ]

StartOfflineFromStaleCheckpoint(host) ==
    /\ state.phase[host] = "checking"
    /\ MandatoryOwnedJournalCovered(host)
    /\ \/ state.localCheckpointID[host] # state.serverCheckpointID
       \/ state.localCheckpointContent[host]
            # state.serverCheckpointContent
       \/ state.localCheckpointGeneration[host]
            # state.serverCheckpointGeneration
    /\ state' = [state EXCEPT
        !.phase[host] = "running",
        !.editable[host] = TRUE,
        !.offline[host] = TRUE,
        !.dirty[host] = TRUE,
        !.live[host] = state.localCheckpointContent[host]
        ]

MergeDeliveredEdit(host) ==
    /\ state.phase[host] = "running"
    /\ state.editable[host]
    /\ Edit \in state.localNoteContent[host]
    /\ ~Represented(host)
    /\ state' = [state EXCEPT
        !.live[host] = @ \cup {Edit},
        !.dirty[host] = FALSE,
        !.offline[host] = FALSE
        ]

PreserveDeliveredEditAsConflict(host) ==
    /\ state.phase[host] = "running"
    /\ state.editable[host]
    /\ Edit \in state.localNoteContent[host]
    /\ ~Represented(host)
    /\ state' = [state EXCEPT
        !.conflicts[host] = @ \cup {Edit},
        !.dirty[host] = FALSE,
        !.offline[host] = FALSE
        ]

ReconcileDeliveredEdit(host) ==
    MergeDeliveredEdit(host) \/ PreserveDeliveredEditAsConflict(host)

CrashHost(host) ==
    /\ state.phase[host] # "closed"
    /\ state' = [state EXCEPT
        !.phase[host] = "closed",
        !.editable[host] = FALSE,
        !.offline[host] = FALSE,
        !.live[host] = state.localCheckpointContent[host],
        !.activeClaims[host] = state.syncedActiveClaims[host],
        !.retainedClaims[host] = state.syncedRetainedClaims[host],
        !.retainedCoverage[host]
            = state.syncedRetainedCoverage[host]
        ]

UploadWriterJournal ==
    /\ state.editAcknowledged
    /\ ~state.deleteRequested
    /\ ~state.serverWriterJournalEverUploaded
    /\ Edit \in state.localWriterJournalContent[WriterHost]
    /\ state' = [state EXCEPT
        !.serverWriterJournalPresent = TRUE,
        !.serverWriterJournalContent =
            state.localWriterJournalContent[WriterHost],
        !.serverWriterJournalEverUploaded = TRUE,
        !.pendingEvents = [host \in Hosts |->
            state.pendingEvents[host] \cup {"journalCreate"}]
        ]

UploadSettledNote ==
    /\ Edit \in state.localNoteContent[WriterHost]
    /\ Edit \notin state.serverNoteContent
    /\ state' = [state EXCEPT
        !.serverNoteContent = @ \cup {Edit},
        !.serverNoteGeneration = 1,
        !.pendingEvents = [host \in Hosts |->
            state.pendingEvents[host] \cup {"note"}]
        ]

UploadWriterCheckpoint ==
    /\ state.receiptCheckpoint[WriterHost] = NewCheckpoint
    /\ WriterJournal \in state.receiptMembers[WriterHost]
    /\ state.serverCheckpointID # NewCheckpoint
    /\ state' = [state EXCEPT
        !.serverCheckpointID = NewCheckpoint,
        !.serverCheckpointContent =
            state.localCheckpointContent[WriterHost],
        !.serverCheckpointGeneration = 1,
        !.pendingEvents = [host \in Hosts |->
            state.pendingEvents[host] \cup {"checkpoint"}]
        ]

AcceptServerJournalDeletion ==
    /\ state.deleteRequested
    /\ ~state.serverWriterJournalDeleteAccepted
    /\ state.uploadQualified[WriterHost]
    /\ state.serverCheckpointID
        = state.receiptCheckpoint[WriterHost]
    /\ state.localWriterJournalContent[WriterHost]
        \subseteq state.serverCheckpointContent
    /\ state' = [state EXCEPT
        !.serverWriterJournalPresent = FALSE,
        !.serverWriterJournalDeleteAccepted = TRUE,
        !.pendingEvents = [host \in Hosts |->
            state.pendingEvents[host] \cup {"journalDelete"}]
        ]

DeliverCheckpoint(host) ==
    /\ "checkpoint" \in state.pendingEvents[host]
    /\ state' = [state EXCEPT
        !.pendingEvents[host] = @ \ {"checkpoint"},
        !.observedEvents[host] = @ \cup {"checkpoint"},
        !.localCheckpointID[host] = state.serverCheckpointID,
        !.localCheckpointContent[host] = state.serverCheckpointContent,
        !.localCheckpointGeneration[host]
            = state.serverCheckpointGeneration,
        !.dirty[host] = IF state.editable[host] /\ ~Represented(host)
            THEN TRUE ELSE @
        ]

DeliverJournalCreate(host) ==
    /\ "journalCreate" \in state.pendingEvents[host]
    /\ state' = [state EXCEPT
        !.pendingEvents[host] = @ \ {"journalCreate"},
        !.observedEvents[host] = @ \cup {"journalCreate"},
        !.localWriterJournalPresent[host] =
            IF state.localJournalGeneration[host] < 1 THEN TRUE ELSE @,
        !.localWriterJournalContent[host] =
            IF state.localJournalGeneration[host] < 1
            THEN state.serverWriterJournalContent ELSE @,
        !.localJournalGeneration[host] =
            IF state.localJournalGeneration[host] < 1 THEN 1 ELSE @,
        !.dirty[host] = IF state.editable[host] /\ ~Represented(host)
            THEN TRUE ELSE @
        ]

DeliverJournalDelete(host) ==
    /\ "journalDelete" \in state.pendingEvents[host]
    /\ state' = [state EXCEPT
        !.pendingEvents[host] = @ \ {"journalDelete"},
        !.observedEvents[host] = @ \cup {"journalDelete"},
        !.localWriterJournalPresent[host] = FALSE,
        !.localJournalGeneration[host] = 2,
        !.dirty[host] = IF state.editable[host] /\ ~Represented(host)
            THEN TRUE ELSE @,
        !.reorderedDeleteObserved =
            @ \/ /\ host = ReaderHost
                  /\ "checkpoint" \in state.pendingEvents[host]
                  /\ state.localCheckpointGeneration[host] = 0
        ]

DeliverNote(host) ==
    /\ "note" \in state.pendingEvents[host]
    /\ state' = [state EXCEPT
        !.pendingEvents[host] = @ \ {"note"},
        !.observedEvents[host] = @ \cup {"note"},
        !.localNoteContent[host] = state.serverNoteContent,
        !.localNoteGeneration[host] = state.serverNoteGeneration,
        !.dirty[host] = IF state.editable[host] /\ ~Represented(host)
            THEN TRUE ELSE @
        ]

HostStep(host) ==
    \/ AcknowledgeWriterEdit(host)
    \/ SettleWriterNote(host)
    \/ InstallWriterCheckpoint(host)
    \/ QualifyExactCheckpointUpload(host)
    \/ WriteRetainedClaim(host)
    \/ SynchronizeRetainedPreferences(host)
    \/ RemoveDemotedActiveClaim(host)
    \/ SynchronizeActivePreferences(host)
    \/ RemoveLocalWriterJournal(host)
    \/ ClearDeletedWriterClaims(host)
    \/ BeginStartup(host)
    \/ StartFromCurrentCheckpoint(host)
    \/ StartOfflineFromStaleCheckpoint(host)
    \/ ReconcileDeliveredEdit(host)
    \/ CrashHost(host)

ProviderStep ==
    \/ UploadWriterJournal
    \/ UploadSettledNote
    \/ UploadWriterCheckpoint
    \/ AcceptServerJournalDeletion
    \/ \E host \in Hosts:
        DeliverCheckpoint(host)
        \/ DeliverJournalCreate(host)
        \/ DeliverJournalDelete(host)
        \/ DeliverNote(host)

Next == ProviderStep \/ \E host \in Hosts: HostStep(host)

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(SettleWriterNote(WriterHost))
    /\ WF_vars(ReconcileDeliveredEdit(ReaderHost))

TypeOK ==
    /\ state.editAcknowledged \in BOOLEAN
    /\ state.phase \in [Hosts -> Phases]
    /\ state.editable \in [Hosts -> BOOLEAN]
    /\ state.offline \in [Hosts -> BOOLEAN]
    /\ state.dirty \in [Hosts -> BOOLEAN]
    /\ state.live \in [Hosts -> SUBSET EditSet]
    /\ state.conflicts \in [Hosts -> SUBSET EditSet]
    /\ state.activeClaims \in [Hosts -> SUBSET Journals]
    /\ state.syncedActiveClaims \in [Hosts -> SUBSET Journals]
    /\ state.retainedClaims \in [Hosts -> SUBSET Journals]
    /\ state.syncedRetainedClaims \in [Hosts -> SUBSET Journals]
    /\ state.retainedCoverage
        \in [Hosts -> CheckpointIDs \cup {None}]
    /\ state.syncedRetainedCoverage
        \in [Hosts -> CheckpointIDs \cup {None}]
    /\ state.localWriterJournalPresent \in [Hosts -> BOOLEAN]
    /\ state.localWriterJournalContent \in [Hosts -> SUBSET EditSet]
    /\ state.localJournalGeneration \in [Hosts -> 0..2]
    /\ state.localCheckpointID \in [Hosts -> CheckpointIDs]
    /\ state.localCheckpointContent \in [Hosts -> SUBSET EditSet]
    /\ state.localCheckpointGeneration \in [Hosts -> 0..1]
    /\ state.localNoteContent \in [Hosts -> SUBSET EditSet]
    /\ state.localNoteGeneration \in [Hosts -> 0..1]
    /\ state.noteWritePending \in BOOLEAN
    /\ state.receiptCheckpoint
        \in [Hosts -> CheckpointIDs \cup {None}]
    /\ state.receiptMembers \in [Hosts -> SUBSET Journals]
    /\ state.uploadQualified \in [Hosts -> BOOLEAN]
    /\ state.serverCheckpointID \in CheckpointIDs
    /\ state.serverCheckpointContent \subseteq EditSet
    /\ state.serverCheckpointGeneration \in 0..1
    /\ state.serverWriterJournalPresent \in BOOLEAN
    /\ state.serverWriterJournalContent \subseteq EditSet
    /\ state.serverWriterJournalEverUploaded \in BOOLEAN
    /\ state.serverWriterJournalDeleteAccepted \in BOOLEAN
    /\ state.serverNoteContent \subseteq EditSet
    /\ state.serverNoteGeneration \in 0..1
    /\ state.deleteRequested \in BOOLEAN
    /\ state.pendingEvents \in [Hosts -> SUBSET Events]
    /\ state.observedEvents \in [Hosts -> SUBSET Events]
    /\ state.reorderedDeleteObserved \in BOOLEAN

AcknowledgedEditAlwaysHasRecoverableEvidence ==
    state.editAcknowledged => EditRecoverable

ServerDeletionRequiresUploadedCheckpointCoverage ==
    state.serverWriterJournalDeleteAccepted =>
        /\ state.serverCheckpointID = NewCheckpoint
        /\ Edit \in state.serverCheckpointContent
        /\ state.receiptCheckpoint[WriterHost] = NewCheckpoint
        /\ WriterJournal \in state.receiptMembers[WriterHost]

QualificationNamesExactServerCheckpoint ==
    state.uploadQualified[WriterHost] =>
        /\ state.receiptCheckpoint[WriterHost] # None
        /\ state.serverCheckpointID
            = state.receiptCheckpoint[WriterHost]
        /\ state.serverCheckpointContent
            = state.localCheckpointContent[WriterHost]
        /\ state.localWriterJournalContent[WriterHost]
            \subseteq state.serverCheckpointContent

WriterClaimDisappearsOnlyAfterSafeCleanup ==
    /\ WriterJournal \notin state.activeClaims[WriterHost]
    /\ WriterJournal \notin state.syncedActiveClaims[WriterHost]
    /\ WriterJournal \notin state.retainedClaims[WriterHost]
    /\ WriterJournal \notin state.syncedRetainedClaims[WriterHost]
    => /\ ~state.localWriterJournalPresent[WriterHost]
       /\ state.uploadQualified[WriterHost]
       /\ Edit \in state.serverCheckpointContent

RetainedClaimsHaveExactLocalCoverage ==
    \A host \in Hosts:
        OwnJournal(host) \in state.syncedRetainedClaims[host] =>
            /\ state.syncedRetainedCoverage[host] # None
            /\ state.syncedRetainedCoverage[host]
                = state.receiptCheckpoint[host]

ClaimsNeverTransferBetweenHosts ==
    \A host \in Hosts:
        state.activeClaims[host] \cup state.syncedActiveClaims[host]
            \cup state.retainedClaims[host]
            \cup state.syncedRetainedClaims[host]
            \subseteq {OwnJournal(host)}

ReaderPreferenceSentinelSurvivesWriterLifecycle ==
    /\ ReaderJournal \in state.activeClaims[ReaderHost]
    /\ ReaderJournal \in state.syncedActiveClaims[ReaderHost]

ObservedOmissionRemainsRecoverableAndVisible ==
    \A host \in Hosts:
        /\ state.editAcknowledged
        /\ state.observedEvents[host] # {}
        /\ ~Represented(host)
        => /\ EditRecoverable
           /\ (~state.editable[host] \/ state.dirty[host])

OfflineEditingRemainsVisibleAndPending ==
    \A host \in Hosts:
        state.offline[host] =>
            /\ state.editable[host]
            /\ state.dirty[host]

DeleteBeforeCheckpointDeliveryCannotLoseTheEdit ==
    state.reorderedDeleteObserved =>
        /\ state.serverWriterJournalDeleteAccepted
        /\ Edit \in state.serverCheckpointContent
        /\ EditRecoverable
        /\ ~state.editable[ReaderHost]
            \/ state.dirty[ReaderHost]
            \/ Represented(ReaderHost)

HostStepsPreserveForeignPreferences ==
    [][\A host \in Hosts:
        HostStep(host) => HostPreferencesUnchangedExcept(host)]_vars

ProviderStepsPreserveAllHostPreferences ==
    [][ProviderStep => AllPreferencesUnchanged]_vars

FairNoteDelivery ==
    /\ WF_vars(UploadSettledNote)
    /\ WF_vars(DeliverNote(ReaderHost))

SpecWithFairNoteDelivery == Spec /\ FairNoteDelivery

FairDeliveryReachesReaderReplica ==
    (state.editAcknowledged /\ state.editable[ReaderHost])
    ~> (\/ ~state.editable[ReaderHost]
        \/ Edit \in state.localNoteContent[ReaderHost])

RemoteConvergence ==
    (state.editAcknowledged /\ state.editable[ReaderHost])
    ~> (~state.editable[ReaderHost] \/ Represented(ReaderHost))

=============================================================================
