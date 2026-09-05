------------------------ MODULE ExternalImportPolicyLab ------------------------
EXTENDS Naturals, FiniteSets, Sequences, TLC
CONSTANTS Policy, Scenario
\* The targeted predicate is adopted. Other policies remain experiments.
\* Exact byte/date tokens stand for comparisons, not hashes used as identities.
\* Receipt scope and duplicate detection are supplied by the existing fenced
\* catalog layer. Hidden physical origin is absent from every decision input.
Notes == {1,2}
Signals == 1..11
\* 1 active path, 2 old path, 3 current nonempty bytes, 4 historical bytes,
\* 5 creation timestamp, 6 modification timestamp, 7 size/format/tags bundle,
\* 8 related event hint, 9 similar name, 10 raw ID outside its valid scope.
\* 11 partial body overlap (two shared synthetic text fragments, not exact bytes).
Rule(bits, threshold, gate) == [bits |-> bits, threshold |-> threshold, gate |-> gate]
Targeted == Rule({1,3},1,TRUE)
AllRules == {Rule(b,t,g): b \in SUBSET Signals, t \in 1..11, g \in BOOLEAN}
Rules == {r \in AllRules: Cardinality(r.bits)>=r.threshold}
ChosenRules == CASE Policy="sweep" -> Rules
 [] Policy \in {"targeted","localOverridesStamp","ambiguousFallsThrough"} -> {Targeted}
 [] Policy="historyPair" -> {Rule({1,3},1,TRUE)}
 [] Policy="eventPair" -> {Rule({1,3},1,TRUE)}
 [] Policy="similarityPair" -> {Rule({1,3},1,TRUE)}
 [] Policy="blanket" -> {Rule({},1,TRUE)}
 [] Policy="automatic" -> {Rule({},1,TRUE)}
 [] Policy="voteIdentity" -> {Rule({1,3,5},2,TRUE)}
 [] Policy="pooledVotes" -> {Rule({1,3,5},2,TRUE)}
ASSUME Policy \in {"sweep","targeted","historyPair","eventPair","similarityPair","blanket",
                    "automatic","voteIdentity","pooledVotes","localOverridesStamp","ambiguousFallsThrough"}

Note(n) == [live |-> TRUE, relationship |-> "present",
 path |-> IF n=1 THEN "P" ELSE "R", oldPaths |-> {IF n=1 THEN "OldP" ELSE "OldR"},
 body |-> IF n=1 THEN "A" ELSE "C", oldBodies |-> {IF n=1 THEN "OldA" ELSE "OldC"},
 transition |-> FALSE, previousPath |-> "PreviousP", previousBody |-> "PreviousA",
 created |-> n, modified |-> n+2, metadata |-> IF n=1 THEN "M" ELSE "N",
 name |-> IF n=1 THEN "NP" ELSE "NR", fileID |-> n, scope |-> "session1",
 fragments |-> IF n=1 THEN {"anchor","middle","tail"} ELSE {"other"}]
Base == [file |-> [path |-> "Q", body |-> "B", created |-> 9, modified |-> 9,
 metadata |-> "Z", name |-> "NQ", fileID |-> 9, scope |-> "session1",
 stamp |-> "none", ref |-> 1, readable |-> TRUE, eligible |-> TRUE, fragments |-> {"unrelated"}],
 notes |-> [n \in Notes |-> Note(n)], events |-> {}, duplicate |-> FALSE,
 history |-> {1,2}, nameCollision |-> FALSE, command |-> "discover"]
Missing == [Base EXCEPT !.notes[1].relationship="missing"]
Cases == {"new","unrelatedMissing","similarName","createdOnly","modifiedOnly",
 "metadataOnly","eventOnly","oldPathOnly","oldBodyOnly","rawIDOnly","blankTemplate",
 "healthySameBody","healthySameDates","healthyOldPath","missingSamePath",
 "renameExactBody","independentTemplate","renameEditedHint","renameEditedDates",
 "renameEditedNoClue","newNoClue","historicReturn","historicTemplate",
 "oldPathWithHint","unrelatedOldPathHint","splitVotes","twoCandidates",
 "samePathAndCreated","pathReuseUnrelated","allWeakCopy","allWeakRename",
 "currentDescriptor","knownStamp","missingSegment","deletedStamp","deletedDescriptor",
 "copiedStamp","foreignStamp","malformedStamp","skewedStamp","localRename",
 "handoffChangedBody","duplicateIDs","crossScopeID","placeholder","unreadable",
 "reservedFile","caseCollision","explicitNew","unrelatedHintAndMissing",
 "mixedMissingHealthy","emptySameName","contradictoryStamp","skewedLocalHandoff",
 "similarBodyOnly","renamedSmallEdit","similarBodyWithHint","similarTemplateWithHint",
 "renamedSmallEditDate","templateSameDate","contradictoryLocalStamp","contradictoryLocalDescriptor",
 "ambiguousDescriptors"}
