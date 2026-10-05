# Phase 4 S2: received snapshot assembly and acceptance

Date: 2026-10-03. Implementation is present; the qualification evidence and
remaining platform limits are recorded below. This report
covers [S2](phase4-received-snapshot-plan.md), following [S1](phase4-snapshot-acceptance-validation.md).
Large fresh-client bootstrap and installing a rebuilt current view remain S3/S4.

## Production boundaries

`ReceiveInputs.swift` supplies one canonical initial/general/Changes dispatch and
the closed `ObjectRequirement` byte/history roles. Requests carry an exact locator;
complete validation and the guarded acceptance consumer issue evidence. Exact-ID
SQL waits reconstruct their roles from immutable inputs at restart.

`receive(_:)` reserves its owner before suspension, opens the bounded compatible
envelope on the preparation worker, then commits exact candidate bytes and indexed
arrival wakeups together. Local snapshot emission and duplicate delivery use the
same retention helper. A valid standalone page reports `retainedForAssembly`.
Unsupported/invalid inputs retain bytes and their own rejection; complete Changes
follow the existing ordinary validator.

`prepareReceived` traverses complete retained page trees before semantic checking.
It retains traversal state across configurable record yields and short database
turns. A general root needs its complete original bootstrap plus accepted exact
operation/action evidence. Initial roots use the complete original-import validator,
including the pinned genesis. The latter is tested in an already bootstrapped
store; opening an incomplete fresh collection remains the separate S3 gate.

Discovery and parking are separate steps. `parkReceived` rechecks all discovered
requirements, replaces only this candidate's waits, and removes its ready entry
in the same transaction. A satisfied requirement leaves the candidate ready;
later arrival wakes committed waits. Retained history can wake a candidate but
cannot satisfy its accepted-history predicate. Root/page sets accept together
through S1's private checked batch; no circular page-first acceptance exists.

Root structural/semantic defects are its own rejection. Intrinsically unsupported
children retain their own result and block their dependents. Shared valid pages
remain usable. A bad incoming locator is checked separately from the actual
target's retained identity. Actual damage to accepted evidence blocks the owner,
even if persisting the damage marker repeatedly fails. I/O, cancellation, missing
inputs and closed ownership retain their distinct outcomes.

Acceptance advances the live retained pin, preserving earlier or later divergent
branches and complete groups outside the snapshot's represented cut. Normal
history reduction still determines Current. Optional preparation and delayed
results may stop at close after actual transactions settle. A new owner resumes
durable ready/wait work. An old completed result describes its historical commit;
its type carries no saved-note generations.

The queue reader explicitly drives its indexed lookup from `ready_objects` using
`CROSS JOIN`. Otherwise SQLCipher's planner could scan `objects` to prove that an
empty queue had no matching entries, regressing healthy returning startup.
Accepted-envelope audits now check each exact SQL occurrence as well as the
retained logical operation/action. These were real implementation gaps discovered
by executable qualification, rather than reasons to relax the assertions.

## Connected checks and independent observations

`ReceivedSnapshotTests.swift` and strengthened existing snapshot tests implement
RS01–RS12 from the plan for both profiles:

- All 24 root/two-leaf/history orders, reopen after each delivery, duplicates,
  deeper index discovery and two accepted-history prerequisites.
- Arrival or history acceptance before/during/after atomic parking, with no extra
  delivery needed for progress.
- Bad roots sharing good pages; unsupported children; unrelated valid saving;
  repeated parking/rejection write failures followed by successful reopening.
- A represented E cut whose referenced envelope contains complete E and F, plus
  concurrent R before or after root acceptance. Independent counts, exact bytes
  and both conflicting heads survive reopening.
- Real nonempty scope, Delete, Restore, Undo/Redo, copy/disposition and typed
  retirement state. Authentic body-equal defective claims fail; valid neighbors,
  post-reopen queries and subsequent saving continue to work.
- Missing accepted occurrence rows, corrupted accepted metadata/bytes and repeated
  damage-marker write failure. An independent SQLCipher connection checks surviving
  state; the damaged owner's success flags are never the oracle.
- Close/cancel at page retention, blocked root, preparation or held completed
  acceptance; reopen and a newer save precede release of an old result.
- Two actual local-save interferences during preparation, smaller budgets, and
  eight independent writer heads through deep page trees and reopening.
- Distinct initial payload dispatch through complete-bootstrap checking; exact
  newly accepted root/pages share one batch without repeating import effects.

