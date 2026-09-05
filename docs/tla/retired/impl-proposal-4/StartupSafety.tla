------------------------- MODULE StartupSafety -------------------------
\* Proposal-4 baseline: NOT a proposal-5 segment acceptance model.
\* See Proposal5-Coverage.md for retained requirements and replacement gaps.
EXTENDS Naturals, FiniteSets
\* START-01, DISC-01, CKPT-01, WAIT-01. Outcome/ownership model, not a
\* decoder or replacement implementation. API errors remove success paths.
\* One external checkpoint/catalog/session disturbance per startup.
\* "absent" means coordinated checkpoint absence within a positively opened
\* root, never a missing root path or lookup error interpreted as deletion.
Scenarios == {"current","staleComplete","staleMissing","staleUncertain","corrupt","missing",
 "owned","uncertain","recovery","already","mixed","unknownExtension","unreadable"}
Phases == {"classify","materialize","choices","recover","buildChoices",
 "gather","prepared","accessor","installed","accepted","cleanup","fresh",
 "header","editing","blocked","canceled"}
VARIABLE s
vars == <<s>>
\* Also used by bridge models to start ordinary startup from actual artifacts.
Initial(c,provider) ==
  [scenario |-> c, provider |-> provider, phase |-> "classify",
   status |-> IF c \in {"missing","owned"} THEN "absent"
              ELSE IF c \in {"staleComplete","staleMissing","staleUncertain"} THEN "stale"
              ELSE IF c \in {"corrupt","mixed","unknownExtension","unreadable"}
                   THEN "invalid" ELSE "current",
   bytesGood |-> c \in {"current","staleComplete","staleUncertain","uncertain","recovery","already"},
   walKind |-> IF c \in {"uncertain","staleUncertain"} THEN "uncertain"
              ELSE IF c \in {"recovery","already"} THEN "valid" ELSE "none",
   walExists |-> c \in {"uncertain","staleUncertain","recovery","already"},
   owned |-> c = "owned", consent |-> FALSE, failedMaterialization |-> FALSE,
   offline |-> FALSE, source |-> "none", store |-> {}, recovered |-> FALSE,
   derived |-> FALSE, walSettled |-> FALSE, filesSettled |-> FALSE,
   expected |-> 0, current |-> IF c \in {"missing","owned"} THEN 0 ELSE 1,
   changedCheckpoint |-> FALSE, catalog |-> 0, capturedCatalog |-> 0,
   root |-> 0, capturedRoot |-> 0, selected |-> {1,2}, read |-> {},
   decoderChosen |-> c # "unknownExtension", target |-> "none",
   disclosure |-> FALSE, accepted |-> FALSE,
   checkpoint |-> IF c = "already" THEN {1,2} ELSE {1},
   verified |-> FALSE, cleanupDurable |-> c \notin {"uncertain","staleUncertain","recovery","already"},
   headerDurable |-> FALSE, freshDirectoryDurable |-> FALSE,
   cancelRequested |-> FALSE]
Init == \E c \in Scenarios, provider \in BOOLEAN: s = Initial(c,provider)
Classify ==
 /\ s.phase = "classify"
 /\ s' = [s EXCEPT !.phase =
     IF s.status = "current" /\ s.bytesGood THEN "recover"
     ELSE IF s.status = "stale" THEN "materialize" ELSE "choices",
     !.source = IF s.status = "current" /\ s.bytesGood THEN "checkpoint" ELSE @,
     !.store = IF s.status = "current" /\ s.bytesGood THEN s.checkpoint ELSE @,
     !.expected = s.current, !.capturedRoot = s.root]
Materialize ==
 /\ s.phase = "materialize"
 /\ s' = [s EXCEPT !.bytesGood = TRUE, !.status = "current",
      !.source = "checkpoint", !.store = {1}, !.expected = s.current,
      !.capturedRoot = s.root, !.phase = "recover"]
MaterializationFails ==
 /\ s.phase = "materialize"
 /\ s' = [s EXCEPT !.failedMaterialization = TRUE, !.phase = "choices"]
WorkOffline ==
 /\ s.phase = "choices" /\ s.failedMaterialization
 /\ s.bytesGood /\ s.walKind # "uncertain"
 /\ s' = [s EXCEPT !.offline = TRUE, !.source = "checkpoint",
      !.store = s.checkpoint, !.expected = s.current, !.capturedRoot = s.root,
      !.phase = "recover"]
Recover ==
 /\ s.phase = "recover" /\ s.walKind # "uncertain"
 /\ s' = [s EXCEPT !.recovered = TRUE,
      !.store = IF s.walKind = "valid" THEN @ \cup {2} ELSE @,
      !.derived = s.scenario = "recovery",
      !.accepted = s.scenario # "recovery",
      !.phase = IF s.scenario = "recovery" THEN "prepared" ELSE "accepted"]
RejectUncertainWAL ==
 /\ s.phase = "recover" /\ s.walKind = "uncertain"
 /\ s' = [s EXCEPT !.phase = "blocked"]
