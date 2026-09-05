------------------------ MODULE CoAddLateHistoryLab ------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"birthDelete","causal","fresh","review","equalMeansObserved","revive"}
 /\ Scenario \in {"staleEcho","hiddenRestore","explicitRestore","knownDelete","observeImport","lateEdit"}
\* Experimental bridge: an old committed creation a, a remote Delete d,
\* an independently captured unassociated file b, optional user edit e or
\* explicit fresh import f. staleEcho/hiddenRestore have identical observations;
\* their different real-world intent is used only in the assertions below.
\* Complete local installation is atomic here. In review mode b denotes
\* preserved LOCAL pending-file bytes, not a new synced operation/UUID. f
\* contains its full copied value; no reference to private b goes on the wire.
Hosts == {1,2}
Records == {"a","b","d","e","f"}
Intent == IF Scenario \in {"explicitRestore","knownDelete"} THEN "new" ELSE "observe"
VARIABLE s
vars == <<s>>
Init == s = [known |-> [h \in Hosts |-> IF h=1 THEN {"a"} ELSE {}],
 durable |-> [h \in Hosts |-> IF h=1 THEN {"a"} ELSE {}],
 incoming |-> [h \in Hosts |-> {}], provider |-> {}, issued |-> {"a"},
 parents |-> [r \in Records |-> {}], birth |-> "none", tentative |-> FALSE,
 down |-> FALSE, crashed |-> FALSE, recoveredFrom |-> {}, freshValue |-> "none"]
Up(h) == h # 2 \/ ~s.down
Public(r) == r # "b" \/ ~s.tentative
PublicKnown(h) == {r \in s.known[h]: Public(r)}
Import ==
 /\ Up(2) /\ "b" \notin s.issued
 /\ IF Scenario="knownDelete" THEN "d" \in s.known[2] ELSE "d" \notin s.known[2]
 /\ (Intent="new" \/ "a" \notin s.known[2])
 /\ s'=[s EXCEPT !.issued=@ \cup {"b"}, !.known[2]=@ \cup {"b"},
       !.durable[2]=@ \cup {"b"}, !.parents["b"]=PublicKnown(2),
       !.birth=IF Intent="new" \/ Policy="fresh" THEN "new" ELSE "old",
       !.tentative=Policy="review" /\ Intent="observe"]
Delete ==
 /\ "d" \notin s.issued /\ "a" \in s.known[1]
 /\ (Scenario \in {"observeImport","lateEdit"} => "b" \in s.known[1])
 /\ (Scenario="lateEdit" => "e" \notin s.known[1])
 /\ s'=[s EXCEPT !.issued=@ \cup {"d"}, !.known[1]=@ \cup {"d"},
       !.durable[1]=@ \cup {"d"}, !.parents["d"]=PublicKnown(1)]
Edit ==
 /\ Up(2) /\ Scenario="lateEdit" /\ "e" \notin s.issued
 /\ "b" \in s.known[2] /\ "d" \notin s.known[2] /\ ~s.tentative
 /\ s'=[s EXCEPT !.issued=@ \cup {"e"}, !.known[2]=@ \cup {"e"},
       !.durable[2]=@ \cup {"e"}, !.parents["e"]=PublicKnown(2)]
ChooseFresh ==
 /\ Up(2) /\ s.tentative /\ "b" \in s.known[2] /\ "f" \notin s.issued
 /\ s'=[s EXCEPT !.issued=@ \cup {"f"}, !.known[2]=@ \cup {"f"},
       !.durable[2]=@ \cup {"f"}, !.parents["f"]=PublicKnown(2), !.freshValue="original"]
Publish(h,r) == /\ Up(h) /\ r \in s.durable[h] \ s.provider /\ Public(r)
 /\ s'=[s EXCEPT !.provider=@ \cup {r}]
Receive(h,r) == /\ Up(h) /\ r \in s.provider \ (s.known[h] \cup s.incoming[h])
 /\ s'=[s EXCEPT !.incoming[h]=@ \cup {r}]
Apply(h,r) == /\ Up(h) /\ r \in s.incoming[h] /\ s.parents[r] \subseteq s.known[h]
 /\ s'=[s EXCEPT !.known[h]=@ \cup {r}, !.durable[h]=@ \cup {r}, !.incoming[h]=@ \ {r}]
Crash == /\ ~s.crashed /\ ~s.down
 /\ s'=[s EXCEPT !.down=TRUE, !.crashed=TRUE, !.known[2]={}, !.incoming[2]={}]
Recover == /\ s.down
 /\ s'=[s EXCEPT !.down=FALSE, !.known[2]=s.durable[2], !.recoveredFrom=s.durable[2]]
Covered(r) == r \in s.parents["d"]
 \/ (Policy="equalMeansObserved" /\ r="b" /\ "a" \in s.parents["d"])
View(k) ==
 LET branch == IF "e" \in k THEN {"e"} ELSE IF "b" \in k /\ ~s.tentative THEN {"b"} ELSE {}
     old == (k \cap {"a"}) \cup (IF s.birth="old" THEN branch ELSE {})
     deleted == "d" \in k
 IN [old |-> IF deleted /\ Policy # "revive" THEN {} ELSE old,
     fresh |-> (k \cap {"f"}) \cup (IF s.birth="new" THEN branch ELSE {}),
     conflict |-> IF deleted /\ s.birth="old" /\ Policy # "birthDelete"
                  THEN {r \in branch: ~Covered(r)} ELSE {},
     review |-> IF s.tentative /\ "b" \in k /\ "f" \notin k THEN {"b"} ELSE {}]
