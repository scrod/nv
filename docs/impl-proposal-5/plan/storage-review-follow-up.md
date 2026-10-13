# Storage review: executable witnesses, type boundaries and proposed remedies

Date: 2026-10-03; implementation follow-up 2026-10-04. This report preserves the
original review witnesses and measurements. REVIEW-DAMAGE-1, REVIEW-HISTORY-2
and REVIEW-HISTORY-3 now have implemented remedies and ordinary assertions;
REVIEW-START-1 also has the [4F checked-capture remedy](phase4-current-row-locality-maintenance-validation.md)
as of 2026-10-07. As of 2026-10-08, REVIEW-START-2 and REVIEW-HISTORY-1 have
qualified portable Runtime remedies and ordinary assertions; their broader qualification is
recorded in the [startup/scoped-query report](phase-4-improvements/startup-and-scoped-queries-validation.md).
Sequential snapshot-root growth has the qualified explicit-retention-parent remedy;
independent concurrent frontier width retains its separate scaling gate. See the
[snapshot-retention report](phase-4-improvements/snapshot-retention-coverage-validation.md) and
[improvement validation report](phase-4-improvements/validation.md) for current
qualification. Storage, conflict, deletion and Undo policies remain intact.

Follow-up, 2026-10-04: the
[durable verification recovery plan](phase-4-improvements/durable-verification-recovery.md)
develops REVIEW-DAMAGE-1 using reminders scoped to complete verification operations.
It supersedes the blanket unclean-session audit as the preferred implementation
direction. The
[at-most-once decoding plan](phase-4-improvements/at-most-once-envelope-decoding.md)
then develops REVIEW-HISTORY-2, including packed membership and snapshot reference
audits. The [recovery graph-reuse plan](phase-4-improvements/recovery-graph-reuse.md)
develops REVIEW-HISTORY-3 through one checked final-prefix preparation before
editable publication. The [benchmark backlog](phase-4-improvements/benchmark-backlog.md)
records the completed capture, startup/scoped-query and sequential snapshot-root
remedies, plus remaining concurrent-width measurements. The original measurements
below describe the starting implementation. The
[validation report](phase-4-improvements/validation.md) records the new results
and remaining qualification limits.

Authority: [START-01, CKPT-01, DUR-01 and REPAIR-01](../../iCloud-Drive-Support-Spec.md),
[ADR 0016](../../adr/0016-repair-from-validated-immutable-copies.md),
[CONTEXT](../../../CONTEXT.md), [LocalStore](../LocalStore.md),
[S3/S4 gates](phase4-bootstrap-reconstruction-plan.md) and the
[conformance strategy](swift-storage-conformance-testing-strategy.md).
The [TLA coverage boundaries](../../tla/README.md) remain applicable: the models
establish abstract transaction/reduction properties. The new verification and
coalesced-recovery models additionally cover interrupted checks and complete
final-prefix installation; measured decoding cost remains executable evidence.

## Implemented compiler boundaries

- `CurrentNoteProvenanceV1` makes revision, derived and automatic provenance
  mutually exclusive. `CurrentNoteCellV1` stores that enum and exposes read-only
  projections for existing consumers. Its constructors continue to check exact
  represented references, heads, result digest and deterministic identity.
  The compact V1 and extended V2 cell layouts retain their respective bytes
  through this API refactor; independent fixtures and a mixed-claim decoder
  challenge verify this. Construction now uses `provenance:` rather
  than two independent optional arguments. The library is unreleased.
- `RetainedGraph` has a private constructor. Its file-private checking factory
  issues complete accepted prefixes after occurrence maps and operation/action
  links agree. `causalCut` derives a bootstrap-complete, whole-action cut from
  an already checked graph, with the existing cancellation/yield behavior.
  This concentrates the structural evidence boundary; it does not claim that
  Swift itself proves semantic graph validation or the authenticity of a
  maliciously altered database.
- `MaterializationRoute` exhaustively dispatches action kinds and operation
  effects. Adding a variant requires a compiler-checked decision instead of
  implicitly inheriting an ordinal comparison's behavior. Existing reducer
  selection is unchanged.

