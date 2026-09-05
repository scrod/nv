---------------- MODULE CrossMachineRestartRecoverySafety ----------------
\* Proposal-4 baseline: NOT a proposal-5 segment acceptance model.
\* See Proposal5-Coverage.md for retained requirements and replacement gaps.
EXTENDS FiniteSets, Naturals

\* Two hosts compose current-file propagation with host-local WAL durability
\* and provider-current checkpoint startup.  Each host admits at most one
\* source decision and crashes at most once.  Decision tokens abstract exact
\* note generations; they are additive so this model checks preservation and
\* startup ordering, not text-merge output.

CONSTANTS
    Hosts, HostA, HostB,
    Decisions, DecisionA, DecisionB,
    NoVersion, MaxFileWritesPerHost, MaxCheckpointWritesPerHost

ASSUME
    /\ Hosts = {HostA, HostB}
    /\ HostA # HostB
    /\ Decisions = {DecisionA, DecisionB}
    /\ DecisionA # DecisionB
    /\ NoVersion \notin Nat
    /\ MaxFileWritesPerHost = 2
    /\ MaxCheckpointWritesPerHost = 2

Phases == {"editable", "crashed", "recovering"}
MaxFileVersion == Cardinality(Hosts) * MaxFileWritesPerHost
MaxCheckpointVersion ==
    Cardinality(Hosts) * MaxCheckpointWritesPerHost

VARIABLE state

vars == <<state>>

HostDecision(host) ==
    IF host = HostA THEN DecisionA ELSE DecisionB

DurableEvidence ==
    state.providerFile
        \cup state.providerCheckpoint
        \cup UNION {state.durableWAL[host] : host \in Hosts}

Init ==
    state = [
        phase |-> [host \in Hosts |-> "editable"],
        crashUsed |-> {},
        admitted |-> {},
        live |-> [host \in Hosts |-> {}],
        freshWAL |-> [host \in Hosts |-> TRUE],
        pendingWAL |-> [host \in Hosts |-> {}],
        durableWAL |-> [host \in Hosts |-> {}],
        everWALDurable |-> {},
        filePending |-> [host \in Hosts |-> FALSE],
        fileWrites |-> [host \in Hosts |-> 0],

        providerFile |-> {},
        providerFileVersion |-> 0,
        fileView |-> [host \in Hosts |-> {}],
        fileViewVersion |-> [host \in Hosts |-> 0],
        reconciledFileVersion |-> [host \in Hosts |-> 0],

        providerCheckpoint |-> {},
        providerCheckpointVersion |-> 0,
        checkpointHistory |-> {},
        acceptedCheckpoint |-> [host \in Hosts |-> {}],
        expectedCheckpointVersion |-> [host \in Hosts |-> 0],
        checkpointWrites |-> [host \in Hosts |-> 0],

        startupCheckpoint |-> [host \in Hosts |-> {}],
        startupCheckpointVersion |->
            [host \in Hosts |-> NoVersion],
        recoveryDurable |-> [host \in Hosts |-> FALSE],
        recoveryDurableVersion |->
            [host \in Hosts |-> NoVersion],
        recoveryFileSettled |-> [host \in Hosts |-> FALSE],
        recoveryFileVersion |-> [host \in Hosts |-> NoVersion]
        ]

AdmitEdit(host) ==
    /\ state.phase[host] = "editable"
    /\ state.freshWAL[host]
    /\ HostDecision(host) \notin state.admitted
    /\ state' = [state EXCEPT
        !.admitted = @ \cup {HostDecision(host)},
        !.live[host] = @ \cup {HostDecision(host)},
        !.pendingWAL[host] = @ \cup {HostDecision(host)},
        !.filePending[host] = TRUE
        ]

DurabilizeOneWALRecord(host) ==
    /\ state.phase[host] = "editable"
    /\ \E decision \in
            state.pendingWAL[host] \ state.durableWAL[host]:
        state' = [state EXCEPT
            !.durableWAL[host] = @ \cup {decision},
            !.everWALDurable = @ \cup {decision}
            ]

PublishCurrentFile(host) ==
    /\ state.phase[host] = "editable"
    /\ state.filePending[host]
    /\ state.fileWrites[host] < MaxFileWritesPerHost
    /\ LET nextVersion == state.providerFileVersion + 1
       IN state' = [state EXCEPT
            !.providerFile = state.live[host],
            !.providerFileVersion = nextVersion,
            !.fileView[host] = state.live[host],
            !.fileViewVersion[host] = nextVersion,
            !.reconciledFileVersion[host] = nextVersion,
            !.filePending[host] = FALSE,
            !.fileWrites[host] = @ + 1
            ]

