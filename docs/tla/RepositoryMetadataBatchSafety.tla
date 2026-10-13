-------------------- MODULE RepositoryMetadataBatchSafety --------------------
EXTENDS Naturals, Sequences, FiniteSets

\* RepositoryDiscovery.swift / RepositoryRoot.swift: two disclosed raw names
\* share an EOF stream. Each durable handoff is independent; the unconsumed
\* tail survives a turn and obtains fresh attributes when selected next time.
\* A matching hint represents accepted bytes, while exact reads cover misses.
\* Executable native/SQL tests qualify those predicates and physical barriers.
CONSTANT Policy
ASSUME Policy \in {"safe", "dropTail", "staleResult", "loseRetained", "oldAttributes", "closeEOF"}
Names == {"A", "B"}
Objects == {<<"A",0>>, <<"B",0>>, <<"B",1>>}
VARIABLE s
vars == <<s>>
Init == s = [phase |-> "idle", names |-> <<>>, stream |-> FALSE,
    physical |-> 0, enumerated |-> 0, selected |-> 0, observed |-> 0,
    root |-> 0, store |-> 0, owner |-> <<0,0>>,
    retained |-> {}, handed |-> {}, accepted |-> {},
    effects |-> [o \in Objects |-> 0], handled |-> {},
    issued |-> FALSE, ended |-> FALSE, usedOldAttributes |-> FALSE,
    changed |-> FALSE, rootChanged |-> FALSE, storeChanged |-> FALSE,
    crashed |-> FALSE, failures |-> 0, partialFailure |-> FALSE]

TypeOK == /\ s.phase \in {"idle", "observe", "lookup", "read", "finish"}
    /\ s.names \in {<<>>, <<"A","B">>, <<"B">>}
    /\ s.physical \in 0..1 /\ s.enumerated \in 0..1 /\ s.selected \in 0..1 /\ s.observed \in 0..1
    /\ s.root \in 0..2 /\ s.store \in 0..2 /\ s.owner \in (0..2) \X (0..2)
    /\ s.retained \subseteq Objects /\ s.handed \subseteq Objects /\ s.accepted \subseteq Objects
    /\ s.effects \in [Objects -> 0..1] /\ s.handled \subseteq Names /\ s.failures \in 0..2
    /\ \A field \in {"stream", "issued", "ended", "usedOldAttributes", "changed", "rootChanged",
        "storeChanged", "crashed", "partialFailure"}: s[field] \in BOOLEAN

Object == <<Head(s.names), IF Head(s.names)="A" THEN 0 ELSE s.observed>>
OwnerMatches == s.owner = <<s.root,s.store>>
Start == /\ s.phase="idle"
    /\ s'=[s EXCEPT !.phase="observe", !.names = <<"A","B">>, !.stream=Policy#"closeEOF",
        !.enumerated=s.physical, !.handled={}, !.issued=FALSE, !.ended=FALSE]
Observe == /\ s.phase="observe" /\ s.names#<<>> /\ s.stream
    /\ LET actual == IF Head(s.names)="A" THEN 0 ELSE s.physical IN
        s'=[s EXCEPT !.selected=actual,
            !.observed=IF Policy="oldAttributes" /\ Head(s.names)="B" THEN s.enumerated ELSE actual,
            !.owner = <<s.root,s.store>>, !.phase="lookup"]
Lookup == /\ s.phase="lookup" /\ OwnerMatches
    /\ s'=[s EXCEPT !.phase=IF Object \in s.accepted THEN "finish" ELSE "read",
        !.handled=IF Object \in s.accepted THEN @ \union {Head(s.names)} ELSE @,
        !.usedOldAttributes=@ \/ (Object \in s.accepted /\ s.observed#s.selected)]
Retain == /\ s.phase="read" /\ OwnerMatches
    /\ s.observed=(IF Head(s.names)="A" THEN 0 ELSE s.physical)
    /\ s'=[s EXCEPT !.retained=@ \union {Object}, !.handed=@ \union {Object},
        !.handled=@ \union {Head(s.names)}, !.phase="finish"]
