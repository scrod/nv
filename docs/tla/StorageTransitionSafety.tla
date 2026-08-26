-------------------- MODULE StorageTransitionSafety ------------------------
EXTENDS FiniteSets, Naturals

\* catalogToken values are opaque; Naturals and +1 only provide bounded fresh
\* values for equality across the export fence.

CONSTANTS
    Notes,
    CheckpointIDs,
    InitialCheckpoint,
    CredentialIDs,
    InitialCredentialID,
    OldKey,
    NewKey,
    MaxCatalogToken,
    None

ASSUME
    /\ IsFiniteSet(Notes)
    /\ IsFiniteSet(CheckpointIDs)
    /\ InitialCheckpoint \in CheckpointIDs
    /\ IsFiniteSet(CredentialIDs)
    /\ InitialCredentialID \in CredentialIDs
    /\ Cardinality(CredentialIDs) >= 2
    /\ OldKey # NewKey
    /\ MaxCatalogToken >= Cardinality(Notes)
    /\ None \notin CheckpointIDs
    /\ None \notin CredentialIDs

VARIABLE state

vars == <<state>>

OldFormats == {"encrypted", "databaseOnly", "rtf", "html"}
Formats == OldFormats \cup {"plaintext"}
RootKinds == {"local", "icloud"}
TransitionKinds == {"plaintextExport", "encryptedRekey"}
Phases == {
    "running", "freezing", "oldInstalled", "oldVerified",
    "oldJournalDeleted", "oldJournalCleared",
    "targetCredentialProvisioned", "targetCredentialVerified",
    "exporting", "fenced",
    "newInstalled", "newVerified", "restarting", "journalCreating",
    "journalHeader", "journalClaimWritten", "journalReady", "editable",
    "cancelled", "failed", "crashed"
}
QualificationKinds == {"none", "local", "icloud"}
Reasons == {"userConversion", "rootMovedIntoICloud"}

FirstClassMode ==
    /\ state.rootKind = "icloud"
    /\ state.checkpointFormat = "plaintext"
    /\ ~state.encryptionEnabled

ExportFenceStable ==
    /\ state.exportStartCatalogToken = state.exportFenceCatalogToken
    /\ state.exportFenceCatalogToken = state.catalogToken

LiveWorkRecoverable ==
    state.liveNotes \subseteq
        state.checkpointNotes \cup
        (IF state.oldJournalExists THEN state.oldJournalDurable ELSE {})

ResumePhaseFromArtifacts ==
    CASE state.newCheckpointVerified -> "restarting"
      [] state.newCheckpointInstalled -> "newInstalled"
      [] state.oldCheckpointVerified /\ ~state.oldJournalExists
            /\ ~state.oldActiveRecord -> "oldJournalCleared"
      [] state.oldCheckpointVerified /\ ~state.oldJournalExists
            -> "oldJournalDeleted"
      [] state.oldCheckpointVerified -> "oldVerified"
      [] OTHER -> "freezing"

