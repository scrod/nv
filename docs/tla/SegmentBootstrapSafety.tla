----------------------- MODULE SegmentBootstrapSafety -----------------------
EXTENDS Naturals, FiniteSets
\* Proposal 5 Protocol: initial import, snapshot preview, current materialization/tail.
\* One starting observer of a fixed two-note history; delivery is arbitrary.
\* Authentication/schema truth is an INPUT, not a cryptographic proof. Startup
\* stops at editable publication; ongoing reconciliation is modeled elsewhere.
\* Rows abstracts current-view catch-up/rebuild, not an O(history) launch algorithm.
\* SQLiteFastStartSafety/SQL checks refine indexed returning-launch behavior.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","rootOnly","emptyFallback","skipTail",
                   "trustFilename","staleRoot","rebuildSettings","rebuildGated"}
       /\ Scenario \in {"new","returning","local"}
InitialHistory == {"genesis","a","b","complete"}
Objects == InitialHistory \cup {"page","snapshot","late","foreign"}
Deps(o) == CASE o = "a" \/ o = "b" -> {"genesis"}
  [] o = "complete" -> {"genesis","a","b"}
  [] o = "snapshot" -> {"page","complete","genesis","a","b"}
  [] o = "late" -> InitialHistory
  [] OTHER -> {}
Valid(o) == o # "foreign"
Rows(objects) == [a |-> IF "late" \in objects THEN 2
                       ELSE IF "a" \in objects THEN 1 ELSE 0,
                  b |-> IF "b" \in objects THEN 7 ELSE 0]
Zero == [a |-> 0,b |-> 0]
VARIABLE s
vars == <<s>>
Init == \E currentStatus \in (IF Scenario = "new" THEN {"missing"}
                      ELSE {"good","stale","missing","corrupt"}):
 s = [raw |-> {}, durable |-> IF Scenario = "new" THEN {}
                     ELSE InitialHistory \cup {"late"},
      phase |-> "collect", currentStatus |-> currentStatus, prepared |-> Zero,
      captured |-> {}, capturedRoot |-> 1, root |-> 1,
      view |-> Zero, preview |-> FALSE, previewEvidence |-> {},
      publishedEvidence |-> {}, publishedRoot |-> 0,
      privateSettings |-> 7, loadedSettings |-> 7,
      settingsSaved |-> FALSE, crashed |-> FALSE, down |-> FALSE,
      viewInvalidated |-> FALSE]
Receive(o) ==
 /\ ~s.down /\ s.phase = "collect" /\ Scenario # "local"
 /\ o \in Objects \ (s.raw \cup s.durable)
 /\ s' = [s EXCEPT !.raw = @ \cup {o}]
ValidateAndPersist(o) ==
 /\ ~s.down /\ s.phase = "collect" /\ o \in s.raw \ s.durable
 /\ Valid(o) \/ Policy = "trustFilename"
 /\ s' = [s EXCEPT !.durable = @ \cup {o}]
Preview ==
 /\ ~s.down /\ s.phase = "collect" /\ ~s.preview
 /\ "snapshot" \in s.durable
 /\ Policy = "rootOnly" \/ "page" \in s.durable
 /\ s' = [s EXCEPT !.preview = TRUE, !.previewEvidence = s.durable \cap {"snapshot","page"}]
Prepare ==
 /\ ~s.down /\ s.phase = "collect"
 /\ InitialHistory \subseteq s.durable \/ Policy = "emptyFallback"
 /\ Policy # "rebuildGated" \/ (~s.viewInvalidated /\ s.currentStatus = "good")
 /\ s' = [s EXCEPT !.phase = "prepared", !.captured = s.durable,
       !.capturedRoot = s.root,
       !.prepared = IF Policy = "skipTail" /\ s.currentStatus = "stale"
                      THEN [a |-> 1,b |-> 7] ELSE Rows(s.durable)]
ChangeRoot ==
 /\ ~s.down /\ s.phase = "prepared" /\ s.root = 1
 /\ s' = [s EXCEPT !.root = 2]
SaveSettings ==
 /\ Scenario # "new" /\ ~s.down /\ s.phase # "editing" /\ ~s.settingsSaved
 /\ s' = [s EXCEPT !.privateSettings = 9, !.loadedSettings = 9,
                    !.settingsSaved = TRUE]
