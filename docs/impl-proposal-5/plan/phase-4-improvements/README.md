# Phase 4 improvements

Status: increments 1–5 are implemented and qualified within their portable
Runtime boundaries. Their checking boundaries, executed qualification and
remaining limits are recorded in the
[validation report](validation.md). The plans below retain their implementation
and qualification requirements.

| Order | Improvement | Starting evidence |
| --- | --- | --- |
| 1 | [Durable reminders for interrupted verification](durable-verification-recovery.md) | `REVIEW-DAMAGE-1`: detected damage to old accepted history can be forgotten after failed diagnosis writes and termination |
| 2 | [At-most-once envelope decoding per history traversal](at-most-once-envelope-decoding.md) | `REVIEW-HISTORY-2`: extracting individual records and auditing snapshot occurrences repeatedly decode packed envelopes |
| 3 | [One checked graph for recovery catch-up](recovery-graph-reuse.md) | `REVIEW-HISTORY-3`: multiple unapplied general-reducer batches rebuild overlapping graphs during recovery |
| 4A | [Publish before optional snapshot verification](startup-and-scoped-queries.md#a-publish-before-independent-optional-snapshots) | `REVIEW-START-2`: an independent ready snapshot walks old history before healthy current notes reach the host |
| 4B | [Select scoped Undo/conflict history before decoding](startup-and-scoped-queries.md#b-select-exact-history-before-decoding) | `REVIEW-HISTORY-1`: note-specific queries load unrelated history bodies |
| 5 | [Snapshot retention coverage](snapshot-retention-coverage.md) | `REVIEW-START-3`: independent snapshot roots accumulate returning-startup checks; v2 explicit retention parents preserve coverage with the existing dependency graph |

The [deferred benchmark backlog](benchmark-backlog.md) records scoped Undo/conflict
queries, initial current-row capture reuse, optional snapshot scheduling and
snapshot-root retention growth. The [storage review report](../storage-review-follow-up.md)
preserves their starting evidence. Initial capture reuse is qualified in 4F;
startup/scoped-query qualification is recorded separately below. Snapshot-root
retention coverage is implemented and qualified in increment 5; its production qualification
is recorded in the [separate report](snapshot-retention-coverage-validation.md).
Concurrent independent frontier width remains a separate scaling consideration.

Verification reminders preserve restart obligations;
at-most-once decoding reduces the work within each captured history traversal.
Recovery graph reuse computes the final unpublished view once for a captured
accepted target, preserving all intermediate actions. All three plans preserve
the existing healthy current-row startup path.

The [startup/scoped-query report](startup-and-scoped-queries-validation.md) records
the new shared-reader boundaries, derived schema index, scheduling checks and
platform results. Increment 4 preserves public APIs and history encodings;
increment 5 retains Runtime method shapes and revises the general snapshot format.

Parent documents: [implementation roadmap](../swift-storage-implementation-plan.md),
[Phase 4 plan](../phase4-startup-recovery-plan.md),
[conformance strategy](../swift-storage-conformance-testing-strategy.md).
