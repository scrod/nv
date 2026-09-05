--------------------------- MODULE CoAddSlotLab ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Policy, Scenario
ASSUME Policy \in {"path","releaseIDs","wholeHistory","occupant","episode","singleRelease","noFence","oneOccupant","localEvents","eventRelease"}
 /\ Scenario \in {"deleteReuse","renameReuse","duplicateRelease","unrelated","aba","occupiedRace","concurrentOccupants","renameHintOnly"}
\* Candidate vacancy-epoch allocator. Knowledge is causal, locally incomplete;
\* it is NOT a globally complete directory. No physical write/unlink is modeled.
\* O0 and O1 are distinct occupancy EVENTS of the same logical note O.
\* Releases d/r can independently vacate O0. A rename-out vacates the path
\* without deleting O; rename-back creates O1 rather than reusing O0.
\* In renameHintOnly, u is an uncommitted local rename hint (e.g. safe save
\* or rename away/back), NOT a logical release. Other scenarios use u for
\* unrelated history. localEvents substitutes observer-local event IDs.
Hosts == {1,2}
Events == {"O0","d","r","O1","s","X","t","u"}
Offered == CASE Scenario="duplicateRelease" -> {"O0","d","r"}
 [] Scenario="renameHintOnly" -> {"O0","u"}
 [] Scenario="unrelated" -> {"O0","d","u"}
 [] Scenario="aba" -> {"O0","d","O1","s"}
 [] Scenario="occupiedRace" -> {"O0","d","X"}
 [] Scenario="concurrentOccupants" -> {"O0","d","O1","X","s","t"}
 [] OTHER -> {"O0","d"}
Parents(e) == CASE e="O0" -> {} [] e \in {"d","r","u"} -> {"O0"}
 [] e \in {"O1","X"} -> {"d"} [] e="t" -> {"X"} [] OTHER -> {"O1"}
Episodes(k) == IF k \cap {"O1","X"} # {} THEN k \cap {"O1","X"}
              ELSE IF "O0" \in k THEN {"O0"} ELSE {"genesis"}
Released(k,o) == CASE o="O0" -> k \cap {"d","r"} # {}
 [] o="O1" -> "s" \in k [] o="X" -> "t" \in k [] OTHER -> TRUE
Vacancy(k) ==
 [empty |-> IF Policy="eventRelease" /\ "u" \in k THEN TRUE
            ELSE IF Policy="oneOccupant" /\ "O1" \in k THEN "s" \in k
            ELSE \A o \in Episodes(k): Released(k,o), ep |-> Episodes(k)]
Releases(k) == IF k \cap {"O1","X"} # {} THEN k \cap {"s","t"} ELSE k \cap {"d","r"}
Token(k,h) ==
 CASE Policy="path" -> <<"P">>
 [] Policy="wholeHistory" -> <<"P",k>>
 [] Policy="localEvents" -> <<"P",h,Episodes(k)>>
 [] Policy="releaseIDs" -> <<"P",Releases(k)>>
 [] Policy="occupant" -> <<"P",{IF o \in {"O0","O1"} THEN "O" ELSE o: o \in Episodes(k)}>>
 [] Policy="singleRelease" /\ Cardinality(Releases(k))>1 -> <<"decline">>
 [] OTHER -> <<"P",Vacancy(k).ep>>
VARIABLE s
vars == <<s>>
Init == s = [emitted |-> {}, known |-> [h \in Hosts |-> {}],
 phase |-> [h \in Hosts |-> 0], captured |-> [h \in Hosts |-> {}],
 token |-> [h \in Hosts |-> <<"none">>], stale |-> FALSE, rejected |-> FALSE]
Emit(e) == /\ e \in Offered \ s.emitted /\ Parents(e) \subseteq s.emitted
 /\ s'=[s EXCEPT !.emitted=@ \cup {e}]
Receive(h,e) == /\ e \in s.emitted \ s.known[h] /\ Parents(e) \subseteq s.known[h]
 /\ s'=[s EXCEPT !.known[h]=@ \cup {e}]
