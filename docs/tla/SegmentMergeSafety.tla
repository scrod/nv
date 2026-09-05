------------------------- MODULE SegmentMergeSafety -------------------------
EXTENDS Naturals, FiniteSets
\* Two observers, concrete two-field values, actual finite ancestry, delayed
\* third head, one explicit edit of a derived result and its durable delivery.
\* Fields stand for independently mergeable values, NOT the LF text algorithm.
\* No clocks/order oracle or symmetric branch-choice assumption is used.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","lastWriter","arbitraryBase","pairwise",
                   "stalePublish","dropParent","automaticWrite","skipParents","stallDelivery",
                   "consumeConflicts","knowledgeSupersedes"}
       /\ Scenario \in {"merge","third","dominated","ambiguous","equal","conflict"}
Hosts == {1,2}
Nodes == {"g","x","y","l","r","t","edit"}
Seed == IF Scenario = "ambiguous" THEN {"g","x","y"} ELSE {"g"}
Offered == IF Scenario \in {"third","dominated"} THEN {"l","r","t"} ELSE {"l","r"}
VARIABLE s
vars == <<s>>
Parents(n) == CASE n = "g" -> {}
 [] n = "edit" -> s.editKnowledge
 [] n = "l" \/ n = "r" -> IF Scenario = "ambiguous" THEN {"x","y"} ELSE {"g"}
 [] n = "t" /\ Scenario = "dominated" -> {"l"}
 [] OTHER -> {"g"}
\* The fixed source DAG is at most two edges deep; an edit adds one edge.
\* Compute that actual closure directly instead of recursively re-expanding
\* it inside every TLC ENABLED/fairness check. No paths/behaviors are pruned.
SourceAnc(n) == CASE n = "g" -> {}
 [] n \in {"l","r"} /\ Scenario = "ambiguous" -> {"g","x","y"}
 [] n = "t" /\ Scenario = "dominated" -> {"g","l"}
 [] OTHER -> {"g"}
Anc(n) == IF n = "edit" THEN s.editKnowledge \cup UNION {SourceAnc(p): p \in s.editKnowledge}
          ELSE SourceAnc(n)
NoteAnc(n) == IF n = "edit" /\ Policy # "knowledgeSupersedes"
             THEN s.editParents \cup UNION {SourceAnc(p): p \in s.editParents}
             ELSE Anc(n)
Heads(ns) == {n \in ns: ~\E m \in ns: n \in NoteAnc(m)}
Bases(hs) == LET common == {n \in Nodes: \A h \in hs: n \in NoteAnc(h)}
             IN {n \in common: ~\E m \in common: n \in NoteAnc(m)}
\* Fixed presentation ordering, independent of receipt and causal awareness.
Order == <<"l","r","t","edit","x","y","g">>
Selected(hs) == Order[CHOOSE i \in 1..7:
                      Order[i] \in hs /\ \A j \in 1..(i-1): Order[j] \notin hs]
Value(n) == CASE n = "g" -> <<0,0>>
 [] n = "x" \/ n = "l" -> <<1,0>>
 [] n = "y" -> <<0,1>>
 [] n = "r" -> IF Scenario = "equal" THEN <<1,0>>
               ELSE IF Scenario = "conflict" THEN <<2,0>> ELSE <<0,1>>
 [] n = "t" -> <<2,0>>
 [] OTHER -> s.editValue
Scalar(b,l,r) == IF l = r THEN l ELSE IF l = b THEN r
                ELSE IF r = b THEN l ELSE 9
