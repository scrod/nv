# Phase 4 improvement implementation and qualification

Date: 2026-10-04. All three increments are implemented. Debug and optimized
full-unit stages, supplementary connected recovery tests, process/static/fixture
campaigns and scaling measurements have passed. The results below distinguish
completed checks from outstanding release qualifications.

Subsequent startup/scoped-query work has its
[own report](startup-and-scoped-queries-validation.md); general-v1 sequential
snapshot coverage has its [own report](snapshot-retention-coverage-validation.md).
The historical counts and known-issue observations below describe these first
three increments, before those later remedies.

## Implemented boundaries

1. `Verification.swift` stores bounded, exact replay requests in the existing
   encrypted `private_groups`. Its exhaustive recipe enum covers an exact accepted
   object, accepted local prefix, or staged/accepted bootstrap. The admitted handle
   binds the actual connection and header context; a private successful-completion
   value authorizes exact settlement. Nested checks inherit covering protection.
   Decode, admission and final consumer checks have distinct responsibilities.
2. `CheckedHistoryTraversal` reads indexed metadata in 64-row keyset pages,
   decodes each required Changes envelope/payload once on the history worker, and
   audits ordered occurrences, representative metadata and operation/note/action
   relationships. Representative and complete-occurrence scopes remain explicit.
   The complete scope issues restricted connection/store/prefix-bound evidence
   used by exact snapshot-reference consumers. Graph records remain proportional
   to required history; one envelope is decoded at a time.
3. `CheckedGraphRows` prepares final current rows/context from one checked target.
   Unpublished returning open, including its nested ready draining, coalesces a
   general-reducer suffix. Its synchronous installer checks connection, header,
   bootstrap, exact starting view and accepted target, then replaces derived rows
   and rotates their epoch atomically. Live general catch-up remains per-batch.

The changes add private request records and short-lived checking/preparation
values. Existing tables, provider envelopes, current-row formats, public storage
APIs, pending-generation matching and application interaction stay unchanged.
Both profiles continue to use encrypted private SQLCipher pages.

## Verification coverage inventory

| Path | Captured replay obligation | Final covered check |
| --- | --- | --- |
| Exact retained-object / payload inspection | Exact accepted locator | Envelope identity/profile/authentication and canonical payload |
| Operation/action lookup and historical ordinary validation | Accepted prefix | Exact occurrence, dependency and group checks through acceptance |
| Retained graph / causal cut / current reduction | Accepted prefix | Complete indexed membership, structural links and reducer result |
| Snapshot capture, claim verification and reconstruction | Accepted prefix | Full Changes occurrence audit, exact references, checked snapshot records and final reduction/install |
| Note History preview/restoration, conflicts and compensation commands | Accepted prefix | Referenced prior state, complete candidate/group checks, worker result and applicable command preparation |
| Stored initial-bootstrap acceptance | Staged bootstrap locator or existing accepted prefix | Complete original import commitment and acceptance |
| Required startup header/settings/frontier checks | Always repeated startup gate | Required association/private-state checks and current retained leaves |

Whole-prefix replay also checks accepted snapshot roots/pages through that prefix,
including older assemblies outside Changes representatives. Bootstrap proof has
its own codec/closure checks. Replay repeats verification, rather than executing
Undo, Delete, conflict choice or other user commands again.

The request remains through worker completion and final checks. Damage immediately
latches the live gate; one independent transaction inserts `history-damage` and
removes that exact request. A failed diagnosis attempt leaves the request durable.
At most one diagnosis attempt occurs in one actor turn, making repeated-write-
failure schedules observable. A later turn may retry.

Transient failure/cancellation can start one automatic live replay of that exact
request. Another failure preserves it for explicit retry/reopening. Close fences
connection-bound work while leaving unfinished requests durable. A replay failure
preserves its original request, including malformed/unsupported required recipes
and missing named scope. Admission stops at 64 independently owned requests.

