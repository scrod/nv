# Remaining Phase 4: current rows, locality and safe maintenance

Date: 2026-10-05. Status: **implementation and qualification plan**. This document
orders 4F and the closing Phase 4 checks. It records planned work, not executed
results or new product-policy decisions.

Implementation update (2026-10-07): F1 framing/dictionaries, F2 checked capture
reuse and F4's explicit headless operation are implemented. The
[contract](private-current-row-codec.md) and
[validation report](phase4-current-row-locality-maintenance-validation.md) separate
executed checks from remaining gates. F0 has a production warm-load baseline;
cold/residency, allocation/peak-memory and larger whole-store experiments remain.
F3 retains the qualified 4-KiB geometry and omits physical hints; neither the
16-KiB candidate nor read-ahead is selected. Automatic VACUUM/retraining/recoding
remain disabled. F5's three policy/format investigations retain their witnesses.
The ordered sections below remain the qualification obligations, not a claim
that every optional experiment has been executed.

The portable 4A–4B snapshot/bootstrap/reconstruction paths and 4C–4E private-state,
backup/repair/activation and copy/export paths are implemented. Their reports
remain the evidence for their tested scope:
[S3/S4](phase4-bootstrap-reconstruction-validation.md),
[4C–4E](phase4-private-state-repair-copy-validation.md) and
[the three completed improvements](phase-4-improvements/validation.md).
Extend those paths rather than replace them with another startup representation.

## Authority and scope

