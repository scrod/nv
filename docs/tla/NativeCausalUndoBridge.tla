---------------------- MODULE NativeCausalUndoBridge ----------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","anyComplete","wholeSpan","redoOriginal","wrongInverse","automaticFork","noOpConsumes"}
 /\ Scenario \in {"linear","partialWins","completeWins"}
\* TC-ACT-03/04: one saved 0->2 group, native partial 2->1 on H1,
\* concurrent complete 2->0 on H2, then coarse U/R/S/T and one restart.
\* Source: CausalUndoV1.select, CompensationV1.remainingAfter/reverse and
\* LocalStoreSession.prepareCompensation. Scope ancestry, note predecessors
\* and inverse targets stay distinct. Atomic accepted records abstract the
\* already-separate SQLite closure/commit checks. Scalar values are exact
\* before/after fixtures; AppKit attribution, codec bytes and other scopes
\* remain separate obligations. Finite slots bound the test, not history.
Ids == {"A","P","C","U","R","S","T"}
Hosts == {1,2}
Empty == [parents |-> {},prev |-> {},target |-> "none",kind |-> "forward",
          before |-> 0,after |-> 0,complete |-> FALSE]
A == [Empty EXCEPT !.after=2]
P == [Empty EXCEPT !.parents={"A"},!.prev={"A"},!.target="A",!.kind="native",
                   !.before=2,!.after=1,!.complete=Policy="wholeSpan"]
C == [P EXCEPT !.after=0,!.complete=TRUE]
VARIABLE s
vars == <<s>>
Init == s=[records |-> [a \in Ids |-> CASE a="A"->A [] a="P"->P [] a="C"->C [] OTHER->Empty],
    durable |-> [h \in Hosts |-> {"A"}],known |-> [h \in Hosts |-> {"A"}],
    phase |-> "U",noEffect |-> FALSE,forcedConsumed |-> {},crashed |-> FALSE,down |-> FALSE]
RECURSIVE Reach(_,_,_)
Reach(nodes,edges,n) == IF n=0 THEN nodes ELSE Reach(nodes \cup UNION {edges[a]:a \in nodes},edges,n-1)
Anc(a) == Reach(s.records[a].parents,[b \in Ids |-> s.records[b].parents],7)
NoteAnc(a) == Reach(s.records[a].prev,[b \in Ids |-> s.records[b].prev],7)
Max(hist) == {a \in hist: ~\E b \in hist\{a}: a \in Anc(b)}
Heads(hist) == {a \in hist: ~\E b \in hist\{a}: a \in NoteAnc(b)}
Order == IF Scenario="completeWins" THEN <<"T","S","R","C","P","U","A">>
         ELSE <<"T","S","R","P","C","U","A">>
Selected(hs) == Order[CHOOSE i \in 1..7: Order[i] \in hs /\ \A j \in 1..(i-1): Order[j] \notin hs]
Scalar(b,l,r) == IF l=r THEN l ELSE IF l=b THEN r ELSE IF r=b THEN l ELSE 99
Bases(hs) == Heads({a \in Ids: \A h \in hs: a=h \/ a \in NoteAnc(h)})
Merged(hist) == LET hs==Heads(hist) bs==Bases(hs) IN
 IF Cardinality(hs)=2 /\ Cardinality(bs)=1
 THEN LET l==Selected(hs) r==CHOOSE a \in hs\{l}:TRUE b==CHOOSE a \in bs:TRUE
      IN Scalar(s.records[b].after,s.records[l].after,s.records[r].after)
 ELSE 99
Current(hist) == LET hs==Heads(hist) vs=={s.records[a].after:a \in hs} IN
 IF Cardinality(vs)=1 THEN CHOOSE v \in vs:TRUE
 ELSE IF Merged(hist)#99 THEN Merged(hist) ELSE s.records[Selected(hs)].after
Inputs(hist) == LET hs==Heads(hist) IN IF Cardinality({s.records[a].after:a \in hs})=1 \/ Merged(hist)#99
 THEN hs ELSE {Selected(hs)}
