# Phase 4F: private current rows and maintenance validation

Date: 2026-10-07. Implementation and qualification record for the
[remaining Phase 4 plan](phase4-current-row-locality-maintenance-plan.md).
The [byte/API contract](private-current-row-codec.md) specifies the implemented
physical mapping; the normative history, deletion, conflict and Undo policies
remain unchanged. Application UI/search/editor code is unchanged.

## Delivered boundaries and remaining gates

| Workstream | Current disposition |
| --- | --- |
| F0: production measurements | Real owner/key/journal recovery through full current values/context, headless model and synchronous search initialization. Warm fresh/64-edit fixtures with 64/256 notes; raw/plain/dictionary/compacted controls. Cold residency, allocation/peak-memory and larger whole-store measurements remain. |
| F1: rows and dictionaries | Versioned bounded physical frames, exact full-digest dictionary binding, named multi-generation reads, atomic dictionary/row installation and complete derived-row rebuild. Provider framing is unchanged. |
| F2: first checked capture | One-shot reuse through the existing `snapshot()` API, with fresh owner/history/view/context/presentation checks and unchanged final host-publication fence. Strict one-decode production witness. |
| F3: geometry/read-ahead | Retain the qualified 4-KiB cipher geometry on every connection. The 16-KiB candidate has no production whole-store qualification. Omit physical hints/read-ahead and their persistent state in this increment. |
| F4: compaction | Explicit idle-owner qualification API with budget/space skips, exact-job cancellation, owner retention and settlement. Automatic scheduling remains disabled; cooldown/fragmentation/large-store latency and benefit lifetime remain unqualified. |
| F5: existing performance findings | `REVIEW-START-1` fixed here. The later [startup/scoped-query report](phase-4-improvements/startup-and-scoped-queries-validation.md) qualifies optional scheduling and scoped reads; [snapshot retention](phase-4-improvements/snapshot-retention-coverage-validation.md) qualifies sequential root coverage separately. |

At this increment, private schema revision 2 added immutable derived dictionary
rows. The later scoped-query increment uses revision 3 with its conflict-copy
index. Existing
otherwise complete unreleased revision 1 inputs are preserved as unsupported;
incomplete required state retains its separate outcome. No intermediate format
migration or mixed-writer compatibility is promised. Required history,
private settings, pending references, selected-store/key policy and epoch-4 Mac
import/export remain separate roles.

## Implementation and Swift-backed checks

`CurrentRowFrameV1` consumes one bounded raw/plain/dictionary frame and then the
complete canonical cell. It rejects invalid lengths, trailing/concatenated or
skippable frames, unknown content size, excessive windows, wrong dictionary IDs
and full-digest mismatch before allocating the expanded output. Each job owns
non-Sendable zstd encoder/decoder resources; at most four prepared dictionaries
are reused, with streaming re-preparation instead of a lifetime count limit.

Ordinary/general materialization prepares immutable `EncodedCurrentRows` off
the database executor and installs them in a synchronous guarded transaction.
The private ordinary batch and recode capture bind connection/store and exact
starting view. Recoding additionally matches original physical rows, including
equal-prefix layout changes. Dictionary insertion and referencing rows share
the transaction. Unused generations remain safely retained; reclamation is
deferred. Training/recoding is explicit, with no automatic quit rewrite.

Opening carries its actual checked capture rather than decoding/discarding it.
The first consumer checks it afresh; later captures use ordinary SQL. The strict
two-note witness now observes two cell decodes instead of six. An immutable
public snapshot alone still grants no persistence or publication permission.

Maintenance uses one actor-owned closed reservation state. Its narrow C registry
issues never-reused scalar cancellation identities and pins the live connection
borrow through cancellation/retirement. Pre-start cancellation changes a flag;
only the running VACUUM receives `sqlite3_interrupt`. Required saves, private
writes, receive, backup, activation and close request cancellation before their
database turn. Resources remain owned until completion or rollback settles.
Late cancellation cannot affect the next ordinary statement.

