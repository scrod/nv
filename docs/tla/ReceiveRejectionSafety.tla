------------------------- MODULE ReceiveRejectionSafety -------------------------
EXTENDS Naturals, FiniteSets

\* A fixed exact-object graph, one serial SQL writer, and durable receive work.
\* 0: existing accepted history; 1: valid/invalid/unsupported prerequisite;
\* 2: another valid prerequisite; 3: child; 4: grandchild; 5: unrelated input.
\* "chain" exercises two-level blockage; "multiple" exercises partial wakeups.
\* Authenticated envelopes, intrinsic validity and SQL atomic commit are inputs.
\* Delivery/parent acceptance can occur at free writer turns. Actor reservation
\* and history-prefix interference are checked in ReceiveResumptionSafety.
CONSTANTS Policy, Topology, RootKind, MaxCrashes, MaxFailures
ASSUME Policy \in {"safe","splitReject","propagate","eraseBytes","lostWake",
 "splitPark","acceptBlocked","duplicateEffect","dropReady","ioIsRejection","directOnly","rejectAltersHistory"}
 /\ Topology \in {"chain","multiple"}
 /\ RootKind \in {"valid","invalid","unsupported"}
 /\ MaxCrashes \in 0..2 /\ MaxFailures \in 0..2
Objects == {0,1,2,3,4,5}
Inputs == IF Topology="chain" THEN {1,3,4,5} ELSE {1,2,3,5}
Parents(o) == CASE o=3 -> IF Topology="chain" THEN {1} ELSE {1,2}
 [] o=4 -> {3} [] OTHER -> {}
Good(o) == o#1 \/ RootKind="valid"
Original(o) == o+1
EmptyWaits == [o \in Objects |-> {}]
InitialDB == [bytes |-> [o \in Objects |-> IF o=0 THEN Original(o) ELSE 0],
 accepted |-> {0}, effects |-> [o \in Objects |-> IF o=0 THEN 1 ELSE 0],
 ready |-> {}, waits |-> EmptyWaits,
 rejected |-> [o \in Objects |-> "none"]]
VARIABLE s
vars == <<s>>
Stored(d) == {o \in Objects: d.bytes[o]#0}
Rejected(d) == {o \in Objects: d.rejected[o]#"none"}
Missing(d,o) == Parents(o) \ d.accepted
WriterFree == s.phase \in {"idle","inspect","validate","parkGap","finish"}
Init == s=[db |-> InitialDB, work |-> InitialDB, mode |-> "running",
 phase |-> "idle", item |-> 0, missing |-> {}, crashes |-> 0, failures |-> 0,
 delivered |-> {}, duplicate |-> FALSE, parked |-> {}, rejectionAttempted |-> FALSE,
 rejectFailures |-> 0, rejectCrashCuts |-> {}, lostRejectCompletion |-> FALSE]

\* Stable exact bytes are inserted with their durable ready entry.
Deliver(o) == /\ s.mode="running" /\ WriterFree /\ o \in Inputs \ Stored(s.db)
 /\ s'=[s EXCEPT !.db.bytes[o]=Original(o), !.db.ready=@ \cup {o},
                   !.delivered=@ \cup {o}]
Duplicate(o) == /\ s.mode="running" /\ WriterFree /\ ~s.duplicate
 /\ o \in Inputs \cap Stored(s.db)
 /\ s'=[s EXCEPT !.duplicate=TRUE,
   !.db.effects[o]=IF Policy="duplicateEffect" /\ o \in s.db.accepted THEN @+1 ELSE @]

Select(o) == /\ s.mode="running" /\ s.phase="idle" /\ o \in s.db.ready
 /\ s'=[s EXCEPT !.phase="inspect", !.item=o]
AlreadyAccepted == /\ s.mode="running" /\ s.phase="inspect" /\ s.item \in s.db.accepted
 /\ s'=[s EXCEPT !.db.ready=@ \ {s.item}, !.phase="idle", !.item=0]
