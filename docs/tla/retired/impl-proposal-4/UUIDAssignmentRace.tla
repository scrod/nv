----------------------- MODULE UUIDAssignmentRace -----------------------
EXTENDS Naturals, FiniteSets

\* EXPERIMENT, not a refinement of the adopted no-xattr policy.
\* Two hosts independently import ONE file, capture competing initial tags,
\* edit, and close. Initial writes use host-local observations: there is no
\* cross-host compare-and-swap on an absent xattr. Provider delivery is separate.
\* scoped requires a positive same-file association for the checkpoint rows;
\* UUIDAssociationLab tests when that premise is unavailable or insufficient.
CONSTANTS Policy, Mode
Policies == {"database", "restamp", "xattr", "eagerMinimum", "minimum", "aliases", "scoped", "stable"}
ASSUME Policy \in Policies /\ Mode \in {"settle", "close"}
Hosts == {1,2}
IDs == {1,2}
Min(xs) == CHOOSE n \in xs: \A m \in xs: n <= m
Row(id, edits, claims) == [id |-> id, edits |-> edits, claims |-> claims]
Edits(rows) == UNION {r.edits: r \in rows}
Claims(rows) == UNION {r.claims: r \in rows}
ByID(rows) ==
 {Row(id, UNION {r.edits: r \in {q \in rows: q.id = id}},
          UNION {r.claims: r \in {q \in rows: q.id = id}}):
     id \in {r.id: r \in rows}}
\* Two-ID bound makes overlap closure either singleton or the whole set.
AliasMerge(rows) ==
 LET both == \E r \in rows: r.claims = IDs
 IN ByID({Row(IF both THEN 1 ELSE r.id, r.edits,
                 IF both THEN IDs ELSE r.claims): r \in rows})
ScopedMerge(rows) ==
 IF rows = {} THEN {} ELSE {Row(Min(Claims(rows)),Edits(rows),Claims(rows))}
Combine(rows) ==
 CASE Policy \in {"scoped","stable"} -> ScopedMerge(rows)
   [] Policy = "aliases" -> AliasMerge(rows)
   [] OTHER -> ByID(rows)

VARIABLE s
vars == <<s>>
Init == s = [imported |-> {}, stamped |-> {}, edited |-> {},
 tag |-> 0, view |-> [h \in Hosts |-> 0], id |-> [h \in Hosts |-> 0],
 proposal |-> [h \in Hosts |-> 0], aliases |-> [h \in Hosts |-> {}],
 wal |-> [h \in Hosts |-> {}],
 phase |-> [h \in Hosts |-> "active"], captured |-> [h \in Hosts |-> {}],
 incoming |-> [h \in Hosts |-> {}], result |-> [h \in Hosts |-> {}],
 expected |-> [h \in Hosts |-> 0], version |-> 0, checkpoint |-> {},
 committed |-> {}, recovered |-> [h \in Hosts |-> {}]]

Import(h) ==
 /\ h \notin s.imported
 /\ LET id == IF Policy # "database" /\ s.view[h] # 0 THEN s.view[h] ELSE h
    IN s' = [s EXCEPT !.imported = @ \cup {h}, !.id[h] = id,
         !.proposal[h] = id, !.aliases[h] = {id}]
StampInitial(h) ==
 /\ h \in s.imported /\ h \notin s.stamped
 /\ s' = [s EXCEPT !.stamped = @ \cup {h},
      !.tag = IF Policy = "database" THEN 0 ELSE s.proposal[h],
      !.view[h] = IF Policy = "database" THEN 0 ELSE s.proposal[h]]
Edit(h) ==
 /\ h \in s.imported /\ h \notin s.edited
 \* An already-durable record keeps its ORIGINAL UUID across later reassignment.
 /\ s' = [s EXCEPT !.edited = @ \cup {h},
      !.wal[h] = {Row(s.id[h],{h},{s.id[h]})}]
Deliver(h) ==
 /\ s.view[h] # s.tag
 /\ s' = [s EXCEPT !.view[h] = s.tag]
ReconcileTag(h) ==
 /\ h \in s.stamped /\ s.phase[h] = "active"
 /\ s.view[h] # 0 /\ Policy # "database"
 /\ LET learned == s.aliases[h] \cup {s.id[h],s.view[h]}
        id == CASE Policy \in {"restamp","stable"} -> s.id[h]
                [] Policy = "xattr" -> s.view[h]
                [] OTHER -> Min(learned)
        aliases == IF Policy \in {"aliases","scoped","stable"} THEN learned ELSE {id}
        winner == IF Policy = "stable" THEN Min(learned) ELSE id
        \* Normal policies write only to correct a locally observed value.
        \* eagerMinimum instead periodically restamps even without new input.
        write == Policy # "xattr" /\ (Policy = "eagerMinimum" \/ winner # s.view[h])
        tag == IF write THEN winner ELSE s.tag
        view == IF write THEN winner ELSE s.view[h]
    IN /\ <<id,aliases,tag,view>> # <<s.id[h],s.aliases[h],s.tag,s.view[h]>>
       /\ s' = [s EXCEPT !.id[h] = id, !.aliases[h] = aliases,
                 !.tag = tag, !.view[h] = view]

