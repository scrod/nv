----------------------- MODULE JournalRecoverySafety -----------------------
EXTENDS FiniteSets, Naturals

CONSTANTS
    CheckpointIDs,
    InitialCheckpoint,
    OtherCheckpoint,
    NoteStates,
    BaseState,
    LocalState,
    RemoteState1,
    RemoteState2,
    Deleted,
    Settings,
    InitialSettings,
    RecoveredSettings,
    RecordCount,
    None

ASSUME
    /\ IsFiniteSet(CheckpointIDs)
    /\ {InitialCheckpoint, OtherCheckpoint} \subseteq CheckpointIDs
    /\ InitialCheckpoint # OtherCheckpoint
    /\ {BaseState, LocalState, RemoteState1, RemoteState2, Deleted}
        \subseteq NoteStates
    /\ Cardinality({BaseState, LocalState, RemoteState1,
                     RemoteState2, Deleted}) = 5
    /\ {InitialSettings, RecoveredSettings} \subseteq Settings
    /\ InitialSettings # RecoveredSettings
    /\ RecordCount = 2
    /\ None \notin CheckpointIDs

VARIABLE state

vars == <<state>>

Records == 1..RecordCount
RecordKinds == {"update", "delete", "settings"}
RootKinds == {"local", "icloud", "otherProvider", "unknown"}
Phases == {
    "discovered", "invalid", "replaying", "recovered", "installed",
    "verified", "deleted", "crashed"
}
QualificationKinds == {"none", "local", "icloud"}
Scenarios == {
    "exactUpdates", "exactDelete", "exactSettings",
    "baseMismatchUpdate", "baseMismatchDelete", "baseMismatchSettings",
    "tornFinal", "interiorCorrupt", "alreadyRepresented", "invalidHeader"
}

BaseMatches(scenario) ==
    scenario \notin {
        "baseMismatchUpdate", "baseMismatchDelete", "baseMismatchSettings",
        "alreadyRepresented"
    }

HeaderIsValid(scenario) == scenario # "invalidHeader"

PrefixLength(scenario) ==
    CASE scenario = "interiorCorrupt" -> 0
      [] scenario = "invalidHeader" -> 0
      [] scenario = "exactUpdates" -> 2
      [] OTHER -> 1

RecordKind(scenario, record) ==
    CASE scenario \in {"exactDelete", "baseMismatchDelete"}
            /\ record = 1 -> "delete"
      [] scenario \in {"exactSettings", "baseMismatchSettings"}
            /\ record = 1 -> "settings"
      [] scenario = "tornFinal" /\ record = 2 -> "delete"
      [] scenario = "interiorCorrupt" /\ record = 1 -> "delete"
      [] OTHER -> "update"

RecordState(scenario, record) ==
    CASE scenario = "exactUpdates" /\ record = 2 -> RemoteState2
      [] scenario = "tornFinal" /\ record = 1 -> RemoteState1
      [] scenario = "alreadyRepresented" -> RemoteState1
      [] OTHER -> RemoteState1

InitialNote(scenario) ==
    CASE scenario \in {
            "baseMismatchUpdate", "baseMismatchDelete",
            "baseMismatchSettings"} -> LocalState
      [] scenario = "alreadyRepresented" -> RemoteState1
      [] OTHER -> BaseState

ValidRecordIDs == 1..state.validPrefix

Init ==
    \E scenario \in Scenarios:
    \E rootKind \in RootKinds:
        LET initialNote == InitialNote(scenario)
        IN state = [
            scenario |-> scenario,
            rootKind |-> rootKind,
            phase |-> "discovered",
            headerValid |-> HeaderIsValid(scenario),
            headerBase |->
                IF BaseMatches(scenario)
                THEN InitialCheckpoint ELSE OtherCheckpoint,
            acceptedDatabaseCheckpoint |-> InitialCheckpoint,
            validPrefix |-> PrefixLength(scenario),
            recordKinds |-> [record \in Records |->
                RecordKind(scenario, record)],
            recordStates |-> [record \in Records |->
                RecordState(scenario, record)],
            nextRecord |-> 1,
            processedRecords |-> {},
            appliedRecords |-> {},
            preservedRecords |-> {},
            duplicateRecords |-> {},
            rejectedUnsafeRecords |-> {},
            liveNote |-> initialNote,
            initialNote |-> initialNote,
            settings |-> InitialSettings,
            conflictNotes |-> {},
            lastAppliedRecord |-> 0,
            suffixObserved |-> FALSE,
            journalExists |-> TRUE,
            replacementCheckpoint |-> None,
            durableNote |-> initialNote,
            durableSettings |-> InitialSettings,
            durableConflicts |-> {},
            durableRecordCoverage |-> {},
            replacementVerified |-> FALSE,
            returnedCheckpoint |-> None,
            replacementQualified |-> FALSE,
            qualificationKind |-> "none",
            deletionWitnesses |-> {}
                ]