Init ==
    \E oldFormat \in OldFormats:
    \E rootKind \in RootKinds:
    \E reason \in Reasons:
    \E transitionKind \in TransitionKinds:
      /\ (reason = "rootMovedIntoICloud" =>
            /\ rootKind = "icloud"
            /\ transitionKind = "plaintextExport")
      /\ (transitionKind = "encryptedRekey" =>
            /\ rootKind = "local"
            /\ reason = "userConversion")
      /\ state = [
            phase |-> "running",
            reason |-> reason,
            rootKind |-> rootKind,
            transitionKind |-> transitionKind,
            oldFormat |-> oldFormat,
            transitionStarted |-> FALSE,
            liveNotes |-> Notes,
            frozenNotes |-> {},
            editable |-> TRUE,
            journalFormat |-> oldFormat,
            journalKey |-> OldKey,
            oldJournalExists |-> TRUE,
            oldActiveRecord |-> TRUE,
            pendingJournal |-> Notes,
            oldJournalDurable |-> {},
            separateFilesSettled |-> FALSE,
            checkpointID |-> InitialCheckpoint,
            usedCheckpointIDs |-> {InitialCheckpoint},
            checkpointInstallCount |-> [checkpoint \in CheckpointIDs |->
                IF checkpoint = InitialCheckpoint THEN 1 ELSE 0],
            checkpointFormat |-> oldFormat,
            checkpointKey |-> OldKey,
            checkpointCredentialID |-> InitialCredentialID,
            checkpointNotes |-> Notes,
            encryptionEnabled |-> oldFormat # "plaintext",
            oldCheckpointVerified |-> FALSE,
            oldInstallWitnesses |-> {},
            oldReplacementQualified |-> FALSE,
            qualificationKind |-> "none",
            returnedCheckpoint |-> None,
            deletionWitnesses |-> {},
            catalogToken |-> 0,
            divergentFiles |-> {},
            preservedDivergences |-> {},
            postInstallExternal |-> {},
            exportedNotes |-> {},
            exportStartCatalogToken |-> 0,
            exportFenceCatalogToken |-> 0,
            newCheckpointInstalled |-> FALSE,
            newCheckpointVerified |-> FALSE,
            stagedNewNotes |-> {},
            newInstallWitnesses |-> {},
            rekeyInstallWitnesses |-> {},
            keychainBindings |-> {<<InitialCredentialID, OldKey>>},
            usedCredentialIDs |-> {InitialCredentialID},
            credentialProvisionCount |->
                [credential \in CredentialIDs |->
                    IF credential = InitialCredentialID THEN 1 ELSE 0],
            oldCredentialID |-> InitialCredentialID,
            stagedTargetCredentialID |-> None,
            targetCredentialReadBackVerified |-> FALSE,
            loadedFormat |-> oldFormat,
            loadedKey |-> OldKey,
            freshJournalHeaderSynced |-> FALSE,
            freshJournalClaimWritten |-> FALSE,
            freshJournalClaimSynced |-> FALSE,
            persistedPhaseLedger |-> FALSE
                ]

BeginControlledTransition ==
    /\ state.phase = "running"
    /\ state.editable
    /\ state' = [state EXCEPT
        !.phase = "freezing",
        !.transitionStarted = TRUE,
        !.editable = FALSE,
        !.frozenNotes = state.liveNotes
                ]

SynchronizeOldJournal ==
    /\ state.phase = "freezing"
    /\ state.pendingJournal # {}
    /\ state.oldJournalExists
    /\ state' = [state EXCEPT
        !.oldJournalDurable = @ \cup state.pendingJournal,
        !.pendingJournal = {}
                ]

SettleOldSeparateFiles ==
    /\ state.phase = "freezing"
    /\ ~state.separateFilesSettled
    /\ state' = [state EXCEPT !.separateFilesSettled = TRUE]

InstallCompleteOldCheckpoint ==
    /\ state.phase = "freezing"
    /\ state.pendingJournal = {}
    /\ state.frozenNotes \subseteq state.oldJournalDurable
    /\ state.separateFilesSettled
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = [state EXCEPT
            !.phase = "oldInstalled",
            !.checkpointID = checkpoint,
            !.usedCheckpointIDs = @ \cup {checkpoint},
            !.checkpointInstallCount[checkpoint] = @ + 1,
            !.checkpointNotes = state.frozenNotes,
            !.oldCheckpointVerified = FALSE,
            !.oldReplacementQualified = FALSE,
            !.qualificationKind = "none",
            !.oldInstallWitnesses = @ \cup
                {<<state.pendingJournal = {},
                   state.frozenNotes \subseteq state.oldJournalDurable,
                   state.separateFilesSettled,
                   state.checkpointFormat \in OldFormats,
                   state.checkpointKey = OldKey>>}
                ]

VerifyCompleteOldCheckpoint ==
    /\ state.phase = "oldInstalled"
    /\ state.checkpointFormat \in OldFormats
    /\ state.checkpointKey = OldKey
    /\ state.checkpointNotes = state.frozenNotes
    /\ state' = [state EXCEPT
        !.phase = "oldVerified",
        !.oldCheckpointVerified = TRUE
                ]

