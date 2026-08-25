----------------------- MODULE ReconciliationSafety ------------------------
EXTENDS FiniteSets, Naturals

\* Versions are immutable persistent version identifiers. catalogToken values
\* are opaque; Naturals and +1 only provide bounded fresh values for equality.
\* processedVersions records traversal only; provider-version representation is
\* tracked separately by publishedRepresentedVersions.

CONSTANTS
    Versions,
    CanonicalVersion,
    UnresolvedVersion,
    NonlocalVersion,
    States,
    BaseState,
    LocalState,
    RemoteState,
    OtherState,
    MergedState,
    Deleted,
    Names,
    BaseName,
    LocalName,
    RemoteName,
    Sessions,
    InitialSession,
    CheckpointIDs,
    InitialCheckpoint,
    MaxModelCounter,
    EnabledScenarios,
    None

ASSUME
    /\ Versions = {CanonicalVersion, UnresolvedVersion, NonlocalVersion}
    /\ {BaseState, LocalState, RemoteState, OtherState, MergedState, Deleted}
        \subseteq States
    /\ Cardinality({BaseState, LocalState, RemoteState, OtherState,
                     MergedState, Deleted}) = 6
    /\ {BaseName, LocalName, RemoteName} \subseteq Names
    /\ Cardinality({BaseName, LocalName, RemoteName}) = 3
    /\ InitialSession \in Sessions
    /\ InitialCheckpoint \in CheckpointIDs
    /\ MaxModelCounter \in Nat
    /\ MaxModelCounter >= 3
    /\ None \notin Sessions
    /\ None \notin CheckpointIDs

VARIABLE state

vars == <<state>>

Scenarios == {
    "fastForward", "twoEditsMerge", "missingBase", "unsafeMerge",
    "deleteEdit", "localDeleteRemoteEdit", "renameRace", "renameOnlyRace",
    "renameRemoteEdit", "unmatchedIdentity", "ambiguousIdentity",
    "pathTimestampIdentity", "filenameContentIdentity", "multiVersion",
    "localEditRemoteUnchanged", "remoteRenameLocalEdit",
    "remoteRenameOnly", "localRenameRemoteUnchanged",
    "localRenameRemoteDelete", "localDeleteRemoteRename",
    "localRenameTwoEditsMerge", "remoteRenameTwoEditsMerge"
}

ASSUME
    /\ EnabledScenarios \subseteq Scenarios
    /\ EnabledScenarios # {}

TxnStates == {"idle", "processing", "fenced"}
Outcomes == {
    "pending", "same", "canonicalSelected", "merged", "preserved", "deleteEdit",
    "unmatched", "localWins"
}
Artifacts == States \X Names

InitialOriginalState(scenario) ==
    CASE scenario \in {"fastForward", "filenameContentIdentity"} -> BaseState
      [] scenario \in {
            "localDeleteRemoteEdit", "localDeleteRemoteRename"
         } -> Deleted
      [] scenario = "multiVersion" -> BaseState
      [] scenario \in {
            "renameRace", "renameOnlyRace", "renameRemoteEdit", "remoteRenameOnly",
            "localRenameRemoteUnchanged", "localRenameRemoteDelete"
         } -> BaseState
      [] OTHER -> LocalState

InitialOriginalName(scenario) ==
    IF scenario \in {
        "renameRace", "renameOnlyRace", "renameRemoteEdit",
        "localRenameRemoteUnchanged",
        "localRenameRemoteDelete", "localRenameTwoEditsMerge"
    }
    THEN LocalName ELSE BaseName

BaseAvailable(scenario) == scenario # "missingBase"
MergeIsSafe(scenario) == scenario \in {
    "twoEditsMerge", "localRenameTwoEditsMerge",
    "remoteRenameTwoEditsMerge"
}

ExternalState(scenario, version) ==
    CASE scenario \in {
            "localEditRemoteUnchanged", "remoteRenameLocalEdit",
            "remoteRenameOnly", "localRenameRemoteUnchanged",
            "localDeleteRemoteRename", "renameOnlyRace"
         }
            /\ version = CanonicalVersion -> BaseState
      [] scenario = "deleteEdit" /\ version = CanonicalVersion -> Deleted
      [] scenario = "multiVersion" /\ version = CanonicalVersion -> Deleted
      [] scenario = "localRenameRemoteDelete"
            /\ version = CanonicalVersion -> Deleted
      [] version = UnresolvedVersion -> OtherState
      [] version = NonlocalVersion -> RemoteState
      [] OTHER -> RemoteState

