# iCloud Drive implementation architecture

Status: proposed implementation architecture for the working epoch-5 specification

This document translates the normative requirements in [Robust iCloud Drive Support](../iCloud-Drive-Support-Spec.md), the [ADRs](../adr), the [TLA+ models](../tla/README.md), and the vocabulary in [CONTEXT.md](../../CONTEXT.md) into an implementation shape for the existing Objective-C application. [Foundation safe-replacement migration](../Foundation-Safe-Replacement-Migration.md) is the required refactor plan for collapsing the existing-file replacement capability ladder after its behavior gates preserve [Atomic Note Saves](../Atomic-Note-Saves.md). Those sources remain authoritative if this proposal differs from them.

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

This is not a distributed database. `NSFileCoordinator` coordinates local processes and the local File Provider extension. Separate note files carry routine cross-Mac changes; the selected provider transports them. `Notes & Settings`, database versions, and journal artifacts provide startup and recovery evidence.

## One new stateful production component

Add `NVRootSession.h` and `NVRootSession.m`. Do not add a provider abstraction, operation subclass hierarchy, synchronization database, or CloudKit layer. Private transaction/receipt values, shared encoding helpers, and the root session's private diagnostic function own no independent workflow and do not enlarge this component boundary.

`NVRootSession` conforms to `NSFilePresenter` and owns everything whose validity is limited to one opening of one notes directory:

- a retained `NVRootedDirectory`;
- a fresh random session-incarnation UUID;
- a private serial dispatch queue installed as the `underlyingQueue` of a private `NSOperationQueue` with `maxConcurrentOperationCount = 1`; the operation queue is both the provider lane and `presentedItemOperationQueue`, and FSEvents targets the underlying dispatch queue;
- the root presenter registration;
- one vnode dispatch source attached to the existing rooted-directory descriptor for delete, rename, and revoke events;
- storage authority (`provider-managed`, `ordinary local`, or `unknown`), plus opaque File Provider domain identity when available;
- authority-fenced/provisional/active publication state, lifecycle quiescing/closing/closed state, transient root continuity (`confirmed`, `inconclusive`, or `confirmedGone`), and independent transient journal-durability status that can select the controller's edit-admission gate;
- cancellation and dirty-generation state, plus one session-scoped exact-versus-current-visible discovery scope derived from the actual version-enumeration result;
- the last accepted catalog and version-set fences;
- a runtime physical-state map per note UUID (installed filename, snapshot/base, and last applied LSN), in-flight note-write generations, and a transient map from eligible persistent version identifiers to the candidate identity needed for later coordinated resolution;
- the matching current-host active claim, retained claims, and exact represented-journal set associated with this opened root; and
- the fixed per-directory lock, held continuously for the root-session lifetime.

The instance UUID is the root session incarnation used by reconciliation fences. A verified same-directory move under unchanged provider authority keeps the object and UUID. Reopening the root creates a fresh object. A confirmed provider authority/account change authority-fences the old object and creates a provisional replacement with a new UUID even when the URL, filesystem identity, and visible files are identical. The old presenter, FSEvents stream, and vnode source are drained without closing the transferred descriptor; the provisional successor takes the directory lock, active journal, pending obligations, and successor-owned observers. It becomes the active publication session only after namespace and journal revalidation. Ambiguity leaves it provisional, with provider publication frozen and healthy WAL durability continuing. Late work need only compare its captured object/UUID with the active session; no global counter is required.

Confirmed root loss cancels the old or provisional object; opening a replacement or a **Save Current Collection As…** destination creates a fresh session rather than retargeting it. The directory lock and active journal descriptor remain continuously held until root closure has drained provider work and settled journal ownership. Ordinary folder switching and **Re-open from Disk** release them with the old session before opening the selected root; **Save Current Collection As…** instead keeps the canceled old session and its evidence open while an unattached destination is constructed, then closes the old session only after the new checkpoint is accepted.

After the stable provider barrier has atomically marked the session closing, cancel and drain the vnode source, stop/invalidate the FSEvents stream, remove the presenter, and use the operation queue's `addBarrierBlock:`. The serial underlying queue orders already-enqueued vnode/FSEvents work with presenter/provider work, while the operation barrier drains presenter callbacks already submitted to the operation queue. Ordinary closure closes the rooted descriptor only after the dispatch-source cancellation handler has run. Authority handoff instead uses a cancellation path whose handler releases only the old source; descriptor ownership has already transferred to the successor and remains open for its replacement source. This replaces custom thread draining, condition variables, and polling.

`NVRootSession` should have a deliberately small public surface: open/discover authority, enqueue a prepared note-file attempt, mark reconciliation dirty, quiesce, install/upload a checkpoint, and close. Reconciliation details remain private methods in `NotationDirectoryManager.m`; WAL details remain in `WALController.m`.

Every potentially blocking entry point is completion-based. Provider work starts on the session queue and delivers its immutable result on the main thread; no caller uses `waitUntilFinished`, a semaphore, or `dispatch_sync` to turn it back into synchronous main-thread I/O.

Use small typed open, close, local-checkpoint-install, and upload-qualification outcomes wherever a Boolean plus `NSError` would make the caller guess whether work was installed, remains pending, or needs user action. Keep these as enums and immutable result values, not operation subclasses or a protocol hierarchy. Each root operation is single-flight and advances monotonically; a repeated completion or stale callback can only be rejected.

This project uses MRC. `NotationController` owns the root session; the session's callback target is non-owning. Blocks submitted to queues copy only immutable values plus the root session needed to keep the operation alive, and every completion checks active incarnation/cancellation before publication. Closing breaks notification registrations and target links before the final releases.

## Existing components and their retained responsibilities

### `AppController`

`AppController` remains responsible for visible lifecycle decisions:

- displaying startup materialization/recovery progress;
- presenting quit, choose-folder, work-offline, retry, and explicit quit-override choices;
- presenting the confirmed/inconclusive root-loss action matrix, **Save Current Collection As…**, **Recover Notes**, **Discard**, **Recover Interrupted Changes**, **Recover Notes from Journals**, **Rebuild from Note Files**, and **Create a New Notes Collection Here**; the storage owners below prepare and execute these actions, while `AppController` owns their sheets, progress, cancellation, and final result presentation;
- selecting the controller's lifecycle-quiescing edit-admission reason before termination or a controlled storage transition, and presenting the distinct durability-suspension UI when the root session selects that reason;
- maintaining a monotonic termination phase; and
- invoking the existing `SyncSessionController` wait callback.

Move checkpoint creation out of `applicationWillTerminate:`. That callback must only close resources and save UI preferences. Add the monotonic termination phase described below; a reentrant termination request observes it and neither starts another checkpoint nor rewinds the phase.

### `NotationController`

`NotationController` remains the sole live-store authority. Its existing sets and arrays remain the source used by synchronous search and UI code.

Add only the state that belongs to the live model:

- the active `NVRootSession`;
- a runtime structural generation;
- the exact accepted checkpoint `NSData`, checkpoint identity, and available local `NSFileVersion.persistentIdentifier` captured together at acceptance;
- intentional tombstones even when no legacy sync service metadata exists.

Do not add another pending-intent registry. The existing main-thread `pendingFileWrites` and `pendingJournalWrites` sets remain the sole durable-work obligation registries and retain the existing typing coalescing contract. At a timer or explicit durability boundary, capture immutable UUID/LSN/value input from the currently pending note and submit that attempt. A completion removes the note from its existing set only when the live UUID/LSN still equals the captured generation; otherwise the same set entry continues to represent the newer obligation. `NVRootSession` tracks only an in-flight attempt and the physical state it actually observed or installed, not a second scheduler.

Keep one main-thread edit-admission check in `NotationController`, immediately before a logical mutation increments its LSN, backed by a small reason bitmask rather than two gates. `AppController` selects `lifecycleQuiescing` before termination, root closure, or a controlled transition and clears it only when that operation cancels before commit. `NVRootSession` selects `journalDurabilitySuspended` only for local journal-durability uncertainty, not provider-authority discovery, and clears it only after the specified revalidation. Either bit rejects the mutation and clearing either leaves the other effective. When durability suspension is delivered after an AppKit edit has already entered the current main-thread callback, admit that current value exactly once, then reject subsequent mutations and submit every `pendingJournalWrites` generation immediately instead of waiting for the ordinary coalescing timer. The existing pending set remains the status and retry truth; lifecycle and durability retain their own state, UI, and retry owners, and no second mutation choke point, durability queue, or ledger is introduced.

The structural generation increments when a note is added or removed, a filesystem name changes, or serialization/storage policy changes. Root-session replacement is fenced by the never-reused incarnation UUID and does not require a redundant structural-generation increment. A verified move of the same open root under unchanged provider authority changes neither fence. Ordinary content/title/tag edits continue to use the note UUID and existing LSN as the finer fence.

Increment the LSN when a logical mutation is admitted to the live store, not later when the WAL happens to encode it. The same UUID/LSN then names the live generation, the WAL record, the separate-file intent, and the reconciliation fence.

### `NVRootedDirectory`

Keep all existing descriptor-relative catalog, snapshot, compare-and-swap, atomic-install, rename, delete, and directory-synchronization code through execution separation. It already supplies the hard part of NV's no-`PATH_MAX`, move-tolerant semantics. Then follow [Foundation safe-replacement migration](../Foundation-Safe-Replacement-Migration.md): retain the descriptor safety envelope and exclusive-create ladder, but replace the APFS swap, HFS+ exchange, and limited-filesystem existing-destination implementations with one private Foundation backend after their contract and filesystem deletion gates pass.

Add four narrow capabilities:

1. Validate that a coordinator-provided URL still denotes this rooted directory or one of its direct child names, then perform the existing descriptor-relative operation. The URL is consumed inside the accessor and is never cached as an operational path.
2. Refresh the transient file-reference URL/bookmark after a presenter-reported root move, but only after verifying that it resolves to the directory already held open.
3. Open and validate the fixed modern directory lock by relative name.
4. Supply the root descriptor through a private implementation-only accessor so `NVRootSession` can attach its vnode dispatch source without taking ownership or converting it to a path.

The replacement backend is not a fourth public write API. Existing create, conditional-replace, and overwrite entry points retain their semantic meanings and `NVFileWriteResult` dispositions. For a conditional write, generate a fresh random-UUID hidden backup name, prove it absent relative to the rooted descriptor without following symlinks, and regenerate on collision before asking Foundation to retain the displaced original there. The existing exact-byte comparison and recovery rename then delete or preserve it. The residual deliberate race against an unseen UUID leaf is not a separate security boundary for a process that can already modify the notes directory. Every leaf file-reference URL is operation-local and expires across replacement. The resulting URL is candidate evidence; a rooted reopen and retained-descriptor identity check establish the installed item.

Promote the existing `NVRootedDirectoryCatalog` just enough for `NotationDirectoryManager` and `NVRootSession` to retain and compare it. Its exact equality is the opaque provider catalog token required by the spec. Do not invent a second catalog digest, ordering, or generation number.

Remove the app-initiated `relocateIntoDirectoryReferenceURL:` convenience path and its AppController command. Finder/File Provider moves remain supported through the open descriptor and presenter callback.

### `NotationDirectoryManager`

Retain and extend the private `NVDirectoryTransaction`, but change its background staging payload to immutable prepared-note values. It already provides the shape needed for all-or-nothing publication on the main thread.

It should become the one deterministic reconciliation kernel for:

- ordinary background scans;
- startup rebuild from note files;
- note-file conflict handling during local writes; and
- recovery-note import from database and unclaimed-journal evidence.

Private value objects can live in `NotationDirectoryManager.m` rather than becoming public classes. At minimum the transaction needs its exact or current-visible discovery scope, first and second catalogs, first and second selected version-ID sets, historical-enumeration completeness, unreadable versions, captured root incarnation, captured structural generation, affected UUID/LSN values, prepared mutations, additive preservation artifacts, and resolution candidates.

Make the decision matrix one private pure function in `NotationDirectoryManager.m`. It receives only immutable catalog/model/version/base/identity values and returns prepared mutations, ancestry, tombstones, and resolution candidates in `NVDirectoryTransaction`. It may call `NVMergedText` and the existing filename/content/identity helpers, but it cannot access the filesystem, queues, `NotationController`, or a live `NoteObject`. Provider code builds its input; the main-thread publication path constructs or updates note objects from its output. Do not add an `NVCandidateBuilder` class for this single function.

Key its table-driven tests by the exact twenty-two scenario identifiers in `ReconciliationDecisionSafety.tla` and run every applicable canonical/unresolved/nonlocal traversal permutation. Sharing those names keeps each implementation fixture visibly tied to the independent formal oracle without making production code parse or depend on a TLA+ file.

Provider work may copy bytes and produce those immutable values, but it must not construct or decode `NoteObject`/`DeletedNoteObject`, initialize their display/search/date caches, attach labels, or consult main-thread preferences. Perform that work on the main thread during fenced publication. This preserves the existing cache and preference assumptions without first making the legacy object graph thread-safe.

Treat prepared reconciliation and recovery publication as external synchronization rather than an undoable user edit. Reuse `-[NoteObject applyPreparedFileStateFromNote:]` for updates, including its existing per-note undo-history clearing, and add imported notes through the existing non-undo-registering transaction path. The single edit-admission check also governs undo and redo because either operation is a logical mutation; a blocked undo/redo leaves its undo stack unchanged.

Adopt the normative identity-first order as an intentional epoch-5 correction to the current filename-first implementation: first associate every unique stable local filesystem identity across the candidate set, then apply unambiguous filename matching to the still-unmatched candidates, and finally use unambiguous content matching as the portable last resort. This prevents a newly created file that reuses an old name from capturing the UUID of the original file after that original was renamed. A same-name safe replacement still reaches filename fallback when no unique stable-identity association exists. Do not add UUID extended attributes or sidecar files.

