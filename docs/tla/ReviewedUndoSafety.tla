------------------------- MODULE ReviewedUndoSafety -------------------------
EXTENDS Naturals, Sequences, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Scenario \in {"undo","redo","history","conflict"}
 /\ Policy \in {"safe","asRecovery","asUndo","clearTail","popOnOpen",
    "cancelPops","staleValue","staleRoot","overwriteOthers","wrongInverse",
    "splitRecord","clearOtherScope"}
\* Protocol/Implementation: invocation-scoped reviewed compensation.
\* One presentation, one approved scalar replacement and its immediate inverse;
\* one remote edit, new local action, root switch and crash. No native invocations,
\* text merge, multi-note approval, provider API or concrete segment codec.
\* Commands target B. Sequence tops are LAST: redo <<D,C>> means C then D.
\* B originally changed title 1 -> 2; intervening Current is 3 (or remote 4).
Empty == <<>>
Pop(q) == SubSeq(q,1,Len(q)-1)
Command == Scenario \in {"undo","redo"}
U0 == IF Scenario="redo" THEN <<"A">> ELSE <<"A","B">>
R0 == IF Scenario="redo" THEN <<"D","C","B">> ELSE <<"D","C">>
Wanted == IF Scenario="redo" THEN 2 ELSE 1
BaseValue == [title |-> 3, body |-> 7, alternative |-> 9]
Initial == [value |-> BaseValue, u |-> U0, r |-> R0, otherRedo |-> <<"K">>]
NoRecord == [before |-> Initial, after |-> Initial, kind |-> "none", target |-> "none", ordinal |-> 0]
EffectiveMode == IF Policy="asRecovery" /\ Command THEN "history"
                ELSE IF Policy="asUndo" /\ ~Command THEN "undo" ELSE Scenario
ForwardU(mode,q) == IF mode="undo" THEN Pop(q)
                   ELSE Append(q,IF mode="redo" THEN "B" ELSE "H")
ForwardR(mode,q) == IF mode="undo" THEN Append(q,"B")
                   ELSE IF mode="redo" THEN Pop(q) ELSE Empty
VARIABLE s
vars == <<s>>
Init == s = [live |-> Initial, disk |-> Initial, diskRecord |-> NoRecord,
    phase |-> "idle", event |-> "init", gen |-> 0, root |-> 0,
    captured |-> Initial, capturedGen |-> 0, capturedRoot |-> 0,
    chosen |-> BaseValue, record |-> NoRecord, approved |-> NoRecord,
    count |-> 0, diskCount |-> 0, ack |-> 0,
    remote |-> FALSE, localEdit |-> FALSE, moved |-> FALSE, crashed |-> FALSE,
    rejected |-> FALSE, recoveredBeforeAck |-> FALSE]
Open == /\ s.phase="idle"
 /\ s' = [s EXCEPT !.phase="review", !.event="open",
    !.captured=s.live, !.capturedGen=s.gen, !.capturedRoot=s.root,
    !.live.u=IF Policy="popOnOpen" THEN Pop(@) ELSE @]
Select == /\ s.phase="review"
 /\ s' = [s EXCEPT !.phase="selected", !.event="select",
    !.chosen=[s.captured.value EXCEPT !.title=Wanted,
        !.body=IF Policy="overwriteOthers" THEN 0 ELSE @,
        !.alternative=IF Policy="overwriteOthers" THEN 0 ELSE @]]
Cancel == /\ s.phase \in {"review","selected"}
 /\ s' = [s EXCEPT !.phase="canceled", !.event="cancel",
    !.live.r=IF Policy="cancelPops" THEN Pop(@) ELSE @]
\* Already admitted/durable external state is a given input. Before approval
\* only: pending compensation versus remote reduction remains a separate bridge.
RemoteEdit == /\ ~s.remote /\ s.phase \in {"idle","review","selected"}
 /\ s' = [s EXCEPT !.remote=TRUE, !.gen=@+1, !.event="remote",
    !.live.value.title=4, !.disk.value.title=4]
NewLocal == /\ ~s.localEdit /\ s.phase \in {"review","selected"}
 /\ LET next == [s.live EXCEPT !.value.title=4, !.u=Append(@,"X"), !.r=Empty]
    IN s' = [s EXCEPT !.localEdit=TRUE, !.gen=@+1, !.event="local",
        !.live=next, !.disk=next]
RootChange == /\ ~s.moved /\ s.phase \in {"review","selected"}
 /\ s' = [s EXCEPT !.moved=TRUE, !.root=@+1, !.event="root"]
Fresh == s.gen=s.capturedGen /\ s.root=s.capturedRoot
         /\ s.live.u=s.captured.u /\ s.live.r=s.captured.r
RejectStale == /\ s.phase \in {"review","selected"} /\ ~Fresh
 /\ s' = [s EXCEPT !.phase="stale", !.event="reject", !.rejected=TRUE]
Approve ==
 /\ s.phase="selected"
 /\ (s.gen=s.capturedGen \/ Policy="staleValue")
 /\ (s.root=s.capturedRoot \/ Policy="staleRoot")
 /\ s.live.u=s.captured.u /\ s.live.r=s.captured.r
 /\ LET after == [s.live EXCEPT !.value=s.chosen,
          !.u=ForwardU(EffectiveMode,@),
          !.r=IF Policy="clearTail" THEN Empty ELSE ForwardR(EffectiveMode,@),
          !.otherRedo=IF Policy="clearOtherScope" THEN Empty ELSE @]
        rec == [before |-> s.live, after |-> after, kind |-> EffectiveMode,
                target |-> IF EffectiveMode \in {"undo","redo"} THEN "B" ELSE "H", ordinal |-> 1]
    IN s' = [s EXCEPT !.live=after, !.record=rec, !.approved=rec,
        !.phase="pending", !.count=1, !.gen=@+1, !.event="approve"]