ExternalName(scenario, version) ==
    IF scenario \in {
        "renameRace", "renameOnlyRace", "remoteRenameLocalEdit",
        "remoteRenameOnly",
        "localDeleteRemoteRename", "remoteRenameTwoEditsMerge"
    }
        /\ version = CanonicalVersion
    THEN RemoteName
    ELSE BaseName

IdentityEvidence(scenario) ==
    CASE scenario = "unmatchedIdentity" -> {}
      [] scenario = "ambiguousIdentity" -> {"filename", "content"}
      [] scenario = "pathTimestampIdentity" -> {"path", "timestamp"}
      [] scenario = "filenameContentIdentity" ->
            {"filename", "content", "unambiguous"}
      [] OTHER -> {"stable"}

IdentityMatches(scenario, version) ==
    /\ version \in Versions
    /\ \/ "stable" \in IdentityEvidence(scenario)
       \/ {"filename", "content", "unambiguous"}
            \subseteq IdentityEvidence(scenario)

ExternalArtifact(version) ==
    <<ExternalState(state.scenario, version),
      ExternalName(state.scenario, version)>>

SnapshotArtifact == <<state.snapshotOriginal, state.snapshotName>>
PublishedArtifact == <<state.originalState, state.originalName>>
CandidateArtifact == <<state.candidateOriginal, state.candidateName>>

Role(version) ==
    CASE version = CanonicalVersion -> "canonical"
      [] version = UnresolvedVersion -> "unresolved"
      [] OTHER -> "nonlocal"

Represents(artifact, original, conflicts, mergedInputs) ==
    \/ artifact = original
    \/ /\ artifact[1] = Deleted
       /\ original[1] = Deleted
    \/ artifact \in conflicts
    \/ artifact \in mergedInputs

EveryDifferingVersionRepresented ==
    /\ ( /\ state.snapshotOriginal = BaseState
          /\ state.snapshotName = BaseName
         \/ Represents(SnapshotArtifact, CandidateArtifact,
                       state.candidateConflicts,
                       state.candidateMergedInputs) )
    /\ \A version \in state.snapshotVersions:
        \/ ExternalArtifact(version) = SnapshotArtifact
        \/ Represents(ExternalArtifact(version), CandidateArtifact,
                      state.candidateConflicts, state.candidateMergedInputs)

ProcessedState(version, outcome, original, name, conflicts, mergedInputs) ==
    [state EXCEPT
        !.processedVersions = @ \cup {version},
        !.outcomes[version] = outcome,
        !.candidateOriginal = original,
        !.candidateName = name,
        !.candidateConflicts = conflicts,
        !.candidateMergedInputs = mergedInputs
        ]

Init ==
    \E scenario \in EnabledScenarios:
    state = [
        scenario |-> scenario,
        activeSession |-> InitialSession,
        usedSessions |-> {InitialSession},
        sessionInstallCount |-> [session \in Sessions |->
            IF session = InitialSession THEN 1 ELSE 0],
        originalState |-> InitialOriginalState(scenario),
        originalName |-> InitialOriginalName(scenario),
        conflictArtifacts |-> {},
        mergedInputs |-> {},
        structuralGeneration |-> 0,
        noteLSN |-> 0,
        catalogToken |-> 0,
        deliveredVersions |-> {},
        knownVersions |-> {},
        unreadableVersions |-> {},
        dirty |-> FALSE,
        txnState |-> "idle",
        snapshotVersions |-> {},
        snapshotCatalogToken |-> 0,
        snapshotSession |-> None,
        snapshotStructuralGeneration |-> 0,
        snapshotNoteLSN |-> 0,
        snapshotOriginal |-> InitialOriginalState(scenario),
        snapshotName |-> InitialOriginalName(scenario),
        snapshotConflicts |-> {},
        enumerationComplete |-> FALSE,
        processedVersions |-> {},
        outcomes |-> [version \in Versions |-> "pending"],
        candidateOriginal |-> InitialOriginalState(scenario),
        candidateName |-> InitialOriginalName(scenario),
        candidateConflicts |-> {},
        candidateMergedInputs |-> {},
        secondCatalogToken |-> 0,
        secondVersions |-> {},
        publishedRepresentedVersions |-> {},
        resolutionEligibleVersions |-> {},
        fileDurableVersions |-> {},
        installedCheckpoint |-> InitialCheckpoint,
        usedCheckpointIDs |-> {InitialCheckpoint},
        checkpointInstallCount |-> [checkpoint \in CheckpointIDs |->
            IF checkpoint = InitialCheckpoint THEN 1 ELSE 0],
        installedCoverage |-> {},
        confirmedCheckpoint |-> None,
        confirmedCoverage |-> {},
        uploadCallbackObserved |-> FALSE,
        resolvedVersions |-> {},
        resolutionWitnesses |-> {},
        commitWitnesses |-> {},
        completeDirtyWitnesses |-> {},
        retryDirtyWitnesses |-> {}
        ]

