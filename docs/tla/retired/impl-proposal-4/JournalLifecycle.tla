------------------------- MODULE JournalLifecycle -------------------------
\* Proposal-4 baseline: NOT a proposal-5 segment acceptance model.
\* See Proposal5-Coverage.md for retained requirements and replacement gaps.
EXTENDS Naturals, FiniteSets
\* AUTH-01 / START-01 / ROOT-01 / AV-15 / AV-16. Two local processes contend for
\* the same opened directory object. s.locks represents retained directory
\* lock ownership; s.descriptors contains exposed WAL writers, not root FDs.
\* Lock, bookmark, header and sync results are abstract API
\* inputs; path equality never supplies association. Crash terminates this
\* attempt; restart/replay is checked by the recovery models. There is no
\* child lock file. Replacement/revoke of the root itself is an API/identity
\* boundary, not proved by this stable-object model. QuitSafety checks release.
Processes == {1,2}
IDs == {1,2,3}
Fixtures == {"absent","matching","copied","unknown","invalid","torn"}
VARIABLE s
vars == <<s>>
Init ==
 \E fixture \in Fixtures:
  s = [fixture |-> fixture, locks |-> {}, files |-> IF fixture = "absent" THEN {} ELSE {1},
   used |-> {1}, attempted |-> [p \in Processes |-> {}],
   phase |-> [p \in Processes |-> "idle"], id |-> [p \in Processes |-> 0],
   headerSynced |-> {}, directorySynced |-> {}, descriptors |-> {},
   headerBookmark |-> [i \in IDs |-> 0], created |-> [i \in IDs |-> 0],
   oldCheckpoint |-> {}, oldVerified |-> FALSE,
   recoveryDone |-> fixture \notin {"matching","torn"},
   recoveryDirectoryDurable |-> fixture \notin {"matching","torn"},
   pathRevision |-> 0, associated |-> TRUE, providerReady |-> TRUE,
   session |-> 1, snapshot |-> [p \in Processes |-> 0],
   published |-> {}, admitted |-> FALSE, appended |-> FALSE,
   durable |-> FALSE, crashed |-> FALSE]
Acquire(p) ==
 /\ ~s.crashed /\ s.phase[p] = "idle" /\ s.locks = {}
 /\ s' = [s EXCEPT !.locks = @ \cup {p}, !.phase[p] = "locked"]
RecoverOld ==
 /\ ~s.crashed /\ s.locks # {} /\ s.fixture = "matching" /\ ~s.oldVerified
 /\ s' = [s EXCEPT !.oldCheckpoint = {"old"}, !.oldVerified = TRUE]
UnlinkOld ==
 /\ ~s.crashed /\ s.fixture = "matching" /\ 1 \in s.files
 /\ s.oldVerified /\ s.oldCheckpoint = {"old"}
 /\ s' = [s EXCEPT !.files = @ \ {1}, !.recoveryDone = TRUE]
SyncRecoveryDirectory ==
 /\ ~s.crashed /\ s.recoveryDone /\ ~s.recoveryDirectoryDurable
 /\ s' = [s EXCEPT !.recoveryDirectoryDurable = TRUE]
BurnFailedID(p,i) ==
 /\ ~s.crashed /\ p \in s.locks /\ s.phase[p] = "locked"
 /\ i \notin s.attempted[p]
 /\ s' = [s EXCEPT !.used = @ \cup {i}, !.attempted[p] = @ \cup {i}]
Create(p,i) ==
 /\ ~s.crashed /\ p \in s.locks /\ s.phase[p] = "locked"
 /\ s.recoveryDone /\ s.recoveryDirectoryDurable /\ s.associated
 /\ i \notin s.files /\ i \notin s.used
 /\ s' = [s EXCEPT !.files = @ \cup {i}, !.used = @ \cup {i},
      !.attempted[p] = @ \cup {i}, !.created[i] = @ + 1,
      !.headerBookmark[i] = s.pathRevision, !.id[p] = i, !.phase[p] = "header"]
SyncHeader(p) ==
 /\ ~s.crashed /\ s.phase[p] = "header" /\ s.id[p] \in s.files
 /\ s' = [s EXCEPT !.headerSynced = @ \cup {s.id[p]}, !.phase[p] = "directory"]
SyncDirectory(p) ==
 /\ ~s.crashed /\ s.phase[p] = "directory" /\ s.id[p] \in s.headerSynced
 /\ s' = [s EXCEPT !.directorySynced = @ \cup {s.id[p]}, !.phase[p] = "ready"]
ExposeDescriptor(p) ==
 /\ ~s.crashed /\ s.phase[p] = "ready" /\ p \in s.locks /\ s.associated
 /\ s.id[p] \in s.headerSynced /\ s.id[p] \in s.directorySynced
 /\ s' = [s EXCEPT !.descriptors = @ \cup {p}, !.phase[p] = "editing"]
AdmitEdit(p) ==
 /\ ~s.crashed /\ p \in s.descriptors /\ s.associated /\ ~s.admitted
 /\ s' = [s EXCEPT !.admitted = TRUE]
Append ==
 /\ ~s.crashed /\ s.admitted /\ ~s.appended
 /\ s' = [s EXCEPT !.appended = TRUE]
Barrier ==
 /\ ~s.crashed /\ s.appended /\ ~s.durable
 /\ s' = [s EXCEPT !.durable = TRUE]
MoveSameRoot ==
 /\ ~s.crashed /\ s.pathRevision = 0
 /\ s' = [s EXCEPT !.pathRevision = 1]
