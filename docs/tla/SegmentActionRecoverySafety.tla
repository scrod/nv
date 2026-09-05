-------------------- MODULE SegmentActionRecoverySafety --------------------
EXTENDS Naturals, FiniteSets
\* Protocol: complete action group + note values in ONE immutable envelope.
\* One existing local action, one remote intervening change, undo then redo,
\* one crash, and a second observer. Full finite note values are serialized.
\* Remote intervention is bounded to before first compensation admission;
\* in restore, it edits the surviving OTHER note, never the deleted birth.
\* ongoing arbitrary edits/native partial typing are outside this fixture.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","splitGroup","earlyAck","staleAdmission",
                   "overwriteRemote","partialBulk","wrongBirth","staleCursor",
                   "ignorePortableUndo","snapshotOnly","badRecord","ackGatedDelivery"}
       /\ Scenario \in {"edit","bulk","restore"}
Ops == {"undo","redo"}
Initial == [a |-> IF Scenario = "restore" THEN 5 ELSE 1,
            b |-> IF Scenario = "bulk" THEN 1 ELSE 7,
            title |-> 0, original |-> Scenario # "restore", restored |-> FALSE]
UndoValue(v) == IF Scenario = "restore" THEN [v EXCEPT !.restored = TRUE]
 ELSE [v EXCEPT !.a = 0,
        !.b = IF Scenario = "bulk" /\ ~(Policy = "partialBulk" /\ v.b # 1) THEN 0 ELSE @,
        !.title = IF Policy = "overwriteRemote" THEN 0 ELSE @]
CanUndo(v) == Scenario = "restore" \/
 (v.a = 1 /\ (Scenario # "bulk" \/ v.b = 1 \/ Policy = "partialBulk"))
RedoValue(v) == IF Scenario = "restore"
 THEN IF Policy = "wrongBirth" THEN [v EXCEPT !.original = FALSE]
      ELSE [v EXCEPT !.restored = FALSE]
 ELSE [v EXCEPT !.a = 1, !.b = IF Scenario = "bulk" THEN 1 ELSE @]
Cursor(records) == IF "redo" \in records THEN "undo"
                   ELSE IF "undo" \in records THEN "redo" ELSE "undo"
VARIABLE s
vars == <<s>>
Init == s = [base |-> Initial, live |-> Initial, cursor |-> "undo",
 phase |-> "idle", op |-> "undo", gen |-> 0, capturedGen |-> 0,
 candidate |-> Initial, capturedBefore |-> Initial,
 noteBytes |-> [o \in Ops |-> Initial], actionBytes |-> {},
 recordBefore |-> [o \in Ops |-> Initial], recordAfter |-> [o \in Ops |-> Initial],
 admittedBefore |-> [o \in Ops |-> Initial],
 stableNotes |-> {}, stableActions |-> {}, acknowledged |-> {},
 stage |-> 0, remote |-> "none", undoAdmitted |-> FALSE,
 undoInput |-> Initial, admittedGen |-> 0, admissionCurrentGen |-> 0,
 cacheNote |-> Initial, cacheCursor |-> "undo", cacheTaken |-> FALSE,
 peerReceived |-> {}, peerApplied |-> {}, peerLive |-> Initial,
 peerCursor |-> "none", crashed |-> FALSE, down |-> FALSE, recovered |-> FALSE]
Result(notes) == IF "redo" \in notes THEN s.noteBytes["redo"]
                ELSE IF "undo" \in notes THEN s.noteBytes["undo"] ELSE s.base
RemoteChange(kind) ==
 /\ ~s.down /\ ~s.crashed /\ ~s.undoAdmitted /\ s.remote = "none"
 /\ s.phase \in {"idle","prepared"} /\ kind \in {"title","overlap"}
 /\ LET v == IF Scenario = "restore" THEN [s.live EXCEPT !.b = 2]
             ELSE IF kind = "title" THEN [s.live EXCEPT !.title = 2]
             ELSE IF Scenario = "bulk" THEN [s.live EXCEPT !.b = 2]
             ELSE [s.live EXCEPT !.a = 2]
    IN s' = [s EXCEPT !.live = v, !.base = v, !.peerLive = v,
        !.gen = @ + 1, !.remote = IF Scenario = "restore" THEN "other" ELSE kind,
        !.peerCursor = "remote"]
Prepare ==
 /\ ~s.down /\ ~s.crashed /\ s.phase = "idle"
 /\ s' = [s EXCEPT !.phase = IF s.op = "redo" \/ CanUndo(s.live)
                                    THEN "prepared" ELSE "review",
       !.capturedGen = s.gen, !.capturedBefore = s.live,
       !.candidate = IF s.op = "undo" THEN UndoValue(s.live) ELSE RedoValue(s.live)]
Admit ==
 /\ ~s.down /\ s.phase = "prepared"
 /\ Policy = "staleAdmission" \/ s.capturedGen = s.gen
 /\ s' = [s EXCEPT !.phase = "pending", !.live = s.candidate,
       !.cursor = IF s.op = "undo" THEN "redo" ELSE "undo",
       !.undoAdmitted = TRUE,
       !.undoInput = IF s.op = "undo" THEN s.capturedBefore ELSE @,
       !.admittedBefore[s.op] = s.live,
       !.admittedGen = s.capturedGen, !.admissionCurrentGen = s.gen,
       !.gen = @ + 1]
RejectStale ==
 /\ ~s.down /\ s.phase = "prepared" /\ s.capturedGen # s.gen
 /\ s' = [s EXCEPT !.phase = "review"]
Encode ==
 /\ ~s.down /\ s.phase = "pending" /\ s.stage = 0
 /\ s' = [s EXCEPT !.noteBytes[s.op] = s.candidate,
       !.recordBefore[s.op] = s.capturedBefore,
       !.recordAfter[s.op] = IF Policy = "badRecord" THEN Initial ELSE s.candidate,
       !.actionBytes = @ \cup {s.op}, !.stage = 1]
