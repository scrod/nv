---------------- MODULE CrossMachineCurrentVisibleSafety ----------------
EXTENDS FiniteSets, Naturals

\* Focused two-host composition model for the current-visible design.
\* It deliberately reuses the local durability guarantees of LocalWALSafety
\* as an abstraction rather than multiplying the state space by replaying that
\* model here. Provider file and checkpoint observations are independent and
\* may occur in either order. Each host contributes at most one source-note
\* change, both changes predate all publication, and each host makes at most
\* two checkpoint writes.
\*
\* A successful coordinated publication and the writer's accepted view form
\* one atomic abstraction. Remote delivery, reconciliation, and checkpoint
\* observation remain separate actions; their intermediate states matter to
\* the cross-host properties. Local WAL and replacement phases are split in
\* their focused models instead of duplicated here.

CONSTANTS
    Hosts, HostA, HostB,
    Bodies, BaseBody, BodyA, BodyB, Absent,
    DeterministicIDs, ConflictID,
    Scenario, ConcurrentEdits, DeleteEdit, Retirement,
    MaxCheckpointWrites,
    ProviderPreservesDisplacedCurrent

ASSUME
    /\ Hosts = {HostA, HostB}
    /\ HostA # HostB
    /\ Bodies = {BaseBody, BodyA, BodyB}
    /\ Cardinality(Bodies) = 3
    /\ Absent \notin Bodies
    /\ DeterministicIDs = {ConflictID}
    /\ Scenario \in {ConcurrentEdits, DeleteEdit, Retirement}
    /\ Cardinality({ConcurrentEdits, DeleteEdit, Retirement}) = 3
    /\ MaxCheckpointWrites = 2
    /\ ProviderPreservesDisplacedCurrent \in BOOLEAN

FileStates == Bodies \cup {Absent}
BranchBodies == {BodyA, BodyB}
MaxFileGeneration == Cardinality(Hosts)
MaxCheckpointGeneration == Cardinality(Hosts) * MaxCheckpointWrites

VARIABLE state

vars == <<state>>

BranchFile(host) ==
    IF host = HostA
      THEN IF Scenario = DeleteEdit THEN Absent ELSE BodyA
      ELSE BodyB

FileBodySet(fileState) ==
    IF fileState = Absent THEN {} ELSE {fileState}

BranchBodySet(host) == FileBodySet(BranchFile(host))

RequiredBranches ==
    UNION {
        BranchBodySet(host) \cap BranchBodies:
            host \in state.changedHosts
    }

EvidenceBodies ==
    UNION {state.liveBodies[host]: host \in Hosts}
        \cup FileBodySet(state.providerFile)
        \cup state.providerUnresolvedBodies
        \cup state.providerCheckpointBodies

MergeBodies(base, local, current) ==
    IF local = current
      THEN local
    ELSE IF local = base
      THEN current
    ELSE IF current = base
      THEN local
    ELSE local \cup current

BodyScenario == Scenario \in {ConcurrentEdits, DeleteEdit}

Init ==
    state = [
        changedHosts |-> {},
        changeBaseFileGeneration |-> [host \in Hosts |-> 0],
        liveBodies |-> [host \in Hosts |-> {BaseBody}],
        liveSourceAbsent |-> [host \in Hosts |-> FALSE],

        publishedFileHosts |-> {},
        providerFile |-> BaseBody,
        providerFileGeneration |-> 0,
        providerUnresolvedBodies |-> {},
        fileView |-> [host \in Hosts |-> BaseBody],
        fileViewGeneration |-> [host \in Hosts |-> 0],
        reconciledFileGeneration |-> [host \in Hosts |-> 0],
        acceptedFileBodies |-> [host \in Hosts |-> {BaseBody}],

        providerCheckpointBodies |-> {BaseBody},
        providerCheckpointSourceAbsent |-> FALSE,
        providerCheckpointDeterministic |-> {},
        providerCheckpointRetired |-> {},
        providerCheckpointGeneration |-> 0,
        acceptedCheckpointBodies |-> [host \in Hosts |-> {BaseBody}],
        acceptedCheckpointSourceAbsent |-> [host \in Hosts |-> FALSE],
        acceptedCheckpointRetired |-> [host \in Hosts |-> {}],
        expectedCheckpointGeneration |-> [host \in Hosts |-> 0],
        liveDeterministic |-> [host \in Hosts |-> {}],
        liveRetired |-> [host \in Hosts |-> {}],
        checkpointWrites |-> [host \in Hosts |-> 0],

        canonicalJoined |-> FALSE,
        everCanonicalSourceAbsent |-> FALSE,
        everCanonicalRetired |-> {}
        ]

