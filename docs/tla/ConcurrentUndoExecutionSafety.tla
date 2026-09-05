--------------------- MODULE ConcurrentUndoExecutionSafety ---------------------
EXTENDS Naturals, FiniteSets
\* Protocol.md / Implementation.md: dynamically author TWO concurrent Undos,
\* then review/redo/undo/redo OR independent edit/undo/redo on their joined view.
\* The plan bounds user requests, not execution depth: all enabled interleavings
\* of prepare/approve/admit/encode/install/ack/receipt/apply/crash are explored.
\* One scalar plus another note, or three fresh restoration births. No text/IME,
\* native partial coverage, codec, filesystem, or arbitrary merge proof. Install
\* abstracts the complete local file/directory/pin barrier checked separately.
\* For the freshness experiment the whole finite live vector/frontier is
\* captured. This is conservative, not a requirement that unrelated-note edits
\* invalidate a real command whose captured inputs did not include them.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "staleConsent", "splitGroup", "earlyAck",
 "staleCompletion", "dropSibling", "wrongBirth", "allowNoop", "omitParent", "dismissConsumes"}
 /\ Scenario \in {"review", "independent", "restore", "intervention"}
Rules == INSTANCE CausalUndoRules
Hosts == {1, 2}
Ids == {"A", "U", "V", "R", "S", "T", "X", "Y", "Z", "E", "N"}
Fields == {"body", "other", "old", "u", "v", "s"}
CommandScope == IF Scenario = "restore" THEN "collection" ELSE "note"
Zero == [f \in Fields |-> CASE f = "other" -> 7 [] f = "old" -> 1 [] OTHER -> 0]
InitialField == IF Scenario = "restore" THEN "old" ELSE "body"
InitialValue == [Zero EXCEPT ![InitialField] = IF Scenario = "restore" THEN 0 ELSE 1]
EmptyRecord == [parents |-> {}, inputs |-> {}, target |-> "none", kind |-> "forward",
 scope |-> CommandScope, fields |-> {}, before |-> Zero, after |-> Zero, reviewed |-> FALSE]
InitialRecord == [EmptyRecord EXCEPT !.fields = {InitialField}, !.after = InitialValue]
VARIABLE s
vars == <<s>>
Init == s = [records |-> [a \in Ids |-> IF a = "A" THEN InitialRecord ELSE EmptyRecord],
 known |-> [h \in Hosts |-> {"A"}], diskNotes |-> [h \in Hosts |-> {"A"}],
 diskActions |-> [h \in Hosts |-> {"A"}], inbox |-> [h \in Hosts |-> {}],
 ack |-> [h \in Hosts |-> {}], live |-> [h \in Hosts |-> InitialValue],
 phase |-> [h \in Hosts |-> "idle"], slot |-> [h \in Hosts |-> "none"],
 capture |-> [h \in Hosts |-> EmptyRecord], mode |-> [h \in Hosts |-> "none"],
 crashed |-> FALSE, recovered |-> FALSE, noopSeen |-> FALSE, rejected |-> FALSE]

\* Note values reduce from concrete per-field operations and their declared
\* inputs, independently of undo candidates or a success/cursor flag.
Value(hist) == [f \in Fields |->
 LET writes == {a \in hist: f \in s.records[a].fields}
     heads == {a \in writes: ~\E b \in writes: a \in s.records[b].inputs}
     vals == {s.records[a].after[f]: a \in heads}
 IN IF vals = {} THEN Zero[f]
    ELSE IF Cardinality(vals) = 1 THEN CHOOSE v \in vals: TRUE ELSE 3]
