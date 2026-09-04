----------------------- MODULE UUIDAssociationLab -----------------------
EXTENDS Naturals, FiniteSets

\* EXPERIMENTAL identity/intent litmus tests, not production policy.
\* o is EVERYTHING the decision function may inspect. Ground-truth origins
\* and intent live in g and are used ONLY by assertions/environment fixtures.
\* proof="same" means positively revalidated SAME INCARNATION, not equal
\* xattrs, filenames, bytes, or a portable NSFileVersion identifier. No Apple
\* API is assumed to always supply it; unknown fixtures deliberately cannot.
CONSTANT Policy
Policies == {"database","xattr","minimum","fingerprint","aliases",
             "incarnation","omission","evidence","currentSnapshot","providerEquality"}
ASSUME Policy \in Policies
Cases == {"independent", "convergedTag", "unknownSharedTag", "copiedTagNewUUID",
 "copy", "hiddenCopy", "rename",
 "strippedContinuous", "strippedUnknown", "recreated", "edits", "aliasCopy",
 "trash", "trashFirst", "trashEdited", "unexplained", "oldTrash",
 "restored", "restoredThenMissing", "intentUnknown", "purgedTrash",
 "neverSeenCheckpoint", "actualCheckpointDelete", "sameLocalSnapshot"}
Rows == {"L","R"}
BaseObservation == [kind |-> "join", leftID |-> 1, rightID |-> 2,
 leftTag |-> 0, rightTag |-> 0, leftEpoch |-> 0, rightEpoch |-> 0,
 leftName |-> "note", rightName |-> "note", leftBody |-> "text",
 rightBody |-> "text", baseBody |-> "text", proof |-> "unknown",
 globalAliases |-> {}, sourcePresent |-> TRUE, trashPresent |-> FALSE,
 baseContains |-> FALSE, checkpointOmits |-> FALSE,
 leftScope |-> 1, rightScope |-> 2, leftItem |-> 11, rightItem |-> 21,
 sameObservationFrame |-> FALSE]
Observation(c) ==
 CASE c = "sameLocalSnapshot" -> [BaseObservation EXCEPT !.proof = "same",
        !.rightScope = 1, !.rightItem = 11, !.sameObservationFrame = TRUE]
   [] c = "independent" -> [BaseObservation EXCEPT !.proof = "same"]
   [] c = "convergedTag" -> [BaseObservation EXCEPT !.leftTag = 2, !.rightTag = 2,
                            !.proof = "same"]
   [] c \in {"unknownSharedTag","copiedTagNewUUID"} ->
       [BaseObservation EXCEPT !.leftTag = 2, !.rightTag = 2]
   [] c = "copy" -> [BaseObservation EXCEPT !.rightID = 1, !.leftTag = 1,
        !.rightTag = 1, !.leftEpoch = 1, !.rightEpoch = 1,
        !.rightName = "copy", !.proof = "different", !.rightScope = 1,
        !.rightItem = 12, !.sameObservationFrame = TRUE]
   [] c = "hiddenCopy" -> [BaseObservation EXCEPT !.rightID = 1,
        !.leftTag = 1, !.rightTag = 1, !.leftEpoch = 1, !.rightEpoch = 1]
   [] c = "rename" -> [BaseObservation EXCEPT !.rightName = "renamed",
                       !.proof = "same"]
   [] c = "strippedContinuous" -> [BaseObservation EXCEPT !.proof = "same"]
   [] c \in {"strippedUnknown","recreated"} -> BaseObservation
   [] c = "edits" -> [BaseObservation EXCEPT !.leftBody = "editA",
                       !.rightBody = "editB", !.proof = "same"]
   [] c = "aliasCopy" -> [BaseObservation EXCEPT !.rightID = 3,
          !.globalAliases = {1,2,3}, !.proof = "different"]
   [] c \in {"trash","trashEdited","trashFirst"} ->
       [BaseObservation EXCEPT !.kind = "delete", !.proof = "same",
        !.sourcePresent = (c = "trashFirst"), !.trashPresent = TRUE,
        !.leftBody = IF c = "trashEdited" THEN "editA" ELSE "text",
        !.leftTag = 1, !.rightTag = 1, !.leftEpoch = 1, !.rightEpoch = 1]
   [] c = "unexplained" -> [BaseObservation EXCEPT !.kind = "delete",
                             !.sourcePresent = FALSE]
   [] c = "oldTrash" -> [BaseObservation EXCEPT !.kind = "delete",
        !.sourcePresent = FALSE, !.trashPresent = TRUE, !.proof = "different"]
   [] c = "restored" -> [BaseObservation EXCEPT !.kind = "delete",
        !.trashPresent = TRUE, !.rightID = 1, !.leftTag = 1, !.rightTag = 1,
        !.leftEpoch = 2, !.rightEpoch = 1, !.proof = "different"]
   [] c \in {"restoredThenMissing","intentUnknown"} ->
       [BaseObservation EXCEPT !.kind = "delete", !.sourcePresent = FALSE,
        !.trashPresent = TRUE, !.rightID = 1, !.leftTag = 1, !.rightTag = 1,
        !.leftEpoch = 1, !.rightEpoch = 1]
   [] c = "purgedTrash" -> [BaseObservation EXCEPT !.kind = "delete",
                             !.sourcePresent = FALSE]
   [] c \in {"neverSeenCheckpoint","actualCheckpointDelete"} ->
       [BaseObservation EXCEPT !.kind = "delete", !.sourcePresent = FALSE,
        !.baseContains = TRUE, !.checkpointOmits = TRUE]

