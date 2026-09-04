------------------- MODULE DeletionIntentTransportSafety -------------------
EXTENDS Naturals, FiniteSets
\* EXPERIMENT: a genuine intent targets birth 1. Bindings are already valid;
\* this does not solve the cross-host association gap. artifact represents
\* either a Trash entry with metadata or a standalone intent record. Its
\* delivery/retention is independent of source absence. No atomic cloud move
\* or guaranteed intermediate delivery is assumed. One fresh restore, one
\* crash. Local receipt/deletion barriers abstract successful WAL durability.
CONSTANT Policy
ASSUME Policy \in {"retain","forgetOnPurge","ignoreBirth"}
VARIABLE s
vars == <<s>>
Init == s = [source |-> 1, artifact |-> 0, captured |-> 0, receipt |-> 0,
 live |-> 1, wal |-> 1, accepted |-> FALSE, restored |-> FALSE,
 observedRestore |-> FALSE, down |-> FALSE, done |-> {}]
DeliverAbsence ==
 /\ "absence" \notin s.done
 /\ s' = [s EXCEPT !.source = 0, !.done = @ \cup {"absence"}]
DeliverArtifact ==
 /\ "artifact" \notin s.done
 /\ s' = [s EXCEPT !.artifact = 1, !.done = @ \cup {"artifact"}]
PurgeArtifact ==
 /\ s.artifact = 1 /\ "purge" \notin s.done
 /\ s' = [s EXCEPT !.artifact = 0, !.done = @ \cup {"purge"},
      !.receipt = IF Policy = "forgetOnPurge" THEN 0 ELSE @]
CaptureIntent ==
 /\ ~s.down /\ s.artifact = 1 /\ s.captured = 0
 /\ s' = [s EXCEPT !.captured = 1]
ReceiptBarrier ==
 /\ ~s.down /\ s.captured = 1 /\ ~s.accepted
 /\ s' = [s EXCEPT !.receipt = s.captured, !.accepted = TRUE]
Restore ==
 /\ ~s.restored
 /\ s' = [s EXCEPT !.source = 2, !.restored = TRUE]
ObserveRestore ==
 /\ ~s.down /\ s.source = 2 /\ ~s.observedRestore
 /\ s' = [s EXCEPT !.live = 2, !.wal = 2, !.observedRestore = TRUE]
ApplyDeletion ==
 /\ ~s.down /\ s.source = 0 /\ s.live # 0 /\ s.receipt = 1
 /\ (Policy = "ignoreBirth" \/ s.live = s.receipt)
 /\ s' = [s EXCEPT !.live = 0, !.wal = 0]
Crash ==
 /\ "crash" \notin s.done
 /\ s' = [s EXCEPT !.down = TRUE, !.live = 0, !.captured = 0,
                  !.done = @ \cup {"crash"}]
Recover ==
 /\ s.down
 /\ s' = [s EXCEPT !.down = FALSE, !.live = s.wal,
                  !.done = @ \cup {"recover"}]
Next == DeliverAbsence \/ DeliverArtifact \/ PurgeArtifact \/ CaptureIntent
 \/ ReceiptBarrier \/ Restore \/ ObserveRestore \/ ApplyDeletion \/ Crash \/ Recover
Spec == Init /\ [][Next]_vars
TypeOK ==
 /\ s.source \in 0..2 /\ s.live \in 0..2 /\ s.wal \in 0..2
 /\ s.artifact \in 0..1 /\ s.captured \in 0..1 /\ s.receipt \in 0..1
 /\ s.accepted \in BOOLEAN /\ s.restored \in BOOLEAN
 /\ s.observedRestore \in BOOLEAN /\ s.down \in BOOLEAN
 /\ s.done \subseteq {"absence","artifact","purge","crash","recover"}
NoForgottenAcceptedIntent == s.accepted => s.receipt = 1
NoOldIntentDeletesRestoration == s.observedRestore => s.wal = 2
NoUnexplainedDeletion == ~s.down /\ s.live = 0 => s.accepted
RecoveryUsesDurableState == ~s.down => s.live = s.wal
NeverAppliedAfterArtifactLoss == ~(~s.down /\ s.live = 0 /\ s.accepted /\ "purge" \in s.done)
NeverRecoveredReceipt == ~("recover" \in s.done /\ s.accepted /\ s.receipt = 1)
NeverMissedPurgedIntent == ~(s.done = {"absence","artifact","purge"} /\
                           ~s.accepted /\ s.captured = 0 /\ s.live = 1)
NeverPreservedRestoration == ~(s.observedRestore /\ s.accepted /\ s.source = 0 /\ s.live = 2)
=============================================================================