Scheduling qualification gates suspend async continuations after capturing the
checked prefix and before history validation. Their actors release workers while
local saves run. This replaces test-only blocking gates that could exhaust worker
threads when the full suite ran many schedules concurrently. The disputed cuts,
two-interference witnesses, one-minute deadlines and safety assertions stay intact;
the gate itself now has compiler-checked isolation. The qualification driver runs
independent top-level tests sequentially so their watchdog budgets cover their own
work. Each test retains its explicit concurrent tasks, competing saves, controlled
pauses and assertions. Parallel full-suite runs exceeded existing one-minute
deadlines and remain failed runs; the passing sequential debug/optimized inventories
each execute all 199 active test functions. Swift Testing reports 200 total entries
because the existing opt-in `historyReadSchedulingBenchmark` is also counted and
skipped unless `NV_HISTORY_READ_BENCHMARK=1`. The new received-snapshot scaling test
is active and ran all six cases in each configuration.

`test-storage-received-snapshot-process.py` runs 40 fresh-process schedules for
both profiles: delivery orders; retention/parking/rejection/acceptance commit cuts;
another failure during recovery; ENOSPC/EIO and ambiguous sync. Each child receives
only the surviving store and normal selection/unlock inputs. Parent expectations
and callback logs stay outside recovery. Independent SQL and Node wire inspection
check exact envelopes, complete batch memberships, operation/action counts,
dependencies/pin, current values, queues and private groups.

The process runner also supports `--ssh-target`, `--ssh-key` and `--remote-env`:
the probe and all recovery operations run on the selected test host, while the
same independent Node oracle checks returned inspection bytes locally. This
permits older macOS execution without replacing the current independent decoder.
The remote runner reuses a private SSH control socket during its campaign. All
artifacts are synthetic temporary collections and remain available for review.

## Work and resource measurements

The optimized 64/256/1,024-action fixture keeps two current notes and five snapshot
records. Root preparation reads 6 candidate envelopes with one page, or 17 with
12 pages. Snapshot record bytes remain 695–697; history reads grow from 205 to
781 to 3,085 and SQL statements from 2,353 to 8,506 to 33,118. Lowering the record
budget from 64 to 1 preserves complete results and adds page/turn work rather than
restarting every decoded record prefix.

In one optimized encrypted run, 1,024-action receive/acceptance took 554 ms
(one page) or 560 ms (12 pages), with maximum measured writer turns of 6.8/10.0 ms
and atomic acceptance of 0.38/1.60 ms. These are observations, not hard latency
bounds. Debug/parallel qualification is slower. The complete graph/preview still
uses memory proportional to its represented history/state; bounded individual
envelopes do not make total work or RAM constant. Eight-head and deeper-tree tests
cover another shape, not every possible large graph or near-ceiling object.

A separate optimized six-case run (both profiles, 64/256/1,024 actions) passed
in 102.611 s and reported 123,486,208 bytes (117.8 MiB) maximum resident set size
for the complete SwiftPM invocation. That includes fixture construction, runtime
libraries and test infrastructure; it is not an isolated graph-allocation measure.
The command spent additional time waiting for SwiftPM's build lock, which is
excluded from the test's reported execution time. `/tmp/nv-s2-peak-memory.log`.

Duplicate intake retains one exact byte copy. Abandoned candidates remain retained;
S2 adds no cleanup/GC or collection lifetime cap. ENOSPC/EIO tests establish preserved
inputs and explicit failure, not a way to create free space or a power-loss proof.

## Model correspondence

`ReceiveSnapshotAssemblySafety.tla` connects retained bytes, accepted history,
exact waits and root/page batch acceptance in one bounded state machine. It starts
from independently specified original history, a two-Changes dependency chain,
two assembly pages and optional shared good/bad roots. A separate unsupported
child blocks its root while unrelated work remains eligible.

| Concrete boundary | Model transition / obligation |
| --- | --- |
| Candidate retention plus reverse wakeup | `Deliver`: exact stored input and applicable wakeups commit together. |
| Preparation separate from parking | `Begin`/`Discover`: missing role-qualified inputs are captured before a competing arrival. |
| Atomic wait replacement/recheck | `CommitPark`: current satisfaction is rechecked; satisfied work stays ready. |
| Complete accepted closure | `CommitAccept`: all required history is accepted; root/pages join one batch. |
| Intrinsic rejection and retryable write failure | `CommitReject`/`WriteFailure`: own results only; retained bytes and old committed state survive. |
| Optional close and crash/reopen | Close/reopen actions stop preparation and retain committed actionable work. |

Five exhaustive configurations completed, including two crashes/two failures
(354,823 states), shared roots (996,755 states), and shared roots with an unsupported
page (1,122,253 states). Five mutations fail the exact intended property: lost
arrival wakeup, stale parking, retention-as-acceptance, circular page acceptance
and inherited rejection. Five negative reachability assertions expose arrival
during parking, retained-but-unaccepted history, completed roots, blocked/unrelated
progress and recovery after two failures. Source SHA-256:
`ad4c26da7529e0f5b26216315c41cfaa3516bf64bd2a6c8c67e797eec7d4bdff`.

