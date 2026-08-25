--------------------- MODULE RecoveryEvidenceSafety -----------------------
EXTENDS FiniteSets, Naturals

\* EvidenceVersions are immutable persistent version identifiers. catalogToken
\* values are opaque; Naturals and +1 only provide bounded fresh values.
\* processedVersions records traversal only; provider-version representation and
\* provider-version resolution eligibility are tracked separately.

CONSTANTS
    DatabaseVersions,
    DatabaseVersion1,
    DatabaseVersion2,
    JournalVersions,
    JournalVersion1,
    JournalVersion2,
    NoteStates,
    LiveState,
    RecoveryState1,
    RecoveryState2,
    RecoveryIDs,
    RecoveryID1,
    RecoveryID2,
    Settings,
    LiveSettings,
    ForeignSettings,
    CheckpointIDs,
    InitialCheckpoint,
    MaxCatalogToken,
    None

ASSUME
    /\ DatabaseVersions = {DatabaseVersion1, DatabaseVersion2}
    /\ JournalVersions = {JournalVersion1, JournalVersion2}
    /\ DatabaseVersions \cap JournalVersions = {}
    /\ {LiveState, RecoveryState1, RecoveryState2} \subseteq NoteStates
    /\ Cardinality({LiveState, RecoveryState1, RecoveryState2}) = 3
    /\ {RecoveryID1, RecoveryID2} \subseteq RecoveryIDs
    /\ RecoveryID1 # RecoveryID2
    /\ {LiveSettings, ForeignSettings} \subseteq Settings
    /\ LiveSettings # ForeignSettings
    /\ InitialCheckpoint \in CheckpointIDs
    /\ MaxCatalogToken >= 2
    /\ None \notin CheckpointIDs

VARIABLE state

vars == <<state>>

EvidenceVersions == DatabaseVersions \cup JournalVersions
Kinds == {"note", "delete", "settings"}
RootKinds == {"local", "icloud"}
Phases == {
    "idle", "recovering", "durability", "discarding", "crashed"
}
Scenarios == {"duplicates", "databaseSettings", "journalDeletion"}

EvidenceKind(scenario, version) ==
    CASE scenario = "databaseSettings" /\ version = DatabaseVersion2
            -> "settings"
      [] version = JournalVersion2 -> "delete"
      [] OTHER -> "note"

EvidenceState(scenario, version) ==
    IF scenario = "databaseSettings" /\ version = JournalVersion1
    THEN LiveState
    ELSE IF version \in {DatabaseVersion1, DatabaseVersion2}
         THEN RecoveryState1
         ELSE RecoveryState2

DeterministicRecoveryID(noteState) ==
    IF noteState = RecoveryState1 THEN RecoveryID1 ELSE RecoveryID2

KnownEvidence == state.knownDatabase \cup state.knownJournals
VisibleDatabaseEvidence ==
    state.knownDatabase \ (state.resolvedDatabase \cup state.discardedDatabase)
RecoveryCandidates == VisibleDatabaseEvidence \cup state.knownJournals

RecoveryInputsRepresented(version) ==
    state.versionContributions[version]
        \subseteq state.importedRecoveryIDs \cup state.intentionalTombstones

ExactUploadedCoverage ==
    /\ state.checkpointVerified
    /\ state.verifiedCoverage = state.installedCoverage
    /\ state.confirmedCheckpoint = state.installedCheckpoint
    /\ state.confirmedCoverage = state.installedCoverage

AccessChangeIsRelevant(version) ==
    \/ state.phase = "idle"
    \/ /\ state.phase = "recovering"
       /\ version \in state.snapshot \ (state.processed \cup state.failed)

