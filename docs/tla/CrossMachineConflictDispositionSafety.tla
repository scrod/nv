--------------- MODULE CrossMachineConflictDispositionSafety ---------------
EXTENDS FiniteSets, Naturals

\* Two hosts may snapshot and dispose the same Apple-reported unresolved
\* members concurrently.  Source notes, saved-copy candidates, and their exact
\* generations are host-local; deterministic recovery identities are shared by
\* construction.  One later member and one intervening local source/copy edit
\* expose snapshot-scope and stale-evidence errors.  Current-file publication
\* and reconciliation remain in CrossMachineCurrentVisibleSafety.

CONSTANTS
    Hosts, HostA, HostB,
    Members, Member1, Member2,
    Bodies, Body1, Body2, CurrentBody,
    RecoveryIDs, RecoveryID1, RecoveryID2,
    NoID, NoBody, ModifiedBody,
    MaxSourceVersion, MaxCandidateGeneration

ASSUME
    /\ Hosts = {HostA, HostB}
    /\ HostA # HostB
    /\ Members = {Member1, Member2}
    /\ Member1 # Member2
    /\ Bodies = {Body1, Body2}
    /\ Body1 # Body2
    /\ CurrentBody \notin Bodies
    /\ RecoveryIDs = {RecoveryID1, RecoveryID2}
    /\ RecoveryID1 # RecoveryID2
    /\ NoID \notin RecoveryIDs
    /\ NoBody \notin Bodies \cup {CurrentBody, ModifiedBody}
    /\ ModifiedBody \notin Bodies \cup {CurrentBody}
    /\ MaxSourceVersion = 3
    /\ MaxCandidateGeneration = 2

Phases == {
    "idle", "selecting",
    "saveSelected", "savePrepared", "saveDurable", "saveInstalled",
    "useSelected", "useApplied", "useDurable", "useInstalled",
    "parked", "done"
}

CandidateStates == Bodies \cup {NoBody, ModifiedBody}

VARIABLE state

vars == <<state>>

MemberBody(member) ==
    IF member = Member1 THEN Body1 ELSE Body2

RecoveryID(member) ==
    IF member = Member1 THEN RecoveryID1 ELSE RecoveryID2

SelectedMember(host) == CHOOSE member \in state.selected[host]: TRUE

SavePhases == {
    "saveSelected", "savePrepared", "saveDurable", "saveInstalled"
}

UsePhases == {
    "useSelected", "useApplied", "useDurable", "useInstalled"
}

Init ==
    state = [
        phase |-> [host \in Hosts |-> "idle"],
        operationUsed |-> {},
        snapshot |-> [host \in Hosts |-> {}],
        selected |-> [host \in Hosts |-> {}],
        capturedSourceVersion |-> [host \in Hosts |-> 0],
        operationSourceVersion |-> [host \in Hosts |-> 0],
        targetBody |-> [host \in Hosts |-> CurrentBody],

        providerMembers |-> {Member1},
        unresolved |-> {Member1},
        resolved |-> {},
        removedVersions |-> {},
        laterMemberArrived |-> FALSE,

        sourceBody |-> [host \in Hosts |-> CurrentBody],
        sourceVersion |-> [host \in Hosts |-> 0],
        sourceEditUsed |-> {},

        candidateBody |->
            [host \in Hosts |-> [id \in RecoveryIDs |-> NoBody]],
        candidateGeneration |->
            [host \in Hosts |-> [id \in RecoveryIDs |-> 0]],
        modifiedCandidateIDs |-> [host \in Hosts |-> {}],
        pendingCopyID |-> [host \in Hosts |-> NoID],
        pendingCopyGeneration |-> [host \in Hosts |-> 0]
        ]

ProviderReportsLaterMember ==
    /\ ~state.laterMemberArrived
    /\ state' = [state EXCEPT
        !.laterMemberArrived = TRUE,
        !.providerMembers = @ \cup {Member2},
        !.unresolved = @ \cup {Member2}
        ]

StartResolver(host) ==
    /\ state.phase[host] = "idle"
    /\ host \notin state.operationUsed
    /\ state.unresolved # {}
    /\ state' = [state EXCEPT
        !.phase[host] = "selecting",
        !.operationUsed = @ \cup {host},
        !.snapshot[host] = state.unresolved,
        !.capturedSourceVersion[host] = state.sourceVersion[host]
        ]

BeginSaveAsNew(host) ==
    /\ state.phase[host] = "selecting"
    /\ \E member \in state.snapshot[host] \cap state.unresolved:
        state' = [state EXCEPT
            !.phase[host] = "saveSelected",
            !.selected[host] = {member},
            !.targetBody[host] = MemberBody(member),
            !.pendingCopyID[host] = RecoveryID(member)
            ]

