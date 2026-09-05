---------------------- MODULE PendingReferenceSafety ----------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "earlyReference", "earlyCleanup", "staleSwitch", "forgetFrozen"}
 /\ Scenario \in {"replace", "first", "reservation"}
VARIABLE s
vars == <<s>>
\* One private-state replacement, two exact payloads and one crash. File/name
\* barriers are distinct. Before the metadata directory barrier, recovery may
\* observe either metadata generation. This is an installer contract model,
\* not proof of fsync, encryption, the Local State codec or hardware behavior.
\* SwitchedStale/pinned/recovered record audit obligations and witnesses;
\* write/validation failures may stutter. No automatic retry liveness is claimed.
Old == IF Scenario="first" THEN 0 ELSE 1
Refs(m) == {m.latest,m.frozen} \ {0}
Initial == [generation |-> 0, latest |-> Old, frozen |-> 0]
Init == s=[durable |-> IF Old=0 THEN {} ELSE {1}, written |-> FALSE,
 synced |-> FALSE, named |-> FALSE, disk |-> Initial, stable |-> Initial,
 phase |-> "idle", liveGeneration |-> 0, captured |-> 0,
 down |-> FALSE, crashed |-> FALSE, recovered |-> FALSE,
 switchedStale |-> FALSE, pinned |-> FALSE]
Prepare == /\ ~s.down /\ s.phase="idle"
 /\ s'=[s EXCEPT !.phase="prepared", !.captured=s.liveGeneration]
WritePayload == /\ s.phase="prepared" /\ ~s.down
 /\ s'=[s EXCEPT !.written=TRUE, !.phase="written"]
SyncPayload == /\ s.phase="written" /\ ~s.down
 /\ s'=[s EXCEPT !.synced=TRUE, !.phase="synced"]
InstallName == /\ s.phase="synced" /\ ~s.down
 /\ s'=[s EXCEPT !.named=TRUE, !.phase="named"]
SyncPayloadDirectory == /\ s.phase="named" /\ ~s.down
 /\ s'=[s EXCEPT !.durable=@ \cup {2}, !.phase="ready"]
\* Another preview decision/cancel can invalidate a prepared reference update.
Invalidate == /\ ~s.down /\ s.liveGeneration=0
 /\ s'=[s EXCEPT !.liveGeneration=1]
\* The frozen operation owns old bytes independently of the latest preview.
PinOld == /\ Scenario="reservation" /\ ~s.down /\ s.phase="idle" /\ ~s.pinned
 /\ s'=[s EXCEPT !.disk.frozen=1, !.stable.frozen=1, !.pinned=TRUE]
InstallReference == /\ ~s.down
 /\ (s.phase="ready" \/ (Policy="earlyReference" /\ s.phase="named"))
 /\ (s.captured=s.liveGeneration \/ Policy="staleSwitch")
 /\ s'=[s EXCEPT !.disk=[generation |-> 1, latest |-> 2,
       frozen |-> IF Policy="forgetFrozen" THEN 0 ELSE s.stable.frozen],
       !.phase="reference", !.switchedStale=@ \/ s.captured # s.liveGeneration]
SyncReferenceDirectory == /\ ~s.down /\ s.phase="reference"
 /\ s'=[s EXCEPT !.stable=s.disk, !.phase="done"]
Collect(v) == /\ ~s.down /\ v \in s.durable
 /\ ~(v=2 /\ s.phase \in {"prepared","written","synced","named","ready","reference"})
 /\ v \notin Refs(s.disk)
 /\ (v \notin Refs(s.stable) \/ Policy="earlyCleanup")
 /\ s'=[s EXCEPT !.durable=@ \ {v}]
\* Checked metadata persistence is the commit point. If it did not complete,
\* namespace recovery can choose the installed or prior complete state.
Crash(m) == /\ ~s.crashed /\ m \in {s.disk,s.stable}
 /\ s'=[s EXCEPT !.down=TRUE, !.crashed=TRUE, !.disk=m, !.stable=m,
                 !.written=FALSE, !.synced=FALSE, !.named=FALSE, !.phase="crashed"]
Recover == /\ s.down
 /\ s'=[s EXCEPT !.down=FALSE, !.recovered=TRUE, !.phase="recovered"]
Next == Prepare \/ WritePayload \/ SyncPayload \/ InstallName \/ SyncPayloadDirectory
 \/ Invalidate \/ PinOld \/ InstallReference \/ SyncReferenceDirectory
 \/ (\E v \in 1..2: Collect(v)) \/ (\E m \in {s.disk,s.stable}: Crash(m)) \/ Recover
Spec == Init /\ [][Next]_vars
StateType == [generation:0..1, latest:0..2, frozen:0..1]
TypeOK == /\ s.disk \in StateType /\ s.stable \in StateType
 /\ s.durable \subseteq 1..2 /\ s.liveGeneration \in 0..1 /\ s.captured \in 0..1
 /\ s.phase \in {"idle","prepared","written","synced","named","ready","reference","done","crashed","recovered"}
 /\ \A k \in {"written","synced","named","down","crashed","recovered","switchedStale","pinned"}: s[k] \in BOOLEAN
EveryRecoverableReferenceHasBytes == Refs(s.disk) \cup Refs(s.stable) \subseteq s.durable
FrozenInputSurvives == s.pinned => 1 \in s.durable
NoStaleReferenceSwitch == ~s.switchedStale
Safety == EveryRecoverableReferenceHasBytes /\ FrozenInputSurvives /\ NoStaleReferenceSwitch
NeverRecoveredOld == ~(s.recovered /\ s.disk.latest=1)
NeverRecoveredNew == ~(s.recovered /\ s.disk.latest=2)
NeverReleasedOld == ~(s.phase="done" /\ 1 \notin s.durable)
NeverKeptFrozenAndNew == ~(s.phase="done" /\ s.disk.latest=2 /\ s.disk.frozen=1 /\ {1,2} \subseteq s.durable)
=============================================================================