Acceptance verification settles before its delayed completion callback. This
ordering preserves the existing optional-snapshot close contract: a historical
commit may be reported after close/reopen without accessing the former connection.
Failed settlement remains an explicit ambiguous/pending outcome with exact retained
inputs. Durability acknowledgment and clearing newer host work keep their existing
independent generation checks.

## Catch-up caller and effect inventory

| Caller | Materialization route | Effects retained independently |
| --- | --- | --- |
| `LocalStoreSession.open`, required ready drain nested inside it | Opening purpose; direct indexed ordinary batches, then one complete general target | Prior acceptance, object/record membership, pin and dependency wakeups already committed |
| Live `persist` / retry / receive / ready drain | Existing per-batch route | Exact receipt issuance, receive reservation and pending-generation matching |
| Exceptional snapshot reconstruction | Existing snapshot-cut/outside-cut proof and guarded installer | Required private groups, accepted history and pending inputs |

Coalescing changes derived installation scheduling, not action membership or
causal meaning. Body-equal Undo/Redo and context changes participate. Changed
history or an equal-prefix epoch replacement rejects the old preparation and
recaptures after finite interference. Independently updated settings survive.

## Completed targeted checks

- Full macOS Swift 6.4 suites: 238 reported tests passed in debug (1,078.693 s)
  and optimized (646.094 s), with the same 12 expected known-issue instances for
  the four explicitly deferred investigations. Four opt-in measurement functions
  were skipped in these broad suites; the two new improvement measurements were
  qualified separately below.
- The supplementary `mixedOpeningRecoveryPreservesConnectedHistory` test passed
  four cases in each build. Three writers make competing revisions; a fourth
  store accepts edits, copy/choice, copy deletion and retirement, source deletion,
  fresh-birth Restore and editing, multi-note creation/deletion, and a repackaged
  Restore without installing the intermediate rows. Its normal opener constructs
  one graph. Independent final bodies, retained competing values, all action and
  object identities, copy disposition/retirement, restoration provenance, scope
  continuation, settings and subsequent Undo remain correct. Two consecutive
  real SQL installation failures leave the exact accepted history, private
  settings and old complete rows/context unchanged. Their retained request
  replays before the successful catch-up; that final open appropriately counts
  one replay graph plus one materialization graph.
- The supplementary `compensationVerificationAdmissionFailurePreservesCommand`
  test passed both profiles in each build. Two failed reminder-admission writes
  leave the frozen Undo command with its caller, with accepted history, current
  rows and continuation unchanged. After storage recovers, that exact command
  succeeds once. This covers failure before action admission separately from
  a pending, already-admitted save.
- macOS Swift 6.4: 18 targeted test functions passed, including both profiles,
  four indexed-corruption cases, three final-context interference cases,
  64-request backpressure, exact sibling settlement, automatic replay without a
  new arrival, cancellation/close, genuine final graph failure and snapshot-page
  replay. Query-plan assertion requires the actual covering unique-key index.
- Ubuntu arm64 Swift 6.4: 20 changed-path functions passed in debug and optimized builds, including
  packed-graph and real Undo/Redo recovery witnesses in addition to the above.
  Both supplementary functions also passed all six parameter cases in each
  build through the documented Makefile entrypoint (mixed/admission functions:
  3.560/1.131 s debug; 1.170/0.146 s optimized).
  Its optimized probe also passed the six fresh-process verification schedules,
  ten focused compiler probes and the PIE/W^X/stack/RELRO observer with its
  permission negative control. Six further real writer-lock failure/retry
  lifecycles passed for preservation, conflict copies and compensation.
  The qualified executable uses the Makefile's bundled lld, RELRO and immediate
  binding settings. A direct build with the default GNU linker still produced
  a writable executable mapping and failed the unchanged permission observer;
  that variant remains unqualified. The proper entrypoint was rerun, rather
  than relaxing the permission assertion.
- Fresh processes: six schedules passed, including crashes after reminder
  admission and successful settlement, two repeated real settlement-write failures,
  and repeated real diagnosis-write failure followed by a normal fresh opener.
  Independently inspected history/index tables remain unchanged; the recovery child
  receives surviving storage and normal unlock/selection inputs only.