Editable(v) == v.old \cup v.fresh \cup v.conflict
\* Only this explicit copy's provenance can represent private b; payload
\* equality with arbitrary a or another note never supplies causal coverage.
PendingCopyRepresentsB(k) == "f" \in View(k).fresh /\ s.freshValue="original"
ImportRepresented(k) == "b" \in Editable(View(k)) \cup View(k).review
 \/ (s.tentative /\ PendingCopyRepresentsB(k))
Next == Import \/ Delete \/ Edit \/ ChooseFresh \/ Crash \/ Recover
 \/ (\E h \in Hosts, r \in Records: Publish(h,r) \/ Receive(h,r) \/ Apply(h,r))
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Recover)
 /\ \A h \in Hosts, r \in Records:
      WF_vars(Publish(h,r)) /\ WF_vars(Receive(h,r)) /\ WF_vars(Apply(h,r))
TypeOK == /\ s.known \in [Hosts -> SUBSET Records] /\ s.durable \in [Hosts -> SUBSET Records]
 /\ s.incoming \in [Hosts -> SUBSET Records] /\ s.parents \in [Records -> SUBSET Records]
 /\ s.provider \subseteq Records /\ s.issued \subseteq Records /\ s.recoveredFrom \subseteq Records
 /\ s.birth \in {"none","old","new"} /\ s.tentative \in BOOLEAN
 /\ s.freshValue \in {"none","original","wrong"}
 /\ s.down \in BOOLEAN /\ s.crashed \in BOOLEAN
OldBirthStaysDeleted == \A h \in Hosts: Up(h) /\ "d" \in s.known[h] => View(s.known[h]).old={}
DeliberateFreshImportSurvives == \A h \in Hosts: Up(h) =>
 /\ (Intent="new" /\ "b" \in s.known[h] => "b" \in View(s.known[h]).fresh)
 /\ ("f" \in s.known[h] => "f" \in View(s.known[h]).fresh)
ConcurrentImportPreserved == \A h \in Hosts:
 Up(h) /\ {"b","d"} \subseteq s.known[h] /\ ~Covered("b") /\ "e" \notin s.known[h] =>
 ImportRepresented(s.known[h])
UserEditPreserved == \A h \in Hosts: Up(h) /\ "e" \in s.known[h] /\ ~Covered("e") =>
 "e" \in Editable(View(s.known[h]))
ObservedImportNotResurrected == \A h \in Hosts:
 Up(h) /\ {"b","d"} \subseteq s.known[h] /\ "b" \in s.parents["d"]
 /\ s.birth="old" /\ "e" \notin s.known[h] => "b" \notin Editable(View(s.known[h]))
NoEqualPayloadCoverageGuess == \A h \in Hosts:
 Up(h) /\ {"b","d"} \subseteq s.known[h] /\ "b" \notin s.parents["d"]
 /\ "e" \notin s.known[h] => ImportRepresented(s.known[h])
ReviewBytesPreserved == Up(2) /\ s.tentative /\ "b" \in s.known[2]
 => ImportRepresented(s.known[2])
RecoveredHistoryRetained == Up(2) => s.durable[2] \subseteq s.known[2]
NoStaleEchoAsNote == Scenario="staleEcho" /\ {"b","d"} \subseteq s.known[2]
 => "b" \notin Editable(View(s.known[2]))
HiddenRestoreAutomatic == Scenario="hiddenRestore" /\ {"b","d"} \subseteq s.known[2]
 /\ "b" \notin s.parents["d"]
 /\ "f" \notin s.known[2] => "b" \in Editable(View(s.known[2]))
Safety == OldBirthStaysDeleted /\ DeliberateFreshImportSurvives
 /\ ConcurrentImportPreserved /\ UserEditPreserved /\ ObservedImportNotResurrected
 /\ NoEqualPayloadCoverageGuess /\ ReviewBytesPreserved /\ RecoveredHistoryRetained
PublicRecordsReachBoth == \A r \in Records:
 ((\E h \in Hosts: r \in s.durable[h]) /\ Public(r)) ~> (\A h \in Hosts: r \in s.known[h])
NeverRecoveredPreservation == ~(~s.down /\ {"b","d"} \subseteq s.recoveredFrom
 /\ "b" \in View(s.known[2]).conflict)
NeverRecoveredFreshChoice == ~(~s.down /\ {"f","d"} \subseteq s.recoveredFrom
 /\ "f" \in View(s.known[2]).fresh)
NeverPreservedUnseenEdit == ~(~s.down /\ {"e","d"} \subseteq s.known[2]
 /\ "b" \in s.parents["d"] /\ "e" \notin s.parents["d"]
 /\ "e" \in View(s.known[2]).conflict /\ "b" \notin View(s.known[2]).conflict)
NeverParkedDelete == ~(\E h \in Hosts: "d" \in s.incoming[h] /\ ~(s.parents["d"] \subseteq s.known[h]))
NeverAskedThenRestored == ~(~s.down /\ s.tentative /\ "f" \in s.known[2]
 /\ View(s.known[2]).review={} /\ "f" \in View(s.known[2]).fresh)
NeverImportedAfterKnownDelete == ~(Scenario="knownDelete" /\ {"b","d"} \subseteq s.known[2]
 /\ "d" \in s.parents["b"] /\ "b" \in View(s.known[2]).fresh)
NeverHonoredObservedDelete == ~(Scenario="observeImport" /\ {"b","d"} \subseteq s.known[2]
 /\ "b" \in s.parents["d"] /\ "b" \notin Editable(View(s.known[2])))
=============================================================================