Write == /\ s.phase="pending"
 /\ s' = [s EXCEPT !.phase="written", !.event="write"]
Install == /\ s.phase="written"
 /\ s' = [s EXCEPT !.phase="installed", !.event="install",
    !.disk=IF Policy="splitRecord" THEN [s.record.after EXCEPT !.r=s.disk.r] ELSE s.record.after,
    !.diskRecord=s.record, !.diskCount=s.count]
Complete == /\ s.phase="installed"
 /\ s' = [s EXCEPT !.phase="settled", !.ack=s.count, !.event="complete"]
\* The inverse uses the approved replacement's actual pre-state, not B's
\* original after-value. Existing C,D remain queued, not automatically applied.
ReverseReviewed == /\ Command /\ s.phase="settled" /\ s.count=1
 /\ LET after == [s.approved.before EXCEPT !.value.title=
          IF Policy="wrongInverse" THEN IF Scenario="undo" THEN 2 ELSE 1
          ELSE s.approved.before.value.title]
        rec == [before |-> s.live, after |-> after,
            kind |-> IF Scenario="undo" THEN "redo" ELSE "undo", target |-> "B", ordinal |-> 2]
    IN s' = [s EXCEPT !.live=after, !.record=rec, !.count=2,
        !.phase="pending", !.gen=@+1, !.event="reverse"]
Crash == /\ ~s.crashed /\ s.phase # "recovered"
 /\ s' = [s EXCEPT !.crashed=TRUE, !.phase="down", !.event="crash"]
Recover == /\ s.phase="down"
 /\ s' = [s EXCEPT !.live=s.disk, !.record=s.diskRecord, !.count=s.diskCount,
    !.phase="recovered", !.event="recover",
    !.recoveredBeforeAck=s.diskCount=1 /\ s.ack=0]
Next == Open \/ Select \/ Cancel \/ RemoteEdit \/ NewLocal \/ RootChange
 \/ RejectStale \/ Approve \/ Write \/ Install \/ Complete \/ ReverseReviewed \/ Crash \/ Recover
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Write) /\ WF_vars(Install) /\ WF_vars(Complete) /\ WF_vars(Recover)
TypeOK == /\ s.phase \in {"idle","review","selected","canceled","stale","pending",
                           "written","installed","settled","down","recovered"}
 /\ s.count \in 0..2 /\ s.diskCount \in 0..2 /\ s.ack \in 0..2
 /\ s.live.value.title \in 1..4 /\ s.disk.value.title \in 1..4
 /\ s.root \in 0..1 /\ s.gen \in 0..4
PresentationPreserves == [][(s'.event \in {"open","select","cancel","reject"}) => s'.live=s.live]_vars
ExactAdmission == [][(s'.event="approve" /\ s.count=0 /\ s'.count=1) => Fresh]_vars
InvocationMeaning == s.approved.ordinal=0 \/
 /\ s.approved.kind=Scenario
 /\ s.approved.target=(IF Command THEN "B" ELSE "H")
 /\ s.approved.after.u=(CASE Scenario="undo" -> Pop(s.approved.before.u)
     [] Scenario="redo" -> Append(s.approved.before.u,"B")
     [] OTHER -> Append(s.approved.before.u,"H"))
 /\ (Command \/ s.approved.after.r=Empty)
RedoTailPreserved == s.approved.ordinal=0 \/ ~Command \/
 s.approved.after.r=(IF Scenario="undo" THEN s.approved.before.r \o <<"B">>
                    ELSE SubSeq(s.approved.before.r,1,Len(s.approved.before.r)-1))
ReviewedScope == s.approved.ordinal=0 \/
 /\ s.approved.after.value.title=Wanted
 /\ s.approved.after.value.body=s.approved.before.value.body
 /\ s.approved.after.value.alternative=s.approved.before.value.alternative
OtherScopePreserved == s.live.otherRedo = <<"K">> /\ s.disk.otherRedo = <<"K">>
DurableAgreement == s.diskCount=0 \/
 /\ s.diskRecord.ordinal>0 /\ s.diskRecord.ordinal=s.diskCount
 /\ s.disk=s.diskRecord.after
LiveAgreement == s.count=0 \/ s.phase="down" \/ s.live=s.record.after
ActualInverse == s.count # 2 \/ s.phase="down" \/ s.live=s.approved.before
Safety == TypeOK /\ InvocationMeaning /\ RedoTailPreserved /\ ReviewedScope
 /\ OtherScopePreserved /\ DurableAgreement /\ LiveAgreement /\ ActualInverse
SettlesAdmitted == <>[](s.phase \notin {"pending","written","installed","down"})
NeverApproved == ~(s.event="approve" /\ s.live.value.title=Wanted)
NeverReversed == ~(s.event="reverse" /\ s.live.value=s.approved.before.value)
NeverCanceled == s.event # "cancel"
NeverRejectedStale == ~s.rejected
NeverRecoveredBeforeAck == ~s.recoveredBeforeAck
NeverBranched == ~(~Command /\ s.event="approve" /\ s.live.r=Empty)
=============================================================================
