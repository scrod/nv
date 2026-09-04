---------------------- MODULE BindingIntentComposition ----------------------
EXTENDS Naturals, FiniteSets
\* EXPERIMENT, not adopted policy. Actual handshake actions feed receiver B's
\* alias admission; no proof=same oracle. Sender A deletes birth 1. B keeps
\* UUID 2. "actual" is assertion-only provenance, not an implementation key.
\* One edit, known or hidden restoration, receiver crash, and artifact purge.
\* Binding execution precedes lifecycle execution to avoid an irrelevant
\* message-history x lifecycle product. This does NOT cover their overlap.
CONSTANTS Policy, Scenario
Policies == {"guarded","tagBinding","unfencedBinding","reuseBirth",
 "volatileReceipt","trashOnly","earlyCleanup","noPublicationFence",
 "noEditPreservation","deferBinding"}
ASSUME Policy \in Policies
ASSUME Scenario \in {"clean","copy","retarget","relay","stale","offline",
                     "lifecycle","hiddenRestore"}
BindingPolicy == CASE Policy = "tagBinding" -> "tag"
 [] Policy = "unfencedBinding" -> "challenge"
 [] Policy = "deferBinding" -> "defer" [] OTHER -> "fenced"
BindingScenario == IF Scenario \in {"lifecycle","hiddenRestore"} THEN "clean" ELSE Scenario
VARIABLES b, s
H == INSTANCE LiveBindingHandshake WITH Policy <- BindingPolicy, Scenario <- BindingScenario
vars == <<b,s>>
Note(actual) == [alive |-> TRUE, actual |-> actual, birth |-> 1, rev |-> 1,
 saved |-> {}, consumed |-> FALSE, aliases |-> {2}]
Init == H!Init /\ s = [started |-> FALSE, down |-> FALSE, generation |-> 0,
 note |-> Note(H!InitialEndpoint), wal |-> Note(H!InitialEndpoint),
 checkpoint |-> Note(H!InitialEndpoint), checkpointed |-> FALSE,
 issued |-> FALSE, outbox |-> FALSE, artifact |-> FALSE, received |-> FALSE,
 receipt |-> FALSE, ack |-> FALSE, absent |-> FALSE, planned |-> FALSE,
 capturedGeneration |-> 0, captured |-> Note(H!InitialEndpoint),
 deletedActuals |-> {}, protectedEdit |-> FALSE, durableAlias |-> FALSE,
 done |-> {}]
BindingStep == ~s.started /\ H!Next /\ UNCHANGED s
BindingProgress == ~s.started /\ (H!Protocol \/ H!LatestDelivery \/ H!Park) /\ UNCHANGED s
FinishBinding ==
 /\ ~s.started /\ (b.accepted \/ b.parked)
 /\ LET n == [Note(b.endpoint) EXCEPT !.aliases = IF b.accepted THEN {1,2} ELSE {2}]
    IN /\ s' = [s EXCEPT !.started = TRUE, !.note = n,
           !.wal = Note(b.endpoint), !.checkpoint = Note(b.endpoint)]
       \* Garbage-collect protocol views after projecting its actual outcome.
       \* Later actions cannot consult discarded messages or restart binding.
       /\ b' = H!InitialState
IssueIntent ==
 /\ s.started /\ ~s.issued
 /\ s' = [s EXCEPT !.issued = TRUE, !.outbox = TRUE]
