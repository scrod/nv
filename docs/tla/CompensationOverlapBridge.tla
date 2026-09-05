--------------------- MODULE CompensationOverlapBridge ---------------------
EXTENDS Naturals, FiniteSets
\* HIST-01/PUB-01/DUR-01. One note with body/title, initial A, local Undo U,
\* peer E (overlap/disjoint/observing edit) or V (competing Undo), then reviewed
\* Redo R of U and Undo S of that ACTUAL R. All share CausalUndoRules.
\* Separate causal parents, note predecessors, and compensation targets.
\* Fixed finite operation slots denote exact semantic operations, not reusable
\* on-disk nonces. Scalar merge is the specified equal/unchanged-base rule;
\* no arbitrary text, native partial-range attribution or encrypted codec proof.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","staleAdmission","consumeAllHeads","lateRecapture",
 "staleCompletion","wrongInverse","splitAction","ignoreSibling","earlyPin","firstPairOnly","stallReceive",
 "noLocalReduction","frontierOnly","mergeUnsealed"}
 /\ Scenario \in {"overlap","disjoint","competing","observing"}
Rules == INSTANCE CausalUndoRules
Ids == {"A","U","E","V","R","S"}
Hosts == {1,2}
Remote == IF Scenario="competing" THEN "V" ELSE "E"
Empty == [parents |-> {},prev |-> {},target |-> "none",kind |-> "forward",
 scope |-> "note",before |-> <<0,7>>,after |-> <<0,7>>]
ARecord == [Empty EXCEPT !.after= <<1,7>>]
VARIABLE s
vars == <<s>>
Init == s=[records |-> [a \in Ids |-> IF a="A" THEN ARecord ELSE Empty],
 bindings |-> [a \in Ids |-> IF a="A" THEN ARecord ELSE Empty],
 known |-> [h \in Hosts |-> {"A"}], objects |-> [h \in Hosts |-> {"A"}],
 actions |-> [h \in Hosts |-> {"A"}], pin |-> [h \in Hosts |-> {"A"}],
 live |-> [h \in Hosts |-> <<1,7>>], acknowledged |-> {},
 currentInputs |-> [h \in Hosts |-> {"A"}],
 phase |-> "idle", slot |-> "U", capture |-> Empty, frame |-> {},
 neededReview |-> FALSE, approved |-> FALSE, remoteMade |-> FALSE,
 crashed |-> FALSE, recovered |-> FALSE, rejected |-> FALSE, inverseCut |-> FALSE]
RECURSIVE NoteReach(_, _)
NoteReach(nodes,n) == IF n=0 THEN nodes ELSE
 NoteReach(nodes \cup UNION {s.records[a].prev:a \in nodes},n-1)
Anc(a) == NoteReach(s.records[a].prev,6)
Heads(hist) == {a \in hist: ~\E b \in hist: a \in Anc(b)}
\* Fixed tie-break solely for presentation of incompatible values.
Order == <<"S","R","E","U","V","A">>
Selected(hs) == Order[CHOOSE i \in 1..6: Order[i] \in hs
 /\ \A j \in 1..(i-1): Order[j] \notin hs]