GroundTruth(c) ==
 [leftOrigin |-> "original",
  rightOrigin |-> IF c \in {"copy","hiddenCopy","copiedTagNewUUID","recreated","aliasCopy",
                           "oldTrash","restored","restoredThenMissing"}
                    THEN "otherIncarnation" ELSE "original",
  intentional |-> c \in {"trash","trashEdited","trashFirst","intentUnknown",
                          "purgedTrash","actualCheckpointDelete"}]

\* Policies have no access to case names, g, or ground-truth origins.
TagID(o,left) == IF left THEN
    IF o.leftTag = 0 THEN o.leftID ELSE o.leftTag
 ELSE IF o.rightTag = 0 THEN o.rightID ELSE o.rightTag
Min(a,b) == IF a <= b THEN a ELSE b
Association(o) ==
 \* Concrete comparison of captured, scope-qualified observations. A remote
 \* checkpoint row is NOT a current observation in this host's capture frame.
 \* This policy never reads proof or fixture ground truth. It deliberately
 \* cannot establish cross-host aliases from the measured host-local IDs.
 CASE Policy = "currentSnapshot" ->
       IF o.sameObservationFrame /\ o.leftScope = o.rightScope /\
          o.leftItem # 0 /\ o.rightItem # 0
       THEN IF o.leftItem = o.rightItem THEN "join" ELSE "separate"
       ELSE "defer"
   [] Policy = "providerEquality" ->
       IF o.leftScope = o.rightScope /\ o.leftItem = o.rightItem THEN "join" ELSE "separate"
   [] Policy = "evidence" ->
       CASE o.proof = "same" -> "join"
         [] o.proof = "different" -> "separate"
         [] OTHER -> "defer"
   [] Policy = "database" -> IF o.leftID = o.rightID THEN "join" ELSE "separate"
   [] Policy = "xattr" -> IF TagID(o,TRUE) = TagID(o,FALSE) THEN "join" ELSE "separate"
   [] Policy = "minimum" ->
       IF Min(o.leftID,TagID(o,TRUE)) = Min(o.rightID,TagID(o,FALSE))
          THEN "join" ELSE "separate"
   [] Policy = "fingerprint" ->
       IF o.leftName = o.rightName /\ o.leftBody = o.rightBody THEN "join" ELSE "separate"
   [] Policy = "aliases" ->
       IF o.leftID = o.rightID \/ {o.leftID,o.rightID} \subseteq o.globalAliases
          THEN "join" ELSE "separate"
   [] Policy = "incarnation" ->
       IF TagID(o,TRUE) = TagID(o,FALSE) /\ o.leftEpoch # 0 /\
          o.leftEpoch = o.rightEpoch THEN "join" ELSE "defer"
   [] OTHER -> IF o.leftID = o.rightID THEN "join" ELSE "separate"
