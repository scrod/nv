# P5.0 — Initial caller and authority inventory

Date: 2026-10-13. Scope: P5.1–P5.5; extend this inventory as physical
read, installation, discovery, coordination and repair consumers land.

The [overall architecture](../phase5-provider-root-implementation-plan.md#whole-system-architecture)
assigns ownership, transaction, scheduling and failure responsibilities. This
inventory records the source boundaries that implement or precede them.

| Actual source / caller | Intent, issuer and consuming boundary | Execution / captured context | Durability / lifetime |
| --- | --- | --- | --- |
| `Database`, `DatabaseLane`; `nv_storage_owner_open` | Exclusive private collection ownership and keyed database access | Existing dedicated local executor; store/connection/selection context | SQLCipher acceptance and materialization retain their separate transactions. Database final disposal releases the private owner on its executor. |
| `StoreSelection` / `SelectionLease`; `nv_selection_*` | Expected-current activation of a verified private replacement | Existing selection owner; exact prior record, stage and replacement identity | File/directory barriers and checked activation; owned old/stage handles survive failures. Foundation migration remains a later separately qualified backend. |
| `RepositoryCopyWorker`, `RepositoryLease`; `nv_repository_open/create` | Preserve available source bytes into a fresh destination | Existing copy executor; source observations and fresh destination ownership | Source opening is path-validated read acquisition; destination creation obtains its directory-object lock. Each copy verifies identity/bytes and synchronizes the destination. This remains the Phase 4 copy path. |
| `RepositoryLease.install`; `nv_repository_install` | Exclusive creation in a fresh copy destination | Existing captured-copy inputs and destination lease | Existing fresh-copy behavior remains distinct from the staged complete-object installer below. |
| `LocalStoreSession.captureRepositoryHistory`, `retainedObject(at:)` | Exact accepted history for copy versus one accepted-object lookup | Existing local database/history resources; accepted prefix and protection context | Captured history is a complete copy input. Routine publication needs bounded indexed selection rather than rebuilding that whole array per save. |
| `LocalStoreSession.receive` and ready-work draining | Retain, park, validate and accept exact incoming objects | Existing receive reservation, history worker and database turns | Atomic bytes/membership/edges/frontier/wakeups; durable blocked/rejected work and verification obligations. P5.3 supplies actual file-discovery input. |
| `LocalStoreSession.publish` | Checked headless current-row publication | Existing database lane and final store/history/view checks | A successful synchronous callback permits existing optional background work. AppKit adoption remains Phase 7. |
| `NVRootedDirectory` snapshot, catalog, create/replace/rename/remove callers | Legacy intent-specific rooted observations and effects | Retained descriptor; expected snapshots and displaced-byte evidence where applicable | Existing capability ladders and file/directory synchronization. Keep legacy callers intact; new immutable installation and Foundation replacement have separate qualification gates. |
| `PrivateRepair`, `CollectionCopies`, `PrivateBackup` | Validated union, source-preserving copy and consistent private backup | Existing owners, captured prefixes and independently verified replacements | Preserve unique history/private inputs; selection activation follows verified reopen. P5.6 connects production provider acquisition/reassociation. |
| **`RepositoryRootSession`, `RootLane`, `RootLease`; `nv_root_*`** | **New P5.1 live physical root owner and metadata read consumer** | **Actor-isolated control, separate dedicated executor, session/generation permission** | **Continuous directory-object flock; explicit close stops admission before entered work settles. Resource disposal runs on that same executor.** |
| `ImmutableRepositoryObject/Locator`; `RepositoryRootSession.read/list/install`; `NVRepositoryFiles.c` | P5.2 checked sealed input, bounded discovery/read and complete-stage exclusive immutable installation | Same root owner/executor; restricted observation/cursor/installation issuers, final session/generation/object consumers | Exact verification and file/nested-directory barriers; preserved collision/uncertain input; owned stage/stream disposal. P5.3 separately supplies accepted-history publication eligibility. |
| `captureRepositoryPublication`, `RepositoryRootSession.publish/validate` | Bounded accepted-prefix capture → exact immutable installation → checked physical result | Store/session-bound immutable batch/cursor; local SQL turns finish before independent root effects | Direct accepted dependencies, retained descriptor, exact bytes and prefix are checked before capture. Physical completion remains separate from local-save acknowledgment; next-pass progress follows successfully handed-off batches. |
| `RepositoryRootSession.discover/validate`, `receiveWithIdentity`, `BootstrapCandidate.retainWithIdentity` | Bounded nested observations → actual durable receive/bootstrap → live-consumer applicability | Root reservation precedes suspension; parent/child streams retain bounded progress; immutable turn binds root and target owner | Queue owns handed-off input across missing callbacks/restart. Ordinary opportunities revisit early empty passes. Existing private accepted-file hints preserve unchanged read work across reopen, with fresh observations and accepted membership. |
| `RootLease.coordinatedRead`, `withCoordinator`, `checkedRelative` | Actual metadata or immutable-body read within a synchronous Foundation accessor | Fresh owner-presenter coordinator on the root executor; accessor URL is compared physically to the held root; CF file reference follows same-object moves | Copied observations/bytes leave the interval before SQL/crypto. Metadata uses `immediatelyAvailableMetadataOnly`; body reads use `withoutChanges`. Final session checks fence delayed results. |
| `RootLease.init`, `NVAppleCreateRootReference` | Bind a system-issued Foundation reference to the continuously held native root | Descriptor alias first; an unusable alias may use the selected path only after positive native comparison, followed by comparison of the resolved reference | Scope remains the root executor. Ordinary HFS+ uses the checked path candidate; fresh deep-HFS+ opening has the approved explicit safe-refusal limitation, qualified separately from already-owned deep moves. Failure grants no uncoordinated effect or replacement-root authority. |
| `RootLease.install`, `nv_root_make_directory/prepare_owned_stage/install_owned_stage` | Separate exact-directory creation, private stage write and two-URL immutable installation | Each effect has its own synchronous grant; final source uses `forDeleting`, destination uses ordinary writing. A noncopyable root-executor lease retains the verified stage descriptor between grants | Exact bytes, held identity, named source and all final barriers are rechecked. Metadata-only provider changes preserve the binding; body changes/displacement preserve retry evidence. |
| `RootPresenter`, `RootCoordinationControl` | Presenter hints/replies and the documented cross-thread cancellation capability | Independent serial presenter reply queue; two small NSLock-protected state cells. Actor lifecycle and generation remain the admission authority | Prompt replies and reacquisition are separate. Cancellation fences results; entered work retains its handles/capacity until actual return. Close unregisters and settles queued presenter work before releasing the native root. |
| `RepositoryTransportDriver.start/revisit/stop`, root/store notifications | Initial passes, local settlements, hints, monotonic revisit, explicit refresh/revalidation and close | One actor-owned worker, one cancellable wakeup and tokenized root/store observer attachments; reservation precedes suspension | Exact incomplete batch survives fencing; exhausted attempts retain their error. No persistent transport queue. Owner readiness is checked after registering a wait. |
| `RepositoryRootSession.availability/requestMaterialization/providerObservation` | Selected metadata/materialization and optional forward identity | Copied issuer-bound values; actual metadata interval, then final generation/root checks. Async provider lookup leaves the root lane free | A request/status is supplemental; exact read proves usable bytes. Unknown/unsupported lookup grants no root continuity, absence or Work Offline authority. |
| `CollectionSession.open/decision`, `CollectionRecoveryRequest` | P5.5 complete private open joined with independent root acquisition and scoped recovery dispatch | One actor owns the attempt, store, root/acquisition and closed startup phase; actual opener and root observations produce the decision | Complete local recovery precedes editing. Provider unavailability preserves healthy local publication; missing association requires explicit binding. P5.6 requests describe required effects rather than completed repairs. |
| `CollectionSession.preparePublication/publish/capture/persist` | Integrated startup admission and issuer-bound host publication / ordinary saved actions | Restricted prepared/captured values bind owner and attempt, alongside existing store/history/view/live checks; in-flight reservation spans the callback | The synchronous checked callback settles before publication is declared successful or ordinary transport is enabled. Matching capture/commit generations preserve newer pending work. Lower-level `LocalStoreSession` remains a separate local-storage boundary. |
| `CollectionSession.considerProviderObject/workOffline/requestWaitingBytes`; named driver input | Exact initial unread disclosure, local membership and complete-health checks issue/consume the narrow Work Offline choice | Same live physical root and attempt; original disclosure can remain applicable while an entered accessor makes a fresh read busy | One bounded named attempt retains input through exhaustion, close and late settlement. Work Offline grants local admission only. Publication and attaching-worker settlement both revisit the existing handoff reservation. |
| `CollectionSession.retryRepository/reopenRepository/resumeReassociation/close` | Fresh same-root permissions versus explicit physical reassociation | One transition freezes expected association generation and owns source/target resources before suspension; SQL binding is read back after ambiguity | Existing association SQL determines committed versus unchanged state. Old entered work retains its original resource through actual return; stale callbacks cannot retarget. Close joins owned acquisition, transport and store settlement. |
| `CollectionSession.create`, `CollectionBootstrapSession.open/resume/discover/preview/complete`; `activateFreshSelection` | Explicit exclusive creation or selected incomplete bootstrap, complete read-only preview, then durable editable reopening and verified selection activation | Selected descriptor/profile/key/snapshot and exclusively owned destination; preview evidence has a restricted validator issuer | Initial import retention/acceptance uses existing SQL boundaries. Normal reopening can retry the same committed snapshot. Selected-store activation reuses expected-current `VerifiedReplacement`/`SelectedStoreOwner`; foreign occupants and partial input remain preserved. |

## Selected first boundary

Keep the first root owner in `NVStorageRuntime`. It reuses `StorageExecutor` and
its synchronous final-disposal pattern, with a distinct queue for root effects.
Core remains portable. The Darwin coordination/presenter bridge is an internal
conditional Objective-C target. It preserves system-issued NSURL/CFURL behavior
across Swift and owns the synchronized presenter snapshot. Permission
constructors remain within Runtime.

`RepositoryRootPermission` is issued only by the owning session. The read consumer
checks session, generation and lifecycle before entering and again after returning
from the blocking lane. `RepositoryEntryObservation` copies entry kind/size and
local identity from that read. P5.2's byte/list/install consumers have their own
restricted evidence and context checks. Logical collection association and private
accepted-history publication are subsequent consuming boundaries. The metadata
reader issues copied observations.

The root owner retains a directory descriptor/local identity, a descriptor-bound
loss-event resource and latched loss result, an actor-owned session/generation/
lifecycle and one in-flight reservation. Quiesce fences admission and joins entered
work while retaining the lock; explicit close releases the physical owner.
The settlement turn explicitly checks the root execution resource, giving it an
observable queue boundary in optimized builds as well as debug builds.
Ownership creates no child file. A retained descriptor addresses its original directory
after a move; explicit candidate comparison can fence a different directory at
the old path. These locks exclude cooperating local processes as specified in
[ADR-0006](../../../adr/0006-retain-positive-association-and-directory-ownership.md).

## Harness reachability and next gates

Native tests hold the actual root executor immediately before its C read, while
the production local-store API saves and reopens both profiles. The existing probe
executable exposes pipe-confirmed root acquisition, observations, invalidation,
quiesce and close. A separate Python process controls moves/replacements and takes native
descriptor locks independently of Runtime success flags. Compiler probes compile
both ordinary clients and clients in the actual Runtime module; isolated mutations
challenge real guards. The C qualification injects unsupported locking beneath
the production acquisition path, injects event-resource failure after locking,
and checks exact final closes and descriptor baselines under sanitizers. The
volume driver forces detach/remount of its own temporary disk images and checks
fencing, fresh ownership and preserved bytes independently.

P5.2 adds exact bounded byte reads, protocol-scoped enumeration, staged
exclusive immutable installation and independently checked persistence-loss
rules; see its [qualification](02-immutable-files-validation.md). P5.3 connects
those effects to private accepted-history publication/receive. P5.4 qualifies
actually entered Foundation accessors, copied platform observations, presenter
teardown and materialization within its recorded capability limits. P5.5 joins
them to startup and durable physical reassociation; its
[execution record](05-startup-and-root-reassociation-validation.md) identifies
the qualified consumers/process cuts and later capability/distribution gates separately.
P5.6 supplies repair/copy effects and Phase 7 supplies application/UI adoption.