DeliverVersion ==
    /\ state.catalogToken < MaxModelCounter
    /\ \E version \in Versions \ state.deliveredVersions:
        state' = [state EXCEPT
            !.deliveredVersions = @ \cup {version},
            !.knownVersions = @ \cup {version},
            !.catalogToken = @ + 1,
            !.dirty = TRUE
        ]

ProviderCatalogTokenChangesWithoutVersionSet ==
    /\ state.txnState \in {"processing", "fenced"}
    /\ state.catalogToken < MaxModelCounter
    /\ state' = [state EXCEPT
        !.catalogToken = @ + 1,
        !.dirty = TRUE
        ]

ProviderVersionSetChangesWithoutCatalogToken ==
    /\ state.txnState \in {"processing", "fenced"}
    /\ \E version \in Versions \ state.deliveredVersions:
        state' = [state EXCEPT
            !.deliveredVersions = @ \cup {version},
            !.knownVersions = @ \cup {version},
            !.dirty = TRUE
            ]

MakeVersionUnreadable ==
    /\ \E version \in state.knownVersions \ state.unreadableVersions:
        state' = [state EXCEPT !.unreadableVersions = @ \cup {version}]

MakeVersionReadable ==
    /\ \E version \in state.unreadableVersions:
        state' = [state EXCEPT !.unreadableVersions = @ \ {version}]

UserEditsOriginal ==
    /\ state.txnState \in {"processing", "fenced"}
    /\ state.noteLSN < MaxModelCounter
    /\ state.noteLSN = state.snapshotNoteLSN
    /\ LET noteState ==
        IF state.originalState = OtherState THEN LocalState ELSE OtherState
       IN state' = [state EXCEPT
            !.originalState = noteState,
            !.noteLSN = @ + 1
                ]

UserRenamesOriginal ==
    /\ state.txnState \in {"processing", "fenced"}
    /\ state.noteLSN < MaxModelCounter
    /\ state.noteLSN = state.snapshotNoteLSN
    /\ LET name ==
        IF state.originalName = RemoteName THEN LocalName ELSE RemoteName
       IN state' = [state EXCEPT
            !.originalName = name,
            !.noteLSN = @ + 1
                ]

ModelStructureChanges ==
    /\ state.txnState \in {"processing", "fenced"}
    /\ state.structuralGeneration < MaxModelCounter
    /\ state.structuralGeneration = state.snapshotStructuralGeneration
    /\ state' = [state EXCEPT !.structuralGeneration = @ + 1]

ReplaceRootSessionIncarnation ==
    /\ state.txnState \in {"processing", "fenced"}
    /\ state.structuralGeneration < MaxModelCounter
    /\ state.structuralGeneration = state.snapshotStructuralGeneration
    /\ state.catalogToken < MaxModelCounter
    /\ \E session \in Sessions \ state.usedSessions:
        state' = [state EXCEPT
            !.activeSession = session,
            !.usedSessions = @ \cup {session},
            !.sessionInstallCount[session] = @ + 1,
            !.structuralGeneration = @ + 1,
            !.catalogToken = @ + 1,
            !.knownVersions = {},
            !.dirty = TRUE
        ]