Natives(hist) == {a \in hist:s.records[a].kind="native"}
Consumed(hist) == {s.records[a].target:a \in {b \in hist:s.records[b].kind \in {"undo","redo"}}}
 \cup (IF (IF Policy="anyComplete" THEN \E a \in Natives(hist):s.records[a].complete
           ELSE Natives(hist)#{} /\ \A a \in Max(Natives(hist)):s.records[a].complete)
       THEN {"A"} ELSE {}) \cup s.forcedConsumed
Leaves(hist) == hist\Consumed(hist)
Forward(hist) == {a \in Leaves(hist):s.records[a].kind \in {"forward","redo"}}
Candidates(hist,d) == Max(IF d="undo" THEN Forward(hist) ELSE
 {a \in Leaves(hist):s.records[a].kind \in {"undo","native"}})
\* All nodes in this focused fixture belong to A's compensation family.
\* One ordered native continuation is safe; incomparable native statements
\* or whole commands retain their competing-family review requirement.
Linear(hist) == Cardinality(Max(Natives(hist)))=1
 /\ \A n \in Max(Natives(hist)),a \in hist:
     s.records[a].kind \in {"undo","redo"} => a \in Anc(n) \/ n \in Anc(a)
Mode(hist,d) == LET cs==Candidates(hist,d) IN
 IF cs={} THEN "none" ELSE IF Cardinality(cs)>1 THEN "review" ELSE
 IF Policy="automaticFork" THEN "automatic" ELSE
 IF \E a \in cs: \E b \in Leaves(hist)\{a}:
      ~(Linear(hist) /\ (a \in Anc(b) \/ b \in Anc(a)))
 THEN "review" ELSE "automatic"
Remaining(hist) == LET ns==Max(Natives(hist)) states=={s.records[n].after:n \in ns}
                      inputs==Inputs(hist)
                      lineage==inputs \cup UNION {NoteAnc(i):i \in inputs}
                      represented==ns \cap lineage IN
 IF Cardinality(states)=1 THEN CHOOSE v \in states:TRUE
 ELSE IF Cardinality(represented)=1 THEN s.records[CHOOSE n \in represented:TRUE].after
 ELSE IF represented={} THEN 2 ELSE Current(hist)
AuthorNative(h,a) == /\ ~s.down /\ a \notin s.durable[h]
 /\ ((h=1 /\ a="P") \/ (h=2 /\ a="C" /\ Scenario#"linear"))
 /\ s'=[s EXCEPT !.durable[h]=@\cup{a},!.known[h]=@\cup{a}]
Joined == "P" \in s.known[1] /\ (Scenario="linear" \/ "C" \in s.known[1])
Target(a) == CASE a="U"->"A" [] a="R"->IF "U" \in s.known[1] THEN "U" ELSE "P"
             [] a="S"->"R" [] OTHER->"S"
Direction(a) == IF a \in {"R","T"} THEN "redo" ELSE "undo"
After(a) == IF a="U" THEN 0 ELSE IF Policy="redoOriginal" /\ a="R" THEN 2
 ELSE IF Policy="wrongInverse" /\ a="S" THEN s.records["A"].after
 ELSE s.records[Target(a)].before
Command == /\ ~s.down /\ Joined /\ s.phase \in {"U","R","S","T"}
 /\ LET a==s.phase hist==s.known[1] t==Target(a) before==Current(hist) after==After(a) IN
    /\ t \in Candidates(hist,Direction(a)) /\ before#after
    /\ s'=[s EXCEPT !.records[a]=[Empty EXCEPT !.parents=Max(hist),!.prev=Inputs(hist),
        !.target=t,!.kind=Direction(a),!.before=before,!.after=after],
        !.durable[1]=@\cup{a},!.known[1]=@\cup{a},
        !.phase=CASE a="U"->"R" [] a="R"->"S" [] a="S"->"T" [] OTHER->"done"]
NoEffect == /\ ~s.down /\ Joined /\ s.phase="U" /\ Current(s.known[1])=0
 /\ s'=[s EXCEPT !.noEffect=TRUE,!.phase="R",
       !.forcedConsumed=IF Policy="noOpConsumes" THEN {"A"} ELSE @]
Receive(h,a) == /\ ~s.down /\ a \in (s.durable[1]\cup s.durable[2])\s.durable[h]
 /\ s.records[a].parents \subseteq s.known[h]
 /\ s'=[s EXCEPT !.durable[h]=@\cup{a},!.known[h]=@\cup{a}]
Crash == /\ ~s.crashed /\ s'=[s EXCEPT !.crashed=TRUE,!.down=TRUE,!.known[1]={}]
Recover == /\ s.down /\ s'=[s EXCEPT !.down=FALSE,!.known[1]=s.durable[1]]
Progress == Recover \/ (\E h \in Hosts,a \in Ids:Receive(h,a))
Next == Command \/ NoEffect \/ Crash \/ Progress \/ (\E h \in Hosts,a \in {"P","C"}:AuthorNative(h,a))
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Progress)
TypeOK == /\ s.known \in [Hosts->SUBSET Ids] /\ s.durable \in [Hosts->SUBSET Ids]
 /\ s.phase \in {"U","R","S","T","done"} /\ s.forcedConsumed \subseteq {"A"}
 /\ s.records \in [Ids -> [parents:SUBSET Ids,prev:SUBSET Ids,target:Ids\cup{"none"},
         kind:{"forward","native","undo","redo"},before:0..2,after:0..2,complete:BOOLEAN]]
 /\ s.down \in BOOLEAN /\ s.crashed \in BOOLEAN /\ s.noEffect \in BOOLEAN
AcceptedClosure == \A h \in Hosts: \A a \in s.durable[h]:s.records[a].parents \subseteq s.durable[h]
PartialStillAvailable == ~s.down /\ Joined /\ s.phase="U" => "A" \in Candidates(s.known[1],"undo")
ForkNeedsReview == Scenario#"linear" /\ ~s.down /\ Joined /\ s.phase="U"
 => Mode(s.known[1],"undo")="review"
ExactRemaining == ~s.down /\ Joined /\ s.phase="U" => Remaining(s.known[1])=Current(s.known[1])
ActualRedo == "R" \in s.durable[1] => s.records["R"].after=s.records[s.records["R"].target].before
ActualInverse == "S" \in s.durable[1] => s.records["S"].after=s.records["R"].before
NoOpKeepsIdentity == s.noEffect => "U" \notin s.durable[1] /\ "A" \notin s.forcedConsumed
Safety == AcceptedClosure /\ PartialStillAvailable /\ ForkNeedsReview /\ ExactRemaining
 /\ ActualRedo /\ ActualInverse /\ NoOpKeepsIdentity
EventualAgreement == <>[](~s.down /\ s.known[1]=s.known[2])
NeverPartialChain == ~(s.phase="done" /\ "U" \in s.durable[1]
 /\ s.records["R"].after=1 /\ s.records["S"].after=0 /\ s.records["T"].after=1)
NeverForkNoOpRecovered == ~(Scenario="completeWins" /\ s.noEffect /\ s.crashed /\ ~s.down
 /\ {"A","P","C","R","S","T"} \subseteq s.known[1]\cap s.known[2])
=============================================================================
