# Swift test-target build performance

## Design and preserved contracts

Profile the actual Swift test build, including optimized whole-module compilation,
before partitioning the large Runtime test module. Measure compiler elapsed time,
child CPU time, unchanged builds and a one-file test edit separately. Keep the
same compiler, SDK, dependency revisions, job limit and production settings.

Runtime tests retain their existing paths under `Tests/NVStorageRuntimeTests` and
compile in three cohesive modules:

| Test module | Responsibility | Existing source files |
| --- | --- | ---: |
| `NVStorageRuntimeTests` | Local/receive acceptance, causal actions, queries and scheduling | 38 |
| `NVStorageRecoveryTests` | Snapshot reconstruction/retention, private state, backup, repair and maintenance | 14 |
| `NVStorageRepositoryTests` | Root/file adapters, repository exchange and collection startup | 19 |

`NVStorageTestSupport` is a test-only target containing the existing shared
fixtures. Its package-visible functions use public Core/Runtime APIs; its gate
actor retains compiler-isolated continuations. Keeping the support target in
the test build also preserves SwiftPM's test-framework deployment context.
Core's smaller test target and its fixture bundle retain their existing layout.
Cross-feature receive companions stay together with their existing internal
instrumentation, keeping the shared fixtures independent of private Runtime APIs.

The later [shared-history pilot](shared-history-fixture-pilot.md) adds
`GrowthHistoryFixtureTests.swift` to the local module and `GrowthHistory.swift`
to test support. Its current source counts are 39/14/19 and its inventory harness
has 24 controls. The measurements and 426-test qualification below describe the
original partition; the pilot records its additional checks separately.

All test declarations, argument lists, assertions, controlled schedules, independent
oracles and watchdogs remain intact. Every original test filename remains valid
for mutation diagnostics and documented commands. The mutation runners and their
test cross-product remain unchanged. Public products, production source bytes,
strict memory/concurrency checks, optimization settings, deployment targets and
encoded formats retain their existing definitions.

The same Make and qualification commands still discover all test modules.
`SWIFT_STORAGE_PACKAGE_PATH` optionally selects a verified isolated source copy;
its default remains `../NVStorage`. The same package is checked by the membership
guard and built by SwiftPM. Dependency/archive checks and compiler flags retain
their existing definitions.
`--filter` selects test execution; it continues to build the package's test
targets. A test edit can now rebuild one smaller optimized module. Changes to
production modules or common fixtures can still rebuild multiple test modules.

## Membership guard

```sh
make -C tests run-storage-test-targets
python3 tools/test-storage-test-targets.py --describe
```

The fast guard runs before `run-swift-storage`. It requires every Runtime Swift
test file to appear exactly once in the literal source table, rejecting missing,
duplicate, unknown, empty and unfamiliar declarations. Its negative controls
challenge those failures and resolved-directory/dependency mistakes.

The qualification driver additionally compares the table with SwiftPM's actual
resolved targets and checks that production products have no dependency path to
test support. This independent check joins the existing content-bound evidence
group. Each original qualification command retains its original checks.

## Qualification and measurements

Local measurements: arm64 macOS 26.6.2, Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), Xcode 27, four build jobs. Raw baseline, compiler-job
timings, frozen original source and source-preservation checks are retained under
`/tmp/nv-test-target-profile.66F0Wq`.

The matched warm baseline edits change one comment in `DatabaseBoundaryTests.swift`.
This forces the real compiler path while preserving test behavior. Baseline
debug runs took 12.75/13.80 seconds; optimized runs took 128.27/134.31 seconds.
The split local-edit witness uses the same file and a stable manifest/source cut.
Each build command also lists every test; listing/fixture initialization remains
included in elapsed and CPU time.

| Build-and-list workload | Original | Split | Compiler work observed |
| --- | ---: | ---: | --- |
| Local test edit, debug | 13.27 s median | 6.83 s | Only local tests and the test runner rebuild |
| Local test edit, optimized | 131.29 s median | 40.67 s | Only local tests and the test runner rebuild |
| Recovery test edit, debug / optimized | Same original monolithic target; no separate matched sample | 8.79 / 25.17 s | Only recovery tests and the runner rebuild |
| Repository test edit, debug / optimized | Same original monolithic target; no separate matched sample | 6.86 / 27.27 s | Only repository tests and the runner rebuild |
| Shared-fixture edit, debug | 13.21 s | 5.85 s | Support and runner rebuild; all three test modules reuse |
| Shared-fixture edit, optimized | No separate matched sample | 7.30 s | Support and runner rebuild; all three test modules reuse |

The local-edit elapsed reductions are 48.51% debug and 69.02% optimized. Combined
driver/child CPU for the optimized local edit falls from 126.94/132.62 seconds
to 39.98 seconds. Its test compiler job falls from 121.78/124.99 seconds to
34.28 seconds. These are two baseline observations and one qualified split
observation, rather than a statistical performance guarantee.

Full invalidation remains a tradeoff: all three modules can repeat import/type-
checking work. One warm three-module rebuild measured approximately 191 seconds
of test-compiler CPU, versus approximately 123 seconds for a warm original
monolithic recompile. Initial compilation/caches and invalidation patterns differ;
these are separate observations, not a universal clean-build speedup claim.
Initial whole-build times also include different dependency work. The qualified
benefit is narrower recompilation after individual test or fixture edits.

