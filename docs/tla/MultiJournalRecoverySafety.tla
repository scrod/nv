------------------ MODULE MultiJournalRecoverySafety ------------------
EXTENDS FiniteSets, Naturals, Sequences

\* JournalRecoverySafety proves byte-prefix and single-journal replay rules.
\* This companion spends its state budget on one ordered two-record journal,
\* one independently interleaved record, and two notes. There is deliberately
\* no cross-journal LSN order.

CONSTANTS
    Journals, Journal1, Journal2,
    Records, Record1, Record2, Record3,
    Notes, NoteX, NoteY,
    Values, XBase, XUpdate1, XUpdate2, YBase, YUpdate, Deleted, None

ASSUME
    /\ Journals = {Journal1, Journal2}
    /\ Journal1 # Journal2
    /\ Records = {Record1, Record2, Record3}
    /\ Cardinality(Records) = 3
    /\ Notes = {NoteX, NoteY}
    /\ NoteX # NoteY
    /\ {XBase, XUpdate1, XUpdate2, YBase, YUpdate, Deleted}
        \subseteq Values
    /\ Cardinality({XBase, XUpdate1, XUpdate2,
                     YBase, YUpdate, Deleted}) = 6
    /\ None \notin Journals

VARIABLE state

vars == <<state>>

Scenarios == {
    "independentNotes", "concurrentUpdates", "deleteUpdateRace",
    "baseMismatch", "withinDeleteThenUpdate",
    "withinUpdateThenDelete", "duplicate"
}
RecordKinds == {"update", "delete"}
Dispositions == {"pending", "applied", "conflict", "duplicate", "rejected"}
Phases == {"replaying", "recovered", "verified", "qualified", "cleaned"}

RecordJournal(record) ==
    IF record \in {Record1, Record2} THEN Journal1 ELSE Journal2

PriorRecords(record) ==
    IF record = Record2 THEN {Record1} ELSE {}

RecordNote(scenario, record) ==
    CASE record = Record2
            /\ scenario \notin {
                "withinDeleteThenUpdate", "withinUpdateThenDelete"
            } -> NoteY
      [] record = Record3
            /\ scenario \in {
                "withinDeleteThenUpdate", "withinUpdateThenDelete"
            } -> NoteY
      [] OTHER -> NoteX

RecordKind(scenario, record) ==
    CASE scenario \in {"deleteUpdateRace", "withinDeleteThenUpdate"}
            /\ record = Record1 -> "delete"
      [] scenario \in {"baseMismatch", "withinUpdateThenDelete"}
            /\ record = Record2 -> "delete"
      [] OTHER -> "update"

RecordValue(scenario, record) ==
    CASE RecordKind(scenario, record) = "delete" -> Deleted
      [] RecordNote(scenario, record) = NoteY -> YUpdate
      [] record = Record3
            /\ scenario \in {"concurrentUpdates", "baseMismatch"}
            -> XUpdate2
      [] record = Record3 /\ scenario = "independentNotes" -> XBase
      [] OTHER -> XUpdate1

RecordBaseMatches(scenario, record) ==
    scenario # "baseMismatch"

BaseValue(note) == IF note = NoteX THEN XBase ELSE YBase

InitialLive == [note \in Notes |-> BaseValue(note)]

JournalRecords(journal) ==
    {record \in Records: RecordJournal(record) = journal}

LaterAppliedRecord(record) ==
    \E later \in state.processedRecords:
        /\ record \in PriorRecords(later)
        /\ RecordJournal(later) = RecordJournal(record)
        /\ RecordNote(state.scenario, later) =
            RecordNote(state.scenario, record)
        /\ state.dispositions[later] \in {"applied", "duplicate"}

LiveValues == {state.live[note]: note \in Notes}

UpdateRepresented(record) ==
    \/ RecordValue(state.scenario, record) \in LiveValues
    \/ RecordValue(state.scenario, record) \in state.conflicts
    \/ state.dispositions[record] = "duplicate"
    \/ record \in state.durableCoverage
    \/ LaterAppliedRecord(record)

