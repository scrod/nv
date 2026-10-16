# P6.1 — History binding and private observation qualification

Contract: [history-bound output and private observations](03-history-observation-contract.md).
This qualifies private intent preparation/retention and passive accepted-record
preservation. Actual rooted installation, accepted-receipt advancement and pending
settlement integration remain later work. Segment transport is still gated.

## Witnesses

| Witness | Observable guarantee |
| --- | --- |
| `projectionObservationsIndependentLayouts` | Independent Python bytes, strict prefix/end checks, raw absent/present-empty metadata and exact captured source |
| `projectionObservationsRejectWrongScopeAndOrdering` | Wrong collection/birth/profile, output generation order and malformed private framing rejected |
| `projectionBindingReconstructsDerivedAndRetainsWideSources` | Real equal/merge values reconstruct; 100 complete equal-source references survive a binding while their stamp is omitted |
| `projectionIntentChecksRealRetainedVariants` | Ordinary/equal/merged/automatic production history yields expected body digests; each selected envelope decodes once |
| `projectionIntentRejectsIncompatibleContext` | Changed current view, association generation, another store and encrypted provider profile cannot authorize intent retention |
| `projectionIntentPreservesAcceptedAcrossFailureAndReopen` | Failed write leaves exact SQL rows intact; accepted A survives intended B/C; stale B cannot replace C; backup/sibling repair and reopen retain descriptions |
| `projectionObservationsClassifyDamage` | Damaged occurrences, membership and sealed bytes fail history checks; unsupported private codec and malformed private record retain distinct reopen outcomes |
| `projectionObservationsRepairUnionPreservesOrRefuses` | Complement-only observations survive either primary ordering; contradictory same-birth rows refuse repair rather than disappear |
| `private-projection-*` process cases | Fresh processes, before/after-commit termination, repeated EIO/ENOSPC, exact old-or-complete-new SQL bytes, eventual successful write and unaffected pending inputs/history |

The process parent independently decodes/reassembles the row, generation,
binding, descriptor and SHA-256 output digest. Recovery receives only ordinary
selection/unlock inputs. A failed sync can leave a complete durable new record;
that ambiguous case permits the exact old or new row, never partial state or a
success acknowledgment. Before/after-commit termination retains its stricter
expected outcome. These are process termination and injected I/O faults, not
physical power-loss qualification.

## Commands

```sh
python3 tools/check-projection-observation-fixtures.py
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter "projectionObservations|projectionBinding|projectionIntent|privateCopyPreparation|repairUnion|projectionStamp"'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel --filter "projectionObservations|projectionBinding|projectionIntent|privateCopyPreparation|repairUnion|projectionStamp"'
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-private-types.py --modules NVStorage/.build/release/Modules
python3 tools/test-storage-private-process.py --binary NVStorage/.build/debug/NVStorageProbe --only projection
python3 tools/test-storage-private-process.py --binary NVStorage/.build/release/NVStorageProbe --only projection
python3 tools/test-storage-runtime-mutations.py --only p61-repair-drop-complement-observation --only p61-intent-drop-accepted --only p61-intent-stale-view --only p61-intent-stale-generation --only p61-observation-empty-is-absent --timeout 900
python3 tools/test-storage-runtime-mutations.py --configuration release --only p61-repair-drop-complement-observation --only p61-intent-drop-accepted --only p61-intent-stale-view --only p61-intent-stale-generation --only p61-observation-empty-is-absent --timeout 900
python3 tools/generate-test-index.py --self-test
python3 tools/generate-test-index.py --check
```

Use `docs/tla/check-segment-models.py --only projection-transition` with the Java
runtime and TLC jar arguments documented in the Phase 6 plan. The unchanged
finite model checks the required safety/reachability/negative controls; its
physical receipt conditions remain future concrete obligations.

## Reuse and limits

Reuse the previous stamp/descriptor fixtures and unaffected qualification in
[01](01-projection-record-validation.md) and [02](02-projection-descriptor-validation.md).
The stamp helper access change is covered by rerunning its targeted suite. The
SQL schema, existing wire hashes, cipher, codecs, root APIs, application callers
and prior mutation cross-product are unchanged. The existing private repair and
copy witnesses run again because required-group validation/repair changed.

No new native boundary or sanitizer exemption is introduced. macOS 11/Intel
physical compatibility and power-loss qualification are not claimed by these
host-free additions. Filename generation is now qualified separately in
[04](04-filename-preparation-validation.md). General encoding fallback, descriptor
placement in segments, inbound stamp applicability and live rooted receipt
settlement remain Phase 6 work.

## Execution ledger

Local host: Apple Silicon macOS 26.6.2, Swift 6.4, on 2026-10-15.

