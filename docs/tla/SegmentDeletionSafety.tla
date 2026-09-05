-------------------------- MODULE SegmentDeletionSafety --------------------------
EXTENDS Naturals, FiniteSets

\* Proposal 5: two known note births, one sender of Delete and one of Edit,
\* optional explicit Restore with a NEW birth, one crash per configured host.
\* orderedRestore adds edit -> delete -> restore and child-first receipt;
\* mixed combines concurrent edit/delete/restore with both physical-file races.
\* CrashHost = 0 lets BOTH hosts crash once in the same execution. File tokens
\* distinguish original/replacement only, not restored projection installation.
\* Immutable bytes/authentication/physical syncing are abstracted; local staging,
\* durability, provider delivery, dependency closure, application, and restart
\* are distinct. This does NOT prove independent external-import identity.
\* Restore supplies only the fresh-birth deletion-safety foundation for
\* Recently Deleted/undo-Delete. It does NOT model history UI, action groups,
\* portable causal undo/redo, or the new conservative automatic merge kernel.
\* materialization abstracts represented inputs, not a full history stored in rows.
\* Private settings/association and
\* visible-directory backup completeness are not represented by this model.
CONSTANTS Policy, Scenario, CrashHost
ASSUME Policy \in {"safe","absenceDeletes","dropConflict","reuseBirth",
                   "skipDependencies","snapshotOnly","deleteReplacement","earlyDependentAck",
                   "removeBeforeDurability","onePassClosure","stallDelivery"}
       /\ Scenario \in {"concurrent","ordered","restore","files","orderedRestore","mixed"}
       /\ CrashHost \in {0,1,2}
Hosts == {1,2}
Base == {"birth","untouched"}
Ops == Base \cup {"edit","delete","restore"}
Ordered == Scenario \in {"ordered","orderedRestore"}
FileRaces == Scenario \in {"files","mixed"}
CrashHosts == IF CrashHost = 0 THEN Hosts ELSE {CrashHost}
Target == IF Scenario \in {"restore","orderedRestore","mixed"} THEN Ops
          ELSE IF Scenario = "files" THEN Base \cup {"delete"}
          ELSE Ops \ {"restore"}
Dependencies(o) ==
 CASE o \in Base -> {}
   [] o = "edit" -> {"birth"}
   [] o = "delete" -> IF Ordered THEN {"birth","edit"} ELSE {"birth"}
   [] o = "restore" -> {"birth","delete"}
RECURSIVE ClosedPartAfter(_, _)
ClosedPartAfter(objects, steps) == IF steps = 0 THEN objects
 ELSE ClosedPartAfter({o \in objects: Dependencies(o) \subseteq objects}, steps - 1)
ClosedPart(objects) == ClosedPartAfter(objects,
 IF Policy = "onePassClosure" THEN 1 ELSE Cardinality(Ops))

\* The finite reducer is intentionally separate from the property predicates.
Reduce(objects,missing) == [
 original |-> IF "delete" \in objects \/ (Policy = "absenceDeletes" /\ missing)
                THEN "absent" ELSE IF "edit" \in objects THEN "edited" ELSE "base",
 restored |-> IF "restore" \in objects /\ ~(Policy = "reuseBirth" /\ "delete" \in objects)
                THEN "restored" ELSE "absent",
 conflicts |-> IF "edit" \in objects /\ "delete" \in objects
                  /\ ~Ordered /\ Policy # "dropConflict"
                THEN {<<"original","edited">>} ELSE {},
 untouched |-> IF "untouched" \in objects THEN "kept" ELSE "absent"]

VARIABLE s
vars == <<s>>
Init == s = [
 produced |-> Base, pending |-> [h \in Hosts |-> {}],
 staged |-> [h \in Hosts |-> {}], durable |-> [h \in Hosts |-> Base],
 applied |-> [h \in Hosts |-> Base], incoming |-> [h \in Hosts |-> {}],
 provider |-> Base, view |-> [h \in Hosts |-> Reduce(Base,FALSE)],
 materialization |-> [h \in Hosts |-> Base],
 file |-> [h \in Hosts |-> 1], changedFile |-> {}, missingObserved |-> {},
 removeAuthority |-> FALSE, removedNV |-> {},
 everApplied |-> [h \in Hosts |-> Base],
 down |-> {}, crashed |-> {}, recovered |-> {}, parkedGrandchild |-> {}]
Up(h) == h \notin s.down
Origin(o) == IF Scenario = "orderedRestore" \/ o = "delete"
                \/ (Ordered /\ o = "edit") THEN 1 ELSE 2