Scalar(b,l,r) == IF l=r THEN l ELSE IF l=b THEN r ELSE IF r=b THEN l ELSE 99
Bases(hs) == Heads({a \in Ids: \A h \in hs: a=h \/ a \in Anc(h)})
Merged(hist) == LET hs==Heads(hist) bases==Bases(hs) IN
 IF Cardinality(hs)=2 /\ Cardinality(bases)=1
    /\ (Policy#"firstPairOnly" \/ hs={"U","E"})
 THEN LET l==Selected(hs) r==CHOOSE a \in hs \ {l}: TRUE
          b==CHOOSE a \in bases: TRUE
      IN <<Scalar(s.records[b].after[1],s.records[l].after[1],s.records[r].after[1]),
           Scalar(s.records[b].after[2],s.records[l].after[2],s.records[r].after[2])>>
 ELSE <<99,99>>
Represented(hist) == LET hs==Heads(hist) vals=={s.records[a].after:a \in hs} IN
 IF Cardinality(vals)=1 \/ 99 \notin {Merged(hist)[i]:i \in {1,2}}
 THEN hs ELSE {Selected(hs)}
Value(hist) == LET hs==Heads(hist) vals=={s.records[a].after:a \in hs} IN
 IF Cardinality(vals)=1 THEN CHOOSE v \in vals: TRUE
 ELSE IF 99 \notin {Merged(hist)[i]:i \in {1,2}} THEN Merged(hist)
 ELSE s.records[Selected(hs)].after
Dependencies(a) == s.records[a].parents \cup s.records[a].prev
 \cup IF s.records[a].target="none" THEN {} ELSE {s.records[a].target}
RECURSIVE Closed(_, _)
Closed(hist,n) == IF n=0 THEN hist
 ELSE Closed({a \in hist: Dependencies(a) \subseteq hist},n-1)
Complete(h) == Closed(s.objects[h] \cap s.actions[h],6)
Target(a) == CASE a="U" -> "A" [] a="R" -> "U" [] OTHER -> "R"
Direction(a) == IF a="R" THEN "redo" ELSE "undo"
NextSlot == IF "U" \notin s.objects[1] THEN "U"
 ELSE IF "R" \notin s.objects[1] THEN "R"
 ELSE IF "S" \notin s.objects[1] THEN "S" ELSE "none"
Candidates(hist,direction) == Rules!Candidates(s.records,hist,"note",direction)
Mode(hist,direction) == IF Policy="ignoreSibling" THEN "automatic"
 ELSE Rules!Mode(s.records,hist,"note",direction)
Prepare == /\ s.phase="idle" /\ NextSlot#"none"
 /\ LET a==NextSlot t==Target(a) hist==s.known[1]
    IN /\ t \in Candidates(hist,Direction(a))
       /\ (a#"U" => {"U",Remote} \subseteq s.pin[1])
       /\ (a="S" => "R" \in s.pin[1])
       /\ LET before==s.live[1]
              after== <<s.records[t].before[1],before[2]>>
              review==Mode(hist,Direction(a))="review" \/ before[1]#s.records[t].after[1]
          IN /\ before#after
             /\ s'=[s EXCEPT !.slot=a, !.frame=hist,
                !.neededReview=review, !.approved=~review,
                !.phase=IF review THEN "preview" ELSE "ready",
                !.capture=[parents |-> Rules!Maximal(s.records,hist),
                    prev |-> s.currentInputs[1],target |-> t,
                    kind |-> Direction(a),scope |-> "note",before |-> before,after |-> after]]
Approve == /\ s.phase="preview"
 /\ s'=[s EXCEPT !.phase="ready", !.approved=TRUE]
FreshCapture == s.frame=s.known[1] /\ s.capture.before=s.live[1]
 /\ s.capture.prev=s.currentInputs[1]
Reject == /\ s.phase \in {"preview","ready"} /\ ~FreshCapture
 /\ s'=[s EXCEPT !.phase="idle", !.approved=FALSE, !.rejected=TRUE]
Admit == /\ s.phase="ready" /\ s.approved
 /\ (FreshCapture \/ Policy="staleAdmission"
      \/ (Policy="frontierOnly" /\ s.frame=s.known[1]))
 /\ LET rec==[s.capture EXCEPT
          !.prev=IF Policy="consumeAllHeads" THEN s.known[1] ELSE @,
          !.after=IF Policy="wrongInverse" /\ s.slot="S" THEN <<0,@[2]>> ELSE @]
    IN s'=[s EXCEPT !.records[s.slot]=rec, !.bindings[s.slot]=s.capture,
       !.known[1]=@ \cup {s.slot}, !.live[1]=rec.after, !.currentInputs[1]={s.slot}, !.phase="pending"]
Encode == /\ s.phase="pending" /\ s'=[s EXCEPT !.phase="encoded"]
CanInstall == s.phase="encoded" /\ Dependencies(s.slot) \subseteq Complete(1)
Install == /\ CanInstall
 /\ s'=[s EXCEPT !.objects[1]=@ \cup {s.slot},
       !.actions[1]=IF Policy="splitAction" THEN @ ELSE @ \cup {s.slot},
       !.records[s.slot]=IF Policy="lateRecapture"
            THEN [@ EXCEPT !.before=s.live[1]] ELSE @,
       !.phase="installed"]
CanPin(h) == Complete(h)#s.pin[h]
Pin(h) == /\ CanPin(h)
 /\ s'=[s EXCEPT !.pin[h]=Complete(h)]
EarlyPin == /\ Policy="earlyPin" /\ s.phase="encoded"
 /\ s'=[s EXCEPT !.pin[1]=@ \cup {s.slot}]
CanAck == s.phase="installed" /\ s.slot \in s.pin[1]
Ack == /\ CanAck
 /\ s'=[s EXCEPT !.acknowledged=@ \cup {s.slot}, !.phase="idle",
       !.live[1]=IF Policy="staleCompletion" THEN s.capture.after ELSE @]