ConsentCreate ==
 /\ s.phase = "choices" /\ s.status = "absent" /\ ~s.consent
 /\ s' = [s EXCEPT !.consent = TRUE]
Create ==
 /\ s.phase = "choices" /\ s.status = "absent" /\ (s.owned \/ s.consent)
 /\ s.walKind = "none"
 /\ s' = [s EXCEPT !.source = "create", !.store = {}, !.recovered = TRUE,
      !.expected = 0, !.capturedRoot = s.root, !.phase = "prepared"]
BeginRebuild ==
 /\ s.phase = "choices" /\ ~s.bytesGood /\ s.walKind = "none"
 /\ s' = [s EXCEPT !.source = "rebuild", !.expected = s.current,
      !.capturedRoot = s.root, !.phase = "buildChoices", !.recovered = TRUE]
ChooseDecoder(keepUnknown) ==
 /\ s.phase = "buildChoices" /\ ~s.decoderChosen
 /\ s' = [s EXCEPT !.decoderChosen = TRUE,
      !.selected = IF keepUnknown THEN {1,2} ELSE {1}]
ChooseFormat(format) ==
 /\ s.phase = "buildChoices" /\ s.target = "none"
 /\ format \in IF s.provider THEN {"plaintext"}
       ELSE IF s.scenario = "mixed" THEN {"plaintext","rtf"} ELSE {"rtf"}
 /\ s' = [s EXCEPT !.target = format]
DiscloseConversion ==
 /\ s.phase = "buildChoices" /\ ~s.disclosure
 /\ s' = [s EXCEPT !.disclosure = TRUE]
Gather ==
 /\ s.phase = "buildChoices" /\ s.decoderChosen /\ s.target # "none"
 /\ (s.target = "plaintext" => s.disclosure)
 /\ s' = [s EXCEPT !.capturedCatalog = s.catalog, !.phase = "gather"]
ReadFile(n) ==
 /\ s.phase = "gather" /\ n \in s.selected \ s.read
 /\ ~(s.scenario = "unreadable" /\ n = 2)
 /\ s' = [s EXCEPT !.read = @ \cup {n}]
FinishRebuild ==
 /\ s.phase = "gather" /\ s.read = s.selected
 /\ s.catalog = s.capturedCatalog /\ s.root = s.capturedRoot
 /\ s' = [s EXCEPT !.store = s.read, !.phase = "prepared"]
SettleWAL ==
 /\ s.phase = "prepared" /\ ~s.walSettled
 /\ s' = [s EXCEPT !.walSettled = TRUE]
SettleFiles ==
 /\ s.phase = "prepared" /\ ~s.filesSettled
 /\ s' = [s EXCEPT !.filesSettled = TRUE]
BeginInstall ==
 /\ s.phase = "prepared" /\ s.walSettled /\ s.filesSettled
 /\ s' = [s EXCEPT !.phase = "accessor"]
Install ==
 /\ s.phase = "accessor" /\ ~s.cancelRequested
 /\ s.current = s.expected /\ s.root = s.capturedRoot
 /\ (s.source = "rebuild" => s.catalog = s.capturedCatalog)
 /\ s' = [s EXCEPT !.checkpoint = s.store, !.current = 3, !.phase = "installed"]