ReplaceRootSessionIncarnationWithSameInputs ==
    /\ state.txnState \in {"processing", "fenced"}
    /\ \E session \in Sessions \ state.usedSessions:
        state' = [state EXCEPT
            !.activeSession = session,
            !.usedSessions = @ \cup {session},
            !.sessionInstallCount[session] = @ + 1,
            !.dirty = TRUE
            ]

StartTransaction ==
    /\ state.txnState = "idle"
    /\ state.dirty
    /\ state.knownVersions \ state.resolvedVersions # {}
    /\ \E complete \in BOOLEAN:
        state' = [state EXCEPT
            !.txnState = "processing",
            !.snapshotVersions = state.knownVersions \ state.resolvedVersions,
            !.snapshotCatalogToken = state.catalogToken,
            !.snapshotSession = state.activeSession,
            !.snapshotStructuralGeneration = state.structuralGeneration,
            !.snapshotNoteLSN = state.noteLSN,
            !.snapshotOriginal = state.originalState,
            !.snapshotName = state.originalName,
            !.snapshotConflicts = state.conflictArtifacts,
            !.enumerationComplete = complete,
            !.processedVersions = {},
            !.outcomes = [version \in Versions |-> "pending"],
            !.candidateOriginal = state.originalState,
            !.candidateName = state.originalName,
            !.candidateConflicts = state.conflictArtifacts,
            !.candidateMergedInputs = state.mergedInputs,
            !.secondCatalogToken = 0,
            !.secondVersions = {}
        ]

ProcessVersion ==
    /\ state.txnState = "processing"
    /\ \E version \in
            state.snapshotVersions \ (state.processedVersions \cup
                                      state.unreadableVersions):
        LET external == ExternalArtifact(version)
            externalState == ExternalState(state.scenario, version)
            externalName == ExternalName(state.scenario, version)
            conflicts == state.candidateConflicts \cup {external}
            merged == state.candidateMergedInputs \cup
                {SnapshotArtifact, external}
        IN
        IF ~IdentityMatches(state.scenario, version)
        THEN state' = ProcessedState(
            version, "unmatched", state.candidateOriginal,
            state.candidateName, conflicts, state.candidateMergedInputs)
        ELSE IF external = SnapshotArtifact
        THEN state' = ProcessedState(
            version, "same", state.candidateOriginal,
            state.candidateName, state.candidateConflicts,
            state.candidateMergedInputs)
        ELSE IF version # CanonicalVersion
        THEN state' = ProcessedState(
            version, "preserved", state.candidateOriginal,
            state.candidateName, conflicts, state.candidateMergedInputs)
        ELSE IF
            /\ externalName # state.snapshotName
            /\ state.snapshotName # BaseName
            /\ externalName # BaseName
        THEN state' = ProcessedState(
            version, "preserved", state.candidateOriginal,
            state.candidateName, conflicts, state.candidateMergedInputs)
        ELSE IF
            /\ state.snapshotName # BaseName
            /\ externalName = BaseName
            /\ state.snapshotOriginal = BaseState
            /\ externalState # Deleted
        THEN state' = ProcessedState(
            version, "merged", externalState,
            state.candidateName, state.candidateConflicts, merged)
        ELSE IF
            /\ state.snapshotName = BaseName
            /\ externalName # BaseName
            /\ externalState = BaseState
            /\ state.snapshotOriginal # BaseState
            /\ state.snapshotOriginal # Deleted
        THEN state' = ProcessedState(
            version, "merged", state.candidateOriginal,
            externalName, state.candidateConflicts, merged)
        ELSE IF
            /\ externalState = state.snapshotOriginal
            /\ state.snapshotName = BaseName
        THEN state' = ProcessedState(
            version, "canonicalSelected", state.candidateOriginal,
            externalName, state.candidateConflicts,
            state.candidateMergedInputs)
        ELSE IF
            /\ externalState = Deleted
            /\ state.snapshotOriginal = BaseState
            /\ state.snapshotName = BaseName
        THEN state' = ProcessedState(
            version, "canonicalSelected", Deleted, state.candidateName,
            state.candidateConflicts, state.candidateMergedInputs)
        ELSE IF
            /\ externalState = Deleted
            /\ state.snapshotOriginal # Deleted
        THEN state' = ProcessedState(
            version, "deleteEdit", Deleted, state.candidateName,
            state.candidateConflicts \cup {SnapshotArtifact},
            state.candidateMergedInputs)
        ELSE IF
            /\ state.snapshotOriginal = Deleted
            /\ externalState # Deleted
        THEN state' = ProcessedState(
            version, "deleteEdit", Deleted, state.candidateName,
            conflicts, state.candidateMergedInputs)
        ELSE IF ~BaseAvailable(state.scenario)
        THEN state' = ProcessedState(
            version, "preserved", state.candidateOriginal,
            state.candidateName, conflicts, state.candidateMergedInputs)
        ELSE IF
            /\ state.snapshotOriginal = BaseState
            /\ externalState # Deleted
        THEN state' = ProcessedState(
            version, "canonicalSelected", externalState, externalName,
            state.candidateConflicts, state.candidateMergedInputs)
        ELSE IF
            /\ externalState = BaseState
            /\ state.snapshotOriginal # Deleted
        THEN state' = ProcessedState(
            version, "localWins", state.candidateOriginal,
            state.candidateName, state.candidateConflicts,
            merged)
        ELSE IF MergeIsSafe(state.scenario)
        THEN state' = ProcessedState(
            version, "merged", MergedState,
            IF /\ state.snapshotName = BaseName
               /\ externalName # BaseName
            THEN externalName ELSE state.candidateName,
            state.candidateConflicts, merged)
        ELSE state' = ProcessedState(
            version, "preserved", state.candidateOriginal,
            state.candidateName, conflicts, state.candidateMergedInputs)

