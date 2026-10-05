# One checked graph for recovery catch-up

Date: 2026-10-04. Status: implemented for unpublished returning-open recovery.
The [validation report](validation.md) records the actual caller/effect inventory,
guarded installer and qualification. The [review report](../storage-review-follow-up.md)
preserves the starting behavior and measurements for `REVIEW-HISTORY-3`.

## Goal and scope

When several accepted actions await general current-row reduction, capture the
accepted target once, build one checked history graph and compute the final
current rows and authoring context from it. Install that complete result in one
guarded transaction. Retain every intermediate action, revision and relationship
for Note History, conflicts and Undo/Redo.

The initial implementation applies to returning-open recovery before an editable
model has been published. Keep the ordinary indexed catch-up path for actions
that it can handle directly. On encountering an action requiring the general
reducer, prepare the whole remaining captured prefix instead of rebuilding an
overlapping graph for each remaining batch. Healthy opens with up-to-date rows
continue to perform zero history-graph construction.

The work bound is **one general catch-up graph and one final reduction per
successful stable-target attempt**, regardless of the number of unapplied
batches. An invalidated or interrupted attempt may repeat. Count all attempts in
end-to-end measurements. Bootstrap/snapshot proof work is separately measured;
this bound does not erase its independent verification obligations.

Use existing tables, encoded formats and actor/worker boundaries. The new state
is a short-lived captured context and prepared result. Release the graph after
preparation. This increment introduces no persistent cache or additional recovery
sidecar.

## Authority and starting evidence

- [Specification](../../../iCloud-Drive-Support-Spec.md): START-01, CKPT-01,
  DUR-01, HIST-01 and PUB-01; accepted history and required private state survive
  independently of derived-row preparation and installation.
- [ADR 0016](../../../adr/0016-repair-from-validated-immutable-copies.md),
  [CONTEXT](../../../../CONTEXT.md) and [LocalStore](../../LocalStore.md):
  exact accepted prefixes, reconstruction, ownership and final publication.
- [S3/S4 plan](../phase4-bootstrap-reconstruction-plan.md),
  [Swift proposal](../swift-storage-library-proposal-v2.md),
  [safety contracts](../phase4-data-safety-contracts.md) and
  [conformance strategy](../swift-storage-conformance-testing-strategy.md):
  complete reduction, private issuance, independent observations and crash tests.