DiscoverExistingExactSavedCopy(host) ==
    /\ state.phase[host] = "saveSelected"
    /\ LET id == state.pendingCopyID[host]
       IN /\ state.candidateBody[host][id] = NoBody
          /\ state.candidateGeneration[host][id]
                < MaxCandidateGeneration
          /\ state' = [state EXCEPT
                !.candidateBody[host][id] = state.targetBody[host],
                !.candidateGeneration[host][id] = @ + 1
                ]

PrepareOrReuseSavedCopy(host) ==
    /\ state.phase[host] = "saveSelected"
    /\ LET member == SelectedMember(host)
           id == RecoveryID(member)
           body == MemberBody(member)
           creates == state.candidateBody[host][id] = NoBody
           nextGeneration ==
                IF creates
                  THEN state.candidateGeneration[host][id] + 1
                  ELSE state.candidateGeneration[host][id]
       IN /\ state.candidateBody[host][id] \in {NoBody, body}
          /\ nextGeneration <= MaxCandidateGeneration
          /\ state' = [state EXCEPT
                !.phase[host] = "savePrepared",
                !.candidateBody[host][id] = body,
                !.candidateGeneration[host][id] = nextGeneration,
                !.pendingCopyGeneration[host] = nextGeneration
                ]

ParkUnavailableSavedSlot(host) ==
    /\ state.phase[host] = "saveSelected"
    /\ LET id == state.pendingCopyID[host]
       IN state.candidateBody[host][id] = ModifiedBody
    /\ state' = [state EXCEPT !.phase[host] = "parked"]

DurabilizeSavedCopy(host) ==
    /\ state.phase[host] = "savePrepared"
    /\ LET id == state.pendingCopyID[host]
       IN /\ state.candidateBody[host][id] = state.targetBody[host]
          /\ state.candidateGeneration[host][id]
                = state.pendingCopyGeneration[host]
    /\ state' = [state EXCEPT !.phase[host] = "saveDurable"]

InstallSavedCopy(host) ==
    /\ state.phase[host] = "saveDurable"
    /\ LET id == state.pendingCopyID[host]
       IN /\ state.candidateBody[host][id] = state.targetBody[host]
          /\ state.candidateGeneration[host][id]
                = state.pendingCopyGeneration[host]
    /\ state' = [state EXCEPT !.phase[host] = "saveInstalled"]

ResolveSavedMember(host) ==
    /\ state.phase[host] = "saveInstalled"
    /\ LET member == SelectedMember(host)
           id == state.pendingCopyID[host]
       IN /\ member \in state.unresolved
          /\ id = RecoveryID(member)
          /\ state.candidateBody[host][id] = MemberBody(member)
          /\ state.candidateGeneration[host][id]
                = state.pendingCopyGeneration[host]
          /\ state' = [state EXCEPT
                !.phase[host] = "done",
                !.unresolved = @ \ {member},
                !.resolved = @ \cup {member}
                ]

ObserveSavedMemberAlreadyResolved(host) ==
    /\ state.phase[host] \in SavePhases
    /\ SelectedMember(host) \notin state.unresolved
    /\ state' = [state EXCEPT !.phase[host] = "done"]

ModifySavedCopy(host, id) ==
    /\ id \in RecoveryIDs \ state.modifiedCandidateIDs[host]
    /\ state.candidateBody[host][id] \in Bodies
    /\ state.candidateGeneration[host][id] < MaxCandidateGeneration
    /\ state' = [state EXCEPT
        !.candidateBody[host][id] = ModifiedBody,
        !.candidateGeneration[host][id] = @ + 1,
        !.modifiedCandidateIDs[host] = @ \cup {id}
        ]

ParkStaleSavedDisposition(host) ==
    /\ state.phase[host] \in
        {"savePrepared", "saveDurable", "saveInstalled"}
    /\ LET id == state.pendingCopyID[host]
       IN \/ state.candidateBody[host][id] # state.targetBody[host]
          \/ state.candidateGeneration[host][id]
                # state.pendingCopyGeneration[host]
    /\ state' = [state EXCEPT !.phase[host] = "parked"]

BeginUseVersion(host) ==
    /\ state.phase[host] = "selecting"
    /\ \E member \in state.snapshot[host] \cap state.unresolved:
        state' = [state EXCEPT
            !.phase[host] = "useSelected",
            !.selected[host] = {member},
            !.targetBody[host] = MemberBody(member)
            ]

BeginUseCurrent(host) ==
    /\ state.phase[host] = "selecting"
    /\ state.sourceVersion[host] = state.capturedSourceVersion[host]
    /\ state' = [state EXCEPT
        !.phase[host] = "useApplied",
        !.selected[host] = {},
        !.targetBody[host] = state.sourceBody[host],
        !.operationSourceVersion[host] = state.sourceVersion[host]
        ]