ASSUME Scenario="all" \/ Scenario \in Cases
Observation(c) == CASE c \in {"new","newNoClue"} -> Base
 [] c \in {"unrelatedMissing","renameEditedNoClue"} -> Missing
 [] c="similarName" -> [Missing EXCEPT !.file.name="NP"]
 [] c="createdOnly" -> [Missing EXCEPT !.file.created=1]
 [] c="modifiedOnly" -> [Missing EXCEPT !.file.modified=3]
 [] c="metadataOnly" -> [Missing EXCEPT !.file.metadata="M"]
 [] c="eventOnly" -> [Missing EXCEPT !.events={<<"P","Q">>}]
 [] c="oldPathOnly" -> [Missing EXCEPT !.file.path="OldP"]
 [] c="oldBodyOnly" -> [Missing EXCEPT !.file.body="OldA"]
 [] c="rawIDOnly" -> [Missing EXCEPT !.file.fileID=1, !.file.scope="expired"]
 [] c="blankTemplate" -> [Missing EXCEPT !.file.body="empty", !.notes[1].body="empty"]
 [] c="healthySameBody" -> [Base EXCEPT !.file.body="A"]
 [] c="healthySameDates" -> [Base EXCEPT !.file.created=1, !.file.modified=3]
 [] c="healthyOldPath" -> [Base EXCEPT !.file.path="OldP", !.file.body="OldA"]
 [] c="missingSamePath" -> [Missing EXCEPT !.file.path="P"]
 [] c="emptySameName" -> [Missing EXCEPT !.file.path="P", !.file.body="empty"]
 [] c \in {"renameExactBody","independentTemplate"} -> [Missing EXCEPT !.file.body="A"]
 [] c="renameEditedHint" -> [Missing EXCEPT !.events={<<"P","Q">>}, !.file.name="NP"]
 [] c="renameEditedDates" -> [Missing EXCEPT !.file.created=1, !.file.modified=3]
 [] c \in {"historicReturn","historicTemplate"} ->
    [Missing EXCEPT !.file.path="OldP", !.file.body="OldA"]
 [] c \in {"oldPathWithHint","unrelatedOldPathHint"} ->
    [Missing EXCEPT !.file.path="OldP", !.events={<<"P","OldP">>}]
 [] c="splitVotes" -> [Missing EXCEPT !.file.path="P", !.file.body="C",
                                      !.notes[2].relationship="missing"]
 [] c="twoCandidates" -> [Missing EXCEPT !.file.body="A", !.notes[2].body="A",
                                         !.notes[2].relationship="uncertain"]
 [] c \in {"samePathAndCreated","pathReuseUnrelated"} ->
    [Missing EXCEPT !.file.path="P", !.file.created=1]
 [] c \in {"allWeakCopy","allWeakRename"} ->
    [Missing EXCEPT !.file.path="OldP", !.file.body="A", !.file.created=1,
     !.file.modified=3, !.file.metadata="M", !.file.name="NP", !.file.fileID=1,
     !.file.scope="expired", !.events={<<"P","OldP">>}]
 [] c="currentDescriptor" -> [Missing EXCEPT !.file.path="P", !.file.body="A"]
 [] c="knownStamp" -> [Missing EXCEPT !.file.path="P", !.file.body="A", !.file.stamp="valid"]
 [] c="contradictoryStamp" -> [Missing EXCEPT !.file.path="P", !.file.body="A",
                                              !.file.stamp="valid", !.file.ref=2]
 [] c="contradictoryLocalStamp" -> [Missing EXCEPT !.file.path="P", !.file.body="A",
     !.file.fileID=1, !.file.stamp="valid", !.file.ref=2]
 [] c="contradictoryLocalDescriptor" -> [Missing EXCEPT !.file.path="R", !.file.body="C",
     !.file.fileID=1, !.file.stamp="valid", !.file.ref=2]
 [] c="ambiguousDescriptors" -> [Base EXCEPT !.file.path="P", !.file.body="A",
     !.notes[2].path="P", !.notes[2].body="A"]
 [] c="missingSegment" -> [Missing EXCEPT !.file.path="P", !.file.body="A",
                                           !.file.stamp="valid", !.history={2}]
 [] c="deletedStamp" -> [Missing EXCEPT !.file.path="P", !.file.body="A",
                                         !.file.stamp="valid", !.notes[1].live=FALSE]
 [] c="deletedDescriptor" -> [Missing EXCEPT !.file.path="P", !.file.body="A", !.notes[1].live=FALSE]
 [] c="copiedStamp" -> [Base EXCEPT !.file.body="A", !.file.stamp="valid", !.duplicate=TRUE]
 [] c="foreignStamp" -> [Base EXCEPT !.file.stamp="foreign"]
 [] c="malformedStamp" -> [Base EXCEPT !.file.stamp="malformed"]
 [] c="skewedStamp" -> [Missing EXCEPT !.file.stamp="skewed"]
 [] c="localRename" -> [Missing EXCEPT !.file.fileID=1, !.file.body="A"]
 [] c="handoffChangedBody" -> [Missing EXCEPT !.file.fileID=1]
 [] c="skewedLocalHandoff" -> [Missing EXCEPT !.file.fileID=1, !.file.stamp="skewed"]
 [] c="duplicateIDs" -> [Missing EXCEPT !.file.fileID=1, !.duplicate=TRUE]
 [] c="crossScopeID" -> [Missing EXCEPT !.file.fileID=1, !.file.scope="otherVolume"]
 [] c \in {"placeholder","unreadable"} -> [Missing EXCEPT !.file.readable=FALSE]
 [] c="reservedFile" -> [Base EXCEPT !.file.eligible=FALSE]
 [] c="caseCollision" -> [Base EXCEPT !.nameCollision=TRUE]
 [] c="explicitNew" -> [Missing EXCEPT !.command="new", !.file.path="P",
                                       !.file.body="A", !.file.stamp="valid"]
 [] c="unrelatedHintAndMissing" -> [Missing EXCEPT !.events={<<"R","Other">>}]
 [] c="mixedMissingHealthy" -> [Missing EXCEPT !.file.body="C", !.file.created=2]
 [] c \in {"similarBodyOnly","renamedSmallEdit"} ->
    [Missing EXCEPT !.file.fragments={"anchor","middle"}]
 [] c \in {"similarBodyWithHint","similarTemplateWithHint"} ->
    [Missing EXCEPT !.file.fragments={"anchor","middle"}, !.events={<<"P","Q">>}]
 [] c \in {"renamedSmallEditDate","templateSameDate"} ->
    [Missing EXCEPT !.file.fragments={"anchor","middle"}, !.file.created=1]