Park == /\ s.mode="running" /\ s.phase="inspect" /\ Good(s.item)
 /\ s.item \notin s.db.accepted /\ Missing(s.db,s.item)#{} /\ Policy#"acceptBlocked"
 /\ IF Policy="splitPark"
       THEN s'=[s EXCEPT !.missing=Missing(s.db,s.item), !.phase="parkGap"]
       ELSE s'=[s EXCEPT !.db.waits[s.item]=Missing(s.db,s.item),
          !.db.ready=@ \ {s.item}, !.parked=@ \cup {s.item}, !.phase="idle", !.item=0]
FinishSplitPark == /\ s.mode="running" /\ s.phase="parkGap"
 /\ s'=[s EXCEPT !.db.waits[s.item]=s.missing, !.db.ready=@ \ {s.item},
    !.parked=@ \cup {s.item}, !.phase="idle", !.item=0, !.missing={}]
Validate == /\ s.mode="running" /\ s.phase="inspect" /\ Good(s.item)
 /\ s.item \notin s.db.accepted
 /\ (Missing(s.db,s.item)={} \/ Policy="acceptBlocked")
 /\ s'=[s EXCEPT !.phase="validate"]

\* The production accepted_object_ready trigger wakes on ANY accepted parent;
\* inspection then recomputes ALL missing prerequisites in one transaction.
AcceptInto(d,o) == [d EXCEPT !.accepted=@ \cup {o}, !.effects[o]=@+1,
 !.ready=(@ \ {o}) \cup IF Policy="lostWake" THEN {} ELSE
     {c \in Inputs \ d.accepted: o \in d.waits[c]},
 !.waits[o]={}]
Accept == /\ s.mode="running" /\ s.phase="validate"
 /\ s.item \notin s.db.accepted
 /\ s'=[s EXCEPT !.db=AcceptInto(@,s.item), !.phase="finish"]
\* An independently admitted local parent uses the same serial acceptance writer.
AcceptParent(o) == /\ s.mode="running" /\ WriterFree /\ o \in {1,2} \cap Inputs
 /\ o \in Stored(s.db) \ s.db.accepted /\ Good(o) /\ o#s.item
 /\ s'=[s EXCEPT !.db=AcceptInto(@,o)]

BeginReject == /\ s.mode="running" /\ s.phase="inspect" /\ ~Good(s.item)
 /\ s'=[s EXCEPT !.work=s.db, !.phase="reason", !.rejectionAttempted=TRUE]
WriteReason == /\ s.mode="running" /\ s.phase="reason"
 /\ s'=[s EXCEPT !.work.rejected[s.item]=RootKind, !.phase="cleanup",
    !.db.rejected[s.item]=IF Policy="splitReject" THEN RootKind ELSE @]
CleanRejected == /\ s.mode="running" /\ s.phase="cleanup"
 /\ LET victims == IF Policy="propagate" THEN {s.item} \cup ({3,4} \cap Stored(s.work))
                    ELSE {s.item}
    IN s'=[s EXCEPT !.work.ready=@ \ victims,
       !.work.waits=[o \in Objects |-> IF o \in victims THEN {} ELSE s.work.waits[o]],
       !.work.rejected=[o \in Objects |-> IF o \in victims THEN RootKind ELSE s.work.rejected[o]],
       !.work.bytes[s.item]=IF Policy="eraseBytes" THEN 0 ELSE @, !.phase="commit"]
CommitReject == /\ s.mode="running" /\ s.phase="commit"
 /\ s'=[s EXCEPT !.db=IF Policy="rejectAltersHistory"
      THEN [s.work EXCEPT !.accepted=@ \ {0}, !.effects[0]=0] ELSE s.work,
      !.work=InitialDB, !.phase="finish"]
Finish == /\ s.mode="running" /\ s.phase="finish"
 /\ s'=[s EXCEPT !.phase="idle", !.item=0]

