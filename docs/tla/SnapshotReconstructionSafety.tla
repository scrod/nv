----------------------- MODULE SnapshotReconstructionSafety -----------------------
EXTENDS Integers, FiniteSets, Sequences

\* Fixed validated graph: two imports, an edit, an independent branch, Delete,
\* and a body-equal continuation. Packing varies independently of logical cuts.
CONSTANTS Mode, SharedEnvelope, DeleteTail, MaxCrashes, Policy
ASSUME Mode \in {"bootstrap", "reconstruction"}
ASSUME SharedEnvelope \in BOOLEAN /\ MaxCrashes \in 0..2
ASSUME DeleteTail \in BOOLEAN
ASSUME Policy \in {"safe", "sequenceTail", "objectTail", "skipTail", "staleInstall", "staleEpoch",
                  "stalePublish", "clearPending", "resetPrivate", "earlyBootstrap"}

Ops == {"G", "I1", "I2", "C", "E", "R", "D", "Q"}
InitialCut == {"G", "I1", "I2", "C"}
SnapshotCut == IF Mode = "bootstrap" THEN InitialCut ELSE InitialCut \cup {"E"}
Parents == [G |-> {}, I1 |-> {"G"}, I2 |-> {"I1"}, C |-> {"I2"},
            E |-> {"C"}, R |-> {"C"}, D |-> {"E"}, Q |-> {"R"}]
Objects == {"initial", "initialPage", "initialRoot", "edits", "remote", "delete", "equal", "snapshot"}
Members(o) == CASE o = "initial" -> InitialCut \cup (IF Mode = "bootstrap" THEN {"E"} ELSE {})
                [] o = "edits" -> {"E"} \cup (IF SharedEnvelope THEN {"R"} ELSE {})
                [] o = "remote" -> {"R"}
                [] o = "delete" -> {"D"}
                [] o = "equal" -> {"Q"}
                [] OTHER -> {}
InitialObjects == {"initial", "initialPage", "initialRoot"}
DeliveredObjects == IF Mode = "bootstrap" THEN InitialObjects \cup {"snapshot"}
                    ELSE Objects \ {IF DeleteTail THEN "equal" ELSE "delete"}
GoalHistory == IF Mode = "bootstrap" THEN Members("initial")
               ELSE Ops \ {IF DeleteTail THEN "Q" ELSE "D"}
Frontier(h) == h \ {p \in Ops : \E c \in h : p \in Parents[c]}

\* Independent value oracle over the complete declared operation set.
ExpectedRows(h) == [a |-> IF "D" \in h THEN "absent" ELSE IF "E" \in h THEN "edited" ELSE "A",
                    b |-> IF "R" \in h \/ "Q" \in h THEN "remote" ELSE "B"]
SeedRows == IF Mode = "bootstrap" THEN [a |-> "A", b |-> "B"] ELSE [a |-> "edited", b |-> "B"]
Update(rows, op) == CASE op = "E" -> [rows EXCEPT !.a = "edited"]
                     [] op = "R" -> [rows EXCEPT !.b = "remote"]
                     [] op = "D" -> [rows EXCEPT !.a = "absent"]
                     [] op = "Q" -> [rows EXCEPT !.b = "remote"]
                     [] OTHER -> rows
RECURSIVE Apply(_, _, _)
Apply(rows, remaining, order) ==
    IF Len(order) = 0 THEN rows
    ELSE Apply(IF Head(order) \in remaining THEN Update(rows, Head(order)) ELSE rows,
               remaining, Tail(order))
RECURSIVE Advance(_, _, _)
Advance(frontier, remaining, order) ==
    IF Len(order) = 0 THEN frontier
    ELSE Advance(IF Head(order) \in remaining THEN (frontier \cup {Head(order)}) \ Parents[Head(order)] ELSE frontier,
                 remaining, Tail(order))

VARIABLES retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
          owner, open, crashes, viewEpoch, installed, prepared, publication, published,
          pending, privateState, stalePublication, observations, manualRebuild
