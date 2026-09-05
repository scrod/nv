-------------- MODULE CrossMachineCheckpointContentionSafety --------------
\* Proposal-4 baseline: NOT a proposal-5 segment acceptance model.
\* See Proposal5-Coverage.md for retained requirements and replacement gaps.
EXTENDS FiniteSets, Naturals

\* Two hosts close from the same checkpoint predecessor.  One checkpoint may
\* win, while the other host must take the no-write CurrentChanged path,
\* durably represent the complete merged note/retirement result, settle its
\* file obligation, and retry against the exact captured current version.
\* A crash can occur at any losing-host stage, and one same-byte replacement
\* checks that settlement is bound to the captured version, not just content.

CONSTANTS
    Hosts, HostA, HostB,
    Decisions, DecisionA, DecisionB,
    RetiredIDs, RetiredA, RetiredB,
    NoVersion, MaxCheckpointVersion

ASSUME
    /\ Hosts = {HostA, HostB}
    /\ HostA # HostB
    /\ Decisions = {DecisionA, DecisionB}
    /\ DecisionA # DecisionB
    /\ RetiredIDs = {RetiredA, RetiredB}
    /\ RetiredA # RetiredB
    /\ NoVersion \notin Nat
    /\ MaxCheckpointVersion = 3

Phases == {
    "attempting", "changed", "merged", "durable", "settled",
    "retrying", "crashed", "done", "rejected"
}

VARIABLE state

vars == <<state>>

HostDecision(host) ==
    IF host = HostA THEN DecisionA ELSE DecisionB

HostRetirement(host) ==
    IF host = HostA THEN RetiredA ELSE RetiredB

Init ==
    state = [
        phase |-> [host \in Hosts |-> "attempting"],
        crashUsed |-> {},
        replacementUsed |-> FALSE,

        localBodies |->
            [host \in Hosts |-> {HostDecision(host)}],
        localRetired |->
            [host \in Hosts |-> {HostRetirement(host)}],
        durableWALBodies |->
            [host \in Hosts |-> {HostDecision(host)}],
        durableRetiredAssertions |->
            [host \in Hosts |-> {HostRetirement(host)}],

        providerBodies |-> {},
        providerRetired |-> {},
        providerVersion |-> 0,
        bodyHistory |-> {},
        retirementHistory |-> {},
        checkpointWrites |-> 0,
        joinedPublished |-> FALSE,

        acceptedBodies |-> [host \in Hosts |-> {}],
        acceptedRetired |-> [host \in Hosts |-> {}],
        expectedVersion |-> [host \in Hosts |-> 0],
        capturedBodies |-> [host \in Hosts |-> {}],
        capturedRetired |-> [host \in Hosts |-> {}],
        capturedVersion |-> [host \in Hosts |-> NoVersion],
        mergedBodies |-> [host \in Hosts |-> {}],
        mergedRetired |-> [host \in Hosts |-> {}],
        pendingBodies |-> [host \in Hosts |-> {}],
        pendingRetired |-> [host \in Hosts |-> {}],
        durableForVersion |-> [host \in Hosts |-> NoVersion],
        filesSettledForVersion |->
            [host \in Hosts |-> NoVersion]
        ]

CommitFirstCheckpoint(host) ==
    /\ state.phase[host] = "attempting"
    /\ state.providerVersion = 0
    /\ state.expectedVersion[host] = state.providerVersion
    /\ state.acceptedBodies[host] = state.providerBodies
    /\ state.acceptedRetired[host] = state.providerRetired
    /\ state' = [state EXCEPT
        !.phase[host] = "done",
        !.providerBodies = state.localBodies[host],
        !.providerRetired = state.localRetired[host],
        !.providerVersion = 1,
        !.bodyHistory = @ \cup state.localBodies[host],
        !.retirementHistory = @ \cup state.localRetired[host],
        !.checkpointWrites = @ + 1,
        !.acceptedBodies[host] = state.localBodies[host],
        !.acceptedRetired[host] = state.localRetired[host],
        !.expectedVersion[host] = 1
        ]

