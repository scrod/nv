-------------------------- MODULE CoAddIntentLab --------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"fresh","path","slot","exact","consent","noFence","oneValue"}
 /\ Scenario \in {"sameFile","sharedEdited","hiddenCopy","differentPaths",
   "differentEpochs","forceNew","ordinaryCreates","consentedCopies","caseAmbiguous","changingFile"}
\* Experimental admission rules, not adopted policy. Only Observation's
\* fields reach Birth; physical origin/desired intent is assertion-only.
\* Same-file and hidden-copy observations are deliberately identical.
\* A complete accepted local install is abstract; remote receipt is independent.
Hosts == {1,2}
Observation(h) == [path |-> IF Scenario="differentPaths" /\ h=2 THEN "Q" ELSE "P",
 epoch |-> IF Scenario="differentEpochs" /\ h=2 THEN 1 ELSE 0,
 value |-> IF Scenario="sharedEdited" /\ h=2 THEN "other" ELSE "text",
 mode |-> CASE Scenario="forceNew" -> "new"
               [] Scenario="ordinaryCreates" -> "create"
               [] Scenario="consentedCopies" -> "match"
               [] OTHER -> "discover",
 clear |-> Scenario # "caseAmbiguous", gen |-> 0]
Observations == {Observation(h): h \in Hosts}
 \cup {[Observation(2) EXCEPT !.value="edited", !.gen=1]}
Birth(o,h) ==
 IF Policy="path" THEN <<"path",o.path>>
 ELSE IF Policy="fresh" \/ o.mode \in {"new","create"} \/ ~o.clear
      \/ (Policy="consent" /\ o.mode # "match") THEN <<"fresh",h>>
 ELSE IF Policy="slot" THEN <<"slot",o.path,o.epoch>>
 ELSE <<"exact",o.path,o.epoch,o.value>>
VARIABLE s
vars == <<s>>
Init == s = [obs |-> [h \in Hosts |-> Observation(h)], phase |-> [h \in Hosts |-> 0],
 captured |-> [h \in Hosts |-> Observation(h)], birth |-> [h \in Hosts |-> <<"none">>],
 durable |-> {}, provider |-> {}, known |-> [h \in Hosts |-> {}],
 frame |-> [h \in Hosts |-> {}], members |-> [h \in Hosts |-> {}],
 staleAdmitted |-> FALSE, changed |-> FALSE, down |-> FALSE, crashed |-> FALSE,
 recovered |-> FALSE, recoveredOwn |-> FALSE, rejected |-> FALSE]
Up(h) == h # 1 \/ ~s.down
Capture(h) == /\ Up(h) /\ s.phase[h]=0
 /\ s'=[s EXCEPT !.captured[h]=s.obs[h], !.phase[h]=1]
ChangeFile == /\ Scenario="changingFile" /\ ~s.changed
 /\ s'=[s EXCEPT !.changed=TRUE, !.obs[2].value="edited", !.obs[2].gen=1]
Admit(h) == /\ Up(h) /\ s.phase[h]=1
 /\ (s.captured[h]=s.obs[h] \/ Policy="noFence")
 /\ s'=[s EXCEPT !.birth[h]=Birth(s.captured[h],h), !.phase[h]=2,
       !.staleAdmitted=@ \/ s.captured[h] # s.obs[h]]
Reject(h) == /\ Up(h) /\ s.phase[h]=1 /\ s.captured[h] # s.obs[h]
 /\ s'=[s EXCEPT !.phase[h]=0, !.rejected=TRUE]
Install(h) == /\ Up(h) /\ s.phase[h]=2
 /\ s'=[s EXCEPT !.durable=@ \cup {h}, !.known[h]=@ \cup {h}, !.phase[h]=3]
Publish(h) == /\ Up(h) /\ h \in s.durable \ s.provider
 /\ s'=[s EXCEPT !.provider=@ \cup {h}]
Receive(h,r) == /\ Up(h) /\ r \in s.provider \ s.known[h]
 /\ s'=[s EXCEPT !.known[h]=@ \cup {r}]
Evaluate(h) == /\ Up(h) /\ s.frame[h] # s.known[h]
 /\ s'=[s EXCEPT !.frame[h]=s.known[h],
       !.members[h]=IF Policy="oneValue" /\ s.known[h]=Hosts /\ s.birth[1]=s.birth[2]
                   THEN {1} ELSE s.known[h]]
Crash == /\ ~s.down /\ ~s.crashed
 /\ s'=[s EXCEPT !.down=TRUE, !.crashed=TRUE, !.known[1]={}, !.frame[1]={}, !.members[1]={}]
Recover == /\ s.down
 /\ s'=[s EXCEPT !.down=FALSE, !.recovered=TRUE,
       !.recoveredOwn=1 \in s.durable,
       !.known[1]=IF 1 \in s.durable THEN {1} ELSE {},
       !.phase[1]=IF 1 \in s.durable THEN 3 ELSE 0]
