-------------------- MODULE ImmutableSegmentDurabilitySafety --------------------
EXTENDS Naturals, FiniteSets

\* Proposal 5 experiment, NOT an implementation refinement proof.
\* Two successive full-state changes to one note, a separate unchanged note,
\* one writer crash/reopen, and one recipient. Bytes are exact finite payloads.
\* Local sealing, transaction preparation, atomic SQL acceptance and callback
\* delivery are separate actions. Only CommitAcceptance changes stable history.
\* One database writer owns the transaction. SQL atomicity/durability is an
\* explicit platform input; SQLCipher/VFS tests qualify it independently.
\* A receiver's durable installation is abstracted here;
\* SegmentDeletionSafety separately splits receive, durability and application.
\* History features: Payload is NOT an ActionRecord/note pair. This model
\* does not yet prove atomic undo-cursor/compensation recovery or merge views;
\* see impl-proposal-5/Verification.md for the additional required model gates.
\* materialization names represented inputs of a derived current view, not its
\* concrete row encoding or a requirement to embed every past operation.
\* Private Local State/settings, row codecs/quit UI and Finder backups are absent.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "earlyAck", "providerGated", "materializationPrunes",
                   "emptySerialize", "staleClear", "snapshotOnly", "ackOnlyRecovery", "multiWriter"}
       /\ Scenario \in {"crash", "offline"}
Changes == {1, 2}
Payload(r) == <<"note", r>>
Base == {<<"note", 0>>, <<"untouched", 7>>}
Latest(rs) == IF 2 \in rs THEN 2 ELSE IF 1 \in rs THEN 1 ELSE 0
Rows(rs) == {<<"note", Latest(rs)>>, <<"untouched", 7>>}

VARIABLE s
vars == <<s>>
Init == s = [
  count |-> 0, pending |-> 0, live |-> Base,
  stage |-> [r \in Changes |-> 0],
  bytes |-> [r \in Changes |-> {}],
  stable |-> [r \in Changes |-> {}],
  acknowledged |-> {}, provider |-> {}, receiver |-> {},
  captured |-> {}, materialization |-> {}, materializationPhase |-> 0,
  providerAvailable |-> Scenario # "offline",
  down |-> FALSE, crashed |-> FALSE, recovered |-> FALSE,
  materializationDropped |-> FALSE, pruned |-> FALSE]

Stored == {r \in Changes: s.stable[r] = {Payload(r)}}

Admit ==
 /\ ~s.down /\ ~s.crashed /\ s.count < 2
 /\ LET r == s.count + 1 IN
    s' = [s EXCEPT !.count = r, !.pending = r,
                    !.live = {<<"note",r>>, <<"untouched",7>>}]
Write(r) ==
 /\ ~s.down /\ ~s.crashed /\ r <= s.count /\ s.stage[r] = 0
 /\ (Policy # "providerGated" \/ s.providerAvailable)
 /\ s' = [s EXCEPT !.stage[r] = 1,
                    !.bytes[r] = IF Policy = "emptySerialize" THEN {} ELSE {Payload(r)}]
BeginAcceptance(r) ==
 /\ ~s.down /\ s.stage[r] = 1
 /\ (Policy="multiWriter" \/ \A other \in Changes: s.stage[other] \notin {2,3})
 /\ s' = [s EXCEPT !.stage[r] = 2]
StageMembership(r) ==
 /\ ~s.down /\ s.stage[r] = 2
 /\ s' = [s EXCEPT !.stage[r] = 3]
CommitAcceptance(r) ==
 /\ ~s.down /\ s.stage[r] = 3
 /\ s' = [s EXCEPT !.stage[r] = 4, !.stable[r] = s.bytes[r]]
Ack(r) ==
 /\ ~s.down /\ r \notin s.acknowledged
 /\ s.stage[r] >= (IF Policy = "earlyAck" THEN 3 ELSE 4)
 /\ s' = [s EXCEPT !.acknowledged = @ \cup {r},
       !.pending = IF Policy = "staleClear" \/ s.pending = r THEN 0 ELSE @]
Publish(r) ==
 /\ ~s.down /\ s.providerAvailable /\ r \in Stored \ s.provider
 /\ s' = [s EXCEPT !.provider = @ \cup {r}]
Receive(r) ==
 /\ r \in s.provider \ s.receiver
 /\ s' = [s EXCEPT !.receiver = @ \cup {r}]
CaptureMaterialization ==
 /\ ~s.down /\ s.materializationPhase = 0 /\ Stored # {}
 /\ s' = [s EXCEPT !.captured = Stored, !.materializationPhase = 1]
InstallMaterialization ==
 /\ ~s.down /\ s.materializationPhase = 1
 /\ s' = [s EXCEPT !.materialization = s.captured, !.materializationPhase = 2]
InvalidateMaterialization ==
 /\ ~s.materializationDropped /\ s.materializationPhase = 2
 /\ s' = [s EXCEPT !.materialization = {}, !.materializationDropped = TRUE]