Ordinary-client and same-module Core probes test the provenance API; Runtime
probes test checked reading/cutting and prohibit construction from another
source file and from an unrelated function in the issuer's own file. The
existing exact source-line/diagnostic checks and strict concurrency/memory-safety
flags remain required. These changes add no persistent tables, fields, sidecars
or long-lived validation cache.

## Tests and interpretation

`StorageReviewTests.swift` runs both provider profiles against real SQLCipher
stores. Tests check independently expected values, exact retained envelopes,
acceptance membership and subsequent command behavior. Optional connection-owned
qualification counters now observe encoded/decoded history bytes, current-cell
decodes, retained-leaf checks and graph loads. They measure work, not peak live
memory or physical device reads. Normal execution has no measurement object.

Each known-issue block encloses only its named desired assertion. Functional
preservation, valid companions and input retention stay outside those blocks.
An unexpectedly satisfied assertion requires reviewing/removing the known-issue
marker. These witnesses document unfinished qualification rather than declaring
the affected performance or interrupted-diagnosis guarantee passed.

| ID / test | Current status and required observation |
| --- | --- |
| REVIEW-START-1 / `returningOpenDecodesCurrentCellsOnce` | Implemented: one complete current-row decode for open plus initial host capture. Healthy opening still reads no old Changes payloads. |
| REVIEW-START-2 / `optionalReadySnapshotKeepsReturningOpenHistoryBounded` | Implemented: independent optional verification begins after actual checked host publication. The root/pages remain durable and finish through the reserved receive worker. |
| REVIEW-START-3 / `repeatedSnapshotsKeepReturningOpenLeafWorkBounded` | Implemented: general-v1 explicit retention parents reduce a sequential chain to one startup root check while preserving every accepted byte. Independent concurrent tips remain until explicitly covered. [Qualification](phase-4-improvements/snapshot-retention-coverage-validation.md). |
| REVIEW-HISTORY-1 / `scopedCommandsAvoidUnrelatedHistoryBodies` | Implemented: Undo/conflict queries for an untouched note read zero historical envelopes and build zero complete collection graphs. Complete global copied-source dispositions remain available. |
| REVIEW-HISTORY-2 / `packedBootstrapGraphDecodesEachEnvelopeOnce` | Implemented: one decode per required Changes envelope per traversal, with exact membership and independent contents preserved. |
| REVIEW-HISTORY-3 / `unappliedCompensationBatchesRecoverEveryAction` | Implemented before first editable publication: one checked final-prefix graph; all seven actions, exact bytes, Current and the next Undo candidate preserved. |
| REVIEW-DAMAGE-1 / `nonfrontierHistoryDamageSurvivesMarkerFailureAndRestart` | Implemented: a durable unfinished-check request survives failed diagnosis writes and blocks damaged reopening. |

The fresh-process driver `test-storage-review-process.py` adds repeated real
SQLITE_FULL failures during the old-segment diagnosis and publication checks,
then terminates before any successful marker retry. The next child receives
normal selection/unlock inputs only. It now requires conservative integrity
failure after discovered damage, alongside healthy interrupted-check recovery
and exact request retention through repeated real write failures. An unrelated
failure or unexpected current value fails the driver.

Initial debug observations (both profiles have equal logical/decode counts):

| Workload | Actual work |
| --- | --- |
| Open and first capture, two notes | 6 current-cell decodes; zero Changes reads or graph loads |
| Ready optional snapshot, 16 / 64 prior edits | 61 / 205 history envelope decodes; one complete graph load |
| Eight snapshots of unchanged notes | Eight required-root envelope checks; zero graph loads |
| Undo plus conflicts for untouched note, 16 / 64 other-note edits | 76 / 268 history envelope decodes; two graph loads |
| Packed 16 / 64-note graph | 24 / 88 decodes; 432,582 / 2,278,589 decoded payload bytes |
| Packed 16 / 64-note exceptional reconstruction | 38 / 112 decodes; 531,133 / 2,667,040 decoded payload bytes |

These counts expose repeated work; they are not claims that decompression alone
dominates latency. Compression, cryptography, Swift record decoding, reducer
work and SQL each contribute. Timings and peak-memory qualification remain
separate from deterministic work assertions.

## Remedies and tradeoffs

