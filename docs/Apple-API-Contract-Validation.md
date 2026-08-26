# Apple API contract validation for iCloud Drive support

Status: required implementation-validation ledger; the behavior specification remains [Robust iCloud Drive Support](iCloud-Drive-Support-Spec.md)

This document records Apple-framework behavior that the NV design needs but that the TLA+ models, mocks, and API type signatures cannot prove. Each condition must be established from current Apple documentation, a focused real-provider test—including iCloud for every first-class contract—or both before code relies on it. An unestablished condition is not silently assumed: the listed fail-closed behavior applies.

No elapsed-time threshold proves freshness, absence, completeness, upload, or conflict resolution (`WAIT-01`). A UX delay may expose Retry, Work Offline, Choose Folder, Quit, or the caller-specific cancel action, but it never turns unknown state into success. Cancellation waits for NV's accessor/completion ownership to return before applying `ROOT-01` or `CKPT-01`. Every potentially blocking probe runs on the provider queue.

## Capability and provider-identification policy

NV follows Apple's operation-scoped capability pattern rather than attempting to identify a provider's brand:

1. Availability checks establish only that an API exists on this OS.
2. An explicit resource value or option set, such as `NSURLUbiquitousItemSupportedSyncControlsKey`, authorizes attempting only the advertised operation on that item.
3. The actual asynchronous operation result is authoritative. Advertised support, selector availability, a prior success, or a successful operation on another item never converts a failure into success.
4. APIs without an explicit capability flag are called normally and their documented unsupported, unavailable, transient, and conflict results are handled. Preflight cannot replace this because provider and item state can change between the check and the operation.
5. Capability observations may be retained as root-session optimization hints, but are not persisted as provider profiles and are not safety evidence for a later operation. For historical-version discovery, only `NSCocoaErrorDomain/NSFeatureUnsupportedError` returned by the required nonlocal-version call for an authoritative note candidate selects current-visible scope. One such result is sufficient for that root session because exact all-candidate discovery is then impossible; it says nothing about other operations or URLs. Every fresh root session retries. Transient, ambiguous, differently scoped, or ordinary failures remain incomplete.
6. `NSFileCoordinator` and `NSFilePresenter` have no provider-capability preflight. NV uses them for applicable local/provider operations and handles each coordination result.

NV does not require a general `iCloud`/`Dropbox`/other-vendor classifier. `NSURLIsUbiquitousItemKey` and successful File Provider URL identity are positive evidence that an item is provider-managed; the latter's opaque item/domain identifiers are used only for equality and authority-change detection. A failed File Provider lookup does not prove ordinary local storage. `-[NSFileManager ubiquityIdentityToken]` describes the active iCloud account, not ownership of an arbitrary selected URL, while `URLForUbiquityContainerIdentifier:` identifies only an app-entitled container that NV does not use. Container/domain display names are presentation strings. NV must not parse paths, raw domain identifiers, private extended attributes, or display names to infer provider type.

iCloud Drive remains the tested and documented first-class configuration. Dropbox and other providers remain best-effort even though they automatically benefit from standard operations they support. This support policy is not a runtime correctness input.

## Acceptance summary

| ID | Required Apple behavior | Needed for | If not established |
| --- | --- | --- | --- |
| AV-01 | Ubiquity and exact-item download status identify a provider-managed item and a provider-current checkpoint | Fast normal startup | Treat authority/status as `unknown`; do not claim current startup |
| AV-02 | Explicit materialization plus coordinated read yields the requested exact item or an error | Stale/unmaterialized startup and selected note reads | Keep progress/offline choices; never publish partial bytes |
| AV-03 | Coordinated shallow enumeration discloses the current direct-child namespace without reading child contents and supports exact note/artifact projections | Routine reconciliation, checkpoint-absence classification, and rebuild | Snapshot is incomplete; no complete commit, creation choice, resolution, cleanup, or rebuild publication |
| AV-04 | Batch preparation and nested coordinated reads have the required accessor/completion behavior | Efficient selected-version reads | Fall back to serial per-URL coordinated reads |
| AV-05 | `NSFileVersion` calls produce a stable, complete set for each known candidate URL | Current-known reconciliation, exact rebuild, and recovery | Preserve known states, retain dirty, and confer no resolution eligibility; only the `CAP-01` result may select current-visible reconciliation or rebuild |
| AV-06 | Historical versions remain discoverable for retained URLs after rename/deletion, or presenter callbacks supply a usable URL | Deleted/renamed version recovery | Treat undiscoverable history as unseen remote work; never claim it was resolved |
| AV-07 | Presenter callbacks and later exact observations can discharge callback-before-visibility obligations | Reconciliation liveness | Retain dirty with bounded-backoff retry; safety remains intact |
| AV-08 | Root callbacks/vnode events and rooted identity distinguish a verified same-domain move, positive namespace deletion, and inconclusive availability while higher-level APIs remain bound across the move | Path-independent provider access and correct root-loss presentation | Freeze publication while continuity is inconclusive; never retarget or suppress Retry without positive evidence; replace the session only for changed authority, or cancel it after confirmed loss |
| AV-09 | File Provider URL identity works for ordinary consumer apps as opaque domain-membership and authority-continuity evidence, and a separate positive ordinary-local exclusion recipe can be validated | Provider-managed versus ordinary-local/unknown authority | Success may confirm provider management; ordinary-local shortcuts remain disabled unless the complete negative-walk/local-filesystem recipe passes; every ambiguous failure remains `unknown` |
| AV-10 | macOS 26 pause/upload/resume and returned-version correlation behave as specified | Optimized exact checkpoint upload barrier | Use ordinary provider sync and retain journal/claim until conservatively qualified |
| AV-11 | Legacy upload resource-key transitions are observable with the stated meaning | macOS 11.5–15 compatibility cleanup | Upload remains pending/unknown and journal/claim remain |
| AV-12 | Spotlight failure cannot affect any required path | Startup and reconciliation availability | Ship blocker if a required path still references `NSMetadataQuery` |
| AV-13 | A LaunchServices-launched NV app with a stable bundle identity can use the required iCloud APIs on a user-selected external iCloud Drive root without an API-specific entitlement | Deployment and signing | Treat a bundleless-process result as nonrepresentative; fail closed on a real app authorization error |
| AV-14 | A fresh generic-password Keychain item can be added without changing another collection's accepted item, read back exactly, and deleted independently | Copy-on-write remembered-credential cutover and encrypted Save As | Keep every accepted checkpoint/item pair; do not install a target checkpoint that names an unverified or shared item |

