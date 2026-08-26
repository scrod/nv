------------------------- MODULE JournalLifecycle --------------------------
EXTENDS FiniteSets, Naturals

\* This is the crash/refinement model for one acting Mac. claims and
\* retainedClaims are that Mac's kCFPreferencesCurrentHost values; shared
\* journal artifacts and an abstract possible remote writer are environment
\* inputs. HostLocalJournalOwnership separately checks the two-host boundary.

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
    "recovered", "installed", "verified", "retainedClaimWritten",
    "retainedClaimed", "deleted"
}
DiscoveryKinds == {"none", "claimed", "retained", "localBackup"}
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

InitialStaleClaims(scenario) ==
    IF scenario = "staleMatching" THEN {Journal1} ELSE {}

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

ValidRetainedCandidates ==
    {journal \in state.retainedClaims:
        /\ state.retainedClaimRoots[journal] = state.openRoot
        /\ journal \in state.syncedRetainedClaims
        /\ JournalRecoveryEligible(<<journal, state.openRoot>>)}

MandatoryRetainedCandidates ==
    {journal \in ValidRetainedCandidates:
        state.retainedCoverage[journal] # state.acceptedDatabaseCheckpoint}

RetainedCleanupCandidates ==
    {journal \in state.retainedClaims:
        LET instance == <<journal, state.openRoot>>
        IN /\ journal \in state.syncedRetainedClaims
           /\ state.retainedClaimRoots[journal] = state.openRoot
           /\ journal \in state.receiptJournals
           /\ instance \in state.files
           /\ state.contents[instance] \subseteq state.checkpoint
           /\ instance \notin state.remoteWriterPossible}

AbsentJournalInstancesNeedingDirectorySync ==
    {instance \in Instances:
        /\ instance[2] = state.openRoot
        /\ instance \notin state.files
        /\ \/ instance \in state.deleted
           \/ /\ instance[1] \in state.claims
              /\ state.claimRoots[instance[1]] = state.openRoot
           \/ /\ instance[1] \in state.retainedClaims
              /\ state.retainedClaimRoots[instance[1]] = state.openRoot}

ValidUnclaimedCandidates ==
    {journal \in JournalIDs \ (state.claims \cup state.retainedClaims):
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
            retainedClaims |-> {},
            retainedClaimRoots |-> [journal \in JournalIDs |-> None],
            retainedCoverage |-> [journal \in JournalIDs |-> None],
            syncedRetainedClaims |-> {},
            retainedDeletionPending |-> {},
            directoryDurableDeletions |-> {},
            staleClaims |-> InitialStaleClaims(scenario),
            refreshPending |-> {},
            unresolvableEver |-> InitialUnresolvable(scenario),
            refreshedPairs |-> {},
            prunedClaims |-> {},
            pruneWitnesses |-> {},
            claimClearWitnesses |-> {},
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
            representedJournals |-> {},
            receiptJournals |-> {},
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
            demotionWitnesses |-> {},
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
                {<<journal, state.claimRoots[journal]>>}
                ]

SynchronizeRefreshedClaim ==
    /\ state.phase = "locked"
    /\ \E journal \in state.refreshPending:
        state' = [state EXCEPT
            !.refreshPending = @ \ {journal},
            !.syncedClaims = @ \cup {journal}
                ]

SynchronizeAbsentJournalDirectory ==
    /\ state.phase \in {"locked", "verified", "deleted"}
    /\ state.lockHeld
    /\ (state.phase = "locked" => state.catalogCurrent)
    /\ LET pending == AbsentJournalInstancesNeedingDirectorySync
            \ state.directoryDurableDeletions
       IN /\ pending # {}
          /\ state' = [state EXCEPT
                !.directoryDurableDeletions = @ \cup pending
                    ]