ScopeParents(hist, scope) == Rules!Maximal(s.records, {a \in hist: s.records[a].scope = scope})
Candidates(h, direction) == Rules!Candidates(s.records, s.known[h], CommandScope, direction)
Mode(h, direction) == Rules!Mode(s.records, s.known[h], CommandScope, direction)
Direction(a) == IF a \in {"U", "V", "S", "Y"} THEN "undo" ELSE "redo"
NextSlot(h) ==
 IF h = 2 THEN IF "V" \notin s.diskActions[2] THEN "V" ELSE "none"
 ELSE IF "U" \notin s.diskActions[1] THEN "U"
 ELSE IF ~({"U", "V"} \subseteq s.diskActions[1]) THEN "none"
 ELSE IF Scenario = "independent" THEN
      CASE "X" \notin s.diskActions[1] -> "X"
       [] "Y" \notin s.diskActions[1] -> "Y"
       [] "Z" \notin s.diskActions[1] -> "Z" [] OTHER -> "none"
 ELSE CASE "R" \notin s.diskActions[1] -> "R"
       [] Scenario = "review" /\ ~s.noopSeen -> "N"
       [] "S" \notin s.diskActions[1] -> "S"
       [] "T" \notin s.diskActions[1] -> "T" [] OTHER -> "none"
FreshField(a) == CASE a = "U" -> "u" [] a = "V" -> "v" [] OTHER -> "s"
Restores(t) == Scenario = "restore" /\
 \E f \in s.records[t].fields: s.records[t].before[f] = 1 /\ s.records[t].after[f] = 0
FreshRestore(a, t) == Restores(t) /\ ~(Policy = "wrongBirth" /\ a = "S")
ChangedFields(a, t) == IF a = "X" THEN {"body"}
 ELSE IF FreshRestore(a, t) THEN {FreshField(a)} ELSE s.records[t].fields
Replacement(h, a, t) == [f \in Fields |->
 IF f \notin ChangedFields(a, t) THEN s.live[h][f]
 ELSE IF a = "X" THEN 2
 ELSE IF FreshRestore(a, t) THEN 1 ELSE s.records[t].before[f]]
Prepare(h, t) ==
 /\ s.phase[h] = "idle" /\ NextSlot(h) # "none"
 /\ LET a == NextSlot(h)
        cs == IF a = "X" THEN {"none"} ELSE Candidates(h, Direction(a))
    IN /\ t \in cs
       /\ LET after == Replacement(h, a, t)
              noEffect == after = s.live[h]
              mode == IF a = "X" THEN "automatic" ELSE Mode(h, Direction(a))
          IN s' = [s EXCEPT !.slot[h] = a, !.mode[h] = mode,
              !.noopSeen = @ \/ a = "N",
              !.phase[h] = IF noEffect /\ Policy # "allowNoop" THEN "blocked"
                          ELSE IF mode = "review" THEN "preview" ELSE "ready",
              !.capture[h] = [parents |-> ScopeParents(s.known[h], CommandScope),
                 inputs |-> s.known[h], target |-> t,
                 kind |-> IF a = "X" THEN "forward" ELSE Direction(a), scope |-> CommandScope,
                 fields |-> ChangedFields(a, t), before |-> s.live[h], after |-> after,
                 reviewed |-> FALSE]]
Approve(h) == /\ s.phase[h] = "preview"
 /\ s' = [s EXCEPT !.phase[h] = "ready", !.capture[h].reviewed = TRUE]
Dismiss(h) == /\ s.phase[h] \in {"preview", "ready", "blocked"}
 /\ s' = [s EXCEPT !.phase[h] = "idle", !.slot[h] = "none",
      !.known[h] = IF Policy = "dismissConsumes" THEN @ \ {s.capture[h].target} ELSE @,
      !.capture[h] = EmptyRecord, !.mode[h] = "none"]
RejectStale(h) == /\ s.phase[h] \in {"preview", "ready"}
 /\ s.capture[h].inputs # s.known[h]
 /\ s' = [s EXCEPT !.phase[h] = "idle", !.slot[h] = "none",
      !.rejected = @ \/ s.mode[h] = "review", !.capture[h] = EmptyRecord, !.mode[h] = "none"]