QualifyLocalOldCheckpoint ==
    /\ state.phase = "oldVerified"
    /\ state.rootKind = "local"
    /\ state.oldCheckpointVerified
    /\ state' = [state EXCEPT
        !.oldReplacementQualified = TRUE,
        !.qualificationKind = "local"
                ]

ObserveICloudOldCheckpointUpload ==
    /\ state.phase = "oldVerified"
    /\ state.rootKind = "icloud"
    /\ state.oldCheckpointVerified
    /\ \E returned \in CheckpointIDs \cup {None}:
        state' = [state EXCEPT
            !.returnedCheckpoint = returned,
            !.oldReplacementQualified = returned = state.checkpointID,
            !.qualificationKind =
                IF returned = state.checkpointID THEN "icloud" ELSE "none"
                ]

DeleteOldJournal ==
    /\ state.phase = "oldVerified"
    /\ state.oldCheckpointVerified
    /\ state.oldReplacementQualified
    /\ state.oldJournalExists
    /\ state.frozenNotes \subseteq state.checkpointNotes
    /\ state' = [state EXCEPT
        !.phase = "oldJournalDeleted",
        !.oldJournalExists = FALSE,
        !.deletionWitnesses = @ \cup
            {<<state.oldCheckpointVerified,
               state.oldReplacementQualified,
               state.frozenNotes \subseteq state.checkpointNotes,
               state.checkpointID>>}
                ]

ClearOldActiveRecord ==
    /\ state.phase = "oldJournalDeleted"
    /\ ~state.oldJournalExists
    /\ state.oldActiveRecord
    /\ state' = [state EXCEPT
        !.phase = "oldJournalCleared",
        !.oldActiveRecord = FALSE
                ]

BeginPlaintextExport ==
    /\ state.phase = "oldJournalCleared"
    /\ state.transitionKind = "plaintextExport"
    /\ state.oldCheckpointVerified
    /\ ~state.oldJournalExists
    /\ ~state.oldActiveRecord
    /\ state' = [state EXCEPT
        !.phase = "exporting",
        !.exportedNotes = {},
        !.exportStartCatalogToken = state.catalogToken,
        !.exportFenceCatalogToken = state.catalogToken
                ]

ExternalFileDiverges ==
    /\ state.phase \in {"exporting", "fenced"}
    /\ state.catalogToken < MaxCatalogToken
    /\ \E note \in Notes \ state.divergentFiles:
        state' = [state EXCEPT
            !.divergentFiles = @ \cup {note},
            !.catalogToken = @ + 1,
            !.exportedNotes = @ \ {note},
            !.preservedDivergences = @ \ {note}
                ]

ExternalFileArrivesAfterInstall ==
    /\ state.phase \in {"newInstalled", "newVerified", "restarting",
                         "journalCreating", "journalHeader",
                         "journalClaimWritten", "journalReady", "editable"}
    /\ state.catalogToken < MaxCatalogToken
    /\ \E note \in Notes \ state.divergentFiles:
        state' = [state EXCEPT
            !.divergentFiles = @ \cup {note},
            !.postInstallExternal = @ \cup {note},
            !.catalogToken = @ + 1
                ]

ExportPlaintextNote ==
    /\ state.phase = "exporting"
    /\ \E note \in Notes \ state.exportedNotes:
        state' = [state EXCEPT
            !.exportedNotes = @ \cup {note},
            !.preservedDivergences =
                IF note \in state.divergentFiles
                THEN @ \cup {note} ELSE @
                ]

TakeExportFence ==
    /\ state.phase = "exporting"
    /\ state.exportedNotes = state.frozenNotes
    /\ state.divergentFiles \subseteq state.preservedDivergences
    /\ state' = [state EXCEPT
        !.phase = "fenced",
        !.exportFenceCatalogToken = state.catalogToken
                ]

