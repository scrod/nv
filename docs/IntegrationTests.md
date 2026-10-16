## Integration tests

The [project-wide test and validation index](Test-and-Validation-Index.md)
catalogues individual checks, commands and their defining/using plans across all
phases, including formal, compiler, mutation and future integration requirements.

Run test commands from the repository root. The test Makefile builds the Deployment app objects without code signing, links standalone test executables into `/tmp/notation-integration-tests`, and then runs them. A successful test is silent or exits with status 0; many deliberately injected failure cases write expected diagnostics to stderr.

The application build is checked once per Make invocation. Content manifests
cover the actual object inventory, headers, framework, compiler and link inputs;
unchanged standalone executables are reused. Changed or damaged inputs and
executables cause a real relink, including changes within the same second on
macOS's bundled Make. Application-build and link failures still stop the tests.
`make -C tests run-qualification-reuse` exercises these rules through the actual
Makefile using synthetic build tools, plus the qualification-cache failure cases.

`make -C tests run-compiler-probe-batches` checks the compiler-client batching
harness, including a real Swift access-control challenge. Core, Runtime,
private-state and root type drivers batch compatible negative clients while
checking every exact diagnostic independently; `--batch-size 1` selects isolated
clients for comparison. Positive companions and source-modifying/SIL probes keep
their existing isolated checks. See the [contract and measurements](impl-proposal-5/plan/compiler-probe-batching.md).

Runtime Swift tests compile in cohesive local/receive, recovery and repository
modules, preserving their existing source paths and test filters. Shared fixtures
live in a test-only, package-visible target. `run-swift-storage` first runs
`run-storage-test-targets` to check that all Runtime test files are selected
exactly once; full qualification also checks SwiftPM-resolved membership. See the
[build-performance contract and measurements](impl-proposal-5/plan/test-target-build-performance.md).

The [shared growth-history pilot](impl-proposal-5/plan/shared-history-fixture-pilot.md)
reuses checked source/receiver prefixes for the snapshot-growth and discovery-
growth tests. Each consumer owns a fresh physical copy, and discovery still
receives every file into its own destination. Both profiles, all sizes and
original assertions remain active. When combining Swift filters in
`SWIFT_STORAGE_TEST_FLAGS`, escape regex alternation as `\|` so Make's shell
passes it to SwiftPM.

`NVIntegrationTest` replaces the app's `NVRootedDirectory.o` with a test-instrumented build of the same source and links `tests/NVRootedDirectoryTestHooks.m`. The production target does not compile the hook category, injected race callbacks, or descriptor-invalidating test seam.

### Common commands

The [P5.4 plan](impl-proposal-5/plan/phase5/04-apple-coordination-and-discovery.md)
and [qualification ledger](impl-proposal-5/plan/phase5/04-apple-coordination-and-discovery-validation.md)
cover the actual Foundation adapter and automatic immutable transport. After
building the storage package, run `make -C tests run-swift-storage-apple-peer`
for independent coordinated write/move and presenter callbacks;
`make -C tests run-swift-storage-apple-stage` for actual grants, native static
analysis and ASan/UBSan; and `make -C tests run-swift-storage-transport-local`
for signed LaunchServices drivers, independent stores and fresh-process recovery.
The local driver companion explicitly copies immutable files between separate
roots; it does not claim provider delivery. `RepositoryCoordinationTests`,
`RepositoryAvailabilityTests` and `RepositoryTransportTests` select deterministic
production-path holds, stale issuers, bounded retries and automatic wakeups.

`make -C tests run-swift-storage
SWIFT_STORAGE_TEST_FLAGS='--filter repositoryDriverCoalescesHintStormAcrossNestedPass --no-parallel'`
holds the real discovery observation through 256 consumed hints, then checks
coalesced passes, bounded listing resources, single accepted-body reads,
rejection isolation and reopening for both profiles. Run
`python3 tools/test-storage-runtime-mutations.py --only driver-lost-coalesced-followup
--only driver-repeated-accepted-bodies --disable-sandbox` for its passing companion
and exact-assertion mutation controls. The controlled storm removes only its own
presenter; the independent peer command above retains actual OS callback coverage.

`make -C tests run-swift-storage
SWIFT_STORAGE_TEST_FLAGS='--filter repositoryCoordination --no-parallel'`
also checks 21 coordinator error cases: documented Cocoa/POSIX diagnoses,
missing/unknown errors, numeric bounds and malformed supplemental dictionaries.
`python3 tools/test-storage-runtime-mutations.py --only coordination-error-domain
--disable-sandbox` requires a passing companion and the exact classification
assertion to fail when domain checking is removed. These injected error values
qualify the mapper; cancellation and held-accessor companions exercise actual
Foundation execution separately.

`python3 tools/test-storage-root-volumes.py --binary
NVStorage/.build/release/NVStorageProbe` checks actual Foundation root access,
same-object moves, replacement preservation and forced detach/remount on owned
APFS/APFSX/HFS+/HFSX/ExFAT images. Add `--filesystem APFS --deep-root` to require
deep coordinated reads and remounted acquisition; repeat separately for HFS+.
The approved HFS+ fresh-deep-open limitation accepts only an exact `ESTALE`
acquisition refusal with unchanged identity/bytes/namespace and released ownership;
the report labels it `LIMITATION`, separately from successful fresh opening.
Ordinary HFS+ access, already-owned deep coordinated reads and APFS fresh deep
opening retain strict success assertions. `--check-outcomes` runs 13 host-free
classification controls. Short-path/native-only passes cannot replace the
applicable deep-path witnesses.
`test-storage-apple-stage.py --repository-parent /absolute/owned/HFS/mount
--sanitize address,undefined --mutations` adds a passing real install companion
and requires an unverified selected-path mutation to fail at the actual root
binding before any write. Preserve these disposable image/fixture artifacts.

The optional live command is `python3 tools/test-storage-apple-transport.py
--local-binary NVStorage/.build/debug/NVStorageProbe --remote-binary
/absolute/path/to/Intel/NVStorageProbe --ssh-target scrod@scrodmini.local
--ssh-key /tmp/scrodmini_ed25519 --repository-parent '/Users/scrod/Library/Mobile
Documents/com~apple~CloudDocs/API_Contract_Testing' --timeout 300`.
It creates fresh P54-* fixtures and transfers only harness/control inputs over
SSH; iCloud supplies live segment delivery. Answer macOS access prompts for the
dedicated `net.notational.velocity.storage-contract` bundle. These opt-in tests
preserve failed fixtures and separately classify authorization, undisclosed
provider input, malformed bytes and Runtime failure. A watchdog does not prove
that an entered system call returned. Release signing and physical power loss
remain separate qualification boundaries.