ValidateJournal ==
    /\ state.phase = "discovered"
    /\ state.headerValid
    /\ state' = [state EXCEPT !.phase = "replaying"]

RejectInvalidHeader ==
    /\ state.phase = "discovered"
    /\ ~state.headerValid
    /\ state' = [state EXCEPT !.phase = "invalid"]

ReplayNextRecord ==
    /\ state.phase = "replaying"
    /\ state.nextRecord \in ValidRecordIDs
    /\ LET record == state.nextRecord
           kind == state.recordKinds[record]
           recordState == state.recordStates[record]
           exactBase == state.headerBase = state.acceptedDatabaseCheckpoint
           differingUpdate ==
                /\ kind = "update"
                /\ recordState # state.liveNote
           nextLive ==
                IF exactBase /\ kind = "update"
                THEN recordState
                ELSE IF exactBase /\ kind = "delete"
                     THEN Deleted
                     ELSE state.liveNote
           nextSettings ==
                IF exactBase /\ kind = "settings"
                THEN RecoveredSettings
                ELSE state.settings
           nextConflicts ==
                IF ~exactBase /\ differingUpdate
                THEN state.conflictNotes \cup {recordState}
                ELSE state.conflictNotes
       IN state' = [state EXCEPT
            !.nextRecord = @ + 1,
            !.processedRecords = @ \cup {record},
            !.appliedRecords =
                IF exactBase THEN @ \cup {record} ELSE @,
            !.preservedRecords =
                IF ~exactBase /\ differingUpdate
                THEN @ \cup {record} ELSE @,
            !.duplicateRecords =
                IF ~exactBase /\ kind = "update"
                    /\ recordState = state.liveNote
                THEN @ \cup {record} ELSE @,
            !.rejectedUnsafeRecords =
                IF ~exactBase /\ kind \in {"delete", "settings"}
                THEN @ \cup {record} ELSE @,
            !.liveNote = nextLive,
            !.settings = nextSettings,
            !.conflictNotes = nextConflicts,
            !.lastAppliedRecord =
                IF exactBase THEN record ELSE @
                ]

FinishValidPrefix ==
    /\ state.phase = "replaying"
    /\ state.processedRecords = ValidRecordIDs
    /\ state.nextRecord = state.validPrefix + 1
    /\ state' = [state EXCEPT
        !.phase = "recovered",
        !.suffixObserved = state.validPrefix < RecordCount
                ]

InstallReplacementCheckpoint ==
    /\ state.phase = "recovered"
    /\ \E checkpoint \in CheckpointIDs \ {state.acceptedDatabaseCheckpoint}:
        state' = [state EXCEPT
            !.phase = "installed",
            !.replacementCheckpoint = checkpoint,
            !.durableNote = state.liveNote,
            !.durableSettings = state.settings,
            !.durableConflicts = state.conflictNotes,
            !.durableRecordCoverage = state.processedRecords
                ]

VerifyReplacementCheckpoint ==
    /\ state.phase = "installed"
    /\ state.replacementCheckpoint # None
    /\ state.durableNote = state.liveNote
    /\ state.durableSettings = state.settings
    /\ state.durableConflicts = state.conflictNotes
    /\ state.durableRecordCoverage = ValidRecordIDs
    /\ state' = [state EXCEPT
        !.phase = "verified",
        !.acceptedDatabaseCheckpoint = state.replacementCheckpoint,
        !.replacementVerified = TRUE
                ]

QualifyLocalReplacement ==
    /\ state.phase = "verified"
    /\ state.rootKind = "local"
    /\ state.replacementVerified
    /\ state' = [state EXCEPT
        !.replacementQualified = TRUE,
        !.qualificationKind = "local"
                ]

ObserveICloudUpload ==
    /\ state.phase = "verified"
    /\ state.rootKind = "icloud"
    /\ state.replacementVerified
    /\ \E returned \in CheckpointIDs \cup {None}:
        state' = [state EXCEPT
            !.returnedCheckpoint = returned,
            !.replacementQualified = returned = state.replacementCheckpoint,
            !.qualificationKind =
                IF returned = state.replacementCheckpoint
                THEN "icloud" ELSE "none"
                ]

DeleteRecoveredJournal ==
    /\ state.phase = "verified"
    /\ state.journalExists
    /\ state.replacementVerified
    /\ state.replacementQualified
    /\ state.durableRecordCoverage = ValidRecordIDs
    /\ state' = [state EXCEPT
        !.phase = "deleted",
        !.journalExists = FALSE,
        !.deletionWitnesses = @ \cup
            {<<state.replacementVerified,
               state.replacementQualified,
               state.durableRecordCoverage = ValidRecordIDs,
               state.replacementCheckpoint>>}
                ]

