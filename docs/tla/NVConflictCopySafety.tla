------------------------ MODULE NVConflictCopySafety ------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "subtractSource", "implicitKeep", "coverAll",
                   "coverDescendant", "forgetDeleted", "earlyDisposition", "recreateDeleted"}
 /\ Scenario \in {"reciprocal", "descendant", "copyEdit", "copyDelete"}
\* Protocol: representation-only NV RecoverCopy, not Apple NSFileVersion.
\* Two validated incompatible source heads A/B; each host initially has a
\* temporary local-edit presentation pin. Settling that fence is explicit;
\* neither fixed ordering nor copies are allowed to create a permanent pin.
\* Exact source/copy identities and valid complete payloads are fixtures.
\* Capture, complete local install, callback, provider delivery and one crash
\* are separate. Install abstracts the full object/dependency/pin barrier;
\* this is not its filesystem proof. View describes durable copy results,
\* not the ordinary pending note shown immediately on creation. A later copy
\* edit/delete or source edit has one abstract complete local install.
\* No Apple calls, physical projection, reuse slots, arbitrary merge, or Undo.
Hosts == {1,2}
Copies == {"copyA", "copyB"}
Records == Copies \cup {"C", "modified", "deleted"}
Source(c) == IF c="copyA" THEN "A" ELSE "B"
Own(h) == IF h=1 THEN "A" ELSE "B"
Request(h) == IF h=1 THEN "copyB" ELSE "copyA"
Dependencies(r) == IF r \in {"C", "modified", "deleted"} THEN Copies ELSE {}
\* C explicitly replaces A, but not B; all bodies are incompatible scalars.
Heads(k) == IF "C" \in k THEN {"B","C"} ELSE {"A","B"}
CopyBodies(k) == [c \in Copies |->
 IF c="copyB" /\ "deleted" \in k /\ Policy # "recreateDeleted" THEN "absent"
 ELSE IF c="copyB" /\ "modified" \in k THEN "changed"
 ELSE IF c \in k THEN Source(c) ELSE "absent"]
Handled(k) ==
 LET cs == IF Policy="forgetDeleted" /\ "deleted" \in k
           THEN (k \cap Copies) \ {"copyB"} ELSE k \cap Copies
     exact == {Source(c): c \in cs}
 IN IF Policy="coverAll" /\ cs # {} THEN {"A","B","C"}
    ELSE exact \cup (IF Policy="coverDescendant" /\ "A" \in exact
                    THEN {"C"} ELSE {})
Select(hs) == IF "A" \in hs THEN "A" ELSE IF "B" \in hs THEN "B"
             ELSE IF "C" \in hs THEN "C" ELSE "absent"
Reduce(k,pin,h) ==
 LET heads == IF Policy="subtractSource" THEN Heads(k) \ Handled(k) ELSE Heads(k)
     current == IF Policy="implicitKeep" /\ Request(h) \in k THEN Own(h)
                ELSE IF pin /\ Own(h) \in heads THEN Own(h) ELSE Select(heads)
 IN [current |-> current, heads |-> heads, handled |-> Handled(k),
     unresolved |-> heads \ ({current} \cup Handled(k)), copies |-> CopyBodies(k)]
VARIABLE s
vars == <<s>>
Init == s = [known |-> [h \in Hosts |-> {}], durable |-> [h \in Hosts |-> {}],
 incoming |-> [h \in Hosts |-> {}], provider |-> {}, phase |-> [h \in Hosts |-> 0],
 pin |-> [h \in Hosts |-> TRUE], view |-> [h \in Hosts |-> Reduce({},TRUE,h)],
 down |-> FALSE, crashed |-> FALSE, recoveredFrom |-> {}]
Up(h) == h # 1 \/ ~s.down
Capture(h) ==
 /\ Up(h) /\ s.phase[h]=0 /\ Request(h) \notin s.known[h]
 /\ Source(Request(h)) \in s.view[h].unresolved
 /\ LET k == s.known[h] \cup (IF Policy="earlyDisposition" THEN {Request(h)} ELSE {})
    IN s' = [s EXCEPT !.phase[h]=1, !.known[h]=k, !.view[h]=Reduce(k,s.pin[h],h)]
