------------------ MODULE ReconciliationDecisionSafety --------------------
EXTENDS FiniteSets, ReconciliationInterface

\* Versions are immutable persistent version identifiers.
\* processedVersions records traversal; representedVersions records
\* provider-version representation.

CONSTANTS
    Versions,
    CanonicalVersion,
    UnresolvedVersion,
    NonlocalVersion,
    States,
    BaseState,
    LocalState,
    RemoteState,
    OtherState,
    MergedState,
    Deleted,
    Names,
    BaseName,
    LocalName,
    RemoteName,
    EnabledScenarios

ASSUME
    /\ Versions = {CanonicalVersion, UnresolvedVersion, NonlocalVersion}
    /\ {BaseState, LocalState, RemoteState, OtherState, MergedState, Deleted}
        \subseteq States
    /\ Cardinality({BaseState, LocalState, RemoteState, OtherState,
                     MergedState, Deleted}) = 6
    /\ {BaseName, LocalName, RemoteName} \subseteq Names
    /\ Cardinality({BaseName, LocalName, RemoteName}) = 3

Scenarios == {
    "fastForward", "twoEditsMerge", "missingBase", "unsafeMerge",
    "deleteEdit", "localDeleteRemoteEdit", "renameRace", "renameOnlyRace",
    "renameRemoteEdit", "unmatchedIdentity", "ambiguousIdentity",
    "pathTimestampIdentity", "filenameContentIdentity", "multiVersion",
    "localEditRemoteUnchanged", "remoteRenameLocalEdit",
    "remoteRenameOnly", "localRenameRemoteUnchanged",
    "localRenameRemoteDelete", "localDeleteRemoteRename",
    "localRenameTwoEditsMerge", "remoteRenameTwoEditsMerge"
}

ASSUME
    /\ EnabledScenarios \subseteq Scenarios
    /\ EnabledScenarios # {}

Outcomes == {
    "pending", "same", "canonicalSelected", "merged", "preserved", "deleteEdit",
    "unmatched", "localWins"
}
Artifacts == States \X Names

Artifact(noteState, name) == <<noteState, name>>

InitialOriginalState(scenario) ==
    CASE scenario \in {"fastForward", "filenameContentIdentity"} -> BaseState
      [] scenario \in {
            "localDeleteRemoteEdit", "localDeleteRemoteRename"
         } -> Deleted
      [] scenario = "multiVersion" -> BaseState
      [] scenario \in {
            "renameRace", "renameOnlyRace", "renameRemoteEdit",
            "remoteRenameOnly", "localRenameRemoteUnchanged",
            "localRenameRemoteDelete"
         } -> BaseState
      [] OTHER -> LocalState

InitialOriginalName(scenario) ==
    IF scenario \in {
        "renameRace", "renameOnlyRace", "renameRemoteEdit",
        "localRenameRemoteUnchanged", "localRenameRemoteDelete",
        "localRenameTwoEditsMerge"
    }
    THEN LocalName ELSE BaseName

SnapshotArtifact(scenario) ==
    Artifact(InitialOriginalState(scenario), InitialOriginalName(scenario))

BaseAvailable(scenario) == scenario # "missingBase"

MergeIsSafe(scenario) == scenario \in {
    "twoEditsMerge", "localRenameTwoEditsMerge",
    "remoteRenameTwoEditsMerge"
}

ExternalState(scenario, version) ==
    CASE scenario \in {
            "localEditRemoteUnchanged", "remoteRenameLocalEdit",
            "remoteRenameOnly", "localRenameRemoteUnchanged",
            "localDeleteRemoteRename", "renameOnlyRace"
         } /\ version = CanonicalVersion -> BaseState
      [] scenario = "deleteEdit" /\ version = CanonicalVersion -> Deleted
      [] scenario = "multiVersion" /\ version = CanonicalVersion -> Deleted
      [] scenario = "localRenameRemoteDelete"
            /\ version = CanonicalVersion -> Deleted
      [] version = UnresolvedVersion -> OtherState
      [] version = NonlocalVersion -> RemoteState
      [] OTHER -> RemoteState

