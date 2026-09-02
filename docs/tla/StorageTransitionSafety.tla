-------------------- MODULE StorageTransitionSafety --------------------
EXTENDS Naturals, FiniteSets
\* ADR-0011 / DUR-01 / AV-14: independent Keychain, checkpoint, export,
\* and local-WAL durability domains. One crash, one conflicting file input,
\* one observable same-bytes checkpoint replacement. Tokens stand for
\* immutable note states, not filenames or a byte-level merge algorithm.
Modes == {"plaintext","rekey","saveAsEncrypted","saveAsPlaintext"}
Live == {1,2,3}
SaveAs(mode) == mode \in {"saveAsEncrypted","saveAsPlaintext"}
Plain(mode) == mode \in {"plaintext","saveAsPlaintext"}
NeedsKey(mode) == mode \in {"rekey","saveAsEncrypted"}
VARIABLE s
vars == <<s>>
Init ==
 \E mode \in Modes:
  s = [mode |-> mode, phase |-> "running", frozen |-> FALSE,
   source |-> {1,2}, sourceKey |-> "old", oldWAL |-> TRUE,
   oldFilesSettled |-> FALSE, oldVerified |-> FALSE, oldDirectoryDurable |-> FALSE,
   keys |-> {"old","collision"}, burned |-> {"old","collision"},
   targetKey |-> "none", keyValidated |-> FALSE,
   target |-> {}, targetKeyRef |-> "none", targetFormat |-> "none",
   bootstrapVerified |-> FALSE, targetVerified |-> FALSE,
   disclosure |-> FALSE, desired |-> Live, files |-> {},
   catalog |-> 0, capturedCatalog |-> 0, snapshotFiles |-> {},
   version |-> 0, expected |-> 0, replaced |-> FALSE, rootAvailable |-> TRUE,
   freshHeader |-> FALSE, freshDirectory |-> FALSE, published |-> FALSE]
CredentialReady == ~NeedsKey(s.mode) \/ (s.targetKey = "new" /\ s.keyValidated)
Freeze ==
 /\ s.phase = "running"
 /\ s' = [s EXCEPT !.frozen = TRUE,
      !.phase = IF SaveAs(s.mode) THEN "prepare" ELSE "oldDrain"]
SettleOldFiles ==
 /\ s.phase = "oldDrain" /\ ~s.oldFilesSettled
 /\ s' = [s EXCEPT !.oldFilesSettled = TRUE]
InstallOldCheckpoint ==
 /\ s.phase = "oldDrain" /\ s.oldFilesSettled /\ s.rootAvailable
 /\ s.version = s.expected
 /\ s' = [s EXCEPT !.source = Live, !.version = 1, !.expected = 1,
      !.phase = "oldInstalled"]
VerifyOld ==
 /\ s.phase = "oldInstalled" /\ s.version = 1 /\ s.source = Live
 /\ s.rootAvailable
 /\ s' = [s EXCEPT !.oldVerified = TRUE, !.phase = "oldCleanup"]
UnlinkOld ==
 /\ s.phase = "oldCleanup" /\ s.oldVerified
 /\ s' = [s EXCEPT !.oldWAL = FALSE, !.phase = "oldDirectory"]
SyncOldDirectory ==
 /\ s.phase = "oldDirectory"
 /\ s' = [s EXCEPT !.oldDirectoryDurable = TRUE, !.phase = "prepare"]
CollidingKeyAdd ==
 /\ s.phase = "prepare" /\ NeedsKey(s.mode) /\ "collision" \in s.keys
 /\ UNCHANGED s
AddFreshKey ==
 /\ s.phase = "prepare" /\ NeedsKey(s.mode) /\ s.targetKey = "none"
 /\ "new" \notin s.burned /\ "new" \notin s.keys
 /\ s' = [s EXCEPT !.keys = @ \cup {"new"}, !.burned = @ \cup {"new"},
      !.targetKey = "new"]