DetectCurrentChanged(host) ==
    /\ state.phase[host] = "attempting"
    /\ state.expectedVersion[host] # state.providerVersion
    /\ state' = [state EXCEPT
        !.phase[host] = "changed",
        !.capturedBodies[host] = state.providerBodies,
        !.capturedRetired[host] = state.providerRetired,
        !.capturedVersion[host] = state.providerVersion
        ]

MergeCompleteBranches(host) ==
    /\ state.phase[host] = "changed"
    /\ LET bodies ==
            state.localBodies[host] \cup state.capturedBodies[host]
           retired ==
            state.localRetired[host] \cup state.capturedRetired[host]
       IN state' = [state EXCEPT
            !.phase[host] = "merged",
            !.mergedBodies[host] = bodies,
            !.mergedRetired[host] = retired,
            !.pendingBodies[host] = bodies,
            !.pendingRetired[host] = retired,
            !.durableForVersion[host] = NoVersion,
            !.filesSettledForVersion[host] = NoVersion
            ]

DurabilizeMergedResult(host) ==
    /\ state.phase[host] = "merged"
    /\ state' = [state EXCEPT
        !.phase[host] = "durable",
        !.durableWALBodies[host] = @ \cup state.pendingBodies[host],
        !.durableRetiredAssertions[host] =
            @ \cup state.pendingRetired[host],
        !.durableForVersion[host] = state.capturedVersion[host]
        ]

SettleMergedFiles(host) ==
    /\ state.phase[host] = "durable"
    /\ state.pendingBodies[host]
        \subseteq state.durableWALBodies[host]
    /\ state.pendingRetired[host]
        \subseteq state.durableRetiredAssertions[host]
    /\ state.durableForVersion[host] = state.capturedVersion[host]
    /\ state' = [state EXCEPT
        !.phase[host] = "settled",
        !.filesSettledForVersion[host] = state.capturedVersion[host]
        ]

BeginExactRetry(host) ==
    /\ state.phase[host] = "settled"
    /\ state.pendingBodies[host]
        \subseteq state.durableWALBodies[host]
    /\ state.pendingRetired[host]
        \subseteq state.durableRetiredAssertions[host]
    /\ state.durableForVersion[host] = state.capturedVersion[host]
    /\ state.filesSettledForVersion[host]
        = state.capturedVersion[host]
    /\ state' = [state EXCEPT
        !.phase[host] = "retrying",
        !.expectedVersion[host] = state.capturedVersion[host]
        ]

CommitExactRetry(host) ==
    /\ state.phase[host] = "retrying"
    /\ state.expectedVersion[host] = state.providerVersion
    /\ state.capturedVersion[host] = state.providerVersion
    /\ state.capturedBodies[host] = state.providerBodies
    /\ state.capturedRetired[host] = state.providerRetired
    /\ state.pendingBodies[host]
        \subseteq state.durableWALBodies[host]
    /\ state.pendingRetired[host]
        \subseteq state.durableRetiredAssertions[host]
    /\ state.durableForVersion[host] = state.providerVersion
    /\ state.filesSettledForVersion[host] = state.providerVersion
    /\ state.providerBodies \subseteq state.mergedBodies[host]
    /\ state.providerRetired \subseteq state.mergedRetired[host]
    /\ state.providerVersion < MaxCheckpointVersion
    /\ LET nextVersion == state.providerVersion + 1
       IN state' = [state EXCEPT
            !.phase[host] = "done",
            !.providerBodies = state.mergedBodies[host],
            !.providerRetired = state.mergedRetired[host],
            !.providerVersion = nextVersion,
            !.bodyHistory = @ \cup state.mergedBodies[host],
            !.retirementHistory = @ \cup state.mergedRetired[host],
            !.checkpointWrites = @ + 1,
            !.joinedPublished =
                @ \/ /\ Decisions \subseteq state.mergedBodies[host]
                     /\ RetiredIDs \subseteq state.mergedRetired[host],
            !.acceptedBodies[host] = state.mergedBodies[host],
            !.acceptedRetired[host] = state.mergedRetired[host],
            !.expectedVersion[host] = nextVersion
            ]