AV-01, AV-02, AV-03, AV-05, AV-07, AV-08, and AV-13 are first-class-iCloud ship conditions. AV-04 and AV-10 are optimizations with specified fallbacks. AV-06 defines the discoverability ceiling of current-known and never authorizes loss or resolution of unseen evidence. AV-09 must pass before URL-domain results participate in authority discovery; it never identifies a provider vendor, and no negative result alone confirms ordinary local storage.
AV-14 is a ship condition for remembered-passphrase changes and encrypted **Save Current Collection As…**, not for unencrypted first-class storage. NV assumes no transaction spanning Keychain Services and checkpoint replacement.

## AV-01 — provider management and checkpoint currentness

APIs:

- `NSURLIsUbiquitousItemKey`
- `NSURLUbiquitousItemDownloadingStatusKey`
- `NSURLUbiquitousItemDownloadingErrorKey`
- `NSURLUbiquitousItemIsSyncPausedKey` on macOS 26+
- `NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly`
- `-[NSURL promisedItemResourceValuesForKeys:error:]`

NV requires all of the following:

1. A user-selected directory inside iCloud Drive can be positively identified as provider-managed without reading note contents by querying the resolved existing item first, then—only for a prospective or not-yet-identified child—walking existing directory ancestors nearest-first on the same volume until the first positive ubiquitous-item result or the volume root. The walk never crosses a volume boundary. This result does not identify the provider as iCloud; current Dropbox also returns it in the focused tests.
2. A coordinated metadata-only accessor using promised-item resource values can read the exact root/checkpoint authority and status keys without materializing file content or waiting for content availability. NV never attempts a content read or directory enumeration under this option.
3. Reading the canonical checkpoint's download-status keys does not itself materialize its content.
4. `NSURLUbiquitousItemDownloadingStatusCurrent` means that complete local content exists and is the newest version the provider has disclosed to this Mac. It need not mean globally current.
5. A missing, nil, erroring, or unknown status is distinguishable from `Current` and never treated as current or absent.
6. On macOS 26+, paused status is observable before freshness evaluation and resume failure remains distinguishable from success.

Validate nested iCloud Drive roots, Optimize Mac Storage with an evicted checkpoint, offline launch, account sign-out/change, a root moved into or out of provider management, and a checkpoint replaced remotely immediately before launch. Compare metadata-only and ordinary coordinated probes and record whether either triggers materialization or waits for content. If the metadata-only option is unavailable or insufficient, use ordinary coordination on the provider queue. If provider-management or status evidence remains inconclusive, the authority/status is `unknown`; startup follows the specified progress/offline/folder/quit choices.

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

1. Inside a coordinated root accessor, enumerating direct children discloses every current child name/placeholder the provider has made known to this Mac for that observation.
2. Listing a dataless directory may wait for namespace availability, but it does not download unchanged child file contents.
3. Enumeration failure, an unavailable directory, a provider error, or a partially returned listing is detectable as incomplete rather than indistinguishable from an empty directory.
4. Two independently created catalogs compare equal exactly when all namespace/cheap-revision inputs relevant to candidate selection compare equal. The token is equality-only.
5. Root coordination is not assumed to coordinate child contents; selected children are prepared and read separately.
6. Projecting the same catalog by exact reserved-artifact names yields independent authoritative-note and artifact-status catalogs. Artifact-only changes cannot change note-catalog equality, while every current non-artifact child remains in the note projection.
7. For startup absence classification, one complete catalog that omits `Notes & Settings`, followed by the AV-05 fixed-name current/other/unresolved/nonlocal queries, is sufficient to present the explicit creation choice. The eventual checkpoint transaction must still recheck expected absence; catalog observation alone never authorizes installation.

Validate with 0, 1, 1,000, and 10,000 files; every file evicted; remote create/delete/rename during each fence; artifact-only creation/deletion during a note transaction; filename collision and Unicode/case variants; deep roots; an evicted directory placeholder; network loss during enumeration; and Spotlight enabled, disabled, excluded, rebuilding, and damaged. Record whether listing materializes child contents and whether errors distinguish incomplete from empty. Until this contract passes, routine processing may preserve known alternatives but cannot report a complete current-known transaction; rebuild cannot publish and checkpoint absence remains unknown.

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
6. Invoking the four version queries for every authoritative note candidate is practical without materializing unchanged content; only candidates selected after metadata comparison need AV-04 preparation and content reads.

Validate two-Mac simultaneous edits, multiple unresolved versions, remote versions not cached locally, eviction and rematerialization, version resolution/removal during enumeration, process restart, unchanged current files whose version sets change, all-candidate metadata enumeration without content download, and independent catalog-only/version-only changes. Any failed callback/read or unstable identity marks enumeration incomplete, permits additive preservation only, retains the note dirty obligation, and confers no provider-version resolution eligibility. Exactly `NSCocoaErrorDomain/NSFeatureUnsupportedError` from the required nonlocal-version call may instead select current-visible reconciliation or bootstrap-rebuild scope for the current root session and avoid repeating that unavailable facility. One result is enough even if another URL could succeed: exact all-candidate completeness is already impossible for this session, while current-visible scope does not claim that every URL or unrelated operation is unsupported. Both fallback forms require the complete stable current snapshot established by AV-03; neither claims current-known completeness, resolves provider versions, or qualifies provider-managed journal cleanup, and a current-visible rebuild enters the UI with session-continuous limited-history status.

The macOS 26.6.1 LaunchServices retest did not change the provider split: iCloud completed nonlocal enumeration, while Dropbox again returned `NSCocoaErrorDomain/3328`. Dropbox's result is therefore a provider capability limit in the tested configuration, not a bundleless-test artifact.

