---------------------- MODULE ProjectionRecoveryBridge ----------------------
EXTENDS Integers, FiniteSets
\* Protocol active projections + Foundation conditional compare-AFTER-replace.
\* A/B/C are exact known output tokens, X an unimported external replacement,
\* R a fresh restored birth. Tokens are fixture identities, NOT hashes/xattrs.
\* One external replacement, two local output generations, one local crash.
\* FreshBind abstracts positive, unique current association under a newly
\* validated root. It does not infer permanent identity from historical bytes.
\* Source uncertainty parks the move. No fair user decision or automatic unlink
\* is invented to force completion. Physical durability is best-effort here;
\* retained NV history has a separate checked installation/pin barrier.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","clearNewer","receiptIsAuthority","dropBackup",
 "removeChangedSource","skipSource","regressReceipt","echoImport","losePendingHistory",
 "loseOrphanBackup","replayRemoval"}
 /\ Scenario \in {"edit","rename","delete","restore"}
Gens == {0,1,2}
Paths == {0,1,2}
Path(g) == IF Scenario="edit" THEN 0 ELSE g
Token(g) == g+1
InitialFiles == [p \in Paths |-> IF p=0 THEN 1 ELSE 0]
EmptyJob == [phase |-> "idle", expected |-> 0, source |-> 0,
 sourceToken |-> 0, root |-> 0, epoch |-> -1, accounted |-> FALSE]
VARIABLE s
vars == <<s>>
Init == s=[files |-> InitialFiles, backup |-> [g \in {1,2} |-> 0], retained |-> {},
 externalAt |-> -1, restored |-> FALSE, root |-> 0, epoch |-> 0, down |-> FALSE,
 crashed |-> FALSE, recovered |-> FALSE, bindEpoch |-> -1, bound |-> 0,
 intent |-> 1, submitted |-> {0,1}, stage |-> [g \in {1,2} |-> 0],
 objects |-> [h \in {1,2} |-> {0}], pin |-> [h \in {1,2} |-> {0}],
 peer |-> {0}, deleted |-> FALSE, deleteMade |-> FALSE, deleteParents |-> {},
 jobs |-> [g \in {1,2} |-> EmptyJob], dirty |-> TRUE, accepted |-> 0,
 receipt |-> 0, receiptDisk |-> 0, receiptJob |-> 0, receiptEpoch |-> -1,
 echoes |-> {}, removed |-> {}, reconstructed |-> {}, installCut |-> FALSE]
Alive == ~s.deleted
EditAgain == /\ ~s.down /\ Alive /\ s.intent=1
 /\ s'=[s EXCEPT !.intent=2, !.submitted=@ \cup {2}, !.dirty=TRUE]
WriteHistory(g) == /\ ~s.down /\ g \in s.submitted /\ s.stage[g]=0
 /\ s'=[s EXCEPT !.stage[g]=1]
InstallHistory(g) == /\ ~s.down /\ s.stage[g]=1
 /\ (g=1 \/ 1 \in s.objects[1])
 /\ s'=[s EXCEPT !.stage[g]=2, !.objects[1]=@ \cup {g}]
PinHistory == /\ s.pin[1]#s.objects[1]
 /\ s'=[s EXCEPT !.pin[1]=s.objects[1]]
ReceivePeer(g) == /\ g \in s.pin[1] \ s.objects[2]
 /\ s'=[s EXCEPT !.objects[2]=@ \cup {g}]
PinPeer == /\ s.objects[2]#s.pin[2] /\ (2 \in s.objects[2] => 1 \in s.objects[2])
 /\ s'=[s EXCEPT !.pin[2]=s.objects[2]]
ApplyPeer == /\ s.peer#s.pin[2] /\ s'=[s EXCEPT !.peer=s.pin[2]]
MakeDelete == /\ Scenario \in {"delete","restore"} /\ ~s.deleteMade
 /\ s'=[s EXCEPT !.deleteMade=TRUE, !.deleteParents=s.peer]