InvalidateMaterialization ==
 /\ Scenario # "new" /\ ~s.down /\ ~s.viewInvalidated /\ s.phase # "editing"
 /\ s' = [s EXCEPT !.viewInvalidated = TRUE, !.currentStatus = "missing",
       !.loadedSettings = IF Policy = "rebuildSettings" THEN 7 ELSE @]
Publish ==
 /\ ~s.down /\ s.phase = "prepared"
 /\ Policy = "staleRoot" \/ s.capturedRoot = s.root
 /\ s' = [s EXCEPT !.phase = "editing", !.view = s.prepared,
       !.publishedEvidence = s.captured, !.publishedRoot = s.capturedRoot]
Crash ==
 /\ ~s.crashed /\ s.phase # "editing" /\ Scenario # "local"
 /\ s' = [s EXCEPT !.crashed = TRUE, !.down = TRUE,
       !.raw = {}, !.captured = {}, !.prepared = Zero,
       !.preview = FALSE, !.loadedSettings = 0, !.phase = "collect"]
Restart ==
 /\ s.down
 /\ s' = [s EXCEPT !.down = FALSE, !.loadedSettings = s.privateSettings]
Next == (\E o \in Objects: Receive(o) \/ ValidateAndPersist(o))
 \/ Preview \/ Prepare \/ ChangeRoot \/ SaveSettings \/ InvalidateMaterialization
 \/ Publish \/ Crash \/ Restart
Spec == Init /\ [][Next]_vars
\* Local scenario is local-only and excludes root changes in the progress run.
LocalNext == Prepare \/ SaveSettings \/ InvalidateMaterialization \/ Publish
LocalFairSpec == Init /\ [][LocalNext]_vars /\ WF_vars(Prepare) /\ WF_vars(Publish)
TypeOK ==
 /\ s.raw \subseteq Objects /\ s.durable \subseteq Objects
 /\ s.phase \in {"collect","prepared","editing"}
 /\ s.currentStatus \in {"good","stale","missing","corrupt"}
 /\ s.prepared \in [a: 0..2,b: {0,7}] /\ s.view \in [a: 0..2,b: {0,7}]
 /\ s.captured \subseteq Objects /\ s.publishedEvidence \subseteq Objects
 /\ s.previewEvidence \subseteq Objects
 /\ s.root \in 1..2 /\ s.capturedRoot \in 1..2 /\ s.publishedRoot \in 0..2
 /\ s.privateSettings \in {7,9} /\ s.loadedSettings \in {0,7,9}
 /\ \A f \in {"preview","settingsSaved","crashed","down","viewInvalidated"}: s[f] \in BOOLEAN
NoForeignAcceptance == "foreign" \notin s.durable
PreviewHasPages == s.preview => {"snapshot","page"} \subseteq s.previewEvidence
EditableHasCompleteImport == s.phase = "editing" =>
 /\ {"genesis","a","b","complete"} \subseteq s.publishedEvidence
 /\ s.view.b = 7 /\ s.view.a \in {1,2}
LocalTailNotLost == s.phase = "editing" /\ "late" \in s.publishedEvidence => s.view.a = 2
PublishedUnderCurrentRoot == s.phase = "editing" => s.publishedRoot = s.root
RebuildCannotResetSettings == ~s.down => s.loadedSettings = (IF s.settingsSaved THEN 9 ELSE 7)
Safety == NoForeignAcceptance /\ PreviewHasPages /\ EditableHasCompleteImport
 /\ LocalTailNotLost /\ PublishedUnderCurrentRoot /\ RebuildCannotResetSettings
LocalStartupProgress == <> (s.phase = "editing" /\ s.view = [a |-> 2,b |-> 7])
NeverPreviewedIncompleteHistory == ~(s.preview /\ "complete" \notin s.durable)
NeverReopenedWithTail == ~(s.crashed /\ s.phase = "editing" /\ s.view.a = 2)
NeverRebuiltCurrent == ~(s.phase = "editing" /\ s.viewInvalidated /\ s.view.a = 2)
=============================================================================
