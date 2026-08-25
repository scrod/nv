# iCloud Drive implementation architecture

Status: proposed implementation architecture for the working epoch-5 specification

This document translates the normative requirements in [Robust iCloud Drive Support](../iCloud-Drive-Support-Spec.md), the [ADRs](../adr), the [TLA+ models](../tla/README.md), and the vocabulary in [CONTEXT.md](../../CONTEXT.md) into an implementation shape for the existing Objective-C application. Those sources remain authoritative if this proposal differs from them.

The proposal intentionally adds one stateful production component rather than a parallel storage stack. `NVRootedDirectory`, `NVDirectoryTransaction`, the note merge code, `WALStorageController`, and `SyncSessionController` remain the mechanisms that do the real work. Cocoa supplies asynchronous execution, local/provider coordination, change notification, version discovery, materialization, and iCloud status. Small private immutable values and C encoding helpers may support those existing owners without becoming new controllers.

## Design in one page

```text
AppController                         main thread; startup/quit/folder UI
    |
NotationController                   main thread; authoritative live notes
    |-- WALStorageController          private serial durability queue
    |       `-- open journal fd       append + synchronize, no provider wait
    |
    `-- NVRootSession                 one fresh object per opened notes root
            |-- serial NSOperationQueue
            |       `-- serial underlying dispatch queue
            |           provider work, presenter/FSEvents callbacks, state
            |-- NSFilePresenter
            |-- per-operation NSFileCoordinator
            |-- NVRootedDirectory     existing descriptor-relative I/O
            `-- NotationDirectoryManager
                    existing catalog, merge, and transaction machinery
```

The important boundaries are:

- Only the main thread mutates or publishes `NotationController`, `NoteObject`, `DeletedNoteObject`, preferences, selection, or search state.
- The WAL durability queue receives immutable encoded records and never waits for note-file materialization or checkpoint upload.
- The root session's provider queue performs every operation that may consult a File Provider. It may wait for the network without blocking the UI or WAL.
- A provider operation returns immutable prepared values to the main thread. Its completion cannot directly mutate a live note.
- `NVRootedDirectory` remains the path-independent filesystem capability. Coordinator accessor URLs authorize an operation; they do not become stored paths.

This is not a distributed database. `NSFileCoordinator` coordinates local processes and the local File Provider extension. Separate note files carry routine cross-Mac changes; iCloud transports them. `Notes & Settings`, database versions, and unclaimed journals provide startup and recovery evidence.

## One new stateful production component

Add `NVRootSession.h` and `NVRootSession.m`. Do not add a provider abstraction, operation subclass hierarchy, synchronization database, or CloudKit layer. Private transaction/receipt values, shared encoding helpers, and the root session's private diagnostic function own no independent workflow and do not enlarge this component boundary.

`NVRootSession` conforms to `NSFilePresenter` and owns everything whose validity is limited to one opening of one notes directory:

- a retained `NVRootedDirectory`;
- a fresh random session-incarnation UUID;
- a private serial dispatch queue installed as the `underlyingQueue` of a private `NSOperationQueue` with `maxConcurrentOperationCount = 1`; the operation queue is both the provider lane and `presentedItemOperationQueue`, and FSEvents targets the underlying dispatch queue;
- the root presenter registration;
- provider classification (`iCloud`, `other File Provider`, `ordinary local`, or `unknown`);
- active/quiescing/closing/closed state;
- cancellation and dirty-generation state;
- the last accepted catalog and version-set fences;
- a runtime physical-state map per note UUID (installed filename, snapshot/base, and last applied LSN), in-flight note-write generations, and transient provider-version resolution eligibility;
- the current-host active-journal claim associated with this opened root; and
- the fixed per-directory lock.

The instance UUID is the root session incarnation used by reconciliation fences. A replacement object always gets a new UUID, even when reopening the same URL and seeing identical files. Late work need only compare the captured object/UUID with the active session; no global session counter is required.

After the stable provider barrier has atomically marked the session closing, stop/invalidate the FSEvents stream, remove the presenter, and use the operation queue's `addBarrierBlock:`. The serial underlying queue orders already-enqueued FSEvents work with presenter/provider work, while the operation barrier drains presenter callbacks already submitted to the operation queue. This replaces custom thread draining, condition variables, and polling.

`NVRootSession` should have a deliberately small public surface: open/classify, enqueue a prepared note-file attempt, mark reconciliation dirty, quiesce, install/upload a checkpoint, and close. Reconciliation details remain private methods in `NotationDirectoryManager.m`; WAL details remain in `WALController.m`.

Every potentially blocking entry point is completion-based. Provider work starts on the session queue and delivers its immutable result on the main thread; no caller uses `waitUntilFinished`, a semaphore, or `dispatch_sync` to turn it back into synchronous main-thread I/O.

Use small typed open, close, local-checkpoint-install, and upload-qualification outcomes wherever a Boolean plus `NSError` would make the caller guess whether work was installed, remains pending, or needs user action. Keep these as enums and immutable result values, not operation subclasses or a protocol hierarchy. Each root operation is single-flight and advances monotonically; a repeated completion or stale callback can only be rejected.

This project uses MRC. `NotationController` owns the root session; the session's callback target is non-owning. Blocks submitted to queues copy only immutable values plus the root session needed to keep the operation alive, and every completion checks active incarnation/cancellation before publication. Closing breaks notification registrations and target links before the final releases.

## Existing components and their retained responsibilities

### `AppController`

`AppController` remains responsible for visible lifecycle decisions:

- displaying startup materialization/recovery progress;
- presenting quit, choose-folder, work-offline, retry, and explicit quit-override choices;
- preventing new user edits once termination or a controlled storage transition starts;
- maintaining a monotonic termination phase; and
- invoking the existing `SyncSessionController` wait callback.

Move checkpoint creation out of `applicationWillTerminate:`. That callback must only close resources and save UI preferences. A reentrant termination request observes the existing termination phase and neither starts another checkpoint nor rewinds the phase.

### `NotationController`

`NotationController` remains the sole live-store authority. Its existing sets and arrays remain the source used by synchronous search and UI code.

Add only the state that belongs to the live model:

- the active `NVRootSession`;
- a runtime structural generation;
- the exact accepted checkpoint `NSData` and checkpoint identity;
- intentional tombstones even when no legacy sync service metadata exists.

Do not add another pending-intent registry. The existing main-thread `pendingFileWrites` and `pendingJournalWrites` sets remain the sole durable-work obligation registries and retain the existing typing coalescing contract. At a timer or explicit durability boundary, capture immutable UUID/LSN/value input from the currently pending note and submit that attempt. A completion removes the note from its existing set only when the live UUID/LSN still equals the captured generation; otherwise the same set entry continues to represent the newer obligation. `NVRootSession` tracks only an in-flight attempt and the physical state it actually observed or installed, not a second scheduler.

The structural generation increments when a note is added or removed, a filesystem name changes, serialization/storage policy changes, or the root session is replaced. Ordinary content/title/tag edits continue to use the note UUID and existing LSN as the finer fence.

Increment the LSN when a logical mutation is admitted to the live store, not later when the WAL happens to encode it. The same UUID/LSN then names the live generation, the WAL record, the separate-file intent, and the reconciliation fence.

### `NVRootedDirectory`

Keep all existing descriptor-relative catalog, snapshot, compare-and-swap, atomic-install, rename, delete, and directory-synchronization code. It already supplies the hard part of NV's no-`PATH_MAX`, move-tolerant semantics.

Add three narrow capabilities:

