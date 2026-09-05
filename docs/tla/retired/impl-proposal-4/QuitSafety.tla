------------------------------ MODULE QuitSafety ------------------------------
\* Proposal-4 baseline: NOT a proposal-5 segment acceptance model.
\* See Proposal5-Coverage.md for retained requirements and replacement gaps.
EXTENDS Naturals, FiniteSets
\* DUR-01 / CLEAN-01 / CKPT-01 / WAIT-01. One close operation, one automatic
\* current-change retry, one callback and one external-editor final read.
\* current is the FULL same-accessor witness; same bytes/version identifier
\* can have a different filesystem observation. Provider upload is absent.
\* rootLocked is the retained directory-descriptor lock, distinct from the
\* WAL descriptor. RemovePresenter abstracts completed observer/operation
\* draining, including vnode cancellation; only then may the root owner close.
VARIABLE s
vars == <<s>>
Init ==
 \E metadataDirty \in BOOLEAN, notePending \in BOOLEAN:
  s = [phase |-> "running", note |-> IF notePending THEN 1 ELSE 0,
   metadataDirty |-> metadataDirty, walDurable |-> 0, fileInstalled |-> 0,
   wal |-> TRUE, walRecords |-> FALSE, descriptor |-> TRUE, rootLocked |-> TRUE,
   callbacks |-> 0, serviced |-> 0, dirty |-> FALSE, externalPending |-> TRUE,
   frozenNote |-> 0, frozenMetadata |-> FALSE, frozenCallbacks |-> 0,
   expected |-> 0, current |-> 0, replacements |-> 0, attempt |-> 0,
   invoked |-> {}, installs |-> 0, remoteNeeded |-> FALSE,
   remoteDurable |-> FALSE, remoteFile |-> FALSE,
   cpNote |-> 0, cpMetadata |-> FALSE, cpRemote |-> FALSE,
   verified |-> FALSE, emptyCleanup |-> FALSE, directoryDurable |-> FALSE,
   presenter |-> TRUE, rootAvailable |-> TRUE, override |-> FALSE]
Settled ==
 s.walDurable = s.note /\ s.fileInstalled = s.note /\
 (~s.remoteNeeded \/ (s.remoteDurable /\ s.remoteFile))
BeginClose ==
 /\ s.phase = "running"
 /\ s' = [s EXCEPT !.phase = "drain"]
FinalExternalRead ==
 /\ s.phase = "drain" /\ s.externalPending
 /\ s' = [s EXCEPT !.externalPending = FALSE, !.note = @ + 1]
CallbackArrives ==
 /\ s.phase \in {"running","drain","frozen"} /\ s.callbacks = 0
 /\ s' = [s EXCEPT !.callbacks = 1, !.dirty = TRUE]
ServiceCallback ==
 /\ s.phase = "drain" /\ s.serviced < s.callbacks /\ s.presenter
 /\ s' = [s EXCEPT !.serviced = s.callbacks, !.note = @ + 1, !.dirty = FALSE]
NoExternalChanges ==
 /\ s.phase = "drain" /\ s.externalPending
 /\ s' = [s EXCEPT !.externalPending = FALSE]
SettleWAL ==
 /\ s.phase \in {"running","drain","frozen"} /\ s.walDurable # s.note
 /\ s' = [s EXCEPT !.walDurable = s.note, !.walRecords = TRUE]
SettleFiles ==
 /\ s.phase \in {"running","drain","frozen"} /\ s.fileInstalled # s.note
 /\ s' = [s EXCEPT !.fileInstalled = s.note]
SettleRetirementWAL ==
 /\ s.phase = "drain" /\ s.remoteNeeded /\ ~s.remoteDurable
 /\ s' = [s EXCEPT !.remoteDurable = TRUE, !.walRecords = TRUE]
SettleRemoteFiles ==
 /\ s.phase = "drain" /\ s.remoteNeeded /\ ~s.remoteFile
 /\ s' = [s EXCEPT !.remoteFile = TRUE]
FreezeBarrier ==
 /\ s.phase = "drain" /\ ~s.externalPending /\ s.serviced = s.callbacks
 /\ ~s.dirty /\ s.presenter /\ s.rootAvailable
 /\ s' = [s EXCEPT !.phase = "frozen", !.frozenNote = s.note,
      !.frozenMetadata = s.metadataDirty, !.frozenCallbacks = s.callbacks]