FileSync == /\ ~s.down /\ s.stage = 1
 /\ s' = [s EXCEPT !.stage = 2]
InstallName == /\ ~s.down /\ s.stage = 2
 /\ s' = [s EXCEPT !.stage = 3]
DirectorySync ==
 /\ ~s.down /\ s.stage = 3
 /\ s' = [s EXCEPT !.stableNotes = @ \cup {s.op},
       !.stableActions = IF Policy = "splitGroup" THEN @ ELSE @ \cup {s.op},
       !.stage = 4]
Ack ==
 /\ ~s.down /\ s.phase = "pending"
 /\ s.stage >= (IF Policy = "earlyAck" THEN 3 ELSE 4)
 /\ s' = [s EXCEPT !.acknowledged = @ \cup {s.op}, !.phase = "done"]
BeginRedo ==
 /\ ~s.down /\ ~s.crashed /\ s.phase = "done" /\ s.op = "undo"
 /\ "undo" \in s.stableNotes /\ "undo" \in s.stableActions
 /\ s' = [s EXCEPT !.op = "redo", !.phase = "idle", !.stage = 0]
CaptureCache ==
 /\ ~s.down /\ ~s.cacheTaken
 /\ s' = [s EXCEPT !.cacheTaken = TRUE, !.cacheNote = Result(s.stableNotes),
       !.cacheCursor = Cursor(s.stableActions)]
PeerReceive(o) ==
 /\ o \in (s.stableNotes \cap s.stableActions) \ s.peerReceived
 /\ Policy # "ackGatedDelivery" \/ o \in s.acknowledged
 /\ s' = [s EXCEPT !.peerReceived = @ \cup {o}]
PeerApply(o) ==
 /\ o \in s.peerReceived \ s.peerApplied
 /\ o = "undo" \/ "undo" \in s.peerApplied
 /\ s' = [s EXCEPT !.peerApplied = @ \cup {o},
       !.peerLive = s.noteBytes[o],
       !.peerCursor = IF Policy = "ignorePortableUndo" THEN @
                       ELSE IF o = "undo" THEN "redo" ELSE "undo"]
Crash ==
 /\ ~s.crashed
 /\ s' = [s EXCEPT !.crashed = TRUE, !.down = TRUE, !.phase = "stopped",
       !.live = Initial, !.cursor = "none", !.stage = 0,
       !.actionBytes = s.stableActions]
Recover ==
 /\ s.down
 /\ s' = [s EXCEPT !.down = FALSE, !.recovered = TRUE,
       !.live = IF Policy = "snapshotOnly" THEN s.cacheNote ELSE Result(s.stableNotes),
       !.cursor = IF Policy = "staleCursor" THEN s.cacheCursor ELSE Cursor(s.stableActions)]
Next == (\E k \in {"title","overlap"}: RemoteChange(k))
 \/ Prepare \/ Admit \/ RejectStale \/ Encode \/ FileSync \/ InstallName
 \/ DirectorySync \/ Ack \/ BeginRedo \/ CaptureCache \/ Crash \/ Recover
 \/ (\E o \in Ops: PeerReceive(o) \/ PeerApply(o))
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Recover)
 /\ \A o \in Ops: (WF_vars(PeerReceive(o)) /\ WF_vars(PeerApply(o)))
NoteType == [a: 0..5,b: {0,1,2,7},title: {0,2},original: BOOLEAN,restored: BOOLEAN]
TypeOK ==
 /\ \A f \in {"base","live","candidate","capturedBefore","undoInput","cacheNote","peerLive"}: s[f] \in NoteType
 /\ s.noteBytes \in [Ops -> NoteType]
 /\ \A f \in {"recordBefore","recordAfter","admittedBefore"}: s[f] \in [Ops -> NoteType]
 /\ \A f \in {"actionBytes","stableNotes","stableActions","acknowledged","peerReceived","peerApplied"}: s[f] \subseteq Ops
 /\ s.phase \in {"idle","prepared","review","pending","done","stopped"}
 /\ s.op \in Ops /\ s.stage \in 0..4
 /\ s.gen \in 0..3 /\ s.capturedGen \in 0..3
 /\ s.admittedGen \in 0..3 /\ s.admissionCurrentGen \in 0..3
 /\ s.cursor \in {"none","undo","redo"} /\ s.cacheCursor \in {"undo","redo"}
 /\ s.peerCursor \in {"none","remote","undo","redo"} /\ s.remote \in {"none","title","overlap","other"}
 /\ \A f \in {"undoAdmitted","cacheTaken","crashed","down","recovered"}: s[f] \in BOOLEAN