- Ten isolated runtime source mutations in both debug and optimized builds produced their designated assertion
  failures: admission, sibling settlement, startup replay, exact occurrences,
  stale target/epoch, required private-state preservation, ready/rebuild ordering,
  complete snapshot membership and received-snapshot occurrence coverage.
- Both configurations passed the complete 32-command qualification inventory:
  existing process, disposal, history, snapshot, received-snapshot, bootstrap,
  Restore and merge checks; all 60 connected Phase 3 schedules; eight generated
  schedules reaching every fault class; 18 rejection schedules; cipher cold
  initialization; Core/Runtime construction probes; 17 schema tests; all eleven
  independent record fixture checkers; envelope/descriptor observers; and strict
  owner/fault-adapter C diagnostics. Execution used stable copied probes.
- All 123 Runtime compiler probes passed against the optimized module, including
  the ten focused graph/request/traversal/successful-completion/prepared-row and
  exhaustive-routing checks. The ordinary and same-module probes retain exact
  diagnostic-category and marked-source-line checks.
- Independent verification fixtures cover all three recipes and strict private
  framing. The Swift literal checks also challenge unsupported tags/codecs, zero
  prefixes, truncation, trailing bytes and wrong context.
- AddressSanitizer passed with instrumented SQLCipher, including its targeted
  expired-handle control; ThreadSanitizer passed seven actor/close-path functions.
  The final ASan follow-up passed six verification/recovery/optional-close
  functions, followed by both supplementary functions (six parameter cases).
  System crypto/OS libraries remain outside that instrumentation.
- Intel macOS 11.7.11: the optimized probe passed all 76 existing process
  schedules and the six new verification schedules, using the documented
  concrete-metadata-accessor compiler workaround and isolated Swift concurrency
  backdeployment library. A separate local Node checker authenticated 46
  inspection reports containing 724 retained-object occurrences. These results
  qualify that variant, rather than default Mach-O deployment metadata or the
  complete Swift Testing suite on macOS 11. The macOS 14 SSH key was unavailable.
