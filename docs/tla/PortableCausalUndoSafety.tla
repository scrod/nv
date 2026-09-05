------------------------ MODULE PortableCausalUndoSafety ------------------------
EXTENDS Naturals, FiniteSets

\* Protocol.md: candidate selection from complete immutable action records.
\* Fixed finite graphs isolate ordering from note codecs/installers. Causal
\* parents and compensation targets are separate relations. Delivery, indexing,
\* invocation and one private-store rebuild interleave on two hosts.
\* Invoke SELECTS a command; it does not apply the note-value compensation.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "arrivalOrder", "localOnly", "ignoreScopeParents",
                   "staleCache", "eraseConcurrentRedo", "privateCursor",
                   "originalAfterRedo", "reviveClearedRedo", "collapseCompeting", "scopeWideFork"}
   /\ Scenario \in {"remote", "ordered", "concurrent", "undone", "redone",
                    "undoAgain", "latestUndone", "twoUndos", "redoFirst", "redoBoth",
                    "redoDescendant", "redoConcurrent", "redoBlockedThenUndone", "redoBlockedThenRedone",
                    "competingUndo", "competingRedo", "forkThenEdit", "forkThenUndo",
                    "forkThenRedo", "otherScope", "privateLoss"}

Hosts == {1, 2}
Actions == {"A", "B", "U", "V", "R", "S", "X"}
NoAction == "none"
Directions == {"undo", "redo"}
Modes == {"idle", "none", "automatic", "review"}
TwoActionChain == Scenario \in {"latestUndone", "twoUndos", "redoFirst", "redoBoth"}
CompetingScenario == Scenario \in {"competingUndo", "competingRedo"}
OldForkScenario == Scenario \in {"forkThenEdit", "forkThenUndo", "forkThenRedo"}
Repo == CASE Scenario = "remote" -> {"A"}
 [] Scenario \in {"ordered", "concurrent", "privateLoss"} -> {"A", "B"}
 [] Scenario = "undone" -> {"A", "U"}
 [] Scenario = "redone" -> {"A", "U", "R"}
 [] Scenario = "undoAgain" -> {"A", "U", "R", "V"}
 [] Scenario = "latestUndone" -> {"A", "B", "U"}
 [] Scenario = "twoUndos" -> {"A", "B", "U", "V"}
 [] Scenario = "redoFirst" -> {"A", "B", "U", "V", "R"}
 [] Scenario = "redoBoth" -> {"A", "B", "U", "V", "R", "S"}
 [] Scenario \in {"redoDescendant", "redoConcurrent"} -> {"A", "U", "X"}
 [] Scenario = "redoBlockedThenUndone" -> {"A", "U", "X", "V"}
 [] Scenario = "redoBlockedThenRedone" -> {"A", "U", "X", "V", "R"}
 [] Scenario = "competingUndo" -> {"A", "U", "V"}
 [] Scenario = "competingRedo" -> {"A", "U", "V", "R"}
 [] Scenario = "forkThenEdit" -> {"A", "U", "V", "X"}
 [] Scenario = "forkThenUndo" -> {"A", "U", "V", "X", "R"}
 [] Scenario = "forkThenRedo" -> {"A", "U", "V", "X", "R", "S"}
 [] Scenario = "otherScope" -> {"A", "X"}

Origin(a) == IF a \in {"A", "R", "V"} THEN 1 ELSE 2
Scope(a) == IF Scenario = "otherScope" /\ a = "X" THEN "other" ELSE "note"
Kind(a) == CASE OldForkScenario /\ a = "R" -> "undo"
 [] a \in {"U", "V"} -> "undo"
 [] a \in {"R", "S"} -> "redo" [] OTHER -> "forward"
Target(a) == CASE a = "U" -> IF TwoActionChain THEN "B" ELSE "A"
 [] a = "V" -> CASE Scenario = "undoAgain" -> "R"
                [] Scenario \in {"redoBlockedThenUndone", "redoBlockedThenRedone"} -> "X" [] OTHER -> "A"
 [] a = "R" -> IF OldForkScenario THEN "X"
              ELSE IF TwoActionChain \/ Scenario = "redoBlockedThenRedone" THEN "V" ELSE "U"
 [] a = "S" -> IF OldForkScenario THEN "R" ELSE "U" [] OTHER -> NoAction
