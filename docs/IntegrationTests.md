## Integration tests

Run test commands from the repository root. The test Makefile builds the Deployment app objects without code signing, links standalone test executables into `/tmp/notation-integration-tests`, and then runs them. A successful test is silent or exits with status 0; many deliberately injected failure cases write expected diagnostics to stderr.

`NVIntegrationTest` replaces the app's `NVRootedDirectory.o` with a test-instrumented build of the same source and links `tests/NVRootedDirectoryTestHooks.m`. The production target does not compile the hook category, injected race callbacks, or descriptor-invalidating test seam.

### Common commands

- `make -C tests` builds every test executable without running it.
- `make -C tests run-core` runs the headless/default integration suite.
- `make -C tests run-platform` runs tests that depend on live macOS services such as WebKit/AppKit, FSEvents, or Trash.
- `make -C tests run` runs `run-core` followed by `run-platform`.
- `make -C tests stress` runs the concurrency, packed-record fuzzing, xattr, and ambiguous-matching stress cases.
- `make -C tests leak-check` runs the resource lifecycle scenario under `/usr/bin/leaks`.
- `make -C tests filesystem-image-stress` creates test-owned 192 MiB sparse disk images and runs the APFS, case-sensitive APFS, HFS+, case-sensitive HFS+, ExFAT, ENOSPC, bookmark-remount, live-detach, filesystem-metadata, and system-tag matrix. It uses `hdiutil`, mounts and detaches images, and may require running outside a restrictive sandbox. SMB/NFS and real iCloud/Finder process coordination remain manual.
- `make -C tests run-icloud-api-contract` runs the focused real-provider probe as an ad-hoc-signed LaunchServices app in `~/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing`.
- `make -C tests run-file-provider-api-contract` runs the same app-context probe in `~/Library/CloudStorage/Dropbox/API_Contract_Testing`. Override either root with `ICLOUD_API_TEST_ROOT=/path` or `FILE_PROVIDER_API_TEST_ROOT=/path`.
- `make -C tests run-icloud-api-contract-legacy-upload` runs the exact pre-macOS-26 upload-transition/correlation probe. Run it on each required older OS.
- `make -C tests run-icloud-api-contract-sync-control-probe` packages the focused macOS 26 pause/resume probe as an ad-hoc-signed, entitlement-free app and launches it through LaunchServices. A direct command-line run is not representative of NV for these controls.
- `make -C tests run-icloud-api-contract-pause-lifecycle` launches the app twice to leave an identity-preserving local edit paused, then verify that a fresh app launch observes, resumes, uploads, and cleans it up. Override `ICLOUD_API_TEST_ROOT` to repeat this against another provider.
- `make -C tests clean` removes the executables from `/tmp/notation-integration-tests`.
- `./build.sh` must still be run after significant source changes, even when the tests pass.

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
/tmp/notation-integration-tests/ICloudAPIContractTest conflict-write "$ICLOUD_API_TEST_ROOT" host "$START_EPOCH"
/tmp/ICloudAPIContractTest conflict-write "$ICLOUD_API_TEST_ROOT" peer "$START_EPOCH"
# Run concurrently on both Macs:
/tmp/notation-integration-tests/ICloudAPIContractTest conflict-inspect "$ICLOUD_API_TEST_ROOT"
/tmp/ICloudAPIContractTest conflict-inspect "$ICLOUD_API_TEST_ROOT"
/tmp/notation-integration-tests/ICloudAPIContractTest cleanup-conflict "$ICLOUD_API_TEST_ROOT"
```

The inspector requires exact before/after coordinated local-version fences with a registered presenter, reads every current/other/unresolved/nonlocal version, verifies both payloads, and checks that each nonlocal persistent identifier remains equal after materialization. It never resolves the conflicts. Cleanup removes only the fixed test subtree.

The macOS 26 server-conflict probe uses `sync-conflict-host` and `sync-conflict-peer` in the same host/peer pattern, but the host must run from `ICloudAPIContractTest.app` through LaunchServices. If the item does not advertise both controls, or pause fails before acquisition, both sides verify the ordinary-sync fallback and exit cleanly. If pause succeeds, the diagnostic host performs an identity-preserving in-place edit, the peer uploads a newer server version, the host fetches and reads it while paused, fail-on-conflict must reject the stale local upload, and the host must preserve local bytes and resume before cleanup. This validates Apple's control APIs; it deliberately does not validate replacing NV's atomic checkpoint writer with an in-place write. Use `cleanup-sync-conflict` after an interrupted run.

The historical compatibility smoke test is intentionally outside `run-core`:

```sh
tools/test-epoch4-v5-compatibility.sh
```

It creates a fresh encrypted epoch-5 `Notes & Settings` archive with the current test
binary, builds a temporary checkout at
`f4ada9d2e3c34fb816183bf9864074770605a4d3`, and has that epoch-4 reader load
and decrypt the archive while verifying the warning, critical note content, and the
`createdDate`, `modifiedDate`, `filename`, `selectedRange`, `currentFormatID`,
and `fileEncoding` fields. No generated epoch-5 database fixture is retained.
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

- `NVIntegrationTest`: scenario-driven full-stack controller, directory, storage, reconciliation, lifecycle, and recovery tests listed below.
- `ICloudAPIContractTest`: opt-in real-provider API probe and two-Mac host/peer protocol described above.

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