PublishArtifact ==
 /\ s.started /\ s.outbox /\ ~s.artifact
 /\ (Policy # "trashOnly" \/ "purge" \notin s.done)
 /\ s' = [s EXCEPT !.artifact = TRUE]
PurgeArtifact ==
 /\ s.started /\ s.artifact /\ "purge" \notin s.done
 /\ s' = [s EXCEPT !.artifact = FALSE, !.done = @ \cup {"purge"}]
Receive ==
 /\ s.started /\ ~s.down /\ s.artifact /\ ~s.received
 /\ s' = [s EXCEPT !.received = TRUE]
ReceiptBarrier ==
 /\ s.started /\ ~s.down /\ s.received /\ ~s.receipt
 /\ s' = [s EXCEPT !.receipt = TRUE]
Acknowledge ==
 /\ s.started /\ s.receipt /\ ~s.ack
 /\ s' = [s EXCEPT !.ack = TRUE]
ReleaseOutbox ==
 /\ s.started /\ s.outbox
 /\ (s.ack \/ (Policy = "earlyCleanup" /\ s.checkpointed))
 /\ s' = [s EXCEPT !.outbox = FALSE]
Disappear ==
 /\ s.started /\ ~s.absent
 /\ s' = [s EXCEPT !.absent = TRUE]
Barrier ==
 /\ s.started /\ ~s.down /\ s.note # s.wal
 /\ s' = [s EXCEPT !.wal = s.note,
      !.protectedEdit = @ \/ s.note.rev = 2 \/ 2 \in s.note.saved,
      !.durableAlias = @ \/ s.note.aliases = {1,2}]
Checkpoint ==
 /\ s.started /\ ~s.down /\ s.note = s.wal
 /\ (~s.checkpointed \/ s.checkpoint # s.wal)
 /\ s' = [s EXCEPT !.checkpoint = s.wal, !.checkpointed = TRUE]
PlanDelete ==
 /\ s.started /\ ~s.down /\ ~s.planned /\ s.absent /\ s.receipt
 /\ s.note.alive /\ ~s.note.consumed /\ s.note.birth = 1
 /\ s.note.aliases = {1,2}
 /\ s' = [s EXCEPT !.planned = TRUE, !.captured = s.note,
                  !.capturedGeneration = s.generation]
PublishDelete ==
 /\ s.started /\ ~s.down /\ s.planned
 /\ (Policy = "noPublicationFence" \/ s.capturedGeneration = s.generation)
 /\ LET saved == s.captured.saved \cup
          IF s.captured.rev = 2 /\ Policy # "noEditPreservation" THEN {2} ELSE {}
    IN s' = [s EXCEPT !.planned = FALSE, !.generation = @ + 1,
      !.note = [s.captured EXCEPT !.alive = FALSE, !.consumed = TRUE, !.saved = saved],
      !.deletedActuals = @ \cup {s.note.actual}]
RejectStalePlan ==
 /\ s.started /\ ~s.down /\ s.planned /\ s.capturedGeneration # s.generation
 /\ s' = [s EXCEPT !.planned = FALSE]
Edit ==
 /\ s.started /\ ~s.down /\ s.note.alive /\ "edit" \notin s.done
 /\ s' = [s EXCEPT !.note.rev = 2, !.generation = @ + 1,
                  !.done = @ \cup {"edit"}]
RestoreKnown ==
 /\ s.started /\ ~s.down /\ "restore" \notin s.done
 /\ s' = [s EXCEPT !.note.alive = TRUE, !.note.actual = 3,
      !.note.birth = IF Policy = "reuseBirth" THEN 1 ELSE 3,
      !.note.rev = 3,
      !.note.saved = @ \cup IF s.note.rev = 2 THEN {2} ELSE {},
      !.generation = @ + 1, !.done = @ \cup {"restore"}]
\* An unobserved delete/restore cycle returns identical current observations.
\* Only hidden provenance changes. This action is an explicit ceiling test;
\* no policy may inspect actual to manufacture a missing restoration signal.
HiddenRestore ==
 /\ s.started /\ Scenario = "hiddenRestore" /\ s.note.alive
 /\ "restore" \notin s.done
 /\ s' = [s EXCEPT !.note.actual = 3, !.wal.actual = 3,
                  !.done = @ \cup {"restore"}]
Crash ==
 /\ s.started /\ "crash" \notin s.done
 /\ s' = [s EXCEPT !.down = TRUE, !.note = Note(1), !.received = FALSE,
      !.planned = FALSE, !.receipt = IF Policy = "volatileReceipt" THEN FALSE ELSE @,
      !.done = @ \cup {"crash"}]
