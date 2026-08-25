# Implementation Proposal 1: Architecture for First-Class iCloud Drive Support

Status: proposal; derived from `docs/iCloud-Drive-Support-Spec.md`, ADRs 0001–0011, `docs/tla/README.md`, and `CONTEXT.md`. Domain terms follow the project [storage and reconciliation vocabulary](../../CONTEXT.md).

**Summary.** The spec's requirements already rhyme with three things the app has or Cocoa provides for free:

1. `synchronizeNotesFromDirectory`'s prepare-detached → double-catalog fence → main-thread commit skeleton is exactly the "reconciliation transaction with exact provider fence" the TLA+ models demand — it only needs a richer fence and a move off the main thread.
2. `NSFileCoordinator`/`NSFilePresenter`/`NSFileVersion` (local + nonlocal) supply nearly the entire provider machinery — coordination, materialization, immutable version snapshots, persistent version identifiers, and resolution — so NV writes almost no provider code of its own.
3. CFPreferences' current-host domain *is* the host-local active-journal registry, and `SyncSessionController`'s existing quit barrier *is* the iCloud upload-wait UI.

The proposal is therefore not a parallel iCloud subsystem: it is **one new threading substrate (two GCD lanes + never-reused root sessions)**, **one journal-identity retrofit**, **five small controllers**, and a **pure decision kernel**, all wrapping the existing rooted-directory/WAL/transaction code.

## 1. What stays, and why that matters

The existing seams carry most of the spec with little change. Recognizing this is where the code reduction comes from:

| Existing component | Spec role it already fills |
| --- | --- |
| `NVRootedDirectory` CAS writes (`replaceNoteFileNamed:...expectedSnapshot:`) | The spec keeps expected-byte compare-and-swap as *the* note-write conflict detector; provider-lane writes call these same methods inside coordination brackets |
| `NVDirectoryTransaction` + double-catalog fence (`isExactlyEqualToCatalog:`) | The detached-candidate/prepare-commit transaction shape; the fence generalizes from name+identity equality to token + version-ID-set equality (same opaque-equality, no-ordering doctrine) |
| `NVMergedText` + `NoteObject` merge-base ivars | The plain-text three-way merge the spec names; only the base becomes "last reconciled separate-file bytes" |
| `DeletedNoteObject` + `reconcileVerifiedExistingNotes:deletedNotes:` | Identity-bound, name-independent tombstones serialized in the checkpoint already exist; retention policy changes (no purge while an unresolved provider deletion is represented) instead of a new tombstone store |
| `SyncSessionController` `waitForUncommitedChangesWithInvocation:` | ADR-0008 mandates reuse for upload waiting — progress, error, and quit-override UI come free |
| `WALController` zlib record codec | Record format is untouched; only the filename, header, and claim protocol change, which is what keeps legacy recovery compatible |
| `FrozenNotation` keyed archive | Gains one backward-readable `checkpointID` field (ADR-0005) |

**Main-thread immediacy is untouched**: search, filtering, editing, and the live store stay exactly as they are. Nothing below puts file I/O on the main thread or makes search asynchronous.

## 2. The threading substrate (the one genuinely invasive change)

Today scans, note writes, and the WAL are all main-thread-serialized (the FSEvents `IgnoreSelf` comment in `NotationDirectoryManager.m` even flags this). The spec requires provider work off-main, WAL durability never blocked by a provider, and main-thread commits that touch no filesystem. Three concepts, all plain GCD:

**`NVRootSession`** — created on every activation/reopen, never reused. Owns: the provider lane (one serial `dispatch_queue_t`), the presenter, cancellation state, the dirty-obligation counter, and the structural-generation counter. Each asynchronous block retains the session and, before publishing to main, validates `[session isEqual:controller.currentRootSession] && session.sessionID matches` — the UUID compare is authoritative because MRC object addresses *can* be reused (the ABA case `ReplaceRootSessionIncarnationWithSameInputs` exercises). This replaces the "global completion generation" the spec explicitly calls unnecessary.

**Durability lane** — one process-wide serial queue owning the journal `NSFileHandle` (append + `NVBarrierSyncFileDescriptor`). `NoteObject -writeUsingJournal:` moves here. Nothing else runs on it, so provider stalls can never delay local durability (ADR-0010).