TakeSecondFence ==
    /\ state.txnState = "processing"
    /\ state.processedVersions \cup
        (state.snapshotVersions \cap state.unreadableVersions)
        = state.snapshotVersions
    /\ state' = [state EXCEPT
        !.txnState = "fenced",
        !.secondCatalogToken = state.catalogToken,
        !.secondVersions = state.knownVersions \ state.resolvedVersions
        ]

ExactSnapshots ==
    /\ state.snapshotCatalogToken = state.secondCatalogToken
    /\ state.snapshotVersions = state.secondVersions

UnchangedModelInputs ==
    /\ state.snapshotSession = state.activeSession
    /\ state.snapshotStructuralGeneration = state.structuralGeneration
    /\ state.snapshotNoteLSN = state.noteLSN

SafeCompleteCommit ==
    /\ state.txnState = "fenced"
    /\ state.snapshotVersions # {}
    /\ state.enumerationComplete
    /\ state.snapshotVersions \cap state.unreadableVersions = {}
    /\ ExactSnapshots
    /\ UnchangedModelInputs
    /\ EveryDifferingVersionRepresented

CommitCompleteTransaction ==
    /\ SafeCompleteCommit
    /\ state.noteLSN < MaxModelCounter
    /\ LET mustRemainDirty ==
                \/ state.catalogToken # state.secondCatalogToken
                \/ state.knownVersions \ state.resolvedVersions #
                    state.secondVersions
           nextDirty == IF mustRemainDirty THEN TRUE ELSE FALSE
       IN state' = [state EXCEPT
            !.txnState = "idle",
            !.originalState = state.candidateOriginal,
            !.originalName = state.candidateName,
            !.conflictArtifacts = state.candidateConflicts,
            !.mergedInputs = state.candidateMergedInputs,
            !.noteLSN = @ + 1,
            !.publishedRepresentedVersions = @ \cup state.snapshotVersions,
            !.resolutionEligibleVersions = @ \cup state.snapshotVersions,
            !.dirty = nextDirty,
            !.completeDirtyWitnesses = @ \cup
                {<<mustRemainDirty, nextDirty>>},
            !.commitWitnesses = @ \cup
                {<<state.snapshotVersions # {},
                   state.enumerationComplete,
                   state.snapshotVersions \cap state.unreadableVersions = {},
                   ExactSnapshots,
                   UnchangedModelInputs,
                   EveryDifferingVersionRepresented>>}
            ]

