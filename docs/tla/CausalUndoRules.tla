--------------------------- MODULE CausalUndoRules ---------------------------
EXTENDS Naturals, FiniteSets
\* Pure finite-graph reducer shared by selection fixtures and execution checks.
\* records[a] has parents, target ("none" for independent actions), kind, scope.
\* Valid complete ancestry/records are preconditions, not established here.
RECURSIVE Reach(_, _, _)
Reach(nodes, edges, n) == IF n = 0 THEN nodes
 ELSE Reach(nodes \cup UNION {edges[a]: a \in nodes}, edges, n - 1)
Ancestors(records, a) == Reach(records[a].parents,
 [b \in DOMAIN records |-> records[b].parents], Cardinality(DOMAIN records))
Root(records, a) ==
 IF records[a].kind = "forward" THEN a
 ELSE LET edges == [b \in DOMAIN records |->
                 IF records[b].target = "none" THEN {} ELSE {records[b].target}]
          chain == Reach(edges[a], edges, Cardinality(DOMAIN records))
      IN CHOOSE b \in chain: records[b].kind = "forward"
Leaves(records, hist, scope) == {a \in hist: records[a].scope = scope
 /\ ~\E b \in hist: records[b].target = a}
ForwardLeaves(records, hist, scope) ==
 {a \in Leaves(records, hist, scope): records[a].kind # "undo"}
Maximal(records, candidates) == {a \in candidates:
 ~\E b \in candidates \ {a}: a \in Ancestors(records, b)}
Undo(records, hist, scope) == Maximal(records, ForwardLeaves(records, hist, scope))
RedoBlocked(records, hist, a) == \E b \in hist:
 records[b].kind = "forward" /\ records[b].scope = records[a].scope
 /\ a \in Ancestors(records, b)
Redo(records, hist, scope) == Maximal(records, {a \in Leaves(records, hist, scope):
 records[a].kind = "undo" /\ ~RedoBlocked(records, hist, a)})
\* A fork in another compensation family cannot taint this command. The sibling
\* may be in the opposite direction, so do not restrict BOTH ends to candidates.
Competing(records, hist, scope, candidates) ==
 \E a \in candidates, b \in Leaves(records, hist, scope):
 a # b /\ Root(records, a) = Root(records, b)
RedoAmbiguous(records, hist, scope) ==
 \E a \in Redo(records, hist, scope), b \in ForwardLeaves(records, hist, scope):
 a \notin Ancestors(records, b) /\ b \notin Ancestors(records, a)
Candidates(records, hist, scope, direction) ==
 IF direction = "undo" THEN Undo(records, hist, scope) ELSE Redo(records, hist, scope)
Mode(records, hist, scope, direction) ==
 LET cs == Candidates(records, hist, scope, direction)
 IN IF cs = {} THEN "none"
 ELSE IF Cardinality(cs) = 1 /\ ~Competing(records, hist, scope, cs)
      /\ ~(direction = "redo" /\ RedoAmbiguous(records, hist, scope))
 THEN "automatic" ELSE "review"
=============================================================================
