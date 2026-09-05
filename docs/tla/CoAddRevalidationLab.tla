------------------------- MODULE CoAddRevalidationLab -------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"scan", "historyFirst", "priority", "hinted", "sticky", "eventEpoch", "quietTrust",
                   "hintAuthority", "hintOnly", "noFileFence", "noRootFence", "noHistoryFence"}
 /\ Scenario \in {"safeSave", "rename", "asymmetric", "roundTrip", "reuse",
                  "duplicate", "gap", "fileRace", "rootRace", "historyRace", "staleStamp",
                  "missingHistory", "hintStorm"}

\* Experimental revalidation, not a physical-incarnation detector or an
\* occupancy-event writer. Protocol.md's unique represented-state decision
\* supplies identity; FSEventsHistoryProbe.m supplies possible hint shapes.
\* Two hosts inspect the SAME abstract final projection state; their histories,
\* local generations, hint availability/timing and read order can differ.
\* No action reads hidden physical origin. A copied exact unique projection
\* can represent known state: this model does NOT prove physical sameness.
Hosts == {1,2}
Paths == {"P","Q"}
PoliciesWithHints == {"priority","hinted","sticky","eventEpoch","quietTrust","hintAuthority",
                      "hintOnly","noFileFence","noRootFence","noHistoryFence"}
Moved == Scenario \in {"rename","asymmetric","gap","missingHistory"}
HasNewHistory == Moved \/ Scenario \in {"historyRace","staleStamp"}
InitialHistory == IF Scenario \in {"rename","asymmetric","gap"} THEN {0,1} ELSE {0}
HistoryPath(r) == IF r=1 /\ Moved THEN "Q" ELSE "P"
Latest(k) == IF 1 \in k THEN 1 ELSE 0
Episode(k) == IF Latest(k)=1 THEN "E1" ELSE "E0"
\* All history revisions have payload 0. Payload 1 is unrepresented work.
File(present, inode, body, stamp) ==
 [present |-> present, inode |-> inode, body |-> body, stamp |-> stamp]
Absent == File(FALSE,0,0,2)
Files(v) == [p \in Paths |->
 IF Moved THEN IF p="Q" THEN File(TRUE,1,0,1) ELSE Absent
 ELSE IF p="Q" THEN IF Scenario="duplicate" THEN File(TRUE,2,0,0) ELSE Absent
 ELSE IF Scenario="reuse" \/ (Scenario="fileRace" /\ v=1) THEN File(TRUE,2,1,2)
 ELSE File(TRUE,IF Scenario="safeSave" THEN 2 ELSE 1,0,
           IF Scenario="historyRace" THEN 2 ELSE 0)]
HintAvailable(h) == Scenario # "asymmetric" \/ h=1
MaxHints(h) == IF Scenario="hintStorm" /\ h=1 THEN 3 ELSE 1
HintPath == IF Moved \/ Scenario="duplicate" THEN "Q" ELSE "P"
\* Gap is positive loss/invalid-cursor evidence; it is not a path hint.
HintKind == IF Scenario="gap" THEN "gap" ELSE "path"
DefaultFrame == [version |-> 0, root |-> 0,
                  history |-> InitialHistory, hint |-> 0]
Active == {"reading","prepared"}
Terminal == {"associated","review","waiting","exhausted"}
VARIABLE s
vars == <<s>>
Init == s = [version |-> [h \in Hosts |-> 0], root |-> [h \in Hosts |-> 0],
 history |-> [h \in Hosts |-> InitialHistory], hint |-> [h \in Hosts |-> 0],
 phase |-> [h \in Hosts |-> "idle"], attempts |-> [h \in Hosts |-> 0],
 frame |-> [h \in Hosts |-> DefaultFrame], read |-> [h \in Hosts |-> {}],
 bytes |-> [h \in Hosts |-> [p \in Paths |-> Absent]],
 result |-> [h \in Hosts |-> "none"], token |-> [h \in Hosts |-> "none"],
 first |-> [h \in Hosts |-> "none"], rejectHint |-> [h \in Hosts |-> FALSE],
 rejectFile |-> FALSE, rejectRoot |-> FALSE, rejectHistory |-> FALSE,
 badFile |-> FALSE, badRoot |-> FALSE, badHistory |-> FALSE]

