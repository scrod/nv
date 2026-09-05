-------------------- MODULE ExternalFileLifecycleSafety --------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","earlyReference","discardReadFailure","replaceFrozen",
 "duplicateRetry","liveNoteLookup","replayConsent","staleAdmission","staleReceipt","uiGated","stickyPrior","dropPrior","reuseOperation"}
 /\ Scenario \in {"pending","race","repeatedCrash","transition","transitionPath","placeholder","unreadableKnown","initialWrite","accounted","multipleCandidates"}
VARIABLE s
vars == <<s>>
E == INSTANCE ExternalImportPolicyLab WITH Policy <- "targeted", Scenario <- "all", s <- s
\* One pending observation on one receiver, two exact snapshot values, up to
\* two ordinary crashes (repeatedCrash), two possible
\* birth IDs (the second detects retry duplication), each with at most two
\* exact operation preparations. An unused birth survives re-preparation;
\* changed semantic inputs receive a fresh operation identity. Immutable operation
\* install abstracts the existing complete segment/action/parent/pin barrier.
\* Snapshot install and its Local State reference switch are SEPARATE actions.
\* stored/latest/frozen/reserved/operation/operations/history/historyOperations/receipt
\* are durable abstract evidence; reserved identifies the prospective birth.
\* phase/frame/preparedHere are volatile execution state (a retained frame has
\* no post-crash consent authority). admittedValues, bad* and the two witness
\* flags are audit-only observers, NOT proposed private file-format fields.
\* No real fsync/codec, full association merge, cross-host transport or private
\* store total-loss proof is claimed. The existing admission bridge covers peers.
Init == s=[file |-> 1, readable |-> TRUE, scope |-> 0,
 stored |-> {}, capture |-> 0, latest |-> 0, frozen |-> 0,
 reserved |-> 0, operation |-> 0,
 operations |-> [i \in 1..4 |-> [birth |-> 0, input |-> 0]],
 historyOperations |-> [i \in 1..2 |-> 0],
 history |-> [i \in 1..2 |-> 0], admittedValues |-> [i \in 1..2 |-> 0],
 receipt |-> 0, phase |-> "idle", frame |-> [file |-> 0, scope |-> 0],
 preparedHere |-> FALSE, down |-> FALSE, crashed |-> FALSE, recovered |-> FALSE,
 crashes |-> 0, retired |-> FALSE,
 visible |-> TRUE, badAdmission |-> FALSE, badReceipt |-> FALSE,
 committedWhileClosed |-> FALSE, recoveredCommitted |-> FALSE,
 transition |-> TRUE, evaluated |-> FALSE, decision |-> "none", decisionTransition |-> TRUE]
Committed == {i \in 1..2: s.history[i] # 0}
ForgetImport == Policy="duplicateRetry" \/ (Policy="liveNoteLookup" /\ s.retired)
ClassificationCases == {"transition","transitionPath","placeholder","unreadableKnown","initialWrite","accounted","multipleCandidates"}
Active == Scenario \notin ClassificationCases
Capture == /\ Active /\ ~s.down /\ s.readable /\ s.capture=0 /\ s.file # s.latest
 /\ s'=[s EXCEPT !.capture=s.file]
InstallSnapshot == /\ ~s.down /\ s.capture # 0 /\ s.capture \notin s.stored
 /\ s'=[s EXCEPT !.stored=@ \cup {s.capture}]
SwitchReference == /\ ~s.down /\ s.capture # 0
 /\ (s.capture \in s.stored \/ Policy="earlyReference")
 /\ s'=[s EXCEPT !.latest=s.capture, !.capture=0]
Protected == ({s.latest,s.frozen,s.capture} \cup
 IF ~s.down /\ s.phase="prepared" THEN {s.frame.file} ELSE {}) \ {0}
Collect(v) == /\ ~s.down /\ v \in s.stored \ Protected
 /\ s'=[s EXCEPT !.stored=@ \ {v}]
ChangeFile == /\ Active /\ s.file=1
 /\ s'=[s EXCEPT !.file=2]
ReadFailure == /\ Active /\ s.readable
 /\ s'=[s EXCEPT !.readable=FALSE,
                 !.stored=IF Policy="discardReadFailure" THEN {} ELSE @]
ChangeScope == /\ Scenario="race" /\ s.scope=0
 /\ s'=[s EXCEPT !.scope=1]
\* Prepare denotes a newly evaluated automatic decision or a fresh manual
\* approval with explicit content choice. It is not fair: users need not choose.
Prepare == /\ Active /\ ~s.down /\ s.phase="idle" /\ s.latest # 0
 /\ s.latest \in s.stored /\ s.readable /\ s.latest=s.file /\ s.scope=0
 /\ (Committed={} \/ ForgetImport)
 /\ s'=[s EXCEPT !.phase="prepared", !.frame=[file |-> s.file, scope |-> s.scope],
                 !.preparedHere=TRUE]