Progress is scoped to finite intake (each role plus one arbitrary duplicate), finite
faults, eventual retry/reopen and weak fairness of enabled work. An infinite stream
of duplicate delivery can continually requeue a blocked root ahead of another
candidate; the model does not disguise that separate intake-fairness problem as
proof of indefinite fairness. Cryptography, byte parsing, truthful classification,
SQLCipher durability, real executor behavior, arbitrary graph sizes and S4 row
installation remain executable or later-model obligations. Existing resumption and
rejection model safety/progress conditions remain unchanged and are rerun separately.

## Qualification entrypoints and remaining boundaries

```sh
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-mutations.py --configuration release --only received-snapshot-lost-arrival
python3 tools/test-storage-runtime-mutations.py --configuration release --only received-snapshot-stale-parking
python3 tools/test-storage-runtime-mutations.py --configuration release --only received-snapshot-inherited-rejection
python3 tools/test-storage-runtime-mutations.py --configuration release --only received-snapshot-optional-close-gate
python3 tools/test-storage-runtime-mutations.py --configuration release --only received-snapshot-omitted-occurrence-audit
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter 'receivedSnapshot|receivedInitialSnapshot'
python3 docs/tla/check-receive-models.py --java /path/to/java --jar /path/to/tla2tools.jar --only assembly --timeout 300
```

The standard driver requires a completed build, named discovery, real child-process campaigns,
independent fixtures, schema checks, compiler construction/consumer challenges and
strict C diagnostics. Mutations require the intended runtime assertion; a compiler
error, surviving mutant or missing discovery is not credited. Early incorrect
mutation recipes were corrected and rerun rather than reported as qualified.

SwiftPM on the constrained Linux VM printed `Build cancelled!` and then ran an
older test executable with exit status zero. That run is rejected: it omitted
the new snapshot tests. The driver explicitly requires `Build complete!` and
rejects the cancellation message in addition to its named-discovery requirements.
Raw log bytes are retained; display parsing replaces malformed UTF-8 when
concurrent SwiftPM diagnostic streams split a glyph. Exit status, required ASCII
test names, completed builds and final successful test counts remain mandatory.

The runtime construction campaign now has 110 probes (14 in the actor-only
subset), plus its diagnostic-classifier self-check. Two new ordinary/same-module
cases distinguish receive requirements/results from save receipts; the additional
same-module case checks the file-private prepared-candidate boundary. The first
optimized driver run passed the individual ordinary/same-module probes and then
failed its obsolete expected-count assertion. The counts were corrected and the
complete 110-probe campaign passed with the same strict compiler flags, marked
source-line checks and exact diagnostic requirements.

### Recorded campaigns

| Campaign | Observed result |
| --- | --- |
| arm64 macOS 26.6.2 / Swift 6.4 | Sequential debug and optimized inventories each passed all 199 active functions, including both profiles and explicit concurrent schedules; one existing opt-in benchmark was skipped. Complete driver results are recorded below. |
| SQLCipher and Swift AddressSanitizer | The instrumented cipher's valid/expired-handle controls behaved as required; all 18 selected snapshot/scheduling functions passed in 525.357 s. `/tmp/nv-s2-sanitizers-source-final.log`. |
| ThreadSanitizer | All four selected parking, optional-close, preparation and resumption functions passed in 199.572 s. `/tmp/nv-s2-tsan-final.log`. The cipher archive and system libraries remain outside this TSan instrumentation. |
| Production mutations | Lost-arrival wakeup, stale parking, inherited rejection, optional-work close gating and omitted occurrence audit each failed at the intended runtime assertion. The adjacent ready-recovery and receive-reservation controls also failed as intended. `/tmp/nv-s2-mutations-corrected-final.log` and `/tmp/nv-s2-mutations-final2.log` identify the corrected recipes. |
| TLA+ | All 15 assembly configurations/controls/witnesses passed their expected outcomes; the 47 existing resumption/rejection cases also passed. `/tmp/nv-s2-tla-assembly-complete.log`, `/tmp/nv-s2-tla-resumption.log`, `/tmp/nv-s2-tla-rejection.log`. |
| Intel macOS 14.8.9 | All 40 received-snapshot fresh-process schedules passed, with the independent wire/SQL oracle. `/tmp/nv-s2-mini-process-final.log`. |
| Intel macOS 11.7.11 | All 40 schedules passed using the direct-metadata compiler variant described below. `/tmp/nv-s2-macos11-complete.log`. |
| arm64 Ubuntu / Swift 6.4 | All 17 affected functional/scheduling functions passed in 84.339 s, and all 40 fresh-process schedules passed, using real native binaries and disk-backed temporary storage. `/tmp/nv-s2-linux-functional-qualified.log`, `/tmp/nv-s2-linux-process-qualified.log`. The separate six-case scaling test exceeded this VM's available disk and remains unqualified here; it passed in both macOS configurations. |
| Legacy application build | `build.sh` reached Xcode 27's deployment-target diagnostic. The identical build succeeded with `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO`, preserving target 11.5 and the warning. `/tmp/nv-s2-app-build-override.log`. |

