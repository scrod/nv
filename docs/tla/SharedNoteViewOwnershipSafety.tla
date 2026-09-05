-------------------- MODULE SharedNoteViewOwnershipSafety --------------------
EXTENDS Naturals, Sequences, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Scenario \in {"lifecycle","routing","composition"}
 /\ Policy \in {"safe","duplicateObserver","viewOwnsUndo","closeDropsPending",
    "lateBinding","staleAdmission","staleRender","draftCapture","splitCursor","staleClear"}
\* Two views, two notes. X has edit/undo/redo; Y has one independent edit.
\* Three attachment changes permit close A, close B, reopen B, or ABA reuse.
\* Routing isolates one command plus one imported remote edit/root change/UI
\* callback; composition isolates one draft and commits it before detachment.
\* Composition is a fixture for the tested separate-snapshot adapter, not a
\* requirement to replace AppKit input handling or a universal recovery policy.
\* It does not model normal focus transfer; draftCapture challenges this
\* adapter's note/action agreement, not every possible draft recovery design.
\* Finite scalar bodies and command cursors, NOT AppKit invocation serialization.
\* Native attribution, correct IME completion, and whole remote values are
\* assumptions to discharge with probes/real integration. No transport model.
\* Remote stages an input through the local pending path; it is not DUR-01
\* accepted-history retention, and can be lost before its modeled installation.
Views == {"A","B"}
Notes == {"X","Y"}
None == "none"
Zero == [n \in Notes |-> 0]
Value(c) == c % 2
Limit(n) == IF Scenario="lifecycle" /\ n="X" THEN 3 ELSE 1
NoRequest == [view |-> None, note |-> "X", epoch |-> 0, gen |-> 0, root |-> 0]
NoRender == [note |-> None, epoch |-> 0, gen |-> 0, root |-> 0]
Ids(log) == {log[i].id: i \in 1..Len(log)}
Last(log,n) == LET ix == {i \in 1..Len(log): log[i].note=n}
              IN IF ix={} THEN [value |-> 0, cursor |-> 0]
                 ELSE log[CHOOSE i \in ix: \A j \in ix: j<=i]
Body(log) == [n \in Notes |-> Last(log,n).value]
Cursor(log) == [n \in Notes |-> Last(log,n).cursor]
VARIABLE s
vars == <<s>>
Init == s = [attach |-> [v \in Views |-> "X"], epoch |-> [v \in Views |-> 0],
    moves |-> 0, root |-> 0, remote |-> FALSE, marked |-> FALSE, composed |-> FALSE,
    body |-> Zero, cursor |-> Zero, gen |-> Zero, log |-> <<>>, issued |-> 0,
    request |-> NoRequest, notice |-> {}, render |-> [v \in Views |-> NoRender],
    ui |-> NoRequest, uiStarted |-> FALSE,
    pending |-> FALSE, phase |-> "idle", capturedBody |-> Zero,
    capturedCursor |-> Zero, capturedLog |-> <<>>, diskBody |-> Zero,
    diskCursor |-> Zero, diskLog |-> <<>>, ack |-> {},
    down |-> FALSE, crashed |-> FALSE, event |-> "init", rejected |-> FALSE,
    detachedUndo |-> FALSE, reopened |-> FALSE, staleCompletion |-> FALSE,
    recoveredBeforeAck |-> FALSE, rejectedUI |-> FALSE, editView |-> None,
    closedAfterEdit |-> FALSE, savedDuringDraft |-> FALSE, rejectedRemote |-> FALSE]
Running == ~s.down /\ ~s.crashed
Fresh(q) == s.attach[q.view]=q.note /\ s.epoch[q.view]=q.epoch
            /\ s.gen[q.note]=q.gen /\ s.root=q.root
CanCommand(n) == s.cursor[n]<Limit(n)
 /\ (Scenario # "routing" \/ n="X")
 /\ (s.cursor[n]=0 \/ s.body[n]=Value(s.cursor[n]))
Prepare(v) == /\ Running /\ s.request.view=None /\ s.attach[v] \in Notes
 /\ CanCommand(s.attach[v]) /\ ~(s.marked /\ s.attach[v]="X")
 /\ s'=[s EXCEPT !.request=[view |-> v, note |-> s.attach[v], epoch |-> s.epoch[v],
       gen |-> s.gen[s.attach[v]], root |-> s.root], !.event="prepare"]