The [P5.5 startup/reassociation ledger](impl-proposal-5/plan/phase5/05-startup-and-root-reassociation-validation.md)
adds the integrated `CollectionSession`/selected bootstrap consumers. Filter
`collection` for their Swift tests. `tools/test-storage-startup-process.py
--binary /absolute/path/NVStorageProbe` runs 18 fresh-process association/crash/
bootstrap schedules; the common storage driver includes them. For remote Macs,
`tools/test-storage-startup-remote.py --binary /tmp/qualified/NVStorageProbe
--ssh-target scrod@scrodmini.local --ssh-key /tmp/scrodmini_ed25519` runs the same
production children while independently decoding their inspected history locally.
The remote opener receives normal selection/unlock and surviving resources only.
`tools/test-storage-apple-startup.py` accepts the same local/remote binary, SSH
and authorized repository-parent options as the P5.4 live command. It exercises
signed integrated creation, read-only bootstrap, editing/Delete, exact named
disclosure, Retry, older-root Re-open and fresh exec under both profiles.
Eviction requests and positively observed startup waits are reported separately.
Each controller restart has a fresh FIFO/configuration/trace; fixtures survive
failure. Application UI, repair effects and release packaging remain later gates.

`tools/test-storage-phase2.py --suite-timeout 7200
--compiler-suite-timeout 3600` gives the complete Swift and compiler campaigns
explicit resource budgets. Each individual test/probe keeps its own watchdog and
diagnostic/assertion checks. The 40-schedule received-snapshot process campaign has
a separate 3,600-second aggregate budget with unchanged 120-second child watchdogs.
An aggregate timeout is incomplete qualification; report independently completed
component reruns separately rather than relabeling the timed-out wrapper as passed.

The [phase-3 schedule and observation matrix](impl-proposal-5/plan/phase3-schedule-observation-matrix.md)
tracks connected semantic qualification for editable merges, deletion/preservation,
source choices/copies, historical recovery and portable compensation. It specifies
expected states and race/failure witnesses; the [connected qualification report](impl-proposal-5/plan/phase3-validation.md)
records executed dimensions and remaining platform/application boundaries.
The [derived-state subrecord checks](impl-proposal-5/plan/phase3-derived-state-validation.md)
add canonical equal/merge bytes and exact dependency reconstruction to the package
suite and qualification driver. Their runtime consumers now preserve those inputs
through authoring, acceptance, current-row installation and fresh editable reopen.

The [first Phase 4A snapshot checks](impl-proposal-5/plan/phase4-general-snapshot-validation.md)
add independently specified root/page bytes, bounded manifest assembly and
verification of real post-edit history cuts. `SWIFT_STORAGE_TEST_FLAGS='--filter
generalSnapshot'` selects these cases. The [S3/S4 checks](impl-proposal-5/plan/phase4-bootstrap-reconstruction-validation.md)
add resumable complete bootstrap and real snapshot-plus-all-branches
reconstruction. The common storage driver includes their 26 fresh-process
fault schedules. `NV_STORAGE_RESOURCE_CAMPAIGN=1` with
`SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter measuredBootstrapResourceCampaign'`
runs the opt-in 64/256/1,024/2,048-note resource campaign for both profiles.

- `make -C tests` builds the six default standalone executables without running them. Opt-in probes such as `NativeUndoProbe` and `FSEventsHistoryProbe` use their separately named Make targets.
- `make -C tests run-core` runs the headless/default integration suite.
- `make -C tests run-swift-storage` runs the standalone Swift package's Core and local SQLCipher Runtime tests without building NV. First run `bash tools/build-storage-deps.sh` from the repository root; SwiftPM resolves the pinned Swift Crypto dependency. `SWIFT_STORAGE_TEST_FLAGS` selects an optimized/sanitized build. `make -C tests run-swift-storage-phase2` additionally verifies fresh-process recovery, independent envelopes/fixtures, schema equality, C diagnostics and ordinary/same-module compiler boundaries. It includes the [Phase 3 connected checks](impl-proposal-5/plan/phase3-validation.md): independent stores exchanging real bytes, editable multi-head Current, exact source-entry exclusion, conflict-copy dispositions, actual compensation inverses and failure/restart schedules. Set `SWIFT_STORAGE_PHASE2_FLAGS='--configuration release --mutations'` for the optimized isolated challenge campaigns. The [Phase 2 report](impl-proposal-5/plan/phase2-local-runtime-validation.md) records underlying acceptance/fault coverage. These use synthetic private stores, not real user collections or providers. The test runner's availability is separate from the library's declared macOS 11.5 deployment target.

