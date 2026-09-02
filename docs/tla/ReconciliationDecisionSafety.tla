-------------------- MODULE ReconciliationDecisionSafety --------------------
EXTENDS Naturals, FiniteSets
\* PUB-01 current-file decision table. No historical traversal/UUID xattrs.
\* One note and one immutable current input. An unrelated automatic recovery
\* candidate is included to check that its status cannot suppress routine
\* preservation or be overwritten by a fresh ordinary conflict note.
\* "merged" abstracts NVMergedText; its byte-level correctness is not proved.
Pairs == {<<"base","base">>, <<"base","remote">>, <<"local","base">>,
 <<"local","remote">>, <<"same","same">>, <<"local","absent">>,
 <<"base","absent">>, <<"absent","remote">>, <<"absent","absent">>}
Bodies == {"base","local","remote","same","absent","merged"}
Names == {"base","local","remote"}
Evidence == {"document","wrongVolume","file","wrongSession","duplicate",
             "fallback","changedIDFallback","pathTimestamp","none"}
BaseOrigins == {"file","settledCheckpoint","unsettledCheckpoint","none"}
Slots == {"free","exact","modified","retired","inconsistent"}
A(body,name) == <<body,name>>
Pristine == A("base","base")
VARIABLE s
vars == <<s>>
Init ==
 \E pair \in Pairs, ln \in Names, rn \in Names, evidence \in Evidence,
    origin \in BaseOrigins, safe \in BOOLEAN, slot \in Slots:
  s = [local |-> A(pair[1],ln), remote |-> A(pair[2],rn),
    evidence |-> evidence, origin |-> origin, safe |-> safe,
    automaticSlot |-> slot, phase |-> "idle", drift |-> "none",
    candidate |-> A(pair[1],ln), preserved |-> {}, imports |-> {},
    live |-> A(pair[1],ln), livePreserved |-> {}, liveImports |-> {},
    dirty |-> TRUE]
Associated == s.evidence \in {"document","file","fallback","changedIDFallback"}
TrustworthyBase == s.origin \in {"file","settledCheckpoint"}
NameConflict ==
 s.local[2] # "base" /\ s.remote[2] # "base" /\ s.local[2] # s.remote[2]
BothBodiesChanged ==
 s.local[1] # "base" /\ s.remote[1] # "base" /\ s.local[1] # s.remote[1]
CombinedName == IF s.local[2] = "base" THEN s.remote[2] ELSE s.local[2]
Decision ==
 IF s.remote[1] = "absent" THEN
   [note |-> A("absent",s.local[2]), imports |-> {},
    preserve |-> IF s.local[1] # "absent" /\
                     (s.local # Pristine \/ ~TrustworthyBase)
                 THEN {s.local} ELSE {}]
 ELSE IF s.local[1] = "absent" \/ ~Associated THEN
   [note |-> s.local, imports |-> {s.remote}, preserve |-> {}]
 ELSE IF s.local = s.remote THEN
   [note |-> s.local, imports |-> {}, preserve |-> {}]
 ELSE IF ~TrustworthyBase \/ NameConflict THEN
   [note |-> s.local, imports |-> {}, preserve |-> {s.remote}]
 ELSE IF s.local[1] = s.remote[1] THEN
   [note |-> A(s.local[1],CombinedName), imports |-> {}, preserve |-> {}]
 ELSE IF s.local[1] = "base" THEN
   [note |-> A(s.remote[1],CombinedName), imports |-> {}, preserve |-> {}]
 ELSE IF s.remote[1] = "base" THEN
   [note |-> A(s.local[1],CombinedName), imports |-> {}, preserve |-> {}]
 ELSE IF s.safe THEN
   [note |-> A("merged",CombinedName), imports |-> {}, preserve |-> {}]
 ELSE [note |-> s.local, imports |-> {}, preserve |-> {s.remote}]
Prepare ==
 /\ s.phase = "idle"
 /\ LET d == Decision
    IN s' = [s EXCEPT !.phase = "prepared", !.candidate = d.note,
      !.imports = d.imports, !.preserved = d.preserve]
Invalidate(kind) ==
 /\ s.phase = "prepared" /\ s.drift = "none"
 /\ kind \in {"root","note","structure","catalog"}
 /\ s' = [s EXCEPT !.drift = kind]
Publish ==
 /\ s.phase = "prepared" /\ s.drift = "none"
 /\ s' = [s EXCEPT !.phase = "published", !.live = s.candidate,
      !.liveImports = s.imports,
      !.livePreserved = s.preserved,
      !.dirty = FALSE]
Reject ==
 /\ s.phase = "prepared" /\ s.drift # "none"
 /\ s' = [s EXCEPT !.phase = "rejected"]
