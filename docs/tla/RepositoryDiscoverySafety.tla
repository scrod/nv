---------------------- MODULE RepositoryDiscoverySafety ----------------------
EXTENDS Naturals, FiniteSets, Sequences

\* RepositoryDiscovery.swift: a bounded DFS pass snapshots disclosed names,
\* preserves its parent stream, reads a candidate, and hands exact bytes to the
\* existing durable receive queue. Later ordinary opportunities start new passes.
\* One writer has a high child and a low parent; the other has independent work
\* and a provider-renamed copy of the child's exact envelope.
\* Envelope checks and durable acceptance are environmental predicates qualified
\* by executable tests and the accepted-history models. This model concentrates
\* on the connection: missed hints, nested progress, retry and stale turn results.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "onlyHint", "highWater", "loseParent", "skipRenamed",
                   "loseRetained", "staleTurn", "duplicateEffects", "skipParents"}
 /\ Scenario \in {"late", "renamed"}
Objects == {"P", "C", "Q"}
Names == {"parent", "child", "alias", "independent"}
Identity(n) == CASE n="parent" -> "P" [] n="independent" -> "Q" [] OTHER -> "C"
SequenceOf(n) == IF Identity(n)="C" THEN 2 ELSE 1
WriterOf(n) == IF Identity(n)="Q" THEN "B" ELSE "A"
Directory(n) == IF n \in {"parent", "child"} THEN "A" ELSE "B"
VARIABLE s
vars == <<s>>
Visible == CASE s.stage=0 -> {}
 [] s.stage=1 -> IF Scenario="late" THEN {"child"} ELSE {"alias"}
 [] OTHER -> IF Scenario="late" THEN Names ELSE Names \ {"child"}
DisclosedDirectories == {Directory(n): n \in Visible}
Writers == (IF "B" \in DisclosedDirectories THEN <<"B">> ELSE <<>>)
        \o (IF "A" \in DisclosedDirectories THEN <<"A">> ELSE <<>>)
Leaves(w) == SelectSeq(IF w="A" THEN <<"child", "parent">> ELSE <<"independent", "alias">>,
                       LAMBDA n: n \in Visible)

Init == s=[stage |-> 0, phase |-> "idle", writers |-> <<>>, leaves |-> <<>>,
 pending |-> "none", hint |-> TRUE, highWater |-> [w \in {"A", "B"} |-> 0], root |-> 0, captured |-> 0,
 retained |-> {}, handed |-> {}, accepted |-> {}, effects |-> [o \in Objects |-> 0],
 value |-> "base", other |-> FALSE, issued |-> FALSE, issuedRoot |-> 0,
 crashed |-> FALSE, generationChanged |-> FALSE, readFailed |-> FALSE,
 emptyFinished |-> FALSE, waited |-> FALSE, staleFinished |-> FALSE]

Disclose == /\ s.stage<2 /\ s'=[s EXCEPT !.stage=@+1]
\* An ordinary opportunity runs even after the sole presenter hint was consumed.
Start == /\ s.phase="idle" /\ (s.hint \/ Policy#"onlyHint")
 /\ s'=[s EXCEPT !.phase="writers", !.writers=Writers, !.hint=FALSE]
EnterWriter == /\ s.phase="writers" /\ s.writers#<<>>
 /\ s'=[s EXCEPT !.leaves=Leaves(Head(s.writers)), !.phase="leaves",
   !.writers=IF Policy="loseParent" THEN <<>> ELSE Tail(s.writers)]
EndWriter == /\ s.phase="leaves" /\ s.leaves = <<>>
 /\ s'=[s EXCEPT !.phase="writers"]
EndPass == /\ s.phase="writers" /\ s.writers = <<>>
 /\ s'=[s EXCEPT !.phase="idle", !.emptyFinished=@ \/ s.stage=0]
Read == /\ s.phase="leaves" /\ s.leaves#<<>>
 /\ LET n == Head(s.leaves) IN
    s'=[s EXCEPT !.pending=n, !.leaves=Tail(s.leaves), !.captured=s.root,
     !.phase=IF (Policy="highWater" /\ SequenceOf(n)<=s.highWater[WriterOf(n)])
                \/ (Policy="skipRenamed" /\ n="alias") THEN "leaves" ELSE "read",
     !.highWater[WriterOf(n)]=IF SequenceOf(n)>@ THEN SequenceOf(n) ELSE @]
FailRead == /\ s.phase="read" /\ ~s.readFailed
 /\ s'=[s EXCEPT !.readFailed=TRUE, !.phase="leaves"]