\* A failed write rolls back; failure after commit preserves the committed DB.
\* An error ends the owned attempt. Retry/reopen below is an explicit request.
StorageFailure == /\ s.mode="running" /\ s.phase#"idle" /\ s.failures<MaxFailures
 /\ s'=[s EXCEPT !.mode="stopped", !.phase="idle", !.item=0,
    !.work=InitialDB, !.missing={}, !.failures=@+1,
    !.rejectFailures=IF s.item=1 /\ s.phase \in {"reason","cleanup","commit","finish"} /\ RootKind#"valid" THEN @+1 ELSE @,
    !.lostRejectCompletion=@ \/ (s.item=1 /\ s.phase="finish" /\ RootKind#"valid"),
    !.db.rejected[s.item]=IF Policy="ioIsRejection" /\ s.item \notin s.db.accepted THEN "storage" ELSE @]
Crash == /\ s.mode#"down" /\ s.crashes<MaxCrashes
 /\ s'=[s EXCEPT !.mode="down", !.phase="idle", !.item=0,
    !.work=InitialDB, !.missing={}, !.crashes=@+1,
    !.rejectCrashCuts=IF s.item=1 /\ RootKind#"valid" /\ s.phase \in {"reason","cleanup","commit","finish"}
       THEN @ \cup {IF s.phase="finish" THEN "committed" ELSE "uncommitted"} ELSE @,
    !.db.ready=IF Policy="dropReady" THEN {} ELSE @]
Retry == /\ s.mode="stopped" /\ s'=[s EXCEPT !.mode="running"]
Reopen == /\ s.mode="down" /\ s'=[s EXCEPT !.mode="running"]

Process == (\E o \in Inputs: Select(o)) \/ AlreadyAccepted \/ Park \/ FinishSplitPark
 \/ Validate \/ Accept \/ BeginReject \/ WriteReason \/ CleanRejected \/ CommitReject \/ Finish
Next == Process \/ StorageFailure \/ Crash \/ Retry \/ Reopen
 \/ (\E o \in Inputs: Deliver(o) \/ Duplicate(o) \/ AcceptParent(o))
Spec == Init /\ [][Next]_vars
\* Finite faults and inputs plus fair execution of runnable processing suffice.
\* Retry/Reopen fairness explicitly assumes a caller requests recovery; delivery
\* of absent prerequisites and any future validator upgrade remain optional.
FairSpec == Spec /\ WF_vars(Process) /\ WF_vars(Retry) /\ WF_vars(Reopen)

DBType(d) == /\ d.bytes \in [Objects -> 0..6] /\ d.accepted \subseteq Objects
 /\ d.ready \subseteq Objects /\ d.waits \in [Objects -> SUBSET Objects]
 /\ d.effects \in [Objects -> 0..2]
 /\ d.rejected \in [Objects -> {"none","invalid","unsupported","storage"}]
TypeOK == /\ DBType(s.db) /\ DBType(s.work)
 /\ s.mode \in {"running","stopped","down"}
 /\ s.phase \in {"idle","inspect","validate","parkGap","reason","cleanup","commit","finish"}
 /\ s.item \in Objects /\ s.missing \subseteq Objects
 /\ s.crashes \in 0..MaxCrashes /\ s.failures \in 0..MaxFailures
 /\ s.delivered \subseteq Inputs /\ s.parked \subseteq Inputs
 /\ s.duplicate \in BOOLEAN /\ s.rejectionAttempted \in BOOLEAN
 /\ s.rejectFailures \in 0..MaxFailures /\ s.rejectCrashCuts \subseteq {"committed","uncommitted"}
 /\ s.lostRejectCompletion \in BOOLEAN
ExactInputRetained == \A o \in s.delivered \cup {0}: s.db.bytes[o]=Original(o)
QueueAccounted == \A o \in Stored(s.db) \ (s.db.accepted \cup Rejected(s.db)):
 o \in s.db.ready \/ s.db.waits[o]#{}
EligibleHasReady == \A o \in Stored(s.db) \ (s.db.accepted \cup Rejected(s.db)):
 Missing(s.db,o)={} => o \in s.db.ready
RejectedSettled == \A o \in Rejected(s.db):
 o \notin s.db.ready /\ s.db.waits[o]={} /\ o \notin s.db.accepted