Admit(o) ==
 /\ o \in Target \ s.produced
 /\ LET h == Origin(o) IN
    /\ Up(h) /\ Dependencies(o) \subseteq s.applied[h]
    /\ (o = "restore" => "delete" \in s.durable[h])
    /\ s' = [s EXCEPT !.produced = @ \cup {o}, !.pending[h] = @ \cup {o},
          !.applied[h] = @ \cup {o},
          !.view[h] = Reduce(s.applied[h] \cup {o},h \in s.missingObserved),
          !.removeAuthority = IF o = "delete" /\ s.file[1] = 1 THEN TRUE ELSE @]
Stage(h,o) ==
 /\ Up(h) /\ o \in s.pending[h] \ s.staged[h]
 /\ s' = [s EXCEPT !.staged[h] = @ \cup {o}]
SyncLocal(h,o) ==
 /\ Up(h) /\ o \in (s.staged[h] \cup s.incoming[h]) \ s.durable[h]
 \* Incoming children may be stored out of order. Acknowledging a LOCAL
 \* mutation, however, must also secure its causal parents before a crash.
 /\ (o \in s.staged[h] => Policy = "earlyDependentAck"
                           \/ Dependencies(o) \subseteq s.durable[h])
 /\ s' = [s EXCEPT !.durable[h] = @ \cup {o},
        !.pending[h] = @ \ {o}, !.staged[h] = @ \ {o}, !.incoming[h] = @ \ {o},
        !.everApplied[h] = IF o \in s.applied[h] THEN @ \cup {o} ELSE @]
Publish(h,o) ==
 /\ Up(h) /\ o \in s.durable[h] \ s.provider
 /\ s' = [s EXCEPT !.provider = @ \cup {o}]
Receive(h,o) ==
 /\ Up(h) /\ o \in s.provider \ (s.durable[h] \cup s.incoming[h])
 /\ ~(Policy = "stallDelivery" /\ h = 2 /\ o = "delete")
 /\ s' = [s EXCEPT !.incoming[h] = @ \cup {o}]
Apply(h,o) ==
 /\ Up(h) /\ o \in s.durable[h] \ s.applied[h]
 /\ (Policy = "skipDependencies" \/
      Dependencies(o) \subseteq (s.applied[h] \cap s.durable[h]))
 /\ s' = [s EXCEPT !.applied[h] = @ \cup {o}, !.everApplied[h] = @ \cup {o},
          !.view[h] = Reduce(s.applied[h] \cup {o},h \in s.missingObserved)]
Materialize(h) ==
 /\ Up(h) /\ s.pending[h] = {} /\ s.materialization[h] # s.applied[h]
 /\ s' = [s EXCEPT !.materialization[h] = s.applied[h]]
ExternalAbsence(h) ==
 /\ FileRaces /\ Up(h) /\ h \notin s.missingObserved
 /\ s' = [s EXCEPT !.file[h] = 0, !.missingObserved = @ \cup {h},
           !.view[h] = Reduce(s.applied[h],TRUE)]
ExternalReplacement(h) ==
 /\ FileRaces /\ Up(h) /\ h \notin s.changedFile
 /\ s' = [s EXCEPT !.file[h] = 2, !.changedFile = @ \cup {h}]
RemoveOriginalFile ==
 /\ Up(1) /\ s.removeAuthority
 /\ (Policy = "removeBeforeDurability" \/ "delete" \in s.durable[1])
 /\ (s.file[1] = 1 \/ (Policy = "deleteReplacement" /\ s.file[1] = 2))
 /\ s' = [s EXCEPT !.removedNV = @ \cup {s.file[1]}, !.file[1] = 0,
                    !.removeAuthority = FALSE]
Crash(h) ==
 /\ h \in CrashHosts \ s.crashed
 /\ s' = [s EXCEPT !.down = @ \cup {h}, !.crashed = @ \cup {h},
      !.pending[h] = {}, !.staged[h] = {}, !.incoming[h] = {},
      !.applied[h] = {}, !.view[h] = Reduce({},FALSE),
      !.removeAuthority = IF h = 1 THEN FALSE ELSE @]
