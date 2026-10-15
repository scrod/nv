------------------ MODULE PreservedRepositoryReplacementSafety ------------------
EXTENDS Naturals, FiniteSets

\* Retired exploratory policy: superseded by stop-and-Save-As on 2026-10-14.
\* A bounded repair has one exact replacement, one external change and up to two
\* process crashes/write failures. Filesystem effects survive process restart.
\* Durability barriers are explicit; physical power-loss behavior is a separate
\* native qualification. Compatible intake abstracts the existing history validator.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "discardBackup", "forgetIntent", "earlyAck",
                    "skipBarrier", "skipReconcile", "overwriteKnownForeign", "staleRoot", "neverResume"}
  /\ Scenario \in {"stable", "race", "childRace", "knownForeign", "crash", "io", "rootLoss",
                     "raceCrash", "childCrash", "combined"}

Valid == {"base", "local", "peer"}
Values == Valid \cup {"damage", "foreign"}
Replacement == {"base", "local"}
Phases == {"idle", "prepared", "checked", "replaced", "synced",
            "reconciled", "done", "restart", "blocked"}
VARIABLE s
vars == <<s>>
Init == s = [phase |-> "idle", current |-> IF Scenario = "knownForeign" THEN {"foreign"} ELSE {"damage"},
  backup |-> {}, accepted |-> Replacement, reported |-> {},
  intent |-> FALSE, barrier |-> FALSE, ack |-> FALSE,
  root |-> "same", raced |-> FALSE, crashes |-> 0, failures |-> 0,
  displaced |-> {}, effect |-> FALSE, effectAuthorized |-> FALSE,
  resumed |-> FALSE, capturedOwned |-> Scenario # "knownForeign"]

Prepare ==
 /\ s.phase = "idle"
 /\ s' = [s EXCEPT !.phase = "prepared", !.intent = Policy # "forgetIntent"]

Check ==
 /\ s.phase = "prepared"
 /\ s' = [s EXCEPT !.phase = IF s.root = "same" /\
        ((s.capturedOwned /\ s.current = {"damage"}) \/ Policy = "overwriteKnownForeign")
      THEN "checked" ELSE "blocked"]

Race ==
 /\ Scenario \in {"race", "childRace", "raceCrash", "childCrash", "combined"} /\ ~s.raced /\ s.phase = "checked"
 /\ s' = [s EXCEPT !.current = IF Scenario \in {"race", "raceCrash", "combined"} THEN {"peer", "foreign"}
                                          ELSE @ \cup {"peer"}, !.raced = TRUE]

LoseRoot ==
 /\ Scenario = "rootLoss" /\ s.root = "same" /\ ~s.effect
 /\ s' = [s EXCEPT !.root = "different"]

\* Native replacement preserves the actual displaced item, including a winner
\* after the last precheck. Authorization still comes from the captured owned damage.
Replace ==
 /\ s.phase = "checked" /\ (s.root = "same" \/ Policy = "staleRoot")
 /\ s' = [s EXCEPT !.backup = IF Policy = "discardBackup" THEN {} ELSE s.current,
       !.displaced = s.current, !.current = Replacement, !.effect = TRUE,
       !.effectAuthorized = s.capturedOwned /\ s.root = "same",
       !.phase = "replaced"]

Sync ==
 /\ s.phase = "replaced"
 /\ s' = [s EXCEPT !.barrier = Policy # "skipBarrier", !.phase = "synced"]

Reconcile ==
 /\ s.phase = "synced"
 /\ s' = [s EXCEPT !.accepted = IF Policy = "skipReconcile" THEN @ ELSE @ \cup (s.backup \cap Valid),
       !.reported = IF Policy = "skipReconcile" THEN @ ELSE @ \cup (s.backup \ Valid),
       !.phase = "reconciled"]

Finish ==
 /\ s.phase = "reconciled" \/ (Policy = "earlyAck" /\ s.phase = "replaced")
 /\ s' = [s EXCEPT !.ack = TRUE, !.intent = FALSE, !.phase = "done"]

Crash ==
 /\ Scenario \in {"crash", "raceCrash", "childCrash", "combined"} /\ s.crashes < 2
 /\ s.phase \in {"prepared", "checked", "replaced", "synced", "reconciled"}
 /\ s' = [s EXCEPT !.phase = "restart", !.crashes = @ + 1]

FailWrite ==
 /\ Scenario \in {"io", "combined"} /\ s.failures < 2
 /\ s.phase \in {"prepared", "replaced", "synced", "reconciled"}
 /\ s' = [s EXCEPT !.phase = "restart", !.failures = @ + 1]

\* A persistent intent makes existing backup evidence required work after restart.
\* Without it, healthy replacement bytes alone would appear to finish the repair.
Restart ==
 /\ s.phase = "restart" /\ Policy # "neverResume"
 /\ s' = [s EXCEPT !.resumed = TRUE,
       !.phase = IF s.intent THEN IF s.backup # {} THEN "replaced" ELSE "prepared"
                  ELSE IF s.current = Replacement THEN "done" ELSE "idle",
       !.ack = ~s.intent /\ s.current = Replacement]

Next == Prepare \/ Check \/ Race \/ LoseRoot \/ Replace \/ Sync \/ Reconcile
     \/ Finish \/ Crash \/ FailWrite \/ Restart
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Prepare) /\ WF_vars(Check) /\ WF_vars(Replace)
 /\ WF_vars(Sync) /\ WF_vars(Reconcile) /\ WF_vars(Finish) /\ WF_vars(Restart)

TypeOK ==
 /\ s.phase \in Phases /\ s.root \in {"same", "different"}
 /\ s.current \subseteq Values /\ s.backup \subseteq Values
 /\ s.accepted \subseteq Valid /\ s.reported \subseteq Values
 /\ s.displaced \subseteq Values /\ s.crashes \in 0..2 /\ s.failures \in 0..2
 /\ \A k \in {"intent", "barrier", "ack", "raced", "effect", "effectAuthorized",
                "resumed", "capturedOwned"}: s[k] \in BOOLEAN
DisplacedEvidenceSurvives == s.displaced \subseteq s.backup
EffectHasOwnedAuthority == s.effect => s.effectAuthorized
CompletionHasBarriers == s.ack => s.barrier
CompletionAccountsForDisplacement == s.ack =>
   (s.displaced \cap Valid) \subseteq s.accepted /\ (s.displaced \ Valid) \subseteq s.reported
UnsettledEffectHasReminder == s.effect /\ ~s.ack => s.intent
KnownForeignStaysCurrent == Scenario = "knownForeign" => s.current = {"foreign"}
LocalHistorySurvives == Replacement \subseteq s.accepted
Safety == TypeOK /\ DisplacedEvidenceSurvives /\ EffectHasOwnedAuthority
 /\ CompletionHasBarriers /\ CompletionAccountsForDisplacement
 /\ UnsettledEffectHasReminder /\ KnownForeignStaysCurrent /\ LocalHistorySurvives
Completes == <>s.ack
Settles == <>(s.ack \/ s.phase = "blocked")
NeverReplacedAfterRace == ~(s.effect /\ s.raced)
NeverReconciledPeer == "peer" \notin s.accepted
NeverResumedEffect == ~(s.resumed /\ s.effect /\ s.ack)
=============================================================================