Admit(h) ==
 /\ s.phase[h] = "ready"
 /\ Policy = "staleConsent" \/ s.capture[h].inputs = s.known[h]
 /\ LET a == s.slot[h]
        rec == IF Policy = "omitParent" /\ a \in {"R", "X"}
               THEN [s.capture[h] EXCEPT !.parents = @ \ {"V"}] ELSE s.capture[h]
        hist == IF Policy = "dropSibling" /\ a = "R"
                THEN (s.known[h] \ {"U", "V"}) \cup {rec.target, a}
                ELSE s.known[h] \cup {a}
    IN s' = [s EXCEPT !.records[a] = rec, !.known[h] = hist,
                    !.live[h] = rec.after, !.phase[h] = "pending"]
Encode(h) == /\ s.phase[h] = "pending"
 /\ s' = [s EXCEPT !.phase[h] = "encoded"]
Install(h) == /\ s.phase[h] = "encoded"
 /\ s' = [s EXCEPT !.diskNotes[h] = @ \cup {s.slot[h]},
      !.diskActions[h] = IF Policy = "splitGroup" THEN @ ELSE @ \cup {s.slot[h]},
      !.phase[h] = "installed"]
Ack(h) == /\ s.phase[h] = "installed" \/ (Policy = "earlyAck" /\ s.phase[h] = "encoded")
 /\ s' = [s EXCEPT !.ack[h] = @ \cup {s.slot[h]}, !.phase[h] = "idle",
      !.live[h] = IF Policy = "staleCompletion" THEN s.capture[h].after ELSE @,
      !.slot[h] = "none", !.capture[h] = EmptyRecord, !.mode[h] = "none"]

\* One independently durable edit of ANOTHER note; it can arrive during review
\* or pending installation without changing the requested command's scope.
OtherEdit == /\ Scenario = "intervention" /\ "V" \in s.diskActions[2]
 /\ s.known[2] = {"A", "U", "V"} /\ s.phase[2] = "idle"
 /\ LET v == [s.live[2] EXCEPT !["other"] = 9]
        rec == [EmptyRecord EXCEPT !.inputs = s.known[2], !.scope = "other",
                                 !.fields = {"other"}, !.before = s.live[2], !.after = v]
    IN s' = [s EXCEPT !.records["E"] = rec, !.known[2] = @ \cup {"E"},
                     !.diskNotes[2] = @ \cup {"E"}, !.diskActions[2] = @ \cup {"E"}, !.live[2] = v]
Available == UNION {s.diskNotes[h] \cap s.diskActions[h]: h \in Hosts}
Receive(h, a) == /\ a \in Available \ (s.known[h] \cup s.inbox[h] \cup s.diskActions[h])
 /\ s' = [s EXCEPT !.inbox[h] = @ \cup {a}]
ApplyReceived(h, a) == /\ s.phase[h] # "down" /\ a \in s.inbox[h] \ s.known[h]
 /\ s.records[a].inputs \subseteq s.known[h]
 \* Cannot accept a dependent envelope durably before a local pending parent.
 /\ s.records[a].inputs \subseteq s.diskActions[h] \cap s.diskNotes[h]
 /\ s' = [s EXCEPT !.known[h] = @ \cup {a}, !.diskNotes[h] = @ \cup {a},
       !.diskActions[h] = @ \cup {a}, !.inbox[h] = @ \ {a}, !.live[h] = Value(s.known[h] \cup {a})]
Crash == /\ ~s.crashed /\ {"U", "V"} \subseteq s.diskActions[1]
 /\ s.phase[1] \in {"preview", "ready", "pending", "encoded", "installed", "idle"}
 /\ s' = [s EXCEPT !.crashed = TRUE, !.phase[1] = "down", !.known[1] = {},
       !.live[1] = Zero, !.slot[1] = "none", !.capture[1] = EmptyRecord]
Recover == /\ s.phase[1] = "down"
 /\ s' = [s EXCEPT !.known[1] = s.diskNotes[1] \cap s.diskActions[1],
       !.live[1] = Value(s.diskNotes[1] \cap s.diskActions[1]),
       !.phase[1] = "idle", !.recovered = TRUE]