\* Durable reservation and frozen reference precede admission, but are not
\* proof of admission/consent after a crash. No operation is installed here.
Reserve == /\ ~s.down /\ s.phase="prepared"
 /\ LET birth == IF s.reserved=0 THEN 1 ELSE s.reserved
        inputs == [birth |-> birth, input |-> s.frame.file]
        reuse == s.operation # 0 /\ (s.operations[s.operation]=inputs \/ Policy="reuseOperation")
        unused == {i \in 1..4: s.operations[i].input=0}
        op == IF reuse THEN s.operation ELSE CHOOSE i \in unused: \A j \in unused: i<=j
    IN /\ reuse \/ unused # {}
       /\ s'=[s EXCEPT !.reserved=birth, !.operation=op,
         !.operations[op]=IF @.input=0 THEN inputs ELSE @,
         !.frozen=s.frame.file, !.phase="reserved"]
Fresh == s.readable /\ s.frame=[file |-> s.file, scope |-> s.scope]
Admit == /\ ~s.down /\ s.phase="reserved" /\ (Fresh \/ Policy="staleAdmission")
 /\ s'=[s EXCEPT !.phase="admitted", !.badAdmission=@ \/ ~Fresh,
                 !.admittedValues[s.reserved]=s.frozen]
Reject == /\ ~s.down /\ s.phase="reserved" /\ ~Fresh
 /\ s'=[s EXCEPT !.phase="idle", !.frozen=0, !.preparedHere=FALSE]
InstallOperation == /\ ~s.down /\ s.phase="admitted"
 /\ (Policy # "uiGated" \/ s.visible)
 /\ s'=[s EXCEPT !.history[s.reserved]=IF Policy="replaceFrozen" THEN s.file ELSE s.frozen,
                 !.historyOperations[s.reserved]=s.operation,
                 !.phase="durable", !.committedWhileClosed=@ \/ ~s.visible]
ReceiptFresh == s.readable /\ s.file=s.history[s.reserved] /\ s.frame.file=s.file
 /\ s.scope=s.frame.scope /\ ~s.retired
SettleReceipt == /\ ~s.down /\ s.phase="durable" /\ s.reserved \in Committed
 /\ (ReceiptFresh \/ Policy="staleReceipt")
 /\ s'=[s EXCEPT !.receipt=s.reserved, !.phase="done", !.frozen=0,
     !.badReceipt=@ \/ ~ReceiptFresh]
\* Recovery of history does not recover a filesystem accessor or live root
\* authorization. Reacquire exact evidence before installing a receipt.
Reobserve == /\ ~s.down /\ s.phase="durable" /\ s.reserved \in Committed
 /\ s.readable /\ s.file=s.history[s.reserved] /\ s.scope=0 /\ ~s.retired
 /\ s'=[s EXCEPT !.frame=[file |-> s.file, scope |-> s.scope]]
\* Deleting the imported birth later does not erase its import operation.
RetireImport == /\ Scenario="repeatedCrash" /\ Committed # {} /\ ~s.retired
 /\ s'=[s EXCEPT !.retired=TRUE]
\* A successful old receipt remains a historical observation after change;
\* SettleReceipt audits applicability at the actual completion, not forever.
Rescan == /\ Active /\ ~s.down /\ s.phase \in {"durable","done"}
 /\ s'=[s EXCEPT !.phase=IF ForgetImport /\ s.reserved=1 THEN "idle" ELSE "durable",
                 !.reserved=IF ForgetImport /\ s.reserved=1 THEN 2 ELSE @]
Close == /\ s.visible /\ s'=[s EXCEPT !.visible=FALSE]
Open == /\ ~s.visible /\ s'=[s EXCEPT !.visible=TRUE]
Crash == /\ Active /\ ~s.down /\ s.crashes < (IF Scenario="repeatedCrash" THEN 2 ELSE 1)
 /\ s'=[s EXCEPT !.down=TRUE, !.crashed=TRUE, !.phase="idle",
                 !.capture=0, !.preparedHere=FALSE, !.crashes=@+1,
                 !.frame=[file |-> 0, scope |-> 0]]
Recover == /\ s.down
 /\ s'=[s EXCEPT !.down=FALSE, !.recovered=TRUE, !.recoveredCommitted=Committed # {},
   !.phase=IF Committed # {} THEN "durable"
           ELSE IF Policy="replayConsent" /\ s.reserved # 0 /\ s.frozen # 0 THEN "admitted" ELSE "idle",
   !.frozen=IF Committed={} /\ Policy # "replayConsent" THEN 0 ELSE @]
\* Dynamic retirement of the prior ACTIVE projection, using the same
\* classifier as the rule survey. No arbitrary historical path/body search.
TransitionObservation == CASE Scenario="multipleCandidates" -> E!Observation("twoCandidates")
 [] Scenario \in {"placeholder","unreadableKnown","initialWrite","accounted"} ->
    [E!Base EXCEPT !.file.body="A", !.notes[1].relationship=Scenario]
 [] OTHER -> [E!Missing EXCEPT
    !.file.body=IF Scenario="transitionPath" THEN "B" ELSE "PreviousA",
    !.file.path=IF Scenario="transitionPath" THEN "PreviousP" ELSE "Q",
    !.notes[1].transition=IF Policy="stickyPrior" THEN TRUE ELSE IF Policy="dropPrior" THEN FALSE ELSE s.transition]
