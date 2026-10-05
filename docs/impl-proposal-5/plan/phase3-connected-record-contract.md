# Phase-3 connected record contract

This contract connects canonical derived state, deletion/preservation, explicit
recovery commands and portable compensation to private current rows. The
[Protocol](../Protocol.md), ADR-0014/0015 and [scenario matrix](phase3-schedule-observation-matrix.md)
define the semantics. Independent literal fixtures pin the byte layouts.

## Action and operation layouts

Keep the first-save action prefix through its affected-state vector. Each affected
birth has one exact before-state and its actual final member-operation after-state.
Native steps can contain several successive members for the same birth.

| Action tag | Kind | Tail following affected states |
| --- | --- | --- |
| 1–5 | Saved edit, rename, labels, create/import, Delete | Empty |
| 6 | Restore | u32-counted restoration vector |
| 7 | Historical recovery | source birth (16), revision reference, field mask (u8) |
| 8 | Explicit conflict choice | selected revision reference, u32-counted sorted captured head references |
| 9 | Conflict copy | source birth (16), revision reference, recovery key (32), slot (u64), optional reused revision reference |
| 10/11 | Undo/Redo | restoration vector, target action reference, reviewed boolean (u8) |
| 12 | Native compensation | u32-counted vector sorted by covered action ID; each entry is action reference, remaining-state reference, complete boolean |

Historical field bits are body=1, title=2, labels=4; nonzero masks through 7 are
valid. Separate historical recovery records all fields and a fresh ordinary birth.
Optional references encode presence 0/1 followed by the existing reference when
present. All integers use canonical big-endian widths. The Restore vector's
optional exact prior state is specified in the [Restore contract](restoration-record-contract.md).
Before-state tags are fresh absence=0, value=1, deleted=2, equal=3, merged=4,
automatic preservation=5. Tag 5 contains source birth (16), automatic key (32)
and source revision reference.

New operation tags retain the standard operation prefix, parents and predecessors:

| Tag | Effect | Length-delimited effect payload |
| --- | --- | --- |
| 7 | RecoverCopy | source birth (16), source revision ID (32), recovery key (32), slot (u64), optional reused operation ID (32), full resulting value |
| 8 | RetireConflict | deterministic identity: tag 0 + automatic key (32), or tag 1 + recovery key (32) + slot (u64) |
| 9 | AdoptAutomatic | source birth (16), source revision ID (32), automatic key (32), full independently authored value |

RetireConflict accompanies the Delete in the same complete action and transaction.
RecoverCopy binds its source and optional reused occurrence through action
references as well as operation identity. Operation hashing retains the established
domain and expanded semantic fields. ChangesPayload uses its complete sections
and canonical dependency table. Repackaging preserves allocated action IDs and
expanded operations, while retaining each exact envelope occurrence.

Action before-state tags 3 and 4 contain the existing equal/merge record directly,
including its sorted exact input references, result digest, and merge base/identity.
Their local references bind to the complete operation section. An action's after
state remains its actual final member operation. Causal parents, note predecessors
and action-scope parents retain their separate roles.

Private `NVCEL1` version 2 retains version 1's birth, full value, representative
operation and scope frontier, then appends two u32-counted vectors of full 92-byte
operation occurrences: represented revisions and all note heads. Both vectors are
strictly raw-ID sorted. The representative is the first represented occurrence.
An optional derived record is encoded as presence u8, its complete dependency
locator table, and u32-length-delimited derived record with external references.
Then encode optional automatic source (presence, source birth, key, full 92-byte
source occurrence) and optional deterministic identity (presence, tag/key/slot as
above). Version 1 remains the minimal single-head encoding. Derived values retain every
represented input; ordinary captures use that set for note predecessors.

Rows decode into canonical sorted sets and compare the complete re-encoding.
Derived result digests match their row values; automatic birth/source/key and
typed identity bind the row. These are stored claims: complete accepted graph
reconstruction verifies their exact evidence at rebuild/command boundaries.

## Admission and reduction

Healthy returning startup loads these indexed rows without replaying history.
An accepted batch with divergent note inputs uses a complete prefix-relative graph
read in bounded database turns, reduction on the history worker, and a separate
guarded current-row transaction. Ownership, view epoch and prior represented
prefix are checked at installation. New history accepted meanwhile remains the
next batch; stale row preparations cannot roll the current prefix backward.