ReadBackKey ==
 /\ s.phase = "prepare" /\ s.targetKey = "new" /\ "new" \in s.keys
 /\ ~s.keyValidated
 /\ s' = [s EXCEPT !.keyValidated = TRUE]
KeyReadFails ==
 /\ s.phase = "prepare" /\ s.targetKey = "new" /\ ~s.keyValidated
 /\ s' = [s EXCEPT !.phase = "blocked"]
InstallBootstrap ==
 /\ s.phase = "prepare" /\ SaveAs(s.mode) /\ CredentialReady
 /\ s.rootAvailable /\ s.version = s.expected
 /\ s' = [s EXCEPT !.target = Live,
      !.targetKeyRef = IF NeedsKey(s.mode) THEN s.targetKey ELSE "none",
      !.targetFormat = IF NeedsKey(s.mode) THEN "encrypted" ELSE "database",
      !.version = 1, !.expected = 1,
      !.phase = "bootstrapInstalled"]
VerifyBootstrap ==
 /\ s.phase = "bootstrapInstalled" /\ s.version = 1 /\ s.target = Live
 /\ s.rootAvailable
 /\ s' = [s EXCEPT !.bootstrapVerified = TRUE,
      !.targetVerified = ~Plain(s.mode),
      !.phase = IF Plain(s.mode) THEN "convert" ELSE "fresh"]
BeginConversion ==
 /\ s.phase = "prepare" /\ ~SaveAs(s.mode) /\ CredentialReady
 /\ s.oldVerified /\ s.oldDirectoryDurable
 /\ s' = [s EXCEPT !.phase = "convert"]
Disclose ==
 /\ s.phase = "convert" /\ Plain(s.mode) /\ ~s.disclosure
 /\ s' = [s EXCEPT !.disclosure = TRUE]
Export(n) ==
 /\ s.phase = "convert" /\ Plain(s.mode) /\ s.disclosure
 /\ n \in s.desired \ s.files
 /\ s' = [s EXCEPT !.files = @ \cup {n}]
ExternalFileArrives ==
 /\ Plain(s.mode) /\ s.catalog = 0
 /\ s.phase \in {"convert","fenced","targetInstalled"}
 /\ s' = [s EXCEPT !.files = @ \cup {4}, !.catalog = 1]
PreserveExternal ==
 /\ s.phase = "convert" /\ 4 \in s.files /\ 4 \notin s.desired
 /\ s' = [s EXCEPT !.desired = @ \cup {4}]
TakeExportSnapshot ==
 /\ s.phase = "convert"
 /\ (~Plain(s.mode) \/ (s.files = s.desired /\ s.disclosure))
 /\ s' = [s EXCEPT !.capturedCatalog = s.catalog, !.snapshotFiles = s.files,
      !.phase = "fenced"]
RetryExport ==
 /\ s.phase = "fenced" /\ Plain(s.mode)
 /\ (s.catalog # s.capturedCatalog \/ s.files # s.snapshotFiles)
 /\ s' = [s EXCEPT !.phase = "convert"]
InstallTarget ==
 /\ s.phase = "fenced" /\ CredentialReady /\ s.rootAvailable
 /\ s.version = s.expected
 /\ (~Plain(s.mode) \/ (s.catalog = s.capturedCatalog /\
       s.files = s.snapshotFiles /\ s.files = s.desired /\ s.disclosure))
 /\ s' = [s EXCEPT !.target = s.desired,
      !.targetKeyRef = IF NeedsKey(s.mode) THEN s.targetKey ELSE "none",
      !.source = IF SaveAs(s.mode) THEN @ ELSE s.desired,
      !.sourceKey = IF SaveAs(s.mode) THEN @
                   ELSE IF NeedsKey(s.mode) THEN s.targetKey ELSE "none",
      !.targetFormat = IF Plain(s.mode) THEN "plaintext" ELSE "encrypted",
      !.version = 3, !.phase = "targetInstalled"]