\* Normally one batch per host; hintStorm gives host 1 three advisory batches
\* for unchanged bytes, representing delayed/overlapping metadata hints.
\* Delivery remains optional, delayed, and asymmetric, never a change oracle.
DeliverHint(h) == /\ HintAvailable(h) /\ s.hint[h]<MaxHints(h) /\ s.phase[h] \notin Terminal
 /\ s'=[s EXCEPT !.hint[h]=@+1]
\* Complete accepted dependency-closed history is an input boundary here;
\* segment receipt/durability is NOT reimplemented as this atomic action.
ReceiveHistory(h) == /\ HasNewHistory /\ 1 \notin s.history[h]
 /\ s.phase[h] \notin Terminal
 /\ s'=[s EXCEPT !.history[h]=@ \cup {1}]
ChangeFile == /\ Scenario="fileRace" /\ s.version[1]=0
 /\ s.phase[1] \in Active /\ s'=[s EXCEPT !.version[1]=1]
ChangeRoot == /\ Scenario="rootRace" /\ s.root[1]=0
 /\ s.phase[1] \in Active /\ s'=[s EXCEPT !.root[1]=1]

\* Capture the complete shallow catalog and independent root/history scope.
\* The finite version stands for the existing exact-snapshot fence, not an
\* Apple integer that detects every possible undetectable physical ABA.
Capture(h) == /\ s.phase[h]="idle" /\ s.attempts[h]<2
 /\ s'=[s EXCEPT !.phase[h]="reading", !.attempts[h]=@+1,
   !.frame[h]=[version |-> s.version[h],
                root |-> s.root[h], history |-> s.history[h], hint |-> s.hint[h]],
   !.read[h]={}, !.bytes[h]=[p \in Paths |-> Absent], !.first[h]="none"]
Required(h) == IF Policy="hintOnly" THEN
                 IF s.frame[h].hint>0 /\ HintKind="path" THEN {HintPath} ELSE {}
              ELSE Paths
NextPath(h) == IF Policy="historyFirst"
                 /\ HistoryPath(Latest(s.frame[h].history)) \notin s.read[h]
              THEN HistoryPath(Latest(s.frame[h].history))
              ELSE IF Policy \in PoliciesWithHints /\ s.frame[h].hint>0
                 /\ HintKind="path" /\ HintPath \notin s.read[h]
              THEN HintPath ELSE IF "P" \notin s.read[h] THEN "P" ELSE "Q"
Read(h) == /\ s.phase[h]="reading" /\ s.read[h] # Required(h)
 /\ LET p == NextPath(h)
    IN /\ p \in Required(h) \ s.read[h]
       /\ s'=[s EXCEPT !.read[h]=@ \cup {p},
          !.bytes[h][p]=Files(s.version[h])[p],
          !.first[h]=IF @="none" THEN p ELSE @]
Prepare(h) == /\ s.phase[h]="reading" /\ s.read[h]=Required(h)
 /\ s'=[s EXCEPT !.phase[h]="prepared"]

\* Concrete finite version of represented-state checks: validated current
\* revision, exact path/body, and no second observed copy of its stamp.
\* inode/HintPath are deliberately not association proof.
Candidate(h) ==
 LET r == Latest(s.frame[h].history)
     p == HistoryPath(r)
     f == s.bytes[h][p]
     copies == {q \in s.read[h]: s.bytes[h][q].present
                 /\ s.bytes[h][q].stamp=r /\ s.bytes[h][q].body=0}
 IN p \in s.read[h] /\ f.present /\ f.body=0 /\ f.stamp \in {r,2}
    /\ Cardinality(copies)<=1