Parents(a) == CASE a = "A" -> {}
 [] a = "B" -> IF Scenario = "concurrent" THEN {} ELSE {"A"}
 [] a = "U" -> {Target(a)}
 [] a = "V" -> CASE CompetingScenario \/ OldForkScenario -> {"A"}
                [] TwoActionChain -> {"U"} [] OTHER -> {Target(a)}
 [] a = "R" -> {Target(a)}
 [] a = "S" -> {"R"}
 [] a = "X" -> CASE OldForkScenario -> {"U", "V"}
                [] Scenario \in {"redoDescendant", "redoBlockedThenUndone", "redoBlockedThenRedone"} -> {"U"}
                [] Scenario = "redoConcurrent" -> {"A"} [] OTHER -> {}

Rules == INSTANCE CausalUndoRules
Records == [a \in Actions |-> [parents |-> Parents(a), target |-> Target(a),
                              kind |-> Kind(a), scope |-> Scope(a)]]
Ancestors(a) == Rules!Ancestors(Records, a)
ActionRoot(a) == Rules!Root(Records, a)
Closed(hist) == \A a \in hist: Parents(a) \subseteq hist
Leaves(hist, scope) == Rules!Leaves(Records, hist, scope)
ForwardLeaves(hist, scope) == Rules!ForwardLeaves(Records, hist, scope)
Maximal(candidates) == Rules!Maximal(Records, candidates)
UndoCandidates(hist, scope) == Rules!Undo(Records, hist, scope)
RedoBlocked(hist, a) == Rules!RedoBlocked(Records, hist, a)
RedoCandidates(hist, scope) == Rules!Redo(Records, hist, scope)
CompetingLeaves(hist, scope, candidates) == Rules!Competing(Records, hist, scope, candidates)
RedoAmbiguous(hist, scope) == Rules!RedoAmbiguous(Records, hist, scope)
ModeFor(candidates, ambiguous) == IF candidates = {} THEN "none"
 ELSE IF Cardinality(candidates) = 1 /\ ~ambiguous THEN "automatic" ELSE "review"

\* Independent fixture oracle: concrete expected IDs, not reducer expressions.
ExpectedUndo == CASE Scenario \in {"remote", "otherScope", "latestUndone"} -> {"A"}
 [] Scenario \in {"ordered", "privateLoss"} -> {"B"}
 [] Scenario = "concurrent" -> {"A", "B"}
 [] Scenario \in {"redone", "redoFirst", "competingRedo", "redoBlockedThenRedone"} -> {"R"}
 [] Scenario \in {"redoBoth", "forkThenRedo"} -> {"S"}
 [] Scenario \in {"redoDescendant", "redoConcurrent", "forkThenEdit"} -> {"X"}
 [] OTHER -> {}
ExpectedRedo == CASE Scenario \in {"undone", "redoConcurrent", "redoFirst", "latestUndone"} -> {"U"}
 [] Scenario \in {"undoAgain", "twoUndos", "redoBlockedThenUndone", "competingRedo"} -> {"V"}
 [] Scenario = "competingUndo" -> {"U", "V"}
 [] Scenario = "forkThenUndo" -> {"R"}
 [] OTHER -> {}
ExpectedCandidates(direction) == IF direction = "undo" THEN ExpectedUndo ELSE ExpectedRedo
ExpectedMode(direction) == IF ExpectedCandidates(direction) = {} THEN "none"
 ELSE IF Scenario = "concurrent" \/ CompetingScenario
         \/ (Scenario = "redoConcurrent" /\ direction = "redo") THEN "review"
 ELSE "automatic"

VARIABLE s
vars == <<s>>
Init == s = [accepted |-> [h \in Hosts |-> IF h = 1 THEN Repo ELSE {}],
 index |-> [h \in Hosts |-> IF h = 1 THEN Repo ELSE {}],
 last |-> [h \in Hosts |-> NoAction], mode |-> [h \in Hosts |-> "idle"],
 candidates |-> [h \in Hosts |-> {}], decisionGraph |-> [h \in Hosts |-> {}],
 selected |-> [h \in Hosts |-> NoAction], direction |-> [h \in Hosts |-> "undo"],
 privateLost |-> [h \in Hosts |-> FALSE], rebuilt |-> [h \in Hosts |-> FALSE]]
Deliver(h, a) ==
 /\ ~s.privateLost[h] /\ a \in Repo \ s.accepted[h] /\ Parents(a) \subseteq s.accepted[h]
 /\ s' = [s EXCEPT !.accepted[h] = @ \cup {a}, !.last[h] = a,
      !.mode[h] = "idle", !.selected[h] = NoAction, !.candidates[h] = {}]
