---------------- MODULE LocalDurabilityLaneIndependence ----------------
EXTENDS FiniteSets

\* Focused liveness refinement of ADR-0010. Provider work may remain stalled
\* forever; weak fairness applies only to NV's local staging and barrier
\* actions after an edit has been admitted. Shared between proposal 4 WALs
\* and proposal 5 immutable segments: this model proves lane independence,
\* not either byte format, directory barriers, or dependency closure.

CONSTANTS Edits

ASSUME IsFiniteSet(Edits) /\ Edits # {}

VARIABLE state

vars == <<state>>

Init ==
    state = [
        admitted |-> {},
        staged |-> {},
        durable |-> {},
        providerWorkPending |-> FALSE,
        providerStalled |-> FALSE,
        providerWorkCompleted |-> FALSE
        ]

AdmitEdit(edit) ==
    /\ edit \in Edits \ state.admitted
    /\ state' = [state EXCEPT !.admitted = @ \cup {edit}]

StageAdmittedEdit(edit) ==
    /\ edit \in state.admitted \ state.staged
    /\ state' = [state EXCEPT !.staged = @ \cup {edit}]

SynchronizeStagedEdit(edit) ==
    /\ edit \in state.staged \ state.durable
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
    \/ \E edit \in Edits: StageAdmittedEdit(edit)
    \/ \E edit \in Edits: SynchronizeStagedEdit(edit)

ProviderStep ==
    QueueProviderWork \/ StallProvider \/ CompleteProviderWork

Next ==
    \/ \E edit \in Edits: AdmitEdit(edit)
    \/ DurabilityStep
    \/ ProviderStep

Spec ==
    /\ Init
    /\ [][Next]_vars
    /\ \A edit \in Edits: WF_vars(StageAdmittedEdit(edit))
    /\ \A edit \in Edits: WF_vars(SynchronizeStagedEdit(edit))

TypeOK ==
    /\ state.admitted \subseteq Edits
    /\ state.staged \subseteq Edits
    /\ state.durable \subseteq Edits
    /\ state.providerWorkPending \in BOOLEAN
    /\ state.providerStalled \in BOOLEAN
    /\ state.providerWorkCompleted \in BOOLEAN

DurabilityStagesAreMonotonic ==
    state.durable \subseteq state.staged
    /\ state.staged \subseteq state.admitted

ProviderStallLeavesLocalDurabilityEnabled ==
    /\ state.providerStalled
    /\ state.admitted \ state.durable # {}
    => ENABLED DurabilityStep

ProviderStepsPreserveLocalState ==
    [][ProviderStep =>
        UNCHANGED <<state.admitted, state.staged, state.durable>>]_vars

AdmittedEditsBecomeDurableWithoutProviderFairness ==
    \A edit \in Edits:
        edit \in state.admitted ~> edit \in state.durable

=============================================================================
