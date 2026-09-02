------------------------- MODULE StorageStartupBridge -------------------------
EXTENDS Naturals, FiniteSets
\* ADR-0011 -> START-01. Execute the real bounded transition actions, crash
\* at any boundary, and hand the selected root's actual checkpoint/key/WAL
\* to the ordinary startup actions. No remembered success flag survives as
\* authority. One reopen only; required further conversion ends this check.
VARIABLES t, r, b
vars == <<t,r,b>>
T == INSTANCE StorageTransitionSafety WITH s <- t
S == INSTANCE StartupSafety WITH s <- r
SourceFormat == IF t.sourceKey = "none" THEN "plaintext" ELSE "encrypted"
RootBytes(root) == IF root = "source" THEN t.source ELSE t.target
RootKey(root) == IF root = "source" THEN t.sourceKey ELSE t.targetKeyRef
RootFormat(root) == IF root = "source" THEN SourceFormat ELSE t.targetFormat
RootWAL(root) == IF root = "source" /\ t.oldWAL THEN {3} ELSE {}
DecodedStore == b.bytes \cup (IF 2 \in r.store THEN b.walBytes ELSE {})
Init ==
 /\ T!Init
 /\ r = S!Initial("current",FALSE)
 /\ \E provider \in BOOLEAN:
    b = [phase |-> "transition", root |-> "none", provider |-> provider,
      bytes |-> {}, walBytes |-> {}, key |-> "none", format |-> "none",
      credentialRead |-> FALSE, openedCheckpoint |-> {}, recoveredFiles |-> {},
      reopened |-> {}]
Transition ==
 /\ b.phase = "transition" /\ T!Next
 /\ UNCHANGED <<r,b>>
ReadRoot(root) ==
 /\ b.phase = "transition" /\ t.phase = "crashed"
 /\ root \in {"source","target"} /\ RootBytes(root) # {}
 /\ b' = [b EXCEPT !.phase = "reading", !.root = root,
      !.bytes = RootBytes(root), !.openedCheckpoint = RootBytes(root),
      !.walBytes = RootWAL(root), !.key = RootKey(root), !.format = RootFormat(root)]
 /\ UNCHANGED <<t,r>>
ReadCredential ==
 /\ b.phase = "reading" /\ ~b.credentialRead
 /\ b.key = "none" \/ b.key \in t.keys
 /\ b' = [b EXCEPT !.credentialRead = TRUE]
 /\ UNCHANGED <<t,r>>
CredentialUnavailable ==
 /\ b.phase = "reading" /\ ~b.credentialRead /\ b.key # "none"
 /\ b' = [b EXCEPT !.phase = "blocked"]
 /\ UNCHANGED <<t,r>>
RequireConversion ==
 /\ b.phase = "reading" /\ b.credentialRead
 /\ b.provider /\ b.format # "plaintext"
 /\ b' = [b EXCEPT !.phase = "conversionRequired"]
 /\ UNCHANGED <<t,r>>
BeginStartup ==
 /\ b.phase = "reading" /\ b.credentialRead
 /\ ~b.provider \/ b.format = "plaintext"
 /\ LET scenario == IF b.walBytes = {} THEN "current"
                    ELSE IF b.walBytes \subseteq b.bytes THEN "already"
                    ELSE "recovery"
    IN r' = S!Initial(scenario,b.provider)
 /\ b' = [b EXCEPT !.phase = "startup"]
 /\ UNCHANGED t
StartupLocal ==
 /\ b.phase = "startup"
 /\ (S!Classify \/ S!Recover \/ S!SettleWAL \/ S!BeginInstall \/ S!Verify \/
     S!CleanupOldWAL \/ S!SyncCleanup \/ S!CreateFresh \/ S!SyncFreshHeader \/
     S!SyncFreshDirectory \/ S!ChangeRootSession \/ S!RejectChanged \/
     S!Cancel \/ S!ReturnCanceledAccessor)
 /\ UNCHANGED <<t,b>>