ExternalName(scenario, version) ==
    IF scenario \in {
        "renameRace", "renameOnlyRace", "remoteRenameLocalEdit",
        "remoteRenameOnly", "localDeleteRemoteRename",
        "remoteRenameTwoEditsMerge"
    } /\ version = CanonicalVersion
    THEN RemoteName
    ELSE BaseName

ExternalArtifact(scenario, version) ==
    Artifact(ExternalState(scenario, version), ExternalName(scenario, version))

IdentityEvidence(scenario) ==
    CASE scenario = "unmatchedIdentity" -> {}
      [] scenario = "ambiguousIdentity" -> {"filename", "content"}
      [] scenario = "pathTimestampIdentity" -> {"path", "timestamp"}
      [] scenario = "filenameContentIdentity" ->
            {"filename", "content", "unambiguous"}
      [] OTHER -> {"stable"}

IdentityMatches(scenario, version) ==
    /\ version \in Versions
    /\ \/ "stable" \in IdentityEvidence(scenario)
       \/ {"filename", "content", "unambiguous"}
            \subseteq IdentityEvidence(scenario)

Represents(artifact, candidate, conflicts, mergedInputs) ==
    \/ artifact = candidate
    \/ /\ artifact[1] = Deleted
       /\ candidate[1] = Deleted
    \/ artifact \in conflicts
    \/ artifact \in mergedInputs

Decision(scenario, version, candidate, conflicts, mergedInputs) ==
    LET snapshot == SnapshotArtifact(scenario)
        external == ExternalArtifact(scenario, version)
        externalState == external[1]
        externalName == external[2]
        snapshotState == snapshot[1]
        snapshotName == snapshot[2]
        withConflict == conflicts \cup {external}
        withMergeInputs == mergedInputs \cup {snapshot, external}
    IN
    IF ~IdentityMatches(scenario, version)
    THEN [outcome |-> "unmatched", candidate |-> candidate,
          conflicts |-> withConflict, mergedInputs |-> mergedInputs]
    ELSE IF external = snapshot
    THEN [outcome |-> "same", candidate |-> candidate,
          conflicts |-> conflicts, mergedInputs |-> mergedInputs]
    ELSE IF version # CanonicalVersion
    THEN [outcome |-> "preserved", candidate |-> candidate,
          conflicts |-> withConflict, mergedInputs |-> mergedInputs]
    ELSE IF
        /\ externalName # snapshotName
        /\ snapshotName # BaseName
        /\ externalName # BaseName
    THEN [outcome |-> "preserved", candidate |-> candidate,
          conflicts |-> withConflict, mergedInputs |-> mergedInputs]
    ELSE IF
        /\ snapshotName # BaseName
        /\ externalName = BaseName
        /\ snapshotState = BaseState
        /\ externalState # Deleted
    THEN [outcome |-> "merged",
          candidate |-> Artifact(externalState, candidate[2]),
          conflicts |-> conflicts, mergedInputs |-> withMergeInputs]
    ELSE IF
        /\ snapshotName = BaseName
        /\ externalName # BaseName
        /\ externalState = BaseState
        /\ snapshotState # BaseState
        /\ snapshotState # Deleted
    THEN [outcome |-> "merged",
          candidate |-> Artifact(candidate[1], externalName),
          conflicts |-> conflicts, mergedInputs |-> withMergeInputs]
    ELSE IF
        /\ externalState = snapshotState
        /\ snapshotName = BaseName
    THEN [outcome |-> "canonicalSelected",
          candidate |-> Artifact(candidate[1], externalName),
          conflicts |-> conflicts, mergedInputs |-> mergedInputs]
    ELSE IF
        /\ externalState = Deleted
        /\ snapshotState = BaseState
        /\ snapshotName = BaseName
    THEN [outcome |-> "canonicalSelected",
          candidate |-> Artifact(Deleted, candidate[2]),
          conflicts |-> conflicts, mergedInputs |-> mergedInputs]
    ELSE IF
        /\ externalState = Deleted
        /\ snapshotState # Deleted
    THEN [outcome |-> "deleteEdit",
          candidate |-> Artifact(Deleted, candidate[2]),
          conflicts |-> conflicts \cup {snapshot},
          mergedInputs |-> mergedInputs]
    ELSE IF
        /\ snapshotState = Deleted
        /\ externalState # Deleted
    THEN [outcome |-> "deleteEdit",
          candidate |-> Artifact(Deleted, candidate[2]),
          conflicts |-> withConflict, mergedInputs |-> mergedInputs]
    ELSE IF ~BaseAvailable(scenario)
    THEN [outcome |-> "preserved", candidate |-> candidate,
          conflicts |-> withConflict, mergedInputs |-> mergedInputs]
    ELSE IF
        /\ snapshotState = BaseState
        /\ externalState # Deleted
    THEN [outcome |-> "canonicalSelected", candidate |-> external,
          conflicts |-> conflicts, mergedInputs |-> mergedInputs]
    ELSE IF
        /\ externalState = BaseState
        /\ snapshotState # Deleted
    THEN [outcome |-> "localWins", candidate |-> candidate,
          conflicts |-> conflicts, mergedInputs |-> withMergeInputs]
    ELSE IF MergeIsSafe(scenario)
    THEN [outcome |-> "merged",
          candidate |-> Artifact(
              MergedState,
              IF /\ snapshotName = BaseName
                 /\ externalName # BaseName
              THEN externalName ELSE candidate[2]),
          conflicts |-> conflicts, mergedInputs |-> withMergeInputs]
    ELSE [outcome |-> "preserved", candidate |-> candidate,
          conflicts |-> withConflict, mergedInputs |-> mergedInputs]

