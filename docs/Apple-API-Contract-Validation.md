# Apple API Contract Validation

This document records Apple/File Provider behaviors that the implementation and TLA+ models cannot prove. It applies to the adopted immutable-history design in the specification, ADRs and [proposal 5](impl-proposal-5/README.md). Earlier checkpoint/WAL fixtures remain measured evidence for their particular primitives or legacy migration, not proof of the segment protocol.

No elapsed-time threshold proves freshness, catalog completeness, conflict absence, upload, or root continuity (`WAIT-01`). Tests distinguish documented API contract, observed provider behavior, and application policy. Every inconclusive result fails closed for the operation that needed it.

## Exploratory incarnation metadata observations (not adopted policy)

The [2026-09-04 metadata experiments](tla/Incarnation-Metadata-Experiments.md) add local APFS/iCloud probes and a separate causal-incarnation model. The current proposal adopts a bounded body-bound projection stamp, not authoritative bare UUID xattrs. Those endpoint experiments inform its fallback rules; the new stamp codec and actual caller integration remain explicit validation gates below.

On macOS 26.6.2, `SYNCABLE | ONLY_SAVING` had the desired public intent-policy values but was nevertheless preserved by both Foundation copy and raw APFS clone. In-place writes retained stale body-bound envelopes; digest validation rejected them. Foundation replacement options `0` installed a freshly staged `#SX` or `#CS` value in the tested cases. This is post-operation evidence only, not the full replacement visibility/durability contract. Copied files had different independently queried local provider item IDs; the initial local-only run did not test cross-host portability.

Public File Provider service enumeration succeeded for the synthetic iCloud item. The returned sharing/collaboration and private service names establish no supported NV identity/deletion protocol. No private service was invoked. A custom `NSFileProviderService` protocol requires explicit provider cooperation; provider-side `userInfo`, version fields, and modification scheduling are not a generic consumer metadata/CAS channel. Details, primary sources, test instructions, and the completed two-Mac follow-up are in the report.

