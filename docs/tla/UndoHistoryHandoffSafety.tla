--------------------- MODULE UndoHistoryHandoffSafety ---------------------
EXTENDS Naturals, Sequences, FiniteSets, TLC
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "replaceIndex", "duplicateOwner", "popFirst",
                   "rawNative", "staleCommit", "unchecked", "splitRecord", "consumeConflict"}
    /\ Scenario \in {"prefix", "title", "overlap", "delete", "conflict"}
\* Public-AppKit probe -> proposed logical command router, NOT an NSTextView model.
\* H is an older durable local action, N a completed newer local capture while
\* H's index loads. One independently authored remote input: a disjoint field/
\* text region, overlapping rewrite, Delete, or unresolved alternative. Values
\* abstract exact disjoint LF regions, not arbitrary character-range rebasing.
\* One command in flight; <=4 undo/redo admissions, one remote arrival and crash.
\* Existing segment models separately establish the assumed complete barrier.
Ids == {"H", "N"}
Empty == <<>>
Pop(q) == SubSeq(q,1,Len(q)-1)
Top(q) == q[Len(q)]
Members(q) == {q[i] : i \in 1..Len(q)}
Base == [local |-> 1, prefix |-> FALSE, title |-> 0, alternative |-> 0, alive |-> TRUE]
VARIABLE s
vars == <<s>>
Init == s = [value |-> Base, durableValue |-> Base,
    u |-> Empty, r |-> Empty, du |-> <<"H">>, dr |-> Empty,
    indexReady |-> FALSE, newer |-> FALSE, remote |-> FALSE,
    nativeValid |-> TRUE, gen |-> 0, capturedGen |-> 0,
    phase |-> "idle", op |-> "undo", target |-> "H", candidate |-> Base,
    oldU |-> Empty, oldR |-> Empty, nextU |-> Empty, nextR |-> Empty,
    admissions |-> 0, stage |-> 0, down |-> FALSE, crashed |-> FALSE,
    refused |-> FALSE, refusedU |-> Empty, refusedR |-> Empty,
    redone |-> {}, recoveredCompensation |-> FALSE,
    remoteDuringPrepare |-> FALSE, rejectedRemote |-> FALSE, preservedRemoteUndo |-> FALSE]
Can(v,op,id) == v.alive /\ v.local =
    (IF op = "undo" THEN IF id = "N" THEN 2 ELSE 1
                      ELSE IF id = "N" THEN 1 ELSE 0)
Compensate(v,op,id) == [v EXCEPT
    !.local = IF op = "undo" THEN IF id = "N" THEN 1 ELSE 0
                              ELSE IF id = "N" THEN 2 ELSE 1,
    !.prefix = IF Policy = "rawNative" /\ id = "N" /\ ~s.nativeValid THEN FALSE ELSE @,
    !.alternative = IF Policy = "consumeConflict" THEN 0 ELSE @]
\* Completion of a newer local action's existing segment barrier. The native
\* token -> N mapping is a probe/integration obligation, never inferred here.
InstallNewLocal ==
 /\ ~s.down /\ ~s.newer /\ s.admissions = 0 /\ s.phase = "idle"
 /\ s.value.local = 1 /\ s.value.alive
 /\ s' = [s EXCEPT !.value.local = 2, !.durableValue.local = 2,
      !.u = Append(@,"N"), !.du = Append(@,"N"), !.newer = TRUE,
      !.gen = @ + 1, !.refused = FALSE]
PublishOldIndex ==
 /\ ~s.down /\ ~s.indexReady /\ s.phase \in {"idle","prepared"}
 /\ s' = [s EXCEPT !.indexReady = TRUE,
      !.u = IF Policy = "replaceIndex" THEN <<"H">>
            ELSE IF Policy = "duplicateOwner" /\ "N" \in Members(s.u)
                 THEN <<"H">> \o s.u \o <<"N">> ELSE <<"H">> \o s.u,
      !.gen = @ + 1, !.refused = FALSE]
