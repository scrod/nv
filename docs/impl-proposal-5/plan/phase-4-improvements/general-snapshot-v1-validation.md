# Single current general-snapshot v1: format correction and validation

Date: 2026-10-13. This report records the correction of an unreleased format,
separately from the earlier [retention qualification](snapshot-retention-coverage-validation.md).
The [record contract](../general-snapshot-record-contract.md) defines current bytes.

## Implementation

General snapshots have one encoding: v1 roots and streams, eight category counts,
a 236-byte root, and the `NV general snapshot state\0v1\0` digest domain.
Retention-parent locators occupy canonical tag 8 manifest records. An empty set
uses a zero eighth count in that same layout. Page and initial-bootstrap layouts,
accepted-parent verification, atomic dependency/frontier updates, byte retention
and outside-cut recovery keep their established behavior.

The codec's version selector, root encoding property, writer/constructor encoding
parameters, seven-count decoding and alternate digest-domain branch are removed.
Runtime public methods retain their existing shapes. Independent Python fixtures
and the Node history/SQL inspector now require the same single layout. Fixture
names distinguish empty and populated parent sets rather than wire variants.

Core tests preserve both parent-set cases and all cross-page/profile combinations.
They require rejection of unsupported root/stream/reducer versions, the incomplete
seven-count shape, duplicate/reordered parents, incorrect counts and truncated
locators. Authentically sealed malformed streams reach the intended inner check.
The Runtime wide-fan-in case combines a general root with no parents and roots
covering the initial bootstrap, then verifies complete retained closure and one
joined frontier. Existing malformed-root helpers retain all eight counts while
altering the specific digest or dependency being challenged.

## Compatibility and documentation

The last public release was in 2011 and used epoch-4 Notes & Settings. No epoch-5,
segment, NVStorage or private SQLite format has shipped. Superseded development
bytes acquire neither a compatibility decoder nor a migration obligation.
Epoch-4 opening, journal recovery and explicit legacy export remain required.
Unsupported development input retains the existing explicit failure/preservation
behavior; this correction adds no destructive conversion.

AGENTS, the normative spec, glossary, ADRs, LocalStore/format contracts, roadmap,
conformance strategy and object/scenario maps state this boundary consistently.
The library proposal's “v2” remains a document edition. Earlier validation counts
and platform timings are identified as evidence for their tested revision, rather
than relabeled as fresh qualification of the corrected bytes.

## Executed checks

Local host: arm64 macOS 26.6.2, Swift 6.4, the pinned SQLCipher build and existing strict
Swift concurrency/memory-safety settings. Both provider profiles are exercised.

| Check | Current result |
| --- | --- |
| Independent general-snapshot fixture checker | Pass; exact empty/populated parent roots, pages, counts and digest bytes |
| Debug affected Swift suite | Reports 40 tests passed; opt-in retention benchmark skipped; 553.142 seconds |
| Optimized affected Swift suite | Reports 40 tests passed; opt-in retention benchmark skipped; 370.989 seconds |
| Fresh-process snapshot acceptance | All 22 crash/I/O schedules pass with three preceding covering roots |
| Delayed-parent delivery | All six parent/commit/restart schedules pass |
| Received-snapshot process schedules | All 40 schedules pass, including retention, parking, rejection and ambiguous commits |
| Bootstrap and reconstruction processes | All 26 S3/S4 schedules pass, including snapshot-plus-tail reconstruction, a second recovery failure and continued authoring |
| Core construction/consumer probes | Complete ordinary-client and same-module campaign passes, including restricted snapshot-preview issuance and decoding |
| Runtime snapshot construction/consumer probes | All eight snapshot checks and the public-client companion pass in both ordinary-client and same-module modes; the broader campaign later hits its unchanged 60-second compiler watchdog |
| Targeted mutation controls | Valid baseline passes; all seven existing controls produce the required targeted runtime failure with complete selected discovery |
| Retention TLA+ checks | All 17 expected outcomes pass: four exhaustive safe cases, six designated mutations and seven reachability witnesses |
| Private schema contracts | All 19 tests pass; this change adds no schema revision |
| Legacy compatibility | Epoch-4 archive export/readability smoke and WAL recovery workflows pass |
| Application build | Integration build and build.sh pass using the documented deployment diagnostic workaround; target remains 11.5 |