1. **Broad alternative: an unclean-session marker.** Before issuing an editable session,
   durably record that this ownership session is open. Clear that record only on
   a healthy close after admitted work settles. A surviving unclean record selects
   an exceptional retained-history audit before renewed editable publication.
   Thus a crash or failed damage-marker write leaves prior durable evidence
   requiring rediscovery. This requires one small persistent lifecycle record
   and additional open/close durability barriers; crash recovery may scan a large
   history. A bounded audit may retain progress, but cannot publish editable
   success before satisfying its required checks. It does not make a failed
   diagnosis write succeed or prove durability against undetectable total rollback.
   The adopted implementation instead scopes durable requests to unfinished
   checks, preserving ordinary indexed startup after unrelated crashes. It adds
   admission/settlement barriers per logical check and bounds active requests at
   64. A whole-prefix interrupted check can still replay the whole named prefix.
2. **Decode by envelope, not by requested member.** For a complete-prefix graph
   read, enumerate accepted Changes envelopes containing applicable membership,
   authenticate/decode one bounded envelope at a time, and insert its applicable
   operations/actions into the graph. Check exact occurrence/index membership,
   duplicate equivalence and transport members outside a snapshot's logical cut.
   Fetch owned bytes on the database lane and do the large authentication,
   decompression and record decoding on the existing history worker; keep the
   captured-prefix and final installation fences.
   Retain record values and compact references, then release the temporary payload.
   This needs no persistent format or long-lived cache. Tradeoff: a more involved
   iterator/membership check, and the graph still occupies memory proportional
   to its required records. A bounded request-local envelope cache is a smaller
   transitional fix, but eviction can reintroduce repeated decoding.
   The [implementation plan](phase-4-improvements/at-most-once-envelope-decoding.md)
   specifies source selection, per-attempt decode assertions, checked occurrence
   reuse, worker ownership and isolated performance qualification.
3. **Reuse one checked graph within recovery.** Capture a stable accepted target,
   build its graph once and calculate the complete final view on the history
   worker. Install under the existing owner/header/target/view fences, preserving
   separately committed history and settings. On interference, reprepare or fall
   back to existing incremental batches; acknowledgment remains at acceptance.
   Tradeoff: a larger private preparation object and potentially repeated work
   after concurrent saves. A final-prefix installation can skip intermediate
   derived views only after proving no consumer needs those intermediate rows;
   it must preserve every action and subsequent Undo/conflict result.
   The [implementation plan](phase-4-improvements/recovery-graph-reuse.md) begins
   with unpublished returning-open recovery, including catch-up invoked by ready
   draining. It specifies exact target/view fences, independent lifecycle and
   crash checks, and one-graph work assertions. Live-session callers retain their
   current route pending separate qualification.
4. **Read scope metadata before historical bodies — implemented.** Use current represented
   heads and indexed action-scope relationships to select the relevant command
   graph. Load exact bodies for the chosen revisions, inverse effects, merge base
   and related restoration/preservation members only. Empty, fully represented
   scope queries are an economical first case. Tradeoff: more explicit traversal
   of compensation/family/cross-scope dependencies; collection-wide commands
   legitimately touch many notes. Keep the full reducer as an independently
   reference for selected-query comparisons and the route for genuinely broad
   commands. Missing/contradictory selected evidence is an integrity/recovery
   outcome, rather than a fallback to hide failed checks. See the
   [startup/scoped-query report](phase-4-improvements/startup-and-scoped-queries-validation.md).
5. **Separate optional snapshot preparation from startup prerequisites — implemented.** Retain
   roots/pages and their ready/wait state, process required causal Changes work
   before startup publication, and resume optional verification afterward without
   another provider event. Tradeoff: a received snapshot may not be available for
   acceleration immediately; queue classification and wakeup tests become
   necessary. The normative startup and implementation contracts now explicitly
   distinguish required work from independent optional snapshots. Do not
   silently defer an actual history dependency or a required repair input.
6. **Reuse the initial consistent current capture.** Have open validation produce
   the same checked current-row capture handed to the host, rather than discard
   two complete decodes and read it again. An `openWithSnapshot` result is simpler
   than maintaining a second cache. Recheck the session/view/history fence at
   publication. Tradeoff: a host-facing API addition and careful invalidation if
   ready acceptance/reconstruction changes the captured prefix. Pending host input
   remains outside that capture.
