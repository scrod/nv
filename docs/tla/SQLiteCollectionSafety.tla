------------------------- MODULE SQLiteCollectionSafety -------------------------
EXTENDS Naturals, Sequences, FiniteSets
\* Experimental private SQLite transaction mapping: DUR-01/START-01/IMPORT-01.
\* Exact complete object/action decoding is an input. Commit is SQLite's atomic
\* durability contract, exercised separately by SQLiteCollectionProtocolProbe.c.
\* One import, a parked child/late parent on another note, a later Delete, two
\* crashes, one source/root change. No artificial depth/state constraints.
\* This is not arbitrary NV merge, encryption, a full file protocol or a claim
\* that an SQL transaction excludes external writers. A receipt is historical.
\* currentValues is the whole current-row transaction, not a packed cache.
\* Replay is a bounded reduction abstraction; indexed access is checked in SQL.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","earlyAck","noLink","arrivalTail","splitCoverage",
 "staleReceipt","replayConsent","liveOnly","loseFrozen","acceptOrphan","splitCommit","skipReady","noReady"}
 /\ Scenario \in {"commit","parked","import","combined"}
Ops == {1,2,3,4,5,6}
Allowed == CASE Scenario="parked" -> {2,3}
 [] Scenario="commit" -> {4}
 [] Scenario="import" -> {4,5}
 [] OTHER -> {2,3,4,5}
Parents(o) == CASE o=1 -> {} [] o=2 -> {3} [] o=5 -> {4} [] OTHER -> {1}
Members(q) == {q[i]:i \in DOMAIN q}
Step(v,o) == CASE o=1 -> [v EXCEPT ![3]=7]
 [] o \in {2,3} -> [v EXCEPT ![2]=o]
 [] o \in {4,6} -> [v EXCEPT ![1]=o]
 [] OTHER -> [v EXCEPT ![1]=0]
RECURSIVE Replay(_,_)
Replay(v,q) == IF q = <<>> THEN v ELSE Replay(Step(v,Head(q)),Tail(q))
\* Independent expected-state oracle for this fixed causal graph, not Replay.
Expected(h) == <<IF 5 \in h THEN 0 ELSE IF 6 \in h THEN 6 ELSE IF 4 \in h THEN 4 ELSE 0,
 IF 2 \in h THEN 2 ELSE IF 3 \in h THEN 3 ELSE 0, 7>>
InitialDB == [objects |-> <<1,2>>, apps |-> <<1>>, actions |-> {1}, ready |-> {}, through |-> 1,
 viewThrough |-> 1, currentValues |-> <<0,0,7>>, viewPresent |-> TRUE,
 settings |-> 7, payloads |-> {1}, latest |-> 1, frozen |-> 0,
 reserved |-> FALSE, link |-> FALSE, consumed |-> FALSE, receipt |-> FALSE]
VARIABLE s
vars == <<s>>
Init == s=[db |-> InitialDB, work |-> InitialDB, phase |-> 0, object |-> 0,
 down |-> FALSE, crashes |-> 0, reopens |-> 0, admitted |-> FALSE,
 file |-> 1, root |-> 0, verified |-> FALSE, active |-> FALSE,
 captureThrough |-> 0, captureValues |-> <<0,0,7>>, building |-> FALSE,
 recovered |-> <<0,0,7>>, status |-> 0, acknowledged |-> FALSE,
 peerStored |-> {1}, peerApplied |-> {1}, peerValues |-> <<0,0,7>>]
Idle == ~s.down /\ s.phase=0
DBType(d) == /\ d.objects \in Seq(Ops) /\ Len(d.objects)<=6
 /\ d.apps \in Seq(Ops) /\ Len(d.apps)<=6 /\ d.actions \subseteq Ops /\ d.ready \subseteq Ops
 /\ d.through \in 0..6 /\ d.viewThrough \in 0..6
 /\ d.currentValues \in [1..3 -> 0..7] /\ d.settings=7
 /\ d.payloads \subseteq {1,2} /\ d.latest \in 0..2 /\ d.frozen \in 0..1
 /\ \A k \in {"viewPresent","reserved","link","consumed","receipt"}: d[k] \in BOOLEAN
TypeOK == /\ DBType(s.db) /\ DBType(s.work) /\ s.phase \in 0..4 /\ s.object \in 0..6
 /\ s.crashes \in 0..2 /\ s.reopens \in 0..2 /\ s.file \in 0..2 /\ s.root \in 0..1
 /\ s.captureThrough \in 0..6 /\ s.captureValues \in [1..3 -> 0..7]
 /\ s.recovered \in [1..3 -> 0..7] /\ s.status \in 0..3
 /\ s.peerStored \subseteq Ops /\ s.peerApplied \subseteq Ops /\ s.peerValues \in [1..3 -> 0..7]
 /\ \A k \in {"down","admitted","verified","active","building","acknowledged"}: s[k] \in BOOLEAN

