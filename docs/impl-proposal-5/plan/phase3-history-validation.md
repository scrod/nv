# Phase 3: retained history reader

Status: first incremental implementation, 2026-09-17. This is the read side of
the [phase-3 sequence](swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores),
not completion of its recovery, merge, conflict or compensation gates. The later
[connected report](phase3-validation.md) records those runtime integrations; the
initial results and limitations below describe this earlier increment.

## Production boundary

`LocalStoreSession.history(for:after:limit:)` lists one birth's accepted operations
or the collection's logical Delete entries. A page contains metadata only, with
a default of 64 and an inclusive maximum of 128 entries. These are request-work
limits; continuation permits arbitrarily long retained histories. A store-issued
cursor binds the query, owner session, store, last ID and captured acceptance
prefix. Saves can advance history between pages without changing the original
listing. Starting a new listing captures newly accepted records. ID order provides
stable enumeration; causal parents and note predecessors carry their separate
graph meanings.

The SQL query reads at most `limit + 1` metadata rows. The reader filters those
against the captured prefix and advances past inspected rows, including newer
ones. A chunk can therefore return no visible entries and still have a
continuation; callers follow that continuation to completion. This keeps a
long-lived listing from making one database turn scan an arbitrarily large newer
suffix. The paging test adds 32 saves after capture and checks both the original
result set and per-query SQL work.

`preview(_:)` consumes a store-issued entry, verifies its membership in the
captured accepted prefix, opens its exact retained operation and complete action,
and checks the target birth/action agreement. A Delete preview includes its
action's exact prior value. Results are detached read-only values. The eventual
host must fence presentation by selected entry and view generation. Previewing
does not create a recovery command; explicit recovery needs its separate capture,
provenance and admission path.

These reads use the existing database actor and ownership/health checks. Paging
adds no durable cursor, history body copy or long-lived cache. The only schema
addition is a partial index over existing Delete rows. Cursors and entries expire
with the owner session; exact operation IDs remain portable and can be found in a
new listing. A preview of damaged accepted evidence records required-history
damage through the existing guard. Missing/corrupt evidence cannot become an
empty historical value or authorize continued editable publication.

Stored-but-parked input stays outside the accepted operation index. Duplicate and
repackaged envelopes expose one logical revision with its original operation ID.
Accepted history is readable independently of current-row materialization; the
existing explicit unsupported result for competing Current branches remains
until the general reducer is implemented.

## Checks

- `NoteHistoryTests.swift`: two independent SQLCipher stores, both profiles,
  parent-first/child-first delivery, parked-child restart, duplicate/repackaged
  envelopes, edit→Delete, exact prior values and retained IDs; concurrent branches
  retain their separate values, causal parents and common note predecessor.
- Paging during additional saves, query/store/session mismatch consumers, page
  limits, metadata-only counters, valid preview followed by corruption, and
  unchanged current rows/context before/after previews.
- `test-storage-history-process.py`: four fresh-process cases across both profiles,
  including process exit after Delete commit before its callback. Independent SQL
  and the existing Node envelope inspector check the history. Rebuilding damaged
  derived rows preserves the same historical values and deletion entry. Recovery
  receives ordinary selection/unlock inputs only.
- Compiler probes check ordinary-client and same-module construction restrictions
  for cursor, entry and preview, plus actual wrong-context consumers in Swift tests.
- Targeted mutations hide Deletes, substitute the wrong pre-deletion value,
  skip the preview's owner-context check and exceed the metadata work bound. Each must fail its named assertion after
  a valid baseline with required test discovery.
- SQL query-plan checks exercise indexed per-birth and Delete enumeration.

Run through the existing local qualification driver:

```sh
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-mutations.py --only history-hidden-delete --only history-wrong-prior --only history-skipped-context --only history-unbounded-chunk
```

The driver retains its phase-2 filename and now includes the initial phase-3
history checks.

Mutation discovery accepts an intact Swift Testing start or completion record.
SwiftPM warnings can split either record even with `--no-parallel`; the shared
parser's self-checks retain both observed start-line interleavings as reduced
fixtures. Required-test membership and exact test/file/assertion-line attribution
remain mandatory. Run `python3 tools/test-storage-runtime-mutations.py
--self-test-only` for the parser/classifier regression checks.

The 2026-09-17 correction passed those self-checks and replayed both previously
misclassified logs as targeted failures. A fresh `--only history-wrong-prior` run
passed its 29-test baseline and reported `targeted runtime failure`, including
the designated assertion in all four parameter cases. An unrelated required
test's start line was again split by the SwiftPM warning; its intact completion
supplied discovery evidence.
Artifacts: `nv-runtime-mutations-lpe3rgcl` beneath the host temporary directory.

## Executed results

On arm64 macOS with Swift 6.4:

- All 100 active Swift test functions pass in debug and release; the runner reports
  101 including the intentionally disabled scheduling benchmark. The four new
  history functions exercise eight cases, including both provider profiles.
- Four standalone fresh-process history cases pass, with independent SQL/envelope
  inspection and current-row rebuilding. Final artifacts: `nv-history-process-wgaxtyu3`
  beneath the host temporary directory.
- All 38 ordinary/same-module compiler-boundary probes pass.
- All four new mutations fail at their intended assertions after a passing
  baseline: `history-hidden-delete`, `history-wrong-prior`, and
  `history-skipped-context`, plus `history-unbounded-chunk`. Final artifacts:
  `nv-runtime-mutations-9vxtt8nc` and `nv-runtime-mutations-n9qk26c6` beneath
  the host temporary directory. The work-bound challenge detects excess SQL
  work even when the displayed history remains correct.
- All 17 schema tests pass, including the new index-access checks.
- The app builds with the user-approved
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` override. Plain `build.sh`
  encounters Xcode 27's macOS-11.5 deployment diagnostic. The deployment target
  and app behavior are unchanged; the app still does not link NVStorage.

Both broader qualification drivers pass all 18 stages, including 72 established
fresh-process cases, generated-failure/rejection schedules, fixtures and C-boundary
checks. Artifacts: `nv-storage-phase2-3zbounag` (debug) and
`nv-storage-phase2-rlp_aq8_` (release) beneath the host temporary directory. The
final bounded-query refinement was followed by complete Swift-suite reruns,
fresh-process history checks and the four focused mutation controls above.
One intermediate optimized build was invalidated by a test-file edit during
compilation; the subsequent completed build is the reported result.

These checks do not qualify physical power loss,
actual provider transport, UI integration or execution of this new reader on
Intel macOS/Linux. No unsafe/C implementation was added by this increment.

## Remaining phase-3 work and model correspondence

The retained deletion listing remains available. The subsequent
[Restore increment](phase3-restoration-validation.md) implements exact named-entry
provenance and default Recently Deleted exclusion (TC-ACT-05) for direct single-value
Delete inputs. Generic historical copying and alternate-branch selection remain
distinct later work. The results above describe the earlier reader qualification.

General Current reduction, equal/merged represented inputs, delete/edit
preservation and its retraction, conflict-copy dispositions and causal Undo/Redo
remain subsequent phase-3 work. No UI integration is included.

The spec's HIST-01, ADR 0015, Protocol's historical-recovery rules and CONTEXT's
Note History/Recently Deleted definitions govern this reader. The
`SegmentDeletionSafety` model's retained-history recovery and the action recovery
models supply adjacent scenarios; as the TLA README states, they do not prove
Recently Deleted list exclusion or actual query/codec correctness. This increment
adds read-only inspection without changing modeled state transitions, so no TLA
safety rule or configuration is changed or rerun.