PruneCoordinatedMissingClaim ==
    /\ state.phase = "locked"
    /\ state.catalogCurrent
    /\ \E journal \in state.claims:
        LET instance == <<journal, state.openRoot>>
        IN /\ state.claimRoots[journal] = state.openRoot
           /\ instance \notin state.files
           /\ instance \in state.directoryDurableDeletions
           /\ state' = [state EXCEPT
                !.claims = @ \ {journal},
                !.syncedClaims = @ \ {journal},
                !.staleClaims = @ \ {journal},
                !.refreshPending = @ \ {journal},
                !.claimRoots[journal] = None,
                !.prunedClaims = @ \cup {journal},
                !.pruneWitnesses = @ \cup
                    {<<"active", journal, state.claimRoots[journal],
                       state.openRoot, state.catalogCurrent,
                       instance \in state.directoryDurableDeletions>>},
                !.claimClearWitnesses = @ \cup {instance}
                    ]

PruneCoordinatedMissingRetainedClaim ==
    /\ state.phase = "locked"
    /\ state.catalogCurrent
    /\ \E journal \in state.retainedClaims:
        LET instance == <<journal, state.openRoot>>
        IN /\ state.retainedClaimRoots[journal] = state.openRoot
           /\ instance \notin state.files
           /\ instance \in state.directoryDurableDeletions
           /\ state' = [state EXCEPT
                !.retainedClaims = @ \ {journal},
                !.syncedRetainedClaims = @ \ {journal},
                !.retainedClaimRoots[journal] = None,
                !.retainedCoverage[journal] = None,
                !.prunedClaims = @ \cup {journal},
                !.pruneWitnesses = @ \cup
                    {<<"retained", journal,
                       state.retainedClaimRoots[journal], state.openRoot,
                       state.catalogCurrent,
                       instance \in state.directoryDurableDeletions>>},
                !.claimClearWitnesses = @ \cup {instance}
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
                {<<journal, state.openRoot, "claimed",
                   journal \in ValidClaimedCandidates,
                   state.lockHeld,
                   state.rootKind>>}
                ]

DiscoverRetainedJournal ==
    /\ state.phase = "locked"
    /\ ValidClaimedCandidates = {}
    /\ PotentialMatchingClaims = {}
    /\ MandatoryRetainedCandidates # {}
    /\ LET journal == CHOOSE candidate \in MandatoryRetainedCandidates: TRUE
       IN state' = [state EXCEPT
            !.phase = "discovered",
            !.current = journal,
            !.discoveryKind = "retained",
            !.discoveryWitnesses = @ \cup
                {<<journal, state.openRoot, "retained",
                   journal \in MandatoryRetainedCandidates,
                   state.lockHeld,
                   state.rootKind>>}
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
                    {<<journal, state.openRoot, "localBackup",
                       journal \in ValidUnclaimedCandidates,
                       state.lockHeld,
                       state.rootKind>>}
                ]

BlockAmbiguousClaims ==
    /\ state.phase = "locked"
    /\ Cardinality(ValidClaimedCandidates) > 1
    /\ state' = [state EXCEPT !.phase = "blocked"]

CreateFreshJournal ==
    /\ state.phase = "locked"
    /\ ValidClaimedCandidates = {}
    /\ PotentialMatchingClaims = {}
    /\ MandatoryRetainedCandidates = {}
    /\ RetainedCleanupCandidates = {}
    /\ state.retainedDeletionPending = {}
    /\ ~(state.rootKind = "local"
         /\ Cardinality(ValidUnclaimedCandidates) = 1)
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
                !.oldJournal = None,
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
            {<<CurrentInstance, state.lockHeld>>}
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
        !.discoveryKind = "none",
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
        !.representedJournals = @ \cup {state.current},
        !.receiptJournals = state.representedJournals \cup {state.current},
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
    /\ state.current \in state.receiptJournals
    /\ \/ state.discoveryKind = "localBackup"
       \/ state.current \in state.claims
       \/ state.current \in state.retainedClaims
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
                       \/ state.current \in state.claims
                       \/ state.current \in state.retainedClaims,
                   instance \notin state.remoteWriterPossible,
                   state.current \in state.receiptJournals,
                   state.replacementCheckpoint>>}
                ]