ReceiveDelete == /\ s.deleteMade /\ ~s.deleted
 /\ s'=[s EXCEPT !.deleted=TRUE, !.bindEpoch=-1,
     !.submitted=IF Policy="losePendingHistory" THEN s.pin[1] ELSE @]
Restore == /\ Scenario="restore" /\ s.deleteMade /\ ~s.restored
 /\ s.files[0] \in {0,1}
 /\ s'=[s EXCEPT !.restored=TRUE, !.files[0]=5]
FreshBind == /\ ~s.down /\ Alive /\ s.root=0 /\ s.bindEpoch#s.epoch
 /\ LET candidates == {g \in s.pin[1]: s.files[Path(g)]=Token(g)}
    IN /\ candidates#{}
       /\ LET g == IF s.receipt \in candidates THEN s.receipt
                   ELSE CHOOSE c \in candidates: \A d \in candidates: c>=d
          IN s'=[s EXCEPT !.bound=g, !.bindEpoch=s.epoch]
Capture(g) == /\ ~s.down /\ Alive /\ g=s.intent /\ g \in s.pin[1]
 /\ s.jobs[g].phase="idle" /\ s.bindEpoch=s.epoch
 /\ s.files[Path(s.bound)]=Token(s.bound)
 /\ s.files[Path(g)] \in {0,1,2,3}
 /\ \A j \in {1,2}: s.jobs[j].phase#"installed"
       /\ (s.jobs[j].phase#"checked" \/ s.jobs[j].accounted)
 /\ s'=[s EXCEPT !.jobs[g]=[phase |-> "captured", expected |-> s.files[Path(g)],
     source |-> Path(s.bound), sourceToken |-> Token(s.bound), root |-> s.root,
     epoch |-> s.epoch, accounted |-> Path(g)=Path(s.bound)]]
\* An atomic safe-save may displace X arriving AFTER capture. Its exact backup
\* survives; an unexpected displaced value must never count as clean success.
Install(g) == /\ ~s.down /\ Alive /\ s.jobs[g].phase="captured"
 /\ s.jobs[g].epoch=s.epoch /\ s.jobs[g].root=s.root
 /\ s'=[s EXCEPT !.backup[g]=IF Policy="dropBackup" THEN 0 ELSE s.files[Path(g)],
     !.files[Path(g)]=Token(g), !.jobs[g].phase="installed"]
CheckDisplaced(g) == /\ ~s.down /\ s.jobs[g].phase="installed"
 /\ LET mismatch == s.backup[g]#s.jobs[g].expected
    IN s'=[s EXCEPT !.retained=IF mismatch /\ s.backup[g]#0
                       THEN @ \cup {s.backup[g]} ELSE @,
       !.backup[g]=0, !.jobs[g].phase=IF mismatch THEN "blocked" ELSE "checked",
       !.bound=IF ~mismatch THEN g ELSE @]
Retry(g) == /\ ~s.down /\ s.jobs[g].phase="blocked"
 /\ s'=[s EXCEPT !.jobs[g]=EmptyJob, !.bindEpoch=-1]
VerifySource(g) == /\ ~s.down /\ Alive /\ s.jobs[g].phase="checked"
 /\ s.jobs[g].epoch=s.epoch /\ s.jobs[g].root=s.root
 /\ s.files[Path(g)]=Token(g) /\ ~s.jobs[g].accounted
 /\ LET src == s.jobs[g].source
        occupant == s.files[src]
    IN /\ (occupant \in {0,s.jobs[g].sourceToken} \/ Policy="removeChangedSource")
       /\ s'=[s EXCEPT !.files[src]=0, !.jobs[g].accounted=TRUE,
            !.removed=IF occupant#0 THEN @ \cup {occupant} ELSE @]
PrepareReceipt(g) == /\ ~s.down /\ Alive /\ s.receiptJob=0
 /\ s.jobs[g].phase="checked"
 /\ (s.jobs[g].accounted \/ Policy="skipSource")
 /\ s.jobs[g].epoch=s.epoch /\ s.jobs[g].root=s.root
 /\ s.files[Path(g)]=Token(g) /\ g>=s.receipt
 /\ s'=[s EXCEPT !.receiptDisk=g, !.receiptJob=g, !.receiptEpoch=s.epoch]
