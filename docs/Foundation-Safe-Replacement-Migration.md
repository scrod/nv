# Foundation safe-replacement migration

Status: implementation migration plan; behavior remains governed by [Atomic Note Saves](Atomic-Note-Saves.md) and [Robust iCloud Drive Support](iCloud-Drive-Support-Spec.md), while empirical provider requirements remain tracked in [Apple API Contract Validation](Apple-API-Contract-Validation.md)

## Decision and intended result

Migrate replacement of an existing regular file to one Foundation safe-save backend built around `-[NSFileManager replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:]` after the acceptance gates preserve the current contract. Keep `NVRootedDirectory`'s descriptor-based safety envelope and its three explicit public intents: exclusive creation, conditional replacement, and unconditional replacement. Checkpoint replacement adopts the backend first; unconditional and conditional note-file replacement follow after their behavior tests pass.

If every deletion gate below passes, this removes the APFS `RENAME_SWAP`, HFS+ `exchangedata()`, and limited-filesystem ordinary-rename implementations used for existing destinations. It does not replace:

- the open rooted-directory descriptor or bookmark;
- coherent descriptor-based snapshots;
- exclusive creation of an absent destination;
- identity-checked rename, removal, cataloging, and directory synchronization;
- exact post-install descriptor and byte verification; or
- `NoteObject`'s merge and conflict policy.

The steady state therefore has two namespace installation mechanisms, selected by intent rather than filesystem-name guessing:

1. the existing exclusive-create capability ladder for an absent name; and
2. Foundation safe replacement for an existing regular file.

There is no production `NSDataWritingAtomic` branch and no permanent parallel provider-only replacement implementation. A filesystem or provider that cannot establish the Foundation replacement contract retains the current implementation until support is deliberately narrowed or another safe backend is specified.

## Why the migration is plausible

