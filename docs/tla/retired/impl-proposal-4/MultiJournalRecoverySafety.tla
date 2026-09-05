-------------------- MODULE MultiJournalRecoverySafety --------------------
\* Proposal-4 baseline: NOT a proposal-5 segment acceptance model.
\* See Proposal5-Coverage.md for retained requirements and replacement gaps.
EXTENDS Naturals, FiniteSets
\* Two positively associated modern WALs, two notes. Ordinary-record fixtures
\* also cover legacy/modern order independence; v8 mismatch retirement is the
\* modern-WAL projection rule, not a claim about arbitrary legacy UUID bytes.
\* Order exists inside each WAL only. Branches are replayed detached before
\* combination. Final per-WAL states, not every superseded record, survive.
\* No durability/coverage receipts: assertions inspect actual checkpoint data.
Journals == {1, 2}
Notes == {"ordinary", "v8"}
Values == {"base", "a", "b", "deleted"}
Scenarios == {"independent", "concurrent", "deleteEdit", "deleteThenEdit",
              "editThenDelete", "duplicate", "mismatch", "v8Mismatch",
              "v8DeleteThenEdit", "sameBodyDifferentNotes", "interleavedNotes"}
R(n,v) == <<n,v>>
Record(c,j,i) ==
  CASE c = "interleavedNotes" ->
         R(IF i = j THEN "ordinary" ELSE "v8", IF j = 1 THEN "a" ELSE "b")
    [] c = "independent" ->
         IF j = 1 THEN R("ordinary","a") ELSE R("v8","b")
    [] c = "sameBodyDifferentNotes" ->
         IF j = 1 THEN R("ordinary","a") ELSE R("v8","a")
    [] c = "v8Mismatch" -> R("v8", IF j = 1 THEN "deleted" ELSE "b")
    [] c = "v8DeleteThenEdit" ->
         R("v8", IF j = 1 /\ i = 1 THEN "deleted" ELSE "a")
    [] c = "deleteEdit" -> R("ordinary", IF j = 1 THEN "deleted" ELSE "a")
    [] c = "deleteThenEdit" ->
         R("ordinary", IF j = 1 /\ i = 1 THEN "deleted" ELSE "a")
    [] c = "editThenDelete" ->
         R("ordinary", IF j = 1 /\ i = 2 THEN "deleted" ELSE "a")
    [] c = "duplicate" -> R("ordinary","a")
    [] OTHER -> R("ordinary", IF j = 1 THEN "a" ELSE "b")
Exact(c,j) == c \notin {"mismatch","v8Mismatch"} \/ j = 2
PrefixValue(c,j,n,pos) ==
  IF pos = 2 /\ Record(c,j,2)[1] = n THEN Record(c,j,2)[2]
  ELSE IF pos > 0 /\ Record(c,j,1)[1] = n THEN Record(c,j,1)[2] ELSE "base"
EndValue(c,j,n) == PrefixValue(c,j,n,2)
Retirements(c) ==
  IF \E j \in Journals, i \in 1..2: Record(c,j,i) = R("v8","deleted")
  THEN {"v8"} ELSE {}
VARIABLE s
vars == <<s>>
Init ==
  \E c \in Scenarios:
    s = [scenario |-> c, phase |-> "replay", pos |-> [j \in Journals |-> 0],
      branch |-> [j \in Journals |-> [n \in Notes |-> "base"]],
      retired |-> {}, live |-> [n \in Notes |-> "base"], conflicts |-> {},
      wal |-> Journals, walSettled |-> FALSE, filesSettled |-> FALSE,
      checkpoint |-> {R(n,"base"): n \in Notes}, checkpointConflicts |-> {},
      checkpointRetired |-> {}, verified |-> FALSE, directoryDurable |-> FALSE]
Replay(j) ==
  /\ s.phase = "replay" /\ s.pos[j] < 2
  /\ LET r == Record(s.scenario,j,s.pos[j]+1)
     IN s' = [s EXCEPT !.pos[j] = @ + 1, !.branch[j][r[1]] = r[2],
       !.retired = IF r = R("v8","deleted") THEN @ \cup {"v8"} ELSE @]