Next == (\E h \in Hosts:
   (\E t \in Ids \cup {"none"}: Prepare(h,t)) \/ Approve(h) \/ Dismiss(h)
   \/ RejectStale(h) \/ Admit(h) \/ Encode(h) \/ Install(h) \/ Ack(h)
   \/ (\E a \in Ids: Receive(h,a) \/ ApplyReceived(h,a)))
 \/ OtherEdit \/ Crash \/ Recover
Spec == Init /\ [][Next]_vars
\* Conditional transport/local progress only. No fairness forces an Undo,
\* review approval, edit, crash, or provider availability in safety checks.
FairSpec == Spec /\ WF_vars(Recover)
 /\ (\A h \in Hosts: WF_vars(Encode(h)) /\ WF_vars(Install(h)) /\ WF_vars(Ack(h)))
 /\ (\A h \in Hosts, a \in Ids: WF_vars(Receive(h,a)) /\ WF_vars(ApplyReceived(h,a)))

TypeOK ==
 /\ DOMAIN s.records = Ids
 /\ \A a \in Ids:
       /\ s.records[a].inputs \subseteq Ids /\ s.records[a].parents \subseteq Ids
       /\ s.records[a].target \in Ids \cup {"none"}
       /\ s.records[a].kind \in {"forward", "undo", "redo"}
       /\ s.records[a].scope \in {"note", "collection", "other"} /\ s.records[a].fields \subseteq Fields
       /\ s.records[a].before \in [Fields -> {0,1,2,3,7,9}]
       /\ s.records[a].after \in [Fields -> {0,1,2,3,7,9}]
 /\ \A h \in Hosts:
       /\ s.phase[h] \in {"idle", "preview", "ready", "blocked", "pending", "encoded", "installed", "down"}
       /\ s.slot[h] \in Ids \cup {"none"} /\ s.live[h] \in [Fields -> {0,1,2,3,7,9}]
       /\ \A f \in {"known", "diskNotes", "diskActions", "inbox", "ack"}: s[f][h] \subseteq Ids
 /\ s.crashed \in BOOLEAN /\ s.recovered \in BOOLEAN /\ s.noopSeen \in BOOLEAN /\ s.rejected \in BOOLEAN
AtomicGroups == \A h \in Hosts: s.diskNotes[h] = s.diskActions[h]
AckDurable == \A h \in Hosts: s.ack[h] \subseteq s.diskNotes[h] \cap s.diskActions[h]
KnownRetainsDurable == \A h \in Hosts: s.phase[h] = "down" \/ s.diskActions[h] \subseteq s.known[h]
ClosedHistory == \A h \in Hosts: \A a \in s.known[h]: s.records[a].inputs \subseteq s.known[h]
LiveMatchesHistory == \A h \in Hosts: s.phase[h] = "down" \/ s.live[h] = Value(s.known[h])
NoNoopRecords == \A h \in Hosts: \A a \in s.known[h]:
 \E f \in s.records[a].fields: s.records[a].before[f] # s.records[a].after[f]
\* Independent expected note values from the requested command sequences.
ConcreteValues == \A h \in Hosts: s.phase[h] = "down" \/
 LET hist == s.known[h]
     v == s.live[h]
 IN /\ v["other"] = IF "E" \in hist THEN 9 ELSE 7
    /\ IF Scenario = "restore" THEN
         /\ v["old"] = 0
         /\ v["u"] = IF "U" \in hist /\ ~("R" \in hist /\ s.records["R"].target = "U") THEN 1 ELSE 0
         /\ v["v"] = IF "V" \in hist /\ ~("R" \in hist /\ s.records["R"].target = "V") THEN 1 ELSE 0
         /\ v["s"] = IF "S" \in hist /\ "T" \notin hist THEN 1 ELSE 0
       ELSE v["body"] = CASE "Z" \in hist -> 2 [] "Y" \in hist -> 0 [] "X" \in hist -> 2
             [] "T" \in hist -> 1 [] "S" \in hist -> 0 [] "R" \in hist -> 1
             [] hist \cap {"U", "V"} # {} -> 0 [] OTHER -> 1