ApplySelectedVersion(host) ==
    /\ state.phase[host] = "useSelected"
    /\ state.sourceVersion[host] = state.capturedSourceVersion[host]
    /\ state.sourceVersion[host] < MaxSourceVersion
    /\ LET nextVersion == state.sourceVersion[host] + 1
       IN state' = [state EXCEPT
            !.phase[host] = "useApplied",
            !.sourceBody[host] = state.targetBody[host],
            !.sourceVersion[host] = nextVersion,
            !.operationSourceVersion[host] = nextVersion
            ]

ParkStaleUseBeforeApply(host) ==
    /\ state.phase[host] = "useSelected"
    /\ state.sourceVersion[host] # state.capturedSourceVersion[host]
    /\ state' = [state EXCEPT !.phase[host] = "parked"]

DurabilizeUsedCurrent(host) ==
    /\ state.phase[host] = "useApplied"
    /\ state.sourceVersion[host] = state.operationSourceVersion[host]
    /\ state.sourceBody[host] = state.targetBody[host]
    /\ state' = [state EXCEPT !.phase[host] = "useDurable"]

InstallUsedCurrent(host) ==
    /\ state.phase[host] = "useDurable"
    /\ state.sourceVersion[host] = state.operationSourceVersion[host]
    /\ state.sourceBody[host] = state.targetBody[host]
    /\ state' = [state EXCEPT !.phase[host] = "useInstalled"]

ResolveUseSnapshot(host) ==
    /\ state.phase[host] = "useInstalled"
    /\ state.sourceVersion[host] = state.operationSourceVersion[host]
    /\ state.sourceBody[host] = state.targetBody[host]
    /\ LET applicable == state.snapshot[host] \cap state.unresolved
       IN state' = [state EXCEPT
            !.phase[host] = "done",
            !.unresolved = @ \ applicable,
            !.resolved = @ \cup applicable
            ]

EditSourceAfterChoice(host) ==
    /\ host \notin state.sourceEditUsed
    /\ state.phase[host] \in
        {"useSelected", "useApplied", "useDurable", "useInstalled"}
    /\ state.sourceVersion[host] < MaxSourceVersion
    /\ state' = [state EXCEPT
        !.sourceEditUsed = @ \cup {host},
        !.sourceBody[host] = CurrentBody,
        !.sourceVersion[host] = @ + 1
        ]

ParkStaleUseDisposition(host) ==
    /\ state.phase[host] \in
        {"useApplied", "useDurable", "useInstalled"}
    /\ \/ state.sourceVersion[host] # state.operationSourceVersion[host]
       \/ state.sourceBody[host] # state.targetBody[host]
    /\ state' = [state EXCEPT !.phase[host] = "parked"]

Next ==
    \/ ProviderReportsLaterMember
    \/ \E host \in Hosts: StartResolver(host)
    \/ \E host \in Hosts: BeginSaveAsNew(host)
    \/ \E host \in Hosts: DiscoverExistingExactSavedCopy(host)
    \/ \E host \in Hosts: PrepareOrReuseSavedCopy(host)
    \/ \E host \in Hosts: ParkUnavailableSavedSlot(host)
    \/ \E host \in Hosts: DurabilizeSavedCopy(host)
    \/ \E host \in Hosts: InstallSavedCopy(host)
    \/ \E host \in Hosts: ResolveSavedMember(host)
    \/ \E host \in Hosts: ObserveSavedMemberAlreadyResolved(host)
    \/ \E host \in Hosts, id \in RecoveryIDs:
        ModifySavedCopy(host, id)
    \/ \E host \in Hosts: ParkStaleSavedDisposition(host)
    \/ \E host \in Hosts: BeginUseVersion(host)
    \/ \E host \in Hosts: BeginUseCurrent(host)
    \/ \E host \in Hosts: ApplySelectedVersion(host)
    \/ \E host \in Hosts: ParkStaleUseBeforeApply(host)
    \/ \E host \in Hosts: DurabilizeUsedCurrent(host)
    \/ \E host \in Hosts: InstallUsedCurrent(host)
    \/ \E host \in Hosts: ResolveUseSnapshot(host)
    \/ \E host \in Hosts: EditSourceAfterChoice(host)
    \/ \E host \in Hosts: ParkStaleUseDisposition(host)

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state.phase \in [Hosts -> Phases]
    /\ state.operationUsed \subseteq Hosts
    /\ state.snapshot \in [Hosts -> SUBSET Members]
    /\ state.selected \in [Hosts -> SUBSET Members]
    /\ \A host \in Hosts: Cardinality(state.selected[host]) <= 1
    /\ state.capturedSourceVersion
        \in [Hosts -> 0..MaxSourceVersion]
    /\ state.operationSourceVersion
        \in [Hosts -> 0..MaxSourceVersion]
    /\ state.targetBody \in [Hosts -> Bodies \cup {CurrentBody}]
    /\ state.providerMembers \subseteq Members
    /\ state.unresolved \subseteq Members
    /\ state.resolved \subseteq Members
    /\ state.removedVersions \subseteq Members
    /\ state.laterMemberArrived \in BOOLEAN
    /\ state.sourceBody \in [Hosts -> Bodies \cup {CurrentBody}]
    /\ state.sourceVersion \in [Hosts -> 0..MaxSourceVersion]
    /\ state.sourceEditUsed \subseteq Hosts
    /\ state.candidateBody
        \in [Hosts -> [RecoveryIDs -> CandidateStates]]
    /\ state.candidateGeneration
        \in [Hosts -> [RecoveryIDs -> 0..MaxCandidateGeneration]]
    /\ state.modifiedCandidateIDs
        \in [Hosts -> SUBSET RecoveryIDs]
    /\ state.pendingCopyID
        \in [Hosts -> RecoveryIDs \cup {NoID}]
    /\ state.pendingCopyGeneration
        \in [Hosts -> 0..MaxCandidateGeneration]

