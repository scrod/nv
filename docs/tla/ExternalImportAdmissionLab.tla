----------------------- MODULE ExternalImportAdmissionLab -----------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"targeted","noFileFence","noRootFence","noHistoryFence","noNoteFence",
 "aliasLate","equalMeansSame","earlyPublish","forgetRecovery","stall"}
 /\ Scenario \in {"lateHistory","lateDelete","stampFirst","fileRace","metadataRace",
                  "rootRace","historyRace","noteRace","crash","edit"}
VARIABLE s
vars == <<s>>
\* Reuse the SAME classifier and fixture representation, not a hand-copied
\* "plausible" Boolean. Its state-machine operators are not instantiated here.
E == INSTANCE ExternalImportPolicyLab WITH Policy <- "targeted", Scenario <- "all", s <- s
Hosts == {1,2}
Records == {"a","b","d","e"}
\* a is the remote old birth, b the fresh import, d Delete(a), e an edit of b.
Birth(r) == IF r \in {"a","d"} THEN "old" ELSE "fresh"
Active == {"captured","prepared"}
Terminal == {"installed","associated","association","provenance","restoration","history","file","ignored","stale"}
InitialKnown(h) == IF h=1 \/ Scenario="noteRace" THEN {"a"} ELSE {}
Init == s=[known |-> [h \in Hosts |-> InitialKnown(h)],
 durable |-> [h \in Hosts |-> InitialKnown(h)],
 incoming |-> [h \in Hosts |-> {}], provider |-> {},
 parents |-> [r \in Records |-> {}], values |-> [r \in Records |-> IF r="e" THEN "edited" ELSE "A"],
 issued |-> {"a"}, ack |-> {}, saved |-> [r \in {"b","e"} |-> "none"],
 file |-> 0, stamp |-> Scenario="stampFirst", root |-> 0, note |-> 0,
 phase |-> "idle", frame |-> [file |-> 0, stamp |-> FALSE, root |-> 0, note |-> 0, history |-> {}],
 decision |-> "none", admitted |-> FALSE, capturedBody |-> "A", badScope |-> {},
 down |-> FALSE, crashed |-> FALSE, recovered |-> FALSE, waited |-> FALSE]
Up(h) == h=1 \/ ~s.down
CurrentFrame == [file |-> s.file, stamp |-> s.stamp, root |-> s.root, note |-> s.note, history |-> s.known[2]]
Observation(f) ==
 [E!Base EXCEPT
   !.file.path=IF Scenario="lateHistory" THEN "Q" ELSE "P",
   !.file.body=IF f.file=0 /\ Scenario # "noteRace" THEN "A" ELSE "changed",
   !.file.stamp=IF ~f.stamp THEN "none" ELSE IF f.file=0 THEN "valid" ELSE "skewed",
   !.notes[1].live="a" \in f.history /\ "d" \notin f.history,
   !.notes[1].relationship=IF f.note=0 THEN "missing" ELSE "present",
   !.notes[1].path=IF f.note=0 THEN "P" ELSE "Q", !.notes[2].live=FALSE,
   !.history=IF "a" \in f.history THEN {1} ELSE {}]

\* Source: NDM prepares detached values before the transaction publication
\* fence. Coherent selected reads/digests/catalog completeness are lower-layer
\* assumptions here; CoAddRevalidationLab models the individual read steps.
Capture == /\ ~s.down /\ s.phase="idle" /\ s.root=0 /\ "b" \notin s.durable[2]
 /\ s'=[s EXCEPT !.frame=CurrentFrame, !.phase="captured"]
Prepare == /\ ~s.down /\ s.phase="captured"
 /\ s'=[s EXCEPT !.phase="prepared", !.decision=E!Decision(Observation(s.frame),E!Targeted).kind,
                   !.capturedBody=Observation(s.frame).file.body]
ScopeOK == /\ (Policy="noFileFence" \/ (s.frame.file=s.file /\ s.frame.stamp=s.stamp))
 /\ (Policy="noRootFence" \/ s.frame.root=s.root)
 /\ (Policy="noHistoryFence" \/ s.frame.history=s.known[2])
 /\ (Policy="noNoteFence" \/ s.frame.note=s.note)
ActualMismatches == {k \in {"file","root","history","note"}:
 CASE k="file" -> s.frame.file # s.file \/ s.frame.stamp # s.stamp
 [] k="root" -> s.frame.root # s.root
 [] k="history" -> s.frame.history # s.known[2]
 [] k="note" -> s.frame.note # s.note}
\* The final decision is fenced at admission, not again after it has become
\* an immutable user-visible operation. Later history cannot revoke that birth.
Admit == /\ ~s.down /\ s.phase="prepared" /\ ScopeOK
 /\ s'=[s EXCEPT !.phase=IF s.decision="new" THEN "admitted"
                         ELSE IF s.decision \in {"represented","edit"} THEN "associated" ELSE s.decision,
   !.admitted=s.decision="new", !.badScope=@ \cup ActualMismatches,
   !.waited=@ \/ s.decision="history",
   !.issued=IF s.decision="new" THEN @ \cup {"b"} ELSE @,
   !.parents["b"]=IF s.decision="new" THEN s.frame.history ELSE @,
   !.values["b"]=IF s.decision="new" THEN s.capturedBody ELSE @]