RetryPlaintextExport ==
    /\ state.phase = "fenced"
    /\ ~ExportFenceStable
    /\ state' = [state EXCEPT
        !.phase = "exporting",
        !.exportedNotes = {},
        !.exportStartCatalogToken = state.catalogToken,
        !.exportFenceCatalogToken = state.catalogToken,
        !.stagedNewNotes = {},
        !.newCheckpointInstalled = FALSE
                ]

InstallPlaintextCheckpoint ==
    /\ state.phase = "fenced"
    /\ state.transitionKind = "plaintextExport"
    /\ ExportFenceStable
    /\ state.exportedNotes = state.frozenNotes
    /\ state.divergentFiles \subseteq state.preservedDivergences
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = [state EXCEPT
            !.phase = "newInstalled",
            !.checkpointID = checkpoint,
            !.usedCheckpointIDs = @ \cup {checkpoint},
            !.checkpointInstallCount[checkpoint] = @ + 1,
            !.checkpointFormat = "plaintext",
            !.checkpointKey = NewKey,
            !.checkpointCredentialID = None,
            !.checkpointNotes = state.frozenNotes,
            !.encryptionEnabled = FALSE,
            !.stagedNewNotes = state.frozenNotes,
            !.newCheckpointInstalled = TRUE,
            !.newCheckpointVerified = FALSE,
            !.newInstallWitnesses = @ \cup
                {<<ExportFenceStable,
                   state.exportedNotes = state.frozenNotes,
                   state.divergentFiles
                       \subseteq state.preservedDivergences,
                   state.oldCheckpointVerified,
                   ~state.oldJournalExists>>}
                ]

VerifyPlaintextCheckpoint ==
    /\ state.phase = "newInstalled"
    /\ state.transitionKind = "plaintextExport"
    /\ state.newCheckpointInstalled
    /\ state.exportStartCatalogToken = state.exportFenceCatalogToken
    /\ state.stagedNewNotes = state.frozenNotes
    /\ state.checkpointNotes = state.stagedNewNotes
    /\ state.checkpointFormat = "plaintext"
    /\ state.checkpointKey = NewKey
    /\ state.checkpointCredentialID = None
    /\ ~state.encryptionEnabled
    /\ state' = [state EXCEPT
        !.phase = "newVerified",
        !.newCheckpointVerified = TRUE
                ]

ProvisionTargetCredential ==
    /\ state.phase = "oldJournalCleared"
    /\ state.transitionKind = "encryptedRekey"
    /\ <<state.oldCredentialID, OldKey>> \in state.keychainBindings
    /\ \E credential \in CredentialIDs \ state.usedCredentialIDs:
        state' = [state EXCEPT
            !.phase = "targetCredentialProvisioned",
            !.keychainBindings = @ \cup {<<credential, NewKey>>},
            !.usedCredentialIDs = @ \cup {credential},
            !.credentialProvisionCount[credential] = @ + 1,
            !.stagedTargetCredentialID = credential,
            !.targetCredentialReadBackVerified = FALSE
                ]

VerifyTargetCredential ==
    /\ state.phase = "targetCredentialProvisioned"
    /\ state.transitionKind = "encryptedRekey"
    /\ state.stagedTargetCredentialID \in CredentialIDs
    /\ <<state.stagedTargetCredentialID, NewKey>> \in
        state.keychainBindings
    /\ state' = [state EXCEPT
        !.phase = "targetCredentialVerified",
        !.targetCredentialReadBackVerified = TRUE
                ]

