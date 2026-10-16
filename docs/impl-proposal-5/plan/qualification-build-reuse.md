# Qualification build and result reuse

## Edit–build–test loop

Optimize cumulative checking time, not merely parallel wall time. During an edit,
run the affected debug tests with a precise Swift Testing filter and retain the
existing build directory. Reuse already qualified probe executables for successive
process schedules. Choose fixture, compiler-boundary and model checks according
to the changed responsibility; unchanged model logic needs no new TLC campaign
solely because implementation files were edited.

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter generalSnapshotLiteralLayoutsAndBounds'
```

Expand the selected checks as the change stabilizes. Debug/release full inventories,
all construction probes, platform runs and broad mutation campaigns are explicit
qualification gates, rather than the default after each small edit. Preserve each
gate's complete scenario/discovery requirements when it is selected. Filters must
discover their intended tests. `--skip-build` is appropriate only for an already
qualified unchanged binary; it cannot certify newly edited source.

Keep debug incremental compilation and compatible compiler caches warm. A fresh
scratch build is an exception for isolation or invalid build artifacts, not the
routine loop. Runtime tests now use cohesive
[test modules](test-target-build-performance.md), retaining every existing source
path and a complete-membership guard before testing. The
[shared growth-history pilot](shared-history-fixture-pilot.md) reuses checked,
closed setup prefixes while each consumer owns fresh physical stores and runs
its existing assertions. Compatible construction probes use bounded
[batching](compiler-probe-batching.md), preserving each marked diagnostic and
isolated source-modifying/SIL checks. Concurrent heavy qualification can also trip compiler watchdogs;
timeouts remain inconclusive and checks retain their original limits.

The single-v1 correction provides one measured example: its literal-layout test
executes in 0.052 seconds, while fresh debug/optimized package builds took
153.66/682.50 seconds during concurrent qualification. These are observed campaign
times, not controlled incremental-build benchmarks. They reinforce keeping warm
debug builds in the loop and treating optimized whole-test-target compilation and
repeated same-module source checking as separate optimization candidates. The
test-module report qualifies the subsequent partition rather than attributing
all of this earlier package-build time to test compilation.

## Contract

Run `python3 tools/test-storage-phase2.py --configuration both` to qualify both
configurations in a single campaign. An explicit `--reuse-directory` shares the
campaign between separate invocations. Each configuration retains its original
Swift discovery requirements, assertions, compiler clients, process schedules,
native scenario executions, profile parameters and child-process watchdogs.
The mutation runners and their cross-product remain unchanged.

The shared campaign contains three kinds of acceleration:

- Native build artifacts. Cold SQLCipher initialization, maintenance controls
  and privacy scenarios execute again using an identical qualified executable.
- Independent-check evidence. All registered Python fixture checkers, the schema
  contract suite, three Node fixture modes and two strict C diagnostic checks
  execute as one evidence group. An identical second configuration references
  this group's verified raw logs, retaining an entry for every original command.
  The configuration-independent compiler-batch harness adds its own check to
  that group, including real Swift access-control and weakened-issuer controls.
  The test-target inventory guard also checks SwiftPM-resolved membership and
  the test-only fixture dependency boundary.
- Compiler-managed module caches. Core, Runtime, private-state and root probes
  retain isolated temporary source files, actual same-module/file compilation,
  marked error locations, positive companions, counts and diagnostic classifiers.
  Compatible probes share module-cache storage; compiler-managed variant keys
  continue to separate additional flags and compilation modes.

Input manifests bind complete declared directory membership and file contents,
commands, helper implementation, actual tool executable hashes, platform,
architecture, selected SDK identity and an environment digest. Native inputs
include generated control source, headers and the pinned SQLCipher archive or
amalgamation. Only generated work-directory prefixes are normalized for native
builds; cached artifacts retain their original build/debug paths. Scenario data
and output directories stay fresh.

Per-key file locks serialize evidence producers. Successful artifacts/logs are
installed before an atomic success record; readers verify the record and payload
checksum. Missing, malformed or damaged entries take the real execution path.
Failures/timeouts issue no success record. Inputs are checked before and after
production or reuse; a concurrent change fails qualification explicitly.

The independent evidence group is captured together, avoiding a full inventory
and toolchain fingerprint for every tiny fixture script. Reports distinguish
execution from reuse and point to the originating evidence record. Campaigns
assume the selected installed SDK/system libraries remain stable during the run,
as ordinary compiler builds do. Start a fresh campaign for another OS, SDK,
toolchain, sanitizer or release-qualification run.

## Integration executable freshness

The tests Makefile checks the normal Xcode application build once per invocation.
It records all linked application objects, object inventory, app/test headers,
Sparkle framework bytes, Info.plist, compiler and link context. Each of the five
application-linked test executables has its own content-bound link receipt and
output checksum. Its helper performs the requested real link when those inputs
or installed bytes change. This works with macOS's bundled Make even when changes
share the same timestamp second; it needs neither future timestamps nor sleeps.
Other Make targets and their scenarios remain unchanged.

## Validation

`python3 tools/test-qualification-reuse.py` (also Make's
`run-qualification-reuse`) checks exact reuse, preserved-timestamp input changes,
directory membership/transitive inputs, command/toolchain/profile separation,
failed/interrupted evidence, corrupt/incomplete records, storage failure while
publishing evidence, input changes during reuse, native artifact corruption and
compiler-cache separation. Its actual-Makefile companion verifies one app build,
six initial links, zero unchanged links, five links for changed/added/removed
application inputs or headers/context, single-executable corruption repair, and
propagation of app-build failure. These are harness tests; production native and
Swift qualification remain separate observations.

Baseline before the change: the SQLCipher cold-start command took 14.51 seconds;
the Make dry run requested five application-linked executable rebuilds.
The real unchanged-input Make rerun reuses all five executables; the 13 harness
tests pass, including source/header changes with preserved timestamps, toolchain
changes, copied-evidence corruption and interrupted publication. Logs:
`/tmp/nv-qualification-final-links-warm.log` and
`/tmp/nv-qualification-reuse-tests.log`.

An initial combined campaign completed 426 debug Swift tests before it was
stopped for the separately requested snapshot-format correction. This is partial
qualification, not a completed debug/release inventory. The
[single-v1 report](phase-4-improvements/general-snapshot-v1-validation.md) records that correction's
affected-path checks. Native cold-start, maintenance and privacy execution/reuse
companions ran before the correction; their scenario executions remain separate
from cached compilation. Full inventory commands retain every check.

The later [test-target partition qualification](test-target-build-performance.md)
completed all 426 Swift tests in both debug and optimized configurations. Its
finalization reuses those exact completed runs while separately checking the
affected cross-module mutations, source preservation and index completeness.
This evidence qualifies the test partition; the earlier interrupted aggregate
campaign retains its narrower recorded scope.

Storage semantics and encoded formats are unchanged; existing TLA+ scenarios and
safety assertions remain intact.