- The legacy app and epoch-4 archive compatibility procedure passed using
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO`. Plain `build.sh` and the
  compatibility script first hit Xcode 27's documented target-range error; the
  workaround keeps the existing target and the epoch-4 reader assertions.

Initial failed runs identified and fixed a real optional-close regression: a
delayed acceptance callback originally preceded verification settlement, causing
post-close failure despite an established commit. Broad tests exposed it and retain
their original late-commit/new-owner-edit assertions. Other corrections were exact
test SQL/unique-index naming and recovery error attribution; accepted framing damage
now reaches the recovery integrity gate before the old lower-level read path.
Existing crash/failure probes now arm at the actual history-acceptance or diagnosis
transition rather than count the newly inserted admission transaction. Bootstrap
and exceptional-reconstruction commit cuts also use an explicit current-row
installation anchor. Ordinary-save writer-lock faults arm after the exact
acceptance preflight query and before its `BEGIN IMMEDIATE`; arming at the later
membership insertion would instead fail a subsequent transaction. Compensation
save faults similarly follow its protected candidate recheck. This preserves
the distinction between command admission, acceptance,
verification settlement and derived installation; all original history/current
oracles remain. Simulated uncommitted WAL-tail loss preserves all earlier
committed frames, including the
verification request. The independently expected historical/current outcomes and
required fault-hit assertions remain intact.

## Models and scope

`VerificationRecoverySafety` checks three exhaustive scenarios (693, 1,211 and
1,564 states), four exact mutation counterexamples and three witnesses. It
separates admission, reading, final checking, settlement, cancellation, sibling
completion, failed diagnosis and restart. Progress concerns an actual reopened
startup and canceled owned checks; fairness does not force a crash or consume the
whole possible failure budget before a successful marker write.

`CoalescedRecoverySafety` checks one exhaustive scenario (5,500 states), four
counterexamples and three witnesses. Its explicit fold and independently authored
expected-value table detect omission of an intermediate Undo, stale target/epoch
installation and private settings reset. Publication, rows/context and retained
history remain separate assertions. Together these are 18 completed outcomes.

Existing SQLite collection, fast-start and snapshot-reconstruction families passed
21, 9 and 20 outcomes respectively, including all named mutations and witnesses.
These bounded checks assume atomic SQL commits, valid complete
accepted groups and the separately tested reducers; they establish their finite
scheduling claims rather than arbitrary graph, cryptography or power-loss proofs.

## Measurements

The starting review measured 24/88 envelope decodes for packed 16/64-note graphs.
The implemented traversal performs exactly 3/5 required Changes decodes for those
fixtures, with one decode per required SegmentID and equal envelope/payload maps.
The five-action Edit/Undo/Redo/Undo/Redo recovery witness now builds one graph
instead of four, preserving seven action records, exact envelopes, both current
notes and the next Undo candidate. Healthy settled opens retain zero graph loads.

`HistoryReaderReferenceTests.swift` retains a test-only record-by-record reader
for independent comparison of operation/action values and exact references, plus
independently expected imported contents. Its opt-in alternating packed-reader
measurements use 64/256/1,024/2,048 notes and both profiles. Timed regions contain
the reader itself; fixture construction, semantic result comparisons and output
are outside. Round zero warms the workload. The whole checked graph still has
history-proportional work/memory. A decoder-count reduction alone is not a claimed
wall-clock speedup.

Optimized macOS measurements used two warm comparison rounds after round-zero
warmup. The test-only record-by-record reader and the new reader produce equal
operations, actions and exact references; independently expected note bodies
provide another oracle. Both include verification admission/settlement. The
new reader additionally performs its complete relationship/graph checks.

| Packed notes | Record-by-record decodes / SQL statements | Batched decodes / SQL statements | Warm reader timings, old → new |
| --- | --- | --- | --- |
| 1,024 | 1,397 / 16,777 | 49 / 3,424 | 588–683 ms → 85–93 ms |
| 2,048 | 2,793 / 33,529 | 95 / 6,790 | 1.21–2.17 s → 180–494 ms |

These are observed ranges across both profiles under concurrent qualification,
including an encrypted-profile timing outlier. Fixture construction and semantic
comparisons are outside the timed reads. They describe graph reading, not healthy
current-row startup or complete bootstrap latency.

`RecoveryWorkReferenceTests.swift` also passed all six profile/history cases,
with 36 actual per-batch/opening observations. Each fixture retains 64, 256 or
1,024 ordinary edits and 16 real alternating Undo/Redo actions. It restores an
earlier exact complete derived view to create 1, 4 or 16 unapplied complex batches.
The real returning opener is compared with the actual live per-batch route on
identical retained history. Exact final cells/context, accepted membership,
private groups, envelopes and subsequent command alternatives remain equal;
the independently expected bodies are `base-N` and `untouched`.

| Prior ordinary edits; 16 pending complex batches | Per-batch graph builds / decodes | Opening graph builds / decodes | Per-batch catch-up → complete returning open |
| --- | --- | --- | --- |
| 64 | 16 / 1,240 | 1 / 85 | 1.03–1.09 s → 80–112 ms |
| 256 | 16 / 4,312 | 1 / 277 | 2.03–2.10 s → 139–155 ms |
| 1,024 | 16 / 16,600 | 1 / 1,045 | 5.87–6.03 s → 441–445 ms |

At 1,024 edits the 4-batch comparison was 1.48–1.58 s → 436–472 ms. A one-batch
complete open was slightly slower than direct live catch-up because it includes
ownership/unlock, required startup checks and current capture. Its graph count
remains one. Longest measured opening writer turns in the 16-batch cases were
10.5–17.4 ms; the per-batch route recorded 19.5–31.9 ms. These are actor-turn
observations, rather than isolated transaction or UI-latency guarantees.

The complete scaling command's maximum RSS was about 1.65 GB, including its cold
optimized build and fixture construction. That measurement cannot establish an
isolated graph-memory peak. Graph memory still grows with required history, and
lifetime-scale/isolated peak-memory qualification remains open. Two durability
transactions per logical verification add overhead; nested reads share their
enclosing request. The broad-suite thread sample showed active full-sync commits
in repeated assertion reads, rather than a deadlock. These costs were retained in
the measurements and test budgets; no synchronization setting was weakened.

## Outstanding qualification

Real physical power loss remains unqualified. The subsequent private-state/repair
and 4F reports qualify physical preservation and rebinding of unfinished requests,
plus initial current-row capture reuse. The
[startup/scoped-query report](startup-and-scoped-queries-validation.md) records
the later optional-work and scoped-read increment. Snapshot-root growth remains
in [the benchmark backlog](benchmark-backlog.md). The campaign below records the
first three improvements, rather than the entire present-day implementation.

## Qualification artifacts and reproduction

The common-driver full-unit stages passed before its later process stages stopped
at the old fault targets. Their raw failures remain in the original artifacts.
After correcting those test-only targets, the equivalent complete command
inventory was executed independently: ten prefix commands and 22 completion
commands in each configuration. This is composite qualification, rather than a
claim that an original stopped driver returned success. The two supplementary
functions were added after the 238-test full-unit runs and passed separately in
both builds. Production source hashes match between each prefix and completion
manifest; their stable-probe checksums and complete executed commands are retained.

Local temporary artifacts below reside under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/` unless an absolute path is shown.