DeleteCoveredRetainedJournal ==
    /\ state.phase \in {"verified", "locked"}
    /\ state.replacementVerified
    /\ state.replacementQualified
    /\ \E journal \in RetainedCleanupCandidates:
        LET instance == <<journal, state.openRoot>>
        IN /\ journal # state.current
           /\ journal \in state.syncedRetainedClaims
           /\ state.retainedClaimRoots[journal] = state.openRoot
           /\ journal \in state.receiptJournals
           /\ instance \in state.files
           /\ state.contents[instance] \subseteq state.checkpoint
           /\ instance \notin state.remoteWriterPossible
           /\ state' = [state EXCEPT
                !.files = @ \ {instance},
                !.syncedHeaders = @ \ {instance},
                !.deleted = @ \cup {instance},
                !.retainedDeletionPending = @ \cup {journal},
                !.deletionWitnesses = @ \cup
                    {<<instance,
                       state.replacementVerified,
                       state.replacementQualified,
                       state.contents[instance] \subseteq state.checkpoint,
                       journal \in state.retainedClaims,
                       instance \notin state.remoteWriterPossible,
                       journal \in state.receiptJournals,
                       state.replacementCheckpoint>>}
                ]

ClearDeletedRetainedClaim ==
    /\ state.phase \in {"verified", "locked"}
    /\ \E journal \in state.retainedDeletionPending:
        LET instance == <<journal, state.openRoot>>
        IN /\ instance \notin state.files
           /\ instance \in state.directoryDurableDeletions
           /\ state' = [state EXCEPT
                !.retainedDeletionPending = @ \ {journal},
                !.retainedClaims = @ \ {journal},
                !.syncedRetainedClaims = @ \ {journal},
                !.retainedClaimRoots[journal] = None,
                !.retainedCoverage[journal] = None,
                !.claimClearWitnesses = @ \cup {instance}
                    ]

ClearDeletedClaim ==
    /\ state.phase = "deleted"
    /\ CurrentInstance \notin state.files
    /\ CurrentInstance \in state.directoryDurableDeletions
    /\ state' = [state EXCEPT
        !.phase = "locked",
        !.claims = @ \ {state.current},
        !.syncedClaims = @ \ {state.current},
        !.staleClaims = @ \ {state.current},
        !.claimRoots[state.current] = None,
        !.retainedClaims = @ \ {state.current},
        !.syncedRetainedClaims = @ \ {state.current},
        !.retainedClaimRoots[state.current] = None,
        !.retainedCoverage[state.current] = None,
        !.retainedDeletionPending = @ \ {state.current},
        !.claimClearWitnesses = @ \cup {CurrentInstance},
        !.current = None,
        !.discoveryKind = "none"
                ]

BeginRetainedHandoff ==
    /\ state.phase = "verified"
    /\ state.rootKind # "local"
    /\ ~state.replacementQualified
    /\ state.current \in state.claims
    /\ CurrentInstance \in state.files
    /\ state' = [state EXCEPT
        !.phase = "retainedClaimWritten",
        !.oldJournal = state.current,
        !.retainedClaims = @ \cup {state.current},
        !.retainedClaimRoots[state.current] = state.openRoot,
        !.retainedCoverage[state.current] = state.replacementCheckpoint,
        !.syncedRetainedClaims = @ \ {state.current},
        !.offlineEvidence = @ \cup {CurrentInstance},
        !.current = state.current
                ]

SynchronizeRetainedClaim ==
    /\ state.phase = "retainedClaimWritten"
    /\ state.current \in state.retainedClaims
    /\ state' = [state EXCEPT
        !.phase = "retainedClaimed",
        !.syncedRetainedClaims = @ \cup {state.current}
                ]

RemoveDemotedActiveClaim ==
    /\ state.phase = "retainedClaimed"
    /\ state.current = state.oldJournal
    /\ state.current \in state.claims
    /\ state.current \in state.syncedRetainedClaims
    /\ state.retainedCoverage[state.current] = state.replacementCheckpoint
    /\ state' = [state EXCEPT
        !.phase = "locked",
        !.claims = @ \ {state.current},
        !.syncedClaims = @ \ {state.current},
        !.claimRoots[state.current] = None,
        !.demotionWitnesses = @ \cup
            {<<state.current,
               state.current \in state.syncedRetainedClaims,
               state.retainedCoverage[state.current]
                   = state.replacementCheckpoint>>},
        !.current = None,
        !.oldJournal = None,
        !.discoveryKind = "none"
                ]