PruneAfterMaterialization ==
 /\ Policy = "materializationPrunes" /\ ~s.pruned
 /\ s.materializationPhase = 2 /\ s.materialization # {}
 /\ s' = [s EXCEPT
       !.stable = [r \in Changes |-> IF r \in s.materialization THEN {} ELSE s.stable[r]],
       !.pruned = TRUE]
Crash ==
 /\ Scenario = "crash" /\ ~s.crashed
 /\ s' = [s EXCEPT !.down = TRUE, !.crashed = TRUE,
       !.live = {}, !.pending = 0,
       !.stage = [r \in Changes |-> IF r \in Stored THEN 4 ELSE 0],
       !.bytes = s.stable,
       !.captured = {},
       !.materializationPhase = IF s.materializationPhase = 2 THEN 2 ELSE 0]
Recover ==
 /\ s.down
 /\ s' = [s EXCEPT !.down = FALSE, !.recovered = TRUE,
       !.live = Rows(IF Policy = "snapshotOnly" THEN s.materialization
                    ELSE IF Policy = "ackOnlyRecovery" THEN s.acknowledged ELSE Stored)]
Next == Admit \/ CaptureMaterialization \/ InstallMaterialization \/ InvalidateMaterialization
     \/ PruneAfterMaterialization \/ Crash \/ Recover
     \/ (\E r \in Changes: Write(r) \/ BeginAcceptance(r) \/ StageMembership(r)
            \/ CommitAcceptance(r) \/ Ack(r) \/ Publish(r) \/ Receive(r))
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Admit)
  /\ \A r \in Changes: WF_vars(Write(r)) /\ WF_vars(BeginAcceptance(r))
       /\ WF_vars(StageMembership(r)) /\ WF_vars(CommitAcceptance(r)) /\ WF_vars(Ack(r))

TypeOK ==
 /\ s.count \in 0..2 /\ s.pending \in 0..2
 /\ s.stage \in [Changes -> 0..4]
 /\ s.bytes \in [Changes -> SUBSET {Payload(r): r \in Changes}]
 /\ s.stable \in [Changes -> SUBSET {Payload(r): r \in Changes}]
 /\ s.acknowledged \subseteq Changes /\ s.provider \subseteq Changes
 /\ s.receiver \subseteq Changes /\ s.captured \subseteq Changes
 /\ s.materialization \subseteq Changes /\ s.materializationPhase \in 0..2
 /\ s.live \subseteq {<<"note",0>>, <<"note",1>>, <<"note",2>>, <<"untouched",7>>}
 /\ \A field \in {"providerAvailable","down","crashed","recovered",
                       "materializationDropped","pruned"}: s[field] \in BOOLEAN

\* Independent per-record requirement, not equality with the encoder helper.
OneAcceptanceWriter == Cardinality({r \in Changes: s.stage[r] \in {2,3}}) <= 1
AcknowledgedBytesSurvive ==
 \A r \in s.acknowledged: s.stable[r] = {<<"note",r>>}
PendingLatestIsNotCleared ==
 ~s.crashed /\ s.count > 0 /\ s.count \notin s.acknowledged => s.pending = s.count
ReopenRetainsLatestAndUnchanged ==
 s.recovered =>
  /\ <<"untouched",7>> \in s.live
  /\ (2 \in s.acknowledged => <<"note",2>> \in s.live)
  /\ (s.acknowledged = {1} =>
        (<<"note",1>> \in s.live \/ <<"note",2>> \in s.live))
UnpublishedHistoryRemainsSendable == s.acknowledged \ s.provider \subseteq Stored
ReceiverHasSourceBytes == s.receiver \subseteq s.provider /\ s.provider \subseteq Stored
\* Durability does not depend on a completion callback having reached AppKit.
ReopenIncludesUnacknowledgedInstall == s.recovered =>
 /\ <<"untouched",7>> \in s.live
 /\ (s.stable[2] = {<<"note",2>>} => <<"note",2>> \in s.live)
 /\ (s.stable[2] = {} /\ s.stable[1] = {<<"note",1>>} => <<"note",1>> \in s.live)
Safety == OneAcceptanceWriter /\ AcknowledgedBytesSurvive /\ PendingLatestIsNotCleared
       /\ ReopenRetainsLatestAndUnchanged /\ UnpublishedHistoryRemainsSendable
       /\ ReceiverHasSourceBytes /\ ReopenIncludesUnacknowledgedInstall
OfflineDurability == <> (s.acknowledged = Changes /\ s.pending = 0)

\* False invariants are reachability checks; each must produce its own trace.
NeverRebuiltMaterialization == ~(s.recovered /\ s.materialization = {}
    /\ 2 \in s.acknowledged /\ <<"note",2>> \in s.live)
NeverReceivedAfterWriterCrash == ~(s.recovered /\ s.receiver = Changes)
NeverHandledStaleCompletion == ~(s.count = 2 /\ s.acknowledged = {1} /\ s.pending = 2)
NeverRecoveredWithoutCallback == ~(s.recovered /\ s.acknowledged = {}
 /\ s.stable[2] = {<<"note",2>>} /\ <<"note",2>> \in s.live)
=============================================================================
