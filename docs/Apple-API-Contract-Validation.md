# Apple API Contract Validation

This document records Apple/File Provider behaviors that the implementation and TLA+ models cannot prove. It follows the current-visible/local-WAL design in ADR-0013 and ADR-0014.

No elapsed-time threshold proves freshness, catalog completeness, conflict absence, upload, or root continuity (`WAIT-01`). Tests distinguish documented API contract, observed provider behavior, and application policy. Every inconclusive result fails closed for the operation that needed it.

## Capability and provider-identification policy

- NV never identifies a provider by path, display name, raw domain identifier, private metadata, or persisted brand/profile.
- Positive ubiquitous-item or File Provider item/domain identity establishes provider management and opaque authority equality. Absence, failure, and ambiguity leave the root unclassified; NV does not attempt to prove ordinary-local authority.
- Advertised capabilities authorize one attempt; the actual operation result controls that attempt.
- Routine reconciliation and rebuild do not require historical/nonlocal `NSFileVersion` support. Historical API failure cannot block current-visible synchronization.
- `NVCheckpointInstallCurrentChanged` may use only an exact coordinated snapshot of the canonical current checkpoint. It is not permission to enumerate or recover historical checkpoint versions.
- Unresolved-version APIs are optional input to the badge-invoked embedded conflict resolver. Failure leaves the affected version unavailable/retryable for the attempt and does not change the current file or routine dirty state. Resolution is attempted only after exact local WAL and separate-file installation; upload status is irrelevant.
- A stronger cross-machine no-silent-branch-loss claim is conditional: when one stale-base publication displaces a different current body, the displaced body must remain current or be returned as unresolved. Current-visible synchronization itself does not depend on that claim.
- Provider upload status is presentation only. It authorizes no WAL cleanup or provider-version destruction.

## Acceptance summary

| ID | Required behavior | Needed for | If not established |
| --- | --- | --- | --- |
| AV-01 | Ubiquity and exact-item status identify provider management and a provider-current checkpoint | Fast startup | Treat authority/status as unknown and use startup choices |
| AV-02 | Explicit materialization plus coordinated read yields the requested exact current item or an error | Startup, selected current note reads, and checkpoint-current note reconciliation | Publish no partial bytes; retain retry/offline/close choices |
| AV-03 | Coordinated shallow enumeration discloses the current direct-child namespace and optional filesystem identity/revision values without reading child contents | Routine reconciliation, absence classification, rebuild | Snapshot incomplete; no `DISC-01`/`PUB-01` commit or rebuild; unusable identity values fall back conservatively |
| AV-04 | Batch preparation and nested coordinated reads obey accessor/completion ownership | Efficient selected current reads | Use serial per-URL coordination |
| AV-05 | Apple-reported unresolved versions can be snapshot/read immutably, `resolved = YES` makes only the designated members leave a fresh unresolved query without changing the current file, and tested stale-base simultaneous nondeletion publications retain the displaced body as current or unresolved | Embedded conflict disposition and the conditional cross-machine nondeletion displaced-body preservation claim | Keep the badge/version retryable; routine sync continues, but do not claim preservation for a branch whose only remaining evidence would have been provider conflict history |
| AV-06 | Retired: absent-current historical discovery | No current requirement | No test gate; NV accepts the current-visible ceiling |
| AV-07 | Presenter callbacks plus later current observations provide reconciliation liveness | Continuous current-visible sync | Retain dirty and bounded-backoff retry |
| AV-08 | Root callbacks/vnode events plus rooted and optional forward-provider identity distinguish positive same-root recovery, positive authority change, and one unavailable fallback | Path independence and root-unavailable UI | Retain or fence the session only from positive evidence; otherwise freeze publication and never infer deletion or retarget by path |
| AV-09 | Forward File Provider URL identity works in a consumer app as a positive provider/equality witness | Positive provider classification and candidate-URL validation | Leave the root unclassified; grant no provider-specific inference |
| AV-10 | Retired: macOS 26 exact upload optimization | No current requirement | Use ordinary provider synchronization/status |
| AV-11 | Retired: pre-macOS-26 upload qualification | No current requirement | Use ordinary provider synchronization/status |
| AV-12 | Spotlight failure cannot affect required paths | Startup and reconciliation availability | Ship blocker if required code uses `NSMetadataQuery` |
| AV-13 | A normally launched app can use required APIs on a user-selected external iCloud root without an API-specific entitlement | Deployment/signing | Fail closed on real authorization error |
| AV-14 | Copy-on-write Keychain target items remain independent and exactly readable | Encrypted cutover and Save As | Preserve accepted checkpoint/item pair; do not install unverified target |
| AV-15 | Application Support bookmark creation/resolution and local directory durability support self-describing WAL association | Same-Mac crash recovery | Block editing for unmatched/uncertain local WAL evidence |
| AV-16 | A continuously retained root-directory descriptor lock excludes another cooperating local writer of that same directory object | Root-session mutual exclusion from startup through teardown | Acquisition failure admits no writer; root replacement/revoke requires positive continuity fencing, never pathname retargeting; no child-lock/WAL fallback |

