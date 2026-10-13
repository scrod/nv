# Shared growth-history fixture pilot

## Scope and preserved checks

Share the setup of `receivedSnapshotGrowingHistoryMeasuresCompleteWork` and
`repositoryExchangeUnchangedHistoryReadWorkRemainsBounded`. Keep the existing
64/256/1,024 sizes, both provider profiles, snapshot budgets 64/1, every assertion,
ten-minute per-test watchdogs and isolated consumer stores. Production source,
compiler settings, encoded formats and mutation-runner cross-products remain
unchanged. Other tests retain their existing fixture helpers.

The snapshot test still independently captures its source state, assembles new
sealed pages/root, receives each page and verifies complete root acceptance for
every size/profile/budget combination. The discovery test still creates its own
repository and fresh destination, delivers every file and performs real initial
discovery/receive, unchanged rescans and the final one-file arrival.

Discovery's unasserted setup bodies now use the snapshot test's `E1`…`E1024`
sequence. The causal shape remains one writer, one saved action and one immutable
envelope per edit, two current notes and a single operation frontier. The final
`one new file` edit is captured from that same writer with its next sequence;
each discovery test installs it only after its unchanged scans. This preserves
the original next-file stimulus within the already-discovered writer directory.

## Ownership and preparation

`NVStorageTestSupport/GrowthHistory.swift` uses public Core/Runtime APIs. One
process-local actor coalesces a complete build per profile. The builder performs
every ordinary save through the real runtime, decodes its exact
envelope and checks the value, operation/action membership, causal predecessor,
note predecessor, origin/scope chain and writer continuity. A separate receiver
accepts every history object through the real receive path.

At each checkpoint, public `backupPrivateStore` creates closed source and receiver
copies and performs its complete-history/private-state audit. Only after all
checkpoints and the following edit finish, and the builder's stores close, does
the actor return immutable fixture values. A failed build remains failed for the
process; partial checkpoints are never returned as usable fixtures.

Each consumer obtains a fresh physical directory by copying a closed seed and
opening it normally. The copy's accepted prefix, current values and exact tip are
checked before use. Seeds and writable database connections remain private to
their owners. Fixtures retain neither a shared writable test store nor unchecked
acceptance receipts; Swift actor isolation and `Sendable` values enforce this
separation. There is no cross-process/cross-configuration fixture cache.

Snapshot cases obtain separate source and receiver copies. Discovery obtains
the appropriate source copy for each prefix, while its own fresh destination
receives all files itself. These tests continue to exercise production
`synchronous=FULL`, full-sync, encryption, validation and ownership settings.

## Validation

The three small fixture-control tests cover:

- Concurrent requests coalesce; all checkpoints belong to the same exact history.
- Source and receiver copies have distinct physical directories/database inodes, independently
  expected accepted-byte inventories and operation/action counts.
- Editing and closing one consumer changes neither a reopened second consumer nor a later seed copy.
- Exact retained bytes survive copying; the undisclosed following edit retains
  its writer and next sequence.
- Failure after a checked intermediate checkpoint publishes no prefix and does
  not start another build silently.
- Invalid sizes/configurations fail explicitly; profile selection remains exact.

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter growthHistory'
python3 tools/test-storage-test-targets.py --describe
```

The inventory guard compares all shared-helper source files with SwiftPM's actual
resolved support target. Its 24 controls include omission of a newly added helper;
production product dependency checks and the public-storage-API fixture boundary
remain enforced.

Affected mutation companions retain their original selected-test cross-product:

```sh
python3 tools/test-storage-runtime-mutations.py --configuration debug --only received-snapshot-lost-arrival --only exchange-lost-observation-hint
python3 tools/test-storage-runtime-mutations.py --configuration release --only received-snapshot-lost-arrival --only exchange-lost-observation-hint
```

Require passing companions, nonzero complete discovery and each designated
assertion failure. Broader unmodified mutation definitions retain their existing
qualification scope.

## Benchmark method and results

Artifacts: `/tmp/nv-shared-history-pilot.3bISbR`. Use the same warm, previously
qualified package directory, installed compiler/SDK, four build jobs and serial
test execution for both revisions. Build changed tests separately from execution.
Each measured invocation starts a fresh process, so the after result includes
the shared fixture's complete construction rather than measuring a warm cache.

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--skip-build -c debug -j 4 --no-parallel --filter receivedSnapshotGrowingHistoryMeasuresCompleteWork\|repositoryExchangeUnchangedHistoryReadWorkRemainsBounded'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--skip-build -c release -j 4 --no-parallel --filter receivedSnapshotGrowingHistoryMeasuresCompleteWork\|repositoryExchangeUnchangedHistoryReadWorkRemainsBounded'
```

