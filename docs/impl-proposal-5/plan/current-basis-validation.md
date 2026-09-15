# Ordinary saves from checked current rows

## Contract and scope

`CheckedCurrentBasis` in `HistoryDatabase.swift` is a file-private, short-lived value created
and consumed inside the serialized acceptance transaction. It reuses the existing
current materialization as the prior state for **one ordinary action**, including
multi-note creation/deletion. Received envelopes use the same rules as local saves.
Public storage APIs and canonical encodings are unchanged.

Issuance requires:

1. The owned database/header/collection checks pass, with no known retained-history
   damage. The current view has the supported reducer, a valid epoch and a positive
   represented sequence equal to the accepted sequence.
2. All action members are new Create/Put/Delete operations, one per affected birth,
   in exactly the payload's operation order; the action ID is new as well.
3. The first operation's parents equal the current operation frontier. Every
   subsequent member names the previous member as its sole parent.
4. Before-states, note predecessors and applicable scope parents exactly match
   the affected current rows and authoring context. A Create additionally checks
   the existing birth index, including births whose notes have been deleted.

The ordinary semantic rules are shared with the full validator: exact membership,
before/after states, predecessors, scope maxima and previous-origin semantics.
Envelope integrity, operation identities and exact external references are still
checked. Directly referenced retained envelopes are opened and checked on each use.
Previous-origin membership is sufficient here because the complete represented
history and exact first-parent frontier establish that **every** previously accepted
action is observed. An accepted action on some other branch is insufficient when
those eligibility conditions fail. Local sequence numbers only identify the private
accepted prefix; they supply no portable causal order.

Failure to establish eligibility selects the full declared-writer-history validator.
This includes delayed materialization, older/divergent captures, duplicate logical
records, repackaged records, multiple actions or multiple operations per birth.
Malformed input and retained-history damage keep their existing outcomes. Exact
bytes, retry ownership, receipt issuance and host pending-generation clearing are
unchanged. Acceptance and materialization remain separate transactions.

Reopening uses the existing current rows and context. Healthy reopening requires
no historical validation cache; invalid derived state uses the established rebuild
path and known required-history damage blocks acceptance/publication. Owner/header
fences still apply to the actual transaction, rather than the earlier capture.

## Incremental frontiers

For a complete, dependency-closed accepted graph with maximal frontier `F`, accepting
genuinely new vertices `N` with direct parents `P` produces:

```text
new frontier = (F ∪ N) − P
```

An old indirect ancestor already has an accepted descendant, so it was already
absent from `F`. Adding the whole new object batch before removing its direct
prerequisites also handles edges within the batch. Duplicate accepted records add
no new logical effects.

Runtime applies this separately to the retained **object** frontier and the current
**operation** frontier. Descriptor retention stays separate. Repackaged envelopes
can enlarge retained object coverage while leaving the operation frontier unchanged.
Ordinary recovery catch-up uses the same operation update.

No new tables, record fields, sidecars or long-lived validation cache are added.
One index, `operations_action(action_id, operation_id)`, indexes an existing foreign
key. Measurement found that SQLite otherwise scans older operations while inserting
their action. Both copies of the executable DDL include this index. It carries no
new semantic fact, changes no encoded format, and is not acceptance evidence.

## Executable checks

Run the full slice with `make -C tests run-swift-storage-phase2`, and again with
`SWIFT_STORAGE_PHASE2_FLAGS='--configuration release'`. Run the affected mutation
campaign with `python3 tools/test-storage-runtime-mutations.py` and `--configuration
release`. The test driver explicitly selects SwiftPM's native build system, preserving
its artifact layout for compiler/process probes across the tested toolchains.

| Obligation | Executable observation |
| --- | --- |
| Fast/full agreement and independent results | `currentBasisAgreesWithFullValidation`: both profiles; edit, rename, labels, two-note creation/deletion and deletion; exact expected values after receipt and reopen |
| Near-valid rejection | `currentBasisRejectsNearValidClaims`: valid companion, omitted scope parents, old before-state, wrong predecessors/parents, wrong origin, bad external record index and conflicting action ID |
| Deleted birth remains reserved | `currentBasisChecksHistoricalBirthReuse`: fresh companion and Create attempting reuse after deletion; both full and Runtime validators reject reuse |
| Complete view is necessary | `currentBasisRequiresCompleteMaterialization`: accept a concurrent action without materializing it, then present a group claiming that unobserved previous-origin action; retention availability alone must not validate the claim |
| Branches, parked work and SQL frontiers | `currentBasisPreservesBranchFrontiers`: independent-note branches, joined edit, exact object and operation tips, child-before-parent, duplicate receive and reopen |
| General direct-parent lemma | `incrementalFrontierMatchesIndependentReachability`: all 1,024 five-vertex topologically ordered DAGs and all eligible old/new/absent partitions; **54,036** cases compared with independent transitive traversal |
| Work versus actual ancestral history | `ordinarySaveWorkAcrossGrowingHistory`: 64, 256 and 1,024 ordinary actions, two fixed-size current notes, both profiles, warm and first save through a new reopened owner |
| Issuer and consumer boundaries | Ordinary and same-module construction probes reject `CheckedCurrentBasis`; existing wrong-store/session/view consumers remain in the full suite |
| Crash, delayed completion and corruption | Existing production VFS/child-process campaign and Runtime schedules, including missing callbacks, materialization failure, exact retries and parked multi-parent work |