AV-01, AV-02, AV-03, AV-07, AV-08, AV-13, and AV-15 are first-class iCloud ship conditions. AV-04 is an optimization. AV-05 gates the optional embedded resolver; its displaced-current subcase also gates the conditional cross-machine branch-preservation claim, not routine current-visible sync. AV-09 must pass before forward File Provider identity is enabled. AV-14 gates remembered-passphrase changes and encrypted Save As.

## AV-01 — provider management and checkpoint currentness

Validate from a LaunchServices-launched app:

1. `NSURLIsUbiquitousItemKey` supplies positive provider evidence without identifying a vendor.
2. Exact checkpoint promised metadata can be obtained without downloading note contents.
3. Provider-current, stale, downloading, unavailable, and error states are distinguishable without Spotlight.
4. Account/network changes return explicit changed/error/unknown evidence rather than false currentness.

An ordinary current checkpoint may open before any note catalog is collected.

## AV-02 — exact-item materialization and read

For a current checkpoint or selected current note file:

1. Request materialization when required.
2. Read only from the coordinated accessor URL.
3. Treat request acceptance as a start, not completion.
4. Accept only exact readable bytes or an error.
5. Exercise offline, eviction, cancellation, provider restart, rename, deletion, and replacement during access.
6. When checkpoint expected-current evidence mismatches, return either one coherent checkpoint-current witness—complete bytes, `NVFileObservation`, and current local version identity when available—or an explicit no-write failure. A later replacement that changes any observed witness component must fail the fresh retry CAS rather than let stale evidence authorize installation. Do not use `NSFileVersion.persistentIdentifier` as the sole replacement generation: same-bytes Foundation replacement kept it equal on macOS 14 and 26 while the filesystem observation changed.

## AV-03 — coordinated shallow current namespace

The current-visible design requires one complete shallow direct-child snapshot. Validate that:

- placeholders and names are returned without reading unchanged child contents;
- an evicted directory and large child sets produce either the complete current set or an explicit failure, never a silent prefix;
- create/edit/rename/delete before, during, and after enumeration are caught by the double-catalog fence or a retained callback obligation;
- the checkpoint, legacy WAL, hidden replacement residue, directories, and ordinary note files can be projected independently; the directory lock creates no artifact;
- nonzero volume-qualified document IDs, session file IDs, and generation counts can be observed without content reads across rename, coordinated replacement, eviction, rematerialization, and restart. Record whether each stays equal or changes, but require neither outcome: document ID is used only with an equal volume UUID, file ID only within one active root session, generation only for invalidation, and every value must be unique on both association sides;
- Spotlight disabled, excluded, rebuilding, or unavailable changes nothing.

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
6. A stale member, per-member setter failure/exception, cancellation, or provider restart produces a partial or ambiguous result that a fresh query exposes; it never silently authorizes resolver dismissal.
7. Repeated `resolved = YES` for an already-resolved member is harmless, and duplicate disclosed versions can be dispositioned independently without changing the current file.
8. Resolution neither requires nor proves provider upload and never calls `removeOtherVersionsOfItemAtURL:`, an individual removal API, or `replaceItemAtURL:options:error:`.

The current SDK documents that the `resolved` setter has no error result, cannot be reversed to `NO`, and has operating-system effects beyond disappearance from the unresolved query that are subject to change. Therefore perform setters inside a short coordinated `NSFileCoordinatorWritingForMerging` accessor and accept only a later fresh query as success evidence. Validate presenter callbacks as wakeups, never as proof.

