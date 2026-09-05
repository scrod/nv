------------------------- MODULE RepositoryRepairSafety -------------------------
EXTENDS FiniteSets

\* Bounded proposal-5 repair policy.  "base" stands for the required
\* descriptor/genesis closure; "local" and "peer" are two independent leaves.
\* The model distinguishes observing damage, automatic same-root NV Data repair,
\* positive provider-withheld evidence, exact-copy installation, verification,
\* private retained-history-pin persistence, and activation. It does not model errno values,
\* provider disclosure completeness, codecs, or byte-level filesystem durability.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe", "manualRestore", "offerOfflineAnyFailure",
                   "overwriteForeign", "claimIncomplete", "fabricate",
                   "editWithoutClosure", "providerGatesEditing", "staleRoot",
                   "destructiveLocal", "repairBeforeLocal", "providerRevokesEditing",
                   "staleCopy", "staleStore"}
   /\ Scenario \in {"healthy", "providerAbsent", "providerPartial",
                    "providerUnavailable", "providerRemoteNewer",
                    "providerUnmaterialized", "providerForeign", "rootReplaced",
                    "localAbsent", "localPartial", "localUnreadable",
                    "localUnwritable", "bothPartial", "bothMissing", "runningDisclosure",
                    "providerRootRace", "localRootRace", "localStoreRace"}

Objects == {"base", "local", "peer"}
Required == Objects
Entries == {"valid", "absent", "inaccessible", "foreign", "building"}
Phases == {"idle", "building", "verified", "pinned", "active"}

InitialLocal ==
 CASE Scenario \in {"localAbsent", "localRootRace", "localStoreRace"} -> {}
 [] Scenario = "localPartial" \/ Scenario = "bothPartial" -> {"base", "local"}
 [] Scenario = "bothMissing" -> {"base"}
 [] OTHER -> Objects

InitialProvider ==
 CASE Scenario \in {"providerAbsent", "providerRootRace", "providerForeign"} -> {}
 [] Scenario = "providerPartial" -> {"base", "local"}
 [] Scenario = "bothPartial" -> {"base", "peer"}
 [] Scenario = "bothMissing" -> {"base"}
 [] OTHER -> Objects

InitialProviderEntry ==
 CASE Scenario \in {"providerAbsent", "providerRootRace"} -> "absent"
 [] Scenario \in {"providerUnavailable", "providerRemoteNewer",
                   "providerUnmaterialized"} -> "inaccessible"
 [] Scenario = "providerForeign" -> "foreign"
 [] OTHER -> "valid"

InitialLocalEntry ==
 CASE Scenario \in {"localAbsent", "localRootRace", "localStoreRace"} -> "absent"
 [] Scenario = "localUnreadable" -> "inaccessible"
 [] OTHER -> "valid"

VARIABLE s
vars == <<s>>

Init == s = [
 local |-> InitialLocal, provider |-> InitialProvider,
 oldLocal |-> InitialLocal,
 pin |-> IF Scenario \in {"localAbsent", "localRootRace", "localStoreRace"} THEN {} ELSE Required,
 localEntry |-> InitialLocalEntry, providerEntry |-> InitialProviderEntry,
 localReadable |-> Scenario # "localUnreadable",
 localWritable |-> Scenario # "localUnwritable",
 localParentWritable |-> Scenario # "localUnwritable",
 providerReadable |-> Scenario \notin {"providerUnavailable", "providerRemoteNewer",
                                        "providerUnmaterialized"},
 providerWritable |-> Scenario \notin {"providerUnavailable", "providerRemoteNewer",
                                        "providerUnmaterialized"},
 root |-> IF Scenario = "rootReplaced" THEN "different" ELSE "same",
 store |-> "same", activatedWithoutProvider |-> FALSE,
 remotePending |-> Scenario \in {"providerRemoteNewer", "providerUnmaterialized"},
 offlineOffered |-> FALSE, offlineChosen |-> FALSE, created |-> FALSE,
 foreignSeen |-> Scenario = "providerForeign",
 fabricated |-> FALSE,
 localBuild |-> {}, providerBuild |-> {},
 localPhase |-> "idle", providerPhase |-> "idle",
 claimedLocal |-> FALSE, claimedProvider |-> FALSE,
 editing |-> Scenario = "runningDisclosure", providerActive |-> FALSE]