InstallRekeyedCheckpoint ==
    /\ state.phase = "targetCredentialVerified"
    /\ state.transitionKind = "encryptedRekey"
    /\ state.targetCredentialReadBackVerified
    /\ state.stagedTargetCredentialID \in CredentialIDs
    /\ <<state.stagedTargetCredentialID, NewKey>> \in
        state.keychainBindings
    /\ <<state.oldCredentialID, OldKey>> \in state.keychainBindings
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = [state EXCEPT
            !.phase = "newInstalled",
            !.checkpointID = checkpoint,
            !.usedCheckpointIDs = @ \cup {checkpoint},
            !.checkpointInstallCount[checkpoint] = @ + 1,
            !.checkpointFormat = state.oldFormat,
            !.checkpointKey = NewKey,
            !.checkpointCredentialID = state.stagedTargetCredentialID,
            !.checkpointNotes = state.frozenNotes,
            !.encryptionEnabled = TRUE,
            !.stagedNewNotes = state.frozenNotes,
            !.newCheckpointInstalled = TRUE,
            !.newCheckpointVerified = FALSE,
            !.rekeyInstallWitnesses = @ \cup
                {<<state.targetCredentialReadBackVerified,
                   <<state.stagedTargetCredentialID, NewKey>> \in
                        state.keychainBindings,
                   <<state.oldCredentialID, OldKey>> \in
                        state.keychainBindings,
                   state.oldCheckpointVerified,
                   ~state.oldJournalExists>>}
                ]

VerifyRekeyedCheckpoint ==
    /\ state.phase = "newInstalled"
    /\ state.transitionKind = "encryptedRekey"
    /\ state.newCheckpointInstalled
    /\ state.stagedNewNotes = state.frozenNotes
    /\ state.checkpointNotes = state.stagedNewNotes
    /\ state.checkpointFormat = state.oldFormat
    /\ state.checkpointKey = NewKey
    /\ state.checkpointCredentialID \in CredentialIDs
    /\ <<state.checkpointCredentialID, NewKey>> \in
        state.keychainBindings
    /\ state.encryptionEnabled
    /\ state' = [state EXCEPT
        !.phase = "newVerified",
        !.newCheckpointVerified = TRUE
                ]

DeleteOldCredential ==
    /\ state.newCheckpointVerified
    /\ state.checkpointCredentialID # state.oldCredentialID
    /\ <<state.oldCredentialID, OldKey>> \in state.keychainBindings
    /\ state' = [state EXCEPT
        !.keychainBindings =
            @ \ {<<state.oldCredentialID, OldKey>>}
                ]

BeginRestart ==
    /\ state.phase = "newVerified"
    /\ state.newCheckpointVerified
    /\ state' = [state EXCEPT !.phase = "restarting"]

RestartFromNewCheckpoint ==
    /\ state.phase = "restarting"
    /\ state.newCheckpointVerified
    /\ state' = [state EXCEPT
        !.phase = "journalCreating",
        !.loadedFormat = state.checkpointFormat,
        !.loadedKey = state.checkpointKey,
        !.journalFormat = state.checkpointFormat,
        !.journalKey = state.checkpointKey
                ]

SynchronizeFreshJournalHeader ==
    /\ state.phase = "journalCreating"
    /\ state.journalFormat = state.checkpointFormat
    /\ state.journalKey = NewKey
    /\ state' = [state EXCEPT
        !.phase = "journalHeader",
        !.freshJournalHeaderSynced = TRUE,
        !.oldJournalExists = TRUE
                ]

PublishFreshJournalClaim ==
    /\ state.phase = "journalHeader"
    /\ state.freshJournalHeaderSynced
    /\ state' = [state EXCEPT
        !.phase = "journalClaimWritten",
        !.freshJournalClaimWritten = TRUE,
        !.oldActiveRecord = TRUE
                ]

SynchronizeFreshJournalClaim ==
    /\ state.phase = "journalClaimWritten"
    /\ state.freshJournalClaimWritten
    /\ state' = [state EXCEPT
        !.phase = "journalReady",
        !.freshJournalClaimSynced = TRUE
                ]

EnableEditingAfterRestart ==
    /\ state.phase = "journalReady"
    /\ state.newCheckpointVerified
    /\ state.loadedFormat = state.checkpointFormat
    /\ state.loadedKey = state.checkpointKey
    /\ state.journalFormat = state.checkpointFormat
    /\ state.journalKey = state.checkpointKey
    /\ state.freshJournalHeaderSynced
    /\ state.freshJournalClaimSynced
    /\ state' = [state EXCEPT
        !.phase = "editable",
        !.editable = TRUE
                ]