Recover(h) ==
 /\ h \in s.down
 /\ LET available == IF Policy = "snapshotOnly" THEN s.materialization[h]
                     ELSE ClosedPart(s.durable[h])
    IN s' = [s EXCEPT !.down = @ \ {h}, !.recovered = @ \cup {h},
            !.applied[h] = available,
            !.view[h] = Reduce(available,h \in s.missingObserved),
            !.parkedGrandchild = IF Scenario = "orderedRestore"
               /\ {"restore","delete"} \subseteq s.durable[h]
               /\ "edit" \notin s.durable[h] /\ "restore" \notin available
               THEN @ \cup {h} ELSE @]
\* These concrete pipeline fields determine the enabling of EACH Progress
\* instance. Every existing progress action changes one by its guard and
\* assignment; Auxiliary preserves them, including across file races.
ProgressGuardState == <<s.pending,s.staged,s.durable,s.incoming,s.applied,s.provider,s.down>>
Progress == (\E h \in Hosts, o \in Target:
 Stage(h,o) \/ SyncLocal(h,o) \/ Publish(h,o) \/ Receive(h,o) \/ Apply(h,o))
 \/ (\E h \in Hosts: Recover(h))
Environment == (\E o \in Target \ Base: Admit(o)) \/ (\E h \in Hosts: Crash(h))
Auxiliary == (\E h \in Hosts: Materialize(h) \/ ExternalAbsence(h) \/ ExternalReplacement(h))
 \/ RemoveOriginalFile
Next == Progress \/ Environment \/ Auxiliary
Spec == Init /\ [][Next]_vars
PerActionFairSpec == Spec /\ (\A h \in Hosts: WF_vars(Recover(h)))
 /\ \A h \in Hosts, o \in Target:
      WF_vars(Stage(h,o)) /\ WF_vars(SyncLocal(h,o)) /\ WF_vars(Publish(h,o))
      /\ WF_vars(Receive(h,o)) /\ WF_vars(Apply(h,o))
AggregateFairSpec == Spec /\ WF_ProgressGuardState(Progress)
FairSpec == AggregateFairSpec

TypeOK ==
 /\ s.produced \subseteq Target /\ s.provider \subseteq Target
 /\ \A field \in {"pending","staged","durable","applied","incoming",
                   "materialization","everApplied"}: s[field] \in [Hosts -> SUBSET Target]
 /\ s.file \in [Hosts -> 0..2] /\ s.changedFile \subseteq Hosts
 /\ s.missingObserved \subseteq Hosts /\ s.removedNV \subseteq {1,2}
 /\ s.removeAuthority \in BOOLEAN
 /\ \A field \in {"down","crashed","recovered","parkedGrandchild"}: s[field] \subseteq Hosts
 /\ s.view \in [Hosts -> [original: {"absent","base","edited"},
          restored: {"absent","restored"},
          conflicts: SUBSET {<<"original","edited">>}, untouched: {"absent","kept"}]]
NoUnexplainedLogicalDeletion == \A h \in Hosts:
 Up(h) /\ "delete" \notin s.applied[h] => s.view[h].original # "absent"
DeletedBirthStaysAbsent == \A h \in Hosts:
 Up(h) /\ "delete" \in s.everApplied[h] => s.view[h].original = "absent"
ConcurrentEditIsPreserved == \A h \in Hosts:
 Up(h) /\ {"delete","edit"} \subseteq s.applied[h] /\ ~Ordered
 => <<"original","edited">> \in s.view[h].conflicts
ObservedDeleteDoesNotMakeFalseConflict == \A h \in Hosts:
 Up(h) /\ Ordered /\ "delete" \in s.applied[h]
 => s.view[h].conflicts = {}
RestorationSurvivesOldDeletion == \A h \in Hosts:
 Up(h) /\ "restore" \in s.everApplied[h] => s.view[h].restored = "restored"
ApplicationHasDependencies == \A h \in Hosts:
 Up(h) => \A o \in s.applied[h]: Dependencies(o) \subseteq s.applied[h]
AcknowledgedHistorySurvivesRestart == \A h \in Hosts:
 Up(h) => s.everApplied[h] \subseteq s.applied[h]
UnchangedNoteSurvives == \A h \in Hosts: Up(h) => s.view[h].untouched = "kept"
NoRemovalOfReplacement == 2 \notin s.removedNV
PhysicalRemovalFollowsDurableDelete == s.removedNV # {}
 => "delete" \in s.durable[1] /\ Dependencies("delete") \subseteq s.durable[1]
