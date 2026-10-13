# Private connection reuse

Date: 2026-10-11. Scope: reuse fixed opening facts and physical ownership checks
within the existing actor-owned SQLCipher connection. Implemented; available-platform
qualification and its limits are recorded below.

## Contract and implementation

`DatabaseLane` already retains a single connection on its dedicated serial
executor. This increment removes repeated checks within that lifetime:

| Fact | Check lifetime |
| --- | --- |
| SQLCipher version, key and connection configuration | Configure and verify each newly opened connection. |
| Schema, header, exact local-store/descriptor binding and required opening state | Establish a private checked context on that connection's first successful validation. Match each caller's exact store and descriptor in memory. |
| Candidate versus accepted complete bootstrap | Keep separate readiness cases; promote only after the exact bootstrap membership check succeeds. |
| Physical directory, database file and held ownership | Check entry and exit of each synchronous database turn; transactions also check immediately before and after commit. Nested statements share the enclosing checks. |
| Mutable records, accepted membership, current-row/prefix/view generations | Check through their actual decoders, queries and consumers. |
| Required private inputs during exceptional reconstruction | Check at preparation and again inside installation's transaction. |
| Acceptance completion after suspension | Report the exact historical commit. Existing session/generation consumers guard subsequent effects, including after orderly optional-work close. |

`Database.CheckedContext` has a private representation and issuer. It stores the
exact store/descriptor binding, the existing verification-record binding and
bootstrap readiness. `withOwnedOperation` is synchronous and file-confined, so
an `await` cannot extend its scope. The database remains non-Sendable and
actor-confined; copied query results cross the boundary.

Additional transient state consists of that context and one nesting-scope Boolean.
Production code writes `store_header` only in candidate initialization, which
commits before the candidate's checked opening context is issued.
Existing connection/session identities remain the asynchronous fences. Ownership
failure blocks the affected operation; every subsequent turn requires fresh
positive native identity of the same held directory and database. A replacement
at the same path fails those checks. Restoring the exact original resources can
resume an owned retry, preserving the existing recovery behavior. Closing/reopening
creates a fresh connection and checks its opening facts again.
There are no added persistent records or schema/format/API changes.

## Failure and recovery

- A detached read withholds its result. Loss detected by the precommit check
  prevents commit. Loss detected by the postcommit/turn-exit checks withholds that
  operation's result while preserving recoverable committed membership. Retry
  retains the exact existing bytes and pending generations.
- After complete acceptance checks produce a committed result, a delayed receipt
  remains a historical fact even if ownership is later lost. Optional-work close
  permits its completion after a new owner has reopened and edited; that receipt
  cannot publish a stale model or alter the new owner's pending generations.
- Opening with mismatched store/descriptor, missing required groups, unsupported
  codecs or incomplete bootstrap keeps its existing explicit outcome.
- Known retained-history damage immediately blocks the live connection and keeps
  the existing durable verification/diagnosis protocol. A hint lookup propagates
  that failure rather than treating it as a miss.
- A mutable settings reader decodes the current settings. Rebuilding derived
  rows rechecks required private inputs before installation, including changes
  during off-lane preparation. Rebuilding preserves retained history and settings.
- Fixed header/schema tampering performed through a test-only raw SQL seam is
  diagnosed on the next opening. Cooperating production writers preserve those
  fixed facts; consumers still check mutable evidence and physical ownership.

Filesystem checks are observations rather than an atomic exclusion of Finder or
other uncooperative tools. The existing native checks and directory lock remain
unchanged. SQLCipher errors, actual malformed reads and on-demand history
verification retain their recovery roles. No filesystem watcher or periodic
reopening is introduced.

## Executable qualification

`ConnectionReuseTests.swift` covers both profiles and independently expected
values/membership:

1. One versus 64 statements in a turn: zero repeated context-validation sequences,
   exact query count, bounded physical checks, wrong-store/descriptor rejection,
   and one full context validation after fresh opening.
2. Incomplete candidate cannot acquire complete-bootstrap readiness; exact resume
   succeeds and the ordinary open still rejects an unfinished candidate.
3. Actual directory displacement before a read returns, before commit and after
   commit. Reject an unrelated replacement without entering its consumer. Restore
   the exact original resources, retry and reopen; inspect an independent committed
   scalar and original note values.
4. Hold a completed edit's callback, admit a newer edit or Delete and displace the
   directory. Require the exact historical receipt to preserve the newer pending
   generation; restore the same resources and verify exactly one durable action.
