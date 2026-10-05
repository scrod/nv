---------------- MODULE ReceiveSnapshotAssemblySafety ----------------
EXTENDS Naturals, FiniteSets

\* Source bridge: retainCandidate/wakeArrivedCandidate, prepareReceived,
\* parkReceived, acceptGeneralSnapshot and rejectReceived. SQL commits are
\* atomic; discovery, transaction preparation, close and crashes interleave.
CONSTANTS Policy, Shared, UnsupportedPage, MaxCrashes, MaxFailures
ASSUME /\ Policy \in {"safe", "lostArrival", "stalePark", "candidateAccepted", "circular", "inherit"}
       /\ Shared \in BOOLEAN /\ UnsupportedPage \in BOOLEAN
       /\ MaxCrashes \in Nat /\ MaxFailures \in Nat

\* 0: previously accepted bootstrap; 1 -> 2: ordinary history;
\* 3,4: inert assembly pages; 5: valid root; 6: unrelated Changes;
\* 7: an intrinsically bad root sharing the same valid pages.
History == {0,1,2,6}
Pages == {3,4}
Roots == IF Shared THEN {5,7} ELSE {5}
Objects == History \union Pages \union Roots
Incoming == Objects \ {0}
OwnInvalid == (IF Shared THEN {7} ELSE {}) \union (IF UnsupportedPage THEN {3} ELSE {})
Actionable == (History \union Roots \union OwnInvalid) \ {0}
Parents(o) == IF o = 2 THEN {1} ELSE IF o \in History \ {0} THEN {0} ELSE {}
PageRequirements(o) == IF o \in Roots THEN {3,4} ELSE {}
HistoryRequirements(o) == IF o \in Roots THEN {0,1,2} ELSE Parents(o)
Requirements == {"bytes", "history"} \X Objects

VARIABLES stored, accepted, ready, waits, rejected, delivered, effects,
          active, phase, discovered, open, blockedIO, crashes, failures,
          closes, arrivalDuringPark, duplicates
vars == <<stored, accepted, ready, waits, rejected, delivered, effects,
          active, phase, discovered, open, blockedIO, crashes, failures,
          closes, arrivalDuringPark, duplicates>>
TypeOK ==
    /\ stored \subseteq Objects /\ accepted \subseteq Objects
    /\ ready \subseteq Actionable /\ rejected \subseteq Incoming
    /\ waits \in [Objects -> SUBSET Objects] /\ delivered \subseteq Incoming
    /\ effects \in [History -> 0..1]
    /\ active \in Objects /\ phase \in {"idle", "discover", "park", "accept", "reject"}
    /\ discovered \subseteq Requirements
    /\ open \in BOOLEAN /\ blockedIO \in BOOLEAN
    /\ crashes \in 0..MaxCrashes /\ failures \in 0..MaxFailures
    /\ closes \in 0..1 /\ arrivalDuringPark \in BOOLEAN /\ duplicates \in 0..1

Init ==
    /\ stored = {0} /\ accepted = {0} /\ ready = {} /\ rejected = {}
    /\ waits = [o \in Objects |-> {}] /\ delivered = {}
    /\ effects = [o \in History |-> IF o = 0 THEN 1 ELSE 0]
    /\ active = 0 /\ phase = "idle" /\ discovered = {}
    /\ open = TRUE /\ blockedIO = FALSE /\ crashes = 0 /\ failures = 0
    /\ closes = 0 /\ arrivalDuringPark = FALSE /\ duplicates = 0

Satisfied(r) ==
    /\ r[2] \notin rejected
    /\ IF r[1] = "bytes" THEN r[2] \in stored \ OwnInvalid ELSE r[2] \in accepted
Needed(o) == {<<"bytes",p>> : p \in PageRequirements(o)}
             \union {<<"history",h>> : h \in HistoryRequirements(o)}
AlgorithmMissing(o) ==
    \* Reading an unsupported child discovers its own failure even before a
    \* separate queue turn has committed that child's rejection record.
    LET pages == {p \in PageRequirements(o) : p \notin stored \/ p \in rejected \/ p \in OwnInvalid}
        first == IF pages = {} THEN {} ELSE {CHOOSE p \in pages : \A q \in pages : p <= q}
        pageRole == IF Policy = "circular" THEN "history" ELSE "bytes"
        missingPages == IF Policy = "circular" THEN PageRequirements(o) \ accepted ELSE first
        knownHistory == IF Policy = "candidateAccepted" THEN stored ELSE accepted
    IN IF missingPages # {} THEN {<<pageRole,p>> : p \in missingPages}
       ELSE {<<"history",h>> : h \in HistoryRequirements(o) \ knownHistory}
