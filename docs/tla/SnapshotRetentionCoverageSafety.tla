-------------------- MODULE SnapshotRetentionCoverageSafety --------------------
EXTENDS Naturals, FiniteSets

\* GeneralSnapshotCapture freezes the owned root frontier and logical cut.
\* CheckedRetentionParents checks exact supported accepted roots, then rechecks
\* them in the atomic HistoryDatabase.accept transaction. Callback delivery is
\* separate from that transaction. Restart discards preparation, retains bytes,
\* membership/edges/frontier, and can retry a missing callback idempotently.
\* Root/page byte closure is collapsed into one immutable snapshot identity here;
\* ReceiveSnapshotAssemblySafety covers page membership and manifest parsing.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "unverified", "clearAll", "omitDeps", "earlyAck", "loseBytes", "skipRecheck"}
 /\ Scenario \in {"sameCut", "differentCut", "unsupported", "damage"}
Stores == {"A", "B"}
Roots == {"initial", "a", "b", "join"}
NewRoots == Roots \ {"initial"}
Author(r) == IF r="b" \/ (r="join" /\ Scenario="unsupported") THEN "B" ELSE "A"
\* The unsupported scenario supplies a future producer's root and a supported
\* descendant; the older receiver retains both while that parent remains blocked.
Supported(m,r) == ~(Scenario="unsupported" /\ r="b" /\ m="A")
VARIABLE s
vars == <<s>>
Maxima(a, d) == a \ UNION {d[r] : r \in a}
RECURSIVE Closure(_, _, _)
Closure(tips, d, budget) == IF budget=0 THEN tips
                          ELSE Closure(tips \cup UNION {d[r] : r \in tips}, d, budget-1)
ValidParents(m, r) == s.parents[r] \subseteq s.accepted[m]
 /\ \A p \in s.parents[r]: Supported(m,p) /\ p \notin s.damaged[m]
Init == s = [captured |-> {"initial"}, parents |-> [r \in Roots |-> {}],
 cuts |-> [r \in Roots |-> {}], logical |-> [m \in Stores |-> {}],
 retained |-> [m \in Stores |-> {"initial"}], accepted |-> [m \in Stores |-> {"initial"}],
 deps |-> [m \in Stores |-> [r \in Roots |-> {}]], frontier |-> [m \in Stores |-> {"initial"}],
 task |-> [m \in Stores |-> "none"], proof |-> [m \in Stores |-> {}],
 completion |-> [m \in Stores |-> "none"], acknowledged |-> [m \in Stores |-> {}],
 crashed |-> {}, failures |-> {}, damaged |-> [m \in Stores |-> {}],
 observations |-> {}]

Edit == /\ Scenario="differentCut" /\ s.logical["B"]={}
 /\ s'=[s EXCEPT !.logical["B"]={"edit"}]
DeliverEdit == /\ "edit" \in s.logical["B"] /\ s.logical["A"]={}
 /\ s'=[s EXCEPT !.logical["A"]={"edit"}]
Capture(r) == /\ r \in NewRoots \ s.captured
 /\ LET m == Author(r) IN
    /\ r="a" \/ r="b" \/ (r="join" /\ {"a", "b"} \subseteq s.accepted[m])
    /\ s'=[s EXCEPT !.captured=@ \cup {r}, !.parents[r]=s.frontier[m], !.cuts[r]=s.logical[m]]
Deliver(m, r) == /\ r \in s.captured \ s.retained[m]
 /\ s'=[s EXCEPT !.retained[m]=@ \cup {r}]
Verify(m, r) == /\ s.task[m]="none" /\ s.completion[m]="none"
 /\ r \in s.retained[m] \ s.accepted[m] /\ r \in NewRoots
 /\ Supported(m,r) /\ (Policy="unverified" \/ ValidParents(m,r))
 /\ s'=[s EXCEPT !.task[m]=r, !.proof[m]=s.parents[r]]
