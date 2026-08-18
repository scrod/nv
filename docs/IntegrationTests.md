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
- `make -C tests clean` removes the executables from `/tmp/notation-integration-tests`.
- `./build.sh` must still be run after significant source changes, even when the tests pass.

The historical compatibility smoke test is intentionally outside `run-core`:

```sh
tools/test-epoch4-v5-compatibility.sh
```

It creates a fresh epoch-5 `Notes & Settings` archive with the current test
binary, builds a temporary checkout at
`f4ada9d2e3c34fb816183bf9864074770605a4d3`, and has that epoch-4 reader load
the archive while verifying the warning, critical note content, and the
`createdDate`, `modifiedDate`, `filename`, `selectedRange`, `currentFormatID`,
and `fileEncoding` fields. No database fixture is retained.
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
- `encryption`: encrypted database persistence plus real controller relaunch, encrypted WAL recovery, post-recovery editing, fresh-WAL replacement, clean WAL retirement, and shutdown/relaunch.
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