Init ==
    \E scenario \in Scenarios:
        state = [
            scenario |-> scenario,
            phase |-> "replaying",
            pendingRecords |-> Records,
            processedRecords |-> {},
            dispositions |-> [record \in Records |-> "pending"],
            replayOrder |-> <<>>,
            live |-> InitialLive,
            canonicalJournal |-> [note \in Notes |-> None],
            conflicts |-> {},
            journalExists |-> Journals,
            durableLive |-> InitialLive,
            durableConflicts |-> {},
            durableCoverage |-> {},
            receiptJournals |-> {},
            qualified |-> FALSE,
            deletedJournals |-> {}
        ]

ReplayRecord(record) ==
    /\ state.phase = "replaying"
    /\ record \in state.pendingRecords
    /\ PriorRecords(record) \subseteq state.processedRecords
    /\ LET note == RecordNote(state.scenario, record)
           kind == RecordKind(state.scenario, record)
           value == RecordValue(state.scenario, record)
           exactBase == RecordBaseMatches(state.scenario, record)
           duplicate ==
                \/ value \in LiveValues
                \/ value \in state.conflicts
           canApply ==
                /\ exactBase
                /\ \/ state.live[note] = BaseValue(note)
                   \/ state.canonicalJournal[note] = RecordJournal(record)
           disposition ==
                IF duplicate THEN "duplicate"
                ELSE IF kind = "update" /\ canApply THEN "applied"
                ELSE IF kind = "update" THEN "conflict"
                ELSE IF canApply THEN "applied"
                ELSE "rejected"
       IN state' = [state EXCEPT
            !.pendingRecords = @ \ {record},
            !.processedRecords = @ \cup {record},
            !.dispositions[record] = disposition,
            !.replayOrder = Append(@, record),
            !.live[note] =
                IF disposition = "applied" THEN value ELSE @,
            !.canonicalJournal[note] =
                IF disposition = "applied"
                THEN RecordJournal(record) ELSE @,
            !.conflicts =
                IF disposition = "conflict"
                THEN @ \cup {value} ELSE @
        ]

FinishReplay ==
    /\ state.phase = "replaying"
    /\ state.pendingRecords = {}
    /\ state' = [state EXCEPT !.phase = "recovered"]

InstallVerifiedRecoveryCheckpoint ==
    /\ state.phase = "recovered"
    /\ state' = [state EXCEPT
        !.phase = "verified",
        !.durableLive = state.live,
        !.durableConflicts = state.conflicts,
        !.durableCoverage = state.processedRecords,
        !.receiptJournals =
            {journal \in Journals:
                JournalRecords(journal) \subseteq state.processedRecords}
        ]

QualifyRecoveryCheckpoint ==
    /\ state.phase = "verified"
    /\ state.durableCoverage = Records
    /\ state.receiptJournals = Journals
    /\ state' = [state EXCEPT
        !.phase = "qualified",
        !.qualified = TRUE
        ]

DeleteCoveredJournal(journal) ==
    /\ state.phase = "qualified"
    /\ state.qualified
    /\ journal \in state.journalExists
    /\ journal \in state.receiptJournals
    /\ JournalRecords(journal) \subseteq state.durableCoverage
    /\ state' = [state EXCEPT
        !.journalExists = @ \ {journal},
        !.deletedJournals = @ \cup {journal}
        ]

FinishCleanup ==
    /\ state.phase = "qualified"
    /\ state.journalExists = {}
    /\ state' = [state EXCEPT !.phase = "cleaned"]

Next ==
    \/ \E record \in Records: ReplayRecord(record)
    \/ FinishReplay
    \/ InstallVerifiedRecoveryCheckpoint
    \/ QualifyRecoveryCheckpoint
    \/ \E journal \in Journals: DeleteCoveredJournal(journal)
    \/ FinishCleanup

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(FinishReplay)

