-------------------- MODULE JournalRecoverySafety --------------------
\* Proposal-4 baseline: NOT a proposal-5 segment acceptance model.
\* See Proposal5-Coverage.md for retained requirements and replacement gaps.
EXTENDS Naturals, FiniteSets
\* START-01 / CLEAN-01; spec Startup and host-local WAL recovery.
\* Two framed records. Validation results are environmental inputs, not a
\* proof of CRC/decoder correctness. Crash is terminal; restart is composed
\* in CrossMachineRestartRecoverySafety. No provider history or upload gate.
Notes == {"ordinary", "v8"}
Values == {"base", "edit", "deleted"}
Records == Notes \X Values
Phases == {"validate", "replay", "blocked", "settle", "installed",
           "verified", "unlinked", "closed", "crashed"}
VARIABLE s
vars == <<s>>
Serialize(live) == {<<n,live[n]>>: n \in {m \in Notes: live[m] # "deleted"}}
FullConflicts(records) ==
  {records[i]: i \in {j \in 1..2: records[j][2] = "edit"}}
FullRetired(records) ==
  IF <<"v8","deleted">> \in {records[i]: i \in 1..2} THEN {"v8"} ELSE {}
Init ==
  \E records \in [1..2 -> Records], prefix \in 0..2,
     exact \in BOOLEAN, association \in {"same", "other", "unknown"},
     headerOK \in BOOLEAN, represented \in BOOLEAN:
    /\ (represented => ~exact)
    /\ s = [phase |-> "validate", records |-> records, prefix |-> prefix,
         exact |-> exact, association |-> association, headerOK |-> headerOK,
         pos |-> 0, live |-> [n \in Notes |-> "base"], conflicts |-> {},
         retired |-> {}, settings |-> "accepted", wal |-> TRUE,
         walSettled |-> FALSE, filesSettled |-> FALSE,
         checkpoint |-> {<<n,"base">>: n \in Notes},
         checkpointConflicts |-> IF represented THEN FullConflicts(records) ELSE {},
         checkpointRetired |-> IF represented THEN FullRetired(records) ELSE {},
         verified |-> FALSE, directoryDurable |-> FALSE]
Consumed == 1..s.pos
LastIndex(n) ==
  CHOOSE i \in {j \in Consumed: s.records[j][1] = n}:
    \A j \in Consumed: s.records[j][1] = n => j <= i
ExpectedLive(n) ==
  IF s.exact /\ \E i \in Consumed: s.records[i][1] = n
  THEN s.records[LastIndex(n)][2] ELSE "base"
ExpectedConflicts ==
  IF s.exact THEN {}
  ELSE {s.records[i]: i \in {j \in Consumed: s.records[j][2] = "edit"}}
ExpectedRetired ==
  IF \E i \in Consumed: s.records[i] = <<"v8", "deleted">>
  THEN {"v8"} ELSE {}
CompleteCoverage ==
  s.checkpoint = Serialize(s.live) /\ s.checkpointConflicts = s.conflicts /\
  s.checkpointRetired = s.retired
Validate ==
  /\ s.phase = "validate"
  /\ s' = [s EXCEPT !.phase =
       IF s.headerOK /\ s.association = "same" THEN "replay" ELSE "blocked"]
Replay ==
  /\ s.phase = "replay"
  /\ s.pos < s.prefix
  /\ LET r == s.records[s.pos + 1]
     IN s' = [s EXCEPT
       !.pos = @ + 1,
       !.live[r[1]] = IF s.exact THEN r[2] ELSE @,
       !.conflicts = IF ~s.exact /\ r[2] = "edit" THEN @ \cup {r} ELSE @,
       !.retired = IF r = <<"v8", "deleted">> THEN @ \cup {"v8"} ELSE @]
EndPrefix ==
  /\ s.phase = "replay" /\ s.pos = s.prefix
  /\ s' = [s EXCEPT !.phase = IF s.prefix = 2 THEN "settle" ELSE "blocked"]
SettleWAL ==
  /\ s.phase = "settle" /\ ~s.walSettled
  /\ s' = [s EXCEPT !.walSettled = TRUE]
SettleFiles ==
  /\ s.phase = "settle" /\ ~s.filesSettled
  /\ s' = [s EXCEPT !.filesSettled = TRUE]
Install ==
  /\ s.phase = "settle"
  /\ s.walSettled /\ s.filesSettled /\ ~CompleteCoverage
  /\ s' = [s EXCEPT !.phase = "installed", !.checkpoint = Serialize(s.live),
       !.checkpointConflicts = s.conflicts, !.checkpointRetired = s.retired]
AlreadyRepresented ==
  /\ s.phase = "settle" /\ CompleteCoverage
  /\ s' = [s EXCEPT !.verified = TRUE, !.phase = "verified"]