## AV-06 — renamed, deleted, and absent-current historical versions

There is no public directory-wide `NSFileVersion` enumeration API. NV therefore retains candidate URLs from the live model and last accepted catalog and adds URLs delivered by presenter move/version callbacks.

NV needs at least one of these behaviors for a historical version whose current file is gone:

1. Calling the version APIs with the retained pre-delete/pre-rename URL still returns the historical versions; or
2. `NSFilePresenter` supplies a URL that can be used to enumerate/read those versions.

Validate remote delete, local delete, remote rename, local rename, delete followed by recreation at the same name, and restart before and after each callback. If neither behavior holds, document the resulting discovery ceiling: the version is undisclosed remote work and is outside current-known until Apple exposes it through a candidate source. NV must never resolve, discard, or claim representation of that unseen version.

Repeating the synthetic current-deletion test from a LaunchServices app still redisclosed no historical version on either iCloud Drive or Dropbox. App identity does not raise this discovery ceiling.

## AV-07 — presenter notification visibility and liveness

APIs:

- root-directory `NSFilePresenter` subitem appearance/change/move/deletion callbacks
- gain/lose/resolve-version callbacks
- `presentedItemDidChangeUbiquityAttributes:`
- relinquish/accommodation callbacks

NV does not assume that callback delivery and provider catalog visibility are atomic. It requires this eventual condition only for liveness: after a generic callback, a later coordinated catalog/version observation either differs from the saved pre-callback projection, or a later callback carries exact version evidence that appears in the version set. A callback that arrives during a transaction must remain a newer dirty generation and cannot be consumed by that transaction.

Validate both orders—state visible before callback and callback before state visible—for remote create, content edit, rename, delete, conflict gain/loss/resolution, materialization, and root ubiquity changes. Also test uncoordinated external editors, NV's own coordinated writes, provider restarts, callback coalescing, and presenter removal/drain at quit. If visibility never advances, NV keeps one coalesced dirty obligation and retries with bounded backoff; it does not spin, fabricate completion, or block the UI/WAL. This is the implementation refinement of the TLA+ dirty invariant, not a modeled fairness promise about Apple.

## AV-08 — root moves, namespace loss, and path independence

APIs:

- `presentedItemDidMoveToURL:`
- `accommodatePresentedItemDeletionWithCompletionHandler:`
- `DISPATCH_SOURCE_TYPE_VNODE` with `DISPATCH_VNODE_DELETE`, `DISPATCH_VNODE_RENAME`, and `DISPATCH_VNODE_REVOKE`
- FSEvents `kFSEventStreamCreateFlagWatchRoot`/`kFSEventStreamEventFlagRootChanged`
- synchronous and asynchronous `NSFileCoordinator`, `NSFileAccessIntent`, and batch preparation
- `-[NSFileManager startDownloadingUbiquitousItemAtURL:error:]` and macOS 26 sync controls
- `NSFileVersion` current/nonlocal-version operations
- Foundation safe replacement through `-[NSFileManager replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:]`
- `+[NSFileProviderManager getIdentifierForUserVisibleFileAtURL:completionHandler:]`
- `+[NSFileProviderManager getDomainsWithCompletionHandler:]`, `+managerForDomain:`, and `-getUserVisibleURLForItemIdentifier:completionHandler:`
- file-reference URLs and bookmarks
- the existing open rooted-directory descriptor and filesystem identity checks

NV requires all of the following:

1. A provider/Finder move callback's URL is verifiable as the directory already held open, including across a rename or move within the same provider domain. The open descriptor, root file-reference URL, resolved bookmark, and opaque File Provider item/domain identity must agree on that object; path equality is insufficient.
2. Ordinary shallow catalogs, asynchronous intent reads, batch preparation with nested reads, and Foundation safe replacement either finish against that object or return an error when a root move is initiated inside the accessor. Correctness cannot depend on ancestor coordination delaying the move: a successful completion never silently addresses an unrelated item at the vacated path.
3. A download requested for an evicted child before the move may complete at the moved root. Current and nonlocal `NSFileVersion` operations remain attached to the intended item, subject to the AV-05 stable-unsupported fallback.
4. On the macOS 26 optimized checkpoint path, pause may be acquired before the root move, but replacement, exact upload when advertised, and resume must continue using a freshly derived post-move child reference with the same opaque item/domain identity. Operation-local leaf references invalidated by replacement are never reused.
5. A verified same-directory, same-domain move does not advance structural generation or replace the root session. An accessor result remains eligible to publish under its ordinary provider, session, structural, and UUID/LSN fences; path text is not an additional transaction input.
6. A provider-domain/account change is not a path-only move and replaces the old session incarnation before authority-scoped evidence may publish or authorize cleanup.
7. On a filesystem that supplies vnode lifecycle events, renaming the opened root produces rename evidence without false delete evidence; unlinking/removing it produces delete evidence on the descriptor for the removed object; and revoke remains distinguishable from delete. Event coalescing preserves every reported bit. Delete alone is sufficient only after ordinary-local authority is confirmed; under provider management, File Provider identity must distinguish logical deletion from eviction or same-item vnode replacement.
8. `accommodatePresentedItemDeletionWithCompletionHandler:` is delivered before coordinated deletion and can be completed promptly after NV quiesces mutations without waiting for UI or network work. It does not itself prove that deletion subsequently completed.
9. A different-identity directory placed at the former pathname never makes the old descriptor, file reference, bookmark, or operation-local child reference identify that replacement, even when every copied byte and filename is identical. Confirmed deletion cancels old-session publication; reopening the replacement creates a fresh session.
10. A missing path, stale or failed bookmark, `ENOENT`, FSEvents root-change notification, provider unavailability, vnode revoke, `st_nlink`, and `F_GETPATH` are not interpreted individually as positive deletion evidence. No correctness or UI decision depends on enumerating other processes' descriptors.
11. Provider-authority uncertainty alone does not imply journal failure while the rooted descriptor remains usable. Vnode delete or revoke, deletion accommodation, or an actual append/outbox/barrier failure is distinguishable and suspends editing; editing may resume only after rooted identity, journal namespace recoverability, the active descriptor/header/claim, complete outbox drainage, and a successful barrier are revalidated. A permanently unlinked or revoked descriptor does not become recoverable merely because its former path or bookmark resolves again.
12. After vnode-delete evidence for a provider-managed root, an ordinary consumer app can enumerate the captured domain, obtain its manager, and reverse-resolve the captured item identifier. A returned URL can be security-scope/coordinated as a directory and round-tripped to the same item/domain pair to prove logical survival across eviction, move, or vnode replacement; filesystem identity distinguishes an ordinary move from a new vnode but is not required to remain equal for survival. Only `NSFileProviderErrorDomain`/`NSFileProviderErrorNoSuchItem` carrying that exact item from that exact domain manager is positive deletion corroboration. Missing domains, unsupported/unavailable managers, nil or mismatched URLs, account/network/provider errors, and all other failures remain inconclusive.

