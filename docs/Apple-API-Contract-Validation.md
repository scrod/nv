# Apple API contract validation for iCloud Drive support

Status: required implementation-validation ledger; the behavior specification remains [Robust iCloud Drive Support](iCloud-Drive-Support-Spec.md)

This document records Apple-framework behavior that the NV design needs but that the TLA+ models, mocks, and API type signatures cannot prove. Each condition must be established from current Apple documentation, a focused real-iCloud test, or both before code relies on it. An unestablished condition is not silently assumed: the listed fail-closed behavior applies.

No elapsed-time threshold proves freshness, absence, completeness, upload, or conflict resolution. Timeouts may expose Retry, Work Offline, Choose Folder, or Quit, but they never turn unknown state into success. Every potentially blocking probe runs on the provider queue.

## Acceptance summary

| ID | Required Apple behavior | Needed for | If not established |
| --- | --- | --- | --- |
| AV-01 | Ubiquity and exact-item download status identify iCloud and a provider-current checkpoint | Fast normal startup | Classify as `unknown`; do not claim first-class iCloud or current startup |
| AV-02 | Explicit materialization plus coordinated read yields the requested exact item or an error | Stale/unmaterialized startup and selected note reads | Keep progress/offline choices; never publish partial bytes |
| AV-03 | Coordinated shallow enumeration discloses the current direct-child namespace without reading child contents | Routine reconciliation and rebuild | Snapshot is incomplete; no complete commit, resolution, cleanup, or rebuild publication |
| AV-04 | Batch preparation and nested coordinated reads have the required accessor/completion behavior | Efficient selected-version reads | Fall back to serial per-URL coordinated reads |
| AV-05 | `NSFileVersion` calls produce a stable, complete set for each known candidate URL | Current-known reconciliation and recovery | Preserve known states, retain dirty, and confer no resolution eligibility |
| AV-06 | Historical versions remain discoverable for retained URLs after rename/deletion, or presenter callbacks supply a usable URL | Deleted/renamed version recovery | Treat undiscoverable history as unseen remote work; never claim it was resolved |
| AV-07 | Presenter callbacks and later exact observations can discharge callback-before-visibility obligations | Reconciliation liveness | Retain dirty with bounded-backoff retry; safety remains intact |
| AV-08 | Root move callbacks/bookmarks continue to identify the open rooted directory | Path-independent provider moves | Close/reopen a fresh root session or present folder recovery |
| AV-09 | File Provider URL identity works for ordinary consumer apps and has a sound positive/negative interpretation | Other-provider versus ordinary-local classification | Success may confirm another provider; every ambiguous failure remains `unknown` |
| AV-10 | macOS 26 pause/upload/resume and returned-version correlation behave as specified | Optimized exact checkpoint upload barrier | Use ordinary iCloud sync and retain journal/claim until conservatively qualified |
| AV-11 | Legacy upload resource-key transitions are observable with the stated meaning | macOS 11.5–15 compatibility cleanup | Upload remains pending/unknown and journal/claim remain |
| AV-12 | Spotlight failure cannot affect any required path | Startup and reconciliation availability | Ship blocker if a required path still references `NSMetadataQuery` |
| AV-13 | A normally signed NV process can use the required iCloud APIs on a user-selected external iCloud Drive root with a known minimal entitlement set | Deployment and signing | Add the proven minimum entitlement without creating an app container; block first-class support if no supported configuration works |

AV-01, AV-02, AV-03, AV-05, AV-07, and AV-13 are first-class-iCloud ship conditions. AV-04 and AV-10 are optimizations with specified fallbacks. AV-06 defines the discoverability ceiling of current-known and never authorizes loss or resolution of unseen evidence. AV-09 is required only to distinguish non-iCloud File Providers from confirmed ordinary local storage; it does not gate confirmed iCloud.

## AV-01 — iCloud classification and checkpoint currentness

APIs:

- `NSURLIsUbiquitousItemKey`
- `NSURLUbiquitousItemDownloadingStatusKey`
- `NSURLUbiquitousItemDownloadingErrorKey`
- `NSURLUbiquitousItemIsSyncPausedKey` on macOS 26+
- `NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly`
- `-[NSURL promisedItemResourceValuesForKeys:error:]`

NV requires all of the following:

1. A user-selected directory inside iCloud Drive can be positively identified by the ubiquitous-item key on the item or a nearest existing ancestor without reading note contents.
2. A coordinated metadata-only accessor using promised-item resource values can read the exact root/checkpoint classification and status keys without materializing file content or waiting for content availability. NV never attempts a content read or directory enumeration under this option.
3. Reading the canonical checkpoint's download-status keys does not itself materialize its content.
4. `NSURLUbiquitousItemDownloadingStatusCurrent` means that complete local content exists and is the newest version iCloud has disclosed to this Mac. It need not mean globally current.
5. A missing, nil, erroring, or unknown status is distinguishable from `Current` and never treated as current or absent.
6. On macOS 26+, paused status is observable before freshness evaluation and resume failure remains distinguishable from success.

Validate nested iCloud Drive roots, Optimize Mac Storage with an evicted checkpoint, offline launch, account sign-out/change, a root moved into or out of iCloud Drive, and a checkpoint replaced remotely immediately before launch. Compare metadata-only and ordinary coordinated probes and record whether either triggers materialization or waits for content. If the metadata-only option is unavailable or insufficient, use ordinary coordination on the provider queue. If any positive classification or status read remains inconclusive, the root/status is `unknown`; startup follows the specified progress/offline/folder/quit choices.

## AV-02 — exact-item materialization and read completion

APIs:

- `-[NSFileManager startDownloadingUbiquitousItemAtURL:error:]`
- ubiquitous-item download status/error keys
- `NSFileCoordinator` coordinated reads

NV requires all of the following:

1. Requesting download for the exact checkpoint or selected note/version returns promptly enough to be called on the provider queue and does not require main-thread waiting.
2. A successful request does not itself count as completion; a later exact-item status/error observation or coordinated-access result does.
3. Once the item reports `Current`, a coordinated read returns the complete bytes for that version or an error. Short/partial data is never exposed as a successful read.
4. Cancellation and provider/account/network failures eventually permit NV to stop its own operation even if the provider has no completion deadline.

The startup `NSProgress` is app-owned and indeterminate by default. A percentage may be displayed only if an exact-item API supplies a value with validated semantics; percentage is never a correctness input. Test offline-to-online recovery, cancellation at each phase, eviction during a request, remote replacement during download, corrupt local bytes, and thousands of selected note versions. Failure retains the old store/evidence and leaves the operation retryable.

## AV-03 — coordinated shallow namespace catalog

APIs:

- `NSFileCoordinator` reading the root directory
- the existing descriptor-relative `NVRootedDirectory`/`NVRootedDirectoryCatalog` enumeration
- cheap `NSURL`/`stat` identity and revision metadata used by that catalog

NV requires all of the following:

1. Inside a coordinated root accessor, enumerating direct children discloses every current child name/placeholder iCloud has made known to this Mac for that observation.
2. Listing a dataless directory may wait for namespace availability, but it does not download unchanged child file contents.
3. Enumeration failure, an unavailable directory, a provider error, or a partially returned listing is detectable as incomplete rather than indistinguishable from an empty directory.
4. Two independently created catalogs compare equal exactly when all namespace/cheap-revision inputs relevant to candidate selection compare equal. The token is equality-only.
5. Root coordination is not assumed to coordinate child contents; selected children are prepared and read separately.

Validate with 0, 1, 1,000, and 10,000 files; every file evicted; remote create/delete/rename during each fence; filename collision and Unicode/case variants; deep roots; an evicted directory placeholder; network loss during enumeration; and Spotlight enabled, disabled, excluded, rebuilding, and damaged. Record whether listing materializes child contents and whether errors distinguish incomplete from empty. Until this contract passes, routine processing may preserve known alternatives but cannot report a complete current-known transaction; rebuild cannot publish.

## AV-04 — selected-item batch preparation

APIs:

- `-[NSFileCoordinator prepareForReadingItemsAtURLs:options:writingItemsAtURLs:options:error:byAccessor:]`
- asynchronous coordination with `NSFileAccessIntent`
- nested coordinated reads of current and historical version URLs

NV requires all of the following:

1. Batch preparation requests materialization only for the selected URLs and does not implicitly fetch unchanged siblings.
2. Accessor URLs remain valid for the synchronous accesses completed before the accessor's supplied completion handler is called.
3. Nested coordinated reads of `NSFileVersion.URL` do not deadlock the serial provider queue and expose provider-prepared content.
4. NV can invoke the supplied completion handler exactly once on success, error, cancellation, and Objective-C exception paths without abandoning coordinated access.