VARIABLE state

vars == <<state>>

Init ==
    \E scenario \in EnabledScenarios:
        state = [
            scenario |-> scenario,
            processedVersions |-> {},
            representedVersions |-> {},
            outcomes |-> [version \in Versions |-> "pending"],
            candidate |-> SnapshotArtifact(scenario),
            conflicts |-> {},
            mergedInputs |-> {}
        ]

ProcessVersion ==
    \E version \in Versions \ state.processedVersions:
        LET decision == Decision(
                state.scenario, version, state.candidate,
                state.conflicts, state.mergedInputs)
            processed == state.processedVersions \cup {version}
            represented == {
                processedVersion \in processed:
                    Represents(
                        ExternalArtifact(state.scenario, processedVersion),
                        decision.candidate, decision.conflicts,
                        decision.mergedInputs)
            }
        IN state' = [state EXCEPT
            !.processedVersions = processed,
            !.representedVersions = represented,
            !.outcomes[version] = decision.outcome,
            !.candidate = decision.candidate,
            !.conflicts = decision.conflicts,
            !.mergedInputs = decision.mergedInputs
        ]

Next == ProcessVersion

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ WF_vars(ProcessVersion)

TypeOK ==
    /\ state.scenario \in Scenarios
    /\ state.processedVersions \subseteq Versions
    /\ state.representedVersions \subseteq Versions
    /\ state.outcomes \in [Versions -> Outcomes]
    /\ state.candidate \in Artifacts
    /\ state.conflicts \subseteq Artifacts
    /\ state.mergedInputs \subseteq Artifacts

EveryProcessedVersionIsRepresented ==
    AllSelectedRepresented(
        state.processedVersions, state.representedVersions)

SnapshotIsRepresentedWhenItDiffersFromPristineBase ==
    \/ SnapshotArtifact(state.scenario) = Artifact(BaseState, BaseName)
    \/ Represents(SnapshotArtifact(state.scenario), state.candidate,
                  state.conflicts, state.mergedInputs)