1. Validate that a coordinator-provided URL still denotes this rooted directory or one of its direct child names, then perform the existing descriptor-relative operation. The URL is consumed inside the accessor and is never cached as an operational path.
2. Refresh the transient file-reference URL/bookmark after a presenter-reported root move, but only after verifying that it resolves to the directory already held open.
3. Open and validate the fixed modern directory lock by relative name.

Promote the existing `NVRootedDirectoryCatalog` just enough for `NotationDirectoryManager` and `NVRootSession` to retain and compare it. Its exact equality is the opaque provider catalog token required by the spec. Do not invent a second catalog digest, ordering, or generation number.

Remove the app-initiated `relocateIntoDirectoryReferenceURL:` convenience path and its AppController command. Finder/File Provider moves remain supported through the open descriptor and presenter callback.

### `NotationDirectoryManager`

Retain and extend the private `NVDirectoryTransaction`, but change its background staging payload to immutable prepared-note values. It already provides the shape needed for all-or-nothing publication on the main thread.

It should become the one deterministic reconciliation kernel for:

- ordinary background scans;
- startup rebuild from note files;
- note-file conflict handling during local writes; and
- recovery-note import from database and unclaimed-journal evidence.

Private value objects can live in `NotationDirectoryManager.m` rather than becoming public classes. At minimum the transaction needs the first and second catalogs, first and second exact version-ID sets, enumeration completeness, unreadable versions, captured root incarnation, captured structural generation, affected UUID/LSN values, prepared mutations, additive preservation artifacts, and resolution candidates.

Make the decision matrix one private pure function in `NotationDirectoryManager.m`. It receives only immutable catalog/model/version/base/identity values and returns prepared mutations, ancestry, tombstones, and resolution candidates in `NVDirectoryTransaction`. It may call `NVMergedText` and the existing filename/content/identity helpers, but it cannot access the filesystem, queues, `NotationController`, or a live `NoteObject`. Provider code builds its input; the main-thread publication path constructs or updates note objects from its output. Do not add an `NVCandidateBuilder` class for this single function.

Key its table-driven tests by the exact twenty-two scenario identifiers in `ReconciliationDecisionSafety.tla` and run every applicable canonical/unresolved/nonlocal traversal permutation. Sharing those names keeps each implementation fixture visibly tied to the independent formal oracle without making production code parse or depend on a TLA+ file.

Provider work may copy bytes and produce those immutable values, but it must not construct or decode `NoteObject`/`DeletedNoteObject`, initialize their display/search/date caches, attach labels, or consult main-thread preferences. Perform that work on the main thread during fenced publication. This preserves the existing cache and preference assumptions without first making the legacy object graph thread-safe.

Preserve the current identity order: stable local filesystem identity, then unambiguous filename/content matching. Do not add UUID extended attributes or sidecar files.

### `WALStorageController` and `StartupRecovery`

Keep the existing record framing, compression stream, encryption behavior outside first-class plaintext mode, checksum validation, UUID/LSN coalescing, and legacy exact-name reader. Correct the recovery loop to implement strict valid-prefix replay: framing, length, decompression, checksum, archive, class, or semantic failure stops at that record. A torn final append yields only the complete valid prefix before it. Never skip an invalid interior record and resume with later records, and never truncate or repair the discovered artifact in place.

Modernize ownership without replacing the record body:

- a modern journal is `Interim Note-Changes.<journalID>`;
- an integrity-checked fixed header contains a magic value, header-format version, random journal ID, canonical checkpoint base identity, and CRC using the existing `NSData` CRC helper;
- the header is followed by the existing framed compressed records;
- one fixed hidden directory-lock file excludes another local modern writer;
- failure or lack of advisory-lock support refuses writable modern operation;
- modern journals do not use inode locking;
- the legacy exact-name path retains its existing inode-lock behavior; and
- the modern file descriptor remains open for the process lifetime.

The WAL queue should receive an already archived immutable note or tombstone record. At the existing coalesced write boundary, archive the latest pending generation on the main thread and submit those bytes; never dereference a mutable `NoteObject` on the WAL queue. The queue performs compression, encryption, append, short-write recovery, and synchronization in order. A write failure posts one main-thread durability error and leaves the in-memory state and journal for recovery.

Journal create/header sync and final journal deletion pass through the provider lane because they change the provider namespace. Ordinary append and `fsync` use the already-open descriptor on the independent durability lane; they do not enter a coordinator accessor.

Expose journal activation as one ordered `WALStorageController` entry point, not as separately callable file and preference steps. It exclusively creates the random journal path, writes and barrier-synchronizes the complete header, synchronizes the directory, writes the matching current-host claim, calls `CFPreferencesSynchronize`, and only then returns an append-capable writer. Any failure returns no writer, so editing cannot observe a half-published active journal. The corresponding cleanup entry point coordinates journal removal and directory synchronization before removing and synchronizing the claim; failure retains the conservative claim. Keep the CFPreferences helpers as functions in `WALController.m`/`StartupRecovery.m`, not a registry object.

`StartupRecovery.m` remains the policy owner for legacy-before-modern replay, base matching, unclaimed-journal recovery, and replacement-checkpoint cleanup. It should use the same prepared-value transaction and the root session's private `NVCheckpointTransaction` entry point rather than a new recovery store or a direct checkpoint write.

### `SyncSessionController`

Do not make `NVRootSession` conform to the large legacy `SyncServiceSession` protocol. Add one assign/weak provider participant and query its few concrete status methods alongside the existing sessions:

- running;
- actionable error;
- uncommitted checkpoint/upload work;
- start/continue commit; and
- short status text.

This preserves `waitForUncommitedChangesWithInvocation:`, its retry/override behavior, the existing status menu and indicator, and the existing completion callback. It avoids a second quit waiter and avoids implementing unrelated note-service methods.

## Cocoa leverage

| Cocoa facility | Use in NV | What it replaces or avoids |
| --- | --- | --- |
| `NSOperationQueue` with a serial `underlyingQueue` | One ordered provider/presenter/FSEvents lane and one independent serial WAL queue | Threads, callback-forwarding queues, dispatch groups, custom operation subclasses, and manual queue draining |
| `NSFilePresenter` | Root/subitem changes, root moves, deletion/accommodation callbacks | Treating FSEvents as authoritative and polling for provider activity |
| `NSFileCoordinator` + `NSFileAccessIntent` | Local/provider arbitration and materialization around exact operations | Naive POSIX access racing a local editor or File Provider extension |
| `NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly` | Exact root/checkpoint probes whose accessor uses promised-item resource values only, subject to AV-01 | Accidentally materializing file contents merely to classify or select work |
| `prepareForReadingItemsAtURLs:...` | Batch preparation of only selected changed versions | One provider round trip per selected file |
| `NSFileVersion` | Current, unresolved, other, and nonlocal immutable version evidence | Invented vector clocks, xattrs, or arrival-order conflict selection |
| Ubiquitous-item resource keys | Current/materialized/uploading/error/paused state | Guessing cloud state from POSIX success or timestamps |
| macOS 26 `NSFileManager` sync controls | Optional checkpoint pause/upload/resume and returned-version correlation | A custom persistent pause/upload state machine |
| `NSFileProviderManager` URL identity, when its consumer contract is validated | Distinguish another File Provider from confirmed local storage | Folder-name/path heuristics; an inconclusive result remains `unknown` |
| File-reference URLs and bookmarks | User selection and provider-reported move refresh | Stored absolute paths |
| `NSProgress` | Startup/rebuild/recovery progress model bound to existing Cocoa UI | Bespoke progress notifications |
| Unified logging (`os_log`) behind a field allowlist | Content-free storage diagnostics | Ad hoc `NSLog` calls that can interpolate filenames, paths, or `NSError.userInfo` |