5. Healthy reconstruction companion, followed by settings deletion/unsupported
   codec during held preparation. Installation must reject; retained envelopes
   and current values remain unchanged, and reopening reports required-state loss.

Existing batch tests require one joined hint query per nonempty group, zero full
scans, exact independent accepted IDs and unchanged error classifications. Growing
current-save tests retain zero ancestor walks, directly measured SQL bounds and
their existing safety assertions.

Construction probes challenge the checked-context representation, ownership-scope
flag and scope entry method from another source file in the runtime module.
Targeted isolated mutations remove exact context matching, entry/return/precommit
checks and reconstruction's final private-input check. Each needs a passing
companion and its designated assertion;
a compile error or unrelated failure is insufficient.

The production discovery benchmark separates warm end-to-end sweeps, metadata,
SQL lookup, receives and native components. Preserve the earlier 13-statements-per-
batch results in [the batch report](bounded-discovery-batches-validation.md);
this increment requires one statement per eligible group. Neither component
timings nor warm synthetic sweeps establish cold/provider latency.

The existing SQLCipher build/qualification setup supplies the prefix for these
entrypoints:

```sh
python3 tools/test-storage-phase2.py --configuration debug --scratch-path NVStorage/.build-final-debug-probe
python3 tools/test-storage-runtime-types.py --modules NVStorage/.build/release/Modules
python3 tools/test-storage-runtime-mutations.py --disable-sandbox --jobs 2 \
  --only connection-context-binding --only connection-entry-fence \
  --only connection-return-fence --only connection-precommit-fence \
  --only connection-rebuild-private-inputs
python3 tools/benchmark-storage-discovery-work.py
```

The full driver requires discovery of every new connection test. The optimized
focused selection is `connection|repositoryHintBatch|livePhysicalOwnership|reconstructionDistinguishesDisposableRowsFromRequiredLoss|verification|realRetryHandleAndReceiptRejectOtherOwnersAndSessions|snapshotOptionalWorkAllowsDurableClose|receivedSnapshotOptionalClosePreservesOwnedInputs|ordinarySaveWorkAcrossGrowingHistory`.

## Model correspondence

`SQLiteCollectionSafety` supplies atomic acceptance, recovery and retained-input
conditions. `SQLiteFastStartSafety` supplies known damage and final current-view
publication conditions. `RepositoryMetadataBatchSafety` supplies root/store
fencing across handoffs and partial retention. Connection reuse changes their
concrete check placement within synchronous operations, preserving their checked
context, atomicity and generation premises. Their actions and safety conditions
remain unchanged. Native physical tests and compiler probes qualify the concrete
mapping; TLC does not prove native identity checks or SQLCipher behavior.

## Results

Artifact availability note, 2026-10-14: the four original local
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/` artifacts recorded below
are no longer present on this host. Their paths are retained as recorded code
text; the results and reproduction commands remain evidence for this increment's
qualified sources. A fresh campaign creates new artifacts rather than restoring
the original raw records.

Completed final-source checks:

- Local debug: all 378 tests across two suites pass, including the existing
  recovery, ownership, optional-close and late-completion assertions. The complete
  **44-command qualification driver passes**, including 60 connected fresh-process
  lifecycle schedules, eight generated schedules, 18 rejection schedules, 19 schema
  tests, twelve independent fixture families, compiler clients and strict C checks.
  Recorded driver results: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-storage-phase2-0kicl1ao/results.json`.
- All five isolated mutations fail at their designated runtime assertions, with a
  passing three-function companion selection. The changes challenge exact context
  matching, entry/return/precommit fences and reconstruction's final private-input
  check. Recorded artifacts: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-runtime-mutations-vkk7tzvq`.
- AddressSanitizer: all 13 affected functions pass with the instrumented SQLCipher
  archive; its valid-handle companion and expired-handle negative control pass.
  Recorded artifacts: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-cipher-sanitizer-tceuldzf`.
- ThreadSanitizer: the same 13 functions pass, including the original exact-resource
  retry and late optional-completion contracts. [Log](/tmp/nv-connection-final-tsan.log).
  Swift/bridge paths are instrumented; the ordinary SQLCipher archive is not a
  fully TSan-instrumented dependency.
- Same-module actor/construction probes: all 19 pass, including the three new
  connection-context/scope probes and their valid companions. All 135 full
  ordinary-client/same-module runtime probes pass against debug and optimized modules.
  [Log](/tmp/nv-connection-final-release-types.log).