DeliverCurrentFile(host) ==
    /\ state.phase[host] = "editable"
    /\ state.fileViewVersion[host] < state.providerFileVersion
    /\ state' = [state EXCEPT
        !.fileView[host] = state.providerFile,
        !.fileViewVersion[host] = state.providerFileVersion
        ]

ReconcileCurrentFile(host) ==
    /\ state.phase[host] = "editable"
    /\ state.reconciledFileVersion[host]
        < state.fileViewVersion[host]
    /\ LET incoming == state.fileView[host]
           merged == state.live[host] \cup incoming
           newDecisions == incoming \ state.live[host]
       IN state' = [state EXCEPT
            !.live[host] = merged,
            !.pendingWAL[host] = @ \cup newDecisions,
            !.filePending[host] =
                @ \/ merged # incoming,
            !.reconciledFileVersion[host] =
                state.fileViewVersion[host]
            ]

PublishCheckpoint(host) ==
    /\ state.phase[host] = "editable"
    /\ state.expectedCheckpointVersion[host]
        = state.providerCheckpointVersion
    /\ state.acceptedCheckpoint[host]
        = state.providerCheckpoint
    /\ state.providerCheckpoint \subseteq state.live[host]
    /\ state.pendingWAL[host] \subseteq state.durableWAL[host]
    /\ ~state.filePending[host]
    /\ state.live[host] # state.providerCheckpoint
    /\ state.checkpointWrites[host] < MaxCheckpointWritesPerHost
    /\ LET nextVersion == state.providerCheckpointVersion + 1
       IN state' = [state EXCEPT
            !.providerCheckpoint = state.live[host],
            !.providerCheckpointVersion = nextVersion,
            !.checkpointHistory = @ \cup state.live[host],
            !.acceptedCheckpoint[host] = state.live[host],
            !.expectedCheckpointVersion[host] = nextVersion,
            !.checkpointWrites[host] = @ + 1,
            !.pendingWAL[host] = {},
            !.durableWAL[host] = {}
            ]

Crash(host) ==
    /\ state.phase[host] = "editable"
    /\ host \notin state.crashUsed
    /\ state' = [state EXCEPT
        !.phase[host] = "crashed",
        !.crashUsed = @ \cup {host},
        !.live[host] = {},
        !.freshWAL[host] = FALSE,
        !.pendingWAL[host] = {},
        !.filePending[host] = FALSE
        ]

BeginRestart(host) ==
    /\ state.phase[host] = "crashed"
    /\ LET recovered ==
            state.providerCheckpoint \cup state.durableWAL[host]
           needsRecovery ==
            state.durableWAL[host] \ state.providerCheckpoint # {}
       IN state' = [state EXCEPT
            !.phase[host] = "recovering",
            !.live[host] = recovered,
            !.acceptedCheckpoint[host] = state.providerCheckpoint,
            !.expectedCheckpointVersion[host] =
                state.providerCheckpointVersion,
            !.startupCheckpoint[host] = state.providerCheckpoint,
            !.startupCheckpointVersion[host] =
                state.providerCheckpointVersion,
            !.recoveryDurable[host] = ~needsRecovery,
            !.recoveryDurableVersion[host] =
                IF needsRecovery
                  THEN NoVersion
                  ELSE state.providerCheckpointVersion,
            !.recoveryFileSettled[host] =
                ~needsRecovery \/ recovered = state.providerFile,
            !.recoveryFileVersion[host] =
                IF needsRecovery /\ recovered = state.providerFile
                  THEN state.providerFileVersion
                  ELSE NoVersion
            ]

DurabilizeRecoveryResult(host) ==
    /\ state.phase[host] = "recovering"
    /\ ~state.recoveryDurable[host]
    /\ state' = [state EXCEPT
        !.durableWAL[host] = @ \cup state.live[host],
        !.everWALDurable = @ \cup state.live[host],
        !.recoveryDurable[host] = TRUE,
        !.recoveryDurableVersion[host] =
            state.startupCheckpointVersion[host]
        ]