Reserve == /\ Idle /\ 4 \in Allowed /\ ~s.db.reserved /\ ~s.db.consumed
 /\ s.file=1 /\ s.root=0
 /\ s'=[s EXCEPT !.db.reserved=TRUE, !.db.frozen=1]
\* Fresh approval/admission is a process-local event, never deserialized.
Admit == /\ Idle /\ s.db.reserved /\ ~s.admitted /\ 4 \notin Members(s.db.apps)
 /\ s.file=1 /\ s.root=0
 /\ s'=[s EXCEPT !.admitted=TRUE]
Begin(o) == /\ Idle /\ o \in Allowed \ Members(s.db.apps)
 /\ (Scenario#"combined" \/ o=4)
 /\ (Parents(o) \subseteq Members(s.db.apps) \/ Policy="acceptOrphan")
 /\ (o=4 => s.admitted)
 /\ s'=[s EXCEPT !.work=s.db, !.phase=1, !.object=o]
WriteObject == /\ ~s.down /\ s.phase=1
 /\ s'=[s EXCEPT !.work.objects=IF s.object \in Members(@) THEN @ ELSE Append(@,s.object),
                 !.work.ready=@ \cup {s.object}, !.phase=2]
WriteAction == /\ ~s.down /\ s.phase=2
 /\ s'=[s EXCEPT !.work.actions=@ \cup {s.object}, !.phase=3]
WriteApplication == /\ ~s.down /\ s.phase=3
 /\ LET w == [s.work EXCEPT !.apps=Append(@,s.object), !.through=@+1,
                  !.ready=(@ \ {s.object}) \cup IF s.object=3 /\ Policy#"noReady" THEN {2} ELSE {},
                  !.link=IF s.object=4 /\ Policy#"noLink" THEN TRUE ELSE @,
                  !.reserved=IF s.object=4 /\ Policy="noLink" THEN FALSE ELSE @,
                  !.frozen=IF s.object=4 /\ Policy="noLink" THEN 0 ELSE @]
    IN s'=[s EXCEPT !.work=w, !.phase=4,
       !.db=IF Policy="splitCommit" THEN [@ EXCEPT !.apps=w.apps] ELSE @]
Commit == /\ ~s.down /\ s.phase=4
 /\ s'=[s EXCEPT !.db=s.work, !.phase=0, !.work=InitialDB, !.object=0,
    !.admitted=IF s.object=4 THEN FALSE ELSE @,
    !.active=IF s.object=5 THEN FALSE ELSE @,
    !.recovered = <<0,0,7>>, !.status=0]
\* The combined case expands the import's SQL stages but treats remote
\* acceptance as one SQL commit. Its intermediate writes cannot be observed
\* outside the transaction, do not acknowledge anything, and do not inspect
\* the file. A crash has the same pre/post durable outcomes. Focused cases and
\* compiled parent/child crash cuts retain the expanded boundary checks.
AcceptRemote(o) == /\ Scenario="combined" /\ Idle
 /\ o \in {2,3,5} \ Members(s.db.apps)
 /\ Parents(o) \subseteq Members(s.db.apps)
 /\ s'=[s EXCEPT
    !.db.objects=IF o \in Members(@) THEN @ ELSE Append(@,o),
    !.db.actions=@ \cup {o}, !.db.apps=Append(@,o), !.db.through=@+1,
    !.db.ready=(@ \ {o}) \cup IF o=3 THEN {2} ELSE {},
    !.active=IF o=5 THEN FALSE ELSE @, !.recovered = <<0,0,7>>, !.status=0]
Abort == /\ ~s.down /\ s.phase#0
 /\ s'=[s EXCEPT !.phase=0, !.work=InitialDB, !.object=0]
Ack == /\ ~s.down /\ ~s.acknowledged
 /\ (4 \in Members(s.db.apps) \/ (Policy="earlyAck" /\ s.object=4 /\ s.phase=4))
 /\ s'=[s EXCEPT !.acknowledged=TRUE]

CaptureMaterialization == /\ Idle /\ ~s.building
 /\ s'=[s EXCEPT !.building=TRUE, !.captureThrough=s.db.through,
                 !.captureValues=Replay(<<0,0,0>>,s.db.apps)]
PublishMaterialization == /\ Idle /\ s.building
 /\ s.captureThrough>=s.db.viewThrough
 /\ s'=[s EXCEPT !.building=FALSE, !.db.viewPresent=TRUE,
    !.db.viewThrough=IF Policy="splitCoverage" THEN s.db.through ELSE s.captureThrough,
    !.db.currentValues=s.captureValues, !.captureThrough=0, !.captureValues = <<0,0,7>>]
