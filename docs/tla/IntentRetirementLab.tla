-------------------------- MODULE IntentRetirementLab --------------------------
EXTENDS Naturals, FiniteSets
\* EXPERIMENT: sender has two immutable, already-valid intent operations.
\* This tests metadata retirement only, not file binding or cloud durability.
\* pinnedSnapshot REQUIRES a correctly selected complete bootstrap snapshot
\* reference from outside a restored stale backup. No Apple API supplies that
\* authority here. Stale reads are rejected, not magically made current.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"retain","maxAck","acksOnly","snapshot","pinnedSnapshot"}
ASSUME Scenario \in {"current","staleRead"}
Events == {1,2}
VARIABLE r
vars == <<r>>
Init == r = [objects |-> Events, learned |-> {}, durable |-> {}, ack |-> {},
 everDurable |-> {}, prepared |-> FALSE, sealed |-> FALSE, snapshot |-> {},
 observed |-> {}, fetched |-> FALSE, retired |-> {}, backup |-> FALSE,
 ready |-> TRUE, resurrected |-> FALSE, newcomer |-> {}, bootstrapped |-> FALSE]
Receive(e) ==
 /\ e \in r.objects /\ e \notin r.learned
 /\ r' = [r EXCEPT !.learned = @ \cup {e}]
Barrier ==
 /\ r.learned # r.durable
 /\ r' = [r EXCEPT !.durable = r.learned, !.everDurable = @ \cup r.learned]
Ack ==
 /\ LET a == IF Policy = "maxAck" /\ 2 \in r.durable THEN Events ELSE r.durable
    IN /\ ~ (a \subseteq r.ack)
       /\ r' = [r EXCEPT !.ack = @ \cup a]
PrepareSnapshot ==
 /\ Policy \in {"snapshot","pinnedSnapshot"} /\ ~r.prepared
 /\ r' = [r EXCEPT !.prepared = TRUE]
SnapshotBarrier ==
 /\ r.prepared /\ ~r.sealed
 /\ r' = [r EXCEPT !.snapshot = Events, !.sealed = TRUE]
Collect(e) ==
 /\ Policy # "retain" /\ e \in r.objects \cap r.ack
 /\ (Policy \notin {"snapshot","pinnedSnapshot"} \/ r.sealed)
 /\ r' = [r EXCEPT !.objects = @ \ {e}, !.retired = @ \cup {e}]
FetchSnapshot ==
 /\ r.sealed
 /\ \E value \in IF Scenario = "staleRead" THEN {r.snapshot,{}} ELSE {r.snapshot}:
     /\ ~r.fetched \/ value # r.observed
     /\ r' = [r EXCEPT !.observed = value, !.fetched = TRUE]
\* The equality below abstracts validation against an explicitly selected
\* immutable reference, not a largest timestamp or "current" provider flag.
BootstrapAllowed == Policy # "pinnedSnapshot" \/ (r.fetched /\ r.observed = Events)
BootstrapNewcomer ==
 /\ ~r.bootstrapped /\ BootstrapAllowed
 /\ r' = [r EXCEPT !.newcomer = r.objects \cup r.observed, !.bootstrapped = TRUE]
RestoreOldBackup ==
 /\ ~r.backup /\ r.ack = Events
 /\ r' = [r EXCEPT !.backup = TRUE, !.learned = {}, !.durable = {},
      !.fetched = FALSE, !.observed = {}, !.ready = Policy # "pinnedSnapshot"]
Rejoin ==
 /\ r.backup /\ ~r.ready /\ BootstrapAllowed
 /\ r' = [r EXCEPT !.learned = r.observed, !.durable = r.observed,
      !.everDurable = @ \cup r.observed, !.ready = TRUE]
ReplayOldAddition ==
 /\ r.backup /\ r.ready /\ 1 \notin r.durable /\ ~r.resurrected
 /\ r' = [r EXCEPT !.resurrected = TRUE]
Next == (\E e \in Events: Receive(e) \/ Collect(e)) \/ Barrier \/ Ack
 \/ PrepareSnapshot \/ SnapshotBarrier \/ FetchSnapshot \/ BootstrapNewcomer
 \/ RestoreOldBackup \/ Rejoin \/ ReplayOldAddition
Spec == Init /\ [][Next]_vars
TypeOK ==
 /\ \A x \in {r.objects,r.learned,r.durable,r.ack,r.everDurable,r.snapshot,
                r.observed,r.retired,r.newcomer}: x \subseteq Events
 /\ \A x \in {r.prepared,r.sealed,r.fetched,r.backup,r.ready,
                r.resurrected,r.bootstrapped}: x \in BOOLEAN
NoAckForUnseenOperation == r.ack \subseteq r.everDurable
NoNewcomerHistoryLoss == r.bootstrapped => r.newcomer = Events
NoBackupResurrection == ~r.resurrected
RetiredHistoryStillAvailable == r.retired \subseteq r.snapshot \cup r.durable
NeverCollectedAll == r.retired # Events
NeverRejoinedAfterCollection == ~(r.retired = Events /\ r.backup /\ r.ready /\ r.durable = Events)
NeverBootstrappedAfterCollection == ~(r.retired = Events /\ r.bootstrapped /\ r.newcomer = Events)
NeverRejectedStaleSnapshot == ~(r.retired = Events /\ r.fetched /\ r.observed = {} /\ ~BootstrapAllowed)
Safety == NoAckForUnseenOperation /\ NoNewcomerHistoryLoss /\ NoBackupResurrection
 /\ RetiredHistoryStillAvailable
=============================================================================
