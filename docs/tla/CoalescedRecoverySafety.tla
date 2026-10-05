------------------------ MODULE CoalescedRecoverySafety ------------------------
EXTENDS Naturals, Integers, FiniteSets
\* Five retained batches: create, edit, inverse, redo, context-only change.
\* Prepared rows use an explicit fold; Expected is an independent fixture table.
\* Acceptance, worker preparation, derived installation, settings and publication
\* are distinct. One epoch replacement and two crashes bound interference.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","omitUndo","staleTarget","staleEpoch","resetSettings"}
 /\ Scenario="coalesced"
VARIABLE s
vars == <<s>>
InitialRows == <<0,9>>
Expected(k) == CASE k \in {1,3} -> <<0,9>> [] OTHER -> <<1,9>>
Step(v,k) == CASE k=1 -> InitialRows [] k=2 -> <<v[1]+1,v[2]>>
 [] k=3 -> IF Policy="omitUndo" THEN v ELSE <<v[1]-1,v[2]>>
 [] k=4 -> <<v[1]+1,v[2]>> [] OTHER -> v
RECURSIVE Fold(_)
Fold(k) == IF k=1 THEN Step(InitialRows,1) ELSE Step(Fold(k-1),k)
NoPreparation == [start |-> 0, epoch |-> 0, target |-> 0, rows |-> InitialRows, context |-> 0]
Init == s=[accepted |-> 1, view |-> 1, rows |-> InitialRows, context |-> 1,
 epoch |-> 1, settings |-> 7, prepared |-> NoPreparation, down |-> FALSE,
 crashes |-> 0, replaced |-> FALSE, published |-> FALSE, rejected |-> FALSE,
 coalesced |-> FALSE, settingsChanged |-> FALSE, publishedAt |-> 0]
Accept == /\ ~s.down /\ s.accepted<5 /\ s'=[s EXCEPT !.accepted=@+1, !.published=FALSE]
Prepare == /\ ~s.down /\ s.view<s.accepted /\ s.prepared=NoPreparation
 /\ s'=[s EXCEPT !.prepared=[start |-> s.view, epoch |-> s.epoch,
       target |-> s.accepted, rows |-> Fold(s.accepted), context |-> s.accepted]]
Applicable == s.prepared.start=s.view /\ s.prepared.epoch=s.epoch /\ s.prepared.target=s.accepted
Install == /\ ~s.down /\ s.prepared#NoPreparation
 /\ s.prepared.start=s.view
 /\ (Policy="staleEpoch" \/ s.prepared.epoch=s.epoch)
 /\ (Policy="staleTarget" \/ s.prepared.target=s.accepted)
 /\ s'=[s EXCEPT !.view=s.prepared.target, !.rows=s.prepared.rows,
      !.context=s.prepared.context, !.epoch=IF @=1 THEN 2 ELSE @,
      !.settings=IF Policy="resetSettings" THEN 7 ELSE @,
      !.coalesced=@ \/ s.prepared.target-s.view>1, !.prepared=NoPreparation]
Reject == /\ ~s.down /\ s.prepared#NoPreparation /\ ~Applicable
 /\ s'=[s EXCEPT !.prepared=NoPreparation, !.rejected=TRUE]
ChangeEpoch == /\ ~s.down /\ ~s.replaced /\ s.prepared#NoPreparation
 /\ s'=[s EXCEPT !.epoch=IF @=1 THEN 2 ELSE 1, !.replaced=TRUE]
ChangeSettings == /\ ~s.down /\ ~s.settingsChanged
 /\ s'=[s EXCEPT !.settings=8, !.settingsChanged=TRUE]
Publish == /\ ~s.down /\ s.view=s.accepted /\ ~s.published
 /\ s'=[s EXCEPT !.published=TRUE, !.publishedAt=s.accepted]
Crash == /\ ~s.down /\ s.crashes<2
 /\ s'=[s EXCEPT !.down=TRUE, !.crashes=@+1, !.prepared=NoPreparation, !.published=FALSE]
Reopen == /\ s.down /\ s'=[s EXCEPT !.down=FALSE]
Next == Accept \/ Prepare \/ Install \/ Reject \/ ChangeEpoch \/ ChangeSettings \/ Publish \/ Crash \/ Reopen
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Accept) /\ WF_vars(Prepare) /\ WF_vars(Install)
 /\ WF_vars(Reject) /\ WF_vars(Publish) /\ WF_vars(Reopen)
TypeOK == /\ s.accepted \in 1..5 /\ s.view \in 1..s.accepted
 /\ s.rows \in (-1..2) \X (9..9) /\ s.context \in 1..5
 /\ s.epoch \in 1..2 /\ s.settings \in {7,8} /\ s.crashes \in 0..2
 /\ \A k \in {"down","replaced","published","rejected","coalesced","settingsChanged"}: s[k] \in BOOLEAN
RowsAndContextExact == s.rows=Expected(s.view) /\ s.context=s.view
PrivateSettingsPreserved == s.settingsChanged => s.settings=8
InstallationFresh == [][s'.view#s.view => Applicable]_vars
HistoryPreserved == [][s'.accepted>=s.accepted]_vars
PublicationExact == s.published => s.rows=Expected(s.publishedAt) /\ s.context=s.publishedAt
EventuallyComplete == <> (s.accepted=5 /\ s.view=5 /\ s.published)
NeverCoalesced == ~s.coalesced
NeverRejectedThenRecovered == ~(s.rejected /\ s.view=5 /\ s.published)
NeverTwoCrashesRecovered == ~(s.crashes=2 /\ s.view=5 /\ s.published)
=============================================================================