Index(h, a) ==
 /\ a \in s.accepted[h] \ s.index[h]
 /\ s' = [s EXCEPT !.index[h] = @ \cup {a}]
LosePrivate(h) ==
 /\ Scenario = "privateLoss" /\ ~s.privateLost[h] /\ ~s.rebuilt[h]
 /\ s' = [s EXCEPT !.accepted[h] = {}, !.index[h] = {}, !.decisionGraph[h] = {},
      !.last[h] = NoAction, !.mode[h] = "idle", !.selected[h] = NoAction,
      !.candidates[h] = {}, !.privateLost[h] = TRUE]
RebuildFromRepository(h) ==
 /\ s.privateLost[h]
 /\ s' = [s EXCEPT !.accepted[h] = Repo, !.index[h] = {},
      !.last[h] = NoAction, !.mode[h] = "idle", !.selected[h] = NoAction,
      !.candidates[h] = {}, !.privateLost[h] = FALSE, !.rebuilt[h] = TRUE]

Seen(h) == IF Policy = "staleCache" THEN s.index[h] ELSE s.accepted[h]
ImplUndo(h) == LET hist == Seen(h)
 base == IF Policy = "ignoreScopeParents" THEN ForwardLeaves(hist, "note")
         ELSE UndoCandidates(hist, "note")
 IN IF Policy = "localOnly" THEN {a \in base: Origin(a) = h}
    ELSE IF Policy = "originalAfterRedo" THEN {ActionRoot(a): a \in base} ELSE base
ImplRedo(h) == LET hist == Seen(h)
 base == IF Policy = "eraseConcurrentRedo" /\ RedoAmbiguous(hist, "note") THEN {}
         ELSE IF Policy = "reviveClearedRedo" THEN Maximal({a \in Leaves(hist, "note"):
              Kind(a) = "undo" /\ ~RedoBlocked(ForwardLeaves(hist, "note"), a)})
         ELSE RedoCandidates(hist, "note")
 IN IF Policy = "localOnly" THEN {a \in base: Origin(a) = h} ELSE base
ImplCandidates(h, direction) ==
 IF Policy = "arrivalOrder" /\ direction = "undo" /\ s.last[h] # NoAction
 THEN {s.last[h]} ELSE IF direction = "undo" THEN ImplUndo(h) ELSE ImplRedo(h)
