------------------------- MODULE JournalLifecycle --------------------------
EXTENDS FiniteSets, Naturals

CONSTANTS
    JournalIDs, Journal1, Journal2,
    RootIDs, Root1, Root2,
    CheckpointIDs, InitialCheckpoint,
    Edits, SeedEdit, None

ASSUME
    /\ IsFiniteSet(JournalIDs)
    /\ IsFiniteSet(RootIDs)
    /\ IsFiniteSet(CheckpointIDs)
    /\ IsFiniteSet(Edits)
    /\ {Journal1, Journal2} \subseteq JournalIDs
    /\ Journal1 # Journal2
    /\ {Root1, Root2} \subseteq RootIDs
    /\ Root1 # Root2
    /\ InitialCheckpoint \in CheckpointIDs
    /\ SeedEdit \in Edits
    /\ None \notin JournalIDs
    /\ None \notin RootIDs
    /\ None \notin CheckpointIDs

VARIABLE state

vars == <<state>>

Instances == JournalIDs \X RootIDs
RootKinds == {"local", "icloud", "otherProvider", "unknown"}
Phases == {
    "closed", "locked", "blocked", "creating", "headerSynced",
    "claimWritten", "freshClaimed", "claimed", "running", "discovered",
    "recovered", "installed", "verified", "handoff", "deleted"
}
DiscoveryKinds == {"none", "claimed", "localBackup"}
QualificationKinds == {"none", "local", "icloud"}
Scenarios == {
    "fresh", "copiedFolder", "ambiguousClaims", "staleMatching",
    "unmatchedEntry", "unresolvableEntry", "restoredLocal",
    "unclaimedICloud", "headerMismatch", "missingClaim"
}

InitialRoot(scenario) ==
    IF scenario = "copiedFolder" THEN Root2 ELSE Root1

InitialRootKind(scenario, selectedKind) ==
    CASE scenario = "restoredLocal" -> "local"
      [] scenario = "unclaimedICloud" -> "icloud"
      [] OTHER -> selectedKind

InitialFiles(scenario) ==
    CASE scenario \in {"fresh", "missingClaim"} -> {}
      [] scenario = "ambiguousClaims" ->
            {<<Journal1, Root1>>, <<Journal2, Root1>>}
      [] OTHER -> {<<Journal1, InitialRoot(scenario)>>}

InitialClaims(scenario) ==
    CASE scenario \in {"fresh", "restoredLocal", "unclaimedICloud"} -> {}
      [] scenario = "ambiguousClaims" -> {Journal1, Journal2}
      [] OTHER -> {Journal1}

InitialClaimRoot(scenario, journal) ==
    CASE scenario = "unresolvableEntry" /\ journal = Journal1 -> None
      [] scenario \in {"copiedFolder", "unmatchedEntry"}
            /\ journal = Journal1 ->
            IF InitialRoot(scenario) = Root1 THEN Root2 ELSE Root1
      [] OTHER -> InitialRoot(scenario)

InitialHeaderID(scenario, instance) ==
    IF scenario = "headerMismatch" /\ instance[1] = Journal1
    THEN Journal2
    ELSE instance[1]

InitialUsed(scenario) ==
    {journal \in JournalIDs:
        \E root \in RootIDs: <<journal, root>> \in InitialFiles(scenario)}
        \cup InitialClaims(scenario)

InitialUnresolvable(scenario) ==
    IF scenario = "unresolvableEntry" THEN {Journal1} ELSE {}

InitialRemoteWriters(scenario) ==
    IF scenario = "unclaimedICloud"
    THEN {<<Journal1, InitialRoot(scenario)>>}
    ELSE {}

CurrentInstance == <<state.current, state.openRoot>>

JournalRecoveryEligible(instance) ==
    /\ instance \in state.files
    /\ instance \in state.syncedHeaders
    /\ state.headerIDs[instance] = instance[1]
    /\ state.headerBases[instance] # None
    /\ \/ state.headerBases[instance] = state.acceptedDatabaseCheckpoint
       \/ state.contents[instance] \subseteq state.checkpoint

ClaimResolvesToOpenRoot(journal) ==
    /\ journal \in state.claims
    /\ state.claimRoots[journal] = state.openRoot

