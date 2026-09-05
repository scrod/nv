------------------------ MODULE NativeUndoSpanSafety ------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "wholeSpan", "redoWholeSpan", "splitCoverage", "staleClear"}
 /\ Scenario = "spans"
\* Two complete saved spans: empty -> AB and AB -> ABCD, boundaries 0/2/4.
\* Four native sub-actions; cursor c denotes the exact prefix of ABCD.
\* Markers and actual native before/after values supply the active span.
\* This finite value fixture does NOT infer identity from a text length, prove
\* NSTextView marker behavior, model rich text, or contain a remote reducer.
\* Local capture and completion can interleave with further native commands.
\* Recovery is terminal for native typing: private AppKit groups do not survive
\* a launch. The separate handoff model exercises reconstructed saved actions.
Spans == {1,2}
Start(i) == IF i=1 THEN 0 ELSE 2
Finish(i) == IF i=1 THEN 2 ELSE 4
Clamp(c,i) == IF c < Start(i) THEN Start(i) ELSE IF c > Finish(i) THEN Finish(i) ELSE c
InitialCoverage == [i \in Spans |-> Finish(i)]
VARIABLE s
vars == <<s>>
Init == s = [body |-> 4, coverage |-> InitialCoverage,
    durableBody |-> 4, durableCoverage |-> InitialCoverage,
    gen |-> 0, durableGen |-> 0, pending |-> FALSE,
    phase |-> "idle", capturedBody |-> 4, capturedCoverage |-> InitialCoverage,
    capturedGen |-> 0, nativeSteps |-> 0, crashed |-> FALSE, down |-> FALSE,
    partialRecovered |-> FALSE, staleCompleted |-> FALSE, lastOp |-> "none"]
Native(op) ==
 /\ ~s.down /\ ~s.crashed /\ s.nativeSteps < 6
 /\ (op="undo" /\ s.body>0) \/ (op="redo" /\ s.body<4)
 /\ LET after == IF op="undo" THEN s.body-1 ELSE s.body+1
        active == IF (IF op="undo" THEN s.body ELSE after) <= 2 THEN 1 ELSE 2
    IN s' = [s EXCEPT !.body = after,
       !.coverage[active] = IF Policy="wholeSpan" /\ op="undo" THEN Start(active)
          ELSE IF Policy="redoWholeSpan" /\ op="redo" THEN Finish(active) ELSE after,
       !.gen = @+1, !.pending = TRUE, !.nativeSteps = @+1, !.lastOp=op]
Capture == /\ ~s.down /\ s.pending /\ s.phase="idle"
 /\ s' = [s EXCEPT !.phase="captured", !.capturedBody=s.body,
      !.capturedCoverage=s.coverage, !.capturedGen=s.gen]
Write == /\ ~s.down /\ s.phase="captured"
 /\ s' = [s EXCEPT !.phase="written"]
Install == /\ ~s.down /\ s.phase="written"
 /\ s' = [s EXCEPT !.phase="installed", !.durableBody=s.capturedBody,
      !.durableCoverage=IF Policy="splitCoverage" THEN @ ELSE s.capturedCoverage,
      !.durableGen=s.capturedGen]
Complete == /\ ~s.down /\ s.phase="installed"
 /\ s' = [s EXCEPT !.phase="idle",
      !.pending=IF Policy="staleClear" THEN FALSE ELSE s.gen # s.capturedGen,
      !.staleCompleted = @ \/ s.gen # s.capturedGen]
Crash == /\ ~s.down /\ ~s.crashed
 /\ s' = [s EXCEPT !.crashed=TRUE, !.down=TRUE]
Recover == /\ s.down
 /\ s' = [s EXCEPT !.down=FALSE, !.body=s.durableBody,
      !.coverage=s.durableCoverage, !.gen=s.durableGen,
      !.phase="idle", !.pending=FALSE, !.lastOp="none",
      !.partialRecovered = s.durableBody \in {1,3}]
Next == (\E op \in {"undo","redo"}: Native(op)) \/ Capture \/ Write \/ Install \/ Complete \/ Crash \/ Recover
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Capture) /\ WF_vars(Write) /\ WF_vars(Install)
 /\ WF_vars(Complete) /\ WF_vars(Recover)
TypeOK == s.body \in 0..4 /\ s.durableBody \in 0..4 /\ s.nativeSteps \in 0..6
 /\ s.coverage \in [Spans -> 0..4] /\ s.durableCoverage \in [Spans -> 0..4]
LiveRemainingEffect == s.down \/ \A i \in Spans: s.coverage[i]=Clamp(s.body,i)
DurableRemainingEffect == \A i \in Spans: s.durableCoverage[i]=Clamp(s.durableBody,i)
NoLostPending == s.down \/ s.phase # "idle" \/ s.gen=s.durableGen \/ s.pending
Safety == TypeOK /\ LiveRemainingEffect /\ DurableRemainingEffect /\ NoLostPending
EventuallyDurable == <>[](~s.down /\ ~s.pending /\ s.body=s.durableBody)
NeverRecoveredPartial == ~s.partialRecovered
NeverCompletedStale == ~s.staleCompleted
NeverRedidPartial == ~(s.lastOp="redo" /\ s.body=3 /\ s.coverage[2]=3)
=============================================================================