SettleRecoveredFiles ==
 /\ b.phase = "startup" /\ S!SettleFiles
 /\ b' = [b EXCEPT !.recoveredFiles = DecodedStore]
 /\ UNCHANGED t
InstallRecoveredCheckpoint ==
 /\ b.phase = "startup" /\ S!Install
 /\ b' = [b EXCEPT !.openedCheckpoint = DecodedStore]
 /\ UNCHANGED t
StartupCheckpointReplaced ==
 /\ b.phase = "startup" /\ r.phase \in {"prepared","accessor","installed"}
 /\ S!ReplaceCheckpoint
 /\ UNCHANGED <<t,b>>
EnableEditing ==
 /\ b.phase = "startup" /\ S!EnableEditing
 /\ b' = [b EXCEPT !.phase = "done", !.reopened = DecodedStore]
 /\ UNCHANGED t
Next == Transition \/ (\E root \in {"source","target"}: ReadRoot(root)) \/
 ReadCredential \/ CredentialUnavailable \/ RequireConversion \/ BeginStartup \/
 StartupLocal \/ SettleRecoveredFiles \/ InstallRecoveredCheckpoint \/
 StartupCheckpointReplaced \/ EnableEditing
Spec == Init /\ [][Next]_vars
TypeOK ==
 /\ T!TypeOK /\ S!TypeOK
 /\ b.phase \in {"transition","reading","blocked","conversionRequired","startup","done"}
 /\ b.root \in {"none","source","target"}
 /\ b.key \in {"none","old","new"}
 /\ b.format \in {"none","database","plaintext","encrypted"}
 /\ b.provider \in BOOLEAN /\ b.credentialRead \in BOOLEAN
 /\ \A rows \in {b.bytes,b.walBytes,b.openedCheckpoint,b.recoveredFiles,b.reopened}:
      rows \subseteq {1,2,3,4}
TransitionChecks ==
 T!EveryInstalledCheckpointHasItsCredential /\ T!LiveWorkAlwaysHasRecoverableArtifact /\
 T!ForeignAndSaveAsSourceCredentialsAreUntouched /\ T!OldWALRemovalHasCoverage
HandoffUsesActualRootArtifacts ==
 b.root # "none" =>
   b.bytes = RootBytes(b.root) /\ b.walBytes = RootWAL(b.root) /\
   b.key = RootKey(b.root) /\ b.format = RootFormat(b.root)
NoSourceWALTransplant == b.root = "target" => b.walBytes = {}
AcceptedDataHasItsOwnCredential ==
 b.phase \in {"startup","done"} =>
   b.credentialRead /\ b.key = RootKey(b.root) /\
   (b.key = "none" \/ b.key \in t.keys)
ProviderEditingRequiresCompletedConversion ==
 b.phase = "done" /\ b.provider => b.format = "plaintext"
ReopenedDataMatchesCrashArtifacts ==
 b.phase = "done" =>
   b.reopened = RootBytes(b.root) \cup RootWAL(b.root) /\
   b.openedCheckpoint = b.reopened /\ S!EditingRequiresCompleteDurableStartup
RecoveryCheckpointIncludesSettledPayload ==
 [][InstallRecoveredCheckpoint => b.recoveredFiles = DecodedStore]_vars
StartupFencesHold == S!EveryInstallUsesExactCurrent /\ S!CurrentChangedNeverWrites /\
                    S!CancellationWaitsForAccessor
UnverifiedInstalledTargetCanReopen ==
 ~(b.phase = "done" /\ b.root = "target" /\ ~t.targetVerified /\ t.target # {})
OldSourceWALCanReopen ==
 ~(b.phase = "done" /\ b.root = "source" /\ t.oldWAL /\ 3 \notin t.source)
ConvertedProviderCanReopen ==
 ~(b.phase = "done" /\ b.provider /\ b.format = "plaintext")
=============================================================================