Reject == /\ ~s.down /\ s.phase="prepared" /\ ~ScopeOK
 /\ s'=[s EXCEPT !.phase="stale"]
\* Positive changed evidence wakes a parked attempt; elapsed time does not
\* declare it new. Each fixture has finitely many external changes. A lost
\* root needs separate authorization and is never silently rebound here.
Reobserve == /\ ~s.down /\ s.root=0 /\ s.phase \in {"history","stale","association","provenance"}
 /\ s.frame # CurrentFrame /\ "b" \notin s.durable[2]
 /\ s'=[s EXCEPT !.phase="idle"]
\* Complete immutable-object/parent durability is one action, not a claim
\* about actual fsync/codec implementation. Only this barrier acknowledges b.
Install == /\ ~s.down /\ s.phase="admitted" /\ Policy # "stall"
 /\ s'=[s EXCEPT !.durable[2]=@ \cup {"b"}, !.known[2]=@ \cup {"b"},
                   !.ack=@ \cup {"b"}, !.saved["b"]=s.capturedBody, !.phase="installed"]
Delete == /\ Scenario \in {"lateDelete","edit","crash"} /\ "d" \notin s.issued
 /\ s'=[s EXCEPT !.issued=@ \cup {"d"}, !.parents["d"]=s.known[1],
                   !.durable[1]=@ \cup {"d"}, !.known[1]=@ \cup {"d"}]
Edit == /\ Scenario="edit" /\ ~s.down /\ "b" \in s.known[2] /\ "e" \notin s.issued
 /\ s'=[s EXCEPT !.issued=@ \cup {"e"}, !.parents["e"]=s.known[2],
                   !.known[2]=@ \cup {"e"}, !.durable[2]=@ \cup {"e"}, !.ack=@ \cup {"e"}, !.saved["e"]="edited"]
Publish(h,r) == /\ Up(h) /\ r \notin s.provider
 /\ (r \in s.durable[h] \/ (Policy="earlyPublish" /\ h=2 /\ r="b" /\ s.phase="admitted"))
 /\ s'=[s EXCEPT !.provider=@ \cup {r}]
Receive(h,r) == /\ Up(h) /\ r \in s.provider \ (s.known[h] \cup s.incoming[h])
 /\ s'=[s EXCEPT !.incoming[h]=@ \cup {r}]
Apply(h,r) == /\ Up(h) /\ r \in s.incoming[h] /\ s.parents[r] \subseteq s.known[h]
 /\ s'=[s EXCEPT !.known[h]=@ \cup {r}, !.durable[h]=@ \cup {r}, !.incoming[h]=@ \ {r}]
ChangeFile == /\ Scenario="fileRace" /\ s.file=0 /\ s.phase \in Active \cup {"admitted","installed"}
 /\ s'=[s EXCEPT !.file=1]
DeliverStamp == /\ Scenario="metadataRace" /\ ~s.stamp /\ s.phase \in Active
 /\ s'=[s EXCEPT !.stamp=TRUE]
ChangeRoot == /\ Scenario="rootRace" /\ s.root=0 /\ s.phase \in Active
 /\ s'=[s EXCEPT !.root=1]
ChangeNote == /\ Scenario="noteRace" /\ s.note=0 /\ s.phase \in Active
 /\ s'=[s EXCEPT !.note=1]
Crash == /\ Scenario \in {"crash","edit"} /\ ~s.crashed
 /\ s'=[s EXCEPT !.down=TRUE, !.crashed=TRUE, !.known[2]={}, !.incoming[2]={},
                   !.phase="idle", !.admitted=FALSE]
Recover == /\ s.down
 /\ LET retained==IF Policy="forgetRecovery" THEN s.durable[2] \ {"b","e"} ELSE s.durable[2]
    IN s'=[s EXCEPT !.down=FALSE, !.recovered=TRUE, !.known[2]=retained,
                  !.phase=IF "b" \in retained THEN "installed" ELSE "idle"]
Next == Capture \/ Prepare \/ Admit \/ Reject \/ Reobserve \/ Install \/ Delete \/ Edit
 \/ ChangeFile \/ DeliverStamp \/ ChangeRoot \/ ChangeNote \/ Crash \/ Recover
 \/ (\E h \in Hosts, r \in Records: Publish(h,r) \/ Receive(h,r) \/ Apply(h,r))
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Recover) /\ WF_vars(Install)
 /\ WF_vars(Capture) /\ WF_vars(Prepare) /\ WF_vars(Admit) /\ WF_vars(Reject) /\ WF_vars(Reobserve)
 /\ \A h \in Hosts, r \in Records: WF_vars(Publish(h,r)) /\ WF_vars(Receive(h,r)) /\ WF_vars(Apply(h,r))
