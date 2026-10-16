# P6.1 — Advisory stamp codec qualification

Completed: 2026-10-15. Scope: **the advisory-stamp codec slice**, within the
[Phase 6 plan](../phase6-plaintext-reconciliation-plan.md), implementing the
[stamp contract](01-projection-record-contract.md). Physical consumers remain
separate qualification gates.

## Production and evidence boundaries

`NVStorageCore/ProjectionStampV1.swift` adds an immutable bounded advisory value,
an exact-file-byte digest type and exhaustive represented-state/preparation
enums. It reuses existing ordinary, derived and automatic source references.
No schema, segment/value hashing, acceptance, actor, native file operation,
provider behavior, application UI or persistence ordering changes.

The starting commit is `b149c4c32f6842577574878e9373c71ce7f83c74`; the working
tree also contains the Phase 6 plan and index changes. The isolated mutation
report records the complete tested source inventory, including uncommitted
inputs. Preserve the [P5.7 qualification](../phase5/07-connected-qualification-validation.md)
at its recorded revision and scope. It is component evidence, not proof of a
new stamp consumer. The compiler checks retain Swift 6, strict concurrency,
strict memory safety, warnings-as-errors, exact diagnostic lines and both
ordinary-client and same-module cases.

## Test/requirement map

| Implemented check | Independent observable result / failure companion |
| --- | --- |
| `projectionStampIndependentLayouts` (four variants) | Exact frozen Python-built bytes, digest, locator table and name; reject every strict prefix and trailing bytes |
| `projectionStampExactDigestAndProfile` | Preserve BOM/line endings and Unicode byte spelling; reject bad digest widths and encrypted-profile construction/parsing/preparation |
| `projectionStampRejectsMalformedClaims` | Reject unknown magic/version/format/state, impossible counts, misaddressed references, invalid identifiers, wrong automatic birth and earlier-local references |
| `projectionStampRequiresExactDependencySet` | Reject unused/duplicate locator entries and unordered/duplicate derived inputs |
| `projectionStampBoundedCompleteOmission` (4,095/4,096/4,097 bytes) | Include the complete in-bound reference set; omit the entire oversized valid claim; reject oversized received values |
| `projectionStampRetainsDerivedReconstruction` (equal/merged) | Round-trip a real derived claim, reconstruct the independently expected body using existing history validation; missing exact history remains an error |
| Core compiler probes | Distinct semantic/file digest roles; passive stamp cannot substitute for reconstructed evidence; collection/source/digest fields remain immutable in ordinary and same-module clients |
| Four isolated `p61-stamp-*` mutations | Passing companion followed by required discovery and exact assertion failure for normalized digest, unused dependencies, oversized construction or encrypted-profile construction |

`DerivedFixture` is now shared within the Core test target, allowing the new
connected codec/reconstruction test to reuse its real history without duplicating
setup. Production issuer access remains unchanged. The normal regression driver
registers all six new functions and the independent checker; the existing mutation
cross-product and assertions are preserved.

## Reproduction

Use the pinned dependencies already required by the existing Makefile:

```sh
python3 tools/check-projection-stamp-fixtures.py
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter projectionStamp'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter NVStorageCoreTests'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel --filter NVStorageCoreTests'
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/release/Modules
python3 tools/test-storage-runtime-mutations.py --only p61-stamp-normalized-digest --only p61-stamp-unused-dependencies --only p61-stamp-overflow --only p61-stamp-encrypted-profile --timeout 900
```

Repeat the mutation command with `--configuration release` for optimized
qualification. The runner's exact-source isolated baseline and each mutant must
execute the designated tests. Timeouts/compile errors are inconclusive, not kills.

## Execution

Local host: Apple Silicon macOS 26.6.2, Apple Swift 6.4
(`swiftlang-6.4.0.34.1`). The frozen production source hashes to
`e085a7b244ad118a7c5ab0c3928dd6a27ad6581033e68170432ae293a85fc8f5`.