Validate mixed local/nonlocal versions, duplicate URLs, one failing URL, cancellation before and during the accessor, provider delay, historical URLs outside the root, and presenter callbacks arriving while preparation waits. If batch behavior fails any condition, use the already-correct serial per-URL asynchronous coordination path. This affects latency, not publication semantics.

## AV-05 — per-candidate `NSFileVersion` completeness and identity

APIs:

- `+[NSFileVersion currentVersionOfItemAtURL:]`
- `+[NSFileVersion otherVersionsOfItemAtURL:]`
- `+[NSFileVersion unresolvedConflictVersionsOfItemAtURL:]`
- `+[NSFileVersion getNonlocalVersionsOfItemAtURL:completionHandler:]`
- `persistentIdentifier`, `URL`, and `hasLocalContents`

Apple's SDK directs clients that need all local and nonlocal versions to register an `NSFilePresenter` and invoke the version APIs within one coordinated read. NV requires:

1. Every completion returns exactly one success set or an error; nil/error ambiguity is treated as incomplete.
2. The union of current, other, unresolved, and returned nonlocal versions is complete for that candidate URL at the fenced observation.
3. `persistentIdentifier` remains equal for the same immutable version as it moves between nonlocal and local caches and is suitable for equality across process launches/checkpoint archives.
4. Distinct immutable versions do not compare equal, and no ordering is inferred from identifiers.
5. A coordinated read of a nonlocal version's supplied URL yields that immutable version, not whichever file later occupies the current path.

Validate two-Mac simultaneous edits, multiple unresolved versions, remote versions not cached locally, eviction and rematerialization, version resolution/removal during enumeration, process restart, and independent catalog-only/version-only changes. Any failed callback/read or unstable identity marks enumeration incomplete, permits additive preservation only, retains dirty, and confers no provider-version resolution eligibility.

## AV-06 — renamed, deleted, and absent-current historical versions

There is no public directory-wide `NSFileVersion` enumeration API. NV therefore retains candidate URLs from the live model and last accepted catalog and adds URLs delivered by presenter move/version callbacks.

NV needs at least one of these behaviors for a historical version whose current file is gone:

1. Calling the version APIs with the retained pre-delete/pre-rename URL still returns the historical versions; or
2. `NSFilePresenter` supplies a URL that can be used to enumerate/read those versions.

Validate remote delete, local delete, remote rename, local rename, delete followed by recreation at the same name, and restart before and after each callback. If neither behavior holds, document the resulting discovery ceiling: the version is undisclosed remote work and is outside current-known until Apple exposes it through a candidate source. NV must never resolve, discard, or claim representation of that unseen version.

## AV-07 — presenter notification visibility and liveness

APIs:

- root-directory `NSFilePresenter` subitem appearance/change/move/deletion callbacks
- gain/lose/resolve-version callbacks
- `presentedItemDidChangeUbiquityAttributes:`
- relinquish/accommodation callbacks

NV does not assume that callback delivery and provider catalog visibility are atomic. It requires this eventual condition only for liveness: after a generic callback, a later coordinated catalog/version observation either differs from the saved pre-callback projection, or a later callback carries exact version evidence that appears in the version set. A callback that arrives during a transaction must remain a newer dirty generation and cannot be consumed by that transaction.

Validate both orders—state visible before callback and callback before state visible—for remote create, content edit, rename, delete, conflict gain/loss/resolution, materialization, and root ubiquity changes. Also test uncoordinated external editors, NV's own coordinated writes, provider restarts, callback coalescing, and presenter removal/drain at quit. If visibility never advances, NV keeps one coalesced dirty obligation and retries with bounded backoff; it does not spin, fabricate completion, or block the UI/WAL. This is the implementation refinement of the TLA+ dirty invariant, not a modeled fairness promise about Apple.

## AV-08 — root moves and path independence

APIs:

- `presentedItemDidMoveToURL:`
- file-reference URLs and bookmarks
- the existing open rooted-directory descriptor and filesystem identity checks

NV requires a provider/Finder move callback's URL to be verifiable as the same directory already held open, including across a rename or move within the same provider domain. Refreshed bookmark data must resolve back to that identity, not merely equal path text.

Validate moves before, during, and after catalog/read/write coordination; nested and deep roots; provider-domain and iCloud-account changes; temporary-folder instances; stale bookmark refresh; and a copied directory with identical contents. A verified same-directory move keeps the session; any identity ambiguity closes it and opens a fresh incarnation so late work is discarded.

