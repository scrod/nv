------------------- MODULE CurrentCheckpointNoteMergeSafety -------------------
EXTENDS FiniteSets, Naturals

CONSTANTS Notes, NoteStates, Absent,
          LocalSettings, CurrentSettings,
          Versions, InitialVersion, DeterministicIDs, None

ASSUME
    /\ IsFiniteSet(Notes)
    /\ Notes # {}
    /\ IsFiniteSet(NoteStates)
    /\ Absent \in NoteStates
    /\ LocalSettings # CurrentSettings
    /\ IsFiniteSet(Versions)
    /\ Cardinality(Versions) >= 2
    /\ InitialVersion \in Versions
    /\ IsFiniteSet(DeterministicIDs)
    /\ DeterministicIDs # {}
    /\ None \notin Versions
    /\ None # LocalSettings
    /\ None # CurrentSettings

Settings == {LocalSettings, CurrentSettings}

Phases == {
    "attempting", "changed", "merged", "durable",
    "settled", "retrying", "committed", "rejected", "recovered"
}

VARIABLE state

vars == <<state>>

MaterialPair(note, value) ==
    IF value = Absent THEN {} ELSE {<<note, value>>}

DecisionPair(note, value) == {<<note, value>>}

MaterialPairs(notes) ==
    UNION {MaterialPair(note, notes[note]) : note \in Notes}

DecisionPairs(notes) ==
    UNION {DecisionPair(note, notes[note]) : note \in Notes}

Materialized(decisions) ==
    {pair \in decisions: pair[2] # Absent}

MergeForNote(note, base, local, current) ==
    IF local[note] = current[note]
      THEN DecisionPair(note, local[note])
    ELSE IF local[note] = base[note]
      THEN DecisionPair(note, current[note])
    ELSE IF current[note] = base[note]
      THEN DecisionPair(note, local[note])
    ELSE DecisionPair(note, local[note]) \cup
         DecisionPair(note, current[note])

MergedPairs(base, local, current) ==
    UNION {MergeForNote(note, base, local, current) : note \in Notes}

ChangedPairs(base, branch) ==
    UNION {
        IF branch[note] # base[note]
          THEN DecisionPair(note, branch[note])
          ELSE {}
        : note \in Notes
    }

Init ==
    \E base \in [Notes -> NoteStates]:
      \E local \in [Notes -> NoteStates]:
        \E current \in [Notes -> NoteStates]:
          \E baseRetired \in SUBSET DeterministicIDs:
            \E localRetired \in
                    {ids \in SUBSET DeterministicIDs:
                        baseRetired \subseteq ids}:
              \E currentRetired \in
                      {ids \in SUBSET DeterministicIDs:
                          baseRetired \subseteq ids}:
            state = [
                phase |-> "attempting",
                baseNotes |-> base,
                localNotes |-> local,
                currentNotes |-> current,
                capturedNotes |-> base,
                baseRetired |-> baseRetired,
                localRetired |-> localRetired,
                currentRetired |-> currentRetired,
                capturedRetired |-> {},
                mergedRetired |-> {},
                localSettings |-> LocalSettings,
                currentSettings |-> CurrentSettings,
                capturedSettings |-> LocalSettings,
                mergedSettings |-> None,
                currentVersion |-> InitialVersion,
                capturedVersion |-> None,
                expectedVersion |-> None,
                seenVersions |-> {InitialVersion},
                represented |-> {},
                checkpointRecords |-> {},
                pendingWAL |-> {},
                durableWAL |-> {},
                pendingRetiredWAL |-> {},
                durableRetiredWAL |-> {},
                recoveredRetired |-> {},
                filesSettled |-> FALSE,
                mergePerformed |-> FALSE,
                checkpointWritten |-> FALSE,
                recoveryWitnesses |-> {},
                writeWitnesses |-> {}
            ]

DetectCurrentChanged ==
    /\ state.phase = "attempting"
    /\ state' = [state EXCEPT
        !.phase = "changed",
        !.capturedNotes = state.currentNotes,
        !.capturedRetired = state.currentRetired,
        !.capturedSettings = state.currentSettings,
        !.capturedVersion = state.currentVersion
        ]