SettleTransition == /\ Scenario \in {"transition","transitionPath"} /\ s.transition
 /\ s'=[s EXCEPT !.transition=FALSE]
EvaluateTransition == /\ Scenario \in ClassificationCases
 /\ (~s.evaluated \/ s.decisionTransition # s.transition)
 /\ s'=[s EXCEPT !.evaluated=TRUE, !.decisionTransition=s.transition,
                 !.decision=E!Decision(TransitionObservation,E!Targeted).kind]
Next == Capture \/ InstallSnapshot \/ SwitchReference \/ ChangeFile \/ ReadFailure \/ ChangeScope
 \/ Prepare \/ Reserve \/ Admit \/ Reject \/ InstallOperation \/ SettleReceipt \/ Rescan
 \/ Close \/ Open \/ Crash \/ Recover \/ Reobserve \/ RetireImport \/ SettleTransition \/ EvaluateTransition
 \/ (\E v \in 1..2: Collect(v))
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Recover) /\ WF_vars(InstallOperation)
TypeOK == /\ s.file \in 1..2 /\ s.scope \in 0..1
 /\ s.crashes \in 0..2 /\ s.retired \in BOOLEAN
 /\ s.stored \subseteq 1..2 /\ s.capture \in 0..2 /\ s.latest \in 0..2 /\ s.frozen \in 0..2
 /\ s.reserved \in 0..2 /\ s.receipt \in 0..2
 /\ s.operation \in 0..4 /\ s.operations \in [1..4 -> [birth:0..2, input:0..2]]
 /\ s.historyOperations \in [1..2 -> 0..4]
 /\ s.history \in [1..2 -> 0..2] /\ s.admittedValues \in [1..2 -> 0..2]
 /\ s.frame \in [file: 0..2, scope: 0..1]
 /\ s.phase \in {"idle","prepared","reserved","admitted","durable","done"}
 /\ \A k \in {"readable","preparedHere","down","crashed","recovered","visible",
               "badAdmission","badReceipt","transition","evaluated","decisionTransition",
               "committedWhileClosed","recoveredCommitted"}: s[k] \in BOOLEAN
 /\ s.decision \in {"none","association","new"}
ReferencedSnapshotsDurable == {s.latest,s.frozen} \ {0} \subseteq s.stored
NoRepeatedImport == Cardinality(Committed)<=1
ExactAdmittedValue == \A i \in Committed: s.history[i]=s.admittedValues[i]
ReservedOperationMatchesInputs == s.phase \in {"reserved","admitted"} =>
 s.operation # 0 /\ s.operations[s.operation]=[birth |-> s.reserved, input |-> s.frozen]
CommittedOperationMatchesHistory == \A i \in Committed:
 s.historyOperations[i] # 0 /\ s.operations[s.historyOperations[i]]=[birth |-> i, input |-> s.history[i]]
NoReplayedConsent == (~s.down /\ s.phase="admitted") => s.preparedHere
NoStaleAdmission == ~s.badAdmission
NoStaleReceipt == ~s.badReceipt
TransitionRule == s.evaluated =>
 s.decision=IF Scenario="multipleCandidates" \/
 (Scenario \in {"transition","transitionPath"} /\ s.decisionTransition) THEN "association" ELSE "new"
Safety == ReferencedSnapshotsDurable /\ NoRepeatedImport /\ ExactAdmittedValue
 /\ ReservedOperationMatchesInputs /\ CommittedOperationMatchesHistory
 /\ NoReplayedConsent /\ NoStaleAdmission /\ NoStaleReceipt /\ TransitionRule
AdmittedAttemptSettles == s.phase="admitted" ~> (s.down \/ s.phase # "admitted")
NeverReplacedPreviewWhilePinned == ~(s.latest=2 /\ s.frozen=1 /\ s.phase="admitted")
NeverRetainedUnreadable == ~(~s.readable /\ s.latest # 0 /\ s.latest \in s.stored)
NeverRecoveredBeforeReceipt == ~(s.recoveredCommitted /\ Committed # {} /\ s.receipt=0)
NeverCommittedAfterClose == ~s.committedWhileClosed
NeverSettledReceipt == s.receipt=0
NeverResettledAfterTwoCrashes == ~(s.crashes=2 /\ s.phase="done" /\ s.receipt # 0 /\ s.frame.file # 0)
NeverRecoveredRetiredWithoutReceipt == ~(s.crashes=2 /\ ~s.down /\ s.retired /\ Committed # {} /\ s.receipt=0)
NeverReleasedPriorProjection == ~(s.evaluated /\ ~s.decisionTransition /\ s.decision="new")
NeverOfferedPriorProjection == ~(s.evaluated /\ s.decisionTransition /\ s.decision="association")
NeverRepreparedUnusedBirth == ~(s.reserved=1 /\ s.operation=2 /\ s.phase="reserved"
 /\ s.operations[1]=[birth |-> 1, input |-> 1]
 /\ s.operations[2]=[birth |-> 1, input |-> 2] /\ Committed={})
=============================================================================