vars == <<retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
          owner, open, crashes, viewEpoch, installed, prepared, publication, published,
          pending, privateState, stalePublication, observations, manualRebuild>>
EmptyView == [history |-> {}, rows |-> [a |-> "absent", b |-> "absent"], frontier |-> {}, through |-> 0]
EmptyToken == [view |-> EmptyView, owner |-> 0, epoch |-> 0]
ViewType == [history : SUBSET Ops, rows : [a : {"A", "edited", "absent"}, b : {"B", "remote", "absent"}],
             frontier : SUBSET Ops, through : 0..8]
PreparedType == [view : ViewType, owner : 1..3, epoch : 0..16]
PublicationType == [view : ViewType, owner : 1..3, epoch : 0..16]
TypeOK == /\ retained \subseteq Objects /\ acceptedObjects \subseteq Objects /\ history \subseteq Ops
          /\ firstSequence \in [Ops -> 0..8] /\ sequence \in 0..8 /\ snapshotSequence \in 0..8
          /\ owner \in 1..3 /\ open \in BOOLEAN /\ crashes \in 0..MaxCrashes /\ viewEpoch \in 0..16
          /\ installed \in ViewType /\ prepared \in PreparedType \cup {EmptyToken}
          /\ publication \in PublicationType \cup {EmptyToken} /\ published \in BOOLEAN
          /\ pending \in BOOLEAN /\ privateState \in {0, 9} /\ stalePublication \in BOOLEAN /\ manualRebuild \in BOOLEAN
          /\ observations \subseteq {"earlyBranch", "sharedGroup", "staleRefused", "sameHistoryEpoch", "twoCrashes"}
Init == /\ retained = {} /\ acceptedObjects = {} /\ history = {}
        /\ firstSequence = [op \in Ops |-> 0] /\ sequence = 0 /\ snapshotSequence = 0
        /\ owner = 1 /\ open = TRUE /\ crashes = 0 /\ viewEpoch = 0
        /\ installed = EmptyView /\ prepared = EmptyToken /\ publication = EmptyToken /\ published = FALSE
        /\ pending = TRUE /\ privateState = 9 /\ stalePublication = FALSE /\ observations = {} /\ manualRebuild = TRUE

Retain(o) == /\ open /\ o \in DeliveredObjects \ retained /\ retained' = retained \cup {o}
             /\ UNCHANGED <<acceptedObjects, history, firstSequence, sequence, snapshotSequence,
                 owner, open, crashes, viewEpoch, installed, prepared, publication, published,
                 pending, privateState, stalePublication, observations, manualRebuild>>

AcceptInitial == /\ open /\ "initialRoot" \notin acceptedObjects
                 /\ (IF Policy = "earlyBootstrap" THEN "initialRoot" \in retained ELSE InitialObjects \subseteq retained)
                 /\ acceptedObjects' = acceptedObjects \cup InitialObjects
                 /\ history' = Members("initial") /\ sequence' = sequence + 1
                 /\ firstSequence' = [op \in Ops |-> IF op \in Members("initial") THEN sequence + 1 ELSE firstSequence[op]]
                 /\ UNCHANGED <<retained, snapshotSequence, owner, open, crashes, viewEpoch,
                      installed, prepared, publication, published, pending, privateState, stalePublication, observations, manualRebuild>>

Accept(o) == /\ open /\ o \in {"edits", "remote", "delete", "equal"} \cap retained
             /\ o \notin acceptedObjects /\ InitialCut \subseteq history
             /\ \A op \in Members(o) : Parents[op] \subseteq history \cup Members(o)
             /\ acceptedObjects' = acceptedObjects \cup {o} /\ history' = history \cup Members(o)
             /\ sequence' = sequence + 1
             /\ firstSequence' = [op \in Ops |-> IF op \in Members(o) \ history THEN sequence + 1 ELSE firstSequence[op]]
             /\ UNCHANGED <<retained, snapshotSequence, owner, open, crashes, viewEpoch,
                  installed, prepared, publication, published, pending, privateState, stalePublication, observations, manualRebuild>>