RejectChanged ==
 /\ s.phase = "accessor" /\ ~s.cancelRequested
 /\ (s.current # s.expected \/ s.root # s.capturedRoot \/
       (s.source = "rebuild" /\ s.catalog # s.capturedCatalog))
 /\ s' = [s EXCEPT !.phase = "blocked"]
Verify ==
 /\ s.phase = "installed" /\ s.current = 3 /\ s.checkpoint = s.store
 /\ s.root = s.capturedRoot
 /\ s' = [s EXCEPT !.verified = TRUE, !.accepted = TRUE, !.phase = "accepted"]
CleanupOldWAL ==
 /\ s.phase = "accepted" /\ s.accepted /\ s.recovered
 /\ (~s.derived \/ s.verified)
 /\ s' = [s EXCEPT !.walExists = FALSE, !.phase = "cleanup"]
SyncCleanup ==
 /\ s.phase = "cleanup"
 /\ s' = [s EXCEPT !.cleanupDurable = TRUE, !.phase = "fresh"]
CreateFresh ==
 /\ s.phase = "fresh" /\ s.accepted /\ s.cleanupDurable /\ ~s.walExists
 /\ s' = [s EXCEPT !.phase = "header"]
SyncFreshHeader ==
 /\ s.phase = "header" /\ ~s.headerDurable
 /\ s' = [s EXCEPT !.headerDurable = TRUE]
SyncFreshDirectory ==
 /\ s.phase = "header" /\ s.headerDurable /\ ~s.freshDirectoryDurable
 /\ s' = [s EXCEPT !.freshDirectoryDurable = TRUE]
EnableEditing ==
 /\ s.phase = "header" /\ s.headerDurable /\ s.freshDirectoryDurable
 /\ s.root = s.capturedRoot
 /\ s' = [s EXCEPT !.phase = "editing"]
ReplaceCheckpoint ==
 /\ ~s.changedCheckpoint /\ s.phase \notin {"editing","canceled"}
 /\ s' = [s EXCEPT !.changedCheckpoint = TRUE, !.current = 2]
ChangeCatalog ==
 /\ s.catalog = 0 /\ s.phase \in {"gather","prepared","accessor"}
 /\ s' = [s EXCEPT !.catalog = 1]
ChangeRootSession ==
 /\ s.root = 0 /\ s.phase \notin {"editing","canceled"}
 /\ s' = [s EXCEPT !.root = 1]
Cancel ==
 /\ s.phase \notin {"editing","canceled"} /\ ~s.cancelRequested
 /\ s' = [s EXCEPT !.cancelRequested = TRUE,
      !.phase = IF s.phase = "accessor" THEN @ ELSE "canceled"]
ReturnCanceledAccessor ==
 /\ s.phase = "accessor" /\ s.cancelRequested
 /\ s' = [s EXCEPT !.phase = "canceled"]
Next == Classify \/ Materialize \/ MaterializationFails \/ WorkOffline \/
 Recover \/ RejectUncertainWAL \/ ConsentCreate \/ Create \/ BeginRebuild \/
 (\E keep \in BOOLEAN: ChooseDecoder(keep)) \/
 (\E f \in {"plaintext","rtf"}: ChooseFormat(f)) \/ DiscloseConversion \/
 Gather \/ (\E n \in {1,2}: ReadFile(n)) \/ FinishRebuild \/ SettleWAL \/
 SettleFiles \/ BeginInstall \/ Install \/ RejectChanged \/ Verify \/
 CleanupOldWAL \/ SyncCleanup \/ CreateFresh \/ SyncFreshHeader \/
 SyncFreshDirectory \/ EnableEditing \/ ReplaceCheckpoint \/ ChangeCatalog \/
 ChangeRootSession \/ Cancel \/ ReturnCanceledAccessor
Spec == Init /\ [][Next]_vars
TypeOK ==
 /\ s.scenario \in Scenarios /\ s.phase \in Phases
 /\ s.store \subseteq {1,2} /\ s.read \subseteq {1,2}
 /\ s.selected \subseteq {1,2} /\ s.checkpoint \subseteq {1,2}
 /\ s.current \in 0..3 /\ s.expected \in 0..3
 /\ s.root \in 0..1 /\ s.capturedRoot \in 0..1
 /\ s.catalog \in 0..1 /\ s.capturedCatalog \in 0..1
 /\ s.source \in {"none","checkpoint","create","rebuild"}
 /\ s.target \in {"none","plaintext","rtf"}
 /\ s.status \in {"absent","stale","invalid","current"}
 /\ s.walKind \in {"none","valid","uncertain"}
 /\ \A b \in {s.provider,s.bytesGood,s.walExists,s.owned,s.consent,
      s.failedMaterialization,s.offline,s.recovered,s.derived,s.walSettled,
      s.filesSettled,s.changedCheckpoint,s.decoderChosen,s.disclosure,
      s.accepted,s.verified,s.cleanupDurable,s.headerDurable,
      s.freshDirectoryDurable,s.cancelRequested}: b \in BOOLEAN
OfflineRequiresCompleteInputs ==
 s.offline => s.failedMaterialization /\ s.bytesGood /\ s.walKind # "uncertain"
EditingRequiresCompleteDurableStartup ==
 s.phase = "editing" =>
   /\ s.accepted /\ s.recovered /\ s.walKind # "uncertain"
   /\ s.headerDurable /\ s.freshDirectoryDurable /\ s.cleanupDurable
   /\ ~s.walExists /\ s.root = s.capturedRoot
   /\ (s.source \in {"create","rebuild"} \/ s.derived => s.verified)
   /\ (s.source = "checkpoint" =>
         s.store = IF s.walKind = "valid" THEN {1,2} ELSE {1})
   /\ (s.source = "rebuild" => s.store = s.selected)
UncertainRecoveryNeverDisappears ==
 s.walKind = "uncertain" => s.walExists /\ ~s.headerDurable
CreationRequiresConsentOrExclusiveOwnership ==
 [][Create => s.owned \/ s.consent]_vars
EveryInstallUsesExactCurrent ==
 [][Install => s.current = s.expected /\ s.root = s.capturedRoot]_vars
RebuildInstallIsCompleteAndCurrent ==
 [][Install /\ s.source = "rebuild" =>
   /\ s.read = s.selected /\ s.decoderChosen /\ s.catalog = s.capturedCatalog
   /\ (s.provider => s.target = "plaintext")
   /\ (s.target = "plaintext" => s.disclosure)]_vars
CurrentChangedNeverWrites ==
 [][RejectChanged => UNCHANGED <<s.checkpoint,s.current>>]_vars
CancellationWaitsForAccessor ==
 [][Cancel /\ s.phase = "accessor" => s'.phase = "accessor"]_vars
=============================================================================