CompleteLocal ==
 /\ s.store = "same" /\ s.localEntry = "valid" /\ s.localReadable /\ s.localWritable
 /\ Required \subseteq s.local /\ s.pin = Required

CompleteProvider ==
 /\ s.root = "same" /\ s.providerEntry = "valid" /\ s.providerReadable
 /\ Required \subseteq s.provider

BeginProviderRestore ==
 /\ s.providerPhase = "idle" /\ s.root = "same"
 /\ CompleteLocal
 /\ ((s.providerEntry = "absent" /\ Policy # "manualRestore")
     \/ (Policy = "overwriteForeign" /\ s.providerEntry = "foreign"))
 /\ s' = [s EXCEPT
      !.providerEntry = "building", !.providerPhase = "building",
      !.providerBuild = {}, !.created = TRUE]

InstallProvider(o) ==
 /\ s.providerPhase = "building" /\ o \notin s.providerBuild
 /\ ((s.root = "same" /\ s.providerWritable) \/ Policy = "staleCopy")
 /\ (o \in s.local \/ Policy = "fabricate")
 /\ s' = [s EXCEPT !.providerBuild = @ \cup {o},
      !.fabricated = @ \/ o \notin s.local]

VerifyProviderRestore ==
 /\ s.providerPhase = "building"
 /\ (Required \subseteq s.providerBuild \/ Policy = "claimIncomplete")
 /\ s' = [s EXCEPT !.providerPhase = "verified"]

ActivateProviderRestore ==
 /\ s.providerPhase = "verified"
 /\ (s.root = "same" \/ Policy = "staleRoot")
 /\ s' = [s EXCEPT !.provider = s.providerBuild,
      !.providerEntry = "valid", !.providerPhase = "active",
      !.claimedProvider = TRUE, !.providerActive = TRUE]

RepublishMissingProvider(o) ==
 /\ s.providerEntry = "valid" /\ s.root = "same"
 /\ s.providerReadable /\ s.providerWritable /\ o \notin s.provider
 /\ (CompleteLocal \/ Policy \in {"repairBeforeLocal", "fabricate"})
 /\ (o \in s.local \/ Policy = "fabricate")
 /\ s' = [s EXCEPT !.provider = @ \cup {o},
      !.fabricated = @ \/ o \notin s.local]

ActivateExistingProvider ==
 /\ ~s.providerActive
 /\ (CompleteProvider
     \/ (Policy = "claimIncomplete" /\ s.providerEntry = "valid")
     \/ (Policy = "staleRoot" /\ s.providerEntry = "valid"
         /\ s.providerReadable /\ Required \subseteq s.provider))
 /\ (s.root = "same" \/ Policy = "staleRoot")
 /\ s' = [s EXCEPT !.claimedProvider = TRUE, !.providerActive = TRUE]

OfferWorkOffline ==
 /\ ~s.offlineOffered /\ ~s.editing
 /\ (s.remotePending \/ (Policy = "offerOfflineAnyFailure"
                         /\ s.providerEntry = "inaccessible"))
 /\ CompleteLocal
 /\ s' = [s EXCEPT !.offlineOffered = TRUE]

ChooseWorkOffline ==
 /\ s.offlineOffered /\ ~s.offlineChosen
 /\ s' = [s EXCEPT !.offlineChosen = TRUE]

BeginLocalRepair ==
 /\ s.localPhase = "idle" /\ s.localParentWritable /\ s.store = "same"
 /\ ~CompleteLocal
 /\ s.root = "same" /\ s.providerEntry = "valid" /\ s.providerReadable
 /\ Required \subseteq ((IF s.localReadable THEN s.oldLocal ELSE {}) \cup s.provider)
 /\ s' = [s EXCEPT !.localPhase = "building", !.localBuild = {},
      !.oldLocal = IF Policy = "destructiveLocal" THEN {} ELSE @]

InstallLocal(o) ==
 /\ s.localPhase = "building" /\ o \notin s.localBuild
 /\ (s.store = "same" \/ Policy = "staleStore")
 /\ ((o \in s.provider /\ s.providerReadable /\ (s.root = "same" \/ Policy = "staleCopy"))
     \/ (s.localReadable /\ o \in s.oldLocal)
     \/ Policy = "fabricate")
 /\ s' = [s EXCEPT !.localBuild = @ \cup {o},
      !.fabricated = @ \/ ~(o \in s.provider \/ (s.localReadable /\ o \in s.oldLocal))]