The growth test counts SQL statements, returned rows, prepared-statement VM steps,
retained-envelope reads/decodes, ancestor visits and recursive SQL across the full
save. It separately times validation, acceptance and materialization and reports
end-to-end time. Diagnostic counters are optional, queue-owned and cleared after
each observation. SQL VM counts cover prepared statements; `sqlite3_exec` transaction
controls contribute statement counts rather than VM counts.

Eligible saves must have zero ancestor visits and zero recursive SQL in every
stage, with unchanged read, decode, statement, returned-row and full-scan-step counts
across those history sizes (warm and reopened cases compared separately). Per-query
VM counts are also unchanged except for two checked alternatives: the bootstrap
existence lookup uses 23/24 instructions, and the one-dependency frontier deletion
uses 37/38. Their actual `EXPLAIN` programs use `Next` followed by `IdxGT` when
another index key follows the matched key; reaching EOF skips that final `IdxGT`.
A sanitizer run exposed the lookup variation; the Ubuntu optimized run exposed
the deletion variation, which a separate pinned-SQLCipher executable reproduced
on macOS by changing only the matching key's position. Both deletion cases removed
one row and performed zero full-table scans. The user approved accepting the two
verified deletion counts. The final check names each exact query and both permitted
counts rather than granting general growth tolerance. This is an assertion about
work attributable to accumulated history, **not constant-time B-tree lookup** or
constant latency. Note size, changed-note count, frontier width, encryption, I/O and
database depth remain relevant. Growth of current authoring frontiers and general
branch validation still need the planned resumable/paged treatment.

Mutation challenges remove complete-prefix/parent/birth guards and damage object
or operation frontiers. The existing early-ack, missed-wakeup, stale-completion,
wrong-context, wrong-materialization and retention challenges remain. Mutants must
fail their designated assertion with nonzero required test discovery; compilation
failure or disagreement between two equally incorrect validators is insufficient.

## Model correspondence and remaining boundaries

`SQLiteCollectionSafety` treats accepted history as complete and semantically
validated; `SQLiteFastStartSafety` requires an accurate materialization of its stated
accepted prefix and publication fences. This optimization refines how those facts
are established and maintained, without changing their modeled transitions or
safety conditions. The executable eligibility and independent DAG tests bridge the
concrete algorithm; the TLA+ models do not prove Swift decoding or this optimization.
No model assertion was weakened and unchanged TLC configurations need no rerun.

The later [hardening increment](phase2-hardening-validation.md) implements
off-writer validation/one-read writer turns and receive quarantine for the ordinary
history subset, with generated recovery schedules and SQLCipher instrumentation.
Older/divergent branch acceleration, row compression and general conflict/undo
reducers remain separate increments.
Platform execution and physical power-loss qualifications must be recorded separately
from process-kill, simulated persistence failure and later corruption tests.

## Qualification results

Development host: arm64 macOS 26.6.2 (25G83), Swift 6.4
(`swiftlang-6.4.0.34.1`), SDK 27.0, pinned SQLCipher 4.19.0/CommonCrypto.
Both profiles use encrypted private database pages.

| Check | Result |
| --- | --- |
| Full Swift suites | 82 discovered test functions passed in debug and optimized builds |
| Fresh-process recovery | 72 checks in each build, including independent exact-envelope/history inspection; both profiles |
| Compiler boundaries | 21 Core and 24 Runtime ordinary/same-module probes passed, plus diagnostic-classifier self-checks |
| Independent format/schema checks | Existing fixture/crypto entrypoints, resource-DDL equality and 17 SQL schema tests passed |
| Mutations | All 14 Runtime mutants failed their designated assertions in debug and optimized builds; each isolated baseline passed |
| AddressSanitizer | Seven new validation/frontier/growth functions passed with optimized code and strict-memory diagnostics |
| ThreadSanitizer | All 22 Runtime functions passed after diagnosing the bootstrap-query instruction-count variation described above |
| Legacy application build | `build.sh` initially stopped at Xcode 27's deployment-target diagnostic. The same build with the user-supplied `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` passed. `vtool` reports minimum macOS **11.5** for both x86_64 and arm64, with SDK 27.0. No project deployment target was raised. |

The Swift Testing skill guided the parameterized valid/failure companions and
independent expected-value checks. No compiler diagnostic or semantic rejection was
waived. New instrumentation borrows the prepared statement for `sqlite3_stmt_status`
before finalization on its owning queue; it adds no pointer escape. Existing unsafe
FFI diagnostics remain explicit reviewed boundaries. The separately compiled
SQLCipher archive/system crypto are not fully sanitizer-instrumented.

