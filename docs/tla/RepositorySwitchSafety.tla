------------------------- MODULE RepositorySwitchSafety -------------------------
EXTENDS Naturals, FiniteSets
\* One fixed private backup and final integrated Save As handoff. Tokens stand
\* for complete checked records; real encoding, SQLCipher backup and filesystem
\* durability are qualified by executable tests. A second cooperating opener can
\* change the retired source before selection exclusion is acquired.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "skipCut", "omitPrivate", "releasePending", "earlyAck"}
       /\ Scenario \in {"normal", "crash"}
Base == {"history", "privatePreview", "settings"}
Late == {"edit", "newPrivatePreview"}
Values == Base \cup Late
Phases == {"editing", "copying", "retired", "pending", "done", "refused", "crashed", "reopened"}
VARIABLE s
vars == <<s>>
Init == s = [source |-> Base, copied |-> {}, captured |-> {}, observed |-> {},
             phase |-> "editing", selected |-> "old", durable |-> "old",
             sourceHeld |-> TRUE, acknowledged |-> FALSE, crashes |-> 0]
TypeOK ==
 /\ s.source \subseteq Values /\ s.copied \subseteq Values
 /\ s.captured \subseteq Values /\ s.observed \subseteq Values
 /\ s.phase \in Phases /\ s.selected \in {"old", "new"}
 /\ s.durable \in {"old", "new"} /\ s.sourceHeld \in BOOLEAN
 /\ s.acknowledged \in BOOLEAN /\ s.crashes \in 0..1

\* Fixed reader captures all required private and accepted state together.
Capture ==
 /\ s.phase = "editing"
 /\ s' = [s EXCEPT !.phase = "copying", !.captured = s.source,
      !.copied = IF Policy = "omitPrivate" THEN s.source \ {"privatePreview"} ELSE s.source]
Write(v) ==
 /\ v \in Late \ s.source
 /\ s.phase \in {"editing", "copying"} \/
       (s.phase \in {"retired", "pending"} /\ ~s.sourceHeld)
 /\ s' = [s EXCEPT !.source = @ \cup {v}]

\* DatabaseLane checks the capture and retires the connection in one actor turn.
Retire ==
 /\ s.phase = "copying"
 /\ s.source = s.captured \/ Policy = "skipCut"
 /\ s' = [s EXCEPT !.phase = "retired", !.sourceHeld = FALSE, !.observed = s.source]
Refuse ==
 /\ s.phase = "copying" /\ s.source # s.captured /\ Policy # "skipCut"
 /\ s' = [s EXCEPT !.phase = "refused"]

\* Selection obtains physical exclusion, then rechecks the retired observation.
Install ==
 /\ s.phase = "retired" /\ s.source = s.observed
 /\ s' = [s EXCEPT !.phase = "pending", !.selected = "new",
      !.sourceHeld = Policy # "releasePending", !.acknowledged = Policy = "earlyAck"]
RefuseRetired ==
 /\ s.phase = "retired" /\ s.source # s.observed
 /\ s' = [s EXCEPT !.phase = "refused", !.sourceHeld = TRUE]
\* Failed I/O leaves the pending handles retained; successful resumption finishes
\* the same installed item. This action abstracts readback and durability barriers.
Finish ==
 /\ s.phase = "pending" /\ s.source = s.observed
 /\ s' = [s EXCEPT !.phase = "done", !.durable = "new",
      !.sourceHeld = FALSE, !.acknowledged = TRUE]
\* Before acknowledgement, either namespace outcome may survive a crash.
Crash ==
 /\ Scenario = "crash" /\ s.crashes = 0
 /\ s.phase \in {"copying", "retired", "pending", "done"}
 /\ \E record \in (IF s.phase = "pending" THEN {"old", "new"} ELSE {s.durable}):
      s' = [s EXCEPT !.phase = "crashed", !.selected = record, !.durable = record,
                    !.sourceHeld = FALSE, !.crashes = 1]
Reopen ==
 /\ s.phase = "crashed"
 /\ s' = [s EXCEPT !.phase = "reopened", !.sourceHeld = s.selected = "old"]

Next == Capture \/ (\E v \in Late: Write(v)) \/ Retire \/ Refuse \/ Install \/ RefuseRetired \/ Finish \/ Crash \/ Reopen
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Capture) /\ WF_vars(Retire) /\ WF_vars(Refuse)
                /\ WF_vars(Install) /\ WF_vars(RefuseRetired) /\ WF_vars(Finish) /\ WF_vars(Reopen)

SelectionCoversSource == s.selected = "new" => s.source \subseteq s.copied
AcknowledgmentIsDurable == s.acknowledged => s.durable = "new"
PendingKeepsExclusion == s.phase = "pending" => s.sourceHeld
SourcePreserved == Base \subseteq s.source
Safety == SelectionCoversSource /\ AcknowledgmentIsDurable /\ PendingKeepsExclusion /\ SourcePreserved
Settles == <> (s.phase \in {"done", "refused", "reopened"})
NeverSwitched == ~(s.phase = "done" /\ s.acknowledged)
NeverRefusedLatePrivate == ~(s.phase = "refused" /\ "newPrivatePreview" \in (s.source \ s.copied))
NeverReopenedNew == ~(s.phase = "reopened" /\ s.selected = "new")
NeverReopenedOld == ~(s.phase = "reopened" /\ s.selected = "old")
=============================================================================