PotentialMatchingClaims ==
    {journal \in state.claims:
        state.claimRoots[journal] = state.openRoot}

ValidClaimedCandidates ==
    {journal \in state.claims:
        /\ ClaimResolvesToOpenRoot(journal)
        /\ journal \in state.syncedClaims
        /\ journal \notin state.staleClaims
        /\ JournalRecoveryEligible(<<journal, state.openRoot>>)}

ValidUnclaimedCandidates ==
    {journal \in JournalIDs \ state.claims:
        JournalRecoveryEligible(<<journal, state.openRoot>>)}

RecoverableEvidence ==
    state.checkpoint \cup
    UNION {state.contents[instance] : instance \in state.files}

Init ==
    \E scenario \in Scenarios:
    \E selectedKind \in RootKinds:
        LET initialFiles == InitialFiles(scenario)
            initialClaims == InitialClaims(scenario)
            initialUsed == InitialUsed(scenario)
        IN state = [
            scenario |-> scenario,
            phase |-> "closed",
            rootKind |-> InitialRootKind(scenario, selectedKind),
            openRoot |-> InitialRoot(scenario),
            lockHeld |-> FALSE,
            used |-> initialUsed,
            files |-> initialFiles,
            syncedHeaders |-> initialFiles,
            headerIDs |-> [instance \in Instances |->
                IF instance \in initialFiles
                THEN InitialHeaderID(scenario, instance)
                ELSE None],
            headerBases |-> [instance \in Instances |->
                IF instance \in initialFiles THEN InitialCheckpoint ELSE None],
            claims |-> initialClaims,
            claimRoots |-> [journal \in JournalIDs |->
                IF journal \in initialClaims
                THEN InitialClaimRoot(scenario, journal)
                ELSE None],
            syncedClaims |-> initialClaims,
            staleClaims |->
                IF scenario = "staleMatching" THEN {Journal1} ELSE {},
            refreshPending |-> {},
            unresolvableEver |-> InitialUnresolvable(scenario),
            refreshedPairs |-> {},
            prunedClaims |-> {},
            pruneWitnesses |-> {},
            current |-> None,
            oldJournal |-> None,
            writable |-> FALSE,
            contents |-> [instance \in Instances |->
                IF instance \in initialFiles THEN {SeedEdit} ELSE {}],
            checkpoint |-> {},
            acceptedDatabaseCheckpoint |-> InitialCheckpoint,
            usedCheckpointIDs |-> {InitialCheckpoint},
            checkpointInstallCount |-> [checkpoint \in CheckpointIDs |->
                IF checkpoint = InitialCheckpoint THEN 1 ELSE 0],
            replacementCheckpoint |-> None,
            replacementInstalled |-> FALSE,
            replacementVerified |-> FALSE,
            returnedCheckpoint |-> None,
            replacementQualified |-> FALSE,
            qualificationKind |-> "none",
            journalDurableEdits |->
                IF initialFiles = {} THEN {} ELSE {SeedEdit},
            creationCount |-> [journal \in JournalIDs |->
                IF journal \in initialUsed THEN 1 ELSE 0],
            deleted |-> {},
            deletionWitnesses |-> {},
            claimPublicationWitnesses |-> {},
            discoveryKind |-> "none",
            discoveryWitnesses |-> {},
            offlineEvidence |-> {},
            remoteWriterPossible |-> InitialRemoteWriters(scenario),
            catalogCurrent |-> FALSE
                ]

AcquireDirectoryLock ==
    /\ state.phase = "closed"
    /\ state' = [state EXCEPT
        !.phase = "locked",
        !.lockHeld = TRUE,
        !.catalogCurrent = FALSE
                ]

FailDirectoryLock ==
    /\ state.phase = "closed"
    /\ state' = [state EXCEPT !.phase = "blocked"]

CompleteCatalog ==
    /\ state.phase = "locked"
    /\ ~state.catalogCurrent
    /\ state' = [state EXCEPT !.catalogCurrent = TRUE]

RefreshMatchingStaleClaim ==
    /\ state.phase = "locked"
    /\ \E journal \in state.claims:
        /\ state.claimRoots[journal] = state.openRoot
        /\ journal \in state.staleClaims
        /\ state' = [state EXCEPT
            !.staleClaims = @ \ {journal},
            !.syncedClaims = @ \ {journal},
            !.refreshPending = @ \cup {journal},
            !.refreshedPairs = @ \cup
                {<<journal, state.openRoot, TRUE, TRUE>>}
                ]

