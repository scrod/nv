# Compiler-boundary probe batching

## Scope and contract

Core, Runtime, private-state and root clients share bounded compilation of
compatible negative probes. Every original case, expected diagnostic alternative,
marked source line, positive companion and final case-count check remains present.
The default batch size is eight; `--batch-size 1` runs the original isolated
source form. Values from one through sixteen permit measured comparisons.

Each client remains a distinct Swift source file. Simple top-level test functions
and their unqualified calls receive unique helper names, keeping their lexical
scope and access level. Imports, production identifiers, member references,
literal values, comments and source-line numbering retain their values. File-level
state, interpolation and richer
declaration contexts use isolated checking. Actual Core/Runtime source files keep
their file boundaries and module/package context.

Shared negative compilation uses whole-module **type checking** to visit all
selected source files in one frontend job. Swift language mode, strict concurrency,
strict memory safety, warnings-as-errors and SDK settings remain enforced. Positive
companions retain their original compilation command. Production builds and
optimization settings are unchanged.

A successful negative batch requires a matching error at each exact marked
file/line. Driver errors, crashes, unrelated source locations, successful
compilation or a missing expected diagnostic cannot stand in for a restriction.
An incomplete batch is rechecked one original client at a time, including those
whose batch diagnostics were present. A restriction that has disappeared then
fails independently. Each case prints its existing PASS observation only after
its contract is satisfied; a family also reports its probe count, compiler
invocations, fallback batches and elapsed time.

Positive companions, Runtime SIL/concurrency checks, modified production-source
copies, actual-file private issuance checks and exhaustive-routing challenges
retain isolated compilation. The per-invocation watchdogs remain 60 seconds for
Core/Runtime, 120 for private-state and 90 for root probes. Full case counts and
the mutation runners' test cross-product are unchanged.

## Harness qualification

```sh
make -C tests run-compiler-probe-batches
python3 tools/test-storage-runtime-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-root-types.py --modules NVStorage/.build/debug/Modules
```

The harness tests bounded batches, isolated positive companions, exact locations
and diagnostic alternatives, suppressed errors, original-source fallback, a
client that unexpectedly compiles, unrelated failures, signals, timeouts, required
discovery and helper-name hygiene. A small real Swift module exercises ordinary
and sibling clients against both private and file-private initializers. Weakening
one issuer must fail while the other still emits its intended restriction error.
The aggregate qualification driver includes this configuration-independent
harness check in its content-bound independent evidence group, whose tool
fingerprint now also includes Swift's executable.

## Measurements and results

Local host: arm64 macOS 26.6.2, Apple Swift 6.4
(`swiftlang-6.4.0.34.1`), Xcode 27. Existing production debug/release modules are
under `/tmp/nv-snapshot-single-v1.a73UAU`; the library sources and binaries were
unchanged. Original drivers are from revision
`6cbae6ae4be60a9aa704f31cbfc319385a6ddad1`.

| Complete debug campaign | Original | Batch size 8 | Observations |
| --- | ---: | ---: | --- |
| Runtime | 1,401.85 s | 411.81 s | Identical 142 client checks plus one diagnostic-classifier check |
| Core | 31.17 s | 6.26 s | Identical 39 client checks plus one diagnostic-classifier check |

Runtime elapsed time fell 70.62%, from 23m 22s to 6m 52s; combined child/driver
user+system CPU time fell from 1,285.15 to 370.87 seconds (71.14%). Compiler
invocations fell from 142 to 50: 22 shared-runner invocations and 28 unchanged
isolated checks. No batch needed fallback. The before/after Runtime PASS-line
multisets match exactly, as do the original/Core comparisons for all three sizes.

Core's batch-size experiment retained all 39 clients and the classifier:

| Batch size | Compiler invocations | Elapsed |
| --- | ---: | ---: |
| 1, original driver | 39 | 31.17 s |
| 4 | 12 | 9.95 s |
| 8 | 7 | 6.26 s |
| 16 | 5 | 4.14 s |

Eight remains the common default qualified across all four families. Sixteen's
Core result supports an explicit larger Core batch; it is not evidence for every
family's larger diagnostic/resource budget. These are single complete campaign
observations with a shared compiler-managed import cache, rather than medians,
cold-build measurements or guarantees of a fixed speedup. The original full
Runtime campaign ran while the helper was developed; small harness/index checks
also ran during that interval. Cumulative CPU reduction and exact case equality
are recorded alongside wall time, rather than attributing the result to parallel
execution. Compilation remains serial between batches.

| Qualification | Result |
| --- | --- |
| Core, Runtime, private-state and root, debug and optimized modules | All pass: 326 client checks and two classifier checks per configuration |
| Debug/optimized PASS observations | Exact per-driver multiset equality: 40 / 143 / 29 / 116 |
| Harness tests | All 15 pass, including actual Swift private/file-private boundaries, weakened issuer, suppressed diagnostics, zero/duplicate discovery and original-source fallback |
| Focused harness command | Individual indexed unittest selection passes and retains nonzero discovery |
| Qualification-cache harness | All 13 checks pass |
| Index generator | Data-only batch-mode tracing self-test passes; every previously indexed compiler-case name remains present, with Core's modes now explicitly expanded |
| Production sources and mutation runners | Unchanged; no mutation cross-product adjustment |
| Application build | Pass using the documented deployment diagnostic workaround; target remains macOS 11.5 |

The conservative file-level-state eligibility guard preserves the generated text
for all 136 unique current probe-source forms collected by the data-only reader.
It narrows future batching without changing this campaign's client inputs.
Compiler/watchdog limits are unchanged. The initial sandboxed attempt could not
start Swift's macro plugin and is a setup failure, not baseline qualification;
real production-source probes ran outside that sandbox. Remote VM keys are
unavailable in this session, so remote execution is not newly qualified.

Artifact directory: `/tmp/nv-compiler-probe-batching.9kw8CP`. Full raw logs use
`before-test-storage-runtime-types.log`, `before-test-swift-storage-types.log`,
`after-<driver>-debug.log`, `after-<driver>-release.log` and `core-size-4/8/16.log`.
`harness-final.log`, `reuse-tests.log`, `application-build.log` and the index logs
record the supporting checks. `results.json` records metrics and source hashes.

For a repeat comparison, run an original driver from the recorded revision or
select `--batch-size 1`, then run the same client family at the selected size.
Use the same built modules, compiler/SDK and import cache, and compare complete
case inventories as well as `/usr/bin/time -lp` results. An explicit
`NV_STORAGE_QUALIFICATION_REUSE` directory shares import caches; source checking
still executes on every run.

This is a test-runner refactor. Storage protocols, encoded bytes, modeled actions
and TLA+ safety assertions retain their established behavior.