LoseAssociation ==
 /\ ~s.crashed /\ s.associated
 /\ s' = [s EXCEPT !.associated = FALSE]
RevalidateAssociation ==
 /\ ~s.crashed /\ ~s.associated
 /\ s' = [s EXCEPT !.associated = TRUE]
ProviderUnavailable ==
 /\ ~s.crashed /\ s.providerReady
 /\ s' = [s EXCEPT !.providerReady = FALSE]
ChangeAuthority ==
 /\ ~s.crashed /\ s.session = 1
 /\ s' = [s EXCEPT !.session = 2, !.providerReady = FALSE]
ValidateAuthority ==
 /\ ~s.crashed /\ ~s.providerReady /\ s.associated
 /\ s' = [s EXCEPT !.providerReady = TRUE]
CaptureProvider(p) ==
 /\ ~s.crashed /\ p \in s.descriptors /\ s.snapshot[p] = 0
 /\ s' = [s EXCEPT !.snapshot[p] = s.session]
PublishProvider(p) ==
 /\ ~s.crashed /\ p \in s.descriptors /\ p \notin s.published
 /\ s.providerReady /\ s.associated /\ s.snapshot[p] = s.session
 /\ s' = [s EXCEPT !.published = @ \cup {p}]
Crash ==
 /\ ~s.crashed
 /\ s' = [s EXCEPT !.crashed = TRUE, !.locks = {}, !.descriptors = {},
      !.appended = IF s.durable THEN @ ELSE FALSE]
Next ==
 (\E p \in Processes:
   Acquire(p) \/ SyncHeader(p) \/ SyncDirectory(p) \/ ExposeDescriptor(p) \/
   AdmitEdit(p) \/ CaptureProvider(p) \/ PublishProvider(p) \/
   (\E i \in IDs: BurnFailedID(p,i) \/ Create(p,i))) \/
 RecoverOld \/ UnlinkOld \/ SyncRecoveryDirectory \/ Append \/ Barrier \/
 MoveSameRoot \/ LoseAssociation \/ RevalidateAssociation \/
 ProviderUnavailable \/ ChangeAuthority \/ ValidateAuthority \/ Crash
Spec == Init /\ [][Next]_vars
TypeOK ==
 /\ s.fixture \in Fixtures /\ s.locks \subseteq Processes
 /\ s.descriptors \subseteq Processes /\ s.files \subseteq IDs /\ s.used \subseteq IDs
 /\ s.created \in [IDs -> 0..2] /\ s.id \in [Processes -> 0..3]
 /\ s.phase \in [Processes -> {"idle","locked","header","directory","ready","editing"}]
 /\ s.headerSynced \subseteq IDs /\ s.directorySynced \subseteq IDs
 /\ s.snapshot \in [Processes -> 0..2] /\ s.session \in 1..2
 /\ s.headerBookmark \in [IDs -> 0..1] /\ s.pathRevision \in 0..1
 /\ s.attempted \in [Processes -> SUBSET IDs] /\ s.published \subseteq Processes
 /\ s.oldCheckpoint \subseteq {"old"}
 /\ \A b \in {s.oldVerified,s.recoveryDone,s.recoveryDirectoryDurable,
      s.associated,s.providerReady,s.admitted,s.appended,s.durable,s.crashed}:
      b \in BOOLEAN
AtMostOneLocalWriter ==
 Cardinality(s.locks) <= 1 /\ s.descriptors \subseteq s.locks
RootLockSpansSession ==
 ~s.crashed => \A p \in Processes:
   s.phase[p] # "idle" => p \in s.locks
DescriptorRequiresDurableAssociatedCreation ==
 \A p \in s.descriptors:
   /\ s.id[p] \in s.files \cap s.headerSynced \cap s.directorySynced
   /\ s.recoveryDone /\ s.recoveryDirectoryDurable
ForeignAndUncertainEvidenceIsUntouched ==
 s.fixture \in {"copied","unknown","invalid","torn"} =>
   1 \in s.files /\ s.created[1] = 0 /\ ~s.oldVerified
UncertainMatchingEvidenceBlocksFreshWAL ==
 s.fixture = "torn" =>
   s.descriptors = {} /\ \A i \in IDs: s.created[i] = 0
IDsAreNeverReused ==
 \A i \in IDs: s.created[i] <= 1
DurableWorkStillHasItsLocalFile ==
 s.durable => s.appended /\ \E p \in Processes:
   s.id[p] \in s.files \cap s.directorySynced
OldCleanupHasActualCoverage ==
 s.fixture = "matching" /\ 1 \notin s.files =>
   s.oldVerified /\ s.oldCheckpoint = {"old"}
FreshCreationNeverUsesBurnedID ==
 [][\A p \in Processes, i \in IDs: Create(p,i) => i \notin s.used]_vars
RootMovesNeverRewriteOpenHeaders ==
 [][MoveSameRoot => UNCHANGED <<s.headerBookmark,s.session,s.files>>]_vars
AdmissionRequiresAssociation ==
 [][\A p \in Processes: AdmitEdit(p) => s.associated]_vars
ProviderPublicationUsesCurrentAuthority ==
 [][\A p \in Processes: PublishProvider(p) =>
   s.associated /\ s.providerReady /\ s.snapshot[p] = s.session]_vars
ProviderStallDoesNotDisableLocalDurability ==
 ~s.crashed /\ ~s.providerReady /\ s.admitted /\ ~s.durable =>
   ENABLED (Append \/ Barrier)
=============================================================================
