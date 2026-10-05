# Typed Runtime boundaries

Date: 2026-10-02. This follow-up implements the concrete opportunities in the
[Swift library proposal](swift-storage-library-proposal-v2.md) under the
[conformance strategy](swift-storage-conformance-testing-strategy.md). It refines
the portable Runtime's implementation boundaries. The specification, Protocol,
ADRs and CONTEXT continue to define its behavior.

## Implemented changes, in priority order

1. **Validated acceptance input.** A private `ValidatedHistoryBatch` is issued by
   bootstrap, checked-current or full declared-history validation. Each
   `HistoryObject` pairs exact authenticated/integrity-checked envelope bytes with
   their decoded contents. Acceptance derives dependency edges from those
   contents and commits that same batch. Bootstrap checks exact complete object
   membership. Asynchronous history validation retains the accepted-prefix and
   header checks immediately before consumption. This replaces parallel maps and
   their missing-entry defaults. Ordinary acceptance reuses the checked envelope
   instead of decoding it a second time.
2. **Command-specific capture intent.** `CapturedActionIntent` pairs each kind
   with its Restore, choice, copy, historical, compensation or native-coverage
   provenance. The wire kind, restoration records and details are derived from
   that value. Existing semantic validation still checks the referenced history,
   selected fields, group membership, before/after states and context.
3. **Automatic versus reviewed compensation.** Preparation issues
   `AutomaticCompensation` or `CompensationReview`. `applyCompensation` consumes
   only the automatic value; `applyReviewedCompensation` is the host's explicit
   approval action and accepts disclosed replacements. `forReview()` keeps the
   same frozen command while deliberately entering review. Both consumers retain
   exact owner, store, view, presentation, affected-state and candidate checks.
   A reviewed call records the existing reviewed wire bit. Calling the same
   command again after its state changes requires fresh preparation.
4. **Exhaustive receive-error classification.** Separate exhaustive switches
   cover `StorageError`, `OrdinaryHistoryError` and `CanonicalEncodingError`.
   Adding a case requires an explicit classification. The stable rejection codes
   and retryable/unclassified outcomes are unchanged.
5. **Explicit owned phases.** `LocalStoreLifecycle` represents open, quiescing and
   closed admission. `LocalCommitState` represents idle, pending and running
   work. `OwnedCommit` carries the frozen capture or its exact sealed envelope.
   Reservations precede suspension; ambiguous failures retain the same work for
   retry. Acceptance and definitive pre-seal rejection release the slot. The
   existing completion waiters resume postponed validation. Pending retries keep
   quiescing from reporting a safely closed collection.

These changes add no tables, encoded fields, sidecars or validation cache. The
public compensation signatures become more specific; encoded history, rejection
codes and product policies remain unchanged. All other public APIs retain their
existing contracts. The existing current-save work assertions still require zero
ancestor traversal and now require zero envelope decoding in the acceptance
stage.

## Unique cleanup experiment

A minimal `~Copyable` handle consumed inside the existing synchronous dispatch
cleanup callback failed Swift 6.4's ownership check: a captured noncopyable value
cannot be consumed in that closure form. Adopting it here would require another
transfer bridge. The implementation retains its actor-owned, non-Sendable C
resources and qualified synchronous disposal path. Its construction/actor/C-call
probes, abandoned-owner tests and fresh-process lease-release checks continue to
exercise that boundary. The prototype tests this direct approach, rather than
claiming that every noncopyable cleanup design is impossible.

## Checks and independent observations

`TypedBoundaryTests.swift` adds:

- An independent literal table of 39 error/code outcomes, including all 25
  stable rejection codes and 14 retryable/unclassified cases.
- Both-profile automatic-to-reviewed compensation, wrong-store and old-session
  rejection, invalid replacement rejection without acceptance, exact reviewed
  action/body inspection, fresh reopen and Redo of the actual reviewed effect.
- Both-profile SQL inspection of exact bootstrap envelope bytes and dependency
  membership, saved operation/action membership and current values after reopen.

`test-storage-runtime-types.py` checks ordinary-client and same-module issuers,
wrong permission types at real consumers, missing associated provenance and the
private batch constructor. Its three classifier source challenges remove an
actual switch case and require the intended exhaustive-switch error. Actor
challenges include lifecycle setter access and a running commit without owned
input. Valid companions and diagnostic source locations remain required.

The affected mutation campaign challenges omitted dependencies, the final
accepted-prefix fence, early acknowledgment, a retained rejected-capture slot,
lost resumption wakeups, wrong compensation context, stale approved values and
wrong native remaining-effect selection. Each mutant must reach its designated
runtime assertion; an unrelated build or discovery failure fails the campaign.

## Model correspondence