Do not require historical `persistentIdentifier` values to be portable across machines or across a current-to-conflict transition. Apple's documented contract is narrower: a saved identifier recreates an equivalent version object through `versionOfItemAtURL:forPersistentIdentifier:`. The focused Foundation probe tests that round trip directly and treats identifier turnover after ordinary replacement as observational because Foundation does not promise that every file replacement creates a new `NSFileVersion`. The two-Mac semantic probe matched revisions by unique synthetic payload, archives each identifier, decodes it in a new process, compares it with the later local identifier, and passes it to that lookup API. A post-conflict archive round trip on its originating Mac passed equality and lookup for all eight current and all eight historical entries, establishing the documented same-version persistence. Exchanging those post-conflict archives between Macs passed all eight current entries but zero of eight historical entries in both directions. Capturing each writer's identifier immediately while its branch was current, then comparing after conflict convergence, likewise passed every branch that remained current but zero branches that became historical—even on the originating Mac. The observed conflict representation therefore did not preserve the former Current identifier for the losing content. This rejects proposal #3's broader shared `providerVersionRepresentationsV1` ancestry assumption without claiming an Apple contract violation. Treat a persistent identifier as an opaque key for one already-disclosed `NSFileVersion` entry; never use it as a portable content-revision identity or serialize it into a shared checkpoint/WAL expecting another Mac to recognize it.

Then validate the application ordering around that contract:

- **Current** is a frozen copy of the authoritative in-memory body, including admitted edits absent from disk.
- A selected member preview is published only for the still-current resolver operation and remains read-only.
- A changed note LSN, structural generation, or root-session incarnation after preview prevents **Use this version** from mutating or resolving anything.
- Killing NV before the disposition's WAL barrier or exact separate-file installation leaves every member unresolved.
- Killing NV after both local gates but before/during resolution leaves either an unresolved retry or a resolved member whose chosen note contents are already locally recoverable.
- **Use this version** revalidates its exact installed generation inside coordinated resolution and resolves only its captured snapshot; **Save as new note** revalidates source/member applicability and resolves only its selected member; every completion performs a fresh unresolved query.
- Recovery-key vectors prove title, labels, extension, filename, collision suffix, and provider identifiers do not affect identity; source UUID or canonical body changes do. Duplicate provider members with equal decoded bodies reuse one exact live-body slot.
- Crashes and injected failures at mutation admission, WAL barrier, exact file installation, coordinated resolution, and fresh-query completion preserve the implementation proposal's per-version status/button behavior and never create another note for an exact reusable slot.
- Editing or deleting a recovery note before provider resolution invalidates its install evidence. The resolver never overwrites or resurrects that slot, and only a later explicit **Save as new note** may choose the next deterministic slot.
- The alert badge alone swaps `ConflictResolverView` into the editor split-view subview in place of `LinkingEditor`; conflict discovery never presents it automatically. The close **×** remains enabled during preview, WAL, file-install, resolution, and fresh-query waits, restores `LinkingEditor`, and never cancels or authorizes the underlying operation.
- Closing during **Use this version** and then editing the source invalidates stale exact-generation resolution authority. Closing during **Save as new note** permits background completion only while the recovery note and source/member/root applicability remain exact.
- Waiting/error state is isolated to the affected member while other members remain selectable. One automatic retry pass is finite, its operation may finish while the resolver is dismissed, and exhaustion parks at **Retry when reopened** without clearing the badge or polling forever. Re-presenting the resolver starts exactly one fresh pass for every parked item on that note and coalesces rather than duplicates running attempts; the resolver exposes no Retry action.

No test attempts to prove a complete historical set, global identifier uniqueness, cross-Mac identifier portability, discoverability after the current file disappears, retention or reclamation of resolved history, or immediate cross-device propagation of resolution. Those are not implementation assumptions.

The required stale-base probe is the gate for the specified simultaneous nondeletion round under both locally ordered host schedules. The inspector records Apple's Current winner but does not equate it with unknowable internal server publication order. The edit/delete probe is observational: the macOS 14/26 run exposed zero of eight edited bodies as Current or unresolved on either host after deletion won, so that stronger current-visible claim is excluded. `otherVersionsOfItemAtURL:` also exposed none, and every nonlocal request for the deleted original URL completed with `NSCocoaErrorDomain/4`; these results do not prove provider-side destruction. Until the required nondeletion modes pass on each supported OS, the corresponding displaced-current claim remains conditional rather than established. `MultiRoundCrossMachineSafety` applies the nondeletion contract independently at each bounded modeled displacement; its passing result is not evidence that Apple preserves displaced bodies across an arbitrary or repeated publication sequence. Any stronger product claim requires a separate repeated-round live-provider test.

