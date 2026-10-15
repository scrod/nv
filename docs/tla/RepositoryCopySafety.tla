-------------------------- MODULE RepositoryCopySafety --------------------------
EXTENDS Naturals, FiniteSets
\* Repository-only copy of a captured finite inventory, not all application
\* state. History is already encoded; exact bytes/secret availability are
\* abstract input tokens. No live namespace/placeholder/crypto proof is claimed.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","currentOnly","privateRequired","copyDamaged","hideDamage","repairSource"}
       /\ Scenario \in {"repository","damagedFile","damagedHierarchy"}
History == {"descriptor","genesis","oldEdit","delete","currentEdit"}
Files == {"currentText","unimportedText"}
Inventory == History \cup Files
\* Unpublished local change deliberately cannot be read by the copy command.
PrivateOnly == {"unpublished","preferences"}
Damage == CASE Scenario = "damagedFile" -> {"oldEdit"}
            [] Scenario = "damagedHierarchy" -> History
            [] OTHER -> {}
Saved == IF Scenario = "repository" THEN {} ELSE History
VARIABLE s
vars == <<s>>
Init == s = [copied |-> {}, damagedCopy |-> {}, reported |-> {},
             sourceDamage |-> Damage, done |-> FALSE]
Copy(o) ==
 /\ ~s.done
 /\ o \in Inventory \ s.reported
 /\ o \notin s.copied \/ o \in Damage
 /\ (Policy # "currentOnly" \/ o \in ({"descriptor","genesis","currentEdit"} \cup Files))
 /\ IF o \in Damage THEN
       /\ s' = [s EXCEPT
                   !.reported = @ \cup {o},
                   !.damagedCopy = IF Policy = "copyDamaged" /\ o \notin s.copied THEN @ \cup {o} ELSE @,
                   !.sourceDamage = IF Policy = "repairSource" THEN @ \ {o} ELSE @]
     ELSE s' = [s EXCEPT !.copied = @ \cup {o}]
\* Exact verified local objects reserve canonical destination names. Source
\* damage is reported and preserved, independently of destination editability.
InstallSaved(o) ==
 /\ ~s.done
 /\ o \in Saved \ (s.copied \cup s.damagedCopy)
 /\ s' = [s EXCEPT !.copied = @ \cup {o}]
Finish ==
 /\ ~s.done
 /\ Policy # "privateRequired"
 /\ Damage \subseteq s.reported
 /\ ((Inventory \subseteq s.copied \cup s.reported /\ Saved \subseteq s.copied \cup s.damagedCopy) \/
     (Policy = "currentOnly" /\ ({"descriptor","genesis","currentEdit"} \cup Files) \subseteq s.copied))
 /\ s' = [s EXCEPT !.done = TRUE,
                   !.reported = IF Policy = "hideDamage" THEN {} ELSE @]
Next == (\E o \in Inventory: Copy(o)) \/ (\E o \in Saved: InstallSaved(o)) \/ Finish
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Finish) /\ (\A o \in Inventory: WF_vars(Copy(o)))
                 /\ (\A o \in Saved: WF_vars(InstallSaved(o)))
TypeOK == s.copied \subseteq Inventory /\ s.done \in BOOLEAN
          /\ s.damagedCopy \subseteq Inventory /\ s.reported \subseteq Inventory
          /\ s.sourceDamage \subseteq Damage
HistoryNotFlattened == s.done => {"oldEdit","delete"} \subseteq s.copied
AllRepositoryFilesCopied == s.done => History \cup Files \subseteq s.copied
NoPrivatePrerequisite == s.copied \cap PrivateOnly = {}
SourceDamagePreserved == s.sourceDamage = Damage
DamageReported == s.done => Damage \subseteq s.reported
ExactHistory == s.done => History \subseteq s.copied /\ s.damagedCopy = {}
Safety == HistoryNotFlattened /\ AllRepositoryFilesCopied /\ NoPrivatePrerequisite
          /\ SourceDamagePreserved /\ DamageReported /\ ExactHistory
RepositoryAloneSuffices == <> s.done
SavedRecoveryCompletes == <> s.done
NeverCopiedWithoutPrivateStore == ~(s.done /\ s.copied = Inventory)
NeverRecoveredWithPreservedDamage == ~(s.done /\ s.copied = Inventory /\ s.reported = Damage /\ Damage # {})
=============================================================================