MissingDependency(h) == \E p \in s.read[h]:
 s.bytes[h][p].present /\ s.bytes[h][p].stamp=1 /\ 1 \notin s.frame[h].history
Decision(h) == IF Policy="quietTrust" /\ s.frame[h].hint=0 THEN "associated"
 ELSE IF Policy="hintAuthority" /\ s.frame[h].hint=1 THEN "associated"
 ELSE IF Candidate(h) THEN "associated"
 ELSE IF MissingDependency(h) THEN "waiting" ELSE "review"
FileFresh(h) == s.frame[h].version=s.version[h]
RootFresh(h) == s.frame[h].root=s.root[h]
HistoryFresh(h) == s.frame[h].history=s.history[h]
HintFresh(h) == Policy \notin (PoliciesWithHints \ {"priority"}) \/ s.frame[h].hint=s.hint[h]
Fence(h) == (FileFresh(h) \/ Policy="noFileFence")
 /\ (RootFresh(h) \/ Policy="noRootFence")
 /\ (HistoryFresh(h) \/ Policy="noHistoryFence") /\ HintFresh(h)
 /\ ~(Policy="sticky" /\ s.hint[h]>0)
Commit(h) == /\ s.phase[h]="prepared" /\ Fence(h)
 /\ LET d == Decision(h)
        t == IF d # "associated" THEN "none"
             ELSE IF Policy="eventEpoch" /\ s.frame[h].hint>0 THEN IF h=1 THEN "local1" ELSE "local2"
             ELSE Episode(s.frame[h].history)
    IN s'=[s EXCEPT !.phase[h]=d, !.result[h]=d, !.token[h]=t,
      !.badFile=@ \/ ~FileFresh(h), !.badRoot=@ \/ ~RootFresh(h),
      !.badHistory=@ \/ ~HistoryFresh(h)]
Reject(h) == /\ s.phase[h]="prepared" /\ ~Fence(h)
 /\ s'=[s EXCEPT !.phase[h]=IF s.attempts[h]<2 THEN "idle" ELSE "exhausted",
   !.rejectHint[h]=@ \/ ~HintFresh(h), !.rejectFile=@ \/ ~FileFresh(h),
   !.rejectRoot=@ \/ ~RootFresh(h), !.rejectHistory=@ \/ ~HistoryFresh(h)]
Work(h) == Capture(h) \/ Read(h) \/ Prepare(h) \/ Commit(h) \/ Reject(h)
Next == ChangeFile \/ ChangeRoot \/
 (\E h \in Hosts: DeliverHint(h) \/ ReceiveHistory(h) \/ Work(h))
Spec == Init /\ [][Next]_vars
\* Fair local CPU work only. No fairness of hint delivery, history arrival,
\* cloud disclosure, or user choice. Waiting/exhausted ends this bounded pass.
FairSpec == Spec /\ (\A h \in Hosts: WF_vars(Work(h)))

TypeOK == /\ s.version \in [Hosts -> 0..1] /\ s.root \in [Hosts -> 0..1]
 /\ s.history \in [Hosts -> SUBSET {0,1}] /\ s.hint \in [Hosts -> 0..3]
 /\ s.phase \in [Hosts -> ({"idle"} \cup Active \cup Terminal)]
 /\ s.attempts \in [Hosts -> 0..2] /\ s.read \in [Hosts -> SUBSET Paths]
 /\ s.frame \in [Hosts -> [version: 0..1, root: 0..1, history: SUBSET {0,1}, hint: 0..3]]
 /\ s.bytes \in [Hosts -> [Paths ->
       [present: BOOLEAN, inode: 0..2, body: 0..1, stamp: 0..2]]]
 /\ s.result \in [Hosts -> {"none","associated","review","waiting"}]
 /\ s.token \in [Hosts -> {"none","E0","E1","local1","local2"}]
 /\ s.first \in [Hosts -> (Paths \cup {"none"})]
 /\ s.rejectHint \in [Hosts -> BOOLEAN]
 /\ {s.rejectFile,s.rejectRoot,s.rejectHistory,s.badFile,s.badRoot,s.badHistory} \subseteq BOOLEAN
