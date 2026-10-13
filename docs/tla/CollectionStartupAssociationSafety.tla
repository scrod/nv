---------------- MODULE CollectionStartupAssociationSafety ----------------
EXTENDS Naturals, FiniteSets

\* CollectionStartup: checked publication, named waits and association readback
\* share one owner. SQL commit, callback and old accessor return remain separate.
\* Two physical roots and one finite save/disclosure/crash keep the product small.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "genericWait", "localWait", "lateWait", "stalePublish",
    "noReservation", "earlyRelease", "retarget", "forgetBinding", "dropHistory"}
 /\ Scenario \in {"ordinary", "unread", "retained", "late", "generic", "readback", "crash"}
Roots == {"A", "B"}
Stable == {"ready", "editable", "waiting"}
VARIABLE s
vars == <<s>>
Init == s = [mode |-> "ready", active |-> "A", binding |-> "A", leases |-> {"A"},
 attempt |-> 0, requested |-> FALSE, stage |-> "none", old |-> "none",
 effect |-> FALSE, effectRoot |-> "A", returned |-> FALSE, canceled |-> FALSE,
 history |-> {0}, save |-> "idle", acknowledged |-> FALSE, savedEntered |-> FALSE,
 pub |-> "none", captured |-> 0, cut |-> {0}, published |-> FALSE,
 publication |-> [issued |-> FALSE, captured |-> 0, actual |-> 0, checked |-> {0}, actualHistory |-> {0}],
 named |-> FALSE, unread |-> TRUE, disclosedUnread |-> FALSE, retained |-> Scenario="retained", disclosed |-> FALSE,
 proceeded |-> FALSE, waited |-> FALSE, lateGated |-> FALSE,
 offline |-> [used |-> FALSE, named |-> FALSE, unread |-> FALSE, held |-> FALSE, retained |-> FALSE, published |-> FALSE],
 storage |-> TRUE, readFailed |-> FALSE, readRecovered |-> FALSE, failures |-> 0,
 crashed |-> FALSE, restarted |-> FALSE, crashBinding |-> "A"]

\* The actual driver owns its entered accessor independently of the SQL lane.
EnterOld == /\ s.old="none" /\ ~s.requested /\ s.mode \in Stable
 /\ s'=[s EXCEPT !.old="entered"]
OldEffect == /\ s.old="entered" /\ ~s.effect
 /\ s'=[s EXCEPT !.effect=TRUE,
      !.effectRoot=IF Policy="retarget" /\ s.binding="B" THEN "B" ELSE "A"]
ReturnOld == /\ s.old="entered" /\ s.effect
 /\ s'=[s EXCEPT !.old="returned", !.returned=TRUE]
BeginSave == /\ s.save="idle" /\ s.mode="editable"
 /\ s'=[s EXCEPT !.save="pending"]
CommitSave == /\ s.save="pending" /\ s.mode \in Stable \union {"publishing"}
 /\ s'=[s EXCEPT !.save="done", !.history=@ \union {1}, !.acknowledged=TRUE,
      !.savedEntered=@ \/ s.old="entered"]

\* Disclosure can be late or refer to bytes already retained by this private owner.
Disclose == /\ ~s.disclosed /\ s.mode \in Stable
 /\ (Scenario="late" => s.published)
 /\ LET named == Scenario \in {"unread", "retained", "late"}
        qualifies == (named \/ Policy="genericWait") /\ s.unread
          /\ (~s.retained \/ Policy="localWait")
        wait == qualifies /\ (~s.published \/ Policy="lateWait")
    IN s'=[s EXCEPT !.named=named, !.disclosed=TRUE, !.disclosedUnread=s.unread,
      !.mode=IF wait THEN "waiting" ELSE @, !.waited=@ \/ wait,
      !.lateGated=@ \/ (wait /\ s.published)]
BytesReadable == /\ s.named /\ s.unread /\ s'=[s EXCEPT !.unread=FALSE]
ReclassifyReadable == /\ s.mode="waiting" /\ ~s.unread /\ s.old # "entered"
 /\ s'=[s EXCEPT !.mode=IF s.published THEN "editable" ELSE "ready"]