The general path verifies exact retained occurrences and complete membership.
The existing single-current fast path remains available and performs no ancestor
walks. Neither path uses receiver Current to validate a writer's prior inputs.

Delete coverage is the union of causal ancestry of all applicable Deletes. Only
maximal uncovered edits qualify for automatic preservation. Equal automatic keys
share one view while any qualifying source remains; ordinary user-authored
revisions at that birth survive later automatic retraction. Retraction changes
derived rows; explicit Delete also durably retires the typed deterministic identity.

Historical recovery into an automatic preservation note authors `AdoptAutomatic`
with the captured source/key provenance, just as another independent edit of that
note does. The selected fields become independently authored state at that birth;
later coverage retracts only the remaining automatic presentation.

An exact captured edit of a then-live automatic copy can be admitted after newer
coverage has removed only that presentation. The original owner/view/presentation
epoch must match, the older prefix must be positive and retained, and the current
cell must be absent or exactly equal to the captured cell. Complete writer-basis
validation still verifies its source evidence and new independent operation. A
different current authored value, a different owner or a refreshed choice requires
fresh capture. Its host generation also fences any prepared live retraction.

Ordinary edits replace only represented inputs. Explicit Use this version replaces
its exact captured head set and preserves Current title/labels. Saving a conflict
copy adds a disposition for precisely its selected source revision; source
selection continues independently. Reuse requires a recovery-typed birth, an
exact single represented occurrence and the canonical selected body. An unrelated
ordinary identity occupying a slot is preserved. Modified/deleted/retired slots
remain occupied and a new admission finds the lowest qualifying slot. One admitted
retry keeps its exact identities/bytes; a later explicit command is a new action.

RAM-only Current pins issue a fresh presentation epoch on pin/release. Release
returns the already computed neutral view immediately, allowing publication
without another provider event. A disappeared/superseded pinned head releases
its pin and fences older prepared views.

## Portable compensation

Scope maxima derive from declared complete writer history. Previous-origin order,
note ancestry and compensation targets remain distinct. Direction-specific
candidates follow retained inverse edges and independent-action suppression;
review is relative to the requested candidate's families. Older forks in unrelated
families preserve history while leaving safe new commands automatic.

Prepare every member against actual Current and the selected action's actual
before/after states. Preserve fields it did not change. Review approval binds the
captured candidate/frontier, tested births, owner/view/presentation epochs and
exact replacement. Unrelated work outside that scope is allowed when those
inputs remain equal. No-effect preparation adds no action or consumption.
Admitted retries retain their frozen replacement, fresh mappings and once-sealed bytes.
Undo of Delete restores fresh births with exact deletion provenance; subsequent
inverses use those resulting births. An inverse's record and the later settled
Current are checked separately because unchosen alternatives remain live.

Command calculations use immutable captured graphs and values on a cancellable
worker, leaving the session actor available to saves, snapshots and quiescing.
Completion checks the live owner/header again. Applying a reviewed proposal still
checks its candidate and affected state; the resulting admitted capture retains
the ordinary exact-prefix persistence fence. If history changes during capture
calculation, persistence returns a stale pending capture and a fresh command
attempt must be prepared explicitly.

Undo candidate queries use temporary ancestry/family memoization within one query.
Candidate maxima exclude every candidate reachable through scope parents,
including paths through consumed commands. This changes traversal work while
preserving the causal candidate rules and received-history validation.

Native records cover saved groups individually and bind every remaining state to
an actual member step. The newest automatic causal candidate must be covered at
the first step, both in authoring and received-record validation. The complete flag
agrees with the target's original before fields. Only all maximal native claims
being complete consumes a group. Ordered partial coverage supplies the remaining
effect on reopen. Incomparable claims retain review and use Current's actual
represented note lineage to select the applicable remaining state; a joined
Current supplies the combined state. AppKit step attribution is qualified in
the later application phase.

## Concrete evidence

`ConnectedRecordTests`, `ExtendedCurrentCodecTests` and independent Python byte
builders qualify tails, identities, current rows and full-state Restore layouts.
Runtime command/edge/near-valid/resumption tests exercise the actual issuers and
consumers under both profiles. The fresh-process driver independently decrypts,
decodes and reduces accepted membership through the Node oracle, with callbacks
absent from recovery inputs. See the [phase-3 qualification report](phase3-validation.md)
for executed dimensions and remaining platform/integration limits.