SynchronizeRefreshedClaim ==
    /\ state.phase = "locked"
    /\ \E journal \in state.refreshPending:
        state' = [state EXCEPT
            !.refreshPending = @ \ {journal},
            !.syncedClaims = @ \cup {journal}
                ]

PruneCoordinatedMissingClaim ==
    /\ state.phase = "locked"
    /\ state.catalogCurrent
    /\ \E journal \in state.claims:
        /\ state.claimRoots[journal] = state.openRoot
        /\ <<journal, state.openRoot>> \notin state.files
        /\ state' = [state EXCEPT
            !.claims = @ \ {journal},
            !.syncedClaims = @ \ {journal},
            !.staleClaims = @ \ {journal},
            !.refreshPending = @ \ {journal},
            !.claimRoots[journal] = None,
            !.prunedClaims = @ \cup {journal},
            !.pruneWitnesses = @ \cup
                {<<journal, state.openRoot, state.catalogCurrent,
                   state.claimRoots[journal] = state.openRoot,
                   <<journal, state.openRoot>> \notin state.files>>}
                ]

DiscoverClaimedJournal ==
    /\ state.phase = "locked"
    /\ Cardinality(ValidClaimedCandidates) = 1
    /\ LET journal == CHOOSE candidate \in ValidClaimedCandidates: TRUE
       IN state' = [state EXCEPT
            !.phase = "discovered",
            !.current = journal,
            !.discoveryKind = "claimed",
            !.discoveryWitnesses = @ \cup
                {<<journal, state.openRoot,
                   journal \in ValidClaimedCandidates,
                   state.lockHeld,
                   state.rootKind \in RootKinds>>}
                ]

DiscoverRestoredLocalJournal ==
    /\ state.phase = "locked"
    /\ state.rootKind = "local"
    /\ ValidClaimedCandidates = {}
    /\ Cardinality(ValidUnclaimedCandidates) = 1
    /\ LET journal == CHOOSE candidate \in ValidUnclaimedCandidates: TRUE
           instance == <<journal, state.openRoot>>
       IN /\ instance \notin state.remoteWriterPossible
          /\ state' = [state EXCEPT
                !.phase = "discovered",
                !.current = journal,
                !.discoveryKind = "localBackup",
                !.discoveryWitnesses = @ \cup
                    {<<journal, state.openRoot,
                       journal \in ValidUnclaimedCandidates,
                       state.lockHeld,
                       state.rootKind = "local">>}
                ]

BlockAmbiguousClaims ==
    /\ state.phase = "locked"
    /\ Cardinality(ValidClaimedCandidates) > 1
    /\ state' = [state EXCEPT !.phase = "blocked"]

CreateFreshJournal ==
    /\ \/ /\ state.phase = "locked"
           /\ ValidClaimedCandidates = {}
           /\ PotentialMatchingClaims = {}
           /\ ~(state.rootKind = "local"
                /\ Cardinality(ValidUnclaimedCandidates) = 1)
       \/ state.phase = "handoff"
    /\ \E journal \in JournalIDs \ state.used:
        LET instance == <<journal, state.openRoot>>
        IN /\ instance \notin state.files
           /\ state' = [state EXCEPT
                !.phase = "creating",
                !.current = journal,
                !.used = @ \cup {journal},
                !.files = @ \cup {instance},
                !.headerIDs[instance] = journal,
                !.headerBases[instance] = state.acceptedDatabaseCheckpoint,
                !.contents[instance] = {},
                !.creationCount[journal] = @ + 1,
                !.writable = FALSE
                ]

SynchronizeHeader ==
    /\ state.phase = "creating"
    /\ CurrentInstance \in state.files
    /\ state.headerIDs[CurrentInstance] = state.current
    /\ state.headerBases[CurrentInstance] = state.acceptedDatabaseCheckpoint
    /\ state' = [state EXCEPT
        !.phase = "headerSynced",
        !.syncedHeaders = @ \cup {CurrentInstance}
                ]

