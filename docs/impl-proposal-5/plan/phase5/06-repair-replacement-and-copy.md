# P5.6 — Transparent repair, safe replacement and repository copy

Updated: 2026-10-14

Status: implemented and qualified within the [ledger's recorded limits](06-repair-replacement-and-copy-validation.md).
The [scenario-to-consumer crosswalk](06-repair-replacement-and-copy-validation.md#scenario-to-consumer-crosswalk)
maps the P56-* acceptance matrix to executed witnesses. Broader generated
combinations remain P5.7; distribution and physical power-loss qualification
remain separate. Dependency:
[P5.5](05-startup-and-root-reassociation.md), whose headless implementation is
[qualified within its recorded limits](05-startup-and-root-reassociation-validation.md).
This expands the existing P5.6 delivery unit. The adopted 2026-10-14 policy is
stop-and-Save-As for occupied damaged entries, with automatic add-only repair for
missing entries. Private-store activation and ordinary note-saving are separate.

## 1. Outcome and authority

Connect the integrated collection session to these user-visible outcomes:

- A healthy collection keeps accepting local edits while repairable, locally
  missing `NV Data` is restored automatically.
- Recovery combines exact compatible copies, preserves unique local work and
  activates a repaired private store only after independently checked reopening.
- Save Note Collection As preserves the repository and available saved history,
  reports incomplete coverage honestly, and optionally switches to a verified
  destination. Current-state recovery export remains a distinct fresh collection.

Use the [normative repair contract](../../../iCloud-Drive-Support-Spec.md#repository-and-private-store-damage-and-repair),
[ADR-0016](../../../adr/0016-repair-from-validated-immutable-copies.md),
[canonical vocabulary](../../../../CONTEXT.md),
[active model guide](../../../tla/README.md),
[Phase 5 testing plan](../phase5-provider-root-testing-plan.md),
[conformance strategy](../swift-storage-conformance-testing-strategy.md) and
[language-boundary proposal](../swift-storage-library-proposal-v2.md).
For physical effects, also follow the
[Apple API ledger](../../../Apple-API-Contract-Validation.md) and
[Foundation replacement contract](../../../Foundation-Safe-Replacement-Migration.md).

P5.6 qualifies actual headless consumers, including connected S4 recovery.
[P5.7](07-connected-qualification.md) consolidates broader phase-wide schedules;
it is not a substitute for each increment's executable acceptance gate.
Plaintext admission/deletion confirmation remains Phase 6, and AppKit controls,
actual application switching/quit and editor adoption remain Phase 7.

### What actually remains from P5.5

P5.5's returning/fresh opens, exact named waits, Work Offline and Retry/Re-open
are implemented. Carry their evidence forward. The remaining handoff is the
effectful consumer of a classified recovery request.

| Existing boundary | P5.6 work |
| --- | --- |
| `CollectionSession.inspectRepository` observes the top-level entry and selected descriptor | Connect its repair/collision/unavailable requests, plus later child-object failures, to one repair lifecycle. These observations alone establish neither complete inventory nor replacement permission. |
| `CollectionRecoveryRequest` describes the requested response | Acquire fresh store/root/entry evidence at the consumer before any physical effect; stale requests remain descriptions. |
| `PrivateRepair` verifies private salvage and complementary private evidence | Add exact repository/selected-backup acquisition and combine it with preserved private evidence through the real validators. |
| `RepositoryCopyWorker` and `CollectionCopies` preserve available files or add saved local history | Integrate coordinated source access, bounded transport and honest partial-source outcomes with the active collection. |
| `VerifiedReplacement`, `SelectedStoreOwner` and fresh-selection activation | Connect repair and copy/switch to expected-current activation and actual lifecycle settlement. |

The [P5.5 ledger](05-startup-and-root-reassociation-validation.md) separately records
platform/distribution limits. Fresh deep-HFS+ opening remains the approved explicit
limitation; successful moved-root access and ordinary HFS+ are separate witnesses.
Earlier interrupted aggregate campaigns do not erase completed component results.

## 2. Architecture and state budget

Keep policy in the collection session, immutable-history validation in the existing
storage boundary, and blocking filesystem work on the owned root execution lane.
Private SQL transactions stay on the private database actor. Complete a local
capture before entering provider coordination; release an accessor before awaiting
SQL, cryptography or another actor.

| Responsibility | Existing implementation to extend |
| --- | --- |
| Classify health, admit local editing, own repair/copy transitions | [CollectionStartup.swift](../../../../NVStorage/Sources/NVStorageRuntime/CollectionStartup.swift), [StorageHealth.swift](../../../../NVStorage/Sources/NVStorageRuntime/StorageHealth.swift) |
| Capture accepted local bytes and ordinary transport progress | Existing bounded publication capture, root installation and transport driver |
| Preserve damaged private sources and construct a checked sibling | [PrivateRepair.swift](../../../../NVStorage/Sources/NVStorageRuntime/PrivateRepair.swift) |
| Preserve repository files and add captured durable work | [RepositoryCopy.swift](../../../../NVStorage/Sources/NVStorageRuntime/RepositoryCopy.swift), [CollectionCopies.swift](../../../../NVStorage/Sources/NVStorageRuntime/CollectionCopies.swift) |
| Activate a verified private destination | [StoreSelection.swift](../../../../NVStorage/Sources/NVStorageRuntime/StoreSelection.swift), existing selection/unlock codecs |
| Handle occupied damaged repository entries | Preserve in place, pause affected writes and offer a fresh Save As destination |

Prefer small source files divided by those responsibilities. Factor shared acquisition
or preservation logic only where its contracts really match. Existing repository-only
copy is valuable when the private store is absent or locked; do not make it depend on
opening that store. A shared-root installer has stricter requirements than a fresh
copy destination.

Use one session-owned reservation for an active repair/copy attempt, acquired before
suspending. Reuse existing worker settlement and wakeups rather than adding a second
transport queue, polling loop or actor per object. A repair reservation must coexist
with healthy local saves; the short final switch handoff uses the existing transition
admission barrier. Root loss, close and replacement of the attempt fence late results,
while entered accessors retain their resources until they actually return.

Persistent state remains the accepted objects/edges and pin, existing private inputs,
verification requests, association and selected-store record. Keep captured inventory,
progress and operation-owned handles local to the attempt. After restart, reobserve
partial output and validate exact bytes through existing boundaries. A filename,
stage prefix or copied receipt alone never grants cleanup/replacement authority.
If a concrete crash witness requires additional durable state, document the smallest
record and its ordering before adding it; avoid a parallel repair journal.

#### Detecting loss after publication

After a stable discovery pass, the existing transport worker checks up to 16 accepted
canonical names per database turn, grouped into metadata reads by protocol directory.
Freeze the acceptance prefix for the pass, and bind its cursor and result to the
issuing store/session and root permission. Cap background selection at the existing
publication cursor's complete acceptance batches: a partial batch excludes its last
sequence until the whole sequence is installed. With no completed publication, the
check has an empty scope. Successful nonempty publication requests discovery again.
Thus newly accepted/unpublished objects keep their owned write retries instead of
being mistaken for losses after publication. Reuse the existing batched hint lookup;
its accepted identity must equal the expected name's identity. Otherwise read exact
bytes and compare their hash before recording a checked observation. Directory
handles close in the same owned turn. A discovery listing already in progress
retains its cursor; the name check waits instead of borrowing that resource.

Missing names route through complete local-closure preflight and exclusive repair.
Occupied damage pauses provider writes and routes to Save As, preserving local
editing. Unknown/quarantined extra files remain outside accepted-name requirements.
Keep a failed batch at its captured position through the existing bounded retries;
explicit Retry starts another attempt after exhaustion. The same idle timer provides
progress without new presenter events. No added worker, timer, durable table or
history-body startup scan is needed. Measure the extra metadata and verification
barriers separately from payload reads; this is an O(known objects) background pass,
not a constant-work integrity audit.

### Compiler-enforced boundaries

Names below describe roles; use existing types where possible.

| Value or resource | Issuer and consumer contract |
| --- | --- |
| Captured repair inventory | Owner issues immutable exact locators, required membership, captured prefix and source context. Completeness is an explicit result. |
| Verified repair closure | Validator issues only after required exact dependencies are usable. It proves logical repair coverage; the effect consumer separately obtains physical authority. |
| Missing-entry installation / occupied-entry refusal | Restricted root evidence permits exclusive installation; an occupied damaged entry yields an explicit collision/Save As outcome. |
| Verified private replacement | Existing restricted issuer proves candidate contents, required private inputs, pin and successful reopen. |
| Copy coverage | Separate captured-inventory completeness, saved-history closure and destination editability. An available-file copy may be useful before it qualifies for activation. |
| Selection activation | Existing owner-bound expected-current input plus checked candidate association; actual consumer rechecks source/destination and selected-record context. |

Restrict evidence constructors to the validating/owning boundary. Use exhaustive enums
for ready, incomplete, blocked, preserved collision and uncertain exclusive-install
outcomes. Prefer immutable `Sendable` facts and actor isolation; use unique
ownership for resources with one settlement/disposal obligation. Evidence still needs
same-type/wrong-store, root, session, generation and prefix checks after suspension.
Keep public result shapes stable where sufficient; add a narrow typed outcome only
where the existing API cannot express a real distinction.

## 3. Ordered implementation increments

Complete each increment's production witness before widening the next one.

### 5.6A — Close the startup-to-repair handoff

1. Connect P5.5 classified requests to the session-owned repair controller. Cover
   initial open and later discovery/read/install failures through the same decisions.
   Preserve the original cause and scope rather than reducing every error to absence.
2. Distinguish positive absence, occupied damage, unknown/foreign occupants,
   provider unavailability, root loss, and private required-state failure. Occupied
   damage pauses affected writes and offers Save As; identifying its prior owner
   grants no replacement permission.
3. Start locally decidable same-root repair automatically. Healthy local publication
   and saves continue while provider work is held, unavailable, read-only or full.
   Private required-history loss continues to block editable publication.
4. Preserve P5.5 exact named-unread Work Offline eligibility, including the approved
   held-accessor case. A generic error creates no new Work Offline choice, and there
   is no Restore NV Data button. Retry retains same-root authority; Re-open obtains
   a new explicit association.
5. Reserve before awaiting and coalesce repeated hints into existing work. Return
   explicit status/settlement facts for future UI use. Persistent failures retain
   recoverable inputs and follow existing retry opportunities instead of polling.

Gate: the real session produces the expected admission/status/effect requests for
P56-01–04, including a held provider operation and a completed local save/reopen.

### 5.6B — Acquire exact complementary repair evidence

1. Capture the complete known required closure at a fixed accepted prefix, including
   unpublished local history, snapshot retention parents and descriptor context.
   Use existing bounded capture/read interfaces and traversal-local deduplication.
2. Acquire exact available bytes from the owned repository and any explicitly selected
   backup. Bind each read to its source observation; retry/reclassify changed inputs.
   Resolve missing/unsupported/locked prerequisites through existing outcomes.
3. Keep accepted private membership, unaccepted retained input and available repository
   bytes distinct. Validate repository objects through normal bootstrap/intake rules;
   do not manufacture private-salvage evidence or mark raw files accepted.
4. Union compatible exact evidence. Duplicate identical objects are idempotent;
   contradictory identities or unavailable dependencies remain explicit. Absence from
   one source subtracts nothing from another source's known history.
   Report inaccessible/wrong-kind subtrees and requested objects by source and path;
   continue other reads only while the captured root permission remains valid. Preserve
   contents and permissions. Lost authority, cancellation and contradictory validated
   identities remain terminal. Require complete known membership before candidate
   creation, even when every available directory listing has finished.
5. Capture required private inputs separately: settings, latest pending snapshots,
   frozen admitted operations, settlement/identity links and verification obligations.
   Obtain damaged-private evidence through C's preservation-first path; partial
   salvage remains visibly partial.
6. Bound buffers and database turns. Exceptional repair may traverse the required
   history, while healthy returning startup continues to use indexed current rows.
   Keep checked metadata/path/length/hash references in private salvage evidence,
   using the existing preserved working databases as the payload source. Selected
   repository inputs use their original root permission and exact canonical paths.
   After complete-membership preflight, reread and compare one object per turn
   before bootstrap/intake. Recheck on subsequent reads too; a source can change
   between initial retention and final reacceptance. Retain unaccepted candidates
   individually before the atomic private-group/scheduling installation. Failed
   construction remains an unselected sibling. This replaces aggregate encoded
   history buffers, while metadata and semantic reconstruction graphs may grow.

Gate: independent inventories demonstrate complementary recovery, unpublished-history
retention and explicit incompleteness when any required evidence is missing everywhere
(P56-05, P56-08–12). An available-file inventory is not proof of accepted-history closure.

### 5.6C — Repair the private store first when necessary

1. Fence private admission and delayed callbacks, settle owned database work, and
   close through the existing preservation path before copying the database/journals.
   Reuse preservation of the original inputs before salvage. Work on the preserved
   copy; retain readable components when another component fails. Opening with
   incorrect credentials remains distinct from corruption.
2. Extend fresh-sibling construction to consume the checked union from B, preserving
   all valid unique private inputs. Conflicting private records require an explicit
   incomplete outcome rather than arbitrary winner selection.
   Preserve earlier capture-scope bindings from every contributing private store,
   validate their collection/descriptor context, and coalesce exact repeated
   records. A previously repaired complementary source must remain usable in
   either input order. Repackaged identical history still preserves each envelope
   while applying its logical actions once; contradictory action identities stop
   reconstruction through the normal history validator.
3. Revalidate verification obligations against exact history in the new store.
   Old local acceptance-sequence integers cannot be copied as if they named the
   replacement's history. Preserve or discharge each obligation with checked evidence.
4. Verify complete retained membership/pin, rebuild derived rows, close and reopen
   with normal unlock inputs, and verify required private state and editing context.
   Failed reconstruction never activates a current-row-only substitute.
5. Activate through the existing expected-current selected-store boundary. Handle
   unchanged, committed and uncertain outcomes by exact readback plus the required
   durability checks. Preserve both candidates and credentials until settlement.
   The live uncertain attempt retains its native handles and candidate identity;
   resumption repeats the installed/displaced checks and barriers rather than the
   replacement. Explicit close releases those handles while retaining disk artifacts.
   A new process uses ordinary selected-record and candidate reopening.
   Check cancellation before selection admission and again after expected-current
   validation, immediately before installation. Once an effect starts, settle it
   with the same durable/uncertain outcomes. A cancelled resumption preserves the
   pending attempt. Closing a candidate invalidates previously issued live evidence;
   the selection owner's pending source exclusion remains separately owned.
   Preserve the integrated Save As handoff's earlier admission: its activation
   runs in a bounded task with independent cancellation, awaited before returning
   or releasing resources. Existing held-accessor cancellation cases still finish
   that admitted handoff; standalone cancelled activation still stops before effect.
6. For total private loss, retain the existing explicit repository-selection and
   fresh-local-identity workflow. Trusted writable parents may be recreated; wrong-kind,
   inaccessible or ambiguous parents remain preserved. Unassociated salvage requires
   the existing explicit recovery/association decision.
7. Begin provider repair only after the repaired private store is usable. Keep portable
   history/Undo distinct from private settings or pending input that was truly lost.

Gate: connected S4 reaches actual activation after complementary recovery, including
a second failure during recovery, with independently expected history, pending input,
settings and obligations (P56-08–13, P56-17).

### 5.6D — Restore missing repository entries transparently

1. For an owned compatible root, exclusively create a positively absent `NV Data`
   or child directory. Install exact immutable descriptor/object bytes through P5.2's
   complete-stage, no-overwrite installer and its file/directory durability barriers.
2. Repair the complete captured known closure, not merely objects needed for today's
   note bodies. Include unpublished history, retained snapshots and their dependencies.
3. Treat verified identical existing bytes as reusable evidence. A changed occupant
   stops the current effect and triggers fresh classification: compatible evidence may
   be unioned, while foreign or contradictory input remains preserved.
4. Keep the capture fixed while local editing continues. Later accepted work is owned
   by normal transport; completion acknowledges only the captured coverage and leaves
   newer pending work intact. Transport attaches/resumes through the existing session
   handoff after compatibility is established.
5. Preserve interrupted add-only output. Reopening/retrying revalidates exact installed
   objects, finishes missing work and performs required barriers before reporting success.
   A callback, provider upload flag or successful rename alone is insufficient.

Gate: positive absence repairs automatically without delaying healthy local editing;
crash/race retry yields either preserved partial output or the complete captured closure
(P56-02–07, P56-16). New cloud disclosures take their existing precedence.

### 5.6E — Stop occupied damage and preserve Save As access

1. Preserve occupied corrupt/wrong-kind entries and populated directories in place.
   Stop affected provider writes, retain healthy local publication/saves and expose
   Save As through the existing recovery request. Keep unread/access uncertainty
   distinct from confirmed occupied damage.
2. Apply the same outcome to late child-object failures. An exact local copy allows
   a fresh destination, not replacement of the occupied source. Repeated hints and
   Retry reobserve; they cannot automatically unlink, move or chmod the occupant.
3. A contender appearing after an absence observation still loses no bytes: the
   exclusive installer refuses the occupied name, then the session reclassifies.
   Verified identical bytes may be reused through the existing checked path.
4. Copy-only preserves source selection; switching uses the separately verified
   private activation path. Missing required history/private inputs prevent
   activation. Unavailable extras remain an explicit partial-inventory report
   alongside complete known-history coverage. No persistent displacement-reconciliation record is introduced.
5. Qualify file, directory, symlink and changed-child cases with independent source
   inventories, healthy local saves/reopen, repeated attempts and Save As outcomes.
   Retain the Foundation capability experiment as rationale, not a production gate.

Gate: P56-14–16 and P56-22 preserve every occupied source while add-only companions
still complete. Existing private selected-store activation and later note-file
replacement retain their own qualification.

### 5.6F — Connect repository Save As and recovery export

1. Adapt repository-only copy to owned/coordinated reads and the bounded discovery
   path. Preserve unknown regular files as available repository data; symlink/special,
   unreadable, placeholder and changing entries get explicit preserved/partial outcomes.
   Copying a text file never implicitly admits it as an NV note.
2. Use strict complete immutable installation for canonical history at the destination.
   Preserve exact sealed bytes and identities, including when copying a locked repository
   without a private store. Report available-inventory coverage separately from validated
   complete history and editability.
3. For an active collection, settle owned admitted saves and capture a durable history
   cut, then add its exact local objects to the copy. Preserve newer work until its own
   save/copy step. An unavailable source repository must not prevent offering a copy of
   complete saved local history; report unavailable repository extras honestly.
   Reserve canonical names for verified local bytes before copying extras. If the
   source has damaged bytes or obstructing wrong-kind entries at those names, report
   them as preserved in the source. Create no extra recovery/archive directory.
   Complete known history and complete available-source inventory remain separate.
   Preflight the fixed cut through bounded publication batches, keeping canonical
   names and exact hashes as the copy inventory. Re-read and check one bounded
   batch against that inventory before installing it; verify complete inventory
   consumption before success. This keeps sealed-payload memory bounded while
   allowing inventory/report metadata to grow with history. Destination verification
   uses the same bounded reader. A missing/corrupt source record stops coverage;
   later acceptance does not change the captured cut.
4. Keep private pending inputs/settings and unsaved RAM coverage explicit. Existing
   saved-work copy reports excluded private pending items; it cannot claim those are
   portable repository history. Preserve their source until handled by an appropriate
   private transfer or explicit recovery decision.
5. Reuse separately labeled current-state export for a fresh genesis/birth set when
   history-preserving recovery is impossible or explicitly unwanted. Capture any live
   RAM values through the existing host boundary; do not infer them from old rows.
6. Validate the destination in a fresh process using normal repository/unlock inputs,
   with the source Application Support directory unavailable. A partial preservation
   copy remains useful, but cannot qualify as a complete editable recovery.

Gate: P56-18–20 demonstrate standalone copy, saved-work supplementation, honest partial
outcomes and distinct current-state export; source bytes remain independently intact.

### 5.6G — Optional switch, connected qualification and handoff

1. Copy-only leaves the active root and selected private store unchanged.
2. For an explicit switch, create/verify the destination's private store, acquire its
   physical root, and establish fresh association/writer context. Reuse the existing
   switch/copy rules; copied physical receipts require fresh validation.
3. Immediately before cutover, use the short admission barrier to settle/capture work
   accepted since the earlier copy. Transfer every required private input under the
   specified copy/switch rules or retain the old selection with an explicit incomplete
   outcome. Never leave a newer edit solely in a source being abandoned.
4. Issue activation evidence only through the proper verified consumer. In particular,
   a fresh candidate with an empty source set does not justify replacing a selected
   active store. Validate expected selection, source ownership and destination context.
5. Reconcile ambiguous selected-record installation before releasing old resources.
   Preserve source data/credentials; drain or fence old provider work through actual
   return. Old callbacks cannot update the newly selected collection.
6. Run the connected matrix, update the caller inventory and publish a revision-bound
   qualification ledger beside this plan. Phase 7 later adopts the headless result in
   the app without changing editing/responder behavior here.

Gate: P56-17, P56-21–25 plus S4 pass, with exact artifact inventories after each crash
and eventual progress once finite interference stops.

#### Fixed-copy preparation and final handoff

For a healthy private source, reuse the fixed-reader SQLCipher backup rather than
salvage/replay the source under the final admission barrier. The complete backup
carries exact immutable bytes, accepted indexes, settings, pending latest/frozen
inputs, reservations and parked/rejected work. Normal reopening and the existing
complete private/history verification qualify it before independent private-store
identity is assigned. Reopen again after the identity/association-scope transaction.
Use the existing `repair-source/` provenance record to keep historical private
capture scopes readable. Old physical observations remain passive; the destination
root must supply its own checked association before activation.

Capture the source connection identity and SQLCipher's 64-bit `total_changes()`
count alongside the fixed reader. A changed connection or any intervening row
write invalidates the preparation, including settings/pending updates that leave
the accepted-history sequence unchanged. The counter belongs to the sole owned
writer; it is a short-lived comparison, never a durable identity or cross-machine
clock. Rolled-back or temporary-row writes may conservatively require a new
preparation. Physical ownership, healthy-history and final selection checks remain.

Before each optional accepted-name turn, the transport worker asks its collection
owner whether the current physical root is editable and the existing operation
count is zero. It reserves the running demand before that asynchronous question and
rechecks lifecycle/cancellation afterward. If foreground work owns a reservation,
retain the inventory cursor and unconsumed attempt budget in the existing delayed
demand, due at the next ordinary idle interval. Standalone drivers retain their
ordinary scheduling. Both initial named-wait attachment and normal attachment use
the same collection callback.

This is a scheduling hint, not an exclusive lease or activation proof. A check
admitted before preparation may finish and invalidate that preparation; the final
write-count fence still retains the source. Directory discovery, received history,
owned publication and local saves retain their existing behavior. After finite
foreground work, the existing timer resumes inventory without another delivery or
explicit Retry. Pre-handoff cancellation reports `StorageError.cancelled`, preserves
source selection and partial output, and releases the preparation reservation.

Qualify a healthy published source with the actual periodic worker: park it at an
idle boundary, prepare and hold a copy, release periodic work, and require an actual
deferred opportunity with unchanged source write count. The quiet copy must activate;
a newer local edit must refuse stale activation, and cancellation must retain the
source. Both refusal paths must resume actual inventory without further input and
reopen the expected saved notes. Existing entered-accessor settlement tests remain
required companions.

Control receive work started by host publication in competing-copy tests too.
After actual receive settlement, the otherwise unchanged retained preparation
must finish. A deliberately held receive owner requires busy refusal with the
original selection preserved; after release, a fresh copy/switch must finish.
Use the existing receive-state predicate and held callback to distinguish these
orders, rather than assuming a current-value observation is side-effect-free.

The final consumer must compare this cut **inside the serialized handoff**, after
fencing/settling admitted source work and before retiring its owner. An earlier
successful comparison alone grants no activation authority. If the cut changed,
keep the source selected/editable and return an explicit retryable incomplete
outcome; prepare again from the newer complete source. This selects the existing
safe-refusal option in step 3 instead of introducing a second incremental
private-state transfer protocol. Keep the candidate and copied repository preserved
on failure. No new persistent table, format or sidecar is needed.

`CollectionSession.switchRepositoryAndSavedWork` reserves preparation through the
existing operation count while ordinary editing remains available. It checks every
saved descriptor/object under the reacquired destination root, binds a fresh physical
association, then enters the transition phase and settles old provider work. The
database lane compares the exact connection/write cut and closes its SQL connection
in one synchronous turn. The existing 25-word settled file/journal observation
fences reacquisition of the source exclusion lease by `SelectedStoreOwner`.

An unchanged source check issues the existing file-restricted activation evidence.
Known unchanged selection failure reopens the original private owner when needed;
old capture generations are fenced if the connection changed. An uncertain selection
retains the candidate, destination root, original root and original private exclusion
in one explicit pending phase. `resumeCopySwitch` repeats only readback/durability
settlement. Success returns a fresh integrated owner; a later admission failure
reports the durable selected identity needing reopening. Explicit close preserves
both candidates and releases owned resources for normal selected-record recovery.
The host must still settle live RAM work at its later application lifecycle boundary.

Implementation and qualification are recorded in the
[ledger](06-repair-replacement-and-copy-validation.md#fixed-private-copy-preparation).
Connected crash qualification and the phase matrix remain independently tracked gates.

## 4. Scenario and independent observation matrix

Each row needs a valid companion and the actual integrated consumer, with nonzero
discovery. Exercise both provider profiles where applicable. These IDs extend the
Phase 5 P5-REPAIR/COPY/CLEAN/PRIV families; they are planned scenarios, not existing
test selectors. Use deterministic held cuts rather than timing-dependent sleeps.

| ID | Schedule or fault | Required independent observation |
| --- | --- | --- |
| P56-01 | Initial and late missing/damaged/unavailable requests; repeat hints | One applicable attempt; correct admission/status; classification alone performs no unauthorized effect. |
| P56-02 | Positively absent same-root `NV Data`, complete local history | Automatic complete exact repair; healthy publication/save succeeds; no Restore or generic Work Offline choice. |
| P56-03 | Missing nested directories/objects, including unpublished local objects | Exact captured dependency closure installed once; identities and sealed bytes preserved; all barriers reached. |
| P56-04 | Exact unread cloud disclosure before/during repair; held accessor | Existing wait/Work Offline rules, same live attempt and fresh local health; no overwrite permission or false absence. |
| P56-05 | Complementary private/repository/selected-backup contents | Union preserves every known required object; available files and accepted membership are checked separately. |
| P56-06 | Save/Delete accepted during capture/install; delay old completion | New action remains durable and pending for transport; old completion reports only its prefix; reopen preserves both histories. |
| P56-07 | Root move, same-path replacement, compatible/foreign occupant or changed child | Owned move follows its resource; lost/changed authority stops effects; competing contents remain preserved and reclassified. |
| P56-08 | Fail preservation/salvage with SQLCipher WAL/journals present | Original inputs survive; working-copy failure is explicit; readable unique components remain available. |
| P56-09 | Complementary recovery with pending latest snapshot, admitted frozen input, settings and verification requests | Repaired private store retains exact inputs/links; remapped or completed verification is justified by exact history. |
| P56-10 | Orphan, unaccepted, malformed or wrong-context salvage mixed with valid history | Valid companion recovers; invalid/unsupported inputs stay explicit; no fabricated accepted membership or silent loss. |
| P56-11 | Total private loss; trusted absent parent versus symlink/wrong-kind/unwritable parent | Existing explicit reselect/fresh identity rules; parent collision preserved; no hidden alternate path. |
| P56-12 | Missing required bytes everywhere, unsupported prerequisite, wrong credential | Incomplete/unsupported/unlock outcomes remain distinct; stale current rows cannot become editable recovery. |
| P56-13 | Retention-parent snapshots with differing logical cuts, Delete/Restore and compensation history | Complete required closure, values, identities, conflicts and Undo/Redo candidates match independent expectations. |
| P56-14 | Occupied corrupt regular file, exact local copy, repeated Retry and saves | Source bytes/inode remain unchanged; affected writes pause with Save As available; local save/reopen preserves newer work. |
| P56-15 | Populated wrong-kind directory, symlink, competing entry/descendant changes | Every occupant remains in place; copy reports unavailable/changed evidence; missing-entry companion still repairs exclusively. |
| P56-16 | Failure/termination before and after write, verification, sync, install, directory barrier and callback; fail again on recovery | Exact unchanged/partial/complete state, no premature success, all recoverable bytes retained, later valid retry completes. |
| P56-17 | Private pin/reopen/activation failure; selected record old/new/third state; source changes | Activation only of a complete checked candidate; ambiguous outcomes preserve sources; readback and durability both checked. |
| P56-18 | Repository-only copy with private directory absent or locked | Fresh process reads exact available inventory; complete qualified copy reconstructs history without source private state. |
| P56-19 | Placeholder, unreadable/unknown file, changed source, dependency hole | Partial coverage names what is unavailable/changed; available bytes preserved; incomplete copy cannot activate as complete. |
| P56-20 | Saved work newer than repository, absent repository, failed local save, unsaved RAM, current-state export | Exact saved cut included when usable; exclusions explicit; current-state export has fresh history and deliberate captured values. |
| P56-21 | Copy-only versus switch; newer save at cutover; held old accessor/callback | Copy-only keeps original association; switch carries required work and fresh physical context; stale result cannot affect destination. |
| P56-22 | Abandoned stage, replaced cleanup name, symlink, occupied damage; repeated cancel/close | Cleanup targets only positively owned disposable resources; accepted, foreign and recovery evidence survives; handles settle once. |
| P56-23 | Both profiles; locked/wrong-key/failed paths; password-free operation without Keychain | Marker scan of real stage, repair, copy, export and log sinks matches confidentiality policy; credentials remain recoverable. |
| P56-24 | Increasing history/inventory; fixed healthy current state; saves during repair | Bounded batch/buffer sizes and database turns; no new mandatory healthy-startup history scan; finite interference resumes work. |
| P56-25 | Two-store and signed two-Mac repair/copy with late Delete/Restore and Undo history | Actual provider-delivered exact bytes, complete membership, independent semantic expectations and fresh reopen; no SSH data shortcut. |

### Connected S4 and bounded scheduling

Start with complementary missing/corrupt private and provider objects, a saved but
unpublished action, unique settings, pending input and a verification obligation.
Preserve sources, construct and reopen a sibling, then fail around pin/activation;
fail again during recovery. After private activation, repair `NV Data` while a
compatible or foreign contender and a newer local edit arrive. Finish with an
independent destination reopen and source/destination inventory.

Enumerate small two-writer/two-note schedules at meaningful cuts, adding selected
three-writer cases for late deletion/restoration. Separate process termination,
simulated file/namespace persistence loss, and later corruption. A pipe-confirmed
reached cut establishes the crash point; ordinary recovery receives only surviving
files and normal selection/unlock inputs, never the expected-state oracle.
Inspect original and repaired databases, exact envelopes, pending rows, selected
record, repository files and preserved artifacts independently of success flags.

Implemented entrypoints are `tools/test-storage-repository-repair-process.py`
(complementary recovery, repeated installation failures and lost activation
callback; then repeated provider access failures, occupied damage and lost repair
completion after activation), `repositoryRepairConnectedActivationNamespaceRace` (repaired selection,
newer save and compatible/foreign contender), and the two
`collectionCopySwitch*Accessor*` tests (real entered accessor and final switch
admission). The [qualification ledger](06-repair-replacement-and-copy-validation.md)
records their exact coverage, commands and remaining matrix/platform gates.

`tools/test-storage-apple-repair.py` exercises P56-25 through the signed
`CollectionSession` startup-controller. The local companion uses isolated repository
directories; its two-Mac mode requires actual provider delivery. Both profiles
exercise late Delete/fresh-birth Restore, portable Undo/Redo, missing-namespace
repair, occupied canonical damage, saved-work copy, verified switching and fresh
peer reconstruction. Every provider copy retains the exact independently checked
history. Source damage remains in place and appears in the copy report. The
runner's self-test challenges its history, membership, note and report oracles.
Live qualification requires a separate successful run with `--ssh-target`; the
local companion establishes neither cloud delivery nor account authorization.

`repositoryRepairGrowthYieldsToSavesAndKeepsCapturedCut` adds the P56-24
automatic-repair witness: both profiles at 64/256/1,024 ordinary actions, isolated
stores from the existing shared history fixture, real host publication, and an
edit/Delete between bounded installation turns. Exact repository bytes must equal
the older captured prefix; the newer local actions must survive normal reopening.
Assert batch limits and zero graph reconstruction/ancestor traversal independently
of elapsed-time measurements. Exceptional private-store salvage has its own
memory/reconstruction costs; this witness qualifies same-root provider repair.

## 5. Qualification strategy

### Compiler boundaries and mutations

Add ordinary-client and same-module construction probes for new evidence/resources.
Exercise actual consumers with valid same-type evidence from another store/root,
session, prefix or selection generation. Positive companions prove accessibility
where intended; failures must occur at the marked line for the intended reason.

Target mutations at omitted closure checks, dropped private input, stale effect
permission, occupied-entry overwrite or a missing Save As outcome, missing sync/readback, early activation,
false copy completeness, stale completion and cleanup of preserved evidence.
Require a passing baseline, nonzero discovery and the intended assertion. Existing
mutation cross-products and access-control checks remain intact.

### Models and executable contracts

Reuse `RepositoryRepairSafety`, `RepositoryCopySafety`,
`CollectionStartupAssociationSafety` and `RootAccessorTransportSafety` as described
in the [model guide](../../../tla/README.md). Update correspondence when these planned
consumers become concrete. Existing abstract preservation/atomicity assumptions do
not prove Foundation replacement, SQLCipher salvage or filesystem barriers.

If implementing a boundary changes modeled behavior, extend the relevant model and
run its documented positive/negative/reachability configurations. Add a small S4
scheduling model only for a material interleaving absent from existing coverage.
Investigate genuine counterexamples against the spec; retain safety assertions.
Planning-only documentation edits require no repeated TLC or runtime campaign.

### OS, API and performance checks

- Run debug/optimized local suites, child-process failures, independent fixture/schema
  checks, affected compiler probes and mutations through the existing test driver.
  Register new P56 cases/selectors as they become executable.
- Qualify current macOS arm64, Intel macOS 14 and the macOS 11 VM when available,
  plus Linux. Record actual OS/compiler/binary revisions and distinguish the Orbb
  compiler/runtime workaround from release-package qualification.
- Test APFS/case-sensitive APFS and applicable HFS+/ExFAT images. Carry existing
  fresh-deep-HFS+ and strict-install capability limits explicitly; a successful
  syscall on one filesystem cannot qualify another. Preserve Linux contracts.
- Exercise signed two-Mac iCloud consumers in the authorized synthetic test root;
  observe actual materialization/eviction and exact peer bytes. Use isolated images
  or the disposable VM for ENOSPC/permission faults, not real-account quota exhaustion.
- Audit new C/Objective-C boundaries with strict diagnostics and affected ASan/TSan
  runs. Run native integration tests, epoch-4 compatibility and `build.sh` when
  their shared app/legacy callers change.
- Measure healthy publication, repair acquisition/validation/installation, copy and
  activation separately. Use increasing inventories/history (including 64/256/1,024
  ordinary actions), both profiles and fixed current notes; count envelopes, SQL
  work, metadata batches and peak buffers. Exceptional complete recovery may be
  history-proportional; provider waits must remain off the local save lane.
- Reuse qualified builds, shared setup and prior unaffected results with their exact
  provenance. Every failure case gets an isolated mutable store. Avoid rebuilding
  unaffected targets or rerunning a full suite for documentation-only changes.

Record results in a sibling P5.6 validation ledger when implementation begins:
test IDs/selectors, source and binary hashes, observed fault cuts, independent results,
compiler/mutation controls, actual platform capabilities, performance and limitations.
Update the [validation index](../../../Test-and-Validation-Index.md) and caller
inventory. Keep physical power-loss qualification explicit and separate from kills.

## 6. Completion and subsequent work

P5.6 completes when the implemented consumers pass their matrix and connected S4:
automatic same-root repair, private-first complementary recovery, occupied-entry refusal, honest standalone/saved-work copy and safe explicit
switch. Each supported outcome must have a production witness. Occupied-entry replacement is outside P5.6; its earlier exploratory model is retired.
Copy completeness and optional activation remain explicit gates.

Keep pruning, snapshot scheduling, plaintext reconciliation, application UI and
release/distribution qualification in their stated later scopes. Preserve epoch-4
opening/recovery/export. Current development segment/private encodings may be revised
directly if implementation needs it; add no migration solely for superseded drafts.