ImplMode(h, direction) == ModeFor(ImplCandidates(h, direction),
 (Policy # "collapseCompeting" /\ CompetingLeaves(Seen(h), "note",
    IF Policy = "scopeWideFork" THEN Leaves(Seen(h), "note") ELSE ImplCandidates(h, direction)))
 \/ (direction = "redo" /\ Policy # "eraseConcurrentRedo" /\ RedoAmbiguous(Seen(h), "note")))
Invoke(h, direction) ==
 /\ ~s.privateLost[h] /\ (s.index[h] = s.accepted[h] \/ Policy = "staleCache")
 /\ (Policy # "privateCursor" \/ ~s.rebuilt[h])
 /\ s' = [s EXCEPT !.mode[h] = ImplMode(h, direction),
      !.candidates[h] = ImplCandidates(h, direction), !.decisionGraph[h] = Seen(h),
      !.selected[h] = IF ImplMode(h, direction) = "automatic"
                      THEN CHOOSE a \in ImplCandidates(h, direction): TRUE ELSE NoAction,
      !.direction[h] = direction]
Next == (\E h \in Hosts, a \in Actions: Deliver(h,a) \/ Index(h,a))
 \/ (\E h \in Hosts: LosePrivate(h) \/ RebuildFromRepository(h)
                    \/ \E direction \in Directions: Invoke(h,direction))
Spec == Init /\ [][Next]_vars
\* Progress assumes eventual fixture delivery, local indexing/rebuild and command
\* invocation. Safety has no fairness or provider-availability premise.
FairSpec == Spec
 /\ (\A h \in Hosts, a \in Repo: WF_vars(Deliver(h,a)) /\ WF_vars(Index(h,a)))
 /\ (\A h \in Hosts: WF_vars(LosePrivate(h)) /\ WF_vars(RebuildFromRepository(h))
       /\ (\A direction \in Directions: WF_vars(Invoke(h,direction))))

TypeOK == \A h \in Hosts:
 /\ s.accepted[h] \subseteq Repo /\ s.index[h] \subseteq s.accepted[h]
 /\ s.candidates[h] \subseteq Repo /\ s.decisionGraph[h] \subseteq Repo
 /\ s.last[h] \in Repo \cup {NoAction} /\ s.mode[h] \in Modes
 /\ s.selected[h] \in Repo \cup {NoAction} /\ s.direction[h] \in Directions
 /\ s.privateLost[h] \in BOOLEAN /\ s.rebuilt[h] \in BOOLEAN /\ Closed(s.accepted[h])
DecisionUsesCompleteIndex == \A h \in Hosts:
 s.mode[h] = "idle" \/ s.decisionGraph[h] = s.accepted[h]
DecisionMatchesRepository == \A h \in Hosts:
 s.mode[h] = "idle" \/ s.accepted[h] # Repo \/
 /\ s.mode[h] = ExpectedMode(s.direction[h])
 /\ s.candidates[h] = ExpectedCandidates(s.direction[h])
 /\ IF s.mode[h] = "automatic" THEN s.candidates[h] = {s.selected[h]}
    ELSE s.selected[h] = NoAction
EqualHistoriesAgree == \A h1,h2 \in Hosts:
 s.accepted[h1] = s.accepted[h2] /\ s.mode[h1] # "idle" /\ s.mode[h2] # "idle"
 /\ s.direction[h1] = s.direction[h2]
 => s.mode[h1] = s.mode[h2] /\ s.candidates[h1] = s.candidates[h2]
    /\ s.selected[h1] = s.selected[h2]
RedoneTargetsActualCompensation == \A h \in Hosts:
 Scenario # "redone" \/ s.accepted[h] # Repo \/ s.mode[h] = "idle"
 \/ s.direction[h] # "undo" \/ (s.mode[h] = "automatic" /\ s.selected[h] = "R")
ClearedRedoStaysCleared == \A h \in Hosts:
 Scenario \notin {"redoBlockedThenUndone", "redoBlockedThenRedone"}
 \/ s.accepted[h] # Repo \/ s.mode[h] = "idle"
 \/ s.direction[h] # "redo" \/ s.candidates[h] = ExpectedRedo
CompetingCompensationsRequireReview == \A h \in Hosts:
 ~CompetingScenario \/ s.accepted[h] # Repo \/ s.mode[h] \in {"idle", "none", "review"}
Safety == TypeOK /\ DecisionUsesCompleteIndex /\ DecisionMatchesRepository
 /\ EqualHistoriesAgree /\ RedoneTargetsActualCompensation
 /\ ClearedRedoStaysCleared /\ CompetingCompensationsRequireReview

PeerCanUndoRemote == <> (s.mode[2] = "automatic" /\ s.direction[2] = "undo" /\ s.selected[2] = "A")
ConcurrentPeerCanReview == <> (s.mode[2] = "review" /\ s.direction[2] = "undo")
PeerCanRedoCompensation == <> (s.mode[2] = "automatic" /\ s.direction[2] = "redo" /\ s.selected[2] = "U")
PrivateLossCanRebuildUndo == <> (s.rebuilt[1] /\ s.mode[1] = "automatic" /\ s.selected[1] = "B")
\* False invariants require selection/rebuild transitions, not Init facts.
NeverSelectedCausalChild == ~(s.mode[2] = "automatic" /\ s.selected[2] = "B")
NeverReviewedConcurrent == ~(s.mode[2] = "review" /\ s.direction[2] = "undo")
NeverSelectedRemoteAction == ~(s.mode[2] = "automatic" /\ s.selected[2] = "A")
NeverSelectedRemoteCompensation == ~(s.mode[2] = "automatic" /\ s.selected[2] = "U")
NeverRebuiltAfterPrivateLoss == ~(s.rebuilt[1] /\ s.mode[1] = "automatic")
NeverSelectedRedoInverse == ~(s.mode[2] = "automatic" /\ s.selected[2] = "R" /\ s.direction[2] = "undo")
NeverSelectedRemainingRedo == ~(s.mode[2] = "automatic" /\ s.selected[2] = "U" /\ s.direction[2] = "redo")
NeverReviewedCompeting == ~(s.mode[2] = "review" /\ s.accepted[2] = Repo)
NeverContinuedPastOldFork == ~(OldForkScenario /\ s.accepted[2] = Repo /\ s.mode[2] = "automatic")
=============================================================================