### Measured ancestral work

The pre-change optimized baseline used the production algorithm at commit
`667e973ed11958bb488395bfedca79d86acd32d1`, with counters added before changing validation
or frontiers. These are **validation-stage** counts for a warm ordinary edit:

| Earlier ordinary actions | Baseline retained-envelope reads / decodes / ancestor visits | Current-basis reads / decodes / ancestor visits |
| --- | --- | --- |
| 64 | 339 / 340 / 137 | 2 / 3 / 0 |
| 256 | 1,299 / 1,300 / 521 | 2 / 3 / 0 |
| 1,024 | 5,139 / 5,140 / 2,057 | 2 / 3 / 0 |

The first save through a reopened owner at 1,024 actions changes from
5,144 reads / 5,145 decodes / 2,059 ancestor visits to **1 / 2 / 0**. Its fresh
action origin has no previous-origin record to read. Across all three sizes,
the fast path has 9 validation statements warm and 6 reopened. Acceptance uses
20 statements and materialization 12. Both later stages perform zero recursive
SQL and zero full-scan steps. At 1,024 actions, their prepared VM counts change
from 35,933 to 974 (warm acceptance) and 23,875 to 216 (materialization).

For scale, one optimized encrypted 1,024-action sample changed validation from
499.5 ms to 0.33 ms; the reopened sample changed from 519.9 ms to 0.25 ms.
The final measured complete saves were about 12–28 ms across the matrix, including
SQL barriers and current-row updating. These are diagnostic samples, with other
qualification processes running, not latency percentiles or a production guarantee.
Deterministic work assertions carry the regression check; timing alone does not.

Full-driver artifacts are `nv-storage-phase2-qy5f03rf` (debug) and
`nv-storage-phase2-80_6u5vj` (optimized) under the host temporary directory.
Mutation artifacts are `nv-runtime-mutations-ljml3u5n` and
`nv-runtime-mutations-5ja2otq0`. Additional logs under `/tmp` include
`nv-current-basis-baseline.log`, `nv-current-basis-asan.log`,
`nv-current-basis-tsan-final.log` and `nv-current-basis-app-compat-build.log`.
Tools and named assertions above remain the reproducible evidence after temporary
artifacts expire.

### Ubuntu qualification and platform limits

Ubuntu 26.10 arm64 used Swift 6.1.3, pinned SQLCipher 4.19.0/OpenSSL and an
ext4-backed temporary workspace, with one build job and 2 GB RAM.

| Check | Result |
| --- | --- |
| Swift suites | All 82 functions passed in final debug and optimized runs, including the approved query-specific instruction counts |
| Fresh-process recovery | 72 optimized checks passed; all 46 preserved SQL/envelope reports then passed the independent inspector on the Mac |
| Compiler boundaries | 21 Core and 24 Runtime ordinary/same-module probes passed, retaining exact diagnostic and marked-source-line checks |
| Schema | All 17 executable DDL checks passed with the added foreign-key index |

The arithmetic split in `ActionRecordV1.encodedByteCount` preserves the UInt64 calculation and all limits,
but avoids a Swift 6.1 type-inference bottleneck exposed by the raw-source Core
probes. The Core harness now typechecks each same-module probe as one whole-module
job rather than repeatedly checking the module for each primary file. All source
files, visibility rules, valid companions, rejection checks and the 60-second
per-probe timeout remain in place. These changes also pass on Swift 6.4.

An incremental native SwiftPM invocation stalled before launching compilation.
The successful final VM build used the supported `--use-integrated-swift-driver`
and `--disable-build-manifest-caching` options with `--build-system native -j 1`.
Build-cache files were preserved under new names during diagnosis. With the user's
later cleanup authorization, the obsolete `/tmp/nv-storage-disk/nv-zstd-build`
cache was removed to make room for the final debug run. This freed roughly 400 MB;
sources, current build products and validation reports were preserved. The removed
cache is reproducible from the pinned dependencies. After that run, four older
synthetic growth-test stores and four failed compiler-probe caches were removed,
leaving about 960 MB free. Both final build configurations, their benchmark stores
and all qualification reports remain. The removed fixtures can be regenerated;
their exact temporary database bytes are no longer retained.

VM logs are under `/tmp/nv-storage-disk/`: `current-basis-integrated-debug.log`,
`current-basis-integrated-release.log`, `current-basis-runtime-types.log`,
`current-basis-core-types-final.log`, `current-basis-schema.log`
and `current-basis-process.log`. Recovery artifacts are `nv-storage-process-u6a3va7t`.
Their independently checked Mac copy is
`/tmp/nv-current-basis-ubuntu-artifacts.7Ki1Ue`; the inspection result is
`/tmp/nv-current-basis-ubuntu-inspection.log`.

Intel macOS 11/14 execution is unavailable for this increment: the user is away
from that network and those Macs cannot currently be reached. Earlier platform
results remain historical evidence, not a run of these changes. Physical power
loss remains unqualified.