SettleRecoveryFile(host) ==
    /\ state.phase[host] = "recovering"
    /\ state.recoveryDurable[host]
    /\ state.recoveryDurableVersion[host]
        = state.startupCheckpointVersion[host]
    /\ \/ ~state.recoveryFileSettled[host]
       \/ state.recoveryFileVersion[host] # state.providerFileVersion
       \/ state.providerFile # state.live[host]
    /\ state.fileWrites[host] < MaxFileWritesPerHost
    /\ LET nextVersion == state.providerFileVersion + 1
       IN state' = [state EXCEPT
            !.providerFile = state.live[host],
            !.providerFileVersion = nextVersion,
            !.fileView[host] = state.live[host],
            !.fileViewVersion[host] = nextVersion,
            !.reconciledFileVersion[host] = nextVersion,
            !.fileWrites[host] = @ + 1,
            !.recoveryFileSettled[host] = TRUE,
            !.recoveryFileVersion[host] = nextVersion
            ]

RefreshRestartCheckpoint(host) ==
    /\ state.phase[host] = "recovering"
    /\ state.startupCheckpointVersion[host]
        < state.providerCheckpointVersion
    /\ LET recovered ==
            state.live[host] \cup state.providerCheckpoint
           needsRecovery ==
            state.durableWAL[host] \ state.providerCheckpoint # {}
       IN state' = [state EXCEPT
            !.live[host] = recovered,
            !.acceptedCheckpoint[host] = state.providerCheckpoint,
            !.expectedCheckpointVersion[host] =
                state.providerCheckpointVersion,
            !.startupCheckpoint[host] = state.providerCheckpoint,
            !.startupCheckpointVersion[host] =
                state.providerCheckpointVersion,
            !.recoveryDurable[host] = ~needsRecovery,
            !.recoveryDurableVersion[host] =
                IF needsRecovery
                  THEN NoVersion
                  ELSE state.providerCheckpointVersion,
            !.recoveryFileSettled[host] =
                ~needsRecovery \/ recovered = state.providerFile,
            !.recoveryFileVersion[host] =
                IF needsRecovery /\ recovered = state.providerFile
                  THEN state.providerFileVersion
                  ELSE NoVersion
            ]

CompleteRestart(host) ==
    /\ state.phase[host] = "recovering"
    /\ state.startupCheckpointVersion[host]
        = state.providerCheckpointVersion
    /\ state.startupCheckpoint[host] = state.providerCheckpoint
    /\ state.recoveryDurable[host]
    /\ state.recoveryDurableVersion[host]
        = state.startupCheckpointVersion[host]
    /\ state.recoveryFileSettled[host]
    /\ state.providerCheckpoint \subseteq state.live[host]
    /\ (state.live[host] = state.providerCheckpoint
        \/ /\ state.recoveryFileVersion[host] = state.providerFileVersion
           /\ state.providerFile = state.live[host])
    /\ (state.live[host] = state.providerCheckpoint
        \/ state.checkpointWrites[host] < MaxCheckpointWritesPerHost)
    /\ LET writes == state.live[host] # state.providerCheckpoint
           nextVersion ==
                IF writes
                  THEN state.providerCheckpointVersion + 1
                  ELSE state.providerCheckpointVersion
       IN state' = [state EXCEPT
            !.phase[host] = "editable",
            !.freshWAL[host] = TRUE,
            !.providerCheckpoint = state.live[host],
            !.providerCheckpointVersion = nextVersion,
            !.checkpointHistory = @ \cup state.live[host],
            !.acceptedCheckpoint[host] = state.live[host],
            !.expectedCheckpointVersion[host] = nextVersion,
            !.checkpointWrites[host] =
                @ + IF writes THEN 1 ELSE 0,
            !.pendingWAL[host] = {},
            !.durableWAL[host] = {},
            !.startupCheckpointVersion[host] = NoVersion,
            !.recoveryDurable[host] = FALSE,
            !.recoveryDurableVersion[host] = NoVersion,
            !.recoveryFileSettled[host] = FALSE,
            !.recoveryFileVersion[host] = NoVersion
            ]

