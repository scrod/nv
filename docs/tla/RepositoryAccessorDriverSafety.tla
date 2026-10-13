-------------------- MODULE RepositoryAccessorDriverSafety --------------------
EXTENDS Naturals, FiniteSets

\* RepositoryRoot/RepositoryTransport: reserve, enter, effect, return and consume
\* are distinct turns. One initial outgoing object and one later local save share
\* the driver with one late incoming object. Exact bytes, native final barriers
\* and SQL acceptance are inputs qualified by their executable/model companions.
\* Scenario selects one independently scheduled environmental interruption.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "earlyRelease", "wrongRoot", "staleReceipt",
                   "advanceFailed", "onlyHint", "lostOwnerWake"}
 /\ Scenario \in {"steady", "move", "close", "restart", "busy", "failure"}
Objects == {0, 1}
VARIABLE s
vars == <<s>>
Init == s = [root |-> "active", generation |-> 0, lease |-> TRUE,
 phase |-> "idle", work |-> "none", object |-> 0, captured |-> 0,
 actual |-> "original", effect |-> FALSE, success |-> FALSE, input |-> FALSE,
 publication |-> TRUE, discovery |-> TRUE, waiting |-> FALSE,
 retained |-> {0}, installed |-> {}, acknowledged |-> {}, visible |-> FALSE,
 accepted |-> FALSE, effects |-> 0, save |-> IF Scenario="busy" THEN "busy" ELSE "idle", interrupted |-> FALSE,
 moved |-> FALSE, failed |-> FALSE, emptyFinished |-> FALSE,
 savedWhileEntered |-> FALSE, waited |-> FALSE, resumed |-> FALSE,
 issued |-> FALSE, issuedGeneration |-> 0, replacementEffects |-> {}]

StartPublication == /\ s.root="active" /\ s.phase="idle" /\ s.publication
 /\ s.retained \ s.acknowledged # {}
 /\ \E object \in s.retained \ s.acknowledged:
    s'=[s EXCEPT !.phase="requested", !.work="publish", !.object=object,
      !.captured=s.generation, !.effect=FALSE, !.success=FALSE,
      !.publication=FALSE, !.issued=FALSE]
EndPublicationPass == /\ s.root="active" /\ s.phase="idle" /\ s.publication
 /\ s.retained=s.acknowledged /\ s'=[s EXCEPT !.publication=FALSE]
\* Register the store wait, then let its actual settlement wake this demand.
WaitForStore == /\ s.root="active" /\ s.phase="idle" /\ s.discovery
 /\ s.save="busy" /\ s'=[s EXCEPT !.waiting=TRUE, !.discovery=FALSE, !.waited=TRUE]
StartDiscovery == /\ s.root="active" /\ s.phase="idle" /\ s.discovery
 /\ s.save#"busy" /\ ~s.publication
 /\ s'=[s EXCEPT !.phase="requested", !.work="discover", !.captured=s.generation,
      !.input=s.visible, !.effect=FALSE, !.success=FALSE, !.discovery=FALSE,
      !.issued=FALSE, !.resumed=@ \/ s.waited]

\* The OS may supply the moved original or a now-replaced pathname. The actual
\* reference and physical owner check, rather than the old requested path, decide.
Enter(actual) == /\ s.phase="requested" /\ actual \in {"original", "replacement"}
 /\ (actual="replacement" => s.moved /\ s.captured#s.generation)
 /\ s'=[s EXCEPT !.phase="entered", !.actual=actual]
Effect == /\ s.phase="entered" /\ ~s.effect
 /\ LET applies == s.actual="original" \/ Policy="wrongRoot"
        failing == Scenario="failure" /\ ~s.failed
        ok == applies /\ ~failing
    IN s'=[s EXCEPT !.effect=TRUE, !.success=ok,
      !.failed=@ \/ failing,
      !.installed=IF ok /\ s.work="publish" /\ s.actual="original"
                   THEN @ \union {s.object} ELSE @,
      !.replacementEffects=IF ok /\ s.actual="replacement" THEN @ \union {s.work} ELSE @,
      !.accepted=@ \/ (ok /\ s.work="discover" /\ s.input),
      !.effects=IF ok /\ s.work="discover" /\ s.input /\ ~s.accepted THEN @+1 ELSE @]
Return == /\ s.phase="entered" /\ s.effect
 /\ s'=[s EXCEPT !.phase="returned"]
\* A failed/stale completion retains the same outgoing bytes for an exact retry.
Finish == /\ s.phase="returned"
 /\ LET applicable == s.root="active" /\ s.captured=s.generation
        receipt == s.success /\ (applicable \/ Policy="staleReceipt")
        advance == receipt \/ (Policy="advanceFailed" /\ ~s.success)
        acknowledged == IF s.work="publish" /\ advance THEN s.acknowledged \union {s.object} ELSE s.acknowledged
    IN s'=[s EXCEPT !.phase="idle", !.work="none",
      !.acknowledged=acknowledged,
      !.publication=@ \/ (s.work="publish" /\ (~advance \/ s.retained \ acknowledged # {})),
      !.discovery=@ \/ (s.work="discover" /\ ~receipt),
      !.emptyFinished=@ \/ (s.work="discover" /\ receipt /\ ~s.input),
      !.issued=receipt, !.issuedGeneration=s.captured]

BeginSave == /\ s.save="idle" /\ s'=[s EXCEPT !.save="busy"]
CommitSave == /\ s.save="busy"
 /\ s'=[s EXCEPT !.retained=@ \union {1}, !.save="done", !.publication=TRUE,
      !.savedWhileEntered=@ \/ (s.phase="entered"),
      !.discovery=@ \/ (s.waiting /\ Policy#"lostOwnerWake"),
      !.waiting=IF Policy="lostOwnerWake" THEN @ ELSE FALSE]
Disclose == /\ ~s.visible /\ s'=[s EXCEPT !.visible=TRUE]
\* An ordinary bounded revisit is independent of provider hint delivery.
Revisit == /\ s.root="active" /\ ~s.discovery /\ ~s.waiting /\ ~s.accepted
 /\ Policy#"onlyHint" /\ s'=[s EXCEPT !.discovery=TRUE]

FenceAndMove == /\ Scenario="move" /\ ~s.interrupted /\ s.root="active"
 /\ s'=[s EXCEPT !.root="fenced", !.generation=@+1, !.interrupted=TRUE,
      !.moved=TRUE, !.issued=FALSE]