Use `python3 tools/test-storage-phase2.py --configuration both` for complete
debug/release qualification with campaign-scoped reuse. Both Swift suites,
compiler probes, process schedules and native scenarios still execute. Identical
native builds and the configuration-independent schema/fixture/C-diagnostic
evidence are shared after content and toolchain checks. Each compiler probe keeps
its own source and diagnostic assertions while sharing compatible module caches.
`--reuse-directory <campaign-directory>` shares this evidence between separately
invoked configurations; `NV_STORAGE_QUALIFICATION_REUSE=<campaign-directory>`
enables native-build/compiler-cache sharing for standalone runners. Use a fresh
campaign directory for a new qualification campaign. See the
[reuse contract and validation](impl-proposal-5/plan/qualification-build-reuse.md).
- [Phase 4 improvements](impl-proposal-5/plan/phase-4-improvements/validation.md) add strict replay-request, per-envelope occurrence and coalesced-recovery checks to that common driver. `tools/test-storage-review-process.py` exercises repeated real diagnosis/settlement write failures and fresh reopening. For scaling comparisons, set `NV_STORAGE_IMPROVEMENT_BENCHMARK=1` and use `SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter packedReaderImprovementMeasurements\|recoveryWorkAcrossHistoryAndLag'`; ordinary test runs keep those larger measurements opt-in.
- [Phase 4C–4E](impl-proposal-5/plan/phase4-private-state-repair-copy-validation.md) adds nonempty private settings/pending codecs, keyed fixed-cut backup, actual encrypted-page salvage, complementary repair, verified selection and repository-copy/export checks. `tools/test-storage-private-process.py --binary <probe>` runs 40 fresh-process schedules with independent history inspection; `--ssh-target`, `--ssh-key` and `--remote-env` run the same children on a test host while keeping the observer local. `tools/test-storage-private-types.py --modules <build>/Modules` checks 29 ordinary/same-module boundaries. The common driver includes both, the independent private fixtures and exact schema tests.
- `make -C tests run-platform` runs tests that depend on live macOS services such as WebKit/AppKit, FSEvents, or Trash.
- `make -C tests run-native-undo-probes` runs 51 isolated synthetic AppKit undo/shared-view experiments without building or opening NV. It is intentionally opt-in; see the [results, limits and interactive commands](impl-proposal-5/Native-Undo-Experiments.md). `--only shared-` on the runner selects the 20 new cases; `--interactive-shared` opens two opt-in keyboard/IME windows. `OBSERVE` denotes an observation-only run, not an assertion proof; passing concrete checks never promotes every accompanying observation. No notes, cloud files, general clipboard or UI-automation permission is used. A denied private pasteboard service requires a normal logged-in execution context, not a false Apple-contract failure.
- `make -C tests run` runs `run-core` followed by `run-platform`.
- `make -C tests stress` runs the concurrency, packed-record fuzzing, xattr, and ambiguous-matching stress cases.
- `make -C tests leak-check` runs the resource lifecycle scenario under `/usr/bin/leaks`.
- `make -C tests filesystem-image-stress` creates test-owned 192 MiB sparse disk images and runs the APFS, case-sensitive APFS, HFS+, case-sensitive HFS+, ExFAT, ENOSPC, bookmark-remount, live-detach, filesystem-metadata, and system-tag matrix. It uses `hdiutil`, mounts and detaches images, and may require running outside a restrictive sandbox. SMB/NFS and real iCloud/Finder process coordination remain manual.
- `make -C tests run-icloud-api-contract` runs the focused real-provider probe as an ad-hoc-signed LaunchServices app in `~/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing`.
- `make -C tests run-file-provider-api-contract` runs the same app-context probe in `~/Library/CloudStorage/Dropbox/API_Contract_Testing`. Override either root with `ICLOUD_API_TEST_ROOT=/path` or `FILE_PROVIDER_API_TEST_ROOT=/path`.
- `make -C tests run-icloud-api-contract-legacy-upload` runs the exact pre-macOS-26 upload-transition/correlation probe. Run it on each required older OS.
- `make -C tests run-icloud-api-contract-sync-control-probe` packages the focused macOS 26 pause/resume probe as an ad-hoc-signed, entitlement-free app and launches it through LaunchServices. A direct command-line run is not representative of NV for these controls.
- `make -C tests run-icloud-api-contract-pause-lifecycle` launches the app twice to leave an identity-preserving local edit paused, then verify that a fresh app launch observes, resumes, uploads, and cleans it up. Override `ICLOUD_API_TEST_ROOT` to repeat this against another provider.
- `make -C tests run-icloud-api-contract-xattr-host` and `run-icloud-api-contract-xattr-peer` run the two-Mac syncable-UUID-xattr probe described below.
- `make -C tests clean` removes the executables from `/tmp/notation-integration-tests`.
- `./build.sh` must still be run after significant source changes, even when the tests pass.

### Private SQLite transaction experiment

The opt-in [private SQLite transaction experiment](impl-proposal-5/plan/sqlite-collection-transaction-validation.md)
runs with `python3 tests/run-sqlite-collection-protocol.py`; add
`--sqlcipher-build /path/to/sqlcipher` for encryption. It creates synthetic
temporary DBs/files, kills child processes at named transaction boundaries and
checks designated mutations. It neither builds NV nor opens a real collection;
it is a candidate storage-mapping test, not a production adapter or provider test.

### Exploratory incarnation metadata probe

This is a policy experiment, not a gate or implementation of UUID xattrs in NV:

```sh
make -C tests /tmp/notation-integration-tests/ICloudAPIContractTest \
  /tmp/notation-integration-tests/ICloudAPIContractTest-x86_64
/tmp/notation-integration-tests/ICloudAPIContractTest metadata-probe "/path/to/API_Contract_Testing"
# On either Mac, using the exact READY session directory (the Intel binary can run on the peer):
/tmp/notation-integration-tests/ICloudAPIContractTest metadata-inspect "/path/to/API_Contract_Testing/nv-api-metadata-UUID"
```

`metadata-probe` owns a fresh UUID-named subtree with synthetic bodies and six flagged xattrs. It compares the public copy/save/share/sync/backup intent evaluator with Foundation copy, APFS clone, rename, in-place/atomic writes, and Foundation replacement with and without staged fresh metadata under both replacement options. `PASS` checks intent evaluation and positive/negative digest binding; preservation and provider behavior are `OBSERVE`, not universal contract assertions. It reuses the existing replacement helper, not an implementation of NV's proposed safe-save backend.

`metadata-inspect` reads the generated `origin.plist` and each named file independently, reporting attribute/body hashes and hashed forward provider item/domain comparisons. It queries the manifest's exact originating attribute names: older runtimes can omit unknown flag bits when encoding names. Older manifests lacking names are rejected; generate a fresh fixture. Manifest arrival is only a wakeup, not a complete-sync barrier; missing bodies/attributes remain observations and can require another inspection. Snapshot fields come from separate reads, not one atomic production admission snapshot. Both modes enumerate public File Provider service names without opening XPC connections or invoking any service. The service/identity callbacks have bounded waits; synchronous coordinated file reads have no cancellation/deadline guarantee. No Finder/TextEdit GUI is opened.

The unique subtree is **retained** for peer inspection; the fixed-name `cleanup-local` command does not remove it. Inspect the printed exact path before manually removing a completed synthetic session. These probes may need execution outside a restrictive sandbox for Foundation coordination. See [incarnation metadata results and limits](tla/Incarnation-Metadata-Experiments.md); local observations do not establish cross-Mac portability, an uncopyable identity, or body/metadata delivery atomicity.

For the two-Mac lifecycle/intent-order experiment, copy the Intel binary into a new temporary directory on the Mini, then run:

```sh
python3 tests/run-incarnation-experiments.py \
  --remote-binary /tmp/your-test-directory/ICloudAPIContractTest \
  --key /tmp/scrodmini_ed25519 --host scrod@scrodmini.local
```

Override `--root` if needed; this runner uses the same root path on both hosts. It drives the harness's `binding ROOT prepare` and `binding SESSION ACTION [LEAF]` modes, touching only fixed synthetic leaves below a UUID-named `nv-api-binding-` subtree. Twenty-three stages cover fresh-process observation, bidirectional rename/safe save, metadata-preserving copy, eviction/rematerialization, test-subdirectory Trash restoration, external deletion/restoration, explicit fresh birth, atomic replacement, and intent-before/after-absence schedules. Each child has a 55-second outer timeout; peer convergence has a 60-second polling budget checked between calls (an in-flight child may extend it). A timeout is inconclusive, never a freshness proof. JSON results, every child output, and fixtures remain available. NV itself is not launched; no actual NV database or WAL is tested by this driver.

Add `--handshake` to run 11 nonce-exchange stages instead: a clean challenge/reply/ack, a metadata-preserving independent copy, then three **explicit** metadata relays between the distinct original/copy endpoints. Fixed `#S` metadata is transferred through public coordinated xattr calls; neither body is changed. The check requires distinct source/copy local provider IDs on each observer and verifies they remain stable during the relays. This tests primitives, not an adopted association protocol or universal provider identity guarantee. Add `--local` (and omit `--remote-binary`) for fresh-process observers on one Mac; JSON explicitly records `localOnly: true`, and this must never be reported as cross-Mac validation.