PublishClaim ==
    /\ state.phase = "headerSynced"
    /\ CurrentInstance \in state.syncedHeaders
    /\ state.headerIDs[CurrentInstance] = state.current
    /\ state.lockHeld
    /\ state' = [state EXCEPT
        !.phase = "claimWritten",
        !.claims = @ \cup {state.current},
        !.claimRoots[state.current] = state.openRoot,
        !.syncedClaims = @ \ {state.current},
        !.staleClaims = @ \ {state.current},
        !.claimPublicationWitnesses = @ \cup
            {<<CurrentInstance,
               CurrentInstance \in state.syncedHeaders,
               state.headerIDs[CurrentInstance] = state.current,
               state.lockHeld>>}
                ]

SynchronizePublishedClaim ==
    /\ state.phase = "claimWritten"
    /\ state.current \in state.claims
    /\ state' = [state EXCEPT
        !.phase = "freshClaimed",
        !.syncedClaims = @ \cup {state.current}
                ]

FinishInitialClaim ==
    /\ state.phase = "freshClaimed"
    /\ state.oldJournal = None
    /\ ValidClaimedCandidates = {state.current}
    /\ state' = [state EXCEPT !.phase = "claimed"]

RemoveSupersededClaim ==
    /\ state.phase = "freshClaimed"
    /\ state.oldJournal # None
    /\ state.oldJournal \in state.claims
    /\ state.current \in ValidClaimedCandidates
    /\ <<state.oldJournal, state.openRoot>> \in state.files
    /\ state' = [state EXCEPT
        !.phase = "claimed",
        !.claims = @ \ {state.oldJournal},
        !.syncedClaims = @ \ {state.oldJournal},
        !.claimRoots[state.oldJournal] = None
                ]

EnableEditing ==
    /\ state.phase = "claimed"
    /\ state.lockHeld
    /\ ValidClaimedCandidates = {state.current}
    /\ state' = [state EXCEPT
        !.phase = "running",
        !.writable = TRUE
                ]

AppendDurableEdit ==
    /\ state.phase = "running"
    /\ state.writable
    /\ state.current \in ValidClaimedCandidates
    /\ \E edit \in Edits \ state.journalDurableEdits:
        state' = [state EXCEPT
            !.contents[CurrentInstance] = @ \cup {edit},
            !.journalDurableEdits = @ \cup {edit}
                ]

Crash ==
    /\ state.phase \notin {"closed", "blocked"}
    /\ state' = [state EXCEPT
        !.phase = "closed",
        !.lockHeld = FALSE,
        !.current = None,
        !.oldJournal = None,
        !.writable = FALSE,
        !.catalogCurrent = FALSE
                ]

RecoverDiscoveredJournal ==
    /\ state.phase = "discovered"
    /\ CurrentInstance \in state.files
    /\ JournalRecoveryEligible(CurrentInstance)
    /\ state' = [state EXCEPT
        !.phase = "recovered",
        !.checkpoint = @ \cup state.contents[CurrentInstance],
        !.replacementCheckpoint = None,
        !.replacementInstalled = FALSE,
        !.replacementVerified = FALSE,
        !.returnedCheckpoint = None,
        !.replacementQualified = FALSE,
        !.qualificationKind = "none"
                ]

InstallReplacementCheckpoint ==
    /\ state.phase = "recovered"
    /\ \E checkpointID \in CheckpointIDs \ state.usedCheckpointIDs:
        state' = [state EXCEPT
            !.phase = "installed",
            !.replacementCheckpoint = checkpointID,
            !.usedCheckpointIDs = @ \cup {checkpointID},
            !.checkpointInstallCount[checkpointID] = @ + 1,
            !.replacementInstalled = TRUE
                ]

VerifyReplacementCheckpoint ==
    /\ state.phase = "installed"
    /\ state.replacementInstalled
    /\ state.replacementCheckpoint # None
    /\ state.contents[CurrentInstance] \subseteq state.checkpoint
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
    /\ state.replacementVerified
    /\ state.replacementQualified
    /\ CurrentInstance \in state.files
    /\ state.contents[CurrentInstance] \subseteq state.checkpoint
    /\ \/ state.discoveryKind = "localBackup"
       \/ state.current \in state.claims
    /\ CurrentInstance \notin state.remoteWriterPossible
    /\ LET instance == CurrentInstance
       IN state' = [state EXCEPT
            !.phase = "deleted",
            !.files = @ \ {instance},
            !.syncedHeaders = @ \ {instance},
            !.deleted = @ \cup {instance},
            !.deletionWitnesses = @ \cup
                {<<instance,
                   state.replacementVerified,
                   state.replacementQualified,
                   state.contents[instance] \subseteq state.checkpoint,
                   state.discoveryKind = "localBackup"
                       \/ state.current \in state.claims,
                   instance \notin state.remoteWriterPossible,
                   state.replacementCheckpoint>>}
                ]

