# Phase 4A: first general-snapshot increment

Date: 2026-10-02. Scope: the first executable slice of
[4A](phase4-startup-recovery-plan.md#4a--general-snapshot-format-construction-and-independent-verification).
The [record contract](general-snapshot-record-contract.md) defines the layouts.
This report covers the first slice. [Durable local root/page acceptance](phase4-snapshot-acceptance-validation.md)
has since connected its checks to SQLCipher. Unaccepted-history verification and
snapshot-based current-row installation remain subsequent work; neither report
closes the complete 4A/4B gates.

## Production path implemented

`LocalStoreSession.captureGeneralSnapshot()` captures an owned accepted prefix,
reads its exact operations/actions in separate database turns, and computes
neutral values plus continuation claims on the history worker. It audits indexed
membership against actual accepted envelopes. A local presentation pin or pending
host edit is separate from this neutral snapshot. Optional construction authors
no action and modifies no current rows.

`GeneralSnapshotV1.write` emits bounded data/index pages and a fixed-size root
through a caller-owned sink. The paged manifest supports arbitrarily growing
state indexes under per-object bounds. Production sealing uses the existing
public/encrypted envelopes and zstd profile. Sink output stays distinct from
SQLCipher acceptance; this increment tests the encoder with owned synthetic
object sinks rather than claiming that snapshot retention is connected already.

`GeneralSnapshotPreviewV1.read` checks exact envelope locators and selected
protection, complete iterative manifest coverage, canonical record framing/order,
counts and the independent state-stream digest. It returns full parsed values,
complete page addresses and direct history references. A missing page names its
exact locator. Unsupported versions, invalid records, bad ranges and cancellation
remain explicit outcomes.

`LocalStoreSession.verifyGeneralSnapshot` reopens the exact root under the actual
consuming key/profile, captures an owned accepted prefix and resolves every stated
operation/action occurrence. It reconstructs just the claimed causal cut, requires
complete action groups and the original complete bootstrap, and compares every
live value, represented/head/scope relationship, deletion, retirement, disposition
and restoration index with neutral reduction of that cut. Valid repackaged
occurrences can differ in locator/index while preserving semantic identity.

`VerifiedGeneralSnapshotClaims` is an issuer-confined fact about that cut and
owner/prefix. Future installation must additionally retain the root/pages, account
for other accepted branches, and enforce the existing owner/view/publication
fences. A later save preserves the validity of older claims without making them
permission to replace newer Current.

Healthy returning opens and ordinary saves keep their existing indexed paths.
The full-history audit belongs only to this explicit exceptional construction/
verification path. No persistent table, validation cache, sidecar, packed startup
cache, provider API dependency or application UI change is introduced.

## Safety and language boundaries

Core owns scalar framing and complete assembly; Runtime owns accepted-history
interpretation and physical store checks. Actual complete bytes pass between
them in checked `Sendable` values and `@Sendable` closures. The SQL connection
remains actor-owned on its existing blocking executor; synchronous transaction
ownership is unchanged. Readers yield the connection between bounded history
reads, check cancellation and perform final lifecycle/owner checks.

Preview, capture and semantic-evidence initializers are private to their issuers.
Ordinary clients and same-module sibling files challenge these exact constructors
and `Decodable` reconstruction. Separate probes reject passing a preview where
semantic evidence is required. Actual consumer tests challenge a wrong key with
the same key ID and a closed owner. Evidence issuance adds no receipt or unchecked
concurrency conformance.

## Executable scenarios

Tests reuse the real Core envelopes, SQLCipher store, save/receive/compensation
paths and opener. Fixtures have an independent Python field writer and literal
bytes; expected note bodies, deleted identities and contested transitions are
explicit. A codec round trip alone is not the semantic oracle.

| Scenario | Concrete observation |
| --- | --- |
| Empty, initial, edited, deleted, restored and undone collections, both profiles | Exact hand-expected bodies/identities and continuation records; existing retained history still verifies after ordinary reopen. |
| One-byte, 17-byte and normal data chunks; multiple index levels | Records cross page boundaries completely; root stays 228 bytes; different transport trees preserve the same stream digest. |
| Every root/page missing in turn | Exact missing locator; intact redelivery assembles successfully. |
| Validly sealed wrong digest/count/range/order/tag | Failure at the intended framing/manifest layer, after envelope validation. |
| Authentic wrong body, heads, scope, deletion, retirement, disposition, restoration or occurrence | Semantic rejection preserves Current and acceptance sequence; unrelated ordinary saving still progresses. |
| Earlier snapshot, later conflicting branch and local presentation pin | Earlier cut still verifies; later accepted/current work remains unchanged; neutral capture preserves both heads. |
| Two complete groups repackaged into one actual accepted envelope | Snapshot can represent E alone while its addressing object also contains F. Both E/F remain accepted; F is excluded from the snapshot cut, not from receiver Current. |
| Snapshot cuts through a two-note creation group | Exact authentic partial-group claim fails before evidence issuance; both new notes remain Current. |
| Conflict copy subsequently deleted | Disposition and typed retirement remain represented; original stays live and deleted output remains absent. |
| Cancellation before work or between emitted pages | Explicit cancellation, exact surviving owned page bytes, and no completed root result. |
| Later deletion of an isolated accepted leaf's operation/action index rows | Actual envelope audit detects the omitted membership; existing durable damage marker blocks subsequent editable success and survives reopen. This is simulated later index damage, not a power-loss experiment. |
| Wrong same-ID encryption key or closed owner | Actual consumer rejects incompatible protection/lifecycle evidence. |

The scope negative case first creates a real note-scoped edit and requires its
nonempty scope frontier. Initial import actions are collection-scoped; omitting
an already empty note frontier would be a vacuous negative case.

## Qualification commands and limits

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--filter generalSnapshot'
make -C tests run-swift-storage
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release'
python3 tools/check-general-snapshot-fixtures.py
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-runtime-types.py --modules NVStorage/.build/debug/Modules
make -C tests run-sqlite-schema
```

The standard `run-swift-storage-phase2` driver requires discovery of all fourteen
new test functions and verifies the independent general-snapshot fixture alongside
the existing fixtures. It preserves the existing fresh-process tests; those
exercise ordinary history recovery, not a new general-snapshot installer.

The existing isolated mutation runner adds nine production challenges: skip
semantic comparison; ignore body/head/scope; allow partial groups; misaddress an
operation as a bootstrap root; skip actual consumer protection; skip stream
digest; omit the accepted-envelope membership audit. Each names its intended
Swift Testing assertion and requires baseline discovery. Select them with
repeated `--only general-snapshot-…` arguments to
`tools/test-storage-runtime-mutations.py`. Qualification records pin the actual
source hashes and isolated binaries; compiler/setup failure receives no credit.

```sh
python3 tools/test-storage-runtime-mutations.py \
  --only general-snapshot-omitted-membership-audit \
  --only general-snapshot-unchecked-state \
  --only general-snapshot-wrong-body \
  --only general-snapshot-omitted-head \
  --only general-snapshot-omitted-scope \
  --only general-snapshot-partial-group \
  --only general-snapshot-bootstrap-occurrence \
  --only general-snapshot-profile-consumer \
  --only general-snapshot-digest
```

The implementation retains Swift 6 checking and strict memory-safety
warnings-as-errors; runtime constructor probes require 96 actual checked cases,
including the eight new ordinary/sibling snapshot cases.

## Executed results

Qualification platform: arm64 macOS 26.6.2, Apple Swift 6.4, macOS 27 SDK;
the existing private SQLCipher build and both provider protection profiles.

| Check | Result |
| --- | --- |
| Full debug suite | 177 test functions passed in 222.787 seconds; `/tmp/nv-phase4-debug-final.log`. |
| Full optimized suite | The same 177 functions passed in 79.770 seconds; `/tmp/nv-phase4-release-final.log`. Ordinary current-state saves retain the zero-ancestor-traversal checks. |
| Focused final snapshot suite | All 14 functions passed in 19.358 seconds; `/tmp/nv-phase4-snapshot-final.log`. Parameterized cases exercise both profiles and multiple malformed claims. |
| Independent snapshot field writer | Literal root, data/index pages, all seven record classes, counts and digest matched the Swift fixture. |
| Core constructor/client probes | Debug/optimized module clients and same-module sibling probes passed, including complete-preview construction and `Decodable` boundaries; `/tmp/nv-phase4-core-types-release.log` records the optimized-module run. |
| Runtime constructor/client probes | All 96 checks passed against both debug and optimized modules, including snapshot capture/semantic evidence, actual actor isolation and C-handle lifetime checks; `/tmp/nv-phase4-runtime-types-final.log` and `/tmp/nv-phase4-runtime-types-release.log`. |
| Isolated mutation campaign | All nine removed safeguards produced the designated runtime assertion failure after a passing 53-function baseline, with required discovery and precise source-line attribution; `/tmp/nv-phase4-mutations-final.log`. |
| Schema regression suite | All 17 checks passed; no schema changes accompany this increment. |
| App build | `build.sh` encountered Xcode 27's deployment-target diagnostic. The identical unsigned build with `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` passed with the existing macOS 11.5 target; `/tmp/nv-phase4-app-build.log`. |

The final mutation record is
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-runtime-mutations-x9mcme_s/results.json`.
It preserves the executed source hashes, patches and assertion locations. Runtime
and test sources match that isolated baseline; the subsequent Core source changes
only clarify the preview's complete page set versus direct history references in
comments. Full debug/optimized suites and client probes exercised the current tree.

This slice has no new Intel, macOS 11 or Linux qualification,
snapshot-installer child-process test, sanitizer campaign or physical power-loss
result. Existing ordinary reopening tests do not qualify snapshot-tail recovery.

## Model correspondence and remaining integration

The immutable-segment and SQLite models continue to assume complete, validated
accepted history and guarded derived-state publication. These codecs/verifiers
make part of that concrete boundary executable, including checking index
completeness against accepted envelopes. The increment changes no modeled action,
delete/copy/undo policy, SQL transaction ordering or publication condition; TLA+
safety assertions remain intact. No model rerun or new end-to-end refinement is
claimed from byte/consumer tests.

Complete local root/page acceptance and pin coverage now have an
[implementation/qualification report](phase4-snapshot-acceptance-validation.md).
Next add intake/wakeups for received candidate roots/pages and exact history
dependencies. Then implement guarded snapshot-plus-other-history rebuild
with fresh-process crash tests, following the
[durable snapshot acceptance/recovery plan](phase4-snapshot-acceptance-recovery-plan.md).
Full unaccepted bootstrap validation, long-history
work qualification, physical power loss, backup/salvage/activation, required
private-record codecs and live-provider/application adapters remain separate
planned gates.