AuthorRemote == /\ ~s.remoteMade
 /\ (IF Scenario="observing" THEN "U" \in s.known[2] ELSE s.known[2]={"A"})
 /\ LET before==s.live[2]
        after==CASE Scenario="competing" -> <<0,before[2]>>
                [] Scenario="disjoint" -> <<before[1],9>> [] OTHER -> <<2,before[2]>>
        rec==[parents |-> Rules!Maximal(s.records,s.known[2]),prev |-> s.currentInputs[2],
              target |-> IF Scenario="competing" THEN "A" ELSE "none",
              kind |-> IF Scenario="competing" THEN "undo" ELSE "forward",
              scope |-> "note",before |-> before,after |-> after]
    IN s'=[s EXCEPT !.records[Remote]=rec, !.bindings[Remote]=rec,
         !.objects[2]=@ \cup {Remote}, !.actions[2]=@ \cup {Remote},
         !.known[2]=@ \cup {Remote}, !.live[2]=after, !.currentInputs[2]={Remote}, !.remoteMade=TRUE]
CanReceive(h,a) == Policy#"stallReceive" /\ a \in (s.pin[1] \cup s.pin[2]) \ s.objects[h]
Receive(h,a) == /\ CanReceive(h,a)
 /\ s'=[s EXCEPT !.objects[h]=@ \cup {a}, !.actions[h]=@ \cup {a}]
CanApply(h,a) == a \in s.pin[h] \ s.known[h]
 /\ Dependencies(a) \subseteq s.known[h] /\ (h=2 \/ s.phase#"down")
ApplyReceived(h,a) == /\ CanApply(h,a)
 /\ LET hist==s.known[h] \cup {a}
        ready==hist \subseteq s.pin[h] \/ Policy="mergeUnsealed"
    IN s'=[s EXCEPT !.known[h]=hist,
       \* Learn the remote action during an unsealed local admission, but keep
       \* the local presentation pin until all merge inputs are durable.
       !.live[h]=IF ready THEN Value(hist) ELSE @,
       !.currentInputs[h]=IF ready THEN Represented(hist) ELSE @]
\* A local edit may pin its head. It still needs generation-fenced reduction
\* after settlement, even if no additional remote notification ever arrives.
CanReconcile(h) == Policy#"noLocalReduction"
 /\ (h=2 \/ s.phase \in {"idle","preview","ready"})
 /\ s.known[h] \subseteq s.pin[h]
 /\ (s.live[h]#Value(s.known[h]) \/ s.currentInputs[h]#Represented(s.known[h]))
ReconcileCurrent(h) == /\ CanReconcile(h)
 /\ s'=[s EXCEPT !.live[h]=Value(s.known[h]), !.currentInputs[h]=Represented(s.known[h])]
Crash == /\ ~s.crashed /\ s.phase#"down"
 /\ s'=[s EXCEPT !.crashed=TRUE, !.phase="down", !.approved=FALSE,
                  !.inverseCut="R" \in s.objects[1] /\ "R" \notin s.acknowledged,
                  !.frame={}, !.known[1]={}, !.currentInputs[1]={}, !.live[1]= <<0,7>>]
CanRecover == s.phase="down" /\ s.pin[1]=Complete(1)
Recover == /\ CanRecover
 /\ s'=[s EXCEPT !.known[1]=s.pin[1], !.live[1]=Value(s.pin[1]),
                     !.currentInputs[1]=Represented(s.pin[1]),
                     !.phase="idle", !.recovered=TRUE]
Progress == Encode \/ Install \/ Ack \/ Recover
 \/ (\E h \in Hosts: Pin(h) \/ ReconcileCurrent(h)
                  \/ (\E a \in Ids: Receive(h,a) \/ ApplyReceived(h,a)))
Next == Prepare \/ Approve \/ Reject \/ Admit \/ AuthorRemote \/ Crash \/ EarlyPin \/ Progress
Spec == Init /\ [][Next]_vars
\* Every safe Progress step consumes finite work (six slots, one crash).
\* These are the actual action guards above, not an assumed ability to advance.
ProgressEnabled == s.phase="pending" \/ CanInstall \/ CanAck \/ CanRecover
 \/ (\E h \in Hosts: CanPin(h) \/ CanReconcile(h)
                  \/ (\E a \in Ids: CanReceive(h,a) \/ CanApply(h,a)))
\* Every branch changes s. Spell out aggregate WF with shared guards to avoid
\* TLC's expensive ENABLED construction over the entire record. No fair user
\* approval is added; all admitted/transport work is finite in this fixture.
FairSpec == Spec /\ (<>[]ProgressEnabled => []<>(<<Progress>>_vars))
TypeOK == /\ s.known \in [Hosts -> SUBSET Ids] /\ s.objects \in [Hosts -> SUBSET Ids]
 /\ s.actions \in [Hosts -> SUBSET Ids] /\ s.pin \in [Hosts -> SUBSET Ids]
 /\ s.currentInputs \in [Hosts -> SUBSET Ids]
 /\ s.live \in [Hosts -> ({0,1,2} \X {7,9})]
ImmutableMeaning == \A a \in s.known[1] \cup s.known[2] \cup s.objects[1] \cup s.objects[2]:
 s.records[a]=s.bindings[a]