VerifyLocalRepair ==
 /\ s.localPhase = "building"
 /\ (s.store = "same" \/ Policy = "staleStore")
 /\ (Required \subseteq s.localBuild \/ Policy = "claimIncomplete")
 /\ s' = [s EXCEPT !.localPhase = "verified"]

CommitLocalFrontier ==
 /\ s.localPhase = "verified"
 /\ (s.store = "same" \/ Policy = "staleStore")
 /\ s' = [s EXCEPT !.pin = Required, !.localPhase = "pinned"]

ActivateLocalRepair ==
 /\ s.localPhase = "pinned"
 /\ (s.store = "same" \/ Policy = "staleStore")
 /\ s' = [s EXCEPT !.local = s.localBuild,
      !.localEntry = "valid", !.localReadable = TRUE, !.localWritable = TRUE,
      !.localPhase = "active", !.claimedLocal = TRUE,
      !.activatedWithoutProvider = s.root # "same"]

\* Invalidation can interrupt an already captured repair. Retained private
\* build bytes stay usable after provider loss; new provider reads/writes do not.
InvalidateRoot ==
 /\ Scenario \in {"providerRootRace", "localRootRace"} /\ s.root = "same"
 /\ s' = [s EXCEPT !.root = "different", !.providerActive = FALSE]

InvalidateStore ==
 /\ Scenario = "localStoreRace" /\ s.store = "same"
 /\ s' = [s EXCEPT !.store = "different", !.editing = FALSE]

StartEditing ==
 /\ ~s.editing
 /\ (CompleteLocal \/ Policy = "editWithoutClosure")
 /\ (~s.remotePending \/ s.offlineChosen)
 /\ (Policy # "providerGatesEditing" \/ CompleteProvider)
 /\ s' = [s EXCEPT !.editing = TRUE, !.claimedLocal = TRUE]

DisclosePending ==
 /\ Scenario = "runningDisclosure" /\ ~s.remotePending
 /\ s' = [s EXCEPT !.remotePending = TRUE, !.providerReadable = FALSE,
      !.providerWritable = FALSE, !.providerEntry = "inaccessible",
      !.providerActive = FALSE,
      !.editing = IF Policy = "providerRevokesEditing" THEN FALSE ELSE @]

Next == BeginProviderRestore \/ OfferWorkOffline \/ ChooseWorkOffline
 \/ VerifyProviderRestore \/ ActivateProviderRestore
 \/ VerifyLocalRepair \/ CommitLocalFrontier \/ ActivateLocalRepair
 \/ BeginLocalRepair \/ ActivateExistingProvider \/ StartEditing \/ DisclosePending
 \/ InvalidateRoot \/ InvalidateStore
 \/ (\E o \in Objects: InstallProvider(o) \/ RepublishMissingProvider(o)
                         \/ InstallLocal(o))

Spec == Init /\ [][Next]_vars
FairSpec == Spec
 /\ WF_vars(BeginProviderRestore) /\ WF_vars(OfferWorkOffline)
 /\ WF_vars(VerifyProviderRestore) /\ WF_vars(ActivateProviderRestore)
 /\ WF_vars(BeginLocalRepair) /\ WF_vars(VerifyLocalRepair)
 /\ WF_vars(CommitLocalFrontier) /\ WF_vars(ActivateLocalRepair)
 /\ WF_vars(ActivateExistingProvider) /\ WF_vars(StartEditing)
 /\ \A o \in Objects:
      WF_vars(InstallProvider(o)) /\ WF_vars(RepublishMissingProvider(o))
       /\ WF_vars(InstallLocal(o))

TypeOK ==
 /\ s.local \subseteq Objects /\ s.provider \subseteq Objects
 /\ s.oldLocal \subseteq Objects /\ s.pin \subseteq Objects
 /\ s.localBuild \subseteq Objects /\ s.providerBuild \subseteq Objects
 /\ s.localEntry \in Entries /\ s.providerEntry \in Entries
 /\ s.localPhase \in Phases /\ s.providerPhase \in Phases
 /\ s.root \in {"same", "different"}
 /\ s.store \in {"same", "different"} /\ s.activatedWithoutProvider \in BOOLEAN
 /\ \A f \in {"localReadable", "localWritable",
               "localParentWritable", "providerReadable", "providerWritable",
               "remotePending", "offlineOffered", "offlineChosen", "created",
               "foreignSeen", "fabricated",
               "claimedLocal", "claimedProvider",
               "editing", "providerActive"}: s[f] \in BOOLEAN