CancelOrFailTransition ==
    /\ state.transitionStarted
    /\ state.phase \in {
        "freezing", "oldInstalled", "oldVerified", "oldJournalDeleted",
        "oldJournalCleared", "targetCredentialProvisioned",
        "targetCredentialVerified", "exporting", "fenced"
                }
    /\ \E outcome \in {"cancelled", "failed"}:
        state' = [state EXCEPT
            !.phase = outcome,
            !.editable = FALSE,
            !.stagedTargetCredentialID = None,
            !.targetCredentialReadBackVerified = FALSE
                ]

Crash ==
    /\ state.transitionStarted
    /\ state.phase \notin {"crashed", "editable"}
    /\ state' = [state EXCEPT
        !.phase = "crashed",
        !.editable = FALSE,
        !.stagedTargetCredentialID = None,
        !.targetCredentialReadBackVerified = FALSE
                ]

RetryFromArtifacts ==
    /\ state.phase \in {"cancelled", "failed", "crashed"}
    /\ state' = [state EXCEPT
        !.phase = ResumePhaseFromArtifacts,
        !.editable = FALSE,
        !.exportedNotes =
            IF ResumePhaseFromArtifacts = "oldJournalCleared" THEN {} ELSE @,
        !.exportStartCatalogToken =
            IF ResumePhaseFromArtifacts = "oldJournalCleared"
            THEN state.catalogToken ELSE @,
        !.stagedTargetCredentialID = None,
        !.targetCredentialReadBackVerified = FALSE
                ]

Next ==
    \/ BeginControlledTransition
    \/ SynchronizeOldJournal
    \/ SettleOldSeparateFiles
    \/ InstallCompleteOldCheckpoint
    \/ VerifyCompleteOldCheckpoint
    \/ QualifyLocalOldCheckpoint
    \/ ObserveICloudOldCheckpointUpload
    \/ DeleteOldJournal
    \/ ClearOldActiveRecord
    \/ BeginPlaintextExport
    \/ ExternalFileDiverges
    \/ ExternalFileArrivesAfterInstall
    \/ ExportPlaintextNote
    \/ TakeExportFence
    \/ RetryPlaintextExport
    \/ InstallPlaintextCheckpoint
    \/ VerifyPlaintextCheckpoint
    \/ ProvisionTargetCredential
    \/ VerifyTargetCredential
    \/ InstallRekeyedCheckpoint
    \/ VerifyRekeyedCheckpoint
    \/ DeleteOldCredential
    \/ BeginRestart
    \/ RestartFromNewCheckpoint
    \/ SynchronizeFreshJournalHeader
    \/ PublishFreshJournalClaim
    \/ SynchronizeFreshJournalClaim
    \/ EnableEditingAfterRestart
    \/ CancelOrFailTransition
    \/ Crash
    \/ RetryFromArtifacts

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(SynchronizeOldJournal)
    /\ WF_vars(SettleOldSeparateFiles)
    /\ WF_vars(ExportPlaintextNote)
    /\ WF_vars(TakeExportFence)
    /\ WF_vars(RetryPlaintextExport)
    /\ WF_vars(SynchronizeFreshJournalHeader)
    /\ WF_vars(PublishFreshJournalClaim)
    /\ WF_vars(SynchronizeFreshJournalClaim)
    /\ WF_vars(EnableEditingAfterRestart)

