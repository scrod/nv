# Phase 4 S3/S4: complete bootstrap and snapshot-based reconstruction

Date: 2026-10-03. Status: S3/S4 implemented. The
[execution report](phase4-bootstrap-reconstruction-validation.md) records the
completed checks and remaining platform/release limits for the gates below.

Implement **large fresh-store bootstrap first, then reconstruction from a verified
snapshot plus every accepted action outside its represented history**. These are
the completed S3/S4 gates of the [acceptance/recovery plan](phase4-snapshot-acceptance-recovery-plan.md).
[S2](phase4-received-snapshot-validation.md) qualifies received assembly and
acceptance, rather than this reconstruction path. Healthy returning startup
continues to use indexed current rows and required ready/catch-up work.

## Authority and completion target

Follow [START-01/CKPT-01/DUR-01](../../iCloud-Drive-Support-Spec.md),
[startup and retention](../Protocol.md#snapshots-startup-rejoin-and-retention),
[LocalStore's returning-launch algorithm](../LocalStore.md#concrete-returning-launch-algorithm),
[ADR 0002](../../adr/0002-require-an-acceptable-startup-store.md),
[ADR 0005](../../adr/0005-separate-startup-cache-private-state-and-visible-history.md),
[ADR 0016](../../adr/0016-repair-from-validated-immutable-copies.md) and
[CONTEXT](../../../CONTEXT.md). The [Swift language boundaries](swift-storage-library-proposal-v2.md),
[conformance strategy](swift-storage-conformance-testing-strategy.md) and
[Phase 4 safety contracts T01–T05/T10](phase4-data-safety-contracts.md#critical-production-path-scenarios)
govern implementation and evidence. This plan adds concrete work and qualification
gates under those policies.

Success requires fresh-process recovery of complete note values **and** the
history relationships governing subsequent editing, Delete, conflict handling,
Restore and Undo/Redo. Accepted history and required private state survive the
tested derived-rebuild failures. Live pending work remains owned; crash tests
assert survival of committed/retained inputs under the stated fault model,
separately from unpersisted typing. A supported valid
fixture must reach complete editable opening and a subsequent command; perpetual
waiting, an unsupported result or an unnoticed full-replay fallback does not
qualify snapshot-based recovery.

The primary data-loss traps are:

1. Publishing a partial initial import, or labeling initial rows as representing
   a batch that also contains later actions.
2. Omitting a previously received branch because its local sequence predates the
   snapshot, or omitting an extra action sharing a snapshot's referenced envelope.
3. Recovering plausible bodies while losing deletion, retirement, disposition,
   restoration or action context that changes the next user command.
4. Treating known lost required history/private state as disposable row damage.
5. Installing a stale or partially rebuilt view, resetting independent private
   state, or letting a delayed result clear a newer pending edit.

## Starting implementation (before this increment) and bounded scope

| Current production path | Required extension |
| --- | --- |
| `InitialCollectionV1.build` retains all sealed objects; `InitialBootstrapValidationV1` retains decoded closure dictionaries | Incremental sealing/retention and exact store-backed validation, with explicit working-memory measurements |
| `LocalStoreSession.create` initializes, accepts and materializes before returning a session | Resumable, exclusively owned construction that can retain incomplete input without issuing an editable session |
| `ValidatedHistoryBatch.bootstrap` consumes an all-object dictionary | Issuer-restricted store-backed bootstrap input consumed by the same acceptance transaction |
| `recoverMaterialization` rebuilds the original import; `catchUp` applies subsequent acceptance batches | Exceptional recovery from an applicable general snapshot and all accepted history through a captured target |
| `CheckedSnapshotAcceptance` verifies claims against exact accepted history | Reissued, store-bound durable recovery basis and a distinct guarded row-installation consumer |
| `RetainedGraph.currentCells` and the collection/note reducers implement current semantics | Shared reduction of affected scopes from checked snapshot state, with full reduction as a reference/fallback |

Keep one database actor/connection owner, its blocking executor, synchronous
transactions and asynchronous history workers. Reuse candidate objects, accepted
membership, occurrences/edges, wait/ready indexes, private groups and view metadata.
Prefer a small concrete adapter over a second graph engine or persistence layer.
Freeze any necessary private codec/index revision and independent fixtures before
writing it; update both schema copies and explicit open-version outcomes together.

This bundle leaves provider publication, physical note-file actions, AppKit/UI,
final selected-store cutover, backup/salvage activation and the rest of Phase 4C–4F
to their existing gates. It adds neither history pruning nor a packed startup
cache. Existing compression/locality decisions remain separate physical work.

## Implementation order and executable gates

### S3.1 — Store-backed initial verification and incremental construction

1. Introduce an exact-locator read/sink adapter under the existing owner. Stream
   sealed objects into immutable candidate retention and reuse the same bytes on
   retry. Verification reads bounded owned buffers; release statement-backed data
   within its valid lifetime. Share the initial semantic checks between the
   small in-memory test adapter and the production store-backed reader.
2. Preserve Genesis/profile/import identity, canonical sorted initial count and
   digest, complete Import action membership, scope/previous-origin checks,
   ImportComplete coverage, exact page rows and acyclic descriptor binding.
   Use iterative traversal and resumable work budgets. Budget exhaustion retains
   work or an exact restart point; it does not truncate a graph or reject its age.
3. Pack complete import groups and initial rows into bounded envelopes/pages;
   support multiple groups per envelope and multiple import batches. Preserve
   complete action boundaries. Capture/freeze initial values before committing
   their count/digest; changing source input invalidates that construction.
4. Account separately for final note storage, compact graph/identity bookkeeping,
   retained encoded buffers and transient decoding buffers. Removing the sealed
   map alone does not make the decoded-history dictionaries bounded. Use indexed
   lookups where they remove whole-history body duplication; document any remaining
   O(history metadata) work explicitly. Measure time as well as memory so repeated
   ancestor validation cannot silently become quadratic at realistic import sizes.

**Format feasibility check:** initial roots currently use a flat page-reference
list; [general roots](general-snapshot-record-contract.md) use a multilevel tree.
Test packed initial pages under their actual root/object limits and general trees
at several levels. Do not describe the initial codec as already supporting trees.
Before freezing the scalable writer, demonstrate representable target workloads
and nearest legal bounds. If the initial manifest imposes a practical collection
limit, specify and fixture the minimal scalable format adjustment before coding
it; never hide it behind a smaller accepted collection or truncated manifest.

**Gate:** independent fixtures for zero notes, distinguishable many-note values,
multi-note actions, several groups per envelope, batches and page boundaries pass
both readers with identical checked facts. Missing/contradictory inputs fail at
the intended check with a valid companion. Record transient-buffer high-water
marks, reads/decodes and validation work for increasing import sizes.

### S3.2 — Resumable fresh candidate and complete bootstrap acceptance

1. Provide a narrow construction owner with retain/resume/complete/close
   operations. It owns a newly created keyed candidate and its physical lock.
   Ordinary session construction remains confined to the complete-open boundary.
   Both profiles use encrypted private pages and existing validated unlock inputs.
2. Persist enough bootstrap context to resume the exact selected commitment:
   collection/store/profile/descriptor and initial-root identity, using existing
   header/private-group roles where sufficient. Distinguish that staged context
   from committed bootstrap completion. Resume only the positively identified
   owned candidate; never initialize over an incomplete unrelated database.
3. Retain arriving bytes independently of acceptance, including out-of-order
   initial pages and Changes. S2's retained-byte versus accepted-history waits
   remain distinct. Initial closure validation must be able to inspect candidates
   before an ordinary editable session exists; routing it through an opener that
   already requires complete bootstrap would create a circular prerequisite.
4. After complete verification, accept the initial unit with exact bytes,
   descriptor, operation/action occurrences and membership, dependencies, retained
   pin and wakeups in one synchronous transaction. Read the objects through the
   checked store-backed input rather than assembling every envelope in RAM for
   the transaction. Private acceptance and derived materialization stay separate.
   The complete bootstrap commit remains one atomic transaction whose work grows
   with membership; bounded validation turns do not make that final commit
   constant-time. Measure its duration separately. This candidate is still closed
   to ordinary edits, and a transaction cannot yield halfway through acceptance.
5. Validate all complete groups in required envelopes. Distinguish the initial
   commitment's operation cut from incidental later groups transported alongside
   it; pass those groups through the ordinary declared-history validator. An
   envelope containing the imports plus edit E must retain E too. Its single
   acceptance sequence cannot be stamped on import-only rows as if E were applied.
   Build a complete view through the batch, or retain an explicitly unpublished
   seed until all effects have been incorporated.
6. Reopen from committed evidence after interruption. Exact duplicate intake is
   idempotent; unavailable bytes remain named prerequisites. An interrupted local
   creation can resume using retained bytes plus a matching frozen source or
   redelivery. If unsealed input was lost, preserve the candidate/source and report
   incomplete construction rather than inventing values or changing the digest.

**Gate:** a fresh child, given surviving candidate bytes and normal selection/
unlock inputs, reaches a complete two-note and a large many-note collection.
Before completion it returns an explicit construction/waiting outcome. Sweep
termination and real SQL/VFS failure before/after acceptance and materialization,
including lost completion and a second failure on reopening. Concurrent ownership,
wrong credentials and mismatched bootstrap context preserve existing data.

### S4.1 — Checked recovery basis and exact outside-cut history

1. Keep healthy/lagging current-row open on its existing indexed path. Route
   invalid derived rows to reconstruction after required-state/header/key checks.
   Required-history damage uses repair classification, even if a snapshot would
   supply convincing note bodies. Damage found during reads revokes prepared
   publication immediately, independently of damage-marker write success.
2. On the exceptional path, enumerate applicable retained snapshots using indexed
   metadata. Reissue the basis from exact accepted root/pages, bootstrap/protection,
   pin coverage, complete membership and semantic claim checks. Preserve the
   distinction between public integrity and encrypted authentication. An invalid
   unaccepted optional candidate can be bypassed; corrupted accepted required
   evidence cannot be bypassed to claim healthy recovery.
3. Capture accepted target H and the starting view/epoch. Compute the snapshot's
   represented operation ancestry and require whole actions. Enumerate all accepted
   operations through H, subtract represented **logical operation IDs**, and order
   the remaining complete groups by their dependencies. Extra occurrences retain
   their exact bytes without repeating a logical effect.
4. Cover branches received before or after the snapshot, extra groups in its
   referenced envelopes, shared ancestors and repackaged equivalent operations.
   Keep object-dependency closure, causal operation ancestry, note predecessors
   and action-scope maxima distinct. H bounds a local read; it is not a causal cut
   encoded by the sender or a substitute for the set difference.

**Gate:** small hand-declared DAGs independently identify the represented and
outside-cut sets, action membership, order constraints and retained closure.
Every delivery permutation of each bounded fixture yields those sets. Mutations
using `seq > snapshotAcceptance`, object-set subtraction, or partial actions must
fail the designated assertions rather than an unrelated decoder check.

### S4.2 — Shared reduction from snapshot state

1. Use verified snapshot current cells and all seven logical-state record classes
   as the starting state. The later [retention-coverage increment](phase-4-improvements/snapshot-retention-coverage.md)
   verifies v2 parent records separately as object coverage. Carry unaffected
   cells forward. For touched notes/scopes,
   invoke existing ordinary/merge/delete/conflict/compensation rules with exact
   historical lookups as needed. Expand the touched set to linked preservation
   outputs, deterministic retirements and multi-note action members.
2. Track continuation facts separately from visible values. Body equality cannot
   erase represented heads, action maxima, Delete evidence, copied-source
   dispositions, restoration provenance or the identity of a compensation.
   Historical records remain authoritative for history/Undo/Redo queries; portable
   snapshots restore neither native undo objects nor physical file permissions.
3. Keep full reduction as an explicit conservative fallback and comparison path.
   Record which path ran, snapshot cells reused and scopes recomputed. A qualifying
   test must witness snapshot state contributing to the installed result and
   outside-cut work changing it. Run follow-on commands against the real recovered
   session to verify consequences of hidden state, not only serialized equality.

**Gate:** compare with independent expected values/IDs and, secondarily, full
production reduction. Cover the connected lifecycles in the matrix below.
Semantic verification can still read extensive history; this increment promises
correct reconstruction, not sublinear fresh bootstrap or universal recovery
acceleration. Measure verification and reconstruction separately.

### S4.3 — Atomic derived installation and complete publication

1. Prepare immutable complete rows/context bound to the durable basis, H, owned
   store/session and starting view state. Compute away from the database writer,
   yielding database access between bounded reads as the existing workers do.
2. In one synchronous transaction recheck owner/header, healthy required history,
   target and view applicability; replace the complete derived rows/context and
   allocate a fresh view epoch. Leave accepted history, descriptor/pin, candidate
   bytes and required private groups intact. Failure exposes the prior complete
   transaction state or the complete replacement after recovery, never a prefix.
3. An intervening acceptance or rebuild causes reprepare/catch-up under the
   established guards. At startup use the existing admission fence, drain
   actionable ready work and publish only after one complete consistent current
   capture through the stable target. Waiting for undisclosed cloud history is
   outside this gate; already-known missing required evidence keeps its policy.
4. For live reconstruction, retain pending overlays and Current pins through the
   existing presentation path. Final `PreparedModelChange` consumption rechecks
   presentation/live generations. A rebuild completion is not a note-save receipt;
   it clears no pending generation. Cancellation preserves admitted inputs and
   uses recovered transaction membership to distinguish commit from rollback.

**Gate:** force acceptance, another same-H rebuild, close/reopen, a new pending
edit/Delete and a settings update at the applicable preparation/install/publication
cuts. Stale work must be rejected or recomputed; a settled valid run must publish.
The first eligible ordinary save after reopening retains zero-ancestor-walk
validation. Derived/conflicting states keep their existing eligibility rules.

## Swift-enforced responsibilities

Use the smallest actual issuer/consumer boundaries needed; names below describe
roles rather than mandate new public types.

| Role | Construction and consumption |
| --- | --- |
| Fresh candidate owner | Owns lock/connection and staged commitment; only complete verification/acceptance/opening can produce an editable session |
| Checked bootstrap input | Issuer-private constructor binds exact retained locators, commitment and owner context; acceptance reads those same bytes under the transaction fence |
| Durable snapshot basis | Restricted issuer joins semantic claims with accepted root/page/closure retention; reissue on reopen, and check actual store/session at use |
| Prepared reconstruction | Restricted factory binds complete cells/context to basis, H and starting view; installer checks current applicability and allocates the epoch |
| Recovery outcome | Closed variants distinguish waiting, budget deferral, unsupported input, invalid candidate, required damage, retryable/ambiguous storage effects, stale work and complete success |

Prefer checked `Sendable` immutable worker inputs, nominal graph-reference roles
and actor-isolated SQL resources. Transactions remain synchronous. Each `await`
is an explicit opportunity for interference; revalidate at the consumer. Use
`~Copyable` only if a genuinely unique resource transfer becomes simpler. Keep
shared history facts copyable and fallible commits explicit.

Extend actual-module compiler probes: ordinary clients and sibling files attempt
to forge, mutate or decode these evidence values, substitute graph roles, escape
SQL state and omit outcome cases. Each negative has a compiling companion and a
marked diagnostic location. Pair them with actual-consumer tests supplying the
right type but wrong store/session/cut/epoch. Preserve strict concurrency/memory-
safety settings and the existing narrow FFI exceptions.

## Risk-ranked scenario and observation matrix

Every row requires a valid companion, a named reached boundary, an independent
expected result, forbidden side effects and an assertion-specific mutation.
Contracts are principally `TC-START-01`, `TC-DUR-01/04/06`, `TC-EVD-01`,
`TC-ASY-01` and `TC-LIMIT-02`; semantics reuse the Phase 3 contract observations.

| ID / priority | Connected scenario | Required independent observation / challenge |
| --- | --- | --- |
| B01 / P0 | Descriptor, Genesis, two imports, completion and multiple pages arrive in different orders; zero-note companion | Editable only after exact commitment/closure; legitimate empty collection distinguished from missing data. Omit a page/import or publish on root arrival. |
| B02 / P0 | Valid framing/protection but wrong count/digest/birth/row/reference, split action or wrong profile | Intended semantic check rejects; source bytes and valid unrelated inputs survive. Mutate prefix-only verification or skipped membership. |
| B03 / P0 | Candidate retention → bootstrap commit → derived install → callback; terminate and fail recovery again | SQL inspection shows either unaccepted retained input or the complete accepted unit; exact committed identities recover without callback evidence. Mutate early session issuance or candidate-as-accepted. |
| B04 / P1 | Large packed batches/pages; duplicate/repackaged occurrences; close/resume | Exact bytes retained, logical Imports applied once, complete canonical digest, bounded transient buffers, eventual completion. Mutate skipped last batch or resumption. |
| B05 / P0 | Initial Imports and later edit/Delete share a required envelope/acceptance batch | Original commitment verified separately; Current at its stated prefix includes the extra effect. Mutate stamping the full batch sequence on import-only rows. |
| R01 / P0 | Snapshot of branch L; concurrent R accepted before the root, then third-writer descendant; exchange in alternate orders | Full accepted union, unresolved alternatives and exact represented heads survive. Mutate sequence-tail/object-tail selection. |
| R02 / P0 | Snapshot covers E; same referenced envelope also contains complete F; separate cut splits a multi-note action | F contributes exactly once; split-action claims reject. Preserve untouched sentinel. Mutate envelope coverage as logical coverage. |
| R03 / P0 | Snapshot → merge → edit → remote Delete → crash/reopen; automatic copy independently edited before late covering Delete | Source deletion and preservation/retirement rules match explicit expected births/heads; independently edited copy survives. Mutate affected-source-only reduction. |
| R04 / P0 | Reciprocal conflict copies → copy deletion → new source revision; Restore then Delete/restore again | Dispositions remain representation-only; retired output stays retired; new descendant can need attention; restored births/provenance/Recently Deleted correct. Mutate flattened/omitted snapshot indexes. |
| R05 / P0 | Undo → remote overlap → reviewed compensation → Redo, including multi-note and selected three-writer fork | Actual targets, inverse states, birth mappings and review/automatic outcomes remain correct after rebuilding. Mutate body-only restoration or original-action Redo. |
| R06 / P0 | Equal current bodies with different heads, scope maxima, origin/compensation or retirement evidence | Independently expected next edit/Delete/Undo decisions distinguish the cases; inspect exact retained records as well as Current. Mutate equality short-circuit. |
| R07 / P0 | Accept F or Delete during preparation; rebuild twice at same H; hold publication while newer pending P is admitted | Fresh target/epoch enforced, P remains pending/live, historical F survives missing callback. Mutate stale install, stale publication or clearing by birth. |
| R08 / P0 | Settings/private sentinel changes during rebuild; EIO/ENOSPC/busy or lost completion at installation | Derived transaction is atomic; private groups, exact accepted bytes and expanded pin coverage remain intact. Mutate settings reset or pin replacement by snapshot closure. |
| R09 / P0 | Separately damage derived row/context, required accepted object, required private group, or unreadable/wrong-key input | Rebuild only derived invalidity; required damage blocks editable success and preserves sources, including repeated damage-marker failures. Mutate generic rebuild-on-error. |
| R10 / P1 | Missing/rejected prerequisite, valid shared page, unrelated work, finite interference and second recovery failure | Actual blocking reason persists, unrelated work resumes, supplied valid prerequisites reach success without another event. Mutate missed wakeup or recursive rejection. |
| R11 / P1 | Healthy/no-work open versus exceptional rebuild, increasing unrelated history and linear ancestors | Healthy opens avoid historical BLOB/operation replay; exceptional work is separately measured; eligible first save has zero ancestor traversals. Mutate unconditional reconstruction. |

For R08/R09, begin with supported nonempty private-state sentinels and compare
their bytes/generations independently. Complete future pending-file codecs remain
Phase 4C; preserving supported private groups here must not be reported as
qualification of their future import/physical-association semantics.

## Execution and evidence strategy

### Deterministic real-runtime tests and fresh processes

- Extend existing Swift Testing suites, `tools/test-storage-phase2.py`, snapshot
  process drivers, independent wire/SQL inspectors and mutation/type runners.
  Register every new gate in the common required-discovery inventory. Use isolated
  owned directories, parameterized profiles and explicit completion gates rather
  than sleep-based scheduling or suite-global serialization.
- Run both provider profiles through the actual keyed SQLCipher store. The parent
  records synthetic commands and expected results; recovery receives only surviving
  storage and normal selection/unlock inputs. Inspect exact envelopes, all operation/
  action occurrences, complete membership, expanded pin coverage, private groups
  and current context independently of runtime receipts/success flags.
- Use hand-declared small histories/literal byte fixtures first. Full production
  replay is a differential check, not the only oracle. Witness the real snapshot
  seed, outside-cut application, install commit, final publication and follow-on
  command so an unused optimization cannot pass through a fallback.
- First sweep one fault/intervening event across each real boundary; then add a
  second failure during recovery and bounded delivery/completion permutations.
  Start with two changing notes and an untouched sentinel; add selected three-writer
  histories where overlap changes semantics. Larger generated cases record both
  seed and explicit schedule and shrink while preserving the contested transition.
- Keep termination, simulated persistence loss and later corruption separate.
  Inject VFS/SQL faults beneath real transactions; hold callbacks after real effects.
  Do not invent partially visible SQL commits or suspend an actor transaction.
  Persistent faults must preserve owned input; after faults/interference cease,
  require a reached progress result, not just an absence of bad publication.
- Require baseline success and precise mutation verdicts: designated runtime
  assertion, compile-blocked, survived, unreachable, unrelated or inconclusive.
  Challenge missing discovery/gates and inert fault hooks. Retain first failures;
  neither automatic retries-to-green nor an earlier framing failure qualifies the
  intended semantic protection.

### Focused model bridge

`SegmentBootstrapSafety` already checks complete initial import, preview separation,
tail inclusion and settings preservation. `SQLiteFastStartSafety` checks exact
rows/context, same-prefix epoch fencing and known-damage publication. The inspected
models and their generated configurations in `check-segment-models.py` abstract
bootstrap/reconstruction itself; they do not connect a partial operation cut,
previously accepted outside-cut branch, snapshot seeding and guarded replacement.
S2's `ReceiveSnapshotAssemblySafety` stops at complete acceptance.

Add a small focused reconstruction bridge when implementing S4.1, before enabling
installation. Use a fixed graph with two imports, a snapshot-covered edit, an
outside-cut branch/Delete and one body-equal context change; vary transport
packaging independently of logical membership. Separate bootstrap-completion
and concurrent-install configurations rather than multiplying every condition.
Model candidate retention, atomic complete acceptance, preparation, atomic derived
install, final publication and crash/reopen as distinct actual boundaries.

Assert accepted-history monotonicity/closure, complete bootstrap before editing,
independent expected union at the published target, preservation of private state,
epoch/owner checks and pending-generation protection. Require witnesses for an
earlier-arriving outside-cut branch, extra group in a referenced envelope, stale
preparation refusal, same-H epoch change and recovery after two failures. Pair
each new guard with its designated counterexample mutation. Progress assumptions
state finite delivery/faults/interference, eventual retry/reopen and fairness of
enabled local work, rather than fairness of a disabled waiter or guaranteed cloud
completeness. Bound graphs/events directly; keep state constraints from hiding
the contested transitions. Use separate small suites if state growth is excessive.

Record source/runner/configuration, explored bounds and counts, safety versus
reachability versus progress, and residual assumptions in the TLA README/report.
Replay environment schedules through the real Swift path. A counterexample is
investigated against the spec first; preserve assertions when it reveals a real
implementation or policy defect. SQLite atomicity, crypto and general reducers
remain assumptions of the scheduling model, qualified separately in executable
tests. Rerun affected model families when their mapping changes, not the whole
model inventory for documentation-only work.

### Resource and platform qualification

Use modest deterministic cases in the default suite and measured larger campaigns.
Sweep 64/256/1,024 imports and extend at least one run beyond those counts, with
fixed-size notes, varying page packing and general-tree depth. Separately increase
history with fixed live-note count. Report encoded-buffer high-water marks, graph
metadata, decode/read counts, SQL work, total time and largest database turn.
The full live note/search model necessarily scales with current contents. Bound
temporary buffers and resumable validation turns, and separately measure complete
atomic acceptance/install transactions, without claiming constant total memory or
imposing a collection-lifetime limit. Verify finite interference automatically
resumes work; optional preparation may stop at close, while owned writes settle.

Run debug and optimized gates, independent fixtures/schema checks, ordinary-client
and sibling-file probes, affected mutations and actor/FFI ASan/TSan campaigns.
Repeat affected runtime/fresh-process tests on Linux arm64 and available Intel
macOS targets. Preflight disk/resource capacity; label incomplete platform or
large-workload runs honestly. The [S2 report](phase4-received-snapshot-validation.md)
records the macOS 11 compiler workaround: passing that build variant does not
qualify the default optimized binary. Record exact flags and runtime dependencies.
Physical power-loss qualification remains separate from process termination.

## Completion ledger

Complete each gate before expanding the next. The validation report must connect
each matrix ID to production entrypoints, independent expectations, reached cuts,
fault/mutation outcomes and residual gaps; record exact source/binary/toolchain and
fixture revisions. Distinguish discovered active tests from optional skipped ones.

- **S3 complete:** store-backed complete bootstrap, incremental construction,
  resumable candidate, exact commitment and full acceptance/reopen pass B01–B05.
- **S4 complete:** actual snapshot-seeded all-branch reconstruction and guarded
  installation pass R01–R11, with the focused bridge and fresh-process follow-on
  commands; no unexplained critical mutation survivor remains.
- Update the parent Phase 4 plans, format/schema contracts if changed, model
  correspondence and executed report. Keep later Phase 4C–4F and platform/power-loss
  gaps visible. No new product-policy decision is needed to begin S3.1; a conflict
  with adopted semantics is raised before changing those semantics.