7. **Prevent snapshot-only frontier growth through actual retention coverage.**
   Consider a new snapshot representation that explicitly binds its prior
   retained roots as retention parents, independently of its logical operation
   frontier. A newer root can then dominate those roots without deleting their
   bytes. Existing edges must continue to derive from authenticated object data.
   Tradeoff: a format revision, wider concurrent frontiers, extra ancestry for
   fresh reconstruction and explicit verification of retention-only parents.
   Making old snapshots optional to the pin is an alternative policy change,
   with weaker detection of lost snapshot evidence. Merely removing old roots
   from `retained_frontier` or pruning history is not a valid local optimization.

Inside full reduction, a short-lived grouping of existing records by note birth
and action scope can also remove repeated collection-wide searches for each
current cell. It adds ephemeral references, not another maintained graph.
Measure that separately after envelope reuse, since the dominant cost can move.

No remedy is justified by weakening the current-save zero-ancestor checks,
discarding conflict/Undo evidence, shortening lifetime history, accepting an
unsupported partial collection or skipping a required dependency. Implement
one remedy at a time against these witnesses and the connected lifecycle tests.

## Original review qualification

These are the starting campaign's results. The
[improvement report](phase-4-improvements/validation.md) records subsequent
qualification and resolved assertions. The linked startup/scoped-query report
records startup/query qualification; the separate
[retention-coverage report](phase-4-improvements/snapshot-retention-coverage-validation.md)
records the subsequent remedy for sequential snapshot-root growth.

- Full local debug and optimized suites: 218 active functions (220 entries
  including two skipped opt-in benchmarks) each, with 20 expected
  known-issue instances across the seven IDs above; 574.066 / 300.496 seconds.
  Logs: `/tmp/nv-storage-review-full-debug.log` and the optimized common driver's
  `swift.log` under `nv-storage-phase2-ksuqvkdu` in the local temporary directory.
- Nine affected functions on Ubuntu arm64 / Swift 6.4: passed with the same 20
  known-issue instances. The full Core construction probes and six focused actual
  graph/routing compiler probes passed there, with their diagnostic classifiers.
- Four isolated mutations: ordinary Undo routed to current rows, body-only
  continuation reuse, unchecked snapshot claims and omitted whole-action cut
  membership. Each reached its designated assertion; baseline and discovery
  checks passed. Artifact: `nv-runtime-mutations-lwekvnrh/results.json`.
- The new repeated-write-failure child schedules reproduced REVIEW-DAMAGE-1 for
  both profiles on macOS and Linux. The Linux schedules also passed with the
  hardened probe, preserving the same separate known-issue classification.
- Independent current-cell, current-state and general-snapshot fixtures passed.
  The unchanged byte layouts and schema remain part of common qualification.
- The optimized common driver completed all 32 commands: 218 active functions
  discovered, 39 Core and 119 Runtime construction/isolation probes, 17 schema
  tests, independent fixtures, all existing child/generated/rejection schedules
  and strict C-adapter diagnostics. Artifact:
  `nv-storage-phase2-ksuqvkdu/results.json`; driver log:
  `/tmp/nv-storage-review-qualification.log`.
- The ordinary Linux bfd link still fails the W^X observer. The documented
  `-use-ld=lld`, `-z relro`, `-z now` variant passed PIE, W^X, non-executable
  stack and RELRO checks plus the observer's RWX negative control. Its repeated
  child schedules passed. This qualifies that build variant, not the default
  Linux packaging configuration; no permission assertion was relaxed.
- `build.sh` reached Xcode 27's existing macOS 11.5 target diagnostic. The same
  app build passed with the previously documented explicit
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` setting, retaining the target.
  Editor and application source remain unchanged.

Physical power loss, fresh Intel/macOS 11
execution, actual provider publication, application/UI integration and worst-case
lifetime-scale peak memory remain separate gates. No TLA safety condition or
modeled behavior changed; these observations expose costs and an interrupted-
diagnosis boundary beyond the current abstract models.