OwnRejectionOnly == \A o \in Rejected(s.db): o=1 /\ RootKind#"valid" /\ s.db.rejected[o]=RootKind
AcceptedClosure == \A o \in s.db.accepted: Good(o) /\ Parents(o) \subseteq s.db.accepted
AcceptanceHasBytes == s.db.accepted \subseteq Stored(s.db)
EffectsExactlyOnce == \A o \in Objects: s.db.effects[o]=IF o \in s.db.accepted THEN 1 ELSE 0
WaitEdgesJustified == \A o \in Objects: s.db.waits[o] \subseteq Parents(o)
HistoryPreserved == [][s.db.accepted \subseteq s'.db.accepted /\ 0 \in s'.db.accepted]_vars
RejectionPreservesHistory == [][s.phase \in {"reason","cleanup","commit"} =>
 s'.db.accepted=s.db.accepted /\ s'.db.effects=s.db.effects]_vars
\* Reachability over stored waiting edges is compared with the independent fixed
\* graph below. Completion is required only after all runnable queue work settles.
RECURSIVE Reach(_,_,_)
Reach(w,seen,n) == IF n=0 THEN seen ELSE
 Reach(w,seen \cup UNION {w[o]: o \in seen},n-1)
Blockers(o) == Rejected(s.db) \cap
 (IF Policy="directOnly" THEN s.db.waits[o] ELSE Reach(s.db.waits,{o},5))
\* A missing intermediate object conceals its own dependency list. Its
\* descendant can name the rejected root once that intermediate is retained.
ExpectedBlockers(o) == IF RootKind#"valid" /\ 1 \in Rejected(s.db)
 /\ (o=3 \/ (o=4 /\ 3 \in Stored(s.db)))
 THEN {1} ELSE {}
SettledDiagnostics == s.phase="idle" /\ s.db.ready={} =>
 \A o \in Stored(s.db) \ Rejected(s.db): Blockers(o)=ExpectedBlockers(o)
DiagnosticSound == \A o \in Inputs \ Rejected(s.db): Blockers(o) \subseteq ExpectedBlockers(o)
DependenciesStored(o) == CASE o=4 -> {1,3,4} \subseteq Stored(s.db)
 [] o=3 -> ({3} \cup Parents(3)) \subseteq Stored(s.db)
 [] OTHER -> o \in Stored(s.db)
SupportedClosure(o) == Good(o) /\ (o \in {3,4} => RootKind="valid")
EligibleEventuallyAccepted == \A o \in Inputs:
 (SupportedClosure(o) /\ DependenciesStored(o)) ~> (o \in s.db.accepted)
BadEventuallyRejected == RootKind#"valid" => (1 \in Stored(s.db) ~> 1 \in Rejected(s.db))
NeverBlockedChainAndIndependent == ~(Topology="chain" /\ s.db.ready={} /\ s.phase="idle"
 /\ {1,3,4,5} \subseteq Stored(s.db) /\ Blockers(4)={1} /\ 5 \in s.db.accepted)
NeverPartialWake == ~(Topology="multiple" /\ 3 \in s.parked /\ s.db.waits[3]={2} /\ 1 \in s.db.accepted)
NeverRecoveredRejection == ~(s.rejectCrashCuts#{} /\ s.rejectFailures>0 /\ 1 \in Rejected(s.db) /\ 5 \in s.db.accepted)
NeverRecoveredValidChain == ~(RootKind="valid" /\ s.crashes>0 /\ Inputs \subseteq s.db.accepted)
NeverFailedTwiceAndSettled == ~(s.rejectFailures=2 /\ 1 \in Rejected(s.db) /\ 5 \in s.db.accepted)
NeverBothRejectionCrashCuts == ~(s.rejectCrashCuts={"committed","uncommitted"} /\ 5 \in s.db.accepted)
NeverLostRejectionCompletion == ~(s.lostRejectCompletion /\ 1 \in Rejected(s.db) /\ 5 \in s.db.accepted)
=============================================================================