Validate moves before, during, and after every operation above; nested and deep roots; provider-domain and iCloud-account changes; temporary-folder instances; stale bookmark refresh; and a copied directory with identical contents. Separately perform coordinated and uncoordinated `rm -rf`, plain `rmdir`, rename, volume revoke/unmount, provider eviction, remote deletion, and same-path replacement while NV has an open root descriptor and in-flight work. For each provider-backed case, exercise the complete reverse-identity recipe from the ordinary NV app context and verify exact `NoSuchItem` error domain/code/identifier payload, same-pair URL round trip, security scope, and coordination; inject domain removal, account loss, provider restart, network failure, timeout, mismatched URL/identity, and unsupported-manager results. Inject append, short-write/outbox, and barrier failures around each event. A verified same-directory, same-domain move keeps the session and does not invalidate detached work. Authority-only uncertainty leaves WAL-durable editing available while publication is frozen. Vnode delete/revoke, deletion accommodation, or actual durability failure gates later edits, preserves and urgently drains admitted work, and cannot resume without rooted identity, namespace recoverability, journal revalidation, and a successful barrier. A changed authority replaces the session so old authority-scoped work is discarded. Confirmed root loss cancels old-session publication and suppresses Retry; physical teardown follows the selected disposition. Every missing or unsupported positive signal remains inconclusive and retains Retry rather than guessing.

The macOS 26.6.1 LaunchServices matrix establishes the online, same-volume, same-provider-identity case on both iCloud Drive and Dropbox. In each run, a child-process move reached the registered root presenter while the original directory descriptor, root file-reference URL, pre-move bookmark, and opaque root/child item/domain identities continued to identify the moved directory. Ordinary post-move catalog, promised metadata, coordinated read, and current-version lookup succeeded. The harness initiated a move inside each asynchronous-read, shallow-catalog, batch-preparation/nested-read, and Foundation-replacement accessor. Read, catalog, and replacement coordination delayed the ancestor move (`move-waited=1`), but batch preparation did not (`move-waited=0`); the retained child reference still yielded exact bytes after that move completed inside the accessor. Every operation retained rooted/provider identity. An evicted 8 MiB child was not current before the move and completed materialization afterward. iCloud's nonlocal-version request was pending when the move began and completed afterward; Dropbox returned its previously established stable `NSFeatureUnsupportedError`. Finally, pause, safe replacement, root move, exact upload when advertised, and resume preserved one checkpoint item identity; Dropbox advertised pause but not exact upload and took that operation-scoped fallback. These results support retaining the root session and structural generation across a verified same-authority move; they do not establish cross-domain/account behavior.

The expanded iCloud matrix also passed from an ad-hoc-signed LaunchServices app on macOS 14.8.9/x86_64. It produced the same accessor scheduling result (`move-waited=1` for read/catalog/replacement and `0` for batch), completed evicted-child materialization and a pending nonlocal-version request across moves, and skipped only the unavailable macOS 26 sync controls. A narrow ad hoc ordinary-APFS probe on macOS 26.6.1 observed `DISPATCH_VNODE_DELETE` for `rmdir` of an open directory and only `DISPATCH_VNODE_RENAME` for rename; after `rmdir`, `st_nlink` remained `2` and `F_GETPATH` still returned the former path, confirming that neither is a deletion predicate. This does not establish provider-backed delete/revoke delivery or the consumer-app reverse-identity recipe, cross-domain/account moves, copied/deleted/replaced provider roots, stale-bookmark refresh after process restart, deep provider roots, remote initiation, daemon/network failure, or macOS 15. Those cases remain open ship-matrix work rather than inferred successes, provider-managed `confirmedGone` remains disabled, and the implementation must keep the inconclusive fallback until the complete recipe passes.

## AV-09 — File Provider domain identity from a consumer app

API:

- `+[NSFileProviderManager getIdentifierForUserVisibleFileAtURL:completionHandler:]`

The SDK says that a URL outside the applicable provider/domain **or** an item not yet assigned an identifier can both produce `NSFileNoSuchFileError`. NV therefore cannot currently treat that error as positive proof of ordinary local storage.

Before relying on this API, validate from a normal NV process—not a File Provider extension—that:

1. A Dropbox/other-provider root and a newly created coordinated child return stable item and domain identifiers.
2. iCloud, ordinary APFS, removable local, network, unavailable, and unassigned provider items produce results whose positive and inconclusive cases can be distinguished.
3. Domain identifiers remain equality-stable for the open root and change when provider authority changes.
4. The normative root-first, nearest-ancestor, same-volume walk stops on the first positive provider result, never crosses the volume root, and returns `unknown` after any missing, inaccessible, changing, or erroring step rather than skipping it to manufacture a local result.
5. A separate candidate ordinary-local recipe combines a completed non-provider ancestor walk with positive local-filesystem evidence and a documented or empirically stable File Provider exclusion result. Exercise ordinary APFS, removable local media, network volumes, provider roots whose child identifier assignment is delayed, provider restart/account loss, and a provider-managed item stored physically on APFS. The recipe passes only if no provider-managed case is misclassified local.

