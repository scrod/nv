--------------------- MODULE SeparateFileDeletionSafety ---------------------
EXTENDS FiniteSets

\* Focused model of the only operation allowed to remove a separate note file.
\* A filename, body, checkpoint omission, or retired identity never identifies
\* the file to delete; the exact accepted file incarnation does. Absence origin
\* distinguishes an environmental removal from NV's authorized deletion.
\* Shared component: the caller supplies the complete Delete/action/parent
\* segment barrier. The replacement is an independently classified new-file
\* fixture; assigning FreshNoteID here does not bypass IMPORT-01's classifier
\* for arbitrary replacements, contradictory provenance or repair candidates.
\* This does not prove encoding, root identity, or crash-time token invalidation.

CONSTANTS
    Incarnations, InitialIncarnation, ReplacementIncarnation,
    NoteIDs, OriginalNoteID, FreshNoteID, None

ASSUME
    /\ Incarnations = {InitialIncarnation, ReplacementIncarnation}
    /\ InitialIncarnation # ReplacementIncarnation
    /\ NoteIDs = {OriginalNoteID, FreshNoteID}
    /\ OriginalNoteID # FreshNoteID
    /\ None \notin Incarnations
    /\ None \notin NoteIDs

VARIABLE state

vars == <<state>>

Init ==
    state = [
        originalNoteLive |-> TRUE,
        logicalDeletionAdmitted |-> FALSE,
        pendingDeletion |-> FALSE,
        deletionDurable |-> FALSE,
        expectedIncarnation |-> InitialIncarnation,
        filePresent |-> TRUE,
        fileIncarnation |-> InitialIncarnation,
        fileAssociation |-> OriginalNoteID,
        absenceOrigin |-> "present",
        replacementCreated |-> FALSE,
        mismatchHandled |-> FALSE,
        checkpointOmissionRecorded |-> FALSE,
        retirementRecorded |-> FALSE,
        removedIncarnations |-> {},
        removalWitnesses |-> {}
        ]

AdmitLogicalDeletion ==
    /\ state.originalNoteLive
    /\ ~state.logicalDeletionAdmitted
    /\ state' = [state EXCEPT
        !.originalNoteLive = FALSE,
        !.logicalDeletionAdmitted = TRUE,
        !.pendingDeletion = TRUE
        ]

ExternalReplaceSameName ==
    /\ state.filePresent
    /\ ~state.replacementCreated
    /\ state' = [state EXCEPT
        !.fileIncarnation = ReplacementIncarnation,
        !.fileAssociation = None,
        !.replacementCreated = TRUE
        ]

ExternalRemoveCurrentFile ==
    /\ state.filePresent
    /\ state' = [state EXCEPT
        !.filePresent = FALSE,
        !.fileIncarnation = None,
        !.fileAssociation = None,
        !.absenceOrigin = "external"
        ]

ExternalRecreateSameName ==
    /\ ~state.filePresent
    /\ ~state.replacementCreated
    /\ state' = [state EXCEPT
        !.filePresent = TRUE,
        !.fileIncarnation = ReplacementIncarnation,
        !.fileAssociation = None,
        !.absenceOrigin = "present",
        !.replacementCreated = TRUE
        ]

CompleteLocalDeletionBarrier ==
    /\ state.logicalDeletionAdmitted
    /\ ~state.deletionDurable
    /\ state' = [state EXCEPT !.deletionDurable = TRUE]

RemoveExactAcceptedIncarnation ==
    /\ state.pendingDeletion
    /\ state.deletionDurable
    /\ state.filePresent
    /\ state.fileIncarnation = state.expectedIncarnation
    /\ state' = [state EXCEPT
        !.pendingDeletion = FALSE,
        !.filePresent = FALSE,
        !.fileIncarnation = None,
        !.fileAssociation = None,
        !.absenceOrigin = "explicitDeletion",
        !.removedIncarnations = @ \cup {state.fileIncarnation},
        !.removalWitnesses =
            @ \cup {<<state.fileIncarnation, state.expectedIncarnation>>}
        ]

PreserveDeletionMismatch ==
    /\ state.pendingDeletion
    /\ state.filePresent
    /\ state.fileIncarnation # state.expectedIncarnation
    /\ state' = [state EXCEPT
        !.pendingDeletion = FALSE,
        !.fileAssociation = FreshNoteID,
        !.mismatchHandled = TRUE
        ]