ExactChanges(n) ==
  {s.branch[j][n]: j \in {k \in Journals:
      Exact(s.scenario,k) /\ s.branch[k][n] # "base"}}
Chosen(n) ==
  IF "deleted" \in ExactChanges(n) THEN "deleted"
  ELSE IF ExactChanges(n) = {} THEN "base"
  ELSE IF "a" \in ExactChanges(n) THEN "a" ELSE "b"
NeededConflicts ==
  ({R(n,s.branch[j][n]): n \in Notes, j \in Journals}
    \ {R(n,v): n \in Notes, v \in {"base","deleted"}})
    \ {R(n,Chosen(n)): n \in Notes}
Combine ==
  /\ s.phase = "replay" /\ \A j \in Journals: s.pos[j] = 2
  /\ s' = [s EXCEPT !.phase = "settle",
       !.live = [n \in Notes |-> Chosen(n)], !.conflicts = NeededConflicts]
SettleWAL ==
  /\ s.phase = "settle" /\ ~s.walSettled
  /\ s' = [s EXCEPT !.walSettled = TRUE]
SettleFiles ==
  /\ s.phase = "settle" /\ ~s.filesSettled
  /\ s' = [s EXCEPT !.filesSettled = TRUE]
Serialize(live) == {R(n,live[n]): n \in {m \in Notes: live[m] # "deleted"}}
Install ==
  /\ s.phase = "settle" /\ s.walSettled /\ s.filesSettled
  /\ s' = [s EXCEPT !.phase = "installed", !.checkpoint = Serialize(s.live),
       !.checkpointConflicts = s.conflicts, !.checkpointRetired = s.retired]
Verify ==
  /\ s.phase = "installed" /\ s.checkpoint = Serialize(s.live)
  /\ s.checkpointConflicts = s.conflicts /\ s.checkpointRetired = s.retired
  /\ s' = [s EXCEPT !.verified = TRUE, !.phase = "cleanup"]
Unlink(j) ==
  /\ s.phase = "cleanup" /\ s.verified /\ j \in s.wal
  /\ s' = [s EXCEPT !.wal = @ \ {j}]
SyncDirectory ==
  /\ s.phase = "cleanup" /\ s.wal = {}
  /\ s' = [s EXCEPT !.directoryDurable = TRUE, !.phase = "closed"]
Crash ==
  /\ s.phase \notin {"crashed","closed"}
  /\ \E remains \in {w \in SUBSET Journals: s.wal \subseteq w}:
       s' = [s EXCEPT !.phase = "crashed", !.wal = remains]
Next == (\E j \in Journals: Replay(j) \/ Unlink(j)) \/ Combine \/
        SettleWAL \/ SettleFiles \/ Install \/ Verify \/ SyncDirectory \/ Crash
Spec == Init /\ [][Next]_vars /\ (\A j \in Journals: WF_vars(Replay(j))) /\
        WF_vars(Combine)
TypeOK ==
  /\ s.scenario \in Scenarios
  /\ s.phase \in {"replay","settle","installed","cleanup","closed","crashed"}
  /\ s.pos \in [Journals -> 0..2]
  /\ s.branch \in [Journals -> [Notes -> Values]]
  /\ s.live \in [Notes -> Values] /\ s.checkpoint \subseteq Notes \X Values
  /\ s.conflicts \subseteq Notes \X Values
  /\ s.checkpointConflicts \subseteq Notes \X Values
  /\ s.retired \subseteq {"v8"} /\ s.checkpointRetired \subseteq {"v8"}
  /\ s.wal \subseteq Journals
  /\ \A b \in {s.walSettled,s.filesSettled,s.verified,s.directoryDurable}: b \in BOOLEAN
BranchesRespectOwnOrder ==
  \A j \in Journals, n \in Notes:
    s.branch[j][n] = PrefixValue(s.scenario,j,n,s.pos[j])
\* Independent oracle from the immutable record fixtures, not dispositions.
\* Include untouched base notes and source deletions, not just changed bodies.
ExpectedNoteValue(n) ==
  IF \E j \in Journals: Exact(s.scenario,j) /\ EndValue(s.scenario,j,n) = "deleted"
  THEN "deleted"
  ELSE IF \E j \in Journals: Exact(s.scenario,j) /\ EndValue(s.scenario,j,n) = "a"
       THEN "a"
       ELSE IF \E j \in Journals: Exact(s.scenario,j) /\ EndValue(s.scenario,j,n) = "b"
            THEN "b" ELSE "base"
ExpectedConflicts ==
  {R(n,EndValue(s.scenario,j,n)): n \in Notes, j \in Journals} \
  ({R(n,v): n \in Notes, v \in {"base","deleted"}} \cup
   {R(n,ExpectedNoteValue(n)): n \in Notes})
CheckpointNotesMatchBranches ==
  \A n \in Notes, v \in Values:
    (R(n,v) \in s.checkpoint) <=> (v = ExpectedNoteValue(n) /\ v # "deleted")
RepresentsEnds(live,conflicts) ==
  \A j \in Journals, n \in Notes:
    EndValue(s.scenario,j,n) \notin {"base","deleted"} =>
      live[n] = EndValue(s.scenario,j,n) \/
        R(n,EndValue(s.scenario,j,n)) \in conflicts
SettledPreservesBothBranches ==
  s.phase \in {"settle","installed","cleanup","closed"} =>
    /\ RepresentsEnds(s.live,s.conflicts)
    /\ s.live = [n \in Notes |-> ExpectedNoteValue(n)]
    /\ s.conflicts = ExpectedConflicts
    /\ s.retired = Retirements(s.scenario)
    /\ \A n \in Notes:
       (\E j \in Journals: Exact(s.scenario,j) /\
         EndValue(s.scenario,j,n) = "deleted") => s.live[n] = "deleted"
MismatchHasNoDeletionAuthority ==
  s.scenario = "v8Mismatch" /\ s.phase \in {"settle","installed","cleanup","closed"} =>
    s.live["v8"] = "b" /\ "v8" \in s.retired
DeletedMembersHaveActualCompleteCheckpoint ==
  s.wal # Journals =>
    /\ s.verified /\ CheckpointNotesMatchBranches
    /\ s.checkpointConflicts = ExpectedConflicts
    /\ s.checkpointRetired = Retirements(s.scenario)
    /\ \A j \in Journals: s.pos[j] = 2
ClosedRequiresAllLocalCleanup ==
  s.phase = "closed" => s.wal = {} /\ s.directoryDurable /\ s.verified
CombineRequiresEveryMember ==
  [][Combine => \A j \in Journals: s.pos[j] = 2]_vars
InstallRequiresDerivedSettlement ==
  [][Install => s.walSettled /\ s.filesSettled]_vars
InstalledCheckpointContainsAllResults ==
  s.phase \in {"installed","cleanup","closed"} =>
    CheckpointNotesMatchBranches /\ s.checkpointConflicts = ExpectedConflicts /\
    s.checkpointRetired = Retirements(s.scenario)
NoGeneralCheckpointTombstones == s.checkpoint \cap (Notes \X {"deleted"}) = {}
LocalReplayTerminates == s.phase = "replay" ~> s.phase # "replay"
=============================================================================