Decide(o) ==
 IF o.kind = "join" THEN Association(o)
 ELSE IF o.sourcePresent THEN "keep"
 ELSE IF Policy = "omission" /\ o.baseContains /\ o.checkpointOmits THEN "delete"
 ELSE IF o.trashPresent /\ Association(o) = "join" THEN "delete"
 ELSE "defer"
Groups(decision,o) ==
 CASE decision = "join" -> {Rows}
   [] decision = "separate" -> {{"L"},{"R"}}
   [] decision = "keep" -> {{"L"}}
   [] decision = "delete" -> IF o.leftBody # o.baseBody THEN {{"L"}} ELSE {}
   [] OTHER -> {}

VARIABLE s
vars == <<s>>
Init == \E c \in Cases:
 s = [case |-> c, o |-> Observation(c), g |-> GroundTruth(c),
      phase |-> "observe", captured |-> BaseObservation,
      fence |-> 0, capturedFence |-> 0, disturbance |-> "none",
      decision |-> "none", groups |-> {}, liveGroups |-> {{"L"}},
      sourceAbsent |-> FALSE, durableGroups |-> {}, checkpoint |-> {{"L"}},
      checkpointDeleted |-> FALSE, dirty |-> TRUE, restarted |-> FALSE]
Capture ==
 /\ s.phase = "observe"
 /\ s' = [s EXCEPT !.phase = "captured", !.captured = s.o,
      !.capturedFence = s.fence]
Prepare ==
 /\ s.phase = "captured"
 /\ s' = [s EXCEPT !.phase = "prepared", !.decision = Decide(s.captured),
      !.groups = Groups(Decide(s.captured),s.captured)]
Interfere(kind) ==
 /\ s.phase \in {"captured","prepared"} /\ s.disturbance = "none"
 /\ kind \in {"edit","replace","restore","checkpoint"}
 /\ s' = [s EXCEPT !.fence = 1, !.disturbance = kind,
      !.o = CASE kind = "edit" -> [s.o EXCEPT !.leftBody = "editLater"]
              [] kind = "restore" -> [s.o EXCEPT !.sourcePresent = TRUE,
                                         !.leftEpoch = 2]
              [] kind = "replace" -> [s.o EXCEPT !.proof = "unknown", !.sameObservationFrame = FALSE,
                                         !.leftTag = 0]
              [] OTHER -> [s.o EXCEPT !.checkpointOmits = ~@]]
Publish ==
 /\ s.phase = "prepared" /\ s.fence = s.capturedFence
 /\ s.decision # "defer"
 /\ s' = [s EXCEPT !.phase = "published", !.liveGroups = s.groups,
      !.sourceAbsent = (s.decision = "delete"), !.dirty = FALSE]
Defer ==
 /\ s.phase = "prepared" /\ s.fence = s.capturedFence
 /\ s.decision = "defer"
 \* No new checkpoint or source deletion. Both captured inputs remain owned;
 \* production must durably preserve them if it offers quit with this pending.
 /\ s' = [s EXCEPT !.phase = "deferred"]
Reject ==
 /\ s.phase = "prepared" /\ s.fence # s.capturedFence
 /\ s' = [s EXCEPT !.phase = "rejected"]
Barrier ==
 /\ s.phase = "published"
 /\ s' = [s EXCEPT !.phase = "durable", !.durableGroups = s.liveGroups]
Install ==
 /\ s.phase = "durable"
 /\ s' = [s EXCEPT !.phase = "installed", !.checkpoint = s.durableGroups,
      !.checkpointDeleted = s.sourceAbsent]
Restart ==
 /\ s.phase = "installed"
 /\ s' = [s EXCEPT !.phase = "reopened", !.restarted = TRUE,
      !.liveGroups = s.checkpoint, !.sourceAbsent = s.checkpointDeleted]
Next == Capture \/ Prepare \/ (\E k \in {"edit","replace","restore","checkpoint"}: Interfere(k))
 \/ Publish \/ Defer \/ Reject \/ Barrier \/ Install \/ Restart
Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Capture) /\ WF_vars(Prepare) /\ WF_vars(Publish)
 /\ WF_vars(Defer) /\ WF_vars(Reject) /\ WF_vars(Barrier) /\ WF_vars(Install)
 /\ WF_vars(Restart)