Init ==
    \E scenario \in Scenarios:
    \E rootKind \in RootKinds:
        state = [
            scenario |-> scenario,
            rootKind |-> rootKind,
            phase |-> "idle",
            knownDatabase |-> {DatabaseVersion1},
            knownJournals |-> {JournalVersion1},
            remoteWriterPossible |-> {JournalVersion1},
            catalogToken |-> 0,
            readable |-> EvidenceVersions,
            decodable |-> EvidenceVersions,
            snapshot |-> {},
            snapshotCatalogToken |-> 0,
            enumerationComplete |-> FALSE,
            processed |-> {},
            failed |-> {},
            versionContributions |->
                [version \in EvidenceVersions |-> {}],
            liveOriginal |-> LiveState,
            liveSettings |-> LiveSettings,
            importedConflictStates |-> {},
            importedRecoveryIDs |-> {},
            intentionalTombstones |-> {},
            ignoredDeletes |-> {},
            ignoredSettings |-> {},
            resolutionEligibleVersions |-> {},
            partialSeen |-> FALSE,
            completionWitnesses |-> {},
            fileDurableVersions |-> {},
            installedCheckpoint |-> InitialCheckpoint,
            usedCheckpointIDs |-> {InitialCheckpoint},
            checkpointInstallCount |-> [checkpoint \in CheckpointIDs |->
                IF checkpoint = InitialCheckpoint THEN 1 ELSE 0],
            installedCoverage |-> {},
            checkpointVerified |-> TRUE,
            verifiedCoverage |-> {},
            confirmedCheckpoint |-> None,
            confirmedCoverage |-> {},
            uploadCallbackObserved |-> FALSE,
            resolvedDatabase |-> {},
            resolutionWitnesses |-> {},
            resolvedJournals |-> {},
            deletedJournals |-> {},
            discardSnapshot |-> {},
            discardFailed |-> {},
            discardedDatabase |-> {},
            discardWitnesses |-> {},
            resolutionEligibleBeforeRun |-> {},
            routineScans |-> 0
                ]

DeliverEvidenceVersion ==
    /\ state.phase # "crashed"
    /\ state.catalogToken < MaxCatalogToken
    /\ \E version \in EvidenceVersions \ KnownEvidence:
        state' = [state EXCEPT
            !.knownDatabase =
                IF version \in DatabaseVersions THEN @ \cup {version} ELSE @,
            !.knownJournals =
                IF version \in JournalVersions THEN @ \cup {version} ELSE @,
            !.remoteWriterPossible =
                IF version \in JournalVersions THEN @ \cup {version} ELSE @,
            !.catalogToken = @ + 1
                ]

MakeEvidenceUnreadable ==
    /\ state.phase \in {"idle", "recovering"}
    /\ \E version \in state.readable:
        /\ AccessChangeIsRelevant(version)
        /\ state' = [state EXCEPT !.readable = @ \ {version}]

MakeEvidenceUndecodable ==
    /\ state.phase \in {"idle", "recovering"}
    /\ \E version \in state.decodable:
        /\ AccessChangeIsRelevant(version)
        /\ state' = [state EXCEPT !.decodable = @ \ {version}]

RestoreEvidenceAccess ==
    /\ state.phase \in {"idle", "recovering"}
    /\ \E version \in EvidenceVersions:
        /\ AccessChangeIsRelevant(version)
        /\ version \notin state.readable \/ version \notin state.decodable
        /\ state' = [state EXCEPT
            !.readable = @ \cup {version},
            !.decodable = @ \cup {version}
                ]

RoutineSynchronization ==
    /\ state.phase = "idle"
    /\ state.routineScans < 2
    /\ state' = [state EXCEPT !.routineScans = @ + 1]

StartRecoverNotes ==
    /\ state.phase = "idle"
    /\ RecoveryCandidates # {}
    /\ \E complete \in BOOLEAN:
        state' = [state EXCEPT
            !.phase = "recovering",
            !.snapshot = RecoveryCandidates,
            !.snapshotCatalogToken = state.catalogToken,
            !.enumerationComplete = complete,
            !.processed = {},
            !.failed = {},
            !.resolutionEligibleBeforeRun = state.resolutionEligibleVersions
                ]

ProcessRecoveryEvidence ==
    /\ state.phase = "recovering"
    /\ \E version \in state.snapshot \ (state.processed \cup state.failed):
        /\ version \in state.readable
        /\ version \in state.decodable
        /\ LET kind == EvidenceKind(state.scenario, version)
               noteState == EvidenceState(state.scenario, version)
               recoveryID == DeterministicRecoveryID(noteState)
               contributes == kind = "note" /\ noteState # state.liveOriginal
               shouldImport ==
                    /\ contributes
                    /\ recoveryID \notin state.importedRecoveryIDs
                    /\ recoveryID \notin state.intentionalTombstones
           IN state' = [state EXCEPT
                !.processed = @ \cup {version},
                !.versionContributions[version] =
                    IF contributes THEN {recoveryID} ELSE {},
                !.importedConflictStates =
                    IF shouldImport
                    THEN @ \cup {noteState} ELSE @,
                !.importedRecoveryIDs =
                    IF shouldImport
                    THEN @ \cup {recoveryID} ELSE @,
                !.ignoredDeletes =
                    IF kind = "delete" THEN @ \cup {version} ELSE @,
                !.ignoredSettings =
                    IF kind = "settings" THEN @ \cup {version} ELSE @
                ]