AcceptSnapshot == /\ open /\ "snapshot" \in retained \ acceptedObjects /\ SnapshotCut \subseteq history
                  /\ acceptedObjects' = acceptedObjects \cup {"snapshot"} /\ sequence' = sequence + 1
                  /\ snapshotSequence' = sequence + 1
                  /\ observations' = observations \cup (IF "R" \in history \ SnapshotCut THEN {"earlyBranch"} ELSE {})
                  /\ UNCHANGED <<retained, history, firstSequence, owner, open, crashes, viewEpoch,
                       installed, prepared, publication, published, pending, privateState, stalePublication, manualRebuild>>

Prepare == /\ open /\ prepared = EmptyToken /\ "initialRoot" \in acceptedObjects
           /\ (installed.through < sequence \/ manualRebuild)
           /\ LET useSnapshot == "snapshot" \in acceptedObjects
                  cut == IF useSnapshot THEN SnapshotCut ELSE InitialCut
                  seed == IF useSnapshot THEN SeedRows ELSE [a |-> "A", b |-> "B"]
                  outside == CASE Policy = "skipTail" -> {}
                                  [] Policy = "sequenceTail" /\ useSnapshot -> {op \in history : firstSequence[op] > snapshotSequence}
                                  [] Policy = "objectTail" /\ useSnapshot -> history \ (cut \cup (IF SharedEnvelope THEN {"R"} ELSE {}))
                                  [] OTHER -> history \ cut
                  rows == Apply(seed, outside, <<"E", "R", "D", "Q">>)
                  frontier == Advance(Frontier(cut), outside, <<"E", "R", "D", "Q">>)
              IN /\ prepared' = [view |-> [history |-> history, rows |-> rows, frontier |-> frontier, through |-> sequence], owner |-> owner, epoch |-> viewEpoch]
                 /\ observations' = observations \cup (IF useSnapshot /\ SharedEnvelope /\ "R" \in outside THEN {"sharedGroup"} ELSE {})
           /\ UNCHANGED <<retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
                owner, open, crashes, viewEpoch, installed, publication, published, pending, privateState, stalePublication, manualRebuild>>

Install == /\ open /\ prepared # EmptyToken /\ prepared.owner = owner
           /\ (Policy = "staleInstall" \/ (prepared.view.through = sequence /\ (Policy = "staleEpoch" \/ prepared.epoch = viewEpoch)))
           /\ installed' = prepared.view /\ viewEpoch' = viewEpoch + 1 /\ prepared' = EmptyToken /\ published' = FALSE
           /\ pending' = IF Policy = "clearPending" THEN FALSE ELSE pending
           /\ privateState' = IF Policy = "resetPrivate" THEN 0 ELSE privateState
           /\ manualRebuild' = IF installed.through = prepared.view.through THEN FALSE ELSE manualRebuild
           /\ observations' = observations \cup (IF installed.history = prepared.view.history /\ viewEpoch > 0 THEN {"sameHistoryEpoch"} ELSE {})
           /\ UNCHANGED <<retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
                owner, open, crashes, publication, stalePublication>>

\* A second verified worker installs the same complete prefix while the first may be suspended.
RebuildSameHistory == /\ open /\ installed.through = sequence /\ viewEpoch > 0 /\ manualRebuild
                     /\ viewEpoch' = viewEpoch + 1 /\ manualRebuild' = FALSE /\ published' = FALSE
                     /\ observations' = observations \cup {"sameHistoryEpoch"}
                     /\ UNCHANGED <<retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
                          owner, open, crashes, installed, prepared, publication, pending, privateState, stalePublication>>