FinishAlreadyAbsentDeletion ==
    /\ state.pendingDeletion
    /\ ~state.filePresent
    /\ state' = [state EXCEPT !.pendingDeletion = FALSE]

ImportUnmatchedReplacement ==
    /\ state.filePresent
    /\ state.fileIncarnation = ReplacementIncarnation
    /\ state.fileAssociation = None
    /\ ~state.pendingDeletion
    /\ state' = [state EXCEPT !.fileAssociation = FreshNoteID]

RecordCheckpointOmission ==
    /\ state.logicalDeletionAdmitted
    /\ ~state.checkpointOmissionRecorded
    /\ state' = [state EXCEPT !.checkpointOmissionRecorded = TRUE]

RecordRetiredIdentity ==
    /\ ~state.retirementRecorded
    /\ state' = [state EXCEPT !.retirementRecorded = TRUE]

Next ==
    \/ AdmitLogicalDeletion
    \/ CompleteLocalDeletionBarrier
    \/ ExternalReplaceSameName
    \/ ExternalRemoveCurrentFile
    \/ ExternalRecreateSameName
    \/ RemoveExactAcceptedIncarnation
    \/ PreserveDeletionMismatch
    \/ FinishAlreadyAbsentDeletion
    \/ ImportUnmatchedReplacement
    \/ RecordCheckpointOmission
    \/ RecordRetiredIdentity

Spec == Init /\ [][Next]_vars

TypeOK ==
    /\ state.originalNoteLive \in BOOLEAN
    /\ state.logicalDeletionAdmitted \in BOOLEAN
    /\ state.pendingDeletion \in BOOLEAN
    /\ state.deletionDurable \in BOOLEAN
    /\ state.expectedIncarnation \in Incarnations
    /\ state.filePresent \in BOOLEAN
    /\ state.fileIncarnation \in Incarnations \cup {None}
    /\ state.fileAssociation \in NoteIDs \cup {None}
    /\ state.absenceOrigin \in {"present", "external", "explicitDeletion"}
    /\ state.replacementCreated \in BOOLEAN
    /\ state.mismatchHandled \in BOOLEAN
    /\ state.checkpointOmissionRecorded \in BOOLEAN
    /\ state.retirementRecorded \in BOOLEAN
    /\ state.removedIncarnations \subseteq Incarnations
    /\ state.removalWitnesses \subseteq Incarnations \X Incarnations
    /\ (state.filePresent => state.fileIncarnation \in Incarnations)
    /\ (~state.filePresent => state.fileIncarnation = None)
    /\ (state.filePresent <=> state.absenceOrigin = "present")

EveryRemovalMatchedTheExactAcceptedIncarnation ==
    state.removalWitnesses \subseteq
        {<<InitialIncarnation, InitialIncarnation>>}

ReplacementIncarnationIsNeverRemovedByOriginalDeletion ==
    ReplacementIncarnation \notin state.removedIncarnations

ReplacementIsNeverReattachedToDeletedUUID ==
    state.fileIncarnation = ReplacementIncarnation =>
        state.fileAssociation # OriginalNoteID

DeletionMismatchPreservesAndImportsReplacement ==
    state.mismatchHandled /\ state.filePresent =>
        /\ state.fileIncarnation = ReplacementIncarnation
        /\ state.fileAssociation = FreshNoteID

EveryPhysicalAbsenceHasAuthorizedOrigin ==
    state.absenceOrigin = "explicitDeletion" =>
        /\ state.logicalDeletionAdmitted
        /\ InitialIncarnation \in state.removedIncarnations

RemovalFollowsLocalDurability == state.removedIncarnations # {} => state.deletionDurable
NeverRemovedDurableOriginal == ~(InitialIncarnation \in state.removedIncarnations /\ state.deletionDurable)

PhysicalFileStateUnchanged ==
    /\ state'.filePresent = state.filePresent
    /\ state'.fileIncarnation = state.fileIncarnation
    /\ state'.fileAssociation = state.fileAssociation
    /\ state'.absenceOrigin = state.absenceOrigin

CheckpointOmissionNeverRemovesAFile ==
    [][RecordCheckpointOmission => PhysicalFileStateUnchanged]_vars

RetirementNeverRemovesAFile ==
    [][RecordRetiredIdentity => PhysicalFileStateUnchanged]_vars

=============================================================================