Wake(id, available) == {o \in Actionable \intersect available : id \in waits[o] /\ o \notin accepted /\ o \notin rejected}

\* Exact arrival and reverse-wait wakeups share the retention transaction.
\* Intake is finite: every role may arrive, plus one duplicate of any role.
\* Progress is checked after finite interference, rather than assuming a fair
\* scheduler can defeat an infinite stream that continually requeues one root.
Deliver(o) ==
    /\ open /\ ~blockedIO /\ o \in Incoming
    /\ o \notin delivered \/ duplicates = 0
    /\ duplicates' = IF o \in delivered THEN duplicates + 1 ELSE duplicates
    /\ stored' = stored \union {o} /\ delivered' = delivered \union {o}
    /\ ready' = ready \union (IF o \in Actionable /\ o \notin accepted /\ o \notin rejected THEN {o} ELSE {})
                 \union (IF Policy = "lostArrival" /\ o \in Pages THEN {} ELSE Wake(o, stored \union {o}))
    /\ arrivalDuringPark' = (arrivalDuringPark \/ (phase = "park" /\ <<"bytes",o>> \in discovered))
    /\ UNCHANGED <<accepted, waits, rejected, effects, active, phase, discovered, open, blockedIO, crashes, failures, closes>>

Begin(o) ==
    /\ open /\ ~blockedIO /\ phase = "idle" /\ o \in ready
    /\ active' = o /\ phase' = "discover" /\ discovered' = {}
    /\ UNCHANGED <<stored, accepted, ready, waits, rejected, delivered, effects, open, blockedIO, crashes, failures, closes, arrivalDuringPark, duplicates>>
Discover ==
    /\ open /\ ~blockedIO /\ phase = "discover"
    /\ LET missing == AlgorithmMissing(active)
       IN /\ discovered' = missing
          /\ phase' = IF active \in OwnInvalid /\ (active \in Pages \/ missing = {}) THEN "reject"
                      ELSE IF Policy = "inherit" /\ active \in Roots /\ (PageRequirements(active) \intersect rejected) # {} THEN "reject"
                      ELSE IF missing # {} THEN "park" ELSE "accept"
    /\ UNCHANGED <<stored, accepted, ready, waits, rejected, delivered, effects, active, open, blockedIO, crashes, failures, closes, arrivalDuringPark, duplicates>>

\* The recheck belongs to this same atomic SQL commit. Arrival may precede or follow it.
CommitPark ==
    /\ open /\ ~blockedIO /\ phase = "park"
    /\ LET missing == IF Policy = "stalePark" THEN discovered ELSE {r \in discovered : ~Satisfied(r)}
       IN /\ waits' = [waits EXCEPT ![active] = {r[2] : r \in missing}]
          /\ ready' = IF missing = {} THEN ready \union {active} ELSE ready \ {active}
    /\ phase' = "idle" /\ discovered' = {}
    /\ UNCHANGED <<stored, accepted, rejected, delivered, effects, active, open, blockedIO, crashes, failures, closes, arrivalDuringPark, duplicates>>
CommitAccept ==
    /\ open /\ ~blockedIO /\ phase = "accept"
    /\ AlgorithmMissing(active) = {}
    /\ LET batch == IF active \in Roots THEN {active} \union Pages ELSE {active}
       IN /\ accepted' = accepted \union batch
          /\ ready' = (ready \ {active}) \union UNION {Wake(o, stored) : o \in batch}
          /\ waits' = [o \in Objects |-> IF o \in batch THEN {} ELSE waits[o]]
    /\ effects' = [o \in History |-> IF o = active THEN 1 ELSE effects[o]]
    /\ phase' = "idle" /\ discovered' = {}
    /\ UNCHANGED <<stored, rejected, delivered, active, open, blockedIO, crashes, failures, closes, arrivalDuringPark, duplicates>>