Success establishes provider management and an opaque domain equality token; it does not reveal whether the provider is iCloud, Dropbox, or another vendor. Every error or nil pair remains `unknown` unless the complete separate ordinary-local recipe above passes. Exhausting only the ubiquitous-item ancestor walk is insufficient. Failure to validate provider identity does not block first-class iCloud when ubiquitous-item evidence is positive, but it disables domain-continuity claims. Failure to validate the ordinary-local recipe keeps those roots `unknown` and disables ordinary-local journal cleanup, unclaimed-journal recovery, and other local-only shortcuts.

The LaunchServices full-suite retest again returned stable item/domain identity for both iCloud Drive and Dropbox, including domain equality between each selected root and its coordinated child. The earlier success was not dependent on command-line process identity.

Do not use `NSFileProviderDomain.displayName`, `NSURLUbiquitousItemContainerDisplayNameKey`, `NSFileProviderManager.providerIdentifier`, raw domain-ID parsing, path prefixes, or private metadata as a vendor classifier. A provider-specific SDK or `NSFileProviderService` contract may identify its own service for an explicit integration, but NV has no such integration in this design.

Do not use `enumeratorForMaterializedItems`; it is a provider-domain management API, enumerates only materialized items, and cannot establish NV's complete note namespace.

## AV-10 — macOS 26 exact checkpoint upload optimization

APIs:

- `NSURLUbiquitousItemSupportedSyncControlsKey`
- pause and resume sync controls
- `-[NSFileManager uploadLocalVersionOfUbiquitousItemAtURL:withConflictResolutionPolicy:completionHandler:]`
- returned `NSFileVersion`

NV requires all of the following when the controls are advertised:

1. The local write preserves the paused provider-item identity; a pathname that merely continues to report the paused resource key is insufficient.
2. Fail-on-conflict upload either accepts the exact stable local version or returns a distinguishable conflict/error.
3. The callback's returned version can be correlated by persistent identifier to the locally installed version and by decoded `checkpointID` to the immutable receipt.
4. Resume-with-preserve-local-changes is safe and callable on every success/error/cancellation path; next launch can observe and repair a failed resume.
5. No coordinator accessor must remain open while waiting for network upload.

Validate pause failure before acquisition, app exit after pause, replacement while paused, stale callback from an older request, identifier/checkpoint mismatches, remote conflict, cancellation, upload success, resume failure, and next-launch repair. Race a coordinated external checkpoint replacement before and during NV's accessor and prove that an expected-current mismatch calls no replacement primitive and returns the typed pre-install failure. A provider may return `EBUSY` while applying changes even after upload-status keys look settled; retry pause with bounded backoff until the operation succeeds or the user-visible timeout expires. Any unsupported control or pre-pause failure uses ordinary sync. Any ambiguity after pause retains journal/claim and reports pending/error through `SyncSessionController`.

Run this validation from an app bundle with a stable `CFBundleIdentifier`, launched through LaunchServices. On macOS 26.6.1, an otherwise identical bundleless command-line invocation returned `NSFeatureUnsupportedError` even though the item advertised both required controls; the ad-hoc-signed, entitlement-free app invocation paused and resumed the same kind of flat file successfully. Initializing `NSApplication` was not required. A command-line result is therefore not authoritative for NV's app-process behavior.

The broader app-context retest established the control APIs themselves on iCloud Drive: pause followed by an identity-preserving in-place write and explicit upload returned the exact installed `NSFileVersion`; a two-Mac run fetched the newer remote version, rejected the stale local upload with `NSFileProviderErrorLocalVersionConflictingWithServer`, preserved both payloads, and resumed; and a separate LaunchServices launch observed and resumed a pause left by the previous launch. Dropbox's advertised pause control likewise survived an in-place edit and a second app launch.

Atomic replacement depends on the installation primitive. On both tested providers, `NSDataWritingAtomic` inside an `NSFileCoordinatorWritingForReplacing` accessor left `NSURLUbiquitousItemIsSyncPausedKey` reporting true but made resume for the pathname return `NSFeatureUnsupportedError`; iCloud's explicit upload did as well. In contrast, Foundation's safe-save primitive passed on macOS 26.6.1: NV created the staged file in the same-volume `NSItemReplacementDirectory`, coordinated the destination with `NSFileCoordinatorWritingForReplacing` and the staged source with `NSFileCoordinatorWritingForMoving`, called `-[NSFileManager replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:]` with replacement options `0`, and used the returned resulting URL thereafter. The destination input may be a file-reference URL. The tested replacement invalidated that old reference and returned a pathname URL; regenerating a reference from either the original pathname URL or a canonical pathname URL identified the replacement, while asking the returned URL object itself for `fileReferenceURL` returned no usable reference. Code must therefore treat every leaf reference as operation-local, revalidate the result against the rooted directory, and regenerate any later reference rather than expecting replacement to retarget the old one. iCloud retained the same opaque File Provider item/domain identity, fail-on-conflict upload returned the exact installed `NSFileVersion`, exact bytes read back, and resume succeeded. Dropbox retained its opaque identity and resumed; it did not advertise fail-on-conflict upload. Therefore the macOS 26 optimization must use this Foundation safe-save sequence, not `NSDataWritingAtomic` or NV's lower-level namespace replacement. Any safe-save, identity, exact-version, read-back, or resume failure retains the journal and uses the existing pending/error behavior.

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

## AV-13 — application identity, signing, and entitlement contract for a user-selected iCloud root

Capabilities and APIs:

- `com.apple.developer.icloud-services` / iCloud Documents capability when required
- the app's effective code-signing entitlements
- ubiquitous-item resource keys, `NSFileCoordinator`, `NSFilePresenter`, `NSFileVersion`, and macOS 26 sync controls on a user-selected iCloud Drive URL