AtomicDurableGroup == s.stableNotes = s.stableActions
AckHasCompleteEnvelope == s.acknowledged \subseteq s.stableNotes \cap s.stableActions
ActionRecordMatchesNoteValues == \A o \in s.stableNotes \cap s.stableActions:
 /\ s.recordBefore[o] = s.admittedBefore[o]
 /\ s.recordAfter[o] = s.noteBytes[o]
NoStaleAdmission == s.undoAdmitted => s.admittedGen = s.admissionCurrentGen
NoPartialBulkUndo == Scenario = "bulk" /\ s.undoAdmitted => s.undoInput.b = 1
RemoteFieldPreserved == s.remote = "title" =>
 /\ (s.undoAdmitted /\ ~s.down => s.live.title = 2)
 /\ (s.peerApplied # {} => s.peerLive.title = 2)
RecoveredEffectAndCursor == s.recovered =>
 /\ ("redo" \in s.stableNotes => s.cursor = "undo")
 /\ (s.stableNotes = {"undo"} => s.cursor = "redo")
 /\ (s.stableNotes = {} => s.cursor = "undo")
 /\ ("redo" \in s.stableNotes /\ Scenario # "restore" => s.live.a = 1)
 /\ (s.stableNotes = {"undo"} /\ Scenario # "restore" => s.live.a = 0)
 /\ ("undo" \in s.stableNotes /\ Scenario = "bulk" =>
          s.live.b = IF "redo" \in s.stableNotes THEN 1 ELSE 0)
FreshBirthRedo == Scenario = "restore" =>
 /\ (~s.down => ~s.live.original)
 /\ (s.recovered /\ s.stableNotes = {"undo"} => s.live.restored)
 /\ (s.recovered /\ "redo" \in s.stableNotes => ~s.live.restored)
RestorePreservesSelectedValueAndOtherNote == Scenario = "restore" =>
 /\ (~s.down => s.live.a = 5 /\ s.live.b = IF s.remote = "other" THEN 2 ELSE 7)
 /\ (s.peerApplied # {} => s.peerLive.a = 5 /\ s.peerLive.b = IF s.remote = "other" THEN 2 ELSE 7)
PeerHasPortableUndo ==
 IF "redo" \in s.peerApplied THEN s.peerCursor = "undo"
 ELSE IF "undo" \in s.peerApplied THEN s.peerCursor = "redo"
 ELSE s.peerCursor = (IF s.remote = "none" THEN "none" ELSE "remote")
PeerSeesWholeAction == s.peerApplied # {} =>
 /\ s.peerApplied \subseteq s.stableNotes \cap s.stableActions
 /\ (Scenario # "restore" => s.peerLive.a = IF "redo" \in s.peerApplied THEN 1 ELSE 0)
 /\ (Scenario = "bulk" => s.peerLive.b = IF "redo" \in s.peerApplied THEN 1 ELSE 0)
 /\ (Scenario = "restore" => ~s.peerLive.original
       /\ s.peerLive.restored = ("redo" \notin s.peerApplied))
Safety == AtomicDurableGroup /\ AckHasCompleteEnvelope /\ NoStaleAdmission
 /\ NoPartialBulkUndo /\ RemoteFieldPreserved /\ RecoveredEffectAndCursor
 /\ FreshBirthRedo /\ RestorePreservesSelectedValueAndOtherNote
 /\ PeerHasPortableUndo /\ PeerSeesWholeAction /\ ActionRecordMatchesNoteValues
DurableActionsReachPeer == \A o \in Ops:
   (o \in s.stableNotes \cap s.stableActions ~> o \in s.peerApplied)
NeverRecoveredBeforeAck == ~(s.recovered /\ s.stableNotes = {"undo"}
  /\ s.acknowledged = {} /\ s.cursor = "redo")
NeverCompletedRedoOnBoth == ~(s.recovered /\ "redo" \in s.stableNotes
  /\ "redo" \in s.peerApplied /\ s.live = s.peerLive)
NeverPreservedRemoteRename == ~(s.recovered /\ s.remote = "title"
  /\ s.stableNotes = {"undo"} /\ s.live.title = 2)
NeverRejectedInterveningEdit == ~(s.phase = "review" /\ s.remote = "overlap"
  /\ ~s.undoAdmitted /\ s.stableNotes = {})
=============================================================================