RefuseStale == /\ open /\ prepared # EmptyToken
               /\ (prepared.view.through # sequence \/ prepared.epoch # viewEpoch \/ prepared.owner # owner)
               /\ prepared' = EmptyToken /\ observations' = observations \cup {"staleRefused"}
               /\ UNCHANGED <<retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
                    owner, open, crashes, viewEpoch, installed, publication, published, pending, privateState, stalePublication, manualRebuild>>

Capture == /\ open /\ installed.through = sequence /\ viewEpoch > 0
           /\ publication # [view |-> installed, owner |-> owner, epoch |-> viewEpoch]
           /\ publication' = [view |-> installed, owner |-> owner, epoch |-> viewEpoch]
           /\ UNCHANGED <<retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
                owner, open, crashes, viewEpoch, installed, prepared, published, pending, privateState, stalePublication, observations, manualRebuild>>
Publish == /\ open /\ publication # EmptyToken /\ ~published
           /\ (Policy = "stalePublish" \/ (publication.owner = owner /\ publication.epoch = viewEpoch /\ publication.view.through = sequence))
           /\ published' = TRUE
           /\ stalePublication' = (stalePublication \/ publication.owner # owner \/ publication.epoch # viewEpoch \/ publication.view.through # sequence)
           /\ UNCHANGED <<retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
                owner, open, crashes, viewEpoch, installed, prepared, publication, pending, privateState, observations, manualRebuild>>
Crash == /\ open /\ crashes < MaxCrashes /\ open' = FALSE /\ crashes' = crashes + 1
         /\ prepared' = EmptyToken /\ published' = FALSE
         /\ UNCHANGED <<retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
              owner, viewEpoch, installed, publication, pending, privateState, stalePublication, observations, manualRebuild>>
Reopen == /\ ~open /\ open' = TRUE /\ owner' = owner + 1
          /\ observations' = observations \cup (IF crashes = 2 THEN {"twoCrashes"} ELSE {})
          /\ UNCHANGED <<retained, acceptedObjects, history, firstSequence, sequence, snapshotSequence,
               crashes, viewEpoch, installed, prepared, publication, published, pending, privateState, stalePublication, manualRebuild>>

Next == (\E o \in Objects : Retain(o)) \/ AcceptInitial \/ (\E o \in Objects : Accept(o)) \/ AcceptSnapshot \/
        Prepare \/ Install \/ RebuildSameHistory \/ RefuseStale \/ Capture \/ Publish \/ Crash \/ Reopen
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ (\A o \in Objects : WF_vars(Retain(o))) /\ WF_vars(AcceptInitial) /\
            (\A o \in Objects : WF_vars(Accept(o))) /\ WF_vars(AcceptSnapshot) /\ WF_vars(Prepare) /\
            WF_vars(Install) /\ WF_vars(RefuseStale) /\ WF_vars(Capture) /\ WF_vars(Publish) /\ WF_vars(Reopen)

ExactAcceptance == acceptedObjects \subseteq retained
ClosedHistory == \A op \in history : Parents[op] \subseteq history
CompleteInitial == installed.through > 0 => InitialCut \subseteq installed.history
ExactRows == installed.through > 0 => installed.rows = ExpectedRows(installed.history)
ExactContinuation == installed.through > 0 => installed.frontier = Frontier(installed.history)
PrivatePreserved == privateState = 9
PendingPreserved == pending
PublicationFence == ~stalePublication
HistoryPreserved == [][history \subseteq history']_vars
InstallCurrent == [][Install => installed'.through = sequence /\ prepared.epoch = viewEpoch]_vars
Completes == <> (published /\ history = GoalHistory /\ installed.history = GoalHistory)
NeverEarlyBranch == "earlyBranch" \notin observations
NeverSharedGroup == "sharedGroup" \notin observations
NeverStaleRefused == "staleRefused" \notin observations
NeverSameHistoryEpoch == "sameHistoryEpoch" \notin observations
NeverTwoCrashes == "twoCrashes" \notin observations
=============================================================================