Admit == /\ Running /\ s.request.view # None
 /\ (Fresh(s.request) \/ Policy \in {"lateBinding","staleAdmission"})
 /\ s.attach[s.request.view] \in Notes
 /\ CanCommand(s.request.note) /\ ~(s.marked /\ s.request.note="X")
 /\ LET n == s.request.note
        target == IF Policy="lateBinding" THEN s.attach[s.request.view] ELSE n
        c == s.cursor[n]+1
        rec == [id |-> s.issued+1, note |-> n, value |-> Value(c), cursor |-> c]
    IN s'=[s EXCEPT !.body[target]=Value(c), !.cursor[target]=c,
       !.gen[target]=@+1, !.log=Append(@,rec), !.issued=@+1,
       !.request=NoRequest, !.notice=Views, !.pending=TRUE, !.event="admit",
       !.editView=IF n="X" /\ c=1 THEN s.request.view ELSE @,
       !.detachedUndo=@ \/ (n="X" /\ c=2 /\ s.attach[s.editView] # "X"),
       !.reopened=@ \/ (n="X" /\ c=2 /\ s.closedAfterEdit)]
Reject == /\ Running /\ s.request.view # None /\ ~Fresh(s.request)
 /\ s'=[s EXCEPT !.request=NoRequest, !.rejected=TRUE, !.event="reject",
       !.rejectedRemote=@ \/ (Scenario="routing" /\ s.gen[s.request.note] # s.request.gen)]
Notify(v) == /\ Running /\ v \in s.notice
 /\ s'=[s EXCEPT !.notice=@\{v}, !.event="notify",
       !.log=IF Policy="duplicateObserver" THEN Append(@,s.log[Len(s.log)]) ELSE @]
Attach(v,n) == /\ Running /\ s.moves<(IF Scenario="routing" THEN 2 ELSE 3) /\ n # s.attach[v]
 /\ ~(s.marked /\ v="A")
 /\ s'=[s EXCEPT !.attach[v]=n, !.epoch[v]=@+1, !.moves=@+1,
       !.render[v]=NoRender, !.event="attach",
       !.closedAfterEdit=@ \/ (n=None /\ s.cursor["X"]=1 /\
          \A other \in Views\{v}: s.attach[other]=None),
       !.cursor=IF Policy="viewOwnsUndo" /\ s.attach[v] \in Notes
                  THEN [@ EXCEPT ![s.attach[v]]=0] ELSE @,
       !.pending=IF Policy="closeDropsPending" /\ n=None THEN FALSE ELSE @]
RootChange == /\ Running /\ Scenario="routing" /\ s.root=0
 /\ s'=[s EXCEPT !.root=1, !.render=[v \in Views |-> NoRender], !.event="root"]
\* Validated value input, not a dependency-closed durably accepted operation.
Remote == /\ Running /\ Scenario="routing" /\ ~s.remote
 /\ LET rec == [id |-> 0, note |-> "X", value |-> 2, cursor |-> s.cursor["X"]]
    IN s'=[s EXCEPT !.remote=TRUE, !.body["X"]=2, !.gen["X"]=@+1,
        !.log=Append(@,rec), !.pending=TRUE, !.event="remote"]
StartUI(v) == /\ Running /\ Scenario="routing" /\ ~s.uiStarted /\ s.attach[v] \in Notes
 /\ s'=[s EXCEPT !.uiStarted=TRUE, !.ui=[view |-> v, note |-> s.attach[v],
       epoch |-> s.epoch[v], gen |-> s.gen[s.attach[v]], root |-> s.root], !.event="ui-start"]
FinishUI == /\ Running /\ s.ui.view # None
 /\ LET valid == Fresh(s.ui)
    IN s'=[s EXCEPT !.render[s.ui.view]=IF valid \/ Policy="staleRender"
       THEN [note |-> s.ui.note, epoch |-> s.ui.epoch, gen |-> s.ui.gen, root |-> s.ui.root] ELSE @,
       !.rejectedUI=@ \/ ~valid, !.ui=NoRequest, !.event="ui-finish"]
StartComposition == /\ Running /\ Scenario="composition" /\ ~s.composed /\ ~s.marked
 /\ s.attach["A"]="X" /\ s.cursor["X"]=0 /\ s.request.view=None
 /\ s'=[s EXCEPT !.marked=TRUE, !.event="marked"]
FinishComposition == /\ Running /\ s.marked
 /\ LET rec == [id |-> s.issued+1, note |-> "X", value |-> 1, cursor |-> 1]
    IN s'=[s EXCEPT !.marked=FALSE, !.composed=TRUE, !.body["X"]=1,
        !.cursor["X"]=1, !.gen["X"]=@+1, !.issued=@+1, !.log=Append(@,rec),
        !.notice=Views, !.pending=TRUE, !.event="compose"]
Capture == /\ ~s.down /\ s.phase="idle" /\ s.pending
 /\ s'=[s EXCEPT !.capturedLog=s.log, !.capturedCursor=s.cursor,
       !.capturedBody=IF Policy="draftCapture" /\ s.marked
          THEN [s.body EXCEPT !["X"]=2] ELSE s.body, !.phase="captured", !.event="capture"]
