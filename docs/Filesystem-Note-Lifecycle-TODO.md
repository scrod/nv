# Filesystem Synchronization and Note Lifecycle TODO

This document tracks the correctness work discovered during the APFS metadata,
single-file-descriptor snapshot, transactional-reconciliation, and durable-outbox
refactors. The serialized database remains epoch 5; none of this work adds keys.

Priority meanings: **P1** can lose or suppress changes; **P2** is narrower
correctness or ownership work; **P3** is simplification or prevention.

## Implemented design (2026-08-11)

Directory synchronization now stays on the main thread and has three phases:

1. **Prepare:** bulk-enumerate, match, snapshot, decode, and validate into one
   detached `NVDirectoryTransaction`. Live notes, labels, deletion state,
   notifications, sync state, sorting/filtering, and the volume UUID do not
   change.
2. **Fence:** enumerate again and compare an exact packed catalog token. A
   changed catalog discards the transaction.
3. **Commit:** apply only prepared in-memory values, batch deletion state, update
   sorting/filtering once, then publish UI and sync effects.

FSEvents remains an asynchronous invalidation mechanism rather than part of the
commit proof. Its main-queue callback cannot run during a synchronous scan; when
delivered it coalesces one later scan and records whether the root watch must be
rebuilt. Stream-reconfiguration and filesystem failures retry after 0.1, 0.5,
2, 10, and then 30 seconds indefinitely. A new event resets the delay; stopping
notifications or changing directories cancels the directory retry.

Note files and WAL records now have independent durable obligations:
`pendingFileWrites` and `pendingJournalWrites`. A sink removes only the
obligation it accepted. WAL-owned pending bytes survive short writes, and a
database checkpoint is refused until both note sets and the WAL byte buffer are
durable. WAL recovery queues recovered separate-file notes for rewrite before
directory reconciliation can import stale disk content.

Construction is detached and side-effect-free. One controller attachment path
assigns the delegate, generates a missing filename, connects labels, creates the
preview, and inserts the note once. Existing notes receive prepared file state
through a non-notifying in-memory operation that preserves object identity and
sync UUID.

Normal note writes use one descriptor-relative atomic-install helper. APFS
prepares note bytes and metadata before swap; HFS+ finalizes prepared metadata
immediately after exchanging content; ExFAT has explicitly weaker create and
conditional-replacement fallbacks. The complete contract and accepted limits are
in [Atomic Note Saves](Atomic-Note-Saves.md). Exports use Foundation's native
atomic write. Finder extension hiding remains best-effort after installation.
App-controlled tag changes, atomic note writes, and exports mirror semantic tag
names through `NSURLTagNamesKey` and then
restore the exact OpenMeta plist (including color suffixes) on the verified
descriptor. Provider-side Cocoa tag support is best-effort; OpenMeta and the
root-relative identity check remain authoritative for write success.

## Automated results

The required transactional and durability contracts pass:

| Scenario | Result |
|---|---|
| `scan-atomicity-contract` | Pass: first, middle, and final update/import failures leave contents, labels, deletion candidates, volume UUID, sorting/filtering, notifications, and sync pushes unchanged. |
| `failed-scan-retry-contract` | Pass: one event plus persistent retry converges after more snapshot failures than the reader's immediate retry; stopping notifications cancels the retry. |
| `catalog-fence-contract` | Pass: a catalog mutation between preparation and the final pass discards the complete transaction and converges on retry. |
| `directory-fence-modes` | Pass: ordinary and stream-reconfiguration-retry scans perform exactly two catalog reads; a failed root-watch rebuild remains pending until the retry succeeds. |
| `unsaved-write-recovery-contract` | Pass: failed file and journal sinks remain independently pending; accepted sinks are not repeated. |
| `file-outbox-crash-recovery` | Pass: WAL success plus note-file failure survives `_exit`, recovers memory, and rewrites the separate file before stale import. |
| `atomic-rollback` | Pass: preparation, xattr, verification, and replacement failures preserve the installed file; export overwrite/non-overwrite uses the same helper. Replacement and same-vnode content mutations injected after note installation cannot be adopted as the completed write's metadata: that write remains pending and the retry installs memory. Export success is not revoked by best-effort post-install Cocoa mirroring. |
| `snapshot-stress` | Pass: 1,587 coherent APFS safe-save snapshots, 754 retryable rejections, zero mixed versions. |
| `snapshot-in-place-observation` | Observed 1,358 coherent snapshots, 2,180 mixed tuples, and 5 rejected reads for a writer using separate same-vnode data/encoding/tag syscalls. This is outside the supported atomic-safe-save contract. |
| `bulk-parser-fuzz` | Pass: 50,000 deterministic mutations plus every truncated length against a guard page. |
| `partial-bulk-fallback` | Pass end to end: unsupported, malformed, invalid-UTF-8, and persistent-`ENOENT` failures discard all partial bulk entries before fallback or failure. |
| `bulk-parser` | Pass: generation present/zero, optional and unknown returned attributes, per-entry errors, missing mandatory fields, overlap, embedded NUL, invalid UTF-8, truncation, and maximum offset/length values. |
| `snapshot-boundary-races` | Pass: replacement exactly at the final `fstatat` and Cocoa-tag mutation between lookup and descriptor validation reject the first attempt and return one coherent retry. |
| `xattr-interoperability` | Pass: XML/binary tags, color/Unicode values, missing/empty tags, and unusual/malformed/resized TextEncoding values. |
| `system-tag-producer` | Pass: external `NSURLTagNamesKey` additions and clears override stale OpenMeta; OpenMeta-only changes are ignored while Finder is readable. Injected Finder read and write failures verify OpenMeta fallback and nonfatal mirroring, while exact OpenMeta persistence remains required. |
| `ambiguity-stress` | Pass: 1:2, 2:1, multiple-empty, hard-link, case-only, and Unicode-normalization groups do not guess identity. |
| `resource-lifecycle` / `make -C tests leak-check` | Pass: eight failed prepared transactions are discarded, their detached notes deallocate, controllers tear down with retry/change timers, buffered WAL bytes, and both outbox obligations pending, and the open-FD count returns to baseline after every cycle. Native `leaks` reports 0 leaked bytes. |
| `directory-relocation-races` | Pass: an atomic install follows the open directory FD when the directory moves after temporary-file preparation; a move between catalog passes commits through the unchanged FD and the queued root event rebuilds the path-based watch and rescans; over 650 root-relative note renames completed per run while a child performed 500 parent-directory renames. |

Warm benchmark medians on the reference APFS machine:

| Directory | Bulk enumeration | Full unchanged transaction |
|---|---:|---:|
| 1,000 files | 0.625 ms | 2.254 ms |
| 10,000 files | 9.006 ms | 33.868 ms |

The bulk performance gates remain below 1.2 ms/1,000 and 14 ms/10,000. An
initial full-scan result of 450.098 ms/10,000 exposed an O(n²) array membership
check; changing the transaction's verified-note collection to a set produced
the result above.

`make -C tests stress` passes. The disposable 192 MiB image matrix passes all
required checks:

| Image/scenario | Result |
|---|---|
| APFS | Bulk enumeration, xattrs, session file IDs, generation counts, reconciliation, coherent safe-save snapshots, two-store tag synchronization, WAL crash recovery, ENOSPC recovery, forced live detach, and bookmark remount pass. Fresh files return document ID zero through Darwin and Foundation. |
| Case-sensitive APFS | Capabilities, metadata, reconciliation, coherent safe-save snapshots, and case-policy behavior pass. |
| Journaled HFS+ and case-sensitive Journaled HFS+ | The full capability, metadata, reconciliation, and coherent safe-save suites pass. Only the focused immediate same-vnode `coarse-ctime-observation` is non-gating and demonstrates the accepted whole-second detection degradation. Safe-save renames still use the changed session file ID. |
| ExFAT | Bulk enumeration, xattrs, and file IDs pass; document ID and generation count are unavailable as expected. |
| APFS ENOSPC | Pass: the first flush leaves failed obligations pending; after space is released, the next flush installs current note content and checkpoints. |
| APFS forced live detach | Pass: with controller and note descriptors open, snapshot, scan, WAL, and note write fail without changing memory or retiring the file obligation; bookmark remount finds the unchanged durable file. |
| WAL process death | Pass: a journal-only edit survives abrupt child exit and recovery. |