Capture(h) == /\ s.phase[h]=0 /\ Vacancy(s.known[h]).empty
 /\ s'=[s EXCEPT !.captured[h]=s.known[h], !.token[h]=Token(s.known[h],h), !.phase[h]=1]
Admit(h) == /\ s.phase[h]=1 /\ s.token[h] # <<"decline">>
 /\ (Vacancy(s.captured[h])=Vacancy(s.known[h]) \/ Policy="noFence")
 /\ s'=[s EXCEPT !.phase[h]=2,
       !.stale=@ \/ Vacancy(s.captured[h]) # Vacancy(s.known[h])]
Reject(h) == /\ s.phase[h]=1
 /\ (Vacancy(s.captured[h]) # Vacancy(s.known[h]) \/ s.token[h] = <<"decline">>)
 /\ s'=[s EXCEPT !.phase[h]=3, !.rejected=TRUE]
Next == (\E e \in Events: Emit(e))
 \/ (\E h \in Hosts: Capture(h) \/ Admit(h) \/ Reject(h)
       \/ (\E e \in Events: Receive(h,e)))
Spec == Init /\ [][Next]_vars
TypeOK == /\ s.emitted \subseteq Events /\ s.phase \in [Hosts -> 0..3]
 /\ s.known \in [Hosts -> SUBSET Events] /\ s.captured \in [Hosts -> SUBSET Events]
 /\ s.stale \in BOOLEAN /\ s.rejected \in BOOLEAN
Both == s.phase[1]=2 /\ s.phase[2]=2
SameEpisodeSharesToken == Both /\ Vacancy(s.captured[1]).ep=Vacancy(s.captured[2]).ep
 => s.token[1]=s.token[2]
DifferentEpisodesStayDistinct == Both /\ Vacancy(s.captured[1]).ep # Vacancy(s.captured[2]).ep
 => s.token[1] # s.token[2]
FreshLocalEvidence == ~s.stale
NoKnownOccupantForgotten == \A h \in Hosts: s.phase[h]=2 =>
 /\ ("X" \in s.captured[h] => "t" \in s.captured[h])
 /\ ("O1" \in s.captured[h] => "s" \in s.captured[h])
 /\ ("O0" \in s.captured[h] /\ s.captured[h] \cap {"O1","X"} = {}
     => s.captured[h] \cap {"d","r"} # {})
NoUnnecessaryRefusal == \A h \in Hosts: s.phase[h]=3 =>
 Vacancy(s.captured[h]) # Vacancy(s.known[h])
Safety == SameEpisodeSharesToken /\ DifferentEpisodesStayDistinct /\ FreshLocalEvidence /\ NoKnownOccupantForgotten
NeverSharedAfterDifferentReleases == ~(Both /\ s.captured[1]={"O0","d"}
 /\ s.captured[2]={"O0","r"} /\ s.token[1]=s.token[2])
NeverSeparatedABA == ~(Both /\ Vacancy(s.captured[1]).ep={"O0"}
 /\ Vacancy(s.captured[2]).ep={"O1"} /\ s.token[1] # s.token[2])
NeverIgnoredUnrelatedHistory == ~(Both /\ s.captured[1]={"O0","d"}
 /\ s.captured[2]={"O0","d","u"} /\ s.token[1]=s.token[2])
NeverRejectedNewOccupant == ~(s.rejected /\ \E h \in Hosts: s.phase[h]=3
 /\ Vacancy(s.captured[h]).empty /\ ~Vacancy(s.known[h]).empty)
NeverSharedReuse == ~(Both /\ s.captured[1]={"O0","d"}
 /\ s.captured[2]={"O0","d"} /\ s.token[1]=s.token[2])
NeverSharedAfterAllOccupantsReleased == ~(Both /\ Vacancy(s.captured[1]).ep={"O1","X"}
 /\ Vacancy(s.captured[2]).ep={"O1","X"} /\ s.token[1]=s.token[2])
NeverDeferredRenameHint == ~(\E h \in Hosts: s.known[h]={"O0","u"}
 /\ s.phase[h]=0 /\ ~Vacancy(s.known[h]).empty)
=============================================================================