Write == /\ ~s.down /\ s.phase="captured"
 /\ s'=[s EXCEPT !.phase="written", !.event="write"]
Install == /\ ~s.down /\ s.phase="written"
 /\ s'=[s EXCEPT !.diskLog=s.capturedLog, !.diskBody=s.capturedBody,
       !.diskCursor=IF Policy="splitCursor" THEN @ ELSE s.capturedCursor,
       !.savedDuringDraft=@ \/ (s.marked /\ s.diskBody["Y"]=0 /\
          s.capturedBody["Y"]=1 /\ s.capturedBody["X"]=0),
       !.phase="installed", !.event="install"]
Complete == /\ ~s.down /\ s.phase="installed"
 /\ s'=[s EXCEPT !.ack=@ \cup Ids(s.capturedLog), !.phase="idle",
       !.pending=IF Policy="staleClear" THEN FALSE ELSE s.log # s.capturedLog,
       !.staleCompletion=@ \/ s.log # s.capturedLog, !.event="complete"]
Crash == /\ Running
 /\ s'=[s EXCEPT !.down=TRUE, !.crashed=TRUE, !.event="crash"]
Recover == /\ s.down
 /\ s'=[s EXCEPT !.down=FALSE, !.body=s.diskBody, !.cursor=s.diskCursor,
       !.log=s.diskLog, !.phase="idle", !.pending=FALSE, !.request=NoRequest,
       !.ui=NoRequest, !.marked=FALSE, !.render=[v \in Views |-> NoRender],
       !.recoveredBeforeAck=~((Ids(s.diskLog)\{0}) \subseteq s.ack), !.event="recover"]
Next == (\E v \in Views: Prepare(v) \/ Notify(v) \/ StartUI(v))
 \/ (\E v \in Views,n \in Notes \cup {None}: Attach(v,n))
 \/ Admit \/ Reject \/ RootChange \/ Remote \/ FinishUI
 \/ StartComposition \/ FinishComposition \/ Capture \/ Write \/ Install \/ Complete \/ Crash \/ Recover
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Capture) /\ WF_vars(Write) /\ WF_vars(Install)
 /\ WF_vars(Complete) /\ WF_vars(Recover)
TypeOK == /\ s.attach \in [Views -> Notes \cup {None}] /\ s.epoch \in [Views -> 0..3]
 /\ s.moves \in 0..3 /\ s.root \in 0..1 /\ s.issued \in 0..4
 /\ s.body \in [Notes -> 0..2] /\ s.cursor \in [Notes -> 0..3]
 /\ s.diskBody \in [Notes -> 0..2] /\ s.diskCursor \in [Notes -> 0..3]
 /\ s.gen \in [Notes -> 0..4] /\ s.notice \subseteq Views
 /\ s.phase \in {"idle","captured","written","installed"}
NoDuplicateActions == Cardinality(Ids(s.log))=Len(s.log)
LiveAgreement == s.down \/ (s.body=Body(s.log) /\ s.cursor=Cursor(s.log))
DurableAgreement == s.diskBody=Body(s.diskLog) /\ s.diskCursor=Cursor(s.diskLog)
AcknowledgedSurvive == s.ack \subseteq Ids(s.diskLog)
NoLostPending == s.down \/ s.pending \/ s.phase # "idle" \/ s.log=s.diskLog
ViewBinding == \A v \in Views: s.render[v].note=None \/
    (s.render[v].note=s.attach[v] /\ s.render[v].epoch=s.epoch[v] /\ s.render[v].root=s.root)
ExactAdmission == [][(s'.event="admit" /\ s'.issued=s.issued+1) => Fresh(s.request)]_vars
ExactRendering == [][(s'.event="ui-finish" /\ s'.render # s.render) => Fresh(s.ui)]_vars
PresentationPreserves == [][(s'.event \in {"attach","prepare","reject","notify","ui-start","ui-finish"})
    => (s'.body=s.body /\ s'.cursor=s.cursor /\ s'.log=s.log)]_vars
Safety == TypeOK /\ NoDuplicateActions /\ LiveAgreement /\ DurableAgreement
 /\ AcknowledgedSurvive /\ NoLostPending /\ ViewBinding
EventuallyDurable == <>[](~s.down /\ ~s.pending /\ s.body=s.diskBody /\ s.cursor=s.diskCursor)
NeverUndidAfterDetach == ~s.detachedUndo
NeverUndidAfterReopen == ~s.reopened
NeverRejectedAdmission == ~s.rejected
NeverRejectedRemote == ~s.rejectedRemote
NeverRejectedUI == ~s.rejectedUI
NeverRecoveredBeforeAck == ~s.recoveredBeforeAck
NeverCompletedStale == ~s.staleCompletion
NeverSavedOtherNoteDuringDraft == ~s.savedDuringDraft
=============================================================================