Next ==
    \/ \E host \in Hosts: AdmitEdit(host)
    \/ \E host \in Hosts: DurabilizeOneWALRecord(host)
    \/ \E host \in Hosts: PublishCurrentFile(host)
    \/ \E host \in Hosts: DeliverCurrentFile(host)
    \/ \E host \in Hosts: ReconcileCurrentFile(host)
    \/ \E host \in Hosts: PublishCheckpoint(host)
    \/ \E host \in Hosts: Crash(host)
    \/ \E host \in Hosts: BeginRestart(host)
    \/ \E host \in Hosts: DurabilizeRecoveryResult(host)
    \/ \E host \in Hosts: SettleRecoveryFile(host)
    \/ \E host \in Hosts: RefreshRestartCheckpoint(host)
    \/ \E host \in Hosts: CompleteRestart(host)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state.phase \in [Hosts -> Phases]
    /\ state.crashUsed \subseteq Hosts
    /\ state.admitted \subseteq Decisions
    /\ state.live \in [Hosts -> SUBSET Decisions]
    /\ state.freshWAL \in [Hosts -> BOOLEAN]
    /\ state.pendingWAL \in [Hosts -> SUBSET Decisions]
    /\ state.durableWAL \in [Hosts -> SUBSET Decisions]
    /\ state.everWALDurable \subseteq Decisions
    /\ state.filePending \in [Hosts -> BOOLEAN]
    /\ state.fileWrites
        \in [Hosts -> 0..MaxFileWritesPerHost]
    /\ state.providerFile \subseteq Decisions
    /\ state.providerFileVersion \in 0..MaxFileVersion
    /\ state.fileView \in [Hosts -> SUBSET Decisions]
    /\ state.fileViewVersion \in [Hosts -> 0..MaxFileVersion]
    /\ state.reconciledFileVersion
        \in [Hosts -> 0..MaxFileVersion]
    /\ state.providerCheckpoint \subseteq Decisions
    /\ state.providerCheckpointVersion \in 0..MaxCheckpointVersion
    /\ state.checkpointHistory \subseteq Decisions
    /\ state.acceptedCheckpoint \in [Hosts -> SUBSET Decisions]
    /\ state.expectedCheckpointVersion
        \in [Hosts -> 0..MaxCheckpointVersion]
    /\ state.checkpointWrites
        \in [Hosts -> 0..MaxCheckpointWritesPerHost]
    /\ state.startupCheckpoint \in [Hosts -> SUBSET Decisions]
    /\ state.startupCheckpointVersion
        \in [Hosts -> (0..MaxCheckpointVersion) \cup {NoVersion}]
    /\ state.recoveryDurable \in [Hosts -> BOOLEAN]
    /\ state.recoveryDurableVersion
        \in [Hosts -> (0..MaxCheckpointVersion) \cup {NoVersion}]
    /\ state.recoveryFileSettled \in [Hosts -> BOOLEAN]
    /\ state.recoveryFileVersion
        \in [Hosts -> (0..MaxFileVersion) \cup {NoVersion}]

AllDurableDecisionsRemainRecoverable ==
    state.everWALDurable \subseteq DurableEvidence

ProviderCheckpointsNeverForgetDecisions ==
    state.checkpointHistory = state.providerCheckpoint

EditingRequiresFreshWAL ==
    \A host \in Hosts:
        state.phase[host] = "editable" => state.freshWAL[host]

FreshWALIsNotExposedDuringRecovery ==
    \A host \in Hosts:
        state.phase[host] # "editable" => ~state.freshWAL[host]

CurrentCheckpointViewsAreExact ==
    \A host \in Hosts:
        state.expectedCheckpointVersion[host]
                = state.providerCheckpointVersion
            => state.acceptedCheckpoint[host]
                = state.providerCheckpoint

CrashPreservesDurableWAL ==
    \A host \in Hosts:
        [][Crash(host) =>
            state'.durableWAL[host] = state.durableWAL[host]]_vars

CheckpointPublicationRequiresSettledDurableState ==
    \A host \in Hosts:
        [][PublishCheckpoint(host) =>
            /\ state.pendingWAL[host] \subseteq state.durableWAL[host]
            /\ ~state.filePending[host]
            /\ state.expectedCheckpointVersion[host]
                = state.providerCheckpointVersion
            /\ state.acceptedCheckpoint[host]
                = state.providerCheckpoint]_vars

RestartCurrentChangedDoesNotWrite ==
    \A host \in Hosts:
        [][RefreshRestartCheckpoint(host) =>
            /\ state'.providerCheckpoint = state.providerCheckpoint
            /\ state'.providerCheckpointVersion
                = state.providerCheckpointVersion]_vars

RestartCompletionUsesExactDurableInputs ==
    \A host \in Hosts:
        [][CompleteRestart(host) =>
            /\ state.startupCheckpointVersion[host]
                = state.providerCheckpointVersion
            /\ state.startupCheckpoint[host]
                = state.providerCheckpoint
            /\ state.recoveryDurable[host]
            /\ state.recoveryDurableVersion[host]
                = state.startupCheckpointVersion[host]
            /\ state.recoveryFileSettled[host]
            /\ (state.live[host] = state.providerCheckpoint
                \/ /\ state.recoveryFileVersion[host]
                    = state.providerFileVersion
                   /\ state.providerFile = state.live[host])
            /\ state'.live[host] = state.live[host]
            /\ state'.freshWAL[host]]_vars

=============================================================================
