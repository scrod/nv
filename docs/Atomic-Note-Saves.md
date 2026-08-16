# Atomic Note Saves

This document describes the current save contract for notes stored as individual
plain-text, RTF, or HTML files. It is written for readers who do not yet know the
codebase. The serialized single-database format has a different persistence path,
although its database file uses part of the same low-level writer.

The implementation is mainly in
[`NoteObject.m`](../NoteObject.m) and
[`NotationFileManager.m`](../NotationFileManager.m). The integration scenarios
that define the contract are in
[`tests/NVIntegrationTest.m`](../tests/NVIntegrationTest.m).

## What “atomic” means here

For a normal save on APFS or HFS+, readers should see a complete old byte stream
or a complete new byte stream, not a partially written mixture. APFS installs
the prepared bytes and metadata with one filesystem namespace operation. HFS+
atomically exchanges the bytes, then immediately finalizes the prepared metadata.

Atomic installation is only one part of the contract:

- `NoteObject` first reads a coherent snapshot and merges or preserves external
  edits.
- The file writer stages and installs the replacement according to the
  filesystem's capabilities.
- The installed file descriptor is checked against the destination name so a
  concurrent replacement is not mistaken for this save.
- A failed save normally remains a pending file-write obligation and is retried;
  unsaved memory is not discarded.

“Atomic” does **not** mean that every supported filesystem offers the same
guarantees, that the app locks out other writers, or that note content, Finder
services, the WAL, and the database form one filesystem transaction. The exact
limits are documented below.

### Small glossary

- A **destination** is the filename the user recognizes, such as `Ideas.txt`.
- A **staged** or **temporary** file is the hidden `.nv-write-<UUID>` file built
  before installation.
- A **file descriptor** is the process's open handle to a file. It continues to
  identify that file even if a directory entry is renamed.
- A **vnode** is the filesystem object identified by a descriptor. A filename is
  only a directory entry that currently points to one.
- The **displaced file** is the previous destination left at the temporary name
  by swap or exchange.
- A **safe-save** writes a separate complete file and atomically replaces the
  directory entry instead of modifying the old file in place.

## The functions and how they fit together

The normal path is:

1. `-[NoteObject writeUsingCurrentFileFormat]` serializes the in-memory note,
   reads the current disk snapshot, and resolves external edits.
2. `-[NotationController storeNoteDataAtomically:...]` supplies the note bytes,
   encoding, tags, dates, and the snapshot's bytes as `expectedData`.
3. `NVStoreDataAtomicallyAtDirectoryFileDescriptor` coordinates staging,
   installation, identity validation, cleanup, and descriptor handoff.
4. `NVPrepareAtomicStore` writes and verifies a hidden `.nv-write-<UUID>` file,
   preserves applicable destination metadata, applies note metadata, and
   `fsync`s the staged descriptor.
5. Exactly one installer runs:
   `NVInstallNewAtomicFile` for a destination observed as absent, or
   `NVInstallAtomicReplacement` for a destination observed as present.
6. `NVInspectInstalledAtomicFile` proves that the retained descriptor is still
   the file named by the destination and obtains `NVFileInfo` from that same
   descriptor.
7. The note-specific wrapper mirrors Finder tags, restores the authoritative
   OpenMeta tag xattr, flushes it, rechecks content/revision stability, and
   returns the installed file information to `NoteObject`.

The smaller entry points intentionally reuse this coordinator:

| Entry point | Meaning |
|---|---|
| `storeNoteDataAtomically:...expectedData:...` | Full separate-note save, including encoding, tags, dates, installed-descriptor validation, and file information. |
| `storeDataAtomicallyInNotesDirectory:...` | Unconditional data replacement with optional staged read-back verification; used for the serialized database and tests. |
| `createDataAtomicallyInNotesDirectory:...` | Create-only installation; an existing destination is never intentionally overwritten. |
| `NVReplaceDataAtomicallyAtDirectoryFileDescriptor` | Data-only conditional replacement; used by external-editing scratch files. |