\* The queue owns admitted bytes before any turn completion reaches the caller.
Retain == /\ s.phase="read" /\ s.captured=s.root
 /\ s'=[s EXCEPT !.retained=@ \cup {Identity(s.pending)}, !.handed=@ \cup {s.pending},
   !.phase="finish", !.waited=@ \/ (Identity(s.pending)="C" /\ "P" \notin s.accepted)]
AbortStaleRead == /\ s.phase="read" /\ s.captured#s.root
 /\ s'=[s EXCEPT !.phase="idle", !.writers = <<>>, !.leaves = <<>>]
Finish == /\ s.phase="finish"
 /\ s'=[s EXCEPT !.phase=IF s.captured=s.root THEN "leaves" ELSE "idle",
   !.issued=(s.captured=s.root) \/ Policy="staleTurn", !.issuedRoot=s.captured,
   !.staleFinished=@ \/ s.captured#s.root]
\* A confirmed same-root revalidation rotates admission while a handoff is held.
ChangeGeneration == /\ ~s.generationChanged
 /\ s'=[s EXCEPT !.generationChanged=TRUE, !.root=@+1, !.issued=FALSE]
\* Restart discards cursors and callbacks, preserving admitted input and membership.
Crash == /\ ~s.crashed
 /\ s'=[s EXCEPT !.crashed=TRUE, !.root=@+1, !.phase="idle", !.writers = <<>>,
   !.leaves = <<>>, !.issued=FALSE, !.retained=IF Policy="loseRetained" THEN {} ELSE @]
Accept(o) == /\ o \in s.retained
 /\ (o \notin s.accepted \/ (Policy="duplicateEffects" /\ s.effects[o]<2))
 /\ (o#"C" \/ "P" \in s.accepted \/ Policy="skipParents")
 /\ s'=[s EXCEPT !.accepted=@ \cup {o}, !.effects[o]=@+1,
   !.value=IF o="C" THEN "child" ELSE IF o="P" THEN "parent" ELSE @,
   !.other=@ \/ o="Q"]
ScanStep == Start \/ EnterWriter \/ EndWriter \/ EndPass \/ Read \/ Retain \/ Finish \/ AbortStaleRead
Next == Disclose \/ ScanStep \/ FailRead \/ ChangeGeneration \/ Crash
        \/ (\E o \in Objects: Accept(o))
Spec == Init /\ [][Next]_vars
\* Fair local processing and recurring ordinary opportunities are caller obligations.
\* Provider disclosure remains unpromised; progress is conditional on stage 2.
FairSpec == Spec /\ WF_vars(ScanStep) /\ (\A o \in Objects: WF_vars(Accept(o)))

TypeOK == /\ s.stage \in 0..2 /\ s.root \in 0..2 /\ s.captured \in 0..2
 /\ s.phase \in {"idle", "writers", "leaves", "read", "finish"}
 /\ s.writers \in {<<>>, <<"A">>, <<"B">>, <<"B", "A">>}
 /\ s.leaves \in Seq(Names) /\ Len(s.leaves)<=2 /\ s.pending \in Names \cup {"none"}
 /\ s.retained \subseteq Objects /\ s.accepted \subseteq Objects /\ s.handed \subseteq Names
 /\ s.effects \in [Objects -> 0..2] /\ s.value \in {"base", "parent", "child"}
 /\ s.highWater \in [{"A", "B"} -> 0..2] /\ s.issuedRoot \in 0..2
 /\ \A f \in {"hint", "other", "issued", "crashed", "generationChanged", "readFailed",
               "emptyFinished", "waited", "staleFinished"}: s[f] \in BOOLEAN
RetainedExact == s.retained = {Identity(n): n \in s.handed}
DependencyClosed == s.accepted \subseteq s.retained /\ ("C" \in s.accepted => "P" \in s.accepted)
LogicalOnce == \A o \in Objects: s.effects[o]=IF o \in s.accepted THEN 1 ELSE 0
ValuesExact == s.value=(IF "C" \in s.accepted THEN "child" ELSE IF "P" \in s.accepted THEN "parent" ELSE "base")
               /\ s.other=("Q" \in s.accepted)
TurnApplicable == s.issued => s.issuedRoot=s.root
AcceptedPreserved == [][s.accepted \subseteq s'.accepted]_vars
DisclosedEventuallyAccepted == (s.stage=2) ~> (s.accepted=Objects)
NeverEmptyThenProgress == ~(s.emptyFinished /\ s.stage=2 /\ s.accepted=Objects)
NeverRestartedThenProgress == ~(s.crashed /\ s.accepted=Objects)
NeverWaitedThenProgress == ~(s.waited /\ s.accepted=Objects)
NeverStaleFinish == ~s.staleFinished
NeverReadFailureThenProgress == ~(s.readFailed /\ s.accepted=Objects)
=============================================================================