RemoteValue(v) == CASE Scenario = "prefix" -> [v EXCEPT !.prefix = TRUE]
 [] Scenario = "title" -> [v EXCEPT !.title = 1]
 [] Scenario = "overlap" -> [v EXCEPT !.local = 3]
 [] Scenario = "delete" -> [v EXCEPT !.alive = FALSE]
 [] OTHER -> [v EXCEPT !.alternative = 1]
ReceiveRemote ==
 /\ ~s.down /\ ~s.remote /\ s.newer
 /\ s.phase \in {"idle","prepared"}
 /\ s' = [s EXCEPT !.remote = TRUE, !.value = RemoteValue(@),
      !.durableValue = RemoteValue(@), !.gen = @ + 1,
      !.nativeValid = Scenario \in {"title","conflict"}, !.refused = FALSE,
      !.remoteDuringPrepare = s.phase="prepared"]
Prepare(op) ==
 /\ ~s.down /\ s.phase = "idle" /\ s.admissions < 4
 /\ LET q == IF op = "undo" THEN s.u ELSE s.r IN
    /\ Len(q) > 0
    /\ s' = [s EXCEPT !.phase = "prepared", !.op = op, !.target = Top(q),
         !.candidate = Compensate(s.value,op,Top(q)), !.capturedGen = s.gen,
         !.oldU = s.u, !.oldR = s.r,
         !.nextU = IF op = "undo" THEN Pop(s.u) ELSE Append(s.u,Top(q)),
         !.nextR = IF op = "undo" THEN Append(s.r,Top(q)) ELSE Pop(s.r),
         !.u = IF Policy = "popFirst" /\ op = "undo" THEN Pop(@) ELSE @,
         !.r = IF Policy = "popFirst" /\ op = "redo" THEN Pop(@) ELSE @,
         !.refused = FALSE, !.remoteDuringPrepare=FALSE]
Applicable == s.capturedGen = s.gen /\ Can(s.value,s.op,s.target)
Admit ==
 /\ ~s.down /\ s.phase = "prepared"
 /\ (Applicable \/ (Policy = "staleCommit" /\ Can(s.candidate,
           IF s.op = "undo" THEN "redo" ELSE "undo",s.target)) \/ Policy = "unchecked")
 /\ s' = [s EXCEPT !.value = s.candidate, !.u = s.nextU, !.r = s.nextR,
      !.phase = "pending", !.stage = 0, !.admissions = @ + 1,
      !.redone = IF s.op="redo" THEN @ \cup {s.target} ELSE @,
      !.preservedRemoteUndo = @ \/ (s.remote /\ Scenario="prefix" /\ s.op="undo" /\ s.candidate.prefix /\ s.candidate.local=1),
      !.gen = @ + 1]
Reject ==
 /\ ~s.down /\ s.phase = "prepared" /\ ~Applicable
 /\ s' = [s EXCEPT !.phase = "idle", !.refused = TRUE,
      !.refusedU = IF s.capturedGen = s.gen THEN s.oldU ELSE s.u,
      !.refusedR = IF s.capturedGen = s.gen THEN s.oldR ELSE s.r,
      !.rejectedRemote = @ \/ s.remoteDuringPrepare]
WriteGroup == /\ ~s.down /\ s.phase = "pending" /\ s.stage = 0
 /\ s' = [s EXCEPT !.stage = 1]
InstallGroup ==
 /\ ~s.down /\ s.phase = "pending" /\ s.stage = 1
 /\ s' = [s EXCEPT !.durableValue = s.candidate, !.stage = 2,
      !.du = IF Policy = "splitRecord" THEN @ ELSE
             IF s.op = "undo" THEN Pop(@) ELSE Append(@,s.target),
      !.dr = IF Policy = "splitRecord" THEN @ ELSE
             IF s.op = "undo" THEN Append(@,s.target) ELSE Pop(@)]