SyncReceipt == /\ s.receiptJob#0 /\ s.receipt#s.receiptDisk
 /\ s'=[s EXCEPT !.receipt=s.receiptDisk]
DiscardStaleReceipt == /\ ~s.down /\ s.receiptJob#0
 /\ LET g==s.receiptJob IN
       (~Alive \/ s.files[Path(g)]#Token(g) \/ s.jobs[g].root#s.root)
 /\ s'=[s EXCEPT !.receiptJob=0]
PublishReceipt(g) == /\ ~s.down /\ Alive /\ s.receiptJob=g /\ s.receipt=g
 /\ ((s.receiptEpoch=s.epoch /\ s.jobs[g].root=s.root /\ s.files[Path(g)]=Token(g))
      \/ Policy="receiptIsAuthority")
 /\ (g>=s.accepted \/ Policy="regressReceipt")
 /\ s'=[s EXCEPT !.accepted=g,
      !.dirty=IF Policy="clearNewer" THEN FALSE ELSE s.intent#g,
      !.jobs[g].phase="done", !.receiptJob=0, !.bound=g]
\* Separate delayed model callback: C can finish after B's source boundary,
\* then B's older callback arrives. It must not regress the accepted value.
LateCallback(g) == /\ ~s.down /\ s.jobs[g].phase="done" /\ g<s.accepted
 /\ Policy="regressReceipt"
 /\ s'=[s EXCEPT !.accepted=g]
ExternalReplacement(p) == /\ s.externalAt=-1
 /\ s'=[s EXCEPT !.externalAt=p, !.files[p]=4]
ChangeRoot == /\ s.root=0 /\ s'=[s EXCEPT !.root=1, !.bindEpoch=-1]
Crash(r) == /\ ~s.crashed /\ ~s.down /\ r \in {s.receipt,s.receiptDisk}
 /\ s'=[s EXCEPT !.crashed=TRUE, !.down=TRUE, !.epoch=1,
     !.installCut=2 \in s.objects[1] /\ s.files[Path(2)]=Token(2) /\ s.receipt<2,
     \* Old attempts own unique backup leaves; a new attempt cannot overwrite
     \* them. Fold their ownership into retained (no physical move on crash).
     !.retained=IF Policy="loseOrphanBackup" THEN @
                 ELSE @ \cup ({s.backup[g]:g \in {1,2}} \ {0}),
     !.backup=[g \in {1,2} |-> 0],
     !.receipt=r, !.receiptDisk=r, !.accepted=r, !.bindEpoch=-1,
     !.jobs=[g \in {1,2} |-> EmptyJob], !.receiptJob=0,
     !.submitted=s.objects[1], !.stage=[g \in {1,2} |-> IF g \in s.objects[1] THEN 2 ELSE 0]]
Recover == /\ s.down /\ s.objects[1]=s.pin[1]
 /\ LET g == IF 2 \in s.pin[1] THEN 2 ELSE IF 1 \in s.pin[1] THEN 1 ELSE 0
    IN s'=[s EXCEPT !.down=FALSE, !.recovered=TRUE, !.intent=g,
                    !.dirty=g#s.receipt, !.reconstructed=s.pin[1]]
\* Current-file scan uses exact known represented-state inputs in this fixture.
\* Absence of the final receipt alone cannot make B/C an external new birth.
ScanOwnOutput(g) == /\ ~s.down /\ s.recovered /\ g \in s.pin[1]
 /\ s.files[Path(g)]=Token(g) /\ g#s.receipt /\ Policy="echoImport"
 /\ s'=[s EXCEPT !.echoes=@ \cup {g}]
\* Deliberately wrong: reuse B's historical A-source receipt after restart.
ReplayRemoval == /\ Policy="replayRemoval" /\ s.recovered /\ ~s.down
 /\ s.receipt=1 /\ s.files[0] \in {4,5}
 /\ s'=[s EXCEPT !.removed=@ \cup {s.files[0]}, !.files[0]=0]
