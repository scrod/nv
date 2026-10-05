------------------------ MODULE VerificationRecoverySafety ------------------------
EXTENDS Naturals, FiniteSets
\* Two independent verification operations, two retained inputs, two crashes.
\* SQLite admission/settlement commits are atomic inputs. Reads and final semantic
\* checks are separate. Finite diagnosis-write failures retain exact requests.
\* Source: Verification.swift, Database.checkingRetainedHistory, returning open.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "noAdmission", "earlySettlement", "settleSibling", "skipReplay"}
 /\ Scenario \in {"healthy", "bytes", "late"}
Tasks == 1..2
VARIABLE s
vars == <<s>>
Init == s = [pending |-> {}, pc |-> [t \in Tasks |-> "idle"],
 claimed |-> [t \in Tasks |-> 0], epoch |-> 1, down |-> FALSE,
 crashes |-> 0, failures |-> 2, liveDamage |-> FALSE, marker |-> FALSE,
 seen |-> FALSE, booting |-> FALSE, published |-> FALSE, blocked |-> FALSE,
 inspected |-> {}, cancelled |-> FALSE, siblingFinished |-> FALSE]
Admit(t) == /\ ~s.down /\ ~s.booting /\ ~s.marker /\ ~s.liveDamage
 /\ s.pc[t] = "idle" /\ t \notin s.pending /\ t \notin s.inspected
 /\ s' = [s EXCEPT !.pending = IF Policy="noAdmission" THEN @ ELSE @ \cup {t},
                  !.pc[t] = "read", !.claimed[t] = s.epoch]
Retry(t) == /\ ~s.down /\ ~s.marker /\ ~s.liveDamage
 /\ t \in s.pending /\ s.pc[t] = "idle"
 /\ s' = [s EXCEPT !.pc[t]="read", !.claimed[t]=s.epoch]
Read(t) == /\ ~s.down /\ ~s.liveDamage /\ s.pc[t]="read"
 /\ s' = [s EXCEPT !.pc[t] = IF t=1 /\ Scenario="bytes" THEN "damaged" ELSE "check",
    !.inspected=@ \cup {t},
    !.seen=@ \/ (t=1 /\ Scenario="bytes"),
    !.liveDamage=t=1 /\ Scenario="bytes",
    !.pending=IF Policy="earlySettlement" THEN @ \ {t} ELSE @,
    !.published=IF t=1 /\ Scenario="bytes" THEN FALSE ELSE @]
Check(t) == /\ ~s.down /\ ~s.liveDamage /\ s.pc[t]="check"
 /\ s' = [s EXCEPT !.pc[t] = IF t=1 /\ Scenario="late" THEN "damaged" ELSE "verified",
    !.seen=@ \/ (t=1 /\ Scenario="late"), !.liveDamage=t=1 /\ Scenario="late",
    !.published=IF t=1 /\ Scenario="late" THEN FALSE ELSE @]
Settle(t) == /\ ~s.down /\ ~s.liveDamage /\ s.pc[t]="verified"
 /\ s.claimed[t]=s.epoch
 /\ s' = [s EXCEPT !.pending=IF Policy="settleSibling" THEN {} ELSE @ \ {t},
                  !.pc[t]="done", !.siblingFinished=@ \/ t=2]
DiagnosisFails == /\ ~s.down /\ s.liveDamage /\ ~s.marker /\ s.failures>0
 /\ s' = [s EXCEPT !.failures=@-1]
RecordDamage == /\ ~s.down /\ s.liveDamage /\ ~s.marker
 /\ s' = [s EXCEPT !.marker=TRUE, !.pending=@ \ {1}, !.blocked=TRUE]
Cancel == /\ ~s.down /\ ~s.cancelled /\ s.pc[1] \in {"read","check","verified"}
 /\ s' = [s EXCEPT !.pc[1]="idle", !.cancelled=TRUE]
Crash == /\ ~s.down /\ s.crashes<2
 /\ s' = [s EXCEPT !.down=TRUE, !.crashes=@+1, !.liveDamage=FALSE,
    !.pc=[t \in Tasks |-> "idle"], !.published=FALSE, !.blocked=FALSE]
Reopen == /\ s.down
 /\ s' = [s EXCEPT !.down=FALSE, !.booting=TRUE, !.epoch=@+1,
                  !.blocked=s.marker]
Publish == /\ ~s.down /\ s.booting /\ ~s.marker /\ ~s.liveDamage /\ ~s.published
 /\ (Policy="skipReplay" \/ s.pending={})
 /\ s'=[s EXCEPT !.published=TRUE]
Next == (\E t \in Tasks: Admit(t) \/ Retry(t) \/ Read(t) \/ Check(t) \/ Settle(t))
 \/ DiagnosisFails \/ RecordDamage \/ Cancel \/ Crash \/ Reopen \/ Publish
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Reopen) /\ WF_vars(Publish)
 /\ WF_vars(DiagnosisFails) /\ WF_vars(RecordDamage)
 /\ (\A t \in Tasks: WF_vars(Retry(t)) /\ WF_vars(Read(t)) /\ WF_vars(Check(t)) /\ WF_vars(Settle(t)))
TypeOK == /\ s.pending \subseteq Tasks /\ s.inspected \subseteq Tasks
 /\ s.pc \in [Tasks -> {"idle","read","check","verified","damaged","done"}]
 /\ s.claimed \in [Tasks -> 0..3] /\ s.epoch \in 1..3 /\ s.crashes \in 0..2
 /\ s.failures \in 0..2
 /\ \A k \in {"down","liveDamage","marker","seen","booting","published","blocked","cancelled","siblingFinished"}: s[k] \in BOOLEAN
InspectionAdmitted == \A t \in Tasks: s.pc[t] \in {"read","check"} => t \in s.pending
DiscoveredProtected == s.seen => s.marker \/ 1 \in s.pending
ReopenPublicationGated == s.booting /\ s.published => ~s.seen /\ ~s.marker /\ s.pending={}
SiblingPreserved == [][s.pc[2]="verified" /\ s'.pc[2]="done" =>
 (1 \in s.pending => 1 \in s'.pending)]_vars
EventuallyOpensOrBlocks == (s.booting /\ ~s.down) ~> (s.published \/ s.blocked)
CancelledEventuallySettled == s.cancelled ~> (1 \notin s.pending \/ s.marker \/ s.blocked)
NeverFailedDiagnosisReplayed == ~(s.crashes>0 /\ s.failures=0 /\ s.marker /\ s.blocked)
NeverSiblingThenLateFailure == ~(s.siblingFinished /\ s.seen /\ ~s.marker /\ 1 \in s.pending)
NeverHealthyReplay == ~(Scenario="healthy" /\ s.crashes=2 /\ s.cancelled /\ s.published)
=============================================================================