ProviderMembershipIsPartitioned ==
    /\ state.unresolved \cap state.resolved = {}
    /\ state.providerMembers = state.unresolved \cup state.resolved

OnlyDisclosedMembersResolve ==
    state.resolved \subseteq state.providerMembers

ProviderHistoryIsNeverRemoved ==
    state.removedVersions = {}

PreparedCopiesUseDeterministicIdentity ==
    \A host \in Hosts:
        state.phase[host] \in
                {"savePrepared", "saveDurable", "saveInstalled"}
            => state.pendingCopyID[host]
                = RecoveryID(SelectedMember(host))

ConcurrentSavesOfOneMemberShareIdentity ==
    \A first \in Hosts:
      \A second \in Hosts:
        /\ state.phase[first] \in SavePhases
        /\ state.phase[second] \in SavePhases
        /\ state.selected[first] = state.selected[second]
        => state.pendingCopyID[first] = state.pendingCopyID[second]

ExactSavedCopyReusePreservesLocalGeneration ==
    \A host \in Hosts:
        [][LET id == RecoveryID(SelectedMember(host))
           IN /\ PrepareOrReuseSavedCopy(host)
              /\ state.candidateBody[host][id]
                    = MemberBody(SelectedMember(host))
              => state'.candidateGeneration[host][id]
                    = state.candidateGeneration[host][id]]_vars

ResolutionIsMonotonic ==
    [][state.resolved \subseteq state'.resolved]_vars

SavedResolutionIsSelectedMemberOnly ==
    \A host \in Hosts:
        [][ResolveSavedMember(host) =>
            state'.resolved \ state.resolved = state.selected[host]]_vars

SavedResolutionRequiresExactInstalledCopy ==
    \A host \in Hosts:
        [][ResolveSavedMember(host) =>
            /\ state.phase[host] = "saveInstalled"
            /\ state.pendingCopyID[host]
                = RecoveryID(SelectedMember(host))
            /\ state.candidateBody[host][state.pendingCopyID[host]]
                = MemberBody(SelectedMember(host))
            /\ state.candidateGeneration[host][state.pendingCopyID[host]]
                = state.pendingCopyGeneration[host]]_vars

UseResolutionIsExactlySnapshotScoped ==
    \A host \in Hosts:
        [][ResolveUseSnapshot(host) =>
            state'.resolved \ state.resolved =
                state.snapshot[host] \cap state.unresolved]_vars

UseResolutionRequiresExactInstalledCurrent ==
    \A host \in Hosts:
        [][ResolveUseSnapshot(host) =>
            /\ state.phase[host] = "useInstalled"
            /\ state.sourceVersion[host]
                = state.operationSourceVersion[host]
            /\ state.sourceBody[host] = state.targetBody[host]]_vars

SourceBodyChangesOnlyThroughExplicitChoiceOrEdit ==
    \A host \in Hosts:
        [][state'.sourceBody[host] # state.sourceBody[host] =>
            \/ EditSourceAfterChoice(host)
            \/ ApplySelectedVersion(host)]_vars

LocalChoiceDoesNotMutateOtherHostSource ==
    \A host \in Hosts:
      \A other \in Hosts \ {host}:
        [][ApplySelectedVersion(host) =>
            /\ state'.sourceBody[other] = state.sourceBody[other]
            /\ state'.sourceVersion[other] = state.sourceVersion[other]]_vars

=============================================================================