**Provider lane** — the session's serial queue owning coordinated catalogs, selected version reads, note-file writes and renames, checkpoint installs, version inspection, and journal discovery/cleanup, in that serial order. Note-file writes migrate here from main; `pendingFileWrites` becomes a lane-mediated obligation set. With our writes off the main thread, the FSEvents `IgnoreSelf` assumption dies — drop the flag and let the dirty accounting absorb self-events (it is designed to tolerate spurious dirty).

The commit pattern is always: provider lane does all failable FS work → hop to main with captured session + fence payload → main validates incarnation and fences → applies to the live store via the existing disconnect/apply/reconnect commit — zero filesystem access on main.

## 3. Provider services (thin, mostly framework)

**`NVStorageProviderClassifier`** — produces `iCloud | otherFileProvider | ordinaryLocal | unknown` from `NSURLIsUbiquitousItemKey` on the item and nearest *existing* ancestors plus `NSFileProviderManager getIdentifierForUserVisibleFileAtURL:`. Confirmed-local requires positive exclusion from both systems plus local-FS evidence; everything inconclusive is `unknown`. A value object computed on the provider lane, cached per root session, invalidated by `NSUbiquityIdentityDidChangeNotification` and root moves. First-class mode is *derived* from classification + `PlainTextFormat` + encryption-off — no stored mode bit (spec §Provider fallback).

**`NVNotesFilePresenter`** — the one `NSFilePresenter` for the notes directory, on a private serial queue per the spec. It and the FSEvents stream both reduce to one protocol (`NVDirectoryWatcher`) whose only output is "new dirty obligation through captured session," so the existing `NotationDirectoryManager` event plumbing survives unchanged behind it.

**`NVCheckpointTransferController`** — encapsulates the entire macOS 26+ upload barrier: `supportedSyncControls` probing, `pauseSync`, short coordinated checkpoint install, `uploadLocalVersionOfUbiquitousItem:withConflictResolutionPolicy:` whose returned `NSFileVersion` must match the exact installed, read-back-verified local version *and* `checkpointID` (transaction-local request identity guards stale callbacks), `resumeSync` on every path. Pre-26 systems get the conservative not-uploaded→uploaded transition qualification. Availability-gated internally so callers see one "upload confirmation" result matching the CONTEXT.md term — this isolates the only OS-version-split behavior in the whole design.

## 4. Journal identity retrofit

`WALController` splits into:

- **`NVDurabilityJournal`** — new filename `Interim Note-Changes.<journalID>`; a CRC-integrity-checked header (magic, format/key epoch, `journalID`, `baseCheckpointID`) precedes the *unchanged* zlib record stream. Legacy `Interim Note-Changes` recovery keeps the current controller, including its inode lock.
- **`NVCheckpointIdentity`** — value object for the random `checkpointID` or `epoch4-sha256:<digest>` tagged base (ADR-0005), with the canonical encoding added to the archive.
- **`NVActiveJournalRegistry`** — the host-local registry as *pure CFPreferences*: `CFPreferencesSetValue` of the rooted-directory bookmark under `NVActiveJournal.<journalID>` in the current-app/current-user/`kCFPreferencesCurrentHost` domain, enumerated with `CFPreferencesCopyKeyList`. Cross-host isolation, atomicity, and synchronization are framework behavior — no registry file, no distributed notifications, nothing in the shared folder. Bookmark resolution compares *item identity* against the open directory descriptor, never bookmark bytes (ADR-0006).
- **`NVDirectoryLock`** — fixed-name advisory lock file (`flock`, `O_CREAT`, nonblocking, refusable) for modern multiprocess exclusion; filtered from note catalogs like `.nv-write-` staging files.

Creation ordering (header write+fsync → pref publish → `CFPreferencesSynchronize` → first accepted edit) is one method on the registry+journal pair; the `JournalLifecycle` model is its contract.

## 5. Reconciliation engine (the heart)

Four objects, cleanly split between "talks to the filesystem" and "decides":

**`NVProviderCatalog`** — metadata-only enumeration on the provider lane: names plus cheap identity/revision resource values (never contents), yielding (a) the **provider catalog token** — an opaque SHA-256 over the canonical encoding of that metadata plus per-item version persistent identifiers and materialization status, used only for equality — and (b) per-item version lists: canonical + unresolved local `NSFileVersion`s + nonlocal versions, deduplicated by persistent version identifier. Failed nonlocal enumeration marks the snapshot incomplete.

