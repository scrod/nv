# Validation resumption and rejection isolation

Date: 2026-09-16. Implements [the resumption plan](validation-resumption-plan.md)
and its two receive-isolation follow-ups. Scope: the existing ordinary-history
Runtime for both provider profiles; private database pages remain encrypted.

## Concrete behavior

- `acceptScheduled` distinguishes two interrupted history checks from database
  busy or I/O failure. Local persist/retry still returns its owned pending handle
  with `busy`. Receive retains its single reservation, waits on existing `drained`
  continuations only while `inFlight`, and retries the durable queue. Every wake
  rechecks the condition; an already-finished save needs no remembered signal.
- Cancellation and quiesce preserve owned receive work. Failed saves wake the
  receiver even when their retry handles remain outstanding. Acceptance still
  rechecks the exact history prefix and owner before committing.
- `receivedObjectStatus(at:)` verifies the exact retained locator, then reports
  accepted, pending validation, waiting, or blocked. Pending validation identifies
  a durable ready entry whose prerequisites are already accepted. A blocked result
  names direct unaccepted locators
  and deduplicated rejected prerequisite IDs/reasons reached through waiting
  edges. The traversal yields the writer between objects. These are observations,
  not acceptance receipts; unknown future formats remain distinguishable.
- Rejection and removal of that object's ready/wait entries remain one SQL
  transaction. Descendants are retained with their original waiting edges and
  receive no inherited rejection record. No schema, wire-format, persistent
  scheduling flag, timer, stored task, or descendant-status cache was added.

## Tests and evidence boundaries

| Check | Observed obligation |
| --- | --- |
| `validationResumesAfterTwoInterferingSaves` | Two real prefix captures invalidated by real local commits; third complete validation succeeds after editing stops. Both already-finished and held-completion orders; exact bytes, sequence and independent expected bodies. Ten profile/lifecycle combinations. |
| Same test, lifecycle variants | Retained receive reservation, cancellation, successful quiesce, and failed quiesce with an ambiguously completed local commit. Recovered exact commit identity settles the pending handle. |
| Same test, live diagnostics | A status query during the held completion reports the retained ready object as pending validation rather than corruption. |
| Same test, shared-notification companion | Resume existing waiters while the save remains active; require condition rechecking. This deliberately injected notification checks the wait consumer; it is not claimed to execute another real save admission in the wake-up interval. |
| `historyInterferenceRetainsItsOwnFailureCategory` | Explicit internal-to-public busy mapping and rejection exclusion; I/O/database categories retain their distinct outcomes. |
| `rejectedPrerequisitesRemainDistinctFromMissingAndInvalidDescendants` | Two-level dependency chain, shared root, unsupported and malformed roots plus absent evidence. Repeated delivery/status queries, restart, wrong locator, unchanged accepted prefix, exact retained bytes and unrelated valid incoming progress. |
| `rejectionCleanupFailureKeepsRetryableBytes` | Real SQL abort after inserting a rejection but before removing the ready row, repeated three times; rollback preserves exact input and accepted history. Healthy retry settles the rejection. |
| `test-storage-rejection.py` | Real SQLCipher write/full/sync faults armed inside rejection, termination before reason/after reason/before commit/after commit, and fresh-process recovery. Independent SQL/envelope inspection plus successful unrelated incoming work. |
| Ready-input crash companion | Terminate after durable receive insertion, before acceptance; fresh opener incorporates it once without another delivery. This exercises the same durable queue used by postponed validation, separately from the live two-interruption test. |

The optional existing `StorageWork` instrumentation carries two qualification
callbacks: before a real history traversal and after actual acceptance commit
before result delivery. Default Runtime operation leaves these unset. They can
hold/fail a completion, but issue no checked history or receipts. Actor/session
scheduling uses only its pre-existing state. Tests use per-collection gates;
watchdogs observe progress rather than arranging interleavings by sleeping.

Eight isolated source mutations target generic-busy escape, an unnecessary wait
after saves ended, a missing completion wake-up, skipped condition rechecking,
premature queue removal, released receive reservation, non-atomic rejection and
direct-only blocker lookup. Ordinary-client and same-module probes also reject
using a blocked-prerequisite diagnostic as commit ownership.

## Findings while qualifying

1. Fixed-count `Task.yield` polling could exhaust before a correct actor resumed
   under the full suite's load. Gate ordering remains deterministic; a time-bounded
   observation watchdog now checks the required state and gives named failures.