For a fixture prepared on either host but not yet exercised, `--handshake --session /absolute/root/nv-api-binding-UUID` reuses that fixture after it has appeared on both hosts. The session must be directly below `--root`; this is not partial-run resume, and an existing `copy.bin` will cause the copy stage to fail rather than overwrite it. On 2026-09-04, both the same-Mac and two-Mac 11-stage nonce runs completed. Two earlier initial-delivery timeouts remained inconclusive; the successful cross-Mac run used a subsequently synchronized Mini-origin fixture. See the [combination report](tla/Protocol-Combination-Experiments.md) for results and retained artifacts.

### Historical FSEvents probe

This opt-in standalone probe changes only a fresh synthetic subtree under the specified parent:

```sh
make -C tests /tmp/notation-integration-tests/FSEventsHistoryProbe \
  /tmp/notation-integration-tests/FSEventsHistoryProbe-x86_64
/tmp/notation-integration-tests/FSEventsHistoryProbe run /private/tmp
# Read a retained fixture's scoped history in a fresh process:
/tmp/notation-integration-tests/FSEventsHistoryProbe replay /path/to/nv-fsevents-history-XXXXXX
```

It tests rename, rename-out/back, POSIX staged replacement, copy/clone, hard-link rename and unlink/recreation. The run captures a per-device cursor/FSEvents database UUID, records live hints and actual file snapshots, then invokes another process for historical replay with file events, extended file/document IDs, FullHistory and MarkSelf. Ten-second observation budgets bound event waits, not arbitrary synchronous filesystem/service calls. It creates no app watcher, reads no raw system event database and never purges historical events. The per-run `manifest.plist`, `observations.jsonl` and synthetic files are retained. Exit 0 reports fixture/replay completion, not one-event-per-operation fidelity; exit 3 is unavailable/inconclusive history and exit 1 is setup/fixture failure.