Prepare(h) ==
 /\ Mode = "close" /\ h \in s.edited \cap s.stamped
 /\ s.phase[h] = "active"
 /\ s' = [s EXCEPT !.phase[h] = "attempt",
      !.captured[h] = {Row(s.id[h],{h},s.aliases[h])},
      !.result[h] = {Row(s.id[h],{h},s.aliases[h])}]
Attempt(h) ==
 /\ s.phase[h] \in {"attempt","retry"}
 /\ IF s.expected[h] = s.version
       THEN s' = [s EXCEPT !.phase[h] = "closed", !.checkpoint = s.result[h],
           !.version = @ + 1, !.committed = @ \cup {h}]
       ELSE s' = [s EXCEPT !.phase[h] = "changed",
           !.incoming[h] = s.checkpoint, !.expected[h] = s.version]
Merge(h) ==
 /\ s.phase[h] = "changed"
 /\ s' = [s EXCEPT !.phase[h] = "merged",
      !.result[h] = Combine(s.captured[h] \cup s.incoming[h])]
\* Separate admission and durable settlement; this is an abstract success
\* boundary, not a proof of byte codecs or physical WAL synchronization.
Settle(h) ==
 /\ s.phase[h] = "merged"
 /\ s' = [s EXCEPT !.phase[h] = "retry"]
Crash(h) ==
 /\ s.committed = Hosts /\ s.phase[h] = "closed"
 /\ s' = [s EXCEPT !.phase[h] = "crashed"]
Recover(h) ==
 /\ s.phase[h] = "crashed"
 /\ s' = [s EXCEPT !.phase[h] = "recovered",
      !.recovered[h] = Combine(s.checkpoint \cup s.wal[h])]

Next == \E h \in Hosts:
 Import(h) \/ StampInitial(h) \/ Edit(h) \/ Deliver(h) \/ ReconcileTag(h)
 \/ Prepare(h) \/ Attempt(h) \/ Merge(h) \/ Settle(h) \/ Crash(h) \/ Recover(h)
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ \A h \in Hosts:
 WF_vars(Import(h)) /\ WF_vars(StampInitial(h)) /\ WF_vars(Edit(h))
 /\ WF_vars(Deliver(h)) /\ WF_vars(ReconcileTag(h))

TypeOK ==
 /\ s.imported \subseteq Hosts /\ s.stamped \subseteq s.imported
 /\ s.edited \subseteq s.imported /\ s.committed \subseteq Hosts
 /\ s.tag \in 0..2 /\ s.view \in [Hosts -> 0..2]
 /\ s.id \in [Hosts -> 0..2] /\ s.proposal \in [Hosts -> 0..2]
 /\ s.aliases \in [Hosts -> SUBSET IDs] /\ s.version \in 0..2
 /\ s.phase \in [Hosts -> {"active","attempt","changed","merged","retry",
                          "closed","crashed","recovered"}]
 /\ \A rows \in {s.checkpoint} \cup {s.wal[h]: h \in Hosts}
      \cup {s.captured[h]: h \in Hosts} \cup {s.result[h]: h \in Hosts}
      \cup {s.incoming[h]: h \in Hosts} \cup {s.recovered[h]: h \in Hosts}:
       rows \subseteq [id: IDs, edits: SUBSET Hosts, claims: SUBSET IDs]
NoPayloadLoss == s.committed \subseteq Edits(s.checkpoint)
NoDuplicateLogicalFile == s.committed = Hosts => Cardinality(s.checkpoint) = 1
RecoveryKeepsPayload == \A h \in Hosts:
 s.phase[h] = "recovered" => Edits(s.recovered[h]) = Hosts
RecoveryDoesNotForkIdentity == \A h \in Hosts:
 s.phase[h] = "recovered" => Cardinality(s.recovered[h]) = 1
WALIdentityStillRepresented == \A h \in s.edited:
 \A r \in s.wal[h]: r.id \in s.aliases[h]
DatabaseIdentityStable == \A h \in s.imported: s.id[h] = s.proposal[h]
CheckpointRemembersCommittedIDs == \A h \in s.committed:
 \A r \in s.wal[h]: r.id \in Claims(s.checkpoint)
ExactCheckpointCAS == [][s.version' # s.version =>
 \E h \in Hosts: s.expected[h] = s.version /\ s'.checkpoint = s.result[h]]_vars
EffectiveID(h) == IF Policy = "stable" /\ s.aliases[h] # {}
                    THEN Min(s.aliases[h]) ELSE s.id[h]
EventualAgreement == <>[](s.stamped = Hosts /\ EffectiveID(1) = EffectiveID(2))
NeverReachedIndependentImports == ~(s.proposal[1] = 1 /\ s.proposal[2] = 2)
NeverReachedMerge == \A h \in Hosts: s.phase[h] # "merged"
NeverReachedRecovery == \A h \in Hosts: s.phase[h] # "recovered"
NeverMergedWithDistinctLiveIDs ==
 ~(s.committed = Hosts /\ s.id[1] # s.id[2] /\ Cardinality(s.checkpoint) = 1)
=============================================================================