ContinuationCandidates == \A h \in Hosts:
 s.phase[h] = "down" \/ ~({"U", "V"} \subseteq s.known[h]) \/
 LET hist == s.known[h]
 IN IF Scenario = "independent" THEN
      /\ ("X" \in hist /\ "Y" \notin hist => Candidates(h,"undo") = {"X"} /\ Mode(h,"undo") = "automatic")
      /\ ("Y" \in hist /\ "Z" \notin hist => Candidates(h,"redo") = {"Y"} /\ Mode(h,"redo") = "automatic")
      /\ ("Z" \in hist => Candidates(h,"undo") = {"Z"} /\ Mode(h,"undo") = "automatic")
    ELSE /\ ("R" \notin hist => Candidates(h,"redo") = {"U", "V"} /\ Mode(h,"redo") = "review")
         /\ ("R" \in hist /\ "S" \notin hist => Candidates(h,"undo") = {"R"} /\ Mode(h,"undo") = "review")
         /\ ("S" \in hist /\ "T" \notin hist => Candidates(h,"redo") = {"S"} /\ Mode(h,"redo") = "review")
         /\ ("T" \in hist => Candidates(h,"undo") = {"T"} /\ Mode(h,"undo") = "review")
Safety == AtomicGroups /\ AckDurable /\ KnownRetainsDurable /\ ClosedHistory
 /\ LiveMatchesHistory /\ NoNoopRecords /\ ConcreteValues /\ ContinuationCandidates
\* Admission and recovery assertions compare actual transitions, not flags set
\* by the successful path. The capture is unchanged by remote publication.
ExactAdmission == [] [\A h \in Hosts:
 (s.phase[h] = "ready" /\ s'.phase[h] = "pending") =>
 /\ s.capture[h].inputs = s.known[h]
 /\ s'.records[s.slot[h]].before = s.live[h]
 /\ s'.records[s.slot[h]].parents = ScopeParents(s.known[h], CommandScope)
 /\ (s.mode[h] # "review" \/ s.capture[h].reviewed)]_vars
RecoveryRebuilds == [] [(s.phase[1] = "down" /\ s'.phase[1] = "idle") =>
 s'.known[1] = s.diskActions[1] /\ s'.live[1] = Value(s.diskNotes[1])]_vars
PresentationPreserves == [] [\A h \in Hosts:
 ((s.phase[h] = "preview" /\ s'.phase[h] = "ready")
  \/ (s.phase[h] \in {"preview", "ready", "blocked"} /\ s'.phase[h] = "idle")) =>
 UNCHANGED <<s.records, s.known, s.diskNotes, s.diskActions, s.live, s.ack>>]_vars
DurableReachesPeer == \A a \in Ids: a \in Available ~> (\A h \in Hosts: a \in s.known[h])
NeverCompletedOnBoth == ~(s.recovered /\ (\A h \in Hosts:
 (IF Scenario = "independent" THEN "Z" ELSE "T") \in s.known[h]))
NeverRejectedStaleReview == ~s.rejected
NeverBlockedNoop == ~s.noopSeen
NeverReceivedChildFirst == ~(\E h \in Hosts: \E a \in s.inbox[h]: ~(s.records[a].inputs \subseteq s.known[h]))
NeverRecoveredBeforeAck == ~(s.recovered /\ (s.diskActions[1] \ {"A", "U", "V", "E"}) \ s.ack[1] # {})
NeverAppliedDuringPending == ~(s.phase[1] \in {"pending", "encoded", "installed"}
 /\ s.slot[1] \in {"R", "S", "T"} /\ "E" \in s.known[1] /\ "E" \notin s.capture[1].inputs)
=============================================================================
