-------------------- MODULE ReconciliationDurabilityBridge --------------------
\* Proposal-4 baseline: NOT a proposal-5 segment acceptance model.
\* See Proposal5-Coverage.md for retained requirements and replacement gaps.
EXTENDS Naturals, FiniteSets
\* PUB-01 -> DUR-01 -> CLEAN-01 -> START-01. Reuse the decision, local
\* durability, and startup actions; carry actual UUID-qualified body/name
\* rows across their interfaces, not an unexamined "represented" token.
\* One transaction, at most one final row per UUID, one crash/reopen. No
\* provider delivery/history assumption and no physical-file deletion action.
Roles == {"source","import","conflict"}
VARIABLES d, w, r, b
vars == <<d,w,r,b>>
D == INSTANCE ReconciliationDecisionSafety WITH s <- d
W == INSTANCE LocalWALSafety WITH state <- w, Edits <- Roles,
     Checkpoints <- {"base","next"}, InitialCheckpoint <- "base", None <- "none"
S == INSTANCE StartupSafety WITH s <- r
Rows == Roles \X (D!Bodies \X D!Names)
Base == {<<"source", <<"base","base">>>>}
IDs(rows) == {row[1]: row \in rows}
ForIDs(rows,ids) == {row \in rows: row[1] \in ids}
Apply(store,records) ==
 {row \in store: row[1] \notin IDs(records)} \cup
 {row \in records: row[2][1] # "absent"}
Covered(store,row) ==
 IF row[2][1] = "absent" THEN row[1] \notin IDs(store) ELSE row \in store
ExpectedRows ==
 {<<"source",<<D!BodyExpected,D!NameExpected>>>>} \cup
 {<<"import",v>>: v \in D!ImportsExpected} \cup
 {<<"conflict",v>>: v \in D!PreservationExpected}
PublishedRows ==
 {<<"source",d.live>>} \cup {<<"import",v>>: v \in d.liveImports} \cup
 {<<"conflict",v>>: v \in d.livePreserved}
NeededRows == ExpectedRows \ Base
\* Independent per-UUID oracles: neither calls the operation's Apply helper.
\* Complete checkpoints retain unchanged notes as well as newly durable rows.
ContainsCompleteDecision(store) ==
 \A id \in Roles:
   {row \in store: row[1] = id} =
     {row \in ExpectedRows: row[1] = id /\ row[2][1] # "absent"}
MatchesCapturedRecovery(store) ==
 \A id \in Roles:
   LET records == {row \in b.restartWAL: row[1] = id}
   IN {row \in store: row[1] = id} =
      IF records = {} THEN {row \in b.restartCheckpoint: row[1] = id}
      ELSE {row \in records: row[2][1] # "absent"}
DecodeStartup ==
 IF 2 \in r.store THEN Apply(b.restartCheckpoint,b.restartWAL)
 ELSE b.restartCheckpoint
Init ==
 /\ D!Init
 \* Ninety cases: all nine body pairs, two name pairs, five evidence/base/
 \* merge/retirement profiles. Full standalone matrix remains separately run.
 /\ <<d.local[2],d.remote[2]>> \in {<<"base","base">>,<<"local","remote">>}
 /\ <<d.evidence,d.origin,d.safe,d.automaticSlot>> \in {
    <<"file","file",TRUE,"free">>, <<"file","file",FALSE,"free">>,
    <<"file","unsettledCheckpoint",TRUE,"free">>,
    <<"wrongVolume","file",FALSE,"free">>, <<"file","file",FALSE,"retired">>}
 /\ W!Init
 /\ r = S!Initial("current",FALSE)
 /\ b = [phase |-> "decision", pending |-> {}, diskWAL |-> {}, stableWAL |-> {},
    protected |-> {}, files |-> Base, checkpoint |-> Base,
    restartCheckpoint |-> {}, restartWAL |-> {},
    recoveryFiles |-> {}, reopened |-> {}, crashUsed |-> FALSE]
Prepare == D!Prepare /\ UNCHANGED <<w,r,b>>
Invalidate == (\E k \in {"root","note","structure","catalog"}: D!Invalidate(k))
              /\ UNCHANGED <<w,r,b>>
Reject == D!Reject /\ UNCHANGED <<w,r,b>>
Publish ==
 /\ b.phase = "decision" /\ D!Publish
 \* Main-thread transaction publication and pending-set admission are atomic.
 \* W's singleton admission is batched here; its I/O actions below are reused.
 /\ w' = [w EXCEPT !.admitted = IDs(PublishedRows' \ Base)]
 /\ b' = [b EXCEPT !.phase = "durability", !.pending = PublishedRows' \ Base]
 /\ UNCHANGED r
