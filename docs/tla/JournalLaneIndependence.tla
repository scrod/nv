------------------ MODULE JournalLaneIndependence -------------------
EXTENDS FiniteSets

\* Focused liveness refinement of ADR-0010. Provider work may remain stalled
\* forever; weak fairness applies only to NV's local append and barrier-sync
\* actions after an edit has been admitted.

CONSTANTS Edits

ASSUME IsFiniteSet(Edits) /\ Edits # {}

VARIABLE state

vars == <<state>>

Init ==
    state = [
        admitted |-> {},
        appended |-> {},
        durable |-> {},
        providerWorkPending |-> FALSE,
        providerStalled |-> FALSE,
        providerWorkCompleted |-> FALSE
        ]

AdmitEdit(edit) ==
    /\ edit \in Edits \ state.admitted
    /\ state' = [state EXCEPT !.admitted = @ \cup {edit}]

AppendAdmittedEdit(edit) ==
    /\ edit \in state.admitted \ state.appended
    /\ state' = [state EXCEPT !.appended = @ \cup {edit}]

SynchronizeAppendedEdit(edit) ==
    /\ edit \in state.appended \ state.durable
    /\ state' = [state EXCEPT !.durable = @ \cup {edit}]

QueueProviderWork ==
    /\ ~state.providerWorkPending
    /\ ~state.providerWorkCompleted
    /\ state' = [state EXCEPT !.providerWorkPending = TRUE]

StallProvider ==
    /\ state.providerWorkPending
    /\ ~state.providerStalled
    /\ state' = [state EXCEPT !.providerStalled = TRUE]

CompleteProviderWork ==
    /\ state.providerWorkPending
    /\ ~state.providerStalled
    /\ state' = [state EXCEPT
        !.providerWorkPending = FALSE,
        !.providerWorkCompleted = TRUE
        ]

DurabilityStep ==
    \/ \E edit \in Edits: AppendAdmittedEdit(edit)
    \/ \E edit \in Edits: SynchronizeAppendedEdit(edit)

ProviderStep ==
    QueueProviderWork \/ StallProvider \/ CompleteProviderWork

Next ==
    \/ \E edit \in Edits: AdmitEdit(edit)
    \/ DurabilityStep
    \/ ProviderStep

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ \A edit \in Edits: WF_vars(AppendAdmittedEdit(edit))
    /\ \A edit \in Edits: WF_vars(SynchronizeAppendedEdit(edit))

TypeOK ==
    /\ state.admitted \subseteq Edits
    /\ state.appended \subseteq Edits
    /\ state.durable \subseteq Edits
    /\ state.providerWorkPending \in BOOLEAN
    /\ state.providerStalled \in BOOLEAN
    /\ state.providerWorkCompleted \in BOOLEAN

DurabilityStagesAreMonotonic ==
    state.durable \subseteq state.appended
    /\ state.appended \subseteq state.admitted

ProviderStallLeavesLocalDurabilityEnabled ==
    /\ state.providerStalled
    /\ state.admitted \ state.durable # {}
    => ENABLED DurabilityStep

ProviderStepsPreserveJournalState ==
    [][ProviderStep =>
        UNCHANGED <<state.admitted, state.appended, state.durable>>]_vars

AdmittedEditsBecomeDurableWithoutProviderFairness ==
    \A edit \in Edits:
        edit \in state.admitted ~> edit \in state.durable

=============================================================================