| Check | Executed result |
| --- | --- |
| Independent bytes | New stamp checker and reused derived-state, connected-record and current-cell checkers pass |
| Targeted debug | Six functions / twelve cases pass; `/tmp/nv-p61-stamp-debug.log` |
| Complete Core regression target | 100 functions pass in debug and optimized builds; `/tmp/nv-p61-core-debug.log`, `/tmp/nv-p61-core-release.log` |
| Core construction/access controls | 29 ordinary-client and 20 same-module checks pass in each configuration; `/tmp/nv-p61-types-debug.log`, `/tmp/nv-p61-types-release.log` |
| Debug mutations | Passing companion; all four mutants produce `targeted runtime failure` at the exact registered assertion. `nv-runtime-mutations-g5uht3gc/results.json` retains 316 source inputs and the per-mutant hashes/patches/logs |
| Optimized mutations | Passing companion and all four intended assertion failures; `nv-runtime-mutations-qjfiw73b/results.json`, `/tmp/nv-p61-stamp-mutations-release.log` |
| Ubuntu arm64 / Swift 6.4 | Independent bytes and all six functions / twelve cases pass in debug and optimized builds. All 29 ordinary-client and 20 same-module checks pass in each configuration. VM artifact `/tmp/nv-p61.HqFIQq`; local log archive `/tmp/nv-p61-ubuntu-logs.tar` |
| App build | `build.sh` reports the known Xcode 27 deployment-range diagnostic. The documented `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` invocation passes, preserving macOS 11.5 and its warning; `/tmp/nv-p61-app-build.log`, `/tmp/nv-p61-app-build-override.log` |

The two local mutation artifact directories live under the recorded host's
temporary directory, `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`.
The standard scripts reproduce these results without those retained artifacts.

Before the Ubuntu incremental run, all **176 pre-existing production/vendor
files**, `Package.swift` and `Package.resolved` matched the local sources exactly;
the only production addition was the stamp codec. Only the new source, affected
tests/fixture, checker and compiler-probe script were transferred to the existing
synthetic workspace, retaining the dependency/build cache. The older copied test
inputs were archived under the new artifact directory.

The first local compile was blocked by the filesystem sandbox's compiler-cache
access; rerunning with cache access preserved all compiler settings. Initial
development compilation also caught a missing `try` and an overly private test
fixture, both corrected before the qualified baseline. On Ubuntu, the first
compiler-probe invocation correctly stopped because `.build/debug` pointed to an
older alternate build-system output. Use the real native modules under
`.build/aarch64-unknown-linux-gnu/{debug,release}/Modules`; no diagnostic or
required-module check was relaxed. These setup failures are excluded from passes.

## Remaining dependencies and reuse limits

The subsequent [descriptor](02-projection-descriptor-validation.md) and
[history/private-observation](03-history-observation-validation.md) increments
qualify their own additions. Finish output-name/encoding preparation and portable
descriptor placement before physical writes. Then connect actual history-backed applicability,
exact installed bytes, unique association, root context and current generation
checks. Codec acceptance grants none of those permissions. Copied/foreign/stale
stamps and body/history arrival schedules remain mandatory consumer tests.
The existing derived reconstructor's enclosing-segment parameter also needs an
explicit standalone-stamp caller contract; the codec test retains a real fixture
context and does not qualify inventing a locator for future file observations.

The schema/hash inputs in `ProjectionStampSafety` correspond to these codec checks;
its association, history-arrival and safety rules remain unchanged. Existing TLC
results retain their finite scope; this increment requires no model rerun. Apple
`#S` propagation, xattr loss/copying and OS replacement behavior retain the
[Apple API ledger](../../../Apple-API-Contract-Validation.md)'s measured limits.
This slice adds no such API call, so it does not claim new platform/provider,
crash or physical-power-loss qualification.