AdmitScenarioChange(host) ==
    /\ BodyScenario
    /\ host \in Hosts \ state.changedHosts
    /\ state.publishedFileHosts = {}
    /\ state.providerCheckpointGeneration = 0
    /\ LET changed ==
            (state.liveBodies[host] \ {BaseBody}) \cup BranchBodySet(host)
       IN state' = [state EXCEPT
            !.changedHosts = @ \cup {host},
            !.changeBaseFileGeneration[host] =
                state.fileViewGeneration[host],
            !.liveBodies[host] = changed,
            !.liveSourceAbsent[host] = (BranchFile(host) = Absent)
            ]

PublishScenarioFile(host) ==
    /\ BodyScenario
    /\ host \in state.changedHosts \ state.publishedFileHosts
    /\ state.changedHosts = Hosts
    /\ state.providerFileGeneration < MaxFileGeneration
    /\ LET nextGeneration == state.providerFileGeneration + 1
       IN state' = [state EXCEPT
            !.publishedFileHosts = @ \cup {host},
            !.providerFile = BranchFile(host),
            !.providerFileGeneration = nextGeneration,
            !.providerUnresolvedBodies =
                IF ProviderPreservesDisplacedCurrent
                    /\ state.changeBaseFileGeneration[host]
                        < state.providerFileGeneration
                    /\ BranchFile(host) # state.providerFile
                  THEN @ \cup FileBodySet(state.providerFile)
                  ELSE @,
            !.fileView[host] = BranchFile(host),
            !.fileViewGeneration[host] = nextGeneration
            ]

DeliverCurrentFile(host) ==
    /\ BodyScenario
    /\ host \in Hosts
    /\ state.fileViewGeneration[host] < state.providerFileGeneration
    /\ state' = [state EXCEPT
        !.fileView[host] = state.providerFile,
        !.fileViewGeneration[host] = state.providerFileGeneration
        ]

ReconcileDeliveredFile(host) ==
    /\ BodyScenario
    /\ host \in Hosts
    /\ state.reconciledFileGeneration[host]
        < state.fileViewGeneration[host]
    /\ LET current == FileBodySet(state.fileView[host])
           merged == MergeBodies(
                state.acceptedFileBodies[host],
                state.liveBodies[host],
                current)
       IN state' = [state EXCEPT
            !.liveBodies[host] = merged,
            !.liveSourceAbsent[host] =
                @ \/ state.fileView[host] = Absent,
            !.acceptedFileBodies[host] = current,
            !.reconciledFileGeneration[host] =
                state.fileViewGeneration[host]
            ]

CreateDeterministicConflict(host) ==
    /\ Scenario = Retirement
    /\ host \in Hosts
    /\ ConflictID \notin
        state.liveDeterministic[host] \cup state.liveRetired[host]
    /\ state' = [state EXCEPT
        !.liveDeterministic[host] = @ \cup {ConflictID}
        ]

RetireDeterministicConflict(host) ==
    /\ Scenario = Retirement
    /\ host \in Hosts
    /\ ConflictID \in state.liveDeterministic[host]
    /\ state' = [state EXCEPT
        !.liveDeterministic[host] = @ \ {ConflictID},
        !.liveRetired[host] = @ \cup {ConflictID}
        ]

ObserveCurrentCheckpoint(host) ==
    /\ host \in Hosts
    /\ state.expectedCheckpointGeneration[host]
        < state.providerCheckpointGeneration
    /\ LET mergedBodies == MergeBodies(
                state.acceptedCheckpointBodies[host],
                state.liveBodies[host],
                state.providerCheckpointBodies)
           mergedRetired ==
                state.liveRetired[host] \cup state.providerCheckpointRetired
           mergedDeterministic ==
                (state.liveDeterministic[host]
                    \cup state.providerCheckpointDeterministic)
                    \ mergedRetired
       IN state' = [state EXCEPT
            !.liveBodies[host] = mergedBodies,
            !.liveSourceAbsent[host] =
                @ \/ state.providerCheckpointSourceAbsent,
            !.liveRetired[host] = mergedRetired,
            !.liveDeterministic[host] = mergedDeterministic,
            !.acceptedCheckpointBodies[host] =
                state.providerCheckpointBodies,
            !.acceptedCheckpointSourceAbsent[host] =
                state.providerCheckpointSourceAbsent,
            !.acceptedCheckpointRetired[host] =
                state.providerCheckpointRetired,
            !.expectedCheckpointGeneration[host] =
                state.providerCheckpointGeneration
            ]