The initial architecture deliberately does not use `NSMetadataQuery`. It is backed by Spotlight, has no documented completion deadline or provider-snapshot completeness contract, and therefore cannot gate startup, reconciliation, rebuild, dirty clearing, or any `current-known` claim. It may be added later only as an advisory progress or wakeup source whose absence and wrong/incomplete results do not change behavior. `NSFileVersion` IDs are opaque equality values, not clocks. `NSFileCoordinator` is not a cross-Mac lock and does not make the checkpoint and journal a distributed transaction.

Do not adopt `NSDocument`, `NSFileWrapper`, Core Data, CloudKit, a file-provider SDK, or a third-party queue/promises library. They would duplicate NV's authoritative in-memory model or weaken its existing atomic writer without satisfying the cross-file durability rules.

Link `FileProvider.framework` only if its URL-domain identification contract passes the independent validation matrix. Validate the signing/entitlement contract for accessing a user-selected iCloud Drive root; add only the minimum required iCloud Documents entitlement and do not create or migrate into an app-owned ubiquity container. Every macOS 26 sync-control call remains availability guarded; macOS 11.5 through 15 uses the specified conservative fallback. [Apple API Contract Validation](../Apple-API-Contract-Validation.md) records every Apple behavior this design still requires and its fail-closed fallback.

## Coordination rules

Create a new `NSFileCoordinator` for each logical operation, initialized with the root presenter. The transaction may expose its current coordinator only long enough for cancellation; never reuse it as a long-lived session coordinator, and never hold an accessor while waiting for upload.

The provider queue follows these rules:

- For an exact root or checkpoint probe whose accessor reads only resource metadata, use `NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly` and `promisedItemResourceValuesForKeys:error:`. Never read file content or enumerate directory children under that option; a shallow catalog always uses an ordinary coordinated root read off-main.
- Use asynchronous intent coordination for an individual read, write, delete, or rename.
- Use one multi-intent request for operations that must be locally ordered together. A rename has a moving source and destination intent in the same request.
- Call Apple's synchronous batch preparation API only from the provider queue. Inside its accessor, perform nested coordinated reads for the selected current and historical version URLs. If Apple invokes the batch accessor, invoke its supplied completion handler exactly once, after every nested accessor has returned, on every success, error, cancellation, and exception path.
- Read a nonlocal `NSFileVersion` only from its coordinated accessor URL and finish that read before returning from the accessor.
- Use the accessor URL that Apple supplies. For a current direct child, validate it and hand only its leaf name to `NVRootedDirectory`; for a historical version outside the root, read the accessor URL directly with Foundation.
- Use ordinary write coordination around NV's existing atomic temp-file installation. Reserve moving/replacing options for actual moves or identity replacement; the coordinator does not replace NV's expected-snapshot compare-and-swap.
- Coordinate a directory catalog read at the root, but do not assume this coordinates the contents of every child. Child contents are separately selected and prepared.
- Never dispatch the actual file access out of an accessor block after the block returns.

The presenter uses the provider queue rather than the main queue. Every accommodation method invokes its completion handler on every path. At session shutdown, first establish the stable provider barrier and atomically mark the session closing while the presenter remains registered. Only then remove the presenter before releasing it and submit a provider-queue barrier to drain callbacks already delivered.

Implement only the presenter callbacks that carry useful evidence: root move/deletion, subitem appear/change/move, and gain/lose/resolve version. A version callback records its URL and persistent ID. A generic callback records its affected direct-child name, or the whole note namespace for a root callback, and marks that projection as not yet provider-visible. Relinquish-to-reader/writer callbacks stop starting new provider operations, invoke Apple's supplied relinquishment block, then mark dirty when the reacquirer returns. They do not run reconciliation recursively inside the callback.

FSEvents remains a cheap best-effort wakeup for ordinary/local filesystems and missed provider callbacks. Target it at the provider operation queue's serial underlying dispatch queue so FSEvents, presenter callbacks, and provider state changes share one ordering domain without a forwarding queue. Remove `kFSEventStreamCreateFlagIgnoreSelf` when note writes move off the main thread: the existing implementation explicitly limits that optimization to main-thread-serialized writers. NV's own event may cause a redundant coalesced transaction, but the exact installed physical state and provider fences make that transaction harmless. Do not suppress all self events unless a later implementation can acknowledge the exact installed write rather than merely its process ID. Neither FSEvents nor a presenter callback proves visibility or publishes model changes directly.

## Dirty state and exact fences

Represent the reconciliation dirty obligation with one monotonically increasing in-memory high-water mark plus coalesced visibility witnesses, not a clearable Boolean or an event ledger:

1. Every relevant presenter, FSEvents, materialization, retry, or provider-status event increments `dirtyGeneration` on the provider queue.
2. A generic external-change callback coalesces its affected name into a small `preVisibilityFence` map, retaining the last accepted catalog/version projection that predates the callback. A root callback uses one whole-note-namespace projection. Repeated callbacks for the same projection do not create records per event.
3. A version callback can witness its projection only when its persistent ID appears in the transaction's exact version set. A generic callback is witnessed only when a later exact coordinated catalog/version observation differs from its saved projection. Checkpoint and journal observations cannot witness note-file events.
4. A transaction starts by capturing `dirtyGeneration` as `servicingGeneration`; any event delivered afterward creates a newer generation.
5. Complete publication may leave the session clean only when both provider fences and all main-thread fences match, `dirtyGeneration == servicingGeneration`, and every visibility witness through that generation has been discharged by the stable exact observation. Equality is used only to recognize that an old observation has not advanced; no ordering is inferred.
6. Partial preservation, failed fencing, cancellation, discard, unreadability, incomplete enumeration, or an unwitnessed generation always leaves dirty and schedules one bounded-backoff retry.

Because the presenter queue is serial, a notification queued while batch preparation is waiting will run afterward and create the next obligation. If provider state becomes visible before its callback, the second catalog/version fence fails first. If notification arrives first, the saved projection prevents an unchanged immediate retry from consuming it. The obligation remains conservatively dirty if the provider never makes the indicated state observable; backoff prevents a hot loop, and weak fairness does not permit NV to invent completion. The required callback-to-observation behavior and the conservative liveness ceiling are explicit validation items rather than assumptions hidden in this state machine.

Each transaction has three independent fences:

- provider: exact first/second `NVRootedDirectoryCatalog` equality and exact first/second persistent-version-ID set equality;
- session/model structure: same root-session UUID and structural generation; and
- affected notes: same UUID/LSN values.

No fence is an ordering claim. An identical root URL, catalog token, version set, or note text never substitutes for the other fences.

## Provider-version evidence

Store the smallest durable provenance needed to make preservation idempotent and later resolution safe. Add an optional epoch-5 archive field to `NoteObject` and `DeletedNoteObject` containing the opaque persistent version identifiers that the object represents and the representation role (candidate, merge input, local-win ancestry, conflict preservation, or identity-bound tombstone).

The field is checkpoint/WAL metadata only. It is never written to a note file, filename, xattr, or sidecar. Epoch 4 ignores it while retaining core note readability. At runtime compare decoded opaque identifiers with `isEqual:`; do not infer anything from their encoded bytes.

