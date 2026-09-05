-------------------------- MODULE RepositoryCopySafety --------------------------
EXTENDS Naturals, FiniteSets
\* Repository-only copy of a captured finite inventory, not all application
\* state. History is already encoded; exact bytes/secret availability are
\* abstract input tokens. No live namespace/placeholder/crypto proof is claimed.
CONSTANTS Policy, Scenario
ASSUME Policy \in {"safe","currentOnly","privateRequired"} /\ Scenario = "repository"
History == {"descriptor","genesis","oldEdit","delete","currentEdit"}
Files == {"currentText","unimportedText"}
Inventory == History \cup Files
\* Unpublished local change deliberately cannot be read by the copy command.
PrivateOnly == {"unpublished","preferences"}
VARIABLE s
vars == <<s>>
Init == s = [copied |-> {}, done |-> FALSE]
Copy(o) ==
 /\ ~s.done
 /\ o \in Inventory \ s.copied
 /\ (Policy # "currentOnly" \/ o \in ({"descriptor","genesis","currentEdit"} \cup Files))
 /\ s' = [s EXCEPT !.copied = @ \cup {o}]
Finish ==
 /\ ~s.done
 /\ Policy # "privateRequired"
 /\ (Inventory \subseteq s.copied \/
     (Policy = "currentOnly" /\ ({"descriptor","genesis","currentEdit"} \cup Files) \subseteq s.copied))
 /\ s' = [s EXCEPT !.done = TRUE]
Next == (\E o \in Inventory: Copy(o)) \/ Finish
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Finish) /\ \A o \in Inventory: WF_vars(Copy(o))
TypeOK == s.copied \subseteq Inventory /\ s.done \in BOOLEAN
HistoryNotFlattened == s.done => {"oldEdit","delete"} \subseteq s.copied
AllRepositoryFilesCopied == s.done => History \cup Files \subseteq s.copied
NoPrivatePrerequisite == s.copied \cap PrivateOnly = {}
Safety == HistoryNotFlattened /\ AllRepositoryFilesCopied /\ NoPrivatePrerequisite
RepositoryAloneSuffices == <> s.done
NeverCopiedWithoutPrivateStore == ~(s.done /\ s.copied = Inventory)
=============================================================================