TypeOK ==
    /\ state.phase \in Phases
    /\ state.reason \in Reasons
    /\ state.rootKind \in RootKinds
    /\ state.transitionKind \in TransitionKinds
    /\ state.oldFormat \in OldFormats
    /\ state.transitionStarted \in BOOLEAN
    /\ state.liveNotes \subseteq Notes
    /\ state.frozenNotes \subseteq Notes
    /\ state.editable \in BOOLEAN
    /\ state.journalFormat \in Formats
    /\ state.journalKey \in {OldKey, NewKey}
    /\ state.oldJournalExists \in BOOLEAN
    /\ state.oldActiveRecord \in BOOLEAN
    /\ state.pendingJournal \subseteq Notes
    /\ state.oldJournalDurable \subseteq Notes
    /\ state.separateFilesSettled \in BOOLEAN
    /\ state.checkpointID \in CheckpointIDs
    /\ state.usedCheckpointIDs \subseteq CheckpointIDs
    /\ state.checkpointInstallCount \in [CheckpointIDs -> 0..1]
    /\ state.checkpointFormat \in Formats
    /\ state.checkpointKey \in {OldKey, NewKey}
    /\ state.checkpointCredentialID \in CredentialIDs \cup {None}
    /\ state.checkpointNotes \subseteq Notes
    /\ state.encryptionEnabled \in BOOLEAN
    /\ state.oldCheckpointVerified \in BOOLEAN
    /\ state.oldInstallWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.oldReplacementQualified \in BOOLEAN
    /\ state.qualificationKind \in QualificationKinds
    /\ state.returnedCheckpoint \in CheckpointIDs \cup {None}
    /\ state.deletionWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X CheckpointIDs)
    /\ state.catalogToken \in 0..MaxCatalogToken
    /\ state.divergentFiles \subseteq Notes
    /\ state.preservedDivergences \subseteq Notes
    /\ state.postInstallExternal \subseteq Notes
    /\ state.exportedNotes \subseteq Notes
    /\ state.exportStartCatalogToken \in 0..MaxCatalogToken
    /\ state.exportFenceCatalogToken \in 0..MaxCatalogToken
    /\ state.newCheckpointInstalled \in BOOLEAN
    /\ state.newCheckpointVerified \in BOOLEAN
    /\ state.stagedNewNotes \subseteq Notes
    /\ state.newInstallWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.rekeyInstallWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.keychainBindings \subseteq
        (CredentialIDs \X {OldKey, NewKey})
    /\ state.usedCredentialIDs \subseteq CredentialIDs
    /\ state.credentialProvisionCount \in [CredentialIDs -> 0..1]
    /\ state.oldCredentialID \in CredentialIDs
    /\ state.stagedTargetCredentialID \in CredentialIDs \cup {None}
    /\ state.targetCredentialReadBackVerified \in BOOLEAN
    /\ state.loadedFormat \in Formats
    /\ state.loadedKey \in {OldKey, NewKey}
    /\ state.freshJournalHeaderSynced \in BOOLEAN
    /\ state.freshJournalClaimWritten \in BOOLEAN
    /\ state.freshJournalClaimSynced \in BOOLEAN
    /\ state.persistedPhaseLedger \in BOOLEAN

LiveNotesAlwaysHaveARecoverableArtifact ==
    LiveWorkRecoverable

OldJournalDeletionWasHistoricallyQualified ==
    /\ ( /\ ~state.oldJournalExists
         /\ ~state.newCheckpointVerified
         => state.deletionWitnesses # {} )
    /\ \A witness \in state.deletionWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]

OldCheckpointInstallHadEverySettledInput ==
    \A witness \in state.oldInstallWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]

ActiveRecordClearsOnlyAfterJournalRemoval ==
    ( /\ ~state.oldActiveRecord
      /\ ~state.newCheckpointVerified )
    => ~state.oldJournalExists

OldCheckpointIsTheRestartMarkerUntilNewInstall ==
    ~state.newCheckpointInstalled =>
        /\ state.checkpointFormat \in OldFormats
        /\ state.checkpointKey = OldKey
        /\ state.checkpointCredentialID = state.oldCredentialID
        /\ <<state.oldCredentialID, OldKey>> \in state.keychainBindings

NewInstallRequiresCompleteStableExport ==
    /\ ( /\ state.newCheckpointInstalled
         /\ state.transitionKind = "plaintextExport"
         /\ ~state.newCheckpointVerified
         => /\ state.newInstallWitnesses # {}
            /\ state.checkpointNotes = state.frozenNotes
            /\ state.checkpointFormat = "plaintext"
            /\ state.checkpointKey = NewKey
            /\ ~state.encryptionEnabled )
    /\ \A witness \in state.newInstallWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]

