-------------------- MODULE ExternalAssociationSafety --------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","staleAdmission","doubleClaim","earlyReceipt",
 "staleReceipt","echoPut","consumeAllHeads","skipProjection","loseLocalField","dropUnrelatedHead"}
 /\ Scenario \in {"equal","useCurrent","useFile","merge","competing"}
VARIABLE s
vars == <<s>>
\* One live birth, two independently prepared file choices, an unrelated head
\* and a committed Delete. Exact two-field values make the merge observable.
\* Admission, operation sealing, retained-pin barrier, physical installation
\* and receipt are distinct. Storage/crash details are checked separately in
\* ExternalFileLifecycleSafety and PendingReferenceSafety, not formally composed.
\* admissions/receipts are append-only audit evidence, not private wire records.
\* Source input after its one modeled change is not re-prepared in this bound.
\* Delete invalidates association authority; this model preserves operations,
\* not the full causal reducer's delete/edit conflict presentation.
InitialValue == IF Scenario="merge" THEN <<1,2>> ELSE <<1,1>>
Source(i) == IF Scenario="equal" THEN InitialValue ELSE <<i+1,1>>
Result(i) == CASE Scenario \in {"equal","useCurrent"} -> InitialValue
 [] Scenario="merge" /\ Policy # "loseLocalField" -> <<Source(i)[1],InitialValue[2]>>
 [] OTHER -> Source(i)
\* Independent fixture oracle, not a second call to the producer.
Expected(i) == CASE Scenario \in {"equal","useCurrent"} -> <<1,1>>
 [] Scenario="merge" -> <<i+1,2>> [] OTHER -> <<i+1,1>>
NeedsPut == Scenario \notin {"equal","useCurrent"}
Empty == [phase |-> "idle", generation |-> 0, revision |-> 0, root |-> 0,
          admittedGeneration |-> 0, parents |-> {}, value |-> <<0,0>>]
Init == s=[live |-> TRUE, generation |-> 0, root |-> 0, claim |-> 0,
 heads |-> {0}, history |-> {0}, pinned |-> {0}, extra |-> FALSE,
 files |-> [i \in 1..2 |-> [revision |-> 0, body |-> Source(i)]],
 choices |-> [i \in 1..2 |-> Empty], admissions |-> {}, receipts |-> {}]
Available == IF Scenario="competing" THEN 1..2 ELSE {1}
Prepare(i) == /\ i \in Available /\ s.choices[i].phase="idle" /\ s.live /\ s.claim=0
 /\ s.files[i].body=Source(i)
 /\ s'=[s EXCEPT !.choices[i]=[phase |-> "prepared", generation |-> s.generation,
     revision |-> s.files[i].revision, root |-> s.root, admittedGeneration |-> 0,
     parents |-> {0}, value |-> Result(i)]]
Fresh(i) == s.live /\ s.choices[i].generation=s.generation
 /\ s.choices[i].revision=s.files[i].revision /\ s.choices[i].root=s.root
Admission(i) == [choice |-> i, fresh |-> Fresh(i), previousClaim |-> s.claim,
 extra |-> 3 \in s.heads, consumed |-> IF Policy="consumeAllHeads" THEN s.heads ELSE s.choices[i].parents]
Admit(i) == /\ s.choices[i].phase="prepared"
 /\ (Fresh(i) \/ Policy="staleAdmission" \/ Policy="doubleClaim")
 /\ (s.claim=0 \/ Policy="doubleClaim")
 /\ s'=[s EXCEPT !.claim=i, !.generation=@+1,
     !.heads=IF NeedsPut \/ Policy="echoPut"
       THEN ((@ \ (IF Policy="consumeAllHeads" THEN @ ELSE s.choices[i].parents))
               \ (IF Policy="dropUnrelatedHead" THEN {3} ELSE {})) \cup {i} ELSE @,
     !.choices[i].phase="admitted", !.choices[i].admittedGeneration=s.generation+1,
     !.admissions=@ \cup {Admission(i)}]
Seal(i) == /\ s.choices[i].phase="admitted"
 /\ s'=[s EXCEPT !.history=IF NeedsPut \/ Policy="echoPut" THEN @ \cup {i} ELSE @,
                 !.choices[i].phase="sealed"]
Pin(i) == /\ s.choices[i].phase="sealed"
 /\ s'=[s EXCEPT !.pinned=IF NeedsPut \/ Policy="echoPut" THEN @ \cup {i} ELSE @,
                 !.choices[i].phase="durable"]
ScopeCurrent(i) == s.live /\ s.claim=i /\ s.generation=s.choices[i].admittedGeneration
 /\ s.root=s.choices[i].root /\ s.files[i].revision=s.choices[i].revision