ClearDeletedClaim ==
    /\ state.phase = "deleted"
    /\ CurrentInstance \notin state.files
    /\ state' = [state EXCEPT
        !.phase = "locked",
        !.claims = @ \ {state.current},
        !.syncedClaims = @ \ {state.current},
        !.staleClaims = @ \ {state.current},
        !.claimRoots[state.current] = None,
        !.current = None,
        !.discoveryKind = "none"
                ]

BeginOfflineHandoff ==
    /\ state.phase = "verified"
    /\ state.rootKind = "icloud"
    /\ ~state.replacementQualified
    /\ state.current \in state.claims
    /\ CurrentInstance \in state.files
    /\ state' = [state EXCEPT
        !.phase = "handoff",
        !.oldJournal = state.current,
        !.offlineEvidence = @ \cup {CurrentInstance},
        !.current = None
                ]

Next ==
    \/ AcquireDirectoryLock
    \/ FailDirectoryLock
    \/ CompleteCatalog
    \/ RefreshMatchingStaleClaim
    \/ SynchronizeRefreshedClaim
    \/ PruneCoordinatedMissingClaim
    \/ DiscoverClaimedJournal
    \/ DiscoverRestoredLocalJournal
    \/ BlockAmbiguousClaims
    \/ CreateFreshJournal
    \/ SynchronizeHeader
    \/ PublishClaim
    \/ SynchronizePublishedClaim
    \/ FinishInitialClaim
    \/ RemoveSupersededClaim
    \/ EnableEditing
    \/ AppendDurableEdit
    \/ Crash
    \/ RecoverDiscoveredJournal
    \/ InstallReplacementCheckpoint
    \/ VerifyReplacementCheckpoint
    \/ QualifyLocalReplacement
    \/ ObserveICloudUpload
    \/ DeleteRecoveredJournal
    \/ ClearDeletedClaim
    \/ BeginOfflineHandoff

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(CreateFreshJournal)
    /\ WF_vars(SynchronizeHeader)
    /\ WF_vars(PublishClaim)
    /\ WF_vars(SynchronizePublishedClaim)

