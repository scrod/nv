# P5.5 — Startup decisions and explicit root reassociation

Updated: 2026-10-13.

Status: production headless implementation and qualification are complete within
the recorded capability/distribution limits. The
[execution record](05-startup-and-root-reassociation-validation.md) separates
passing component reruns from earlier incomplete aggregate campaigns.
Dependency: [P5.4](04-apple-coordination-and-discovery.md), within its
[qualified capability and distribution limits](04-apple-coordination-and-discovery-validation.md).

Testing: [startup/create/replay families](../phase5-provider-root-testing-plan.md#restart-classification-and-rejected-work),
P5-ROOT and S3/S5. Follow the specification's
[startup table](../../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state),
[repair classification](../../../iCloud-Drive-Support-Spec.md#repository-and-private-store-damage-and-repair)
and [transition rules](../../../iCloud-Drive-Support-Spec.md#root-events-shutdown-and-transitions).
This part exposes headless decisions; application presentation remains Phase 7.

## 1. Outcome and scope

Connect the existing private opener, bootstrap receiver and physical root owner:

**Normal selection/unlock → classified evidence → required local recovery →
checked complete publication → independent transport.**

Then connect Retry of the retained resource and explicit Re-open of a selected
resource. Complete each increment below through executable production-consumer
tests before expanding it.

Apply the [conformance strategy](../swift-storage-conformance-testing-strategy.md)
and [Swift boundary proposal](../swift-storage-library-proposal-v2.md). Read the
policy above with [ADR-0002](../../../adr/0002-require-an-acceptable-startup-store.md),
[ADR-0005](../../../adr/0005-separate-startup-cache-private-state-and-visible-history.md),
[ADR-0006](../../../adr/0006-retain-positive-association-and-directory-ownership.md),
[ADR-0016](../../../adr/0016-repair-from-validated-immutable-copies.md),
[CONTEXT](../../../../CONTEXT.md#9-authority-repair-and-transitions) and the
[active-model guide](../../../tla/README.md). Check AV-01/02/08/09/13/15/16 in the
[Apple API ledger](../../../Apple-API-Contract-Validation.md) for observation,
materialization, root continuity and ownership assumptions.
Selected-store activation also follows the expected-current caller contract in
[Foundation safe replacement](../../../Foundation-Safe-Replacement-Migration.md#caller-scope-under-proposal-5);
private association/current rows remain SQL transactions and immutable provider
objects retain exclusive installation.

P5.5 implements headless startup/association decisions and their consumers.
P5.6 implements repository repair/replacement/copy effects. Phase 6 implements
plaintext-file reconciliation; Phase 7 implements AppKit presentation, the actual
application admission predicate and quit/folder-switch adoption. Preserve epoch-4
opening/recovery/export, existing editing behavior and synchronous search.

Both profiles participate throughout. Private pages use SQLCipher in both;
provider objects follow their pinned public/encrypted profile and zstd codec.
Reuse existing key derivations/unlock inputs. Password-free recovery remains
independent of Keychain and separately held secrets.

## 2. Adopted policy to implement

1. Implement a closed decision boundary over observed root/provider/private-store
   health. Keep continuity/ownership, entry kind, access/materialization, exact
   identity/authentication and required closure separate. Attach context/generation
   to observations and revalidate before their effects. Provider failure alone
   does not close a healthy local edit gate; local durability/ownership failure does.
2. Connect returning open to existing required-state checks, indexed required-work
   draining/catch-up and one consistent checked current-row capture. Independent
   optional snapshots remain background work after successful publication. Known
   accepted-history damage and unfinished verification requests retain their
   required path; invalid derived rows use reconstruction, preserving private state.
3. Implement Work Offline eligibility exactly: before initial editable publication,
   positively disclosed named newer/required provider evidence is unread and not
   retained locally, while the existing local closure is complete and usable.
   Offer proceeding from that local closure or Save Current Collection As….
   Do not wait for discovery just to determine whether to offer it. Generic
   offline/full/access/coordination errors and evicted copies already retained
   locally do not qualify.
   If an entered provider accessor makes fresh readability checking busy, allow
   the original exact disclosure to release local editing after freshly checking
   local health and the same live root/attempt. Preserve the pending evidence;
   this grants no provider-write permission. Stale-root and unhealthy-local
   companions must reject the choice.
4. Keep later disclosed history pending without revoking healthy editing. Bound
   materialization attempts and expose accurate sync/retry status. Work Offline
   does not reinterpret delayed evidence as absent or grant permission to overwrite
   it; known root contention is not bypassed. Repair-required outcomes dispatch
   to P5.6 rather than falsely reporting a repaired repository.
5. Connect explicit fresh collection selection to P5.3's descriptor/bootstrap path.
   Retain incomplete genesis/import/page/history input. A read-only snapshot preview
   requires every bounded named page/count/digest and complete displayed value;
   editable publication requires durable complete initial import and stated
   history closure. Existing empty/unavailable directories never initialize
   silently; concurrent unrelated bootstraps require explicit selection.
6. Connect Retry and Re-open to the owner lifecycle. Retry rechecks the existing
   retained session/evidence. Re-open supplies an explicit new physical association,
   fences/quiesces old work and independently acquires the selected resource.
   Preserve still-running accessor resources until actual settlement; a new
   association cannot inherit old effect permission. Save As delegates to P5.6.
7. Reconstruct missing private state through the adopted fresh-Mac association/
   recovery path. Allocate fresh local-store/writer/origin context where required;
   revalidate credentials/ownership. Portable history/Undo remain available from
   validated action records, while physical receipts require fresh validation.
   Use the existing key lifecycle, including password-free recovery without Keychain.

Fresh deep-HFS+ acquisition has the approved explicit capability limitation.
Preserve its safe unavailable result, repository bytes and healthy private editing;
qualify ordinary HFS+ access and already-owned deep moves separately. This adds
neither a blanket path-length limit nor Work Offline eligibility. Retry or explicit
relocation/reassociation must positively establish authority before root effects.

Use [LocalStore's launch algorithm](../../LocalStore.md#concrete-returning-launch-algorithm)
and current Runtime opening/publication fences. Final application association
cutover, dialog wiring and quit/folder-switch orchestration remain their Phase 7
consumers. A headless status result must clearly distinguish usable local state,
pending provider work, required recovery and an unsettled transition.

## 3. Source responsibilities and language boundaries

Reuse these production boundaries rather than adding another store or receive queue:

| Existing source | P5.5 connection |
| --- | --- |
| [StorageHealth.swift](../../../../NVStorage/Sources/NVStorageRuntime/StorageHealth.swift) | Extend phase-scoped diagnosing results into the shared classifier. Namespace probes are diagnostic observations; the owned opener establishes usable local state. |
| [LocalStore.swift](../../../../NVStorage/Sources/NVStorageRuntime/LocalStore.swift), [CurrentRows.swift](../../../../NVStorage/Sources/NVStorageRuntime/CurrentRows.swift) | Journal/header/private checks, verification replay, required leaves, reconstruction, required ready work, indexed catch-up and checked opening capture. |
| [Publication.swift](../../../../NVStorage/Sources/NVStorageRuntime/Publication.swift), [ReceivedObjects.swift](../../../../NVStorage/Sources/NVStorageRuntime/ReceivedObjects.swift) | Final view/prefix/live checks, successful-callback optional-worker reservation, exact retention/waits/rejection and recovery. |
| [RepositoryRoot.swift](../../../../NVStorage/Sources/NVStorageRuntime/RepositoryRoot.swift) | Physical acquisition/comparison, issuer-bound availability/materialization, permissions, presenter and actual resource settlement. |
| [RepositoryDiscovery.swift](../../../../NVStorage/Sources/NVStorageRuntime/RepositoryDiscovery.swift), [RepositoryTransport.swift](../../../../NVStorage/Sources/NVStorageRuntime/RepositoryTransport.swift) | Bounded real intake, grouped accepted hints, retained publication batches and existing retry/resumption. |
| [BootstrapConstruction.swift](../../../../NVStorage/Sources/NVStorageRuntime/BootstrapConstruction.swift) | Retain/resume the selected incomplete commitment; complete it through existing validation/acceptance and normal reopening. |
| [PrivateState.swift](../../../../NVStorage/Sources/NVStorageRuntime/PrivateState.swift), [PrivateRecordsV1.swift](../../../../NVStorage/Sources/NVStorageCore/PrivateRecordsV1.swift) | Generation-checked association/settings and passive bookmarks; existing required pin, pending buffers and operation links. |
| [StoreSelection.swift](../../../../NVStorage/Sources/NVStorageRuntime/StoreSelection.swift), [PrivateRepair.swift](../../../../NVStorage/Sources/NVStorageRuntime/PrivateRepair.swift) | Verified-candidate/selected-record activation when a fresh store is required; P5.6 connects damaged-source repair effects. |

Add one small integrated startup/association owner in Runtime, with a suggested
`CollectionStartup.swift` for control state and evidence issuers. Split transition
code only where it clarifies ownership/access boundaries. Names below describe
responsibilities rather than freezing a new public API or wire format. Keep the
bookmark/platform adapter at the existing conditional Darwin seam.

Use exhaustive health/startup/transition enums rather than booleans whose
combinations admit contradictory choices. Separate observation values from
edit/effect admission, with restricted factories and consuming context checks.
Reserve a transition before suspension; invalidate stale observations, prepared
values and callbacks together with the affected session generation.

Reuse existing association/private-state records and retained-history pin.
Transitions do not add a durable restoration-consent flag or permission ledger.
Matching collection IDs identify possible history, while the root owner establishes
current physical authority. Required history loss is not derived-row damage.

Keep observations composable along their independent axes; a closed decision
selects a usable local session, read-only preview, scoped wait, recovery/unlock,
contention or unsettled transition. Associated values own each case's required
inputs. Avoid a state for every Cartesian combination of observations.

| Evidence responsibility | Restricted issuer | Actual consumer requirements |
| --- | --- | --- |
| Locally ready startup basis | Successful owned opener and required recovery | Store/connection incarnation, bootstrap/profile/key, accepted/materialized prefix, view and lifecycle. |
| Named unread provider disclosure | Root observation adapter plus selected-context/local-membership checks | Exact item/version, root/attempt generation and evidence absent from the usable local closure. Raw status alone is insufficient. |
| Read-only bootstrap preview | Complete bounded snapshot/page/value validator | Selected collection/profile/key and preview generation; immutable preview exposes no edit/commit capability. |
| Work Offline choice | Integrated owner joining ready local basis and applicable disclosure | Initial-publication phase, same attempt/selection, surviving complete local closure and current named wait. |
| Prepared publication | Existing checked capture/reduction plus integrated startup state | Final store/view/prefix/presentation/live and applicable root/lifecycle generations; one synchronous publication/admission decision. |
| Reassociation preparation | Transition owner after explicit selection and independent target checks | Source/target ownership, association/selection generation, pending-work accounting and lifecycle at durable binding/adoption. |

Use private/file-private constructors beside the actual issuer. Keep passive
persisted records decodable as inputs; live authority is freshly established.
Provide no public raw/memberwise initializer, synthesized `Decodable`, mutable
evidence setter or production test factory for ready/choice/transition evidence.
Approval methods consume issuer-bound choice context and recheck applicability.

Actor-isolate the new control state. Reserve before suspension and recheck after
each completion; SQL and root work retain their independent dedicated executors.
Native handles/Foundation objects stay inside audited adapters. Use `~Copyable`
only for unique ownership that simplifies code; immutable observations/history
remain shareable. Preserve Swift 6.4+, Swift 6 language mode and strict memory-safety
warnings as errors; avoid expanding unsafe/concurrency exceptions.

The integrated owner holds the newly opened session until its startup decision
allows publication/admission. Every new integrated command/publication entrypoint
must enforce that decision. Existing low-level `LocalStoreSession` APIs establish
local storage readiness, not proof that the combined provider-startup decision
occurred. Inventory both boundaries rather than claiming a wrapper automatically
protects every lower-level call.

Minimum additional state: selected context, lifecycle/attempt generation, applicable
existing store/root/candidate handles and one owned wait/transition. Reuse transport's
worker, demand, timer and settlement notifications. Each new field needs a producer,
consumer and removal condition. Persist through existing association/selection,
history/pin, pending and verification records; add no durable Work Offline flag,
restoration consent, permission ledger, outbox, copied allocator or startup cache.

## 4. Dependency-ordered increments

### 5.5A — Closed observation-to-decision boundary

1. Freeze literal fixtures for every row in the normative startup and both repair
   tables. Record input facts, choices, local admission, provider effects and the
   responsible P5.5/P5.6/later consumer. Include combined local/provider failures.
2. Adapt actual opener/root results into the classifier, preserving failure phase,
   error domain/code, continuity/ownership, non-followed kind, access/residency,
   exact format/key validation and closure. A database unlock/read failure remains
   ambiguous until independent evidence resolves it; never infer corruption from
   `SQLITE_NOTADB` alone.
3. Use a small deterministic decision function. Cause labels such as user deletion,
   restore or provider glitch never participate. Distinguish initial publication
   from an already editable session; preserve known contention/refusal without
   substituting private ownership or Work Offline for the contended resource.
4. Return scoped unlock/recovery/repair/reselection/Save As requests. A P5.6 request
   is `repair required`, not completed repair. Missing same-root NV Data entries
   follow automatic add-only repair; occupied damage stays in place and offers
   Save As. No Restore control is added.

**Gate:** literal table plus real diagnostic-to-decision-to-consumer companions
pass. Equal observations from different causes yield equal decisions. Contradictory
inputs fail closed in their proper scope instead of acquiring favorable authority.

### 5.5B — Returning open and complete first publication

1. Feed normal selection/unlock inputs to the diagnosed opener. Revalidate the
   active-store locator against the owned store/association. Passive bookmarks
   supply candidates, followed by independent physical checks; equality of their
   bytes/path alone cannot establish root authority. A missing association on the
   integrated returning path requires explicit reassociation, not attachment from
   a valid header/current view. Standalone local fixtures retain their narrower
   existing opening contract.
2. Schedule root acquisition/metadata independently. Consume relevant disclosures
   already available when startup makes its decision. An unfinished provider
   accessor, catalog or forward lookup is not a new mandatory launch dependency;
   later disclosure uses the already-editable policy.
3. Reuse LocalStore's launch sequence: journal/header/private checks, verification
   replay, required leaves, invalid-materialization reconstruction, required ready
   Changes/prerequisites, indexed catch-up and one complete consistent capture.
   Required queue selection remains independent of optional-entry order.
4. Reuse the opening capture once, with its zstd dictionary and current-cell
   checks. Compose the integrated startup gate with existing final owner, prefix,
   view, presentation and live-generation checks. A changed target recaptures/
   catches up; it never publishes stale editable values.
5. After the actual successful `publish` callback, preserve existing optional
   receive reservation/coalescing. Attach one applicable transport driver after
   selected association/root/startup state permits it. Bootstrap reading may gather
   inputs earlier without granting active publication authority. A callback that
   throws is not successful startup or background handoff.

Reserve final publication against association adoption through callback settlement.
Use the existing synchronous checked callback and a serial headless host generation;
do not synchronously hop between actors or read actor state from the SQL callback.
Competing transition requests must settle/cancel the applicable publication before
adopting another selection. Root-only unavailability still leaves a healthy local
capture usable. Phase 7 adds its actual main-thread host fence; the headless witness
must accurately describe the narrower callback contract it exercises.

**Gate:** fresh exec publishes independently expected complete notes, deletions
and body-equal authoring-context changes. Required work/verification block success
when held; independent optional work/provider enumeration do not. Releasing finite
interference, with no new delivery, produces background progress.

### 5.5C — Exact named waits and Work Offline

1. Join positive named-item/version evidence with selected collection context and
   fresh local retained membership. Download status alone, a sequence gap, upload
   result, empty listing or I/O failure cannot establish missing newer/required
   evidence. Keep locators and opaque version/generation observations distinct;
   use neither portable Apple IDs nor all-history enumeration.
2. Before first editable publication only, issue a scoped wait/Work Offline choice
   for applicable unread evidence absent locally while complete local closure is
   usable. On invocation, recheck owner, local history health, attempt, selection
   and disclosure applicability. Another store's valid choice is incompatible.
3. Work Offline releases that provider wait and uses normal checked publication.
   Retain named pending evidence. It grants no overwrite/repair/disposition/root
   permission. A restart reevaluates present facts rather than replaying the choice.
4. Reuse P5.4 bounded materialization/retry: request success is distinct from exact
   readable bytes. Exhaustion preserves pending inputs/status; normal hints or
   save settlement do not reset a persistent error's exhausted attempt. Explicit
   retry/useful positive revalidation follows existing policies.
5. Bytes arriving before choice consumption, a different selection or changed
   history requires reclassification. An unusable local closure requires recovery,
   not an offline override. Late disclosure never revokes healthy editing; readable
   validated history is eventually unioned through ordinary receive.

**Gate:** assert available choices and actual command admission, not only a
`canWorkOffline` result. Generic errors, already-local eviction, stale choices,
contention and incomplete local state cannot gain the option. A legitimately
editable local save completes while a real entered provider accessor remains held.

### 5.5D — Explicit creation, fresh bootstrap and private-loss entry

1. Separate open-existing, explicit-create-in-existing and exclusively-new-destination
   intents. Only exclusively new creation initializes silently within that operation.
   Empty/unavailable/foreign existing directories never implicitly choose Create.
2. Discover descriptor/initial-snapshot candidates through bounded P5.3 real intake.
   Pin the explicitly selected bootstrap/profile/key. Preserve unrelated candidates;
   concurrent unrelated genesis commitments require selection, not timestamp/name/
   arrival election or merging their imports into one collection.
3. Retain exact input/waits in `BootstrapCandidate`, resume the same commitment
   after failure and validate genesis/import/count/digest/ImportComplete plus all
   required dependencies. Complete acceptance precedes normal editable reopening.
4. Add the separately restricted complete read-only snapshot preview. Verify every
   named bounded page, category/count/digest and displayed value under the pinned
   context. Incomplete history can forbid editing even with a complete preview;
   missing preview pages cannot yield a falsely complete omitted-note result.
   Initial and general snapshot layouts retain their respective validators.
5. Total private loss requires explicit repository selection, a trusted writable
   Application Support parent and a fresh exclusively created local-store ID.
   Validate available keys/closure and establish a new association/pin. Surviving
   orphan/damaged/private-only input enters explicit recovery/P5.6 acquisition,
   rather than being silently discarded or overwritten.
6. Newly opened editable sessions use the existing fresh writer-epoch/action-origin
   allocation. Exact sealed retries keep their original identities/bytes. Rebuild
   portable History/Recently Deleted/Undo from action records; physical receipts
   need fresh validation. Lost native typing groups differ from durable history.

**Gate:** child processes use only surviving files and normal selection/unlock/
explicit choices. Complete durable bootstrap edits; complete preview with incomplete
closure stays read-only. Interrupted/competing creation never reports partial/empty
success. Erased undisclosed branches cannot be claimed recovered or detected.

### 5.5E — Retry and explicit Re-open

| Operation | Required resource checks | Outcome |
| --- | --- | --- |
| Retry | Recheck the retained session and freshly observed candidate; reuse continuously held ownership only on positive supported equality | Fresh permissions for the same object, or continued fenced/unknown/different outcome with local work preserved. |
| Re-open | Explicit selection, independently validated/acquired resource and target bootstrap/profile/key | New physical association, freshly issued permissions and no inherited old-root authority. |
| Save Current Collection As… | Delegate source/choice to P5.6's history-preserving copy/switch consumer | Honest deferred/required copy; current-state-only export remains separately labeled. |

Implementation order:

1. Reserve one transition with frozen source/target context before suspension.
   Fence affected integrated admission/result routing; account for owned local
   commits, receive input, private buffers and actual entered accessor resources.
2. Positively compare the explicit candidate with any retained owner. Same-object
   handoff reuses ownership with a fresh permission generation: no unlock gap or
   self-contention from reopening the same directory. A different selected root is
   independently acquired. Failed acquisition preserves the recoverable source.
3. Distinguish same-collection reassociation from another collection. The former
   may retain its healthy private store and every accepted/private input, updating
   the association under its captured generation. Compatible history unions normally;
   an older repository subtracts nothing. Another collection uses its own validated
   open/fresh store. Save-As-with-switch keeps P5.6's required fresh-store/writer path.
4. Finish admitted local barriers before owner release; failure keeps exact pending
   work and retry/recovery status. Retain incoming bytes/obligations and required
   private state. `LocalStoreSession.quiesce()` closes on success: use it for terminal
   teardown. Cancelable preparation uses a short-lived reservation, not reopening
   a closed actor or resetting its lifecycle by hand.
5. Commit a same-store association with `saveLocalAssociation` generation/scope
   checks; use verified-candidate/selected-record activation for fresh stores.
   Independently reopen/verify the candidate and usable unlock route, then recheck
   source/target ownership and expected selection before effect. That applicable
   durable binding/activation is the restart decision point. SQL and filesystem
   effects retain separate atomic boundaries; ambiguous completion requires record
   readback, never latest-file selection or a cross-resource atomicity assumption.
6. Publish/attach the selected generation only after those checks. Stop/detach old
   transport and fence late results. An entered accessor may finish its previously
   authorized effect on its original resource; retain resources until actual return.
   It cannot retarget, publish an old model, clear target pending work or acquire
   new permission. Report unsettled teardown accurately while resources remain held.
   Keep its transition/resource reservation until settlement; repeated requests
   coalesce or return busy before acquiring more owners. A stuck old accessor must
   not cause an unbounded sequence of retired roots/workers.
7. Cancellation before durable adoption preserves the source and releases only
   settled owned candidate resources. After committed/ambiguous effects, reconcile
   before reporting cancellation/success. Resume uses fresh applicable evidence.
   Final application adoption and quit orchestration remain Phase 7 consumers.

**Gate:** independent contenders prove continuous same-root ownership; inventories
prove replacements unchanged. Fresh exec at association/activation cuts observes
verified prior/committed state or explicit recovery. Identical collection bytes
in a selected copy never transplant physical receipts or old permissions.

### 5.5F — Connected qualification and handoff

Run the matrix below for both profiles. Extend the
[caller inventory](00-caller-inventory.md) with actual symbols, issuers/consumers,
execution resources, fault seams and durable decision points as they land. Record
completed evidence separately in `05-startup-and-root-reassociation-validation.md`;
link it only when executable results exist. P5.6/6/7 consumers remain visibly planned.

## 5. Scenario and independent-observation matrix

P55-* identifiers specialize the existing P5/TC contracts; they are planned test
labels, not new protocol records or currently accepted runner options. Each needs
a passing companion, actual contested-boundary entry, independent observations
and an intended mutation failure.

| ID / basis | Schedule and near-valid variants | Required independent observations |
| --- | --- | --- |
| P55-01 / START, REPAIR | Expand all normative startup/provider/private repair rows; equal observations from deletion, backup and provider failure; combined/contradictory inputs. | Literal expected classification/choices and actual admission/effects; cause labels never change decisions. |
| P55-02 / START, CKPT | Returning required Changes, Delete and body-equal context update; optional root before required entry. | Actual complete published notes/context, exact accepted bytes, expanded pin and waits. |
| P55-03 / START, WAIT | Hold optional verification across publication; repeat publication; stop saves/release without delivery. Required snapshot prerequisite and unfinished verification companions. | Publish precedes optional completion; one coalesced worker; required companions stay gated; eventual exact acceptance/current values. |
| P55-04 / PUB, ASY | Hold capture; accept history, rebuild at same numerical prefix, change live/presentation/selection or throw from callback. | Actual stale-consumer rejection and fresh recapture; no half model or false successful background handoff. |
| P55-05 / START, REPAIR | Valid rows with known pin damage/unfinished diagnosis; invalid rows/dictionary with healthy history; missing/corrupt/unsupported required state. | Distinct required-loss versus derived-rebuild outcomes; preserved settings/history/pending; failed diagnosis replayable. |
| P55-06 / START, AV-01 | Positive exact unread newer/required evidence before publication versus generic offline/full/permission/coordination/unknown/no disclosure. | Only positive absent-local conjunction offers Work Offline; invoking it publishes complete local closure and retains disclosure. |
| P55-07 / START, EVD | Disclosure after publication, already-local evicted copy, bytes arrive while choice held, local health or selection changes. | Healthy active editing continues; no redundant local-byte wait; stale choice reclassifies; unhealthy local state cannot be overridden. |
| P55-08 / LIVE, WAIT | Enter/hold materialization/accessor; bounded exhaustion/cancel; legitimate local edit, release/read/reopen. | Request differs from readable bytes; independent local barrier survives; bounded retry/accessor ownership; no premature overwrite. |
| P55-09 / ROOT, EVD | Independent root/private contenders; supplemental forward equal/changed/unknown/unsupported identity. | Explicit contention/refusal, separate lock ownership and no offline bypass; lookup alone grants no authority. |
| P55-10 / CREATE | Existing empty/unavailable/foreign directory versus explicit/exclusively new creation; race occupant. | No silent initialization/overwrite; valid create has exact committed count/digest/values and source preservation. |
| P55-11 / START, DUR | Independently deliver descriptor/genesis/import/completion/root/pages; missing/duplicate/repackaged dependencies; crash/resume. | Retained partial bytes/waits versus accepted membership; exact commitment completes once; fresh process has complete expected state. |
| P55-12 / START, CRYPT | Complete preview missing closure versus missing page/count/digest/value, wrong collection/profile/key or mandatory codec. | Only complete supported immutable preview succeeds; preview cannot admit edits; editable route requires durable bootstrap/closure. |
| P55-13 / CREATE, EVD | Unrelated bootstraps; vary arrival/name/time order; explicit selection changes during decode. | Separate identities, explicit selection, stale result cannot attach; order-independent permitted choices. |
| P55-14 / START-03, REPLAY | Total private/selection loss, surviving orphans, missing key and absent/hostile Application Support levels. | Explicit association, fresh store/pin/allocators where required; portable available history; preserved occupants and truthful incomplete recovery. |
| P55-15 / ROOT | Retry same-object/deep move; recreate old path with identical IDs/bytes; unknown comparison, revoke/detach/remount and latched loss. | Positive supported continuity only, continuous exclusion, no replacement effects or resurrected loss-latched owner. |
| P55-16 / ROOT, AV-13 | Fresh deep APFS; ordinary HFS+/HFSX/ExFAT; owned deep-HFS+ move/read; approved fresh deep-HFS+ refusal. | Supported companions succeed; explicit approved unavailable seam preserves bytes/local saves, with no blanket path limit or Work Offline fallback. |
| P55-17 / ROOT, ASY | Re-open while old accessor/result held; repeat/cancel transition; old success/error/hint after target adoption. | Single transition, resources held through return, no retarget/stale publication/duplicate detach/cleared target work. |
| P55-18 / ROOT, DUR | Reassociate same collection to older repository with unpublished/pending local/private work; another-collection companion. | No subtraction or mixed identity, exact local barrier before release, preserved buffers and independently validated target context/credentials. |
| P55-19 / REPLAY, HIST | Old backups; Delete/concurrent edit/fresh Restore in both orders; third branch or disposition. | Exact retained bodies/births, conflicts, Recently Deleted, source selection and Undo/Redo; fresh allocators and logical-once replay. |
| P55-20 / REPAIR, ROOT | Same-root owned NV Data omission/damage versus foreign/symlink/access/quota/positive unread evidence; simultaneous private failure. | Correct repair/preserve/fence dispatch, private-first sequencing, no fake repair success/Restore control/broadened permissions. |
| P55-21 / DUR, ASY | Fail/kill around binding, candidate verification, selection activation, publication/attachment and old release; second recovery failure. | Durable records determine prior/target/recovery; exact history/settings/pending survive; ambiguous outcome preserves source/candidates. |
| P55-22 / EVD, STATIC | Real evidence from another store/root/connection/attempt/profile/view; public/same-module construction, decoding and substitution. | Intended compile restrictions and actual context rejection before effects; matched real-issuer companions succeed. |
| P55-23 / CKPT, LIMIT | Fixed current values; 64/256/1,024 ordinary ancestors; sequential snapshots/independent tips; held listing. | Indexed healthy publication, specified required-leaf work, one checked current capture, no unrelated replay/provider-wide launch dependency; honest width costs. |
| P55-24 / PRIV, CLEAN | Unlock/access failures, canceled preview/transition, diagnostic sinks and repeated close cycles. | No encrypted-output/log plaintext/path/secret markers; password-free reopen without Keychain; settled resources return to baseline, foreign/retained evidence preserved. |

Require causal outcomes only after applicable evidence arrives. An old backup
may legitimately show older state before a previously undisclosed Delete.
Concurrent recoverable content and fresh restored births remain preserved. Actual
plaintext deletion/association and Apple-version disposition remain later callers.

### Connected schedules

1. **S3 — first publication:** complete local store; optional snapshot before
   required Change; held worker and finite saves. Publish after required work,
   exercise qualifying before/after disclosure, then make bytes readable without
   another delivery. Observe exact acceptance/context; repeat with required verification.
2. **S6 — reassociation with stuck work:** hold an entered old-root accessor, commit
   local save, move/replace/invalidate, Retry and explicitly Re-open. Release old
   work after target preparation/adoption as its settlement state permits. Inspect
   both physical roots, barrier, pending work, callback routing and lock lifetime;
   fresh exec afterward.
3. **S5 — rollback and third branch:** restore older evidence, reopen with fresh
   allocators, deliver Delete/edit/Restore permutations then a third branch/copy
   disposition. Check semantic results and reopen again; pair total private loss
   and missing-everywhere input without an impossible global-freshness claim.
4. **Two failures:** fail a private-state/verification write, kill after a reached
   effect, fail again during recovery, then healthy retry. Required inputs and
   obligations survive, unrelated valid work resumes and missing history is reported.

Start hand-scripted; sweep single faults across applicable cuts, then selected
second failures and bounded permutations (two writers, one/two notes, two/three
complete actions). Add targeted three-writer schedules rather than one universal
state-space product. Retain/minimize failure schedules and seeds.

## 6. Fault seams and recovery observations

Reuse completion controls, the C fault seam and SQL/VFS controls beneath the real
Runtime. Add narrowly named hooks only around new decisions/effects:

| Reached boundary | Challenge | Required result |
| --- | --- | --- |
| Diagnosed open / copied root observation | Permission/kind/context change, wrong credential, unusable reference | Scoped failure; no initialization or invented positive fact. |
| Required verification / ready drain / current capture | EIO/ENOSPC/busy, withheld prerequisite, changed prefix/view | Durable obligations retained; stale capture cannot publish. |
| Provider wait issued / choice consumed | Disclosure settles, selection changes, private health fails | Reclassification; no offline override of local durability failure. |
| Bootstrap retain / complete / normal reopen | Before/after SQL commit, lost completion, commitment mismatch | Partial input retryable; exact complete membership recovers once. |
| Association transaction / selected-record effect | Definite pre-effect failure, commit before callback, ambiguous installation | Durable record readback decides outcome; source and both candidates preserved. |
| Host callback / transport attachment | Throw, cancellation, reentrant request, close or competing transition | No false adoption/publication; one applicable attachment and generation-correct routing. |
| Old accessor return / detach / final release | Late/duplicate events and canceled close | Resources released at safe actual settlement; replacement untouched; independent contender succeeds only afterward. |

Bracket real effects; introduce no imaginary suspension inside atomic SQL commit
or rename. Separate definite no-effect failure, committed effect with lost callback
and ambiguity. An assertion must prove its fault/cut was reached, not just that the
child exited. Fail recovery again before permitting healthy retry.

Keep four roles separate: immutable stimulus, production executor, independent
observer and newly exec'ed production opener. Inspect exact envelopes, expanded
pin/dependency closure, accepted/parked/rejected membership, waits/verification,
current values/context, settings, association/selection records, pending generations
and both roots' physical namespace/identity. Recovery receives surviving resources,
normal selection/unlock and current explicit choices; the parent oracle and
acknowledgment log stay outside it. Runtime success flags are claims to inspect.

Process termination, versioned simulated persistence loss, later corruption and
actual restart/remount remain separate campaigns. Process kill cannot qualify
physical power-loss durability. Persistent storage failure yields explicit bounded
recovery status, followed by an actual healthy retry/reopen companion.

## 7. Compiler and mutation qualification

Extend existing ordinary-client and same-module
[root](../../../../tools/test-storage-root-types.py),
[runtime](../../../../tools/test-storage-runtime-types.py) and
[private-state](../../../../tools/test-storage-private-types.py) probes against
the actual production module. For each new evidence type require a valid client
plus intended marked-line rejection for:

- Fabricated ready basis, Work Offline choice or transition evidence.
- Read-only preview supplied to editable/commit consumer; passive association or
  parsed selection supplied as physical permission.
- Reconstructed authority through decoding, mutable evidence fields or actor
  state accessed outside isolation.
- Duplicate consumption where unique ownership is actually adopted.

Challenge a newly added decision case/removed switch branch to require exhaustive
handling, paired with a literal behavioral table. `internal` alone is not an
issuer restriction. Correctly typed wrong-store/root/session/attempt/profile/view
tests still challenge the actual dynamic consumers before effects.

Audit actual API/FFI/bridge surfaces, unsafe annotations, dependency/build flags
and cleanup lifetimes. Preserve strict release checks; avoid broad unchecked
conformances or access bypasses. Rerun applicable sanitizers on new owner/callback/
cleanup paths and report their real platform boundaries.

| Mutation target | Intended failing witness |
| --- | --- |
| Generic error/status/empty listing grants disclosure/absence | P55-01/06/10/20: exact wrong-choice/effect or preserved-occupant assertion. |
| Local retained-membership test omitted | P55-07: evicted already-local bytes spuriously gate startup. |
| Choice ignores attempt/local health | P55-07/22: actual stale/unhealthy admission. |
| Late disclosure revokes active editing | P55-07/08: valid local admission/barrier cannot proceed. |
| Optional work gates startup; required prerequisite/verification skipped | P55-02/03/05: publication order, exact current context or required-gate assertion. |
| Final view/prefix/presentation/selection fence omitted | P55-04/22: incompatible current/model publication. |
| Partial bootstrap/preview edits; unrelated bootstrap elected | P55-11/12/13: forbidden editability or wrong selected commitment. |
| Path/collection equality transfers authority; unknown restores owner | P55-15/17/22: independent replacement no-effect/context check. |
| Same-root handoff unlocks; timeout releases entered resource | P55-15/17: actual contender/lifetime witness. |
| Reassociation drops unique work or skips durable binding | P55-18/21: exact inventory and fresh-exec adoption. |
| Restored allocator reused; stale callback clears target work | P55-17/19: fresh IDs, logical-once effects and pending generation. |
| Publication loses/coalesces background startup incorrectly | P55-03: reached publication plus missing eventual work or duplicate worker. |

Run isolated production mutations with a passing baseline and identical selections.
Require nonzero discovery of every required case/parameter, actual boundary entry
and the intended assertion. Setup/compiler failure, SKIP, unrelated rejection or
generic timeout is not a killed correctness mutation. Reuse robust Swift Testing
discovery checks. Preserve traces; explain a survivor protected by another guard
with independent evidence instead of removing the safeguard.

## 8. Model correspondence

| Existing model family | P5.5 witnesses / concrete residual obligation |
| --- | --- |
| `SQLiteFastStartSafety`, `SQLiteCollectionSafety` | P55-02/04/05/23: exact prefix/capture, complete acceptance and final publication; physical SQLCipher/ownership facts remain concrete. |
| `SegmentBootstrapSafety`, `ReceiveSnapshotAssemblySafety`, `SnapshotReconstructionSafety` | P55-10–14: complete selected import versus preview/partial intake; actual files/codecs/context still tested. |
| `OptionalReadyStartupSafety`, `ReceiveResumptionSafety`, `ReceiveRejectionSafety` | P55-02/03/05/21: required selection, publish/reservation, finite interference and durable queue/verification. |
| `RepositoryRepairSafety` | P55-01/06/07/14/20: health/disclosure and truthful repair dispatch; its finite positive observations are implementation obligations, and P5.6 supplies physical repair. |
| `RepositoryAccessorDriverSafety`, `LocalDurabilityLaneIndependence` | P55-08/09/15–18: actual entry/return, independent saving and stale fences; acquisition capability remains a qualified external input. |
| Segment deletion/merge, causal Undo and conflict-copy models | P55-18/19 and S5: available-history rollback/order outcomes, not inference of erased undisclosed history. |

Use configurations/runners in [TLA README](../../../tla/README.md). The implemented
`CollectionStartupAssociationSafety` companion checks the combined boundary;
its execution and limits are recorded in the validation report.
Update correspondence and rerun affected configurations
when assumptions/transitions change. Add a focused combined startup/reassociation
model only if the new interaction lacks coverage: two physical roots, finite
disclosures/actions, one held completion and one/two restarts. Preserve separate
commit/callback/adoption steps and all safety assertions. A genuine counterexample
may require a user policy decision, not a weakened assertion. State fairness
explicitly; promise neither undisclosed provider delivery nor termination of a
permanently blocked OS accessor.

## 9. Work bounds, platform qualification and execution

### Performance and resources

Measure normal input-to-checked-publication separately from provider acquisition/
discovery, optional acceptance and exceptional reconstruction. Hold current values
fixed while growing 64/256/1,024 actual ordinary ancestors, sequential covering
snapshots and independent frontier width. Record historical BLOB reads/envelope
decodes, SQL work/scans, current decodes, provider entries/turns, time and peak
buffers/descriptors.

Healthy settled returning startup must work with old historical body reads
forbidden apart from specified required-leaf/verification checks. Preserve one
root check for a sequential covering snapshot chain and honest independent-tip
costs. Required work/verification may read their exact scope; reconstruction is
measured separately. Initial capture reuse should not decode all rows twice
without actual interference. Add no mandatory provider-wide inventory/lookup,
full graph, packed cache, current-table rewrite or VACUUM to launch.

Reuse existing discovery/publication budgets and bounded retry attempts. Different
budgets must produce identical eventual outcomes. Measure local-save delay with
an entered held accessor and prove progress when finite interference ends. Timing
observations never replace strict work/semantic assertions. Repeated transition/
cancel/reopen cycles return resources to baseline after actual settlement.

### Qualification layers

1. **Each increment:** deterministic host-free Swift debug/optimized tests, actual
   Runtime consumers, independent literal expectations, type probes and mutations.
2. **Persistence/lifecycle:** child cuts/fresh exec, independent SQL/envelope and
   namespace inspection, contenders and repeated recovery failures.
3. **Portable:** actual Linux arm64 strict build/execution for portable store,
   decision and lifecycle behavior; Darwin capability is separately qualified.
4. **macOS:** actual oldest supported deployment path (declared 11.5), Intel macOS
   14 and current arm64 binaries. Record OS/compiler/SDK/dependency/binary revisions,
   runner and compiler-workaround limits separately from completed execution.
5. **Filesystem:** APFS/APFSX/HFS+/HFSX/ExFAT ownership/moves/detach/remount and test
   image ENOSPC. Preserve the approved fresh deep-HFS+ refusal separately from
   successful ordinary acquisition/owned deep moves; extend no unapproved limitation.
6. **Signed app-context/two-Mac:** production startup/choice/reassociation with
   observed named materialization and exact peer delivery under both profiles.
   Record app identity/signing/session. Request acknowledgment without observed
   eviction/visibility is inconclusive. If no positive newer evidence is exposed,
   test the honest no-gate result and retain deterministic positive-input tests.

Use newly owned synthetic subtrees and authorized host mutation scopes. Never fill
a real account or alter unrelated provider configuration. Audit encrypted artifacts
and diagnostic sinks separately from test-only oracle files. Default distribution
signing, actual application UI and physical power-loss remain explicit later gates.

### Driver integration

Register suites/process schedules/type probes in the existing driver as they become
executable. Preserve the actual regression entrypoints:

```sh
make -C tests run-swift-storage
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
```

Add a focused startup/reassociation process selection through the existing probe,
fault and inspector infrastructure. Document exact commands and required discovered
IDs in the validation report and [integration guide](../../../IntegrationTests.md).
Use existing mutation/type/native/image/live commands with implemented selections;
P55-* labels here are not runner options yet. Preserve
[epoch-4 qualification](../../../../tools/test-epoch4-v5-compatibility.sh).
Run `build.sh` and applicable native integration if shared app helpers change;
the headless implementation preserves application UI and epoch-4 callers.

## 10. Completion and handoff

P5.5 completes when:

1. Every normative startup/repair row has a closed truthful decision and actual
   consumer witness, preserving separate local admission/provider effects.
2. Returning publication remains indexed, complete and consistent; required work
   stays required and successful callback starts/coalesces optional background work.
3. Work Offline uses the precise initial-publication/positive-disclosure/complete-
   local-closure conjunction. Later evidence preserves healthy editing.
4. Explicit creation/bootstrap/private loss preserves incomplete inputs and
   distinguishes complete read-only preview from complete durable editability.
5. Retry/Re-open preserves unique work, continuous applicable ownership, actual
   resource settlement and durable binding outcomes; stale evidence cannot acquire
   a new target, including after restart/ambiguous completion.
6. Critical valid/near-valid/consumer/compiler/mutation/process/scaling witnesses
   pass under both profiles on available qualified platforms. Unsupported, failed,
   unavailable and inconclusive cases stay explicit rather than counted as passes.
7. A revision-bound report records commands, discovered cases/parameters, cuts/seeds,
   independent outcomes, mutation verdicts, capabilities and artifacts. Inventory
   and roadmap link actual evidence and retain later consumer gates.

Then proceed to the [expanded P5.6 plan](06-repair-replacement-and-copy.md) with
typed repair/copy requests and qualified startup/reassociation consumers. Its first
increment connects those requests to effectful recovery; later increments qualify
complementary private repair, automatic missing-entry repair, occupied-entry refusal,
copy and optional switching. Application dialogs, keyboard behavior and final
quit/selection adoption remain Phase 7 human-reviewed work.