LocalCheckpointDiffers(host) ==
    \/ state.liveBodies[host] # state.providerCheckpointBodies
    \/ state.liveSourceAbsent[host]
        # state.providerCheckpointSourceAbsent
    \/ state.liveDeterministic[host]
        # state.providerCheckpointDeterministic
    \/ state.liveRetired[host] # state.providerCheckpointRetired

PublishCheckpoint(host) ==
    /\ host \in Hosts
    /\ state.checkpointWrites[host] < MaxCheckpointWrites
    /\ state.expectedCheckpointGeneration[host]
        = state.providerCheckpointGeneration
    /\ LocalCheckpointDiffers(host)
    /\ LET nextGeneration == state.providerCheckpointGeneration + 1
       IN state' = [state EXCEPT
            !.providerCheckpointBodies = state.liveBodies[host],
            !.providerCheckpointSourceAbsent =
                state.liveSourceAbsent[host],
            !.providerCheckpointDeterministic =
                state.liveDeterministic[host],
            !.providerCheckpointRetired = state.liveRetired[host],
            !.providerCheckpointGeneration = nextGeneration,
            !.acceptedCheckpointBodies[host] = state.liveBodies[host],
            !.acceptedCheckpointSourceAbsent[host] =
                state.liveSourceAbsent[host],
            !.acceptedCheckpointRetired[host] = state.liveRetired[host],
            !.expectedCheckpointGeneration[host] = nextGeneration,
            !.checkpointWrites[host] = @ + 1,
            !.canonicalJoined =
                @ \/ /\ Scenario = ConcurrentEdits
                     /\ state.changedHosts = Hosts
                     /\ RequiredBranches \subseteq state.liveBodies[host],
            !.everCanonicalSourceAbsent =
                @ \/ state.liveSourceAbsent[host],
            !.everCanonicalRetired = @ \cup state.liveRetired[host]
            ]

Next ==
    \/ \E host \in Hosts: AdmitScenarioChange(host)
    \/ \E host \in Hosts: PublishScenarioFile(host)
    \/ \E host \in Hosts: DeliverCurrentFile(host)
    \/ \E host \in Hosts: ReconcileDeliveredFile(host)
    \/ \E host \in Hosts: CreateDeterministicConflict(host)
    \/ \E host \in Hosts: RetireDeterministicConflict(host)
    \/ \E host \in Hosts: ObserveCurrentCheckpoint(host)
    \/ \E host \in Hosts: PublishCheckpoint(host)

Spec == Init /\ [][Next]_vars

Quiescent ==
    /\ BodyScenario
    /\ state.changedHosts = Hosts
    /\ state.publishedFileHosts = Hosts

HostStatesConverged ==
    /\ state.liveBodies[HostA] = state.liveBodies[HostB]
    /\ state.liveSourceAbsent[HostA] = state.liveSourceAbsent[HostB]
    /\ state.liveRetired[HostA] = state.liveRetired[HostB]

FairSpec ==
    /\ Spec
    /\ \A host \in Hosts:
        /\ WF_vars(DeliverCurrentFile(host))
        /\ WF_vars(ReconcileDeliveredFile(host))
        /\ WF_vars(ObserveCurrentCheckpoint(host))
        /\ WF_vars(PublishCheckpoint(host))

SingleRoundConcurrentEditsConverge ==
    (Scenario = ConcurrentEdits /\ Quiescent)
        ~> []HostStatesConverged