Combine(base,l,r) == <<Scalar(base[1],l[1],r[1]),Scalar(base[2],l[2],r[2])>>
NoView == [kind |-> "none", body |-> <<0,0>>, heads |-> {}, bases |-> {}]
Compute(ns,last) ==
 LET hs0 == Heads(ns)
     hs == IF Policy = "pairwise" /\ Cardinality(hs0) > 2 THEN {"l","r"} ELSE hs0
     bs == Bases(hs)
     vals == {Value(h): h \in hs}
 IN IF Cardinality(vals) = 1 THEN
       [kind |-> "current", body |-> CHOOSE v \in vals: TRUE, heads |-> hs, bases |-> bs]
    ELSE IF Cardinality(hs) = 2 /\ (Cardinality(bs) = 1 \/ Policy = "arbitraryBase") THEN
       LET b == IF bs = {} THEN "g" ELSE CHOOSE n \in bs: TRUE
           l == CHOOSE n \in hs: TRUE
           r == CHOOSE n \in hs \ {l}: TRUE
           v == IF Policy = "lastWriter" THEN Value(last) ELSE Combine(Value(b),Value(l),Value(r))
       IN [kind |-> IF 9 \in {v[1],v[2]} THEN "conflict" ELSE "merged",
           body |-> IF 9 \in {v[1],v[2]} THEN Value(Selected(hs)) ELSE v,
           heads |-> hs, bases |-> bs]
    ELSE [kind |-> "conflict", body |-> Value(Selected(hs)), heads |-> hs, bases |-> bs]
Init == s = [accepted |-> [h \in Hosts |-> Seed], last |-> [h \in Hosts |-> "g"],
 phase |-> [h \in Hosts |-> "idle"], captured |-> [h \in Hosts |-> {}],
 prepared |-> [h \in Hosts |-> NoView], view |-> [h \in Hosts |-> NoView],
 frame |-> [h \in Hosts |-> {}], root |-> 1, capturedRoot |-> [h \in Hosts |-> 1],
 stalePublished |-> FALSE, automaticOps |-> {},
 editCreated |-> FALSE, editParents |-> {}, editKnowledge |-> {}, editValue |-> <<0,0>>,
 editOrigin |-> {}, editStage |-> 0, incomingEdit |-> FALSE]
Receive(h,n) ==
 /\ n \in Offered \ s.accepted[h] /\ Parents(n) \subseteq s.accepted[h]
 /\ Policy # "stallDelivery" \/ n # "r"
 /\ s' = [s EXCEPT !.accepted[h] = @ \cup {n}, !.last[h] = n]
Prepare(h) ==
 /\ s.phase[h] = "idle" /\ s.frame[h] # s.accepted[h]
 /\ s' = [s EXCEPT !.phase[h] = "prepared", !.captured[h] = s.accepted[h],
       !.prepared[h] = Compute(s.accepted[h],s.last[h]), !.capturedRoot[h] = s.root]
ChangeRoot == /\ s.root = 1 /\ s.phase[1] = "prepared"
 /\ s' = [s EXCEPT !.root = 2]
Publish(h) ==
 /\ s.phase[h] = "prepared"
 /\ Policy = "stalePublish" \/
       (s.captured[h] = s.accepted[h] /\ s.capturedRoot[h] = s.root)
 /\ s' = [s EXCEPT !.view[h] = s.prepared[h], !.frame[h] = s.captured[h],
       !.phase[h] = "idle",
       !.stalePublished = @ \/ s.captured[h] # s.accepted[h] \/ s.capturedRoot[h] # s.root,
       !.automaticOps = IF Policy = "automaticWrite" /\ s.prepared[h].kind = "merged"
                         THEN @ \cup {h} ELSE @]
Reject(h) ==
 /\ s.phase[h] = "prepared"
 /\ s.captured[h] # s.accepted[h] \/ s.capturedRoot[h] # s.root
 /\ s' = [s EXCEPT !.phase[h] = "idle"]
EditDerived ==
 /\ ~s.editCreated /\ s.phase[1] = "idle" /\ s.frame[1] = s.accepted[1]
 /\ s.view[1].heads = {"l","r"}
 /\ s.view[1].kind \in {"merged","current"} \/ Scenario = "conflict"
 /\ s' = [s EXCEPT !.editCreated = TRUE, !.editStage = 1,
       !.editParents = IF Policy = "dropParent" \/
                          (Scenario = "conflict" /\ Policy # "consumeConflicts")
                       THEN {"l"} ELSE s.view[1].heads,
       !.editKnowledge = IF Policy = "dropParent" THEN {"l"} ELSE s.view[1].heads,
       !.editOrigin = IF Scenario = "conflict" THEN {"l"} ELSE s.view[1].heads,
       !.editValue = <<3,s.view[1].body[2]>>, !.accepted[1] = @ \cup {"edit"},
       !.last[1] = "edit"]