2. A failed sync does not promise rollback of all bytes visible to a subsequent
   process. The fault test requires either a complete rejection or a retryable
   candidate, with no partial settlement or accepted-history change. Termination,
   I/O error and physical persistence loss remain separate fault classes.
3. An expected error in `NVStorageProbe.receive-file` could leave asynchronous
   connection disposal racing process-exit SQLCipher destructors. The crash report
   showed `DatabaseLane.deinit` closing on the writer while process exit ran
   `sqlcipher_extra_shutdown`. The probe now awaits quiesce before propagating
   that error. Production hosts must likewise finish owned work before orderly
   process teardown. This is not a claim of an Apple/SQLite contract violation.
4. Rebuilding a probe while a process suite launches it can transiently expose an
   unfinished executable. The Phase 2 driver now snapshots its tested child
   executable before process qualification.

## Executed results

macOS arm64, Swift 6.4:

- Complete Phase 2 driver passed in debug and optimized configurations: 17 commands
  each, with 94 active Swift tests discovered (the separate opt-in history-read
  benchmark remains skipped). Each run includes independent fixtures, schema,
  existing process/generated-failure suites and strict C diagnostics.
- All 18 new process schedules passed in each configuration: eight rejection
  fault/termination schedules and one durable-ready-input crash per profile.
- All eight targeted source mutations failed their intended runtime assertions in
  both configurations, after a passing baseline. These campaigns preceded the
  final pending-validation diagnostic addition; both complete final drivers cover
  that addition.
- All 28 ordinary-client/same-module Runtime construction probes passed in each
  complete driver.
- The SQLCipher-instrumented AddressSanitizer Runtime suite passed, including its
  library-internal expired-handle negative control. The normal application build
  also passed using the approved deployment-target diagnostic setting; the Xcode
  deployment-target warning remains.

Artifact roots under the development Mac's temporary directory
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`:

| Campaign | Directory |
| --- | --- |
| Final debug Phase 2 | `nv-storage-phase2-jqnarlwj` |
| Final optimized Phase 2 | `nv-storage-phase2-8p1adv6_` |
| Debug targeted mutations | `nv-runtime-mutations-auv6f791` |
| Optimized targeted mutations | `nv-runtime-mutations-ave2z_zl` |
| Instrumented SQLCipher | `nv-cipher-sanitizer-qy6tc668` |

Ubuntu 26.10 arm64, Swift 6.1.3, optimized build:

- All four new Swift test functions passed, including ten profile/lifecycle
  combinations in the resumption test and both-profile rejection companions.
- All 18 fresh-process recovery schedules passed with independent SQL/envelope
  observations.
- All 28 Runtime construction probes passed, retaining exact source-line and
  diagnostic checks. ELF qualification passed PIE, W^X, non-executable stack and
  RELRO checks, with the deliberately RWX negative control rejected.

Guest logs are `/tmp/nv-storage-disk/nv-resumption-{focused,rejection,types,elf}.log`;
process artifacts are `/tmp/nv-storage-disk/nv-rejection-8jzorx0e`. Copies of the
logs and `nv-resumption-ubuntu-rejection-results.json` are under `/tmp/` on the
development Mac.

The attempted full Runtime rerun exhausted the VM's disk during large-history
performance testing and is not counted as a pass. Older synthetic stores were
archived on the development Mac before reclaiming their VM space. Logs of both
disk-full runs remain under `/tmp/nv-storage-disk/` on the VM. No API contract or
assertion was relaxed for its compiler, platform, or disk capacity.

Only previously generated synthetic data was removed from the VM: four old
process-test directories and three old history-test stores. Recoverable archives
are `/tmp/nv-ubuntu-older-process-evidence.tar.gz` and
`/tmp/nv-ubuntu-archived-history-test-stores.tar.gz` on the development Mac.

## Model and release boundary

The original SQLite TLA+ models assume complete valid accepted input and abstract
SQL atomicity. Their safety predicates and transitions are unchanged. A subsequent
[receive-model follow-up](receive-model-validation.md) adds bounded scheduling and
rejection/dependency checks with explicit progress assumptions; it complements
these actual runtime tests rather than proving Swift scheduler behavior. Unchanged
SQLite models were not rerun merely because Swift implementation changed. Physical
power-loss qualification, general undo/conflict reducers, future-validator upgrade
migration and provider/UI integration remain separate work. Intel Macs were not
rerun in this follow-up; their earlier qualification is a separate dated result.