PreserveRecoveredRetainedJournal ==
    /\ state.phase = "verified"
    /\ state.rootKind # "local"
    /\ ~state.replacementQualified
    /\ state.current \in state.retainedClaims
    /\ state.current \in state.syncedRetainedClaims
    /\ CurrentInstance \in state.files
    /\ state' = [state EXCEPT
        !.phase = "locked",
        !.retainedCoverage[state.current] = state.replacementCheckpoint,
        !.offlineEvidence = @ \cup {CurrentInstance},
        !.current = None,
        !.oldJournal = None,
        !.discoveryKind = "none"
                ]

Next ==
    \/ AcquireDirectoryLock
    \/ FailDirectoryLock
    \/ CompleteCatalog
    \/ RefreshMatchingStaleClaim
    \/ SynchronizeRefreshedClaim
    \/ SynchronizeAbsentJournalDirectory
    \/ PruneCoordinatedMissingClaim
    \/ PruneCoordinatedMissingRetainedClaim
    \/ DiscoverClaimedJournal
    \/ DiscoverRetainedJournal
    \/ DiscoverRestoredLocalJournal
    \/ BlockAmbiguousClaims
    \/ CreateFreshJournal
    \/ SynchronizeHeader
    \/ PublishClaim
    \/ SynchronizePublishedClaim
    \/ FinishInitialClaim
    \/ EnableEditing
    \/ AppendDurableEdit
    \/ Crash
    \/ RecoverDiscoveredJournal
    \/ InstallReplacementCheckpoint
    \/ VerifyReplacementCheckpoint
    \/ QualifyLocalReplacement
    \/ ObserveICloudUpload
    \/ DeleteCoveredRetainedJournal
    \/ ClearDeletedRetainedClaim
    \/ DeleteRecoveredJournal
    \/ ClearDeletedClaim
    \/ BeginRetainedHandoff
    \/ SynchronizeRetainedClaim
    \/ RemoveDemotedActiveClaim
    \/ PreserveRecoveredRetainedJournal

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(CreateFreshJournal)
    /\ WF_vars(SynchronizeHeader)
    /\ WF_vars(PublishClaim)
    /\ WF_vars(SynchronizePublishedClaim)
    /\ WF_vars(SynchronizeRetainedClaim)
    /\ WF_vars(RemoveDemotedActiveClaim)

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
    /\ state.retainedClaims \subseteq JournalIDs
    /\ state.retainedClaimRoots \in [JournalIDs -> RootIDs \cup {None}]
    /\ state.retainedCoverage \in [JournalIDs -> CheckpointIDs \cup {None}]
    /\ state.syncedRetainedClaims \subseteq JournalIDs
    /\ state.retainedDeletionPending \subseteq JournalIDs
    /\ state.directoryDurableDeletions \subseteq Instances
    /\ state.staleClaims \subseteq JournalIDs
    /\ state.refreshPending \subseteq JournalIDs
    /\ state.unresolvableEver \subseteq JournalIDs
    /\ state.refreshedPairs \subseteq Instances
    /\ state.prunedClaims \subseteq JournalIDs
    /\ state.pruneWitnesses \subseteq
        ({"active", "retained"} \X JournalIDs
            \X RootIDs \X RootIDs \X BOOLEAN \X BOOLEAN)
    /\ state.claimClearWitnesses \subseteq Instances
    /\ state.current \in JournalIDs \cup {None}
    /\ state.oldJournal \in JournalIDs \cup {None}
    /\ state.writable \in BOOLEAN
    /\ state.contents \in [Instances -> SUBSET Edits]
    /\ state.checkpoint \subseteq Edits
    /\ state.acceptedDatabaseCheckpoint \in CheckpointIDs
    /\ state.usedCheckpointIDs \subseteq CheckpointIDs
    /\ state.checkpointInstallCount \in [CheckpointIDs -> 0..1]
    /\ state.representedJournals \subseteq JournalIDs
    /\ state.receiptJournals \subseteq JournalIDs
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
            \X BOOLEAN \X BOOLEAN \X CheckpointIDs)
    /\ state.demotionWitnesses \subseteq
        (JournalIDs \X BOOLEAN \X BOOLEAN)
    /\ state.claimPublicationWitnesses \subseteq
        (Instances \X BOOLEAN)
    /\ state.discoveryKind \in DiscoveryKinds
    /\ state.discoveryWitnesses \subseteq
        (JournalIDs \X RootIDs \X DiscoveryKinds
            \X BOOLEAN \X BOOLEAN \X RootKinds)
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
        /\ state.headerIDs[witness[1]] = witness[1][1]
        /\ state.headerBases[witness[1]] # None
        /\ witness[1] \in state.syncedHeaders \cup state.deleted