CancelRecoverNotes ==
    /\ state.phase = "recovering"
    /\ state' = [state EXCEPT
        !.phase = "idle",
        !.partialSeen = TRUE
                ]

TombstoneImportedRecoveryNote ==
    /\ state.phase = "idle"
    /\ \E recoveryID \in state.importedRecoveryIDs:
        LET noteState ==
            IF recoveryID = RecoveryID1
            THEN RecoveryState1 ELSE RecoveryState2
        IN state' = [state EXCEPT
            !.importedRecoveryIDs = @ \ {recoveryID},
            !.importedConflictStates = @ \ {noteState},
            !.intentionalTombstones = @ \cup {recoveryID}
                ]

FailRecoveryEvidence ==
    /\ state.phase = "recovering"
    /\ \E version \in state.snapshot \ (state.processed \cup state.failed):
        /\ version \notin state.readable \/ version \notin state.decodable
        /\ state' = [state EXCEPT !.failed = @ \cup {version}]

FinishRecoverNotes ==
    /\ state.phase = "recovering"
    /\ state.processed \cup state.failed = state.snapshot
    /\ LET completeRun ==
            /\ state.enumerationComplete
            /\ state.failed = {}
            /\ state.snapshot = RecoveryCandidates
            /\ state.snapshotCatalogToken = state.catalogToken
            /\ \A version \in state.snapshot:
                RecoveryInputsRepresented(version)
       IN state' = [state EXCEPT
            !.phase = IF completeRun THEN "durability" ELSE "idle",
            !.resolutionEligibleVersions =
                IF completeRun THEN @ \cup state.snapshot ELSE @,
            !.partialSeen = IF completeRun THEN @ ELSE TRUE,
            !.completionWitnesses =
                IF completeRun
                THEN @ \cup
                    {<<state.enumerationComplete,
                       state.failed = {},
                       state.snapshot = RecoveryCandidates,
                       state.snapshotCatalogToken = state.catalogToken,
                       \A version \in state.snapshot:
                           RecoveryInputsRepresented(version)>>}
                ELSE @
                ]

PersistRecoveredContributions ==
    /\ state.phase = "durability"
    /\ state.resolutionEligibleVersions \ state.fileDurableVersions # {}
    /\ \A version \in state.resolutionEligibleVersions:
        RecoveryInputsRepresented(version)
    /\ state' = [state EXCEPT
        !.fileDurableVersions = @ \cup state.resolutionEligibleVersions
                ]

InstallRecoveryCheckpoint ==
    /\ state.phase = "durability"
    /\ state.fileDurableVersions \ state.installedCoverage # {}
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = [state EXCEPT
            !.installedCheckpoint = checkpoint,
            !.usedCheckpointIDs = @ \cup {checkpoint},
            !.checkpointInstallCount[checkpoint] = @ + 1,
            !.installedCoverage = state.fileDurableVersions,
            !.checkpointVerified = FALSE,
            !.verifiedCoverage = {},
            !.confirmedCheckpoint = None,
            !.confirmedCoverage = {},
            !.uploadCallbackObserved = FALSE
                ]

VerifyRecoveryCheckpoint ==
    /\ state.phase = "durability"
    /\ state.installedCoverage # {}
    /\ ~state.checkpointVerified
    /\ state' = [state EXCEPT
        !.checkpointVerified = TRUE,
        !.verifiedCoverage = state.installedCoverage
                ]

ConfirmRecoveryCheckpointUpload ==
    /\ state.phase = "durability"
    /\ state.installedCoverage # {}
    /\ state.checkpointVerified
    /\ ~state.uploadCallbackObserved
    /\ \E returned \in CheckpointIDs \cup {None}:
        state' = [state EXCEPT
            !.confirmedCheckpoint =
                IF returned = state.installedCheckpoint THEN returned ELSE None,
            !.confirmedCoverage =
                IF returned = state.installedCheckpoint
                THEN state.installedCoverage ELSE {},
            !.uploadCallbackObserved = TRUE
                ]