Append ==
 /\ b.phase = "durability" /\ W!AppendEdit
 /\ b' = [b EXCEPT !.diskWAL = @ \cup ForIDs(b.pending,w'.appended \ w.appended)]
 /\ UNCHANGED <<d,r>>
Barrier ==
 /\ b.phase = "durability" /\ W!SynchronizeEdit
 /\ b' = [b EXCEPT !.stableWAL = ForIDs(b.diskWAL,w'.durable),
      !.protected = ForIDs(NeededRows,w'.durable)]
 /\ UNCHANGED <<d,r>>
SettleFile ==
 /\ b.phase = "durability" /\ W!SettleNoteFile
 \* "absent" is a settled logical removal after observed remote deletion,
 \* not permission to delete a same-named current file. See deletion model.
 /\ b' = [b EXCEPT !.files = Apply(@,
      ForIDs(b.pending,w'.noteFilesDurable \ w.noteFilesDurable))]
 /\ UNCHANGED <<d,r>>
Quiesce == b.phase = "durability" /\ W!Quiesce /\ UNCHANGED <<d,r,b>>
Install ==
 /\ b.phase = "durability" /\ W!InstallCheckpoint
 /\ b' = [b EXCEPT !.checkpoint = Apply(Base,b.pending)]
 /\ UNCHANGED <<d,r>>
Verify ==
 /\ b.phase = "durability" /\ W!VerifyCheckpoint
 /\ b.checkpoint = Apply(Base,b.pending)
 /\ UNCHANGED <<d,r,b>>
Cleanup ==
 /\ b.phase = "durability"
 /\ (W!CloseWAL \/ W!DeleteWAL \/ W!SynchronizeRecoveryDirectory)
 \* Retain the last synced bytes as crash history: an unsynced unlink may
 \* reappear. Only diskWAL counts as currently present recovery evidence.
 /\ b' = [b EXCEPT !.diskWAL = IF w'.walExists THEN @ ELSE {}]
 /\ UNCHANGED <<d,r>>
Stall == b.phase = "durability" /\ W!ProviderStalls /\ UNCHANGED <<d,r,b>>
Crash ==
 /\ b.phase = "durability" /\ ~b.crashUsed /\ W!Crash
 /\ b' = [b EXCEPT !.phase = "restartReady", !.crashUsed = TRUE,
      !.diskWAL = IF w'.walExists THEN b.stableWAL ELSE {},
      !.pending = {}]
 /\ UNCHANGED <<d,r>>
ReopenClosed ==
 /\ b.phase = "durability" /\ w.phase = "closed"
 /\ b' = [b EXCEPT !.phase = "restartReady"]
 /\ UNCHANGED <<d,w,r>>
BeginStartup ==
 /\ b.phase = "restartReady"
 /\ LET records == b.diskWAL
        scenario == IF records = {} THEN "current"
                    ELSE IF Apply(b.checkpoint,records) = b.checkpoint
                         THEN "already" ELSE "recovery"
    IN /\ r' = S!Initial(scenario,FALSE)
       /\ b' = [b EXCEPT !.phase = "startup",
            !.restartCheckpoint = b.checkpoint, !.restartWAL = records]
 /\ UNCHANGED <<d,w>>
StartupLocal ==
 /\ b.phase = "startup"
 /\ (S!Classify \/ S!Recover \/ S!SettleWAL \/ S!BeginInstall \/ S!Verify \/
     S!SyncCleanup \/ S!CreateFresh \/ S!SyncFreshHeader \/ S!SyncFreshDirectory \/
     S!ChangeRootSession \/ S!RejectChanged \/ S!Cancel \/ S!ReturnCanceledAccessor)
 /\ UNCHANGED <<d,w,b>>
StartupFiles ==
 /\ b.phase = "startup" /\ S!SettleFiles
 /\ b' = [b EXCEPT !.recoveryFiles = DecodeStartup]
 /\ UNCHANGED <<d,w>>
StartupInstall ==
 /\ b.phase = "startup" /\ S!Install
 /\ b' = [b EXCEPT !.checkpoint = DecodeStartup]
 /\ UNCHANGED <<d,w>>
StartupCheckpointReplaced ==
 /\ b.phase = "startup" /\ r.phase \in {"prepared","accessor","installed"}
 /\ S!ReplaceCheckpoint
 \* Same bytes, different full local witness: no invented provider counter.
 /\ UNCHANGED <<d,w,b>>
StartupCleanup ==
 /\ b.phase = "startup" /\ S!CleanupOldWAL
 /\ b' = [b EXCEPT !.diskWAL = {}, !.stableWAL = {}]
 /\ UNCHANGED <<d,w>>
EnableEditing ==
 /\ b.phase = "startup" /\ S!EnableEditing
 /\ b' = [b EXCEPT !.phase = "done", !.reopened = DecodeStartup]
 /\ UNCHANGED <<d,w>>
