--------------------- MODULE OptionalReadyStartupSafety ---------------------
EXTENDS Naturals, FiniteSets

\* LocalStore.open drains required Changes and discovered snapshot prerequisites.
\* Publication.publish reserves the receive owner after the checked host callback.
\* ReceivedObjects uses separate prepare/validate/accept turns and the existing
\* save-completion continuation. Current rows update separately from acceptance.
\* Two local saves, one later Changes delivery and one crash bound interference.
\* Verification and integrity outcomes are inputs from the existing checking models.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "hideRequired", "earlyPublish", "lostKick", "lostWake",
                   "loseReady", "unvalidatedSnapshot", "skipVerification"}
 /\ Scenario \in {"healthy", "prerequisite", "verify", "damage", "late", "failure"}
VARIABLE s
vars == <<s>>
Objects == {"change", "snapshot", "late"}
Logical == s.accepted \ {"snapshot"}
Prefix == <<Logical, s.saved>>
Required == {"change"} \cup (s.delivered \cap {"late"})
            \cup IF Scenario="prerequisite" THEN {"snapshot"} ELSE {}
ReadyRequired == s.ready \cap Required
Init == s = [phase |-> "opening", ready |-> {"change", "snapshot"},
 parked |-> {}, accepted |-> {}, rejected |-> {}, delivered |-> {"change", "snapshot"},
 rows |-> <<{}, 0>>, verified |-> (Scenario#"verify"),
 owner |-> FALSE, task |-> "idle", item |-> "none", captured |-> <<{}, 0>>,
 checked |-> FALSE, attempts |-> 0, save |-> "idle", issued |-> 0, saved |-> 0,
 published |-> FALSE, crashUsed |-> FALSE, closed |-> FALSE,
 failedWrite |-> FALSE, storageStopped |-> FALSE,
 publishedBeforeOptional |-> FALSE, requiredBehindOptional |-> FALSE,
 resumed |-> FALSE, restartedThenSettled |-> FALSE]

Verify == /\ s.phase="opening" /\ ~s.verified
 /\ s'=[s EXCEPT !.verified=TRUE]
StartupDone == /\ s.phase="opening" /\ s.task="idle"
 /\ (ReadyRequired={} \/ Policy="hideRequired")
 /\ s'=[s EXCEPT !.phase="publication"]
Choose(item) == /\ ~s.closed /\ s.task="idle" /\ item \in s.ready
 /\ (s.phase="opening" => item \in Required)
 /\ (s.phase="live" => s.owner /\ ~s.storageStopped)
 /\ s.phase \in {"opening", "live"}
 /\ s'=[s EXCEPT !.item=item, !.task="prepare", !.checked=FALSE,
        !.requiredBehindOptional=@ \/ (item="change" /\ "snapshot" \in s.ready)]
Park == /\ s.task="prepare" /\ s.item="change" /\ Scenario="prerequisite"
 /\ "snapshot" \notin s.accepted
 /\ s'=[s EXCEPT !.ready=@ \ {"change"}, !.parked=@ \cup {"change"}, !.task="idle"]
Prepare == /\ s.task="prepare"
 /\ ~(s.item="change" /\ Scenario="prerequisite" /\ "snapshot" \notin s.accepted)
 /\ s'=[s EXCEPT !.captured=Prefix,
   !.task=IF Policy="unvalidatedSnapshot" /\ s.item="snapshot" THEN "commit" ELSE "validate"]
Validate == /\ s.task="validate"
 /\ s'=[s EXCEPT !.checked=TRUE, !.task="commit"]
Retry == /\ s.task="commit" /\ s.item#"snapshot" /\ s.captured#Prefix
 /\ s'=[s EXCEPT !.attempts=IF @=0 THEN 1 ELSE 0,
   !.task=IF s.attempts=0 THEN "prepare" ELSE "waitCheck"]
WaitCheck == /\ s.task="waitCheck"
 /\ s'=[s EXCEPT !.task=IF s.save="idle" THEN "prepare" ELSE "asleep"]
Accept == /\ s.task="commit"
 /\ (s.item="snapshot" \/ s.captured=Prefix)
 /\ (s.checked \/ Policy="unvalidatedSnapshot")
 /\ ~(Scenario="failure" /\ s.item="snapshot")
 /\ s'=[s EXCEPT !.accepted=@ \cup {s.item},
   !.ready=(s.ready \ {s.item}) \cup IF s.item="snapshot" THEN s.parked ELSE {},
   !.parked=IF s.item="snapshot" THEN {} ELSE @, !.task="idle",
   !.attempts=0, !.restartedThenSettled=@ \/ s.crashUsed]
\* A rejection write failure leaves both bytes and scheduling retained. Retrying
\* storage is an explicit publication or restart, rather than a polling action.
FailRejectionWrite == /\ Scenario="failure" /\ s.item="snapshot"
 /\ s.task="commit" /\ ~s.failedWrite
 /\ s'=[s EXCEPT !.failedWrite=TRUE, !.storageStopped=TRUE, !.owner=FALSE, !.task="idle"]
Reject == /\ Scenario="failure" /\ s.item="snapshot" /\ s.task="commit" /\ s.failedWrite
 /\ s'=[s EXCEPT !.rejected=@ \cup {s.item}, !.ready=@ \ {s.item}, !.task="idle"]
Materialize == /\ ~s.closed /\ s.rows#Prefix
 /\ s'=[s EXCEPT !.rows=Prefix]
