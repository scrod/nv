-------------------------- MODULE ProjectionStampSafety --------------------------
EXTENDS Naturals, FiniteSets
\* One receiving file, two source revisions and independently visible body,
\* stamp and history. Digest equality, schema validation and unique applicable
\* path association are finite inputs, NOT Apple guarantees or physical identity.
\* Observation/decision is an already-fenced atomic snapshot here; the existing
\* file/root models and actual codec/installer tests supply that boundary.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","stampAuthority","ignoreDigest","ignoreDuplicate","uncheckedImport","aliasExplicit"}
 /\ Scenario \in {"unique","duplicate","repair"}
\* Body/stamp 1 and 2 are exact revision bytes/digests; body 3 is an external
\* edit. Stamp 0 is absent, 3 is malformed/foreign. No collision oracle.
VARIABLE s
vars == <<s>>
Init == s = [body |-> 0, stamp |-> 0, history |-> {},
 frame |-> [body |-> 0, stamp |-> 0, history |-> {}, explicit |-> FALSE, admitted |-> FALSE], result |-> "none",
 explicit |-> FALSE, newBirth |-> FALSE, admitted |-> FALSE, autoFrame |-> [body |-> 0, stamp |-> 0, history |-> {}]]
Body(b) == /\ b \in 0..3 /\ b # s.body
 /\ s' = [s EXCEPT !.body = b]
Stamp(v) == /\ v \in 0..3 /\ v # s.stamp
 /\ s' = [s EXCEPT !.stamp = v]
History(v) == /\ v \in {1,2} \ s.history /\ (v = 2 => 1 \in s.history)
 /\ s' = [s EXCEPT !.history = @ \cup {v}]
Evaluate ==
 /\ s.frame # [body |-> s.body, stamp |-> s.stamp, history |-> s.history, explicit |-> s.explicit, admitted |-> s.admitted]
 /\ LET identifiable == s.body \in {1,2}
        matched == s.stamp = s.body \/ s.stamp = 0
        known == s.body \in s.history
        unique == Scenario # "duplicate"
        associate == identifiable /\ (matched \/ Policy = "ignoreDigest")
                     /\ (known \/ Policy = "stampAuthority")
                     /\ (unique \/ Policy = "ignoreDuplicate")
        result == IF s.body = 0 THEN "none"
                  ELSE IF s.admitted /\ Policy # "aliasExplicit" THEN "review"
                  ELSE IF associate THEN "represented"
                  ELSE IF s.stamp = s.body /\ identifiable /\ ~known THEN "waiting"
                  ELSE IF s.stamp=0 /\ Scenario="unique" THEN "new"
                  ELSE "review"
    IN s' = [s EXCEPT !.result = result,
      !.frame = [body |-> s.body, stamp |-> s.stamp, history |-> s.history, explicit |-> s.explicit, admitted |-> s.admitted],
      !.newBirth = IF Policy = "aliasExplicit" /\ result = "represented" THEN FALSE
                  ELSE @]
\* This model supplies no repair candidate in "unique". The shared classifier
\* labs exercise that predicate; "repair" supplies an explicit unhandled one.
AutomaticImport == /\ ~s.admitted /\ s.body # 0
 /\ (Policy="uncheckedImport" \/ (s.result="new" /\
       s.frame=[body |-> s.body, stamp |-> s.stamp, history |-> s.history, explicit |-> s.explicit, admitted |-> s.admitted]))
 /\ s'=[s EXCEPT !.newBirth=TRUE, !.admitted=TRUE,
                 !.autoFrame=[body |-> s.body, stamp |-> s.stamp, history |-> s.history]]
ImportAsNew == /\ ~s.admitted /\ s.body # 0
 /\ s' = [s EXCEPT !.explicit = TRUE, !.admitted=TRUE, !.newBirth = TRUE]
Next == (\E b \in 0..3: Body(b) \/ Stamp(b))
 \/ (\E v \in {1,2}: History(v)) \/ Evaluate \/ ImportAsNew \/ AutomaticImport
Spec == Init /\ [][Next]_vars
TypeOK ==
 /\ s.body \in 0..3 /\ s.stamp \in 0..3 /\ s.history \subseteq {1,2}
 /\ s.frame \in [body: 0..3, stamp: 0..3, history: SUBSET {1,2}, explicit: BOOLEAN, admitted: BOOLEAN]
 /\ s.result \in {"none","represented","waiting","review","new"}
 /\ s.explicit \in BOOLEAN /\ s.newBirth \in BOOLEAN /\ s.admitted \in BOOLEAN
 /\ s.autoFrame \in [body: 0..3, stamp: 0..3, history: SUBSET {1,2}]
AssociationNeedsHistory == s.result = "represented" => s.frame.body \in s.frame.history
AssociationNeedsExactBytes == s.result = "represented" =>
 s.frame.body \in {1,2} /\ s.frame.stamp \in {0,s.frame.body}
CopiedStampIsNotIdentity == Scenario = "duplicate" => s.result # "represented"
AutomaticBirthHasEligibleObservation == s.admitted /\ ~s.explicit =>
 /\ s.autoFrame.body # 0 /\ s.autoFrame.stamp=0 /\ Scenario="unique"
 /\ ~(s.autoFrame.body \in {1,2} /\ s.autoFrame.body \in s.autoFrame.history)
ExplicitBirthIsNotAliased == s.explicit => s.newBirth
ImportedBirthIsNotAliased == s.admitted => s.newBirth
ExplicitChoiceNotRebound == s.result = "represented" => ~s.frame.explicit
AdmittedChoiceNotRebound == s.result = "represented" => ~s.frame.admitted
Safety == AssociationNeedsHistory /\ AssociationNeedsExactBytes
 /\ CopiedStampIsNotIdentity /\ AutomaticBirthHasEligibleObservation
 /\ ExplicitBirthIsNotAliased /\ ImportedBirthIsNotAliased /\ ExplicitChoiceNotRebound /\ AdmittedChoiceNotRebound
NeverAutomaticallyImported == ~(s.admitted /\ ~s.explicit)
NeverKeptAutomaticImport == ~(s.admitted /\ ~s.explicit /\ s.newBirth /\ s.stamp=2 /\ s.history={1,2} /\ s.result="review")
NeverWaitedForSegment == ~(s.frame.body = 2 /\ s.frame.stamp = 2
 /\ 2 \notin s.frame.history /\ s.result = "waiting" /\ ~s.newBirth)
NeverAssociatedAfterHistory == ~(s.frame.body = 2 /\ s.frame.stamp = 2
 /\ s.frame.history = {1,2} /\ s.result = "represented" /\ ~s.newBirth)
NeverRejectedSkew == ~(s.frame.body = 2 /\ s.frame.stamp = 1
 /\ s.frame.history = {1,2} /\ s.result = "review")
NeverKeptExplicitImport == ~(s.explicit /\ s.newBirth /\ s.frame.history = {1,2}
 /\ s.frame.explicit /\ s.frame.body = 2 /\ s.frame.stamp = 2 /\ s.result = "review")
=============================================================================