RepeatBarrier ==
 /\ s.phase = "frozen" /\ (s.dirty \/ s.callbacks # s.frozenCallbacks)
 /\ s' = [s EXCEPT !.phase = "drain"]
EmptyClose ==
 /\ s.phase = "frozen" /\ Settled /\ ~s.dirty
 /\ s.callbacks = s.frozenCallbacks /\ s.rootAvailable
 /\ ~s.walRecords /\ ~s.metadataDirty /\ ~s.remoteNeeded
 /\ s' = [s EXCEPT !.emptyCleanup = TRUE, !.phase = "cleanup"]
InvokeCheckpoint ==
 /\ s.phase = "frozen" /\ Settled /\ ~s.dirty /\ s.rootAvailable
 /\ s.callbacks = s.frozenCallbacks
 /\ (s.walRecords \/ s.metadataDirty \/ s.remoteNeeded)
 /\ s.attempt \notin s.invoked
 /\ s' = [s EXCEPT !.invoked = @ \cup {s.attempt}, !.phase = "accessor"]
InstallCheckpoint ==
 /\ s.phase = "accessor" /\ s.rootAvailable /\ s.current = s.expected
 /\ Settled /\ s.frozenNote = s.note /\ s.frozenMetadata = s.metadataDirty
 /\ s' = [s EXCEPT !.phase = "installed", !.installs = @ + 1,
      !.cpNote = s.note, !.cpMetadata = s.metadataDirty,
      !.cpRemote = s.remoteNeeded, !.current = 3]
CurrentChanged ==
 /\ s.phase = "accessor" /\ s.rootAvailable /\ s.current # s.expected
 /\ s' = [s EXCEPT
      !.phase = IF s.attempt = 0 THEN "drain" ELSE "paused",
      !.expected = s.current, !.attempt = 1,
      !.remoteNeeded = TRUE]
PossibleInstallFailure ==
 /\ s.phase = "accessor"
 /\ s' = [s EXCEPT !.phase = "paused"]
Verify ==
 /\ s.phase = "installed" /\ s.current = 3 /\ s.rootAvailable
 /\ s.cpNote = s.note /\ s.cpMetadata = s.metadataDirty
 /\ s.cpRemote = s.remoteNeeded
 /\ s' = [s EXCEPT !.verified = TRUE, !.phase = "cleanup"]
FailedReadback ==
 /\ s.phase = "installed"
 /\ s' = [s EXCEPT !.phase = "paused"]
UnlinkWAL ==
 /\ s.phase = "cleanup" /\ (s.verified \/ s.emptyCleanup)
 /\ s' = [s EXCEPT !.descriptor = FALSE, !.wal = FALSE, !.phase = "unlinked"]
SyncDirectory ==
 /\ s.phase = "unlinked"
 /\ s' = [s EXCEPT !.directoryDurable = TRUE, !.phase = "barrier"]
Override ==
 /\ s.phase \in {"paused","drain","frozen","installed"} /\ ~s.verified
 /\ s' = [s EXCEPT !.override = TRUE, !.descriptor = FALSE, !.phase = "barrier"]
RemovePresenter ==
 /\ s.phase = "barrier" /\ ~s.descriptor
 /\ (s.directoryDurable \/ (s.override /\ s.wal))
 /\ s' = [s EXCEPT !.presenter = FALSE, !.phase = "release"]
ReleaseRootDescriptor ==
 /\ s.phase = "release"
 /\ s' = [s EXCEPT !.rootLocked = FALSE, !.phase = "closed"]
Cancel ==
 /\ s.phase = "paused" /\ s.installs = 0
 /\ s' = [s EXCEPT !.phase = "canceled"]
ReplaceCurrent ==
 /\ s.replacements < 2 /\ s.phase \notin {"closed","crashed","canceled"}
 /\ s' = [s EXCEPT !.replacements = @ + 1, !.current = s.replacements + 1]
LoseRoot ==
 /\ s.rootAvailable /\ s.phase \notin {"closed","crashed","canceled"}
 /\ s' = [s EXCEPT !.rootAvailable = FALSE]
ReentrantQuit ==
 /\ s.phase \notin {"running","crashed"}
 /\ UNCHANGED s
WillTerminate ==
 /\ s.phase = "closed" /\ UNCHANGED s
Crash ==
 /\ s.phase \notin {"closed","crashed","canceled"}
 /\ \E remains \in IF s.phase = "unlinked" THEN BOOLEAN ELSE {s.wal}:
      s' = [s EXCEPT !.phase = "crashed", !.wal = remains,
           !.descriptor = FALSE, !.presenter = FALSE, !.rootLocked = FALSE]