Publish == /\ s.phase="publication" /\ ~s.closed
 /\ (s.rows=Prefix \/ Policy="earlyPublish")
 /\ (s.verified \/ Policy="skipVerification") /\ Scenario#"damage"
 /\ s'=[s EXCEPT !.published=TRUE, !.phase="live",
   !.owner=Policy#"lostKick",
   !.publishedBeforeOptional=@ \/ ("snapshot" \in s.ready /\ Scenario#"prerequisite")]
PublishAgain == /\ s.phase="live" /\ ~s.closed /\ ~s.owner /\ s.task="idle"
 /\ s.rows=Prefix
 /\ s'=[s EXCEPT !.owner=TRUE, !.storageStopped=FALSE]
ReleaseOwner == /\ s.phase="live" /\ s.owner /\ s.task="idle" /\ s.ready={}
 /\ s'=[s EXCEPT !.owner=FALSE]
DeliverLate == /\ Scenario="late" /\ s.published /\ "late" \notin s.delivered
 /\ ~s.closed /\ s.owner
 /\ s'=[s EXCEPT !.ready=@ \cup {"late"}, !.delivered=@ \cup {"late"}]
BeginSave == /\ s.phase="live" /\ ~s.closed /\ s.save="idle" /\ s.issued<2
 /\ s'=[s EXCEPT !.save="work", !.issued=@+1]
CommitSave == /\ s.save="work" /\ ~s.closed
 /\ s'=[s EXCEPT !.saved=s.issued, !.save="completion"]
FinishSave == /\ s.save="completion" /\ ~s.closed
 /\ s'=[s EXCEPT !.save="idle",
   !.task=IF @="asleep" /\ Policy#"lostWake" THEN "waitCheck" ELSE @,
   !.resumed=@ \/ (s.task="asleep" /\ Policy#"lostWake")]
Crash == /\ ~s.closed /\ ~s.crashUsed
 /\ s'=[s EXCEPT !.phase="opening", !.task="idle", !.owner=FALSE,
   !.published=FALSE, !.crashUsed=TRUE, !.save="idle", !.issued=s.saved,
   !.ready=IF Policy="loseReady" THEN {} ELSE @, !.storageStopped=FALSE]
Close == /\ s.phase="live" /\ ~s.closed /\ s.save="idle"
 /\ (s.item="snapshot" \/ s.task="idle")
 /\ s'=[s EXCEPT !.closed=TRUE, !.task="idle", !.owner=FALSE]

WorkerStep == (\E item \in Objects: Choose(item)) \/ Park \/ Prepare \/ Validate
              \/ Retry \/ WaitCheck \/ Accept \/ Reject \/ FailRejectionWrite \/ ReleaseOwner
StartupStep == Verify \/ StartupDone \/ Publish
Next == WorkerStep \/ StartupStep \/ Materialize \/ PublishAgain \/ DeliverLate
        \/ BeginSave \/ CommitSave \/ FinishSave \/ Crash \/ Close
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(WorkerStep) /\ WF_vars(StartupStep)
                /\ WF_vars(Materialize) /\ WF_vars(CommitSave) /\ WF_vars(FinishSave)
TypeOK == /\ s.phase \in {"opening", "publication", "live"}
 /\ s.task \in {"idle", "prepare", "validate", "commit", "waitCheck", "asleep"}
 /\ s.item \in Objects \cup {"none"}
 /\ (\A k \in {"ready", "parked", "accepted", "rejected", "delivered"}: s[k] \subseteq Objects)
 /\ s.rows \in ((SUBSET {"change", "late"}) \X (0..2))
 /\ s.captured \in ((SUBSET {"change", "late"}) \X (0..2))
 /\ s.save \in {"idle", "work", "completion"}
 /\ s.saved \in 0..2 /\ s.issued \in s.saved..2 /\ s.attempts \in 0..1
 /\ (\A k \in {"verified", "owner", "checked", "published", "crashUsed", "closed", "failedWrite",
               "storageStopped", "publishedBeforeOptional", "requiredBehindOptional", "resumed", "restartedThenSettled"}: s[k] \in BOOLEAN)
QueueAccounted == s.delivered=s.ready \cup s.parked \cup s.accepted \cup s.rejected
PublicationRequired == s.published => "change" \in s.accepted /\ s.verified /\ Scenario#"damage"
PublicationInputs == [][Publish => (s.delivered \cap {"change", "late"}) \subseteq s'.accepted]_vars
PublicationExact == [][Publish => s'.rows = <<s'.accepted \ {"snapshot"}, s'.saved>>]_vars
SnapshotValidated == [][Accept /\ s.item="snapshot" => s.checked]_vars
SnapshotNeutral == [][Accept /\ s.item="snapshot" => s'.rows=s.rows]_vars
AcceptedPreserved == [][s.accepted \subseteq s'.accepted /\ s.saved<=s'.saved]_vars
OptionalEventuallySettles == s.published ~> ("snapshot" \in s.accepted \cup s.rejected \/ s.closed \/ s.storageStopped)
LateEventuallySettles == "late" \in s.delivered ~> ("late" \in s.accepted \/ s.closed)
NeverPublishedBeforeOptional == ~s.publishedBeforeOptional
NeverRequiredBehindOptional == ~s.requiredBehindOptional
NeverRestartedAndSettled == ~s.restartedThenSettled
NeverWaitedAndResumed == ~s.resumed
=============================================================================