Next == Prepare \/ Invalidate \/ Reject \/ Publish \/ Append \/ Barrier \/
 SettleFile \/ Quiesce \/ Install \/ Verify \/ Cleanup \/ Stall \/ Crash \/
 ReopenClosed \/ BeginStartup \/ StartupLocal \/ StartupFiles \/ StartupInstall \/
 StartupCheckpointReplaced \/ StartupCleanup \/ EnableEditing
Spec == Init /\ [][Next]_vars
TypeOK ==
 /\ D!TypeOK /\ W!TypeOK /\ S!TypeOK
 /\ b.phase \in {"decision","durability","restartReady","startup","done"}
 /\ \A rows \in {b.pending,b.diskWAL,b.stableWAL,b.protected,b.files,
      b.checkpoint,b.restartCheckpoint,b.restartWAL,b.recoveryFiles,b.reopened}:
        rows \subseteq Rows /\ Cardinality(rows) = Cardinality(IDs(rows))
 /\ b.crashUsed \in BOOLEAN
DecisionChecks == D!PreparedDecisionMatchesIndependentTable /\
 D!PublicationMatchesRoutineDecision /\ D!ConflictingRenamesPreserveRemote /\
 D!RoutineDeletionPreservesChangedLocal
AdmissionCarriesEveryPublishedRow ==
 b.phase = "durability" => b.pending = NeededRows /\ w.admitted = IDs(NeededRows)
BarrierCarriesExactRows ==
 b.phase = "durability" => b.stableWAL = ForIDs(NeededRows,w.durable)
SettledFilesCarryExactRows ==
 b.phase = "durability" =>
   \A row \in ForIDs(NeededRows,w.noteFilesDurable): Covered(b.files,row)
ProtectedRowsRemainRecoverable ==
 \A row \in b.protected: row \in b.diskWAL \/ Covered(b.checkpoint,row)
InstalledCheckpointContainsDecision ==
 b.phase = "durability" /\ w.installedCheckpoint # "none" =>
   ContainsCompleteDecision(b.checkpoint)
UnchangedSourceSurvives ==
 /\ Base \cap ExpectedRows \subseteq b.checkpoint
 /\ (b.phase = "done" => Base \cap ExpectedRows \subseteq b.reopened)
StartupCleanupHasActualCoverage ==
 b.phase \in {"startup","done"} /\ (r.phase = "installed" \/ ~r.walExists) =>
   MatchesCapturedRecovery(b.checkpoint)
EditingContainsDurableDecision ==
 b.phase = "done" =>
   /\ \A row \in b.protected: Covered(b.reopened,row)
   /\ Base \cap ExpectedRows \subseteq b.reopened
   /\ (~b.crashUsed => ContainsCompleteDecision(b.reopened))
   /\ MatchesCapturedRecovery(b.reopened)
   /\ S!EditingRequiresCompleteDurableStartup
RecoveryInstallUsesActualSettledFiles ==
 [][StartupInstall => b.recoveryFiles = DecodeStartup]_vars
StartupFencesHold == S!EveryInstallUsesExactCurrent /\ S!CurrentChangedNeverWrites /\
                    S!CancellationWaitsForAccessor
StartupInstallUsesExactCurrent ==
 [][StartupInstall => r.current = r.expected /\ r.root = r.capturedRoot]_vars
RejectedDecisionNeverAdmits ==
 d.phase = "rejected" => w.admitted = {} /\ b.checkpoint = Base
\* Rich witnesses: both the removal and preserved conflict survive a crash
\* before any checkpoint install; clean reopening also contains a conflict.
NoCrashRecoveryEditing ==
 ~(b.phase = "done" /\ b.crashUsed /\ b.protected = NeededRows /\
   "conflict" \in IDs(b.protected) /\ d.remote[1] = "absent" /\
   w.installedCheckpoint = "none")
NoCleanReopenEditing ==
 ~(b.phase = "done" /\ ~b.crashUsed /\ "conflict" \in IDs(NeededRows))
\* The audited loss path must now reach editing with the changed body intact,
\* even when an unrelated automatic-preservation identity was retired.
NoRetiredCandidateRoutineRecovery ==
 ~(b.phase = "done" /\ ~b.crashUsed /\ d.automaticSlot = "retired" /\
   d.local = <<"local","base">> /\ d.remote = <<"absent","base">> /\
   <<"conflict",d.local>> \in b.reopened /\ "source" \notin IDs(b.reopened))
NoUnchangedSourceImportReopen ==
 ~(b.phase = "done" /\ ~b.crashUsed /\ d.local = <<"base","base">> /\
   d.evidence = "wrongVolume" /\ Base \subseteq b.reopened /\
   <<"import",d.remote>> \in b.reopened)
=============================================================================