The later [two-Mac follow-up](tla/Incarnation-Metadata-Experiments.md#two-mac-follow-up-measured-binding-and-intent-transport) on 14.8.9/26.6.2 established different opaque item **and** domain values for the same synchronized file across hosts; do not use their cross-host equality as a portable note key. Local identity survived tested rename, safe replacement, eviction, and moving into/out of an ordinary Trash subdirectory. Backup-copy restoration created new local item identities while reproducing old body/xattr bytes. Corrected exact-name probes delivered syncable metadata both ways. The initial apparent loss of `#SX` attributes was a harness bug: macOS 14's name encoder omitted the unsupported `ONLY_SAVING` bit. The harness now carries exact origin names, and makes no Apple-contract violation claim. These results do not enable an xattr identity protocol.

The subsequent [protocol-combination experiments](tla/Protocol-Combination-Experiments.md) add a nonce/relay primitive probe. Both same-Mac and two-Mac (14.8.9/26.6.2) 11-stage runs completed: a clean challenge/reply/ack, followed by a fresh exchange carried between distinct files through three explicit coordinated xattr copies. At each stage body/attribute digests matched across observers; source/copy retained distinct, unchanged local provider identities on each Mac. This is not spontaneous provider cross-item delivery. Two earlier initial-fixture delivery timeouts were inconclusive; the completed two-Mac run used a subsequently synchronized Mini-origin fixture. A completed copyable transcript alone is not a portable identity certificate. The associated retirement model's pinned bootstrap snapshot is an explicit external input obligation, not a newly assumed Apple freshness or membership API.

## Historical FSEvents observations (2026-09-07)

The [co-add/FSEvents investigation](tla/CoAdd-Policy-Experiments.md#historical-fsevents-follow-up) adds a scoped per-device public-API probe with file/document IDs, FullHistory, MarkSelf and a fresh-process replay. Local fixtures completed on macOS 14.8.9/26.6.2, plus a local macOS 26 iCloud-folder fixture. Observed rename coalescing, multiple inode values at one replaced path, hard-link ambiguity, pre-cursor overlap and missing historical OwnEvent classification are not a reconstructible transaction log. These are not cross-Mac delivery, reboot, guaranteed retention or file-incarnation tests. The installed SDK explicitly describes event flags as hints; a missing history database or changed UUID cannot be treated as successful replay.

The adopted application policy uses FSEvents only to prioritize normal inspection. Actual changed file/root/history evidence invalidates a candidate; a hint alone neither changes classification nor restarts a valid attempt, adds a question, establishes co-add occupancy/deletion intent/newness/permanent UUID identity, or grants unlink permission. Optional historical cursor/database UUID state is private/discardable scanning state, not required history. The report distinguishes public contract, observed fixtures, harness corrections and rejected policies. [Build/run instructions](IntegrationTests.md#historical-fsevents-probe).

The [external-import rule investigation](tla/External-Import-Policy-Experiments.md#creation-time-observation-rechecked) rechecked retained local APFS and iCloud-directory copies with `lstat`: different inodes had identical birth seconds/nanoseconds. This is local macOS 26 evidence, not a new two-Mac timestamp-delivery claim. The adopted narrow import/repair predicate excludes timestamp/similarity voting and adds no Apple guarantee. Automatic new-file import tolerates undisclosed-history duplicates; it does not assert provider completeness. Private pending snapshots, rather than Apple historical-version retention, preserve the latest explicitly retained unadmitted input; actual new storage/receipt callers require fault-injection tests.

The [revalidation model follow-up](tla/CoAdd-Policy-Experiments.md#historical-hints-and-revalidation--coaddrevalidationlab) compares hint prioritization with restarting on each advisory batch. It exercises asymmetric/absent hints and repeated false alarms for unchanged files, using the existing probe observations rather than adding a new native contract claim. Complete fresh file/root/history validation remains the decision boundary; the model does not infer invisible physical generations or shared episode identifiers from replay. Candidate-ordering witnesses are not measured performance results.

## Native undo observations (integration evidence)

The separate [native undo investigation](impl-proposal-5/Native-Undo-Experiments.md) records 31 own-window AppKit scenarios on macOS 14.8.9/26.6.2 and a human typing trace without IME. It tests undo/coalescing/marked-text call sequences, not provider behavior. Group notifications are not persistence barriers, and untracked body replacement does not promise native inverse-range rebasing. The metadata API is unavailable before macOS 15; real IME/autocorrection and the production editor/segment bridge remain gates. No new Apple contract violation or provider guarantee is inferred from these observations. Apply the platform-first interpretation below before turning probe mechanisms into implementation requirements.

The [shared-window follow-up](impl-proposal-5/Native-Undo-Experiments.md#shared-window-follow-up) adds 20 cases and reruns the original 31 on both systems. One storage/separate layout managers supports the tested cross-view undo, retargeting, formatting and independent selection/highlighting. A peer displays another view's marked draft but reports no marked text; injected peer input can end that marking and preserve unwanted preedit text. The candidate note-wide gate prevents that tested interleaving, and input-depth/committed snapshots exclude the tested draft even when processing notifications precede the marked flag. Synthetic resignation/window close can leave the origin marked; real input-context handoff is not proved. After allowing bounded AppKit event-loop scheduling, actual deallocation counters confirm both original views are destroyed before reopening/Undo/Redo. The initial 50-ms drain was insufficient even for an unused view; it was not evidence that undo retained the origin. These are measured call-sequence results, not universal TextKit guarantees or an Apple API contract violation. No new File Provider assumption is added.

### Text input and undo platform boundary

Policy clarification, 2026-09-09: consult Apple's contracts, HIG and ordinary macOS/NV behavior before inventing additional input rules. [`NSTextView`/input-context documentation](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/TextEditing/Tasks/TextViewTask.html) describes marked text inside the text storage and input state associated with the client. This explains why an arbitrary storage copy can include provisional text; it does not require NV to reimplement composition or prove normal focus transfer broken. Let AppKit handle local user-driven focus, note switching and closing. Prefer deferring remote editor application until a safe input boundary, followed by existing generation checks and merge/conflict rules; active composition alone creates no conflict or prompt. Preserve unrelated local progress. A separate completed-input snapshot and durable draft recovery are not newly mandated features.

[Apple's undo architecture](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UndoArchitecture/Articles/AppKitUndo.html) warns that changes omitted from undo can invalidate the chain. Its [Undo/Redo HIG](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo) emphasizes predictable targets, meaningful labels and standard commands. The next experiment should therefore compare supported registered external edits with the existing unregistered negative cases: prior typing → external localized/whole-body change → later typing → repeated Undo/Redo, plus separate/coalesced groups and shared-view routing. Verify exact results, fine granularity and causal eligibility. Registering an adapter for received history must not author a duplicate operation, make a derived merge a user action, or silently choose among incomparable candidates. Passing sequential AppKit undo is not a proof of these distributed cases. The [registered-edit follow-up](impl-proposal-5/plan/remaining-storage-validation.md#registered-external-undo) now tests prefix, whole-body Unicode, multi-range and post-Undo independent edits: four cases passed on both macOS 14.8.9 and 26.6.2, retaining two older native typing groups. Later typing/shared-view causal routing and production integration still require their own checks; the sequential results are ordinary LIFO undo, not selective rebasing.

Test actual input methods through normal keyboard/focus delivery before adding snapshot/refusal machinery. Preserve the synthetic tests as adapter/interleaving evidence, not a reason to require custom cancellation, interrupted typing, or a universal crash-snapshot policy. The [normative input scope](iCloud-Drive-Support-Spec.md#input-and-content-scope) and implementation proposal own NV's integration outcomes.

## Capability and provider-identification policy

- NV never identifies a provider by path, display name, raw domain identifier, private metadata, or persisted brand/profile.
- Positive ubiquitous-item or File Provider item/domain identity establishes provider management and opaque authority equality. Absence, failure, and ambiguity leave the root unclassified; NV does not attempt to prove ordinary-local authority.
- Advertised capabilities authorize one attempt; the actual operation result controls that attempt.
- Routine reconciliation and rebuild do not require historical/nonlocal `NSFileVersion` support. Historical API failure cannot block current-visible synchronization.
- Modern recovery uses validated, dependency-closed immutable NV objects. A provider status, complete directory listing, or Apple version identifier establishes neither global history completeness nor causal ancestry. `NVCheckpointInstallCurrentChanged` belongs to the retired shared-checkpoint design, not the modern synchronization path.
- Unresolved-version APIs are optional input to the badge-invoked embedded conflict resolver. Failure leaves the affected version unavailable/retryable for the attempt and does not change the current file or routine dirty state. Apple resolution is attempted only after the exact dependency-closed local segment barrier and separate-file installation; upload status is irrelevant. NV-head choices use NV history operations, not this Apple API.
- Preservation of edits committed to NV history does not depend on Apple's conflict retention. Preservation of an external editor's displaced, never-imported branch still depends on its disclosure; neither the segment protocol nor a passing one-round provider probe manufactures unavailable external bytes.
- Provider upload status is presentation only. It authorizes no history pruning, provider-version destruction, or claim of backup completeness.

## Acceptance summary

| ID | Required behavior / present scope | If not established |
| --- | --- | --- |
| AV-01 | Positive provider management and exact named-item/version status, used for materialization and the narrow disclosed-newer/unmaterialized Work Offline gate only; no provider-current/global-completeness authority | Leave classification/status unknown; retain independent local startup and do not manufacture a Work Offline choice |
| AV-02 | Coordinated exact-item materialization/read for note projections and immutable transport objects | Publish no partial or unvalidated bytes; missing dependencies remain pending |
| AV-03 | Complete shallow current catalogs for plaintext observations; apply scoped enumeration separately within the nested protocol namespace | No absence inference from incomplete listings; history acceptance remains monotonic |
| AV-04 | Batch preparation/accessor completion ownership | Fall back to serial asynchronous per-URL coordination |
| AV-05 | Immutable disclosed-member reads and snapshot-scoped Apple disposition; displaced external-body retention is only conditional observed evidence | Leave the affected member unavailable/retryable; NV-history sync and ordinary editing continue |
| AV-06 | Retired absent-current Apple history discovery | No gate; does not limit retained NV history |
| AV-07 | Prompt presenter acknowledgments plus later observations and retry/discovery opportunities | Retain pending work; callbacks alone are neither a catalog nor complete recursive discovery |
| AV-08 | Positive root-continuity evidence and conservative unavailable handling | Fence provider effects, never infer deletion or retarget by pathname; healthy positively associated local history can remain editable |
| AV-09 | Consumer forward File Provider identity as optional positive evidence | No provider-specific inference from failure; preserve independent positive evidence |
| AV-10/11 | Retired upload qualification | Observational status only; no durability or cleanup authority |
| AV-12 | Spotlight-independent correctness paths | Release blocker if required work waits for Spotlight |
| AV-13 | Real application authorization for a user-selected external provider root | Fail the affected operation on actual authorization errors |
| AV-14 | Independent, exactly read-back Keychain target credentials across source-preserving cutover | Retain source artifacts and keys; no unverified target adoption |
| AV-15 | Private Application Support, safe bookmark association and truthful filesystem barriers | No writable publication from uncertain private-store/root association or failed local durability; old WAL probes alone do not validate segments |
| AV-16 | Continuously owned directory-descriptor exclusion of cooperating local writers | No writer on known contention or failed private-store acquisition; root unavailability cannot retarget an existing session |
| AV-17 | Exact immutable-object installation and dependency-closed local durability, with independent transport delivery | Segment implementation gate; never substitute a successful replacement/WAL probe |

Required operation paths must pass on supported targets or use their specified conservative fallback. AV-04 is an optimization; AV-09 must pass before using forward identity. AV-05 gates Apple disposition, not NV history. AV-14 gates remembered credentials/cutover. AV-15–17 require concrete segment/private-state integration tests as well as the existing primitive probes.

## AV-01 — provider management and exact-item status

Validate from a LaunchServices-launched app:

1. `NSURLIsUbiquitousItemKey` supplies positive provider evidence without identifying a vendor.
2. Exact-item promised metadata can be obtained without downloading unrelated note contents.
3. Reported current/downloaded, stale, downloading, unavailable, and error states are distinguished without Spotlight; none proves global history completeness.
4. Account/network changes return explicit changed/error/unknown evidence rather than false currentness.
5. Work Offline eligibility requires a positively enumerated/versioned required item whose identity or generation is not represented by the complete local closure and whose exact bytes are currently unmaterialized/unreadable. `NSURLUbiquitousItemDownloadingStatusCurrent` describes the queried local item; it is not proof that no newer sibling/version exists. Generic offline/full/permission/timeout/error states are not positive newer evidence.

Returning startup opens validated local history/cache plus its durable tail without a provider-current checkpoint. The earlier checkpoint-status fixture tests only exact-item metadata; a complete, validated snapshot may provide a read-only preview before full history import.

## AV-02 — exact-item materialization and read

For a selected current note file or immutable protocol object (and a legacy checkpoint when testing migration):

1. Request materialization when required.
2. Read only from the coordinated accessor URL.
3. Treat request acceptance as a start, not completion.
4. Accept only exact readable bytes or an error.
5. Exercise offline, eviction, cancellation, provider restart, rename, deletion, and replacement during access.
6. For the retained legacy/checkpoint replacement fixture, when expected-current evidence mismatches, return either one coherent checkpoint-current witness—complete bytes, `NVFileObservation`, and current local version identity when available—or an explicit no-write failure. A later replacement that changes any observed witness component must fail the fresh retry CAS rather than let stale evidence authorize installation. Do not use `NSFileVersion.persistentIdentifier` as the sole replacement generation: same-bytes Foundation replacement kept it equal on macOS 14 and 26 while the filesystem observation changed.

## AV-03 — coordinated shallow current namespace

Plaintext projection reconciliation requires complete shallow direct-child snapshots around selected reads. Validate that:

- placeholders and names are returned without reading unchanged child contents;
- an evicted directory and large child sets produce either the complete current set or an explicit failure, never a silent prefix;
- create/edit/rename/delete before, during, and after enumeration are caught by the double-catalog fence or a retained callback obligation;
- `NV Data`, legacy `Notes & Settings`/WAL inputs, hidden replacement residue, directories, and ordinary note files can be classified independently; the directory lock creates no artifact;
- nonzero volume-qualified document IDs, session file IDs, and generation counts can be observed without content reads across rename, coordinated replacement, eviction, rematerialization, and restart. Record whether each stays equal or changes, but require neither outcome: document ID is used only with an equal volume UUID, file ID only within one active root session, generation only for invalidation, and every value must be unique on both association sides;
- Spotlight disabled, excluded, rebuilding, or unavailable changes nothing.

The immutable transport namespace is nested: validate scoped catalogs for descriptors, writers, segments and snapshots independently, with startup/reopen/invalidation and bounded retry discovery opportunities. A root presenter's callbacks are not proof that every descendant was disclosed; removal from any listing is never a logical Delete.

Use a two-Mac test-owned manifest for empty, small, and thousand-file roots. A marker file is only a wakeup; it is not a cross-file ordering fence.

Extend the existing `foundation`/manifest modes to record these optional identity fields before and after rename, replacement, eviction, rematerialization, and restart. The test passes when each observation is complete and the evaluator selects the documented identity or fallback tier; it must not require an identifier to remain stable.

## AV-04 — selected-item batch preparation

Validate nested coordinated reads and completion exactly once on success, failure, cancellation, exception, duplicate URLs, provider delay, and a root move. If any ownership rule cannot be established, use serial asynchronous per-URL coordination with identical inputs and fences.

## AV-05 — unresolved-version disclosure, immutable reads, and disposition

APIs:

- `NSURLUbiquitousItemHasUnresolvedConflictsKey`
- `+[NSFileVersion unresolvedConflictVersionsOfItemAtURL:]`
- `NSFileVersion.URL` and coordinated reading of that URL

For one visible note file with a real two-Mac conflict, validate the API contract separately from the NV UI:

1. For both locally ordered stale-base nondeletion schedules, every distinct edited body remains either the current body or a member returned by `unresolvedConflictVersionsOfItemAtURL:` after convergence. Separately record edit racing deletion as a ceiling probe. Report Current, unresolved, other, and nonlocal visibility independently; do not infer either retention or destruction from an undisclosed body when deletion removes the visible file.
2. A positive conflict status leads to a nonempty disclosed set or an explicit retryable ambiguity. A nil result or query error is never treated as an empty set.
3. Each retained member's supplied URL yields that member's immutable bytes when coordinated, including after the current file changes again. Eviction, materialization, and process restart never justify substituting current-file bytes.
4. Setting one retained member's `resolved` property to `YES` leaves the current file bytes unchanged and causes only that member to disappear from a fresh `unresolvedConflictVersionsOfItemAtURL:` result unless setting fails. Other unresolved members remain disclosed.
5. Marking every still-applicable member of one captured snapshot resolved makes a fresh unresolved result empty only when no new member arrived. A member created after that snapshot remains unresolved.
6. A stale member, per-member setter failure/exception, cancellation, or provider restart produces a partial or ambiguous result that a fresh query exposes; it never silently clears the conflict badge. User dismissal remains always available.
7. Repeated `resolved = YES` for an already-resolved member is harmless, and duplicate disclosed versions can be dispositioned independently without changing the current file.
8. Resolution neither requires nor proves provider upload and never calls `removeOtherVersionsOfItemAtURL:`, an individual removal API, or `replaceItemAtURL:options:error:`.

The current SDK documents that the `resolved` setter has no error result, cannot be reversed to `NO`, and has operating-system effects beyond disappearance from the unresolved query that are subject to change. Therefore perform setters inside a short coordinated `NSFileCoordinatorWritingForMerging` accessor and accept only a later fresh query as success evidence. Validate presenter callbacks as wakeups, never as proof.

Do not require historical `persistentIdentifier` values to be portable across machines or across a current-to-conflict transition. Apple's documented contract is narrower: a saved identifier recreates an equivalent version object through `versionOfItemAtURL:forPersistentIdentifier:`. The focused Foundation probe tests that round trip directly and treats identifier turnover after ordinary replacement as observational because Foundation does not promise that every file replacement creates a new `NSFileVersion`. The two-Mac semantic probe matched revisions by unique synthetic payload, archives each identifier, decodes it in a new process, compares it with the later local identifier, and passes it to that lookup API. A post-conflict archive round trip on its originating Mac passed equality and lookup for all eight current and all eight historical entries, establishing the documented same-version persistence. Exchanging those post-conflict archives between Macs passed all eight current entries but zero of eight historical entries in both directions. Capturing each writer's identifier immediately while its branch was current, then comparing after conflict convergence, likewise passed every branch that remained current but zero branches that became historical—even on the originating Mac. The observed conflict representation therefore did not preserve the former Current identifier for the losing content. This rejects proposal #3's broader shared `providerVersionRepresentationsV1` ancestry assumption without claiming an Apple contract violation. Treat a persistent identifier as an opaque key for one already-disclosed `NSFileVersion` entry; never use it as a portable content-revision identity or serialize it into a shared checkpoint/WAL expecting another Mac to recognize it.

Then validate the application ordering around that contract:

- **Current** is a frozen copy of the authoritative in-memory body, including admitted edits absent from disk.
- A selected member preview is published only for the still-current resolver operation and remains read-only.
- A changed note LSN, structural generation, or root-session incarnation after preview prevents **Use this version** from mutating or resolving anything.
- Killing NV before the disposition's local segment barrier or exact separate-file installation leaves every member unresolved.
- Killing NV after both local gates but before/during resolution leaves either an unresolved retry or a resolved member whose chosen note contents are already locally recoverable.
- **Use this version** revalidates its exact installed generation inside coordinated resolution and resolves only its captured snapshot; **Save as new note** revalidates source/member applicability and resolves only its selected member; every completion performs a fresh unresolved query.
- Recovery-key vectors prove title, labels, extension, filename, collision suffix, and provider identifiers do not affect identity; source UUID or canonical body changes do. Duplicate provider members with equal decoded bodies reuse one exact live-body slot.
- Crashes and injected failures at mutation admission, segment barrier, exact file installation, coordinated resolution, and fresh-query completion preserve the implementation proposal's per-version status/button behavior and never create another note for an exact reusable slot.
- Editing or deleting a recovery note before provider resolution invalidates its install evidence. The resolver never overwrites or resurrects that slot, and only a later explicit **Save as new note** may choose the next deterministic slot.
- The alert badge alone swaps `ConflictResolverView` into the editor split-view subview in place of `LinkingEditor`; conflict discovery never presents it automatically. The close **×** remains enabled during preview, segment, file-install, resolution, and fresh-query waits, restores `LinkingEditor`, and never cancels or authorizes the underlying operation.
- Closing during **Use this version** and then editing the source invalidates stale exact-generation resolution authority. Closing during **Save as new note** permits background completion only while the recovery note and source/member/root applicability remain exact.
- Waiting/error state is isolated to the affected member while other members remain selectable. One automatic retry pass is finite, its operation may finish while the resolver is dismissed, and exhaustion parks at **Retry when reopened** without clearing the badge or polling forever. Re-presenting the resolver starts exactly one fresh pass for every parked item on that note and coalesces rather than duplicates running attempts; the resolver exposes no Retry action.

No test attempts to prove a complete historical set, global identifier uniqueness, cross-Mac identifier portability, discoverability after the current file disappears, retention or reclamation of resolved history, or immediate cross-device propagation of resolution. Those are not implementation assumptions.

The stale-base probe gates only an external displaced-body claim for its specified simultaneous nondeletion round under both locally ordered host schedules; it is not a prerequisite for preserving NV-committed branches. The inspector records Apple's Current winner but does not equate it with unknowable internal server publication order. The edit/delete probe is observational: the macOS 14/26 run exposed zero of eight edited bodies as Current or unresolved on either host after deletion won, so that stronger current-visible claim is excluded. `otherVersionsOfItemAtURL:` also exposed none, and every nonlocal request for the deleted original URL completed with `NSCocoaErrorDomain/4`; these results do not prove provider-side destruction. Until the required nondeletion modes pass on each supported OS, the corresponding displaced-current claim remains conditional rather than established. The bounded live results are not evidence that Apple preserves displaced bodies across an arbitrary or repeated publication sequence. Any stronger product claim requires a separate repeated-round live-provider test.

## AV-06 — retired historical discovery

Earlier probes showed that retained pre-rename/pre-delete URLs did not redisclose historical versions in fresh processes. For Apple-only recovery, a version not reported as unresolved for a currently visible file is unavailable to the resolver. NV's own retained segment history is separate and remains available without a visible projection. AV-06 remains numbered only so older notes and test output are intelligible.

## AV-07 — presenter visibility and liveness

Register one presenter for the root directory. Exercise coordinated and ordinary external create/edit/rename/delete, direct-child and version/ubiquity callbacks, callback coalescing, callback-before-catalog visibility, sleep/wake, App Nap, network flap, provider restart, and relaunch. Reader/writer relinquishment and deletion accommodation must invoke Apple's supplied block exactly once and promptly; an external coordinated accessor must not remain blocked. A callback schedules/retries current-visible observation; it never proves the corresponding mutation visible. A later stable double-catalog transaction or a newer dirty generation must prevent permanent loss of the wakeup. Extend the focused presenter harness with a coordinated peer to enforce the acknowledgement/blocking case.

## AV-08 — root moves, authority changes, and unavailability

Validate same-volume provider/Finder moves while catalog, current read, batch preparation, Foundation replacement, and current-version CAS are in flight. Candidate URLs may come only from the rooted descriptor, presenter callback, file-reference URL, or bookmark. Rooted identity and any available forward item/domain identity must positively identify the same directory before retaining the session.

Separately test deletion, replacement with identical bytes, revoke/unmount, eviction, stale bookmarks, deep roots, provider/account change, and network failure. Positive changed-authority evidence fences into the provisional successor. Every result lacking positive same-root or changed-authority evidence enters root-continuity-unavailable state, leaves Retry and the explicit Save As/Re-open/quit choices, and forbids path retargeting or automatic session cancellation. Positive later evidence may restore or fence the session; an explicit user choice may end it. There is no deletion-proof recipe.

The focused macOS 14.8.9 and 26.6.1 iCloud tests rejected consumer-side reverse lookup. Forward `getIdentifierForUserVisibleFileAtURL:` succeeded, but looking up the matching domain and calling `getUserVisibleURLForItemIdentifier:` failed with `NSFileProviderErrorProviderNotFound`; macOS 26 additionally disclosed `NSFileProviderErrorApplicationExtensionNotFound`. `NSFileProviderManager`'s instance API is scoped to the provider extension and its containing/related processes, not an unrelated consumer such as NV. Production code must not enumerate provider domains, call or wait for this reverse API, or classify its errors. The recorded result is design evidence, not a continuing release gate.

Local segment durability is independent: provider authority uncertainty may leave editing enabled while positively associated Application Support history remains healthy and privately owned. Uncertain private-store/root association or known local writer contention still blocks editing.

## AV-09 — positive File Provider identity from a consumer app

`getIdentifierForUserVisibleFileAtURL:` can report `NSFileNoSuchFileError` both outside a provider and before a provider assigns an identifier. Validate positive identities for iCloud and other providers, equality continuity when an independently supplied candidate URL names the same moved item, and changed identity across authority change. By itself, every negative, failed, delayed, or ambiguous result leaves the root unclassified and authorizes no local-only or deletion inference; it does not erase separate current positive ubiquitous-item evidence.

The live harness owns only those raw API observations. The retained table-driven [forward-provider/root evaluation matrix](impl-proposal-4/README.md#forward-providerroot-evaluation-matrix) injects them into `NVRootSession` and verifies retention, provisional-successor fencing, unavailable fallback, retry, and every prohibited inference without requiring a provider failure for each policy row. Its identity-evaluation rows remain relevant; proposal 4's WAL/checkpoint recovery and deletion policies do not transfer with them.

Do not generalize successful forward identity into access to a domain manager. Remove `provider-reverse-child` from the regular harness when implementing this plan; the two-OS observation above is sufficient for an API production code deliberately does not use. If Apple later documents consumer reverse access and a concrete product need appears, design and validate that behavior afresh in a disposable process because reverse lookup changes that process's later materialization behavior.

## AV-10 and AV-11 — retired upload qualification

Keep existing harness modes as observational compatibility probes if useful, but remove them from release gates and production cleanup decisions. The app may present provider upload progress through existing status APIs. It does not pause an item, request fail-on-conflict upload, correlate an upload receipt, retain a WAL for upload, or infer cloud durability from legacy status transitions.

## AV-12 — Spotlight independence

Run startup, rebuild, current-visible reconciliation, conflict-copy status, root moves, and quit with Spotlight healthy, disabled, excluded, rebuilding, and unavailable. Required paths must not construct or wait for `NSMetadataQuery`.

## AV-13 — application identity and entitlements

Run the focused suite from the actual app context with stable bundle identity on a user-selected root outside an app-owned ubiquitous container. Record API authorization errors separately from provider/network errors. Retain one release-signed smoke test; provider behavior does not depend on parsing signature identity.

## AV-14 — copy-on-write Keychain cutover

Scope clarification: [password-free private SQLite recovery](impl-proposal-5/LocalStore.md#database-keys-and-password-free-recovery) uses a documented nonsecret key, not Keychain. AV-14 applies to optional Remember on this Mac for encrypted CKs and legacy/independent target credential handling. Encrypted DB keys derive from CK; password changes reuse same-CK wrapped-key descriptors, not a new database-secret cutover. Keychain loss must leave password/descriptor recovery available. The SQLCipher backup/salvage probes do not qualify signed-app Keychain behavior.

Retain the existing focused matrix: fresh add, exact read-back/KDF validation, source-independent target credentials, crashes at every boundary, duplicate account, denied access, malformed bytes, read mismatch, deletion failure, and two independently openable destinations. The older target-checkpoint fixture validates primitive credential handling only. Proposal 5 must bind credentials to its actual collection descriptor/key envelopes and Local State cutover. Deleting an old credential must not make retained source history unreadable; rewrapping is not revocation or re-encryption of old ciphertext.

## AV-15 — private local history association and directory durability

This is primarily a deterministic Foundation/filesystem contract, not a provider contract. Validate:

- user-domain Application Support lookup and proposal 5's private collection store; the existing `Recovery Journals` fixture is a legacy path, not the new layout;
- restrictive directory/file permissions and non-following of malicious symlinks;
- bookmark resolution after root rename/move, stale-bookmark handling, copied root, deleted root, unavailable volume, and permission failure;
- resolved directory identity comparison rather than bookmark/path equality;
- file and directory barrier behavior across immutable installation, Local State replacement and process/machine restart; preserve legacy header/append/delete probes as distinct migration evidence;
- unrelated/malformed objects remain untouched and never become authority for a selected root; cache failure cannot reset private settings or change that association.

## AV-16 — root-directory lock contract

The adopted design locks the already-open root-directory descriptor before provider-root mutation and retains its owner through observer/operation teardown. Independent private-store ownership protects local history/settings during offline use; it is not a substitute for a contended root lock. It creates no provider-visible lock file and does not substitute a per-session WAL lock. Apple's [`flock` contract](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html) provides advisory object locking, not pathname reservation, provider coordination, or a cross-Mac lease. A directory recreated at an old pathname is a different lock resource and remains subject to the existing positive-continuity fence.

The [directory-descriptor probe](IntegrationTests.md#root-directory-descriptor-lock-probe) checks independent-process contention and descriptor lifetime, including rename/move, child replacement, and process death. All local contenders opening the same directory must address the same exclusion resource regardless of their writer-epoch IDs. Abstract retention/release ordering does not prove platform behavior.

Remaining real-system cases: positively dataless-directory open/materialization; delivered remote-origin root moves/replacement/revoke; case-sensitive filesystem variants and detach/remount; older supported macOS releases, cross-user access, and other configured providers/network filesystems. Some can use this two-Mac setup; the dataless-directory stimulus has not yet been reproduced. Require observed transitions and fresh independent contenders, not eviction-request acceptance, peer install success, or elapsed time. Root replacement is expected to require identity fencing, not a lock magically transferring to the replacement. Tests must verify conservative no-retarget behavior and production ownership through controller/authority/storage handoffs, failed cleanup, and vnode cancellation before broadening the guarantee.

Observations on 2026-09-03:

| Scenario | Observation and limit |
| --- | --- |
| APFS local and iCloud directories, macOS 14.8.9 Intel and 26.6.1 arm64 | Read-only directory `flock(LOCK_EX | LOCK_NB)` succeeded. Independently opened contenders returned `EWOULDBLOCK`. Exclusion and local inode identity survived coordinated child creation/Foundation replacement, directory rename, and movement to another parent. |
| Descriptor lifetime, both Macs | Closing a separately opened scan descriptor did not release the lock. A duplicate retained it after the original closed; closing the last descriptor released it. Killing a pipe-confirmed independent holder released it for the next process. |
| Recreated old pathname, both Macs | The new directory had a different identity and was independently lockable while the moved original remained locked. Root-continuity checks are still required; `flock` is not a pathname reservation. |
| Directory eviction requests, both Macs | With no holder, the request succeeded and the child became not-downloaded, but directory `SF_DATALESS` was not observed during the 15-second check. Opening/locking that directory took under 1 ms. This did **not** establish cold dataless-directory behavior. |
| Child eviction/rematerialization while the directory was locked, both Macs | Exact coordinated payload reads succeeded, same-directory identity was retained, and independent contenders remained excluded. A subsequent directory-eviction request while locked again evicted the child without an observed dataless directory; exact rematerialization and exclusion passed again. Both provider runs returned 2 to preserve the unexercised directory-placeholder case. |
| HFS+ disk image, macOS 26 | All local directory-lock controls passed. No provider behavior is exercised by this volume. |
| ExFAT disk image, macOS 26.6.2 (25G83) | Retry with the existing filesystem harness's 192 MiB sparse-image settings and `NVEXFAT` volume label succeeded; `diskutil` confirmed the mounted filesystem was ExFAT. All local directory-lock controls passed: contention, separate scan close, child Foundation replacement, rename/move, recreated-path independence, duplicate handoff, final close, and `SIGKILL` release. The earlier image-creation error did not recur; its cause is unconfirmed, and the retry ran on a newer OS build. Provider eviction is inapplicable to this local image. |

The specification and ADR-0006 adopt this mechanism with continuous single-owner retention and no alternate lock-file/WAL fallback. The untested boundaries above remain open; success on these volumes is not a universal provider guarantee. Acquisition failure grants no writer authority, and a fresh open is not a lock transfer. No production implementation is supplied by the probe.

### Comparison only: child lock-file interference

The retained [child-lock probe](IntegrationTests.md#root-lock-interference-probe) explains the rejected `.nv-root.lock` approach; its unexercised scenarios are not acceptance gates for the directory-descriptor design. Local replacement/unlink controls deliberately reproduce a second acquisition on a new child inode while the old one remains locked. They do not establish spontaneous iCloud replacement or an Apple contract violation. No provider version history was changed.

Comparison observations, 2026-09-03:

| Scenario | Observation and limit |
| --- | --- |
| Local controls, macOS 14.8.9 and 26.6.1 | All six passed on both Macs. Deliberate same-byte replacement and unlink/recreation displaced the held inode and allowed a second local lock. A separate macOS 26 monitor-plus-injected-replacement run emitted `HAZARD` and exited 1, validating the monitoring path too. |
| Cold evicted empty lock, macOS 26 | Eviction was positively observed. Raw open completed in under 1 ms while the file remained dataless; all five subsequent local contenders were rejected. Eviction does not necessarily make opening an empty lock block or fail. |
| Eviction requested while held, macOS 26 | Rejected with `NSCocoaErrorDomain/255`, underlying `NSPOSIXErrorDomain/16` (`EBUSY`). Exclusion remained intact, but this did not exercise eviction of a held file. |
| Already-dataless lock rematerialized while held, macOS 26 | Coordinated exact empty read succeeded, the dataless flag cleared without changing the inode, and all eleven contenders were rejected across the 12-second watch. |
| Concurrent empty creation, macOS 14 and 26 | Both Macs proved exclusive local creation at the scheduled start and held concurrently for 35 seconds. Each rejected all 32 local contenders; neither observed a changed inode, extra sibling, or unresolved member. This is not proof of completed server reconciliation or future stability. |
| Empty Foundation replacement on macOS 14 while macOS 26 held | Peer installation succeeded, but the receiving Mac observed no inode change in its 40-second watch; all 37 contenders were rejected. **Inconclusive for delivered replacement**: no payload change identifies delivery, and local upload/install status cannot substitute for an observed receiving-side change. |

## AV-17 — immutable-object and local-segment contract gates

The existing Foundation replacement and WAL barrier probes do not establish these new contracts. Before shipping, bind the actual proposal-5 codec/installer to crash injection and the [implementation verification matrix](impl-proposal-5/Verification.md):

- exclusive final-name installation never overwrites an existing object; exact existing bytes are idempotent success and conflicting bytes are retained/quarantined;
- verify complete bytes, authentication/digest and parent closure before acceptance; file synchronization, final-name installation and parent-directory synchronization precede durability acknowledgment;
- a crash after final installation but before callback recovers the installed group, including its action metadata, without callback bookkeeping as authority;
- independent provider delivery/eviction can postpone dependencies but cannot cause partial group application, cloud-acknowledged durability or pruning;
- delayed nested-namespace disclosure and copied/malformed names cannot bypass object validation;
- cache loss, retained-history-pin write/readback failure, a pinned missing leaf, private/root lock ownership and fresh-sibling repair are tested independently.

For repository repair, a coordinated local ENOENT observation proves only that the name is absent from that accessor's current namespace. It is sufficient input to the app's explicitly authorized exclusive-create attempt after positive root validation; it is not proof of remote deletion, global absence or permission to overwrite something that appears before installation. Test concurrent creation and peer-observed results without requiring Apple to merge two directories or disclose a globally complete inventory. These are uncompleted implementation/contract gates, not new empirical Apple observations.

The Work Offline classifier needs two layers of tests. Scope the choice to startup with already disclosed evidence missing locally; late disclosure after local editing begins cannot close admission or demand the choice. An evicted provider copy of bytes already retained locally creates no missing-evidence wait. A table-driven application test supplies positive disclosed-newer, positive disclosed-unmaterialized, generic unavailable/full/permission/timeout and unknown inputs and verifies that only the first two offer the choice. A live provider probe may establish the raw input by enumerating a named required item/version and observing its materialization state, but cannot require Apple to reveal an undisclosed server branch or use `DownloadingStatusCurrent` as a no-newer oracle. If the platform exposes no positive newer evidence in a case, the app continues from healthy local history and reconciles later discovery; it does not show Work Offline on speculation.

## Existing focused harness evidence

`tests/ICloudAPIContractTest.m` already supplies LaunchServices app-context provider probes, two-Mac host/peer mutation, simultaneous conflict generation, current-item materialization, shallow catalogs, batch reads, root moves, Spotlight independence, and historical observations. Retain those useful modes while changing the required policy:

- the previous all-version AV-05 fence and identifier migration results become exploratory only;
- the simultaneous-conflict setup should feed the new unresolved-version immutable-read/disposition test, including one-member and snapshot-wide `resolved = YES` behavior;
- exact current checkpoint replacement remains a retired proposal-4 caller fixture; only the generic exact-observation/replacement primitives transfer to modern mutable-file callers, not checkpoint omission or checkpoint-note merging;
- pause/upload and legacy qualification modes become observational only;
- the local suite must fail when a required current-design case reports `SKIP` or `OBSERVE` rather than `PASS`.

The focused harness now also supplies:

- `foundation`, which checks coherent current bytes/version evidence, the documented same-version persistent-identifier lookup, and observational same-bytes replacement behavior across both `NSFileVersion` and the existing filesystem observation; it also checks dual-URL coordination, old-or-new concurrent visibility, retained displaced bytes, provider/root identity, custom xattrs, and the local AV-15 Application Support create/append/delete barriers. Every replacement obtains a fresh file-reference URL from a newly constructed canonical pathname URL; deliberately reusing pre-replacement URL state is not accepted. `wal-reboot-prepare` and `wal-reboot-verify` bracket a real machine restart without letting elapsed time stand in for durability.
- `manifest-host` / `manifest-peer`, which use a 1,000-item two-Mac manifest, explicitly evict a sample on the peer, require an exact stable post-mutation catalog, and treat causal marker files only as wakeups.
- `conflict-disposition`, which changes the current file after capturing an unresolved member, proves immutable member bytes, sets only that member's `resolved` property inside merging coordination, requires fresh-query disappearance with unchanged current bytes, repeats the setter, and dispositions the rest of the captured snapshot without removal APIs.
- `conflict-export-identifiers` / `conflict-compare-identifiers`, which exchange identifier archives outside the provider root and compare only counts for the same synthetic payload-defined revisions; identifier values are never logged.
- an uncoordinated POSIX writer, so AV-07 records presenter activity separately from the later exact catalog/read observation.

The exploratory `xattr-host` / `xattr-peer` probe on iCloud Drive between macOS 26.6.1 and macOS 14.8.9 found:

- all five 16-byte values whose names were generated with `XATTR_FLAG_SYNCABLE` arrived in both synchronization directions;
- the UUID remained readable through metadata-only coordination while the file body stayed evicted, and remained equal after materialization and rename;
- actual Finder duplication and a TextEdit save preserved the UUID when run in an interactive logged-in session; SSH-launched Apple-event automation could not establish those GUI results and is therefore bounded and observational;
- a generic `NSDataWritingAtomic` replacement removed the UUID on both systems (`ENOATTR` on the installed replacement), so any future xattr-writing design would have to stage the attribute before installation rather than depend on destination metadata preservation; v1 does not write this UUID; and
- both systems disclosed both bodies for all eight simultaneous-write conflicts. A follow-up eliminated the initial write/restamp interval by putting the UUID on each staged replacement before one coordinated Foundation installation; half used default replacement metadata handling and half used `NSFileManagerItemReplacementUsingNewMetadataOnly`. All eight current files retained their UUID, but zero conflicts exposed it on both body-bearing versions under either replacement mode. Only the current winner's body exposed the UUID. `NSFileVersion.URL` must therefore not be assumed to carry branch-specific custom xattrs.

These observations do not authorize UUID-based current-file deletion, identify historical resolver members, or make a missing/malformed/duplicate xattr destructive evidence. Proposal 5 now adopts a **body-bound advisory projection stamp**, not the older bare UUID attribute: see [Protocol](impl-proposal-5/Protocol.md#projection-stamp-and-delayed-history-handling) and ADR-0014. NV stages the bounded stamp with its output where supported; missing/stripped attributes remain supported through conservative association. No new live-provider result is claimed by that adoption.

The later [two-Mac incarnation experiments](tla/Incarnation-Metadata-Experiments.md#two-mac-follow-up-measured-binding-and-intent-transport) confirmed exact staged body/stamp values at converged endpoints, including metadata readable while evicted. They did not establish intermediate atomic body/metadata visibility. Apple versions content and metadata separately and limits aggregate syncable xattrs to approximately 32 KiB; the adopted stamp is bounded to 4 KiB but must still tolerate omission. These are documented separate concerns, not evidence of a contract violation. [Item versions](https://developer.apple.com/documentation/fileprovider/nsfileprovideritemversion), [extended attributes](https://developer.apple.com/documentation/fileprovider/nsfileprovideritemprotocol/extendedattributes).

Required new checks: fixed exact `org.notationalvelocity.projection#S` name and canonical value across Intel/ARM; fresh staged stamp/body through both existing-file and exclusive-create paths; fault injection for old-body/new-stamp and new-body/old-stamp observations; stripped/duplicate/foreign/oversized values; missing referenced segment/parent closure; unchanged merged/conflict projection echo suppression; copied stamped files and actual external-editor safe saves. A matching stamp may request history but cannot be applied as a standalone operation. The receiver must preserve ambiguous bytes regardless of ordering, not assert that Apple must deliver them atomically. Compiled production codec/caller tests remain necessary; prior endpoint probes do not test this new encoding.

On iCloud Drive, the 1,000-item macOS 26/macOS 14 run returned the complete initial and mutated catalogs while all 16 explicitly evicted sample bodies stayed unmaterialized. The focused empty/small double-catalog fence also detected coordinated create, edit, rename, and delete on both systems. The real simultaneous-edit run disclosed both bodies for all eight files, and the required per-member disposition sequence passed. The edit/delete run exposed zero of eight edited bodies as Current or unresolved on either host after deletion won; this establishes only the current-visible ceiling, not provider-side destruction. Foundation replacement and AV-15 local barriers passed on both OS versions. On both, a same-bytes Foundation replacement kept the current `NSFileVersion.persistentIdentifier` equal while the filesystem witness changed; different replacement bytes were returned coherently. Identifier equality is compatible with Apple's same-version lookup contract and is not interpreted as a replacement-generation guarantee. The retired reverse-domain attempt failed on both versions as recorded under AV-08 and is no longer part of the regular suite.

Content-free diagnostics remain mandatory: OS build, operation ID, item count, phase, status enum, and error domain/code only. Never log paths, filenames, note text, bookmarks, provider identifiers, or account identity.

## Real-system matrix

Run first-class ship conditions on macOS 15 and the current release, using two Macs on one iCloud account where ordering matters. Run the legacy-root-WAL migration on the oldest supported macOS. Repeat provider membership, current catalog, move, and optional unresolved-version cases with current Dropbox and one additional File Provider as best-effort observations.

Minimum faults:

- online, offline, reconnecting, and account transition;
- Optimize Mac Storage on/off with current files and directory evicted;
- remote mutation before the first catalog, between catalogs, after the second catalog, and before callback visibility;
- independent/out-of-order segment and snapshot-page delivery, conflicting bytes at one immutable name, missing dependencies, retained-history-pin races, and private-state replacement races;
- partial/total `NV Data` and Application Support loss; symlink, file/directory-kind and permission collisions at every required level; automatic same-root top-level repair versus preserved foreign/concurrent occupants; complementary-copy rebuild and the no-copy-available terminal case;
- provider daemon restart and app crash at every accessor/completion boundary;
- root moved, copied, deleted, replaced, revoked, and unavailable, with only positive same-root evidence restoring publication and no automatic loss classification;
- local segment write/file-sync/install/directory-sync failures independently of provider state, including install-before-lost-callback recovery;
- normal quit, explicit override, disposable cache failure, Local State ambiguity, and next-launch replay; retain separate legacy WAL/import/export cases.

An API/OS result is accepted only when the required condition is demonstrated, not because Finder eventually appeared correct.

## Relationship to TLA+

The [active coverage map](tla/Proposal5-Coverage.md) separates segment checks, shared components and retired proposal-4 comparisons. Segment models assume truthful local barriers, authenticated/associated immutable inputs and dependency information; they do not prove those inputs or actual provider delivery. The bootstrap model does not turn a complete current listing into a globally complete history set.

Current-file catalog/generation and Apple member-scope components remain useful. Their local-WAL durability input must be bound to the exact segment closure before counting them as an implementation proof. Shared mutable-checkpoint merge, WAL cleanup and old storage/startup bridges are retired authority models, not segment coverage. Same-bytes replacement may invalidate a filesystem witness while the Apple persistent identifier stays equal.

Failure to establish an environmental precondition removes only the corresponding success path and retains pending work/evidence; it never justifies inventing history, deleting notes, or gating otherwise healthy local durability on provider progress. Model mutations and reachability witnesses are not live API validation.

## Primary Apple references

- [NSFileCoordinator](https://developer.apple.com/documentation/foundation/nsfilecoordinator)
- [NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter)
- [NSFileVersion](https://developer.apple.com/documentation/foundation/nsfileversion)
- [NSFileVersion persistentIdentifier](https://developer.apple.com/documentation/foundation/nsfileversion/persistentidentifier)
- [iCloud file-version conflict handling](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)
- [File Provider item identity](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/getidentifierforuservisiblefile%28at%3Acompletionhandler%3A%29)
- [iCloud download status](https://developer.apple.com/documentation/foundation/urlubiquitousitemdownloadingstatus)
- [Application Support directory](https://developer.apple.com/documentation/foundation/filemanager/searchpathdirectory/applicationsupportdirectory)
- [Bookmark resolution](https://developer.apple.com/documentation/foundation/nsurl/urlbyresolvingbookmarkdata%28_%3Aoptions%3Arelativetourl%3Abookmarkdataisstale%3A%29)
- [File Provider syncable extended attributes](https://developer.apple.com/documentation/fileprovider/nsfileprovideritemprotocol/extendedattributes)