Apple defines [`replaceItemAtURL:`](https://developer.apple.com/documentation/foundation/filemanager/replaceitem%28at%3Awithitemat%3Abackupitemname%3Aoptions%3Aresultingitemurl%3A%29) as its non-`NSDocument` safe-save primitive, recommends an OS-provided same-volume replacement directory, and permits a retained backup of the original item. Focused iCloud tests on macOS 14.8.9 and 26.6.1 established the narrower provider contract needed by NV:

- a file-reference URL is accepted as the existing destination;
- replacement preserves opaque File Provider item/domain identity;
- exact-version upload and resume remain operable after replacement;
- the old file-reference URL becomes invalid because it identifies the displaced filesystem object;
- Foundation returns a pathname URL;
- a fresh reference can be generated from a newly constructed canonical pathname URL;
- concurrent uncoordinated readers observed only complete old or new byte streams across repeated replacements;
- `NSFileManagerItemReplacementWithoutDeletingBackupItem` retained the exact displaced bytes; and
- the tested custom xattr survived options-`0` replacement.

The focused test also demonstrated that reconstructing the URL is mandatory, not stylistic: asking for the next replacement directory through URL state retained from before the previous replacement failed before coordination. Each replacement attempt must therefore start with a newly constructed canonical pathname URL and derive a fresh operation-local file-reference URL from it. Metadata finalization remains required because one xattr on two tested OS releases does not establish all note-owned metadata and date behavior.

Production code must not depend on that pathname result. It reopens and verifies the destination relative to the rooted-directory descriptor, then generates any later operation-local file-reference URL from the rooted directory and leaf name. The returned URL and `NSFileOriginalItemLocationKey`, when present on error, are candidate evidence only.

## Target transaction

The migration remains inside `NVRootedDirectory` so callers continue receiving one `NVFileWriteResult` and never need to understand Foundation replacement details.

### 1. Admission and initial snapshot

On the root session's serial provider lane:

1. Validate the destination as one filesystem leaf. Reject empty names, `.`, `..`, separators, unrepresentable names, and overlong leaf names exactly as today.
2. Open the destination relative to the rooted-directory descriptor with `O_NOFOLLOW` and require a regular file.
3. Capture the coherent destination snapshot and retained descriptor required by the requested intent.
4. For conditional replacement, perform the existing initial exact-byte comparison with `expectedData`. Metadata-only differences remain outside the conflict predicate.
5. Create one operation-local destination file-reference URL and prove that it still identifies the opened destination before giving it to Foundation.

The initial check is an optimization and early failure boundary, not the final conditional-write decision. The displaced file remains the authoritative race witness.

Checkpoint replacement has a distinct mandatory precondition supplied by `NVCheckpointTransaction`: expected absence for creation, or one exact checkpoint-current witness captured in a single coordinated accessor—complete bytes, the existing `NVFileObservation`, and the current local `NSFileVersion.persistentIdentifier` when available. Recheck every captured component inside the coordinated accessor immediately before namespace mutation. A mismatch returns `NVCheckpointInstallCurrentChanged` without invoking Foundation replacement; it does not use the note writer's install-then-preserve conditional path. The typed result returns the same coherent witness to the checkpoint caller for the specification's complete-note-set/base-relative-deletion reconciliation. Failure to capture that snapshot remains a no-write failure and never weakens the replacement precondition. The persistent identifier is supplemental: macOS 14 and 26 contract probes kept it equal across same-bytes Foundation replacement while `NVFileObservation` changed.

### 2. Staging

Ask `NSFileManager` for `NSItemReplacementDirectory` appropriate for the destination so the staged item is on the same volume. Open that directory once and create one uniquely named stage with `O_EXCL`, `O_NOFOLLOW`, close-on-exec, and mode `0600`.

Reuse the existing descriptor helpers to:

1. write all bytes with short-write and `EINTR` handling;
2. run any prepared-data verifier;
3. preserve the destination permissions and custom metadata promised by the current contract;
4. apply note-controlled encoding, exact OpenMeta tags, creation time, and modification time;
5. perform best-effort Finder tag and extension mirroring without making those mirrors authoritative;
6. read back staged bytes when requested; and
7. synchronize the staged descriptor before installation.

The stage descriptor remains open across replacement. No notes-directory path is needed to create it, and no stage is placed in the provider-visible notes directory before installation.

Use replacement options `0` initially. The validated paused-item path preserved provider identity with that setting, and Apple documents that the default preserves selected metadata from the original item. That does not prove how NV's custom xattrs and note-owned metadata interact. Tests must establish which values survive. After replacement, reapply any authoritative note-owned metadata that Foundation did not install from the stage, restore exact requested dates, and synchronize the verified installed descriptor, as the existing HFS+ path already does.

Do not use `NSFileManagerItemReplacementUsingNewMetadataOnly` unless separate tests prove provider identity and every metadata guarantee below. Conversely, do not delete the APFS note-file backend if options `0` require post-install metadata repair that would weaken APFS's current one-namespace-operation bytes-and-metadata contract. Checkpoints have no separate-note metadata requirement and may advance independently.

### 3. Coordinated installation

Create one per-operation `NSFileCoordinator`. Coordinate the destination with `NSFileCoordinatorWritingForReplacing` and the staged source with `NSFileCoordinatorWritingForMoving`. Inside the accessor, call `replaceItemAtURL:` exactly once.

- Unconditional replacement and checkpoint installation use no backup name. Checkpoint installation nevertheless enforces its separate no-write expected-current precondition immediately before this call.
- Conditional replacement generates a fresh hidden backup leaf from the same random UUID source used for NV's other unguessable transaction identifiers. Immediately before replacement, check relative to the open root descriptor that the candidate is absent without following symlinks; if occupied, burn that UUID and generate another. Supply the accepted leaf with `NSFileManagerItemReplacementWithoutDeletingBackupItem` so the displaced destination remains available for exact comparison and recovery.

The accessor performs only local replacement. It never waits for provider upload, version enumeration, presenter settlement, or any other network-dependent operation.

### 4. Identity and exact verification

After the accessor returns:

1. Treat the old leaf file-reference URL as expired whether or not it still happens to resolve.
2. Treat Foundation's resulting URL as candidate evidence, not stored authority.
3. Reopen the destination by leaf through the rooted-directory descriptor.
4. Prove that the reopened destination and retained stage descriptor identify the same installed filesystem object.
5. Bracket an exact content read with revision observations and require the requested bytes.
6. Finalize authoritative note-owned metadata and exact dates if Foundation did not already preserve the staged values, then synchronize the verified descriptor.
7. Read authoritative xattrs, dates, and other snapshot metadata from that verified descriptor.
8. Generate a fresh operation-local file-reference URL from the rooted directory and leaf when later Foundation or provider work needs one.

A provider-managed checkpoint additionally verifies its decoded `checkpointID` and captures its exact installed local `NSFileVersion`. Provider upload status is presentation only and remains outside the coordinator accessor and replacement success predicate.

### 5. Conditional compare-after-replace

Open the retained backup by its unique leaf relative to the rooted directory and verify that it is a regular file created by this replacement transaction.

Apple documents that `replaceItemAtURL:` removes a preexisting item with the requested backup name, so NV never uses a fixed, predictable, or merely incremented backup name. The descriptor-relative absence check prevents an accidental preexisting collision, and a fresh UUIDv4 leaves no practical accidental collision window. A process deliberately able to discover and create that unseen random leaf during the call already has permission to alter or delete the notes themselves; NV does not treat the backup leaf as an additional security boundary. This is the same random-identifier uniqueness assumption already used for journals, checkpoint IDs, and recovery names, not a separate conditional-write backend or deletion gate.

- If its bytes exactly equal `expectedData`, remove it with the existing identity-checked cleanup and return ordinary installed verification.
- If its bytes differ, the local replacement remains installed and the backup is moved with the existing exclusive rename into a visible `(<conflict recovery UUID>)` file. Return `NVFileWriteInstalledNeedsReconciliation` with that recovery filename.
- If comparison, cleanup, or visible preservation fails, keep every provably owned artifact and return reconciliation-required. Never classify the write as a clean success merely because the destination contains NV's bytes.

This preserves the current recoverable compare-after-swap meaning. It is not a lock, and it does not expand support for a third party that exposes intermediate same-vnode byte/xattr combinations.

### 6. Failure classification

Foundation can fail before, during, or after moving one of the items. Reobserve all owned state before assigning a disposition:

- destination still contains the old verified object and the stage remains owned: `NVFileWriteNotInstalled`;
- destination is the verified staged object and no unresolved displaced artifact remains: `NVFileWriteInstalledVerified`;
- requested bytes are installed but the old item, backup, stage cleanup, metadata, or identity is uncertain: `NVFileWriteInstalledNeedsReconciliation`;
- installation identity cannot be established: retain candidate artifacts, fail closed, and require reconciliation.

If the error supplies `NSFileOriginalItemLocationKey`, coordinate and inspect that URL as one candidate for the displaced original. Never log it, delete it from path equality alone, or reinstall it over a destination that has not been identity-checked. Checkpoint ambiguity retains the matching host-local WAL.

After a verified namespace change, retain the existing best-effort root-directory synchronization. Checked synchronization of the separate Application Support Recovery Journals directory remains at the local WAL create/delete boundaries defined by the storage specification.

## Preservation of the Atomic Note Saves contract

| Existing contract area | Migration requirement and acceptance evidence |
| --- | --- |
| Complete old-or-new visibility | Concurrent readers on every supported filesystem observe only the complete old or complete new byte stream. A failure before installation leaves the old destination. |
| Serialization and merge policy | Unchanged. `NoteObject` still serializes, captures a merge base, performs three-way text merging, and preserves unsafe alternatives before choosing one of the same three write intents. |
| Coherent disk snapshots | Unchanged descriptor implementation. Bytes, encoding xattr, tags, dates, file information, and revision observations still come from one verified open file. |
| Expected-snapshot conflict detection | Conditional safe replacement retains and compares the displaced original exactly, then deletes it or preserves it as a recovery file. It never substitutes a hash, timestamp, provider version, or coordinator lock for `expectedData`. |
| Input and leaf validation | Existing validation and non-null/tag/encoding checks run before Foundation receives a URL. Foundation never receives a caller-controlled path component. |
| Stage ownership and cleanup | Same exclusive creation, descriptor ownership, synchronization, exact read-back, and identity-checked cleanup apply in the OS-provided same-volume replacement directory. |
| APFS/APFSX replacement | Foundation must pass atomic visibility, displaced-backup, metadata, identity, race, and cleanup tests before `RENAME_SWAP` is deleted. |
| HFS+/HFSX replacement | Foundation must pass the same tests on the disk-image matrix, including prepared-descriptor handoff and no transient partial bytes, before `exchangedata()` and its path/`PATH_MAX` shim are deleted. |
| ExFAT and limited filesystems | Foundation must be no worse than the documented current best-effort replacement contract and must preserve both byte streams for conditional replacement. The exclusive-create fallback remains unchanged. |
| Installed descriptor identity | The retained stage descriptor must follow the installed item, and a rooted reopen must identify it. A merely matching pathname, URL, size, mtime, or contents is insufficient. |
| Permissions and custom xattrs | Establish the exact behavior of options `0` and `UsingNewMetadataOnly`; preserve tested destination permissions and unrelated custom xattrs while applying note-owned metadata. No option is accepted merely because its name sounds appropriate. |
| Encoding, tags, and dates | Exact `com.apple.TextEncoding`, exact OpenMeta plist including present-empty tags, requested creation/modification dates, and descriptor synchronization remain mandatory. Finder tags and extension hiding remain best effort. |
| Write dispositions | Preserve the exact meanings of not-installed, installed-verified, and installed-needs-reconciliation, including post-install errors and retained recovery filenames. |
| Recovery artifact naming | Continue exclusive visible conflict-recovery naming. A failed visible rename leaves a hidden, owned artifact and returns reconciliation-required. |
| Symlinks and special files | Preexisting or racing symlinks, directories, devices, and FIFOs fail closed. The test must prove Foundation does not make NV follow or replace an unintended target. |
| Root containment and moves | Destination admission and final verification remain rooted-descriptor operations. File-reference URLs are operation-local adapters. Ancestor and root moves during every pre-accessor, accessor, and post-accessor boundary must retain the opened root or fail with `EAGAIN`. |
| No `PATH_MAX` ceiling | Deep-directory tests must pass without resolving the notes root to a fixed-size path. The stage's OS directory may use its own path, but destination correctness may not. |
| Hard links | Preserve the documented unsupported ownership model: replacement may detach the named entry while another hard link retains old content, and reconciliation continues refusing ambiguous hard-linked notes. |
| Case-sensitive volumes | Existing case-insensitive logical namespace, case-only rename behavior, collision suffixing, and atomic rejection of physical case collisions remain outside replacement and unchanged. |
| Durability | Stage synchronization precedes installation; post-install compatibility work is synchronized before success; directory synchronization retains its current best-effort or checked-boundary meaning. No new hardware-durability claim is made. |
| Unsupported in-place producers | No settling-delay heuristic is added. The supported cross-process producer contract remains atomic safe-save; stable intermediate same-vnode states remain indistinguishable. |
| Pending-write durability | WAL and existing `pendingFileWrites` obligations remain independent. No Foundation error or successful checkpoint clears an unverified note-file obligation. |

## Migration phases and deletion gates

Each phase is independently revertible and leaves one production path authoritative. Do not maintain a runtime preference, dual-write mode, or permanent backend selector.

### Phase 0 — Expand contract tests

Before production integration, extend the existing test harness rather than adding another runner:

- run Foundation replacement with pathname, file-reference, and root-relative regenerated references;
- retain and compare a backup for matching and conflicting conditional writes;
- inject failure before coordination, inside replacement, after installation, during backup inspection, during metadata finalization, and during cleanup;
- preserve and inspect `NSFileOriginalItemLocationKey` candidates;
- test options `0` and `NSFileManagerItemReplacementUsingNewMetadataOnly` separately, including the transient bytes/metadata visibility contract;
- verify exact bytes, descriptor identity, modes, arbitrary custom xattrs, OpenMeta present/empty tags, encoding, Finder mirrors, and exact dates;
- inject a deterministic occupied backup-name candidate and prove that NV leaves it untouched, burns the candidate, and retries with a fresh UUID leaf;
- race safe-save writers, removal, rename, symlink substitution, same-size/preserved-mtime edits, root moves, and post-install replacement;
- exercise empty data, invalid leaves, temporary-name collision, ENOSPC, permission failure, cancellation, and stale coordinator accessor URLs;
- run paths beyond `PATH_MAX` without destination path conversion;
- run APFS, APFSX, HFS+, HFSX, and ExFAT disk-image scenarios; and
- repeat paused iCloud replacement with the final staging, metadata, file-reference, and verification implementation.

The current `atomic-rollback`, `snapshot-boundary-races`, `snapshot-stress`, `snapshot-in-place-observation`, filename-collision, durability-recovery, directory-relocation, and deep-directory scenarios remain acceptance tests. Rewrite only capability-injection fixtures whose removed implementation hook no longer exists; preserve the behavior assertion they represented.

### Phase 1 — Add one private Foundation backend

Implement a private replacement helper inside `NVRootedDirectory.m` using the target transaction above. It is not yet selected by ordinary note writes. The helper returns the existing `NVFileWriteResult` shape and reuses existing descriptor write, metadata, snapshot, conflict-preservation, and cleanup helpers.

Use it first through deterministic tests and the focused API-contract app. Do not create a public installer protocol, operation class, provider adapter, or second staging subsystem.

### Phase 2 — Adopt for every checkpoint replacement

Route every checkpoint replacement through the same Foundation backend and `NVCheckpointTransaction`; no authority classification adds pause/upload controls to replacement. Every existing-file checkpoint installation at the canonical semantic boundaries—including the final-format replacement after a **Save Current Collection As…** bootstrap—routes through that transaction and therefore receives the same implementation.

At every such boundary the transaction captures expected-current evidence and the backend rechecks it inside the accessor. Appearance, disappearance, exact-byte change, `NVFileObservation` change, or available local-version change returns the typed pre-install mismatch with no replacement. Caller policy is not part of the replacement backend: the normative `CKPT-01` matrix in [Robust iCloud Drive Support](iCloud-Drive-Support-Spec.md) decides whether that caller performs complete-note-set/base-relative-deletion reconciliation, retries, cancels, preserves the predecessor, or takes an explicit override. The backend never decodes checkpoints or merges notes, preferences, or database metadata. An ambiguous possible-install result never authorizes publication or cleanup.

Checkpoint creation when `Notes & Settings` is absent remains the existing exclusive-create operation, including the complete single-database bootstrap in a newly and exclusively created **Save Current Collection As…** destination. A remembered-encrypted Save-As target provisions and validates its fresh independent Keychain item before entering this operation; an ambiguous creation result retains that item because the checkpoint may name it. Any installation ambiguity also retains the applicable host-local WAL. An exactly verified Save-As destination may retire the old host-local WAL only because its frozen checkpoint represents the old live store; no WAL is copied into the destination.

### Phase 3 — Adopt unconditional existing-file replacement

Route `overwriteFileNamed:` and `overwriteNoteFileNamed:` to Foundation only when the destination exists. Storage conversion and ordinary overwrite callers retain the same return dispositions and metadata contract. Absent destinations continue through exclusive creation.

Do not advance while any checkpoint caller has to branch around the helper to regain old semantics.

### Phase 4 — Adopt conditional note replacement

Enable retained-backup compare-after-replace for `replaceFileNamed:...expectedSnapshot:` and its note variant using the checked fresh-UUID backup-leaf rule. Run the full merge/conflict, occupied-candidate, and external-writer matrix. A matching backup must disappear through identity-checked cleanup; a differing backup must become exactly one recovery artifact and one reconciliation obligation.

### Phase 5 — Delete superseded replacement implementations

Only after every filesystem and provider gate passes with the Foundation backend selected, delete the superseded existing-destination implementation:

- the old `NVInstallReplacement` capability ladder, including its `RENAME_SWAP` call, unsupported-capability fallthrough, HFS descriptor-handoff/finalization branch, and ordinary-rename fallback dispatch;
- `NVExchangeDataForHFSCompatibility`;
- `NVCopyPreparedMetadata`, which exists only to finalize the HFS exchange result;
- `NVInstallBestEffortReplacement`;
- the exchange-only `F_GETPATH`, fixed `PATH_MAX` buffers, pathname assembly, deprecated `exchangedata()` call, `FSOPT_NOFOLLOW_ANY`/`FSOPT_UNIQUE` flags, and warning-suppression pragmas; and
- any replacement-only prepared-observation or capability-selection state left dead by those removals.

Delete the corresponding implementation-specific test surface:

- `_didRejectAtomicSwapForNoteNamed:`, `_didExchangeNoteFileNamed:`, and `_metadataFinalizationErrorAfterExchangingNoteNamed:` declarations and implementations;
- the exchange-specific `postExchangeBoundaryMutationName`, `postExchangeBoundaryReplacementData`, `postExchangeBoundaryRemovalName`, and `exchangedMetadataFailureName` fixture state and helper methods; and
- assertions whose only purpose is to distinguish APFS swap, HFS exchange, or ExFAT ordinary-rename replacement.

Do not delete the behavior those fixtures covered. Replace them with Foundation-level fault points and assertions for mutation/removal before replacement, mutation/removal immediately after installation, metadata-finalization failure, displaced-backup preservation, and each `NVFileWriteDisposition` on every supported filesystem. A pre-install removal fixture currently named around rejected swap should likewise become a generic Foundation pre-accessor/replacement fixture rather than disappearing.

Retain the exclusive-create ladder and the code it still uses: `NVInstallNewFile`, `NVAtomicPrimitiveUnavailable`, `NVRenameExclusivelyWithinDirectory`, hard-link installation, and the visible `O_EXCL` fallback. Retain `NVFileWriteCapability` and its HFS-compatible/best-effort values while those create paths still report them. Retain or adapt the common staging, descriptor snapshot/identity, metadata/date, displaced-file preservation, identity-checked cleanup, result-disposition, rooted-rename, and directory-synchronization helpers; in particular, `NVPrepareAtomicStore`, `NVPreserveDisplacedFile`, `NVFinishDisplacedFile`, and `NVRemoveTemporaryFile` still express required behavior even if their names or inputs change for the OS replacement directory and Foundation backup leaf.

Update [Atomic Note Saves](Atomic-Note-Saves.md) in the same change so it describes Foundation replacement rather than the removed implementation details. The completed production tree must have no existing-destination filesystem capability dispatch hidden behind a renamed helper.

If a required filesystem cannot pass, stop before deletion. Keeping the existing backend for that filesystem is preferable to silently weakening the contract, but any resulting capability dispatch must remain internal and evidence-based rather than a stored user preference or provider-brand branch.

## Verification and formal-model boundary

The complete migration requires:

1. `build.sh` without new warnings;
2. the complete integration suite described in [Integration Tests](IntegrationTests.md);
3. `atomic-rollback` and every filesystem-image stress configuration;
4. the focused iCloud and observational File Provider API-contract suites;
5. a macOS 26 paused checkpoint replacement using the final production adapter;
6. root-move and deep-path tests while replacement is in flight; and
7. epoch-4 checkpoint compatibility tests, because checkpoint callers move to the shared backend even though archive bytes do not change; and
8. **Save Current Collection As…** crash tests for exclusive bootstrap creation and optional final-format replacement.

This migration is intended to refine, not change, the specification or TLA+ state machines. Atomic replacement remains an environmental assumption in the models. No model change is required while all current observable guarantees and failure classifications remain intact. If Foundation cannot establish one of those guarantees and the proposed response would alter publication, preservation, checkpoint verification, journal retention, or recovery behavior, stop the migration and update the normative specification, applicable ADRs, and models before changing production semantics.

Every ADR that invokes checkpoint or separate-file installation is subordinate to this backend and introduces no alternate replacement semantics. This plan does not alter local WAL identity/lifecycle, startup authority, current-visible reconciliation, embedded unresolved-version disposition, Spotlight independence, or provider classification. Resolver actions use this migration's ordinary separate-file installation result as a local durability gate; they never use `NSFileVersion` replacement.

## Completion criteria

The migration is complete only when:

- every existing destination replacement enters the one Foundation backend;
- every absent destination enters the existing exclusive-create path;
- no production code uses `NSDataWritingAtomic` for atomic installation;
- no caller knows whether the filesystem is APFS, HFS+, ExFAT, local, or provider-managed in order to choose a replacement primitive;
- descriptor identity, expected-byte conflict preservation, metadata, path independence, dispositions, and pending obligations retain their current behavior;
- the old leaf file-reference URL is never reused after replacement;
- every provider API uses a freshly validated operation-local reference;
- every superseded APFS/HFS+/limited-filesystem replacement branch and obsolete test hook is deleted; and
- [Atomic Note Saves](Atomic-Note-Saves.md), the implementation proposal, Apple API validation ledger, tests, and production code describe the same transaction.