An explicitly authorized provider **testing** folder may replace `/private/tmp`; that tests local FSEvents there, not cross-Mac propagation or remote user intent. For Intel macOS use the `-x86_64` executable. See [observations, retained results and policy limits](tla/CoAdd-Policy-Experiments.md#historical-fsevents-follow-up). Historical hints never replace current rooted/catalog checks or supply logical deletion/UUID authority.

### Real cloud API contract probe

The local cloud commands build and launch `ICloudAPIContractTest.app`, use only the fixed `nv-api-contract-local`, `nv-api-contract-path-a`, and `nv-api-contract-path-b` subtrees under the selected testing directory, exercise promised metadata, eviction/materialization, shallow and batch coordination, `NSFileVersion`, File Provider identity, presenter callbacks, root moves, capability advertisement versus actual outcomes, and the ordinary-sync fallbacks, then remove those subtrees. The AV-08 phase moves one retained root before and while catalog, asynchronous intent read, batch read, Foundation replacement, materialization, version, and sync-control operations execute. The iCloud command selects the first-class-required policy; Dropbox selects observational policy. Neither mode branches on provider brand at runtime. Fixed test names make crash cleanup possible without enumerating the user's directory; only one local run may use a given root at once. They are intentionally outside `run` and `run-platform`: results depend on the live account, provider, network, storage policy, OS, and signing configuration. `PASS` establishes only the scenario named by the output; `OBSERVE` and `SKIP` preserve an API-contract gap without turning it into a false test failure.

After a crashed local or legacy-upload run, remove only the fixed local rendezvous names with:

```sh
/tmp/notation-integration-tests/ICloudAPIContractTest cleanup-local "/path/to/API_Contract_Testing"
```

For the remote create/edit/rename/delete and callback path, use two Macs on the same iCloud account. Start this on Mac A and leave it running:

```sh
make -C tests run-icloud-api-contract-remote-host
```

After it prints `READY`, run this once on Mac B:

```sh
make -C tests run-icloud-api-contract-remote-peer
```

The protocol uses one fixed `nv-api-contract-remote` rendezvous so no token or path must be copied. Only one remote run may be active in that testing directory. Its marker is only a wakeup: the host retains the dirty obligation and retries coordinated exact observations until the remote namespace/content converges or the test times out. It then verifies presenter activity and version enumeration, acknowledges the peer, removes and drains the presenter, launches a fresh child process to query retained pre-rename/pre-delete URLs, and removes the rendezvous. The default remote timeout is 15 minutes. After a crashed remote run, rebuild the executable and remove only that fixed rendezvous with:

```sh
/tmp/notation-integration-tests/ICloudAPIContractTest cleanup-remote "$HOME/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing"
```

The UUID-xattr probe uses the fixed `nv-api-contract-xattr-v2` rendezvous and the same host/peer ordering:

```sh
make -C tests run-icloud-api-contract-xattr-host
# On the second Mac, after READY:
make -C tests run-icloud-api-contract-xattr-peer
```

It writes five 16-byte UUID values under names generated by `xattr_name_with_flags(..., XATTR_FLAG_SYNCABLE)`, then checks cross-Mac delivery, metadata-only access while a body remains evicted, rematerialization, rename, Foundation atomic replacement, Finder duplication, and TextEdit saving. The Finder and TextEdit phases are real Apple-event-driven GUI operations, are bounded to 30 seconds, and may require the logged-in user to grant Automation access or answer a TextEdit keep/delete prompt; choose **Delete** for the synthetic test document. A headless or denied GUI phase reports `OBSERVE` and does not block the remaining protocol. Run `ICloudAPIContractTest cleanup-xattr ROOT` after interruption. Reverse the host and peer roles to cover both synchronization directions.

Local provider and macOS 26 sync-control modes use the LaunchServices app wrapper; remote peer and cleanup modes may use the standalone executable. On macOS 26.6.1, the app run succeeded with no Team ID or entitlements while direct invocation of the same binary returned `NSFeatureUnsupportedError`. A normally launched release build remains a deployment smoke test, but Developer ID signing, notarization, and an iCloud entitlement are not API prerequisites established by this probe. See [Apple-API-Contract-Validation.md](Apple-API-Contract-Validation.md).

For a real simultaneous conflict/nonlocal-version test, build the executable for both architectures, copy the x86_64 binary to the peer, and use the fixed `nv-api-contract-conflict` subtree:

```sh
export ICLOUD_API_TEST_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing"
make -C tests /tmp/notation-integration-tests/ICloudAPIContractTest \
  /tmp/notation-integration-tests/ICloudAPIContractTest-x86_64
/tmp/notation-integration-tests/ICloudAPIContractTest conflict-prepare "$ICLOUD_API_TEST_ROOT"
# On Mac B:
/tmp/ICloudAPIContractTest conflict-materialize "$ICLOUD_API_TEST_ROOT"
# Choose one epoch several seconds in the future, then run concurrently:
/tmp/notation-integration-tests/ICloudAPIContractTest conflict-write "$ICLOUD_API_TEST_ROOT" host "$START_EPOCH" /tmp/host-source-identifiers.plist
/tmp/ICloudAPIContractTest conflict-write "$ICLOUD_API_TEST_ROOT" peer "$START_EPOCH" /tmp/peer-source-identifiers.plist
# Run concurrently on both Macs:
/tmp/notation-integration-tests/ICloudAPIContractTest conflict-inspect "$ICLOUD_API_TEST_ROOT" required
/tmp/ICloudAPIContractTest conflict-inspect "$ICLOUD_API_TEST_ROOT" required
# Optional: export on each Mac, exchange the two plists outside iCloud Drive, then compare the peer's file:
/tmp/notation-integration-tests/ICloudAPIContractTest conflict-export-identifiers "$ICLOUD_API_TEST_ROOT" /tmp/local-identifiers.plist
/tmp/notation-integration-tests/ICloudAPIContractTest conflict-compare-identifiers "$ICLOUD_API_TEST_ROOT" /tmp/peer-identifiers.plist
/tmp/notation-integration-tests/ICloudAPIContractTest cleanup-conflict "$ICLOUD_API_TEST_ROOT"
```

Each conflict writer puts the syncable UUID on its staged replacement before the coordinated installation; half the files use default Foundation replacement metadata handling and half use `NSFileManagerItemReplacementUsingNewMetadataOnly`. Required inspection waits for all eight fork pairs and fails rather than reporting observational success when Apple exposes no conflict. It records which side became Current, but does not infer Apple's internal server order from that outcome. Run two clean prepared/materialized rounds with staggered epochs so each host is locally first once; both runs must preserve every pair even if Apple deterministically selects the same branch as Current. When the optional output argument is present, the writer also captures its identifier immediately while its payload is current. The inspector requires exact before/after coordinated local-version fences with a registered presenter, reads every current/other/unresolved/nonlocal version, verifies both payloads, checks that each nonlocal persistent identifier remains equal after materialization, and records whether each body-bearing version URL exposes the base file's syncable UUID xattr. The optional identifier exports contain only the synthetic file index, branch name, and archived opaque identifier. Compare each source capture locally after convergence to test current-to-historical transition, then exchange it to test the same transition across machines. Separately export the settled 16-version set, compare it in a new process on the same Mac, then exchange it to distinguish archive persistence from cross-machine portability. Exchange through SSH or removable temporary storage, not through the provider under test; the comparator uses payload-matched semantic equality and `versionOfItemAtURL:forPersistentIdentifier:` without logging identifiers. Remove all temporary plists afterward. The probe never resolves the conflicts. Cleanup removes only the fixed test subtree.

To exercise the edit/delete case, prepare and materialize the same fixed subtree again, choose one future epoch, and run these concurrently:

```sh
# Mac A
/tmp/notation-integration-tests/ICloudAPIContractTest conflict-edit-delete-write "$ICLOUD_API_TEST_ROOT" edit "$START_EPOCH"
# Mac B
/tmp/ICloudAPIContractTest conflict-edit-delete-write "$ICLOUD_API_TEST_ROOT" delete "$START_EPOCH"
# After provider convergence, on either Mac:
NV_ICLOUD_API_TEST_TIMEOUT=900 /tmp/notation-integration-tests/ICloudAPIContractTest conflict-edit-delete-inspect "$ICLOUD_API_TEST_ROOT"
```

The inspection is observational. It records separately how many edited payloads are Current or Apple-reported unresolved and how many are discoverable through `otherVersionsOfItemAtURL:` or `getNonlocalVersionsOfItemAtURL:completionHandler:`. An absent current file supplies no recovery input under NV's current-visible policy. The macOS 26/macOS 14 run exposed zero of eight edited bodies as Current or unresolved on either Mac after the delete won, so the specification makes no current-visible delete/edit recovery claim. This result does not establish that the provider destroyed undisclosed server-side data, and the historical/nonlocal observations are diagnostic rather than inputs NV may use. Reverse Mac roles when rechecking a new OS/provider implementation.

The macOS 26 server-conflict probe uses `sync-conflict-host` and `sync-conflict-peer` in the same host/peer pattern, but the host must run from `ICloudAPIContractTest.app` through LaunchServices. If the item does not advertise both controls, or pause fails before acquisition, both sides verify the ordinary-sync fallback and exit cleanly. If pause succeeds, the diagnostic host performs an identity-preserving in-place edit, the peer uploads a newer server version, the host fetches and reads it while paused, fail-on-conflict must reject the stale local upload, and the host must preserve local bytes and resume before cleanup. This validates Apple's control APIs; it deliberately does not validate replacing NV's atomic checkpoint writer with an in-place write. Use `cleanup-sync-conflict` after an interrupted run.

### Root-lock interference probe

The child-file `ICloudAPIContractTest root-lock-*` modes below are comparison probes for the rejected `.nv-root.lock` design, not current implementation requirements. The adopted [directory-descriptor probe](#root-directory-descriptor-lock-probe) follows this section. The child-file probes use **empty mode-0600 lock files**, descriptor-relative non-following open, `flock(LOCK_EX | LOCK_NB)`, and an independently exec'ed contender. The holder's descriptors are close-on-exec. Output records local root/file identity, link count, dataless status, open latency, each contender outcome, and advisory unresolved-version/namespace counts. Cross-Mac inode values are never compared. No version is resolved or removed.

First run the deterministic controls on a local temporary directory:

```sh
make -C tests run-root-lock-probe-control
```

Six controls require ordinary contention, release/reacquisition, deliberate same-byte Foundation replacement, deliberate unlink/recreation, symlink refusal, and nonblocking FIFO refusal. The two replacement controls **pass when they reproduce the hazard**: another local process acquires the current pathname while the original descriptor is still locked. They establish detector sensitivity and POSIX behavior, not spontaneous iCloud behavior. Run outside a restricted sandbox if Foundation coordination is denied.

For live tests, build the ordinary executable and, for an Intel peer, the `-x86_64` target. On each Mac set `LOCK_PROBE` to its executable and `LOCK_ROOT` to that Mac's existing `API_Contract_Testing` directory. Generate **one** `LOCK_RUN` UUID on Mac A and copy its exact uppercase value to Mac B; do not generate a different value on each machine.

```sh
make -C tests /tmp/notation-integration-tests/ICloudAPIContractTest \
  /tmp/notation-integration-tests/ICloudAPIContractTest-x86_64
LOCK_PROBE=/tmp/notation-integration-tests/ICloudAPIContractTest
LOCK_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing"
LOCK_RUN=$(uuidgen)
"$LOCK_PROBE" root-lock-prepare "$LOCK_ROOT" "$LOCK_RUN"  # Mac A only
```

Preparation exclusively creates `nv-api-contract-lock-<LOCK_RUN>` with an ownership marker and three children: `cold`, `held`, and `race`. Only `cold` and `held` initially contain locks. Existing sessions are never overwritten. The other commands verify the ownership marker and accept only those three child names. On Mac B, `root-lock-inspect "$LOCK_ROOT" "$LOCK_RUN" held` verifies accessibility; also verify the `race` directory has arrived before starting its race. Marker visibility alone is not an ordering fence for other children.

| Scenario | Procedure and evidence required |
| --- | --- |
| Cold startup with an evicted lock | Run `root-lock-evict ROOT RUN cold`, then `NV_ICLOUD_API_TEST_TIMEOUT=10 ... root-lock-watch ROOT RUN cold`. Require actual `not-downloaded-observed=1`; inspect `before-open dataless`, open latency, and local contention. Open may succeed while the empty file remains dataless. Request acceptance alone does not exercise eviction. |
| Eviction/rematerialization while held | Start `root-lock-watch ROOT RUN held` for 60 seconds. After its holder-acquired line, use another process on that same Mac for `root-lock-evict ROOT RUN held`, then `root-lock-download ROOT RUN held`. Record refusal separately. If refused, the transition was not exercised; do not call it a successful eviction test. Repeat by evicting `cold` **before** opening, holding that dataless lock, and requesting `root-lock-download ROOT RUN cold` while held. |
| Remote replacement while held | On Mac A, start `root-lock-watch ROOT RUN held` for 60 seconds. After acquisition, run `root-lock-replace ROOT RUN held` on Mac B. This explicitly installs another **empty** file with coordinated Foundation replacement. A local install on B does not prove delivery to A: require A's name/descriptor identity change before claiming replacement was exercised. Reverse roles in a fresh run. |
| Concurrent creation on two Macs | On both Macs run `root-lock-watch ROOT RUN race START_EPOCH` using the same epoch 15–30 seconds ahead. Each process checks absence and then uses exclusive creation; both logs must show `exclusive-created=1` and overlapping held intervals. An `EEXIST` result is inconclusive, not concurrent creation. Neither process changes the empty lock afterward. Watch for provider-created replacement, extra siblings/unresolved versions, and second-local-process admission. Use a fresh session for every round. |

For example, after setting the same run UUID on both Macs, run this on **each** for the creation race (copy one future epoch; do not compute separate epochs):

```sh
NV_ICLOUD_API_TEST_TIMEOUT=60 "$LOCK_PROBE" root-lock-watch "$LOCK_ROOT" "$LOCK_RUN" race "$LOCK_START_EPOCH"
```

The monitor launches a contender roughly once a second and retains the original lock throughout. A `HAZARD AV-LOCK-local-exclusion` line means a second local process acquired while that original descriptor remained locked; distinguish this from the **expected** ability of separate Macs to hold their own local locks. A changed root directory is reported separately rather than attributed to a lock-file replacement. Sampling can miss transient namespace changes: lack of a hazard is only a bounded observation, never proof that provider replacement cannot happen.

Exit codes: `0` means a completed observation or successful control suite, **not provider certification**; `1` means a detected hazard or failed control; `2` means invalid setup/inconclusive access; `124` means the hard deadline expired. Read per-phase `INCONCLUSIVE` output too. `NV_ICLOUD_API_TEST_TIMEOUT` bounds the observation interval (1–300 seconds). Each contender has a five-second deadline; an additional process alarm bounds synchronous `open`/Foundation calls, including up to 60 seconds of scheduled-start lead time and ten seconds of teardown allowance. `BEGIN` output identifies the unfinished phase. No API timeout is interpreted as root loss, eviction, conflict absence, or successful exclusion.

The probe intentionally preserves its UUID-owned subtree for examination; after **all** holders on **both** Macs exit, it may be moved to Trash manually. Never run these actions against a real notes directory's own lock. Only the deliberate local control unlinks a lock, and only within its freshly created private subtree.

### Root-directory descriptor lock probe

`root-lock-directory TEST_ROOT` tests the adopted design of locking an `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC` directory descriptor directly. It creates a fresh `nv-api-contract-directory-lock-<UUID>` subtree and a synthetic child payload; **no `.nv-root.lock` or WAL is created**. This is an isolated platform probe, not the production ownership implementation.

```sh
make -C tests run-directory-lock-probe-control
# Repeat on each Mac, against its existing iCloud API test directory:
NV_ICLOUD_API_TEST_TIMEOUT=30 /tmp/notation-integration-tests/ICloudAPIContractTest \
  root-lock-directory "$ICLOUD_API_TEST_ROOT"
```

Independent exec'ed processes verify exclusion initially, after closing a separately opened catalog descriptor, after coordinated child-file creation/Foundation replacement, after directory rename and movement to another parent, and across a duplicated-descriptor handoff. Closing the last descriptor permits acquisition. A pipe-confirmed independent holder is killed with `SIGKILL`, after which another process must acquire. Recreating the old pathname deliberately produces a **different**, independently lockable directory: this positive control must not be interpreted as protection of a pathname or a replacement root.

On a positively ubiquitous directory with an uploaded child, the probe also requests directory eviction, opens/locks it again, materializes the exact child bytes while locked, and repeats eviction/rematerialization while holding the lock. It records directory `SF_DATALESS` separately from the child's not-downloaded status. **Child-only eviction does not establish directory-placeholder coverage.** That case still exercises child rematerialization and exclusion, but returns 2 to retain the stronger coverage gap. Eviction acceptance alone, refusal, and missing upload evidence are not successful lifecycle observations. The shared process/contender deadlines above apply, and synthetic subtrees are retained.

This is a per-host probe, not a distributed lock or certification of every filesystem/provider event. Remote-origin directory replacement/movement, a positively dataless directory, cross-user access, and unsupported/network filesystems require separate evidence before extending the claim. Results are recorded under [AV-16](Apple-API-Contract-Validation.md#av-16--root-directory-lock-contract). The [P5.1 production-owner qualification](impl-proposal-5/plan/phase5/01-root-ownership-validation.md) separately covers continuous ownership through handoff, canceled/entered work, quiesce, close and teardown. [P5.5](impl-proposal-5/plan/phase5/05-startup-and-root-reassociation-validation.md) adds integrated startup and root reassociation; actual application lifecycle adoption remains a later gate. Legacy checkpoint/WAL cleanup is covered by the legacy scenarios below.

The epoch-4 archive compatibility smoke test is intentionally outside `run-core`:

```sh
tools/test-epoch4-v5-compatibility.sh
```

NV's last public release used epoch-5 Notes & Settings. Most people are still using a release from 2011 based on epoch-4. Every segment/private format remains unreleased. This test exercises the legacy
archive/export boundary, independently of NVStorage and its development bytes.
Its filename and `NV_EPOCH5_DATABASE_DIRECTORY` retain development-era names.

It creates a fresh encrypted `Notes & Settings` archive through the app's legacy
writer with the current test binary, builds a temporary checkout at
`f4ada9d2e3c34fb816183bf9864074770605a4d3`, and has that epoch-4 reader load
and decrypt the archive while verifying the warning, critical note content, and the
`createdDate`, `modifiedDate`, `filename`, `selectedRange`, `currentFormatID`,
and `fileEncoding` fields. No generated archive fixture is retained.
The reader is a 2026-08-08 source revision using the epoch-4 format; this test
qualifies archive readability through that reader, rather than execution of a
2011 release binary.
Because the historical reader constructs an AppKit alert, run this smoke test
in a normal logged-in macOS session rather than a restricted sandbox.

For a normal change, run the narrowest relevant scenario first, then `make -C tests run-core` and `./build.sh`. Run `run-platform`, `stress`, `leak-check`, or `filesystem-image-stress` when the touched behavior falls in those areas. A sandbox denial involving Trash, FSEvents, `leaks`, or `hdiutil` should be rerun in a normal logged-in macOS session before being treated as a product failure.

To run one scenario:

```sh
make -C tests /tmp/notation-integration-tests/NVIntegrationTest
/tmp/notation-integration-tests/NVIntegrationTest <scenario-name>
```

To run one standalone test, build its `/tmp/notation-integration-tests/<TestName>` Make target and execute that path directly.

### Standalone test executables

- `AppearanceColorTest`: light/dark appearance colors, divider rendering and temporary screen attributes; runs in `run-core`.
- `GlobalPrefsArchiveMigrationTest`: legacy/secure preference archive migration, including font and color values; runs in `run-core`.
- `WebArchiveImportIntegrationTest`: styled WebArchive import, body-font normalization and retained text traits; runs in `run-core`.
- `ModernStickiesImportTest`: RTFD note-package detection/import and ordinary-file eligibility; runs in `run-platform`.
- `NVIntegrationTest`: scenario-driven full-stack controller, directory, storage, reconciliation, lifecycle, and recovery tests listed below.
- `ICloudAPIContractTest`: opt-in real-provider API probe and two-Mac host/peer protocol described above.

The [native catalogue](test-index/native-and-legacy.md) also indexes separately
built experimental probes and every helper subprocess mode. Their explicit
runner/arguments select the required synthetic fixture and observation schedule.

### `NVIntegrationTest` scenarios

Enumeration and filesystem metadata:

- `bulk-parser`: valid, unavailable, transient, malformed, overlapping-name, embedded-NUL, document-ID, file-ID, and generation-count packed records.
- `bulk-parser-fuzz`: guard-page truncation checks and 50,000 deterministic packed-record mutations.
- `file-metadata`: case collisions, ctime/generation detection, document and session file identity, rename matching, tags, content fallback, and refusal to read, replace, or remove symlink targets.
- `coarse-ctime-observation`: records the accepted degraded same-vnode detection behavior on HFS+ with coarse ctime; the image harness treats this as an open-contract observation.
- `partial-bulk-fallback`: partial `getattrlistbulk` output is discarded before Foundation fallback; persistent transient failures do not commit partial catalogs.
- `filesystem-capabilities`: verifies expected filesystem type/case sensitivity, xattrs, bulk enumeration, document/file IDs, generation count, and stable snapshots. Normally run by the disk-image harness with `NV_TEST_VOLUME_ROOT`, `NV_EXPECT_FSTYPE`, and `NV_EXPECT_CASE_SENSITIVE`.
- `benchmark`: warm medians for raw bulk enumeration and complete unchanged-directory scans at 1,000 and 10,000 files; enforces the bulk performance gates.

Stable snapshots, xattrs, and concurrent writers:

- `snapshot-stress`: repeatedly safe-saves content, encoding, and tags from a child process and rejects mixed-vnode snapshots.
- `snapshot-boundary-races`: deterministic replacement at final identity and Cocoa-tag fallback boundaries; verifies retry to a coherent snapshot.
- `snapshot-in-place-observation`: races same-vnode content/encoding/tag mutation and reports coherent versus rejected/mixed observations.
- `snapshot-failures`: injected data, xattr, decode, identity, and constructor failures propagate without mutating live state.
- `xattr-interoperability`: Finder/OpenMeta tag plists and named/numeric `com.apple.TextEncoding` values, including absent xattrs.
- `system-tag-producer`: a separate process changes `NSURLTagNamesKey`; verifies Finder precedence, explicit clears, OpenMeta fallback, and nonfatal Finder-write failure. The filesystem-image harness runs it on APFS.
- `system-tag-writer-child`: helper subprocess for `system-tag-producer`; do not normally invoke directly (`NV_SYSTEM_TAG_PATH` is required).

Transactional directory reconciliation:

- `directory-reconciliation`: imports, metadata/content/tag changes, Unicode names, case collisions, bulk/Foundation recovery, rename identity, deletions, and content matching.
- `ambiguous-content`: 1:2, 2:1, identical empty-note, hard-link, case-only, and mutation ambiguity falls through without unsafe rename matching.
- `ambiguity-stress`: larger repeated ambiguous-content groups and concurrent mutation stress.
- `scan-atomicity-contract`: failures at the first, middle, and last update/import leave the entire scan uncommitted.
- `failed-scan-retry-contract`: transient scan failures retry and converge without another event; stopping notifications cancels retries.
- `catalog-fence-contract`: mutation between preparation and the exact second catalog pass discards the first transaction and converges on retry.
- `directory-fence-modes`: every scan uses two exact catalog passes; FSEvents is invalidation-only, and failed stream reconfiguration remains a retry obligation.
- `unsaved-write-recovery-contract`: memory-wins conflicts, independent file/WAL outbox obligations, failed writes, and later recovery.
- `external-editing-text-merge`: conservative text merging and refusal of ambiguous overlapping patches; private scratch-workspace lifecycle, separate-file save/reconciliation and external-editing merge-base handling.
- `storage-transition-memory-wins`: switching from a single database to separate files queues authoritative in-memory notes even when a newer external file exists.
- `open-files-workflow`: mixed known and external paths reveal owned notes while importing the remaining files.
- `deletion-contracts`: restored external deletions, batched confirmation-free deletion, and failed Trash moves.
- `fsevents-live`: live service delivery drives create, rename, edit, and delete reconciliation without a manual scan; it also covers real direct/scratch editor routing and delivery, plus private 0600 encrypted scratch editing on the verified RAM disk and teardown. Belongs to the platform suite.
- `rename-without-preflight`: note renames do not widen the race with a separate existence check.
- `rename-enoent-source-proof`: ENOENT is accepted only when the source is truly absent; a disappearing destination with a surviving source returns `EAGAIN`.

Storage formats, archives, and recovery:

- `epoch-five-archive`: epoch-5 additive metadata keys and removal of obsolete serialized caches/types.
- `single-database`, `plain-text`, `rtf`, `html`: CRUD, persistence, reload, and format-specific serialization for each storage format. `html` belongs to the platform suite.
- `storage-transitions`: plain-text to RTF to single-database persistence, including optional separate-file cleanup.
- `plain-text-encodings`: ISO-8859-1 and malformed-declared-UTF-8 fallback import, save, byte preservation, encoding metadata, and reload.
- `filesystem-crud`: separate-file create, external move, save, and reload on the selected volume; the disk-image harness runs it on ExFAT and native formats.
- `file-barrier-sync`: the real file barrier and its unsupported-command `fsync` fallback, using a temporary regular file and `/dev/null`.
- `filename-collisions`: slash-bearing titles, untracked destination files, and case-only internal renames remain distinct and reloadable.
- `case-sensitive-filename-collisions`: on APFSX/HFSX, untracked case-only create/rename targets remain distinct, same-note case-only renames leave one file, and physical case collisions abort reconciliation without model mutation.
- `concurrent-controllers`: a live controller keeps exclusive ownership of its WAL while a second controller fails closed; crash recovery remains separately covered.
- `unsupported-journal-locks`: bookmark-resolved controller launches and WAL recovery tolerate unsupported advisory locking (`ENOTSUP` and regular-file `EINVAL`) while lock contention still fails closed.
- `legacy-temporary-database-recovery`: after a journaling error, an epoch-4 database offers recovery from the newest qualifying legacy verified-write temporary file; nanosecond/lexical selection, age/size/epoch/filename gates, source preservation, rollback, declined choices, and clean relaunch are covered.
- `wal-record-recovery`: exercises clean records, skippable archive/type/length failures, checksum/decryption/zlib hard stops, compression-stream resynchronization, unexpected short reads, and benign truncated tails while retaining every safely recovered note.
- `wal-recovery-workflows`: covers complete epoch-4 WAL replay before upgrade, partial-note merging, legacy-candidate merging before epoch upgrade, starting from the old database, one-write epoch upgrade, mutually exclusive alerts, preservation names, rename/sync/fresh-journal rollback, discarded-controller callback cancellation, and unrelated journaling errors.
- `legacy-fixtures`: reads legacy keyed/non-keyed database fixtures and upgrades metadata safely.
- `encryption`: encrypted database persistence plus real controller relaunch, modern loading and upgrading of an encrypted epoch-4 fixture, encrypted WAL recovery, post-recovery editing, fresh-WAL replacement, clean WAL retirement, and shutdown/relaunch. With `NV_EPOCH5_DATABASE_DIRECTORY` set, this scenario writes the encrypted current database consumed by the standalone epoch-4 compatibility smoke test.
- `wal-crash-recovery`: child-process WAL crash and relaunch recovery on the selected volume; normally run by the disk-image harness.
- `wal-crash-child`: helper subprocess for `wal-crash-recovery`; do not normally invoke directly (`NV_WAL_CRASH_DIRECTORY` is required).
- `wal-history-recovery`: bookmark-resolved child crashes after interleaved updates and deletion; recovery keeps each UUID's newest state without resurrecting the deleted note.
- `wal-damaged-tail-recovery`: truncates the last synchronized record and verifies complete preceding records recover while the partial tail is ignored.
- `wal-recovery-retry-idempotence`: forces the database flush after WAL recovery to fail, crashes again, and verifies the re-journaled state recovers identically on repeated bookmark-based launches.
- `wal-database-ordering`: verifies stale WAL records cannot replace a newer database, while newer WAL updates and deletions supersede it.
- `wal-durability-boundaries`: crashes before journal synchronization, after journal synchronization, and after database persistence but before WAL cleanup to lock the durability contract.
- `file-outbox-crash-recovery`: WAL success plus note-file failure survives relaunch, rewrites stale disk content before reconciliation, and recreates a WAL-only new note without classifying it as an external deletion.
- `file-outbox-crash-child`: helper subprocess for the outbox crash test; do not normally invoke directly (`NV_FILE_OUTBOX_CRASH_DIRECTORY` is required).
- `disk-full-recovery-contract`: fills a fixed-size image, verifies ENOSPC keeps the write pending, frees reserve space, and converges. Requires `NV_TEST_REQUIRE_DISK_IMAGE=1` and is normally harness-only.
- `atomic-rollback`: leaf validation, symlink refusal, create/replace/overwrite semantics, exact installed-content verification, every typed write disposition, separation of file installation from explicit database synchronization, database pending-state retention, conflict recovery, post-install identity failures, and ownership-safe temporary cleanup.
- `atomic-replacement-capabilities`: verifies the reported capability for APFS swap, HFS+ exchange/link fallbacks, and ExFAT replacement/create fallbacks, plus prepared HFS+ metadata/descriptor handoff and identity-safe ExFAT create cleanup. Normally run by the disk-image harness.
- `failures`: corrupt database, invalid notes directory, read-only writes, nonblocking rejection of a FIFO journal, and related error propagation.

Directory identity, bookmarks, and lifecycle:

- `lifecycle`: detached-note construction/attachment, delegate clearing, label registration, notifications, and constructor/encoding failure behavior.
- `resource-lifecycle`: repeated success/failure/abort/controller teardown cycles, timer/outbox cleanup, deallocation, and file-descriptor baseline; also used by `leak-check`.
- `directory-identity`: file-reference/bookmark and rooted-directory identity survive directory movement.
- `directory-relocation-races`: moves the directory during atomic installation, exact two-catalog scanning, and repeated root-relative note renames.
- `location-migration`: legacy notes-location state migrates to the current bookmark/reference representation.
- `preferences-migration`: legacy preference archive migration and modern values.
- `deep-directory`: a retained rooted capability survives controller restart and keeps reads, writes, scans, and updates directory-relative after an ancestor moves beyond `PATH_MAX`.
- `reference-edges`: Unicode normalization, symlinks, missing references, same-file identity, and related URL/FD edge cases.
- `bookmark-create`, `bookmark-resolve`: helper pair used by the filesystem-image harness to verify resolution after detach/remount (`NV_BOOKMARK_DIRECTORY` and `NV_BOOKMARK_FILE` are required; resolve optionally uses `NV_BOOKMARK_EXPECTED_CONTENT`).
- `live-detach-child`: harness-controlled process that keeps controller descriptors open across forced detach and validates in-memory safety/remount recovery; requires the `NV_LIVE_DETACH_*` variables.
- `trash`: moves a note through the real macOS Trash API and belongs to the platform suite.