Safety == NoUnexplainedLogicalDeletion /\ DeletedBirthStaysAbsent
 /\ ConcurrentEditIsPreserved /\ ObservedDeleteDoesNotMakeFalseConflict
 /\ RestorationSurvivesOldDeletion /\ ApplicationHasDependencies
 /\ AcknowledgedHistorySurvivesRestart /\ UnchangedNoteSurvives /\ NoRemovalOfReplacement
 /\ PhysicalRemovalFollowsDurableDelete
\* Only immutable dependency-closed objects are promised eventual delivery.
\* No fairness is assumed by Spec. FairSpec is a separate transport premise.
EqualHistoriesAgree == s.down = {} /\ s.applied[1] = s.applied[2]
 => s.view[1] = s.view[2]
EventualAgreement == <>[](s.down = {} /\ s.view[1] = s.view[2])
Agreement == s.down = {} /\ s.view[1] = s.view[2]
LocalWork(h) == Cardinality(Target \ s.durable[h])
 + Cardinality(Target \ (s.durable[h] \cup s.staged[h]))
 + Cardinality(Target \ (s.durable[h] \cup s.incoming[h]))
 + Cardinality(Target \ s.applied[h])
Work == Cardinality(Target \ s.provider) + LocalWork(1) + LocalWork(2)
 + Cardinality(s.down)
WorkCeiling == Cardinality(Target) * (1 + 4 * Cardinality(Hosts)) + Cardinality(Hosts)
EnvironmentBudget == Cardinality(Target \ s.produced) + Cardinality(CrashHosts \ s.crashed)
Rank == (WorkCeiling + 1) * EnvironmentBudget + Work
\* Check all actual edges by their concrete tracked-state delta, avoiding
\* expensive re-evaluation of every action merely to classify an edge.
\* A changed tracked tuple strictly lowers the finite rank; an unchanged one
\* preserves rank and agreement. Persistent disagreement would therefore
\* eventually keep actual nonstuttering Progress enabled at a constant rank,
\* contradicting WF_ProgressGuardState(Progress). No goal/rank action is fair.
\* User admission/crash remains optional. No safety transition is constrained.
\* For this bounded graph the old per-action premise also suffices: after the
\* last rank decrease, EACH progress instance has fixed guard inputs, not just
\* a fixed aggregate enabledness. Any enabled instance would violate its WF.
TrackedState == <<ProgressGuardState,s.produced,s.crashed>>
RankObligations == Rank \in Nat /\ Work \in 0..WorkCeiling
 /\ (~Agreement => ENABLED (Progress /\ ProgressGuardState' # ProgressGuardState))
AdvancingStepsDecreaseRank == [][TrackedState' # TrackedState => Rank' < Rank]_vars
AuxiliaryPreservesRankAndAgreement == [][TrackedState' = TrackedState =>
 Rank' = Rank /\ (Agreement' <=> Agreement)]_vars
NeverPreservedAcrossCrash == ~(\E h \in s.recovered:
 Up(h) /\ {"delete","edit"} \subseteq s.applied[h]
 /\ <<"original","edited">> \in s.view[h].conflicts)
NeverRestoredAcrossBothHosts == ~(s.down = {} /\ \A h \in Hosts: s.view[h].restored = "restored")
NeverReceivedBeforeParent == ~(\E h \in Hosts: "delete" \in s.durable[h]
 /\ "edit" \notin s.durable[h] /\ Ordered)
NeverKeptUnexplainedMissingNote == ~(\E h \in Hosts: Up(h) /\ h \in s.missingObserved
 /\ "delete" \notin s.applied[h] /\ s.view[h].original # "absent")
NeverRejectedReplacementRemoval == ~(s.removeAuthority /\ "delete" \in s.durable[1]
 /\ s.file[1] = 2 /\ 2 \notin s.removedNV)
NeverParkedTransitiveDependency == ~(\E h \in s.parkedGrandchild:
 Up(h) /\ "restore" \notin s.applied[h] /\ "delete" \notin s.applied[h])
NeverAppliedAfterTransitiveDependency == ~(\E h \in s.parkedGrandchild:
 Up(h) /\ Target \subseteq s.applied[h] /\ s.view[h].restored = "restored")
NeverRecoveredMixedOnBoth == ~(Scenario = "mixed" /\ s.recovered = Hosts
 /\ s.down = {} /\ s.changedFile = Hosts /\ s.missingObserved = Hosts
 /\ 1 \in s.removedNV /\ 2 \notin s.removedNV
 /\ \A h \in Hosts: Target \subseteq s.applied[h]
    /\ s.view[h].restored = "restored"
    /\ <<"original","edited">> \in s.view[h].conflicts)
=============================================================================