ArtifactsHaveProcessedProvenance ==
    LET sources ==
        {ExternalArtifact(state.scenario, version):
            version \in state.processedVersions}
            \cup {SnapshotArtifact(state.scenario)}
    IN
    /\ state.conflicts \subseteq sources
    /\ state.mergedInputs \subseteq sources

IdentityPolicyIsExact ==
    \A version \in Versions:
        IdentityMatches(state.scenario, version)
        <=> state.scenario \notin {
            "unmatchedIdentity", "ambiguousIdentity", "pathTimestampIdentity"
        }

LocalWinsRecordsBaseAncestry ==
    \A version \in state.processedVersions:
        state.outcomes[version] = "localWins" =>
            {SnapshotArtifact(state.scenario),
             ExternalArtifact(state.scenario, version)}
                \subseteq state.mergedInputs

ExpectedCanonicalOutcome(scenario) ==
    CASE scenario \in {
            "fastForward", "filenameContentIdentity", "multiVersion",
            "remoteRenameOnly"
         } -> "canonicalSelected"
      [] scenario \in {
            "twoEditsMerge", "renameRemoteEdit", "remoteRenameLocalEdit",
            "localRenameRemoteUnchanged", "localRenameTwoEditsMerge",
            "remoteRenameTwoEditsMerge"
         } -> "merged"
      [] scenario \in {
            "missingBase", "unsafeMerge", "renameRace", "renameOnlyRace"
         } -> "preserved"
      [] scenario \in {
            "deleteEdit", "localDeleteRemoteEdit", "localRenameRemoteDelete",
            "localDeleteRemoteRename"
         } -> "deleteEdit"
      [] scenario = "localEditRemoteUnchanged" -> "localWins"
      [] scenario \in {
            "unmatchedIdentity", "ambiguousIdentity", "pathTimestampIdentity"
         } -> "unmatched"

ExpectedCanonicalArtifact(scenario) ==
    CASE scenario \in {"fastForward", "filenameContentIdentity"} ->
            Artifact(RemoteState, BaseName)
      [] scenario = "twoEditsMerge" -> Artifact(MergedState, BaseName)
      [] scenario \in {
            "missingBase", "unsafeMerge", "unmatchedIdentity",
            "ambiguousIdentity", "pathTimestampIdentity",
            "localEditRemoteUnchanged"
         } -> Artifact(LocalState, BaseName)
      [] scenario \in {
            "deleteEdit", "localDeleteRemoteEdit", "multiVersion",
            "localDeleteRemoteRename"
         } -> Artifact(Deleted, BaseName)
      [] scenario \in {"renameRace", "renameOnlyRace"} ->
            Artifact(BaseState, LocalName)
      [] scenario = "renameRemoteEdit" -> Artifact(RemoteState, LocalName)
      [] scenario = "remoteRenameLocalEdit" -> Artifact(LocalState, RemoteName)
      [] scenario = "remoteRenameOnly" -> Artifact(BaseState, RemoteName)
      [] scenario = "localRenameRemoteUnchanged" ->
            Artifact(BaseState, LocalName)
      [] scenario = "localRenameRemoteDelete" -> Artifact(Deleted, LocalName)
      [] scenario = "localRenameTwoEditsMerge" ->
            Artifact(MergedState, LocalName)
      [] scenario = "remoteRenameTwoEditsMerge" ->
            Artifact(MergedState, RemoteName)

ScenarioDecisionsMatchIndependentOracle ==
    /\ (CanonicalVersion \in state.processedVersions =>
        /\ state.outcomes[CanonicalVersion] =
            ExpectedCanonicalOutcome(state.scenario)
        /\ state.candidate = ExpectedCanonicalArtifact(state.scenario))
    /\ \A version \in
            state.processedVersions \ {CanonicalVersion}:
        state.outcomes[version] =
            IF IdentityMatches(state.scenario, version)
            THEN "preserved" ELSE "unmatched"

AllVersionsEventuallyProcessed ==
    <> (state.processedVersions = Versions)

=============================================================================