Recover ==
 /\ s.started /\ s.down
 /\ s' = [s EXCEPT !.down = FALSE, !.note = s.wal,
      !.generation = @ + 1, !.done = @ \cup {"recover"}]
Work == IssueIntent \/ PublishArtifact \/ Receive \/ ReceiptBarrier \/ Acknowledge
 \/ ReleaseOutbox \/ Disappear \/ Barrier \/ Checkpoint \/ PlanDelete
 \/ PublishDelete \/ RejectStalePlan
Next == BindingStep \/ FinishBinding \/
 ((Work \/ PurgeArtifact \/ Edit \/ RestoreKnown \/ HiddenRestore \/ Crash \/ Recover) /\ UNCHANGED b)
Spec == Init /\ [][Next]_vars
\* Progress excludes editing/restoration/crash and uses H's stable latest
\* delivery environment. It still permits one artifact purge before receipt.
FairSpec == Init /\ [][BindingProgress \/ FinishBinding \/
                         ((Work \/ PurgeArtifact) /\ UNCHANGED b)]_vars
 /\ WF_vars(BindingProgress) /\ WF_vars(FinishBinding)
 /\ WF_vars(IssueIntent /\ UNCHANGED b) /\ WF_vars(PublishArtifact /\ UNCHANGED b)
 /\ WF_vars(Receive /\ UNCHANGED b) /\ WF_vars(ReceiptBarrier /\ UNCHANGED b)
 /\ WF_vars(Acknowledge /\ UNCHANGED b) /\ WF_vars(Disappear /\ UNCHANGED b)
 /\ WF_vars(Barrier /\ UNCHANGED b) /\ WF_vars(PlanDelete /\ UNCHANGED b)
 /\ WF_vars(PublishDelete /\ UNCHANGED b)
NoteType == [alive: BOOLEAN, actual: 1..3, birth: {1,3}, rev: 1..3,
             saved: SUBSET {2}, consumed: BOOLEAN, aliases: SUBSET {1,2}]
TypeOK == H!TypeOK
 /\ s.note \in NoteType /\ s.wal \in NoteType /\ s.checkpoint \in NoteType /\ s.captured \in NoteType
 /\ s.generation \in Nat /\ s.capturedGeneration \in Nat
 /\ s.done \subseteq {"purge","edit","restore","crash","recover"}
 /\ s.deletedActuals \subseteq 1..3
 /\ \A x \in {s.started,s.down,s.checkpointed,s.issued,s.outbox,s.artifact,
     s.received,s.receipt,s.ack,s.absent,s.planned,s.protectedEdit,s.durableAlias}: x \in BOOLEAN
NoWrongIncarnationDeletion == s.deletedActuals \subseteq {1}
NoLostDurableEdit == s.protectedEdit =>
 (s.wal.alive /\ s.wal.rev = 2) \/ 2 \in s.wal.saved
NoForgottenReceipt == s.ack => s.receipt \/ s.wal.consumed
NoForgottenOutbox == s.issued /\ ~s.ack => s.outbox
NoUnexplainedDeletion == s.deletedActuals # {} => s.issued
DurableAliasesSurvive == s.durableAlias => s.wal.aliases = {1,2}
EventuallyReceived == <>s.receipt
EventuallyApplied == <>s.wal.consumed
NeverApplied == ~s.wal.consumed
NeverPreservedEdit == ~(s.wal.consumed /\ 2 \in s.wal.saved)
NeverRecoveredDecision == ~("recover" \in s.done /\ s.note.consumed)
NeverKeptRestoration == ~(s.receipt /\ s.note.alive /\ s.note.actual = 3 /\ s.note.birth = 3)
NeverReplayedConsumedIntent == ~(s.received /\ "recover" \in s.done /\ s.note.consumed)
NeverEditedWhileUnbound == ~(s.started /\ s.wal.aliases = {2} /\ s.wal.rev = 2)
Safety == NoWrongIncarnationDeletion /\ NoLostDurableEdit /\ NoForgottenReceipt
 /\ NoForgottenOutbox /\ NoUnexplainedDeletion /\ DurableAliasesSurvive
=============================================================================