MergeCompleteNoteSets ==
    /\ state.phase = "changed"
    /\ LET merged == MergedPairs(
            state.baseNotes,
            state.localNotes,
            state.capturedNotes)
       IN state' = [state EXCEPT
            !.phase = "merged",
            !.represented = merged,
            !.checkpointRecords = Materialized(merged),
            !.pendingWAL = merged \ DecisionPairs(state.localNotes),
            !.mergedRetired =
                state.localRetired \cup state.capturedRetired,
            !.pendingRetiredWAL =
                state.localRetired \cup state.capturedRetired,
            !.mergedSettings = state.localSettings,
            !.mergePerformed = TRUE
        ]

RejectUnreadableCurrent ==
    /\ state.phase = "changed"
    /\ state' = [state EXCEPT !.phase = "rejected"]

DurabilizeMerge ==
    /\ state.phase = "merged"
    /\ state' = [state EXCEPT
        !.phase = "durable",
        !.durableWAL = state.pendingWAL,
        !.durableRetiredWAL = state.pendingRetiredWAL
        ]

SettleSeparateFiles ==
    /\ state.phase = "durable"
    /\ state.pendingWAL \subseteq state.durableWAL
    /\ state.pendingRetiredWAL \subseteq state.durableRetiredWAL
    /\ state' = [state EXCEPT
        !.phase = "settled",
        !.filesSettled = TRUE
        ]

BeginRetry ==
    /\ state.phase = "settled"
    /\ state.pendingWAL \subseteq state.durableWAL
    /\ state.pendingRetiredWAL \subseteq state.durableRetiredWAL
    /\ state.filesSettled
    /\ state' = [state EXCEPT
        !.phase = "retrying",
        !.expectedVersion = state.capturedVersion
        ]

ReplaceCurrentAgain ==
    /\ state.phase \in {"changed", "merged", "durable", "settled", "retrying"}
    /\ \E version \in Versions \ state.seenVersions:
      \E notes \in [Notes -> NoteStates]:
        \E retired \in SUBSET DeterministicIDs:
          \E settings \in Settings:
            state' = [state EXCEPT
                !.currentNotes = notes,
                !.currentRetired = retired,
                !.currentSettings = settings,
                !.currentVersion = version,
                !.seenVersions = @ \cup {version}
            ]

CommitRetry ==
    /\ state.phase = "retrying"
    /\ state.currentVersion = state.expectedVersion
    /\ state' = [state EXCEPT
        !.phase = "committed",
        !.checkpointWritten = TRUE,
        !.writeWitnesses = @ \cup
            {<<state.expectedVersion = state.currentVersion,
               state.pendingWAL \subseteq state.durableWAL,
               state.pendingRetiredWAL
                   \subseteq state.durableRetiredWAL,
               state.filesSettled,
               state.mergedSettings = state.localSettings,
               state.checkpointRecords = Materialized(state.represented),
               state.mergedRetired =
                   state.localRetired \cup state.capturedRetired,
               ChangedPairs(state.baseNotes, state.localNotes)
                   \subseteq state.represented,
               ChangedPairs(state.baseNotes, state.capturedNotes)
                   \subseteq state.represented>>}
        ]

RejectStaleRetry ==
    /\ state.phase = "retrying"
    /\ state.currentVersion # state.expectedVersion
    /\ state' = [state EXCEPT !.phase = "rejected"]

RecoverRetirementsAfterStaleRetry ==
    /\ state.phase = "rejected"
    /\ state.mergePerformed
    /\ state.pendingRetiredWAL \subseteq state.durableRetiredWAL
    /\ LET recovered ==
            state.currentRetired \cup state.durableRetiredWAL
       IN state' = [state EXCEPT
            !.phase = "recovered",
            !.recoveredRetired = recovered,
            !.recoveryWitnesses = @ \cup
                {<<state.mergedRetired \subseteq recovered,
                   state.pendingRetiredWAL
                       \subseteq state.durableRetiredWAL>>}
        ]