Crash ==
    /\ state.phase \notin {"deleted", "crashed"}
    /\ state' = [state EXCEPT !.phase = "crashed"]

Next ==
    \/ ValidateJournal
    \/ RejectInvalidHeader
    \/ ReplayNextRecord
    \/ FinishValidPrefix
    \/ InstallReplacementCheckpoint
    \/ VerifyReplacementCheckpoint
    \/ QualifyLocalReplacement
    \/ ObserveICloudUpload
    \/ DeleteRecoveredJournal
    \/ Crash

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(ValidateJournal)
    /\ WF_vars(RejectInvalidHeader)
    /\ WF_vars(ReplayNextRecord)
    /\ WF_vars(FinishValidPrefix)

TypeOK ==
    /\ state.scenario \in Scenarios
    /\ state.rootKind \in RootKinds
    /\ state.phase \in Phases
    /\ state.headerValid \in BOOLEAN
    /\ state.headerBase \in CheckpointIDs
    /\ state.acceptedDatabaseCheckpoint \in CheckpointIDs
    /\ state.validPrefix \in 0..RecordCount
    /\ state.recordKinds \in [Records -> RecordKinds]
    /\ state.recordStates \in [Records -> NoteStates]
    /\ state.nextRecord \in 1..(RecordCount + 1)
    /\ state.processedRecords \subseteq Records
    /\ state.appliedRecords \subseteq Records
    /\ state.preservedRecords \subseteq Records
    /\ state.duplicateRecords \subseteq Records
    /\ state.rejectedUnsafeRecords \subseteq Records
    /\ state.liveNote \in NoteStates
    /\ state.initialNote \in NoteStates
    /\ state.settings \in Settings
    /\ state.conflictNotes \subseteq NoteStates
    /\ state.lastAppliedRecord \in 0..RecordCount
    /\ state.suffixObserved \in BOOLEAN
    /\ state.journalExists \in BOOLEAN
    /\ state.replacementCheckpoint \in CheckpointIDs \cup {None}
    /\ state.durableNote \in NoteStates
    /\ state.durableSettings \in Settings
    /\ state.durableConflicts \subseteq NoteStates
    /\ state.durableRecordCoverage \subseteq Records
    /\ state.replacementVerified \in BOOLEAN
    /\ state.returnedCheckpoint \in CheckpointIDs \cup {None}
    /\ state.replacementQualified \in BOOLEAN
    /\ state.qualificationKind \in QualificationKinds
    /\ state.deletionWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X CheckpointIDs)

OnlyTheCompleteValidPrefixIsProcessed ==
    /\ state.processedRecords \subseteq ValidRecordIDs
    /\ state.processedRecords = 1..(state.nextRecord - 1)
    /\ state.appliedRecords \cup state.preservedRecords
        \cup state.duplicateRecords \cup state.rejectedUnsafeRecords
        = state.processedRecords

BaseMismatchCannotOverwriteDeleteOrRestoreSettings ==
    state.headerBase # InitialCheckpoint =>
        /\ state.liveNote = state.initialNote
        /\ state.settings = InitialSettings
        /\ state.appliedRecords = {}

BaseMismatchDifferingUpdatesBecomeConflicts ==
    \A record \in state.processedRecords:
        /\ state.headerBase # InitialCheckpoint
        /\ state.recordKinds[record] = "update"
        /\ state.recordStates[record] # state.initialNote
        => state.recordStates[record] \in state.conflictNotes

ExactBaseReplayRespectsRecordOrder ==
    /\ state.headerBase = InitialCheckpoint
    /\ state.lastAppliedRecord > 0
    /\ state.recordKinds[state.lastAppliedRecord] = "update"
    => state.liveNote = state.recordStates[state.lastAppliedRecord]

InvalidOrUnprocessedSuffixRemainsEvidence ==
    /\ state.phase \in {"invalid", "replaying", "recovered", "installed"}
    /\ \/ ~state.headerValid
       \/ state.validPrefix < RecordCount
    => state.journalExists

ValidRecordsRemainRecoverable ==
    ValidRecordIDs \subseteq
        IF state.journalExists
        THEN ValidRecordIDs
        ELSE state.durableRecordCoverage

CleanupWasHistoricallyQualified ==
    /\ ~state.journalExists => state.deletionWitnesses # {}
    /\ \A witness \in state.deletionWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]

UnqualifiedProviderRootsRetainJournal ==
    state.rootKind \in {"otherProvider", "unknown"} => state.journalExists

InvalidHeaderNeverAuthorizesRecoveryOrDeletion ==
    ~state.headerValid =>
        /\ state.processedRecords = {}
        /\ state.journalExists

RecoveryProgress ==
    state.phase = "replaying"
    ~> state.phase \in {"recovered", "crashed"}

=============================================================================