Next == EditAgain \/ PinHistory \/ PinPeer \/ ApplyPeer \/ MakeDelete
 \/ ReceiveDelete \/ Restore \/ FreshBind \/ SyncReceipt \/ DiscardStaleReceipt \/ ChangeRoot \/ Recover \/ ReplayRemoval
 \/ (\E g \in {1,2}: WriteHistory(g) \/ InstallHistory(g) \/ ReceivePeer(g)
      \/ Capture(g) \/ Install(g) \/ CheckDisplaced(g) \/ Retry(g)
      \/ VerifySource(g) \/ PrepareReceipt(g) \/ PublishReceipt(g)
      \/ LateCallback(g) \/ ScanOwnOutput(g))
 \/ (\E p \in Paths: ExternalReplacement(p))
 \/ (\E r \in {s.receipt,s.receiptDisk}: Crash(r))
Spec == Init /\ [][Next]_vars
FairSpec == Spec \* Action-safety configurations add no progress assumption.
TypeOK == /\ s.files \in [Paths -> 0..5] /\ s.retained \subseteq 1..5
 /\ s.objects \in [{1,2} -> SUBSET Gens] /\ s.pin \in [{1,2} -> SUBSET Gens]
 /\ s.intent \in Gens /\ s.accepted \in Gens /\ s.receipt \in Gens
ExternalBytesSurviveNV == s.externalAt#-1 =>
 4 \in {s.files[p]:p \in Paths} \cup {s.backup[g]:g \in {1,2}} \cup s.retained
NoForeignRemoval == s.removed \subseteq {1,2,3}
NoEchoImport == s.echoes={}
NewerWorkRemainsPending == ~s.down /\ s.intent>s.accepted => s.dirty
PinContainsInstalled == \A h \in {1,2}: s.pin[h] \subseteq s.objects[h]
RecoveredExactHistory == s.recovered => s.reconstructed \subseteq s.objects[1]
Safety == ExternalBytesSurviveNV /\ NoForeignRemoval /\ NoEchoImport
 /\ NewerWorkRemainsPending /\ PinContainsInstalled /\ RecoveredExactHistory
\* Actual-effect assertions, not a repeated producer's success flag.
AcceptedIsVerified == [][~s.down /\ s'.accepted#s.accepted /\ ~s'.down =>
 LET g == s'.accepted IN s.files[Path(g)]=Token(g) /\ s.jobs[g].epoch=s.epoch
 /\ s.jobs[g].root=s.root /\ s.jobs[g].accounted /\ Alive]_vars
AcceptedNeverRegresses == [][~s.down /\ ~s'.down => s'.accepted>=s.accepted]_vars
PendingHistoryNotCanceled == [][~s.down /\ ~s'.down => s.submitted \subseteq s'.submitted]_vars
RecoveryReconstructsLatest == [][s.down /\ ~s'.down =>
 s'.reconstructed=s.objects[1] /\ s'.intent \in s.objects[1]
 /\ (\A g \in s.objects[1]: s'.intent>=g) /\ s'.bindEpoch=-1]_vars
NeverSettledBWithCWaiting == ~(s.accepted=1 /\ s.intent=2 /\ s.dirty)
NeverRebuiltWithoutReceipt == ~(s.recovered /\ 2 \in s.pin[1]
 /\ s.installCut
 /\ s.receipt<2 /\ s.intent=2 /\ s.dirty)
NeverPreservedDisplacedX == ~(4 \in s.retained /\ \E g \in {1,2}: s.files[Path(g)]=Token(g))
NeverRestoredDuringOldMove == ~(s.restored /\ s.deleted /\ 1 \in s.pin[1]
 /\ s.files[0]=5 /\ s.removed \subseteq {1,2,3})
NeverSettledAfterRestart == ~(s.recovered /\ s.accepted=2 /\ ~s.dirty)
=============================================================================