## AV-06 — retired historical discovery

Earlier probes showed that retained pre-rename/pre-delete URLs did not redisclose historical versions in fresh processes. The current design accepts that ceiling: a version not reported as unresolved for a currently visible file is unavailable to NV. AV-06 remains numbered only so older notes and test output are intelligible.

## AV-07 — presenter visibility and liveness

Register one presenter for the root directory. Exercise coordinated and ordinary external create/edit/rename/delete, direct-child and version/ubiquity callbacks, callback coalescing, callback-before-catalog visibility, sleep/wake, App Nap, network flap, provider restart, and relaunch. Reader/writer relinquishment and deletion accommodation must invoke Apple's supplied block exactly once and promptly; an external coordinated accessor must not remain blocked. A callback schedules/retries current-visible observation; it never proves the corresponding mutation visible. A later stable double-catalog transaction or a newer dirty generation must prevent permanent loss of the wakeup. Extend the focused presenter harness with a coordinated peer to enforce the acknowledgement/blocking case.

## AV-08 — root moves, authority changes, and unavailability

Validate same-volume provider/Finder moves while catalog, current read, batch preparation, Foundation replacement, and current-version CAS are in flight. Candidate URLs may come only from the rooted descriptor, presenter callback, file-reference URL, or bookmark. Rooted identity and any available forward item/domain identity must positively identify the same directory before retaining the session.

Separately test deletion, replacement with identical bytes, revoke/unmount, eviction, stale bookmarks, deep roots, provider/account change, and network failure. Positive changed-authority evidence fences into the provisional successor. Every result lacking positive same-root or changed-authority evidence enters root-continuity-unavailable state, leaves Retry and the explicit Save As/Re-open/quit choices, and forbids path retargeting or automatic session cancellation. Positive later evidence may restore or fence the session; an explicit user choice may end it. There is no deletion-proof recipe.

The focused macOS 14.8.9 and 26.6.1 iCloud tests rejected consumer-side reverse lookup. Forward `getIdentifierForUserVisibleFileAtURL:` succeeded, but looking up the matching domain and calling `getUserVisibleURLForItemIdentifier:` failed with `NSFileProviderErrorProviderNotFound`; macOS 26 additionally disclosed `NSFileProviderErrorApplicationExtensionNotFound`. `NSFileProviderManager`'s instance API is scoped to the provider extension and its containing/related processes, not an unrelated consumer such as NV. Production code must not enumerate provider domains, call or wait for this reverse API, or classify its errors. The recorded result is design evidence, not a continuing release gate.

WAL durability is now independent: provider authority uncertainty may leave editing enabled while the local Application Support WAL remains healthy. Root/WAL association uncertainty still blocks editing.

## AV-09 — positive File Provider identity from a consumer app

`getIdentifierForUserVisibleFileAtURL:` can report `NSFileNoSuchFileError` both outside a provider and before a provider assigns an identifier. Validate positive identities for iCloud and other providers, equality continuity when an independently supplied candidate URL names the same moved item, and changed identity across authority change. By itself, every negative, failed, delayed, or ambiguous result leaves the root unclassified and authorizes no local-only or deletion inference; it does not erase separate current positive ubiquitous-item evidence.