PersistEdit == /\ s.editStage \in 1..3
 /\ s' = [s EXCEPT !.editStage = @ + 1]
ReceiveEdit == /\ s.editStage = 4 /\ ~s.incomingEdit
 /\ s' = [s EXCEPT !.incomingEdit = TRUE]
ApplyEdit ==
 /\ s.incomingEdit /\ "edit" \notin s.accepted[2]
 /\ Policy = "skipParents" \/ s.editKnowledge \subseteq s.accepted[2]
 /\ s' = [s EXCEPT !.accepted[2] = @ \cup {"edit"}, !.last[2] = "edit"]
Progress == (\E h \in Hosts: Prepare(h) \/ Publish(h) \/ Reject(h)
                      \/ (\E n \in Offered: Receive(h,n)))
 \/ PersistEdit \/ ReceiveEdit \/ ApplyEdit
Next == Progress \/ ChangeRoot \/ EditDerived
Spec == Init /\ [][Next]_vars
\* One weak-fairness clause suffices ONLY because progress strictly decreases
\* Rank and the two environment events are one-shot. This is checked below,
\* not an assumption of a fair per-item scheduler under unbounded editing.
FairSpec == Spec /\ WF_vars(Progress)
ViewWork(h) == IF s.phase[h] = "prepared"
 THEN IF s.captured[h] = s.accepted[h] /\ s.capturedRoot[h] = s.root THEN 1 ELSE 3
 ELSE IF s.frame[h] = s.accepted[h] THEN 0 ELSE 2
Missing(h) == Cardinality(Offered \ s.accepted[h])
             + IF s.editCreated /\ "edit" \notin s.accepted[h] THEN 1 ELSE 0
Rank == 4 * (Missing(1) + Missing(2)) + ViewWork(1) + ViewWork(2)
        + IF s.editCreated THEN 4-s.editStage + IF s.incomingEdit THEN 0 ELSE 1 ELSE 0