The Deployment target compiles and links with `CODE_SIGNING_ALLOWED=NO`, and
`build.sh` completes successfully on the reference machine. Remaining output is
limited to existing linker, app-category, Sparkle-stripping, and headermap
warnings.

## Outstanding work

### 1. P2 — Finish filesystem/provider diversity

- [ ] Run on representative SMB and NFS servers, including provider latency,
  coarse/optional metadata, reconnects, and server-side safe-save behavior.
- [ ] Detach a real removable device while a controller and snapshot descriptor
  are live.
- [ ] Exercise real Finder and iCloud Drive producers, including color tags,
  evicted/provider placeholders, and provider safe saves.
- [ ] Exercise reused session file IDs and power-loss durability. Disk images
  model capacity, format, remount, relocation, and process death, but not these
  coordination failures.

### 2. P3 — Preserve platform-service test classification

`make -C tests run-core` is the deterministic, sandbox-safe correctness gate.
`make -C tests run-platform` contains Stickies/RTFD, AppKit HTML, Trash, and live
FSEvents integration and passes in an unrestricted login session. Keep new
platform-service tests in that target so sandbox denial is not mistaken for a
filesystem regression.

## Accepted behavior limits

- Atomic safe-save/replacement is the supported cross-process write contract.
  A stable intermediate state produced by separate same-vnode content and xattr
  syscalls is indistinguishable from a completed version; no settling heuristic
  is added.
- APFS is primary. On HFS+, a same-vnode edit inside one coarse ctime second may
  be observed late or on the next event. A changed session file ID still catches
  same-second safe-save replacement.
- Case-insensitive filename semantics remain intentional even on case-sensitive
  volumes. A case-only collision cancels the scan and waits for a new event or
  user action.

## Resolved issue checklist

1. **Failed scan retry (P1):** implemented one retained, coalesced main-run-loop
   timer with capped delay and independent scan/write flags.
2. **Concurrent snapshot coherence (P1):** stable single-FD snapshots and real
   safe-save stress pass; unsupported same-vnode multi-syscall writes are
   documented above.
3. **Scan transaction scope (P1):** the entire scan commits atomically; all
   listed model and publication side effects are asserted unchanged on failure.
4. **Unsaved-memory-wins write failure (P1):** split durable obligations,
   permission/atomic/ENOSPC tests, and WAL relaunch recovery pass.
5. **Rename ambiguity (P2):** document ID, zero-document-ID/session-ID, volume
   mismatch, 1:1 content, cardinality ambiguity, empty, hard-link, case, Unicode,
   and preflight-to-fence mutation paths are covered.
6. **Filesystem metadata matrix (P2):** APFS/APFSX/HFS+/HFSX/ExFAT and
   detach/remount coverage is automated; external device/server cases remain in
   outstanding item 1. A forced APFS detach now also covers live controller and
   note descriptors, pending writes, and bookmark remount recovery.
7. **Bulk recovery/parser (P2):** unsupported partial-result fallback and parser
   fuzzing pass; caller-level malformed, invalid-name, and persistent-churn
   failures now prove no partial catalog is published.
8. **Extended attributes (P2):** synthetic interoperability, concurrent stress,
   missing versus empty, and cross-process Cocoa tags pass; real Finder/iCloud
   remain in outstanding item 1. All app-controlled note/tag/export writes now
   mirror OpenMeta and `NSURLTagNamesKey` wherever the provider supports Cocoa
   tags.
9. **Failed note writes (P1):** no collection is cleared wholesale; each sink
   retires only its accepted obligation, and checkpointing waits for durability.
10. **In-place snapshot limit (P1):** resolved by the explicit atomic-safe-save
    policy rather than an unreliable settling delay.
11. **Coarse ctime (P1):** changed nonzero file ID forces a snapshot; remaining
    HFS+ same-vnode behavior is an accepted degradation.
12. **Finder-preferred tags (P2):** implemented an identity-validated Finder read
    on every coherent snapshot, with OpenMeta fallback only when the Finder value
    is unavailable or invalid; content remains FD-authoritative.