## AV-09 — File Provider classification from a consumer app

API:

- `+[NSFileProviderManager getIdentifierForUserVisibleFileAtURL:completionHandler:]`

The SDK says that a URL outside the applicable provider/domain **or** an item not yet assigned an identifier can both produce `NSFileNoSuchFileError`. NV therefore cannot currently treat that error as positive proof of ordinary local storage.

Before relying on this API, validate from a normal NV process—not a File Provider extension—that:

1. A Dropbox/other-provider root and a newly created coordinated child return stable item and domain identifiers.
2. iCloud, ordinary APFS, removable local, network, unavailable, and unassigned provider items produce distinguishable results.
3. Domain identifiers remain equality-stable for the open root and change when provider authority changes.

Success may positively classify another File Provider. Every error or nil pair remains `unknown` unless Apple documents and testing establishes a separate positive ordinary-local test. Failure to validate this API does not block first-class iCloud, but it disables the confirmed-other/confirmed-local distinction and therefore the ordinary-local journal-cleanup shortcut for affected roots.

Do not use `enumeratorForMaterializedItems`; it is a provider-domain management API, enumerates only materialized items, and cannot establish NV's complete note namespace.

## AV-10 — macOS 26 exact checkpoint upload optimization

APIs:

- `NSURLUbiquitousItemSupportedSyncControlsKey`
- pause and resume sync controls
- `-[NSFileManager uploadLocalVersionOfUbiquitousItemAtURL:withConflictResolutionPolicy:completionHandler:]`
- returned `NSFileVersion`

NV requires all of the following when the controls are advertised:

1. Pausing only `Notes & Settings` prevents automatic transfer of an intermediate replacement while preserving local edits.
2. Fail-on-conflict upload either accepts the exact stable local version or returns a distinguishable conflict/error.
3. The callback's returned version can be correlated by persistent identifier to the locally installed version and by decoded `checkpointID` to the immutable receipt.
4. Resume-with-preserve-local-changes is safe and callable on every success/error/cancellation path; next launch can observe and repair a failed resume.
5. No coordinator accessor must remain open while waiting for network upload.

Validate pause failure before acquisition, crash after pause, replacement while paused, stale callback from an older request, identifier/checkpoint mismatches, remote conflict, cancellation, upload success, resume failure, and next-launch repair. Any unsupported control or pre-pause failure uses ordinary sync. Any ambiguity after pause retains journal/claim and reports pending/error through `SyncSessionController`.

## AV-11 — pre-macOS-26 upload qualification

APIs:

- `NSURLUbiquitousItemIsUploadedKey`
- `NSURLUbiquitousItemIsUploadingKey`
- `NSURLUbiquitousItemUploadingErrorKey`
- coordinated exact checkpoint read-back and local `NSFileVersion`

For compatibility only, validate whether one post-install not-uploaded/uploading-to-uploaded transition can be observed without polling on the main thread and without confusing an earlier or later checkpoint. The full transition, unchanged local version, exact bytes, and matching `checkpointID` are all required. A status already observed as uploaded, a missed transition, or any error is pending/unknown. This contract is intentionally conservative; retaining the journal is the fallback.

## AV-12 — Spotlight independence

API:

- `NSMetadataQuery`

There is no NV correctness requirement on this API. The initial implementation must contain no `NSMetadataQuery` object and no wait for `NSMetadataQueryDidFinishGatheringNotification`. Validate that all required startup, reconciliation, rebuild, recovery, status, and quit tests behave the same when:

- indexing is enabled and healthy;
- the notes root is excluded from indexing;
- indexing is disabled;
- the metadata index is rebuilding or unavailable; and
- a query, in a diagnostic build, returns late, empty, duplicated, or stale results.

If `NSMetadataQuery` is ever added for determinate progress or extra wakeups, deleting that optional component must leave every state transition and safety decision unchanged. Its result set may request a retry, but may never add authoritative candidates, establish absence/completeness, discharge a visibility witness, or clear dirty.

## AV-13 — signing and entitlement contract for a user-selected iCloud root

Capabilities and APIs:

- `com.apple.developer.icloud-services` / iCloud Documents capability when required
- the app's effective code-signing entitlements
- ubiquitous-item resource keys, `NSFileCoordinator`, `NSFilePresenter`, `NSFileVersion`, and macOS 26 sync controls on a user-selected iCloud Drive URL

