------------------------ MODULE ReceiveResumptionSafety ------------------------
EXTENDS Naturals, FiniteSets

\* One retained, valid, dependency-complete receive on one owned collection.
\* Local saves change its checked prefix; all bytes/semantic checks are inputs.
\* Commit.swift: admission, commit and finish/defer are separate actions.
\* ReceivedObjects.swift: atomic condition/continuation registration, then a
\* separately scheduled continuation rechecks inFlight. LocalStore.swift:
\* quiesce owns its wait and either closes safely or returns busy.
\* MaxSaves bounds distinct admitted saves, representing finite interference.
\* Pending handles may remain indefinitely; their retry is a user action.
CONSTANTS Policy, MaxSaves
ASSUME MaxSaves \in 0..3
 /\ Policy \in {"safe", "lostWake", "splitWait", "waitPending", "waitAlways",
   "staleConsume", "earlyClose", "cancelDrops", "loseReady", "returnBusy",
   "lostQuitWake", "waitForQuit"}
VARIABLE s
vars == <<s>>
ActiveSave == s.save # "idle"
Quiescing == s.quit \in {"check", "asleep"}
Closed == s.quit = "closed"
Prefix == Cardinality(s.local)
Init == s = [receive |-> "capture", owned |-> TRUE, ready |-> TRUE,
 accepted |-> FALSE, captured |-> 0, tries |-> 0, interrupted |-> 0,
 save |-> "idle", issued |-> 0, local |-> {}, pending |-> FALSE,
 quit |-> "idle", cancelled |-> FALSE,
 \* Audit-only observations distinguish actually reached schedules.
 waited |-> FALSE, woke |-> FALSE, rewaited |-> FALSE,
 acceptedPrefix |-> 0, consumedPrefix |-> 0]

BeginSave == /\ ~Closed /\ ~Quiescing /\ ~ActiveSave /\ ~s.pending
 /\ s.issued < MaxSaves
 /\ s' = [s EXCEPT !.save="work", !.issued=@+1, !.pending=TRUE]
CommitSave == /\ ~Closed /\ s.save="work"
 /\ s' = [s EXCEPT !.local=@ \cup {s.issued}, !.save="completion"]
FailSave == /\ ~Closed /\ s.save="work"
 /\ s' = [s EXCEPT !.save="completion"]
FinishSave(ok) == /\ ~Closed /\ s.save="completion"
 /\ (ok => s.issued \in s.local)
 /\ s' = [s EXCEPT !.save="idle", !.pending=~ok,
   !.receive=IF @="asleep" /\ Policy#"lostWake" THEN "waitCheck" ELSE @,
   !.woke=@ \/ (s.receive="asleep" /\ Policy#"lostWake"),
   !.quit=IF @="asleep" THEN "check" ELSE @]
\* An explicit exact-identity retry can settle a committed pending handle.
RecoverPending == /\ ~Closed /\ ~Quiescing /\ ~ActiveSave /\ s.pending
 /\ s.issued \in s.local
 /\ s' = [s EXCEPT !.pending=FALSE]

Capture == /\ ~Closed /\ s.receive="capture" /\ s.ready
 /\ s' = [s EXCEPT !.captured=Prefix, !.receive="check"]
Validate == /\ ~Closed /\ s.receive="check" /\ s.captured=Prefix
 /\ s' = [s EXCEPT !.receive="consume"]
Restart == /\ ~Closed /\ s.receive \in {"check", "consume"}
 /\ s.captured#Prefix
 /\ s' = [s EXCEPT !.tries=IF @=0 THEN 1 ELSE 0,
   !.interrupted=@+1,
   !.receive=IF s.tries=0 THEN "capture"
             ELSE IF Policy="returnBusy" THEN "abandoned" ELSE "waitCheck",
   !.owned=IF s.tries=1 /\ Policy="returnBusy" THEN FALSE ELSE @,
   !.ready=IF s.tries=1 /\ Policy="loseReady" THEN FALSE ELSE @]
Consume == /\ ~Closed /\ s.receive="consume" /\ s.ready
 /\ (Policy="staleConsume" \/ s.captured=Prefix)
 /\ s' = [s EXCEPT !.accepted=TRUE, !.ready=FALSE, !.receive="finish",
   !.acceptedPrefix=Prefix, !.consumedPrefix=s.captured]