Next ==
    \/ DetectCurrentChanged
    \/ MergeCompleteNoteSets
    \/ RejectUnreadableCurrent
    \/ DurabilizeMerge
    \/ SettleSeparateFiles
    \/ BeginRetry
    \/ ReplaceCurrentAgain
    \/ CommitRetry
    \/ RejectStaleRetry
    \/ RecoverRetirementsAfterStaleRetry

Spec ==
    /\ Init
    /\ [][Next]_vars

TypeOK ==
    /\ state.phase \in Phases
    /\ state.baseNotes \in [Notes -> NoteStates]
    /\ state.localNotes \in [Notes -> NoteStates]
    /\ state.currentNotes \in [Notes -> NoteStates]
    /\ state.capturedNotes \in [Notes -> NoteStates]
    /\ state.baseRetired \subseteq DeterministicIDs
    /\ state.localRetired \subseteq DeterministicIDs
    /\ state.currentRetired \subseteq DeterministicIDs
    /\ state.capturedRetired \subseteq DeterministicIDs
    /\ state.mergedRetired \subseteq DeterministicIDs
    /\ state.baseRetired \subseteq state.localRetired
    /\ state.localSettings \in Settings
    /\ state.currentSettings \in Settings
    /\ state.capturedSettings \in Settings
    /\ state.mergedSettings \in Settings \cup {None}
    /\ state.currentVersion \in Versions
    /\ state.capturedVersion \in Versions \cup {None}
    /\ state.expectedVersion \in Versions \cup {None}
    /\ state.seenVersions \subseteq Versions
    /\ state.represented \subseteq Notes \X NoteStates
    /\ state.checkpointRecords \subseteq Notes \X NoteStates
    /\ state.pendingWAL \subseteq Notes \X NoteStates
    /\ state.durableWAL \subseteq Notes \X NoteStates
    /\ state.pendingRetiredWAL \subseteq DeterministicIDs
    /\ state.durableRetiredWAL \subseteq DeterministicIDs
    /\ state.recoveredRetired \subseteq DeterministicIDs
    /\ state.filesSettled \in BOOLEAN
    /\ state.mergePerformed \in BOOLEAN
    /\ state.checkpointWritten \in BOOLEAN
    /\ state.recoveryWitnesses \subseteq BOOLEAN \X BOOLEAN

CurrentChangedNeverWrites ==
    [][DetectCurrentChanged =>
        state'.checkpointWritten = state.checkpointWritten]_vars

CompetingSettingsAreNeverImported ==
    state.mergePerformed => state.mergedSettings = state.localSettings

CheckpointContainsNoDeletionRecord ==
    state.mergePerformed =>
        /\ state.checkpointRecords = Materialized(state.represented)
        /\ \A pair \in state.checkpointRecords: pair[2] # Absent

RetiredDeterministicIdentitiesAreMonotonic ==
    state.mergePerformed =>
        state.mergedRetired =
            state.localRetired \cup state.capturedRetired

MergedRetirementsAreDurableBeforeRetry ==
    state.phase \in {"retrying", "committed"} =>
        /\ state.pendingRetiredWAL = state.mergedRetired
        /\ state.pendingRetiredWAL \subseteq state.durableRetiredWAL

BaseMismatchRecoveryPreservesMergedRetirements ==
    state.recoveryWitnesses \subseteq {<<TRUE, TRUE>>}

MergeRepresentsEveryChangedBranch ==
    state.mergePerformed =>
        /\ ChangedPairs(state.baseNotes, state.localNotes)
            \subseteq state.represented
        /\ ChangedPairs(state.baseNotes, state.capturedNotes)
            \subseteq state.represented

RetryRequiresDurableSettledMerge ==
    state.phase \in {"retrying", "committed"} =>
        /\ state.mergePerformed
        /\ state.pendingWAL \subseteq state.durableWAL
        /\ state.pendingRetiredWAL \subseteq state.durableRetiredWAL
        /\ state.filesSettled

CommittedRetryUsedExactCapturedCurrent ==
    state.checkpointWritten =>
        /\ state.phase = "committed"
        /\ state.expectedVersion = state.capturedVersion
        /\ state.currentVersion = state.expectedVersion

EveryWriteHadCompleteSafetyEvidence ==
    state.writeWitnesses \subseteq
        {<<TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE>>}

=============================================================================
