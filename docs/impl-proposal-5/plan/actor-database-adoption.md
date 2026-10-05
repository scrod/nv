# Actor-owned database: adoption and robustness

Status: adopted in the production Runtime, 2026-09-17. This follows the
[isolated prototype](actor-database-prototype.md). The portable library retains
its macOS 11 deployment target; execution of the custom executor on macOS 11
remains a separate platform qualification.

## Ownership and execution

`LocalStoreSession` continues to own admitted saves, exact retry inputs and pending
completion state. `DatabaseLane` is now an actor owning the connection and mutable
database state. A custom serial executor runs its jobs on the existing dedicated
blocking-I/O queue. `HistoryWorker` uses a separate utility-priority queue for
envelope preparation.

Conflict and compensation calculations run on a cancellable worker over immutable
captured data. The session actor remains available for local admission and close
requests, and command completion rechecks live ownership before consumption.

Each `DatabaseLane.perform` closure is synchronous. The closure and its result
cross the actor boundary under Swift's `Sendable` checking; the actor supplies
the non-Sendable connection inside that closure. A transaction completes or throws
within one actor turn. SQL transaction atomicity, owner checks and
acceptance-generation checks retain their existing roles.

The outer acceptance, catch-up, ready-work and blocked-prerequisite loops are
explicitly `nonisolated`: they await individual database turns. This is important
because an actor method calling its own synchronous method would stay in the same
turn. The current-state save path still validates and accepts in one turn;
historical validation awaits individual indexed reads.

The change adds no persistent state, fields, sidecars or long-lived validation
cache. Existing immutable values carry data between turns. The actor conversion
preserved Runtime client APIs, durable formats and the current-state zero-ancestor
fast path. The subsequent [review corrections](phase3-review-corrections.md) narrow
the generic capture initializer to ordinary kinds with complete host-supplied intent.
Core's general `OrdinaryHistoryV1.validate` API becomes asynchronous so its readers
can suspend directly.

## Validation and interference

The general validator retains its iterative history traversal. Exact-reference
checks share one verifier between synchronous bootstrap/current-state callers and
asynchronous history callers. They retain at most one resolved dependency payload
and an input-sized list of explicit reference claims. Ordinary action validation
shares structural/before-after/scope checks and emits explicit ancestry
obligations, consumed by either validator.

Each historical database read checks the captured acceptance sequence. After the
last read, acceptance checks that sequence again inside the transaction, alongside
the existing owner/header checks. A local save in either interval causes a fresh
validation attempt. The bounded-interference result and automatic resumption
after saves settle remain unchanged.

The pre-conversion synchronous history validator is retained in tests as a
comparison oracle, together with independent expected outcomes. Sharing the
production semantic checks avoids maintaining two production rulesets. Multiple
simultaneous defects can change which validation error is reported first; exact
single-defect failure classifications remain tested.

## Connection lifetime