ReplaceCurrentWithSameState(host) ==
    /\ state.phase[host] = "done"
    /\ ~state.replacementUsed
    /\ state.expectedVersion[host] = state.providerVersion
    /\ state.acceptedBodies[host] = state.providerBodies
    /\ state.acceptedRetired[host] = state.providerRetired
    /\ state.providerVersion < MaxCheckpointVersion
    /\ LET nextVersion == state.providerVersion + 1
       IN state' = [state EXCEPT
            !.replacementUsed = TRUE,
            !.providerVersion = nextVersion,
            !.expectedVersion[host] = nextVersion
            ]

RejectStaleRetry(host) ==
    /\ state.phase[host] = "retrying"
    /\ state.expectedVersion[host] # state.providerVersion
    /\ state' = [state EXCEPT !.phase[host] = "rejected"]

Crash(host) ==
    /\ state.phase[host] \in
        {"attempting", "changed", "merged", "durable", "settled", "retrying"}
    /\ host \notin state.crashUsed
    /\ state' = [state EXCEPT
        !.phase[host] = "crashed",
        !.crashUsed = @ \cup {host},
        !.capturedBodies[host] = {},
        !.capturedRetired[host] = {},
        !.capturedVersion[host] = NoVersion,
        !.mergedBodies[host] = {},
        !.mergedRetired[host] = {},
        !.pendingBodies[host] = {},
        !.pendingRetired[host] = {},
        !.durableForVersion[host] = NoVersion,
        !.filesSettledForVersion[host] = NoVersion
        ]

RestartFromCurrentAndLocalWAL(host) ==
    /\ state.phase[host] = "crashed"
    /\ LET bodies ==
            state.providerBodies
                \cup state.localBodies[host]
                \cup state.durableWALBodies[host]
           retired ==
            state.providerRetired
                \cup state.localRetired[host]
                \cup state.durableRetiredAssertions[host]
       IN state' = [state EXCEPT
            !.phase[host] = "merged",
            !.acceptedBodies[host] = state.providerBodies,
            !.acceptedRetired[host] = state.providerRetired,
            !.expectedVersion[host] = state.providerVersion,
            !.capturedBodies[host] = state.providerBodies,
            !.capturedRetired[host] = state.providerRetired,
            !.capturedVersion[host] = state.providerVersion,
            !.mergedBodies[host] = bodies,
            !.mergedRetired[host] = retired,
            !.pendingBodies[host] = bodies,
            !.pendingRetired[host] = retired,
            !.durableForVersion[host] = NoVersion,
            !.filesSettledForVersion[host] = NoVersion
            ]

Next ==
    \/ \E host \in Hosts: CommitFirstCheckpoint(host)
    \/ \E host \in Hosts: DetectCurrentChanged(host)
    \/ \E host \in Hosts: MergeCompleteBranches(host)
    \/ \E host \in Hosts: DurabilizeMergedResult(host)
    \/ \E host \in Hosts: SettleMergedFiles(host)
    \/ \E host \in Hosts: BeginExactRetry(host)
    \/ \E host \in Hosts: CommitExactRetry(host)
    \/ \E host \in Hosts: ReplaceCurrentWithSameState(host)
    \/ \E host \in Hosts: RejectStaleRetry(host)
    \/ \E host \in Hosts: Crash(host)
    \/ \E host \in Hosts: RestartFromCurrentAndLocalWAL(host)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state.phase \in [Hosts -> Phases]
    /\ state.crashUsed \subseteq Hosts
    /\ state.replacementUsed \in BOOLEAN
    /\ state.localBodies \in [Hosts -> SUBSET Decisions]
    /\ state.localRetired \in [Hosts -> SUBSET RetiredIDs]
    /\ state.durableWALBodies \in [Hosts -> SUBSET Decisions]
    /\ state.durableRetiredAssertions
        \in [Hosts -> SUBSET RetiredIDs]
    /\ state.providerBodies \subseteq Decisions
    /\ state.providerRetired \subseteq RetiredIDs
    /\ state.providerVersion \in 0..MaxCheckpointVersion
    /\ state.bodyHistory \subseteq Decisions
    /\ state.retirementHistory \subseteq RetiredIDs
    /\ state.checkpointWrites \in 0..Cardinality(Hosts)
    /\ state.joinedPublished \in BOOLEAN
    /\ state.acceptedBodies \in [Hosts -> SUBSET Decisions]
    /\ state.acceptedRetired \in [Hosts -> SUBSET RetiredIDs]
    /\ state.expectedVersion
        \in [Hosts -> 0..MaxCheckpointVersion]
    /\ state.capturedBodies \in [Hosts -> SUBSET Decisions]
    /\ state.capturedRetired \in [Hosts -> SUBSET RetiredIDs]
    /\ state.capturedVersion
        \in [Hosts -> (0..MaxCheckpointVersion) \cup {NoVersion}]
    /\ state.mergedBodies \in [Hosts -> SUBSET Decisions]
    /\ state.mergedRetired \in [Hosts -> SUBSET RetiredIDs]
    /\ state.pendingBodies \in [Hosts -> SUBSET Decisions]
    /\ state.pendingRetired \in [Hosts -> SUBSET RetiredIDs]
    /\ state.durableForVersion
        \in [Hosts -> (0..MaxCheckpointVersion) \cup {NoVersion}]
    /\ state.filesSettledForVersion
        \in [Hosts -> (0..MaxCheckpointVersion) \cup {NoVersion}]