TypeOK ==
    /\ state.scenario \in Scenarios
    /\ state.phase \in Phases
    /\ state.rootKind \in RootKinds
    /\ state.openRoot \in RootIDs
    /\ state.lockHeld \in BOOLEAN
    /\ state.used \subseteq JournalIDs
    /\ state.files \subseteq Instances
    /\ state.syncedHeaders \subseteq Instances
    /\ state.headerIDs \in [Instances -> JournalIDs \cup {None}]
    /\ state.headerBases \in [Instances -> CheckpointIDs \cup {None}]
    /\ state.claims \subseteq JournalIDs
    /\ state.claimRoots \in [JournalIDs -> RootIDs \cup {None}]
    /\ state.syncedClaims \subseteq JournalIDs
    /\ state.staleClaims \subseteq JournalIDs
    /\ state.refreshPending \subseteq JournalIDs
    /\ state.unresolvableEver \subseteq JournalIDs
    /\ state.refreshedPairs \subseteq
        (JournalIDs \X RootIDs \X BOOLEAN \X BOOLEAN)
    /\ state.prunedClaims \subseteq JournalIDs
    /\ state.pruneWitnesses \subseteq
        (JournalIDs \X RootIDs \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.current \in JournalIDs \cup {None}
    /\ state.oldJournal \in JournalIDs \cup {None}
    /\ state.writable \in BOOLEAN
    /\ state.contents \in [Instances -> SUBSET Edits]
    /\ state.checkpoint \subseteq Edits
    /\ state.acceptedDatabaseCheckpoint \in CheckpointIDs
    /\ state.usedCheckpointIDs \subseteq CheckpointIDs
    /\ state.checkpointInstallCount \in [CheckpointIDs -> 0..1]
    /\ state.replacementCheckpoint \in CheckpointIDs \cup {None}
    /\ state.replacementInstalled \in BOOLEAN
    /\ state.replacementVerified \in BOOLEAN
    /\ state.returnedCheckpoint \in CheckpointIDs \cup {None}
    /\ state.replacementQualified \in BOOLEAN
    /\ state.qualificationKind \in QualificationKinds
    /\ state.journalDurableEdits \subseteq Edits
    /\ state.creationCount \in [JournalIDs -> 0..1]
    /\ state.deleted \subseteq Instances
    /\ state.deletionWitnesses \subseteq
        (Instances \X BOOLEAN \X BOOLEAN \X BOOLEAN \X BOOLEAN
            \X BOOLEAN \X CheckpointIDs)
    /\ state.claimPublicationWitnesses \subseteq
        (Instances \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.discoveryKind \in DiscoveryKinds
    /\ state.discoveryWitnesses \subseteq
        (JournalIDs \X RootIDs \X BOOLEAN \X BOOLEAN \X BOOLEAN)
    /\ state.offlineEvidence \subseteq Instances
    /\ state.remoteWriterPossible \subseteq Instances
    /\ state.catalogCurrent \in BOOLEAN

DurableWorkIsDiscoverable ==
    state.journalDurableEdits \subseteq RecoverableEvidence

EditingRequiresOneRootAndHeaderValidatedClaim ==
    state.writable =>
        /\ state.phase = "running"
        /\ state.lockHeld
        /\ state.current # None
        /\ ValidClaimedCandidates = {state.current}

AmbiguityBlocksEditing ==
    Cardinality(ValidClaimedCandidates) # 1 => ~state.writable

ClaimPublicationFollowedDurableHeader ==
    \A witness \in state.claimPublicationWitnesses:
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]

OnlyMatchingStaleBookmarksWereRefreshed ==
    \A witness \in state.refreshedPairs:
        /\ witness[3]
        /\ witness[4]

MissingClaimsWerePrunedConservatively ==
    /\ state.unresolvableEver \cap state.prunedClaims = {}
    /\ \A witness \in state.pruneWitnesses:
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]

DiscoveryWasRootAndLockValidated ==
    \A witness \in state.discoveryWitnesses:
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]

LocalBackupIsTheOnlyUnclaimedAutomaticRecovery ==
    state.discoveryKind = "localBackup" => state.rootKind = "local"

JournalIDIsNeverReused ==
    \A journal \in JournalIDs: state.creationCount[journal] <= 1

CheckpointIDIsNeverReused ==
    \A checkpoint \in CheckpointIDs:
        state.checkpointInstallCount[checkpoint] <= 1

DeletedJournalsHadDurableQualifiedReplacement ==
    /\ state.deleted = {witness[1]: witness \in state.deletionWitnesses}
    /\ \A witness \in state.deletionWitnesses:
        /\ witness[2]
        /\ witness[3]
        /\ witness[4]
        /\ witness[5]
        /\ witness[6]

OfflineHandoffPreservesOrQualifiesOldEvidence ==
    \A instance \in state.offlineEvidence:
        \/ instance \in state.files
        \/ \E witness \in state.deletionWitnesses:
            /\ witness[1] = instance
            /\ witness[2]
            /\ witness[3]
            /\ witness[4]

PossibleRemoteWriterEvidenceIsNeverDeleted ==
    state.remoteWriterPossible \cap state.deleted = {}

RegistryOnlyNamesKnownIDs ==
    state.claims \subseteq state.used

HeadersOnlyBecomeDurableForExistingFiles ==
    state.syncedHeaders \subseteq state.files

FreshCreationProgress ==
    state.phase = "creating"
    ~> state.phase \in {"headerSynced", "closed"}

ClaimPublicationProgress ==
    state.phase = "claimWritten"
    ~> state.phase \in {"freshClaimed", "closed"}

OfflineHandoffProgressWhileFreshIDExists ==
    /\ state.phase = "handoff"
    /\ JournalIDs \ state.used # {}
    ~> \/ state.phase \in {"creating", "closed"}
       \/ JournalIDs \ state.used = {}

=============================================================================