NeedsRepair(n) == n.live /\ n.relationship \in {"missing","uncertain"}
ActivePaths(n) == {n.path} \cup IF n.transition THEN {n.previousPath} ELSE {}
ActiveBodies(n) == {n.body} \cup IF n.transition THEN {n.previousBody} ELSE {}
Matches(o,n) == LET f==o.file v==o.notes[n] IN
 {i \in Signals: CASE i=1 -> f.path \in ActivePaths(v)
  [] i=2 -> f.path \in v.oldPaths
  [] i=3 -> f.body \in ActiveBodies(v) /\ f.body # "empty"
  [] i=4 -> f.body \in v.oldBodies /\ f.body # "empty"
  [] i=5 -> f.created=v.created /\ f.created # 0
  [] i=6 -> f.modified=v.modified /\ f.modified # 0
  [] i=7 -> f.metadata=v.metadata /\ f.metadata # "empty"
  [] i=8 -> <<v.path,f.path>> \in o.events
  [] i=9 -> f.name=v.name
  [] i=10 -> f.fileID=v.fileID /\ f.fileID # 0 /\ f.scope # v.scope
  [] i=11 -> f.body # v.body /\ Cardinality(f.fragments \cap v.fragments)>=2}
Descriptor(o,n) == n \in o.history /\ o.file.path=o.notes[n].path /\ o.file.body=o.notes[n].body
Local(o,n) == o.notes[n].live /\ NeedsRepair(o.notes[n]) /\ ~o.duplicate
 /\ o.file.fileID # 0 /\ o.file.fileID=o.notes[n].fileID /\ o.file.scope=o.notes[n].scope
Strong(o) == {n \in Notes: o.notes[n].live /\ ~o.duplicate /\
 (Local(o,n) \/ (Descriptor(o,n) /\ (o.file.stamp="none" \/
                              (o.file.stamp="valid" /\ o.file.ref=n))))}
Plausible(o,r,n) ==
 /\ (IF r.gate THEN NeedsRepair(o.notes[n]) ELSE o.notes[n].live)
 /\ LET hits==Matches(o,n) IN
    Cardinality(hits \cap r.bits)>=r.threshold
    \/ (Policy="historyPair" /\ {2,4} \subseteq hits)
    \/ (Policy="eventPair" /\ 8 \in hits /\ hits \cap {2,4,9} # {})
    \/ (Policy="similarityPair" /\ 11 \in hits /\ hits \cap {2,5,8,9} # {})
Answer(kind,targets) == [kind |-> kind, targets |-> targets]
Decision(o,r) ==
 LET candidates=={n \in Notes: Plausible(o,r,n)}
     pooled==UNION {Matches(o,n) \cap r.bits: n \in Notes}
 IN CASE ~o.file.eligible -> Answer("ignored",{})
 [] ~o.file.readable -> Answer("file",{})
 [] o.command="new" -> Answer("new",{})
 [] o.nameCollision \/ o.duplicate -> Answer("provenance",{})
 [] o.file.stamp="valid" /\ o.file.ref \notin o.history -> Answer("history",{})
 [] \E n \in Notes: ~o.notes[n].live /\ Descriptor(o,n) -> Answer("restoration",{})
 [] o.file.stamp="valid" /\ Policy # "localOverridesStamp"
    /\ (\E n \in Notes: Local(o,n) /\ n # o.file.ref) -> Answer("provenance",{})
 [] o.file.stamp \in {"foreign","malformed","skewed"} ->
       IF Cardinality({n \in Notes: Local(o,n)})=1 /\ o.file.stamp="skewed"
       THEN Answer("edit",{n \in Notes: Local(o,n)}) ELSE Answer("provenance",{})
 [] Cardinality(Strong(o))>1 /\ Policy # "ambiguousFallsThrough" -> Answer("provenance",{})
 [] Cardinality(Strong(o))=1 ->
       Answer(IF \E n \in Strong(o): o.file.body # o.notes[n].body THEN "edit" ELSE "represented",Strong(o))
 [] o.file.stamp="valid" -> Answer("provenance",{})
 [] Policy="blanket" -> Answer("association",{n \in Notes: NeedsRepair(o.notes[n])})
 [] Policy="automatic" -> Answer("new",{})
 [] Policy="pooledVotes" /\ Cardinality(pooled)>=r.threshold ->
       Answer("association",{n \in Notes: NeedsRepair(o.notes[n])})
 [] candidates # {} -> Answer(IF Policy="voteIdentity" THEN "represented" ELSE "association",candidates)
 [] OTHER -> Answer("new",{})

\* Independent UX desiderata. Identical observed fixtures intentionally carry
\* incompatible wishes; the classifier cannot inspect these case names.
WantNew == {"new","unrelatedMissing","similarName","createdOnly","modifiedOnly",
 "metadataOnly","eventOnly","oldPathOnly","oldBodyOnly","rawIDOnly","blankTemplate",
 "healthySameBody","healthySameDates","healthyOldPath","independentTemplate",
 "newNoClue","historicTemplate","unrelatedOldPathHint","pathReuseUnrelated",
 "allWeakCopy","crossScopeID","unrelatedHintAndMissing","mixedMissingHealthy",
 "similarBodyOnly","similarTemplateWithHint","templateSameDate"}
WantChoice == {"missingSamePath","renameExactBody","renameEditedHint","renameEditedDates",
 "renameEditedNoClue","historicReturn","oldPathWithHint","splitVotes","twoCandidates",
 "samePathAndCreated","allWeakRename","emptySameName","renamedSmallEdit",
 "similarBodyWithHint","renamedSmallEditDate"}
\* Common repairs are a product priority, NOT measured frequency weights.
CoreRepairs == {"missingSamePath","renameExactBody","twoCandidates","emptySameName"}
QuietNew == WantNew \ {"independentTemplate","historicTemplate","unrelatedOldPathHint",
                        "pathReuseUnrelated","allWeakCopy"}
SelectedCases == IF Scenario="all" THEN Cases ELSE {Scenario}
Kinds == {"none","new","represented","edit","association","provenance","restoration","history","file","ignored"}
VARIABLE s
vars == <<s>>
Init == \E r \in ChosenRules: s=[rule |-> r, done |-> FALSE,
 result |-> [c \in SelectedCases |-> Answer("none",{})]]
Evaluate == /\ ~s.done
 /\ s'=[s EXCEPT !.done=TRUE, !.result=[c \in SelectedCases |-> Decision(Observation(c),s.rule)]]
Next == Evaluate
Spec == Init /\ [][Next]_vars
TypeOK == /\ s.rule \in ChosenRules /\ s.done \in BOOLEAN
 /\ s.result \in [SelectedCases -> [kind: Kinds, targets: SUBSET Notes]]
AutomaticAssociationNeedsEvidence == s.done => \A c \in SelectedCases:
 s.result[c].kind \in {"represented","edit"} =>
 s.result[c].targets \subseteq Strong(Observation(c)) /\ Cardinality(s.result[c].targets)=1
KnownExceptionsRespected == s.done =>
 /\ ("missingSegment" \in SelectedCases => s.result["missingSegment"].kind="history")
 /\ \A c \in SelectedCases \cap {"deletedStamp","deletedDescriptor"}: s.result[c].kind="restoration"
 /\ \A c \in SelectedCases \cap {"copiedStamp","foreignStamp","malformedStamp","skewedStamp","duplicateIDs","caseCollision","contradictoryStamp",
     "contradictoryLocalStamp","contradictoryLocalDescriptor","ambiguousDescriptors"}:
       s.result[c].kind="provenance"
 /\ \A c \in SelectedCases \cap {"placeholder","unreadable"}: s.result[c].kind="file"
 /\ ("reservedFile" \in SelectedCases => s.result["reservedFile"].kind="ignored")
 /\ ("explicitNew" \in SelectedCases => s.result["explicitNew"].kind="new")
HealthyNotesNotOffered == s.done => \A c \in SelectedCases:
 s.result[c].kind="association" => \A n \in s.result[c].targets: NeedsRepair(Observation(c).notes[n])
NoPooledEvidence == s.done => \A c \in SelectedCases:
 s.result[c].kind="association" =>
 \A n \in s.result[c].targets: Plausible(Observation(c),s.rule,n)
ExistingAutomaticPathsRetained == s.done =>
 /\ \A c \in SelectedCases \cap {"currentDescriptor","knownStamp","localRename"}:
       s.result[c]=Answer("represented",{1})
 /\ \A c \in SelectedCases \cap {"handoffChangedBody","skewedLocalHandoff"}:
       s.result[c]=Answer("edit",{1})
ContradictoryLocalStampIsAmbiguous == s.done =>
 \A c \in SelectedCases \cap {"contradictoryLocalStamp","contradictoryLocalDescriptor"}:
  s.result[c].kind="provenance"
AmbiguousDescriptorsNeedReview == s.done /\ "ambiguousDescriptors" \in SelectedCases =>
 s.result["ambiguousDescriptors"].kind="provenance"
HintIndependentClassification == s.done => \A c \in SelectedCases:
 s.result[c]=Decision([Observation(c) EXCEPT !.events={}],s.rule)
NoUnnecessaryQuestions == s.done => \A c \in SelectedCases \cap WantNew: s.result[c].kind="new"
EveryRepairOffered == s.done => \A c \in SelectedCases \cap WantChoice: s.result[c].kind="association"
CommonRepairsOffered == s.done => \A c \in SelectedCases \cap CoreRepairs: s.result[c].kind="association"
UnrelatedNoiseDoesNotPrompt == s.done => \A c \in SelectedCases \cap QuietNew: s.result[c].kind="new"
Safety == AutomaticAssociationNeedsEvidence /\ KnownExceptionsRespected
NeverDecided == ~s.done
NeverOfferedBoth == ~s.done \/ "twoCandidates" \notin SelectedCases
 \/ s.result["twoCandidates"].targets # Notes
NeverReachedIndistinguishablePair == ~s.done \/ Scenario # "all" \/
 s.result["renameExactBody"] # s.result["independentTemplate"]
\* One compact line per rule, interpreted by the existing experimental runner.
\* Counts describe synthetic cases, NOT empirical user error rates.
RECURSIVE SumBits(_)
SumBits(bits) == IF bits={} THEN 0 ELSE LET i==CHOOSE x \in bits: TRUE
 IN 2^(i-1)+SumBits(bits \ {i})
Mask(r) == SumBits(r.bits)
Survey == ~s.done \/ PrintT(<<"NV_IMPORT_SURVEY",Mask(s.rule),s.rule.threshold,s.rule.gate,
 Cardinality({c \in WantNew: s.result[c].kind # "new"}),
 Cardinality({c \in WantChoice: s.result[c].kind # "association"}),
 Cardinality({c \in CoreRepairs: s.result[c].kind # "association"}),
 Cardinality({c \in QuietNew: s.result[c].kind # "new"})>>)
=============================================================================
