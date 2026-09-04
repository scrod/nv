---------------------- MODULE CausalIncarnationSafety ----------------------
EXTENDS Naturals, FiniteSets

\* EXPERIMENT: stable local UUIDs already bind to birth dots. This does NOT
\* solve initial cross-host file association or authenticate copied metadata.
\* One xattr/checkpoint envelope is a last-writer register, NOT a CRDT server.
\* Explicit complete exchange tests merge algebra without assuming iCloud
\* will deliver every overwritten envelope. All local admissions here are
\* already durable; byte-level WAL/barrier implementation is outside the model.
CONSTANTS Policy, Scenario
Policies == {"causal","uuidDelete","dropContext","registerOnly","maxClock"}
ASSUME Policy \in Policies /\ Scenario \in {"restore","gap"}
Hosts == {1,2}
Dots == {1,2}
Envelope(live,seen,deleted) == [live |-> live, seen |-> seen, deleted |-> deleted]
Empty == Envelope({},{},FALSE)
Context(e) == IF Policy = "maxClock" /\ 2 \in e.seen THEN Dots ELSE e.seen
Merge(a,b) ==
 LET present == (a.live \cap b.live) \cup (a.live \ Context(b)) \cup (b.live \ Context(a))
 IN Envelope(IF Policy = "uuidDelete" /\ (a.deleted \/ b.deleted) THEN {} ELSE present,
             Context(a) \cup Context(b), a.deleted \/ b.deleted)
HasRemoval(e) == 1 \in e.seen /\ 1 \notin e.live

VARIABLE s
vars == <<s>>
Init ==
 LET initial == [h \in Hosts |-> IF Scenario = "gap" THEN Envelope({h},{h},FALSE)
                                ELSE Envelope({1},{1},FALSE)]
 IN s = [localUUID |-> [h \in Hosts |-> h], replica |-> initial,
      durable |-> initial, current |-> Empty, published |-> {},
      done |-> IF Scenario = "gap" THEN Hosts ELSE {},
      removed |-> [h \in Hosts |-> FALSE],
      protected |-> [h \in Hosts |-> IF Scenario = "gap" THEN {h} ELSE {}],
      down |-> FALSE, crashed |-> FALSE, recovered |-> FALSE,
      exchange |-> "idle", captured |-> [h \in Hosts |-> Empty], remaining |-> {}]
Up(h) == h # 1 \/ ~s.down

DeleteOriginal ==
 /\ Scenario = "restore" /\ 1 \notin s.done /\ Up(1)
 /\ LET kept == s.replica[1].live \ {1}
        after == Envelope(kept,IF Policy = "dropContext" THEN kept ELSE s.replica[1].seen,TRUE)
    IN s' = [s EXCEPT !.replica[1] = after, !.durable[1] = after,
          !.done = @ \cup {1}, !.removed[1] = TRUE]
RestoreFresh ==
 /\ Scenario = "restore" /\ 2 \notin s.done
 \* Restore gets a fresh birth, not merely a new timestamp on the old UUID.
 /\ LET after == Envelope({2},{1,2},s.replica[2].deleted)
    IN s' = [s EXCEPT !.replica[2] = after, !.durable[2] = after,
          !.done = @ \cup {2}, !.protected[2] = {2}, !.removed[2] = TRUE]
Publish(h) ==
 /\ Up(h) /\ (s.current # s.replica[h] \/ h \notin s.published)
 /\ s' = [s EXCEPT !.current = s.replica[h], !.published = @ \cup {h}]
Receive(h) ==
 /\ Up(h)
 /\ LET after == Merge(s.replica[h],s.current)
    IN /\ after # s.replica[h]
       /\ s' = [s EXCEPT !.replica[h] = after, !.durable[h] = after,
            !.removed[h] = @ \/ (Scenario = "restore" /\ HasRemoval(s.current)),
            !.protected[h] = @ \cup (s.current.live \ {1})]
Crash ==
 /\ ~s.crashed /\ 1 \in s.done /\ s.published = Hosts
 /\ s' = [s EXCEPT !.down = TRUE, !.crashed = TRUE, !.replica[1] = Empty,
      \* Negative policy mistakes own xattr publication for durable coverage.
      !.durable[1] = IF Policy = "registerOnly" THEN Empty ELSE @]
Recover ==
 /\ s.down
 /\ s' = [s EXCEPT !.down = FALSE, !.recovered = TRUE,
      !.replica[1] = Merge(s.durable[1],s.current)]

CaptureExchange ==
 /\ s.done = Hosts /\ ~s.down /\ s.exchange = "idle"
 /\ s' = [s EXCEPT !.exchange = "delivering", !.captured = s.replica,
                  !.remaining = Hosts]
DeliverExchange(h) ==
 /\ s.exchange = "delivering" /\ h \in s.remaining /\ Up(h)
 /\ LET other == s.captured[3-h]
        after == Merge(s.replica[h],other)
    IN s' = [s EXCEPT !.replica[h] = after, !.durable[h] = after,
         !.removed[h] = @ \/ (Scenario = "restore" /\ HasRemoval(other)),
         !.protected[h] = @ \cup (other.live \ {1}),
         !.remaining = @ \ {h},
         !.exchange = IF s.remaining = {h} THEN "complete" ELSE @]
Next == DeleteOriginal \/ RestoreFresh \/ Crash \/ Recover \/ CaptureExchange
 \/ (\E h \in Hosts: Publish(h) \/ Receive(h) \/ DeliverExchange(h))
Spec == Init /\ [][Next]_vars

TypeOK ==
 /\ s.localUUID = [h \in Hosts |-> h]
 /\ s.replica \in [Hosts -> [live: SUBSET Dots, seen: SUBSET Dots, deleted: BOOLEAN]]
 /\ s.durable \in [Hosts -> [live: SUBSET Dots, seen: SUBSET Dots, deleted: BOOLEAN]]
 /\ s.current \in [live: SUBSET Dots, seen: SUBSET Dots, deleted: BOOLEAN]
 /\ s.done \subseteq Hosts /\ s.published \subseteq Hosts /\ s.remaining \subseteq Hosts
 /\ s.protected \in [Hosts -> SUBSET Dots] /\ s.removed \in [Hosts -> BOOLEAN]
 /\ s.exchange \in {"idle","delivering","complete"}
 /\ s.down \in BOOLEAN /\ s.crashed \in BOOLEAN /\ s.recovered \in BOOLEAN
LiveDotsHaveContext == \A h \in Hosts: s.replica[h].live \subseteq s.replica[h].seen
NoResurrectionAfterObservedRemoval == \A h \in Hosts:
 Up(h) /\ s.removed[h] => 1 \notin s.replica[h].live
NoLostProtectedBirth == \A h \in Hosts:
 Up(h) => s.protected[h] \subseteq s.replica[h].live
CompleteExchangeAgrees == s.exchange = "complete" /\ ~s.down => s.replica[1] = s.replica[2]
NeverPreservedFreshRestore == ~(s.exchange = "complete" /\ Scenario = "restore"
 /\ s.replica[1].live = {2} /\ s.replica[2].live = {2})
NeverMergedUnseenBirths == ~(s.exchange = "complete" /\ Scenario = "gap"
 /\ s.replica[1].live = Dots /\ s.replica[2].live = Dots)
NeverRecoveredDeletion == ~(s.recovered /\ s.removed[1] /\ 1 \notin s.replica[1].live)
=============================================================================