No broad unchecked Sendable or safety-disabling build option was added. New
same-module probes challenge encoder/decoder sharing, immutable dictionary
identity and private capture/batch/request construction; valid companions
exercise the closed result enums. Genuine wrong-store/connection consumers are
tested independently from constructor denial.

## Independent bytes, crash cuts and mutations

The Node oracle and standalone C fixture generator independently produce/decode
raw, plain and dictionary frames, outside the production Swift codec. Current
rows are decoded alongside exact retained envelopes by
`inspect-storage-history.mjs`; recovery children receive ordinary selection/
unlock inputs, not the parent's expected-value oracle or acknowledgment log.

The local child-process campaign completed **24 schedules**, twelve per provider
profile. It reaches real dictionary training/insertion with mixed rows; process
termination before/after row commit, ENOSPC write and EIO sync; ordinary VACUUM,
write/sync termination and storage failure; and held VACUUM writes at ordinals
1, 8 and 32 with a competing exact saved edit. Independent inspection compares
logical current values/context, exact history/acceptance/frontiers, settings,
latest B/frozen A/pending reservation and dictionary/row cuts. The surviving cut
must be complete old or complete new, never torn.

An interruption during a nearly finished VACUUM can return completed, as allowed
by [SQLite's contract](https://sqlite.org/c3ref/interrupt.html). The held-write
tests require actual reached write ordinals, settlement, preserved state and the
new save's exact barrier; they do not require every late interruption to return
`SQLITE_INTERRUPT`. A separate actual-mid-SQL progress gate requires that code.
Its designated lost-running-cancellation mutant fails at that precise assertion.
The prepared-cancellation mutant fails at the independent ordinary-save result.

An additional cipher-boundary probe observes every actual VFS write buffer during
normal VACUUM, EIO/ENOSPC failure and successful retry, using two raw-key fixtures
and the Runtime's WAL/FULL/memory-temp settings. All six keyed cases preserve
2,000 independently named synthetic values and expose no marker in observed
writes. The unkeyed companion exposes the marker and fails at the intended
privacy assertion. These seven outcomes also pass with instrumented SQLCipher
under ASan/UBSan and on Ubuntu. The tested memory-temp build emits no temporary
file writes in this fixture; that result covers the observed paths, rather than
claiming qualification of an untested disk-temp profile. Runtime/process tests
separately cover the actual keys derived for both provider profiles.

The Swift mutation campaign challenges stale recode view/layout, unchecked first
capture, dictionary digest substitution, omitted save cancellation and foreign
maintenance consumption, alongside the affected ready-before-view-repair
control. The initial capture mutant first survived: the new test had discarded
the first result and checked a later snapshot. The test now compares the actual
first handoff's epoch with independently read database state; that mutant fails
at the intended assertion. The earlier survivor is a test defect, not evidence
of a passing guard.

## Regressions discovered and corrected

1. Off-lane row preparation initially settled the history verification request
   before installation. A failed row transaction could then lose its durable
   replay obligation. The request now spans capture, preparation and final
   installation; the original mixed-recovery/failed-marker assertions pass
   unchanged.
2. Shared encoding initially honored caller cancellation for already-owned
   received work. Required history materialization now retains ownership through
   settlement; optional recoding keeps explicit cancellation checks. The original
   received-cancellation test passes unchanged.
3. SQLCipher's pinned `PRAGMA page_size` returns text `4096`, rather than the
   integer assumed by the first budget query. The query now checks that exact
   qualified representation and uses checked multiplication; malformed/unsupported
   geometry remains explicit failure.
4. A pre-start maintenance cancellation initially interrupted any currently
   running SQL on the connection. The registry now interrupts only running
   VACUUM; the actual held ordinary INSERT companion and mutation distinguish
   these phases.

Off-lane preparation checks the bootstrap/header locator at capture and install.
The approved work assertion requires **two executions in materialization**, each
23/24 VM instructions and zero scans for that lookup, rather than comparing their
46/48 sum with one execution's cost. Per-SQL call count, minimum/maximum VM steps,
total steps and scan count are observed. All remaining per-stage reads/rows/
statements/scan bounds, zero ancestor walks and ordinary-save checks remain
intact; this does not claim every schema lookup performs zero scan steps.

## Production warm-start measurements

Swift 6.4 optimized build; five repetitions per format/profile/fixture. Timer
includes returning owner/key/journal opening, checked row capture, complete
headless values/context and synchronous lowercased title/body search setup/query.
Independent expected-value/context comparisons are outside the timer. Synthetic
Unicode prose includes a small less-compressible component. Aging is 64 ordinary
saved edits at fixed note count, not the earlier large fragmented-freelist
benchmark. All 160 samples are explicitly **warm**; no uncached-I/O claim is made.

Representative median milliseconds (same note values across each format):

| Notes / aging / profile | Raw canonical control | Plain zstd | Dictionary | Dictionary + explicit VACUUM |
| --- | ---: | ---: | ---: | ---: |
| 64 / fresh / public | 7.04 | 7.13 | 9.33 | 6.80 |
| 64 / fresh / encrypted | 7.70 | 7.78 | 7.78 | 7.60 |
| 256 / fresh / public | 22.37 | 22.88 | 22.64 | 22.15 |
| 256 / fresh / encrypted | 21.89 | 23.43 | 22.41 | 22.38 |
| 256 / aged / public | 32.83 | 26.79 | 40.54 | 25.69 |
| 256 / aged / encrypted | 37.15 | 43.42 | 33.41 | 26.63 |

For 256 fresh notes, raw canonical rows total 583,658 bytes; plain frames total
95,003 bytes and dictionary frames approximately 69,150 bytes. Every open decodes
exactly 256 current cells, loads zero historical Changes bodies/graphs and checks
two required leaves in this fixture. Raw/plain use 42 SQL statements; a single
named dictionary adds one lookup. Timings vary and are not uniformly improved
by dictionaries. Smaller BLOBs establish byte savings, not universal startup
speed, cold performance or an automatic training/compaction schedule.

Held-write resumed-save barriers locally observed roughly 52–80 ms on the small
synthetic process fixture, including actual settlement and commit. The same six
held-write cases measured 14–37 ms on Ubuntu and 205–230 ms on the Intel Mini;
the child measures settlement through its save barrier, excluding SSH transport.
The six corresponding macOS 11 VM cases measured 91–102 ms.
These measurements are not an interactive-latency certificate for unbounded
retained history; automatic maintenance remains disabled.

## Focused model correspondence

`PrivateMaintenanceSafety` covers two jobs/one save/one crash with separate
prepared/running/settled/retired, commit/ack and reopen stages. The exhaustive
safety/progress case checks 3,111 states. Five exact defects produce their named
counterexamples; two witnesses reach contested-save/crash/reopen and
prepared-save/second-job/retired-late-cancel schedules. All eight outcomes pass
the runner's exact attribution checks without state/depth constraints.

It assumes atomic SQLite commit/rollback, mutex regions and eventual SQL return
under finite interference; it does not prove actual C pointer safety, interrupt
latency, codec bytes, arbitrary stores or power-loss durability. Executable
checks cover those concrete boundaries where feasible. Existing verification
safety conditions are unchanged; the three verification scenarios and their
controls/witnesses were rerun (ten expected outcomes).

## Qualification entrypoints and records

Use the existing native driver with the pinned SQLCipher prefix, Swift 6 language
mode, complete concurrency checking, strict memory-safety diagnostics and
warnings-as-errors. Both provider profiles use encrypted private database pages.
Dependencies: SQLCipher 4.19.0 revision
`c4b275a47932888216bade83aff2bbc73df0ff85`; zstd 1.5.7 revision
`f8745da6ff1ad1e7bab384bd1f9d742439278e99`; existing Swift Crypto resolution.

```sh
PKG_CONFIG_PATH="$PWD/NVStorage/.deps/sqlcipher/lib/pkgconfig" \
  make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel'
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-types.py --modules NVStorage/.build/debug/Modules
node tools/check-private-current-fixtures.mjs
python3 tools/test-sql-maintenance.py
python3 tools/test-sql-maintenance-privacy.py
python3 tools/test-sql-maintenance.py --sanitize thread
python3 tools/test-sql-maintenance.py --prefix NVStorage/.deps/sqlcipher-asan --sanitize address,undefined
python3 tools/test-sql-maintenance-privacy.py --prefix NVStorage/.deps/sqlcipher-asan --sanitize address,undefined
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan \
  --filter 'vacuum|resumedSaveCancels|currentDictionary|currentRecode|openingCapture|privateCurrent'
```

The mutation entrypoint is `test-storage-runtime-mutations.py --only NAME` for:
`current-recode-stale-view`, `current-recode-stale-layout`,
`opening-capture-stale-view`, `current-dictionary-wrong-digest`,
`maintenance-save-skips-cancellation`, `maintenance-wrong-connection` and
`ready-before-view-repair`. Discovery, valid companions and exact assertion-line
failure are mandatory; timeouts/compile errors are not controls.

Local records: `/tmp/nv-4f-startup-bench.log`,
`/tmp/nv-4f-current-process.log`, `/tmp/nv-4f-runtime-mutations.log`,
`/tmp/nv-4f-capture-mutation.log`, `/tmp/nv-4f-maintenance-tla.log`,
`/tmp/nv-4f-c-maintenance-asan.log`, `/tmp/nv-4f-maintenance-tsan.log` and
`/tmp/nv-4f-runtime-asan.log`. The additional write-observation logs are
`/tmp/nv-4f-maintenance-privacy.log` and
`/tmp/nv-4f-maintenance-privacy-asan.log`. C ASan/UBSan and TSan companions pass;
TSan covers the registry/probe concurrency paths with the ordinary cipher
archive, not full SQLCipher instrumentation. The Runtime ASan campaign uses the
instrumented SQLCipher archive and its
independently caught expired-handle negative control. Schema constraints pass
18 direct SQL tests; both schema copies match exactly. The legacy app and
epoch-4 compatibility pass with the documented Xcode 27
`__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` workaround, preserving minimum
11.5; the default command still reports that deployment-target diagnostic.

### Platform and revision evidence

| Environment | Executed checks |
| --- | --- |
| Local arm64 macOS / Swift 6.4 | Full debug: 278 executed test functions (283 reported, five opt-in benchmarks skipped), plus final five-function debug follow-up. Final optimized: 281 executed (286 reported, the same five benchmarks skipped). Both full runs retain the same ten expected failures across the three existing F5 witnesses, with no unexpected failures. All 41 integrated qualification commands pass, including complete Runtime/private compiler-boundary campaigns. Seven separately qualified optimized mutation controls, valid companions and exact failure attribution; C/Runtime sanitizers, independent bytes/schema, and fresh-process schedules. |
| Ubuntu arm64 / Swift 6.4 | Final optimized affected suite: 21 functions, including 64/256/1,024-action growth and first save after reopening. Seven locality construction probes; 18 schema checks, independent frame fixtures, C interruption controls and all seven write-observation outcomes. Explicit optimized probe build, 24 fresh-process schedules and PIE/W^X/non-executable-stack/RELRO checks, including the RWX observer control. This is targeted platform qualification, not a complete Linux suite or sanitizer campaign. |
| Intel macOS 14.8.9 | Swift 6.4 cross-built production probe with the pinned x86_64 SQLCipher archive. All 24 fresh-process schedules pass on the actual Mini; independent Node inspection runs locally and is not supplied to the recovery child. This does not qualify the Mac's installed Swift 6.0.3 compiler, the Swift Testing runner or macOS 11. |
| Intel macOS 11.7.11 (Orbb) | All 24 new compression/compaction schedules and all 40 existing pending-state/backup/repair schedules pass on the actual VM with the Swift 6.4 direct-metadata variant and isolated concurrency back-deployment runtime described below. Independent inspection remains outside the recovery child. This qualifies that executable variant, rather than the VM's installed Swift 5.5.2 compiler, the Swift Testing runner or default macOS 11 distribution metadata. |

Linux records are under `/var/lib/nv-storage-test-volume/nv-4f.ZtglkH`:
`locality-release-final.log`, `locality-types-release.log`,
`locality-schema.log`, `locality-fixtures.log`, `locality-c.log`,
`locality-privacy.log`, `locality-probe-build.log` and `locality-elf.log`.
Local remote-run logs are `/tmp/nv-4f-linux-current-process.log` and
`/tmp/nv-4f-intel-current-process.log`, with complete 24-result manifests at
`/tmp/nv-current-maintenance-jnx_70ng/results.json` and
`/tmp/nv-current-maintenance-_d0awoxc/results.json` respectively. The qualified
probe SHA-256 values are:

- Linux: `aca3214b6354c180b510f7024dbd04be55d02f126afe2213c3a0d53f8284caca`.
- Intel Mini: `407b94f355afe5a24bb85ccb57ce4f87312a06e18f2a8a20c4f4d1af3988e8a3`.
- Orbb: `326d2d8bd821288e06d7b1505c25823da66febc6002905141c308e223bad1179`.
- Local integrated campaign: `2367d3d96ea48eb3d406f2e5c1b588d2cb7ded71fee75595741c05e4f1b03b34`.

The Orbb log is `/tmp/nv-4f-orbb-current-process.log`, with its complete 24-result
manifest at `/tmp/nv-current-maintenance-w9sw99di/results.json`. Its temporary
executable directory is `/tmp/nv-4f-orbb.hXLu44`; no system runtime was replaced.
The 40-case connected pending-state/backup/repair rerun is recorded in
`/tmp/nv-4f-orbb-private-process.log` and
`/tmp/nv-private-process-1o5n3jgy/results.json`. It preserves source/candidate
history, current values, settings, latest/frozen pending contents and reservations
through repeated I/O failures and activation crash cuts, using the same framed-row
executable. All 32 applicable independent history inspections run locally.
The reproducing cross-build uses the same pinned Intel SQLCipher archive and
retains the package's Swift 6, concurrency, memory-safety and warning checks:

```sh
PKG_CONFIG_PATH=/tmp/nv-storage-intel-ad3wfpj5/lib/pkgconfig \
swift build --build-system native --package-path NVStorage \
  --scratch-path /tmp/nv-4f-orbb-build.qQ9BHy \
  --triple x86_64-apple-macosx11.5 -c release --product NVStorageProbe \
  -Xswiftc -Xfrontend -Xswiftc -disable-concrete-type-metadata-mangled-name-accessors
```

The probe loads only the isolated Xcode `swift-5.5/macosx/libswift_Concurrency.dylib`
through `DYLD_LIBRARY_PATH`; the copied dylib's SHA-256 is
`8d4c70c66fee1bed34f756942e490a27f34bf31b54e2cd182677058acf22cefb`.
The build log is `/tmp/nv-4f-orbb-build.log`. Xcode 27 still stamps this executable
with Mach-O minimum OS 12.0 despite the 11.5 target request. The actual execution
on macOS 11.7.11 passes, while the default distribution build and deployment
metadata retain the [existing release gate](phase4-received-snapshot-validation.md#macos-11-compiler-qualification).

Local full-suite logs are `/tmp/nv-4f-native-debug.log`,
`/tmp/nv-4f-final-debug.log` and
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-storage-phase2-wsoihg7k/swift.log`.
The corrected integrated rerun reports 286 test functions in 823.868 seconds:
281 execute, five opt-in benchmark functions are skipped, and the same ten known
issues remain. Its full-suite log is
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-storage-phase2-crr8ulfk/swift.log`.
The separately enabled `currentProductionStartupBenchmark` supplies the 160
warm measurements above; its skipped aggregate entry supplies no performance
evidence. The other opt-in resource/scheduling/reader/recovery benchmarks retain
their separate campaign records and outstanding scale gates.

The complete integrated driver passes **41 qualification commands**, including
76 ordinary fresh-process checks, 40 received-snapshot, 26 S3/S4, 40 private,
24 new compression/compaction and 60 connected Phase 3 schedules; generated
faults, rejection isolation, all 131 Runtime and 29 private compiler outcomes,
18 schema tests and independent byte fixtures. The exact command/discovery
manifest is
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-storage-phase2-crr8ulfk/results.json`;
the driver log is `/tmp/nv-4f-phase2-release-complete.log`.
The final seven-control optimized manifest is
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-runtime-mutations-q3icm448/results.json`.

The tested production codec, Runtime rows, maintenance Swift/C and focused model
have these SHA-256 values; the Linux source copy matches all four production
values:

| File | SHA-256 |
| --- | --- |
| `CurrentRowFrameV1.swift` | `054eb465fee949be268a2e10c86c4685d283a9aa65bf107e025194d64b1a3f92` |
| `CurrentRows.swift` | `877176d6c1b8ca6e67eb18e0ad9f7562aa00baaa9c96d630dc1efe8de7675cba` |
| `Maintenance.swift` | `8f2c60db9a0133af21de0592bad2f2648363d41839bceb42459cac2e1a5aaf59` |
| `NVSQLMaintenance.c` | `98a80983fa9334d3b6a27a802b9413ca7412df1fafbf1a75a69cfbf5e1a2ce33` |
| `PrivateMaintenanceSafety.tla` | `ae751b5259d3e2d4edbe8c5232cc4a5be4b2cbdc807956799c506cb52fb08e56` |

The first integrated driver attempt exhausted its outer 1,800-second allowance
after queueing behind another complete suite; it is a failed qualification
attempt, not a pass. The next full Swift run completed in 929.734 seconds under
the revised 3,600-second outer allowance. Individual contention/watchdog bounds
remain unchanged. That integrated attempt later stopped at the private-state
compiler probe's valid companion because its command lacked the new
`CSQLMaintenance` module map. Adding the actual built module map fixes that
configuration error; all 29 private-state probes pass in
`/tmp/nv-4f-private-types-release-final.log`, with their original marked-line and
diagnostic checks intact. The complete integrated rerun above passes those same
probes and all subsequent schema/fixture/C checks.
A quoted-filter setup correction on Ubuntu likewise does not
count as a completed campaign. The privacy probe's strengthened exact-value
companion was rerun separately in ordinary, ASan/UBSan and Ubuntu campaigns.

## Open performance/policy gates

The later [startup/scoped-query increment](phase-4-improvements/startup-and-scoped-queries-validation.md)
addresses optional pre-publication verification and unrelated historical query
reads through their separate qualification gates. Keep the
[snapshot-root witness](phase-4-improvements/benchmark-backlog.md#snapshot-root-retention-growth)
active with its strict one-root bound for a covering v2 chain. Independent
concurrent roots still grow required-leaf startup work until explicitly covered.
The [retention-coverage report](phase-4-improvements/snapshot-retention-coverage-validation.md)
records that later remedy and separates work bounds from whole-open timing.

Cold/residency and allocation/peak-memory qualification, alternative cipher
geometry, physical read-ahead and automatic maintenance eligibility/latency
remain outstanding. macOS 11 execution is qualified for the workaround variant
above; its default distribution/build metadata remains outstanding.
Actual provider/UI behavior and physical power
loss remain separate release qualification. Portable process
termination, VFS-simulated failures and later corruption are distinct tested
fault classes, not a physical power-loss proof.