The live harness owns only those raw API observations. The table-driven [forward-provider/root evaluation matrix](impl-proposal-4/README.md#forward-providerroot-evaluation-matrix) injects them into `NVRootSession` and verifies retention, provisional-successor fencing, unavailable fallback, retry, and every prohibited inference without requiring a provider failure for each policy row.

Do not generalize successful forward identity into access to a domain manager. Remove `provider-reverse-child` from the regular harness when implementing this plan; the two-OS observation above is sufficient for an API production code deliberately does not use. If Apple later documents consumer reverse access and a concrete product need appears, design and validate that behavior afresh in a disposable process because reverse lookup changes that process's later materialization behavior.

## AV-10 and AV-11 — retired upload qualification

Keep existing harness modes as observational compatibility probes if useful, but remove them from release gates and production cleanup decisions. The app may present provider upload progress through existing status APIs. It does not pause an item, request fail-on-conflict upload, correlate an upload receipt, retain a WAL for upload, or infer cloud durability from legacy status transitions.

## AV-12 — Spotlight independence

Run startup, rebuild, current-visible reconciliation, conflict-copy status, root moves, and quit with Spotlight healthy, disabled, excluded, rebuilding, and unavailable. Required paths must not construct or wait for `NSMetadataQuery`.

## AV-13 — application identity and entitlements

Run the focused suite from the actual app context with stable bundle identity on a user-selected root outside an app-owned ubiquitous container. Record API authorization errors separately from provider/network errors. Retain one release-signed smoke test; provider behavior does not depend on parsing signature identity.

## AV-14 — copy-on-write Keychain cutover

Retain the existing focused matrix: fresh add, exact read-back/KDF validation, target checkpoint installation, old-item deletion after commit, Save-As source independence, crashes at every boundary, duplicate account, denied access, malformed bytes, read mismatch, deletion failure, and two independently openable destinations.

## AV-15 — local WAL bookmark and directory durability

This is primarily a deterministic Foundation/filesystem contract, not a provider contract. Validate:

- user-domain Application Support lookup and the exact `Notational Velocity/Recovery Journals` child;
- restrictive directory/file permissions and non-following of malicious symlinks;
- bookmark resolution after root rename/move, stale-bookmark handling, copied root, deleted root, unavailable volume, and permission failure;
- resolved directory identity comparison rather than bookmark/path equality;
- file and directory barrier behavior across header creation, append, checkpoint verification, WAL deletion, process `_exit`, and machine restart;
- unrelated/malformed WALs remain untouched and never become authority for a selected root.

## AV-16 — root-directory lock contract

The adopted design locks the already-open root-directory descriptor before WAL discovery and retains its owner through local cleanup and observer/operation teardown. It creates no provider-visible lock file and does not substitute a per-session WAL lock. Apple's [`flock` contract](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html) provides advisory object locking, not pathname reservation, provider coordination, or a cross-Mac lease. A directory recreated at an old pathname is a different lock resource and remains subject to the existing positive-continuity fence.

The [directory-descriptor probe](IntegrationTests.md#root-directory-descriptor-lock-probe) checks independent-process contention and descriptor lifetime, including rename/move, child replacement, and process death. All local contenders opening the same directory must address the same exclusion resource regardless of their WAL IDs. `JournalLifecycle` and `QuitSafety` check NV's abstract retention/release ordering; they do not prove platform behavior.

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

## Existing focused harness evidence

`tests/ICloudAPIContractTest.m` already supplies LaunchServices app-context provider probes, two-Mac host/peer mutation, simultaneous conflict generation, current-item materialization, shallow catalogs, batch reads, root moves, Spotlight independence, and historical observations. Retain those useful modes while changing the required policy:

- the previous all-version AV-05 fence and identifier migration results become exploratory only;
- the simultaneous-conflict setup should feed the new unresolved-version immutable-read/disposition test, including one-member and snapshot-wide `resolved = YES` behavior;
- exact current checkpoint replacement should feed a `NVCheckpointInstallCurrentChanged` test that decodes complete note sets, infers deletion only relative to the exact base, unions retired deterministic identities, ignores competing preferences/other database metadata, and rejects another replacement before retry;
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
- a generic `NSDataWritingAtomic` replacement removed the UUID on both systems (`ENOATTR` on the installed replacement), so an NV replacement must put the UUID on its prepared replacement before installation rather than depend on destination metadata preservation; and
- both systems disclosed both bodies for all eight simultaneous-write conflicts. A follow-up eliminated the initial write/restamp interval by putting the UUID on each staged replacement before one coordinated Foundation installation; half used default replacement metadata handling and half used `NSFileManagerItemReplacementUsingNewMetadataOnly`. All eight current files retained their UUID, but zero conflicts exposed it on both body-bearing versions under either replacement mode. Only the current winner's body exposed the UUID. `NSFileVersion.URL` must therefore not be assumed to carry branch-specific custom xattrs.

These observations support a syncable UUID only as optional current-file identity evidence. They do not authorize UUID-based current-file deletion, identify historical resolver members, or make a missing/malformed/duplicate xattr destructive evidence. UUID xattrs remain outside the normative design unless the specification and ADR-0014 explicitly adopt that policy.

On iCloud Drive, the 1,000-item macOS 26/macOS 14 run returned the complete initial and mutated catalogs while all 16 explicitly evicted sample bodies stayed unmaterialized. The focused empty/small double-catalog fence also detected coordinated create, edit, rename, and delete on both systems. The real simultaneous-edit run disclosed both bodies for all eight files, and the required per-member disposition sequence passed. The edit/delete run exposed zero of eight edited bodies as Current or unresolved on either host after deletion won; this establishes only the current-visible ceiling, not provider-side destruction. Foundation replacement and AV-15 local barriers passed on both OS versions. On both, a same-bytes Foundation replacement kept the current `NSFileVersion.persistentIdentifier` equal while the filesystem witness changed; different replacement bytes were returned coherently. Identifier equality is compatible with Apple's same-version lookup contract and is not interpreted as a replacement-generation guarantee. The retired reverse-domain attempt failed on both versions as recorded under AV-08 and is no longer part of the regular suite.

Content-free diagnostics remain mandatory: OS build, operation ID, item count, phase, status enum, and error domain/code only. Never log paths, filenames, note text, bookmarks, provider identifiers, or account identity.

## Real-system matrix

Run first-class ship conditions on macOS 15 and the current release, using two Macs on one iCloud account where ordering matters. Run the legacy-root-WAL migration on the oldest supported macOS. Repeat provider membership, current catalog, move, and optional unresolved-version cases with current Dropbox and one additional File Provider as best-effort observations.

Minimum faults:

- online, offline, reconnecting, and account transition;
- Optimize Mac Storage on/off with current files and directory evicted;
- remote mutation before the first catalog, between catalogs, after the second catalog, and before callback visibility;
- current checkpoint replacement before the quit CAS and again before its one permitted retry;
- provider daemon restart and app crash at every accessor/completion boundary;
- root moved, copied, deleted, replaced, revoked, and unavailable, with only positive same-root evidence restoring publication and no automatic loss classification;
- local WAL append/barrier/directory-sync failures independently of provider state;
- normal quit, explicit override, local checkpoint ambiguity, and next-launch recovery.

An API/OS result is accepted only when the required condition is demonstrated, not because Finder eventually appeared correct.

## Relationship to TLA+

The migrated startup, creation, replay, quit, decision, and storage-transition models consume the same confirmed boundaries: positive association/classification, truthful local synchronization, complete current snapshots, exact full checkpoint witnesses, and independently validated Keychain items. They assume neither provider progress nor historical completeness, cross-machine version identifiers, reverse lookup, UUID xattrs, or atomic Keychain/checkpoint cutover. Same-bytes replacement may invalidate the filesystem component while the current persistent identifier stays equal. Their negative-control runner mutates synthetic TLA+ models only; it is not another live Apple contract test. Byte-level recovery, real crash persistence, and production callback/admission wiring remain integration obligations.

The executable `ReconciliationDurabilityBridge` and `StorageStartupBridge` carry actual model payloads through those boundaries and reopen crash-surviving artifacts using the startup actions. Their same-bytes replacement event changes the full local witness, not a presumed provider generation counter. They neither require an old process's success acknowledgement to survive a crash nor infer successful decryption, root association, provider-format compatibility, or upload from that acknowledgement. Fresh concrete validation still supplies each API/decoder fact; failures remove the applicable success path. Their witness traces demonstrate reachable reopen paths, not provider liveness.

The active models begin after Apple/Foundation supplies the environmental inputs above. `CurrentVisibleReconciliationSafety` consumes complete current catalogs and immutable selected current snapshots. `UnresolvedVersionResolutionSafety` consumes only the snapshot Apple disclosed for one visible file, exact local-install results, retired deterministic copy identities, and truthful later unresolved queries; it assumes no historical completeness. `CurrentCheckpointNoteMergeSafety` consumes exact retained/live/current complete note sets, retired deterministic identity sets, and exact current-version equality for the retry. `CrossMachineCurrentVisibleSafety` composes two hosts with independent current-file/checkpoint delivery and exposes displaced-current retention as a configuration constant rather than hiding it in the algorithm. `LocalWALSafety` consumes truthful local append/checkpoint/directory-durability results and contains no provider action capable of deleting a WAL.

If an environmental input cannot be established, the implementation removes the corresponding success transition and retains dirty/evidence. Models for historical completeness, automatic/provider-wide resolution, shared journals, and upload-qualified cleanup are retired with their superseded design.

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