ResolveDatabaseVersion ==
    /\ state.phase = "durability"
    /\ \E version \in
            (DatabaseVersions \cap state.resolutionEligibleVersions
                \cap state.installedCoverage) \ state.resolvedDatabase:
        /\ state.checkpointVerified
        /\ state.verifiedCoverage = state.installedCoverage
        /\ version \in state.verifiedCoverage
        /\ \/ state.rootKind = "local"
           \/ /\ state.rootKind = "icloud"
              /\ ExactUploadedCoverage
              /\ version \in state.confirmedCoverage
        /\ state' = [state EXCEPT
            !.resolvedDatabase = @ \cup {version},
            !.resolutionWitnesses = @ \cup
                {<<version,
                   version \in state.resolutionEligibleVersions,
                   version \in state.fileDurableVersions,
                   version \in state.installedCoverage,
                   state.checkpointVerified
                       /\ state.verifiedCoverage = state.installedCoverage
                       /\ version \in state.verifiedCoverage,
                   state.rootKind = "local"
                       \/ /\ state.rootKind = "icloud"
                          /\ ExactUploadedCoverage
                          /\ version \in state.confirmedCoverage,
                   state.installedCheckpoint>>}
                ]

FinishRecoveryDurability ==
    /\ state.phase = "durability"
    /\ DatabaseVersions \cap state.resolutionEligibleVersions
        \subseteq state.resolvedDatabase
    /\ state' = [state EXCEPT !.phase = "idle"]

StartDiscard ==
    /\ state.phase = "idle"
    /\ VisibleDatabaseEvidence # {}
    /\ state' = [state EXCEPT
        !.phase = "discarding",
        !.discardSnapshot = VisibleDatabaseEvidence,
        !.discardFailed = {}
                ]

DiscardDatabaseVersion ==
    /\ state.phase = "discarding"
    /\ \E version \in state.discardSnapshot \
            (state.discardedDatabase \cup state.discardFailed):
        /\ version \in state.knownDatabase
        /\ \/ state' = [state EXCEPT
                !.discardedDatabase = @ \cup {version},
                !.discardWitnesses = @ \cup
                    {<<version,
                       version \in state.discardSnapshot,
                       version \in state.knownDatabase>>}
                ]
           \/ state' = [state EXCEPT
                !.discardFailed = @ \cup {version}
                ]

FinishDiscard ==
    /\ state.phase = "discarding"
    /\ state.discardSnapshot
        \subseteq state.discardedDatabase \cup state.discardFailed
    /\ state' = [state EXCEPT !.phase = "idle"]

Crash ==
    /\ state.phase # "crashed"
    /\ state' = [state EXCEPT !.phase = "crashed"]

Next ==
    \/ DeliverEvidenceVersion
    \/ MakeEvidenceUnreadable
    \/ MakeEvidenceUndecodable
    \/ RestoreEvidenceAccess
    \/ RoutineSynchronization
    \/ StartRecoverNotes
    \/ ProcessRecoveryEvidence
    \/ FailRecoveryEvidence
    \/ CancelRecoverNotes
    \/ FinishRecoverNotes
    \/ PersistRecoveredContributions
    \/ InstallRecoveryCheckpoint
    \/ VerifyRecoveryCheckpoint
    \/ ConfirmRecoveryCheckpointUpload
    \/ ResolveDatabaseVersion
    \/ FinishRecoveryDurability
    \/ StartDiscard
    \/ DiscardDatabaseVersion
    \/ FinishDiscard
    \/ TombstoneImportedRecoveryNote
    \/ Crash

RecoveryProcessingProgress ==
    ProcessRecoveryEvidence \/ FailRecoveryEvidence \/ FinishRecoverNotes

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(RecoveryProcessingProgress)
    /\ WF_vars(DiscardDatabaseVersion)
    /\ WF_vars(FinishDiscard)