NoEditWithoutCompleteLocal == s.editing => CompleteLocal
NoProviderUseWithoutAuthority == s.providerActive => CompleteProvider
ProviderClaimHasKnownClosure == s.claimedProvider => Required \subseteq s.provider
LocalClaimHasKnownClosure == s.claimedLocal =>
  Required \subseteq s.local /\ s.pin = Required
ProviderCreationIsAutomaticLocalRepair == s.created => Scenario \in {"providerAbsent", "providerRootRace"}
ProviderCreationUsesCompleteLocal == s.created => CompleteLocal
WorkOfflineOnlyForWithheldEvidence ==
 (s.offlineOffered \/ s.offlineChosen) => s.remotePending
ForeignEvidenceIsPreserved == s.foreignSeen => s.providerEntry = "foreign"
RepairUsesOnlyExactAvailableBytes == ~s.fabricated
LocalRepairPreservesOldEvidence == s.oldLocal = InitialLocal
ActiveSessionRemainsEditable == Scenario # "runningDisclosure" \/ s.editing
NoActiveSessionOfflinePrompt == Scenario # "runningDisclosure" \/ ~s.offlineOffered

Safety == NoEditWithoutCompleteLocal /\ NoProviderUseWithoutAuthority
 /\ ProviderClaimHasKnownClosure /\ LocalClaimHasKnownClosure
 /\ ProviderCreationIsAutomaticLocalRepair /\ ProviderCreationUsesCompleteLocal
 /\ WorkOfflineOnlyForWithheldEvidence
 /\ ForeignEvidenceIsPreserved
 /\ RepairUsesOnlyExactAvailableBytes /\ LocalRepairPreservesOldEvidence
 /\ ActiveSessionRemainsEditable /\ NoActiveSessionOfflinePrompt

ProviderRepairUsesCompleteLocal == [][
 (s'.provider \ s.provider # {} \/ (~s.created /\ s'.created)) => CompleteLocal
 ]_vars

ProviderEffectsHaveAuthority == [][
 (s'.providerBuild \ s.providerBuild # {} \/ s'.provider \ s.provider # {}
  \/ (~s.created /\ s'.created) \/ (~s.providerActive /\ s'.providerActive))
 => s.root = "same"
]_vars
LocalRepairEffectsHaveStoreAuthority == [][
 (s'.localBuild \ s.localBuild # {} \/
  (s'.localPhase # s.localPhase /\ s'.localPhase \in {"building","verified","pinned","active"}))
 => s.store = "same"
]_vars
LocalCopiesHaveAvailableSource == [][
 \A o \in s'.localBuild \ s.localBuild:
  (s.root = "same" /\ s.providerReadable /\ o \in s.provider)
  \/ (s.localReadable /\ o \in s.oldLocal)
]_vars
RepairEffectsAreFenced == ProviderEffectsHaveAuthority
 /\ LocalRepairEffectsHaveStoreAuthority /\ LocalCopiesHaveAvailableSource

OfflineEditingAvailable == <>s.editing
ProviderRepairCompletes == <>s.claimedProvider
LocalRepairCompletes == <>s.claimedLocal
BidirectionalRepairCompletes == <>(s.claimedLocal /\ s.claimedProvider)

\* False invariants are non-vacuity witnesses and must produce traces.
NeverOfferedWorkOffline == ~s.offlineOffered
NeverChoseWorkOffline == ~s.offlineChosen
NeverBuiltProviderCopy == s.providerBuild = {}
NeverBuiltLocalCopy == s.localBuild = {}
NeverWorkedOffline == ~s.editing
NeverActivatedProvider == ~s.providerActive
NeverContinuedEditingDuringDisclosure == ~(Scenario = "runningDisclosure" /\ s.remotePending /\ s.editing)
NeverInterruptedProviderCopy == ~(s.root = "different" /\ s.providerPhase = "building" /\ s.providerBuild # {})
NeverActivatedFromRetainedBuild == ~s.activatedWithoutProvider
NeverInterruptedStoreCopy == ~(s.store = "different" /\ s.localPhase = "building" /\ s.localBuild # {})
=============================================================================