Complete == /\ ~s.down /\ s.phase = "pending" /\ s.stage = 2
 /\ s' = [s EXCEPT !.phase = "idle"]
Crash == /\ ~s.down /\ ~s.crashed
 /\ s' = [s EXCEPT !.down = TRUE, !.crashed = TRUE, !.u = Empty, !.r = Empty, !.refused = FALSE]
Recover == /\ s.down
 /\ s' = [s EXCEPT !.down = FALSE, !.value = s.durableValue,
      !.u = s.du, !.r = s.dr, !.indexReady = TRUE, !.phase = "idle",
      !.stage = 0, !.nativeValid = FALSE, !.gen = @ + 1,
      !.recoveredCompensation = @ \/ (s.newer /\ s.durableValue.local=1 /\ "N" \in Members(s.dr))]
Next == InstallNewLocal \/ PublishOldIndex \/ ReceiveRemote \/
 (\E op \in {"undo","redo"}: Prepare(op)) \/ Admit \/ Reject \/
 WriteGroup \/ InstallGroup \/ Complete \/ Crash \/ Recover
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(PublishOldIndex) /\ WF_vars(Recover)
 /\ WF_vars(Admit) /\ WF_vars(Reject) /\ WF_vars(WriteGroup)
 /\ WF_vars(InstallGroup) /\ WF_vars(Complete)
TypeOK == /\ s.value.local \in 0..3 /\ s.durableValue.local \in 0..3
 /\ s.admissions \in 0..4 /\ s.stage \in 0..2
 /\ s.redone \subseteq Ids
 /\ Members(s.u) \cup Members(s.r) \cup Members(s.du) \cup Members(s.dr) \subseteq Ids
NoDuplicateOwner == s.down \/
 (Len(s.u)+Len(s.r) = Cardinality(Members(s.u) \cup Members(s.r)))
NewerActionRetained == s.down \/ ~s.newer \/ "N" \in Members(s.u) \cup Members(s.r)
NewestBeforeHistorical == s.down \/ "N" \notin Members(s.u) \/ Top(s.u) = "N"
RefusalDoesNotPop == s.down \/ ~s.refused \/ (s.u = s.refusedU /\ s.r = s.refusedR)
RemoteIntentPreserved == ~s.remote \/ s.down \/
 CASE Scenario = "prefix" -> s.value.prefix
 [] Scenario = "title" -> s.value.title = 1
 [] Scenario = "overlap" -> s.value.local = 3
 [] Scenario = "delete" -> ~s.value.alive
 [] OTHER -> s.value.alternative = 1
\* Independent concrete oracle: removing N leaves H's value 1; removing both
\* gives 0, restoring N gives 2. Remote overlap is intentionally never undone.
DurableEffectMatchesPosition == s.durableValue.local =
 IF s.remote /\ Scenario = "overlap" THEN 3
 ELSE IF "N" \in Members(s.du) THEN 2 ELSE IF "H" \in Members(s.du) THEN 1 ELSE 0
Safety == TypeOK /\ NoDuplicateOwner /\ NewerActionRetained /\ NewestBeforeHistorical
 /\ RefusalDoesNotPop /\ RemoteIntentPreserved /\ DurableEffectMatchesPosition
EventuallyReadyAndSettled == <>[](s.indexReady /\ ~s.down /\ s.phase # "pending")
NeverUndidNewThenOld == ~(s.newer /\ s.admissions >= 2 /\ s.value.local = 0)
NeverRecoveredCompensation == ~s.recoveredCompensation
NeverPreservedRemoteUndo == ~s.preservedRemoteUndo
NeverRejectedInterveningRemote == ~s.rejectedRemote
NeverRejectedRedoAfterRemote == ~(s.remote /\ s.refused /\ s.op = "redo")
NeverRedidBoth == ~(s.redone=Ids /\ s.value.local=2 /\ s.dr=Empty)
=============================================================================