Title-driven filename changes, directory reconciliation, exports, and the WAL
are adjacent systems, not phases inside this atomic writer.

## Note-level behavior before the file write

### Serialization

- Plain text is encoded with the note's selected encoding. Text that cannot be
  represented promotes the note to UTF-8 rather than losing characters.
- RTF and HTML are serialized as rich document data. A serialization failure
  stops before the destination is touched.
- The single-database format should never call the individual-note writer.

Storage-format changes first flush pending writes and reconcile the directory
while the source format is still active. File-to-file conversion then renames
each clean source and installs the in-memory note with unconditional replacement.
Database-to-file conversion additionally checks an existing destination: equal
plain text causes no conflict, while different plain text or rich-format bytes
are moved verbatim to a conflict note before the database note is installed.
Same-format writes continue to use the snapshot and conflict rules below.

### Coherent disk snapshot

The snapshot reader opens the destination once and reads bytes, text-encoding
xattr, fallback OpenMeta tags, and file information through that descriptor. In
the same metadata bracket it requests `NSURLTagNamesKey`; a successful value
(with Foundation's nil "no tags" result treated as an empty array) is preferred
after the URL is proven to identify the opened descriptor. An unavailable or
invalid Finder value falls back to OpenMeta. A URL identity mismatch or another
changing-file observation returns `EAGAIN`; one immediate retry handles an
ordinary external safe-save without blocking.

A generation count strengthens the revision comparison when the filesystem
provides a nonzero value. Zero means “unavailable” and is ignored. When Finder
returns a valid value, differing or malformed OpenMeta data is ignored for that
snapshot. Filesystems with unreliable Finder resource values may therefore
degrade between Finder and OpenMeta precedence without weakening identity checks.

### External edits and conflicts

If the destination exists, the snapshot is compared with the note's merge base:

- Plain text and labels use a three-way merge: starting value, local value, and
  external value. Non-overlapping text edits can be combined.
- RTF and HTML are not structurally merged. If both serialized versions changed,
  the external version is preserved as a separate conflict note rather than
  guessing how to combine formatting.
- An unmergeable label change also causes conflict preservation.
- Conflict notes keep the external bytes, dates, encoding, and tags under an
  exclusive unique filename ending in `(conflict)` plus any required suffix.

After this decision, `expectedData` means “the destination must still contain
the exact bytes in the snapshot.” It compares the entire byte sequence, not a
hash. It does not compare tags, dates, or other metadata.

`nil` `expectedData` means unconditional replacement, not “the destination must
be absent.” If the coordinator observes the destination as absent it still uses
an exclusive create path. If another process creates the destination before
that initial existence check, however, the operation is treated as an
unconditional replacement. Callers that require strict absence must use the
create-only entry point.

## Common staging behavior

The coordinator validates both destination and temporary names as single leaf
filenames. Empty names, `.`, `..`, names containing `/`, and unrepresentable or
overlong filesystem names fail before installation. All normal operations are
relative to the already-open notes-directory descriptor, so they do not escape
the directory and continue to address that directory if an ancestor is renamed.

The data and, for a full note save, the `resultingFileInfo` output pointer must
be non-null. Callers must supply tags as an array of strings, and a requested
text encoding must have a valid filesystem attribute representation. Empty data
is a valid file. Null data/output and invalid filenames or encodings fail before
installation.

The temporary file is created with `O_EXCL`, `O_NOFOLLOW`, close-on-exec, and
mode `0600`. The writer then:

1. writes every byte, handling short writes and `EINTR`;
2. optionally reads the staged bytes back and runs the caller's verification;
3. opens the destination without following symlinks;
4. enforces create-only and initial `expectedData` checks;
5. for a replacement, copies portable destination metadata such as permissions
   and custom xattrs to the staged file while keeping the staged timestamps under
   the caller's control;
6. runs the preparation block, which sets note encoding, exact OpenMeta tag data,
   creation date, and modification date; and
7. `fsync`s the staged descriptor.

Any failure in this phase leaves the destination unchanged and normally removes
the hidden temporary file. Existing permissions and unrelated custom xattrs are
preserved across successful replacements; note-controlled encoding, tags, and
dates are deliberately updated.

## Filesystem capability tiers

Installation follows filesystem capability, not a guessed filesystem name.
Only `ENOTSUP` and `EINVAL` mean that swap or exchange is unavailable. Other
errors are operational failures and stop the save. The create path also treats
`EPERM` from hard-link creation as lack of that capability.

| Situation | APFS / APFSX | HFS+ / HFSX | ExFAT and similarly limited filesystems |
|---|---|---|---|
| Destination absent | Exclusive rename (`RENAME_EXCL`). | Exclusive rename, or hard-link plus unlink when needed. | Visible `O_CREAT | O_EXCL` file populated as a last resort. |
| Existing, unconditional replacement | Atomic `RENAME_SWAP`, then remove the displaced file. | Ordinary atomic rename after swap reports unsupported. | Ordinary atomic rename after swap reports unsupported. |
| Existing, conditional replacement | Atomic `RENAME_SWAP`; inspect the atomically displaced bytes. | Atomic `exchangedata()`; finalize prepared metadata and inspect displaced bytes. | Re-read expected bytes immediately before ordinary atomic rename. |
| Concurrent-writer guarantee | Displaced content can be compared and recovered without losing either version. | Displaced content can be compared and recovered without losing either version. | Best effort; a writer can win after the last check and still be overwritten. |

APFSX and HFSX use the same installation primitives as their case-insensitive
variants. Their filename-policy differences are described later.

### APFS conditional replacement

`RENAME_SWAP` atomically makes the staged file the destination and moves the old
destination to the temporary name. The writer then reads the displaced file:

- If its bytes equal `expectedData`, it is the version already considered by
  `NoteObject` and is removed.
- If they differ, another writer won the race. The local replacement remains
  installed, while the displaced external version is moved to a unique visible
  `(<conflict recovery UUID>)` filename. The call returns
  `NVNoteStorageAtomicRecoveryError` so the controller knows that the local
  content was installed but reconciliation is required.

This is a recoverable compare-after-swap, not a lock. A conflict can therefore
change the destination even though the API returns `NO`; the important guarantee
is that neither set of bytes is silently discarded.

### HFS+ conditional replacement

When swap is unsupported, HFS+ uses `exchangedata()`. This atomically exchanges
the data while open descriptors follow the exchanged content. It has two extra
steps:

1. reopen the installed destination and prove that it is the prepared content's
   vnode and still matches the destination name; and
2. copy the already-prepared metadata to that installed vnode, restore the exact
   prepared creation/modification dates, and `fsync` it.

The old destination remains at the temporary name and uses the same expected-byte
comparison and recovery helper as APFS.

HFS+ content becomes visible at `exchangedata()` before metadata finalization is
complete. A concurrent reader can briefly observe new bytes with not-yet-final
metadata. If metadata finalization fails while the replacement is still proven
installed, the old destination is recovered and the call returns
`NVNoteStorageAtomicRecoveryError`. If the destination was removed or replaced
after exchange, the old destination is still recovered but the call returns
`EAGAIN`, keeping the local in-memory write pending for retry. A racing writer's
vnode is never accepted as the completed local write.

`exchangedata()` requires paths, so this compatibility helper briefly resolves
the open directory descriptor with `F_GETPATH`. A path-resolution, path-length,
or operational exchange failure fails closed; it does not fall through to an
ordinary rename. Only a genuine unsupported-capability error permits the
limited-filesystem fallback.

### ExFAT and limited filesystems

ExFAT is supported for basic use, not first-class multi-writer safe saving.

For conditional replacement, the staged file is complete and flushed before it
is visible. The writer reopens the destination, compares all bytes with
`expectedData`, and performs an atomic rename if they match. A replacement,
deletion, or creation between that check and the rename remains an accepted race.

For create-only installation, ExFAT provides neither exclusive rename nor hard
links. The fallback creates the final destination with `O_EXCL`, then writes,
prepares, and flushes it. Consequences:

- readers may see an empty, partial, or not-yet-prepared file;
- the preparation block runs twice—once on the hidden staged file and once on
  the visible fallback—so it must be descriptor-local and safe to repeat;
- staged read-back verification is not repeated after the visible copy; and
- failed cleanup unlinks the visible file only after proving that its name still
  identifies the descriptor created by this operation.

That identity check prevents cleanup from deleting a concurrent replacement
that already won the name. ExFAT has no atomic compare-and-unlink primitive, so
a final race remains between the identity check and `unlinkat`. Closing that
last race would require a stronger filesystem primitive, not another path check.

## Installed-file metadata and identity

The full note writer keeps an installed descriptor open across installation and
post-install work. HFS+ reopens the destination only for its descriptor handoff;
that reopened handle is never accepted without an identity proof. Device/inode
equality proves that the retained descriptor and destination name still identify
the same vnode.

The authoritative note metadata is:

- `com.apple.TextEncoding` for plain-text encoding;
- `com.apple.metadata:kMDItemOMUserTags` for the exact OpenMeta tag plist,
  including color suffixes and a present-empty array when the note has no tags;
- creation and modification dates; and
- the retained portable metadata copied from the previous destination.

Finder's `NSURLTagNamesKey` is a separate provider-facing interface. The writer
mirrors semantic tag names there first, then restores the exact OpenMeta plist on
the descriptor. Finder-tag mirroring and extension hiding are best effort because
some providers do not support them. Failure of either does not revoke an
otherwise valid save. Failure to write or flush the authoritative descriptor
xattr does fail the save. When Finder tags are unavailable, snapshot reads
preserve the distinction between an absent OpenMeta xattr and a present-empty one.

After tag synchronization, the writer checks the descriptor's revision before
and after an exact content read, then proves the destination name still identifies
that descriptor. This prevents a same-size, preserved-mtime mutation or a
path-level replacement from being recorded as this save. `resultingFileInfo` is
read from that verified descriptor and becomes the note's new disk identity.

An ordinary error during this post-install phase can occur after new content has
become visible. The call still returns `NO`, the file-write obligation stays
pending, and a retry re-snapshots and reconciles the actual disk state. Callers
must not interpret every `NO` as “the destination was unchanged.”

## Error and recovery meanings

| Result | Meaning to the caller | Pending-write behavior |
|---|---|---|
| `YES` | The requested installation and required descriptor checks completed. | The note's file obligation may be retired. |
| `NSFileWriteFileExistsError` | A create-only operation found an existing destination. | Keep or report the attempted write; existing bytes remain. |
| POSIX `EAGAIN` | Expected bytes did not match, the expected destination vanished, or installed identity was lost. | Keep the local write pending and retry after re-snapshot/merge. |
| `NVNoteStorageAtomicRecoveryError` | The local replacement is proven installed, but displaced content had to be recovered or HFS+ post-exchange finalization failed. | Retire this exact write, alert, and schedule directory reconciliation. |
| Other Cocoa/POSIX/OSStatus error | Preparation, verification, metadata, sync, capability operation, capacity, permission, or I/O failure. | Normally keep the local write pending. |

Recovery files use an exclusive name shaped like
`Title (conflict recovery <UUID>).ext`. If that visible rename fails, the
displaced file remains under its hidden `.nv-write-<UUID>` name for emergency
recovery, and normal failure cleanup deliberately leaves it alone. Failure to
remove a displaced file whose bytes were already expected is logged but does not
turn an otherwise completed save into failure; this can also leave a hidden
stale file.

## Naming, case, and file-type edge cases

- Destination symlinks are not followed. Preexisting symlink, directory, device,
  FIFO, and other non-regular targets fail rather than being read as note
  content; a target substituted during installation is handled as a race and is
  either preserved by swap recovery or causes a fail-closed error.
- All namespace operations use leaf names relative to the notes-directory
  descriptor. A supplied path cannot redirect the writer outside that directory.
- New files start at mode `0600`. Successful replacement preserves tested
  destination permissions and custom xattrs before applying note-owned metadata.
- Rename/swap safe-saves replace one directory entry; another hard link to the
  old vnode continues to refer to that old vnode. HFS+ exchange operates on file
  data instead. Hard-linked note names are outside the app's unambiguous ownership
  model, and directory reconciliation deliberately refuses to guess their
  identity.
- The app intentionally maintains one case-insensitive logical filename
  namespace even on APFSX/HFSX. Filename selection scans for case-only siblings;
  a same-note case-only rename is allowed, while untracked case-only targets force
  a suffix. Two physical case-colliding files make reconciliation fail atomically
  without mutating the note model.
- The case-folding preflight is best effort against an external creator because
  macOS exposes no case-insensitive exclusive-create primitive on a case-sensitive
  volume. A new directory event and reconciliation handle later discoveries.

## Durability and coordination limits

- File descriptors are `fsync`ed before successful completion of their required
  phase. The coordinator also attempts to `fsync` the directory after install,
  but currently treats directory-sync failure as best effort. This contract has
  process-death and remount coverage, not a power-loss proof for every filesystem.
- Atomic safe-save is the supported cross-process producer contract. A third
  party that rewrites content and xattrs through separate syscalls on the same
  vnode can expose a stable intermediate combination indistinguishable from its
  final version. The app deliberately has no settling-delay heuristic.
- `expectedData` protects bytes only. A metadata-only external edit made after
  the snapshot but before installation is not an installation conflict and may
  be replaced by the note's prepared metadata.
- APFS and HFS+ preserve racing bytes through swap/exchange recovery. ExFAT can
  silently overwrite a writer in its documented last-check-to-rename window.
- SMB, NFS, iCloud/provider latency, real removable-device loss, reused file IDs,
  and true power loss remain outside the automated disk-image matrix. Unknown
  filesystems descend the same capability ladder and fail closed on operational
  errors.
- The WAL and `pendingFileWrites` protect unsaved memory independently of the
  note-file operation. A failed file write is not cleared merely because another
  sink succeeded, and a database checkpoint waits for outstanding file and WAL
  obligations. Crash recovery queues recovered separate-file notes for rewrite
  before directory reconciliation can import stale disk bytes.

## Tests that define the contract

The most relevant integration scenarios are:

| Scenario | Coverage |
|---|---|
| `atomic-rollback` | Create-only refusal, conditional mismatch/success, metadata preservation, preparation/read-back failures, conflict recovery, post-install identity races, and temporary-file cleanup. |
| `atomic-replacement-capabilities` | APFS swap, HFS+ exchange and descriptor handoff, operational exchange failure, post-exchange races/finalization, ExFAT best-effort replacement, visible create fallback, and identity-aware cleanup. |
| `snapshot-boundary-races`, `snapshot-stress` | Coherent single-descriptor reads and safe-save races. |
| `snapshot-in-place-observation` | Documents the unsupported same-vnode multi-syscall producer limit. |
| `filename-collisions`, `case-sensitive-filename-collisions` | Logical case-insensitive naming, APFSX/HFSX behavior, and atomic rejection of physical case collisions. |
| `unsaved-write-recovery-contract`, `file-outbox-crash-recovery`, `disk-full-recovery-contract` | Pending-write retention, WAL recovery, ENOSPC, and retry convergence. |
| `directory-relocation-races` | Descriptor-relative installation while the notes directory or its ancestors move. |

Run the host scenario and the real filesystem capability matrix with:

```sh
make -C tests /tmp/notation-integration-tests/NVIntegrationTest
/tmp/notation-integration-tests/NVIntegrationTest atomic-rollback
make -C tests filesystem-image-stress
```

The disk-image matrix is essential for this code: APFS behavior on the host does
not exercise HFS+ `exchangedata()` or ExFAT's limited fallbacks.