\* A busy accessor permits local admission from the original exact disclosure.
\* It grants no provider effect and preserves the old root through actual return.
WorkOffline == /\ s.mode="waiting" /\ (s.unread \/ s.old="entered")
 /\ s'=[s EXCEPT !.mode=IF s.published THEN "editable" ELSE "ready", !.proceeded=TRUE,
      !.offline=[used |-> TRUE, named |-> s.named, unread |-> s.disclosedUnread, held |-> s.old="entered",
        retained |-> s.retained, published |-> s.published]]

\* preparePublication freezes a checked local view; publish reserves adoption
\* through its real synchronous callback. A save can make an earlier cut stale.
Capture == /\ s.mode \in {"ready", "editable"} /\ s.pub # "callback"
 /\ s'=[s EXCEPT !.pub="captured", !.captured=s.attempt, !.cut=s.history]
BeginPublish == /\ s.mode \in {"ready", "editable"} /\ s.pub="captured"
 /\ s'=[s EXCEPT !.pub="callback", !.mode=IF Policy="noReservation" THEN @ ELSE "publishing"]
FinishPublish == /\ s.pub="callback" /\ s.mode # "crashed"
 /\ LET valid == (s.captured=s.attempt /\ s.cut=s.history) \/ Policy="stalePublish"
    IN s'=[s EXCEPT !.pub="none", !.published=@ \/ valid,
      !.mode=IF s.mode \in {"ready", "editable", "publishing"}
         THEN IF valid \/ s.published THEN "editable" ELSE "ready" ELSE @,
      !.publication=IF valid THEN [issued |-> TRUE, captured |-> s.captured, actual |-> s.attempt,
           checked |-> s.cut, actualHistory |-> s.history] ELSE @]

\* reserveTransition prevents repeated acquisition and waits for admitted saves.
BeginReopen == /\ ~s.requested /\ s.save # "pending" /\ s.mode \in Stable
 /\ (s.pub # "callback" \/ Policy="noReservation")
 /\ s'=[s EXCEPT !.mode="transition", !.requested=TRUE, !.stage="acquire"]
AcquireTarget == /\ s.mode="transition" /\ s.stage="acquire"
 /\ s'=[s EXCEPT !.leases=@ \union {"B"}, !.stage="binding"]
CancelPreparation == /\ s.mode="transition" /\ s.stage="binding"
 /\ s'=[s EXCEPT !.mode=IF s.published THEN "editable" ELSE "ready",
      !.stage="none", !.leases=@ \ {"B"}, !.canceled=TRUE]
CommitBinding == /\ s.mode="transition" /\ s.stage="binding"
 /\ s'=[s EXCEPT !.binding=IF Policy="forgetBinding" THEN @ ELSE "B", !.stage="readback"]
FailReadback == /\ Scenario="readback" /\ s.stage="readback" /\ s.storage /\ s.failures<2
 /\ s'=[s EXCEPT !.storage=FALSE, !.readFailed=TRUE, !.failures=@+1]
RecoverStorage == /\ ~s.storage /\ s'=[s EXCEPT !.storage=TRUE, !.readRecovered=TRUE]
Readback == /\ s.mode="transition" /\ s.stage="readback" /\ s.storage
 /\ IF s.binding="B" \/ Policy="forgetBinding"
       THEN s'=[s EXCEPT !.stage="settling"]
       ELSE s'=[s EXCEPT !.mode=IF s.published THEN "editable" ELSE "ready",
             !.stage="none", !.leases=@ \ {"B"}]
CancelCommitted == /\ s.mode="transition" /\ s.stage \in {"readback", "settling"} /\ ~s.canceled
 /\ s'=[s EXCEPT !.canceled=TRUE]