OnlyMatchingStaleBookmarksWereRefreshed ==
    \A instance \in state.refreshedPairs:
        /\ instance \in {
            <<journal, state.openRoot>>:
                journal \in InitialStaleClaims(state.scenario)}
        /\ instance[1] \notin state.staleClaims
        /\ \/ instance[1] \in state.refreshPending
           \/ instance[1] \in state.syncedClaims
           \/ instance[1] \notin state.claims

MissingClaimsWerePrunedConservatively ==
    /\ state.unresolvableEver \cap state.prunedClaims = {}
    /\ state.prunedClaims =
        {witness[2]: witness \in state.pruneWitnesses}
    /\ \A witness \in state.pruneWitnesses:
        /\ witness[3] = witness[4]
        /\ witness[5]
        /\ witness[6]
        /\ <<witness[2], witness[4]>> \notin state.files
        /\ IF witness[1] = "active"
           THEN witness[2] \notin state.claims
           ELSE witness[2] \notin state.retainedClaims

ClaimsWereClearedOnlyAfterDirectoryDurability ==
    state.claimClearWitnesses \subseteq state.directoryDurableDeletions

DiscoveryWasRootAndLockValidated ==
    /\ (state.discoveryKind # "none" =>
        \E witness \in state.discoveryWitnesses:
            /\ witness[1] = state.current
            /\ witness[2] = state.openRoot
            /\ witness[3] = state.discoveryKind)
    /\ \A witness \in state.discoveryWitnesses:
        LET instance == <<witness[1], witness[2]>>
        IN /\ witness[3] # "none"
           /\ witness[4]
           /\ witness[5]
           /\ instance \in state.files \cup state.deleted
           /\ state.headerIDs[instance] = witness[1]
           /\ state.headerBases[instance] # None
           /\ (witness[3] = "localBackup" => witness[6] = "local")

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
        /\ witness[7]

RetainedHandoffPreservesOrQualifiesOldEvidence ==
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
    state.claims \cup state.retainedClaims \subseteq state.used

RetainedClaimsNeverBecomeUnclaimed ==
    ValidUnclaimedCandidates \cap state.retainedClaims = {}

SynchronizedRetainedClaimsHaveCoverage ==
    \A journal \in state.syncedRetainedClaims:
        /\ journal \in state.retainedClaims
        /\ state.retainedCoverage[journal] # None

ActiveClaimsWereRemovedOnlyAfterRetainedPublication ==
    \A witness \in state.demotionWitnesses:
        /\ witness[2]
        /\ witness[3]

HeadersOnlyBecomeDurableForExistingFiles ==
    state.syncedHeaders \subseteq state.files

FreshCreationProgress ==
    state.phase = "creating"
    ~> state.phase \in {"headerSynced", "closed"}

ClaimPublicationProgress ==
    state.phase = "claimWritten"
    ~> state.phase \in {"freshClaimed", "closed"}

RetainedClaimPublicationProgress ==
    state.phase = "retainedClaimWritten"
    ~> state.phase \in {"retainedClaimed", "closed"}

RetainedDemotionProgress ==
    state.phase = "retainedClaimed"
    ~> state.phase \in {"locked", "closed"}

=============================================================================