InstallProjection(i) == /\ s.choices[i].phase="durable" /\ ScopeCurrent(i)
 /\ s'=[s EXCEPT !.files[i].body=s.choices[i].value, !.choices[i].phase="projected"]
Receipt(i) == [choice |-> i, current |-> ScopeCurrent(i), body |-> s.files[i].body,
 durable |-> (IF NeedsPut THEN i ELSE 0) \in s.pinned,
 represented |-> (IF NeedsPut THEN i ELSE 0) \in s.history]
Settle(i) == /\ (s.choices[i].phase="projected"
                  \/ (Policy="earlyReceipt" /\ s.choices[i].phase="admitted")
                  \/ (Policy="skipProjection" /\ s.choices[i].phase="durable"))
 /\ (ScopeCurrent(i) \/ Policy="staleReceipt")
 /\ s'=[s EXCEPT !.receipts=@ \cup {Receipt(i)}, !.choices[i].phase="done"]
ChangeFile(i) == /\ s.files[i].revision=0
 /\ s'=[s EXCEPT !.files[i]=[revision |-> 1, body |-> <<9,9>>]]
ChangeRoot == /\ s.root=0 /\ s'=[s EXCEPT !.root=1]
ConcurrentHead == /\ ~s.extra /\ s.live
 /\ s'=[s EXCEPT !.extra=TRUE, !.heads=@ \cup {3}, !.history=@ \cup {3},
                 !.pinned=@ \cup {3}, !.generation=@+1]
LogicalDelete == /\ s.live
 /\ s'=[s EXCEPT !.live=FALSE, !.claim=0, !.generation=@+1,
                 !.history=@ \cup {4}, !.pinned=@ \cup {4}]
Next == ChangeRoot \/ ConcurrentHead \/ LogicalDelete \/
 (\E i \in Available: Prepare(i) \/ Admit(i) \/ Seal(i) \/ Pin(i)
                        \/ InstallProjection(i) \/ Settle(i) \/ ChangeFile(i))
Spec == Init /\ [][Next]_vars
Value == (1..9) \X (1..9)
TypeOK == /\ s.live \in BOOLEAN /\ s.extra \in BOOLEAN /\ s.generation \in 0..4
 /\ s.root \in 0..1 /\ s.claim \in 0..2 /\ s.heads \subseteq 0..3
 /\ s.history \subseteq 0..4 /\ s.pinned \subseteq s.history
 /\ s.files \in [1..2 -> [revision:0..1,body:Value]]
 /\ s.choices \in [1..2 -> [phase:{"idle","prepared","admitted","sealed","durable","projected","done"},
       generation:0..4,revision:0..1,root:0..1,admittedGeneration:0..4,parents:SUBSET (0..3),value:(0..9) \X (0..9)]]
 /\ s.admissions \subseteq [choice:1..2,fresh:BOOLEAN,previousClaim:0..2,extra:BOOLEAN,consumed:SUBSET (0..3)]
 /\ s.receipts \subseteq [choice:1..2,current:BOOLEAN,body:Value,durable:BOOLEAN,represented:BOOLEAN]
FreshAdmission == \A a \in s.admissions: a.fresh
OneRelationshipClaim == \A a \in s.admissions: a.previousClaim=0
NoImplicitHeadConsumption == \A a \in s.admissions: a.consumed \subseteq {0}
\* Check the actual result, not only the independently recorded intent.
UnrelatedHeadSurvives == s.extra => 3 \in s.heads
ExactDurableReceipt == \A r \in s.receipts:
 r.current /\ r.durable /\ r.represented /\ r.body=Expected(r.choice)
ExactOperationValue == \A i \in s.history \cap {1,2}: s.choices[i].value=Expected(i)
NoEchoOperation == ~NeedsPut => s.history \cap {1,2}={}
Safety == FreshAdmission /\ OneRelationshipClaim /\ NoImplicitHeadConsumption
 /\ ExactDurableReceipt /\ NoEchoOperation /\ ExactOperationValue /\ UnrelatedHeadSurvives
NeverCompletedEqualWithoutPut == ~(Scenario="equal" /\ s.receipts # {} /\ s.history \cap {1,2}={})
NeverInstalledChosenCurrent == ~(Scenario="useCurrent" /\ s.receipts # {} /\ s.files[1].body=InitialValue)
NeverMergedBothChanges == ~(Scenario="merge" /\ s.receipts # {} /\ s.files[1].body = <<2,2>>)
NeverPreservedUnrelatedHead == ~(s.receipts # {} /\ {1,3} \subseteq s.heads)
NeverRetainedAfterDelete == ~(~s.live /\ 1 \in s.pinned /\ s.receipts={})
NeverPreparedCompetingChoices == ~(s.choices[1].phase="prepared" /\ s.choices[2].phase="prepared")
=============================================================================