Verify ==
  /\ s.phase = "installed"
  /\ s.checkpoint = Serialize(s.live) /\ s.checkpointConflicts = s.conflicts
  /\ s.checkpointRetired = s.retired
  /\ s' = [s EXCEPT !.verified = TRUE, !.phase = "verified"]
Unlink ==
  /\ s.phase = "verified" /\ s.verified
  /\ s' = [s EXCEPT !.wal = FALSE, !.phase = "unlinked"]
SyncDirectory ==
  /\ s.phase = "unlinked"
  /\ s' = [s EXCEPT !.directoryDurable = TRUE, !.phase = "closed"]
Crash ==
  /\ s.phase \notin {"crashed", "closed"}
  \* A non-durable unlink may or may not survive. Neither outcome can lose
  \* the verified checkpoint; unsynchronized cleanup never reaches closed.
  /\ \E remains \in IF s.phase = "unlinked" THEN BOOLEAN ELSE {s.wal}:
       s' = [s EXCEPT !.phase = "crashed", !.wal = remains]
Next == Validate \/ Replay \/ EndPrefix \/ SettleWAL \/ SettleFiles \/ AlreadyRepresented \/
        Install \/ Verify \/ Unlink \/ SyncDirectory \/ Crash
Spec == Init /\ [][Next]_vars /\ WF_vars(Replay) /\ WF_vars(EndPrefix)
TypeOK ==
  /\ s.phase \in Phases /\ s.records \in [1..2 -> Records]
  /\ s.prefix \in 0..2 /\ s.pos \in 0..2
  /\ s.live \in [Notes -> Values] /\ s.checkpoint \subseteq Notes \X Values
  /\ s.conflicts \subseteq Records /\ s.checkpointConflicts \subseteq Records
  /\ s.retired \subseteq {"v8"} /\ s.checkpointRetired \subseteq {"v8"}
  /\ s.exact \in BOOLEAN /\ s.headerOK \in BOOLEAN
  /\ s.association \in {"same", "other", "unknown"}
  /\ s.settings \in {"accepted"}
  /\ \A b \in {s.wal, s.verified, s.directoryDurable,
               s.walSettled, s.filesSettled}: b \in BOOLEAN
ReplayMatchesOrderedPrefix ==
  /\ s.pos <= s.prefix
  /\ s.live = [n \in Notes |-> ExpectedLive(n)]
  /\ s.conflicts = ExpectedConflicts /\ s.retired = ExpectedRetired
InvalidOrUnassociatedNeverReplays ==
  (~s.headerOK \/ s.association # "same") => s.pos = 0
UncertainSuffixNeverAuthorizesCleanup ==
  s.prefix < 2 => s.wal /\ ~s.verified /\ s.phase # "closed"
MismatchNeverDeletesOrRestoresSettings ==
  /\ (~s.exact => s.live = [n \in Notes |-> "base"])
  /\ s.settings = "accepted"
\* Oracle checks every UUID/value directly, including untouched base notes.
\* Do not use Serialize: it is part of the operation under test.
CheckpointNotesMatchReplay ==
  \A n \in Notes, v \in Values:
    (<<n,v>> \in s.checkpoint) <=> (v = ExpectedLive(n) /\ v # "deleted")
InstalledCheckpointContainsAllResults ==
  s.phase \in {"installed","verified","unlinked","closed"} =>
    /\ CheckpointNotesMatchReplay
    /\ s.checkpointConflicts = ExpectedConflicts
    /\ s.checkpointRetired = ExpectedRetired
DeletedWALHasActualRepresentation ==
  ~s.wal =>
    /\ s.verified /\ s.pos = 2
    /\ CheckpointNotesMatchReplay
    /\ s.checkpointConflicts = ExpectedConflicts
    /\ s.checkpointRetired = ExpectedRetired
ClosedRequiresDirectoryDurability ==
  s.phase = "closed" => s.directoryDurable /\ ~s.wal /\ s.verified
InstallRequiresSettlement ==
  [][Install => s.walSettled /\ s.filesSettled /\ s.pos = 2]_vars
ReplayDoesNotMutateCheckpoint ==
  [][Replay => UNCHANGED <<s.checkpoint, s.checkpointRetired,
                           s.checkpointConflicts, s.wal>>]_vars
NoGeneralCheckpointTombstones ==
  s.checkpoint \cap (Notes \X {"deleted"}) = {}
LocalPrefixScanTerminates == s.phase = "replay" ~> s.phase # "replay"
AlreadyRepresentedCleanupIsReadOnly ==
  [][AlreadyRepresented =>
    UNCHANGED <<s.checkpoint,s.checkpointConflicts,s.checkpointRetired,s.wal>>]_vars
=============================================================================
