-------------------- MODULE ProjectionTransitionSafety --------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","clearNewer","skipSource","skipVerification","stalePublication"}
 /\ Scenario \in {"edit","rename","format"}
VARIABLE s
vars == <<s>>
\* Two successive intended outputs, exact file/root tokens and delayed local
\* completion. Source accounting is a validated rename/move outcome, NOT an
\* authorization to unlink by filename. Bodies/paths stand for coherent exact
\* encoded projections; this is not the filesystem CAS implementation.
\* verified/receipts are audit evidence; jobs are volatile work, not serialized
\* authority. This module has no crash/restart action or completion fairness.
Paths == [g \in 0..2 |-> IF Scenario="edit" THEN "A" ELSE IF g=0 THEN "A" ELSE IF g=1 THEN "B" ELSE "C"]
Bodies == [g \in 0..2 |-> IF Scenario="rename" THEN 1 ELSE g+1]
Formats == [g \in 0..2 |-> IF Scenario="format" /\ g>0 THEN 2 ELSE 1]
EmptyJob == [stage |-> "idle", file |-> 0, root |-> 0, source |-> FALSE]
Init == s=[intent |-> 1, accepted |-> 0, file |-> 0, root |-> 0,
 dirty |-> TRUE, jobs |-> [g \in 1..2 |-> EmptyJob], installed |-> {},
 verified |-> {}, receipts |-> {}, advanced |-> FALSE]
Capture(g) == /\ g=s.intent /\ s.jobs[g].stage="idle"
 /\ s.file # 3
 /\ (\A h \in s.installed: s.jobs[h].source)
 /\ s'=[s EXCEPT !.jobs[g]=[stage |-> "captured", file |-> s.file, root |-> s.root,
                            source |-> Scenario="edit"]]
Install(g) == /\ s.jobs[g].stage="captured"
 /\ s.file=s.jobs[g].file /\ s.root=s.jobs[g].root
 /\ s'=[s EXCEPT !.file=g, !.installed=@ \cup {g}, !.jobs[g].stage="installed"]
Verify(g) == /\ s.jobs[g].stage="installed" /\ s.file=g /\ s.root=s.jobs[g].root
 /\ s'=[s EXCEPT !.verified=@ \cup {<<g,s.root>>}, !.jobs[g].stage="verified"]
AccountSource(g) == /\ g \in s.installed /\ ~s.jobs[g].source
 /\ s.file=g /\ s.root=s.jobs[g].root
 /\ s'=[s EXCEPT !.jobs[g].source=TRUE]
Evidence(g) == [generation |-> g, file |-> s.file, root |-> s.root,
 capturedRoot |-> s.jobs[g].root, verified |-> <<g,s.root>> \in s.verified,
 source |-> s.jobs[g].source, previous |-> s.accepted, intended |-> s.intent]
Publish(g) == /\ (s.jobs[g].stage="verified" \/ (Policy="skipVerification" /\ s.jobs[g].stage="installed"))
 /\ (s.jobs[g].source \/ Policy="skipSource")
 /\ ((s.file=g /\ s.root=s.jobs[g].root /\ g>=s.accepted) \/ Policy="stalePublication")
 /\ s'=[s EXCEPT !.accepted=g, !.dirty=IF Policy="clearNewer" THEN FALSE ELSE s.intent # g,
                 !.receipts=@ \cup {Evidence(g)}, !.jobs[g].stage="published"]
EditAgain == /\ ~s.advanced
 /\ s'=[s EXCEPT !.intent=2, !.dirty=TRUE, !.advanced=TRUE]
ChangeRoot == /\ s.root=0 /\ s'=[s EXCEPT !.root=1]
ExternalReplacement == /\ s.file # 3 /\ s'=[s EXCEPT !.file=3]
ActiveProjections == {<<Paths[g],Bodies[g],Formats[g]>>: g \in {s.intent,s.accepted}}
Next == EditAgain \/ ChangeRoot \/ ExternalReplacement \/
 (\E g \in 1..2: Capture(g) \/ Install(g) \/ Verify(g) \/ AccountSource(g) \/ Publish(g))
Spec == Init /\ [][Next]_vars
TypeOK == /\ s.intent \in 1..2 /\ s.accepted \in 0..2 /\ s.file \in 0..3 /\ s.root \in 0..1
 /\ s.dirty \in BOOLEAN /\ s.advanced \in BOOLEAN /\ s.installed \subseteq 1..2
 /\ s.verified \subseteq ((1..2) \X (0..1))
 /\ s.jobs \in [1..2 -> [stage:{"idle","captured","installed","verified","published"}, file:0..3, root:0..1, source:BOOLEAN]]
 /\ s.receipts \subseteq [generation:1..2,file:0..3,root:0..1,capturedRoot:0..1,verified:BOOLEAN,source:BOOLEAN,previous:0..2,intended:1..2]
ReceiptRequiresExactVerifiedTransition == \A r \in s.receipts:
 r.file=r.generation /\ r.root=r.capturedRoot /\ r.verified /\ r.source /\ r.generation>=r.previous
NewerIntentRemainsPending == s.dirty=(s.intent # s.accepted)
PriorHasSettledSuccessor == s.accepted # 0 =>
 \E r \in s.receipts: r.generation=s.accepted /\ r.source /\ r.verified
Safety == ReceiptRequiresExactVerifiedTransition /\ NewerIntentRemainsPending /\ PriorHasSettledSuccessor
NeverAcceptedOlderWhileNewerPending == ~(s.accepted=1 /\ s.intent=2 /\ s.dirty)
NeverFinishedNewest == ~(s.accepted=2 /\ ~s.dirty)
NeverKeptPriorWhileSourcePending == ~(s.file=1 /\ s.accepted=0 /\ ~s.jobs[1].source)
NeverReplacedActivePrior == ~(s.intent=2 /\ s.accepted=1 /\
 <<Paths[0],Bodies[0],Formats[0]>> \notin ActiveProjections)
=============================================================================