NV selects an existing user-visible directory; it does not call `URLForUbiquityContainerIdentifier:`, own a ubiquity container, or migrate the notes folder into one. Validate from a normal unsandboxed app bundle launched through LaunchServices. The app must have a stable `CFBundleIdentifier`; a standalone executable is not a valid sync-control probe even if it contains the same code. On each supported OS family, establish whether the app can obtain positive provider-managed evidence for the selected root and use every required first-class API, including version discovery and sync controls where available.

The macOS 26.6.1 focused test passed pause/resume from an app bearing only an ad-hoc signature: it had no Team ID, entitlements, hardened runtime, or notarization ticket. The same item and binary returned `NSFeatureUnsupportedError` when invoked directly with no process bundle identity. This establishes that Developer ID signing, notarization, and iCloud Documents entitlements are not prerequisites for this operation; normal app identity is. NV still follows ordinary distribution signing, hardened-runtime, and notarization requirements, but those are deployment protections rather than iCloud sync-control capabilities. Add no iCloud entitlement and do not introduce an app-owned storage location or key-value-store entitlement. Any authorization failure from the real app remains `unknown`/actionable setup failure rather than silently dropping to ordinary POSIX behavior.

## AV-14 — copy-on-write Keychain credential cutover

APIs:

- `SecItemAdd`
- `SecItemCopyMatching`
- `SecItemDelete`
- `kSecClassGenericPassword` with NV's existing service and a fresh account identifier

NV requires all of the following:

1. Adding a generic-password item under a fresh random account leaves the accepted account and bytes unchanged; `errSecDuplicateItem` is distinguishable and causes that candidate identifier to be burned rather than updated.
2. A successful add is followed by an exact `SecItemCopyMatching` read-back whose bytes can be validated against the isolated target `NotationPrefs` KDF/verifier before the target checkpoint is installed.
3. The accepted item remains readable after target add/read-back failure and after process termination at every pre-install boundary.
4. Once an exactly verified target checkpoint names the new account, a new process can retrieve that account and decrypt the checkpoint without process-local migration state.
5. Deleting the old account cannot delete or mutate the fresh target account, and deletion failure remains distinguishable so NV can issue a nonfatal credential-cleanup warning.
6. Two independently installed encrypted Save-As collections that use the same passphrase have distinct account identifiers and remain decryptable after either collection performs a later passphrase cutover and deletes only its own former item.

Test remembered-passphrase rekeying, disabling encryption, and remembered-encrypted Save As with a crash or forced termination after target-item add, target-item read-back, target-checkpoint creation/replacement, target-checkpoint verification, and any same-collection old-item deletion. Also inject duplicate-account, user-denied Keychain access, missing item, malformed bytes, read-back mismatch, and deletion failure. A cutover pre-install failure or crash must leave the old checkpoint/item pair usable; a post-install crash must leave the target pair usable. Save As must leave the source pair unchanged at every boundary, must retain a target item after ambiguous installation, and may best-effort remove only its exact item after proven noninstallation. Open two surviving Save-As destinations, change one passphrase, and prove the other still decrypts. An interrupted pre-install attempt may leave an unreferenced item, which NV neither discovers nor deletes automatically. These tests validate the item/checkpoint orderings separately; they do not assume a cross-resource transaction or Keychain reference counting.

## Focused test harness and preliminary observations

`tests/ICloudAPIContractTest.m` is an MRC Foundation probe. Local provider suites and sync-control modes are packaged with `ICloudAPIContractTest-Info.plist`, ad-hoc signed, and launched through LaunchServices; peer/cleanup modes that do not call identity-sensitive controls may remain standalone. It creates only fixed-name test-owned subtrees, uses child processes and a fixed marker to initiate each root move at the chosen accessor boundary, records whether coordination delayed that move, and removes its artifacts on success. Its current AV-08 phase retains the pre-move descriptor/reference/bookmark/opaque identity and exercises post-move access plus in-flight catalog, read, batch, replacement, materialization, version, and sync-control cases; the coordinated/uncoordinated delete, revoke, eviction, and replacement matrix above remains to be added. It has no `NSMetadataQuery` dependency. The Makefile supplies one-command app-context runs for iCloud Drive, Dropbox, pause lifecycle, and the narrow sync-control probe, plus a standalone legacy-upload probe and host/peer modes for remote namespace changes, simultaneous conflicting writes, and macOS 26 sync-control conflicts. Tests select a first-class-required or observational policy; they do not identify or branch on provider brand. Every capability-sensitive result reports API availability/advertisement separately from the attempted operation's actual result and verifies the applicable fallback.

The first local run was performed on macOS 26.6.1 (25G76), arm64, with the ad-hoc-signed standalone executable and no iCloud entitlement. These are preliminary observations, not completion of the real-system matrix:

| ID | iCloud Drive observation | Dropbox observation | Present conclusion |
| --- | --- | --- | --- |
| AV-01 | The selected root reported ubiquitous; promised metadata for an evicted 1 MiB child returned without materializing it. | The root also reported ubiquitous and exposed the same status/materialization behavior. | Exact metadata probing is promising. The ubiquitous-item result establishes provider-managed evidence, not provider brand, and is sufficient for that narrower role. |
| AV-02 | Explicit download, `Current`, and coordinated byte read succeeded for an evicted item. | The same probe succeeded. | Established only for the online single-item case on this OS/provider version. |
| AV-03 | A coordinated five-item shallow catalog remained complete while three child contents stayed evicted. | The same probe succeeded. | The no-child-download behavior is established for this small online case; scale, fault, remote-race, and dataless-directory cases remain. |
| AV-04 | Batch preparation materialized the selected evicted file and left an evicted sibling untouched. | The same probe succeeded. | Basic batch/nested-read behavior passed; cancellation, errors, historical URLs, and provider delay remain. |
| AV-05 | Current-version identity was repeat-stable and survived an archive round trip. In eight simultaneous two-Mac forks, both payloads were readable for every item; the two replicas respectively exposed 7/8 other and unresolved versions, each observed 16 nonlocal versions, and all 16 identifiers survived materialization into local version storage. | Nonlocal-version enumeration returned `NSCocoaErrorDomain/3328` (`NSFeatureUnsupportedError`) again from the LaunchServices app. | The tested iCloud conflict/nonlocal and identifier-migration cases pass using an ordinary coordinated read, a registered presenter, and exact before/after local-version fences. Faults, resolution during enumeration, and additional OS versions remain; this facility is genuinely unavailable in the tested Dropbox configuration. |
| AV-06 | A deliberately added historical version was not redisclosed after current deletion in either standalone or LaunchServices app runs. In the two-Mac test, presenter callbacks supplied the remote rename/deletion candidate URLs, but a fresh process querying the retained pre-rename and pre-delete URLs received `NSCocoaErrorDomain/4` and no readable history; the renamed current URL remained readable. | The app-context synthetic-delete ceiling was the same. | Callback URLs are usable candidate evidence while delivered, but retained old URLs cannot recover rename/delete history after restart in the tested configurations. The specification's undisclosed-history ceiling is required. |
| AV-07 | A child process's coordinated create/edit/rename/delete reached the directory presenter. | The same probe succeeded. | A later two-Mac run observed callback/marker delivery before exact cross-file visibility and eventual convergence under retry. Uncoordinated writers, coalescing, daemon restart, and quit drain remain. |
| AV-08 | The expanded same-provider move matrix passed on macOS 26.6.1 and 14.8.9: rooted/reference/bookmark/File Provider identity, post-move access, accessor-boundary catalog/read/batch/safe-replace, materialization, and version cases all held; macOS 26 pause/replace/upload/resume also passed. | The macOS 26.6.1 matrix passed; nonlocal-version history remained stably unsupported and exact upload was not advertised, so those operation-specific fallbacks applied. | Online same-volume moves are established on current and fallback iCloud OS versions. A narrow ordinary-APFS probe distinguished vnode delete from rename and disproved link-count/`F_GETPATH` deletion tests. Provider-backed delete/revoke, cross-domain/account, copied/replaced roots, restart-stale bookmarks, deep roots, faults, and macOS 15 remain. |
| AV-09 | The LaunchServices consumer app returned stable item/domain identity for iCloud and the test child shared the root domain. | It did the same for Dropbox. | Success establishes File Provider domain membership and equality continuity. Provider naming is neither established nor required. Ordinary-local negative interpretation remains unestablished. |
| AV-10 | App-context in-place edit/upload, exact returned-version correlation, two-Mac fetch/fail-on-conflict/resume, separate-launch pause repair, and coordinated Foundation safe-save/exact-upload/resume passed. `NSDataWritingAtomic` replacement alone broke operational pause ownership. | Advertised pause, in-place edit, separate-launch repair, no-edit pause/resume, and coordinated Foundation safe-save/resume passed. `NSDataWritingAtomic` replacement broke operational pause ownership; fail-on-conflict was not advertised. | Use `NSFileManager` safe replacement from `NSItemReplacementDirectory`, preserve original metadata with replacement options `0`, and continue with its resulting URL. Do not substitute `NSDataWritingAtomic` or a lower-level rename/swap in the paused-item path. |
| AV-11 | On macOS 26.6.1 and 14.8.9, the dedicated probe observed a post-install pending/uploading state followed by uploaded/not-uploading for one unchanged persistent version and exact byte receipt. A rapid second replacement could not satisfy the first receipt. | Not exercised. | The exact legacy transition/correlation algorithm passed on the tested macOS 14 and 26 configurations. A macOS 15 run is still required for the stated release matrix. |
| AV-12 | The focused paths completed without constructing or waiting for a metadata query. | The same probe succeeded. | The harness is Spotlight-independent; full-app startup/reconciliation scenarios remain. |
| AV-13 | The LaunchServices probe passed with an ad-hoc signature, stable bundle identifier, no Team ID, and no entitlements; initializing AppKit made no difference. Other required APIs had already succeeded without iCloud entitlements. | Not applicable to the iCloud entitlement question. | No API-specific entitlement, Developer ID signature, or notarization requirement was observed. Keep a release-build smoke test, not an entitlement matrix. |
| AV-14 | Not yet exercised. | Not provider-specific. | Keep the accepted checkpoint and Keychain item unchanged until the focused crash matrix passes. |

The host/peer protocol passed both its same-Mac self-check and repeated real two-Mac runs between macOS 26.6.1 on arm64 and macOS 14.8.9 on x86_64 using one iCloud account. The remote peer's coordinated edit, rename, deletion, and completion marker uploaded successfully. On the host, the marker and presenter activity arrived before the edit/rename/delete set was simultaneously visible; repeated coordinated exact observations then converged, version enumeration completed, the acknowledgement reached the peer, and cleanup succeeded. This directly confirms that a separate uploaded file is only a wakeup—not a cross-file ordering fence—and that AV-07's retained dirty obligation is necessary. The fresh-process history phase establishes the AV-06 ceiling described above.

The simultaneous-fork protocol first materialized eight identical bases on both Macs and then scheduled divergent coordinated writes for the same instant. Every resulting snapshot was complete on both replicas; both user payloads remained readable for all eight files; other and unresolved conflict versions were exposed; and each replica returned 16 nonlocal identifiers that remained equal after coordinated materialization moved them into local version storage. This establishes the exercised online AV-05 conflict/nonlocal identity contract without relying on provider naming, timestamps, or synthetic vector clocks. It does not establish behavior under network/account faults or version resolution concurrent with enumeration.

The full local probe also passed on the macOS 14.8.9 peer: promised metadata left content evicted; exact and batch materialization succeeded; current-version identity survived archival; the expanded AV-08 move matrix passed as described above; and the suite remained Spotlight-independent. Historical versions again were not redisclosed after current deletion. AV-10 was unavailable by OS version. The separate AV-11 probe passed there as described above.

This host has no valid development signing identity, but the weaker ad-hoc app result is sufficient to show that Developer ID or Apple Development signing is not an API prerequisite. A release-signed NV run remains a final deployment smoke test, not a blocker on the sync-control contract. The standalone signed-executable target is not a substitute because the deciding observed property is LaunchServices app identity, not certificate strength.