The compiler recorder delegates each invocation to the installed Swift compiler,
preserving its arguments and real macro-plugin layout. Early setup failures
(sandbox access, a build command without testable imports, and plugin discovery)
remain separate from successful measurements. Compiler-path normalization also
caused one complete rebuild; it is a setup observation rather than an unchanged-
build speed claim.

One mixed-stream listing lost part of a method name when a SwiftPM warning was
inserted mid-line. Metadata qualification now captures stdout/stderr separately
and requires complete, distinct logical identities with exact argument labels.
The original debug binary and split debug/optimized binaries list the same
426 methods. Source inspection independently counts the same 426 `@Test`
declarations. The permanent harness challenges interleaving, empty discovery,
duplicate identities, omitted methods and changed parameters. Original helper
bodies and all 71 test files are compared against frozen source; 224 production,
Core fixture and probe inputs retain exact hashes. Production Core/Runtime/Probe
and Crypto compiler arguments and source inventories match in both configurations.
An actual ordinary client is denied access to package-visible fixtures at its
marked source line; the matching same-package client compiles successfully.

```sh
python3 tools/test-storage-test-targets.py --compare-inventory BEFORE.stdout.log AFTER.stdout.log
```

`benchmark-summary.json`, per-case JSON/streams and `source-preservation.json`
retain the measured inputs/results. All 22 membership-harness controls, 13 build-
reuse checks, 15 compiler-batch controls, 19 schema tests, twelve Python fixture
checkers, three Node fixture modes and two strict C diagnostic checks passed.
The application build passed using the documented Xcode 27 deployment-diagnostic
workaround; its macOS 11.5 target remains unchanged.

### Full-suite evidence

The normal Make entrypoint executed the complete split inventory with the installed
compiler in each configuration. These completed results are reused for final
qualification; documentation and index updates require no further Swift rebuild.

| Configuration | Outcome | Test execution time | Raw log |
| --- | --- | ---: | --- |
| Debug | All 426 tests passed | 1,831.325 s | `full-debug.log` |
| Optimized | All 426 tests passed | 1,454.529 s | `full-release.log` |

Both logs are under the artifact directory above. Test execution times exclude
compilation and describe the existing complete workload; they are separate from
the incremental build-and-list measurements. Existing benchmark enablement,
parameter matrices, assertions and watchdogs retain their original definitions.

### Cross-module mutation qualification

Use one existing production-source mutation per split module. Each configuration
runs a passing unmodified companion and then every selected test for each mutant,
preserving the runner's selected-test cross-product and exact assertion attribution.

| Module | Mutation | Required test | Challenged behavior |
| --- | --- | --- | --- |
| Local history | `history-wrong-prior` | `historySurvivesReorderedDeliveryAndReopen` | Deleted-note preview identifies the exact preceding saved revision across both profiles and delivery orders |
| Recovery/private state | `pending-review-fresh-birth` | `pendingCompetingReviewReusesBirthAndCommitsOnce` | A refreshed review retains its reserved note identity across both profiles |
| Repository/startup | `startup-generic-wait` | `collectionStartupLiteralHealthDecisions` | Provider unavailability alone preserves locally ready startup; exact missing input controls waiting |

```sh
python3 tools/test-storage-runtime-mutations.py --configuration debug --only history-wrong-prior --only pending-review-fresh-birth --only startup-generic-wait
python3 tools/test-storage-runtime-mutations.py --configuration release --only history-wrong-prior --only pending-review-fresh-birth --only startup-generic-wait
```

The qualifying mutant outcome is `targeted runtime failure`, with every selected
test discovered and the designated test/source line reporting its expected
assertion failure. Setup errors, timeouts and unrelated failures remain distinct
outcomes.

| Configuration | Unmodified companion | Mutation outcomes | Raw evidence directory |
| --- | --- | --- | --- |
| Debug | All three selected tests passed | All three caught as `targeted runtime failure` | `nv-runtime-mutations-89dbgvkm` |
| Optimized | All three selected tests passed | All three caught as `targeted runtime failure` | `nv-runtime-mutations-z_hdnit6` |

Both evidence directories are under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`; each contains the baseline,
per-mutant patches/logs and `results.json` with the exact source manifest, command,
mutant hashes and assertion locations. Driver logs are also retained beside the
build benchmarks as `mutations-debug-driver.log` and `mutations-release-driver.log`.

Each configuration caught the mutations at `CollectionStartupTests.swift:35`,
`NoteHistoryTests.swift:67` and `PrivateStateTests.swift:119`. The history assertion
failed for all four profile/delivery combinations, and the reserved-identity
assertion failed for both profiles. The other two selected tests passed in each
mutant run. Complete mutation setup/classifier self-checks passed in both campaigns;
the mutation definitions, selected-test cross-product and watchdogs are unchanged.

### Completion

The partition is qualified locally: complete debug/optimized execution, exact
method/argument inventories, source and production-compiler-context preservation,
shared-fixture construction boundaries, resolved target membership, targeted
cross-module mutations and the application build passed. The test/validation
index is regenerated with its completeness check. This finalization reuses the
completed full-suite runs rather than repeating their approximately 55 minutes
of test execution.

Storage semantics, encoded formats and TLA+ behavior are unchanged. This local
test-build qualification adds no new remote-platform or physical-power-loss claim.