VerifyTarget ==
 /\ s.phase = "targetInstalled" /\ s.version = 3 /\ s.rootAvailable
 /\ s.target = s.desired
 /\ (~Plain(s.mode) \/ (s.files = s.snapshotFiles /\ s.catalog = s.capturedCatalog))
 /\ s' = [s EXCEPT !.targetVerified = TRUE, !.phase = "fresh"]
RemoveOldKey ==
 /\ s.targetVerified /\ ~SaveAs(s.mode) /\ "old" \in s.keys
 /\ s.phase \in {"fresh","editing"}
 /\ s' = [s EXCEPT !.keys = @ \ {"old"}]
SyncFreshHeader ==
 /\ s.phase = "fresh" /\ ~s.freshHeader
 /\ s' = [s EXCEPT !.freshHeader = TRUE]
SyncFreshDirectory ==
 /\ s.phase = "fresh" /\ s.freshHeader /\ ~s.freshDirectory
 /\ s' = [s EXCEPT !.freshDirectory = TRUE]
PublishTarget ==
 /\ s.phase = "fresh" /\ s.targetVerified /\ s.freshHeader /\ s.freshDirectory
 /\ s' = [s EXCEPT !.published = TRUE, !.phase = "editing"]
RetireSaveAsSourceWAL ==
 /\ SaveAs(s.mode) /\ s.phase = "editing" /\ s.targetVerified /\ s.oldWAL
 /\ s' = [s EXCEPT !.oldWAL = FALSE]
SyncSaveAsCleanup ==
 /\ SaveAs(s.mode) /\ s.phase = "editing" /\ ~s.oldWAL /\ ~s.oldDirectoryDurable
 /\ s' = [s EXCEPT !.oldDirectoryDurable = TRUE]
ReplaceCheckpoint ==
 /\ ~s.replaced /\ s.phase \notin {"editing","crashed"}
 /\ s' = [s EXCEPT !.replaced = TRUE, !.version = 2]
LoseRoot ==
 /\ s.rootAvailable /\ s.phase \notin {"editing","crashed"}
 /\ s' = [s EXCEPT !.rootAvailable = FALSE]
RejectChangedCheckpoint ==
 /\ s.phase \in {"oldDrain","prepare","fenced"}
 /\ s.version # s.expected
 /\ s' = [s EXCEPT !.phase = "blocked"]
Crash ==
 /\ s.phase # "crashed"
 /\ s' = [s EXCEPT !.phase = "crashed", !.published = FALSE]
Next == Freeze \/ SettleOldFiles \/ InstallOldCheckpoint \/ VerifyOld \/
 UnlinkOld \/ SyncOldDirectory \/ CollidingKeyAdd \/ AddFreshKey \/
 ReadBackKey \/ KeyReadFails \/ InstallBootstrap \/ VerifyBootstrap \/
 BeginConversion \/ Disclose \/ (\E n \in Live \cup {4}: Export(n)) \/
 ExternalFileArrives \/ PreserveExternal \/ TakeExportSnapshot \/ RetryExport \/
 InstallTarget \/ VerifyTarget \/ RemoveOldKey \/ SyncFreshHeader \/
 SyncFreshDirectory \/ PublishTarget \/ RetireSaveAsSourceWAL \/ SyncSaveAsCleanup \/
 ReplaceCheckpoint \/ LoseRoot \/ RejectChangedCheckpoint \/ Crash