An ordinary edit retains the note's ancestry because the edited note is a descendant of the represented input; deletion transfers it to the identity-bound tombstone. Creating an unrelated note or duplicate never copies ancestry. A reconciliation operation adds ancestry only when its decision kernel actually used or preserved that version—matching output bytes, names, or timestamps is insufficient.

Resolution eligibility itself stays transient in `NVRootSession`. A crash before checkpoint/upload leaves Apple's versions unresolved. On restart the durable ancestry allows the same deterministic transaction to recognize existing representation and regain eligibility without creating repeated conflict notes.

After the durability chain qualifies an ID, resolve/remove it only through `NSFileVersion` inside a coordinated write. Never touch revision-storage paths directly. A per-version API failure leaves that version, eligibility evidence, and dirty status intact for retry.

Intentional tombstones reuse `DeletedNoteObject`, keyed by stable note UUID or deterministic recovery-note UUID, and must be retained even when no legacy sync-service metadata exists. Implement that retention by extending the existing `-[NotationController _addDeletedNote:]` and `-[NotationController _purgeAlreadyDistributedDeletedNotes]` decisions; do not add another tombstone collection or type. A tombstone's provider ancestry follows the UUID through renames; it is never keyed by path.

## Local edit and note-file write flow

Local editing must remain synchronous from the user's perspective:

1. The main thread mutates the live note, increments its LSN, updates search/list state immediately, and adds the note to the existing `pendingJournalWrites` and `pendingFileWrites` sets as applicable. It does not archive or access the filesystem for every keystroke.
2. Reuse the existing idle and maximum-delay timers to coalesce typing. At that boundary, capture the latest immutable WAL record and file-write values on the main thread, then submit them to their independent queues. Queue execution and synchronization no longer block the timer callback.
3. Keep each note in its existing pending set until the submitted generation succeeds and still matches the live UUID/LSN. A newer edit leaves or restores the same set membership; there is no per-generation queue or parallel pending-intent dictionary.
4. The provider lane discards a superseded captured attempt before coordination, resolves its source from the session's physical-state map, then coordinates the selected file and runs the existing snapshot/three-way-merge/atomic-write algorithm.
5. Return an immutable result to the main thread.
6. Advance the provider-lane physical-state map to what was actually installed. Apply file metadata, merge output, or a preserved conflict to the live model only if the active root, structural generation, UUID, and LSN still match. A stale completion leaves the newer obligation queued and uses the updated physical state when it runs.

A private `NVNoteFileWriteIntent`/result pair may live in `NotationDirectoryManager.m`. It contains copied values only: root/session identity, UUID/LSN, desired and prior filesystem names, encoded bytes, tags, dates, encoding, and the last reconciled snapshot/base. It must not retain a mutable live `NoteObject` for background dereference.

Make `captureFileMergeBaseIfNecessary` a value-only main-thread operation. A current checkpoint can seed the pre-edit plaintext base because its note-file obligations settled before that checkpoint was installed; a successful reconciliation/write replaces it with the exact accepted snapshot. If no trustworthy base/identity exists, the provider transaction preserves the alternate rather than synchronously reading a cloud file from the main thread.

Keep note operations serial on the provider lane. This preserves their logical order, makes rename/write coalescing straightforward, and means a cold cloud read can delay only later provider work—not UI mutation or WAL durability. Add read concurrency only if measurements later show the serial lane cannot meet reconciliation latency; it is not part of the initial architecture.

A rename coordinates source and destination in one intent group, then uses the existing descriptor-relative exclusive destination/rename implementation. A delete uses the expected observation and stages an identity-bound tombstone when the conflict matrix requires it.

The existing `makeNoteDurableForExternalEditing:` boundary becomes completion-based: submit the immutable WAL record and a durability-queue barrier, then let `ExternalEditingSession` replace/remove its scratch file from that completion. It must not synchronously wait on the main thread.

After this conversion, all active-root namespace/content calls route through `NVRootSession` except append/synchronize on the already-open WAL descriptor. In the test target, a rooted-directory subclass should fail active-root calls made on the main thread so direct-call regressions are caught without production queue-tracking machinery.

## Reconciliation flow

One current-known reconciliation transaction proceeds as follows:

1. Coordinate a shallow root catalog on the provider queue and retain the existing exact `NVRootedDirectoryCatalog` as the first catalog token. Enumeration reads direct-child names and cheap identity/revision metadata, not note contents, and its completion—not Spotlight—is the namespace-discovery boundary.
2. Form the candidate-URL set from the current direct-child catalog, the live model and last accepted catalog, names/URLs delivered by presenter move and version callbacks, and the fixed checkpoint/journal/recovery artifact names. This retains candidates for deleted or renamed current files without requiring a directory-wide historical-version index.
3. Select the union of catalog-changed or unmatched items and items marked version-dirty because a presenter callback arrived or the per-item persistent-version-ID set differs from the last accepted set. Ask the main thread for an immutable model snapshot: root/session identity and structural generation; lightweight UUID/LSN/filename/filesystem-identity descriptors for all notes; and full content/base/labels only for that selected union. Copying model values is the only main-thread phase and performs no file access. No background task enumerates `allNotes`, constructs a note object, or dereferences a live `NoteObject`.
4. For every selected item, collect current, other, unresolved, and asynchronously returned nonlocal `NSFileVersion` objects. Deduplicate their opaque persistent identifiers and compare the per-item set with the last accepted set; a version-dirty item cannot become clean until every version kind is represented in both exact fences. Retain the transaction while asynchronous nonlocal callbacks are outstanding; each callback re-enters the provider queue, decrements a pending count, and advances the state machine only when all callbacks return or cancellation wins. No queue is blocked waiting on a dispatch group. Any enumeration failure marks the snapshot incomplete.
5. Batch-prepare only the selected current/historical URLs. Nested coordinated reads copy immutable content and metadata before their accessors return. Record every unreadable selected version.
6. Run the normative decision matrix into one prepared-value `NVDirectoryTransaction`, independent of version traversal order. Reuse `NVMergedText`, the existing expected snapshot, filename matching, identity matching, conflict-note creation, and atomic writer. Construct and decode note objects only later on the main thread during publication.
7. Repeat the same candidate construction and take a second independently produced exact catalog and exact persistent-version-ID set.
8. Dispatch the candidate to the main thread. Recheck root incarnation, structural generation, and affected UUID/LSN values without filesystem access.
9. Commit all mutations only under a complete fence. If provider evidence is incomplete but the model fences match, publish only additive represented conflict notes/provenance allowed by the partial-preservation rule. Otherwise discard.
10. Record complete-transaction resolution eligibility transiently, retain dirty when required, and coalesce one follow-up transaction.

This exact current-known path is mandatory for confirmed iCloud. Here `current-known` covers only URLs disclosed by those authoritative candidate sources and every version returned for them by the required `NSFileVersion` calls; it never claims a directory-wide inventory of undisclosed remote history. If candidate or version discovery cannot satisfy the independently validated Apple contract, enumeration is incomplete and the fail-closed publication rules apply. Confirmed ordinary local storage has a complete empty provider-version set and uses the same dual catalog fence. Other/unknown File Providers attempt compatible `NSFileVersion` enumeration; when unavailable, they retain NV's existing double-catalog/current-file compare-and-swap transaction as explicitly best-effort. That fallback may update the live model and preserve conflicts, but it never claims first-class current-known status, resolves provider versions, or qualifies journal cleanup.

The initial catalog should retain enough identity/revision metadata to select content reads cheaply. Listing placeholders should not materialize their contents. The batch preparation step—not directory enumeration—is where selected cloud bytes may download.