\* Freshness belongs to the installed creation record, not a rediscovered
\* filename, equal payload, or delayed stamp naming the old birth.
EffectiveBirth(k,r) == IF Policy="aliasLate" /\ r \in {"b","e"} /\ "a" \in k THEN "old" ELSE Birth(r)
Live(k) == {r \in k \cap {"a","b","e"}:
 ~(EffectiveBirth(k,r)="old" /\ "d" \in k)
 /\ ~(r="b" /\ "e" \in k)
 /\ ~(Policy="equalMeansSame" /\ r="b" /\ "a" \in k /\ s.values["a"]=s.values["b"])}
TypeOK == /\ s.known \in [Hosts -> SUBSET Records] /\ s.durable \in [Hosts -> SUBSET Records]
 /\ s.incoming \in [Hosts -> SUBSET Records] /\ s.provider \subseteq Records
 /\ s.parents \in [Records -> SUBSET Records] /\ s.values \in [Records -> {"A","changed","edited"}]
 /\ s.issued \subseteq Records /\ s.ack \subseteq {"b","e"}
 /\ s.saved \in [{"b","e"} -> {"none","A","changed","edited"}]
 /\ s.file \in 0..1 /\ s.stamp \in BOOLEAN /\ s.root \in 0..1 /\ s.note \in 0..1
 /\ s.frame \in [file: 0..1, stamp: BOOLEAN, root: 0..1, note: 0..1, history: SUBSET Records]
 /\ s.phase \in {"idle","captured","prepared","admitted"} \cup Terminal
 /\ s.decision \in E!Kinds /\ s.capturedBody \in {"A","changed"}
 /\ s.badScope \subseteq {"file","root","history","note"}
 /\ s.admitted \in BOOLEAN /\ s.down \in BOOLEAN /\ s.crashed \in BOOLEAN /\ s.recovered \in BOOLEAN /\ s.waited \in BOOLEAN
ExactFileAdmission == "file" \notin s.badScope
ExactRootAdmission == "root" \notin s.badScope
ExactHistoryAdmission == "history" \notin s.badScope
ExactNoteAdmission == "note" \notin s.badScope
PublishedIsDurable == s.provider \subseteq UNION {s.durable[h]: h \in Hosts}
AcknowledgedImportsRecover == ~s.down => s.ack \subseteq s.known[2]
AcknowledgedBytesRetained == \A r \in s.ack: s.values[r]=s.saved[r]
IndependentBirthSurvives == \A h \in Hosts: Up(h) =>
 /\ ("b" \in s.known[h] /\ "e" \notin s.known[h] => "b" \in Live(s.known[h]))
 /\ ("e" \in s.known[h] => "e" \in Live(s.known[h]))
NoRetroactiveAlias == \A h \in Hosts: \A r \in s.known[h] \cap {"b","e"}:
 EffectiveBirth(s.known[h],r)="fresh"
OldDeleteHonored == \A h \in Hosts: "d" \in s.known[h] => "a" \notin Live(s.known[h])
DependencyClosed == \A h \in Hosts: \A r \in s.known[h]: s.parents[r] \subseteq s.known[h]
Safety == ExactFileAdmission /\ ExactRootAdmission /\ ExactHistoryAdmission /\ ExactNoteAdmission
 /\ PublishedIsDurable /\ AcknowledgedImportsRecover /\ AcknowledgedBytesRetained /\ IndependentBirthSurvives
 /\ NoRetroactiveAlias /\ OldDeleteHonored /\ DependencyClosed
DurableImportsReachBoth == \A r \in {"b","e"}:
 (r \in s.ack) ~> (\A h \in Hosts: r \in s.known[h])
\* Only an already admitted, non-crashed local attempt must finish. No fairness
\* assumption makes the user choose, invents cloud delivery, or forces imports.
AdmittedAttemptFinishes == (s.phase="admitted") ~> (s.phase # "admitted")
DisclosedProjectionSettles == (Scenario="stampFirst" /\ "a" \in s.known[2]) ~> (s.phase="associated")
NeverImported == "b" \notin s.ack
NeverLateDuplicate == ~(\E h \in Hosts: {"a","b"} \subseteq Live(s.known[h]) /\ s.values["a"]=s.values["b"])
NeverPreservedAfterDelete == ~(\E h \in Hosts: {"b","d"} \subseteq s.known[h] /\ "b" \in Live(s.known[h]))
NeverRecoveredEdit == ~(s.recovered /\ "e" \in s.known[2] /\ "e" \in Live(s.known[2]))
NeverWaitedForHistory == s.phase # "history"
NeverParkedChild == ~(\E h \in Hosts: \E r \in s.incoming[h]: ~(s.parents[r] \subseteq s.known[h]))
NeverRejectedRace == s.phase # "stale"
NeverAssociatedInstead == s.phase # "associated"
NeverWaitedThenAssociated == ~(s.waited /\ s.phase="associated")
NeverKeptAdmittedSnapshot == ~(s.file=1 /\ "b" \in s.ack /\ s.values["b"]="A")
=============================================================================