- [TLA coverage](../../../tla/README.md#private-sqlite-transaction-and-fast-start-mapping):
  acceptance, materialization and publication remain distinct transitions.

Before this increment, `DatabaseLane.catchUp` called the indexed ordinary path one acceptance
batch at a time. If that batch required general reduction,
`materializeGraphBatch` captures `start + 1`, constructs `retainedGraph` through
that target and replaced the complete current table. The next such batch repeated
the earlier work.

The existing `unappliedCompensationBatchesRecoverEveryAction` witness retains an
edit followed by four actual Undo/Redo actions while leaving current rows behind.
The starting reopen correctly preserved the two current values, seven action records, exact
envelopes and subsequent Undo eligibility, but constructed four graphs and
performed 57 envelope decodes. Those are baseline work counts for that fixture, not a
startup timing estimate.

The [envelope-decoding plan](at-most-once-envelope-decoding.md) reduces repeated
decoding *inside* each traversal. This plan removes repeated traversals *between*
recovery batches. Implement and measure the two increments separately, then
qualify their combined path.

## Recovery algorithm

### 1. Establish the eligible caller

Audit every `catchUp` caller, including returning open, receive/ready processing
and save completion. Record which effects are acceptance-time obligations and
which consumers can observe intermediate materialization. Thread a narrow
internal recovery mode through the opening path, including its ready-work drain,
so that nested catch-up calls use the same eligible route. Merely optimizing the
last `LocalStoreSession.open` call would miss work performed during that drain.

Initially enable coalescing only while the owner is preparing its first editable
model. Live-session save and receive callers keep their existing route until
their publication/pending-work interactions are independently qualified. A
caller eligibility failure chooses that route; corrupt or unsupported history
retains its actual failure classification.

Required ready work, complete bootstrap checks and outstanding verification
obligations still precede editable publication. Optional-ready classification is
a [separate investigation](benchmark-backlog.md#optional-snapshot-work-before-editability).

### 2. Capture one exact target

On the database actor, capture a consistent context containing:

- Owned connection/store incarnation, selected collection/descriptor and
  bootstrap identity.
- Exact starting `view_meta`, including represented sequence `S`, view epoch,
  reducer version and authoring context.
- Accepted target `H`, with `S < H`, and the supported verifier/reducer context.

`H` describes a complete locally accepted prefix. Arrival sequence bounds the
records available to the reducer; causal relationships inside those records
determine their meaning. Changes accepted after capture belong to later work.
The target says nothing about undisclosed provider history.

Retain the existing short actor turns for database reads. Complete expensive
verification and reduction on the history worker, with cancellation/yield checks.
Avoid holding a SQL write transaction or admission lock while constructing the
graph.

### 3. Prepare the complete final view

Read/check the graph through `H` once using the shared retained-history reader.
Verify complete membership, exact occurrences and action relationships under
the existing rules. Run the existing general reducer over that captured history
and compute the complete operation frontier and collection action-scope maxima.
Current cells retain the per-note references and context required for later
editing, deletion, restoration, conflict resolution and compensation.

Coalescing applies to installation of disposable current rows. Every accepted
action still participates in reduction. An Undo followed by Redo, or a Delete
followed by fresh-birth Restore, cannot be reduced to a last-arriving body.
Body-equal results can have different frontiers and continuation rights.

Share final-state preparation with the existing graph materializer where its
contracts match. Keep snapshot-seeded reconstruction's separate proof and
affected-scope rules intact; invoking full snapshot verification solely to reuse
its installer would reintroduce unrelated work.

The result is an immutable prepared value containing complete cells/context and
the captured installation context. Use the
[verification-reminder mechanism](durable-verification-recovery.md) from the
preceding improvement for the complete logical verification, including final
graph/reducer checks. Reaching
the end of envelope reading alone cannot discharge that obligation.

### 4. Install atomically and finish publication checks

Within the actor's existing transaction boundary:

1. Recheck physical ownership, connection/store/descriptor and bootstrap context,
   supported reducer and required-history health.
2. Require the exact starting view metadata and accepted target still to match
   the prepared context. For this first recovery route, use `acceptedThrough == H`.
3. Replace current cells and authoring context together and advance the represented
   prefix directly from `S` to `H`. Use a fresh view epoch for the complete
   replacement, consistent with the exceptional-reconstruction installation rule.
4. Preserve acceptance membership, retained frontier, required private settings,
   pending inputs and durable ready/wait/rejection state. Update only the derived
   rows/context and the independently justified verification completion state.

If the target or starting view changed, discard the preparation and recapture.
Finite interference must be followed by progress without another incoming event.
Cancellation leaves accepted history and durable retry obligations intact.

After installation, continue returning-open catch-up and the final complete-row
capture/publication fence. Further accepted work must be incorporated before
editable publication. Reusing the initial row capture is a separate backlog item.

## Language-backed boundaries

Use one narrowly scoped prepared-result type with a private initializer and a
checking preparation factory. Bind it to the actual owner connection and captured
view/history context; collection IDs and equal sequence numbers alone cannot
authorize installation. Prefer reusing existing contextual types to introducing
wrappers that certify the same fact twice.

The database actor owns SQL access and the final synchronous transaction. The
worker receives immutable `Sendable` inputs. The prepared result grants only
derived-row installation authority: accepted-history receipts remain issued by
the acceptance transaction. Runtime consumer checks establish freshness even
when Swift accepts a value of the correct type.

Add ordinary-client and same-module construction probes, including a probe in the
issuer's own file outside its allowed construction scope. Challenge the actual
installer with a correctly typed result from another connection, another view
epoch and another captured prefix. Preserve strict concurrency/memory-safety
diagnostics and the current actor executor design.

## Implementation gates

| Gate | Work | Required evidence |
| --- | --- | --- |
| G0 — Caller/effect inventory | Trace catch-up through open and ready draining; measure the existing multi-compensation fixture | Identify every intermediate-row consumer and acceptance-time effect; preserve the current passing semantic checks |
| G1 — Shared preparation | Capture `H`, build one graph and prepare complete final cells/context | Private issuance; independent results agree with both full reduction and the existing per-batch reference |
| G2 — Guarded recovery installation | Enable the unpublished-open route, including nested ready-drain catch-up | Exact starting-view/target fences; one atomic replacement; stale attempts resume after interference |
| G3 — Failure qualification | Process cuts, injected I/O failures, wrong-context consumers and mutation challenges | History/private state survive; fresh opener gets the exact result or explicit failure; actual optimized path is exercised |
| G4 — Work qualification | Compare baseline, envelope reuse alone and combined optimization | Stable recovery uses one graph; healthy/ordinary paths preserve their work bounds; publish timings and memory limits |

If G0 finds an essential per-batch side effect currently hidden in materialization,
preserve or explicitly relocate that effect before enabling coalescing. Record
the affected contract and qualify it. Keeping an unqualified caller on the old
route is acceptable; counting that route as a successful optimized witness is not.

## Test matrix

Run each functional schedule for both provider profiles using real SQLCipher
stores. Compare independent values/identities/references, not just two reducers
agreeing or the number of rows.

| Case | Schedule | Required observation |
| --- | --- | --- |
| RG01 — Existing witness | Edit, Undo, Redo, Undo, Redo accepted before reopen | Exact bodies, all seven action records/envelopes and next Undo candidate; one recovery graph |
| RG02 — Mixed suffix | Ordinary edits, rich actions, multi-note groups, duplicate-only/repacked acceptance batches | Every genuine action contributes once; exact retention and correct final context; duplicates still covered |
| RG03 — Connected lifecycles | Merge → edit → remote Delete → Restore; reciprocal conflict copies → copy deletion → new source revision; include a selected three-writer history | Births, deleted originals, preserved contents, unresolved alternatives, dispositions and compensation candidates independently correct |
| RG04 — Equal visible values | Body-equal compensation/label/relationship changes and view replacement at the same numerical prefix | Full context changes preserved; stale preparations rejected even when bodies/sequence agree |
| RG05 — Target interference | Accept new history or rebuild rows after graph preparation; then cease interference | Old preparation cannot overwrite the new basis; recapture finishes without further delivery; all attempt work counted |
| RG06 — Settings and host boundaries | Settings update while preparing; delayed save completion with a newer pending edit/Delete on the live caller route | Latest private settings preserved; acknowledgment clears only its covered generation; unpublished-open optimization cannot leak into live publication |
| RG07 — Crash and repeated failures | Terminate before install, during SQL transaction, after commit before completion, and during the next recovery; inject EIO/FULL/busy | Either old complete derived view or new complete view survives; accepted history/private state unchanged; fresh process recovers exact final state |
| RG08 — Damage and diagnosis failure | Missing/corrupt required history during preparation; fail diagnosis writes and restart again | Existing health classifier and durable verification obligations retain the failure; no editable stale prefix |
| RG09 — Incomplete/unsupported prerequisites | Park a late action, withhold a prerequisite, or require an unsupported reducer | Complete accepted history retains its defined outcome; waiting input remains retained; unsupported accepted state cannot become partially editable |
| RG10 — Snapshot and branch boundaries | Snapshot logical cut excludes earlier-arriving branch; transport envelope contains extra complete groups | Entire target history remains represented; snapshot applicability checks retain their separate coverage and counters |
| RG11 — Consumer authority | Wrong store/connection/bootstrap, same-type stale target/view and constructor probes | Actual installer rejects before row mutation/publication; restricted construction remains compiler-enforced |
| RG12 — Route and scaling | Healthy current rows, ordinary-only suffix, and increasing complex suffixes | Healthy graph count zero; ordinary route retains its existing bounds; eligible stable complex recovery constructs exactly one graph |

For RG07/RG08, the child receives only surviving storage and normal unlock/selection
inputs. Inspect exact envelopes, operation/action membership, required private
records and resulting continuation independently. Keep process termination,
simulated persistence loss and subsequent corruption as separate fault classes.

Mutation challenges must catch: computing only the last action, advancing through
`H` with rows from an earlier prefix, omitting a cross-note member, retaining stale
scope parents, skipping epoch/connection/target checks, overwriting newer settings,
publishing before commit and clearing verification state before final checks.
Require valid companions, nonzero discovery and failure at the intended consumer
assertion. Replace REVIEW-HISTORY-3's known-issue block only when its real optimized
route passes alongside all semantic assertions.

### Work and latency measurements

Use fixed note counts/sizes and controlled frontier width. First keep accepted
history fixed and vary the starting materialization so 1, 4 and 16 complex batches
remain unapplied. Then vary accumulated history (64, 256 and 1,024 actions) at a
fixed lag. Include packed and unpacked envelopes and both profiles.

Record graph builds, required envelope decodes/bytes, reducer invocations, SQL
reads/writes, preparation time, longest database transaction and total open-to-
editable-model time. Measure peak memory separately. Include all failed/restarted
attempts and separately identify bootstrap/snapshot proofs. Timing remains an
observation; exact work bounds and independent semantic checks are assertions.

One graph still takes history-proportional memory and work. The full-table
installation can hold the writer for a substantial interval; compare its duration
with the existing per-batch full-table replacements. This increment reduces repeat
work rather than making exceptional recovery history-independent. Future live-
session reuse requires additional save-latency and pending-publication qualification.

## Model correspondence and completion

Check `SQLiteFastStartSafety`, `SQLiteCollectionSafety` and
`SnapshotReconstructionSafety` against the concrete transition. Coalescing several
derived-row installations changes a schedule even though retained-history and
publication guarantees stay the same. Where a model assumes one batch per update,
add a bounded coalesced-recovery action with actual intermediate actions contributing
to the independently expected final state. Preserve assertions for exact represented
prefix, atomic rows/context, retained history, private state and stale publication.
Challenge omission of a middle compensation and use of a later uncaptured action.
Avoid defining correctness as equality to the same helper used by the transition.

Run applicable models when implementing that correspondence change. Run debug and
optimized suites, construction probes, independent fixtures, affected process and
mutation campaigns, and available macOS/Linux checks through existing drivers.
Record unavailable platform and physical-power-loss qualification explicitly.

Completion requires the optimized real opener to satisfy RG01–RG12 and the work
bounds, with existing startup/current-save guarantees intact. Update LocalStore,
the implementation contract and review report with actual results. Consult the
[validation report](validation.md) for implemented coverage and qualification limits.