- The new eight Swift functions cover **23 cases**. The final debug run passed
  those plus the six stamp regression functions: **14 functions / 35 cases**,
  9.358 seconds. The optimized run passed **20 functions**, adding six existing
  private-copy/repair witnesses, in 32.333 seconds. The preceding debug run
  passed those private-copy/repair witnesses alongside the then-current seven
  new functions; the final run adds the complementary-observation repair test.
  Logs: `/tmp/nv-p61-observations-{debug,debug-final,release}.log`.
- All **52 private compiler probes** (23 ordinary-client, 29 same-module) passed
  in debug and optimized configurations, including the eight new constructor,
  type-substitution and mutation checks. Logs:
  `/tmp/nv-p61-observations-types-{debug,release}.log`.
- All four new child-process schedules passed in both configurations, each
  repeating its interruption/failure twice before eventual successful recovery.
  Logs: `/tmp/nv-p61-observations-process-{debug,release}.log`.
- Independent observation, descriptor and stamp fixture checks passed.
- All **five new mutations** failed at their designated runtime assertions in
  both configurations, after passing companions and required discovery. Reports
  under `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`:
  `nv-runtime-mutations-dhguhjsh/results.json` (debug) and
  `nv-runtime-mutations-fpyge1nh/results.json` (optimized). Their production,
  test, fixture and package manifests still match; the incidental root
  `.DS_Store` is outside compiled/resource inputs. The prior cross-product
  remains unchanged.
- All **11 unchanged projection-transition model scenarios** produced their
  required safety, reachability or negative-control outcomes. Report:
  `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-segment-tlc-64od_d4g`.
  The first sandboxed invocation could not open TLC's local RMI socket; the
  permitted rerun used the same model/configurations and assertions.
- `build.sh` passed with the approved deployment diagnostic workaround supplied
  through `XCODE_XCCONFIG_FILE=/tmp/nv-p61-observations-deployment.xcconfig`;
  that file contains `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR = NO`.
  The macOS 11.5 deployment target remains unchanged. Setting it only as a shell
  environment variable did not reach Xcode; the bare diagnostic remains recorded
  in `/tmp/nv-p61-observations-app-build.log`, with success in
  `/tmp/nv-p61-observations-app-build-override.log`.

The first process test incorrectly assumed that an injected SQLite sync failure
always rolls back. The corrected oracle accepts only exact old or complete new
bytes for that explicitly ambiguous outcome and still requires a failed call,
preserved other private inputs and fresh-process recovery. A corruption injector
initially hit foreign-key enforcement; it now disables that constraint only in
the test injection to reach the intended damaged-occurrence check. Neither fix
relaxes production checks. Probe/schedule discovery totals were updated for all
new cases; a zero/missing discovery remains failure.

Ubuntu arm64 / Swift 6.4 passed the combined projection suite in both
configurations: **19 functions / 54 cases**, debug 33.049 seconds and optimized
3.112 seconds. That includes the eight new functions and all earlier descriptor
and stamp functions. All 52 private compiler probes and four new process
schedules passed in both configurations. The eight source/fixture hashes below
match the VM. Logs remain on the VM under
`/tmp/nv-p61-observations-linux-{debug,release,types-debug,types-release,process-debug,process-release}.log`
and are archived locally at `/tmp/nv-p61-observations-ubuntu-logs.tar`.
The existing native workspace, SQLCipher build and compiler caches were reused;
production compiler settings and error checks were preserved. The known
SwiftPM-manifest linker warning remains distinct from the production ELF checks.
The rebuilt release probe and test binary both passed PIE, W^X, non-executable
stack and RELRO checks plus the RWX negative control; see
`/tmp/nv-p61-observations-ubuntu-elf.log`.

Exact SHA-256 inputs:

```text
ProjectionBindingV1.swift 2925bc70ef0a4631329b3e615a885ae7fd1dadfbb932267860d05880a3eeae2e
ProjectionObservationsV1.swift 8dcea30760d7446d9da790fca8c7ade720cb774b4fdd82b0d9939bde0eb01600
ProjectionObservations.swift ec45e4699658510996158c9405cc259db225470d165aa448888ac1e7064e64e5
PrivateState.swift 68b853d528ddb4b2eb6edfb0a01fbb71122a59bde3cb660ac4548b7754329844
PrivateRepair.swift c7bdf1404e4d87415e511642a3a2ab924e7b65b6dc15be009eb920d548741937
projection-observations.json b418c385b24349b5756d3b0ebe69f96f67697dae1ec102106143c058241e4d1b
ProjectionObservationTests.swift cb1020074b3c3bd4cf880adac05bd51c6dcd775db273a619b67e7714fc729106
ProjectionObservationRuntimeTests.swift 9fa5ad39ae08fa759168c80b96bf64055b078bc027dd21679f16526860544b14
```