The first incremental build reused an obsolete probe object referring to the
removed Core API. A fresh scratch build resolved that build-artifact issue; no
source compatibility shim was added. The first sandboxed TLC attempt failed to
open its local monitoring socket. The unchanged run outside that sandbox completed
all 17 checks. Neither setup failure is counted as a passing semantic check.

The broader Runtime construction campaign timed out in a later probe while two
optimized test-target compilations were active. Its completed snapshot checks
retain their exact marked-line/error/companion observations; the whole Runtime
campaign is **inconclusive**, not a pass. The watchdog and compiler requirements
are unchanged. Unrelated probes are not rerun as part of this codec correction.

TLA+ models abstract supported roots and protected byte closure, rather than wire
version numbers. Their actions, safety conditions and configurations are unchanged.
The unsupported-parent scenario continues to represent unknown future input.

## Reproduction and artifacts

```sh
python3 tools/check-general-snapshot-fixtures.py
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--scratch-path /tmp/nv-snapshot-single-v1.a73UAU --no-parallel --filter generalSnapshot --filter snapshotRetention --filter receivedSnapshot --filter snapshotAcceptance'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--scratch-path /tmp/nv-snapshot-single-v1.a73UAU --configuration release --no-parallel --filter generalSnapshot --filter snapshotRetention --filter receivedSnapshot --filter snapshotAcceptance'
python3 tools/test-storage-snapshot-process.py --binary /tmp/nv-snapshot-single-v1.a73UAU/debug/NVStorageProbe --retention-prefix 3
python3 tools/test-storage-retention-delivery.py --binary /tmp/nv-snapshot-single-v1.a73UAU/debug/NVStorageProbe
python3 tools/test-storage-received-snapshot-process.py --binary /tmp/nv-snapshot-single-v1.a73UAU/debug/NVStorageProbe
python3 tools/test-storage-bootstrap-reconstruction-process.py --binary /tmp/nv-snapshot-single-v1.a73UAU/debug/NVStorageProbe
python3 tools/test-swift-storage-types.py --modules /tmp/nv-snapshot-single-v1.a73UAU/debug/Modules
python3 tools/test-storage-runtime-types.py --modules /tmp/nv-snapshot-single-v1.a73UAU/debug/Modules
python3 tools/test-storage-runtime-mutations.py --configuration release --jobs 2 --timeout 1200 --only retention-unverified-kind --only retention-clears-independent-tips --only retention-omitted-dependency --only retention-premature-receipt --only retention-skipped-consumer-check --only general-snapshot-digest --only general-snapshot-profile-consumer
```

The optimized probe supports the same process commands by substituting
`release/NVStorageProbe`. Mutation combinations, assertions, positive companions
and nonzero-discovery checks are preserved.

Logs use `/tmp/nv-snapshot-single-v1-*.log`; the fresh build is
`/tmp/nv-snapshot-single-v1.a73UAU`. Retention model artifacts are
`nv-improvements-tla-*` under the host temporary directory; the successful run is
identified by `/tmp/nv-snapshot-single-v1-tla.log`. The successful model directory
is `nv-improvements-tla-zhllpqmx`. The model command remains
`python3 docs/tla/check-improvement-models.py --only retention --java <java>
--jar <tla2tools.jar> --timeout 600`.
The temporary checker is TLA+ 1.7.4 / TLC 2.19; its JAR SHA-256 is
`936a262061c914694dfd669a543be24573c45d5aa0ff20a8b96b23d01e050e88`.

This is affected-path qualification, not a rerun of every project test. Remote
platforms and physical power-loss behavior are not requalified by these local
checks. Earlier complete platform campaigns remain tied to their original bytes.

The [fast-loop guidance](../qualification-build-reuse.md#editbuildtest-loop)
separates focused incremental debug checks from full qualification. This correction
retains the existing mutation combinations and watchdogs. Current logs include
`/tmp/nv-snapshot-single-v1-debug.log`, `/tmp/nv-snapshot-single-v1-release.log`,
the four `*-debug.log` process-driver logs, and
`/tmp/nv-snapshot-single-v1-mutations.log`. The mutation report is
`nv-runtime-mutations-ig9rf24f/results.json` under the host temporary directory.