NV selects an existing user-visible directory; it does not call `URLForUbiquityContainerIdentifier:`, own a ubiquity container, or migrate the notes folder into one. Validate release-signed builds from a normal unsandboxed NV process with no iCloud entitlement and with the minimum entitlement configuration Apple permits. On each supported OS family, establish whether the process can positively classify the selected root and use every required first-class API, including version discovery and sync controls where available.

If no entitlement is required, add none. If iCloud Documents capability is required, add only the minimum proven signing entitlement and container declaration required by Apple while continuing to operate on the user-selected external root; do not introduce an app-owned storage location or key-value-store entitlement. Missing-entitlement and authorization failures must be distinguishable from a non-iCloud root and produce `unknown`/actionable setup failure rather than silently dropping to ordinary POSIX behavior. If no supported signing configuration permits the required APIs on a user-selected root, first-class iCloud support is blocked until the architecture is revised.

## Real-system validation matrix

Run the ship-condition cases on at least macOS 15 and the current macOS release, using two Macs on one iCloud account where remote ordering matters. Repeat provider-classification cases with current Dropbox and at least one other File Provider, but record those as best-effort observations rather than iCloud guarantees.

For every case, capture only content-free diagnostics: OS build, operation ID, item count, elapsed phase, status enum, error domain/code, and whether each required condition passed. Never record paths, filenames, note text, persistent version identifiers, account identity, or bookmark bytes.

The minimum fault matrix is:

- online, offline, reconnecting, and iCloud account transition;
- Optimize Mac Storage on/off with files and directory evicted;
- remote mutation before first fence, between fences, after second fence, and before callback visibility;
- File Provider daemon restart and app crash at each accessor/completion boundary;
- Spotlight healthy, disabled, excluded, rebuilding, and unavailable;
- root moved, renamed, copied, deleted, and replaced while work is in flight;
- normal quit, explicit quit override, pause/upload/resume failure, and next-launch recovery; and
- release-signed builds with each AV-13 entitlement configuration on user-selected roots inside and outside iCloud Drive.

An API/OS result is accepted only when the test demonstrates the required condition, not merely because the operation eventually appeared to work in Finder. Record the result beside the relevant AV identifier before enabling that path.

## Relationship to the TLA+ models

The models begin from abstract delivered candidates, catalog tokens, version sets, callbacks, and success/failure results. They prove what NV may do with those values; they do not prove that Apple disclosed every candidate, that a callback is catalog-visible, or that an upload result identifies remote durability.

Removing `NSMetadataQuery` therefore does not violate or alter a tested model: no model contains a query-gathering state or assumes Spotlight fairness. AV-03, AV-05, AV-06, and AV-07 define how real Apple behavior refines the discovery and dirty inputs to `ReconciliationSafety` and `ReconciliationFencingSafety`; AV-01 and AV-02 refine `StartupSafety`; AV-10 and AV-11 refine `QuitSafety`. AV-13 is a deployment precondition outside the state models. If an implementation change needs a different modeled transition—for example, allowing a complete commit from incomplete discovery—the specification and affected model must change and pass TLC before the implementation is accepted. This document does not authorize such a change.

## Primary Apple references

- [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery)
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [`NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly`](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/immediatelyavailablemetadataonly)
- [Asynchronous coordination](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate%28with%3Aqueue%3Abyaccessor%3A%29)
- [Batch coordination](https://developer.apple.com/documentation/foundation/nsfilecoordinator/prepare%28forreadingitemsat%3Aoptions%3Awritingitemsat%3Aoptions%3Aerror%3Abyaccessor%3A%29)
- [NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)
- [NSFileVersion](https://developer.apple.com/documentation/foundation/nsfileversion)
- [Nonlocal versions](https://developer.apple.com/documentation/foundation/nsfileversion/getnonlocalversionsofitem%28at%3Acompletionhandler%3A%29)
- [Start downloading an ubiquitous item](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem%28at%3A%29)
- [iCloud download status](https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus)
- [File Provider URL identity](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getidentifierforuservisiblefile%28at%3Acompletionhandler%3A%29)
- [Supported sync controls](https://developer.apple.com/documentation/foundation/nsfilemanagersupportedsynccontrols)
- [Version-returning iCloud upload](https://developer.apple.com/documentation/foundation/filemanager/uploadlocalversionofubiquitousitem%28at%3Awithconflictresolutionpolicy%3Acompletionhandler%3A%29)
- [iCloud services entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services)
