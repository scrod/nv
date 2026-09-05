------------------- MODULE MultiRoundCrossMachineSafety -------------------
\* Proposal-4 baseline: NOT a proposal-5 segment acceptance model.
\* See Proposal5-Coverage.md for retained requirements and replacement gaps.
EXTENDS FiniteSets, Naturals

\* Two hosts, two edit rounds each, independent file/checkpoint delivery, and
\* permanent loss of at most one host. Decision tokens represent causal edit
\* contributions rather than historical bodies, so a later edit retains the
\* decisions on which it was based without adding unbounded body values.

CONSTANTS
    Hosts, HostA, HostB, MaxEditsPerHost,
    MaxCheckpointWritesPerHost, ProviderPreservesDisplacedCurrent

ASSUME
    /\ Hosts = {HostA, HostB}
    /\ HostA # HostB
    /\ MaxEditsPerHost = 2
    /\ MaxCheckpointWritesPerHost = 2
    /\ ProviderPreservesDisplacedCurrent \in BOOLEAN

EditNumbers == 1..MaxEditsPerHost
Decisions == Hosts \X EditNumbers
MaxFileGeneration == Cardinality(Decisions)
MaxCheckpointGeneration ==
    Cardinality(Hosts) * MaxCheckpointWritesPerHost

VARIABLE state

vars == <<state>>

Init ==
    state = [
        onlineHosts |-> Hosts,
        lostHosts |-> {},
        editCount |-> [host \in Hosts |-> 0],
        knowledge |-> [host \in Hosts |-> {}],
        localDurable |-> [host \in Hosts |-> {}],
        everLocallyDurable |-> {},
        pendingFile |-> [host \in Hosts |-> FALSE],

        providerFile |-> {},
        providerFileGeneration |-> 0,
        providerUnresolved |-> {},
        publishedDecisions |-> {},
        fileView |-> [host \in Hosts |-> {}],
        fileViewGeneration |-> [host \in Hosts |-> 0],
        reconciledFileGeneration |-> [host \in Hosts |-> 0],

        providerCheckpoint |-> {},
        providerCheckpointGeneration |-> 0,
        expectedCheckpointGeneration |-> [host \in Hosts |-> 0],
        checkpointWrites |-> [host \in Hosts |-> 0],
        everCanonical |-> {}
        ]

RoundReady(host, number) ==
    \/ number = 1
    \/ /\ number = 2
       /\ \A peer \in Hosts: state.editCount[peer] >= 1
       /\ \A peer \in Hosts: ~state.pendingFile[peer]

AdmitDurableEdit(host) ==
    /\ host \in state.onlineHosts
    /\ ~state.pendingFile[host]
    /\ state.editCount[host] < MaxEditsPerHost
    /\ LET number == state.editCount[host] + 1
           decision == <<host, number>>
       IN /\ RoundReady(host, number)
          /\ state' = [state EXCEPT
                !.editCount[host] = number,
                !.knowledge[host] = @ \cup {decision},
                !.localDurable[host] = @ \cup {decision},
                !.everLocallyDurable = @ \cup {decision},
                !.pendingFile[host] = TRUE
                ]

PublishCurrentFile(host) ==
    /\ host \in state.onlineHosts
    /\ state.pendingFile[host]
    /\ state.providerFileGeneration < MaxFileGeneration
    /\ LET outgoing == state.knowledge[host]
           displaced == state.providerFile \ outgoing
       IN state' = [state EXCEPT
            !.pendingFile[host] = FALSE,
            !.providerFile = outgoing,
            !.providerFileGeneration = @ + 1,
            !.providerUnresolved =
                IF ProviderPreservesDisplacedCurrent
                  THEN @ \cup displaced
                  ELSE @,
            !.publishedDecisions = @ \cup outgoing,
            !.fileView[host] = outgoing,
            !.fileViewGeneration[host] =
                state.providerFileGeneration + 1
            ]

DeliverCurrentFile(host) ==
    /\ host \in state.onlineHosts
    /\ state.fileViewGeneration[host] < state.providerFileGeneration
    /\ state' = [state EXCEPT
        !.fileView[host] = state.providerFile,
        !.fileViewGeneration[host] = state.providerFileGeneration
        ]

ReconcileDeliveredFile(host) ==
    /\ host \in state.onlineHosts
    /\ state.reconciledFileGeneration[host]
        < state.fileViewGeneration[host]
    /\ state' = [state EXCEPT
        !.knowledge[host] = @ \cup state.fileView[host],
        !.reconciledFileGeneration[host] =
            state.fileViewGeneration[host]
        ]

ObserveCurrentCheckpoint(host) ==
    /\ host \in state.onlineHosts
    /\ state.expectedCheckpointGeneration[host]
        < state.providerCheckpointGeneration
    /\ state' = [state EXCEPT
        !.knowledge[host] = @ \cup state.providerCheckpoint,
        !.expectedCheckpointGeneration[host] =
            state.providerCheckpointGeneration
        ]