\* WaitCheck is one actor turn, including continuation registration.
WaitCheck == /\ ~Closed /\ s.receive="waitCheck"
 /\ LET wait == ActiveSave \/ (Policy="waitPending" /\ s.pending)
                 \/ Policy="waitAlways" \/ (Policy="waitForQuit" /\ Quiescing)
    IN s' = [s EXCEPT
      !.receive=IF wait THEN IF Policy="splitWait" THEN "register" ELSE "asleep"
                        ELSE "capture",
      !.waited=@ \/ wait, !.rewaited=@ \/ (wait /\ s.woke)]
RegisterLate == /\ ~Closed /\ s.receive="register"
 /\ s' = [s EXCEPT !.receive="asleep"]
FinishReceive == /\ ~Closed /\ s.receive="finish"
 /\ s' = [s EXCEPT !.receive="done", !.owned=FALSE,
   !.quit=IF @="asleep" /\ Policy#"lostQuitWake" THEN "check" ELSE @]
Cancel == /\ ~Closed /\ ~s.cancelled /\ s.owned
 /\ s' = [s EXCEPT !.cancelled=TRUE,
   !.receive=IF Policy="cancelDrops" THEN "abandoned" ELSE @,
   !.owned=IF Policy="cancelDrops" THEN FALSE ELSE @]

RequestQuit == /\ s.quit="idle"
 /\ s' = [s EXCEPT !.quit="check"]
QuitCheck == /\ s.quit="check"
 /\ s' = [s EXCEPT !.quit=
   IF Policy#"earlyClose" /\ (ActiveSave \/ s.owned) THEN "asleep"
   ELSE IF s.pending THEN "busy" ELSE "closed"]

ReceiveStep == Capture \/ Validate \/ Restart \/ Consume \/ WaitCheck
               \/ RegisterLate \/ FinishReceive
SaveWork == CommitSave \/ FailSave
SaveCompletion == \E ok \in BOOLEAN: FinishSave(ok)
Next == BeginSave \/ SaveWork \/ SaveCompletion \/ RecoverPending
        \/ ReceiveStep \/ Cancel \/ RequestQuit \/ QuitCheck
Spec == Init /\ [][Next]_vars
\* Runnable work eventually executes. A sleeping continuation has no enabled
\* ReceiveStep; only an actual completion notification makes it runnable.
FairSpec == Spec /\ WF_vars(ReceiveStep) /\ WF_vars(SaveWork)
                /\ WF_vars(SaveCompletion) /\ WF_vars(QuitCheck)
TypeOK == /\ s.receive \in {"capture","check","consume","waitCheck","register",
                            "asleep","finish","done","abandoned"}
 /\ s.save \in {"idle","work","completion"}
 /\ s.quit \in {"idle","check","asleep","busy","closed"}
 /\ s.issued \in 0..MaxSaves /\ s.local \subseteq 1..s.issued
 /\ s.captured \in 0..MaxSaves /\ s.tries \in 0..1
 /\ s.interrupted \in 0..MaxSaves
 /\ s.acceptedPrefix \in 0..MaxSaves /\ s.consumedPrefix \in 0..MaxSaves
 /\ \A k \in {"owned","ready","accepted","pending","cancelled","waited","woke","rewaited"}:
       s[k] \in BOOLEAN
CurrentValidation == s.accepted => s.consumedPrefix=s.acceptedPrefix
ReadyAccounted == s.ready = ~s.accepted
ClosedAfterOwnedWork == Closed => ~s.owned /\ ~ActiveSave /\ ~s.pending
ReceiveReservation == s.receive \notin {"done","abandoned"} => s.owned
CompletionHasAcceptance == s.receive="done" => s.accepted
AcceptedHistoryPreserved == [][s.local \subseteq s'.local /\ (s.accepted => s'.accepted)]_vars
ReceiveCompletes == <>(s.receive="done")
QuitSettles == Quiescing ~> (s.quit \in {"busy","closed"})
NeverExhaustedAndFinished == ~(s.interrupted>=2 /\ s.receive="done")
NeverFinishedWithoutWait == ~(s.interrupted>=2 /\ ~s.waited /\ s.receive="done")
NeverRewaited == ~(s.rewaited /\ s.receive="done")
NeverPendingAndFinished == ~(s.pending /\ s.interrupted>=2 /\ s.receive="done")
NeverCancelledAndClosed == ~(s.cancelled /\ Closed /\ s.accepted)
NeverQuitBusy == ~(s.quit="busy" /\ s.accepted)
=============================================================================