Adopt == /\ s.mode="transition" /\ s.stage="settling"
 /\ (s.old # "entered" \/ Policy="earlyRelease")
 /\ s'=[s EXCEPT !.active="B", !.attempt=@+1, !.leases=@ \ {"A"}, !.stage="none",
      !.mode=IF s.published THEN "editable" ELSE "ready",
      !.history=IF Policy="dropHistory" THEN {0} ELSE @]

\* Process death ends that process's accessor and ownership together. Surviving
\* SQL membership and binding, rather than a lost callback, select reopening.
Crash == /\ Scenario="crash" /\ ~s.crashed /\ s.mode # "crashed"
 /\ s'=[s EXCEPT !.mode="crashed", !.leases={}, !.old="none", !.pub="none",
      !.save=IF s.save="pending" THEN "idle" ELSE @, !.stage="none",
      !.crashed=TRUE, !.crashBinding=s.binding]
Restart == /\ s.mode="crashed" /\ ~s.restarted
 /\ s'=[s EXCEPT !.mode="ready", !.active=s.binding, !.leases={s.binding},
      !.attempt=@+1, !.published=FALSE, !.proceeded=FALSE, !.restarted=TRUE]

Next == EnterOld \/ OldEffect \/ ReturnOld \/ BeginSave \/ CommitSave \/ Disclose
 \/ BytesReadable \/ ReclassifyReadable \/ WorkOffline \/ Capture \/ BeginPublish \/ FinishPublish
 \/ BeginReopen \/ AcquireTarget \/ CancelPreparation \/ CommitBinding \/ FailReadback
 \/ RecoverStorage \/ Readback \/ CancelCommitted \/ Adopt \/ Crash \/ Restart
Spec == Init /\ [][Next]_vars
\* Progress assumes finite storage failure and eventual return of entered OS work.
\* It makes no promise that an indefinitely blocked OS call returns or a user chooses.
FairSpec == Spec /\ WF_vars(OldEffect) /\ WF_vars(ReturnOld) /\ WF_vars(RecoverStorage)
 /\ WF_vars(Readback) /\ WF_vars(Adopt) /\ WF_vars(Restart) /\ WF_vars(FinishPublish)

TypeOK == /\ s.mode \in Stable \union {"publishing", "transition", "crashed"}
 /\ s.active \in Roots /\ s.binding \in Roots /\ s.leases \subseteq Roots
 /\ s.attempt \in 0..2 /\ s.stage \in {"none", "acquire", "binding", "readback", "settling"}
 /\ s.history \subseteq {0,1} /\ s.pub \in {"none", "captured", "callback"}
 /\ s.old \in {"none", "entered", "returned"} /\ s.save \in {"idle", "pending", "done"}
 /\ s.failures \in 0..2 /\ s.storage \in BOOLEAN
ResourcesThroughReturn == s.old="entered" => "A" \in s.leases
OriginalAccessorOnly == s.effect => s.effectRoot="A"
StableBinding == s.mode \in Stable => s.active=s.binding
DurableHistory == s.acknowledged => 1 \in s.history
ExactPublication == s.publication.issued =>
 s.publication.captured=s.publication.actual /\ s.publication.checked=s.publication.actualHistory
PublicationReservation == s.pub="callback" => s.mode="publishing"
ExactOffline == s.offline.used => s.offline.named /\ s.offline.unread /\ ~s.offline.retained /\ ~s.offline.published
LateEditingPreserved == ~s.lateGated
BindingProgress == (s.mode="transition" /\ s.binding="B") ~> (s.active="B" /\ s.mode \in Stable)
NeverSavedEntered == ~s.savedEntered
NeverWaited == ~s.waited
NeverOfflineWhileEntered == ~(s.offline.used /\ s.offline.held)
NeverReadRecovered == ~s.readRecovered
NeverRepeatedReadFailure == s.failures<2
NeverRestartedCommitted == ~(s.restarted /\ s.crashBinding="B")
NeverCanceledCommitted == ~(s.canceled /\ s.binding="B" /\ s.active="B" /\ s.mode \in Stable)
=============================================================================