| Evidence | Artifact |
| --- | --- |
| Full debug and optimized unit stages | `nv-storage-phase2-qrno753_/swift.log`; `nv-storage-phase2-_0lvhto5/swift.log` |
| Supplementary mixed recovery and command-admission functions | `/tmp/nv-phase4-supplement-debug-final.log`; `/tmp/nv-phase4-supplement-release-final.log` |
| Debug ten-command prefix and 22-command completion, with source/probe hashes | `nv-improvement-debug-commands-uku_1c69/results.json`; `nv-improvement-debug-commands-jgah1e39/results.json` |
| Optimized ten-command prefix and 22-command completion | `nv-improvement-release-commands-1_ydaaol/results.json`; `nv-improvement-release-commands-s660_qua/results.json` |
| All new bounded model outcomes and source hashes | `nv-improvements-tla-v6bf1zd6/results.json` |
| Targeted mutation campaigns | `/tmp/nv-phase4-mutations-debug2.log`; `nv-runtime-mutations-8dip19dm/results.json` |
| ASan production paths and supplementary recovery functions | `nv-cipher-sanitizer-w6gc4vmi/`; `nv-cipher-sanitizer-0e56tjgw/` |
| TSan actor/close/recovery functions | `/tmp/nv-phase4-tsan.log` |
| Packed-reader and actual returning-open measurements | `/tmp/nv-phase4-benchmarks.log` (eight packed-reader cases); `/tmp/nv-phase4-recovery-benchmarks-final.log` |
| Qualified Ubuntu supplementary functions and final controls | On the VM: `/tmp/nv-phase4-linux-{mixed,admission}-{debug,release}-qualified.log`; `/tmp/nv-phase4-linux-busy-qualified.log`; `/tmp/nv-phase4-linux-elf-qualified.log` |
| Intel macOS 11 selected build variant and independent inspections | `/tmp/nv-phase4-intel-build.log`; `/tmp/nv-phase4-macos11-inspections/results.json`; `/tmp/nv-phase4-macos11-inspection-final.log` |
| Legacy app and epoch-4 procedure with documented target workaround | `/tmp/nv-phase4-app-build-workaround.log`; `/tmp/nv-phase4-epoch4-workaround.log` |

`tools/test-storage-phase2.py` now requires discovery of both supplementary
functions and runs the common ordered inventory for future debug/optimized
qualification. The improvement model runner is `docs/tla/check-improvement-models.py`;
the [TLA README](../../../tla/README.md) records its safe, mutation and witness
configurations. Opt-in measurement entrypoints remain in
`HistoryReaderReferenceTests.swift` and `RecoveryWorkReferenceTests.swift`.