CommitPartialPreservation ==
    /\ state.txnState = "fenced"
    /\ state.structuralGeneration < MaxModelCounter
    /\ \/ ~state.enumerationComplete
       \/ state.snapshotVersions \cap state.unreadableVersions # {}
       \/ ~ExactSnapshots
    /\ UnchangedModelInputs
    /\ state.candidateOriginal = state.snapshotOriginal
    /\ state.candidateName = state.snapshotName
    /\ LET nextDirty == TRUE
       IN state' = [state EXCEPT
            !.txnState = "idle",
            !.conflictArtifacts = state.candidateConflicts,
            !.mergedInputs = state.candidateMergedInputs,
            !.structuralGeneration = @ + 1,
            !.publishedRepresentedVersions = @ \cup state.processedVersions,
            !.dirty = nextDirty,
            !.retryDirtyWitnesses = @ \cup {<<TRUE, nextDirty>>}
            ]

DiscardTransaction ==
    /\ state.txnState = "fenced"
    /\ LET nextDirty == TRUE
       IN state' = [state EXCEPT
            !.txnState = "idle",
            !.dirty = nextDirty,
            !.retryDirtyWitnesses = @ \cup {<<TRUE, nextDirty>>}
            ]

PersistRepresentedVersions ==
    /\ state.publishedRepresentedVersions \ state.fileDurableVersions # {}
    /\ state' = [state EXCEPT
        !.fileDurableVersions = @ \cup state.publishedRepresentedVersions
        ]

InstallVersionCheckpoint ==
    /\ state.fileDurableVersions \ state.installedCoverage # {}
    /\ \E checkpoint \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = [state EXCEPT
            !.installedCheckpoint = checkpoint,
            !.usedCheckpointIDs = @ \cup {checkpoint},
            !.checkpointInstallCount[checkpoint] = @ + 1,
            !.installedCoverage = state.fileDurableVersions,
            !.confirmedCheckpoint = None,
            !.confirmedCoverage = {},
            !.uploadCallbackObserved = FALSE
        ]

CheckpointUploadCallback ==
    /\ state.installedCoverage # {}
    /\ ~state.uploadCallbackObserved
    /\ \E returnedCheckpoint \in CheckpointIDs \cup {None}:
        state' = [state EXCEPT
            !.confirmedCheckpoint =
                IF returnedCheckpoint = state.installedCheckpoint
                THEN returnedCheckpoint ELSE None,
            !.confirmedCoverage =
                IF returnedCheckpoint = state.installedCheckpoint
                THEN state.installedCoverage ELSE {},
            !.uploadCallbackObserved = TRUE
        ]

ResolveVersion ==
    /\ state.confirmedCheckpoint = state.installedCheckpoint
    /\ \E version \in
            (state.resolutionEligibleVersions \cap state.confirmedCoverage)
                \ state.resolvedVersions:
        state' = [state EXCEPT
            !.resolvedVersions = @ \cup {version},
            !.resolutionWitnesses = @ \cup
                {<<version,
                   version \in state.resolutionEligibleVersions,
                   version \in state.fileDurableVersions,
                   version \in state.installedCoverage,
                   version \in state.confirmedCoverage,
                   state.confirmedCheckpoint = state.installedCheckpoint,
                   state.installedCheckpoint>>},
            !.dirty = TRUE
        ]

Next ==
    \/ DeliverVersion
    \/ ProviderCatalogTokenChangesWithoutVersionSet
    \/ ProviderVersionSetChangesWithoutCatalogToken
    \/ MakeVersionUnreadable
    \/ MakeVersionReadable
    \/ UserEditsOriginal
    \/ UserRenamesOriginal
    \/ ModelStructureChanges
    \/ ReplaceRootSessionIncarnation
    \/ ReplaceRootSessionIncarnationWithSameInputs
    \/ StartTransaction
    \/ ProcessVersion
    \/ TakeSecondFence
    \/ CommitCompleteTransaction
    \/ CommitPartialPreservation
    \/ DiscardTransaction
    \/ PersistRepresentedVersions
    \/ InstallVersionCheckpoint
    \/ CheckpointUploadCallback
    \/ ResolveVersion

