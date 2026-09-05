---------------------- MODULE SegmentDeletionOrderingSafety ----------------------
EXTENDS Naturals, FiniteSets
\* Two receiving replicas of a fixed authored DAG: A authored D0; B authored
\* E then D1 without D0. Optional F extends E without either Delete. P is
\* separately admitted against the displayed automatic E copy before D1.
\* In awareness, F replaces H while knowing E; D0 is concurrent with all
\* three edits. Causal knowledge cannot suppress E's independent note head.
\* Receipt/application and view publication are distinct. No actual installer,
\* UUID hashing, projection unlink or arbitrary-history theorem is modeled.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","stickyCopy","perDeleteUnion","coverDescendants","eraseIndependent","knowledgeSupersedes"}
 /\ Scenario \in {"covered","extension","editedCopy","explicitCopy","awareness"}
Hosts == {1,2}
Source == IF Scenario = "awareness" THEN {"g","E","H","F","D0"}
 ELSE {"g","E","D0","D1"} \cup IF Scenario = "extension" THEN {"F"} ELSE {}
Ops == Source \cup {"P"}
Anc(o) == CASE o = "g" -> {}
 [] o = "F" /\ Scenario = "awareness" -> {"g","E","H"}
 [] o = "D1" \/ o = "F" -> {"g","E"}
 [] o = "P" -> {"g","E","D0"}
 [] OTHER -> {"g"}
NoteAnc(o) == IF o = "F" /\ Scenario = "awareness" THEN {"g","H"} ELSE Anc(o)
Edits == {"E","F","H"}
Deletes == {"D0","D1"}
Covered(e,ns) == \E d \in ns \cap Deletes:
 e \in Anc(d) \/ (Policy = "coverDescendants" /\ "E" \in Anc(e) /\ "E" \in Anc(d))
Candidate(e,ns) ==
 /\ e \in ns \cap Edits
 /\ ~\E later \in ns \cap Edits:
       e \in IF Policy = "knowledgeSupersedes" THEN Anc(later) ELSE NoteAnc(later)
 /\ \E d \in ns \cap Deletes: e \notin Anc(d) /\ d \notin Anc(e)
 /\ Policy = "perDeleteUnion" \/ ~Covered(e,ns)
Reduce(ns,previous) ==
 {e \in Edits: Candidate(e,ns)}
 \cup (IF "P" \in ns /\ ~(Policy = "eraseIndependent" /\ "D1" \in ns) THEN {"P"} ELSE {})
 \cup (IF Policy = "stickyCopy" THEN previous ELSE {})
VARIABLE s
vars == <<s>>
Init == s = [accepted |-> [h \in Hosts |-> {"g"}], frame |-> [h \in Hosts |-> {"g"}],
 view |-> [h \in Hosts |-> {}], independent |-> FALSE,
 sawTemporary |-> {}, crashed |-> FALSE, down |-> FALSE, restarted |-> FALSE]
Up(h) == h # 1 \/ ~s.down
Receive(h,o) ==
 /\ Up(h) /\ o \in (Source \cup IF s.independent THEN {"P"} ELSE {}) \ s.accepted[h]
 /\ Anc(o) \subseteq s.accepted[h]
 /\ s' = [s EXCEPT !.accepted[h] = @ \cup {o}]
Publish(h) ==
 /\ Up(h) /\ s.frame[h] # s.accepted[h]
 /\ LET nextView == Reduce(s.accepted[h],s.view[h]) IN
    s' = [s EXCEPT !.view[h] = nextView, !.frame[h] = s.accepted[h],
       !.sawTemporary = IF "E" \in nextView THEN @ \cup {h} ELSE @]
IndependentAction(h) ==
 /\ Scenario \in {"editedCopy","explicitCopy"} /\ ~s.independent /\ Up(h)
 /\ s.frame[h] = s.accepted[h] /\ "E" \in s.view[h] /\ "D1" \notin s.accepted[h]
 /\ s' = [s EXCEPT !.independent = TRUE, !.accepted[h] = @ \cup {"P"}]
Crash == /\ ~s.crashed
 /\ s' = [s EXCEPT !.crashed = TRUE, !.down = TRUE, !.frame[1] = {}, !.view[1] = {}]
Restart == /\ s.down
 /\ s' = [s EXCEPT !.down = FALSE, !.restarted = TRUE]
Next == (\E h \in Hosts: Publish(h) \/ IndependentAction(h)
                             \/ (\E o \in Ops: Receive(h,o))) \/ Crash \/ Restart
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Restart)
 /\ \A h \in Hosts: WF_vars(Publish(h)) /\ \A o \in Ops: WF_vars(Receive(h,o))
TypeOK ==
 /\ \A f \in {"accepted","frame"}: s[f] \in [Hosts -> SUBSET Ops]
 /\ s.view \in [Hosts -> SUBSET {"E","F","H","P"}] /\ s.sawTemporary \subseteq Hosts
 /\ \A f \in {"independent","crashed","down","restarted"}: s[f] \in BOOLEAN
Closure == \A h \in Hosts: \A o \in s.accepted[h]: Anc(o) \subseteq s.accepted[h]
\* Concrete oracles do not call Candidate/Reduce or their coverage predicate.
CoveredEditIsHistoricalOnly == \A h \in Hosts:
 Up(h) /\ "D1" \in s.frame[h] => "E" \notin s.view[h]
UncoveredExtensionSurvives == \A h \in Hosts:
 Up(h) /\ {"D1","F"} \subseteq s.frame[h] => "F" \in s.view[h] /\ "E" \notin s.view[h]
TemporaryPreservationExists == \A h \in Hosts:
 Up(h) /\ {"D0","E"} \subseteq s.frame[h] /\ s.frame[h] \cap {"D1","F"} = {}
 => "E" \in s.view[h]
IndependentWorkSurvives == \A h \in Hosts:
 Up(h) /\ "P" \in s.frame[h] => "P" \in s.view[h]
KnownAlternativeSurvives == \A h \in Hosts:
 Up(h) /\ Scenario = "awareness" /\ {"D0","E","H","F"} \subseteq s.frame[h]
 => s.view[h] = {"E","F"}
EqualHistoriesAgree == ~s.down /\ s.frame[1] = s.frame[2] => s.view[1] = s.view[2]
Safety == Closure /\ CoveredEditIsHistoricalOnly /\ UncoveredExtensionSurvives
 /\ TemporaryPreservationExists /\ IndependentWorkSurvives /\ EqualHistoriesAgree
 /\ KnownAlternativeSurvives
EventualAgreement == <>[] (~s.down /\ s.frame[1] = s.accepted[1]
 /\ s.frame[2] = s.accepted[2] /\ s.view[1] = s.view[2])
NeverRetractedAfterDisplay == ~(1 \in s.sawTemporary /\ "D1" \in s.frame[1] /\ s.view[1] = {})
NeverPreservedF == ~({"D0","D1","F"} \subseteq s.frame[2] /\ s.view[2] = {"F"})
NeverPreservedIndependentAfterRestart == ~(s.restarted /\ ~s.down
 /\ {"D1","P"} \subseteq s.frame[1] /\ "P" \in s.view[1])
NeverPreservedKnownAlternativeAfterRestart == ~(Scenario = "awareness"
 /\ s.restarted /\ ~s.down /\ \A h \in Hosts:
    Source \subseteq s.frame[h] /\ s.view[h] = {"E","F"})
=============================================================================