Install(h) ==
 /\ Up(h) /\ s.phase[h]=1
 /\ LET k == s.known[h] \cup {Request(h)}
    IN s' = [s EXCEPT !.phase[h]=2, !.durable[h]=@ \cup {Request(h)},
                       !.known[h]=k, !.view[h]=Reduce(k,s.pin[h],h)]
Complete(h) == /\ Up(h) /\ s.phase[h]=2
 /\ s' = [s EXCEPT !.phase[h]=3]
SettlePin(h) == /\ Up(h) /\ s.pin[h]
 /\ s' = [s EXCEPT !.pin[h]=FALSE, !.view[h]=Reduce(s.known[h],FALSE,h)]
Publish(h,r) == /\ Up(h) /\ r \in s.durable[h] \ s.provider
 /\ s' = [s EXCEPT !.provider=@ \cup {r}]
Receive(h,r) == /\ Up(h) /\ r \in s.provider \ (s.known[h] \cup s.incoming[h])
 /\ s' = [s EXCEPT !.incoming[h]=@ \cup {r}]
Apply(h,r) ==
 /\ Up(h) /\ r \in s.incoming[h] /\ Dependencies(r) \subseteq s.known[h]
 /\ LET k == s.known[h] \cup {r}
    IN s' = [s EXCEPT !.known[h]=k, !.durable[h]=@ \cup {r},
               !.incoming[h]=@ \ {r}, !.view[h]=Reduce(k,s.pin[h],h)]
LaterChange ==
 /\ Up(1) /\ Scenario # "reciprocal" /\ Copies \subseteq s.known[1] /\ ~s.pin[1]
 /\ LET r == CASE Scenario="descendant" -> "C"
                  [] Scenario="copyEdit" -> "modified"
                  [] OTHER -> "deleted"
        k == s.known[1] \cup {r}
    IN /\ r \notin s.known[1]
       /\ s' = [s EXCEPT !.known[1]=k, !.durable[1]=@ \cup {r},
                          !.view[1]=Reduce(k,FALSE,1)]
Crash == /\ ~s.crashed /\ ~s.down
 /\ s' = [s EXCEPT !.down=TRUE, !.crashed=TRUE, !.known[1]={},
        !.incoming[1]={}, !.phase[1]=0, !.pin[1]=FALSE,
        !.view[1]=Reduce({},FALSE,1)]
Recover == /\ s.down
 /\ s' = [s EXCEPT !.down=FALSE, !.known[1]=s.durable[1], !.recoveredFrom=s.durable[1],
        !.phase[1]=IF Request(1) \in s.durable[1] THEN 3 ELSE 0,
        !.view[1]=Reduce(s.durable[1],FALSE,1)]
Next == Crash \/ Recover \/ LaterChange
 \/ (\E h \in Hosts: Capture(h) \/ Install(h) \/ Complete(h) \/ SettlePin(h)
       \/ (\E r \in Records: Publish(h,r) \/ Receive(h,r) \/ Apply(h,r)))
Spec == Init /\ [][Next]_vars
\* Conditional transport/recovery progress only; no fair user command/pin.
FairSpec == Spec /\ WF_vars(Recover)
 /\ \A h \in Hosts, r \in Records:
      WF_vars(Publish(h,r)) /\ WF_vars(Receive(h,r)) /\ WF_vars(Apply(h,r))
TypeOK ==
 /\ \A f \in {"known","durable","incoming"}: s[f] \in [Hosts -> SUBSET Records]
 /\ s.provider \subseteq Records /\ s.phase \in [Hosts -> 0..3]
 /\ s.pin \in [Hosts -> BOOLEAN]
 /\ s.down \in BOOLEAN /\ s.crashed \in BOOLEAN /\ s.recoveredFrom \subseteq Records
 /\ \A h \in Hosts: s.view[h] \in
      [current: {"A","B","C","absent"}, heads: SUBSET {"A","B","C"},
       handled: SUBSET {"A","B","C"}, unresolved: SUBSET {"A","B","C"},
       copies: [Copies -> {"A","B","changed","absent"}]]