The optimized inventory passed in 236.568 s. Its driver also passed the 72 basic
fresh-process checks, disposal/history campaigns, 22 local-snapshot cases,
40 received-snapshot cases, 12 Restore cases, six merge-evidence cases, all 60
connected lifecycle schedules, eight generated schedules reaching all six fault
classes, 18 rejection schedules, cold-start controls and Core compiler probes.
The runtime-probe count correction described above was then verified by a complete
110-probe rerun. The remaining 15 schema/independent-fixture/C-diagnostic commands
passed separately, completing that interrupted campaign's checks. The original
driver invocation remains recorded as failed, rather than rewriting its exit
status. Artifacts: `nv-storage-phase2-vau_gn4j` under the host's temporary directory
and `/tmp/nv-s2-runtime-types-release-final.log`.

The final debug driver completed all 30 qualification commands with exit status
zero and 199 named active tests discovered. Its Swift inventory passed in
430.147 s, followed by the complete process, generated-failure, rejection,
compiler, schema, fixture and strict C campaigns. The machine-readable result is
`nv-storage-phase2-td9egyrr/results.json` under the host's temporary directory;
the driver log is `/tmp/nv-s2-qualification-debug-final.log`.

The Linux build required temporary swap and serial compilation within the VM's
2 GiB RAM. Both temporary swap files were disabled and truncated afterward; boot
configuration is unchanged. The completed native build keeps strict concurrency,
strict memory safety and warnings as errors. Both linked ELF executables passed
the PIE, W^X, non-executable stack and RELRO checker, including its deliberate RWX
negative control.

Earlier Linux attempts are failed campaigns: compiler OOM/build cancellation,
actual ENOSPC while accumulating fixtures, and write errors on the quota-enabled
`/tmp` tmpfs. Qualification uses `/tmp/nv-storage-disk`. Reproducible compiler
intermediates were removed under the authorized work-file cleanup. Three large
synthetic stores were copied to `/tmp/nv-s2-linux-fixture-backup.vn2BaD` on the Mac;
all nine files were SHA-256 verified before removing those exact VM copies. Source,
native linked executables and the other test collections remain intact.
All 96 Swift source/test files and test C/header files were hash-compared between
the local and qualified Linux source trees. The sorted relative-path/SHA-256 JSON
manifest (compact separators) has SHA-256
`4845093d6c289cc3b2fa73413aab1cfc985f2e5bc1711f89367358e41c554215`.

### macOS 11 compiler qualification

The normal optimized Swift 6.4 Intel probe crashed at entry to `Probe.run`, before
opening a store. Disassembly and the symbolicated report locate a failed
`TaskPriority?` metadata lookup through
`__swift_instantiateConcreteTypeFromMangledNameV2`. This observation concerns this
compiler/runtime combination; it does not identify an actor-ownership failure.

Rebuilding with `-Xswiftc -Xfrontend -Xswiftc
-disable-concrete-type-metadata-mangled-name-accessors` generated direct metadata
access and passed the complete 40-case campaign. The variant retains Swift 6
mode, checked concurrency, strict memory safety and warnings as errors. The probe
loaded Xcode's macOS concurrency back-deployment library through `DYLD_LIBRARY_PATH`.
The reproducing build was:

```sh
PKG_CONFIG_PATH=/private/tmp/nv-phase3-cipher-intel/lib/pkgconfig \
swift build --build-system native --package-path NVStorage \
  --scratch-path /private/tmp/nv-phase4-s2-intel-build \
  --triple x86_64-apple-macosx11.5 -c release --product NVStorageProbe \
  -Xswiftc -Xfrontend -Xswiftc -disable-concrete-type-metadata-mangled-name-accessors
```

This qualifies that build variant on macOS 11. The package's default flags are
unchanged; selecting and testing the eventual app/library distribution build
configuration remains a release requirement. The ordinary Intel build passed on
macOS 14. Artifacts include `/tmp/nv-s2-intel-direct-metadata-build.log` and the VM's
`NVStorageProbe_2026-10-03-110515_orbb.crash` report.

Physical power loss, actual provider/UI adapters, fresh large bootstrap,
snapshot-based rebuilding, backup/salvage activation and candidate cleanup remain
explicitly unqualified by S2.