CommitReject ==
    /\ open /\ ~blockedIO /\ phase = "reject"
    /\ rejected' = rejected \union {active} /\ ready' = ready \ {active}
    /\ waits' = [waits EXCEPT ![active] = {}]
    /\ phase' = "idle" /\ discovered' = {}
    /\ UNCHANGED <<stored, accepted, delivered, effects, active, open, blockedIO, crashes, failures, closes, arrivalDuringPark, duplicates>>

\* Failed writes preserve exact candidate bytes and previously committed queue state.
WriteFailure ==
    /\ open /\ ~blockedIO /\ phase \in {"park", "accept", "reject"} /\ failures < MaxFailures
    /\ failures' = failures + 1 /\ blockedIO' = TRUE /\ phase' = "idle" /\ discovered' = {}
    /\ UNCHANGED <<stored, accepted, ready, waits, rejected, delivered, effects, active, open, crashes, closes, arrivalDuringPark, duplicates>>
Retry ==
    /\ open /\ blockedIO /\ blockedIO' = FALSE
    /\ UNCHANGED <<stored, accepted, ready, waits, rejected, delivered, effects, active, phase, discovered, open, crashes, failures, closes, arrivalDuringPark, duplicates>>
Crash ==
    /\ open /\ crashes < MaxCrashes /\ crashes' = crashes + 1
    /\ open' = FALSE /\ phase' = "idle" /\ discovered' = {}
    /\ UNCHANGED <<stored, accepted, ready, waits, rejected, delivered, effects, active, blockedIO, failures, closes, arrivalDuringPark, duplicates>>
Close ==
    /\ open /\ closes = 0 /\ closes' = 1 /\ open' = FALSE /\ phase' = "idle" /\ discovered' = {}
    /\ UNCHANGED <<stored, accepted, ready, waits, rejected, delivered, effects, active, blockedIO, crashes, failures, arrivalDuringPark, duplicates>>
Reopen ==
    /\ ~open /\ open' = TRUE /\ blockedIO' = FALSE
    /\ UNCHANGED <<stored, accepted, ready, waits, rejected, delivered, effects, active, phase, discovered, crashes, failures, closes, arrivalDuringPark, duplicates>>
Next == \/ \E o \in Incoming : Deliver(o)
        \/ \E o \in Actionable : Begin(o)
        \/ Discover \/ CommitPark \/ CommitAccept \/ CommitReject
        \/ WriteFailure \/ Retry \/ Crash \/ Close \/ Reopen
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ (\A o \in Actionable : WF_vars(Begin(o)))
           /\ WF_vars(Discover) /\ WF_vars(CommitPark) /\ WF_vars(CommitAccept) /\ WF_vars(CommitReject)
           /\ WF_vars(Retry) /\ WF_vars(Reopen)

\* Independent observations name the complete expected batch and original history.
ExactInputsRetained == delivered \subseteq stored
OriginalHistoryPreserved == 0 \in accepted /\ effects[0] = 1
AcceptanceHasBytes == accepted \subseteq stored
HistoryClosure == \A o \in accepted \intersect History : Parents(o) \subseteq accepted
CompleteRoot == 5 \in accepted => {0,1,2,3,4,5} \subseteq accepted
OwnRejectionOnly == rejected \subseteq OwnInvalid
RejectionSettled == \A o \in rejected : o \notin ready /\ waits[o] = {} /\ o \notin accepted
EffectsExactlyOnce == \A o \in History : effects[o] = IF o \in accepted THEN 1 ELSE 0
QueueAccounted == \A o \in (stored \intersect Actionable) \ (accepted \union rejected) : o \in ready \/ waits[o] # {}
EligibleRunnable == \A o \in (stored \intersect Actionable) \ (accepted \union rejected) :
                     (\A r \in Needed(o) : Satisfied(r)) => o \in ready
RootCompletes == (5 \in stored /\ {0,1,2,3,4} \subseteq stored /\ ~UnsupportedPage) ~> (5 \in accepted)
UnrelatedCompletes == 6 \in stored ~> 6 \in accepted
NeverArrivalDuringPark == ~arrivalDuringPark
NeverRetainedHistoryWait == ~(5 \in stored /\ 2 \in stored \ accepted /\ 2 \in waits[5])
NeverCompleteRoot == 5 \notin accepted
NeverBlockedAndIndependent == ~(6 \in accepted /\ 3 \in rejected /\ waits[5] # {})
NeverRecoveredAfterTwoFailures == ~(failures = 2 /\ crashes = 2 /\ 5 \in accepted)
=======================================================================