AcknowledgedComplete == s.acknowledged \subseteq Complete(1)
PinnedComplete == \A h \in Hosts: s.pin[h] \subseteq Complete(h)
WholeGroup == \A h \in Hosts: s.objects[h]=s.actions[h]
DisjointTitleSurvives == Scenario="disjoint" => \A h \in Hosts:
 "E" \in s.known[h] /\ s.currentInputs[h]=Represented(s.known[h]) => s.live[h][2]=9
OverlapHasBothAlternatives == Scenario="overlap" => \A h \in Hosts:
 {"U","E"} \subseteq s.known[h] /\ "R" \notin s.known[h]
 => Heads(s.known[h])={"U","E"}
 /\ (s.currentInputs[h]=Represented(s.known[h]) => s.live[h]= <<2,7>>)
ActualInverse == "S" \in s.objects[1] => s.records["S"].after[1]=s.records["R"].before[1]
InverseIsVisible == \A h \in Hosts: "S" \in s.known[h]
 /\ Remote \in Rules!Ancestors(s.records,"R")
 => s.live[h][1]=s.records["R"].before[1]
\* An inverse restores its recorded input, not an unconditional future Current.
\* If E observes U but S has not observed E, S's return to U's unchanged body
\* must merge with E, retaining E's later change rather than forcing S's zero.
LaterEditSurvivesInverse == Scenario="observing" => \A h \in Hosts:
 {"S","E"} \subseteq s.known[h] /\ "E" \notin Rules!Ancestors(s.records,"S")
 /\ s.currentInputs[h]=Represented(s.known[h])
 => s.live[h][1]=2
CurrentMatchesItsInputs == \A h \in Hosts: (h=2 \/ s.phase#"down") =>
 s.currentInputs[h] \subseteq s.known[h] /\ s.live[h]=Value(s.currentInputs[h])
DerivedInputsDurable == \A h \in Hosts: Cardinality(s.currentInputs[h])>1
 => s.currentInputs[h] \subseteq s.pin[h]
CompetingNeedsReview == Scenario="competing" /\ {"U","V"} \subseteq s.known[1]
 /\ "R" \notin s.known[1] => Mode(s.known[1],"redo")="review"
ObservedEditBlocksOldRedo == Scenario="observing" /\ {"U","E"} \subseteq s.known[1]
 => "U" \notin Candidates(s.known[1],"redo")
Safety == ImmutableMeaning /\ AcknowledgedComplete /\ PinnedComplete /\ WholeGroup
 /\ DisjointTitleSurvives /\ OverlapHasBothAlternatives /\ ActualInverse
 /\ CompetingNeedsReview /\ ObservedEditBlocksOldRedo /\ InverseIsVisible
 /\ CurrentMatchesItsInputs /\ LaterEditSurvivesInverse /\ DerivedInputsDurable
ExactAdmission == [][s.phase="ready" /\ s'.phase="pending" =>
 FreshCapture /\ s.approved]_vars
UnchosenHeadsSurvive == [][s.phase="ready" /\ s'.phase="pending" =>
 Heads(s.known[1]) \ s.capture.prev \subseteq (Heads(s.known[1]))']_vars
CompletionDoesNotOverwrite == [][s'.acknowledged#s.acknowledged => s'.live=s.live]_vars
EventualAgreement == <>[](s.phase#"down" /\ s.live[1]=s.live[2])
NeverCompletedOverlappingInverse == ~(Scenario="overlap" /\ s.recovered
 /\ s.inverseCut
 /\ {"U","E","R","S"} \subseteq s.pin[1] \cap s.pin[2]
 /\ s.records["R"].before= <<2,7>> /\ s.records["S"].after= <<2,7>>)
NeverKeptMergedTitle == ~(Scenario="disjoint" /\ s.recovered
 /\ {"U","E","R","S"} \subseteq s.pin[1] \cap s.pin[2] /\ s.live[1][2]=9)
NeverRetainedCompetingSibling == ~(Scenario="competing" /\ s.recovered
 /\ {"U","V","R","S"} \subseteq s.pin[1] \cap s.pin[2]
 /\ s.records["V"].target="A" /\ s.records["R"].target="U")
NeverRejectedChangedFrontier == ~s.rejected
NeverChangedCurrentWithoutHistory == ~(s.phase \in {"preview","ready"}
 /\ s.frame=s.known[1] /\ s.capture.before#s.live[1])
NeverLearnedRemoteWhileUnsealed == ~(s.phase \in {"pending","encoded"}
 /\ "E" \in s.known[1] /\ "U" \notin s.pin[1] /\ s.currentInputs[1]={"U"})
NeverRebuiltInstalledWithoutAck == ~(s.recovered /\ "U" \in s.known[1]
 /\ "U" \notin s.acknowledged)
=============================================================================