### `WALStorageController` and `StartupRecovery`

Keep the existing record framing, compression stream, encryption behavior outside first-class plaintext mode, checksum validation, UUID/LSN coalescing, and legacy exact-name reader. Correct the recovery loop to implement strict valid-prefix replay: framing, length, decompression, checksum, archive, class, or semantic failure stops at that record. A torn final append yields only the complete valid prefix before it. Never skip an invalid interior record and resume with later records, and never truncate or repair the discovered artifact in place.

Modernize ownership without replacing the record body:

- a modern journal is `Interim Note-Changes.<journalID>`;
- an integrity-checked fixed-prefix/variable-identity header uses exactly the magic, version, field order, big-endian lengths, UUID/base bytes, and CRC coverage in the normative [epoch-5 persistence-format appendix](../iCloud-Drive-Support-Spec.md#epoch-5-persistence-format-appendix);
- the header is followed by the existing framed compressed records;
- the fixed hidden `.nv-root.lock` file defined by that appendix excludes another local modern writer;
- failure or lack of advisory-lock support refuses writable modern operation;
- modern journals do not use inode locking;
- the legacy exact-name path retains its existing inode-lock behavior; and
- the modern file descriptor remains open for the active root-session lifetime.

The WAL queue should receive an already archived immutable note or tombstone record. At the existing coalesced write boundary, archive the latest pending generation on the main thread and submit those bytes; never dereference a mutable `NoteObject` on the WAL queue. The queue performs compression, encryption, append, short-write recovery, and synchronization in order. An attempt becomes durable only after its bytes have left the short-write outbox and `NVBarrierSyncFileDescriptor` succeeds; `write` success never clears `pendingJournalWrites`. Append, outbox-drain, or barrier failure posts one main-thread durability error, selects the root session's journal-durability suspension, and leaves the in-memory state and journal obligation available for Retry or **Save Current Collection As…**.

Journal create/header sync and final journal deletion pass through the provider lane because they change the provider namespace. Ordinary append and `fsync` use the already-open descriptor on the independent durability lane; they do not enter a coordinator accessor.

Expose journal activation, active-to-retained demotion, and cleanup as ordered `WALStorageController` entry points, not as separately callable file and preference steps. Activation exclusively creates the random journal path, writes and barrier-synchronizes the complete header, synchronizes the directory, writes the matching current-host active claim, calls `CFPreferencesSynchronize`, and only then returns an append-capable writer. Demotion writes and synchronizes the retained claim before removing and synchronizing the active claim. Cleanup coordinates journal removal and directory synchronization before removing and synchronizing whichever same-host claim remains. Any failure returns a conservative result: no half-published writer, and no claim is cleared early. Add direct CFPreferences helper functions in `WALController.m`/`StartupRecovery.m`; do not introduce a registry object.

`StartupRecovery.m` remains the policy owner for legacy-before-modern replay, base matching, unclaimed-journal recovery, and replacement-checkpoint cleanup. It preserves record order inside each strict valid prefix while assigning no order between journals: equal already-represented states are idempotent, a later same-journal record may supersede an earlier one, and no record from another journal may resurrect an applied deletion or silently overwrite a differing state. It should use the same prepared-value transaction and the root session's private `NVCheckpointTransaction` entry point rather than a new recovery store or a direct checkpoint write.

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
| `NSFileManager replaceItemAtURL:...` | One validated safe-replacement backend for an existing regular file, inside NV's descriptor and exact-verification envelope | Separate APFS swap, HFS+ exchange, limited-filesystem rename, and provider-checkpoint replacement implementations after the migration gates pass |
| `NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly` | Exact root/checkpoint probes whose accessor uses promised-item resource values only, subject to AV-01 | Accidentally materializing file contents merely to classify or select work |
| `prepareForReadingItemsAtURLs:...` | Batch preparation of only selected changed versions | One provider round trip per selected file |
| `NSFileVersion` | Current, unresolved, other, and nonlocal immutable version evidence | Invented vector clocks, xattrs, or arrival-order conflict selection |
| Ubiquitous-item resource keys | Current/materialized/uploading/error/paused state | Guessing cloud state from POSIX success or timestamps |
| macOS 26 `NSFileManager` sync controls | Optional checkpoint pause/upload/resume and returned-version correlation | A custom persistent pause/upload state machine |
| `NSFileProviderManager` URL identity, when its consumer contract is validated | Establish provider management and opaque domain continuity | Provider-name/path heuristics; an inconclusive result remains `unknown` |
| File-reference URLs and bookmarks | User selection and provider-reported move refresh | Stored absolute paths |
| `NSProgress` | Startup/rebuild/recovery progress model bound to existing Cocoa UI | Bespoke progress notifications |
| Unified logging (`os_log`) behind a field allowlist | Content-free storage diagnostics | Ad hoc `NSLog` calls that can interpolate filenames, paths, or `NSError.userInfo` |

The initial architecture deliberately does not use `NSMetadataQuery`. It is backed by Spotlight, has no documented completion deadline or provider-snapshot completeness contract, and therefore cannot gate startup, reconciliation, rebuild, dirty clearing, or any `current-known` claim. It may be added later only as an advisory progress or wakeup source whose absence and wrong/incomplete results do not change behavior. `NSFileVersion` IDs are opaque equality values, not clocks. `NSFileCoordinator` is not a cross-Mac lock and does not make the checkpoint and journal a distributed transaction.

Capability discovery is operation-scoped rather than a provider profile. Guard API availability, read an explicit per-item option set where Apple supplies one, then let the real asynchronous call decide success, unsupported, conflict, transient failure, or unknown. An advertised bit, selector availability, prior success, or success for another item is never completion evidence. APIs without a capability bit are simply attempted with their documented fallback. Only the `CAP-01` historical-version result promotes the active root session to current-visible scope; transient, ambiguous, differently scoped, and ordinary failures retain the ordinary retry/unknown obligation. NV persists no capability matrix and rechecks every safety-sensitive result.

Provider identity is intentionally narrower. Positive ubiquitous-item or File Provider URL identity establishes a provider-managed root; an opaque domain identifier may fence authority continuity. Neither result names iCloud, Dropbox, or another vendor. `-[NSFileManager ubiquityIdentityToken]` identifies iCloud account availability rather than ownership of an arbitrary selected URL, and app-container URLs do not classify NV's user-selected external root. Display names are UI-only. Do not parse paths, domain identifiers, private xattrs, or display names. iCloud remains the tested first-class configuration; other providers receive whatever standard operations they successfully support without a product guarantee.

Do not adopt `NSDocument`, `NSFileWrapper`, Core Data, CloudKit, a file-provider SDK, or a third-party queue/promises library. They would duplicate NV's authoritative in-memory model or weaken its existing atomic writer without satisfying the cross-file durability rules.

Link `FileProvider.framework` only if its URL-domain identity contract passes the independent validation matrix; use it for provider membership and opaque authority continuity, never provider naming. Use NV's normal LaunchServices app identity for macOS 26 sync controls; the validated contract requires a stable bundle identifier but no iCloud entitlement, Developer ID certificate, or notarization ticket. Do not create or migrate into an app-owned ubiquity container. Every sync-control call remains availability guarded and gated by the per-item option set plus actual operation result; macOS 11.5 through 15 uses the specified conservative fallback. [Apple API Contract Validation](../Apple-API-Contract-Validation.md) records every Apple behavior this design still requires and its fail-closed fallback.

## Coordination rules

Create a new `NSFileCoordinator` for each logical operation, initialized with the root presenter. The transaction may expose its current coordinator only long enough for cancellation; never reuse it as a long-lived session coordinator, and never hold an accessor while waiting for upload.

The provider queue follows these rules:

- For an exact root or checkpoint probe whose accessor reads only resource metadata, use `NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly` and `promisedItemResourceValuesForKeys:error:`. Never read file content or enumerate directory children under that option; a shallow catalog always uses an ordinary coordinated root read off-main.
- Use asynchronous intent coordination for an individual read, write, delete, or rename.
- Use one multi-intent request for operations that must be locally ordered together. A rename has a moving source and destination intent in the same request.
- Call Apple's synchronous batch preparation API only from the provider queue. Inside its accessor, perform nested coordinated reads for the selected current and historical version URLs. If Apple invokes the batch accessor, invoke its supplied completion handler exactly once, after every nested accessor has returned, on every success, error, cancellation, and exception path. If AV-04's batch contract is unavailable or fails, use the same state machine with serial per-URL asynchronous coordinated reads; this changes latency only, not selected input or publication semantics.
- Do not rely on coordination to delay an ancestor/root move. The AV-08 matrix on macOS 14 and 26 allowed a root move to complete inside a batch-preparation accessor even though ordinary read, root-catalog, and replacement accessors delayed it. Operation-local file references and the rooted descriptor kept every tested physical access attached to the intended item. A verified same-directory, same-authority move therefore leaves the root session and structural generation unchanged, and the result may publish under its ordinary provider/model fences; a confirmed authority change fences the old session immediately and promotes its provisional replacement only after revalidation.
- Read a nonlocal `NSFileVersion` only from its coordinated accessor URL and finish that read before returning from the accessor.
- Use the accessor URL that Apple supplies. For a current direct child, validate it and hand only its leaf name to `NVRootedDirectory`; for a historical version outside the root, read the accessor URL directly with Foundation.
- Use moving/replacing coordination only for actual moves and the Foundation safe-replacement transaction. `NSFileCoordinator` does not provide expected-snapshot compare-and-swap: conditional writes select a checked fresh-UUID backup leaf, retain Foundation's displaced backup, compare its exact bytes, and preserve a mismatch through NV's existing exclusive recovery rename. Exclusive creation remains descriptor-relative.
- Coordinate a directory catalog read at the root, but do not assume this coordinates the contents of every child. Child contents are separately selected and prepared.
- Never dispatch the actual file access out of an accessor block after the block returns.

The presenter uses the provider queue rather than the main queue. Every accommodation method invokes its completion handler on every path. At session shutdown, first establish the stable provider barrier and atomically mark the session closing while the presenter remains registered. Only then remove the presenter before releasing it and submit a provider-queue barrier to drain callbacks already delivered.

Implement only the presenter callbacks that carry useful evidence: root move/deletion, subitem appear/change/move, and gain/lose/resolve version. A version callback records its URL and persistent ID. A generic callback records its affected direct-child name, or the whole note namespace for a root callback, and marks that projection as not yet provider-visible. Relinquish-to-reader/writer callbacks stop starting new provider operations, invoke Apple's supplied relinquishment block, then mark dirty when the reacquirer returns. They do not run reconciliation recursively inside the callback.

FSEvents remains a cheap best-effort wakeup for ordinary/local filesystems and missed provider callbacks. Target it at the provider operation queue's serial underlying dispatch queue so FSEvents, presenter callbacks, and provider state changes share one ordering domain without a forwarding queue. Remove `kFSEventStreamCreateFlagIgnoreSelf` when note writes move off the main thread: the existing implementation explicitly limits that optimization to main-thread-serialized writers. NV's own event may cause a redundant coalesced transaction, but the exact installed physical state and provider fences make that transaction harmless. Do not suppress all self events unless a later implementation can acknowledge the exact installed write rather than merely its process ID. Neither FSEvents nor a presenter callback proves visibility or publishes model changes directly.

## Dirty state and exact fences

Represent routine note reconciliation with one monotonically increasing in-memory note high-water mark plus coalesced visibility witnesses, not a clearable Boolean or an event ledger. Track fixed checkpoint/journal/lock and hidden `.nv-write-<UUID>` residue status with an independent artifact-status generation. A root callback may advance both, but completion or failure in one projection never clears or delays the other. The root session also holds one nonpersisted discovery scope: `exact`, or `currentVisible` after the required historical/nonlocal version call for an authoritative note candidate returns `NSCocoaErrorDomain/NSFeatureUnsupportedError`. A fresh root session starts by attempting `exact` again.

1. Every note-namespace presenter, FSEvents, materialization, retry, or provider-status event increments `dirtyGeneration` on the provider queue. Artifact-only events increment only the artifact-status generation.
2. A generic external-change callback coalesces its affected name into a small `preVisibilityFence` map, retaining the last accepted catalog/version projection that predates the callback. A root callback uses one whole-note-namespace projection. Repeated callbacks for the same projection do not create records per event.
3. In exact scope, a version callback can witness its projection only when its persistent ID appears in the transaction's exact version set, and a generic callback is witnessed only when a later exact coordinated catalog/version observation differs from its saved projection. In current-visible scope, a callback is discharged only when the stable current catalog/content observation or an explicitly delivered immutable version accounts for it. Checkpoint and journal observations cannot witness note-file events.
4. A transaction starts by capturing `dirtyGeneration` as `servicingGeneration`; any event delivered afterward creates a newer generation.
5. Complete exact publication may leave the session clean only when both provider fences and all main-thread fences match, `dirtyGeneration == servicingGeneration`, and every visibility witness through that generation has been discharged by the stable exact observation. Equality is used only to recognize that an old observation has not advanced; no ordering is inferred.
6. A current-visible transaction may consume the serviced generation only when the shallow namespace and every selected current state are complete/readable, both current-visible fences and all model fences match, no newer generation exists, and every through-generation callback is accounted for within that narrower scope. It records no resolution eligibility and leaves the root's limited-history status visible.
7. Partial preservation, failed fencing, cancellation, discard, unreadability, a transient or ambiguous incomplete enumeration, or an unwitnessed generation always leaves dirty and schedules one bounded-backoff retry. Stable unsupported history suppresses only retries whose sole purpose would be invoking that unavailable facility.

Because the presenter queue is serial, a notification queued while batch preparation is waiting will run afterward and create the next obligation. If provider state becomes visible before its callback, the second catalog/version fence fails first. If notification arrives first, the saved projection prevents an unchanged immediate retry from consuming it. The obligation remains conservatively dirty if the provider never makes the indicated state observable; backoff prevents a hot loop, and weak fairness does not permit NV to invent completion. The required callback-to-observation behavior and the conservative liveness ceiling are explicit validation items rather than assumptions hidden in this state machine.

Reuse the existing filesystem-retry schedule for provider-visibility retries: `0.1`, `0.5`, `2`, `10`, then `30` seconds, capped at `30` seconds with one coalesced timer and no jitter. Reset the attempt after a successful visible-state advance. These values are an implementation/liveness policy, not evidence of correctness and not an operation timeout.

Each transaction has three independent fences:

- provider: exact first/second `NVRootedDirectoryCatalog` equality and exact first/second persistent-version-ID set equality;
- session/model structure: same root-session UUID and structural generation; and
- affected notes: same UUID/LSN values.

No fence is an ordering claim. An identical root URL, catalog token, version set, or note text never substitutes for the other fences.

## Provider-version evidence

Store the smallest durable provenance needed to make preservation idempotent and later resolution safe. Add the optional `providerVersionRepresentationsV1` archive field to `NoteObject` and `DeletedNoteObject` using the exact array/dictionary keys, opaque identifier object, and numeric roles in the normative persistence-format appendix.

The field is checkpoint/WAL metadata only. It is never written to a note file, filename, xattr, or sidecar. Epoch 4 ignores it while retaining core note readability. At runtime compare decoded opaque identifiers with `isEqual:`; do not infer anything from their encoded bytes.

An ordinary edit retains the note's ancestry because the edited note is a descendant of the represented input; deletion transfers it to the identity-bound tombstone. Creating an unrelated note or duplicate never copies ancestry. A reconciliation operation adds ancestry only when its decision kernel actually used or preserved that version—matching output bytes, names, or timestamps is insufficient.

Resolution eligibility itself stays transient in `NVRootSession` and is populated only by complete exact routine reconciliation or complete explicit **Recover Notes** processing. A crash before checkpoint/upload leaves Apple's versions unresolved. On restart the durable ancestry allows the same deterministic transaction to recognize existing representation and regain eligibility without creating repeated conflict notes.

At a root-closing boundary, intersect the transient eligible IDs with the ancestry/tombstone representations still present in the frozen store and with completed local separate-file obligations, then freeze that exact set into the checkpoint receipt's `resolutionCoverage`. After local checkpoint durability and, under provider management, exact upload qualification of that receipt, resolve/remove each ID only through `NSFileVersion` inside a coordinated write. Never touch revision-storage paths directly. Per-version failure leaves that version in provider evidence for rediscovery and does not invalidate the checkpoint or block root closure. No persistent resolution ledger is needed.

Intentional tombstones reuse `DeletedNoteObject`, keyed by stable note UUID or deterministic recovery-note UUID, and must be retained even when no legacy sync-service metadata exists. Implement that retention by extending the existing `-[NotationController _addDeletedNote:]` and `-[NotationController _purgeAlreadyDistributedDeletedNotes]` decisions; do not add another tombstone collection or type. A tombstone's provider ancestry follows the UUID through renames; it is never keyed by path.

## Local edit and note-file write flow

Local editing must remain synchronous from the user's perspective:

1. The main thread mutates the live note, increments its LSN, updates search/list state immediately, and adds the note to the existing `pendingJournalWrites` and `pendingFileWrites` sets as applicable. It does not archive or access the filesystem for every keystroke.
2. Reuse the existing idle and maximum-delay timers to coalesce typing. At that boundary, capture the latest immutable WAL record and file-write values on the main thread, then submit them to their independent queues. Queue execution and synchronization no longer block the timer callback.
3. Keep each note in its existing pending set until the submitted generation succeeds and still matches the live UUID/LSN. A newer edit leaves or restores the same set membership; there is no per-generation queue or parallel pending-intent dictionary.
4. The provider lane discards a superseded captured attempt before coordination, resolves its source from the session's physical-state map, then coordinates the selected file and runs the existing snapshot/three-way-merge/write-intent algorithm. Existing-destination installation migrates behind that unchanged boundary according to [Foundation safe-replacement migration](../Foundation-Safe-Replacement-Migration.md).
5. Return an immutable result to the main thread.
6. Advance the provider-lane physical-state map to what was actually installed. Apply file metadata, merge output, or a preserved conflict to the live model only if the active root, structural generation, UUID, and LSN still match. A stale completion leaves the newer obligation queued and uses the updated physical state when it runs.

A private `NVNoteFileWriteIntent`/result pair may live in `NotationDirectoryManager.m`. It contains copied values only: root/session identity, UUID/LSN, desired and prior filesystem names, encoded bytes, tags, dates, encoding, and the last reconciled snapshot/base. It must not retain a mutable live `NoteObject` for background dereference.

Make `captureFileMergeBaseIfNecessary` a value-only main-thread operation. The exact accepted checkpoint can seed the pre-edit plaintext base only for a represented note whose separate-file obligation was settled before that checkpoint was serialized, as the normative checkpoint boundary requires; a successful reconciliation/write replaces it with the exact accepted snapshot. If no trustworthy base/identity exists, the provider transaction preserves the alternate rather than synchronously reading a cloud file from the main thread.

Keep note operations serial on the provider lane. This preserves their logical order, makes rename/write coalescing straightforward, and means a cold cloud read can delay only later provider work—not UI mutation or WAL durability. Add read concurrency only if measurements later show the serial lane cannot meet reconciliation latency; it is not part of the initial architecture.

A rename coordinates source and destination in one intent group, then uses the existing descriptor-relative exclusive destination/rename implementation. A delete uses the expected observation and stages an identity-bound tombstone when the conflict matrix requires it.

The existing `makeNoteDurableForExternalEditing:` boundary becomes completion-based: submit the immutable WAL record and a durability-queue barrier, then let `ExternalEditingSession` replace/remove its scratch file from that completion. It must not synchronously wait on the main thread.

After this conversion, all active-root namespace/content calls route through `NVRootSession` except append/synchronize on the already-open WAL descriptor. In the test target, a rooted-directory subclass should fail active-root calls made on the main thread so direct-call regressions are caught without production queue-tracking machinery.

## Reconciliation flow

One current-known reconciliation transaction proceeds as follows:

1. Coordinate a shallow root catalog on the provider queue and retain the existing exact `NVRootedDirectoryCatalog` as the first catalog token. Enumeration reads direct-child names and cheap identity/revision metadata, not note contents, and its completion—not Spotlight—is the namespace-discovery boundary.
2. Project that catalog into two disjoint candidate sets. Authoritative note candidates come from current non-artifact children—including visible `Title (conflict recovery <UUID>).ext` files—the live model and last accepted note catalog, and note URLs delivered by presenter move/version callbacks. The exact fixed checkpoint/journal/lock names and hidden `.nv-write-<UUID>` residue form the artifact-status set. Retained note candidates preserve deleted or renamed current files without requiring a directory-wide historical-version index; artifacts never enter the note decision matrix.
3. Select note candidates whose catalog state changed, which are unmatched, or whose persistent-version-ID set later proves changed. Ask the main thread for an immutable model snapshot: root/session identity and structural generation; lightweight UUID/LSN/filename/filesystem-identity descriptors for all notes; and full content/base/labels only for that selected union. Copying model values is the only main-thread phase and performs no file access. No background task enumerates `allNotes`, constructs a note object, or dereferences a live `NoteObject`.
4. In exact scope, initiate the current, other, unresolved, and asynchronous nonlocal `NSFileVersion` calls for each authoritative note candidate from that candidate's coordinated read, as required by AV-05, including candidates whose current catalog entry appears unchanged. Copy the synchronous metadata before the accessor returns. Retain the transaction while asynchronous callbacks are outstanding; each callback re-enters the provider queue, contributes its immutable metadata, decrements a pending count, and advances the state machine only when all callbacks return or cancellation wins. Deduplicate opaque persistent identifiers, compare each per-item set with the last accepted set, and add newly version-dirty candidates to the selected union. This all-candidate metadata pass is required because provider history can change without a catalog or presenter witness. No queue is blocked waiting on a dispatch group. Only `NSCocoaErrorDomain/NSFeatureUnsupportedError` from the required nonlocal-version call selects `currentVisible` for this root session; a transient, ambiguous, differently scoped, or ordinary failure marks the note snapshot incomplete.
5. Batch-prepare only the selected current/historical URLs. Nested coordinated reads copy immutable content and metadata before their accessors return. Record every unreadable selected version. If AV-04 batch preparation is unsupported or violates its required accessor/completion behavior, fall back to serial per-URL asynchronous coordinated reads without changing the transaction's input or fences.
6. Run the normative decision matrix into one prepared-value `NVDirectoryTransaction`, independent of version traversal order. Reuse `NVMergedText`, the existing expected snapshot, filename matching, identity matching, conflict-note creation, and atomic writer. Construct and decode note objects only later on the main thread during publication.
7. Repeat the same candidate construction. Exact scope takes a second independently produced note-catalog projection and an exact persistent-version-ID set for every authoritative note candidate; current-visible scope takes an independent note-catalog projection and selected current-state snapshot. Artifact churn cannot invalidate or complete either note fence.
8. Dispatch the candidate to the main thread. Recheck root incarnation, structural generation, and affected UUID/LSN values without filesystem access.
9. Commit the exact transaction only under its complete dual fence. A stable current-visible transaction may apply the existing current-file compare-and-swap/merge/rename/deletion result only under its complete shallow-catalog/current-state and model fences. If the selected scope's required evidence is incomplete but the model fences match, publish only additive represented conflict notes/provenance allowed by the partial-preservation rule. Otherwise discard.
10. Record resolution eligibility only for a complete exact transaction. Consume the serviced dirty generation after either kind of stable commit only when every through-generation witness is accounted for and no newer generation exists; otherwise retain dirty and coalesce one follow-up transaction.

This exact current-known path is attempted for every provider-managed root under the plaintext storage contract. Here `current-known` covers only URLs disclosed by those authoritative candidate sources and every version returned for them by the required `NSFileVersion` calls; it never claims a directory-wide inventory of undisclosed remote history. If current namespace/content discovery cannot satisfy the independently validated Apple contract, the operation remains incomplete and fail-closed. Confirmed ordinary local storage has a complete empty provider-version set and uses the same dual catalog fence.

`NSCocoaErrorDomain/NSFeatureUnsupportedError` from one required nonlocal-version call for an authoritative note candidate selects the existing double-catalog/current-file compare-and-swap transaction as the root session's current-visible scope. It proves only that exact historical discovery cannot complete for this session, not that other operations or URLs lack support. It requires complete current catalogs and selected current contents, may update the live model and consume the serviced dirty generation, and need not repeat the unsupported call in that session. It never claims first-class current-known status, records resolution eligibility, resolves provider versions, or proves hidden history absent. The session-continuous limitation is retried when a fresh root session opens and is never persisted or associated with a provider brand. Every other error remains incomplete and dirty.

Current-visible reconciliation does not itself qualify journal cleanup, but it also does not veto a separately matched exact checkpoint upload. Once visible file obligations are settled, a root-closing checkpoint may proceed; exact upload qualification of its receipt may resolve only previously exact-eligible covered versions and may clean its covered journals. Without that qualification, the normal retained-journal path applies.

The initial catalog should retain enough identity/revision metadata to select content reads cheaply. Listing placeholders should not materialize their contents. The batch preparation step—not directory enumeration—is where selected cloud bytes may download.

Routine note reconciliation excludes exactly `Notes & Settings`, the legacy exact-name journal, modern `Interim Note-Changes.<journalID>` journals, `.nv-root.lock`, and hidden `.nv-write-<UUID>` operation residue. A visible `Title (conflict recovery <UUID>).ext` file is deliberately an ordinary note candidate and follows the normal recognized-extension and reconciliation path. Presenter changes to true NV artifacts advance the independent artifact-status generation and update startup/recovery/upload status; an unavailable artifact cannot keep an otherwise complete note generation dirty.

## Startup flow

Opening a root is an asynchronous state machine owned by `AppController` and executed by `NVRootSession`:

For this state machine, the mandatory journal set is exactly the legacy exact-name journal, the one unambiguous current-host active journal, and every same-host retained journal whose covering checkpoint differs from the accepted checkpoint. A matching retained claim already covered by the accepted checkpoint needs no materialization. Unresolved database versions and unclaimed provider-managed journals are recovery/status evidence and never block ordinary startup.

1. Resolve the selected bookmark into `NVRootedDirectory`, acquire the fixed directory lock, create a fresh root session, and register its presenter during a coordinated root read. `AppController` owns this unattached startup session until checkpoint acceptance creates `NotationController`, then transfers ownership to the controller.
2. Discover storage authority without naming the provider. Query the resolved existing root first. Only for a prospective child or an existing item without usable item evidence, walk existing directory ancestors nearest-first on the same volume and stop at the first positive ubiquitous-item or `NSFileProviderManager` URL-domain result or at the volume root. Never cross a volume boundary. Any failed, missing, changing, permission-denied, or unsupported step remains `unknown` unless another positive result succeeded. Retain opaque identifiers only for equality and authority-change detection. An exhausted negative walk does not prove local storage; confirm ordinary local storage only through the positive exclusion/local-filesystem recipe after AV-09 validates it, otherwise remain `unknown`.
3. On macOS 26+, inspect `Notes & Settings` for an interrupted pause before checking freshness. Resume it with `NSFileManagerResumeSyncBehaviorPreserveLocalChanges`, then begin the ordinary provider-current check only after resume succeeds. `SyncSessionController` owns retry/status presentation for a failed resume; the paused resource value is the restart evidence, so NV persists no pause marker.
4. Coordinate checkpoint status and journal discovery off-main. Classify canonical-checkpoint absence only after one complete shallow root catalog omits its fixed name and current, other, unresolved, and nonlocal version queries for that fixed URL reveal no version. A transient or ordinary query failure leaves startup unavailable; `NSCocoaErrorDomain/NSFeatureUnsupportedError` means only that history is unavailable. `ENOENT` alone is never an empty collection. If this process did not just create the root, offer **Create a New Notes Collection Here** only after that classification; the transaction then rechecks expected absence as its compare-and-swap precondition. Either creation path serializes, installs, and exactly verifies one initial empty checkpoint through `NVCheckpointTransaction` before continuing.
5. If the checkpoint is provider-current and materialized and no mandatory journal work exists, copy its exact bytes and current local `NSFileVersion.persistentIdentifier` when available once on the provider queue and pass that immutable pair to a new `NotationController` initializer/factory. Decode those exact bytes on the main thread, retain the same bytes/version as the accepted predecessor evidence, and present the normal UI; `NotationController` must not reopen the checkpoint path.
6. If it is explicitly stale or unmaterialized, request download and show an app-owned `NSProgress`. It is indeterminate unless a trustworthy exact-item progress value is available; presenter/resource-status wakeups update it, and only a coordinated provider-current read advances startup.
7. Recover the mandatory legacy journal first, install its replacement checkpoint, then evaluate this host's active journal and every retained journal whose recorded covering checkpoint differs from the accepted checkpoint. A matching retained claim establishes coverage without materializing its journal.
8. Before enabling editing, create the modern journal, synchronize its header, write/synchronize its current-host claim, and only then admit the first mutation.
9. After the normal UI appears, start routine reconciliation directly with the first coordinated shallow catalog. It never waits for Spotlight, note content downloads, or historical-version discovery before presenting a provider-current checkpoint.

If paused-checkpoint resume, materialization, or online update fails, the visible choices are Retry, quit, choose another folder, or work offline. Offline is enabled only when complete local checkpoint bytes and every mandatory journal can be materialized, validated, and recovered. It has a visible status until current-known reconciliation succeeds or stable unsupported history lets current-visible fallback settle every visible obligation; that outcome replaces offline status with the session-continuous nonblocking limited-history status. Cancel or elapsed time publishes no startup store. There is no read-only store.

Apply `WAIT-01` uniformly: operations have no correctness deadline, a UI delay may reveal the already permitted choices, and cancellation requests coordinator/provider cancellation but waits for accessor/completion ownership before returning to `ROOT-01` or `CKPT-01`. The final closing barrier may remain pending while the user leaves it running; cancel before checkpoint commit or the caller's surfaced-error override preserves the prior evidence rather than fabricating completion.

“Created by this operation” is transient startup state, not a persisted collection flag. Files or versions that arrive after explicit creation enter ordinary reconciliation and preservation; they are never silently discarded as remnants of an empty folder.

If no acceptable canonical checkpoint can produce a startup store, offer **Rebuild from Note Files** for any NV-readable separate-file root whose applicable stable snapshot can be established. Exact-capable roots use the complete current-known note-catalog/version fence, confirmed ordinary-local roots use their complete coordinated current note snapshot, and stable unsupported history may select the session's current-visible double-catalog fence.

Build one operation-local extension map before selecting content. Enumerate nonhidden direct-child regular files after removing the exact NV artifact set, and retain those current candidate URLs for the applicable current-known or current-visible snapshot. Seed the map from `+[NotationPrefs defaultPathExtensionsForFormat:]` only for the existing readable formats: plain text (`txt`, `text`, `utf8`, `taskpaper`), RTF (`rtf`), and HTML (`html`, `htm`). Do not sniff bytes. Group every other extension for one user choice: assign `PlainTextFormat`, `RTFTextFormat`, or `HTMLFormat`, or explicitly Ignore. An ignored group remains untouched and outside the selected set; an unresolved/ambiguous group or decoder failure blocks publication. Keep this map only in the detached rebuild operation. In exact scope, run the all-candidate version-metadata pass and select every disclosed current, other, unresolved, and nonlocal version; each version uses the decoder assigned from its candidate URL's extension, even when its immutable `NSFileVersion.URL` is elsewhere. Current-visible and confirmed ordinary-local rebuilds select only their complete current snapshots. Feed each selected snapshot to the existing `-[NoteObject initWithCatalogEntry:snapshot:format:fallbackLabels:fallbackEncoding:fallbackCreatedDate:error:]`; do not add a decoder or reuse `NotationPrefs`' single-database default.

Reuse the batch reader and deterministic decision kernel against a detached temporary store initialized only with the normative safe non-format settings. Provider-managed targets run the existing all-note `requireFileWrite` admission and immutable plaintext writer to settle an unencrypted `PlainTextFormat` target before checkpoint installation. Uniform ordinary-local input retains its assigned format. Mixed ordinary-local input requires an explicit target and the same detached conversion. Plaintext conversion from RTF/HTML extends the existing conversion confirmation flow with a new warning that formatting and attachments are discarded. Transient, incomplete, unreadable, or canceled input cannot publish. Import every selected note state without inferring deletions and never obtain settings, metadata, or deletion evidence from historical recovery artifacts.

Publish nothing until every selected state is represented and `NVCheckpointTransaction` exactly installs the replacement against expected absence or the exact classified predecessor. `NVCheckpointInstallCurrentChanged` discards the detached candidate and restarts checkpoint/root discovery; it never adopts the appeared or changed checkpoint inside the same attempt. A current-visible result presents the normal UI with session-continuous limited-history status and no provider-version resolution eligibility. Failure discards the temporary store without a rebuild ledger.

### Current-host journal registry

Implement the registry as direct Core Foundation preferences helpers in `WALController.m`/`StartupRecovery.m`, not a registry class. Use the exact current-application/current-user/`kCFPreferencesCurrentHost` domain:

| Entry | Property-list value | Meaning |
| --- | --- | --- |
| `NVActiveJournal.<journalID>` | Direct bookmark `NSData` | The one append-capable journal for that root on this host. |
| `NVRetainedJournal.<journalID>` | Dictionary containing integer `schemaVersion = 1`, bookmark `NSData` as `rootBookmark`, and 16-byte UUID `NSData` as `coveringCheckpointID` | A closed journal this host must retain until an exactly covering checkpoint obtains applicable upload qualification. |

The canonical uppercase UUID key suffixes, malformed-value behavior, lock leaf, journal name/header, and archive schemas are fixed by the normative persistence-format appendix. Do not store a writer ID, provider identity/capability profile, upload-success bit, Bloom filter, or accumulated journal history. The shared checkpoint remains a complete snapshot; the host registry records only conservative local ownership.

At launch, enumerate both prefixes, resolve each bookmark, and compare the resolved directory identity with the selected `NVRootedDirectory` plus the named journal/header. Refresh only a matching stale bookmark. Preserve unmatched or temporarily unavailable records unchanged. More than one different matching active ID is ambiguous and authorizes neither append nor automatic cleanup; startup offers the explicit all-candidate interrupted-change recovery below. Any number of retained candidates is valid because none grants append authority.

A matching claim whose journal appears absent is not pruned from coordinated catalog evidence alone. Under the directory lock, keep the claim, revalidate absence in the operation, and invoke the existing `-[NVRootedDirectory synchronize:]` helper on the provider lane. Only a successful directory synchronization permits claim removal and current-host preference synchronization. Failure keeps the claim in `deleting/pending-durability`; presence or later reappearance routes it back through claimed recovery. A copied folder cannot inherit the source claim because bookmark resolution must identify the opened directory descriptor, not merely equal path text or copied contents.

Creation order is journal file, integrity header and directory synchronization; then host claim and `CFPreferencesSynchronize`; then editing. Fresh random checkpoint and journal UUIDs are retried on collision and are never reused. There is no writer ID.

Startup never resumes append on a discovered journal. An active claim is recovered as interrupted append work. A retained claim whose covering checkpoint equals the accepted checkpoint is represented without reading the journal; every mismatch is mandatory same-host recovery input before editing. This includes an older claim left by a crash before coverage advancement because checkpoint identities have equality semantics only. Recovered state is installed through an exact replacement checkpoint, after which startup creates one fresh process journal.

When any exactly installed local checkpoint does not qualify for cleanup—whether provider upload is pending, unsupported, failed, overridden, or ambiguous, or storage authority is unknown—close the old descriptor permanently and demote ownership in this order while the root lock is held:

1. Write `NVRetainedJournal.<journalID>` with the root bookmark and exact installed `checkpointID`, then synchronize current-host preferences.
2. Remove `NVActiveJournal.<journalID>`, then synchronize current-host preferences again.
3. Terminate, switch roots, or activate a fresh randomly named journal.

A crash before step 1 completes leaves the active claim authoritative. A crash between steps 1 and 2 leaves both claims for the same ID; startup validates the retained covering checkpoint and either completes demotion or recovers through the active role. Different matching active IDs remain ambiguous.

`NVRootSession` keeps an exact in-memory set of active and retained IDs represented by its accepted live state. Recovery adds an ID only after its result is installed; a matching retained claim seeds the set directly. Every immutable checkpoint receipt freezes that set. After exact local installation, retained claims named by the receipt may be advanced to its new checkpoint ID. An interrupted preference update leaves older conservative evidence, but its later mismatch with the accepted checkpoint requires materialization/classification and a replacement checkpoint rather than ancestry inference.

One later upload qualification may clean every same-host journal named by that receipt, independently per ID:

1. Coordinate removal of the artifact. A failed removal that positively revalidates the original artifact leaves the prior state for a later receipt.
2. Successful or ambiguous removal enters `deleting/pending-durability` with the claim intact. Call `-[NVRootedDirectory synchronize:]`; one success advances every already validated pending removal in that directory, while failure leaves them pending.
3. After directory durability, remove and synchronize the current-host claim. Failure leaves `deleting/durable` and retries only this preference tail.

After a restart, coordinated absence validation returns the journal to step 2 rather than skipping to step 3. A reappearing artifact remains claimed and cannot reuse the old volatile receipt for another removal.

After append has permanently stopped, the provider lane may remove an owned active journal without upload qualification only when the WAL queue reports no pending or failed record and an exact header/length validation proves zero record bytes. Coordinate removal, synchronize the root directory, then clear and synchronize the active claim. Any trailing, torn, malformed, unreadable, or uncertain bytes take the nonempty recovery path. If that journal is empty, no checkpoint-scoped state changed, and there is no retained backlog, root closure skips checkpoint installation. A retained backlog alone makes the next orderly root closure create one fresh-ID full checkpoint so older systems get a new observable upload transition and newer systems can request exact upload. This is a closure-time cleanup retry, not periodic checkpointing. In a confirmed ordinary local backup restore, exactly one structurally valid and journal-recovery-eligible unclaimed journal is recovered automatically under the directory lock without asking the user to choose; zero candidates need no recovery. Multiple eligible candidates require explicit all-candidate recovery. Invalid, unavailable, or changing evidence authorizes no replay or deletion. An unclaimed provider-managed journal may still have a remote writer, so it is available only to explicit **Recover Notes** and is never automatically appended, resolved, or deleted.

## Database and journal recovery

Treat noncanonical `Notes & Settings` versions and unclaimed provider-managed journals as recovery evidence only. Their arrival never changes the live store, but their permitted actions differ.

For noncanonical database versions, extend the existing status UI to expose **Recover Notes** and **Discard**:

- **Recover Notes** snapshots all known persistent version identifiers, batch-materializes every readable version, and imports every distinct differing non-deletion note state through the same prepared-value transaction. `DeletedNoteObject` and settings records produce no recovered note and never mutate or suppress the live original. The action never imports database settings or installs a historical checkpoint. A deterministic UUIDv5 derived from the archived source-note UUID plus the SHA-256 digest of the normative canonical `v1` recovery-state encoding makes repeated recovery idempotent. At publication, route each imported note through the existing normal dirty/write scheduling leaf so it enters both `pendingJournalWrites` and, in separate-file mode, `pendingFileWrites`; the ordinary WAL coalescing and barrier make the accepted import journal-durable. Completion requires the transaction's second exact catalog/version fence; incomplete enumeration, changed fences, or failed reads preserve what is safe but leave dirty and confer no resolution eligibility.
- **Discard** snapshots database-version persistent identifiers after one confirmation and removes only that snapshot. Per-version failures and versions arriving later remain visible.

For an unclaimed provider-managed journal, the UI exposes **Recover Notes** only. That action snapshots the current and all known local/nonlocal versions of the selected journal, reads each strict valid prefix, and imports only missing or differing non-deletion note states with the same deterministic recovery identity. It ignores deletion and settings records and uses the same exact second fence before reporting the recovery complete. Imported states enter the active journal and separate-file pending sets through the same normal dirty/write scheduling leaf as database recovery. The action never confers resolution eligibility and never resolves, deletes, or offers **Discard** for any journal version that may still have a remote writer.

For multiple different matching active claims, startup exposes **Recover Interrupted Changes**. Under the directory lock it snapshots every claimed current artifact and valid prefix, requires the complete set to remain materializable and classifiable, applies the multi-journal rules, and installs one verified replacement checkpoint. Before cleanup or demotion begins, cancellation or any candidate/checkpoint failure preserves every candidate journal and active claim. Once the first irreversible member transition begins, cancellation is unavailable.

Clean or demote each member independently. A completed member stays completed; a failed or unprocessed member remains conservatively `active`, `demoting`, `retained`, or `deleting`. A `deleting` member retries the remaining directory-durability and claim-synchronization tail. After termination, startup must perform coordinated absence validation and successful root-directory synchronization before clearing the claim; a present artifact returns to claimed recovery handling. Create the fresh journal only after every former active ID is absent or durably retained, never beside a partially settled active claim.

For multiple eligible unclaimed journals in a confirmed ordinary-local root, startup exposes **Recover Notes from Journals** with the same exact all-candidate snapshot and multi-journal replay. The continuously held directory lock and local authority exclude another writer, so only after one verified replacement checkpoint may NV remove each recovered local journal independently. Failure or cancellation preserves every candidate.

Do not add a version picker, whole-checkpoint restore, export-checkpoint workflow, recovery ledger, or note-UUID migration. Existing note UUIDs are never regenerated. Add the required SHA-256 helper beside the existing digest utilities in `NSData_transformations`, and implement UUIDv5 as a small formatting wrapper around the existing `SHA1Digest`; UUIDv5 itself requires SHA-1, so no duplicate digest implementation or dependency is needed.

A complete **Recover Notes** run adds its database-version identifiers to the same transient resolution-eligibility map used by complete exact routine reconciliation. At the next root closure, only identifiers whose imported notes—or intentional tombstones created by later user deletion—are locally durable in separate files and represented in the frozen live store enter the checkpoint receipt's `resolutionCoverage`. Under provider management, automatic resolution waits for exact upload qualification of that receipt. A crash or per-version failure leaves the database versions unresolved and lets durable ancestry make the next run idempotent; neither blocks root closure. This rule never applies to unclaimed provider-managed journals, and explicit **Discard** remains a separately authorized destructive action.

## Checkpoint identity and installation

Add optional `checkpointID` `NSData` containing exactly 16 UUID bytes to `FrozenNotation`'s keyed archive. A modern serialization attempt receives a fresh random ID. An epoch-4 checkpoint without it uses the tagged SHA-256 digest of its exact loaded bytes as the base identity until the next verified modern save.

Use the normative persistence-format appendix's canonical one-byte-tag-plus-payload checkpoint-base encoding everywhere outside the archive. Add C helpers beside the digest utilities in `NSData_transformations` to construct, validate, encode, decode, and compare it and to exercise the exact vectors. The fixed binary encoding is shared by `FrozenNotation`, `WALController`, and `StartupRecovery`; callers can test equality but cannot parse strings, compare identities across domains, or infer ordering. `FrozenNotation` continues to archive only its optional backward-readable `checkpointID` field.

Keep the user-visible filename exactly `Notes & Settings` and keep its core keyed archive readable by epoch 4. Do not add a parallel epoch-5 checkpoint name.

Retain the exact accepted checkpoint `NSData` loaded at startup. It provides the byte-derived legacy identity and immutable accepted evidence; it is not a second synchronization database.

Define a private immutable `NVCheckpointReceipt` value in `NVRootSession.m`. It retains the exact frozen bytes, canonical checkpoint identity, installed local `NSFileVersion` persistent identifier, fresh transaction-local request identity, the exact `resolutionCoverage` set of already eligible routine and **Recover Notes** version identifiers durably represented by the frozen store, and the exact active/retained journal IDs represented by that store. These correlated fields are created together after exact local installation and never updated independently or reused by a later attempt.

Define one private, single-use `NVCheckpointTransaction` in `NVRootSession.m` as the only local checkpoint-installation implementation. It accepts already serialized immutable bytes containing a fresh checkpoint ID, the canonical identity and resolution/journal coverage captured from the frozen live state, the root-session incarnation, and the expected current checkpoint snapshot/version. It owns a coordinator only for the short local install/read-back operation, then returns either one immutable `NVCheckpointReceipt` or a typed installation failure. An absent destination, including the first checkpoint in a newly created **Save Current Collection As…** root, uses the existing exclusive-create intent; its later final-format checkpoint uses the same existing-file replacement path as every other checkpoint. The transaction never receives a live `FrozenNotation`, serializes the model, waits for upload, resolves a provider version, deletes a journal, or becomes a public controller.

Expected-current evidence is a mandatory local compare-and-swap precondition. Ordinary closure and controlled transitions use the accepted predecessor's exact retained bytes plus the local `NSFileVersion.persistentIdentifier` captured with them when available; they do not snapshot a newly arrived checkpoint and thereby authorize overwriting it. Startup recovery uses the exact current artifact that operation classified. Rebuild uses either that exact predecessor or expected absence after authoritative absence classification; a second Save-As installation uses its verified bootstrap, and creation records expected absence. Inside the coordinated accessor, immediately before calling Foundation replacement or exclusive creation, reopen `Notes & Settings` relative to the rooted directory and compare exact bytes plus the available version identifier, or prove expected absence. A missing, newly appeared, byte-different, or version-different destination returns `NVCheckpointInstallCurrentChanged` without a namespace mutation; remove the still-owned stage and leave the current checkpoint untouched. This is a pre-install failure, not a diagnostic warning and not the note writer's compare-after-replace conflict path. The caller takes its `CKPT-01` row; rebuild restarts checkpoint/root discovery, and no path silently adopts changed evidence within the same attempt. A possible-install ambiguity retains every predecessor, journal/claim, and target credential that might still be referenced and authorizes neither publication nor cleanup. A remote server change not yet reflected locally is caught by fail-on-conflict upload when available; without exact qualification the receipt cannot clean journals or provider versions.

The semantic rule is: before a root becomes editable it has one accepted checkpoint and a fresh journal based on it; after editing stops, closing or changing a still-writable root installs at most one final checkpoint; and every exceptional replacement of an accepted store uses this same transaction. The concrete boundaries are initial collection creation, legacy or modern startup recovery, bootstrap rebuild, root closure by quit or folder switching, both halves of a controlled storage transition, and the bootstrap/final installations in a **Save Current Collection As…** destination. The latter destination is not editable and has no journal between its two installations, so it does not create a periodic checkpoint boundary. Recovered notes become checkpoint-covered through the ordinary later root-closing transaction; **Recover Notes** does not introduce a periodic checkpoint. `NotationController`, `StartupRecovery`, and transition code no longer call the checkpoint overwrite path directly. This replaces the duplicated normal-save and recovery installation sequences without adding another long-lived owner.

Checkpoint installation is therefore:

1. With editing frozen, serialize the live store once on the main thread using a fresh checkpoint ID.
2. Create one `NVCheckpointTransaction` with those exact bytes and mandatory expected-current evidence captured at the semantic boundary.
3. On the provider lane, install `Notes & Settings` atomically. An absent checkpoint uses the existing exclusive-create path and fails if the leaf appeared. An existing checkpoint uses the shared Foundation backend from [Foundation safe-replacement migration](../Foundation-Safe-Replacement-Migration.md): stage and synchronize the bytes in the same-volume `NSItemReplacementDirectory`; obtain one operation-local file-reference URL for the existing destination; coordinate that destination for replacing and the stage for moving; enforce the expected-current bytes/version precondition immediately before mutation; call `-[NSFileManager replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:]` with options `0` only on a match; revalidate the resulting item against the rooted directory and retained stage descriptor; and synchronize the root directory. The same backend serves ordinary-local and provider-managed checkpoint replacement; pause/upload controls wrap it only when advertised and successfully acquired. Replacement invalidates the old leaf reference, so any later access regenerates one from the rooted directory and verified leaf rather than caching or retargeting it. Do not use `NSDataWritingAtomic` for production installation.
4. Coordinate an exact read-back and require byte equality, successful decode, and the expected checkpoint ID.
5. Capture the installed local `NSFileVersion` persistent identifier and create the receipt atomically from those correlated values.
6. For each covered retained claim, advance its covering checkpoint ID to this receipt and synchronize current-host preferences. Failure leaves its previous conservative coverage and cannot broaden later cleanup.

The existing rough structural verification may remain diagnostic, but it cannot authorize journal deletion or provider-version resolution. Exact bytes, decode, ID, and local version form the checkpoint receipt.

There is no periodic checkpoint and no journal rotation. Startup recovery or new collection creation installs an accepted checkpoint before creating its one fresh process journal. Normal editing installs at most one root-closing checkpoint; a provably empty journal with no checkpoint-scoped changes or retained backlog takes the no-checkpoint cleanup path.

`NVCheckpointTransaction` is an implementation refinement, not a new atomic protocol step. The TLA+ models continue to distinguish checkpoint installation, exact verification, upload qualification, and journal/version cleanup. The separate checkpoint-transfer helper consumes the receipt only after local installation has completed, so the implementation does not collapse those modeled failure boundaries.

## Quit and exact upload flow

Use a monotonic quit state such as `running -> quiescing -> locallyClosed -> waitingForUpload -> finished/overridden`. `locallyClosed` carries either the one immutable checkpoint receipt or the provably-empty no-checkpoint result. State advances only on the main thread.

The normal path is:

1. On the main thread select `lifecycleQuiescing` in the controller's single edit-admission reason mask, reject new sync requests, and wait for already admitted main-thread mutations. Durability suspension may remain selected independently.
2. Drain the WAL queue through `synchronize`.
3. While the presenter remains registered, drain its queued callbacks, settle pending note writes, and repeat final reconciliation until the root session's applicable exact or current-visible catalog/version-or-current-state, session, structural, UUID/LSN, and dirty-state fences are stable. Atomically mark the root session closing so no later callback can publish into the quit transaction.
4. Stop/invalidate FSEvents, remove the root presenter, and use a provider-queue barrier to drain callbacks already delivered. Do not restart reconciliation after removal; external changes arriving after the closing barrier remain in separate files for next-launch reconciliation.
5. If the active journal is provably empty, remove it with local directory durability and clear its active claim without upload qualification. If no checkpoint-scoped state changed and no retained backlog exists, return the no-checkpoint result; otherwise serialize once and install/read-back a receipt without that absent journal in its coverage. A nonempty journal remains until the receipt's cleanup or demotion outcome.
6. For a provider-managed receipt, ask `SyncSessionController` to wait for checkpoint upload evidence. The no-checkpoint empty-journal result has no provider wait.
7. After applicable qualification, resolve each provider version in the receipt's exact `resolutionCoverage` independently. A failure leaves that version unresolved for next-launch rediscovery and does not block termination.
8. If the receipt obtained applicable qualification, independently remove every active or retained journal in its exact journal coverage and then clear each corresponding claim. If it did not, demote any remaining covered active claim to retained ownership and finish termination with the backlog preserved.

For confirmed ordinary local storage, exact local checkpoint durability supplies the applicable qualification. For a provider-managed root, the specified exact upload qualification is required. Unknown roots use the same conservative active-to-retained transition after exact local installation because NV cannot establish either cleanup rule. Stable current-visible reconciliation may satisfy the final visible-file barrier but neither grants nor blocks qualification; the checkpoint-transfer result remains authoritative. A pre-checkpoint failure leaves the active claim unchanged.

On macOS 26+, if provider-managed `Notes & Settings` advertises the required controls, prefer this bounded optimization. The option set authorizes attempting the path; each real operation must still succeed:

1. Pause only the checkpoint item before the short replacement.
2. Install it through the Foundation safe-save branch above and verify the returned, revalidated item exactly.
3. Outside every coordinator accessor, request fail-on-conflict upload.
4. Accept success only when the request token, returned `NSFileVersion`, installed local-version identifier, and checkpoint ID all match the current receipt.
5. Resume with preserve-local-changes behavior on every path.

Keep this OS-version split in one private checkpoint-transfer helper in `NVRootSession.m`. It consumes one `NVCheckpointReceipt`, owns pause/upload/resume and stale-callback rejection, and returns only `confirmed`, `pendingOrUnknown`, or `actionableError` for that same receipt. `SyncSessionController` continues to see only the provider participant's running/error/uncommitted/status surface; it never correlates request tokens or version identifiers itself. No checkpoint-transfer controller or public protocol is needed.

Pause acquisition failure falls back to ordinary provider synchronization and does not itself fail quit. Treat `EBUSY` as transient: retry it with the same bounded-backoff policy until pause succeeds or the existing wait UI offers its user-visible choices; cancellation or a nonbusy pre-pause failure takes the ordinary fallback. Once pause succeeds, upload ambiguity, conflict, returned-version mismatch, or resume failure retains the journal through active-to-retained demotion. Unsupported controls use the ordinary fallback.

On macOS 11.5 through 15, observe `NSURLUbiquitousItemIsUploadedKey`, `NSURLUbiquitousItemIsUploadingKey`, and `NSURLUbiquitousItemUploadingErrorKey` only on the provider lane, woken by presenter ubiquity-attribute callbacks and the same bounded non-main-thread retry schedule. One attempt is bound to one receipt's checkpoint ID and captured local `NSFileVersion`: only a newly observed not-uploaded/uploading state followed by uploaded, with that local version unchanged, followed by coordinated exact read-back can qualify it. A preexisting uploaded state, missed transition, local-version change, error, or failure of AV-11's observation contract remains pending/unknown rather than inventing qualification. A later qualified receipt covering the retained backlog retires it in one pass.

The existing quit waiter presents the retry/error/override behavior. **Quit Anyway** preserves the old checkpoint and active claim after a pre-checkpoint failure, or the newly installed checkpoint and retained claim after local installation. It also preserves unresolved versions and all unconfirmed state for next startup. Resolution is cleanup after durability, so an individual `NSFileVersion` failure is reported/deferred rather than treated as an uncommitted user edit. A successful local checkpoint is never rewritten by `applicationWillTerminate:`.

## Root moves, folder switching, and storage transitions

### Provider/Finder root move

`presentedItemDidMoveToURL:` runs on the provider queue. A path-only move is a rename or relocation whose reported URL still resolves to the directory object held by the open descriptor and presenter and whose opaque authority evidence still identifies the same provider domain: only its pathname or ancestors changed. Verify directory identity, refresh the root file-reference URL/bookmark and every matching current-host active or retained claim, and rebuild the FSEvents watch. Do not increment structural generation, cancel in-flight provider access, or schedule reconciliation solely because the path changed. AV-08 establishes that catalogs, reads, batch preparation, safe replacement, materialization, version access, and supported sync controls remain attached to the moved items; immutable results may therefore publish under their existing provider, session, structural, and UUID/LSN fences.

Rediscover opaque provider authority after the callback. While authority continuity is inconclusive, freeze authority-dependent publication and cleanup but allow already issued accesses to finish into immutable results. Do not suspend editing for authority uncertainty alone while rooted filesystem identity and the independent WAL durability lane remain healthy. Equality with the captured authority retains the session and releases otherwise valid results.

For a confirmed changed provider domain or account:

1. Mark the old incarnation authority-fenced. Its callbacks and transactions can no longer publish provider-derived state or authorize cleanup, but the healthy WAL continues serving the durability lane.
2. Construct a fresh provisional `NVRootSession`. Transfer the still-open rooted directory, directory lock, active journal descriptor and claim, and pending local obligations without creating a second journal, closing the descriptor, or opening an unlocked interval.
3. Drain and remove the old presenter, FSEvents stream, and vnode source through the handoff-specific non-closing cancellation path. Register the provisional successor's presenter and attach its vnode source and FSEvents stream to the transferred root.
4. Revalidate rooted namespace identity and journal recoverability. The provisional successor owns local durability but is not the active provider-publication incarnation, so provider results remain frozen. A notification or validation ambiguity leaves it provisional and retryable.
5. On success, atomically publish the never-reused successor as active. It starts with authority `unknown`, exact discovery scope, no accepted provider catalog/version or resolution-eligibility state, and dirty reconciliation.

The active-session identity check rejects every old callback and every provisional result completed before promotion. Failed directory-identity verification without positive delete evidence remains inconclusive; an indistinguishable copy is never retargeted merely because its contents match. This is one transient session state, not persistent handoff state or another scheduler.

The application no longer offers its own whole-directory relocation operation. Moving an individual note remains an ordinary coordinated rename.

`NSUbiquityIdentityDidChangeNotification` makes authority continuity inconclusive but does not itself prove that the selected root changed authority or that local journal durability failed. Freeze provider-derived publication and cleanup, preserve the active journal and root lock, mark authority unknown, invalidate authority-scoped current-known and transient resolution evidence, and rediscover authority/capabilities asynchronously. Continue editing while the root and WAL remain locally durable. Confirmed continuity retains the session and reconciles exact evidence again; a confirmed authority change takes the fresh-incarnation handoff above. Do not persist or log the iCloud identity token, and do not treat it as proof that the selected root belongs to iCloud.

### Root deletion, replacement, and Save Current Collection As

Use the normative `ROOT-01` matrix as the single action selector. Root continuity, journal durability, and lifecycle quiescing remain independent inputs, and clearing one never clears another. Compose edit/publication/cleanup permissions conjunctively. Select presentation by the spec's explicit precedence: confirmed loss; active lifecycle caller/`CKPT-01`; journal durability suspension; authority uncertainty; normal. If WAL durability fails before a lifecycle commit, abort that attempt to the suspension presentation; after verified commit, finish only its monotonic cleanup/retention tail without reopening edits.

Create one `DISPATCH_SOURCE_TYPE_VNODE` source for the existing root descriptor with `DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME | DISPATCH_VNODE_REVOKE`, targeted at the provider lane. Reuse the descriptor; do not open another root path solely for monitoring. Handle coalesced flags independently:

- `RENAME` starts the verified path-only-move procedure above.
- `REVOKE` makes continuity inconclusive, selects `journalDurabilitySuspended`, and retains retry because an unmount or temporary filesystem/provider failure may recover.
- `DELETE` selects `journalDurabilitySuspended`, positively classifies the opened vnode as unlinked, and starts post-delete identity classification. For confirmed ordinary-local storage it may select `confirmedGone` directly. Provider-managed or unknown storage selects `confirmedGone` only after operation-local File Provider/file-reference evidence establishes that no identity-equivalent logical item remains; provider eviction or same-item vnode replacement stays inconclusive. Once `confirmedGone` is selected, reject every old-session completion.

The source is an optimization only in the direction of positive proof: a filesystem that omits an event leaves the state inconclusive, and a provider-backed delete event proves only that the current vnode was removed until logical item identity is checked. Do not infer deletion from `st_nlink`, `F_GETPATH`, path `ENOENT`, bookmark failure, FSEvents `RootChanged`, or a process/file-descriptor scan. `accommodatePresentedItemDeletionWithCompletionHandler:` similarly means deletion is about to occur. Mark continuity inconclusive, select `journalDurabilitySuspended`, quiesce new filesystem mutations and publication, call the completion after the live state is safe, then await the vnode event and applicable identity classification or an independently validated equivalent; never keep Apple's coordinator blocked on UI or network work.

Implement provider identity classification as one private `NVRootSession` procedure, not a provider abstraction. Root activation retains the successful opaque File Provider item/domain pair. After `DELETE`, first use the existing file-reference, bookmark, URL-to-identifier, and rooted-descriptor checks only to prove survival; any failure remains inconclusive. Then call `+[NSFileProviderManager getDomainsWithCompletionHandler:]`, find the exact captured domain, obtain `managerForDomain:`, and call `getUserVisibleURLForItemIdentifier:completionHandler:` for the captured item. On URL success, enter its security scope, coordinate a read that requires a directory, and round-trip it through `getIdentifierForUserVisibleFileAtURL:completionHandler:`. The same item/domain proves logical survival: matching filesystem identity is an ordinary move, while a different vnode is provider rematerialization/replacement and cannot revive the old unlinked journal descriptor. Neither case selects `confirmedGone`. Only `NSFileProviderErrorDomain`/`NSFileProviderErrorNoSuchItem` carrying the exact captured item from that exact domain manager corroborates the vnode delete and selects `confirmedGone`. Observing a different item at the old path is not proof by itself and never adopts that replacement; the separate exact `NoSuchItem` result for the old identifier may still prove its loss. A missing domain, manager failure, unsupported call, timeout, nil/mismatched reverse URL, authentication/network/provider error, or any malformed result remains inconclusive. If authority was `unknown`, rerun classification when it later becomes positively ordinary-local or provider-managed. Until AV-08 validates this reverse lookup in the supported consumer-app matrix, provider roots deliberately retain Retry.

`journalDurabilitySuspended` is one transient reason selecting the controller's shared edit-admission gate, not another root identity, provider state, or second gate. On first selection, dispatch to the main thread, admit the AppKit mutation already in delivery, block later mutations, and immediately submit immutable records for every existing `pendingJournalWrites` generation. Clear that reason only after rooted identity is revalidated, the journal is again namespace-recoverable, the active descriptor/header/claim still match, the WAL outbox is empty, and a barrier sync succeeds. Authority may remain unknown after that local proof, and an independently selected lifecycle reason remains blocking. A permanently revoked or unlinked descriptor cannot clear the durability reason; preserve the live store for **Save Current Collection As…** or require explicit abandonment. Reuse the existing pending set, durability queue, typed WAL error, and AppController blocking-action UI; add no retry ledger or second scheduler.

Once loss is confirmed, inspect the former presentation location only to determine whether a different-identity replacement is available for ordinary opening. Never compare contents to adopt it. The UI is:

- replacement present: **Save Current Collection As…** (recommended) or **Re-open from Disk**;
- no replacement: **Save Current Collection As…**; quitting requires an explicit discard warning; or
- continuity inconclusive with suspended durability: Retry, **Save Current Collection As…**, open another collection after an abandonment warning, or quit after explicit discard confirmation.

Confirmed loss has no Cancel/Retry action because the old vnode cannot return to the namespace. **Re-open from Disk** explicitly abandons the live in-memory collection after warning, closes the old session, and invokes the ordinary startup flow for the replacement under a fresh session. This policy applies equally to ordinary local folders and provider-managed roots.

Implement **Save Current Collection As…** as new-collection construction, not root adoption:

1. Quiesce edits and freeze the complete authoritative `NotationController` state. Keep the inaccessible old session, journal descriptor, and claims untouched until the destination is accepted.
2. Use `NSSavePanel` to select a new directory name. Exclusively create the directory and reject an existing destination instead of adding merge or overwrite behavior. Open/lock it as an unattached target `NVRootSession`, using the same ownership shape as asynchronous startup.
3. Clone the source settings into detached target preferences but never copy its `keychainDatabaseIdentifier`. For remembered encryption, obtain the source's currently validated passphrase or authenticate again, then call the same private add-only target-credential helper used by credential cutover: generate a fresh identifier, `SecItemAdd`, read back, and validate against the target KDF/verifier. For unremembered or unencrypted storage, clear the target identifier. No target checkpoint may be installed before this succeeds. A proven pre-install failure may best-effort delete that exact target item; an ambiguous installation retains it.
4. Serialize the frozen store with those staged target preferences, `SingleDatabaseFormat`, a fresh checkpoint ID, and no cross-root resolution or journal coverage. Install and exactly verify this complete bootstrap with `NVCheckpointTransaction`'s absent-destination branch. Decode the verified bytes into detached target notes/preferences using the same `FrozenNotation` path as startup; never retarget or mutate the authoritative source controller.
5. If single-database storage is the intended result, that bootstrap is the final accepted checkpoint. Otherwise reuse the export phase of the existing controlled storage transition: run the current all-note `requireFileWrite` admission and planned immutable-write-intent path over the detached target notes against the target session with editing still frozen, apply successful file metadata only to those target notes, then serialize and exactly install one fresh-ID final checkpoint containing the intended separate-file format and resulting metadata. A target change or export error stops here; it does not mutate the source controller or merge into the destination.
6. Create no target journal before the final accepted checkpoint. A crash after step 4 therefore leaves a complete ordinary single-database collection; reopening it can retry the existing conversion path, and no migration ledger or emergency escrow is needed.
7. After final verification, reuse the ordinary post-checkpoint startup tail to activate the target's fresh journal/claim and produce a startup-ready target controller. Pass it through the existing `AppController` controller-replacement path, persisting its bookmark only for a permanent collection switch; replacement then closes the old controller/session. A temporary-folder instance preserves its existing no-global-bookmark behavior.

Canceling the save panel before exclusive creation returns to the applicable `ROOT-01` prompt and leaves the source session, live store, journal, claims, and credential untouched. Cancellation or failure after target creation never retargets the source or silently opens the target. Before bootstrap verification, clean up only target residue and a target credential proven both owned and unreferenced; after bootstrap verification, retain the complete detached destination for ordinary reopening/conversion retry and tell the user where it remains.

Neither destination checkpoint covers the old journal. Do not transplant its descriptor, transfer/demote its claim, delete shared old-root artifacts or the source Keychain item, or create a cross-root recovery record. Closing the old session leaves its current-host claim as conservative interrupted-session evidence under the existing registry policy; the complete new checkpoint and its independently owned credential protect the collection the user elected to save.

### Choosing another notes folder

Treat ordinary switching as old-session quit without process termination only while that root remains writable enough to complete closure:

1. quiesce old-root edits;
2. settle WAL/note/reconciliation work;
3. take the no-checkpoint provably-empty path when eligible; otherwise install the old-root checkpoint and either clean its covered journals after applicable qualification or demote the active journal to retained same-host recovery ownership;
4. remove/drain the old presenter and close the old session;
5. open a fresh session for the new root; and
6. update the saved global bookmark only for a permanent switch.

A failure before checkpoint verification offers retry or cancel. If the old journal itself is durable, explicit **Switch Anyway** may close the session while preserving that journal and its active claim as interrupted work because no covering checkpoint exists. Once a checkpoint is verified, switching always cleans or demotes; it never leaves that closed journal active merely because upload qualification is missing.

Confirmed root loss bypasses this transaction and uses the preceding **Save Current Collection As…**/**Re-open from Disk** policy because the old root cannot accept a checkpoint, note settlement, journal namespace mutation, or directory synchronization.

A temporary-folder app instance creates and maintains its own current-host active/retained entries keyed by journal ID without changing the saved default bookmark. Matching is by resolved rooted-directory identity, not by which bookmark is global.

### Controlled storage-contract changes

A passphrase, encryption, or storage-format change is not a live preference mutation. Route every such change through one controlled-restart transaction: freeze edits, settle the current WAL/note/reconciliation obligations, install and verify a complete checkpoint under the old contract, retire the old journal only after its applicable durability barrier, prepare the target preferences and credential without modifying the accepted pair, install and verify the target representation described below, and restart before accepting another edit. Startup then creates the one fresh process journal under the new contract. A failed attempt leaves either the old journal plus checkpoint or the complete old-contract checkpoint alone; it never leaves one process writing a journal under two contracts.

Reuse and extend the existing `NotationPrefsViewController` confirmation path and `_finishExternalEditingForAction:informativeText:continuation:` boundary, the existing `PassphraseChanger`, and the all-note `requireFileWrite` admission loop currently embedded in `databaseSettingsChangedFromOldFormat:`. Extract the latter as the conversion admission step instead of adding a transition controller or another export scheduler. Change the preference UI continuations to supply proposed values rather than invoking `setPassphraseData:inKeychain:` or the encryption/storage setters on the accepted `NotationPrefs`. Build one isolated target `NotationPrefs` snapshot for serialization; the accepted object remains untouched and need not be swapped into the running controller because successful installation immediately commits a restart.

Keep the Keychain leaf in `NotationPrefs.m`. Reuse `_keychainQueryForAccount:` and `_keychainDataForAccount:status:`, but add one private add-only target-credential helper instead of using `_setKeychainData:forAccount:`, whose update branch is correct only for an already accepted item. For an encrypted target whose passphrase is to be remembered, generate a fresh UUID `keychainDatabaseIdentifier`, call `SecItemAdd`, burn and retry on an account collision, read the exact bytes back with `SecItemCopyMatching`, and validate them with the staged target KDF/verifier. The target checkpoint may be passed to `NVCheckpointTransaction` only after that validation. For an unremembered or unencrypted target, clear the staged identifier and create no target item. Credential cutover and **Save Current Collection As…** call this same provisioning leaf; only same-collection cutover owns post-commit deletion of its formerly accepted item, while Save As never deletes or aliases the source collection's item.

The exact verified `NVCheckpointTransaction` receipt is the credential-cutover commit point. Before it, neither the accepted preferences nor their old Keychain item may be modified or deleted. After it, the orderly path attempts to delete the old account and then restarts to publish the target preferences; deletion is best-effort, and failure produces a nonfatal cleanup warning rather than rollback or a blocked restart. A crash before target installation can leave one unreferenced target item from that attempt but the old checkpoint still references its untouched old item. A crash after installation leaves the target checkpoint referencing its already read-back-verified item and may leave the old item as inert residue. Retry allocates a new target identifier when needed, keeps no migration ledger, and never discovers, chooses, or deletes service-matching unreferenced items automatically.

For an ordinary encryption, passphrase, or non-provider-managed storage-format change, serialize the unchanged complete live store under the target settings and install it through `NVCheckpointTransaction` before restart. Replace the existing live encryption/format preference callbacks with this path. No migration ledger or compatibility for an unreleased intermediate epoch-5 state is needed.

### Entering the first-class provider-managed storage contract

Derive the contract every time from provider-managed authority, `PlainTextFormat`, and encryption disabled. Store no mode preference or provider capability profile. iCloud is the supported and validated configuration; another provider may exercise the same code only to the extent that each required standard operation succeeds.

Before conversion, explicitly warn that first-class iCloud interoperability stores note contents, filenames, and provider metadata as unencrypted plain text visible to other applications with folder access. When the source format is RTF or HTML, extend that confirmation with the new statement that plaintext content is retained while formatting and attachments are discarded.

Use the controlled-restart transaction above, but replace its ordinary same-store conversion step with the first-class export: export every note through the existing plaintext atomic writer, verify the same provider catalog token before and after the export, install and verify the complete unencrypted checkpoint, and restart into a fresh journal. This is deliberately a catalog-only fence; conversion does not require historical/nonlocal version enumeration. Reuse the existing preferences/storage-conversion and plaintext atomic-writer code. The old checkpoint format is the only restart marker; export is idempotent and divergent preexisting files enter normal reconciliation. Do not add a migration ledger.

A provider move that places an incompatible active root under provider management invokes the same blocking choice: convert/restart, choose another folder, or quit. Journal-durable admitted edits remain recoverable while the choice is pending.

If the legacy exact-name journal appears while a modern session is active, stop new filesystem mutations, preserve the modern journal, and ask the user to quit every NV process and relaunch modern NV. Concurrent epoch-4 and modern editing is unsupported.

## User-visible state and diagnostics

Keep presentation smaller than the internal state machine:

- A current, materialized checkpoint opens with no sync UI.
- Startup materialization/rebuild/recovery shows one progress view with cancel where cancellation is safe.
- Working offline remains visibly marked until current-known reconciliation succeeds or a stable current-visible fallback settles every visible obligation. The latter becomes an idle, session-continuous, nonblocking “file-version history unavailable” limitation rather than remaining offline or spinning indefinitely.
- Routine synchronization uses the existing activity indicator/status menu. A successful text merge is silent; all alternatives preserved by one transaction produce one coalesced conflict notification.
- The UI reports checkpoint upload pending/unknown or an actionable error. It does not distinguish “saved in WAL” from “saved to a local note file.”
- Database versions appear as nonmodal **Recover Notes**/**Discard** candidates. Unclaimed provider-managed journals expose **Recover Notes** only and are never presented as discardable evidence.
- Quit uses the existing wait/error/override UI.
- Authority uncertainty alone does not interrupt editing while the WAL remains durable. Journal durability suspension blocks editing and shows Retry, **Save Current Collection As…**, opening another collection after an abandonment warning, and quit after explicit discard confirmation; it is not a persistent read-only mode.
- Confirmed root loss never shows Cancel or Retry. Inconclusive root availability retains Retry; **Save Current Collection As…** remains available in both states because it preserves the already open in-memory collection without adopting the questionable root.

Storage diagnostics must remain content-free: operation, item count, error domain, and error code only. Do not log note text, filenames, tags, paths, bookmark bytes, persistent version identifiers, account identity, keys, or path-bearing error descriptions.

Do not add a diagnostics subsystem or public header. New provider/recovery storage leaves return a typed result plus `NSError` and never log. `NVRootSession.m` contains one private reporting choke point backed by unified logging; it accepts only a closed operation enum, item count, and error domain/code and has no parameter capable of carrying a free-form message, item URL/name, `localizedDescription`, or `userInfo`. WAL completions report their typed failure to the main-thread/root-session owner through the same boundary. Replace direct `NSLog` interpolation only on storage paths brought under this architecture; unrelated legacy diagnostics need not be refactored preemptively. UI error presentation remains separate and may use localized user-facing text.

## File-level implementation map

| File | Proposed change |
| --- | --- |
| `NVRootSession.h/.m` | New session owner, authority-fenced/provisional/active handoff, presenter, ordered provider/presenter/FSEvents/vnode lane, independent root-continuity/authority and journal-durability status, exact reverse-identity deletion probe, operation-scoped exact/current-visible capability handling, dirty/visibility state, transient resolution map, represented-journal set, private single-use checkpoint transaction/receipt with mandatory expected-current CAS, checkpoint-transfer helper, and diagnostics choke point |
| `AppController.m` | Asynchronous startup UI; presentation and cancellation owner for recovery, discard, rebuild, explicit creation, root-loss, and Save-As actions; select/clear the shared gate's lifecycle reason around monotonic pre-termination and controlled-transition flow; durability-suspension choices; native Save panel; remove app relocation command |
| `NotationController.h/.m` | Own active root session; structural generation; one main-thread edit-admission check with independent lifecycle/durability reason bits; initialize from and retain exact checkpoint bytes/ID; keep existing pending-write sets as sole obligation registries; immutable WAL/file-attempt capture; extend existing tombstone hooks; no termination write |
| `NotationDirectoryManager.m` | Extend the existing transaction with immutable prepared values; project catalogs into independent note/artifact sets; implement the decision matrix as one pure private function; enumerate version metadata for every note candidate while preparing content only for selected candidates; perform exact fences, partial preservation, recovery/rebuild; construct note objects only on the main thread |
| `NVRootedDirectory.h/.m` | Accessor-URL validation/adaptation, root bookmark refresh, fixed directory lock, private borrowed descriptor access for vnode monitoring, minimally expose exact catalog; migrate existing-destination installation to the one Foundation safe-replacement backend while retaining descriptor snapshots, verification, recovery, and exclusive creation; remove relocation method |
| `WALController.h/.m` | Versioned integrity header/name, ordered journal activation/demotion/cleanup APIs, independent serial queue, outbox-plus-barrier durability completion, direct current-host active/retained preference helpers, immutable record input; correct the legacy reader to stop at the first invalid/torn record |
| `StartupRecovery.m` | Policy/execution backend for legacy-before-modern and evidence recovery through the shared prepared-value transaction and the root session's checkpoint-transaction entry point, including explicit all-candidate recovery for ambiguous matching active claims and multiple eligible ordinary-local journals; every imported live state enters the existing pending WAL/file sets before success is reported |
| `NoteObject.h/.m` | Mutation-time LSN; immutable write-intent capture; provider-version ancestry archive field |
| `DeletedNoteObject.h/.m` | Identity-bound intentional tombstone and provider ancestry even without legacy sync metadata |
| `FrozenNotation.h/.m` | Optional checkpoint ID and exact verification support while keeping epoch-4 core readability |
| `NSData_transformations.h/.m` | SHA-256 plus a UUIDv5 wrapper over the existing SHA-1 helper, and the canonical tagged checkpoint-base-identity codec |
| `SyncSessionController.h/.m` | One provider participant in existing status/wait/error aggregation |
| `NotationPrefs.m`, `NotationPrefsViewController.m` | Route passphrase, encryption, and storage-format changes through controlled restart; stage proposed preferences without mutating the accepted object; share one fresh add-only/read-back-validated target-credential helper with encrypted Save As; delete an old item only after same-collection verified cutover and never from Save As; extend the existing confirmation UI with cleartext and formatting/attachment-loss disclosure while reusing external-editing shutdown, passphrase, and all-note export admission; no provider-managed mode bit or migration ledger |
| Xcode project | Add `NVRootSession`; link `FileProvider.framework` only if AV-09 validates provider-membership/domain-continuity use; add no iCloud entitlement for the user-selected root workflow |

Private intent/result/evidence objects should remain in the implementation file that consumes them. Split them into separate files only if Objective-C compilation dependencies force it.

## Formal-state mapping

| Model concept | Concrete implementation state |
| --- | --- |
| active/root session | fresh `NVRootSession` UUID plus active object identity |
| root continuity | transient `confirmed`/`inconclusive`/`confirmedGone` state; only positive validated deletion evidence selects `confirmedGone`, and every old-session completion then fails its ordinary session check |
| edit admission | one main-thread reason mask: modeled lifecycle quiescing plus unmodeled safety-strengthening `journalDurabilitySuspended`; clearing either reason cannot clear the other |
| local journal durability | existing pending-journal set plus WAL outbox/barrier result; its transient status selects only the durability bit in the shared admission mask and remains independent of provider-authority state |
| dirty obligation | independent provider-queue note and artifact-status generations; note state retains coalesced pre-visibility projections, and a stable current-visible note commit may consume only the generation accounted for by its narrower fences |
| version-discovery scope | root-session-only `exact` or stable-unsupported `currentVisible`; never persisted and reset to exact attempt by a fresh session |
| provider catalog token | exact `NVRootedDirectoryCatalog` equality value, projected independently for authoritative notes and NV artifacts |
| provider version set | `NSSet` of retained opaque `NSFileVersion.persistentIdentifier` values |
| note-changed fence | captured note UUID/LSN pairs |
| structural-changed fence | main-thread `NotationController` structural generation |
| unsettled local note/WAL work | existing main-thread `pendingFileWrites`/`pendingJournalWrites` membership; immutable attempts never become a second obligation registry |
| represented versions | optional ancestry archived in `NoteObject`/`DeletedNoteObject` |
| resolution eligibility | transient root-session map populated only by complete exact routine or explicit **Recover Notes** commits |
| accepted/verified checkpoint | one immutable receipt produced only after the private single-use checkpoint transaction's mandatory expected-current CAS and exact post-install verification, containing exact bytes, canonical checkpoint identity, installed local-version ID, request identity, exact provider-version `resolutionCoverage`, and exact represented-journal coverage |
| remembered credential ownership | every installed encrypted remembered checkpoint names its own fresh add-only/read-back-validated item; same-collection cutover may delete only its former item after commit, while Save As neither aliases nor deletes the source item |
| atomic existing-file installation | Foundation safe replacement inside the rooted descriptor, retained-stage, exact-byte, metadata, and disposition checks defined by the migration plan |
| active journal | versioned integrity header plus one synchronized current-host `NVActiveJournal.<journalID>` claim, exposed for editing only by the ordered activation entry point |
| retained journal | the same immutable artifact plus synchronized current-host `NVRetainedJournal.<journalID>` containing schema, root bookmark, and exact covering checkpoint identity; never appendable or upload evidence |
| represented journal coverage | exact `NSSet` of journal IDs in `NVRootSession`, frozen into each checkpoint receipt; rebuilt from matching claims and completed recovery rather than persisted as shared history |
| journal creation count | exclusive random filename creation; failed/colliding IDs are burned |
| quit phase | monotonic main-thread AppController state |

This table is the refinement boundary for the TLA+ state. Do not substitute timestamps, paths, pointer reuse, callback order, or upload-status text for any modeled identity or fence.

The implementation boundaries trace to the existing contracts as follows; this is a review index, not another source of requirements:

| Boundary | Governing decisions | Formal reference |
| --- | --- | --- |
| root open, checkpoint currentness, offline choice, rebuild | ADR-0001, ADR-0002, ADR-0012 | `StartupSafety` |
| journal activation, replay, and cleanup | ADR-0005, ADR-0006, ADR-0007, ADR-0009, ADR-0010 | `JournalLifecycle`, `HostLocalJournalOwnership`, `CrossMachineDurability`, `CrossMachineGenerationSafety`, `JournalRecoverySafety`, `MultiJournalRecoverySafety`, `JournalLaneIndependence` |
| note reconciliation and provider-version evidence | ADR-0001, ADR-0003, ADR-0010, ADR-0012 | `ReconciliationInterface`, `ReconciliationDecisionSafety`, `ReconciliationFencingSafety`, `CurrentVisibleFallbackSafety`, `ReconciliationSafety`, `RecoveryEvidenceSafety` |
| checkpoint transaction, upload qualification, and quit override | ADR-0004, ADR-0008 | `QuitSafety`, `CrossMachineDurability`, `CrossMachineGenerationSafety`, `ReconciliationSafety` |
| passphrase/encryption/storage conversion | ADR-0011 | `StorageTransitionSafety` |
| root move/loss and **Save Current Collection As…** | ADR-0004, ADR-0010, ADR-0011 | stale-completion fencing refines `ReconciliationFencingSafety`; fresh opening, export, and target credential provisioning reuse `StartupSafety`/`StorageTransitionSafety` boundaries, while AV-08/AV-14 and crash tests cover the unmodeled edit gate, cross-root construction, and independent credential ownership |

## Implementation sequence

Each slice should leave the existing local-filesystem path working:

1. **Identity foundation:** implement the normative persistence-format appendix exactly—canonical checkpoint-identity codec, modern versioned journal header/name, `.nv-root.lock`, direct current-host active/retained claim shapes, ancestry archive shape, and byte/epoch-4 compatibility vectors—before any writer ships.
2. **Execution separation:** immutable WAL records and durability queue; outbox-plus-barrier completion and the main-thread journal-durability admission gate; `NVRootSession` provider queue/presenter with one serial underlying callback queue; move existing note-file work off-main without changing its CAS algorithm or duplicating its pending-write registries; remove blanket FSEvents `IgnoreSelf`.
3. **Foundation replacement foundation:** complete phases 0 and 1 of [Foundation safe-replacement migration](../Foundation-Safe-Replacement-Migration.md): expand the current atomic/filesystem/provider contract tests and add one private backend without selecting it for ordinary note writes or deleting a fallback.
4. **Provider discovery/startup:** provider-managed/local/unknown authority, opaque domain continuity, operation-scoped capability handling, exact-item checkpoint status/materialization, coordinated shallow catalogs, startup progress/offline choices, root moves, and vnode-backed root-loss classification.
5. **Transactional versions:** current/other/unresolved/nonlocal enumeration, batch reads, exact dual fences, pure decision function, deterministic complete/partial publication, provenance/tombstones.
6. **Recovery and rebuild:** all-version database Recover Notes/Discard, provider-managed unclaimed-journal Recover Notes, explicit all-candidate recovery for ambiguous active claims and multiple ordinary-local journals, strict valid-prefix replay, deterministic UUIDv5, format-aware all-or-nothing rebuild.
7. **Quit and transitions:** closing barrier before presenter removal, one private checkpoint transaction used by every local checkpoint installation, exact receipt, phase-2 checkpoint adoption of Foundation replacement, sync-controller participant, macOS 26 upload optimization/fallback, controlled-restart encryption/storage conversion, and **Save Current Collection As…** through independent target-credential provisioning, bootstrap, and optional existing export.
8. **Replacement convergence:** complete phases 3 through 5 only after their behavior gates pass: adopt unconditional and checked-UUID conditional replacement, rerun the complete filesystem/provider matrix, remove the complete production/test inventory listed by migration phase 5, and update the current atomic-save contract.

Do not start with the macOS 26 upload optimization. It depends on the exact checkpoint receipt and quit state but does not define either one.

## Verification architecture

Keep the production design concrete. Tests can subclass `NVRootSession` or `NVRootedDirectory` in the test target to inject provider callbacks and fence values; a production provider protocol solely for mocking is unnecessary.

Add focused deterministic checks for:

- UUIDv5 vectors through the existing SHA-1 helper, SHA-256 vectors, exact normative checkpoint-identity and journal-header vectors, malformed tag/version/length/CRC rejection, canonical journal-name parsing, checkpoint-ID round trips, exact current-host plist shapes, and ancestry semantic archive round trips;
- epoch-4 opening a clean epoch-5 checkpoint via `tools/test-epoch4-v5-compatibility.sh`;
- journal persistence and ownership:
  - magic/version/CRC validation and every create/header-sync/claim/claim-sync crash point returning no writable handle;
  - every active-to-retained crash point including synchronized dual-role recovery, plus matching and mismatched retained checkpoint coverage;
  - ambiguous matching active claims and multiple ordinary-local unclaimed journals taking explicit exact all-candidate recovery, with pre-transition cancellation preserving every candidate, completed-member cleanup remaining completed, failed or unprocessed members remaining conservative including `deleting`, artifact reappearance, and no fresh active journal until every former active ID is absent or retained;
  - cleanup and startup pruning retaining the claim until successful root-directory synchronization after current absence validation, including directory-sync and claim-tail retry and the unlink-success/sync-failure/terminate/restart trace; and
  - UUID collision retry, current-host matching, copied roots, and directory-lock exclusion;
- valid-prefix recovery stopping at corrupt framing, length, decompression, checksum, archive, class, and semantic records without processing a later record; three records across two journals in every order-preserving interleaving, including both within-journal delete/update orders, cross-journal delete/update preservation, equal-state duplicate idempotence in either journal order, and anti-resurrection;
- mutation-time UUID/LSN fencing, the existing pending sets remaining the sole obligation source, stale file-write completions never clearing a newer set entry, and every accepted database/unclaimed-journal recovery import entering both applicable pending sets and becoming WAL-durable before a crash can lose it;
- note-catalog and version-ID equality changing independently; artifact-only changes never blocking or completing the note generation;
- all-candidate version metadata calls initiated within each candidate's coordinated read, discovering a changed version set when current catalog metadata and callbacks did not change, while unchanged content remains unmaterialized;
- normal startup and complete reconciliation with Spotlight disabled, the root excluded from Spotlight, and the metadata index rebuilding or broken;
- immediate-metadata-only exact probes using promised-item resource values, plus ordinary coordinated shallow catalogs over dataless folders proving whether child names/placeholders are complete without materializing unchanged note contents;
- provider-managed/local/unknown authority discovery across iCloud, Dropbox, ordinary APFS, removable, network, unavailable, and unassigned items; opaque domain equality without provider-name/path/display-name parsing; advertised sync controls whose actual operation succeeds, reports unsupported, or fails transiently; and exactly the `CAP-01` result selecting session-scoped current-visible reconciliation or bootstrap while every other failure remains incomplete and a fresh session retries exact discovery;
- candidate discovery after current-file deletion/rename and for nonlocal versions whose current URL is absent;
- every one of the twenty-two exactly named conflict-matrix fixtures under every version traversal order; identity-tier tests first associate all unique stable identities before considering unmatched filenames or content, including an original file renamed while a different file reuses its old name, same-name identity-changing safe replacement, duplicate/ambiguous identities, and the no-identity fallback path;
- complete exact publication, stable current-visible publication, and additive partial preservation as distinct outcomes; fallback dirty-generation consumption only under stable current fences; no fallback resolution eligibility; and persistent ancestry;
- a presenter notification delivered before its catalog mutation becomes visible, plus NV's own FSEvent arriving after a provider-lane write and causing at most an idempotent follow-up transaction; exact deterministic `0.1/0.5/2/10/30`-second retry scheduling, coalescing, cap, and reset after visible progress;
- two-host checkpoint, journal-create, journal-delete, and note delivery in every cross-file order, including journal deletion reaching one replica before its covering checkpoint, while one host's journal-preference transitions leave the other's preferences unchanged;
- stable closing while the presenter remains registered, followed by unregister/drain with no post-removal reconciliation restart;
- a verified same-authority root move during every AV-08 operation leaving the session and structural generation unchanged while valid work can publish, plus authority-change session replacement with identical visible inputs, handoff-specific old vnode-source cancellation that does not close the transferred descriptor, successor source attachment and namespace/journal revalidation, gap ambiguity remaining frozen, and late callbacks unable to publish or authorize cleanup;
- vnode-delete classification through the exact reverse File Provider recipe: same-item move/eviction/vnode replacement proves survival, exact-domain `NoSuchItem` proves provider deletion, different replacement identity is never adopted, and every unavailable/missing-domain/authentication/network/unsupported/malformed result stays inconclusive;
- authority-only uncertainty continuing edits and WAL durability while provider publication stays frozen; coordinated and uncoordinated local/provider root deletion, rename, revoke/unmount, and same-path replacement with an identical copy; immediate edit gating on revoke, deletion accommodation, and injected append/outbox/barrier failures; the in-delivery edit admitted exactly once; pending records urgently drained without changing ordinary coalescing; resume only after rooted revalidation plus successful barrier; permanent revoke never resuming; vnode-event coalescing; no false deletion classification from `ENOENT`, stale bookmark, `F_GETPATH`, link count, or presenter advance notice; and the exact confirmed/inconclusive UI matrix;
- **Save Current Collection As…** panel cancellation before creation returning to the old prompt; destination collision; cancellation/crash before and after bootstrap verification; proven empty pre-bootstrap cleanup versus disclosure and retention of a complete post-bootstrap destination; interruption during every exported file/final installation boundary; complete bootstrap reopening, conversion retry without a ledger, permanent/temporary bookmark behavior, fresh target journal activation, no target coverage of the old journal, **Re-open from Disk** using ordinary fresh-root startup, and remembered-encrypted targets receiving fresh add-only/read-back-validated credential IDs without source-item deletion or cross-destination aliasing—including credential collision, unavailable passphrase, proven pre-install cleanup, ambiguous-install retention, multiple surviving destinations, and later independent passphrase cutover;
- no provider or network operation on the main thread and WAL progress while provider work is stalled;
- every checkpoint-installing caller—including new collection creation—routing through the private transaction; expected absence and exact expected-byte/available-local-version preconditions; no namespace mutation on `NVCheckpointInstallCurrentChanged`; exact checkpoint byte read-back/decode/ID/local-version checks; single-use enforcement; retained-coverage advancement; and rejection of every mismatched receipt request, local-version, checkpoint-identity, resolution-coverage, and journal-coverage combination;
- one edit-admission check with independently composed lifecycle and durability reasons, including blocked undo/redo leaving the undo stack unchanged and external publication using the existing non-undoable prepared-state path; quit reentry, every pre-checkpoint failure, provably empty no-checkpoint closure and rejection of nonempty/uncertain bytes, override, transient `EBUSY` pause retries, pause/upload/resume correlation, provider-lane pre-macOS-26 resource-key transitions tied to one unchanged receipt/local version, active-to-retained fallback, independent provider-version resolution failure, one qualified receipt cleaning multiple retained generations with independent member failure, backlog-only cleanup checkpoint, and next-launch paused-item repair;
- startup current/stale/unmaterialized/offline/rebuild branches; paused-resume failure choices; catalog-plus-fixed-name-version absence classification followed by expected-absence installation; cancellation and elapsed time publishing no partial store;
- rebuild from any readable separate-file root using exact, ordinary-local, or `CAP-01` current-visible fencing; every disclosed current/other/unresolved/nonlocal version in exact scope and current-only input in the narrower scopes; deterministic built-in extension mapping and explicit per-extension decoder/Ignore decisions without content sniffing; each historical version decoded by its candidate URL's extension through the existing initializer; provider-managed plaintext target with the extended formatting/attachment-loss confirmation; uniform ordinary-local retention; mixed ordinary-local target selection and detached conversion; expected-absence or exact-predecessor checkpoint CAS with appearance or same-status predecessor replacement restarting discovery; safe non-format defaults with no recovered settings or deletion inference; rejected database evidence preserved; and session-continuous limited-history presentation only for current-visible publication;
- batch preparation completion exactly once after nested accessors on every exit, plus AV-04 failure selecting serial per-URL asynchronous coordination with identical selected input, fences, and publication;
- ordinary passphrase/encryption and first-class provider-managed controlled-restart paths, including the shared add-only target-Keychain provisioning leaf, read-back/KDF validation, target-account collision retry, every crash boundary around target-checkpoint installation, nonfatal old-item cleanup failure, and proof that cleanup never removes another collection's credential;
- diagnostics proving storage leaves return errors without logging and the root-session choke point emits only operation/count/error-domain/error-code fields; and
- provider/Finder root moves and deep root paths.

The replacement-specific cases, filesystem matrix, failure injection, and deletion gates in [Foundation safe-replacement migration](../Foundation-Safe-Replacement-Migration.md) are mandatory parts of this verification architecture, not optional cleanup after the iCloud feature ships.

Extend the existing integration-test harness and filesystem capability matrix rather than introducing another runner. Use real iCloud tests for API behavior that a fake cannot establish, while deterministic test doubles cover race orderings and failures. [Apple API Contract Validation](../Apple-API-Contract-Validation.md) is the acceptance matrix for behaviors that mocks and the TLA+ models cannot prove. Run every applicable configuration in [the TLA+ README](../tla/README.md) whenever implementation-driven behavior changes require adjusting the models; never weaken a modeled safety predicate to fit the code.

## Deliberate omissions

This architecture does not add:

- a second synchronization database;
- a second pending-write registry, public checkpoint transaction/controller, or diagnostics subsystem;
- CloudKit or direct Dropbox integration;
- vector clocks, UUID xattrs, sidecars, or a provider-event ledger;
- periodic checkpointing, journal sealing/rotation, writer IDs, or legacy WAL aliases;
- whole-checkpoint restore/export or a version picker;
- a stored first-class provider-managed mode flag;
- a provider-brand classifier or persisted provider capability profile;
- permanent parallel local/provider or filesystem-specific existing-file replacement backends after the Foundation migration gates pass;
- concurrent provider lanes;
- any correctness or liveness dependency on Spotlight or `NSMetadataQuery`;
- application-driven whole-root relocation;
- cross-root merge/adoption, WAL transplant, claim transfer, emergency escrow, or a root-loss recovery ledger;
- compatibility for unreleased intermediate epoch-5 designs; or
- the proposed future RNCryptor/FSNotes separate-file format.

Those omissions are part of the design: the existing live model, exact checkpoint, append-only process journal, individual note files, Apple version evidence, and exact transactional fences already cover the specified authority and recovery boundaries.
