# Phase-3 review corrections

These corrections implement the existing Protocol, ADR-0015, first-save and
connected-record rules. Product policy, canonical encodings, provider behavior
and application interaction remain as specified. Qualification follows TC-ASY-01,
TC-LIVE-01, independent observations and targeted negative controls in the
[conformance strategy](swift-storage-conformance-testing-strategy.md).

## Historical recovery and admission ownership

Historical recovery into an automatic delete/edit-preservation note produces an
independently authored `AdoptAutomatic` operation. The payload encoder now permits
that operation in a historical-recovery action; full validation checks its captured
source/key and complete writer history. Later Delete coverage retracts only the
automatic presentation, preserving the independent revision and deterministic birth.

Public ordinary captures take `OrdinaryActionKind`. Specialized issuers supply the
matching Restore, conflict, historical or compensation provenance; private
construction checks kind/details agreement before admission.

Definitive capture or canonical-sealing rejection before any envelope exists
returns the unchanged input handle and releases the session reservation. Later
valid saves/quiescing can proceed. Storage failure, cancellation and sealed or
ambiguous work retain their existing owned retry rules. This fixes an unsealable
capture's permanent busy state while preserving frozen retries and host generations.

`ReviewRegressionTests` covers body/all-field recovery, independent adoption,
subsequent saves, later covering Delete and peer delivery/reopen under both profiles.
Companions reject missing specialized provenance and malformed pre-seal input,
inspect ownership, retry the exact handle and complete a valid save. Compiler
probes reject each specialized kind at the marked ordinary-capture line, including
same-module construction attempts.

## Command scheduling and Undo queries

Conflict/compensation calculations use a cancellable worker over immutable captured
graphs/values. A short-lived actor supplies a dedicated execution resource for the
calculation, preserving caller progress even when the global Swift task pool has
one worker. SQL reads retain their bounded database turns; the session actor can
serve saves, snapshots and close requests during CPU work. Completion rechecks live
ownership/header, closure and cancellation. Capture persistence retains the exact
accepted-prefix fence. A save during calculation can therefore require explicit
fresh preparation, rather than rebasing frozen input.

Undo selection checks the scoped graph once and uses query-local ancestry/family
memoization. A shared union traversal finds dominated candidates, including paths
through consumed commands. Linear ordinary histories avoid repeated per-candidate
ancestry reconstruction. General branching/native-coverage histories retain their
rules and may require more work; this is not a constant-time query.

`CommandSchedulingTests` holds the real worker while independently observing a
completed save and snapshot. Six command paths, both profiles, cancellation,
quiescing and a changed affected note exercise actual consumers. Old captures are
rejected and fresh companions succeed. The suite serializes blocking test gates;
each case still creates the relevant concurrent operations.

`CausalUndoQueryTests` compares 20,418 candidate/mode/frontier outcomes with an
independent Boolean transitive-closure oracle over all 1,024 five-node forward
DAGs and applicable Undo/Redo variants. These are query-component comparisons;
Runtime tests separately exercise complete action admission. Linear
64/256/1,024/2,048-action cases and invalid graph companions are included.

## Current creation dates

Incremental current-row updates preserve the birth's creation date, matching
general reduction and reconstruction. Exact history keeps the caller's complete
recorded value, including any different date. The regression checks those bytes,
writer/peer Current, unrelated general reduction, another save and derived-row
damage/rebuild against independently expected dates.

## Final connection cleanup

Abandoned owners finish cipher cleanup on the owning queue before the destructor
returns. Queue-local destruction releases inline; destruction elsewhere uses a
synchronous queue turn. The connection is released before the directory lease,
using the existing immutable release-only C-handle transfer. Explicit quit still
drains collection owners before process exit, as the specification requires.

The original implementation reproduced two normal-exit SIGSEGVs in twelve runs:
the worker was closing the cipher while the main thread finalized global state.
Regressions cover lexical queue-local disposal, abandoned off-queue disposal/reopen
and repeated normal child-process exits. Failed-close companions inject actual
VFS write/disk-full errors during acceptance, preserve the busy pending owner,
verify final owner/lease release while the process is alive, drain the reopened
verifier, then return normally and independently inspect history/current values
in a fresh process.
SQL trace callbacks identify commit cuts for termination/holds; VFS callbacks inject
returned I/O errors.

The macOS 11 test exposed an additional qualification error: returning from async
`main` can enter process exit handlers before a default actor's final destructor
runs. Pinned SQLCipher's `sqlcipher_atexit` calls `sqlcipher_extra_shutdown`, freeing
its provider/private heap. A concurrent late `sqlite3FreeCodecArg` is unsafe even
with synchronous queue disposal. The original probe deliberately omitted the
specified quit drain. Its corrected abandoned-owner helper waits, with a bounded
watchdog, for successful public reopen/close before exiting; failure to release
the lease or close the verifier fails the test. This is a test-lifecycle correction,
not a guarantee of graceful teardown after uncontrolled process exit. Termination
and ambiguous-commit recovery retain their separate fault tests.

## Qualification

The [Phase-3 report](phase3-validation.md) retains the preceding feature qualification
and its original source scope. Review-specific results and artifacts are listed
below; open qualification work is identified explicitly.