TypeOK ==
    /\ state.scenario \in Scenarios
    /\ state.rootKind \in RootKinds
    /\ state.phase \in Phases
    /\ state.knownDatabase \subseteq DatabaseVersions
    /\ state.knownJournals \subseteq JournalVersions
    /\ state.remoteWriterPossible \subseteq JournalVersions
    /\ state.catalogToken \in 0..MaxCatalogToken
    /\ state.readable \subseteq EvidenceVersions
    /\ state.decodable \subseteq EvidenceVersions
    /\ state.snapshot \subseteq EvidenceVersions
    /\ state.snapshotCatalogToken \in 0..MaxCatalogToken
    /\ state.enumerationComplete \in BOOLEAN
    /\ state.processed \subseteq EvidenceVersions
    /\ state.failed \subseteq EvidenceVersions
    /\ state.versionContributions \in
        [EvidenceVersions -> SUBSET RecoveryIDs]
    /\ state.liveOriginal \in NoteStates
    /\ state.liveSettings \in Settings
    /\ state.importedConflictStates \subseteq NoteStates
    /\ state.importedRecoveryIDs \subseteq RecoveryIDs
    /\ state.intentionalTombstones \subseteq RecoveryIDs
    /\ state.ignoredDeletes \subseteq EvidenceVersions
    /\ state.ignoredSettings \subseteq EvidenceVersions
    /\ state.resolutionEligibleVersions \subseteq EvidenceVersions
    /\ state.partialSeen \in BOOLEAN
    /\ state.completionWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.fileDurableVersions \subseteq EvidenceVersions
    /\ state.installedCheckpoint \in CheckpointIDs
    /\ state.usedCheckpointIDs \subseteq CheckpointIDs
    /\ state.checkpointInstallCount \in [CheckpointIDs -> 0..1]
    /\ state.installedCoverage \subseteq EvidenceVersions
    /\ state.checkpointVerified \in BOOLEAN
    /\ state.verifiedCoverage \subseteq EvidenceVersions
    /\ state.confirmedCheckpoint \in CheckpointIDs \cup {None}
    /\ state.confirmedCoverage \subseteq EvidenceVersions
    /\ state.uploadCallbackObserved \in BOOLEAN
    /\ state.resolvedDatabase \subseteq DatabaseVersions
    /\ state.resolutionWitnesses \subseteq
        (DatabaseVersions \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN
            \X BOOLEAN \X CheckpointIDs)
    /\ state.resolvedJournals \subseteq JournalVersions
    /\ state.deletedJournals \subseteq JournalVersions
    /\ state.discardSnapshot \subseteq DatabaseVersions
    /\ state.discardFailed \subseteq DatabaseVersions
    /\ state.discardedDatabase \subseteq DatabaseVersions
    /\ state.discardWitnesses \subseteq
        (DatabaseVersions \X BOOLEAN \X BOOLEAN)
    /\ state.resolutionEligibleBeforeRun \subseteq EvidenceVersions
    /\ state.routineScans \in 0..2

RecoveryNeverOverwritesOriginalOrSettings ==
    /\ state.liveOriginal = LiveState
    /\ state.liveSettings = LiveSettings

ImportedNotesHaveDeterministicConflictIdentities ==
    /\ state.importedRecoveryIDs \cup state.intentionalTombstones
        \subseteq {RecoveryID1, RecoveryID2}
    /\ state.importedConflictStates =
        {noteState \in {RecoveryState1, RecoveryState2}:
            DeterministicRecoveryID(noteState)
                \in state.importedRecoveryIDs}

IntentionalTombstonesPreventResurrection ==
    state.importedRecoveryIDs \cap state.intentionalTombstones = {}

DeleteAndSettingsEvidenceHasNoNoteContribution ==
    \A version \in state.ignoredDeletes \cup state.ignoredSettings:
        state.versionContributions[version] = {}

IdenticalLiveEvidenceHasNoNoteContribution ==
    \A version \in state.processed:
        (/\ EvidenceKind(state.scenario, version) = "note"
         /\ EvidenceState(state.scenario, version) = state.liveOriginal)
        => state.versionContributions[version] = {}

CompleteRunsHadExactAllVersionSnapshots ==
    \A witness \in state.completionWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]

ResolvedDatabaseVersionsHadFullDurability ==
    /\ state.resolvedDatabase =
        {witness[1]: witness \in state.resolutionWitnesses}
    /\ \A witness \in state.resolutionWitnesses:
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]
        /\ witness[6]

CheckpointIDsAreNeverReused ==
    \A checkpoint \in CheckpointIDs:
        state.checkpointInstallCount[checkpoint] <= 1

UnclaimedJournalEvidenceWithPossibleWriterIsNeverConsumed ==
    /\ state.resolvedJournals = {}
    /\ state.deletedJournals = {}
    /\ state.remoteWriterPossible \subseteq state.knownJournals

DiscardNeverBroadensItsConfirmedSnapshot ==
    /\ state.discardedDatabase =
        {witness[1]: witness \in state.discardWitnesses}
    /\ \A witness \in state.discardWitnesses:
        /\ witness[2]
        /\ witness[3]

PartialOrFailedRunsDoNotGainResolutionEligibility ==
    state.failed \cap (state.resolutionEligibleVersions \ state.resolutionEligibleBeforeRun) = {}

ExplicitRecoveryProgress ==
    state.phase = "recovering"
    ~> state.phase \in {"durability", "idle", "crashed"}

RoutineSyncPreservesRecoveryEvidence ==
    [][RoutineSynchronization =>
        UNCHANGED <<state.liveOriginal, state.liveSettings,
                    state.resolvedDatabase, state.resolvedJournals,
                    state.deletedJournals>>]_vars

=============================================================================