Accept(m) == /\ s.task[m]#"none"
 /\ LET r == s.task[m] IN
    /\ Supported(m,r) /\ (Policy \in {"unverified", "skipRecheck"} \/ ValidParents(m,r))
    /\ s.proof[m]=s.parents[r]
    /\ s'=[s EXCEPT !.accepted[m]=@ \cup {r},
      !.deps[m][r]=IF Policy="omitDeps" THEN {} ELSE s.parents[r],
      !.frontier[m]=IF Policy="clearAll" THEN {r} ELSE (@ \cup {r}) \ s.parents[r],
      !.task[m]="none", !.proof[m]={}, !.completion[m]=r,
      !.observations=@ \cup
        (IF \E p \in s.accepted[m] \ s.parents[r]: p \in {"a","b"}
         THEN {"independent"} ELSE {}) \cup
        (IF s.parents[r] \cap {"a","b"} # {} /\
             \E p \in s.parents[r]: s.cuts[p] # s.cuts[r] THEN {"differentCut"} ELSE {})]
FailBeforeCommit(m) == /\ s.task[m]#"none" /\ m \notin s.failures
 /\ s'=[s EXCEPT !.task[m]="none", !.proof[m]={}, !.failures=@ \cup {m}]
Complete(m) == /\ s.completion[m]#"none"
 /\ s'=[s EXCEPT !.acknowledged[m]=@ \cup {s.completion[m]}, !.completion[m]="none"]
EarlyComplete(m) == /\ Policy="earlyAck" /\ s.task[m]#"none"
 /\ s.task[m] \notin s.acknowledged[m]
 /\ s'=[s EXCEPT !.acknowledged[m]=@ \cup {s.task[m]}]
Retry(m,r) == /\ r \in s.accepted[m] \ s.acknowledged[m] /\ r \in NewRoots
 /\ s.completion[m]="none" /\ s.task[m]="none"
 /\ s'=[s EXCEPT !.completion[m]=r]
Damage(m) == /\ Scenario="damage" /\ s.task[m]#"none" /\ s.damaged[m]={}
 /\ \E p \in s.parents[s.task[m]]:
       s'=[s EXCEPT !.damaged[m]={p}, !.observations=@ \cup {"damageBetweenChecks"}]
Crash(m) == /\ m \notin s.crashed
 /\ s'=[s EXCEPT !.task[m]="none", !.proof[m]={}, !.completion[m]="none",
      !.crashed=@ \cup {m},
      !.retained[m]=IF Policy="loseBytes" THEN {"initial"} ELSE @,
      !.observations=@ \cup (IF s.completion[m]#"none" THEN {"lostCallback"} ELSE {})]
Next == Edit \/ DeliverEdit \/ (\E r \in NewRoots: Capture(r))
 \/ (\E m \in Stores, r \in Roots: Deliver(m,r) \/ Verify(m,r) \/ Retry(m,r))
 \/ (\E m \in Stores: Accept(m) \/ FailBeforeCommit(m) \/ Complete(m) \/ EarlyComplete(m) \/ Damage(m) \/ Crash(m))
Spec == Init /\ [][Next]_vars

TypeOK == /\ s.captured \subseteq Roots /\ s.parents \in [Roots -> SUBSET Roots]
 /\ s.cuts \in [Roots -> SUBSET {"edit"}] /\ s.logical \in [Stores -> SUBSET {"edit"}]
 /\ (\A k \in {"retained","accepted","frontier","acknowledged","damaged"}: s[k] \in [Stores -> SUBSET Roots])
 /\ s.deps \in [Stores -> [Roots -> SUBSET Roots]]
 /\ s.task \in [Stores -> Roots \cup {"none"}] /\ s.completion \in [Stores -> Roots \cup {"none"}]
 /\ s.proof \in [Stores -> SUBSET Roots] /\ s.crashed \subseteq Stores /\ s.failures \subseteq Stores
 /\ s.observations \subseteq {"independent","differentCut","damageBetweenChecks","lostCallback"}
ExactMembership == \A m \in Stores: s.accepted[m] \subseteq s.retained[m]
DependencyClosed == \A m \in Stores: \A r \in s.accepted[m]: s.parents[r] \subseteq s.accepted[m] /\ Supported(m,r)
ExactEdges == \A m \in Stores: \A r \in s.accepted[m]: s.deps[m][r]=s.parents[r]
MaximalFrontier == \A m \in Stores: s.frontier[m]=Maxima(s.accepted[m], s.deps[m])
CoverageComplete == \A m \in Stores: Closure(s.frontier[m], s.deps[m], Cardinality(Roots))=s.accepted[m]
AcknowledgeDurable == \A m \in Stores: s.acknowledged[m] \subseteq s.accepted[m]
CapturedImmutable == [][\A r \in s.captured: s'.parents[r]=s.parents[r] /\ s'.cuts[r]=s.cuts[r]]_vars
RetainedPreserved == [][\A m \in Stores: s.retained[m] \subseteq s'.retained[m] /\ s.accepted[m] \subseteq s'.accepted[m]]_vars
SnapshotNeutral == [][\A m \in Stores: Accept(m) => s'.logical=s.logical]_vars
ParentRechecked == [][\A m \in Stores: Accept(m) => ValidParents(m,s.task[m])]_vars
NeverIndependent == "independent" \notin s.observations
NeverDifferentCut == "differentCut" \notin s.observations
NeverLostCallback == "lostCallback" \notin s.observations
NeverFanIn == \A m \in Stores: "join" \notin s.accepted[m]
NeverFaultThenProgress == \A m \in s.failures: s.accepted[m]={"initial"}
NeverDamagedPreparation == "damageBetweenChecks" \notin s.observations
NeverUnsupportedParentBlocked == ~(Scenario="unsupported" /\ {"b","join"} \subseteq s.retained["A"]
 /\ "join" \in s.accepted["B"] /\ "a" \in s.accepted["A"]
 /\ "b" \notin s.accepted["A"] /\ "join" \notin s.accepted["A"])
=============================================================================