RejectMaterialization == /\ Idle /\ s.building /\ s.captureThrough<s.db.viewThrough
 /\ s'=[s EXCEPT !.building=FALSE, !.captureThrough=0, !.captureValues = <<0,0,7>>]
InvalidateMaterialization == /\ Idle /\ s.db.viewPresent
 /\ s'=[s EXCEPT !.db.viewPresent=FALSE, !.db.viewThrough=0, !.db.currentValues = <<0,0,7>>]

ChangeFile(v) == /\ Scenario \in {"import","combined"} /\ s.file=1 /\ v \in {0,2}
 /\ s'=[s EXCEPT !.file=v, !.active=FALSE]
ChangeRoot == /\ Scenario \in {"import","combined"} /\ s.root=0
 /\ s'=[s EXCEPT !.root=1, !.active=FALSE]
ReplacePreview == /\ Idle /\ s.file=2 /\ s.db.latest#2
 /\ s'=[s EXCEPT !.db.payloads=@ \cup {2}, !.db.latest=2,
     !.db.frozen=IF Policy="loseFrozen" THEN 0 ELSE @]
VerifyFile == /\ Idle /\ s.file=1 /\ s.root=0 /\ ~s.verified
 /\ s.db.link /\ 4 \in Members(s.db.apps) /\ 5 \notin Members(s.db.apps)
 /\ s'=[s EXCEPT !.verified=TRUE]
Settle == /\ Idle /\ s.db.link /\ ~s.db.consumed /\ s.verified
 /\ 5 \notin Members(s.db.apps)
 /\ (Policy="staleReceipt" \/ (s.file=1 /\ s.root=0))
 /\ s'=[s EXCEPT !.db.receipt=TRUE, !.db.consumed=TRUE, !.db.link=FALSE,
    !.db.frozen=0, !.db.reserved=FALSE,
    !.db.latest=IF @=1 THEN 0 ELSE @, !.active=TRUE, !.verified=FALSE]
SettleDeleted == /\ Idle /\ s.db.link /\ 5 \in Members(s.db.apps)
 /\ s'=[s EXCEPT !.db.consumed=TRUE, !.db.link=FALSE,
    !.db.frozen=0, !.db.reserved=FALSE, !.db.latest=IF @=1 THEN 0 ELSE @, !.verified=FALSE]
Collect(v) == /\ Idle /\ v \in s.db.payloads
 /\ v \notin {s.db.latest,s.db.frozen}
 /\ s'=[s EXCEPT !.db.payloads=@ \ {v}]

\* down also covers opening/recovery: another crash can interrupt queue draining.
\* recovered/status are output diagnostics, not the live model or durable
\* classifier. Clear stale diagnostics after a new commit or crash. Properties
\* inspect the actual Recover transition; no subsequent safe guard uses them.
Crash == /\ s.crashes<2
 /\ s'=[s EXCEPT !.down=TRUE, !.crashes=@+1, !.phase=0, !.work=InitialDB, !.object=0,
    !.admitted=FALSE, !.verified=FALSE, !.active=FALSE, !.building=FALSE,
    !.captureThrough=0, !.captureValues = <<0,0,7>>,
    !.recovered = <<0,0,7>>, !.status=0]
RecoveryTail == IF Policy="arrivalTail" /\ s.db.viewPresent
 THEN SelectSeq(s.db.apps,LAMBDA o: o \notin {1,2})
 ELSE SubSeq(s.db.apps,IF s.db.viewPresent THEN s.db.viewThrough+1 ELSE 1,Len(s.db.apps))
ReadyStored == {o \in Members(s.db.objects) \ Members(s.db.apps): Parents(o) \subseteq Members(s.db.apps)}
RecoverAccept(o) == /\ s.down /\ o \in s.db.ready /\ Parents(o) \subseteq Members(s.db.apps)
 /\ s'=[s EXCEPT !.db.apps=Append(@,o), !.db.actions=@ \cup {o}, !.db.through=@+1,
                 !.db.ready=(@ \ {o}) \cup IF o=3 THEN {2} ELSE {}]
Recover == /\ s.down /\ (ReadyStored={} \/ Policy="skipReady")
 /\ s'=[s EXCEPT !.down=FALSE, !.reopens=@+1,
    !.recovered=Replay(IF s.db.viewPresent THEN s.db.currentValues ELSE <<0,0,0>>,RecoveryTail),
    !.db.currentValues=Replay(IF s.db.viewPresent THEN s.db.currentValues ELSE <<0,0,0>>,RecoveryTail),
    !.db.viewThrough=s.db.through, !.db.viewPresent=TRUE,
    !.status=IF Policy="liveOnly" /\ 5 \in Members(s.db.apps) THEN 1
       ELSE IF s.db.consumed THEN 3 ELSE IF 4 \in Members(s.db.apps) THEN 2 ELSE 1,
    !.admitted=Policy="replayConsent" /\ s.db.reserved /\ 4 \notin Members(s.db.apps)]