PublishCheckpoint(host) ==
    /\ host \in state.onlineHosts
    /\ ~state.pendingFile[host]
    /\ state.checkpointWrites[host] < MaxCheckpointWritesPerHost
    /\ state.expectedCheckpointGeneration[host]
        = state.providerCheckpointGeneration
    /\ state.knowledge[host] # state.providerCheckpoint
    /\ state' = [state EXCEPT
        !.providerCheckpoint = state.knowledge[host],
        !.providerCheckpointGeneration = @ + 1,
        !.expectedCheckpointGeneration[host] =
            state.providerCheckpointGeneration + 1,
        !.checkpointWrites[host] = @ + 1,
        !.everCanonical = @ \cup state.knowledge[host]
        ]

LoseHostPermanently(host) ==
    /\ host \in state.onlineHosts
    /\ state.lostHosts = {}
    /\ ~state.pendingFile[host]
    /\ state.localDurable[host] \subseteq state.publishedDecisions
    /\ state' = [state EXCEPT
        !.onlineHosts = @ \ {host},
        !.lostHosts = @ \cup {host},
        !.knowledge[host] = {},
        !.localDurable[host] = {},
        !.pendingFile[host] = FALSE
        ]

Next ==
    \/ \E host \in Hosts: AdmitDurableEdit(host)
    \/ \E host \in Hosts: PublishCurrentFile(host)
    \/ \E host \in Hosts: DeliverCurrentFile(host)
    \/ \E host \in Hosts: ReconcileDeliveredFile(host)
    \/ \E host \in Hosts: ObserveCurrentCheckpoint(host)
    \/ \E host \in Hosts: PublishCheckpoint(host)
    \/ \E host \in Hosts: LoseHostPermanently(host)

Spec == Init /\ [][Next]_vars

ProviderEvidence ==
    state.providerFile
        \cup state.providerUnresolved
        \cup state.providerCheckpoint

RecoverableEvidence ==
    ProviderEvidence
        \cup UNION {
            state.localDurable[host] \cup state.knowledge[host]:
                host \in state.onlineHosts
        }

TypeOK ==
    /\ state.onlineHosts \subseteq Hosts
    /\ state.lostHosts \subseteq Hosts
    /\ state.onlineHosts \cap state.lostHosts = {}
    /\ Cardinality(state.lostHosts) <= 1
    /\ state.editCount \in [Hosts -> 0..MaxEditsPerHost]
    /\ state.knowledge \in [Hosts -> SUBSET Decisions]
    /\ state.localDurable \in [Hosts -> SUBSET Decisions]
    /\ state.everLocallyDurable \subseteq Decisions
    /\ state.pendingFile \in [Hosts -> BOOLEAN]
    /\ state.providerFile \subseteq Decisions
    /\ state.providerFileGeneration \in 0..MaxFileGeneration
    /\ state.providerUnresolved \subseteq Decisions
    /\ state.publishedDecisions \subseteq Decisions
    /\ state.fileView \in [Hosts -> SUBSET Decisions]
    /\ state.fileViewGeneration \in [Hosts -> 0..MaxFileGeneration]
    /\ state.reconciledFileGeneration
        \in [Hosts -> 0..MaxFileGeneration]
    /\ state.providerCheckpoint \subseteq Decisions
    /\ state.providerCheckpointGeneration
        \in 0..MaxCheckpointGeneration
    /\ state.expectedCheckpointGeneration
        \in [Hosts -> 0..MaxCheckpointGeneration]
    /\ state.checkpointWrites
        \in [Hosts -> 0..MaxCheckpointWritesPerHost]
    /\ state.everCanonical \subseteq Decisions

EveryLocallyDurableDecisionRemainsRecoverable ==
    state.everLocallyDurable \subseteq RecoverableEvidence

EveryPublishedDecisionRemainsProviderRecoverable ==
    state.publishedDecisions \subseteq ProviderEvidence

CanonicalDecisionHistoryIsMonotonic ==
    state.everCanonical = state.providerCheckpoint

CurrentHostsContainCanonicalCheckpoint ==
    \A host \in state.onlineHosts:
        state.expectedCheckpointGeneration[host]
                = state.providerCheckpointGeneration
            => state.providerCheckpoint \subseteq state.knowledge[host]

LostHostsHaveNoRemainingLocalAuthority ==
    \A host \in state.lostHosts:
        /\ state.knowledge[host] = {}
        /\ state.localDurable[host] = {}
        /\ ~state.pendingFile[host]

ObservedGenerationsNeverExceedProviderCurrent ==
    \A host \in Hosts:
        /\ state.fileViewGeneration[host]
            <= state.providerFileGeneration
        /\ state.reconciledFileGeneration[host]
            <= state.fileViewGeneration[host]
        /\ state.expectedCheckpointGeneration[host]
            <= state.providerCheckpointGeneration

CheckpointPublicationRequiresSettledLocalFile ==
    [][\A host \in Hosts:
        PublishCheckpoint(host) => ~state.pendingFile[host]]_vars

=============================================================================