ProgressDecreasesRank == [][Progress => Rank' < Rank]_vars
EnvironmentBudget == (2-s.root) + IF s.editCreated THEN 0 ELSE 1
EnvironmentDecreasesBudget == [][(ChangeRoot \/ EditDerived)
                                => EnvironmentBudget' < EnvironmentBudget]_vars
\* Together with the two action properties and WF(Progress), these checked
\* obligations give a finite-rank convergence argument for the FULL scenario.
\* This is not a TLAPS certificate. Direct LTL results are recorded separately
\* in impl-proposal-5/Verification.md.
ProgressAvailable == Rank > 0 => ENABLED (Progress /\ s' # s)
TerminalAgreement == Rank = 0 =>
 s.frame[1] = s.accepted[1] /\ s.frame[2] = s.accepted[2] /\ s.view[1] = s.view[2]
RankObligations == Rank \in Nat /\ EnvironmentBudget \in Nat /\ ProgressAvailable /\ TerminalAgreement
ViewType == [kind: {"none","current","merged","conflict"}, body: (0..9) \X (0..9),
             heads: SUBSET Nodes, bases: SUBSET Nodes]
TypeOK ==
 /\ \A f \in {"accepted","captured","frame"}: s[f] \in [Hosts -> SUBSET Nodes]
 /\ s.last \in [Hosts -> Nodes] /\ s.phase \in [Hosts -> {"idle","prepared"}]
 /\ s.prepared \in [Hosts -> ViewType] /\ s.view \in [Hosts -> ViewType]
 /\ s.root \in 1..2 /\ s.capturedRoot \in [Hosts -> 1..2]
 /\ s.automaticOps \subseteq Hosts /\ s.editParents \subseteq Nodes
 /\ s.editKnowledge \subseteq Nodes
 /\ s.editOrigin \subseteq Nodes /\ s.editValue \in (0..3) \X (0..1)
 /\ s.editStage \in 0..4
 /\ \A f \in {"stalePublished","editCreated","incomingEdit"}: s[f] \in BOOLEAN
NoStalePublication == ~s.stalePublished
NoAutomaticOperations == s.automaticOps = {}
\* Independently verify the compact closure table against the actual edges.
AncestryMatchesEdges == \A n \in Nodes:
 Anc(n) = Parents(n) \cup UNION {Anc(p): p \in Parents(n)}
AllAcceptedParentsPresent == \A h \in Hosts: \A n \in s.accepted[h]: Parents(n) \subseteq s.accepted[h]
UniqueBaseRequired == \A h \in Hosts: s.view[h].kind = "merged" => Cardinality(s.view[h].bases) = 1
ThreeHeadsNotFolded == \A h \in Hosts:
 Scenario = "third" /\ {"l","r","t"} \subseteq s.frame[h] /\ "edit" \notin s.frame[h]
 => s.view[h].kind = "conflict" /\ s.view[h].heads = {"l","r","t"}
IndependentFieldsSurvive == \A h \in Hosts:
 Scenario = "merge" /\ s.frame[h] = {"g","l","r"}
 => s.view[h].kind = "merged" /\ s.view[h].body = <<1,1>>
DominatedHeadHandled == \A h \in Hosts:
 Scenario = "dominated" /\ s.frame[h] = {"g","l","r","t"}
 => s.view[h].body = <<2,1>> /\ s.view[h].heads = {"r","t"}
UserEditRetainsBothInputs == s.editCreated /\ Scenario # "conflict" =>
 /\ {"l","r"} \subseteq s.editParents /\ s.editOrigin = {"l","r"}
 /\ s.editValue = <<3,IF Scenario = "equal" THEN 0 ELSE 1>>
OrdinaryEditTargetsCurrentOnly == s.editCreated /\ Scenario = "conflict" =>
 /\ s.editParents = {"l"} /\ s.editOrigin = {"l"}
 /\ s.editKnowledge = {"l","r"} /\ s.editValue = <<3,0>>
UnchosenHeadSurvives == \A h \in Hosts:
 Scenario = "conflict" /\ "edit" \in s.frame[h]
 => s.view[h].heads = {"edit","r"} /\ s.view[h].kind = "conflict"
EqualAcceptedViewsAgree == s.frame[1] # {} /\ s.frame[1] = s.frame[2] => s.view[1] = s.view[2]
Safety == NoStalePublication /\ NoAutomaticOperations /\ AllAcceptedParentsPresent
 /\ UniqueBaseRequired /\ ThreeHeadsNotFolded /\ IndependentFieldsSurvive
 /\ DominatedHeadHandled /\ UserEditRetainsBothInputs /\ EqualAcceptedViewsAgree /\ AncestryMatchesEdges
 /\ OrdinaryEditTargetsCurrentOnly /\ UnchosenHeadSurvives
EventualAgreement == <>[] (s.frame[1] = s.accepted[1] /\ s.frame[2] = s.accepted[2]
  /\ s.view[1] = s.view[2])
NeverMergedBothOrders == ~(s.frame[1] = {"g","l","r"} /\ s.frame[2] = s.frame[1]
 /\ s.last[1] # s.last[2] /\ s.view[1].body = <<1,1>> /\ s.view[2].body = <<1,1>>)
NeverDelayedThirdHead == ~(s.view[1].kind = "merged" /\ "t" \in s.accepted[1]
 /\ "t" \notin s.frame[1])
NeverReceivedEditBeforeParents == ~(s.incomingEdit /\ ~({"l","r"} \subseteq s.accepted[2]))
NeverAppliedDerivedEditOnPeer == ~(s.frame[2] # {} /\ "edit" \in s.frame[2]
 /\ Scenario = "merge" /\ s.view[2].body = <<3,1>>)
NeverEditedCurrentWithKnownConflict == ~(Scenario = "conflict"
 /\ "edit" \in s.frame[2] /\ s.view[2].heads = {"edit","r"}
 /\ s.editKnowledge = {"l","r"} /\ s.editParents = {"l"})
=============================================================================