The existing SQLite acceptance/current-row separation, exact-byte retry,
generation-bound publication, declared-writer validation, rejection preservation,
automatic validation resumption and causal Undo/Redo rules remain intact. The
private batch narrows the issuer and preserves the modeled final acceptance
fence; phase enums encode the existing reservation and drain states; permission
types split the existing automatic/reviewed admission routes. No modeled behavior
or assertion changes, so this follow-up uses the established scenarios and does
not rerun unchanged TLA+ configurations. See the active
[model map](../../tla/README.md), the [first-save contract](first-save-reopen-contract.md)
and [Phase 3 report](phase3-validation.md).

Specifically, `SQLiteCollectionSafety` retains its atomic acceptance and separate
materialization boundaries; `ReceiveResumptionSafety` retains commit versus
completion, owned pending work and completion-driven wakeups;
`ReceiveRejectionSafety` retains truthful classification and preserved candidate
bytes; `ConcurrentUndoExecutionSafety` and `ReviewedUndoSafety` retain distinct
preparation, explicit approval, captured effects and final context checks. The
compiler and executable checks qualify these concrete refinements of the existing
boundaries, rather than establishing a formal refinement of every model.

## Execution record

Executed on arm64 macOS 26.6.2 (25G83), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`) and Xcode 27.0 (27A266a):

| Check | Observed result |
| --- | --- |
| Final debug suite | Passed: 162 active test functions; the separate opt-in scheduling benchmark was skipped. Swift Testing reports 163 including that skip. |
| Complete optimized qualification driver | Passed: 27 commands, 162 active Swift functions discovered, both profiles. Includes 60 connected fresh-process schedules, 8 seeded delivery/crash schedules, 18 rejection schedules and the existing bootstrap/history/Restore/merge/disposal process checks. |
| Compiler boundaries | 88 Runtime probes passed in debug and optimized configurations; 31 Core probes passed through the optimized driver. Valid companions and diagnostic classifier self-checks also passed. |
| Independent encodings and schema | All nine Python fixture families, envelope and descriptor checks, and 17 schema tests passed. Runtime and documented schema bytes matched. |
| Affected assertion-specific mutations | All eight reached their designated runtime failures after a valid baseline. Setup/discovery checks passed. |
| Instrumented SQLCipher/Swift ASan | All nine selected ownership, compensation, delayed-completion and resumption functions passed. The archive's instrumentation, valid C-handle companion and deliberate expired-handle control were independently checked. |
| C diagnostics | Owner/fault boundaries passed strict C warning/error checks through the optimized driver. |
| App build | `build.sh` passed using the previously approved Xcode deployment-target override. The existing macOS 11.5 target and deployment warning remain. |

The growing-history tests still check 64, 256 and 1,024 ordinary actions, including
the first save after reopen. Eligible saves performed zero ancestor traversal in
validation, acceptance and materialization; acceptance decoded zero envelopes.
SQL work assertions were preserved.

Reproduce the complete main checks with:

```sh
make -C tests run-swift-storage
python3 tools/test-storage-runtime-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-mutations.py \
  --only omitted-dependencies --only actor-final-prefix --only early-ack \
  --only rejected-capture-retains-slot --only resumption-loses-wakeup \
  --only undo-proposal-context --only undo-stale-values --only native-remaining-original
```

Final logs/artifacts:

- `/tmp/nv-typed-final-debug.log` and `/tmp/nv-typed-final-debug-types.log`.
- `/tmp/nv-typed-final-qualification.log`; complete optimized results and child
  logs at `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-storage-phase2-rhek3lqt/`.
- `/tmp/nv-typed-mutations.log`; exact assertion locations, mutant hashes and
  baseline source hashes at `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-runtime-mutations-enkevlon/`.
  That isolated copy predates the final bootstrap complete-membership guard;
  final debug/optimized suites and process qualification include that guard.
- `/tmp/nv-typed-asan.log`; its exact nine-function filter, runtime log and result
  at `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-cipher-sanitizer-4f81z5te/`.
- `/tmp/nv-typed-app-build.log`, using
  `XCODE_XCCONFIG_FILE=/tmp/nv-typed-build.xcconfig`, whose sole setting is
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO`.
- `/tmp/nv-unique-cleanup-prototype.swift` and its compiler log record the direct
  ownership experiment. The production disposal implementation is unchanged.

This follow-up qualifies the local host revision. Additional host-platform and
physical power-loss qualification remain separate from process termination,
simulated I/O failure and later corruption. UI/provider integration retains its
existing subsequent-phase boundaries. Concurrency, ownership and Swift Testing
guidance informed the synchronous transaction turns, explicit reservations before
suspension, restricted issuers and real-module challenge tests.