- Debug and optimized Swift suites passed 159 active functions (160 reported,
  including the explicitly opt-in scheduling benchmark's skip). Final debug and
  optimized runs took 253.163 and 99.814 seconds respectively. The independent
  Undo oracle made 20,418 comparisons. The final encoder-expression reruns are
  retained in `/tmp/nv-review-debug-final.log` and `/tmp/nv-review-release-final.log`.
  All 31 Core and 62 Runtime construction probes passed, including same-module
  issuers and actor isolation. Logs: `/tmp/nv-review-core-types-final.log` and
  `/tmp/nv-review-runtime-types-final.log`.
- All seven affected debug and optimized mutation controls reached their designated assertions,
  with all 48 required functions discovered for each run. Artifacts:
  `nv-runtime-mutations-q_lnjwxa` (debug) and `nv-runtime-mutations-kegpotg1`
  (optimized). Their captured source hashes precede the final byte-equivalent
  encoder expression rewrite, which is covered by both final suites and the
  unchanged independent byte fixtures.
- SQLCipher-instrumented AddressSanitizer and strict-memory-safety checks passed
  the nine review-related Runtime functions, including both-profile scheduling
  and cleanup paths. The C expired-handle control was rejected at the intended
  `sqlite3_total_changes` use-after-free. Final targeted artifacts:
  `nv-cipher-sanitizer-7jkvrcem`, following the byte-equivalent encoder rewrite.
  The preceding targeted pass remains in `nv-cipher-sanitizer-ygig35l_`.
- ThreadSanitizer passed the same nine functions, 554.246 seconds, through the
  dedicated `.build-thread-sanitizer` build. The earlier full ASan Runtime child
  also passed 81 functions in 530.634 seconds; its wrapper initially rejected
  Swift Testing's singular `1 suite` grammar. The corrected wrapper requires
  nonzero completed tests, accepts singular/plural suite wording, rejects failed
  completion and writes the child exit/discovery evidence. The failed wrapper's
  artifacts remain in `nv-cipher-sanitizer-_u_nhpnu`.
- The final orderly-exit probe ran 30 abandoned-owner saves per profile, two
  quiesced companions and 12 VFS `SQLITE_IOERR_WRITE`/`SQLITE_FULL` failed-close
  companions per platform. Every saved/recovered history was checked independently: 74 reports
  on arm64 macOS (`nv-disposal-process-6cmwdiqh`) and Intel macOS 14.8.9
  (`nv-disposal-process-853yswzf`). macOS 11.7.11 generated its reports in
  `nv-disposal-process-eduq1s1_`; all 74 independent inspections then passed
  locally in `/tmp/nv-review-macos11-inspections.L5qvqH`. The VM opener received
  only surviving storage and normal selection/unlock inputs. ASan additionally
  passed 10 abandoned saves per profile and the failed-close companions
  (`nv-disposal-process-vc1qac6y`).
- The broader debug driver passed all 27 qualification commands and discovered
  159 active Swift functions (`nv-storage-phase2-2u562_lc/results.json`). It
  completed all 60 connected fresh-process schedules with independent wire/SQL
  checks under both profiles, generated ordinary-action/damage-recovery histories,
  18 rejection schedules, save/reopen, Note History, Restore and merge campaigns,
  compiler probes, schema/independent fixtures and strict owner/fault C diagnostics.
  The captured probe precedes the test-only orderly-exit correction and final
  byte-equivalent encoder expression. Final suites/lifecycle results are listed
  separately above.

The application build was also checked without editing application interaction
source. Xcode 27's default invocation diagnoses the declared older deployment
target; the matching `xcodebuild install` passed with
`__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` and signing disabled. Physical
power-loss survival and provider/UI integration retain their independent release
gates.

The Intel probe was compiled with explicit Swift/Clang 11.5 targets, availability
checks enabled, and a verified Mach-O `minos 11.5` field. Its SHA-256 is
`0a50fceceaa02369781c9663876128b8170ab41d0a42753fafdb2b39ac3c7f56`.
This probe precedes the later byte-equivalent Swift 6.1 expression rewrite below;
the exercised Runtime ownership/protocol logic is unchanged. The Mac Mini's
installed Swift 6.0.3 remains below the library's declared build-tool requirement,
so this is cross-built executable qualification, not native package compilation.

The unchanged `portable-` causal-undo TLC family passed 25 positive exhaustive
checks and 19 designated negative/reachability controls. Bounds/fairness remain
those in the TLA README. No modeled safety condition was weakened. These checks
qualify the abstract rules; the independent query oracle and Runtime tests check
their concrete implementation.

The current build platform is arm64 macOS 26.6.2 / Swift 6.4 with pinned SQLCipher
4.19.0. The earlier Ubuntu arm64 / Swift 6.1.3 attempt first encountered a
type-checker timeout in
`OperationEffectV1.recoverCopy`'s long concatenation. Sequential typed byte appends
encode precisely the same birth/revision/key/slot/reuse/value layout; independent
connected-record fixtures remain unchanged and pass. This preserves the API,
canonical identities and strict language checks. The subsequent compiler reached
Runtime and rejected `StorageExecutor.queueIdentity`: its installed Dispatch
module declares `DispatchSpecificKey<UInt8>` non-Sendable. The current Apple SDK
and [upstream Dispatch source](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/main/src/swift/Queue.swift)
declare the key conditionally Sendable. The user chose upgrading to Swift 6.4;
the VM now compiles the actual immutable key and executor with checked Sendable
conformance. Core/Runtime also enable strict memory-safety errors. The proposed
compatibility adapter was unnecessary. See the
[upgrade and platform report](swift64-platform-qualification.md) for final checks,
the one-CPU scheduling counterexample and its actor-backed correction. No
`@preconcurrency`, broadened unchecked actor/lane conformance or disabled
concurrency check was used.
Initial cancelled/zero-test runs are excluded from qualification. Provider/UI
integration and physical power-loss qualification remain separate obligations.