These observations do not change any TLA+ transition or safety invariant. They determine whether concrete Apple behavior can refine the models' abstract authority, catalog, version-set, callback, and upload inputs. The models do not contain provider-brand state. AV-01 and AV-09 can therefore refine positive provider management and opaque authority continuity without solving provider naming; inconclusive local/provider results still take the existing fail-closed path.

## Real-system validation matrix

Run the ship-condition cases on at least macOS 15 and the current macOS release, using two Macs on one iCloud account where remote ordering matters. Repeat provider-membership, domain-continuity, and operation-capability cases with current Dropbox and at least one other File Provider, but record those as best-effort observations rather than iCloud guarantees.

For every case, capture only content-free diagnostics: OS build, operation ID, item count, elapsed phase, status enum, error domain/code, and whether each required condition passed. Never record paths, filenames, note text, persistent version identifiers, account identity, or bookmark bytes.

The minimum fault matrix is:

- online, offline, reconnecting, and iCloud account transition;
- Optimize Mac Storage on/off with files and directory evicted;
- remote mutation before first fence, between fences, after second fence, and before callback visibility;
- File Provider daemon restart and app crash at each accessor/completion boundary;
- Spotlight healthy, disabled, excluded, rebuilding, and unavailable;
- root moved, renamed, copied, deleted, and replaced while work is in flight;
- normal quit, explicit quit override, pause/upload/resume failure, and next-launch recovery; and
- a release-signed NV smoke test, launched normally with no iCloud entitlement, on user-selected roots inside and outside iCloud Drive.

An API/OS result is accepted only when the test demonstrates the required condition, not merely because the operation eventually appeared to work in Finder. Record the result beside the relevant AV identifier before enabling that path.

## Relationship to the TLA+ models

The models begin from abstract delivered candidates, catalog tokens, version sets, callbacks, and success/failure results. They prove what NV may do with those values; they do not prove that Apple disclosed every candidate, that a callback is catalog-visible, or that an upload result identifies remote durability.

Removing `NSMetadataQuery` therefore does not violate or alter a tested model: no model contains a query-gathering state or assumes Spotlight fairness. Provider brand is likewise absent from the models; operation-specific evidence refines their existing success, failure, complete, incomplete, current, and unknown inputs. AV-03, AV-05, AV-06, and AV-07 define how real Apple behavior refines the discovery and dirty inputs to `ReconciliationSafety` and `ReconciliationFencingSafety`; AV-01 and AV-02 refine `StartupSafety`; AV-08 establishes whether a concrete root event is a stuttering move, an authority/session boundary, positive root loss, or inconclusive availability and supplies the implementation-only edit gate when local durability cannot be established; AV-10 and AV-11 refine `QuitSafety`; AV-14 refines `StorageTransitionSafety`'s abstract fresh add/read-back/delete credential actions, which encrypted Save As reuses without source-item deletion. AV-13 is a deployment precondition outside the state models. If an implementation change needs a different modeled transition—for example, allowing a complete commit from incomplete discovery—the specification and affected model must change and pass TLC before the implementation is accepted. This document does not authorize such a change.

## Primary Apple references

- [NSMetadataQuery](https://developer.apple.com/documentation/foundation/nsmetadataquery)
- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [`NSFileCoordinatorReadingImmediatelyAvailableMetadataOnly`](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/immediatelyavailablemetadataonly)
- [Asynchronous coordination](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate%28with%3Aqueue%3Abyaccessor%3A%29)
- [Batch coordination](https://developer.apple.com/documentation/foundation/nsfilecoordinator/prepare%28forreadingitemsat%3Aoptions%3Awritingitemsat%3Aoptions%3Aerror%3Abyaccessor%3A%29)
- [Coordinating a replacement](https://developer.apple.com/documentation/foundation/nsfilecoordinator/writingoptions/forreplacing)
- [NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)
- [Presenter deletion accommodation](https://developer.apple.com/documentation/foundation/nsfilepresenter/accommodatepresenteditemdeletion%28completionhandler%3A%29)
- [Dispatch vnode events](https://developer.apple.com/documentation/dispatch/dispatch_source_vnode_flags_t)
- [NSFileVersion](https://developer.apple.com/documentation/foundation/nsfileversion)
- [Nonlocal versions](https://developer.apple.com/documentation/foundation/nsfileversion/getnonlocalversionsofitem%28at%3Acompletionhandler%3A%29)
- [Start downloading an ubiquitous item](https://developer.apple.com/documentation/foundation/filemanager/startdownloadingubiquitousitem%28at%3A%29)
- [iCloud download status](https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus)
- [iCloud account identity token](https://developer.apple.com/documentation/foundation/filemanager/ubiquityidentitytoken)
- [App-entitled ubiquity-container URL](https://developer.apple.com/documentation/foundation/filemanager/url%28forubiquitycontaineridentifier%3A%29)
- [File Provider URL identity](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getidentifierforuservisiblefile%28at%3Acompletionhandler%3A%29)
- [File Provider domains](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getdomainswithcompletionhandler%28_%3A%29)
- [File Provider reverse item lookup](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getuservisibleurl%28for%3Acompletionhandler%3A%29)
- [File Provider implementation identifier](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/provideridentifier)
- [Supported sync controls](https://developer.apple.com/documentation/foundation/nsfilemanagersupportedsynccontrols)
- [Pause sync for an ubiquitous item](https://developer.apple.com/documentation/foundation/filemanager/pausesyncforubiquitousitem%28at%3Acompletionhandler%3A%29)
- [Version-returning iCloud upload](https://developer.apple.com/documentation/foundation/filemanager/uploadlocalversionofubiquitousitem%28at%3Awithconflictresolutionpolicy%3Acompletionhandler%3A%29)
- [iCloud services entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-services)
- [Entitlements catalog](https://developer.apple.com/documentation/bundleresources/entitlements)
- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Keychain Services](https://developer.apple.com/documentation/security/keychain-services)
- [Updating and deleting Keychain items](https://developer.apple.com/documentation/security/updating-and-deleting-keychain-items)