Next == BeginClose \/ FinalExternalRead \/ NoExternalChanges \/ CallbackArrives \/
 ServiceCallback \/ SettleWAL \/ SettleFiles \/ SettleRetirementWAL \/
 SettleRemoteFiles \/ FreezeBarrier \/ RepeatBarrier \/ EmptyClose \/
 InvokeCheckpoint \/ InstallCheckpoint \/ CurrentChanged \/ PossibleInstallFailure \/
 Verify \/ FailedReadback \/ UnlinkWAL \/ SyncDirectory \/ Override \/
 RemovePresenter \/ ReleaseRootDescriptor \/ Cancel \/ ReplaceCurrent \/ LoseRoot \/ ReentrantQuit \/
 WillTerminate \/ Crash
Spec == Init /\ [][Next]_vars
TypeOK ==
 /\ s.phase \in {"running","drain","frozen","accessor","installed","paused",
      "cleanup","unlinked","barrier","release","closed","canceled","crashed"}
 /\ s.note \in 0..3 /\ s.walDurable \in 0..3 /\ s.fileInstalled \in 0..3
 /\ s.cpNote \in 0..3 /\ s.current \in 0..3 /\ s.expected \in 0..3
 /\ s.attempt \in 0..1 /\ s.invoked \subseteq {0,1}
 /\ s.installs \in 0..2 /\ s.replacements \in 0..2
 /\ s.callbacks \in 0..1 /\ s.serviced \in 0..1
 /\ s.frozenNote \in 0..3 /\ s.frozenCallbacks \in 0..1
 /\ \A b \in {s.metadataDirty,s.wal,s.walRecords,s.descriptor,s.dirty,
      s.externalPending,s.frozenMetadata,s.remoteNeeded,s.remoteDurable,
      s.remoteFile,s.cpMetadata,s.cpRemote,s.verified,s.emptyCleanup,
      s.directoryDurable,s.presenter,s.rootAvailable,s.override,s.rootLocked}: b \in BOOLEAN
AtMostOneInstallationPerClose == s.installs <= 1
WALRemovalHasActualCheckpointOrEmptyProof ==
 ~s.wal =>
   (s.verified /\ s.cpNote = s.note /\ s.cpMetadata = s.metadataDirty /\
       s.cpRemote = s.remoteNeeded) \/
   (s.emptyCleanup /\ s.note = 0 /\ ~s.metadataDirty /\ ~s.remoteNeeded)
DurableLocalWorkRemainsRecoverable ==
 s.wal \/ (s.cpNote >= s.walDurable /\ (~s.remoteDurable \/ s.cpRemote))
TerminalCleanupIsDirectoryDurable ==
 s.phase = "closed" => ~s.presenter /\ ~s.descriptor /\
   (s.directoryDurable \/ (s.override /\ s.wal))
UnverifiedOverridePreservesWAL == s.override => s.wal
RootLockSpansClose ==
 s.rootLocked = (s.phase \notin {"closed","crashed"})
RootLockReleaseFollowsLocalClose ==
 [][(s.rootLocked /\ ~s'.rootLocked /\ s'.phase # "crashed") =>
   s.phase = "release" /\ ~s.presenter /\ ~s.descriptor /\
   (s.directoryDurable \/ (s.override /\ s.wal))]_vars
EmptyCloseRequiresAllCheckpointScopedStateUnchanged ==
 [][EmptyClose => ~s.metadataDirty /\ s.note = 0 /\ ~s.remoteNeeded]_vars
EveryInstallUsesExactSettledLiveInput ==
 [][InstallCheckpoint =>
   /\ s.current = s.expected /\ s.rootAvailable
   /\ s.walDurable = s.note /\ s.fileInstalled = s.note
   /\ (s.remoteNeeded => s.remoteDurable /\ s.remoteFile)
   /\ s.frozenNote = s.note /\ s.frozenMetadata = s.metadataDirty
   /\ ~s.externalPending /\ s.callbacks = s.serviced /\ ~s.dirty
   /\ s.presenter]_vars
MismatchAndReentryNeverWrite ==
 [][(CurrentChanged \/ ReentrantQuit \/ WillTerminate) =>
   UNCHANGED <<s.cpNote,s.cpMetadata,s.cpRemote,s.installs>>]_vars
SecondMismatchCannotAutomaticallyRetry ==
 [][CurrentChanged /\ s.attempt = 1 => s'.phase = "paused"]_vars
PresenterRemovalFollowsLocalClose ==
 [][RemovePresenter => ~s.descriptor /\
    (s.directoryDurable \/ (s.override /\ s.wal))]_vars
=============================================================================