Routine note reconciliation excludes `Notes & Settings`, modern/legacy journals, the lock file, and NV recovery artifacts by name. Presenter changes to those files update startup/recovery/upload status rather than entering the note decision matrix.

## Startup flow

Opening a root is an asynchronous state machine owned by `AppController` and executed by `NVRootSession`:

1. Resolve the selected bookmark into `NVRootedDirectory`, acquire the fixed directory lock, create a fresh root session, and register its presenter during a coordinated root read. `AppController` owns this unattached startup session until checkpoint acceptance creates `NotationController`, then transfers ownership to the controller.
2. Classify the root. Check iCloud ubiquity on the item and nearest existing ancestors first. If not confirmed, use `NSFileProviderManager` URL-domain identity only after its use by an ordinary consumer app has passed the API-contract matrix. Confirm ordinary local storage only after both provider systems are successfully excluded and local-filesystem evidence agrees. Permission, missing-ancestor, unsupported-API, and transient failures produce `unknown`, not `local`.
3. On macOS 26+, inspect and repair a paused `Notes & Settings` before checking freshness.
4. Coordinate checkpoint status and journal discovery off-main. `ENOENT` is not an empty collection unless this process just created the directory or the user explicitly chose **Create a New Notes Collection Here** after a current parent catalog.
5. If the checkpoint is provider-current and materialized and no mandatory journal work exists, copy its exact bytes once on the provider queue and pass that `NSData` to a new `NotationController` initializer/factory. Decode those exact bytes on the main thread, retain the same object as the accepted checkpoint evidence, and present the normal UI; `NotationController` must not reopen the checkpoint path.
6. If it is explicitly stale or unmaterialized, request download and show an app-owned `NSProgress`. It is indeterminate unless a trustworthy exact-item progress value is available; presenter/resource-status wakeups update it, and only a coordinated provider-current read advances startup.
7. Recover the mandatory legacy journal first, install its replacement checkpoint, then evaluate this host's claimed modern journal against that checkpoint.
8. Before enabling editing, create the modern journal, synchronize its header, write/synchronize its current-host claim, and only then admit the first mutation.
9. After the normal UI appears, start routine reconciliation directly with the first coordinated shallow catalog. It never waits for Spotlight, note content downloads, or historical-version discovery before presenting a provider-current checkpoint.

If online update fails, the visible choices are quit, choose another folder, or work offline. Offline is enabled only when complete local checkpoint bytes and every mandatory journal can be materialized, validated, and recovered. It has a persistent visible status until a current-known reconciliation succeeds. There is no read-only store.

“Created by this operation” is transient startup state, not a persisted collection flag. Files or versions that arrive after explicit creation enter ordinary reconciliation and preservation; they are never silently discarded as remnants of an empty folder.

If no checkpoint version decodes, **Rebuild from Note Files** uses the same version enumeration, batch reader, deterministic decision kernel, and exact double fence against a detached temporary store initialized only with the normative safe default database settings. It imports readable note states without inferring deletions and never obtains settings, metadata, or deletion evidence from historical recovery artifacts. It publishes nothing until every selected version is represented and the replacement checkpoint is exactly installed. Cancel/failure discards the temporary store without a rebuild ledger.

### Current-host journal registry

Keep the registry as direct Core Foundation preferences helpers in `WALController.m`/`StartupRecovery.m`, not a registry class. Store one `NVActiveJournal.<journalID>` key under current application/current user/current host; its value is the opened root's bookmark.

At launch, enumerate only keys with that prefix, resolve each bookmark, and compare the resolved directory identity with the selected `NVRootedDirectory` plus the named journal/header. Refresh only a matching stale bookmark. Preserve unmatched or temporarily unavailable records unchanged. Duplicate/ambiguous matches fail closed.

A matching claim whose journal appears absent is pruned only after a coordinated current catalog proves absence. A copied folder cannot inherit the source claim because bookmark resolution must identify the opened directory descriptor, not merely equal path text or copied contents.

Creation order is journal file, integrity header and directory synchronization; then host claim and `CFPreferencesSynchronize`; then editing. Fresh random checkpoint and journal UUIDs are retried on collision and are never reused. There is no writer ID.

Startup never resumes append on a discovered journal. It recovers an eligible claimed journal into an exact replacement checkpoint and creates a fresh process journal. If offline operation means the recovered iCloud checkpoint cannot qualify deletion, preserve the old journal as unclaimed evidence, publish the fresh journal and claim, and only then remove the superseded claim. In a confirmed ordinary local backup restore, exactly one structurally valid and recovery-eligible unclaimed journal may be recovered automatically under the directory lock. An unclaimed iCloud journal may still have a remote writer, so it is available only to explicit **Recover Notes** and is never automatically appended, resolved, or deleted.

## Database and unclaimed-journal recovery

Treat noncanonical `Notes & Settings` versions and unclaimed iCloud journals as recovery evidence only. Their arrival never changes the live store, but their permitted actions differ.

For noncanonical database versions, the existing status UI exposes **Recover Notes** and **Discard**:

- **Recover Notes** snapshots all known persistent version identifiers, batch-materializes every readable version, and imports every distinct differing non-deletion note state through the same prepared-value transaction. `DeletedNoteObject` and settings records produce no recovered note and never mutate or suppress the live original. The action never imports database settings or installs a historical checkpoint. A deterministic UUIDv5 derived from the archived source-note UUID plus the SHA-256 digest of the normative canonical `v1` recovery-state encoding makes repeated recovery idempotent. Completion requires the transaction's second exact catalog/version fence; incomplete enumeration, changed fences, or failed reads preserve what is safe but leave dirty and confer no resolution eligibility.
- **Discard** snapshots database-version persistent identifiers after one confirmation and removes only that snapshot. Per-version failures and versions arriving later remain visible.

For an unclaimed iCloud journal, the UI exposes **Recover Notes** only. That action snapshots the current and all known local/nonlocal versions of the selected journal, reads each strict valid prefix, and imports only missing or differing non-deletion note states with the same deterministic recovery identity. It ignores deletion and settings records and uses the same exact second fence before reporting the recovery complete. It never confers resolution eligibility and never resolves, deletes, or offers **Discard** for any journal version that may still have a remote writer.

Do not add a version picker, whole-checkpoint restore, export-checkpoint workflow, recovery ledger, or note-UUID migration. Existing note UUIDs are never regenerated. Add the required SHA-256 helper beside the existing digest utilities in `NSData_transformations`, and implement UUIDv5 as a small formatting wrapper around the existing `SHA1Digest`; UUIDv5 itself requires SHA-1, so no duplicate digest implementation or dependency is needed.

A noncanonical database recovery version can be resolved only after its imported notes—or intentional tombstones created by later user deletion of those recovered notes—are represented in separate files, covered by an exact replacement checkpoint, and, under iCloud, covered by exact upload confirmation for that checkpoint. Keep this action's eligibility set transient. A crash leaves the database versions unresolved and lets durable ancestry make the next run idempotent. This resolution rule never applies to unclaimed iCloud journals.

## Checkpoint identity and installation

Add an optional `checkpointID` to `FrozenNotation`'s keyed archive. A modern serialization attempt receives a fresh random ID. An epoch-4 checkpoint without it uses `epoch4-sha256:<digest of exact loaded bytes>` as the base identity until the next verified modern save.

Use one canonical immutable checkpoint-base-identity encoding everywhere outside the archive. Add C helpers beside the digest utilities in `NSData_transformations` to construct, validate, encode, decode, and compare a tagged modern UUID or tagged 32-byte epoch-4 SHA-256 digest. The fixed binary encoding is shared by `FrozenNotation`, `WALController`, and `StartupRecovery`; callers can test equality but cannot parse strings, compare identities across domains, or infer ordering. `FrozenNotation` continues to archive only its optional backward-readable `checkpointID` field.