Next == Prepare \/ Publish \/ Reject \/
        (\E kind \in {"root","note","structure","catalog"}: Invalidate(kind))
Spec == Init /\ [][Next]_vars
\* Independent table oracle decomposes identity, deletion, naming, and body
\* decisions. It does not use Decision or the result's own provenance flags.
ImportsExpected ==
 IF s.remote[1] # "absent" /\ (s.local[1] = "absent" \/ ~Associated)
 THEN {s.remote} ELSE {}
Deletion == s.remote[1] = "absent"
KeepsLocal ==
 ~Deletion /\ (ImportsExpected # {} \/ s.local = s.remote \/
   ~TrustworthyBase \/ NameConflict \/ (BothBodiesChanged /\ ~s.safe))
BodyExpected ==
 IF Deletion THEN "absent"
 ELSE IF KeepsLocal THEN s.local[1]
 ELSE IF s.local[1] = "base" THEN s.remote[1]
 ELSE IF s.remote[1] = "base" \/ s.remote[1] = s.local[1] THEN s.local[1]
 ELSE "merged"
NameExpected ==
 IF Deletion \/ KeepsLocal THEN s.local[2]
 ELSE IF s.local[2] # "base" THEN s.local[2] ELSE s.remote[2]
PreservationExpected ==
 IF Deletion THEN
   IF s.local[1] # "absent" /\ (s.local # Pristine \/ ~TrustworthyBase)
   THEN {s.local} ELSE {}
 ELSE IF ImportsExpected = {} /\ s.local # s.remote /\ KeepsLocal
      THEN {s.remote} ELSE {}
TypeOK ==
 /\ s.phase \in {"idle","prepared","published","rejected"}
 /\ s.local \in Bodies \X Names /\ s.remote \in Bodies \X Names
 /\ s.candidate \in Bodies \X Names /\ s.live \in Bodies \X Names
 /\ s.automaticSlot \in Slots
 /\ s.preserved \subseteq Bodies \X Names /\ s.imports \subseteq Bodies \X Names
 /\ s.livePreserved \subseteq Bodies \X Names /\ s.liveImports \subseteq Bodies \X Names
 /\ s.evidence \in Evidence /\ s.origin \in BaseOrigins
 /\ s.safe \in BOOLEAN /\ s.dirty \in BOOLEAN
 /\ s.drift \in {"none","root","note","structure","catalog"}
PreparedDecisionMatchesIndependentTable ==
 s.phase # "idle" =>
   s.candidate = A(BodyExpected,NameExpected) /\
   s.imports = ImportsExpected /\ s.preserved = PreservationExpected
PublicationMatchesRoutineDecision ==
 s.phase = "published" =>
   /\ s.live = A(BodyExpected,NameExpected) /\ s.liveImports = ImportsExpected
   /\ s.livePreserved = PreservationExpected
UnmatchedFileNeverReattachesDeletedUUID ==
 s.phase = "published" /\ s.local[1] = "absent" /\ s.remote[1] # "absent" =>
   s.live[1] = "absent" /\ s.liveImports = {s.remote}
NoMergeFromUnsettledCheckpointBase ==
 s.phase = "published" /\ s.origin \in {"none","unsettledCheckpoint"} =>
   s.live[1] # "merged"
UnqualifiedIdentityAlwaysImportsFresh ==
 s.phase = "published" /\ s.remote[1] # "absent" /\
 s.evidence \in {"wrongVolume","wrongSession","duplicate","pathTimestamp","none"} =>
   s.live = s.local /\ s.liveImports = {s.remote}
ConflictingRenamesPreserveRemote ==
 s.phase = "published" /\ s.local[1] # "absent" /\ s.remote[1] # "absent" /\
 s.evidence \in {"document","file","fallback","changedIDFallback"} /\
 s.local[2] # "base" /\ s.remote[2] # "base" /\ s.local[2] # s.remote[2] =>
   s.live = s.local /\ s.livePreserved = {s.remote}
RoutineDeletionPreservesChangedLocal ==
 s.phase = "published" /\ s.remote[1] = "absent" /\
 s.local[1] # "absent" /\ s.local # Pristine =>
   s.live[1] = "absent" /\ s.livePreserved = {s.local}
RejectedCandidateNeverPublishes ==
 s.phase = "rejected" =>
   s.live = s.local /\ s.liveImports = {} /\ s.livePreserved = {} /\ s.dirty
PublicationRequiresEveryCurrentFence ==
 [][Publish => s.drift = "none"]_vars
RoutinePreservationLeavesAutomaticCandidateUntouched ==
 [][Publish => UNCHANGED s.automaticSlot]_vars
=============================================================================
