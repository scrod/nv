# Foundation safe-replacement migration

Status: implementation migration plan; behavior remains governed by [Atomic Note Saves](Atomic-Note-Saves.md) and [Robust iCloud Drive Support](iCloud-Drive-Support-Spec.md), while empirical provider requirements remain tracked in [Apple API Contract Validation](Apple-API-Contract-Validation.md)

## Decision and intended result

The [P5.6 capability experiment](impl-proposal-5/plan/phase5/06-repair-replacement-and-copy-validation.md#existing-item-replacement-capability-gap)
shows that Foundation can retain concurrent file/directory contents in a backup
while replacing the current name after an uncoordinated writer's change. Provider
repository repair therefore uses **stop-and-Save-As for occupied damaged entries**
and exclusive installation for missing entries. It has no existing-item replacement
backend or displacement-reconciliation state. The experiment remains capability
evidence, not a production repair gate. Private selected-store activation and
ordinary note-file saving retain their separate intent-specific contracts.

Migrate replacement of an existing regular file to one Foundation safe-save backend built around `-[NSFileManager replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:]` after the acceptance gates preserve the current contract. Keep `NVRootedDirectory`'s descriptor-based safety envelope and its three explicit public intents: exclusive creation, conditional replacement, and unconditional replacement. The private selected-store record and legacy/export database callers can adopt the backend first; unconditional and conditional note-file replacement follow after their behavior tests pass. Private state/current rows use SQL transactions, not this backend. Immutable provider segment, descriptor and snapshot-page installation is exclusive creation, never replacement.

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

## Caller scope under proposal 5

| Caller | Required policy above this backend |
| --- | --- |
| Plaintext note projection | Exact captured generation and expected-snapshot/displaced-byte preservation; local segment durability is a separate prerequisite, not supplied by replacement |
| Private selected-store record | Expected-current replacement and checked file/directory durability; activate only an independently reopened, verified sibling DB and its usable unlock routes. Failure/ambiguity retains both stores and cannot claim the association changed |
| Private Local State and derived current rows | SQL transactions inside `Collection.sqlite`, **not this file-replacement path**. Required state versus derived materialization retains distinct failure semantics |
| Immutable segment/descriptor/snapshot page | **Never this replacement path**; exclusive final-name installation with exact-existing-byte verification and the segment directory barrier |
| Legacy opening/exported Notes & Settings | Preserve its archive and recovery contract; no shared modern checkpoint authority or proposal-4 checkpoint-note merge |

P5.5's `CollectionSession.activateFreshSelection` consumes the existing verified
candidate and expected selected-store record. Root Re-open updates the existing
SQL association record instead; it is not a Foundation replacement of the private
database. Both paths retain exact readback after ambiguous completion, and old
root accessors retain their resources until actual return. See
[the startup/reassociation caller qualification](impl-proposal-5/plan/phase5/05-startup-and-root-reassociation-validation.md).

Private-store operations run on their own local serialized lane, not the provider lane. A helper may be shared without making local durability wait for provider coordination. [LocalStore](impl-proposal-5/LocalStore.md#sqlite-backup-salvage-and-replacement-activation) maps the private selected-store record and external exact wrapped-key descriptor copies; no database/WAL replacement is performed under a live SQLite connection. The existing absent-file capability ladder must be validated against the stricter immutable-object contract before reuse: a fallback exposing an incomplete final name cannot be treated as a sealed object. This migration does not prove the proposal-5 segment installer.

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

On the owning store's serialized lane (the provider lane for note projections; local lane for the selected-store record):

1. Validate the destination as one filesystem leaf. Reject empty names, `.`, `..`, separators, unrepresentable names, and overlong leaf names exactly as today.
2. Open the destination relative to the rooted-directory descriptor with `O_NOFOLLOW` and require a regular file.
3. Capture the coherent destination snapshot and retained descriptor required by the requested intent.
4. For conditional replacement, perform the existing initial exact-byte comparison with `expectedData`. Metadata-only differences remain outside the conflict predicate.
5. Create one operation-local destination file-reference URL and prove that it still identifies the opened destination before giving it to Foundation.

The initial check is an optimization and early failure boundary, not the final conditional-write decision. The displaced file remains the authoritative race witness.

Expected-current mutable-state callers have a distinct no-write precondition: expected absence for creation, or exact bytes and filesystem observation captured coherently. Recheck captured evidence immediately before namespace mutation; mismatch must not take the note writer's install-then-preserve path. The retained `NVCheckpointTransaction` / `NVCheckpointInstallCurrentChanged` proposal-4 fixture additionally captures a current local `NSFileVersion.persistentIdentifier` when available. It remains a legacy/comparison caller fixture, not a modern checkpoint merge requirement. An Apple identifier is supplemental evidence only: the macOS 14/26 probes kept it equal across same-bytes replacement while `NVFileObservation` changed. Private state/cache do not need a provider-version lookup.

Failure to capture or revalidate exact evidence is a no-write failure. The backend returns coherent outcomes; it never decides note merging, settings adoption or root/key cutover.

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

Do not use `NSFileManagerItemReplacementUsingNewMetadataOnly` unless separate tests prove provider identity and every metadata guarantee below. Conversely, do not delete the APFS note-file backend if options `0` require post-install metadata repair that would weaken APFS's current one-namespace-operation bytes-and-metadata contract. Private metadata/cache and legacy databases have no separate-note metadata requirement and may advance independently after their own permissions and durability tests.

### 3. Coordinated installation

Create one per-operation `NSFileCoordinator`. Coordinate the destination with `NSFileCoordinatorWritingForReplacing` and the staged source with `NSFileCoordinatorWritingForMoving`. Inside the accessor, call `replaceItemAtURL:` exactly once.

- Unconditional replacement and expected-current metadata/database installation use no backup name. The latter nevertheless enforce their separate no-write expected-current precondition immediately before this call.
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

Each mutable caller verifies its own decoded identity/generation when applicable. Capturing an installed Apple version belongs only to a caller that actually needs that evidence, not every private-state/cache save. Provider upload status is presentation only and remains outside the coordinator accessor and replacement success predicate.

### 5. Conditional compare-after-replace

Open the retained backup by its unique leaf relative to the rooted directory and verify that it is a regular file created by this replacement transaction.

Apple documents that `replaceItemAtURL:` removes a preexisting item with the requested backup name, so NV never uses a fixed, predictable, or merely incremented backup name. The descriptor-relative absence check prevents an accidental preexisting collision, and a fresh UUIDv4 leaves no practical accidental collision window. A process deliberately able to discover and create that unseen random leaf during the call already has permission to alter or delete the notes themselves; NV does not treat the backup leaf as an additional security boundary. This is the same random-identifier uniqueness assumption already used for writer epochs, operation IDs, and recovery names, not a separate conditional-write backend or deletion gate.

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

If the error supplies `NSFileOriginalItemLocationKey`, coordinate and inspect that URL as one candidate for the displaced original. Never log it, delete it from path equality alone, or reinstall it over a destination that has not been identity-checked. Mutable-state ambiguity retains all required source artifacts/keys. Legacy database ambiguity retains applicable legacy recovery inputs; modern history is never pruned because a mutable replacement succeeded.

For note projections, retain the existing best-effort root-directory synchronization after a verified namespace change. A caller with a stronger checked durability boundary, notably private Local State or the separate immutable segment installer, must obtain its required directory barrier before reporting that boundary complete. The note helper's best-effort result is not such a barrier. Legacy Recovery Journals create/delete tests retain their legacy scope.

## Preservation of the Atomic Note Saves contract

| Existing contract area | Migration requirement and acceptance evidence |
| --- | --- |
| Complete old-or-new visibility | Concurrent readers on every supported filesystem observe only the complete old or complete new byte stream. A failure before installation leaves the old destination. |
| Serialization and merge policy | Outside this primitive. The adopted protocol controls causal merge and projection import; existing serialization and snapshot helpers are reused only where they implement that policy. Replacement neither runs an alternative reducer nor authorizes fuzzy merges. |
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
| Pending-write durability | Local history and exact `pendingFileWrites` obligations remain separate. Neither Foundation success nor a cache update clears another generation's obligation. Legacy WAL fixtures do not supply the modern segment barrier. |

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
- for proposal-5 plaintext callers, stage/verify the bounded projection stamp alongside the body and existing note-owned metadata, preserving unrelated attributes; inject stamp failures/skew without claiming atomic remote delivery or turning a failed stamp into successful association;
- inject a deterministic occupied backup-name candidate and prove that NV leaves it untouched, burns the candidate, and retries with a fresh UUID leaf;
- race safe-save writers, removal, rename, symlink substitution, same-size/preserved-mtime edits, root moves, and post-install replacement;
- exercise empty data, invalid leaves, temporary-name collision, ENOSPC, permission failure, cancellation, and stale coordinator accessor URLs;
- run paths beyond `PATH_MAX` without destination path conversion;
- run APFS, APFSX, HFS+, HFSX, and ExFAT disk-image scenarios; and
- repeat ordinary coordinated iCloud replacement with the final staging, metadata, file-reference, and verification implementation; retained pause/upload probes are observational, not production requirements.

The current `atomic-rollback`, `snapshot-boundary-races`, `snapshot-stress`, `snapshot-in-place-observation`, filename-collision, durability-recovery, directory-relocation, and deep-directory scenarios remain acceptance tests. Rewrite only capability-injection fixtures whose removed implementation hook no longer exists; preserve the behavior assertion they represented.

### Phase 1 — Add one private Foundation backend

Implement a private replacement helper inside `NVRootedDirectory.m` using the target transaction above. It is not yet selected by ordinary note writes. The helper returns the existing `NVFileWriteResult` shape and reuses existing descriptor write, metadata, snapshot, conflict-preservation, and cleanup helpers.

Use it first through deterministic tests and the focused API-contract app. Do not create a public installer protocol, operation class, provider adapter, or second staging subsystem.

### Phase 2 — Adopt for mutable metadata and legacy/export databases

Route supported existing-file selected-store metadata and legacy/export database saves through the same private Foundation backend. Keep decoding, expected-current capture and caller-specific failure handling above it; no authority classification adds pause/upload controls. Expected absence uses exclusive creation. Appearance, disappearance, exact-byte or filesystem-witness change at an expected-current boundary must produce no-write mismatch.

Modern `CKPT-01` uses derived private current rows, not a packed startup cache; it does not authorize proposal-4 complete-note-set/base-relative checkpoint merging. A Local State ambiguity cannot silently publish new settings or key/root association. Invalid derived rows require reconstruction, not history cleanup or private settings reset. They remain SQL-managed data, not Foundation replacement callers. Legacy opening and explicit export retain their own archive/recovery guarantees without recreating a shared modern Notes & Settings file.

Repository Save As follows proposal 5's available-history copy: exact retained objects/descriptors and associated note files, unchanged identities, no dependency on source Application Support/unpublished work, and a separately validated explicit transition if the command includes opening the copy. Legacy migration/current-notes export/key-profile conversion instead use their disclosed current-state import and independently verified credentials. Neither silently substitutes for the other or authorizes deleting source history/keys. Test each real caller's cancellation, failure and crash boundaries, rather than implementing the retired checkpoint/WAL lifecycle as an adapter.

### Phase 3 — Adopt unconditional existing-file replacement

Route `overwriteFileNamed:` and `overwriteNoteFileNamed:` to Foundation only when the destination exists. Storage conversion and ordinary overwrite callers retain the same return dispositions and metadata contract. Absent destinations continue through exclusive creation.

Do not advance while a supported mutable caller must branch around the helper to recover its required semantics.

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
5. ordinary coordinated iCloud replacement using the final production adapter; pause/upload cases are optional compatibility observations;
6. root-move and deep-path tests while replacement is in flight;
7. epoch-4 legacy-opening/export compatibility tests for any changed archive caller (not a new segment-cache format constraint); and
8. selected-store-record failure tests and **Save Current Collection As…** crash tests for complete target history, independent credentials and exact cutover; private SQL state/cache failure tests qualify that separate transaction mapping.

This migration is intended to refine, not change, the specification or TLA+ state machines. Atomic replacement remains an environmental assumption in the models. No model change is required while all current observable guarantees and failure classifications remain intact. If Foundation cannot establish one of those guarantees and the proposed response would alter publication, preservation, caller verification, history retention, or recovery behavior, stop the migration and update the normative specification, applicable ADRs, and models before changing production semantics.

This backend must implement the specification and ADRs' caller contracts; it cannot override them. It does not reintroduce a mutable WAL, authoritative startup cache, checkpoint-note merge, upload-qualified cleanup, or automatic Apple-version recovery. Apple's resolver uses ordinary exact separate-file installation in addition to its local segment barrier and never calls `NSFileVersion` replacement. Immutable-object installation remains a separate verified create path, not another existing-file replacement backend.

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