Keep the user-visible filename exactly `Notes & Settings` and keep its core keyed archive readable by epoch 4. Do not add a parallel epoch-5 checkpoint name.

Retain the exact accepted checkpoint `NSData` loaded at startup. It provides the byte-derived legacy identity and immutable accepted evidence; it is not a second synchronization database.

Define a private immutable `NVCheckpointReceipt` value in `NVRootSession.m`. It retains the exact frozen bytes, canonical checkpoint identity, installed local `NSFileVersion` persistent identifier, fresh transaction-local request identity, and the exact set of recovery-version identifiers whose representations the checkpoint covers. These correlated fields are created together after exact local installation and never updated independently or reused by a later attempt.

Define one private, single-use `NVCheckpointTransaction` in `NVRootSession.m` as the only local checkpoint-installation implementation. It accepts already serialized immutable bytes containing a fresh checkpoint ID, the canonical identity and recovery coverage derived from those bytes, the root-session incarnation, and the expected current checkpoint snapshot/version. It owns a coordinator only for the short local install/read-back operation, then returns either one immutable `NVCheckpointReceipt` or a typed installation failure. It never receives a live `FrozenNotation`, serializes the model, waits for upload, deletes a journal, or becomes a public controller.

Every checkpoint boundary routes through the root session method that creates this transaction: ordinary quit, legacy or modern startup recovery, bootstrap rebuild, folder switching, and both halves of a controlled storage transition. Recovered notes become checkpoint-covered through the ordinary later quit transaction; **Recover Notes** does not introduce a periodic checkpoint. `NotationController`, `StartupRecovery`, and transition code no longer call the checkpoint overwrite path directly. This replaces the duplicated normal-save and recovery installation sequences without adding another long-lived owner.

Checkpoint installation is therefore:

1. With editing frozen, serialize the live store once on the main thread using a fresh checkpoint ID.
2. Create one `NVCheckpointTransaction` with those exact bytes and the expected current checkpoint evidence.
3. On the provider lane, coordinate a compare-and-swap write of `Notes & Settings` and call the existing `NVRootedDirectory` atomic overwrite plus directory synchronization.
4. Coordinate an exact read-back and require byte equality, successful decode, and the expected checkpoint ID.
5. Capture the installed local `NSFileVersion` persistent identifier and create the receipt atomically from those correlated values.

The existing rough structural verification may remain diagnostic, but it cannot authorize journal deletion or provider-version resolution. Exact bytes, decode, ID, and local version form the checkpoint receipt.

There is no periodic checkpoint and no journal rotation. Startup recovery may install a replacement checkpoint before creating its one fresh process journal; normal editing installs only the quit checkpoint.

`NVCheckpointTransaction` is an implementation refinement, not a new atomic protocol step. The TLA+ models continue to distinguish checkpoint installation, exact verification, upload qualification, and journal/version cleanup. The separate checkpoint-transfer helper consumes the receipt only after local installation has completed, so the implementation does not collapse those modeled failure boundaries.

## Quit and exact upload flow

Use a monotonic quit state such as `running -> quiescing -> localCheckpointInstalled -> waitingForUpload -> finished/overridden`. State advances only on the main thread.

The normal path is:

1. Reject new edits/sync requests and wait for already admitted main-thread mutations.
2. Drain the WAL queue through `synchronize`.
3. While the presenter remains registered, drain its queued callbacks, settle pending note writes, and repeat final reconciliation until the exact catalog, version, session, structural, UUID/LSN, and dirty-state fences are stable. Atomically mark the root session closing so no later callback can publish into the quit transaction.
4. Stop/invalidate FSEvents, remove the root presenter, and use a provider-queue barrier to drain callbacks already delivered. Do not restart reconciliation after removal; external changes arriving after the closing barrier remain in separate files for next-launch reconciliation.
5. Serialize once and install/read-back the exact checkpoint receipt.
6. Ask `SyncSessionController` to wait for checkpoint upload evidence.
7. Resolve only provider versions whose representations have complete historical eligibility and have reached their required separate-file, checkpoint, and upload durability.
8. Coordinate deletion of the active journal, synchronize the directory, remove its host claim, and finish termination.

Step 8 is available after exact local checkpoint durability for confirmed ordinary local storage, and after the specified exact upload qualification for iCloud. Confirmed other File Providers and unknown roots retain the journal and claim because NV cannot establish either cleanup rule.

On macOS 26+, if `Notes & Settings` advertises the required controls, prefer this bounded optimization:

1. Pause only the checkpoint item before the short replacement.
2. Install and verify the checkpoint.
3. Outside every coordinator accessor, request fail-on-conflict upload.
4. Accept success only when the request token, returned `NSFileVersion`, installed local-version identifier, and checkpoint ID all match the current receipt.
5. Resume with preserve-local-changes behavior on every path.

Keep this OS-version split in one private checkpoint-transfer helper in `NVRootSession.m`. It consumes one `NVCheckpointReceipt`, owns pause/upload/resume and stale-callback rejection, and returns only `confirmed`, `pendingOrUnknown`, or `actionableError` for that same receipt. `SyncSessionController` continues to see only the provider participant's running/error/uncommitted/status surface; it never correlates request tokens or version identifiers itself. No checkpoint-transfer controller or public protocol is needed.

Pause acquisition failure falls back to ordinary iCloud synchronization and does not itself fail quit. Once pause succeeds, upload ambiguity, conflict, returned-version mismatch, or resume failure retains the journal and host claim. Unsupported controls use the ordinary fallback. On older systems, only the specified complete post-install upload transition plus exact local read-back can qualify; ambiguity remains pending/unknown.

The existing quit waiter presents the retry/error/override behavior. **Quit Anyway** preserves the old or newly installed checkpoint as applicable, the journal, active claim, unresolved versions, and all unconfirmed state for next startup. A successful local checkpoint is never rewritten by `applicationWillTerminate:`.

## Root moves, folder switching, and storage transitions

### Provider/Finder root move

`presentedItemDidMoveToURL:` runs on the provider queue. Verify the reported URL against the directory descriptor, refresh the root file-reference URL/bookmark and matching current-host journal claim, rebuild the FSEvents watch, increment the structural generation, reclassify, and schedule a fenced reconciliation. A verified path-only move does not replace the root session; the open descriptor and presenter still represent the same root. Failed identity verification or an authority/account change closes it and opens a fresh incarnation, so old in-flight work can only be discarded.

The application no longer offers its own whole-directory relocation operation. Moving an individual note remains an ordinary coordinated rename.

`NSUbiquityIdentityDidChangeNotification` follows the same fail-closed boundary: freeze provider mutations, preserve the active journal, replace the root session/classification with `unknown`, invalidate current-known evidence, and reclassify asynchronously. Do not persist or log the iCloud identity token.

Presenter deletion/unavailability callbacks likewise cancel provider publication and enter the existing retry/choose-folder UI after invoking Apple's accommodation completion. NV does not continue mutating an unverified replacement merely because the old directory descriptor remains open.

### Choosing another notes folder

Treat switching as old-session quit without process termination:

1. quiesce old-root edits;
2. settle WAL/note/reconciliation work;
3. install the old-root checkpoint and satisfy its applicable durability choice, or explicitly leave its journal for recovery;
4. remove/drain the old presenter and close the old session;
5. open a fresh session for the new root; and
6. update the saved global bookmark only for a permanent switch.

