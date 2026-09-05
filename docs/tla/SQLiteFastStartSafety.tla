------------------------- MODULE SQLiteFastStartSafety -------------------------
EXTENDS Naturals, FiniteSets
\* Private current-row startup, CKPT-01/START-01. Atomic SQLite transactions
\* are an input, not a proof of SQLite. Three batches: create two notes, delete
\* one, change only the other's authoring context. Expected is independent of
\* incremental Apply. One rebuild epoch and one crash/reopen bound the fixture.
\* DiscoverDamage includes durable recording of the observation. The concrete
\* runtime blocks immediately on detection, then attempts its private marker
\* transaction; interruption/failure before that marker commits is a separate
\* physical qualification boundary, not an atomic step proved by this model.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","omitDelete","omitContext","staleStartup","staleEpoch","ignoreDamage"}
 /\ Scenario = "fast-start"
VARIABLE s
vars == <<s>>
Empty == [n \in 1..2 |-> <<0,0>>]
Expected(k) == CASE k=0 -> Empty
 [] k=1 -> [n \in 1..2 |-> <<n,1>>]
 [] k=2 -> [n \in 1..2 |-> IF n=1 THEN <<0,0>> ELSE <<2,1>>]
 [] OTHER -> [n \in 1..2 |-> IF n=1 THEN <<0,0>> ELSE <<2,3>>]
Apply(v,k) == CASE k=1 -> [v EXCEPT ![1]= <<1,1>>, ![2]= <<2,1>>]
 [] k=2 -> IF Policy="omitDelete" THEN v ELSE [v EXCEPT ![1]= <<0,0>>]
 [] OTHER -> IF Policy="omitContext" THEN v ELSE [v EXCEPT ![2]= <<2,3>>]
NoPrepared == [cut |-> 0, epoch |-> 0, rows |-> Empty, context |-> 0]
Init == s=[accepted |-> 0, view |-> 0, rows |-> Empty, context |-> 0,
 epoch |-> 0, prepared |-> NoPrepared, published |-> NoPrepared,
 publishedAt |-> 0, damaged |-> FALSE, crashed |-> FALSE, reopened |-> FALSE,
 rejected |-> FALSE]
Accept == /\ s.accepted<3 /\ s'=[s EXCEPT !.accepted=@+1]
Materialize == /\ s.view<s.accepted
 /\ LET k==s.view+1 IN s'=[s EXCEPT !.view=k, !.rows=Apply(@,k), !.context=k]
RebuildEpoch == /\ s.epoch=0 /\ s.view>0
 /\ s'=[s EXCEPT !.epoch=1]
Prepare == /\ s.view=s.accepted /\ s.view>0 /\ ~s.damaged
 /\ s.prepared=NoPrepared
 /\ s'=[s EXCEPT !.prepared=[cut |-> s.view, epoch |-> s.epoch,
                            rows |-> s.rows, context |-> s.context]]
Applicable == /\ s.prepared.cut=s.view /\ s.view=s.accepted
 /\ s.prepared.epoch=s.epoch /\ ~s.damaged
PublishModel == /\ s.prepared#NoPrepared /\ s.published#s.prepared
 /\ (Policy="staleStartup" \/ (s.prepared.cut=s.view /\ s.view=s.accepted))
 /\ (Policy="staleEpoch" \/ s.prepared.epoch=s.epoch)
 /\ (Policy="ignoreDamage" \/ ~s.damaged)
 /\ s'=[s EXCEPT !.published=s.prepared, !.publishedAt=s.accepted]
DropPrepared == /\ s.prepared#NoPrepared
 /\ s'=[s EXCEPT !.prepared=NoPrepared, !.rejected=@ \/ ~Applicable]
DiscoverDamage == /\ s.view>0 /\ ~s.damaged
 /\ s'=[s EXCEPT !.damaged=TRUE]
Crash == /\ ~s.crashed
 /\ s'=[s EXCEPT !.crashed=TRUE, !.prepared=NoPrepared,
                 !.published=NoPrepared, !.publishedAt=0]
Reopen == /\ s.crashed /\ ~s.reopened /\ s'=[s EXCEPT !.reopened=TRUE]
Next == Crash \/ Reopen \/
 ((~s.crashed \/ s.reopened) /\
  (Accept \/ Materialize \/ RebuildEpoch \/ Prepare \/ PublishModel
   \/ DropPrepared \/ DiscoverDamage))
Spec == Init /\ [][Next]_vars
FairSpec == Spec \* No unconditional progress claim.
TypeOK == /\ s.accepted \in 0..3 /\ s.view \in 0..s.accepted
 /\ s.context \in 0..3 /\ s.epoch \in 0..1
 /\ s.rows \in [1..2 -> (0..3) \X (0..3)]
 /\ \A k \in {"damaged","crashed","reopened","rejected"}: s[k] \in BOOLEAN
MaterializationExact == s.rows=Expected(s.view) /\ s.context=s.view
PublishedExact == s.published#NoPrepared =>
 s.published.rows=Expected(s.publishedAt) /\ s.published.context=s.publishedAt
PublicationEpoch == [][s'.published#s.published /\ s'.published#NoPrepared =>
 s'.published.epoch=s.epoch]_vars
NoKnownDamagePublication == [][s'.published#s.published /\ s'.published#NoPrepared =>
 ~s.damaged]_vars
HistorySurvives == [][s'.accepted>=s.accepted]_vars
Safety == MaterializationExact /\ PublishedExact
NeverDeleteContext == ~(s.publishedAt=3 /\ s.published.rows=Expected(3))
NeverReopened == ~(s.reopened /\ s.publishedAt=3)
NeverRejectedAndRecovered == ~(s.rejected /\ s.reopened /\ s.publishedAt=3)
=============================================================================