13. **FSEvents transaction fence (P1):** rejected after an unrestricted
    external-child probe on macOS 26.6.1 showed that `FSEventStreamFlushSync`
    can return before an already-fsynced mutation is delivered, even with a
    private callback queue. Removed the flush, atomics, private queue, and
    historical-stream proposal. Exact two-pass catalog equality is the sole
    commit fence; main-queue FSEvents only schedules later reconciliation and
    root-watch repair.
14. **Descriptor-boundary races (P2):** deterministic seams now replace the
    directory name at the final snapshot identity lookup and mutate Cocoa tags
    between lookup and descriptor validation. Both force a coherent retry. The
    note writer also carries metadata from its installed descriptor through tag
    synchronization instead of reopening by name; an injected replacement keeps
    the file obligation pending rather than being recorded as the completed
    write. A same-size, preserved-mtime edit during tag synchronization is also
    rejected by an exact content/revision bracket. Export metadata failures occur
    before installation, while Cocoa tag mirroring remains best-effort afterward.

`ATTR_CMN_GEN_COUNT` is retained as an unarchived revision/invalidation token in
bulk records, snapshots, and exact catalog tokens. Testing showed that ordinary
APFS edits change it, so it must not qualify file-ID rename matches or be treated
as an inode-incarnation identifier. True reused file-ID behavior remains in
outstanding item 1. Encoding reinterpretation rejects a nonzero expected/current
generation mismatch and treats zero as unavailable. Because its own xattr update
changes the counter, the post-write fence starts after that update and combines
generation/ctime stability with an exact comparison to the prepared content.

## Lifecycle audit results

- [x] Detached construction never registers delegates, labels, previews,
  filenames, notifications, or writes. Simplenote merge candidates cannot create
  ghost labels.
- [x] `setDelegate:nil` clears the non-retained pointer; attachment side effects
  live only in the controller gateway.
- [x] Encoding reinterpretation prepares and validates first; denied xattr or
  decode failure leaves live content, encoding, xattr, notifications, and sync
  state unchanged.
- [x] Failable `NoteObject`, import, URL/pasteboard, Blor, and Simplenote
  constructors/callers are checked.
- [x] MRC initializer failure paths release `self`; fallback titles/labels own
  their values; same-title and label-update temporaries are balanced.
- [x] WAL initializer failures release descriptors/controllers, failed
  compression setup removes its newly created empty journal, and zlib state is
  finalized on deallocation.
- [x] External imports, database load, WAL recovery, Simplenote insertion, and
  newly created notes use the single attachment gateway.
- [x] `updateFromNoteFileNamed:`, duplicate content-fallback reads, per-note scan
  deletion updates, selector-cancellation scheduling, and unconditional pending
  write clearing are removed.

Additional refactor findings fixed during validation:

- The exact catalog token's fixed record is packed, avoiding nondeterministic
  equality from structure padding.
- Foundation fallback skips per-entry `ENOENT` churn like the bulk parser while
  preserving all-or-nothing failure for other errors.
- WAL recovery treats clean EOF as normal instead of logging stale `errno`.
- A note-level drain can no longer clear a retry owned by failed WAL `fsync`;
  only successful WAL synchronization retires that obligation.
- Transaction verified-note membership uses a set, eliminating O(n²) unchanged
  scans.
- Failed shutdown flushes used to leave a retained retry timer targeting the
  controller, preventing teardown indefinitely. Shutdown now retires scheduling
  (without pretending the durable obligations succeeded) before deallocation.
- The controller did not release its WAL writer, leaving one directory-backed
  descriptor per failed lifecycle.
- `NoteObject` omitted its owned content and sync metadata, the controller
  omitted search/stat buffers, `FastListDataSource` omitted its realloc buffer,
  `NotationPrefs` omitted crypto material, and `TemporaryFileCachePreparer`
  omitted all owned preparation state. The native leak gate exposed and now
  covers these MRC ownership failures.
- An active `NVDirectoryTransaction` exists only within the synchronous
  main-thread scan call, so normal controller destruction cannot overlap it.
  The lifecycle test instead proves the meaningful boundary: an actual prepared
  transaction fails, releases its detached state, leaves its retry scheduled,
  and the controller then tears down with every asynchronous write obligation
  still pending.