- Local optimized companions: all 26 functions pass, including ordinary saves
  after 64, 256 and 1,024 actual ancestors and immediately after reopening. The
  exact SQL bounds, zero ancestor walks and zero repeated fixed-context checks
  remain asserted. [Log](/tmp/nv-connection-final-release.log).
- macOS 14.8.9 Intel: all 25 optimized connection, reconstruction, batch, retry,
  optional-close and verification functions pass. The final log is
  `/tmp/nv-connection-mini.8yr7rM/final-results.log` on that host.
- Ubuntu arm64, Swift 6.4: the same 25 debug functions pass. Both final probe and
  test executables pass independent PIE, W^X, nonexecutable-stack and RELRO checks,
  including the RWX negative control. The same 25 optimized functions and release
  hardening checks also pass. Logs are `/tmp/nv-connection-final-debug.log` and
  `/tmp/nv-connection-final-release.log` on the VM.
- macOS 11.7.11 Intel: all six scoped-query fresh-process lifecycles and all six
  backup/I/O-failure process cases pass for both profiles. [Scoped artifacts](/tmp/nv-scoped-platform-a4sobnpq),
  [backup artifacts](/tmp/nv-private-process-uc_x6xcs). These runs use the previously
  documented isolated concurrency runtime/compiler workaround; they qualify that
  execution variant, rather than resolving the default macOS 11 distribution limit.
- The application build passes with Xcode 27's previously approved
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` override. Plain `build.sh`
  reports the existing unsupported 11.5 deployment-target diagnostic; the
  override retains that target and reports it as a warning. Project settings and
  note-interaction code are unchanged. [Qualified build log](/tmp/nv-connection-final-app-qualified.log).

Unchanged model checks pass all 39 runner cases across `SQLiteCollectionSafety`,
`SQLiteFastStartSafety` and `RepositoryMetadataBatchSafety`, including their
designated defects and reachability witnesses. These are the bounded abstract
checks described above, rather than native/filesystem proofs.

Physical power-loss qualification remains outside this increment. The macOS 11
distribution and SQLCipher TSan-instrumentation limits remain as described above.

### Discovery measurements

The production work analysis passes at 64, 256 and 1,024 files for both profiles.
At 1,024 unchanged files and budget 16, it observes 138 hint groups, **138 SQL
statements instead of 1,794**, and **278 physical checks instead of 1,932**
(including instrumentation boundaries). Fixed-context revalidation, full scans,
history/body reads and envelope decoding are zero. Native metadata work and its
bounded refresh rules are unchanged.
Recorded work/latency artifacts: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-discovery-work-gmvo57cl`.

A separate comparison rotates the frozen previous batched binary and the final
binary over the **same physical files and private stores**, without compiling
between timed variants. Each cell is the median of 27 warm samples across three
rounds. Both binaries assert independent exact IDs and unchanged note values,
editing context and accepted membership.

| 1,024 unchanged files | Previous batched implementation | Connection reuse |
| --- | ---: | ---: |
| Public profile, budget 16 | 40.61 ms | 26.10 ms |
| Encrypted profile, budget 16 | 40.47 ms | 25.37 ms |
| Public profile, budget 64 | 30.34 ms | 19.49 ms |
| Encrypted profile, budget 64 | 30.73 ms | 19.55 ms |

This is a further 36–37% reduction in median sweep time on these warm local
fixtures. [Paired results and exact binary/source hashes](/tmp/nv-connection-comparison-_xcnhs5x/results.json).
The individual work-analysis timings were more variable while other qualification
jobs ran; prefer this rotated same-fixture comparison when quoting the improvement.
These are synthetic warm sweeps, rather than a cold/provider latency guarantee.

The foreground witness also completes a real save while the lookup completion is
held, then finishes the exact scan with zero body reads. During the remaining
scan, its seven database-entry waits range from 0.022–0.259 ms (public) and
0.034–0.525 ms (encrypted). Full save timings include the existing durability
barriers and concurrent qualification load; they are not lookup-only latency.

The first broad regression pass exposed three overextensions of the optimization:
required settings were no longer checked at reconstruction, temporary loss was
made permanently sticky, and a late historical snapshot receipt incorrectly
required a still-open connection. Existing assertions remain intact. Required
inputs are now checked at reconstruction capture/installation; temporary loss and
committed-receipt behavior retain their established contracts. Early focused
passes predating these corrections are development evidence, not final qualification.
