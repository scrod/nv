------------------------ MODULE PrivateMaintenanceSafety ------------------------
EXTENDS Naturals, FiniteSets
\* Source: Maintenance.swift, Database.runVacuum and NVSQLMaintenance.c.
\* One connection, two optional jobs, one save and one process crash. SQLite
\* atomic commit/rollback and eventual return from interrupted SQL are inputs.
\* Mutex-protected registration/cancellation/retirement are atomic here. Timing,
\* encrypted bytes, SQL row preservation and pointer validity need executable tests.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "prestartInterrupt", "reuseToken", "earlyClose", "earlyAck", "wrongReopen"}
 /\ Scenario = "maintenance"
Jobs == 1..2
Token(j) == IF Policy="reuseToken" THEN 1 ELSE j
VARIABLE s
vars == <<s>>
Init == s = [owner |-> TRUE, down |-> FALSE, closing |-> FALSE, jobs |-> 0,
 vac |-> "idle", active |-> 0, registry |-> 0, cancelled |-> {},
 retired |-> {}, lateSent |-> {}, lateTouched |-> FALSE,
 sql |-> "idle", save |-> "idle", saveInterrupted |-> FALSE,
 committed |-> FALSE, acknowledged |-> FALSE, crashes |-> 0,
 reopened |-> FALSE, reopenedCommitted |-> FALSE, displayed |-> "E", contested |-> FALSE]
Reserve == /\ s.owner /\ ~s.closing /\ s.vac="idle" /\ s.jobs<2
 /\ s.save \in {"idle","done"}
 /\ s'=[s EXCEPT !.jobs=@+1, !.vac="prepared", !.active=s.jobs+1,
                       !.registry=Token(s.jobs+1)]
\* Preparation can suspend before SQL starts; an admitted save can use that turn.
StartVacuum == /\ s.owner /\ s.vac="prepared" /\ s.sql="idle"
 /\ s'=[s EXCEPT !.vac=IF s.active \in s.cancelled THEN "settled" ELSE "running",
                    !.sql=IF s.active \in s.cancelled THEN "idle" ELSE "vacuum"]
FinishVacuum == /\ s.vac="running" /\ s.owner
 /\ s'=[s EXCEPT !.vac="settled", !.sql="idle"]
Retire == /\ s.vac="settled" /\ s.sql="idle"
 /\ s'=[s EXCEPT !.retired=@ \cup {s.active}, !.registry=0,
                    !.active=0, !.vac="idle"]
AdmitSave == /\ s.owner /\ ~s.closing /\ s.save="idle"
 /\ s'=[s EXCEPT !.save="queued", !.cancelled=IF s.active=0 THEN @ ELSE @ \cup {s.active},
                    !.contested=@ \/ s.vac \in {"prepared","running"}]
StartSave == /\ s.owner /\ s.save="queued" /\ s.sql="idle"
 /\ s'=[s EXCEPT !.save="sql", !.sql="save",
                    !.acknowledged=IF Policy="earlyAck" THEN TRUE ELSE @]
\* A pre-start request records cancellation. Only the running VACUUM is interrupted.
CancelActive == /\ s.owner /\ s.active>0
 /\ s'=[s EXCEPT !.cancelled=@ \cup {s.active},
     !.saveInterrupted=@ \/ (Policy="prestartInterrupt" /\ s.sql="save")]
CancelRetired(j) == /\ s.owner /\ j \in s.retired /\ j \notin s.lateSent
 /\ s'=[s EXCEPT !.lateSent=@ \cup {j},
     !.lateTouched=@ \/ (s.registry=Token(j) /\ s.active # j),
     !.cancelled=IF s.registry=Token(j) /\ s.active>0 THEN @ \cup {s.active} ELSE @,
     !.saveInterrupted=@ \/ (Policy="prestartInterrupt" /\ s.registry=Token(j) /\ s.sql="save")]
CommitSave == /\ s.owner /\ s.save="sql" /\ s.sql="save"
 /\ s'=[s EXCEPT !.committed=TRUE, !.save="committed", !.sql="idle"]
Acknowledge == /\ s.owner /\ s.save="committed"
 /\ s'=[s EXCEPT !.save="done", !.acknowledged=TRUE]
RequestClose == /\ s.owner /\ ~s.closing
 /\ s'=[s EXCEPT !.closing=TRUE,
     !.cancelled=IF s.active=0 THEN @ ELSE @ \cup {s.active}]
Close == /\ s.owner /\ s.closing /\ s.sql="idle" /\ s.save \in {"idle","done"}
 /\ (s.registry=0 \/ Policy="earlyClose")
 /\ s'=[s EXCEPT !.owner=FALSE]
Crash == /\ s.owner /\ s.crashes=0
 /\ s'=[s EXCEPT !.owner=FALSE, !.down=TRUE, !.crashes=1,
     !.registry=0, !.active=0, !.vac="idle", !.sql="idle", !.closing=FALSE,
     !.save=IF s.committed THEN (IF s.acknowledged THEN "done" ELSE "committed") ELSE "idle"]
Reopen == /\ ~s.owner /\ (s.down \/ s.closing)
 /\ s'=[s EXCEPT !.owner=TRUE, !.down=FALSE, !.closing=FALSE, !.reopened=TRUE,
     !.reopenedCommitted=s.committed,
     !.displayed=IF Policy="wrongReopen" THEN "E" ELSE (IF s.committed THEN "F" ELSE "E")]
Next == Reserve \/ StartVacuum \/ FinishVacuum \/ Retire \/ AdmitSave
 \/ StartSave \/ CommitSave \/ Acknowledge \/ CancelActive
 \/ (\E j \in Jobs: CancelRetired(j)) \/ RequestClose \/ Close \/ Crash \/ Reopen
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(StartVacuum) /\ WF_vars(FinishVacuum) /\ WF_vars(Retire)
 /\ WF_vars(StartSave) /\ WF_vars(CommitSave) /\ WF_vars(Acknowledge)
 /\ WF_vars(Close) /\ WF_vars(Reopen)
TypeOK == /\ s.jobs \in 0..2 /\ s.active \in 0..2 /\ s.registry \in 0..2
 /\ s.vac \in {"idle","prepared","running","settled"}
 /\ s.sql \in {"idle","save","vacuum"}
 /\ s.save \in {"idle","queued","sql","committed","done"}
 /\ s.cancelled \subseteq Jobs /\ s.retired \subseteq Jobs /\ s.lateSent \subseteq Jobs
 /\ s.crashes \in 0..1 /\ s.displayed \in {"E","F"}
 /\ \A k \in {"owner","down","closing","saveInterrupted","committed","acknowledged","reopened","reopenedCommitted","contested","lateTouched"}: s[k] \in BOOLEAN
BorrowOwned == s.registry>0 => s.owner /\ ~s.down
SaveIsolation == ~s.saveInterrupted
LateCancellationScoped == ~s.lateTouched
AcknowledgmentDurable == s.acknowledged => s.committed
ReopenExact == s.reopened /\ s.reopenedCommitted => s.displayed="F"
RequiredEventuallySettles == s.save \in {"queued","sql","committed"} ~> (s.save="done" \/ s.down)
NeverContestedSaveRecovered == ~(s.contested /\ s.committed /\ s.acknowledged /\ s.crashes=1 /\ s.reopened /\ s.displayed="F")
NeverPrestartSaveThenLateCancel == ~(s.jobs=2 /\ s.save="done" /\ 1 \in s.lateSent /\ s.reopened)
=============================================================================