A temporary-folder app instance creates its own current-host active-journal entry keyed by its journal ID without changing the saved default bookmark. Matching is by resolved rooted-directory identity, not by which bookmark is global.

### Controlled storage-contract changes

A passphrase, encryption, or storage-format change is not a live preference mutation. Route every such change through one controlled-restart transaction: freeze edits, settle the current WAL/note/reconciliation obligations, install and verify a complete checkpoint under the old contract, retire the old journal only after its applicable durability barrier, install and verify the target representation described below, and restart before accepting another edit. Startup then creates the one fresh process journal under the new contract. A failed attempt leaves either the old journal plus checkpoint or the complete old-contract checkpoint alone; it never leaves one process writing a journal under two contracts.

Reuse the existing `NotationPrefsViewController` disclosure and `_finishExternalEditingForAction:informativeText:continuation:` boundary, the existing `PassphraseChanger`, and the all-note `requireFileWrite` admission loop currently embedded in `databaseSettingsChangedFromOldFormat:`. Extract the latter as the conversion admission step instead of adding a transition controller or another export scheduler. Do not mutate the stored target preferences until the final target checkpoint has been verified and the restart can be committed.

For an ordinary encryption, passphrase, or non-iCloud storage-format change, serialize the unchanged complete live store under the target settings and install it through `NVCheckpointTransaction` before restart. Replace the existing live encryption/format preference callbacks with this path. No migration ledger or compatibility for an unreleased intermediate epoch-5 state is needed.

### Entering first-class iCloud mode

Derive mode every time from confirmed iCloud classification, `PlainTextFormat`, and encryption disabled. Store no mode preference.

Before conversion, explicitly warn that first-class iCloud interoperability stores note contents, filenames, and provider metadata as unencrypted plain text visible to other applications with folder access.

Use the controlled-restart transaction above, but replace its ordinary same-store conversion step with the first-class export: export every note through the existing plaintext atomic writer, verify an unchanged exact provider catalog/version fence, install and verify the complete unencrypted checkpoint, and restart into a fresh journal. Reuse the existing preferences/storage-conversion and plaintext atomic-writer code. The old checkpoint format is the only restart marker; export is idempotent and divergent preexisting files enter normal reconciliation. Do not add a migration ledger.

A provider move that places an incompatible active root in iCloud invokes the same blocking choice: convert/restart, choose another folder, or quit. Journal-durable admitted edits remain recoverable while the choice is pending.

If the legacy exact-name journal appears while a modern session is active, stop new filesystem mutations, preserve the modern journal, and ask the user to quit every NV process and relaunch modern NV. Concurrent epoch-4 and modern editing is unsupported.

## User-visible state and diagnostics

Keep presentation smaller than the internal state machine:

- A current, materialized checkpoint opens with no sync UI.
- Startup materialization/rebuild/recovery shows one progress view with cancel where cancellation is safe.
- Working offline remains visibly marked until a current-known reconciliation succeeds.
- Routine synchronization uses the existing activity indicator/status menu. A successful text merge is silent; all alternatives preserved by one transaction produce one coalesced conflict notification.
- The UI reports checkpoint upload pending/unknown or an actionable error. It does not distinguish “saved in WAL” from “saved to a local note file.”
- Database versions appear as nonmodal **Recover Notes**/**Discard** candidates. Unclaimed iCloud journals expose **Recover Notes** only and are never presented as discardable evidence.
- Quit uses the existing wait/error/override UI.

Storage diagnostics must remain content-free: operation, item count, error domain, and error code only. Do not log note text, filenames, tags, paths, bookmark bytes, persistent version identifiers, account identity, keys, or path-bearing error descriptions.

Do not add a diagnostics subsystem or public header. New provider/recovery storage leaves return a typed result plus `NSError` and never log. `NVRootSession.m` contains one private reporting choke point backed by unified logging; it accepts only a closed operation enum, item count, and error domain/code and has no parameter capable of carrying a free-form message, item URL/name, `localizedDescription`, or `userInfo`. WAL completions report their typed failure to the main-thread/root-session owner through the same boundary. Replace direct `NSLog` interpolation only on storage paths brought under this architecture; unrelated legacy diagnostics need not be refactored preemptively. UI error presentation remains separate and may use localized user-facing text.

## File-level implementation map

| File | Proposed change |
| --- | --- |
| `NVRootSession.h/.m` | New session owner, presenter, ordered provider/presenter/FSEvents lane, coordination, classification, dirty/visibility state, private single-use checkpoint transaction and receipt, checkpoint-transfer helper, and diagnostics choke point |
| `AppController.m` | Asynchronous startup UI; monotonic pre-termination checkpoint flow; remove app relocation command |
| `NotationController.h/.m` | Own active root session; structural generation; initialize from and retain exact checkpoint bytes/ID; keep existing pending-write sets as sole obligation registries; immutable WAL/file-attempt capture; extend existing tombstone hooks; no termination write |
| `NotationDirectoryManager.m` | Extend the existing transaction with immutable prepared values; implement the decision matrix as one pure private function; perform version enumeration, exact fences, partial preservation, recovery/rebuild; construct note objects only on the main thread |
| `NVRootedDirectory.h/.m` | Accessor-URL validation/adaptation, root bookmark refresh, fixed directory lock, minimally expose exact catalog; remove relocation method |
| `WALController.h/.m` | Versioned integrity header/name, one ordered journal-activation/cleanup API, independent serial queue, current-host preference helpers, immutable record input; correct the legacy reader to stop at the first invalid/torn record |
| `StartupRecovery.m` | Legacy-before-modern and evidence recovery through the shared prepared-value transaction and the root session's checkpoint-transaction entry point |
| `NoteObject.h/.m` | Mutation-time LSN; immutable write-intent capture; provider-version ancestry archive field |
| `DeletedNoteObject.h/.m` | Identity-bound intentional tombstone and provider ancestry even without legacy sync metadata |
| `FrozenNotation.h/.m` | Optional checkpoint ID and exact verification support while keeping epoch-4 core readability |
| `NSData_transformations.h/.m` | SHA-256 plus a UUIDv5 wrapper over the existing SHA-1 helper, and the canonical tagged checkpoint-base-identity codec |
| `SyncSessionController.h/.m` | One provider participant in existing status/wait/error aggregation |
| `NotationPrefs.m`, `NotationPrefsViewController.m` | Route passphrase, encryption, and storage-format changes through controlled restart while reusing existing disclosure, external-editing shutdown, passphrase, and all-note export admission; no iCloud mode bit or migration ledger |
| Xcode project | Add `NVRootSession`; link `FileProvider.framework` only if AV-09 validates its classification use; add only entitlements proven necessary by AV-13 |

Private intent/result/evidence objects should remain in the implementation file that consumes them. Split them into separate files only if Objective-C compilation dependencies force it.

## Formal-state mapping

| Model concept | Concrete implementation state |
| --- | --- |
| active/root session | fresh `NVRootSession` UUID plus active object identity |
| dirty obligation | provider-queue dirty generation plus coalesced pre-visibility projections |
| provider catalog token | exact `NVRootedDirectoryCatalog` object |
| provider version set | `NSSet` of retained opaque `NSFileVersion.persistentIdentifier` values |
| note-changed fence | captured note UUID/LSN pairs |
| structural-changed fence | main-thread `NotationController` structural generation |
| unsettled local note/WAL work | existing main-thread `pendingFileWrites`/`pendingJournalWrites` membership; immutable attempts never become a second obligation registry |
| represented versions | optional ancestry archived in `NoteObject`/`DeletedNoteObject` |
| resolution eligibility | transient root-session map populated only by complete exact commits |
| accepted/verified checkpoint | one immutable receipt produced by the private single-use checkpoint transaction, containing exact bytes, canonical checkpoint identity, installed local-version ID, request identity, and covered recovery-version set |
| active journal | versioned integrity header plus one synchronized current-host `NVActiveJournal.<journalID>` claim, exposed for editing only by the ordered activation entry point |
| journal creation count | exclusive random filename creation; failed/colliding IDs are burned |
| quit phase | monotonic main-thread AppController state |

This table is the refinement boundary for the TLA+ state. Do not substitute timestamps, paths, pointer reuse, callback order, or upload-status text for any modeled identity or fence.

The implementation boundaries trace to the existing contracts as follows; this is a review index, not another source of requirements:

| Boundary | Governing decisions | Formal reference |
| --- | --- | --- |
| root open, checkpoint currentness, offline choice, rebuild | ADR-0001, ADR-0002, ADR-0012 | `StartupSafety` |
| journal activation, replay, and cleanup | ADR-0005, ADR-0006, ADR-0007, ADR-0009, ADR-0010 | `JournalLifecycle`, `JournalRecoverySafety` |
| note reconciliation and provider-version evidence | ADR-0001, ADR-0003, ADR-0010, ADR-0012 | `ReconciliationInterface`, `ReconciliationDecisionSafety`, `ReconciliationFencingSafety`, `ReconciliationSafety`, `RecoveryEvidenceSafety` |
| checkpoint transaction, upload qualification, and quit override | ADR-0004, ADR-0008 | `QuitSafety`, `RecoveryEvidenceSafety` |
| passphrase/encryption/storage conversion | ADR-0011 | `StorageTransitionSafety` |

## Implementation sequence

Each slice should leave the existing local-filesystem path working:

1. **Identity foundation:** canonical checkpoint-identity codec, modern versioned journal header/name, ordered journal activation/cleanup, fixed directory lock, current-host claim, epoch-4 compatibility vectors.
2. **Execution separation:** immutable WAL records and durability queue; `NVRootSession` provider queue/presenter with one serial underlying callback queue; move existing note-file work off-main without changing its CAS algorithm or duplicating its pending-write registries; remove blanket FSEvents `IgnoreSelf`.
3. **Provider discovery/startup:** classification, exact-item checkpoint status/materialization, coordinated shallow catalogs, startup progress/offline choices, root moves.
4. **Transactional versions:** current/other/unresolved/nonlocal enumeration, batch reads, exact dual fences, pure decision function, deterministic complete/partial publication, provenance/tombstones.
5. **Recovery and rebuild:** all-version database Recover Notes/Discard, Recover Notes-only unclaimed journals, strict valid-prefix replay, deterministic UUIDv5, safe-default all-or-nothing rebuild.
6. **Quit and transitions:** closing barrier before presenter removal, one private checkpoint transaction used by every local checkpoint installation, exact receipt, sync-controller participant, macOS 26 upload optimization/fallback, and controlled-restart encryption/storage conversion.

Do not start with the macOS 26 upload optimization. It depends on the exact checkpoint receipt and quit state but does not define either one.

## Verification architecture

Keep the production design concrete. Tests can subclass `NVRootSession` or `NVRootedDirectory` in the test target to inject provider callbacks and fence values; a production provider protocol solely for mocking is unnecessary.

Add focused deterministic checks for:

- UUIDv5 vectors through the existing SHA-1 helper, SHA-256 vectors, canonical checkpoint-identity round trips, malformed tag/length rejection, and checkpoint-ID round trips;
- epoch-4 opening a clean epoch-5 checkpoint via `tools/test-epoch4-v5-compatibility.sh`;
- journal magic/version/CRC validation; every create/header-sync/claim/claim-sync crash point returning no writable handle; cleanup retaining the claim until removal is directory-durable; UUID collision retry, current-host matching, copied roots, and directory-lock exclusion;
- valid-prefix recovery stopping at corrupt framing, length, decompression, checksum, archive, class, and semantic records without processing a later record;
- mutation-time UUID/LSN fencing, the existing pending sets remaining the sole obligation source, and stale file-write completions never clearing a newer set entry;
- catalog and version-ID equality changing independently;
- version-only callbacks selecting an item whose catalog metadata did not change;
- normal startup and complete reconciliation with Spotlight disabled, the root excluded from Spotlight, and the metadata index rebuilding or broken;
- immediate-metadata-only exact probes using promised-item resource values, plus ordinary coordinated shallow catalogs over dataless folders proving whether child names/placeholders are complete without materializing unchanged note contents;
- candidate discovery after current-file deletion/rename and for nonlocal versions whose current URL is absent;
- every one of the twenty-two exactly named conflict-matrix fixtures under every version traversal order;
- complete publication versus additive partial preservation and persistent ancestry;
- a presenter notification delivered before its catalog mutation becomes visible, plus NV's own FSEvent arriving after a provider-lane write and causing at most an idempotent follow-up transaction;
- stable closing while the presenter remains registered, followed by unregister/drain with no post-removal reconciliation restart;
- root-session replacement with identical visible inputs and late callbacks;
- no provider or network operation on the main thread and WAL progress while provider work is stalled;
- every checkpoint-installing caller routing through the private transaction; exact checkpoint byte read-back/decode/ID/local-version checks; single-use enforcement; and rejection of every mismatched receipt request, local-version, checkpoint-identity, and recovery-coverage combination;
- quit reentry, every pre-checkpoint failure, override, pause/upload/resume correlation, fallback, and next-launch paused-item repair;
- startup current/stale/unmaterialized/offline/rebuild branches and no partial store publication;
- rebuild safe defaults with no recovered settings or deletion inference;
- batch preparation completion exactly once after nested accessors on every exit;
- ordinary passphrase/encryption and first-class iCloud controlled-restart paths;
- diagnostics proving storage leaves return errors without logging and the root-session choke point emits only operation/count/error-domain/error-code fields; and
- provider/Finder root moves and deep root paths.

Extend the existing integration-test harness and filesystem capability matrix rather than introducing another runner. Use real iCloud tests for API behavior that a fake cannot establish, while deterministic test doubles cover race orderings and failures. [Apple API Contract Validation](../Apple-API-Contract-Validation.md) is the acceptance matrix for behaviors that mocks and the TLA+ models cannot prove. Run every applicable configuration in [the TLA+ README](../tla/README.md) whenever implementation-driven behavior changes require adjusting the models; never weaken a modeled safety predicate to fit the code.

## Deliberate omissions

This architecture does not add:

- a second synchronization database;
- a second pending-write registry, public checkpoint transaction/controller, or diagnostics subsystem;
- CloudKit or direct Dropbox integration;
- vector clocks, UUID xattrs, sidecars, or a provider-event ledger;
- periodic checkpointing, journal sealing/rotation, writer IDs, or legacy WAL aliases;
- whole-checkpoint restore/export or a version picker;
- a stored first-class-iCloud mode flag;
- concurrent provider lanes;
- any correctness or liveness dependency on Spotlight or `NSMetadataQuery`;
- application-driven whole-root relocation;
- compatibility for unreleased intermediate epoch-5 designs; or
- the proposed future RNCryptor/FSNotes separate-file format.

Those omissions are part of the design: the existing live model, exact checkpoint, append-only process journal, individual note files, Apple version evidence, and exact transactional fences already cover the specified authority and recovery boundaries.