DuplicateScan == /\ Idle /\ Policy="liveOnly" /\ s.status=1
 /\ 5 \in Members(s.db.apps) /\ 6 \notin Members(s.db.apps)
 /\ s'=[s EXCEPT !.db.objects=Append(@,6), !.db.apps=Append(@,6),
                 !.db.actions=@ \cup {6}, !.db.through=@+1]
Deliver(o) == /\ o \in Members(s.db.apps) \ s.peerStored
 /\ s'=[s EXCEPT !.peerStored=@ \cup {o}]
PeerApply(o) == /\ o \in s.peerStored \ s.peerApplied
 /\ Parents(o) \subseteq s.peerApplied
 /\ s'=[s EXCEPT !.peerApplied=@ \cup {o}, !.peerValues=Step(@,o)]
Next == Reserve \/ Admit \/ WriteObject \/ WriteAction \/ WriteApplication
 \/ Commit \/ Abort \/ Ack \/ CaptureMaterialization \/ PublishMaterialization \/ RejectMaterialization \/ InvalidateMaterialization
 \/ ChangeRoot \/ ReplacePreview \/ VerifyFile \/ Settle \/ SettleDeleted
 \/ Crash \/ Recover \/ DuplicateScan
 \/ (\E o \in Ops: Begin(o) \/ AcceptRemote(o) \/ Deliver(o) \/ PeerApply(o) \/ RecoverAccept(o))
 \/ (\E v \in {0,2}: ChangeFile(v)) \/ (\E v \in {1,2}: Collect(v))
Spec == Init /\ [][Next]_vars
FairSpec == Spec \* No user/provider/disk progress assumption in action checks.

GroupAtomic == /\ Members(s.db.apps) \subseteq Members(s.db.objects)
 /\ Members(s.db.apps)=s.db.actions /\ s.db.through=Len(s.db.apps)
 /\ Cardinality(Members(s.db.apps))=Len(s.db.apps)
DependencyClosed == \A o \in Members(s.db.apps): Parents(o) \subseteq Members(s.db.apps)
ReadyQueueExact == s.db.ready=ReadyStored
AcknowledgedRecoverable == s.acknowledged => 4 \in Members(s.db.apps)
MaterializationTruth == s.db.viewPresent =>
 s.db.viewThrough<=Len(s.db.apps) /\
 s.db.currentValues=Expected(Members(SubSeq(s.db.apps,1,s.db.viewThrough)))
ObservationOwned == 4 \in Members(s.db.apps) => s.db.reserved \/ s.db.link \/ s.db.consumed
InputsRetained == /\ {s.db.latest,s.db.frozen} \ {0} \subseteq s.db.payloads
 /\ s.db.reserved /\ ~s.db.consumed => s.db.frozen=1 /\ 1 \in s.db.payloads
ReceiptAfterHistory == s.db.receipt => 4 \in Members(s.db.apps) /\ s.db.consumed
NoRepeatedImport == 6 \notin Members(s.db.apps)
PeerResult == s.peerValues=Expected(s.peerApplied)
Safety == GroupAtomic /\ DependencyClosed /\ ReadyQueueExact /\ AcknowledgedRecoverable /\ MaterializationTruth
 /\ ObservationOwned /\ InputsRetained /\ ReceiptAfterHistory /\ NoRepeatedImport /\ PeerResult
RecoveryExact == [][s.down /\ ~s'.down => s'.recovered=Expected(Members(s.db.apps))]_vars
NoReplayedConsent == [][s.down /\ ~s'.down => ~s'.admitted]_vars
FreshReceipt == [][~s.active /\ s'.active =>
 s.file=1 /\ s.root=0 /\ s.verified /\ 4 \in Members(s.db.apps) /\ 5 \notin Members(s.db.apps)]_vars
HistoryMonotonic == [][Members(s.db.apps) \subseteq Members(s'.db.apps)]_vars
StartupDrained == [][s.down /\ ~s'.down => ReadyStored={}]_vars
NeverLostCallbackRecovery == ~(s.reopens>0 /\ ~s.acknowledged /\ s.status=2 /\ 4 \in Members(s.db.apps))
NeverParkedRecovery == ~(s.reopens>0 /\ s.recovered[2]=2 /\ s.db.viewThrough=s.db.through)
NeverDeletedSettlement == ~(s.reopens=2 /\ s.db.consumed /\ 5 \in Members(s.db.apps) /\ s.recovered[1]=0)
NeverFrozenAndLatest == ~(s.db.latest=2 /\ s.db.frozen=1 /\ s.db.link)
NeverPeerDeleteFirst == ~(5 \in s.peerStored /\ 4 \notin s.peerStored /\ s.peerValues[1]=0)
=============================================================================