Spec == Init /\ [][Next]_vars
TypeOK ==
 /\ s.mode \in Modes
 /\ s.phase \in {"running","oldDrain","oldInstalled","oldCleanup","oldDirectory",
   "prepare","bootstrapInstalled","convert","fenced","targetInstalled",
   "fresh","editing","blocked","crashed"}
 /\ s.source \subseteq Live \cup {4} /\ s.target \subseteq Live \cup {4}
 /\ s.files \subseteq Live \cup {4} /\ s.desired \subseteq Live \cup {4}
 /\ s.keys \subseteq {"old","collision","new"}
 /\ s.sourceKey \in {"old","new","none"} /\ s.targetKeyRef \in {"old","new","none"}
 /\ s.version \in 0..3 /\ s.expected \in 0..3
 /\ s.targetKey \in {"none","new"} /\ s.burned \subseteq {"old","collision","new"}
 /\ s.targetFormat \in {"none","database","plaintext","encrypted"}
 /\ s.catalog \in 0..1 /\ s.capturedCatalog \in 0..1
 /\ s.snapshotFiles \subseteq Live \cup {4}
 /\ \A b \in {s.frozen,s.oldWAL,s.oldFilesSettled,s.oldVerified,
      s.oldDirectoryDurable,s.keyValidated,s.bootstrapVerified,s.targetVerified,
      s.disclosure,s.replaced,s.rootAvailable,s.freshHeader,
      s.freshDirectory,s.published}: b \in BOOLEAN
EveryInstalledCheckpointHasItsCredential ==
 /\ (s.sourceKey # "none" => s.sourceKey \in s.keys)
 /\ (s.targetKeyRef # "none" => s.targetKeyRef \in s.keys /\ s.keyValidated)
LiveWorkAlwaysHasRecoverableArtifact ==
 Live \subseteq s.source \cup s.target \cup (IF s.oldWAL THEN {3} ELSE {})
ForeignAndSaveAsSourceCredentialsAreUntouched ==
 /\ "collision" \in s.keys
 /\ (SaveAs(s.mode) => s.source = {1,2} /\ s.sourceKey = "old" /\ "old" \in s.keys)
SaveAsDestinationCredentialIsIndependent ==
 SaveAs(s.mode) /\ NeedsKey(s.mode) /\ s.target # {} =>
   s.targetKeyRef = "new" /\ s.targetKeyRef # s.sourceKey
OldCredentialDeletionIsPostCommit ==
 "old" \notin s.keys => ~SaveAs(s.mode) /\ s.targetVerified /\
   s.source = s.target /\ s.sourceKey = s.targetKeyRef
EditingUsesOneVerifiedTargetContract ==
 s.published =>
   /\ s.targetVerified /\ s.freshHeader /\ s.freshDirectory
   /\ Live \subseteq s.target
   /\ (Plain(s.mode) => s.targetFormat = "plaintext" /\ s.disclosure)
   /\ (NeedsKey(s.mode) => s.targetKeyRef = "new" /\ s.keyValidated)
DivergentFileEvidenceIsPreserved == s.catalog = 1 => 4 \in s.files
OldWALRemovalHasCoverage ==
 ~s.oldWAL =>
   IF SaveAs(s.mode) THEN s.targetVerified /\ Live \subseteq s.target
   ELSE s.oldVerified /\ Live \subseteq s.source
EveryCheckpointWriteUsesExactCurrent ==
 [][(InstallOldCheckpoint \/ InstallBootstrap \/ InstallTarget) =>
    s.rootAvailable /\ s.version = s.expected]_vars
PlaintextInstallRequiresCompleteStableExport ==
 [][InstallTarget /\ Plain(s.mode) =>
   s.files = s.desired /\ s.files = s.snapshotFiles /\
   s.catalog = s.capturedCatalog /\ s.disclosure]_vars
FreshCredentialPrecedesAnyReference ==
 [][(InstallBootstrap \/ InstallTarget) /\ NeedsKey(s.mode) =>
   s.targetKey = "new" /\ s.keyValidated /\ "new" \in s.keys]_vars
UnverifiedCrashNeverDeletesCredential ==
 [][Crash => UNCHANGED <<s.keys,s.source,s.sourceKey,s.target,s.targetKeyRef>>]_vars
=============================================================================