Follow the [Phase 4 obligations](phase4-startup-recovery-plan.md),
[normative startup requirements](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state),
[LocalStore](../LocalStore.md), [ADR 0002](../../adr/0002-require-an-acceptable-startup-store.md),
[ADR 0005](../../adr/0005-separate-startup-cache-private-state-and-visible-history.md),
[CONTEXT](../../../CONTEXT.md) and [model boundaries](../../tla/README.md#private-sqlite-transaction-and-fast-start-mapping).
Apply the [Swift language-enforced design](swift-storage-library-proposal-v2.md)
and [conformance strategy](swift-storage-conformance-testing-strategy.md) at every
increment, including actual consumers, independent observations and mutations.

Already selected:

- One encrypted private SQLCipher database per local store; complete current
  values and editing context load before publication. Healthy returning startup
  uses current rows and indexed required work, rather than replaying all history.
- Zstd for new compression. The current-row candidate uses **level 3**, at most
  **1,024 candidate notes / 8 MiB** of training input and an **8-KiB dictionary**.
  These optimization budgets leave all notes eligible for saving.
- Optional opportunistic full VACUUM, subject to measured eligibility and safe
  interruption. Keep `auto_vacuum=NONE`; required persistence takes priority.

The production physical format and warm Swift startup now have the executed
checks in the linked 4F report. Remaining qualification covers cold/residency and
allocation/scale measurements, alternative cipher geometry, read-ahead benefit
and lifecycle, automatic maintenance thresholds and large-store resumed-save
latency. The
[locality strategy](clean-quit-locality-strategy.md) and
[dictionary experiments](zstd-shared-dictionary-validation.md) supply candidate
mechanisms and their limitations, not a production certificate.

Keep provider adapters, projection installation, application UI and credential
provisioning in Phases 5–7. Use the existing headless host and startup comparison
harness; measure full note/search initialization without changing search or
editor code. Preserve epoch-4 compatibility in the Mac application. The packed
cache remains removed.

## Ordered increments

| Order | Deliverable | Gate before expanding |
| --- | --- | --- |
| F0 | Production-path baseline and caller inventory | Independent current/history/private observations, complete work accounting |
| F1 | Versioned independently decodable current cells and bounded dictionaries | Byte fixtures, all readers/writers, crash-safe mixed generations and recovery |
| F2 | Evaluate and, if justified, reuse the initial checked row capture | Measured benefit plus production publication/context checks |
| F3a | Cipher page-geometry qualification | Whole-store costs and every connection/recovery route, not startup alone |
| F3b | Optional physical read-ahead | Safe no-hint equivalence, bounded lifetime and useful complete-launch benefit |
| F4 | Idle full-VACUUM qualification and scheduling | Settled interruption, timely durable saves, exact retained state |
| F5 | Resolve or explicitly disposition the remaining performance investigations | API/policy/format review where required; retain failing witnesses |
| F6 | Connected regression and platform handoff | Revision-bound results, outstanding gates and honest completion status |

Complete each increment with executable checks before widening it. F3a and F3b
are separate experiments; neither becomes a prerequisite for F1 correctness.

## F0 — Baseline and complete-path accounting

1. Inventory every current-cell consumer: materialization eligibility, ordinary
   checked-basis validation, current capture/presentation, general reduction and
   reconstruction, backup auditing, salvage/repair and current-value export.
   Include raw-cut backup comparison separately from post-recovery comparison.
   The [4C–4E report](phase4-private-state-repair-copy-validation.md) documents why
   these comparisons have different targets.
2. Measure actual `LocalStoreSession.open` through the first usable host capture,
   complete note/context construction and synchronous search initialization.
   Retain raw canonical rows as the correctness and performance control. Count
   current-cell decodes, encoded/expanded bytes, SQL work, dictionary setup,
   retained-leaf checks, history reads, allocations and peak live memory. Include
   owner/key/journal recovery and final publication checks in the full result.
3. Separate current-row loading from ready-work processing, required verification
   replay and exceptional reconstruction. Grow old history at fixed current
   values; separately grow live notes/body sizes and required pending work.
   Report the four existing review findings explicitly rather than attributing
   their costs to compression or disk locality.
4. Run fresh, aged and post-compaction fixtures: edit/growth, Delete/recreate,
   rename/label changes, conflicts, compensations and repeated close/reopen.
   Include small collections, long notes, broad authoring context, varied prose,
   Unicode and poorly compressible text. Use synthetic/non-sensitive input and
   independently declared final values/references.

**Gate:** the baseline reaches the real consumer, accounts for complete startup
and detects changed/missing values or context. Follow the
[existing benchmark](aged-current-row-startup-validation.md): time actual row
I/O, decoding and full host/search construction, with eviction, residency setup,
instrumentation allocation and independent oracle comparisons outside the
measurement. Verify claimed cold reads from residency/I/O observations; label
warm, file-cache-cold and other conditions accurately. Record storage/toolchain
and distributions/outliers. Establish performance criteria from these workloads
before selecting defaults; timing alone supplies no semantic acceptance rule.

## F1 — Physical current-cell codec and dictionaries

### Representation and byte contract

Keep `CurrentNoteCellV1` and authoring-context canonical semantics as the inner
records. Add a small separately versioned private storage framing for raw,
dictionary-free zstd and dictionary-backed zstd cells. Freeze its field table,
tags, exact encoded/expanded lengths, reference presence, frame/window bounds
and complete-consumption rules before enabling the writer. Specify how existing
raw cells are recognized without ambiguous fallback parsing. These unreleased
private formats need no epoch-4-readable mirror.

Store exact immutable dictionary bytes under their content digest in the same
encrypted database. A frame's shorter zstd dictionary ID is a consistency check;
it cannot replace the full digest association. Prefer one small derived-metadata
role for dictionaries, with explicit reference transactions. Keep it distinct
from required settings/pending groups and retained-history evidence. Freeze any
necessary schema revision and its initialization/unsupported outcomes with the
codec contract; never initialize an existing incompatible store over its data.

Extend the pinned zstd boundary separately from the existing dictionary-free
provider frame profile. Provider envelopes, snapshots, semantic identities and
retry bytes stay unchanged. Dictionary bytes belong to private materialization;
portable history remains independently reconstructible.

### Production path

1. Centralize row encode/decode so every F0 consumer uses the physical codec.
   Decode one bounded cell into unpublished final values/context; bound temporary
   buffers and consume the whole canonical record. Retain strict birth/value/
   represented-head/provenance/frontier validation. SQL column borrows and C
   buffers remain scoped to their valid statement/call lifetimes.
2. Prepare ordinary compression outside the short materialization transaction,
   on the existing bounded work resource. Bind output to the captured
   store/session, view and target. A stale preparation is discarded/recomputed;
   it cannot install old values, advance context or acknowledge a save.
3. Compare framed sizes including dictionary-reference overhead. Permit raw
   fallback and plain level-3 compression when dictionary compression is worse.
   Qualify the selection rule against drifted and poorly compressible inputs.
   A compression/training resource failure can use a valid fallback; a shared
   database failure retains its actual storage outcome.
4. Train only from consistently captured resident current values, within the
   adopted candidate/input/output caps. Bound candidate visits and avoid encoding
   an oversized sample just to discover its size. Train at most once per captured
   generation. Too few samples, cancellation or failure permits reuse/plain/raw
   saving. Record a bounded retraining eligibility rule after measurement;
   all-row recoding or training on every quit is not a requirement.
5. Commit new dictionary bytes and the rows that use them atomically, under fresh
   view checks. Allow rows from different dictionary generations to coexist.
   Preserve each referenced old dictionary. Load dictionaries named by the
   captured rows, rather than enumerate every historical/unused dictionary.
   Decoder preparation is reused within a load/job, with a measured memory
   budget; a valid collection with many referenced dictionaries must stream/
   reprepare rather than hit a lifetime count limit.
6. Keep any recoding incremental and representation-only. It authors no action,
   changes no accepted membership/pin/settings and preserves the exact logical
   view. Use existing view/lifecycle fences plus the qualified layout reservation;
   test same-prefix races explicitly. Dictionary reclamation requires a complete
   reference/lifetime check; skipping cleanup is safe. Begin without persistent
   reference counts or a separate cleanup journal.
7. Missing/invalid derived framing or referenced dictionary contents require complete
   materialization reconstruction from healthy retained evidence. Shared page/
   SQLite damage, known required-history loss and private-state loss retain their
   different recovery outcomes. Never return an editable subset or reset settings.
   Backup carries the dictionaries needed at its fixed cut; repaired current rows
   may be regenerated from history. Preserve raw-cut equality checks before
   ordinary destination recovery processes captured ready work.

**Gate:** independent valid/malformed bytes, mixed dictionary generations and
real crash/reopen consumers pass under both profiles. Normal save and first-save-
after-reopen work bounds remain intact. Complete launch measurements demonstrate
the chosen configuration's benefit/cost, including encoding and dictionary
setup; a smaller BLOB alone does not establish faster launch.

## F2 — Reuse the first checked current capture

`REVIEW-START-1` originally observed three decodes per cell across opening and
first capture. The implemented one-shot handoff reuses the existing checked
capture through `snapshot()`; its strict witness and stale-consumer mutation are
recorded in the 4F report. The qualification obligations below continue to apply
to that handoff and any later adaptation.

If measured benefit justifies implementation:

- Reuse the actual consistent capture from after required replay/ready processing
  and materialization catch-up. Include complete current values, compact context,
  view/presentation epoch, represented target and store/session association.
- Have the existing final publication consumer check that capture and the live
  host generation. A newer acceptance, equal-prefix rebuilt view, presentation
  change, repair/selection change, close or newer host input invalidates it.
- Keep later snapshot/reduction calls correct after the initial handoff; count
  every opening path, including fallback/rebuild. Release redundant encoded
  buffers rather than share mutable state between actor and host.
- Specify and review the public-result change in the implementation contract.
  Restricted evidence issuance and runtime fences remain mandatory; an ordinary
  `StoreSnapshot` value alone supplies no new publication permission.

**Gate:** complete open-to-host construction improves under equivalent work,
stale consumers still fail, and the review witness becomes a strict passing
assertion with an intended mutation. If the candidate is deferred, retain its
known-issue status and measured cost; do not describe repeated decoding as fixed.

## F3 — Page geometry and optional physical read-ahead

### F3a: measure geometry independently

Compare the current qualified cipher geometry with the 16-KiB candidate on the
same actual rows, history and aging schedules. Measure ordinary save/barrier,
acceptance/lookup, checkpoint/recovery, backup/repair, file size, write
amplification and memory as well as full cold/warm startup. Keep both profile
keys and encryption guarantees unchanged.

Before selecting a new geometry, specify where its versioned profile is learned
and applied **before page access on every connection**, including secondary
backup readers, salvage connections and fresh destinations. Qualify mismatch and
unsupported outcomes. Any conversion uses verified, source-preserving replacement
and ordinary fresh reopening; it is not an opportunistic pragma on a live store.
Startup results alone do not select the global cipher profile.

### F3b: implement a hint only if it earns its cost

1. Capture only the current-note B-tree's physical pages, including overflow,
   under an owned consistent read. Verify the pinned DBSTAT support and the
   actual table-restricted traversal before depending on it. Bound enumeration,
   sorting/coalescing, stored bytes and work. Omit a costly/oversized hint rather
   than reject a collection or truncate its current values.
2. Store the optional hint in the encrypted database with its format, owner/view/
   layout context and cipher geometry. Install it only while the captured layout
   still applies. Reuse existing fences/reservations where possible; justify any
   added layout generation specifically for same-view physical changes.
3. Invalidate in the same transaction as current-row layout changes and durably
   before schema/geometry maintenance, repair/replacement or VACUUM. After
   invalidation, a stale producer cannot put an old hint back. Hint preparation
   stays off required startup/quit work and failure alone cannot fail a saved quit.
4. On returning open, use only the qualified checkpointed main-file path with
   applicable view/layout checks. Skip stale hints after catch-up or live journal
   recovery; main-file offsets cannot describe pending WAL pages. Strictly bound
   ranges, arithmetic, file size, scratch memory and worker count.
5. Read ciphertext using a positively matched owned file handle and a bounded
   I/O resource. All actual values still come from the normal SQL capture and
   decoder. Retain descriptors/buffers until reads settle; cancellation or a
   deadline alone supplies no permission to close/reuse them.
6. Missing, unsupported or malformed *hint contents* fall back to ordinary SQL
   startup. An inaccessible/shared corrupt database retains its real health
   outcome. Wrong but structurally valid page advice must change only I/O, never
   the notes, history checks or publication decision.

**Gate:** measure producer cost, subsequent complete startup and combined F1
benefit separately. Preserve the no-hint baseline and current-row SQL reads.
Select concurrency/coalescing from measurements, starting with adjacent ranges;
the earlier eight-worker result is a candidate, not a portable latency promise.
Freeze hint byte/time/memory budgets only after qualification. Leave read-ahead
disabled or omit it if its benefit does not justify the lifetime/state machinery.

## F4 — Optional full-VACUUM with required-write priority

Use the [adopted maintenance policy](clean-quit-locality-strategy.md#adopted-opportunistic-full-vacuum-policy).
Start with an explicit headless qualification operation. Enable automatic
scheduling only after all of these gates:

1. Capture healthy idle-owner eligibility: no pending required commit, unique
   admitted inputs durable, no incompatible backup/repair/key/selection/close
   work. Reserve one maintenance operation before suspension. Use a small closed
   actor-owned state rather than separate racing flags or another scheduler.
2. Combine elapsed cooldown with measured current-page fragmentation and a
   whole-store cost/space estimate. Collect those observations off the startup
   and required-quit paths. Full VACUUM cost includes unbounded retained history;
   an oversized store/work estimate permits skipping indefinitely. Free-space
   preflight is advisory, so failures after admission remain tested outcomes.
3. Durably invalidate the optional physical hint before beginning. Execute the
   blocking operation on the qualified I/O resource. SQLite's exclusive writer
   work remains real even though it runs away from the interaction thread.
4. Wire resumed required work/quit to interruption through a narrow lifetime-safe
   path that can actually run while the database actor is occupied. Check the
   pinned SQLite interruption contract and connection ownership; posting a
   cancellation message behind the blocked database job is insufficient.
   Avoid a new general actor/unsafe connection-sharing abstraction.
5. Retain the operation, connection and owner until completion/rollback settles.
   Distinguish interrupted, successfully completed, skipped and actual database
   failure outcomes. A late interrupt cannot target the next ordinary transaction.
   Only then resume the required save/quit and issue its own exact durability
   receipt. Cancellation request time is not the save/barrier time.
6. Record successful cooldown separately from attempts, and back off failed or
   cancelled work. Scheduling state is fixed-size private advice; missing advice
   permits conservative skipping. Rebuild a hint only against the new layout.
   Preserve every exact object/descriptor, membership/pin, current/context value,
   settings group, latest/frozen pending input, settlement and verification request.

Calibrate cooldown, fragmentation, headroom, work and latency thresholds against
realistic workloads **after** compaction as well as never-compacted controls.
Measure worst observed resumed-input/quit-to-durable-barrier latency at multiple
VACUUM phases, including rollback and final commit. Require a finite-interference
progress witness. If timely settling is unqualified, keep automatic maintenance
disabled; optional physical layout work cannot replace timely local persistence.

## F5 — Remaining review investigations and decision gates

The [benchmark backlog](phase-4-improvements/benchmark-backlog.md) remains the
detailed starting point for the original four review findings. F0–F2 qualified
current-capture reuse. The later
[startup/scoped-query plan](phase-4-improvements/startup-and-scoped-queries.md) and
[report](phase-4-improvements/startup-and-scoped-queries-validation.md) implement
and qualify two further remedies. Snapshot-root growth retains its known-issue
classification and separate format gate. The table preserves each workstream's
required boundary:

| Finding | Experiment and next gate | Boundary that must remain strong |
| --- | --- | --- |
| `REVIEW-START-2`: optional ready snapshots run before healthy current publication | Implemented: required/optional selection and a successful-publication receive reservation; see the separate qualification report. | Required replay/bootstrap/causal closure still gates editability; optional work automatically resumes without a new file event and validates completely before becoming usable. |
| `REVIEW-START-3`: independent snapshot roots accumulate in the retained frontier | Measure fixed logical history with 1/8/64/256 roots, linear and concurrent writers. Model and review genuine retention-parent coverage separately from logical snapshot frontiers before any format change. | Preserve exact bytes, required-loss detection, missing-parent handling and every concurrent branch; deleting roots from the pin without verified coverage is not a performance fix. |
| `REVIEW-HISTORY-1`: scoped Undo/conflict queries read unrelated history bodies | Implemented: indexed note/scope selection and a shared checked reader, preserving global copied-source IDs with one derived partial index; see the separate qualification report. | Complete multi-note actions, represented alternatives, restoration/provenance and compensation dependencies survive; genuinely collection-wide commands may still require broad work. |

Give each qualified remedy its own implementation/validation increment, with
consumer, failure and mutation coverage. API, startup-policy and authenticated
format changes require their explicit review gates; this plan chooses none of
those changes implicitly. Keep the diagnostic witnesses active until the exact
production fixes pass. Report residual work growth honestly: a faster row codec
does not remove historical work caused by optional snapshots or growing pins.

## Critical test matrix

The `LOC*` IDs below are planned scenario identifiers. Parameterize both profiles
and share the existing real Runtime, SQLCipher/VFS, child-process and mutation
harnesses. Each scenario needs a valid companion, proof that its named boundary
was reached, a precise failure classification and an independent observable
result. Keep targeted fault schedules small before combining them.

| ID / contracts | Schedule or defect | Required observation / intended challenge |
| --- | --- | --- |
| LOC01 / `TC-START-01`, `TC-PERF-01` | Fixed current rows with growing ordinary history; first save after fresh reopen | Complete values/context; no new all-history launch pass, zero ancestor traversal on eligible saves; count every decode/load path. |
| LOC02 / `TC-BYTE-02`, `TC-LIMIT-01` | Raw/plain/dictionary cells; truncated fields, length overflow, unknown tags, concatenated/skippable frames, wrong dictionary, excessive window and trailing bytes | Exact bounded decode or the specified derived-row failure, before oversized allocation; independently written valid neighbors and literal canonical results. Provider dictionary-free framing stays separately tested. |
| LOC03 / `TC-START-01`, `TC-DUR-04` | Crash/write failure around dictionary insertion plus row/context commit; old and new dictionaries referenced together | Either complete previous or complete new transaction; every surviving row decodes, no early release of a referenced dictionary. |
| LOC04 / `TC-EVD-01`, `TC-DUR-01` | Prepare recoding/capture at E; accept F, Delete, equal-prefix rebuild or selection/session change before installation/publication | Reject stale output; F remains durable/pending as appropriate, with exact represented references. Challenge omitted view/owner/live-generation fences. |
| LOC05 / `TC-START-01`, `TC-REPAIR-01` | Remove/corrupt a dictionary or current cell; separately damage a shared page or required retained object | Healthy-history derived rebuild preserves all settings/pending work; shared/required damage blocks complete editable success. Never skip a note or swallow SQLite integrity failure as a hint/codec miss. |
| LOC06 / `TC-LIMIT-02`, `TC-PERF-01` | Few samples, oversized sample, many referenced dictionaries, growing unused generations, cancellation and training failure | Every note still saves; budgets bound optimization input/work, not collection lifetime. Load only applicable dictionaries; unused malformed extras do not block healthy current rows. Raw/plain fallback, bounded decoder reuse and settled worker cleanup. |
| LOC07 / `TC-REPAIR-01`, `TC-COPY-01–02` | Compressed mixed rows during fixed-cut live-WAL backup, failed materialization, captured ready work, complementary repair and export | Compare the exact copied raw cut first, then recovered semantics; exact required history/private inputs survive and fresh destinations unlock. No substitution of current-value export for history copy. |
| LOC08 / `TC-START-01`, `TC-KEY-01`, `TC-PORT-01` | Selected geometry across every keyed connection; mismatched profile/geometry and source-preserving conversion | Normal reopen and complete backup/repair use the declared profile; mismatch has an explicit outcome and leaves original evidence intact. |
| LOC09 / `TC-START-01`, `TC-EVD-01` | Absent/malformed/empty/valid-wrong-page hint; row update or layout change while hint producer is paused | Same complete SQL-derived result; stale hint cannot reinstall after invalidation. Challenge treating successful prefetch as publication or history evidence. |
| LOC10 / `TC-DUR-04`, `TC-START-01` | Crash before/after invalidation/hint commit/checkpoint; live WAL, failed checkpoint and returning catch-up | Safe ordinary no-hint startup; accepted work survives and stale main-file advice is bypassed. A checkpoint failure never retracts a durable edit. |
| LOC11 / `TC-STATIC-02`, `TC-ASY-01` | Held ciphertext read; cancel, close or replace selected resource; late completion | Resources remain owned until settled; no descriptor reuse, stale result publication or effect on a foreign file. Use actual controlled OS handles, not just a token comparison. |
| LOC12 / `TC-DUR-04`, `TC-CLOSE-01`, `TC-PERF-01` | Request save/quit during VACUUM read/rewrite/commit/rollback; then stop interference | Cancellation reaches the live operation, settles and the exact requested save commits within the qualified measured budget. Late cancellation cannot interrupt the next commit. |
| LOC13 / `TC-DUR-04`, `TC-REPAIR-01` | ENOSPC/EIO, busy, process termination and a second failure on maintenance reopen | Required history/private work intact or precisely classified damage; exact retry remains owned, no RAM-only acknowledgment or accidental repair by VACUUM. |
| LOC14 / `TC-DUR-06`, `TC-IMPORT-01` | Maintenance with retained latest B, frozen A, unresolved verification, rejection/dependent waits and nonempty settings | Independently inspect exact bytes, generations, memberships and requests before/after fresh reopen. Challenge lost pending ownership, pin regression or cleared verification. |
| LOC15 / `TC-PERF-01` | Repeated edit/delete/recreate/close cycles after one compaction versus controls; no maintenance ever runs | Measure benefit lifetime, total encoding/I/O/maintenance cost and startup tails; identical logical state without compaction, dictionary tuning or read-ahead. |
| LOC16 / `TC-PRIV-01`, `TC-PORT-01` | Synthetic text/key/path markers through training, hints, VACUUM, temporary files and failure diagnostics | Both profiles retain specified private page protection; no disallowed plaintext/diagnostic spill or added zlib path. Instrument actual temporary-output boundaries. |
| LOC17 / `TC-STATIC-01–04`, `TC-EVD-01` | Ordinary and same-module proof construction, role substitution, duplicate resource transfer, same-type/wrong-context use | Valid API companions compile; invalid clients fail at the marked line/category; production consumers reject incompatible genuine evidence. |
| LOC18 / `TC-START-01`, `TC-PERF-01` | Existing four review witnesses before/after each candidate | Preserve independently expected values and actual work counts. Remove only the fixed witness's known-issue classification after qualified improvement; unrelated findings remain reported. |

Sweep precommit, committed-but-callback-missing, derived commit and restart cuts.
Keep process termination, VFS-simulated persistence failure and later corruption
distinct. Recovery receives normal surviving storage/selection/unlock inputs,
never the parent's expected-note oracle or acknowledgment log. Inspect surviving
exact envelopes/membership/pins, private reference graphs and decoded current
context independently of Runtime success flags. A final equal body alone cannot
show that authoring context, Undo alternatives or unique pending input survived.

## Swift-backed separation and minimal state

Use concrete boundaries rather than a new generic workflow framework:

| Responsibility | Compiler boundary | Runtime/failure obligation |
| --- | --- | --- |
| Canonical note/context | Existing nominal values and exact codecs | Same complete canonical semantics under every physical codec |
| Physical framing/dictionary | Closed format enum, nominal dictionary digest and private checked-frame constructor | Bounds, exact dictionary bytes, full frame consumption and supported versions |
| Prepared current-row change | Immutable `Sendable` output with issuer-confined applicability context | Recheck owned store/session, starting view and target inside the committing consumer |
| Initial checked capture | Restricted preparation/handoff using the existing publication boundary | Final owner/view/presentation/live-generation check; immutable values alone grant no authority |
| Layout hint | Explicit advisory value, bounded codec and confined physical-handle issuer | Hint cannot satisfy history, acceptance or editable-publication prerequisites |
| Maintenance and decoder resources | Existing actor/executor ownership and one closed operation state; selective unique ownership where simpler | Reserve before suspension, retain C resources until settled, scope cancellation to the exact operation |

Keep dictionary decoder preparation job-scoped; add no long-lived history
validation cache. Persist only the physical codec/dictionary references and exact
dictionary bytes needed by surviving rows, an optional bounded hint and minimal
advisory scheduling metadata. Justify each schema field against a concrete
consumer/race. Required history, settings and pending state retain their existing
roles. Transient optimization state cannot replace durable verification requests.

Retain Swift 6.4/Swift 6 language mode, complete concurrency checking, strict
memory-safety diagnostics and warnings-as-errors. Keep unsafe zstd/SQLCipher/OS
borrows in narrow audited adapters. Use borrowing/non-escapable views where the
qualified toolchain/deployment path supports them; actual ownership and C cleanup
remain necessary. Prefer existing actor-owned cleanup when noncopyable bridging
would add plumbing. Avoid public unchecked constructors, broad unchecked Sendable
and safety-disabling build settings.

Add construction probes for any new restricted evidence, exhaustive switches
for format/maintenance outcomes, valid companions and same-type/wrong-context
consumer tests. Target mutations for omitted size/frame/dictionary checks,
premature dictionary release, stale recoding/capture, missing hint invalidation,
late cancellation and early save acknowledgment. A compiler/setup failure,
timeout or undiscovered test cannot count as the intended mutation result.

## F6 — Qualification, records and handoff

1. Extend the existing `test-storage-phase2.py`, fixture/schema, process,
   compiler-boundary and targeted-mutation drivers with explicit named filters
   for LOC cases. Require a freshly built probe, successful build marker and
   nonzero intended discovery. Use independent owned directories/callback gates;
   serialize only scenarios that deliberately share resources. Add no test
   framework or dependency to control scheduling already covered by the harness.
2. Run debug and optimized suites for both profiles; rerun affected Phase 2–4
   crash, backup/repair, pending-input, receipt and ordinary-save work checks.
   Audit new zstd/SQLite/C I/O and cancellation/cleanup branches with instrumented
   dependencies under applicable ASan/TSan. Qualify strict binaries on supported
   arm64/macOS, Intel/macOS and Linux; record unavailable systems and the existing
   oldest-macOS compiler workaround separately from default-toolchain support.
3. Keep [SQLiteFastStartSafety](../../tla/SQLiteFastStartSafety.tla),
   [VerificationRecoverySafety](../../tla/VerificationRecoverySafety.tla) and
   [CoalescedRecoverySafety](../../tla/CoalescedRecoverySafety.tla) publication/
   recovery conditions intact. Byte-codec and locality-only changes need concrete
   tests, not unrelated TLC reruns. If scheduling or maintenance adds a new
   cross-component transition, add a focused model with actual competing save,
   settlement and reopen states, independent assertions and progress witnesses;
   run its designated controls. Policy/retention changes from F5 require their
   own normative/ADR/CONTEXT/model updates before implementation. No model proves
   SQLCipher/zstd bytes, interrupt latency or physical power-loss durability.
4. Freeze completed physical records in their own contract/fixtures and
   [Format TODO](../Format-TODO.md). Update schema/source mappings, LocalStore and
   validation reports with exact revisions, commands, workload, fault reachability,
   mutations, discovered defects and limitations. Run `build.sh` and affected
   epoch-4 compatibility checks after significant implementation changes.

**Completion is separated:** F1 correctness may pass while a geometry/read-ahead
candidate is rejected or automatic VACUUM remains disabled. Record that disposition
explicitly. Do not call unexecuted optional gates qualified. Phase 4's functional
recovery/copy implementation and its performance/platform qualification are
distinct. The initial checked-capture handoff closes one of the four original
performance findings. The later startup/scoped-query and
[snapshot-retention](phase-4-improvements/snapshot-retention-coverage-validation.md)
increments address the other three. Independent concurrent frontier width and
physical journal/I/O costs retain their measured limits; a one-root work bound
does not establish constant-time whole-open behavior.

The Phase 5 provider/root work can use already qualified local boundaries without
implementing these physical optimizations first. Its handoff must list outstanding
Phase 4 gates rather than silently count them as finished. Physical power loss,
actual provider completeness and application UI behavior remain outside the
portable process/VFS results.