`--skip-build` requires the exact already-built revision. The recorded commands
also select the verified isolated package using `SWIFT_STORAGE_PACKAGE_PATH`.
The escaped `\|` preserves regex alternation through Make's shell command.
Keep both complete test/parameter inventories and compare the snapshot work
counters and discovery read/turn outcomes. Measure build time, complete execution,
fixture preparation and the measured operations separately.

| Configuration | Original execution | Pilot execution | Outcome |
| --- | ---: | ---: | --- |
| Debug | 544.606 s | 396.564 s | Both tests passed; 148.042 s saved (27.18%) |
| Optimized | 496.546 s | 398.679 s | Both tests passed; 97.867 s saved (19.71%) |

Before full command elapsed/user/system times were 555.03/119.88/44.61 seconds
debug and 502.43/65.79/46.67 seconds optimized. After times were
403.88/95.20/36.11 seconds debug and 409.03/49.85/32.81 seconds optimized.
Combined driver/child CPU fell from 164.49 to 131.31 seconds debug and
112.46 to 82.66 seconds optimized. These are matched selected-run
observations, not statistical or cold-storage guarantees. Shared preparation may
shift time into whichever test requests a profile first; use the combined elapsed
time to judge the pilot. Debug fixture builds took 113.38/116.61 seconds for
public/encrypted profiles, and optimized builds took 124.78/119.75 seconds.
Discovery still performs its own initial reception and pays the first fixture
request: 371.402/385.214 seconds debug/optimized. Snapshot reception then takes
25.161/13.464 seconds. The unchanged discovery-arrival work limits the achievable
savings; the pilot deliberately preserves that path.

The first request prepares all three checkpoints for its profile. This favors
the combined growth workload and full suites; a filtered run requesting only a
small size can pay more setup than its former independent fixture. Subsequent
requests in the same process reuse the checked prefixes.

`analyze.py` requires both tests, all eight parameter cases, all twelve snapshot
size/profile/budget combinations and all six discovery size/profile combinations.
Before/after page counts, record counts/bytes, candidate reads/bytes, historical
reads, SQL counts, writer turns and discovery read/turn counts match exactly.
Raw logs are retained. The analysis joins only the exact known SwiftPM
deprecation warning when it interleaves a metric; qualification still uses the
real run's passing outcome and original assertions. `results.json` records the
metrics and equality results.

All three fixture controls passed in debug and optimized modes. The strengthened
debug controls took 14.173 seconds; optimized controls took 6.296 seconds.
Ordinary and same-package constructor probes fail at their marked source lines,
while the same-package consumer companion compiles, in both configurations with
strict concurrency/memory-safety and warnings-as-errors checks.

The first small-control run exposed an incorrect new oracle: the two-note
bootstrap retains two import actions and its descriptor in accepted membership.
The oracle now explicitly expects those records; the original growth assertions
were unchanged. A first after command had incorrect Make filter quoting and was
stopped; standalone probe setup also needed the existing helper/SDK search paths.
Those first-failure/setup artifacts remain separate from passing qualification.

The 426 original test identities and argument signatures remain present in both
configurations, with three additional fixture-control methods. All 224 recorded
production/Core-fixture/probe inputs and existing fixture helper bytes remain
unchanged. Each original growth test's six assertions and parameter/watchdog
declaration are byte-for-byte unchanged.

Both affected mutation campaigns passed their unmodified companions with all
14 parameter cases. In debug and optimized configurations,
`exchange-lost-observation-hint` failed the zero-read assertion at
`RepositoryExchangeLifecycleTests.swift:34`, and
`received-snapshot-lost-arrival` failed exact root acceptance at
`ReceivedSnapshotTests.swift:503`. Each result was classified as a targeted
runtime failure. The existing selected-test cross-product and all mutation
definitions remain unchanged. Raw debug/optimized artifacts are under
`nv-runtime-mutations-fx1payul` / `nv-runtime-mutations-n3r6po5i` in
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`; their `results.json`
records the commands, source hashes and designated failures.

The previous 426-test full-suite results in
`/tmp/nv-test-target-profile.66F0Wq/full-debug.log` and `full-release.log`
remain evidence for the unchanged tests. The changed growth setup and three new
fixture controls were qualified by the targeted runs above; this report does
not claim a new 429-test full-suite execution. The app build passed with the
existing deployment-diagnostic override, retaining its macOS 11.5 target;
`app-build.log` records the existing Xcode deployment/Simulator warnings.
The inventory guard passed all 24 controls and resolved all 72 Runtime test
files exactly once. Regenerate and check the
[validation index](../../Test-and-Validation-Index.md) with the documented
`tools/generate-test-index.py` commands.

Storage semantics and TLA+ behavior are unchanged. Unavailable remote platforms
and physical power-loss qualification retain their existing scope.