OriginalNeverDisappears == \A h \in Hosts: Up(h) => s.view[h].current # "absent"
\* Independent concrete oracle: C replaces A, so B becomes first, otherwise A.
CurrentIgnoresCopies == \A h \in Hosts: Up(h) /\ ~s.pin[h] =>
 s.view[h].current = IF "C" \in s.known[h] THEN "B" ELSE "A"
ExactDisposition == \A h \in Hosts: Up(h) =>
 s.view[h].handled = {Source(c): c \in Copies \cap s.known[h]}
DispositionHasDurableCopy == \A h \in Hosts: Up(h) =>
 \A v \in s.view[h].handled:
    \E c \in Copies \cap s.durable[h]: Source(c)=v
NewDescendantNeedsAttention == \A h \in Hosts: Up(h) /\ "C" \in s.known[h] =>
 "C" \in s.view[h].unresolved
CopyChangeDoesNotReopen == \A h \in Hosts:
 Up(h) /\ ("modified" \in s.known[h] \/ "deleted" \in s.known[h]) =>
 s.view[h].unresolved = {}
ReciprocalCopyResult == \A h \in Hosts:
 Up(h) /\ Copies \subseteq s.known[h] /\ s.known[h] \subseteq Copies =>
 s.view[h].unresolved = {} /\ s.view[h].copies["copyA"]="A"
 /\ s.view[h].copies["copyB"]="B"
LaterCopyValueSurvives == \A h \in Hosts: Up(h) =>
 /\ ("deleted" \in s.known[h] => s.view[h].copies["copyB"]="absent")
 /\ ("modified" \in s.known[h] => s.view[h].copies["copyB"]="changed")
Agreement == ~s.down /\ ~s.pin[1] /\ ~s.pin[2] /\ s.known[1]=s.known[2]
 => s.view[1]=s.view[2]
Safety == OriginalNeverDisappears /\ CurrentIgnoresCopies /\ ExactDisposition
 /\ DispositionHasDurableCopy /\ NewDescendantNeedsAttention
 /\ CopyChangeDoesNotReopen /\ ReciprocalCopyResult /\ LaterCopyValueSurvives /\ Agreement
DurableRecordsReachBoth == \A r \in Records:
 (\E h \in Hosts: r \in s.durable[h]) ~> (\A h \in Hosts: r \in s.known[h])
\* False invariants demand actual transitions, not merely an expected table.
NeverRecoveredReciprocal == ~(Copies \subseteq s.recoveredFrom /\ ~s.down /\ ~s.pin[1] /\ ~s.pin[2]
 /\ Copies \subseteq s.known[1] /\ Copies \subseteq s.known[2]
 /\ s.view[1].current="A" /\ s.view[2].current="A"
 /\ s.view[1].unresolved={} /\ s.view[2].unresolved={})
NeverSawNewDescendant == ~(~s.down /\ \A h \in Hosts:
 "C" \in s.known[h] /\ s.view[h].unresolved={"C"})
NeverKeptModifiedCopy == ~("modified" \in s.recoveredFrom /\ ~s.down /\ \A h \in Hosts:
 "modified" \in s.known[h] /\ s.view[h].copies["copyB"]="changed"
 /\ s.view[h].unresolved={})
NeverKeptDeletedCopy == ~("deleted" \in s.recoveredFrom /\ ~s.down /\ \A h \in Hosts:
 "deleted" \in s.known[h] /\ s.view[h].copies["copyB"]="absent"
 /\ s.view[h].unresolved={})
NeverParkedChild == ~(\E h \in Hosts: "C" \in s.incoming[h]
 /\ ~(Copies \subseteq s.known[h]))
=============================================================================