Published == s.phase \in {"published","durable","installed","reopened"}
TypeOK ==
 /\ s.case \in Cases /\ s.fence \in 0..1 /\ s.capturedFence \in 0..1
 /\ s.phase \in {"observe","captured","prepared","published","durable",
                  "installed","reopened","deferred","rejected"}
 /\ s.decision \in {"none","join","separate","keep","delete","defer"}
 /\ s.groups \subseteq SUBSET Rows /\ s.liveGroups \subseteq SUBSET Rows
 /\ s.durableGroups \subseteq SUBSET Rows /\ s.checkpoint \subseteq SUBSET Rows
 /\ s.sourceAbsent \in BOOLEAN /\ s.checkpointDeleted \in BOOLEAN
 /\ s.dirty \in BOOLEAN /\ s.restarted \in BOOLEAN
 /\ s.o.proof \in {"same","different","unknown"}
 /\ s.captured.proof \in {"same","different","unknown"}
NoFalseJoin == Published /\ s.o.kind = "join" /\ s.g.leftOrigin # s.g.rightOrigin
                 => Rows \notin s.liveGroups
NoFalseSeparation == Published /\ s.o.kind = "join" /\ s.g.leftOrigin = s.g.rightOrigin
                 => s.liveGroups = {Rows}
NoFalseDeletion == Published /\ s.sourceAbsent =>
 s.g.intentional /\ s.g.leftOrigin = s.g.rightOrigin /\ ~s.o.sourcePresent
NoPayloadLoss == Published =>
 IF s.o.kind = "join" THEN UNION s.liveGroups = Rows
 ELSE IF ~s.sourceAbsent \/ s.o.leftBody # s.o.baseBody
         THEN "L" \in UNION s.liveGroups ELSE TRUE
NoStalePublication == Published => s.fence = s.capturedFence
DeferredAndRejectedRetainInputs == s.phase \in {"deferred","rejected"} =>
 s.liveGroups = {{"L"}} /\ s.checkpoint = {{"L"}} /\ ~s.sourceAbsent /\ s.dirty
 /\ s.captured = Observation(s.case)
CheckpointMatchesPublication == s.phase \in {"installed","reopened"} =>
 s.checkpoint = s.liveGroups /\ s.checkpointDeleted = s.sourceAbsent
EveryAttemptTerminates == <>(s.phase \in {"reopened","deferred","rejected"})
NoDeferral == s.phase # "deferred"
\* Exact observational twins: any decision function of o must give equal
\* answers, although total automatic correctness requires different answers.
AmbiguityPairsAreIndistinguishable ==
 /\ Observation("unknownSharedTag") = Observation("copiedTagNewUUID")
 /\ GroundTruth("unknownSharedTag") # GroundTruth("copiedTagNewUUID")
 /\ Observation("strippedUnknown") = Observation("recreated")
 /\ GroundTruth("strippedUnknown") # GroundTruth("recreated")
 /\ Observation("restoredThenMissing") = Observation("intentUnknown")
 /\ GroundTruth("restoredThenMissing") # GroundTruth("intentUnknown")
 /\ Observation("neverSeenCheckpoint") = Observation("actualCheckpointDelete")
 /\ GroundTruth("neverSeenCheckpoint") # GroundTruth("actualCheckpointDelete")
 /\ Observation("unexplained") = Observation("purgedTrash")
 /\ GroundTruth("unexplained") # GroundTruth("purgedTrash")
NeverJoined == ~(Published /\ s.decision = "join")
NeverSeparated == ~(Published /\ s.decision = "separate")
NeverDeleted == ~(Published /\ s.decision = "delete")
NeverPreservedEdit == ~(Published /\ s.sourceAbsent /\ s.liveGroups = {{"L"}})
NeverKeptRestored == ~(Published /\ s.case = "restored" /\ ~s.sourceAbsent)
NeverReopened == ~s.restarted
NeverDeferredIndependentImport == ~(s.case = "independent" /\ s.phase = "deferred")
=============================================================================