RevalidateOriginal == /\ s.root="fenced" /\ s.phase="idle"
 /\ s'=[s EXCEPT !.root="active", !.publication=TRUE, !.discovery=TRUE]
RequestClose == /\ Scenario="close" /\ ~s.interrupted /\ s.root="active"
 /\ s'=[s EXCEPT !.root="closing", !.generation=@+1, !.interrupted=TRUE,
      !.issued=FALSE, !.lease=IF Policy="earlyRelease" THEN FALSE ELSE @]
CloseAfterReturn == /\ s.root="closing" /\ s.phase="idle"
 /\ s'=[s EXCEPT !.root="closed", !.lease=FALSE]
\* Process termination releases its resources; reopening discards callbacks and
\* cursors while preserving independently committed bytes and membership.
Crash == /\ Scenario="restart" /\ ~s.interrupted
 /\ s'=[s EXCEPT !.root="closed", !.generation=@+1, !.interrupted=TRUE,
      !.phase="idle", !.work="none", !.lease=FALSE, !.acknowledged={},
      !.issued=FALSE, !.waiting=FALSE]
Reopen == /\ Scenario="restart" /\ s.root="closed"
 /\ s'=[s EXCEPT !.root="active", !.lease=TRUE, !.publication=TRUE, !.discovery=TRUE]

DriverStep == StartPublication \/ EndPublicationPass \/ WaitForStore \/ StartDiscovery
             \/ (\E actual \in {"original", "replacement"}: Enter(actual))
             \/ Effect \/ Return \/ Finish
Next == DriverStep \/ BeginSave \/ CommitSave \/ Disclose \/ Revisit
        \/ FenceAndMove \/ RevalidateOriginal \/ RequestClose \/ CloseAfterReturn
        \/ Crash \/ Reopen
Spec == Init /\ [][Next]_vars
\* Runnable local work and an entered OS accessor eventually run/return for these
\* conditional progress checks. Safety also covers an indefinitely stuck accessor.
FairSpec == Spec /\ WF_vars(DriverStep) /\ WF_vars(CommitSave) /\ WF_vars(Revisit)
 /\ WF_vars(RevalidateOriginal) /\ WF_vars(CloseAfterReturn) /\ WF_vars(Reopen)
TypeOK == /\ s.root \in {"active", "fenced", "closing", "closed"}
 /\ s.generation \in 0..1 /\ s.captured \in 0..1 /\ s.issuedGeneration \in 0..1
 /\ s.phase \in {"idle", "requested", "entered", "returned"}
 /\ s.work \in {"none", "publish", "discover"} /\ s.object \in Objects
 /\ s.actual \in {"original", "replacement"} /\ s.save \in {"idle", "busy", "done"}
 /\ s.retained \subseteq Objects /\ s.installed \subseteq Objects /\ s.acknowledged \subseteq Objects
 /\ s.replacementEffects \subseteq {"publish", "discover"} /\ s.effects \in 0..1
 /\ \A key \in {"lease", "effect", "success", "input", "publication", "discovery", "waiting",
  "visible", "accepted", "interrupted", "moved", "failed", "emptyFinished", "savedWhileEntered",
  "waited", "resumed", "issued"}: s[key] \in BOOLEAN
ResourcesThroughReturn == s.phase \in {"requested", "entered", "returned"} => s.lease
OriginalRootOnly == s.replacementEffects={}
ExactPublication == s.acknowledged \subseteq s.installed /\ s.installed \subseteq s.retained
ApplicableCompletion == s.issued => s.issuedGeneration=s.generation /\ s.root="active"
ReceiveOnce == s.effects=IF s.accepted THEN 1 ELSE 0
DurablePreserved == [][s.retained \subseteq s'.retained /\ s.installed \subseteq s'.installed
                       /\ (s.accepted => s'.accepted)]_vars
LateInputProgress == (s.visible /\ Scenario#"close") ~> s.accepted
SavedOutputProgress == (s.save="done" /\ Scenario#"close") ~> (1 \in s.acknowledged)
CloseSettles == s.root="closing" ~> (s.root="closed")
NeverLateAfterEmpty == ~(s.emptyFinished /\ s.visible /\ s.accepted)
NeverSaveWhileEntered == ~s.savedWhileEntered
NeverResumedAfterWait == ~(s.waited /\ s.resumed /\ s.accepted)
NeverRestartedThenComplete == ~(s.interrupted /\ Scenario="restart" /\ s.accepted /\ 1 \in s.acknowledged)
NeverMovedThenComplete == ~(s.moved /\ s.accepted /\ 1 \in s.acknowledged)
=============================================================================