**`NVCandidateBuilder` + the decision kernel — pure and filesystem-free.** Given the catalog, the selected immutable version snapshots, and the live model, it produces the detached `NVReconciliationTransaction`: per-item decisions implementing the normative 22-fixture matrix, fresh-UUID conflict notes, identity-bound tombstones, rename pairings (source+destination coordinated together), `NVMergedText` merges with the last-reconciled base, decision ancestry records, and the representation ledger (which selected versions are represented as original/conflict/tombstone/ancestry — the input that later drives resolution eligibility). Because it is pure, the spec's "every row of the matrix in every canonical/unresolved/nonlocal processing order" test obligation becomes a plain permutation unit test sharing fixture names with `ReconciliationDecisionSafety.tla`.

**`NVVersionReader`** — the only coordinator-intensive piece: `NSFileCoordinator prepareForReadingItemsAt:...` batch preparation over the *selected* set, each nested operation using the accessor URL; nonlocal contents read only through coordinated reads of the version URL (`NSFileVersion`'s immutable snapshot behavior is assumed by the models and verified by integration tests). Returns snapshots keyed by persistent identifier.

**`NVReconciliationScheduler`** — owns the dirty obligation: an atomic counter consumed at transaction start; notifications arriving after start bump it; a complete commit clears dirty only when the counter is unchanged *and* the second fence matches. Everything else — failed fencing, partial preservation, discard, cancellation — retains dirty. This makes "notification before catalog visibility" a non-event by construction.

The commit path in `NotationController` extends `_commitDirectoryTransaction:` to also consume the fence fields {second catalog token, exact version-ID set}, the model fence {structural generation, affected UUID/LSN map}, and the session incarnation, and to record partial-preservation commits as additive-only. The existing main-thread mutation sequence is otherwise reused verbatim.

## 6. Startup, recovery, quit, transitions

- **`NVStartupCoordinator`** — state machine over the spec's Startup section: paused-checkpoint resume (macOS 26+) → provider-current check → decode → legacy-then-active journal discovery → present / work-offline / rebuild / choose / quit. `StartupSafety.tla` is its contract. It replaces the init sequencing inside `NotationController`+`StartupRecovery` with an explicit phase object, which is also what makes crash-point testing tractable.
- **`NVRecoveryEvidenceController`** — catalogs `NSFileVersion`s of `Notes & Settings` and unclaimed iCloud journals as passive evidence; implements **Recover Notes** (coordinated persistent-identifier snapshot → immutable reads → deterministic conflict notes whose UUIDv5 name input is the source-note UUID + SHA-256 of the canonical `v1` recovery encoding → exact provider fence → resolution only after the full separate-file/checkpoint/upload durability chain) and one-confirmation **Discard**. A ~20-line RFC 4122 v5 helper over CommonCrypto is the only crypto code. `RecoveryEvidenceSafety.tla` is its contract.
- **`NVBootstrapRebuilder`** — all-or-nothing rebuild-from-note-files with both fences, replacement checkpoint install, and fresh journal.
- **`NVQuitTransaction`** — the quiesce → final provider barrier → journal sync → file-write settlement → frozen serialize with fresh `checkpointID` → verified install → durability rule (local: dir-sync + journal removal; iCloud: `NVCheckpointTransferController` barrier *then* journal deletion). Reentrant callbacks resume a recorded phase; one retry/Quit-Anyway outcome for every pre-install failure; the checkpoint write moves *before* the iCloud wait and is never repeated (ADR-0008). Hooks into the existing `SyncSessionController` barrier.
- **`NVStorageTransitionController`** — controlled-restart transaction for encryption/format changes and detected mid-session moves into iCloud, with the old-format checkpoint as the crash/retry marker and an idempotent, catalog-token-fenced plaintext export (`StorageTransitionSafety.tla`). This absorbs what `PassphraseChanger`/`databaseSettingsChangedFromOldFormat:` do today and generalizes it.

## 7. The leverage, explicitly

Where the framework or existing code eliminates whole subsystems:

1. **`NSFileVersion` local + nonlocal** *is* the version ledger — persistent identifiers, immutable coordinated snapshots, and resolution APIs. NV adds only the discipline of *when* resolution is allowed (the eligibility chain), never its own version store.
2. **Batch coordination** (`prepareForReadingItemsAt:`) covers provider preparation and materialization for the selected set in one call — no custom download machinery, and placeholders stay unmaterialized per the catalog contract.
3. **CFPreferences current-host** gives journal-claim isolation, atomicity, and synchronization as framework behavior.
4. **GCD serial queues + never-reused session UUIDs** give the lanes and ABA-safe publication with no custom scheduler, locks, or generation counters.
5. **The quit barrier, conflict-note machinery, CAS writer, merge function, tombstone store, and transaction skeleton are all reused** — the spec was written to permit exactly this (it names `NVMergedText`, the CAS, and the existing barrier as retained).
6. **The pure decision kernel** turns the largest verification obligation (22 fixtures × processing orders × ancestry) into data-driven unit tests shared with the TLA+ fixtures, and keeps all concurrency out of the decision code.
7. **`NSURL` resource values** (`NSURLIsUbiquitousItemKey`, downloading status, `NSURLUbiquitousItemIsSyncPausedKey`) drive every status/UI decision — no polling loops, no `NSMetadataQuery`, no CloudKit.

## 8. What deliberately stays out

No CloudKit or custom networking; no `NSMetadataQuery`; no stored first-class-mode flag; no per-version picker UI; no recovery ledger (deterministic identities make retries idempotent); no checkpoint rotation or periodic checkpointing (ADR-0007); no journal sealing/ancestry chain; no legacy WAL alias (ADR-0005); no telemetry — and diagnostics go through one redaction wrapper (operation, count, domain, code) so the "no note text, filenames, paths, or account IDs" rule is enforced in one place.

## 9. Build order and verification hooks

Each phase is independently shippable and lands against the already-written model configs in `docs/tla`:

1. **Journal identity + registry + directory lock** (`JournalLifecycle`, `JournalRecoverySafety`) — pure local behavior, invisible to iCloud-less users, unlocks everything else.
2. **Root sessions + lanes + presenter + classifier** — no user-visible change for local folders beyond the lock; moves note writes off main.
3. **Reconciliation engine** (fences, version sets, decision kernel) — local-folder path first, iCloud after; permutation tests for the matrix from day one.
4. **Startup coordinator** (paused resume, provider-current, offline, explicit creation, rebuild).
5. **Quit transaction + upload barrier** (`QuitSafety`), reusing the sync barrier.
6. **Recovery evidence + storage transition** (`RecoveryEvidenceSafety`, `StorageTransitionSafety`), then UI wiring (offline status, recovery UI, coalesced conflict notification).

## 10. Two tensions worth deciding early

- **Coordinator URLs vs. path independence.** The doctrine that resolves it: the rooted directory's descriptor stays authoritative *between* operations; coordinator URLs exist only inside accessors, where a leaf name is mapped onto the accessor URL and the write still goes through the descriptor-relative CAS, with the accessor URL's file identity used as extra post-write validation. This is the same "transient adapter" pattern already used for FSEvents and Finder, applied consistently.
- **`relocateIntoDirectoryReferenceURL:`** must lose its app-initiated UI command (the spec removes it) while remaining as the mechanism for absorbing provider-driven root moves; the classification/journal-record/FSEvents updates on move hang off `NVRootSession` replacement, so the capability stays but the command goes.

## Component-to-contract map

| Component | Spec sections | ADRs | TLA+ contract |
| --- | --- | --- | --- |
| `NVRootSession`, lanes, presenter | Execution and file-provider coordination | 0008, 0010 | `ReconciliationFencingSafety` |
| `NVStorageProviderClassifier` | Provider fallback and user presentation | 0001 | — |
| `NVCheckpointTransferController` | Checkpoint and quit transaction | 0004, 0008 | `QuitSafety` |
| `NVDurabilityJournal`, `NVCheckpointIdentity`, `NVActiveJournalRegistry`, `NVDirectoryLock` | Journal identity and recovery | 0005, 0006, 0007 | `JournalLifecycle`, `JournalRecoverySafety` |
| `NVProviderCatalog`, `NVCandidateBuilder`, `NVVersionReader`, `NVReconciliationScheduler` | Routine separate-file reconciliation | 0009, 0010 | `ReconciliationSafety`, `ReconciliationDecisionSafety`, `ReconciliationFencingSafety` |
| `NVStartupCoordinator`, `NVBootstrapRebuilder` | Startup | 0002 | `StartupSafety` |
| `NVRecoveryEvidenceController` | Database recovery evidence | 0003, 0009 | `RecoveryEvidenceSafety` |
| `NVQuitTransaction` | Checkpoint and quit transaction | 0004, 0008 | `QuitSafety` |
| `NVStorageTransitionController` | Migration, security, and compatibility | 0011 | `StorageTransitionSafety` |