Next == ChangeFile \/ Crash \/ Recover
 \/ (\E h \in Hosts: Capture(h) \/ Admit(h) \/ Reject(h) \/ Install(h)
    \/ Publish(h) \/ Evaluate(h) \/ (\E r \in Hosts: Receive(h,r)))
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Recover)
 /\ \A h \in Hosts: WF_vars(Publish(h)) /\ WF_vars(Evaluate(h))
       /\ \A r \in Hosts: WF_vars(Receive(h,r))
TypeOK == /\ s.phase \in [Hosts -> 0..3] /\ s.durable \subseteq Hosts
 /\ s.obs \in [Hosts -> Observations] /\ s.captured \in [Hosts -> Observations]
 /\ s.birth \in [Hosts -> ({<<"none">>} \cup {Birth(o,h): o \in Observations, h \in Hosts})]
 /\ s.provider \subseteq Hosts
 /\ \A f \in {"known","frame","members"}: s[f] \in [Hosts -> SUBSET Hosts]
 /\ s.changed \in BOOLEAN /\ s.staleAdmitted \in BOOLEAN
 /\ s.down \in BOOLEAN /\ s.crashed \in BOOLEAN /\ s.recovered \in BOOLEAN
 /\ s.recoveredOwn \in BOOLEAN /\ s.rejected \in BOOLEAN
BothInstalled == s.durable=Hosts
NoFalseJoin == BothInstalled /\ Scenario \in {"hiddenCopy","differentPaths","differentEpochs",
 "forceNew","ordinaryCreates","caseAmbiguous"} => s.birth[1] # s.birth[2]
CommonFileUnified == BothInstalled /\ Scenario \in {"sameFile","sharedEdited","consentedCopies"}
 => s.birth[1]=s.birth[2]
FreshIntentRespected == BothInstalled /\ Scenario \in {"forceNew","ordinaryCreates"}
 => s.birth[1] # s.birth[2]
AllRevisionInputsRetained == \A h \in Hosts: s.members[h]=s.frame[h]
NoStaleAdmission == ~s.staleAdmitted
Safety == NoFalseJoin /\ FreshIntentRespected /\ AllRevisionInputsRetained /\ NoStaleAdmission
DurableImportsReachBoth == \A r \in Hosts:
 r \in s.durable ~> (\A h \in Hosts: r \in s.members[h])
NeverUnified == ~(BothInstalled /\ s.birth[1]=s.birth[2] /\ s.frame[1]=Hosts /\ s.frame[2]=Hosts)
NeverSeparated == ~(BothInstalled /\ s.birth[1] # s.birth[2] /\ s.frame[1]=Hosts /\ s.frame[2]=Hosts)
NeverRecoveredImports == ~(s.recoveredOwn /\ ~s.down /\ BothInstalled
 /\ s.frame[1]=Hosts /\ s.frame[2]=Hosts /\ s.members[1]=Hosts /\ s.members[2]=Hosts)
NeverRetriedChangedFile == ~(s.rejected /\ 2 \in s.durable /\ s.captured[2].gen=1)
=============================================================================