RekeyInstallRequiresReadBackFreshCredential ==
    /\ ( /\ state.newCheckpointInstalled
         /\ state.transitionKind = "encryptedRekey"
         => /\ state.rekeyInstallWitnesses # {}
            /\ state.checkpointFormat = state.oldFormat
            /\ state.checkpointKey = NewKey
            /\ state.checkpointCredentialID \in CredentialIDs
            /\ <<state.checkpointCredentialID, NewKey>> \in
                state.keychainBindings
            /\ state.encryptionEnabled )
    /\ \A witness \in state.rekeyInstallWitnesses:
        /\ witness[1]
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]

EveryInstalledRememberedCheckpointHasItsCredential ==
    state.checkpointFormat # "plaintext" =>
        /\ state.checkpointCredentialID \in CredentialIDs
        /\ <<state.checkpointCredentialID, state.checkpointKey>> \in
            state.keychainBindings

TargetProvisioningNeverInvalidatesAcceptedCredential ==
    ~state.newCheckpointInstalled =>
        <<state.oldCredentialID, OldKey>> \in state.keychainBindings

OldCredentialCleanupIsPostCommit ==
    <<state.oldCredentialID, OldKey>> \notin state.keychainBindings =>
        state.newCheckpointVerified

DivergentFilesForceRetryOrArePreservedBeforeVerification ==
    /\ (state.newCheckpointVerified =>
        state.divergentFiles \subseteq
            state.preservedDivergences \cup state.postInstallExternal)
    /\ ( /\ state.phase = "fenced"
         /\ state.divergentFiles \ state.preservedDivergences # {}
         => ~ExportFenceStable )

EditingRequiresOneConsistentArtifactContract ==
    state.editable =>
        /\ state.loadedFormat = state.checkpointFormat
        /\ state.loadedKey = state.checkpointKey
        /\ state.journalFormat = state.checkpointFormat
        /\ state.journalKey = state.checkpointKey
        /\ state.oldJournalExists
        /\ state.oldActiveRecord
        /\ \/ state.checkpointFormat = "plaintext"
           \/ <<state.checkpointCredentialID, state.checkpointKey>> \in
                state.keychainBindings
        /\ \/ state.phase = "running"
           \/ /\ state.phase = "editable"
              /\ state.newCheckpointVerified
              /\ state.freshJournalHeaderSynced
              /\ state.freshJournalClaimWritten
              /\ state.freshJournalClaimSynced

FinalStorageModeIsDerivedFromArtifacts ==
    /\ ( /\ state.newCheckpointVerified
         /\ state.transitionKind = "plaintextExport"
         => /\ state.checkpointFormat = "plaintext"
            /\ state.checkpointKey = NewKey
            /\ state.checkpointCredentialID = None
            /\ ~state.encryptionEnabled)
    /\ ( /\ state.newCheckpointVerified
         /\ state.transitionKind = "encryptedRekey"
         => /\ state.checkpointFormat = state.oldFormat
            /\ state.checkpointKey = NewKey
            /\ state.checkpointCredentialID \in CredentialIDs
            /\ state.encryptionEnabled)
    /\ ( /\ state.newCheckpointVerified
         /\ state.rootKind = "icloud"
         => FirstClassMode )

NoMigrationPhaseLedger ==
    ~state.persistedPhaseLedger

CheckpointIDsAreNeverReused ==
    \A checkpoint \in CheckpointIDs:
        state.checkpointInstallCount[checkpoint] <= 1

CredentialIDsAreNeverReused ==
    \A credential \in CredentialIDs:
        state.credentialProvisionCount[credential] <= 1

ExportProgress ==
    state.phase = "exporting"
    ~> state.phase \in {"fenced", "cancelled", "failed", "crashed"}

FreshJournalProgress ==
    state.phase = "journalCreating"
    ~> state.phase \in {"editable", "crashed"}

ChangedFenceProgress ==
    /\ state.phase = "fenced"
    /\ ~ExportFenceStable
    ~> state.phase \in {"exporting", "cancelled", "failed", "crashed"}

=============================================================================