Reset == /\ ((s.phase \in {"lookup","read"} /\ ~OwnerMatches)
             \/ (s.phase="read" /\ s.observed#(IF Head(s.names)="A" THEN 0 ELSE s.physical)))
    /\ s'=[s EXCEPT !.phase="idle", !.names = <<>>, !.stream=FALSE, !.issued=FALSE]
Finish == /\ s.phase="finish"
    /\ LET tail == IF Policy="dropTail" THEN <<>> ELSE Tail(s.names) IN
        s'=[s EXCEPT !.issued=OwnerMatches \/ Policy="staleResult",
            !.ended=OwnerMatches /\ tail = <<>>,
            !.phase=IF ~OwnerMatches \/ tail = <<>> THEN "idle" ELSE "observe",
            !.names=IF OwnerMatches THEN tail ELSE <<>>,
            !.stream=OwnerMatches /\ tail#<<>>]
Fail == /\ s.phase \in {"lookup","read","finish"} /\ s.failures<2
    /\ s'=[s EXCEPT !.failures=@+1, !.partialFailure=@ \/ <<"A",0>> \in s.retained,
        !.phase="idle", !.names = <<>>, !.stream=FALSE, !.issued=FALSE,
        !.retained=IF Policy="loseRetained" THEN {} ELSE @]
ChangeFile == /\ ~s.changed
    /\ s'=[s EXCEPT !.changed=TRUE, !.physical=1]
ChangeRoot == /\ ~s.rootChanged
    /\ s'=[s EXCEPT !.rootChanged=TRUE, !.root=@+1, !.issued=FALSE]
ChangeStore == /\ ~s.storeChanged
    /\ s'=[s EXCEPT !.storeChanged=TRUE, !.store=@+1, !.issued=FALSE]
Crash == /\ ~s.crashed
    /\ s'=[s EXCEPT !.crashed=TRUE, !.root=@+1, !.store=@+1,
        !.phase="idle", !.names = <<>>, !.stream=FALSE, !.issued=FALSE]
Accept(o) == /\ o \in s.retained \ s.accepted
    /\ (o[1]="A" \/ <<"A",0>> \in s.accepted)
    /\ s'=[s EXCEPT !.accepted=@ \union {o}, !.effects[o]=1]
Scan == Start \/ Observe \/ Lookup \/ Retain \/ Reset \/ Finish
Next == Scan \/ Fail \/ ChangeFile \/ ChangeRoot \/ ChangeStore \/ Crash
        \/ (\E o \in Objects: Accept(o))
Spec == Init /\ [][Next]_vars
\* Finite modeled interference and recurring ordinary caller opportunities.
FairSpec == Spec /\ WF_vars(Scan) /\ (\A o \in Objects: WF_vars(Accept(o)))
RetainedExact == s.retained=s.handed
AcceptedClosure == /\ s.accepted \subseteq s.retained
    /\ ((\E o \in s.accepted: o[1]="B") => <<"A",0>> \in s.accepted)
LogicalOnce == \A o \in Objects: s.effects[o]=IF o \in s.accepted THEN 1 ELSE 0
ApplicableResult == s.issued => OwnerMatches
CompleteTail == s.ended => s.handled=Names
TailStreamAlive == s.names#<<>> => s.stream
FreshSelectedObservation == ~s.usedOldAttributes
EventuallyLatest == <>[]({<<"A",0>>, <<"B",s.physical>>} \subseteq s.accepted)
AcceptedPreserved == [][s.accepted \subseteq s'.accepted]_vars
NeverPartialFailureThenProgress == ~(s.partialFailure /\ <<"B",s.physical>> \in s.accepted)
NeverRestartThenProgress == ~(s.crashed /\ <<"B",s.physical>> \in s.accepted)
NeverChangedTailThenProgress == ~(s.changed /\ <<"B",1>> \in s.accepted)
=============================================================================
