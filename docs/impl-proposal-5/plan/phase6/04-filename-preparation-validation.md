# P6.1 — Filename preparation qualification

Contract: [captured filename preparation](04-filename-preparation-contract.md).
This ledger qualifies the pure name helper and its existing private intention
consumer. Actual file creation/replacement and encoding selection remain separate.

## Witnesses

| Test | Independent observation |
| --- | --- |
| `projectionFilenameIndependentCases` | Fourteen literal expected names: sanitizing, extension retention/change, cross-format/disk collisions, numeric suffixes, case-only rename, Unicode, extensionless and reserved output |
| `projectionFilenameUTF16Budget` | Below/at/above the title budget, safe surrogate cut and legacy combining-text cut |
| `projectionFilenameRejectsAmbiguousInventory` | Exact duplicate, case alias and normalization alias remain ambiguous even for the current leaf |
| `projectionFilenameRejectsUnsafeInputs` | Empty/NUL title, unsafe settings and extension limits reject explicitly |
| `projectionFilenameUsesCapturedInventory` | 64/256/1,024 collisions produce the independently calculated next suffix; repeated preparation uses the same immutable capture |
| `projectionIntentRetainsSelectedFilename` | Production preparation/commit/reopen retains `Title.1.txt`, exact body digest and unchanged current value |

Five Core functions plus one Runtime function cover **25 cases**. The independent
fixture checker compares every literal row; Swift reads those same fixtures.
The new ordinary-client and same-module negative probes reject substitution of
an inventory for a selected leaf and access to the policy's private current name.
They run with the existing positive client and precise diagnostic checks.

```sh
python3 tools/check-projection-filename-fixtures.py
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter "projectionFilename|projectionIntentRetainsSelectedFilename"'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel --filter "projectionFilename|projectionIntentRetainsSelectedFilename"'
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/release/Modules
python3 tools/test-storage-runtime-mutations.py --only p61-filename-ignore-occupancy --only p61-filename-allow-aliases --only p61-filename-split-surrogate --only p61-filename-forget-extension --timeout 1200
python3 tools/test-storage-runtime-mutations.py --configuration release --only p61-filename-ignore-occupancy --only p61-filename-allow-aliases --only p61-filename-split-surrogate --only p61-filename-forget-extension --timeout 1200
```

On Linux use its actual `aarch64-unknown-linux-gnu/{debug,release}/Modules`
directories. The existing Makefile retains that platform's link hardening and
production compiler settings. These functions are also required discoveries in
`tools/test-storage-phase2.py`; the mutation cross-product is unchanged.

## Executed results — 2026-10-15

- macOS 26.6.2 arm64 / Swift 6.4: six functions / 25 cases passed in debug
  (0.576 seconds) and optimized (0.247 seconds) runs. All **61 Core compiler
  probes**, 35 ordinary-client and 26 same-module, passed in both configurations.
  Logs: `/tmp/nv-p61-filename-{debug-final,release,types-debug,types-release}.log`.
- Ubuntu arm64 / Swift 6.4: the same six functions / 25 cases passed in debug
  (0.064 seconds) and optimized (0.030 seconds) runs; all 61 compiler probes
  passed in both. Logs on the VM:
  `/tmp/nv-p61-filename-linux-{debug,release,types-debug,types-release}.log`.
- All four mutations reached the designated runtime assertions in both modes,
  after passing companions and complete discovery. Artifact parent:
  `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`. The first three results
  are in `nv-runtime-mutations-xkbwu8xi` (debug) and
  `nv-runtime-mutations-_kvlt0p3` (optimized). The corrected extension mutation
  is in `nv-runtime-mutations-mwmwq5u4` and `nv-runtime-mutations-9bvfdai2`.
  Initially removing the extension assignment made `var ext` immutable and
  failed warnings-as-errors. Those two setup failures are **excluded** from
  qualification. The corrected mutant assigns the selected extension, keeping
  the compiler checks intact and failing the expected retained-extension value.
- All four mutation artifact source manifests match the current 328 package
  inputs, excluding incidental `.DS_Store`. The application build passed with
  the already approved `XCODE_XCCONFIG_FILE=/tmp/nv-p61-observations-deployment.xcconfig`
  workaround; log `/tmp/nv-p61-filename-app-build.log`. No application caller or
  deployment target changed.

Exact SHA-256 inputs:

```text
ProjectionFilenameV1.swift 46afa3af6d955e27174673c09e4a640775ca53c5691a6beb204177d841c21aa7
ProjectionFilenameTests.swift 12a3d35bf280e7482c937422bfe25a9c0e68753739634831789d9f8b47e0e18e
projection-filename.json 9d2f74355aac8f67157925e5d6a3607832cd53bad82bff77feda724eecbad55e
ProjectionObservationRuntimeTests.swift 477395d99a5d8df9a7612796f6b0a46549482f6cd3f5c7d2641acbfc561b4dbe
```

## Reuse boundaries

Reuse the unchanged descriptor/stamp, private crash/I/O/repair and model outcomes
in ledgers [01](01-projection-record-validation.md),
[02](02-projection-descriptor-validation.md) and
[03](03-history-observation-validation.md). This addition changes no SQL schema,
existing encoded layout, history reducer, transaction boundary or native API.
The Runtime test file adds one function; earlier function bodies remain unchanged.
The existing compiler suite reruns because its probe inputs changed.
Intel Runtime qualification and physical installation remain unclaimed here.
The separate [encoding experiment](05-text-encoding-investigation.md) is not
qualification of general text encoding or cross-platform reconstruction.