ExactFileFence == ~s.badFile
ExactRootFence == ~s.badRoot
ExactHistoryFence == ~s.badHistory
CompleteInspection == \A h \in Hosts: s.result[h] # "none" => s.read[h]=Paths
AssociationNeedsApplicableState == \A h \in Hosts: s.result[h]="associated" =>
 LET p == HistoryPath(Latest(s.frame[h].history))
 IN s.bytes[h][p].present /\ s.bytes[h][p].body=0
    /\ s.bytes[h][p].stamp \in {Latest(s.frame[h].history),2}
NoDuplicateAssociation == Scenario="duplicate" =>
 \A h \in Hosts: s.result[h] # "associated"
NoEventAuthoredEpisode == \A h \in Hosts: s.result[h]="associated" =>
 s.token[h]=Episode(s.frame[h].history)
SameHistorySameEpisode ==
 (s.result[1]="associated" /\ s.result[2]="associated"
  /\ s.frame[1].history=s.frame[2].history) => s.token[1]=s.token[2]
Safety == ExactFileFence /\ ExactRootFence /\ ExactHistoryFence /\ CompleteInspection
 /\ AssociationNeedsApplicableState /\ NoDuplicateAssociation
 /\ NoEventAuthoredEpisode /\ SameHistorySameEpisode
\* UX hypotheses are separate from safety; an all-review policy is not a win.
StableProjectionAccepted == Scenario \in {"safeSave","rename","asymmetric","roundTrip","gap","hintStorm"}
 => \A h \in Hosts: s.phase[h] \in Terminal => s.result[h]="associated"
OnePassForStableProjection == Scenario \in {"safeSave","rename","asymmetric","roundTrip","gap","hintStorm"}
 => \A h \in Hosts: s.attempts[h]<=1
AllPassesFinish == <>(\A h \in Hosts: s.phase[h] \in Terminal)
NeverHintFirst == ~(\E h \in Hosts: s.result[h]="associated" /\ s.first[h]="Q")
NeverAsymmetricAgreement == ~(s.result[1]="associated" /\ s.result[2]="associated"
 /\ s.frame[1].hint=1 /\ s.frame[2].hint=0 /\ s.token[1]=s.token[2])
NeverRecoveredFalseAlarm == ~(\E h \in Hosts: s.rejectHint[h]
 /\ s.attempts[h]=2 /\ s.result[h]="associated")
NeverReviewedReuse == ~(\E h \in Hosts: s.result[h]="review" /\ s.read[h]=Paths)
NeverGapFallback == ~(\E h \in Hosts: s.frame[h].hint=1
 /\ s.read[h]=Paths /\ s.result[h]="associated")
NeverWaitedForHistory == ~(\E h \in Hosts: s.result[h]="waiting")
NeverDependencyFirst == ~(\E h \in Hosts: s.result[h]="waiting" /\ s.first[h]="Q")
NeverReviewedStaleStamp == ~(\E h \in Hosts: s.result[h]="review" /\ 1 \in s.frame[h].history)
NeverAcceptedNewEpisode == ~(\E h \in Hosts: s.token[h]="E1")
NeverRetriedFile == ~(s.rejectFile /\ s.attempts[1]=2 /\ s.result[1]="review")
NeverRetriedRoot == ~(s.rejectRoot /\ s.attempts[1]=2 /\ s.result[1]="associated")
NeverRetriedHistory == ~(s.rejectHistory /\ \E h \in Hosts:
 s.attempts[h]=2 /\ s.token[h]="E1")
NeverExhaustedFromHints == ~(\E h \in Hosts: s.phase[h]="exhausted" /\ s.rejectHint[h]
 /\ ~s.rejectFile /\ ~s.rejectRoot /\ ~s.rejectHistory)
=============================================================================