TypeOK ==
    /\ state.scenario \in Scenarios
    /\ state.phase \in Phases
    /\ state.pendingRecords \subseteq Records
    /\ state.processedRecords \subseteq Records
    /\ state.dispositions \in [Records -> Dispositions]
    /\ state.replayOrder \in Seq(Records)
    /\ state.live \in [Notes -> Values]
    /\ state.canonicalJournal
        \in [Notes -> Journals \cup {None}]
    /\ state.conflicts \subseteq Values
    /\ state.journalExists \subseteq Journals
    /\ state.durableLive \in [Notes -> Values]
    /\ state.durableConflicts \subseteq Values
    /\ state.durableCoverage \subseteq Records
    /\ state.receiptJournals \subseteq Journals
    /\ state.qualified \in BOOLEAN
    /\ state.deletedJournals \subseteq Journals

EveryRecordHasExactlyOneDisposition ==
    /\ state.pendingRecords \cap state.processedRecords = {}
    /\ state.pendingRecords \cup state.processedRecords = Records
    /\ \A record \in state.pendingRecords:
        state.dispositions[record] = "pending"
    /\ \A record \in state.processedRecords:
        state.dispositions[record] # "pending"

EveryRecordRemainsJournalBackedOrCheckpointCovered ==
    \A record \in Records:
        \/ /\ RecordJournal(record) \in state.journalExists
           /\ \/ record \in state.pendingRecords
              \/ record \in state.processedRecords
        \/ record \in state.durableCoverage

EveryValidUpdateRemainsRecoverable ==
    \A record \in Records:
        RecordKind(state.scenario, record) = "update" =>
            \/ /\ record \in state.pendingRecords
               /\ RecordJournal(record) \in state.journalExists
            \/ UpdateRepresented(record)

CompletedRecoveryPreservesEveryUpdateIndependentOfOrder ==
    state.phase # "replaying" =>
        \A record \in Records:
            RecordKind(state.scenario, record) = "update" =>
                UpdateRepresented(record)

IndependentNoteUpdatesBothSurvive ==
    /\ state.scenario = "independentNotes"
    /\ state.phase # "replaying"
    => /\ XUpdate1 \in LiveValues \cup state.conflicts
       /\ YUpdate \in LiveValues \cup state.conflicts

DeleteUpdateRaceNeverLosesTheUpdate ==
    /\ state.scenario = "deleteUpdateRace"
    /\ state.phase # "replaying"
    => XUpdate1 \in LiveValues \cup state.conflicts

BaseMismatchCannotOverwriteOrDelete ==
    state.scenario = "baseMismatch" =>
        /\ state.live[NoteX] = XBase
        /\ state.live[NoteY] = YBase

WithinJournalOrderIsPreserved ==
    Record2 \in state.processedRecords =>
        /\ Record1 \in state.processedRecords
        /\ \E first, second \in 1..Len(state.replayOrder):
            /\ first < second
            /\ state.replayOrder[first] = Record1
            /\ state.replayOrder[second] = Record2

WithinJournalDeleteThenUpdateEndsUpdated ==
    /\ state.scenario = "withinDeleteThenUpdate"
    /\ Record2 \in state.processedRecords
    => state.live[NoteX] = XUpdate1

AppliedDeleteCannotBeResurrectedAcrossJournals ==
    \A record \in state.processedRecords:
        /\ RecordKind(state.scenario, record) = "delete"
        /\ state.dispositions[record] = "applied"
        /\ ~LaterAppliedRecord(record)
        => state.live[RecordNote(state.scenario, record)] = Deleted

DuplicateScenarioIsIdempotent ==
    /\ state.scenario = "duplicate"
    /\ {Record1, Record3} \subseteq state.processedRecords
    => /\ ((state.dispositions[Record1] = "applied"
             /\ state.dispositions[Record3] = "duplicate")
            \/ (state.dispositions[Record3] = "applied"
                /\ state.dispositions[Record1] = "duplicate"))
       /\ state.live[NoteX] = XUpdate1
       /\ XUpdate1 \notin state.conflicts

DeletedJournalsWereCompletelyCovered ==
    \A journal \in state.deletedJournals:
        /\ state.qualified
        /\ journal \in state.receiptJournals
        /\ JournalRecords(journal) \subseteq state.durableCoverage

RecoveryProgress ==
    state.phase = "replaying" /\ state.pendingRecords = {}
    ~> state.phase # "replaying"

=============================================================================