Explicit close and failed-open cleanup run on the database executor. If a caller
abandons an owner, `Database.deinit` transfers its remaining C handles to that
same queue for final disposal. Disposal finishes synchronously before the destructor
returns, closing the connection before releasing the private-directory lease.
An abandonment already executing on that queue disposes inline; another executor
uses a synchronous queue turn. The executor's private queue-specific key selects
the appropriate path. Orderly process exit separately drains collection owners
before SQLCipher's process-exit handlers run, following the specified quit
lifecycle. A final actor release can itself occur after async-main returns; the
abandoned-owner process probe therefore observes lease release and closes its
reopened verifier while still alive. The [review report](phase3-review-corrections.md#final-connection-cleanup)
records the macOS 11 counterexample to relying on async-main return alone.

`StorageExecutor.RetiredHandles` is a private, non-Sendable value holding immutable
pointers for final release. The synchronous queue closure borrows it until disposal
finishes; it remains confined to that release operation. The ownership argument is
exactly-once transfer from `deinit`; explicit close clears both pointers. Swift 6.4
checks the executor's immutable stored state and its Dispatch queue-identity key.
The private `synchronizeRelease` helper takes a nonescaping closure, giving Swift
a checked scope for the off-queue disposal borrow. A compiler challenge changes
that helper to an asynchronous queue hop and requires the precise escaping-capture
error at its marked line.
The C pointer lifetime remains an audited interoperation boundary, qualified by
disposal/reopen and sanitizer tests. Production Core and Runtime now use checked
conformances and actor ownership throughout this path.

The executor enqueues each `UnownedJob` once and retains itself through execution.
The explicit `asUnownedSerialExecutor` implementation and older job entry point
preserve the declared deployment target. Queue preconditions guard connection
access and final disposal. Platform tests must cover the actual runtime as well
as successful compilation.

The ownership/reentrancy rules follow [SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md);
the dispatch-backed executor follows [SE-0392](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md).

Phase-3 command calculations also use this executor through a short-lived,
value-only `CommandWorker` actor. Its synchronous calculation runs away from both
the database lane and the global Swift task pool, retaining foreground progress
on single-worker runtimes. The detached task awaits the actor and retains the
existing cancellation/result checks. Each command owns its calculation resource
until completion; captured immutable graph values supply all of its inputs.

## Robustness checks

These checks apply the [conformance strategy](swift-storage-conformance-testing-strategy.md)'s
TC-ASY-01 and issuer/consumer separation: test the real adapter, independently
assert resulting values, and challenge the checks with targeted mutations.

- Compiler construction probes require an awaited database call, reject returning
  `Database`, and reject an asynchronous transaction closure. Same-module probes
  run through SIL generation, where region-isolation diagnostics are emitted.
- Compiler probes accept the actual executor and immutable Dispatch key as
  Sendable, reject adding mutable state to the actual executor, and reject using
  its final C-handle value where checked Sendable transfer is required.
- Strict memory-safety probes require an explicit acknowledgment at the actual
  SQLCipher key borrow. A separate challenge verifies that the final-release
  closure completes synchronously within its caller's lifetime.
- Failed keying releases ownership; dropping the final owner releases the lease
  and allows reopening with the independently expected rows intact.
- A deterministic pause after the final historical read admits a local save.
  The receiver must perform a second full validation, preserve the new local
  body, and retain the exact remote bytes in both protection profiles.
- The old synchronous validator and independent expected errors check async
  equivalence, including an action member whose declared note predecessor is
  absent from its causal past.
- Targeted mutations remove a per-read generation check, the final transaction
  check, or an ancestry obligation. Each must fail its intended assertion.
- Existing phase-2 suites exercise fresh-process recovery, completion races,
  rejection transactions, automatic validation resumption, fault injection,
  current-basis work counts and static evidence-construction boundaries.

## Model correspondence

The logical transitions and assumptions in `ReceiveResumptionSafety` and
`ReceiveRejectionSafety` are unchanged. Database calls are now actor turns;
validation still consists of individually fenced reads and a separately fenced
acceptance transaction. Synchronous SQL transactions continue to supply the
models' atomic commit/rollback boundary. Save settlement still wakes the existing
session waiters. Executor scheduling remains subject to the same eventual-work
assumption; actor isolation alone does not establish fairness.

No TLA+ state/action change or new model-checking claim is required for this
execution-mechanism change. Runtime schedule tests and compiler rejection probes
qualify its concrete mapping. Physical power-loss behavior and execution on an
unavailable macOS 11 host remain explicitly unqualified.

## Validation results

Local Swift 6.4 / arm64 macOS 26.6.2, targeting macOS 11.5:

- Both debug and optimized phase-2 drivers passed all 17 qualification commands, including
  96 discovered active Swift test functions, fresh child-process failures,
  generated histories, rejection failures, independent fixtures, schema checks,
  compiler clients and strict C diagnostics. Swift Testing lists 97 tests total,
  including the intentionally disabled optional history benchmark.
- After restoring the preparation queue's utility priority, both complete Swift
  suites passed again in debug and optimized builds. The four actor-specific
  compiler probes also passed on the final source.
- Three targeted mutations were killed at the intended assertions in both debug
  and optimized builds: per-read prefix, final prefix, and ancestry obligation.
- The app built successfully with the explicit
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` build argument. Xcode still
  warns about the older deployment target. `build.sh` alone rejected that target.

Ubuntu arm64 / Swift 6.1.3: seven selected production runtime tests passed,
including both profiles of the final-read race and all ten resumption schedules.
All four actor/compiler probes passed. Swift 6.1 and 6.4 give different precise
missing-`await` diagnostics; the harness accepts those two messages, still
requiring failure at the marked line. After restoring utility priority, all seven
runtime tests passed again (3.413 seconds).

Artifacts:

- Debug/optimized drivers:
  `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-storage-phase2-fyx7r7d4/`
  and `nv-storage-phase2-q_fi32m_/` in the same parent directory.
- Final Swift suites and compiler probes: `/tmp/nv-actor-swift-debug-final.log`,
  `/tmp/nv-actor-swift-release-final.log`, `/tmp/nv-actor-static-final.log`.
- Debug/optimized mutations:
  `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-runtime-mutations-51nr319k/`
  and `nv-runtime-mutations-955pkznm/` in the same parent directory.
- Ubuntu: `/tmp/nv-storage-disk/nv-actor-linux-final.log`,
  `nv-actor-linux-types-final.log`, and `nv-actor-linux-qos-final.log` in that
  same remote directory.

### Sanitizer follow-up (2026-09-17)

The adopted actor implementation passed the following fresh macOS arm64 / Swift
6.4 checks, with production source and test assertions unchanged:

- **AddressSanitizer:** complete Runtime suite, 36 active test functions plus the
  skipped opt-in benchmark (37 listed), passed in 126.604 seconds. SQLCipher's
  separate instrumented archive was verified by its ASan symbols, a valid C
  control and the expected library-internal expired-handle detection. Run with
  `python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan`.
- **ThreadSanitizer:** eight focused functions passed in 189.823 seconds: owner
  exclusion/wrong-key cleanup, abandoned-owner disposal/reopen, final-read
  interference, yielding historical validation, stale-read rejection, resumption
  after two saves, delayed completion and ordinary save/delete/reopen. This
  includes both protection profiles where parameterized and all ten resumption
  cases. The test executable contains TSan access instrumentation.

The first parallel TSan run exceeded the existing one-minute deadlines in 13
cases while the ASan campaign was also active. It reported no data race and is
retained as a failed run. The successful rerun used the same compiled binary and
timeouts with `--skip-build --no-parallel`, after ASan finished. Independent test
execution was serialized; each test's actual concurrent actors, controlled races,
cancellation and quiescing schedules stayed intact. A one-second process sample
during that rerun showed active instrumented Argon2 work. The successful runtime
logs were independently checked for all eight required passing functions and
absence of sanitizer/error reports.

ASan artifacts: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-cipher-sanitizer-1g1e4_nx/`.
TSan logs: `/tmp/nv-actor-tsan-followup.log` (initial deadline failures) and
`/tmp/nv-actor-tsan-serial-followup.log` (passing rerun). Its build used
`swift test --build-system native --package-path NVStorage --scratch-path
NVStorage/.build-tsan --sanitize thread`, the normal SQLCipher prefix and an exact
filter containing those eight function names. The sample is
`/tmp/nv-actor-tsan-sample.txt`.

System crypto/OS libraries remain outside sanitizer instrumentation; SQLCipher's
archive is instrumented for this ASan run, but remains outside TSan coverage.
These checks close the actor-conversion sanitizer follow-up, while actual macOS
11 execution and physical power-loss qualification retain their separate limits.