InternalTransactionProgress ==
    ProcessVersion \/ TakeSecondFence \/ CommitCompleteTransaction
        \/ CommitPartialPreservation \/ DiscardTransaction

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(StartTransaction)
    /\ WF_vars(InternalTransactionProgress)

TypeOK ==
    /\ state.scenario \in Scenarios
    /\ state.activeSession \in Sessions
    /\ state.usedSessions \subseteq Sessions
    /\ state.sessionInstallCount \in [Sessions -> 0..1]
    /\ state.originalState \in States
    /\ state.originalName \in Names
    /\ state.conflictArtifacts \subseteq Artifacts
    /\ state.mergedInputs \subseteq Artifacts
    /\ state.structuralGeneration \in Nat
    /\ state.noteLSN \in Nat
    /\ state.catalogToken \in Nat
    /\ state.deliveredVersions \subseteq Versions
    /\ state.knownVersions \subseteq Versions
    /\ state.unreadableVersions \subseteq Versions
    /\ state.dirty \in BOOLEAN
    /\ state.txnState \in TxnStates
    /\ state.snapshotVersions \subseteq Versions
    /\ state.snapshotCatalogToken \in Nat
    /\ state.snapshotSession \in Sessions \cup {None}
    /\ state.snapshotStructuralGeneration \in Nat
    /\ state.snapshotNoteLSN \in Nat
    /\ state.snapshotOriginal \in States
    /\ state.snapshotName \in Names
    /\ state.snapshotConflicts \subseteq Artifacts
    /\ state.enumerationComplete \in BOOLEAN
    /\ state.processedVersions \subseteq Versions
    /\ state.outcomes \in [Versions -> Outcomes]
    /\ state.candidateOriginal \in States
    /\ state.candidateName \in Names
    /\ state.candidateConflicts \subseteq Artifacts
    /\ state.candidateMergedInputs \subseteq Artifacts
    /\ state.secondCatalogToken \in Nat
    /\ state.secondVersions \subseteq Versions
    /\ state.publishedRepresentedVersions \subseteq Versions
    /\ state.resolutionEligibleVersions \subseteq Versions
    /\ state.fileDurableVersions \subseteq Versions
    /\ state.installedCheckpoint \in CheckpointIDs
    /\ state.usedCheckpointIDs \subseteq CheckpointIDs
    /\ state.checkpointInstallCount \in [CheckpointIDs -> 0..1]
    /\ state.installedCoverage \subseteq Versions
    /\ state.confirmedCheckpoint \in CheckpointIDs \cup {None}
    /\ state.confirmedCoverage \subseteq Versions
    /\ state.uploadCallbackObserved \in BOOLEAN
    /\ state.resolvedVersions \subseteq Versions
    /\ state.resolutionWitnesses \subseteq
        (Versions \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN
            \X BOOLEAN \X CheckpointIDs)
    /\ state.commitWitnesses \subseteq
        (BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.completeDirtyWitnesses \subseteq (BOOLEAN \X BOOLEAN)
    /\ state.retryDirtyWitnesses \subseteq (BOOLEAN \X BOOLEAN)

EveryCompleteCommitHadRealFencedSources ==
    state.commitWitnesses \subseteq
        {<<TRUE, TRUE, TRUE, TRUE, TRUE, TRUE>>}

RoutineCandidatesComeOnlyFromDeliveredVersions ==
    state.snapshotVersions \subseteq state.deliveredVersions

ResolutionRequiredHistoricalEligibilityAndDurability ==
    /\ state.resolvedVersions =
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

RootSessionIncarnationsAreNeverReused ==
    \A session \in Sessions:
        state.sessionInstallCount[session] <= 1

RepresentationDurabilityOrder ==
    /\ state.confirmedCoverage \subseteq state.installedCoverage
    /\ state.installedCoverage \subseteq state.fileDurableVersions
    /\ state.fileDurableVersions \subseteq state.publishedRepresentedVersions
    /\ state.resolutionEligibleVersions \subseteq state.publishedRepresentedVersions

LateProviderChangeKeepsDirty ==
    /\ state.txnState = "fenced"
    /\ \/ state.catalogToken # state.secondCatalogToken
       \/ state.knownVersions \ state.resolvedVersions # state.secondVersions
    => state.dirty

EveryCompleteCommitSetCorrectDirtyState ==
    state.completeDirtyWitnesses \subseteq
        {<<FALSE, FALSE>>, <<TRUE, TRUE>>}

EveryRetryPathKeptDirty ==
    state.retryDirtyWitnesses \subseteq {<<TRUE, TRUE>>}

LocalWinsRecordsBaseAncestry ==
    \A version \in state.processedVersions:
        state.outcomes[version] = "localWins" =>
            {SnapshotArtifact, ExternalArtifact(version)}
                \subseteq state.candidateMergedInputs

ExpectedInitialCanonicalOutcome(scenario) ==
    CASE scenario \in {
            "fastForward", "filenameContentIdentity", "multiVersion",
            "remoteRenameOnly"
         } -> "canonicalSelected"
      [] scenario \in {
            "twoEditsMerge", "renameRemoteEdit",
            "remoteRenameLocalEdit", "localRenameRemoteUnchanged",
            "localRenameTwoEditsMerge", "remoteRenameTwoEditsMerge"
         } -> "merged"
      [] scenario \in {
            "missingBase", "unsafeMerge", "renameRace", "renameOnlyRace"
         } -> "preserved"
      [] scenario \in {
            "deleteEdit", "localDeleteRemoteEdit",
            "localRenameRemoteDelete", "localDeleteRemoteRename"
         } -> "deleteEdit"
      [] scenario = "localEditRemoteUnchanged" -> "localWins"
      [] scenario \in {
            "unmatchedIdentity", "ambiguousIdentity",
            "pathTimestampIdentity"
         } -> "unmatched"

ExpectedInitialCanonicalArtifact(scenario) ==
    CASE scenario \in {"fastForward", "filenameContentIdentity"} ->
            <<RemoteState, BaseName>>
      [] scenario = "twoEditsMerge" -> <<MergedState, BaseName>>
      [] scenario \in {
            "missingBase", "unsafeMerge", "unmatchedIdentity",
            "ambiguousIdentity", "pathTimestampIdentity",
            "localEditRemoteUnchanged"
         } -> <<LocalState, BaseName>>
      [] scenario \in {
            "deleteEdit", "localDeleteRemoteEdit", "multiVersion",
            "localDeleteRemoteRename"
         } -> <<Deleted, BaseName>>
      [] scenario \in {"renameRace", "renameOnlyRace"} ->
            <<BaseState, LocalName>>
      [] scenario = "renameRemoteEdit" -> <<RemoteState, LocalName>>
      [] scenario = "remoteRenameLocalEdit" -> <<LocalState, RemoteName>>
      [] scenario = "remoteRenameOnly" -> <<BaseState, RemoteName>>
      [] scenario = "localRenameRemoteUnchanged" ->
            <<BaseState, LocalName>>
      [] scenario = "localRenameRemoteDelete" -> <<Deleted, LocalName>>
      [] scenario = "localRenameTwoEditsMerge" ->
            <<MergedState, LocalName>>
      [] scenario = "remoteRenameTwoEditsMerge" ->
            <<MergedState, RemoteName>>

InitialScenarioSnapshot ==
    /\ state.snapshotOriginal = InitialOriginalState(state.scenario)
    /\ state.snapshotName = InitialOriginalName(state.scenario)

ScenarioConflictDecisionsMatchPolicy ==
    /\ ((/\ CanonicalVersion \in state.processedVersions
          /\ InitialScenarioSnapshot)
        => /\ state.outcomes[CanonicalVersion] =
                ExpectedInitialCanonicalOutcome(state.scenario)
           /\ CandidateArtifact =
                ExpectedInitialCanonicalArtifact(state.scenario))
    /\ (InitialScenarioSnapshot =>
        \A version \in state.processedVersions \ {CanonicalVersion}:
            state.outcomes[version] =
                IF IdentityMatches(state.scenario, version)
                THEN "preserved" ELSE "unmatched")

DirtyKnownWorkEventuallyStarts ==
    /\ state.txnState = "idle"
    /\ state.dirty
    /\ state.knownVersions \ state.resolvedVersions # {}
    ~> \/ state.txnState # "idle"
       \/ ~state.dirty
       \/ state.knownVersions \ state.resolvedVersions = {}

=============================================================================