TypeOK ==
    /\ state.changedHosts \subseteq Hosts
    /\ state.changeBaseFileGeneration
        \in [Hosts -> 0..MaxFileGeneration]
    /\ state.liveBodies \in [Hosts -> SUBSET Bodies]
    /\ state.liveSourceAbsent \in [Hosts -> BOOLEAN]
    /\ state.publishedFileHosts \subseteq Hosts
    /\ state.providerFile \in FileStates
    /\ state.providerFileGeneration \in 0..MaxFileGeneration
    /\ state.providerUnresolvedBodies \subseteq Bodies
    /\ state.fileView \in [Hosts -> FileStates]
    /\ state.fileViewGeneration
        \in [Hosts -> 0..MaxFileGeneration]
    /\ state.reconciledFileGeneration
        \in [Hosts -> 0..MaxFileGeneration]
    /\ state.acceptedFileBodies \in [Hosts -> SUBSET Bodies]
    /\ state.providerCheckpointBodies \subseteq Bodies
    /\ state.providerCheckpointSourceAbsent \in BOOLEAN
    /\ state.providerCheckpointDeterministic \subseteq DeterministicIDs
    /\ state.providerCheckpointRetired \subseteq DeterministicIDs
    /\ state.providerCheckpointGeneration
        \in 0..MaxCheckpointGeneration
    /\ state.acceptedCheckpointBodies \in [Hosts -> SUBSET Bodies]
    /\ state.acceptedCheckpointSourceAbsent \in [Hosts -> BOOLEAN]
    /\ state.acceptedCheckpointRetired
        \in [Hosts -> SUBSET DeterministicIDs]
    /\ state.expectedCheckpointGeneration
        \in [Hosts -> 0..MaxCheckpointGeneration]
    /\ state.liveDeterministic \in [Hosts -> SUBSET DeterministicIDs]
    /\ state.liveRetired \in [Hosts -> SUBSET DeterministicIDs]
    /\ state.checkpointWrites
        \in [Hosts -> 0..MaxCheckpointWrites]
    /\ state.canonicalJoined \in BOOLEAN
    /\ state.everCanonicalSourceAbsent \in BOOLEAN
    /\ state.everCanonicalRetired \subseteq DeterministicIDs

CheckpointWritesUseExactCurrent ==
    \A host \in Hosts:
        state.expectedCheckpointGeneration[host]
                = state.providerCheckpointGeneration
            => /\ state.acceptedCheckpointBodies[host]
                    = state.providerCheckpointBodies
               /\ state.acceptedCheckpointRetired[host]
                    = state.providerCheckpointRetired
               /\ state.acceptedCheckpointSourceAbsent[host]
                    = state.providerCheckpointSourceAbsent

ConcurrentBranchesRemainRecoverable ==
    RequiredBranches \subseteq EvidenceBodies

DeleteEditLossRequiresAcceptedDeletion ==
    \/ Scenario # DeleteEdit
    \/ HostB \notin state.changedHosts
    \/ BodyB \in EvidenceBodies
    \/ /\ state.providerFile = Absent
       /\ state.fileView[HostB] = Absent
       /\ state.reconciledFileGeneration[HostB]
            = state.fileViewGeneration[HostB]
       /\ state.acceptedFileBodies[HostB] = {}
       /\ state.liveSourceAbsent[HostB]
    \/ /\ state.expectedCheckpointGeneration[HostB]
            = state.providerCheckpointGeneration
       /\ state.acceptedCheckpointSourceAbsent[HostB]
       /\ BodyB \notin state.acceptedCheckpointBodies[HostB]

CanonicalSourceAbsenceIsMonotonic ==
    state.everCanonicalSourceAbsent
        = state.providerCheckpointSourceAbsent

CurrentHostsHonorCanonicalSourceAbsence ==
    \A host \in Hosts:
        state.expectedCheckpointGeneration[host]
                = state.providerCheckpointGeneration
            => (state.providerCheckpointSourceAbsent
                => state.liveSourceAbsent[host])

JoinedCanonicalBranchesStayJoined ==
    state.canonicalJoined =>
        RequiredBranches \subseteq state.providerCheckpointBodies

AcceptedRetirementsAreNeverForgotten ==
    \A host \in Hosts:
        state.acceptedCheckpointRetired[host]
            \subseteq state.liveRetired[host]

CanonicalRetirementsAreMonotonic ==
    state.everCanonicalRetired = state.providerCheckpointRetired

DeterministicAndRetiredIdentitiesStayDisjoint ==
    /\ state.providerCheckpointDeterministic
        \cap state.providerCheckpointRetired = {}
    /\ \A host \in Hosts:
        state.liveDeterministic[host] \cap state.liveRetired[host] = {}

CurrentHostsHonorCanonicalRetirements ==
    \A host \in Hosts:
        state.expectedCheckpointGeneration[host]
                = state.providerCheckpointGeneration
            => state.liveDeterministic[host]
                \cap state.providerCheckpointRetired = {}

ObservedGenerationsNeverExceedProviderCurrent ==
    \A host \in Hosts:
        /\ state.fileViewGeneration[host]
            \leq state.providerFileGeneration
        /\ state.expectedCheckpointGeneration[host]
            \leq state.providerCheckpointGeneration

=============================================================================