PublishedCheckpointBodiesAreMonotonic ==
    state.bodyHistory = state.providerBodies

PublishedRetirementsAreMonotonic ==
    state.retirementHistory = state.providerRetired

JoinedCheckpointContainsBothBranches ==
    state.joinedPublished =>
        /\ Decisions \subseteq state.providerBodies
        /\ RetiredIDs \subseteq state.providerRetired

RetirementUnionIsDurableBeforeRetry ==
    \A host \in Hosts:
        state.phase[host] = "retrying" =>
            state.pendingRetired[host]
                \subseteq state.durableRetiredAssertions[host]

RetrySettlementNamesExactCapturedVersion ==
    \A host \in Hosts:
        state.phase[host] = "retrying" =>
            /\ state.durableForVersion[host]
                = state.capturedVersion[host]
            /\ state.filesSettledForVersion[host]
                = state.capturedVersion[host]

EveryFirstWriteUsedExactCurrent ==
    \A host \in Hosts:
        [][CommitFirstCheckpoint(host) =>
            /\ state.expectedVersion[host] = state.providerVersion
            /\ state.acceptedBodies[host] = state.providerBodies
            /\ state.acceptedRetired[host] = state.providerRetired]_vars

CurrentChangedNeverWrites ==
    \A host \in Hosts:
        [][DetectCurrentChanged(host) =>
            /\ state'.providerBodies = state.providerBodies
            /\ state'.providerRetired = state.providerRetired
            /\ state'.providerVersion = state.providerVersion]_vars

StaleRetryNeverWrites ==
    \A host \in Hosts:
        [][RejectStaleRetry(host) =>
            /\ state'.providerBodies = state.providerBodies
            /\ state'.providerRetired = state.providerRetired
            /\ state'.providerVersion = state.providerVersion]_vars

EveryRetryWriteUsedExactDurableSettlement ==
    \A host \in Hosts:
        [][CommitExactRetry(host) =>
            /\ state.expectedVersion[host] = state.providerVersion
            /\ state.capturedVersion[host] = state.providerVersion
            /\ state.pendingBodies[host]
                \subseteq state.durableWALBodies[host]
            /\ state.pendingRetired[host]
                \subseteq state.durableRetiredAssertions[host]
            /\ state.durableForVersion[host] = state.providerVersion
            /\ state.filesSettledForVersion[host]
                = state.providerVersion]_vars

CrashPreservesDurableMergeEvidence ==
    \A host \in Hosts:
        [][Crash(host) =>
            /\ state'.durableWALBodies[host]
                = state.durableWALBodies[host]
            /\ state'.durableRetiredAssertions[host]
                = state.durableRetiredAssertions[host]]_vars

RestartUnionsCurrentWithAllDurableEvidence ==
    \A host \in Hosts:
        [][RestartFromCurrentAndLocalWAL(host) =>
            /\ state'.mergedBodies[host] =
                state.providerBodies
                    \cup state.localBodies[host]
                    \cup state.durableWALBodies[host]
            /\ state'.mergedRetired[host] =
                state.providerRetired
                    \cup state.localRetired[host]
                    \cup state.durableRetiredAssertions[host]]_vars

=============================================================================
