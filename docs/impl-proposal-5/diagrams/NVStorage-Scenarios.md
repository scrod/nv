# NVStorage scenario reference

[Interactive scenario reference](nvstorage-object-map.html) · [Architecture inventory](../NVStorage-Object-Map.md)

These walkthroughs describe specified storage behavior. Requirement links identify governing rules; test-contract links identify validation obligations. Implementation and platform qualification are documented in the linked plans and reports. Example names and values instantiate the cited requirements. Each diagram represents one Mac; the participant label identifies the Mac or external actor involved at that stage. Read/write labels record conceptual inputs and outputs. Transaction boundaries are specified in the operations and their references.

## Local editing, durability and startup

Edit admission and capture, SQL acceptance, accepted-prefix startup, verification replay, and derived-row reconstruction.

### Local save while the provider is unavailable

[Open walkthrough](nvstorage-object-map.html#scenario=offline-save&step=1)

With a healthy, unlocked private store, edits enter the live model immediately. The local SQL transaction commits exact history and its required bookkeeping before acknowledgment; provider publication remains pending.

**Initial conditions.** A returning Mac has a healthy, unlocked, exclusively owned private store. The user edits “Packing” while the provider is unavailable.

**Expected outcome.** After the complete local commit, the edit survives reopening and remains queued for exact publication.

1. **Edit admission and pending-generation registration** (This Mac).

   Observable state: The text and synchronous search results update immediately. The edit is pending.

   Storage operation: Admit the edit into the live model and record its generation, before-state and action context.

   Applicable rule: Local health, key and lifecycle gates govern admission; provider waiting alone does not block it.

   Read / consume: `live`, `views`.

   Write / produce: `pendinglive`, `search`.

   Check / gate: `gate`, `localowner`.

2. **Capture, sealing and atomic local acceptance** (This Mac).

   Observable state: Typing continues while the captured generation is encoded off the main thread.

   Storage operation: Freeze the complete action, seal once, then atomically commit exact bytes, acceptance/indexes, retained pin and wakeups.

   Applicable rule: A qualified complete SQL commit is the local durability barrier. Capture scheduling is not an acknowledgment.

   Read / consume: `capture`, `seal`, `batch`.

   Write / produce: `objects`, `accepted`, `opindex`, `actionindex`, `pin`, `receiveq`.

   Check / gate: `localowner`.

3. **Reopening from local history before publication** (This Mac).

   Observable state: Packing contains the durable edit and is searchable. Sync remains pending.

   Storage operation: Recover the accepted suffix, load complete current rows/context, and later publish the same retained sealed objects.

   Applicable rule: Upload and plaintext installation are separate outcomes; local durability does not depend on either.

   Read / consume: `objects`, `accepted`, `current`, `view`.

   Write / produce: `live`, `search`, `pubwork`.

   Check / gate: `gate`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CKPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-CAP-01](../plan/swift-storage-conformance-testing-strategy.md#tc-cap-01--a-faithful-frozen-action-not-just-durable-bytes) — A faithful frozen action, not just durable bytes
- [TC-LIVE-01](../plan/swift-storage-conformance-testing-strategy.md#tc-live-01--local-durability-progresses-with-a-stuck-provider) — Local durability progresses with a stuck provider
- [TC-DUR-04](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Sweep actual SQL transaction/VFS write/sync/commit outcomes, including persistent failures and interrupted recovery

Design / plans:

- [Local admission, sealing and recovery](../../iCloud-Drive-Support-Spec.md#local-admission-sealing-and-recovery) — iCloud-Drive-Support-Spec.md
- [Admission, sealing, and durability without a second WAL](../Protocol.md#admission-sealing-and-durability-without-a-second-wal) — Protocol.md
- [6. Phase 2 — One complete local save and fresh reopen](../plan/swift-storage-implementation-plan.md#6-phase-2--one-complete-local-save-and-fresh-reopen) — swift-storage-implementation-plan.md

### Crash recovery before and after the local commit

[Open walkthrough](nvstorage-object-map.html#scenario=save-crash&step=1)

A pending edit becomes recoverable only after its complete local transaction commits. Recovery includes a committed action whose callback was lost; text still held only in RAM remains within the pending loss window.

**Initial conditions.** “Trip” has a durable value A and a pending value B. Power is lost at different points in the next save.

**Expected outcome.** Recovery includes complete committed groups, including a commit whose callback was lost. RAM-only edits retain an explicit loss window.

1. **Pending value B before the durability barrier** (This Mac).

   Observable state: B is visible with pending work; it has no completed durability acknowledgment.

   Storage operation: Capture/sealing may be scheduled, but the previous accepted closure A remains the recovery baseline.

   Applicable rule: The existing 2.7-second idle and 15-second first-pending timers are scheduling targets, not per-keystroke durability promises.

   Read / consume: `live`.

   Write / produce: `pendinglive`, `capture`.

   Check / gate: `gate`.

2. **Interruption of the acceptance transaction** (This Mac).

   Observable state: Before a qualified commit, B is unacknowledged. After a complete commit, its durable identity exists even without a callback.

   Storage operation: SQLite resolves transaction state; exact object bytes and complete action/index/pin/wakeup bookkeeping succeed together.

   Applicable rule: There is no accepted partial action and no second NV note-value WAL.

   Read / consume: `seal`, `batch`.

   Write / produce: `objects`, `accepted`, `pin`, `receiveq`.

   Check / gate: `localowner`.

3. **Recovery from complete committed evidence** (Restart).

   Observable state: The recovered model shows A or committed B according to the durable evidence.

   Storage operation: Query exact committed identities, drain required work and materialize the complete accepted prefix before editable publication.

   Applicable rule: Neither an upload flag nor a lost UI completion determines whether the action committed.

   Read / consume: `objects`, `accepted`, `receiveq`.

   Write / produce: `current`, `view`, `live`, `search`.

   Check / gate: `gate`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-DUR-01](../plan/swift-storage-conformance-testing-strategy.md#tc-dur-01--earlier-completion-cannot-clear-later-work) — Earlier completion cannot clear later work
- [TC-DUR-04](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Sweep actual SQL transaction/VFS write/sync/commit outcomes, including persistent failures and interrupted recovery
- [TC-CAP-01](../plan/swift-storage-conformance-testing-strategy.md#tc-cap-01--a-faithful-frozen-action-not-just-durable-bytes) — A faithful frozen action, not just durable bytes

Design / plans:

- [Local admission, sealing and recovery](../../iCloud-Drive-Support-Spec.md#local-admission-sealing-and-recovery) — iCloud-Drive-Support-Spec.md
- [Admission, sealing, and durability without a second WAL](../Protocol.md#admission-sealing-and-durability-without-a-second-wal) — Protocol.md
- [6. Phase 2 — One complete local save and fresh reopen](../plan/swift-storage-implementation-plan.md#6-phase-2--one-complete-local-save-and-fresh-reopen) — swift-storage-implementation-plan.md

### Delayed save completion with a newer pending generation

[Open walkthrough](nvstorage-object-map.html#scenario=delayed-save&step=1)

Capture E contains AB. A later edit creates generation F containing ABC before E completes. E’s completion settles only E; F remains pending and its live value remains ABC.

**Initial conditions.** Capture E contains “AB”. While E saves, another keystroke produces newer generation F with “ABC”.

**Expected outcome.** E may settle its own generation; F remains pending until its own complete barrier succeeds.

1. **Frozen capture E containing AB** (This Mac).

   Observable state: The sealer works on AB while the editor remains responsive.

   Storage operation: Copy complete E values/action metadata and bind the capture to exact pending generations.

   Applicable rule: One collection sealer owns immutable retry input; later edits cannot alter that capture.

   Read / consume: `pendinglive`.

   Write / produce: `capture`, `seal`.

   Check / gate: `localowner`.

2. **Admission of F containing ABC while E is in flight** (This Mac).

   Observable state: The live note is ABC; F is a distinct newer pending generation.

   Storage operation: Preserve F and its dependent causal context while E finishes its own SQL acceptance.

   Applicable rule: A captured value is not a snapshot of all work that will exist at completion time.

   Read / consume: `live`, `capture`.

   Write / produce: `pendinglive`, `accepted`, `pin`.

   Check / gate: `gate`.

3. **Settlement of E without clearing F** (This Mac).

   Observable state: ABC stays visible and pending. E cannot clear F or write AB over it.

   Storage operation: Settle only serviced generations; separately validate any prepared model publication and capture F next.

   Applicable rule: Durable record completion and generation-fenced live publication have separate applicability checks.

   Read / consume: `accepted`, `pendinglive`.

   Write / produce: `capture`, `live`.

   Check / gate: `gate`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CKPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-DUR-01](../plan/swift-storage-conformance-testing-strategy.md#tc-dur-01--earlier-completion-cannot-clear-later-work) — Earlier completion cannot clear later work
- [TC-ASY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-asy-01--real-actorqueue-wiring-not-only-pure-transitions) — Real actor/queue wiring, not only pure transitions

Design / plans:

- [Admission, sealing, and durability without a second WAL](../Protocol.md#admission-sealing-and-durability-without-a-second-wal) — Protocol.md
- [Local admission, sealing and recovery](../../iCloud-Drive-Support-Spec.md#local-admission-sealing-and-recovery) — iCloud-Drive-Support-Spec.md
- [11. Phase 7 — Application capture, history UI and lifecycle](../plan/swift-storage-implementation-plan.md#11-phase-7--application-capture-history-ui-and-lifecycle) — swift-storage-implementation-plan.md

### Returning startup with optional snapshot work queued

[Open walkthrough](nvstorage-object-map.html#scenario=fast-startup&step=1)

Startup drains required Changes, prerequisites and unfinished verification, then captures all current rows and authoring context consistently. Independent optional snapshot work starts after checked publication of the editable model.

**Initial conditions.** The returning store has valid current rows plus a small accepted suffix, a large old history, and an independent optional snapshot waiting.

**Expected outcome.** All current notes and authoring context publish together; optional history preparation continues after that checked handoff.

1. **Recovery of startup-required work** (This Mac).

   Observable state: Opening waits for known required Changes and prerequisites, not arbitrary queue order.

   Storage operation: Drain durable required work and unfinished verification; leave independent optional snapshot assembly durably queued.

   Applicable rule: Bootstrap, known damage and required dependencies still gate success.

   Read / consume: `receiveq`, `verification`, `accepted`.

   Write / produce: `reduce`, `current`, `view`.

   Check / gate: `localowner`.

2. **Consistent capture and publication of complete current state** (This Mac).

   Observable state: Every current body and synchronous-search index is ready before editing begins.

   Storage operation: Decode complete current rows and compact authoring frontiers directly into final unpublished memory under one consistent read capture.

   Applicable rule: Validate scope/version/codecs, view epoch and accepted/materialized prefixes; final owner checks prevent stale publication.

   Read / consume: `current`, `view`, `dict`.

   Write / produce: `live`, `search`, `pendinglive`.

   Check / gate: `gate`.

3. **Optional intake after successful host publication** (This Mac).

   Observable state: The complete current model accepts input and serves synchronous search while optional history/snapshot work proceeds in bounded background turns.

   Storage operation: Reserve the receive owner after successful publication; resume optional validation and lazy scoped history queries.

   Applicable rule: Finite saves settling must allow progress without another delivery. Required persistence takes priority over optional maintenance.

   Read / consume: `objects`, `actionindex`, `receiveq`.

   Write / produce: `snapwork`, `history`, `maintenance`.

   Check / gate: `gate`.

Requirements: [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CKPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-START-01](../plan/swift-storage-conformance-testing-strategy.md#tc-start-01--complete-bootstrap-and-current-row-startup) — Complete bootstrap and current-row startup
- [TC-PERF-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Fixed realistic note/body/history fixtures, cold/warm reopen, small/large tail, current-cell decode bounds, provider backlog, KDF and active typing
- [TC-LIMIT-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Same valid long graph with small/large work budgets, resumed repeatedly, plus a wide frontier near its representation ceiling

Design / plans:

- [Startup, creation and private current state](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state) — iCloud-Drive-Support-Spec.md
- [Concrete returning-launch algorithm](../LocalStore.md#concrete-returning-launch-algorithm) — LocalStore.md
- [8. Phase 4 — Startup, repair, repository copy and private state](../plan/swift-storage-implementation-plan.md#8-phase-4--startup-repair-repository-copy-and-private-state) — swift-storage-implementation-plan.md

### Startup with positively disclosed but unreadable newer evidence

[Open walkthrough](nvstorage-object-map.html#scenario=work-offline&step=1)

A complete returning local history can support Work Offline when startup is waiting for named, positively disclosed newer evidence. Generic provider unavailability is a synchronization status condition and does not require this choice.

**Initial conditions.** Local history is complete. At startup the provider positively discloses newer required object R, whose bytes cannot yet be read.

**Expected outcome.** Work Offline opens the complete local closure and preserves the obligation to reconcile R later.

1. **Positive disclosure of named unread evidence R** (This Mac).

   Observable state: Startup shows a bounded wait for R and offers Work Offline or Save Current Collection As….

   Storage operation: Record positive disclosure and distinguish it from generic offline, quota, permission or timeout status.

   Applicable rule: An evicted provider copy already retained exactly in the private store creates no such wait.

   Read / consume: `appleowner`, `objects`, `pin`.

   Write / produce: `recvwork`.

   Check / gate: `rootowner`.

2. **Explicit continuation from the complete local closure** (This Mac).

   Observable state: All locally durable notes remain editable and searchable.

   Storage operation: Publish the healthy local closure after ordinary ownership/key/startup gates; fence affected provider effects.

   Applicable rule: This choice does not declare R absent, resolved or safe to overwrite. Generic provider unavailability needs no Work Offline prompt.

   Read / consume: `current`, `view`, `pin`.

   Write / produce: `live`, `search`.

   Check / gate: `gate`, `localowner`.

3. **Reconciliation when R becomes readable** (This Mac).

   Observable state: New history reconciles with any local edits without revoking the active session’s editability.

   Storage operation: Retain and validate R, resolve dependencies, then prepare and generation-check its reduction.

   Applicable rule: Late positive disclosure in an already editing session is pending sync status, not a retroactive startup gate.

   Read / consume: `rchanges`.

   Write / produce: `objects`, `receiveq`, `reduce`, `live`.

   Check / gate: `gate`.

Requirements: [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [WAIT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-START-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Healthy local closure with generic offline/full/permission/timeout versus positively disclosed missing newer/required evidence; disclosure before versus after editing starts
- [TC-LIVE-01](../plan/swift-storage-conformance-testing-strategy.md#tc-live-01--local-durability-progresses-with-a-stuck-provider) — Local durability progresses with a stuck provider

Design / plans:

- [Startup, creation and private current state](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state) — iCloud-Drive-Support-Spec.md
- [Repository and private-store damage and repair](../../iCloud-Drive-Support-Spec.md#repository-and-private-store-damage-and-repair) — iCloud-Drive-Support-Spec.md
- [9. Phase 5 — Provider and physical-root adapters](../plan/swift-storage-implementation-plan.md#9-phase-5--provider-and-physical-root-adapters) — swift-storage-implementation-plan.md

### Reconstruction of invalid derived current rows

[Open walkthrough](nvstorage-object-map.html#scenario=derived-rebuild&step=1)

Invalid current-row codecs, dictionaries or prefix binding require reconstruction from healthy retained history. Complete rows and authoring context install under a fresh view epoch while required private records and pending work are preserved.

**Initial conditions.** Retained history is healthy, but a current-cell codec/dictionary or represented-prefix binding is invalid.

**Expected outcome.** Reconstruct the complete current model from validated history, preserving settings, association and pending work.

1. **Classification of derived-row invalidity** (This Mac).

   Observable state: Opening reports reconstruction instead of showing an empty or partial collection.

   Storage operation: Separate current-row/dictionary/view invalidity from retained-history or required-private-state damage.

   Applicable rule: A damaged required pin, association or shared database takes the repair path; it cannot be treated as a disposable row.

   Read / consume: `current`, `dict`, `view`, `header`, `pin`.

   Write / produce: `repairwork`.

   Check / gate: `localowner`.

2. **Reconstruction through the captured accepted prefix** (This Mac).

   Observable state: Recovery prepares every note and compact authoring context off the main thread.

   Storage operation: Verify the snapshot’s logical cut and all accepted outside-cut actions; reduce complete final values/context.

   Applicable rule: Snapshot values alone cannot omit earlier branches, Deletes, restorations or compensation context.

   Read / consume: `objects`, `accepted`, `opindex`, `actionindex`.

   Write / produce: `graph`, `reduce`.

   Check / gate: `verification`.

3. **Generation-checked installation of the complete derived view** (This Mac).

   Observable state: The complete collection reopens with its settings and pending decisions intact.

   Storage operation: Atomically install complete rows/context with a fresh epoch only while owner, accepted target and starting view still match.

   Applicable rule: Required private groups and history remain independently durable; interference forces recapture.

   Read / consume: `reduce`, `private`, `pendingdisk`.

   Write / produce: `current`, `view`, `live`, `search`.

   Check / gate: `gate`.

Requirements: [CKPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-START-01](../plan/swift-storage-conformance-testing-strategy.md#tc-start-01--complete-bootstrap-and-current-row-startup) — Complete bootstrap and current-row startup
- [TC-DUR-06](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Delete/materialization-loss plus removal of a pinned leaf or descriptor; unrelated invalid extra; total Local State loss in a distinct scenario

Design / plans:

- [Exceptional bootstrap and snapshot reconstruction](../LocalStore.md#exceptional-bootstrap-and-snapshot-reconstruction) — LocalStore.md
- [Preparation and installation](../plan/private-current-row-codec.md#preparation-and-installation) — private-current-row-codec.md
- [Startup, creation and private current state](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state) — iCloud-Drive-Support-Spec.md

### Restart during retained-history verification

[Open walkthrough](nvstorage-object-map.html#scenario=verification-restart&step=1)

A durable request records the exact scope before a check that may discover retained-history damage. If checking, diagnosis or settlement is interrupted, reopening replays that obligation before editable publication.

**Initial conditions.** An on-demand history read may discover damage. The process can crash or fail a diagnosis write before recording its result.

**Expected outcome.** A durable verification obligation is replayed before editing; it rechecks evidence instead of replaying a user command.

1. **Durable registration of the verification scope** (This Mac).

   Observable state: The operation enters verification with an exact, recoverable scope.

   Storage operation: Durably retain a host-private request before checking accepted evidence whose damage diagnosis could otherwise disappear.

   Applicable rule: A successful normal open with no unfinished requests keeps the indexed startup path.

   Read / consume: `accepted`, `graph`.

   Write / produce: `verification`.

   Check / gate: `localowner`.

2. **Interrupted verification, diagnosis or settlement** (This Mac).

   Observable state: The app retains the unfinished request, even if writing a damage marker fails.

   Storage operation: Check exact bytes through graph/reducer validation; fence the live owner immediately on discovered damage.

   Applicable rule: Only completed verification settles that request; storage failure leaves a replayable obligation.

   Read / consume: `objects`, `verification`.

   Write / produce: `graph`.

   Check / gate: `gate`.

3. **Replay of the unfinished verification request** (Restart).

   Observable state: Editing waits for the required check or an explicit repair/recovery outcome.

   Storage operation: Replay the retained scope, then atomically settle it or replace it with the diagnosed damage marker.

   Applicable rule: Cancellation/close never turn an unfinished check into a successful one; retries are bounded.

   Read / consume: `verification`, `objects`.

   Write / produce: `repairwork`, `current`, `live`.

   Check / gate: `gate`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-START-01](../plan/swift-storage-conformance-testing-strategy.md#tc-start-01--complete-bootstrap-and-current-row-startup) — Complete bootstrap and current-row startup
- [TC-REPAIR-01](../plan/swift-storage-conformance-testing-strategy.md#tc-repair-01--complementary-copies-repair-private-history-first) — Complementary copies repair private history first
- [TC-DUR-06](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Delete/materialization-loss plus removal of a pinned leaf or descriptor; unrelated invalid extra; total Local State loss in a distinct scenario

Design / plans:

- [Local admission, sealing and recovery](../../iCloud-Drive-Support-Spec.md#local-admission-sealing-and-recovery) — iCloud-Drive-Support-Spec.md
- [Reopening, cancellation and shutdown](../plan/phase-4-improvements/durable-verification-recovery.md#reopening-cancellation-and-shutdown) — durable-verification-recovery.md

### Optional current-row recoding and full-VACUUM maintenance

[Open walkthrough](nvstorage-object-map.html#scenario=idle-maintenance&step=1)

Bounded row recoding preserves logical values and context under exact view/prefix checks. Opportunistic full VACUUM requires a healthy idle store, measured benefit and space budgets, and qualified interruption/commit latency; required persistence takes priority.

**Initial conditions.** A healthy private store qualifies for explicit row recoding or opportunistic full VACUUM under measured fragmentation/space budgets.

**Expected outcome.** Values, accepted history, authoring context and Undo stay identical. Skipped/failed maintenance alone cannot invalidate a durable save.

1. **Capture of a bounded row-recoding candidate** (This Mac).

   Observable state: The active model remains available while optional work is prepared off the main thread.

   Storage operation: Bind exact current cells/dictionary data and logical context to the captured view/prefix.

   Applicable rule: Optional work is neither startup/quit-required nor a substitute for complete validation.

   Read / consume: `current`, `dict`, `view`.

   Write / produce: `maintenance`.

   Check / gate: `localowner`.

2. **Interference by required persistence** (This Mac).

   Observable state: Required persistence takes priority; stale optional installation is rejected or recaptured.

   Storage operation: Check owner/view/prefix and exact row generations before atomic codec/dictionary installation.

   Applicable rule: Recoding changes physical representation, not history identity, note values or causal authoring context.

   Read / consume: `maintenance`, `current`.

   Write / produce: `dict`, `current`.

   Check / gate: `gate`.

3. **Qualified optional database compaction** (This Mac).

   Observable state: Full VACUUM is opportunistic and subject to temporary-space, interruption and commit-latency qualification.

   Storage operation: Invalidate physical read-ahead hints before layout changes and retain worker/owner resources until settling.

   Applicable rule: Automatic execution stays disabled until interruption/settling and durable-commit latency are qualified. Maintenance preserves every logical identity and retained byte; genuine damage follows ordinary recovery.

   Read / consume: `dbcontainer`, `hints`, `maintenance`.

   Write / produce: `maintenance`.

   Check / gate: `localowner`.

Requirements: [CKPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-START-01](../plan/swift-storage-conformance-testing-strategy.md#tc-start-01--complete-bootstrap-and-current-row-startup) — Complete bootstrap and current-row startup
- [TC-PERF-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Fixed realistic note/body/history fixtures, cold/warm reopen, small/large tail, current-cell decode bounds, provider backlog, KDF and active typing

Design / plans:

- [Preparation and installation](../plan/private-current-row-codec.md#preparation-and-installation) — private-current-row-codec.md
- [Adopted opportunistic full-VACUUM policy](../plan/clean-quit-locality-strategy.md#adopted-opportunistic-full-vacuum-policy) — clean-quit-locality-strategy.md
- [Startup, creation and private current state](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state) — iCloud-Drive-Support-Spec.md

## Immutable history, merge and deletion

Dependency-aware reception and publication, note-head reduction, causal Delete/edit handling, and snapshot retention ancestry.

### Receipt of a Delete before its parent edit

[Open walkthrough](nvstorage-object-map.html#scenario=child-first&step=1)

Mac B receives Delete D before edit P, which D observes. B retains D and its reverse waits across restart, then accepts and reduces the complete validated dependency closure when P arrives.

**Initial conditions.** Mac A creates edit P then Delete D observing P. Mac B receives D first and restarts before P arrives.

**Expected outcome.** B retains D as waiting evidence and applies the complete validated closure only after P is durable locally.

1. **Retention of D while parent P is missing** (Mac B).

   Observable state: Mac B keeps its current note; the incomplete child is not yet an applied Delete.

   Storage operation: Retain exact D bytes, record named dependencies and atomically park reverse waits.

   Applicable rule: Stored bytes, accepted causal history and live publication are separate states.

   Read / consume: `rchanges`.

   Write / produce: `objects`, `receiveq`, `recvwork`.

   Check / gate: `rootowner`.

2. **Receipt of P and validation of D’s complete closure** (Mac B).

   Observable state: The durable waiting obligation survives the restart.

   Storage operation: Retain/validate P, wake affected dependents and validate D’s entire action/parent closure.

   Applicable rule: A rejected prerequisite blocks its dependents without discarding shared evidence or accepting a valid-looking prefix.

   Read / consume: `objects`, `receiveq`.

   Write / produce: `batch`, `accepted`, `pin`, `opindex`, `actionindex`.

   Check / gate: `localowner`.

3. **Publication of the accepted causal result** (Mac B).

   Observable state: B now reflects the applicable Delete without emitting a new local echo action.

   Storage operation: Reduce the accepted operation set and publish atomically after current generation checks.

   Applicable rule: Incoming Delete affects a logical birth; it never grants permission to unlink a remembered filename.

   Read / consume: `accepted`, `graph`.

   Write / produce: `reduce`, `live`, `conflicts`.

   Check / gate: `gate`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DELETE-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DISC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-DUR-02](../plan/swift-storage-conformance-testing-strategy.md#tc-dur-02--a-dependent-delete-cannot-outrun-its-parent) — A dependent Delete cannot outrun its parent
- [TC-DISC-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — No presenter callback, callback-before-visibility, coalesced callbacks, new writer directory, sequence holes, renamed valid duplicates

Design / plans:

- [Admission, sealing, and durability without a second WAL](../Protocol.md#admission-sealing-and-durability-without-a-second-wal) — Protocol.md
- [Immutable provider publication and reception](../Protocol.md#immutable-provider-publication-and-reception) — Protocol.md
- [7. Phase 3 — Portable semantics through two independent stores](../plan/swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores) — swift-storage-implementation-plan.md

### Publication retry after an uncertain completion

[Open walkthrough](nvstorage-object-map.html#scenario=publication-retry&step=1)

A retry reuses exact locally accepted bytes and identity. Equal provider finals still require verification and namespace barriers; foreign or contradictory occupants are preserved, and duplicate receipt adds one semantic action.

**Initial conditions.** A locally durable segment was installed at the provider, but its completion was lost. A duplicate or conflicting final name appears.

**Expected outcome.** Retry the same sealed bytes and identity; verify final/directory barriers and preserve conflicting evidence.

1. **Selection of exact locally accepted publication input** (This Mac).

   Observable state: Pending sync selects objects already protected by the local barrier.

   Storage operation: Capture an accepted prefix and retrieve its exact sealed objects/descriptors for publication.

   Applicable rule: A publication retry never reseals changed values under an old operation identity or nonce.

   Read / consume: `accepted`, `objects`, `pin`.

   Write / produce: `pubwork`.

   Check / gate: `localowner`.

2. **Verification of final names and installation barriers** (This Mac).

   Observable state: An equal final can complete a verified retry. A foreign/wrong-kind/contradictory occupant is preserved.

   Storage operation: Use held rooted parents, exclusive creation, exact final-byte checks and required namespace barriers; clean only owned disposable stages.

   Applicable rule: Equal bytes alone do not prove provider installation durability or physical ownership.

   Read / consume: `pubwork`, `rstages`.

   Write / produce: `rchanges`, `rkeys`.

   Check / gate: `rootowner`, `appleowner`.

3. **Idempotent receipt of duplicate objects** (Mac B).

   Observable state: Mac B adds one semantic action, even if filenames or notifications differ.

   Storage operation: Validate bounded bytes and complete identity, deduplicate accepted set insertion, and retain independent legitimate branches.

   Applicable rule: Listings and callbacks are discovery opportunities; omissions, sequence holes and empty passes do not certify completeness.

   Read / consume: `rchanges`, `recvwork`.

   Write / produce: `objects`, `accepted`, `receiveq`.

   Check / gate: `localowner`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DISC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CLEAN-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [AUTH-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-DUR-05](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Private duplicate exact BLOB versus contradictory bytes under one identity; provider equal unqualified final, conflicting/wrong-kind occupant and nested writer directory
- [TC-DISC-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — No presenter callback, callback-before-visibility, coalesced callbacks, new writer directory, sequence holes, renamed valid duplicates
- [TC-ASY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-asy-01--real-actorqueue-wiring-not-only-pure-transitions) — Real actor/queue wiring, not only pure transitions

Design / plans:

- [Immutable provider publication and reception](../Protocol.md#immutable-provider-publication-and-reception) — Protocol.md
- [9. Phase 5 — Provider and physical-root adapters](../plan/swift-storage-implementation-plan.md#9-phase-5--provider-and-physical-root-adapters) — swift-storage-implementation-plan.md

### Automatic merge of strictly separated line edits

[Open walkthrough](nvstorage-object-map.html#scenario=separated-merge&step=1)

Two heads share a unique common base. One changes line 1 and the other changes line 3, with an unchanged line between them. If every field satisfies the conservative rules, reduction derives a combined Current while retaining both inputs.

**Initial conditions.** Both Macs know “Bread / Milk / Apples” on three LF-separated lines. A changes line 1 to Sourdough; B changes line 3 to Pears.

**Expected outcome.** With exactly two eligible heads and a unique common base, Current becomes “Sourdough / Milk / Pears”; both inputs remain history.

1. **Independent revisions from one common base** (Mac A + Mac B).

   Observable state: A sees its first-line edit; B sees its last-line edit.

   Storage operation: Capture distinct complete actions with the exact represented note predecessors and scope parents.

   Applicable rule: Dates and arrival order supply no winner; exact stored UTF-8/CRLF/LF distinctions are preserved.

   Read / consume: `live`, `view`.

   Write / produce: `capture`, `pendinglive`.

   Check / gate: `gate`.

2. **Validation of heads, base and separated edit intervals** (This Mac).

   Observable state: Each receiver retains both complete branches before attempting a merge.

   Storage operation: Derive exact note heads and the unique best common base; calculate one prefix/suffix-bounded edit per branch.

   Applicable rule: Only strictly separated intervals merge. Other fields must also satisfy their rules, together as one result.

   Read / consume: `objects`, `opindex`.

   Write / produce: `graph`, `decoded`, `reduce`.

   Check / gate: `verification`.

3. **Fenced publication of the derived combined Current** (This Mac).

   Observable state: The three lines read Sourdough, Milk, Pears. Both branch IDs remain inspectable.

   Storage operation: Publish the complete derived value and its represented inputs after a live-generation recheck.

   Applicable rule: Automatic recomputation does not mint a random local merge action; third-head or stale inputs require recomputation/review.

   Read / consume: `reduce`, `graph`.

   Write / produce: `live`, `search`, `conflicts`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-MERGE-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Exact LF/CRLF/non-normalized Unicode, repeated lines, empty/unterminated bodies, strictly separated/touching intervals, equal/one-sided long bodies
- [TC-MERGE-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Two heads with unique base; multiple best bases; third/dominating head arriving during preparation; equal-value heads
- [TC-BYTE-01](../plan/swift-storage-conformance-testing-strategy.md#tc-byte-01--canonical-identity-is-neither-transport-identity-nor-display-equality) — Canonical identity is neither transport identity nor display equality

Design / plans:

- [Causal values, conflicts and deletion](../../iCloud-Drive-Support-Spec.md#causal-values-conflicts-and-deletion) — iCloud-Drive-Support-Spec.md
- [Conservative automatic merge version 1](../Protocol.md#conservative-automatic-merge-version-1) — Protocol.md
- [7. Phase 3 — Portable semantics through two independent stores](../plan/swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores) — swift-storage-implementation-plan.md

### Review after overlapping edits or a third head

[Open walkthrough](nvstorage-object-map.html#scenario=merge-review&step=1)

Overlapping or touching edits, ambiguous bases, a third head, or the two-sided line limit prevent automatic merge. All alternatives remain available; a prepared choice must match the complete current inputs at admission.

**Initial conditions.** Two Macs replace “Milk” differently, or a third independent head arrives while a two-head merge is being prepared.

**Expected outcome.** Preserve all alternatives and offer review instead of electing a timestamp winner or pairwise folding three branches.

1. **Discovery of incompatible exact heads** (This Mac).

   Observable state: Current has unresolved alternatives, even if two previews happen to look equal.

   Storage operation: Retain exact revisions and build deterministic head/represented-input evidence.

   Applicable rule: Touching edit intervals, same-boundary insertions, ambiguous best bases, and two-sided bodies over 10,000 lines require review.

   Read / consume: `objects`, `opindex`.

   Write / produce: `graph`, `conflicts`.

   Check / gate: `verification`.

2. **Invalidation of a two-head preparation by a third head** (This Mac).

   Observable state: A prepared two-input result cannot overwrite the now-current three-head state.

   Storage operation: Recheck the complete head set, generation and represented inputs immediately before publication or choice admission.

   Applicable rule: Three heads are not pairwise merged into an invented winner; equal values do not erase revision identities.

   Read / consume: `graph`, `live`.

   Write / produce: `reduce`.

   Check / gate: `gate`.

3. **Preparation and admission of an explicit applicable choice** (This Mac).

   Observable state: The resolver previews exact alternatives. Dismissal before admission leaves note state and history unchanged.

   Storage operation: An explicit applicable choice captures its exact scope, then takes the ordinary complete local action barrier.

   Applicable rule: Preview is side-effect free; changed inputs require new preparation and consent.

   Read / consume: `conflicts`, `graph`.

   Write / produce: `capture`, `pendinglive`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-MERGE-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Exact LF/CRLF/non-normalized Unicode, repeated lines, empty/unterminated bodies, strictly separated/touching intervals, equal/one-sided long bodies
- [TC-MERGE-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Two heads with unique base; multiple best bases; third/dominating head arriving during preparation; equal-value heads
- [TC-UI-01](../plan/swift-storage-conformance-testing-strategy.md#tc-ui-01--apple-disposition-review-and-history-are-separate-commands) — Apple disposition, review, and history are separate commands

Design / plans:

- [Causal values, conflicts and deletion](../../iCloud-Drive-Support-Spec.md#causal-values-conflicts-and-deletion) — iCloud-Drive-Support-Spec.md
- [Conservative automatic merge version 1](../Protocol.md#conservative-automatic-merge-version-1) — Protocol.md
- [Conflict resolver and Apple disposition](../../iCloud-Drive-Support-Spec.md#conflict-resolver-and-apple-disposition) — iCloud-Drive-Support-Spec.md

### Ordinary editing of one unresolved head

[Open walkthrough](nvstorage-object-map.html#scenario=ordinary-conflict-edit&step=1)

An ordinary edit of displayed head A supersedes the represented A input. Known incompatible head B remains unresolved. Releasing the temporary local Current-head pin schedules reduction of the complete applied head set.

**Initial conditions.** Current represents A while incompatible head B is known. The user edits A to A′ before explicitly resolving B.

**Expected outcome.** The ordinary edit supersedes its represented A input and preserves B and independently edited conflict notes.

1. **Current A with unresolved alternative B** (This Mac).

   Observable state: The editor shows A; conflict attention retains B.

   Storage operation: Pair Current with its actual represented note inputs and keep the full applied causal action frontier.

   Applicable rule: Action awareness and note supersession answer different questions.

   Read / consume: `graph`, `view`.

   Write / produce: `live`, `conflicts`.

   Check / gate: `gate`.

2. **Ordinary edit from represented A to A′** (This Mac).

   Observable state: A′ is visible and pending; B is still an alternative.

   Storage operation: Freeze a faithful action before/after pair and predecessor set for Current’s represented A, without silently widening it to B.

   Applicable rule: An explicit resolution or valid automatic merge needs its own complete represented-input evidence.

   Read / consume: `live`, `pendinglive`.

   Write / produce: `capture`.

   Check / gate: `gate`.

3. **Reduction after release of the temporary Current-head pin** (This Mac).

   Observable state: After the exact local barrier, the full applied head set is reduced again.

   Storage operation: Schedule reduction/publication when the temporary editing pin is released, even without another provider callback.

   Applicable rule: Keep independently edited conflict copies; generation checks protect newer typing.

   Read / consume: `accepted`, `graph`, `conflicts`.

   Write / produce: `reduce`, `live`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-SEM-01](../plan/swift-storage-conformance-testing-strategy.md#tc-sem-01--ordinary-edits-preserve-unresolved-alternatives) — Ordinary edits preserve unresolved alternatives
- [TC-MERGE-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Two heads with unique base; multiple best bases; third/dominating head arriving during preparation; equal-value heads

Design / plans:

- [Causal values, conflicts and deletion](../../iCloud-Drive-Support-Spec.md#causal-values-conflicts-and-deletion) — iCloud-Drive-Support-Spec.md
- [Action records and cross-launch undo](../Protocol.md#action-records-and-cross-launch-undo) — Protocol.md
- [7. Phase 3 — Portable semantics through two independent stores](../plan/swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores) — swift-storage-implementation-plan.md

### Concurrent Delete and offline edit on separate Macs

[Open walkthrough](nvstorage-object-map.html#scenario=delete-race&step=1)

Delete D and edit E are authored independently from the same note. Causal reduction deletes the old birth and preserves an otherwise eligible concurrent E in a deterministic conflict birth; an edit covered by D has a different result.

**Initial conditions.** A and B know the same note. A deletes it while B independently edits it without observing the Delete.

**Expected outcome.** The old birth is deleted, while an otherwise eligible concurrent edit is preserved in a deterministic conflict birth.

1. **Independent local acceptance of Delete and edit** (Mac A + Mac B).

   Observable state: Each Mac completes its own full local action/parent barrier.

   Storage operation: Record the Delete’s causal inputs and B’s separate note revision exactly.

   Applicable rule: Logical deletion requires applicable explicit history; a missing provider file is not that intent.

   Read / consume: `live`, `capture`.

   Write / produce: `objects`, `accepted`, `pin`.

   Check / gate: `gate`.

2. **Reduction of the complete Delete/edit history** (This Mac).

   Observable state: The deleted source birth leaves Current; B’s concurrent value remains recoverable.

   Storage operation: Reduce causal Delete/edit relationships and derive the eligible deterministic automatic-preservation birth.

   Applicable rule: An edit already observed by the Delete is covered; an edit descended from the Delete does not revive the old birth.

   Read / consume: `objects`, `graph`.

   Write / produce: `reduce`, `conflicts`, `live`.

   Check / gate: `gate`.

3. **Inspection and fresh-birth restoration of deleted history** (This Mac).

   Observable state: History/Recently Deleted retains exact prior branches. Explicit restoration creates a fresh birth.

   Storage operation: Derive deleted-history entries and restoration provenance separately from filesystem Trash.

   Applicable rule: An incoming Delete cannot physically remove a remembered path; the original exact-snapshot operation owns any such effect.

   Read / consume: `actionindex`, `opindex`.

   Write / produce: `history`, `capture`.

   Check / gate: `gate`.

Requirements: [DELETE-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-DUR-02](../plan/swift-storage-conformance-testing-strategy.md#tc-dur-02--a-dependent-delete-cannot-outrun-its-parent) — A dependent Delete cannot outrun its parent
- [TC-SEM-02](../plan/swift-storage-conformance-testing-strategy.md#tc-sem-02--automatic-preservation-can-retract-without-erasing-independent-work) — Automatic preservation can retract without erasing independent work

Design / plans:

- [Causal values, conflicts and deletion](../../iCloud-Drive-Support-Spec.md#causal-values-conflicts-and-deletion) — iCloud-Drive-Support-Spec.md
- [Admission, sealing, and durability without a second WAL](../Protocol.md#admission-sealing-and-durability-without-a-second-wal) — Protocol.md
- [7. Phase 3 — Portable semantics through two independent stores](../plan/swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores) — swift-storage-implementation-plan.md

### Retraction after a later Delete covers a preserved edit

[Open walkthrough](nvstorage-object-map.html#scenario=retracted-copy&step=1)

An initial Delete concurrent with E derives automatic copy C. A later Delete observing E can retract untouched C once no eligible source remains. Independent edits to C and still-eligible descendants of E remain preserved.

**Initial conditions.** D₀ races with E, creating automatic copy C. Later D₁ observes E. In one branch C is untouched; in another C was edited to P.

**Expected outcome.** Retraction removes an ineligible untouched automatic copy; P and any still-eligible independent descendant survive.

1. **Derivation of automatic copy C for concurrent E** (This Mac).

   Observable state: C appears because E is not covered by D₀.

   Storage operation: Retain source/provenance evidence for the deterministic automatic result.

   Applicable rule: Automatic preservation is derived from complete history, not a new independent user import.

   Read / consume: `graph`, `objects`.

   Write / produce: `conflicts`, `live`.

   Check / gate: `gate`.

2. **Reevaluation after D₁ observes E** (This Mac).

   Observable state: Eligibility is recomputed for the source and its preservation result.

   Storage operation: Prepare retraction only if C has no independent edit and no remaining eligible source value.

   Applicable rule: A new F descended from E but concurrent with D₁ still deserves preservation; P is independent work.

   Read / consume: `graph`, `live`.

   Write / produce: `reduce`.

   Check / gate: `gate`.

3. **Fenced retraction and projection reconciliation** (This Mac).

   Observable state: Untouched C disappears; independently edited P stays. Uncertain external bytes remain pending.

   Storage operation: Generation-fence the model transition and inspect any exact projection before cleanup/import classification.

   Applicable rule: Do not create blind retirement/unlink effects or echo-import the obsolete automatic projection.

   Read / consume: `reduce`, `filework`.

   Write / produce: `live`, `projection`, `pendingdisk`.

   Check / gate: `rootowner`, `gate`.

Requirements: [DELETE-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CLEAN-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-SEM-02](../plan/swift-storage-conformance-testing-strategy.md#tc-sem-02--automatic-preservation-can-retract-without-erasing-independent-work) — Automatic preservation can retract without erasing independent work

Design / plans:

- [Causal values, conflicts and deletion](../../iCloud-Drive-Support-Spec.md#causal-values-conflicts-and-deletion) — iCloud-Drive-Support-Spec.md
- [Action records and cross-launch undo](../Protocol.md#action-records-and-cross-launch-undo) — Protocol.md
- [Current-file decision matrix](../Protocol.md#current-file-decision-matrix) — Protocol.md

### Snapshot retention ancestry and logical operation cuts

[Open walkthrough](nvstorage-object-map.html#scenario=snapshot-retention&step=1)

A general v1 snapshot can retain an exact accepted parent root independently of its represented logical cut. Parent-frontier changes commit atomically; all required ancestor bytes and accepted outside-cut actions remain part of recovery.

**Initial conditions.** General snapshot S₂ names accepted S₁ as a retention parent. A later captured snapshot may represent an older logical cut.

**Expected outcome.** Exact parent closure stays retained; Current and Undo still derive from complete accepted operations, not snapshot age.

1. **Capture of accepted prefix and snapshot-root frontier** (This Mac).

   Observable state: Snapshot preparation captures a consistent accepted prefix plus exact accepted root tips.

   Storage operation: Prepare bounded pages/root and explicit supported retention-parent locators from checked evidence.

   Applicable rule: Snapshot retention parents cover object closure; note predecessors and action scope parents have separate roles.

   Read / consume: `accepted`, `pin`, `graph`.

   Write / produce: `snapwork`.

   Check / gate: `localowner`.

2. **Atomic acceptance of S₂ and its exact parent evidence** (This Mac).

   Observable state: S₁ remains durable while the accepted root frontier advances.

   Storage operation: Atomically retain root/pages, accepted membership, parent edges and wakeups; remove only explicitly named parent tips.

   Applicable rule: Concurrent independent roots remain tips. Empty parent sets use the same eight-category v1 layout. Missing supported dependencies wait normally.

   Read / consume: `snapwork`, `objects`.

   Write / produce: `accepted`, `pin`, `receiveq`, `rgeneral`.

   Check / gate: `localowner`.

3. **Reconstruction including accepted outside-cut actions** (This Mac).

   Observable state: Notes, conflicts, deleted history and Undo still include accepted outside-cut operations.

   Storage operation: Reuse checked logical traversal and retained closure, then reconstruct the complete target prefix if needed.

   Applicable rule: An older logical cut never rolls Current back or authorizes deleting retained ancestor bytes. Sequential covered chains reduce startup root work.

   Read / consume: `objects`, `accepted`, `rgeneral`.

   Write / produce: `graph`, `reduce`, `current`, `view`.

   Check / gate: `verification`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CLEAN-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CKPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-START-01](../plan/swift-storage-conformance-testing-strategy.md#tc-start-01--complete-bootstrap-and-current-row-startup) — Complete bootstrap and current-row startup
- [TC-LIMIT-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Same valid long graph with small/large work budgets, resumed repeatedly, plus a wide frontier near its representation ceiling

Design / plans:

- [Storage, identity and ownership](../../iCloud-Drive-Support-Spec.md#storage-identity-and-ownership) — iCloud-Drive-Support-Spec.md
- [State and history responsibilities](../plan/general-snapshot-record-contract.md#state-and-history-responsibilities) — general-snapshot-record-contract.md
- [Snapshots, startup, rejoin, and retention](../Protocol.md#snapshots-startup-rejoin-and-retention) — Protocol.md

## History, restoration and compensation

Historical field recovery, fresh-birth Restore, causal Undo/Redo, native remaining-effect coverage, and shared-window ownership.

### Historical body restoration with current title and labels

[Open walkthrough](nvstorage-object-map.html#scenario=selective-history&step=1)

Note History supplies an exact retained body for a new recovery action. Body restoration preserves current title and labels unless those fields are explicitly selected, and admission revalidates Current and the complete preview.

**Initial conditions.** “Travel 2027” has a current title and labels. The user opens Note History and selects an older body while retaining those current fields.

**Expected outcome.** A newly admitted historical-recovery action restores the selected fields after Current revalidation; the old history remains.

1. **Read-only preview of a retained historical body** (This Mac).

   Observable state: History shows read-only Current, known branches and informational dates. Preview changes nothing.

   Storage operation: Load a scoped historical query from retained exact revision/action evidence.

   Applicable rule: The viewer is not a promise of complete global timeline or full-history search; late results cannot reopen a dismissed view.

   Read / consume: `actionindex`, `opindex`, `objects`.

   Write / produce: `history`, `graph`.

   Check / gate: `gate`.

2. **Selection of body restoration against exact Current** (This Mac).

   Observable state: The review shows today’s title/labels preserved and the chosen historical body.

   Storage operation: Capture the selected fields and complete preview with Current’s exact birth, value and generation.

   Applicable rule: Body is the default selection; title/labels require explicit selection. Stale Current requires fresh preparation.

   Read / consume: `history`, `live`, `graph`.

   Write / produce: `capture`.

   Check / gate: `gate`.

3. **Acceptance of the new historical-recovery action** (This Mac).

   Observable state: The restored body is ordinary current work with a durable source link and an actual inverse.

   Storage operation: Admit the complete group, then seal/accept it through the ordinary local barrier.

   Applicable rule: Save as new note is a separate fresh-birth action; history recovery neither disposes conflict heads nor resolves Apple versions.

   Read / consume: `capture`, `seal`.

   Write / produce: `objects`, `accepted`, `actionindex`, `live`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-UI-01](../plan/swift-storage-conformance-testing-strategy.md#tc-ui-01--apple-disposition-review-and-history-are-separate-commands) — Apple disposition, review, and history are separate commands
- [TC-CAP-01](../plan/swift-storage-conformance-testing-strategy.md#tc-cap-01--a-faithful-frozen-action-not-just-durable-bytes) — A faithful frozen action, not just durable bytes

Design / plans:

- [Note History, Recently Deleted and undo](../../iCloud-Drive-Support-Spec.md#note-history-recently-deleted-and-undo) — iCloud-Drive-Support-Spec.md
- [Historical recovery and deleted-note history](../Protocol.md#historical-recovery-and-deleted-note-history) — Protocol.md
- [Per-note history and selective recovery](../Implementation.md#per-note-history-and-selective-recovery) — Implementation.md

### Named restoration followed by deletion of the fresh birth

[Open walkthrough](nvstorage-object-map.html#scenario=recently-deleted&step=1)

Restore creates a fresh birth linked to a named deleted entry. Complete durable restoration evidence excludes that source entry from the default list; deleting the restored birth later creates a separate entry.

**Initial conditions.** “Ideas” appears in Recently Deleted. The user restores its named entry, then later deletes the restored birth.

**Expected outcome.** The original entry leaves the default list only after durable restoration evidence. The later Delete creates its own entry.

1. **Selection of a named deleted-history entry** (This Mac).

   Observable state: A separate read-only viewer offers Restore and shows prior recoverable branches.

   Storage operation: Derive the entry from applicable Delete and exact revision/action evidence.

   Applicable rule: This is retained note history, independent of Trash and any physical-file sweep.

   Read / consume: `actionindex`, `opindex`, `objects`.

   Write / produce: `history`.

   Check / gate: `gate`.

2. **Restore admission and durability for fresh birth R** (This Mac).

   Observable state: R is pending until its complete local action and source provenance are durable.

   Storage operation: Capture a fresh birth with exact restoredFrom deletion/revision evidence and commit it with its action.

   Applicable rule: Only completed named restoration hides the source entry; generic historical copies do not. Projection/upload need not finish.

   Read / consume: `history`, `capture`.

   Write / produce: `accepted`, `actionindex`, `live`.

   Check / gate: `gate`.

3. **Later deletion of R or concurrent independent restoration** (This Mac).

   Observable state: R’s Delete yields a new entry; a concurrent explicit restore on another Mac has its own birth.

   Storage operation: Retain the old source restoration link even if R is edited or deleted; reduce each fresh birth independently.

   Applicable rule: The original entry does not reappear based on whether R is live. Concurrent restores may both remain.

   Read / consume: `objects`, `actionindex`.

   Write / produce: `history`, `conflicts`.

   Check / gate: `gate`.

Requirements: [DELETE-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-ACT-05](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Restore a named Recently Deleted entry; fail/pause barrier; delete the fresh restored birth; generic historical copy; concurrent restores
- [TC-ACT-03](../plan/swift-storage-conformance-testing-strategy.md#tc-act-03--concurrent-compensation-and-fresh-birth-continuation) — Concurrent compensation and fresh-birth continuation

Design / plans:

- [Note History, Recently Deleted and undo](../../iCloud-Drive-Support-Spec.md#note-history-recently-deleted-and-undo) — iCloud-Drive-Support-Spec.md
- [Historical recovery and deleted-note history](../Protocol.md#historical-recovery-and-deleted-note-history) — Protocol.md
- [7. Phase 3 — Portable semantics through two independent stores](../plan/swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores) — swift-storage-implementation-plan.md

### Causal Undo after relaunch or on another Mac

[Open walkthrough](nvstorage-object-map.html#scenario=portable-undo&step=1)

Validated action records preserve exact members, before/after references and scope parents. Any Mac may compensate a unique applicable maximal action; incomparable or overlapping candidates require review, and bulk admission applies to the whole group.

**Initial conditions.** Mac A renames a note. After the action is durably synced, Mac B opens it and invokes Undo Rename.

**Expected outcome.** A unique applicable maximal action can be compensated on B; the new complete action preserves unrelated current changes.

1. **Capture and acceptance of the rename action on Mac A** (Mac A).

   Observable state: A sees the new title; its saved action includes exact before/after references and scope parents.

   Storage operation: Freeze operation members, origin provenance and every maximal action represented by the captured applied frontier.

   Applicable rule: Received-but-unapplied bytes and incompletely loaded history rows do not define the writer’s scope.

   Read / consume: `live`, `view`, `pendinglive`.

   Write / produce: `capture`, `accepted`, `actionindex`.

   Check / gate: `gate`.

2. **Derivation of Mac B’s applicable maximal Undo candidate** (Mac B).

   Observable state: B offers the unique causally maximal applicable rename, regardless of its origin or arrival time.

   Storage operation: Build a scoped candidate view from validated action/scope-parent/compensation evidence and actual Current.

   Applicable rule: Old NSUndoManager entries, selectors and pointers are not persisted. Incomparable/overlapping candidates require review.

   Read / consume: `actionindex`, `graph`, `live`.

   Write / produce: `undo`.

   Check / gate: `gate`.

3. **Admission and acceptance of complete guarded compensation** (Mac B).

   Observable state: The title reverses while unrelated body/labels remain. History and causal eligibility recover together.

   Storage operation: Admit all compensation members or none, then commit its complete action/parent closure.

   Applicable rule: Bulk work is wholly revalidated; oversized groups must be disclosed as separate independently undoable batches before admission.

   Read / consume: `undo`, `capture`.

   Write / produce: `objects`, `accepted`, `actionindex`, `live`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-ACT-01](../plan/swift-storage-conformance-testing-strategy.md#tc-act-01--validate-the-complete-writer-scope-not-the-receivers-current-view) — Validate the complete writer scope, not the receiver's current view
- [TC-CAP-02](../plan/swift-storage-conformance-testing-strategy.md#tc-cap-02--native-coverage-and-composition-survive-the-real-application-seam) — Native coverage and composition survive the real application seam
- [TC-ACT-04](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Bulk action where one member is invalid/stale/unsupported; complete valid neighbors; repeated retry after partial I/O

Design / plans:

- [Action records and cross-launch undo](../Protocol.md#action-records-and-cross-launch-undo) — Protocol.md
- [Note History, Recently Deleted and undo](../../iCloud-Drive-Support-Spec.md#note-history-recently-deleted-and-undo) — iCloud-Drive-Support-Spec.md
- [7. Phase 3 — Portable semantics through two independent stores](../plan/swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores) — swift-storage-implementation-plan.md

### Reviewed Undo with an actual-current inverse

[Open walkthrough](nvstorage-object-map.html#scenario=reviewed-undo&step=1)

Rename B was Shopping → Groceries, while a represented concurrent action makes Current Errands. Approved Undo B records Errands → Shopping; its Redo reverses that actual compensation to Errands.

**Initial conditions.** Rename B was Shopping → Groceries. A represented concurrent action supplies Current = Errands. The user selects B through Undo review and explicitly approves replacement with Shopping.

**Expected outcome.** The new compensation records Errands → Shopping; its Redo returns to Errands, while preserving the remaining eligible redo chain.

1. **Undo B preparation against represented Current Errands** (This Mac).

   Observable state: A dismissible read-only review explains the overlap and the captured candidate frontier.

   Storage operation: Prepare the actual proposed compensation from Errands to approved Shopping in the invocation’s Undo mode.

   Applicable rule: Preview/Cancel consumes nothing. Note History and conflict commands remain distinct even with identical text.

   Read / consume: `undo`, `graph`, `live`.

   Write / produce: `history`.

   Check / gate: `gate`.

2. **Approval and admission of Errands → Shopping** (This Mac).

   Observable state: Shopping becomes pending only if the captured Current and candidate frontier still match.

   Storage operation: Freeze actual before = Errands and after = Shopping, with exact undoOf/action/causal evidence.

   Applicable rule: Approval does not bypass missing evidence, no-op checks, format/birth/generation gates or retarget a changed candidate.

   Read / consume: `history`, `undo`, `live`.

   Write / produce: `capture`, `pendinglive`.

   Check / gate: `gate`.

3. **Redo derived from the actual accepted compensation** (This Mac).

   Observable state: Redo restores Errands. Other eligible causal redo steps remain independently available.

   Storage operation: Validate and append the inverse of the actual reviewed action, not the historical Groceries value.

   Applicable rule: Reviewed compensation affects the selected action; it never silently consumes siblings or substitutes generic recovery.

   Read / consume: `actionindex`, `graph`, `undo`.

   Write / produce: `capture`, `accepted`, `live`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-ACT-02](../plan/swift-storage-conformance-testing-strategy.md#tc-act-02--reviewed-compensation-preserves-the-actual-inverse) — Reviewed compensation preserves the actual inverse
- [TC-UI-01](../plan/swift-storage-conformance-testing-strategy.md#tc-ui-01--apple-disposition-review-and-history-are-separate-commands) — Apple disposition, review, and history are separate commands

Design / plans:

- [Invocation-scoped Undo/Redo review](../Implementation.md#invocation-scoped-undoredo-review) — Implementation.md
- [Action records and cross-launch undo](../Protocol.md#action-records-and-cross-launch-undo) — Protocol.md
- [Note History, Recently Deleted and undo](../../iCloud-Drive-Support-Spec.md#note-history-recently-deleted-and-undo) — iCloud-Drive-Support-Spec.md

### Concurrent compensation of the same action

[Open walkthrough](nvstorage-object-map.html#scenario=concurrent-undo&step=1)

Two Macs can each admit compensation of X before learning of the other. U and V remain distinct actions. Candidate ambiguity is relative to direction and compensation family, and reversing one restored birth preserves the other.

**Initial conditions.** A and B independently prepare Undo of action X. Each commits its own compensation U or V before learning of the other.

**Expected outcome.** Both actions survive. Competing family descendants require scoped review; unrelated later actions retain their own eligibility.

1. **Independent admission of Undo X on two Macs** (Mac A + Mac B).

   Observable state: Each local capture is checked against its own complete candidate frontier and Current.

   Storage operation: Allocate distinct immutable compensation identities and preserve exact undoOf evidence.

   Applicable rule: There is no distributed exactly-once pop or mutable cross-Mac undo cursor.

   Read / consume: `undo`, `live`, `graph`.

   Write / produce: `capture`, `accepted`.

   Check / gate: `gate`.

2. **Candidate derivation after receipt of U and V** (This Mac).

   Observable state: Equal effects may converge visibly, while competing descendants remain reviewable.

   Storage operation: Derive direction-relative candidates and compensation families, keeping every causal action.

   Applicable rule: After reviewed Redo U, a now-no-op Redo V creates nothing and consumes no eligibility. A separate X family can still undo/redo automatically.

   Read / consume: `objects`, `actionindex`.

   Write / produce: `graph`, `undo`, `conflicts`.

   Check / gate: `gate`.

3. **Independent fresh-birth mappings for Undo Delete** (This Mac).

   Observable state: Two concurrent restorations produce distinct fresh births; reversing one preserves the other.

   Storage operation: Record exact fresh-birth mapping in each compensation and reverse only the selected mapping.

   Applicable rule: A later reversal of that deletion needs another fresh birth; no historical branch is collapsed by equal preview bytes.

   Read / consume: `undo`, `actionindex`.

   Write / produce: `capture`, `live`, `history`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DELETE-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-ACT-03](../plan/swift-storage-conformance-testing-strategy.md#tc-act-03--concurrent-compensation-and-fresh-birth-continuation) — Concurrent compensation and fresh-birth continuation
- [TC-ACT-02](../plan/swift-storage-conformance-testing-strategy.md#tc-act-02--reviewed-compensation-preserves-the-actual-inverse) — Reviewed compensation preserves the actual inverse

Design / plans:

- [Action records and cross-launch undo](../Protocol.md#action-records-and-cross-launch-undo) — Protocol.md
- [Note History, Recently Deleted and undo](../../iCloud-Drive-Support-Spec.md#note-history-recently-deleted-and-undo) — iCloud-Drive-Support-Spec.md
- [7. Phase 3 — Portable semantics through two independent stores](../plan/swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores) — swift-storage-implementation-plan.md

### Partial native Undo followed by relaunch

[Open walkthrough](nvstorage-object-map.html#scenario=native-remaining&step=1)

Partial native reversal records exact remaining-effect coverage for saved typing actions. Reopening derives portable eligibility from retained coverage and Current lineage, so an already reversed effect is not compensated twice.

**Initial conditions.** A saved typing action contains several edits. Native Undo reverses only part, then the app closes and reopens.

**Expected outcome.** The durable remaining-effect claim prevents a later coarse Undo from reversing the already undone part twice.

1. **Causal eligibility check before native Undo consumption** (This Mac).

   Observable state: The existing native text operation runs only after the shared causal router approves its candidate.

   Storage operation: Check current text-state/range validity and causal eligibility before consuming a native entry.

   Applicable rule: A later remote rename can change the eligible action even if native body ranges still look valid.

   Read / consume: `views`, `undo`, `live`.

   Write / produce: `pendinglive`, `capture`.

   Check / gate: `gate`.

2. **Durable remaining-effect coverage and note compensation** (This Mac).

   Observable state: The partial reversal records which saved-action effects remain, with exact state references.

   Storage operation: Commit the native-coverage compensation together with its complete note effects and dependencies.

   Applicable rule: Coverage follows action ancestry; incomparable maximal claims require review, not an arbitrary newest claim.

   Read / consume: `capture`, `graph`.

   Write / produce: `accepted`, `actionindex`, `pin`.

   Check / gate: `localowner`.

3. **Portable candidate reconstruction after reopening** (Restart).

   Observable state: Only the remaining eligible effect is proposed. Old Cocoa grouping/selection is not reconstructed.

   Storage operation: Build candidates from retained coverage and Current’s represented lineage, including all relevant families.

   Applicable rule: Saved-edit granularity survives; per-keystroke cross-device stacks and executable native objects do not.

   Read / consume: `actionindex`, `view`, `live`.

   Write / produce: `undo`, `history`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-CAP-02](../plan/swift-storage-conformance-testing-strategy.md#tc-cap-02--native-coverage-and-composition-survive-the-real-application-seam) — Native coverage and composition survive the real application seam
- [TC-ACT-01](../plan/swift-storage-conformance-testing-strategy.md#tc-act-01--validate-the-complete-writer-scope-not-the-receivers-current-view) — Validate the complete writer scope, not the receiver's current view

Design / plans:

- [Action records and cross-launch undo](../Protocol.md#action-records-and-cross-launch-undo) — Protocol.md
- [Note History, Recently Deleted and undo](../../iCloud-Drive-Support-Spec.md#note-history-recently-deleted-and-undo) — iCloud-Drive-Support-Spec.md
- [Shared-note windows and editor ownership](../Implementation.md#shared-note-windows-and-editor-ownership) — Implementation.md

### Shared-note windows during composition and remote publication

[Open walkthrough](nvstorage-object-map.html#scenario=shared-windows&step=1)

Two windows reference one live note and per-note Undo owner while retaining independent selections. Remote body publication observes the native input boundary and revalidates note, attachment, store, root and lifecycle generations.

**Initial conditions.** Windows X and Y show the same note. X starts composition; Y changes selection or closes while a remote result is pending.

**Expected outcome.** Input uses normal AppKit event delivery. Admitted work survives attachment changes; remote publication waits for an applicable native input boundary and revalidates its captured context.

1. **Independent view attachments to one live note** (This Mac).

   Observable state: Each view has its own selection/scroll while edits belong to the shared note and Undo scope.

   Storage operation: Attach observers to one live model; retain remembered cursor updates as private presentation state.

   Applicable rule: View observers must not duplicate mutation, action registration or pending capture.

   Read / consume: `live`, `undo`.

   Write / produce: `views`, `private`.

   Check / gate: `gate`.

2. **Native composition while remote publication is prepared** (This Mac).

   Observable state: Input uses normal native event delivery. A prepared remote body may wait for an applicable native input boundary before publication.

   Storage operation: Retain captured attachment/note/generation evidence and defer applicable remote body publication as required by the host bridge.

   Applicable rule: Composition alone creates no conflict prompt or durable IME buffer. Search remains synchronous.

   Read / consume: `views`, `live`, `reduce`.

   Write / produce: `pendinglive`.

   Check / gate: `gate`.

3. **Attachment changes before a late completion** (This Mac).

   Observable state: Admitted history continues; a late callback cannot target a different attachment or overwrite newer text.

   Storage operation: Revalidate the native input boundary, note/root/store/lifecycle generations and attachment identity at the actual consumer.

   Applicable rule: Closing the last view does not discard pending history. Native keyboard/IME integration still has its own qualification gate.

   Read / consume: `pendinglive`, `capture`, `views`.

   Write / produce: `live`, `undo`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-CAP-02](../plan/swift-storage-conformance-testing-strategy.md#tc-cap-02--native-coverage-and-composition-survive-the-real-application-seam) — Native coverage and composition survive the real application seam
- [TC-ASY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-asy-01--real-actorqueue-wiring-not-only-pure-transitions) — Real actor/queue wiring, not only pure transitions
- [TC-PERF-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Fixed realistic note/body/history fixtures, cold/warm reopen, small/large tail, current-cell decode bounds, provider backlog, KDF and active typing

Design / plans:

- [Shared-note windows and editor ownership](../Implementation.md#shared-note-windows-and-editor-ownership) — Implementation.md
- [Input and content scope](../../iCloud-Drive-Support-Spec.md#input-and-content-scope) — iCloud-Drive-Support-Spec.md
- [Text input and undo platform boundary](../../Apple-API-Contract-Validation.md#text-input-and-undo-platform-boundary) — Apple-API-Contract-Validation.md
- [11. Phase 7 — Application capture, history UI and lifecycle](../plan/swift-storage-implementation-plan.md#11-phase-7--application-capture-history-ui-and-lifecycle) — swift-storage-implementation-plan.md

### Dedicated saved-search windows and bookmark preferences

[Open walkthrough](nvstorage-object-map.html#scenario=saved-search-windows&step=1)

Each saved search owns a reusable ordinary window over the shared collection. Activation preserves other windows’ queries and selections; bookmark-scoped preferences retain frame and open state across launches.

**Initial conditions.** An ordinary window shows “inbox”. The user activates saved searches Work and Personal, then activates Work again before relaunching.

**Expected outcome.** Each bookmark reuses its dedicated shared-model window. Existing bookmark preferences remember its frame and open state; the collection and note Undo remain shared.

1. **Bookmark activation and dedicated-window creation** (This Mac).

   Observable state: A dedicated Work window opens with its saved search and remembered note. The inbox window keeps its own presentation.

   Storage operation: The existing bookmark owner routes activation through open-window management and initializes a view over the same live collection.

   Applicable rule: Search stays synchronous. Query, selection, layout and focus are view state; opening a window creates no second database, writer identity or action branch.

   Read / consume: `hostprefs`, `live`.

   Write / produce: `views`, `search`.

   Check / gate: `gate`.

2. **Reuse of Work while Personal remains independently presented** (This Mac).

   Observable state: Personal has its own query. Work’s existing window comes to the foreground instead of duplicating or replacing another view.

   Storage operation: Resolve the bookmark-to-window association; edits and per-note Undo continue through the one shared model and causal router.

   Applicable rule: Commands target the invoking window’s actual note/attachment. Closing a bookmark window releases presentation resources while admitted note work survives.

   Read / consume: `hostprefs`, `live`, `undo`.

   Write / produce: `views`, `pendinglive`.

   Check / gate: `gate`.

3. **Preference retention and reopening of existing bookmarks** (Restart).

   Observable state: Remembered open windows for bookmarks that still exist reopen with their saved searches and placement.

   Storage operation: Persist bookmark-scoped frame/open-state through the existing bookmark preference path; rebuild views only after complete current/search readiness.

   Applicable rule: This is private UI preference data, separate from causal note actions. It does not promise restoration of every arbitrary ordinary window; query-edit/removal behavior remains a named UI decision.

   Read / consume: `views`, `current`, `view`.

   Write / produce: `hostprefs`, `views`, `search`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-CAP-02](../plan/swift-storage-conformance-testing-strategy.md#tc-cap-02--native-coverage-and-composition-survive-the-real-application-seam) — Native coverage and composition survive the real application seam
- [TC-PERF-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Fixed realistic note/body/history fixtures, cold/warm reopen, small/large tail, current-cell decode bounds, provider backlog, KDF and active typing
- [TC-CLOSE-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Close with pending edits/external-editor handoff; materialization failure; pin/settings failure; provider wait; cancel/retry; old callbacks after switch

These contracts cover the shared-editor, synchronous-search and lifecycle seams. Dedicated bookmark activation/frame/reopen acceptance is specified in the linked window feature contract and retains its application integration gate.

Design / plans:

- [Note Bookmarks: a dedicated window per saved search](../Window-UI-Architecture.md#note-bookmarks-a-dedicated-window-per-saved-search) — Window-UI-Architecture.md
- [Shared-note windows and editor ownership](../Implementation.md#shared-note-windows-and-editor-ownership) — Implementation.md
- [11. Phase 7 — Application capture, history UI and lifecycle](../plan/swift-storage-implementation-plan.md#11-phase-7--application-capture-history-ui-and-lifecycle) — swift-storage-implementation-plan.md

### Durable preservation of a selected unresolved revision

[Open walkthrough](nvstorage-object-map.html#scenario=conflict-copy&step=1)

Save as new note records exact copy and disposition evidence for the selected revision without superseding the source. Reciprocal explicit copies can produce distinct births; completed disposition survives later copy edits or deletion.

**Initial conditions.** Two Macs independently choose Save as new note for exact unresolved revision R of an NV-head conflict.

**Expected outcome.** Each explicit copy may have its own birth. Completed preservation hides only the selected revision’s unresolved attention.

1. **Captured preview of source revision R in NV-copy mode** (This Mac).

   Observable state: The resolver has a captured NV-copy command and exact selected revision.

   Storage operation: Validate source revision, selected mode, Current and candidate copy evidence.

   Applicable rule: A body-equal or already modified/deleted candidate is not automatically exact reusable preservation evidence.

   Read / consume: `conflicts`, `graph`, `history`.

   Write / produce: `capture`.

   Check / gate: `gate`.

2. **Durable copy and source-disposition evidence** (This Mac).

   Observable state: The new note and completed source disposition become durable before attention is settled.

   Storage operation: Commit exact copy/action/provenance evidence and its complete dependency closure.

   Applicable rule: No source Put/Delete/Keep Current or supersession is emitted just to preserve R.

   Read / consume: `capture`, `seal`.

   Write / produce: `accepted`, `actionindex`, `live`.

   Check / gate: `localowner`.

3. **Reconciliation of reciprocal copies and later copy deletion** (This Mac).

   Observable state: The original plus two recovered copies may remain, even with equal bodies.

   Storage operation: Derive unresolved attention from durable completed dispositions while reducing the source independently.

   Applicable rule: Completed disposition survives copy edits/deletion and reopen; new source descendants remain reviewable.

   Read / consume: `actionindex`, `graph`.

   Write / produce: `conflicts`, `history`.

   Check / gate: `gate`.

Requirements: [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-UI-01](../plan/swift-storage-conformance-testing-strategy.md#tc-ui-01--apple-disposition-review-and-history-are-separate-commands) — Apple disposition, review, and history are separate commands
- [TC-SEM-01](../plan/swift-storage-conformance-testing-strategy.md#tc-sem-01--ordinary-edits-preserve-unresolved-alternatives) — Ordinary edits preserve unresolved alternatives

Design / plans:

- [Conflict resolver and Apple disposition](../../iCloud-Drive-Support-Spec.md#conflict-resolver-and-apple-disposition) — iCloud-Drive-Support-Spec.md
- [Note History, Recently Deleted and undo](../../iCloud-Drive-Support-Spec.md#note-history-recently-deleted-and-undo) — iCloud-Drive-Support-Spec.md
- [Action records and cross-launch undo](../Protocol.md#action-records-and-cross-launch-undo) — Protocol.md

## Plaintext files and external versions

File observation and provenance, automatic import, pending input retention, projection installation, external deletion, and Apple version disposition.

### Automatic import of an eligible ordinary text file

[Open walkthrough](nvstorage-object-map.html#scenario=automatic-import&step=1)

An ordinary unstamped file imports after provenance, availability and narrowly scoped repair-candidate checks. One admitted observation retains its retry identity; later duplicate knowledge preserves independently created births.

**Initial conditions.** An ordinary unstamped txt file appears in the repository. Provenance and availability checks permit inspection, and there is no applicable association or narrowly scoped repair candidate.

**Expected outcome.** NV creates one fresh birth for that admitted observation. If delayed history later reveals a duplicate, both independent births survive.

1. **Verified observation and ordinary-file classification** (This Mac).

   Observable state: NV reads a verified current file through matching complete catalogs around the selected read.

   Storage operation: Check availability/provenance and per-note active-path or exact nonempty-content repair exceptions first.

   Applicable rule: Missing metadata alone does not prompt. Quiet catalogs do not prove that unknown remote history is complete.

   Read / consume: `rnotes`, `filework`.

   Write / produce: `pendingdisk`, `pendingwork`.

   Check / gate: `rootowner`.

2. **Admission of one fresh import identity** (This Mac).

   Observable state: The eligible file becomes a new note through ordinary admission and complete action capture.

   Storage operation: Reserve exact observation/operation identity and freeze input values; commit its history and eventual relationship evidence.

   Applicable rule: Retry of one admitted observation reuses its identity; equal independent files are not globally deduplicated by body/name.

   Read / consume: `pendingwork`, `pendingdisk`.

   Write / produce: `capture`, `accepted`, `actionindex`.

   Check / gate: `gate`.

3. **Receipt of delayed history after independent import** (This Mac).

   Observable state: Both independently created births remain; new evidence can change future classification.

   Storage operation: Union incoming history and revalidate provenance/associations without rewriting the admitted import’s identity.

   Applicable rule: Late duplicate knowledge does not retroactively merge unrelated births or replay old consent.

   Read / consume: `rchanges`, `objects`, `actionindex`.

   Write / produce: `graph`, `live`, `projection`.

   Check / gate: `gate`.

Requirements: [IMPORT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DISC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-IMPORT-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — [Adopted import/pending matrix](../Verification.md#external-file-admission-and-pending-recovery--adopted-policy): ordinary new files, unrelated missing notes, per-note active path/exact nonempty-content candidates, missing/copied provenance; latest B versus admitted frozen A; competing/no-op associations; A→B→C projections; repeated crashes before/after operation/pin/receipt; later Delete
- [TC-PROJ-01](../plan/swift-storage-conformance-testing-strategy.md#tc-proj-01--body-stamp-and-history-arrive-independently) — Body, stamp, and history arrive independently

Design / plans:

- [Current-file decision matrix](../Protocol.md#current-file-decision-matrix) — Protocol.md
- [Separate plaintext files](../../iCloud-Drive-Support-Spec.md#separate-plaintext-files) — iCloud-Drive-Support-Spec.md
- [External-file admission and pending decisions](../Implementation.md#external-file-admission-and-pending-decisions) — Implementation.md
- [10. Phase 6 — Plaintext projection and pending-file recovery](../plan/swift-storage-implementation-plan.md#10-phase-6--plaintext-projection-and-pending-file-recovery) — swift-storage-implementation-plan.md

### Projection stamp arriving before its named history

[Open walkthrough](nvstorage-object-map.html#scenario=stamp-waits&step=1)

A file with a projection stamp naming unavailable history waits for that exact evidence. Once the represented state and unique association validate against current bytes, the file associates with the existing birth without an echo Put.

**Initial conditions.** A note body and bounded projection stamp arrive, but the exact immutable history named by the stamp has not.

**Expected outcome.** NV waits for the named evidence; once exact represented state validates, it associates without an echo Put.

1. **Independent observation of body and bounded stamp** (This Mac).

   Observable state: The file is not imported as a new birth merely because its history is delayed.

   Storage operation: Parse bounded advisory metadata and record exact missing locators while preserving body bytes.

   Applicable rule: Body/xattr arrival is not atomic; a stamp is neither physical authority nor an authenticated substitute for history.

   Read / consume: `rnotes`, `filework`.

   Write / produce: `pendingdisk`, `recvwork`.

   Check / gate: `rootowner`.

2. **Validation of the stamp’s named history and represented state** (This Mac).

   Observable state: Complete dependencies establish the represented birth/state and exact output digest.

   Storage operation: Validate envelope/schema/history and unique association evidence against the actual current file.

   Applicable rule: Malformed/copied/wrong-collection/stale stamps authorize no alias, overwrite or deletion; uncertainty preserves bytes.

   Read / consume: `rchanges`, `pendingdisk`.

   Write / produce: `objects`, `graph`.

   Check / gate: `localowner`.

3. **Fresh physical association and receipt installation** (This Mac).

   Observable state: The matching file represents the existing note without manufacturing another note action.

   Storage operation: Commit freshly validated relationship/receipt state, then reconcile subsequent external changes normally.

   Applicable rule: No timeout or quiet-catalog count converts missing named history into a new-birth permission.

   Read / consume: `graph`, `filework`.

   Write / produce: `projectiondisk`, `projection`.

   Check / gate: `gate`, `rootowner`.

Requirements: [DISC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [IMPORT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [AUTH-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-PROJ-01](../plan/swift-storage-conformance-testing-strategy.md#tc-proj-01--body-stamp-and-history-arrive-independently) — Body, stamp, and history arrive independently
- [TC-DISC-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — No presenter callback, callback-before-visibility, coalesced callbacks, new writer directory, sequence holes, renamed valid duplicates

Design / plans:

- [Projection stamp and delayed-history handling](../Protocol.md#projection-stamp-and-delayed-history-handling) — Protocol.md
- [Separate plaintext files](../../iCloud-Drive-Support-Spec.md#separate-plaintext-files) — iCloud-Drive-Support-Spec.md
- [10. Phase 6 — Plaintext projection and pending-file recovery](../plan/swift-storage-implementation-plan.md#10-phase-6--plaintext-projection-and-pending-file-recovery) — swift-storage-implementation-plan.md

### Source change before external-file choice admission

[Open walkthrough](nvstorage-object-map.html#scenario=pending-choice&step=1)

A pending choice previews A, then the source changes to B before approval. Latest-reference replacement is durable and generation-checked; the old A preparation is rejected rather than retargeted to B.

**Initial conditions.** A repair/recovery choice previews external value A. Another editor saves B before the user approves A.

**Expected outcome.** The stale preparation is rejected and the latest durable preview refreshes; prior consent never retargets B.

1. **Durable retention and preview of source A** (This Mac).

   Observable state: The read-only choice shows exact captured A and its proposed target relationship.

   Storage operation: Commit the latest verified payload and its reference before reporting durable retention. Keep unadmitted consent process-local.

   Applicable rule: Merely previewing every external save does not create an archive or an admitted operation.

   Read / consume: `rnotes`, `filework`.

   Write / produce: `pendingdisk`, `pendingwork`.

   Check / gate: `rootowner`.

2. **Replacement of the latest verified snapshot with B** (This Mac).

   Observable state: The latest preview becomes B only after its payload and reference are durable.

   Storage operation: Generation-check the snapshot replacement transaction while preserving still-frozen operation references.

   Applicable rule: Rollback keeps the prior durable pair; an ambiguous outcome is resolved by exact identity lookup.

   Read / consume: `filework`, `pendingdisk`.

   Write / produce: `pendingdisk`, `pendingwork`.

   Check / gate: `localowner`.

3. **Rejection of the stale A preparation at admission** (This Mac).

   Observable state: No note mutation occurs from stale consent; the refreshed exact choice needs renewed approval.

   Storage operation: Recheck source/target/history/root/claim generations atomically at admission.

   Applicable rule: A reservation label is not proof that a manual command was admitted, and restart cannot replay consent.

   Read / consume: `pendingwork`, `live`, `projection`.

   Write / produce: `capture`.

   Check / gate: `gate`.

Requirements: [IMPORT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-IMPORT-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — [Adopted import/pending matrix](../Verification.md#external-file-admission-and-pending-recovery--adopted-policy): ordinary new files, unrelated missing notes, per-note active path/exact nonempty-content candidates, missing/copied provenance; latest B versus admitted frozen A; competing/no-op associations; A→B→C projections; repeated crashes before/after operation/pin/receipt; later Delete
- [TC-UI-01](../plan/swift-storage-conformance-testing-strategy.md#tc-ui-01--apple-disposition-review-and-history-are-separate-commands) — Apple disposition, review, and history are separate commands

Design / plans:

- [Pending-file retention and retry identity](../Protocol.md#pending-file-retention-and-retry-identity) — Protocol.md
- [Pending-file commit and recovery records](../Protocol.md#pending-file-commit-and-recovery-records) — Protocol.md
- [External-file admission and pending decisions](../Implementation.md#external-file-admission-and-pending-decisions) — Implementation.md

### Source change after external-file operation admission

[Open walkthrough](nvstorage-object-map.html#scenario=admitted-file&step=1)

An admitted operation retains frozen input A while newer B becomes a subsequent observation. After restart, exact operation/action evidence determines whether A committed; receipt recovery continues the same operation and birth.

**Initial conditions.** An operation on external A is admitted. Before history/receipt completion, another editor saves B and the app crashes.

**Expected outcome.** Recovery locates the exact A operation and finishes association/settlement; it does not allocate another birth or discard B.

1. **Admission of A with its exact operation link** (This Mac).

   Observable state: A becomes ordinary pending history with its frozen input and provisional relationship claim.

   Storage operation: Atomically revalidate/admit the note mutation and claim after asynchronous preparation/reservation.

   Applicable rule: Only admission fixes the operation’s exact semantic identity; the receipt is a later physical/accounting result.

   Read / consume: `pendingwork`, `pendingdisk`, `live`.

   Write / produce: `capture`, `pendinglive`, `projection`.

   Check / gate: `gate`.

2. **Retention of latest B alongside unfinished frozen A** (This Mac).

   Observable state: The recovery graph retains latest B plus frozen A independently.

   Storage operation: Durably replace the latest reference without releasing A’s unfinished-operation ownership; complete A’s history barrier.

   Applicable rule: A later Delete does not erase the earlier import’s committed identity or authorize re-admission into the deleted birth.

   Read / consume: `filework`, `capture`.

   Write / produce: `pendingdisk`, `accepted`, `actionindex`.

   Check / gate: `localowner`.

3. **Recovery of committed A before receipt settlement** (Restart).

   Observable state: The same A operation/birth is recovered, even if that birth was later deleted. B remains subsequent work.

   Storage operation: Resolve ambiguous SQL outcomes, validate exact operation/action/parent closure, then freshly account for the chosen actual projection and settle links.

   Applicable rule: Lookup must not ask only whether the birth is currently live. No receipt retry replays the note mutation or old consent.

   Read / consume: `pendingdisk`, `objects`, `actionindex`.

   Write / produce: `projectiondisk`, `pendingwork`.

   Check / gate: `gate`, `rootowner`.

Requirements: [IMPORT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-IMPORT-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — [Adopted import/pending matrix](../Verification.md#external-file-admission-and-pending-recovery--adopted-policy): ordinary new files, unrelated missing notes, per-note active path/exact nonempty-content candidates, missing/copied provenance; latest B versus admitted frozen A; competing/no-op associations; A→B→C projections; repeated crashes before/after operation/pin/receipt; later Delete
- [TC-DUR-01](../plan/swift-storage-conformance-testing-strategy.md#tc-dur-01--earlier-completion-cannot-clear-later-work) — Earlier completion cannot clear later work

Design / plans:

- [Pending-file commit and recovery records](../Protocol.md#pending-file-commit-and-recovery-records) — Protocol.md
- [Separate plaintext files](../../iCloud-Drive-Support-Spec.md#separate-plaintext-files) — iCloud-Drive-Support-Spec.md
- [10. Phase 6 — Plaintext projection and pending-file recovery](../plan/swift-storage-implementation-plan.md#10-phase-6--plaintext-projection-and-pending-file-recovery) — swift-storage-implementation-plan.md

### Disappearance of an unadmitted pending external file

[Open walkthrough](nvstorage-object-map.html#scenario=disappeared-file&step=1)

The last durably retained readable snapshot survives later source disappearance or unreadability. Its bytes support renewed applicable decisions or explicit recovery, while association and physical effects still require fresh evidence.

**Initial conditions.** A verified external snapshot is pending, then its file disappears or becomes unreadable before a decision.

**Expected outcome.** The last readable snapshot stays privately recoverable; a fresh recovery action needs fresh applicable evidence or explicit choice.

1. **Durable latest-snapshot retention** (This Mac).

   Observable state: The recovery viewer can preview the exact retained bytes.

   Storage operation: Commit payload and latest reference together in the private pending graph.

   Applicable rule: Pending snapshots are not segments, note identity, provider output, or an archive of all unreviewed saves.

   Read / consume: `filework`.

   Write / produce: `pendingdisk`, `pendingwork`.

   Check / gate: `localowner`.

2. **Current observation of disappearance or unreadability** (This Mac).

   Observable state: NV preserves the snapshot and reports uncertainty; it does not infer a committed note Delete.

   Storage operation: Retain last readable input and reclassify current physical/provenance evidence.

   Applicable rule: Missing source bytes grant no stale import, restoration, association or physical permission.

   Read / consume: `pendingdisk`, `filework`.

   Write / produce: `pendingwork`.

   Check / gate: `rootowner`.

3. **Fresh preparation of an applicable explicit recovery** (This Mac).

   Observable state: A separate recovery can create a fresh note from the retained input.

   Storage operation: Prepare/approve current target and source evidence, then admit a new exact recovery action through the complete local barrier.

   Applicable rule: An already admitted operation resumes its own identity; an unadmitted reservation returns to fresh decision work after restart.

   Read / consume: `pendingwork`, `history`.

   Write / produce: `capture`, `accepted`, `live`.

   Check / gate: `gate`.

Requirements: [IMPORT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DELETE-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-IMPORT-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — [Adopted import/pending matrix](../Verification.md#external-file-admission-and-pending-recovery--adopted-policy): ordinary new files, unrelated missing notes, per-note active path/exact nonempty-content candidates, missing/copied provenance; latest B versus admitted frozen A; competing/no-op associations; A→B→C projections; repeated crashes before/after operation/pin/receipt; later Delete
- [TC-PROJ-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — External disappearance while confirmation is open; file returns, note changes, or remote committed Delete arrives; stale Delete/Restore click

Design / plans:

- [Pending-file retention and retry identity](../Protocol.md#pending-file-retention-and-retry-identity) — Protocol.md
- [Separate plaintext files](../../iCloud-Drive-Support-Spec.md#separate-plaintext-files) — iCloud-Drive-Support-Spec.md
- [External-file admission and pending decisions](../Implementation.md#external-file-admission-and-pending-decisions) — Implementation.md

### External disappearance during deletion confirmation

[Open walkthrough](nvstorage-object-map.html#scenario=external-deletion&step=1)

A missing projection can trigger the configured external-deletion choice. File return, changed Current or a received committed Delete invalidates or changes that choice; a new local Delete still requires fresh admission and its complete local barrier.

**Initial conditions.** The external-deletion preference asks about a missing projection. The file may return, the note may change, or remote Delete may arrive.

**Expected outcome.** Revalidate the exact current candidate before a new local Delete; committed received Delete follows its own causal semantics.

1. **Preparation of the configured missing-file decision** (This Mac).

   Observable state: NV retains the live note and prepares the configured external-deletion confirmation.

   Storage operation: Capture the exact source relationship, note generation and current absence evidence.

   Applicable rule: Filesystem disappearance alone is not an immutable Delete and does not erase retained history.

   Read / consume: `projectiondisk`, `filework`, `live`.

   Write / produce: `pendingwork`.

   Check / gate: `rootowner`.

2. **Intervening file return, note change or received Delete** (This Mac).

   Observable state: The old click cannot delete a different generation or remove the returned file.

   Storage operation: Invalidate stale source/note/claim evidence and refresh classification before admission.

   Applicable rule: If remote committed Delete arrives, its separate reducer semantics apply; an association claim cannot suppress it.

   Read / consume: `filework`, `live`, `graph`.

   Write / produce: `reduce`, `pendingwork`.

   Check / gate: `gate`.

3. **Fresh Delete admission and exact-snapshot physical effect** (This Mac).

   Observable state: A newly admitted local Delete takes its complete parent barrier; restoration uses a fresh birth.

   Storage operation: Only the original exact-snapshot operation may physically remove a still-matching accepted projection after local durability.

   Applicable rule: No startup tombstone sweep or physical permission replay follows restart; newer bytes are preserved/reconciled.

   Read / consume: `capture`, `accepted`, `projection`.

   Write / produce: `live`, `history`, `filework`.

   Check / gate: `rootowner`, `gate`.

Requirements: [DELETE-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [IMPORT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-PROJ-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — External disappearance while confirmation is open; file returns, note changes, or remote committed Delete arrives; stale Delete/Restore click
- [TC-DUR-02](../plan/swift-storage-conformance-testing-strategy.md#tc-dur-02--a-dependent-delete-cannot-outrun-its-parent) — A dependent Delete cannot outrun its parent

Design / plans:

- [Separate plaintext files](../../iCloud-Drive-Support-Spec.md#separate-plaintext-files) — iCloud-Drive-Support-Spec.md
- [Current-file decision matrix](../Protocol.md#current-file-decision-matrix) — Protocol.md
- [10. Phase 6 — Plaintext projection and pending-file recovery](../plan/swift-storage-implementation-plan.md#10-phase-6--plaintext-projection-and-pending-file-recovery) — swift-storage-implementation-plan.md

### New projection intent C while installation B is unfinished

[Open walkthrough](nvstorage-object-map.html#scenario=projection-abc&step=1)

A is the accepted projection when B starts. New intent C arrives before B’s installation or receipt completes. B settles only its captured output and serviced generations; C remains intended until its own applicable installation.

**Initial conditions.** A is installed. Projection B starts, then a newer intended value C is admitted before B’s result or receipt returns.

**Expected outcome.** B can settle only its captured work. C remains intended/pending until the correct file and receipt evidence exist.

1. **Preparation of B against accepted projection A** (This Mac).

   Observable state: The file plan captures expected A and exact output B.

   Storage operation: Bind the projection to the note/root/relationship generations and locally durable represented history.

   Applicable rule: Mutable note replacement uses the expected-snapshot contract, distinct from immutable object exclusive creation.

   Read / consume: `projectiondisk`, `live`.

   Write / produce: `projection`, `filework`.

   Check / gate: `rootowner`, `gate`.

2. **Admission of newer intent C before B settles** (This Mac).

   Observable state: The live note and intended projection become C while B retains its own owned inputs.

   Storage operation: Record newer pending generations and retain the latest external observation separately from frozen B.

   Applicable rule: A successful old file write is not evidence that C was installed, and old approval cannot overwrite newer source bytes.

   Read / consume: `live`, `projection`.

   Write / produce: `pendinglive`, `pendingdisk`.

   Check / gate: `gate`.

3. **Exact-result accounting for B with C still pending** (This Mac).

   Observable state: The system records only the actual applicable B outcome and still owes C.

   Storage operation: Reobserve exact file/claim state, transfer only serviced links into a receipt, and schedule C’s proper projection.

   Applicable rule: Retiring accepted B for a later observation never clears intended C or manufactures an echo import.

   Read / consume: `filework`, `pendingdisk`, `projection`.

   Write / produce: `projectiondisk`, `projection`.

   Check / gate: `rootowner`, `gate`.

Requirements: [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [IMPORT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-IMPORT-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — [Adopted import/pending matrix](../Verification.md#external-file-admission-and-pending-recovery--adopted-policy): ordinary new files, unrelated missing notes, per-note active path/exact nonempty-content candidates, missing/copied provenance; latest B versus admitted frozen A; competing/no-op associations; A→B→C projections; repeated crashes before/after operation/pin/receipt; later Delete
- [TC-DUR-01](../plan/swift-storage-conformance-testing-strategy.md#tc-dur-01--earlier-completion-cannot-clear-later-work) — Earlier completion cannot clear later work
- [TC-PROJ-01](../plan/swift-storage-conformance-testing-strategy.md#tc-proj-01--body-stamp-and-history-arrive-independently) — Body, stamp, and history arrive independently

Design / plans:

- [Pending-file commit and recovery records](../Protocol.md#pending-file-commit-and-recovery-records) — Protocol.md
- [Separate plaintext files](../../iCloud-Drive-Support-Spec.md#separate-plaintext-files) — iCloud-Drive-Support-Spec.md
- [Target transaction](../../Foundation-Safe-Replacement-Migration.md#target-transaction) — Foundation-Safe-Replacement-Migration.md

### Scoped disposition of an Apple unresolved version

[Open walkthrough](nvstorage-object-map.html#scenario=apple-versions&step=1)

For captured version V, disposition follows admission, complete local history durability, exact plaintext installation and final coordinated revalidation. Only still-applicable captured members receive resolved = YES, followed by a fresh verification query.

**Initial conditions.** The conflict resolver presents selected Apple unresolved member V. The user chooses Use or Save as new note for that captured member.

**Expected outcome.** Only applicable captured members receive resolved = YES after exact local history, projection and final coordinated checks.

1. **Version capture, bounded preview and choice admission** (This Mac).

   Observable state: Read-only preview is dismissible; per-version waits/errors use bounded attempts.

   Storage operation: Capture invocation mode, exact source/member/root observations and selected content; revalidate then admit the chosen action.

   Applicable rule: Preview/Cancel has no disposition effect. Re-presentation retries applicable work without overlapping accessors.

   Read / consume: `appleversions`, `filework`.

   Write / produce: `history`, `capture`.

   Check / gate: `appleowner`, `gate`.

2. **Local-history barrier and exact plaintext installation** (This Mac).

   Observable state: The action’s complete group/parent barrier and the actual chosen file result must both succeed.

   Storage operation: Retain accepted exact history, then install/verify the expected plaintext generation.

   Applicable rule: Local acceptance alone cannot substitute for the extra file gate; upload is irrelevant.

   Read / consume: `capture`, `accepted`, `filework`.

   Write / produce: `rnotes`, `projectiondisk`.

   Check / gate: `rootowner`, `gate`.

3. **Final coordinated member check and scoped disposition** (This Mac).

   Observable state: Set resolved only for still-applicable captured members, then verify via a successful fresh query.

   Storage operation: Recheck source/member/root/file generations inside the short merging accessor before scoped setters.

   Applicable rule: No version removal occurs. Failed enumeration is not empty, and empty Apple results cannot clear an NV-head conflict.

   Read / consume: `appleversions`, `projectiondisk`.

   Write / produce: `filework`, `conflicts`.

   Check / gate: `appleowner`, `rootowner`, `gate`.

Requirements: [REC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [WAIT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-UI-01](../plan/swift-storage-conformance-testing-strategy.md#tc-ui-01--apple-disposition-review-and-history-are-separate-commands) — Apple disposition, review, and history are separate commands
- [TC-ROOT-01](../plan/swift-storage-conformance-testing-strategy.md#tc-root-01--physical-ownership-cannot-be-replaced-by-matching-names-or-bytes) — Physical ownership cannot be replaced by matching names or bytes

Design / plans:

- [Conflict resolver and Apple disposition](../../iCloud-Drive-Support-Spec.md#conflict-resolver-and-apple-disposition) — iCloud-Drive-Support-Spec.md
- [AV-05 — unresolved-version disclosure, immutable reads, and disposition](../../Apple-API-Contract-Validation.md#av-05--unresolved-version-disclosure-immutable-reads-and-disposition) — Apple-API-Contract-Validation.md
- [Target transaction](../../Foundation-Safe-Replacement-Migration.md#target-transaction) — Foundation-Safe-Replacement-Migration.md
- [11. Phase 7 — Application capture, history UI and lifecycle](../plan/swift-storage-implementation-plan.md#11-phase-7--application-capture-history-ui-and-lifecycle) — swift-storage-implementation-plan.md

### External-editor handoff from an encrypted collection

[Open walkthrough](nvstorage-object-map.html#scenario=external-editor&step=1)

An explicit handoff uses owned plaintext scratch outside the provider namespace with disclosed external-app retention risks. Returned edits take the ordinary local barrier; cleanup applies only to the matching serviced scratch generation.

**Initial conditions.** The user explicitly opens an encrypted note in an external editor through a disclosed plaintext scratch file outside the provider folder.

**Expected outcome.** Returned edits are admitted/captured normally; scratch survives until the exact accepted generation is locally durable.

1. **Explicit plaintext handoff and scratch creation** (This Mac).

   Observable state: The explicit action discloses that the other app’s autosave/backup may retain plaintext.

   Storage operation: Capture exact note/root/generation and create owned scratch outside the encrypted provider namespace.

   Applicable rule: Encryption does not implicitly create plaintext projections or authorize undisclosed temporary exports.

   Read / consume: `live`, `secrets`.

   Write / produce: `scratch`, `filework`.

   Check / gate: `gate`.

2. **Read, admission and capture of returned edits** (This Mac).

   Observable state: NV preserves the returned value as ordinary pending history and freezes the exact handoff generation.

   Storage operation: Revalidate read/attachment/current inputs and force asynchronous capture for external settlement.

   Applicable rule: A failed local barrier retains admitted text and owned scratch. Handoff completion requires that exact generation’s complete local durability barrier.

   Read / consume: `scratch`, `filework`, `live`.

   Write / produce: `capture`, `pendinglive`.

   Check / gate: `gate`.

3. **Scratch settlement after exact-generation durability** (This Mac).

   Observable state: After its complete local barrier, matching owned scratch can settle; newer scratch/work remains.

   Storage operation: Check exact-generation completion and the still-identifiable owned resource before cleanup.

   Applicable rule: Quit/switch owns settlement or explicit cancellation; stale callbacks cannot clear newer work.

   Read / consume: `accepted`, `pendinglive`, `scratch`.

   Write / produce: `filework`.

   Check / gate: `gate`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CRYPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-CAP-01](../plan/swift-storage-conformance-testing-strategy.md#tc-cap-01--a-faithful-frozen-action-not-just-durable-bytes) — A faithful frozen action, not just durable bytes
- [TC-CLOSE-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Close with pending edits/external-editor handoff; materialization failure; pin/settings failure; provider wait; cancel/retry; old callbacks after switch
- [TC-PRIV-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Synthetic title/body/path/bookmark/secret markers through success, malformed input, key errors, preview, repair and export

Design / plans:

- [Separate plaintext files](../../iCloud-Drive-Support-Spec.md#separate-plaintext-files) — iCloud-Drive-Support-Spec.md
- [Encryption and persistence formats](../../iCloud-Drive-Support-Spec.md#encryption-and-persistence-formats) — iCloud-Drive-Support-Spec.md
- [11. Phase 7 — Application capture, history UI and lifecycle](../plan/swift-storage-implementation-plan.md#11-phase-7--application-capture-history-ui-and-lifecycle) — swift-storage-implementation-plan.md

## Damage classification, repair and backup

Same-root repository repair, retained-history reconstruction, fresh-store activation, bootstrap, and complete private backups.

### Automatic repair of positively absent same-root NV Data

[Open walkthrough](nvstorage-object-map.html#scenario=repository-repair&step=1)

With the same positively owned root, a complete private closure and no disclosed unread newer evidence, positively absent NV Data triggers automatic exact reconstruction. Exclusive creation preserves a competing namespace occupant.

**Initial conditions.** The positively owned root remains the same directory. NV Data is positively absent, local closure is complete, and no unread newer evidence is disclosed.

**Expected outcome.** NV transparently reconstructs the known repository; it does not ask Restore or Work Offline for this case.

1. **Classification of same-root top-level absence** (This Mac).

   Observable state: Healthy local editing continues while automatic repository repair starts.

   Storage operation: Verify held root identity, exact top-level absence, complete local closure and writable namespace.

   Applicable rule: Unreadable, offline, foreign or identity-ambiguous is not positive absence; disclosed unread newer evidence uses its own policy.

   Read / consume: `rootowner`, `objects`, `pin`.

   Write / produce: `repairwork`.

   Check / gate: `appleowner`.

2. **Exclusive reconstruction of the known protocol namespace** (This Mac).

   Observable state: The complete known descriptors/objects are copied by exact identity.

   Storage operation: Exclusively create ordinary protocol directories, verify final names and perform required barriers.

   Applicable rule: A race winner is reclassified/preserved. Damaged owned replacement needs displaced evidence preserved before a generation-checked install.

   Read / consume: `repairwork`, `objects`.

   Write / produce: `rdirs`, `rkeys`, `rchanges`, `rgeneral`.

   Check / gate: `rootowner`.

3. **Verification and resumption of provider publication** (This Mac).

   Observable state: Sync resumes from the same local history; available remote branches still union later.

   Storage operation: Verify the reconstructed known repository and retain all accepted history plus restartable unfinished work.

   Applicable rule: Foreign collisions stop affected provider effects; cleanup removes only exact owned disposable artifacts.

   Read / consume: `rdirs`, `pubwork`.

   Write / produce: `recvwork`.

   Check / gate: `rootowner`, `gate`.

Requirements: [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [AUTH-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CLEAN-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-REPAIR-01](../plan/swift-storage-conformance-testing-strategy.md#tc-repair-01--complementary-copies-repair-private-history-first) — Complementary copies repair private history first
- [TC-ROOT-01](../plan/swift-storage-conformance-testing-strategy.md#tc-root-01--physical-ownership-cannot-be-replaced-by-matching-names-or-bytes) — Physical ownership cannot be replaced by matching names or bytes
- [TC-DUR-05](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Private duplicate exact BLOB versus contradictory bytes under one identity; provider equal unqualified final, conflicting/wrong-kind occupant and nested writer directory

Design / plans:

- [Repository and private-store damage and repair](../../iCloud-Drive-Support-Spec.md#repository-and-private-store-damage-and-repair) — iCloud-Drive-Support-Spec.md
- [Repository and private-store repair protocol](../Protocol.md#repository-and-private-store-repair-protocol) — Protocol.md
- [8. Phase 4 — Startup, repair, repository copy and private state](../plan/swift-storage-implementation-plan.md#8-phase-4--startup-repair-repository-copy-and-private-state) — swift-storage-implementation-plan.md

### Fresh-store repair from complementary retained copies

[Open walkthrough](nvstorage-object-map.html#scenario=private-repair&step=1)

A surviving pin requires G+L+R; private history supplies G+L and the repository supplies G+R. A validated union populates a fresh sibling, whose complete closure and retained pin must be durable before activation.

**Initial conditions.** The surviving pin names closure G+L+R. The damaged private store has G+L; the repository has G+R. Neither alone is complete.

**Expected outcome.** Use the validated union to build a fresh sibling; activate it only after its complete closure and retained pin are durable.

1. **Capture and preservation of independently valid repair evidence** (This Mac).

   Observable state: Recovery preserves the damaged source and identifies independently valid objects from each copy.

   Storage operation: Classify identity, entry kind, access, exact authenticated bytes and required closure, not presumed cause or timestamps.

   Applicable rule: Missing entries never subtract from the repair union; contradictory bytes are not merged into a synthetic payload.

   Read / consume: `objects`, `rchanges`, `rkeys`, `pin`.

   Write / produce: `repairwork`, `backup`.

   Check / gate: `localowner`, `rootowner`.

2. **Construction of fresh sibling with closure G+L+R** (This Mac).

   Observable state: The candidate remains unattached while copy/validation/pin work can be interrupted.

   Storage operation: Commit complete accepted closure and required private groups, pending links and usable unlock descriptors into a fresh candidate.

   Applicable rule: A second failure preserves old evidence and leaves the candidate unactivated; provider repair cannot precede private closure.

   Read / consume: `repairwork`, `private`, `pendingdisk`, `projectiondisk`, `unlock`.

   Write / produce: `candidate`.

   Check / gate: `selectowner`.

3. **Activation after candidate verification and pin durability** (This Mac).

   Observable state: The repaired collection reopens through normal startup gates with a fresh session/origin/epoch.

   Storage operation: Durably commit the candidate pin, verify activation and selection cutover, then establish new ownership.

   Applicable rule: Copied state never restores old physical permission or allocation epochs. Preserve displaced evidence.

   Read / consume: `candidate`.

   Write / produce: `selection`, `current`, `live`.

   Check / gate: `selectowner`, `gate`.

Requirements: [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CLEAN-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-REPAIR-01](../plan/swift-storage-conformance-testing-strategy.md#tc-repair-01--complementary-copies-repair-private-history-first) — Complementary copies repair private history first
- [TC-DUR-06](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Delete/materialization-loss plus removal of a pinned leaf or descriptor; unrelated invalid extra; total Local State loss in a distinct scenario

Design / plans:

- [Repository and private-store damage and repair](../../iCloud-Drive-Support-Spec.md#repository-and-private-store-damage-and-repair) — iCloud-Drive-Support-Spec.md
- [Repository and private-store repair protocol](../Protocol.md#repository-and-private-store-repair-protocol) — Protocol.md
- [SQLite backup, salvage and replacement activation](../LocalStore.md#sqlite-backup-salvage-and-replacement-activation) — LocalStore.md

### Required retained object missing from all available sources

[Open walkthrough](nvstorage-object-map.html#scenario=missing-history&step=1)

A surviving pin names a leaf or descriptor absent from private history, repository and selected backup. Editable publication waits for complete repair or an explicit recovery outcome; apparently valid derived rows cannot waive the dependency.

**Initial conditions.** Current rows exist, but the required retained pin names a missing leaf or descriptor absent from private store, repository and selected backup.

**Expected outcome.** Editable success waits for complete repair or an explicit recovery outcome; an unrelated malformed extra remains a separate case.

1. **Detection of a missing required dependency** (This Mac).

   Observable state: NV reports the exact recovery problem instead of trusting apparently plausible current rows.

   Storage operation: Check the required retained closure and distinguish it from unrelated unaccepted/invalid extras.

   Applicable rule: Derived current rows, timestamps and a valid snapshot tag cannot waive known retained dependencies.

   Read / consume: `pin`, `objects`, `unlock`, `current`.

   Write / produce: `verification`, `repairwork`.

   Check / gate: `gate`.

2. **Inspection of available exact repair sources** (This Mac).

   Observable state: Available evidence is preserved while repository/backup reads are bounded.

   Storage operation: Try exact named copies and validate complete closure; record unfinished verification/damage durably when possible.

   Applicable rule: Provider unavailability is not deletion; contradictory/unsupported required data cannot become silent omission.

   Read / consume: `rchanges`, `rkeys`, `backup`, `objects`.

   Write / produce: `repairwork`, `verification`.

   Check / gate: `rootowner`.

3. **Explicit unresolved-damage or separate salvage outcome** (This Mac).

   Observable state: The affected collection stays noneditable until its requirements are satisfied.

   Storage operation: Offer applicable Retry/another source or explicitly labeled fresh current-note/file salvage with disclosed limits.

   Applicable rule: Total private-state loss is a distinct classification; it does not invent knowledge of unpublished history that no surviving pin discloses.

   Read / consume: `repairwork`, `live`.

   Write / produce: `copy`, `candidate`.

   Check / gate: `selectowner`, `gate`.

Requirements: [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-DUR-06](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Delete/materialization-loss plus removal of a pinned leaf or descriptor; unrelated invalid extra; total Local State loss in a distinct scenario
- [TC-START-01](../plan/swift-storage-conformance-testing-strategy.md#tc-start-01--complete-bootstrap-and-current-row-startup) — Complete bootstrap and current-row startup
- [TC-REPAIR-01](../plan/swift-storage-conformance-testing-strategy.md#tc-repair-01--complementary-copies-repair-private-history-first) — Complementary copies repair private history first

Design / plans:

- [Repository and private-store damage and repair](../../iCloud-Drive-Support-Spec.md#repository-and-private-store-damage-and-repair) — iCloud-Drive-Support-Spec.md
- [Startup, creation and private current state](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state) — iCloud-Drive-Support-Spec.md
- [Reopening, cancellation and shutdown](../plan/phase-4-improvements/durable-verification-recovery.md#reopening-cancellation-and-shutdown) — durable-verification-recovery.md

### Fresh private-store bootstrap from a selected repository

[Open walkthrough](nvstorage-object-map.html#scenario=fresh-mac&step=1)

A new Mac or total private-state loss requires explicit physical association and complete verified bootstrap closure. A complete authenticated snapshot can support read-only preview while editing waits for required history and a durable fresh local pin.

**Initial conditions.** The repository is selected explicitly. No old private store survives; initial-import closure may arrive in pieces.

**Expected outcome.** Complete authenticated snapshot preview can be read-only. Editing needs complete bootstrap/closure and a fresh private pin/origin/epoch.

1. **Explicit root selection, ownership and profile unlock** (New Mac).

   Observable state: The selected folder and key are independently validated; no auto-attachment follows a collection-ID match.

   Storage operation: Acquire ownership and read bounded descriptors/bootstrap evidence into a fresh private candidate.

   Applicable rule: An incomplete import is not a successful empty/partial collection. Missing keys keep it locked.

   Read / consume: `rdirs`, `rkeys`, `selection`.

   Write / produce: `candidate`, `secrets`.

   Check / gate: `rootowner`, `selectowner`.

2. **Verification of complete initial-import and snapshot evidence** (New Mac).

   Observable state: A fully authenticated complete snapshot can be previewed read-only while named batches/parents arrive.

   Storage operation: Verify genesis commitment, ImportComplete, snapshot pages/counts/digests and required exact history closure.

   Applicable rule: Usable assembly pages are not accepted causal history. No preview grants editability or globally latest knowledge.

   Read / consume: `rinitial`, `rchanges`.

   Write / produce: `objects`, `receiveq`, `snapwork`.

   Check / gate: `localowner`.

3. **Fresh private acceptance and checked editable publication** (New Mac).

   Observable state: All current/search values and authoring frontiers appear together; portable Undo is reconstructed from action history.

   Storage operation: Commit complete acceptance/pin and derived rows, establish fresh origin/writer epoch, and final-check the opening handoff.

   Applicable rule: Old native stacks, physical permissions and source private settings are not transplanted from repository identities.

   Read / consume: `objects`, `accepted`, `actionindex`.

   Write / produce: `pin`, `current`, `view`, `live`, `search`, `undo`.

   Check / gate: `gate`.

Requirements: [AUTH-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CRYPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-START-01](../plan/swift-storage-conformance-testing-strategy.md#tc-start-01--complete-bootstrap-and-current-row-startup) — Complete bootstrap and current-row startup
- [TC-START-03](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Total private store loss with complete repository; explicit root selection; unknown orphan objects and missing key variants
- [TC-KEY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-key-01--credential-and-association-cutover-have-different-failure-boundaries) — Credential and association cutover have different failure boundaries

Design / plans:

- [Startup, creation and private current state](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state) — iCloud-Drive-Support-Spec.md
- [Repository and private-store damage and repair](../../iCloud-Drive-Support-Spec.md#repository-and-private-store-damage-and-repair) — iCloud-Drive-Support-Spec.md
- [Snapshots, startup, rejoin, and retention](../Protocol.md#snapshots-startup-rejoin-and-retention) — Protocol.md
- [8. Phase 4 — Startup, repair, repository copy and private state](../plan/swift-storage-implementation-plan.md#8-phase-4--startup-repair-repository-copy-and-private-state) — swift-storage-implementation-plan.md

### Private backup containing unpublished and pending work

[Open walkthrough](nvstorage-object-map.html#scenario=private-backup&step=1)

A consistent keyed SQLite backup or quiesced complete pager capture includes unpublished accepted history, required private records and pending recovery links. Usable unlock descriptors accompany encrypted backups; restore establishes fresh ownership.

**Initial conditions.** The provider is offline. The private store holds unpublished accepted actions, settings and pending external-file recovery buffers.

**Expected outcome.** A consistent keyed database backup or quiesced complete pager copy, plus unlock descriptors, preserves the private recovery state.

1. **Consistent capture of the complete private backup boundary** (This Mac).

   Observable state: The backup covers accepted unpublished history, required state and latest/frozen pending links.

   Storage operation: Choose a consistent SQLite backup or quiesced complete DB/journal capture under keyed ownership.

   Applicable rule: A live database-file-only copy is not the specified consistent backup; current rows alone omit history and required state.

   Read / consume: `dbcontainer`, `objects`, `pin`, `private`, `pendingdisk`, `projectiondisk`.

   Write / produce: `repairwork`.

   Check / gate: `localowner`.

2. **Inclusion and verification of usable unlock descriptors** (This Mac).

   Observable state: Encrypted backup recovery has an authorized password/recovery route; password-free recovery needs no Mac secret.

   Storage operation: Include the bounded private unlock descriptors alongside the database and verify the captured backup.

   Applicable rule: A remembered device-bound Keychain item is not promised portable. Encrypted ciphertext alone does not promise unlockability.

   Read / consume: `unlock`, `secrets`, `repairwork`.

   Write / produce: `backup`.

   Check / gate: `selectowner`.

3. **Restore under freshly validated ownership and session identity** (This Mac).

   Observable state: Exact retained actions and pending work recover before editing, using fresh session/epoch allocation.

   Storage operation: Revalidate root/key/bootstrap/association and complete closure; recover exact admitted external operations before rescanning.

   Applicable rule: Old receipts require fresh physical evidence and grant no surviving file-delete permission.

   Read / consume: `backup`.

   Write / produce: `candidate`, `selection`, `live`, `pendingwork`.

   Check / gate: `gate`, `rootowner`.

Requirements: [BACKUP-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CRYPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-REPAIR-01](../plan/swift-storage-conformance-testing-strategy.md#tc-repair-01--complementary-copies-repair-private-history-first) — Complementary copies repair private history first
- [TC-START-03](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Total private store loss with complete repository; explicit root selection; unknown orphan objects and missing key variants
- [TC-KEY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-key-01--credential-and-association-cutover-have-different-failure-boundaries) — Credential and association cutover have different failure boundaries

Design / plans:

- [Backup, diagnostics and compatibility](../../iCloud-Drive-Support-Spec.md#backup-diagnostics-and-compatibility) — iCloud-Drive-Support-Spec.md
- [SQLite backup, salvage and replacement activation](../LocalStore.md#sqlite-backup-salvage-and-replacement-activation) — LocalStore.md
- [Database keys and password-free recovery](../LocalStore.md#database-keys-and-password-free-recovery) — LocalStore.md

## Encryption profiles and credentials

Password/key recovery, add-only key wrapping, authenticated decoding, and explicitly requested plaintext output.

### Password unlock with an unavailable remembered key

[Open walkthrough](nvstorage-object-map.html#scenario=unlock&step=1)

When Keychain is locked or unavailable, a usable wrapped descriptor and authorized password can recover the same collection key. Remembering a new key item requires add-only creation and verified readback before association refers to it.

**Initial conditions.** An encrypted collection’s device-bound remembered key is unavailable or locked, but a usable wrapped descriptor and password survive.

**Expected outcome.** The authorized password unlocks the same collection key; failed unlock preserves ciphertext and never produces empty plaintext.

1. **Profile and unlock-route validation before editable opening** (This Mac).

   Observable state: Notes remain private and noneditable until an authorized key succeeds.

   Storage operation: Read bounded provider/private unlock descriptors and distinguish unavailable Keychain from corrupt history.

   Applicable rule: Profile, key scope and physical association are independently checked; a matching collection ID proves none of them.

   Read / consume: `rkeys`, `unlock`, `keychain`.

   Write / produce: `secrets`.

   Check / gate: `selectowner`.

2. **Password unwrapping and authenticated object decoding** (This Mac).

   Observable state: The reviewed KDF/descriptor route unwraps CK, then domain-separated keys open database and objects.

   Storage operation: Authenticate envelopes before decompression/value decoding; enforce bounds and semantic consistency separately.

   Applicable rule: Unsupported profiles, malformed input or authentication failure yield typed failure; there is no weaker/plaintext fallback.

   Read / consume: `secrets`, `objects`.

   Write / produce: `decoded`, `graph`.

   Check / gate: `gate`.

3. **Optional remembered-key provisioning and association cutover** (This Mac).

   Observable state: Password unlocking still works if remembering fails.

   Storage operation: Provision add-only, read back/validate the signed-app Keychain item, then durably reference it in private association.

   Applicable rule: No association may point to an unverified key item; ambiguous cutover preserves potentially referenced credentials.

   Read / consume: `secrets`.

   Write / produce: `keychain`, `private`.

   Check / gate: `selectowner`.

Requirements: [CRYPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [AUTH-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-KEY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-key-01--credential-and-association-cutover-have-different-failure-boundaries) — Credential and association cutover have different failure boundaries
- [TC-CRYPT-01](../plan/swift-storage-conformance-testing-strategy.md#tc-crypt-01--authentication-coverage-and-semantic-validation-are-separate-gates) — Authentication coverage and semantic validation are separate gates

Design / plans:

- [Encryption and persistence formats](../../iCloud-Drive-Support-Spec.md#encryption-and-persistence-formats) — iCloud-Drive-Support-Spec.md
- [Database keys and password-free recovery](../LocalStore.md#database-keys-and-password-free-recovery) — LocalStore.md
- [Common object envelope version 1](../Encryption.md#common-object-envelope-version-1) — Encryption.md

### Same-key password rewrap and full key/profile conversion

[Open walkthrough](nvstorage-object-map.html#scenario=password-rewrap&step=1)

Password rewrap adds a descriptor for the existing CK while retaining history and prior descriptors. A full key/profile change creates an independently owned current-state destination whose output and credentials are verified before cutover.

**Initial conditions.** The collection is unlocked with CK. The requested operation is either a new password wrapping that same CK or a full conversion to a fresh key/profile destination.

**Expected outcome.** Rewrap preserves exact history and old descriptors. A full key/profile change uses a source-preserving fresh destination and verified cutover.

1. **Preparation of a same-CK wrapped descriptor** (This Mac).

   Observable state: The operation explains that old descriptors/secrets may still unlock retained copies.

   Storage operation: Prepare a new bounded wrapped-key descriptor for the same CK without changing note/action identities or database key derivation.

   Applicable rule: Rewrap is not revocation, database rekeying or erasure of provider/APFS copies.

   Read / consume: `secrets`, `rkeys`, `unlock`.

   Write / produce: `seal`.

   Check / gate: `gate`.

2. **Add-only descriptor and credential installation** (This Mac).

   Observable state: The new unlock route is verified before association refers to it.

   Storage operation: Retain/publish exact descriptor bytes and read back independent credential items before private cutover.

   Applicable rule: Keychain and filesystem are not one transaction; interruption preserves possibly referenced credentials and source data.

   Read / consume: `seal`, `secrets`.

   Write / produce: `rkeys`, `unlock`, `keychain`, `private`.

   Check / gate: `selectowner`.

3. **Fresh-destination path for full key/profile change** (This Mac).

   Observable state: Current-state conversion is explicitly labeled and verified before switching.

   Storage operation: Capture coherent source values, create fresh collection/key/bootstrap, verify complete output and only then change active association.

   Applicable rule: Source changes invalidate capture. Independent destinations never update/delete source credentials automatically.

   Read / consume: `live`, `repairwork`.

   Write / produce: `copy`, `candidate`, `selection`.

   Check / gate: `selectowner`, `gate`.

Requirements: [CRYPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [BACKUP-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-KEY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-key-01--credential-and-association-cutover-have-different-failure-boundaries) — Credential and association cutover have different failure boundaries
- [TC-COPY-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Recovery Save As during local failure with admitted unsaved work; current-state export; source changes during capture

Design / plans:

- [Encryption and persistence formats](../../iCloud-Drive-Support-Spec.md#encryption-and-persistence-formats) — iCloud-Drive-Support-Spec.md
- [Passphrase changes, key changes, and recovery](../Encryption.md#passphrase-changes-key-changes-and-recovery) — Encryption.md
- [Root events, shutdown and transitions](../../iCloud-Drive-Support-Spec.md#root-events-shutdown-and-transitions) — iCloud-Drive-Support-Spec.md

### Encrypted history, plaintext output and conversion limits

[Open walkthrough](nvstorage-object-map.html#scenario=privacy-profile&step=1)

Encrypted current/history/deleted values, previews and diagnostics follow their profile-specific handling rules. Explicit plaintext output has a disclosed destination and scope; unsupported rich or attachment conversion preserves source data before cutover.

**Initial conditions.** An encrypted collection contains sensitive current, deleted and historical values. The requested operation is an explicit plaintext export or a conversion whose target may not support the source content.

**Expected outcome.** Encrypted provider/private history stays within its profile; explicit output discloses scope and preserves source on unsupported or failed conversion.

1. **Authenticated reading and profile-specific plaintext handling** (This Mac).

   Observable state: Previews are available in memory; encrypted at-rest values and diagnostics retain their prescribed privacy.

   Storage operation: Use bounded authenticated envelopes before decoding; encrypt sensitive private rows/indexes and keep provider IDs opaque.

   Applicable rule: Authentication does not prove freshness/physical authority. Production diagnostics use closed IDs/counts/status, not titles, paths or keys.

   Read / consume: `objects`, `secrets`.

   Write / produce: `history`, `decoded`, `live`.

   Check / gate: `gate`.

2. **Lock or explicitly requested plaintext output** (This Mac).

   Observable state: Lock releases view-held plaintext. Export/handoff requires an explicit disclosed destination.

   Storage operation: Retain ownership of intentional scratch/export output and keep it outside encrypted provider history.

   Applicable rule: The design does not promise whole-process zeroization or erasure of another app’s backup; those are not inferred from marker tests.

   Read / consume: `history`, `live`, `secrets`.

   Write / produce: `scratch`.

   Check / gate: `gate`, `selectowner`.

3. **Unsupported rich/attachment conversion before cutover** (This Mac).

   Observable state: The conversion rejects/discloses unsupported loss and preserves source bytes before any cutover.

   Storage operation: Choose a supported target codec/profile and detached verified conversion; maintain genuine legacy recovery/export separately.

   Applicable rule: Attachments are unsupported; RTF/HTML identity/rendering is deferred. Never silently flatten or fetch resources to satisfy a conversion.

   Read / consume: `legacy`, `live`, `scratch`.

   Write / produce: `copy`, `repairwork`.

   Check / gate: `selectowner`, `gate`.

Requirements: [CRYPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [BACKUP-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-PRIV-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Synthetic title/body/path/bookmark/secret markers through success, malformed input, key errors, preview, repair and export
- [TC-RICH-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Existing rich or attachment-bearing legacy inputs presented to a plaintext-only destination; unsupported format/conversion and failed migration
- [TC-CRYPT-01](../plan/swift-storage-conformance-testing-strategy.md#tc-crypt-01--authentication-coverage-and-semantic-validation-are-separate-gates) — Authentication coverage and semantic validation are separate gates
- [TC-ZSTD-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Both suites with authentic envelopes around short/long output claims, truncation, concatenated/skippable frames, dictionaries, unknown content sizes, oversized windows and trailing bytes; genuine valid compressed examples and independent writer checks
- [TC-BYTE-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Truncate every short fixed fixture at each byte; invalid counts/tags/order/duplicates, overflow lengths, nested trailing data and invalid UTF-8
- [TC-LIMIT-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Below/at/above each finalized object, descriptor, stamp, passphrase and record bound; normalized rather than input character count

Design / plans:

- [Encryption and persistence formats](../../iCloud-Drive-Support-Spec.md#encryption-and-persistence-formats) — iCloud-Drive-Support-Spec.md
- [Backup, diagnostics and compatibility](../../iCloud-Drive-Support-Spec.md#backup-diagnostics-and-compatibility) — iCloud-Drive-Support-Spec.md
- [Common object envelope version 1](../Encryption.md#common-object-envelope-version-1) — Encryption.md
- [12. Phase 8 — Qualification, not a late testing phase](../plan/swift-storage-implementation-plan.md#12-phase-8--qualification-not-a-late-testing-phase) — swift-storage-implementation-plan.md

## Root ownership and collection transitions

Repository copy, current-note recovery export, root moves, close ordering, collection switching, and epoch-4 migration.

### Repository copy with unavailable entries and no private store

[Open walkthrough](nvstorage-object-map.html#scenario=repository-copy&step=1)

The captured inventory includes available immutable history, descriptors and associated unknown files. Unreadable placeholders or changed captured files are reported; source Application Support is outside the repository-copy boundary.

**Initial conditions.** A repository is copied from Finder or backup without source Application Support. One provider placeholder is unreadable and an unknown text file is present.

**Expected outcome.** Preserve the exact available captured inventory and report holes/changed inputs. A current-state export remains a separate command.

1. **Rooted capture of the repository inventory** (This Mac).

   Observable state: The requested copy includes visible NV Data, historical objects/descriptors and associated unknown/unimported files.

   Storage operation: Use rooted bounded enumeration and capture actual available bytes and known missing/unreadable dependencies.

   Applicable rule: Source Application Support, unpublished work and other Macs are outside this copy’s scope and are not prerequisites.

   Read / consume: `rdirs`, `rkeys`, `rchanges`, `rinitial`, `rgeneral`, `rnotes`.

   Write / produce: `repairwork`.

   Check / gate: `rootowner`.

2. **Verified copying of available exact evidence** (This Mac).

   Observable state: The destination preserves immutable identities/bytes and reports the unreadable placeholder or changed captured file.

   Storage operation: Verify copied inventory; preserve useful available evidence even if editable recovery waits for a missing dependency.

   Applicable rule: Do not fabricate a new genesis/current-state history or claim global freshness/completeness.

   Read / consume: `repairwork`.

   Write / produce: `copy`.

   Check / gate: `selectowner`.

3. **Optional explicit switch after destination verification** (This Mac).

   Observable state: Copy-only leaves the active root unchanged; switching establishes fresh private ownership and epoch.

   Storage operation: Explicitly validate destination physical root/bootstrap/key and activate a fresh private association.

   Applicable rule: Historical lineage and portable Undo transfer through bytes; old root authority, receipts and distributed writer identity do not.

   Read / consume: `copy`, `objects`.

   Write / produce: `candidate`, `selection`, `undo`.

   Check / gate: `selectowner`, `gate`.

Requirements: [BACKUP-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [AUTH-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-COPY-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Repository-only copy with no source private store, unknown text files and retained old actions/deletes; unreadable placeholder; source text changes
- [TC-ROOT-01](../plan/swift-storage-conformance-testing-strategy.md#tc-root-01--physical-ownership-cannot-be-replaced-by-matching-names-or-bytes) — Physical ownership cannot be replaced by matching names or bytes

Design / plans:

- [Backup, diagnostics and compatibility](../../iCloud-Drive-Support-Spec.md#backup-diagnostics-and-compatibility) — iCloud-Drive-Support-Spec.md
- [Root events, shutdown and transitions](../../iCloud-Drive-Support-Spec.md#root-events-shutdown-and-transitions) — iCloud-Drive-Support-Spec.md
- [Repository copy versus current-notes export](../Implementation.md#repository-copy-versus-current-notes-export) — Implementation.md
- [8. Phase 4 — Startup, repair, repository copy and private state](../plan/swift-storage-implementation-plan.md#8-phase-4--startup-repair-repository-copy-and-private-state) — swift-storage-implementation-plan.md

### Current-note recovery after local acceptance failure

[Open walkthrough](nvstorage-object-map.html#scenario=unsaved-recovery&step=1)

An admitted edit remains visible when its SQL barrier fails. Retry retains exact pending identity; a recovery export must explicitly include coherent live pending values and verify a fresh destination before source work is released.

**Initial conditions.** An admitted edit is visible but its local SQL barrier fails. The user requests recovery Save As while that live work remains pending.

**Expected outcome.** Retain the live work, retry the urgent barrier or create a disclosed verified current-notes recovery export before transition.

1. **Local barrier failure after edit admission** (This Mac).

   Observable state: The visible pending text remains available; subsequent mutation is gated by local failure policy.

   Storage operation: Keep exact capture/retry input and pending generations while classifying committed, failed or uncertain outcomes.

   Applicable rule: An admitted value is not discarded because I/O failed; ambiguous identity is queried before allocating replacement work.

   Read / consume: `live`, `capture`, `seal`.

   Write / produce: `pendinglive`.

   Check / gate: `gate`, `localowner`.

2. **Selection of urgent retry or current-note recovery export** (This Mac).

   Observable state: The UI distinguishes urgent local retry from a current-notes recovery export that includes live pending values.

   Storage operation: Capture a coherent complete source and verify a fresh destination with explicitly disclosed history limits.

   Applicable rule: A repository-only copy may omit admitted RAM edits and cannot serve as evidence those edits were saved.

   Read / consume: `live`, `pendinglive`, `repairwork`.

   Write / produce: `copy`.

   Check / gate: `selectowner`, `gate`.

3. **Verification before source release or collection transition** (This Mac).

   Observable state: Source live work stays retained until the chosen recovery result is verified and the transition is applicable.

   Storage operation: Recheck source generation, required outputs, credentials and physical destination before association cutover.

   Applicable rule: Failure/cancellation leaves pending work and source intact; an old completion cannot certify newer edits.

   Read / consume: `copy`, `live`.

   Write / produce: `candidate`, `selection`.

   Check / gate: `selectowner`, `gate`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [BACKUP-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-COPY-02](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Recovery Save As during local failure with admitted unsaved work; current-state export; source changes during capture
- [TC-CLOSE-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Close with pending edits/external-editor handoff; materialization failure; pin/settings failure; provider wait; cancel/retry; old callbacks after switch
- [TC-DUR-04](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Sweep actual SQL transaction/VFS write/sync/commit outcomes, including persistent failures and interrupted recovery

Design / plans:

- [Root events, shutdown and transitions](../../iCloud-Drive-Support-Spec.md#root-events-shutdown-and-transitions) — iCloud-Drive-Support-Spec.md
- [Admission, sealing, and durability without a second WAL](../Protocol.md#admission-sealing-and-durability-without-a-second-wal) — Protocol.md
- [Repository copy versus current-notes export](../Implementation.md#repository-copy-versus-current-notes-export) — Implementation.md

### Close with local work pending and provider work stalled

[Open walkthrough](nvstorage-object-map.html#scenario=quit-offline&step=1)

One close owner quiesces admission and drains complete local actions plus required private state. After local durability, Quit Without Waiting retains unpublished objects and reconcilable projection intent; derived-row failure alone does not block close.

**Initial conditions.** Edits and an external-editor handoff are pending. Provider work is stalled and current materialization may fail independently.

**Expected outcome.** One close owner drains mandatory local state. After that, Quit Without Waiting retains unpublished objects and reconcilable file intent.

1. **Quiescing and mandatory local close barriers** (This Mac).

   Observable state: New admission quiesces while existing edits and external handoffs settle or are explicitly canceled.

   Storage operation: Capture close ownership/generations and force complete admitted note/action/parent barriers plus required private state.

   Applicable rule: No recursive last-chance save runs from applicationWillTerminate; local failure retains the app and live work for recovery.

   Read / consume: `pendinglive`, `capture`, `private`.

   Write / produce: `accepted`, `pin`.

   Check / gate: `gate`.

2. **Required-state persistence and separate external waits** (This Mac).

   Observable state: A derived materialization failure alone does not make a durable quit fail.

   Storage operation: Persist required settings/association and restart-reconcilable projection intent; optionally wait for captured provider/file work.

   Applicable rule: Unsaved required settings or mandatory key/association cutover failure is reported separately and cannot count as success.

   Read / consume: `accepted`, `pin`, `projectiondisk`.

   Write / produce: `private`, `pubwork`.

   Check / gate: `gate`.

3. **Deferred external work, callback draining and final ownership release** (This Mac).

   Observable state: Safe quit keeps unpublished exact objects; cancellation resumes only healthy admission.

   Storage operation: Fence/drain late callbacks and retain owned resources through settled accessors, then release ownership last.

   Applicable rule: Timeout is not instant OS cancellation. Old callbacks after a switch cannot clear or publish the next session’s work.

   Read / consume: `objects`, `receiveq`, `pendingdisk`, `rootowner`.

   Write / produce: `gate`.

   Check / gate: `localowner`.

Requirements: [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [WAIT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CKPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-CLOSE-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Close with pending edits/external-editor handoff; materialization failure; pin/settings failure; provider wait; cancel/retry; old callbacks after switch
- [TC-LIVE-01](../plan/swift-storage-conformance-testing-strategy.md#tc-live-01--local-durability-progresses-with-a-stuck-provider) — Local durability progresses with a stuck provider
- [TC-ASY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-asy-01--real-actorqueue-wiring-not-only-pure-transitions) — Real actor/queue wiring, not only pure transitions

Design / plans:

- [Root events, shutdown and transitions](../../iCloud-Drive-Support-Spec.md#root-events-shutdown-and-transitions) — iCloud-Drive-Support-Spec.md
- [Quit, root closure, and storage transitions](../Implementation.md#quit-root-closure-and-storage-transitions) — Implementation.md
- [11. Phase 7 — Application capture, history UI and lifecycle](../plan/swift-storage-implementation-plan.md#11-phase-7--application-capture-history-ui-and-lifecycle) — swift-storage-implementation-plan.md

### Root move followed by replacement at the old pathname

[Open walkthrough](nvstorage-object-map.html#scenario=root-move&step=1)

Held authority follows the positively same directory object through a move. A new directory at the old path remains a separate target despite matching collection identity or bytes, and delayed operations revalidate their captured physical/session context.

**Initial conditions.** Finder moves owned root R. A different directory appears at R’s old pathname with the same collection ID and protocol bytes.

**Expected outcome.** Held authority continues only for the positively same root. Replacement/loss fences affected provider effects while healthy local editing continues.

1. **Provider preparation under continuously owned root R** (This Mac).

   Observable state: The operation retains rooted descriptors, lifetime ownership and exact source/target generation.

   Storage operation: Acquire private/root ownership nonblockingly in the specified order and capture operation-local resources.

   Applicable rule: Known live lock contention is not bypassed by Work Offline; a scan never closes a borrowed owner descriptor.

   Read / consume: `rootowner`, `localowner`.

   Write / produce: `pubwork`, `filework`.

   Check / gate: `gate`.

2. **Movement of R and replacement at its former path** (This Mac).

   Observable state: A same-object move preserves supported continuity; the lookalike gains no authority.

   Storage operation: Use retained physical identity and positive forward provider revalidation, not pathname/UUID/hash matching.

   Applicable rule: A missing/revoked/ambiguous root pauses provider effects. It does not destroy a healthy private closure.

   Read / consume: `rootowner`, `appleowner`.

   Write / produce: `recvwork`.

   Check / gate: `gate`.

3. **Consumption of the delayed result in its original context** (This Mac).

   Observable state: It can settle only its captured root/session operation and cannot mutate the replacement.

   Storage operation: Revalidate consumer/root/lifecycle generations; retain entered accessor resources until completion/fence.

   Applicable rule: Offer explicit Re-open/Save As/Retry for loss; no silent same-ID pathname retargeting or receipt transplantation.

   Read / consume: `pubwork`, `filework`, `live`.

   Write / produce: `gate`.

   Check / gate: `rootowner`.

Requirements: [AUTH-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [WAIT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-ROOT-01](../plan/swift-storage-conformance-testing-strategy.md#tc-root-01--physical-ownership-cannot-be-replaced-by-matching-names-or-bytes) — Physical ownership cannot be replaced by matching names or bytes
- [TC-ASY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-asy-01--real-actorqueue-wiring-not-only-pure-transitions) — Real actor/queue wiring, not only pure transitions

Design / plans:

- [Storage, identity and ownership](../../iCloud-Drive-Support-Spec.md#storage-identity-and-ownership) — iCloud-Drive-Support-Spec.md
- [Root events, shutdown and transitions](../../iCloud-Drive-Support-Spec.md#root-events-shutdown-and-transitions) — iCloud-Drive-Support-Spec.md
- [AV-16 — root-directory lock contract](../../Apple-API-Contract-Validation.md#av-16--root-directory-lock-contract) — Apple-API-Contract-Validation.md
- [9. Phase 5 — Provider and physical-root adapters](../plan/swift-storage-implementation-plan.md#9-phase-5--provider-and-physical-root-adapters) — swift-storage-implementation-plan.md

### Collection switch, cancellation and late completion

[Open walkthrough](nvstorage-object-map.html#scenario=collection-switch&step=1)

One transition owner settles source work and verifies the chosen destination before association cutover. Cancellation resumes only healthy admission; late callbacks retain their original session scope and cannot affect the new collection.

**Initial conditions.** A folder switch is requested while edits are pending. The transition may be canceled, or it may finish while old provider/read callbacks remain outstanding.

**Expected outcome.** Admitted work settles under its original owner; only a verified explicit transition changes selection and activates a fresh session.

1. **Transition capture and source quiescing** (This Mac).

   Observable state: One close/transition owner quiesces admission and settles mandatory source work.

   Storage operation: Capture session/root/store generations and destination intent while retaining continuous source locks.

   Applicable rule: Canceled close does not temporarily release and reacquire authority; admission resumes only if health permits.

   Read / consume: `live`, `pendinglive`, `rootowner`.

   Write / produce: `selectowner`, `gate`.

   Check / gate: `localowner`.

2. **Destination verification and fresh-session activation** (This Mac).

   Observable state: A complete verified destination gets fresh physical ownership and editable-session origin/epoch.

   Storage operation: Recheck bootstrap/key/closure and durable private selection/association before final publication.

   Applicable rule: Matching collection ID does not transfer root permission or existing file receipts.

   Read / consume: `copy`, `candidate`, `secrets`.

   Write / produce: `selection`, `live`, `view`.

   Check / gate: `selectowner`, `gate`.

3. **Fencing of an old callback after cutover** (This Mac).

   Observable state: The new collection’s text, pending work and view stay unchanged by the stale result.

   Storage operation: Consume late work only against its captured operation/session resources, retaining ownership until it settles.

   Applicable rule: No completion reopens a dismissed view, clears a new session’s work or widens the old command’s target.

   Read / consume: `recvwork`, `filework`, `views`.

   Write / produce: `gate`.

   Check / gate: `rootowner`.

Requirements: [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [AUTH-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-CLOSE-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Close with pending edits/external-editor handoff; materialization failure; pin/settings failure; provider wait; cancel/retry; old callbacks after switch
- [TC-ASY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-asy-01--real-actorqueue-wiring-not-only-pure-transitions) — Real actor/queue wiring, not only pure transitions
- [TC-ROOT-01](../plan/swift-storage-conformance-testing-strategy.md#tc-root-01--physical-ownership-cannot-be-replaced-by-matching-names-or-bytes) — Physical ownership cannot be replaced by matching names or bytes

Design / plans:

- [Root events, shutdown and transitions](../../iCloud-Drive-Support-Spec.md#root-events-shutdown-and-transitions) — iCloud-Drive-Support-Spec.md
- [Quit, root closure, and storage transitions](../Implementation.md#quit-root-closure-and-storage-transitions) — Implementation.md
- [11. Phase 7 — Application capture, history UI and lifecycle](../plan/swift-storage-implementation-plan.md#11-phase-7--application-capture-history-ui-and-lifecycle) — swift-storage-implementation-plan.md

### Verified migration from recovered epoch-4 state

[Open walkthrough](nvstorage-object-map.html#scenario=legacy-migration&step=1)

Migration first recovers and coherently captures legacy current values. The fresh destination must verify its complete genesis/import/snapshot, required output and credentials before association changes; failure preserves the legacy source.

**Initial conditions.** The legacy Notes & Settings/WAL path first recovers current notes. Migration targets a new segment collection with a supported codec/profile.

**Expected outcome.** Complete genesis/import/snapshot and required outputs are verified before cutover; failed migration preserves legacy source and credentials.

1. **Recovery and coherent capture of legacy source values** (This Mac).

   Observable state: Current legacy values are recovered through the genuine epoch-4 path before conversion.

   Storage operation: Settle external work and capture complete initial values/count/canonical digest with disclosed target format/profile.

   Applicable rule: Unsupported rich/attachment conversion preserves source and requires explicit supported handling; no silent flattening.

   Read / consume: `legacy`, `live`.

   Write / produce: `capture`, `repairwork`.

   Check / gate: `selectowner`, `gate`.

2. **Complete initial-history construction and verification** (This Mac).

   Observable state: Genesis, dependency-linked batches, ImportComplete and complete snapshot agree with the commitment.

   Storage operation: Seal/validate all initial objects, durably accept their closure, and verify required plaintext/credential output independently.

   Applicable rule: Interrupted or contradictory bootstrap cannot become a successful partial/empty collection.

   Read / consume: `capture`, `snapwork`.

   Write / produce: `candidate`, `rkeys`, `rchanges`, `rinitial`.

   Check / gate: `gate`.

3. **Source-generation check and verified association cutover** (This Mac).

   Observable state: Only verified destination evidence commits active association; failures leave the source usable.

   Storage operation: Read back independent credentials and recheck source generation before durable selection cutover.

   Applicable rule: Explicit legacy export remains genuine epoch-4 current-state output. No live compatibility archive or mixed-version segment writer is introduced.

   Read / consume: `candidate`, `repairwork`.

   Write / produce: `selection`, `copy`.

   Check / gate: `selectowner`.

Requirements: [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [CRYPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [BACKUP-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry), [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry).

Test contracts:

- [TC-LEGACY-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Existing epoch-4 open/recovery/export tests plus new independent destination migration failure cases
- [TC-START-01](../plan/swift-storage-conformance-testing-strategy.md#tc-start-01--complete-bootstrap-and-current-row-startup) — Complete bootstrap and current-row startup
- [TC-RICH-01](../plan/swift-storage-conformance-testing-strategy.md#9-remaining-scenario-backlog-and-caller-coverage) — Existing rich or attachment-bearing legacy inputs presented to a plaintext-only destination; unsupported format/conversion and failed migration
- [TC-KEY-01](../plan/swift-storage-conformance-testing-strategy.md#tc-key-01--credential-and-association-cutover-have-different-failure-boundaries) — Credential and association cutover have different failure boundaries

Design / plans:

- [Startup, creation and private current state](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state) — iCloud-Drive-Support-Spec.md
- [Root events, shutdown and transitions](../../iCloud-Drive-Support-Spec.md#root-events-shutdown-and-transitions) — iCloud-Drive-Support-Spec.md
- [Backup, diagnostics and compatibility](../../iCloud-Drive-Support-Spec.md#backup-diagnostics-and-compatibility) — iCloud-Drive-Support-Spec.md
- [8. Phase 4 — Startup, repair, repository copy and private state](../plan/swift-storage-implementation-plan.md#8-phase-4--startup-repair-repository-copy-and-private-state) — swift-storage-implementation-plan.md

## Requirement coverage

Every normative registry entry has at least one linked scenario. This is explanatory coverage; actual qualification evidence is tracked by the conformance strategy and validation reports.

- [AUTH-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Publication retry after an uncertain completion](nvstorage-object-map.html#scenario=publication-retry&step=1); [Projection stamp arriving before its named history](nvstorage-object-map.html#scenario=stamp-waits&step=1); [Automatic repair of positively absent same-root NV Data](nvstorage-object-map.html#scenario=repository-repair&step=1); [Fresh private-store bootstrap from a selected repository](nvstorage-object-map.html#scenario=fresh-mac&step=1); [Password unlock with an unavailable remembered key](nvstorage-object-map.html#scenario=unlock&step=1); [Repository copy with unavailable entries and no private store](nvstorage-object-map.html#scenario=repository-copy&step=1); [Root move followed by replacement at the old pathname](nvstorage-object-map.html#scenario=root-move&step=1); [Collection switch, cancellation and late completion](nvstorage-object-map.html#scenario=collection-switch&step=1).
- [START-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Crash recovery before and after the local commit](nvstorage-object-map.html#scenario=save-crash&step=1); [Returning startup with optional snapshot work queued](nvstorage-object-map.html#scenario=fast-startup&step=1); [Startup with positively disclosed but unreadable newer evidence](nvstorage-object-map.html#scenario=work-offline&step=1); [Reconstruction of invalid derived current rows](nvstorage-object-map.html#scenario=derived-rebuild&step=1); [Restart during retained-history verification](nvstorage-object-map.html#scenario=verification-restart&step=1); [Required retained object missing from all available sources](nvstorage-object-map.html#scenario=missing-history&step=1); [Fresh private-store bootstrap from a selected repository](nvstorage-object-map.html#scenario=fresh-mac&step=1); [Password unlock with an unavailable remembered key](nvstorage-object-map.html#scenario=unlock&step=1); [Verified migration from recovered epoch-4 state](nvstorage-object-map.html#scenario=legacy-migration&step=1).
- [DISC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Receipt of a Delete before its parent edit](nvstorage-object-map.html#scenario=child-first&step=1); [Publication retry after an uncertain completion](nvstorage-object-map.html#scenario=publication-retry&step=1); [Automatic import of an eligible ordinary text file](nvstorage-object-map.html#scenario=automatic-import&step=1); [Projection stamp arriving before its named history](nvstorage-object-map.html#scenario=stamp-waits&step=1).
- [PUB-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Local save while the provider is unavailable](nvstorage-object-map.html#scenario=offline-save&step=1); [Delayed save completion with a newer pending generation](nvstorage-object-map.html#scenario=delayed-save&step=1); [Returning startup with optional snapshot work queued](nvstorage-object-map.html#scenario=fast-startup&step=1); [Automatic merge of strictly separated line edits](nvstorage-object-map.html#scenario=separated-merge&step=1); [Review after overlapping edits or a third head](nvstorage-object-map.html#scenario=merge-review&step=1); [Ordinary editing of one unresolved head](nvstorage-object-map.html#scenario=ordinary-conflict-edit&step=1); [Retraction after a later Delete covers a preserved edit](nvstorage-object-map.html#scenario=retracted-copy&step=1); [Historical body restoration with current title and labels](nvstorage-object-map.html#scenario=selective-history&step=1); [Causal Undo after relaunch or on another Mac](nvstorage-object-map.html#scenario=portable-undo&step=1); [Reviewed Undo with an actual-current inverse](nvstorage-object-map.html#scenario=reviewed-undo&step=1); [Partial native Undo followed by relaunch](nvstorage-object-map.html#scenario=native-remaining&step=1); [Shared-note windows during composition and remote publication](nvstorage-object-map.html#scenario=shared-windows&step=1); [Dedicated saved-search windows and bookmark preferences](nvstorage-object-map.html#scenario=saved-search-windows&step=1); [Automatic import of an eligible ordinary text file](nvstorage-object-map.html#scenario=automatic-import&step=1); [Source change before external-file choice admission](nvstorage-object-map.html#scenario=pending-choice&step=1); [Source change after external-file operation admission](nvstorage-object-map.html#scenario=admitted-file&step=1); [External disappearance during deletion confirmation](nvstorage-object-map.html#scenario=external-deletion&step=1); [New projection intent C while installation B is unfinished](nvstorage-object-map.html#scenario=projection-abc&step=1); [Scoped disposition of an Apple unresolved version](nvstorage-object-map.html#scenario=apple-versions&step=1); [External-editor handoff from an encrypted collection](nvstorage-object-map.html#scenario=external-editor&step=1); [Collection switch, cancellation and late completion](nvstorage-object-map.html#scenario=collection-switch&step=1).
- [REC-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Review after overlapping edits or a third head](nvstorage-object-map.html#scenario=merge-review&step=1); [Historical body restoration with current title and labels](nvstorage-object-map.html#scenario=selective-history&step=1); [Durable preservation of a selected unresolved revision](nvstorage-object-map.html#scenario=conflict-copy&step=1); [Source change before external-file choice admission](nvstorage-object-map.html#scenario=pending-choice&step=1); [Scoped disposition of an Apple unresolved version](nvstorage-object-map.html#scenario=apple-versions&step=1).
- [DUR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Local save while the provider is unavailable](nvstorage-object-map.html#scenario=offline-save&step=1); [Crash recovery before and after the local commit](nvstorage-object-map.html#scenario=save-crash&step=1); [Delayed save completion with a newer pending generation](nvstorage-object-map.html#scenario=delayed-save&step=1); [Restart during retained-history verification](nvstorage-object-map.html#scenario=verification-restart&step=1); [Receipt of a Delete before its parent edit](nvstorage-object-map.html#scenario=child-first&step=1); [Publication retry after an uncertain completion](nvstorage-object-map.html#scenario=publication-retry&step=1); [Concurrent Delete and offline edit on separate Macs](nvstorage-object-map.html#scenario=delete-race&step=1); [Snapshot retention ancestry and logical operation cuts](nvstorage-object-map.html#scenario=snapshot-retention&step=1); [Named restoration followed by deletion of the fresh birth](nvstorage-object-map.html#scenario=recently-deleted&step=1); [Causal Undo after relaunch or on another Mac](nvstorage-object-map.html#scenario=portable-undo&step=1); [Reviewed Undo with an actual-current inverse](nvstorage-object-map.html#scenario=reviewed-undo&step=1); [Concurrent compensation of the same action](nvstorage-object-map.html#scenario=concurrent-undo&step=1); [Partial native Undo followed by relaunch](nvstorage-object-map.html#scenario=native-remaining&step=1); [Durable preservation of a selected unresolved revision](nvstorage-object-map.html#scenario=conflict-copy&step=1); [Source change after external-file operation admission](nvstorage-object-map.html#scenario=admitted-file&step=1); [New projection intent C while installation B is unfinished](nvstorage-object-map.html#scenario=projection-abc&step=1); [Scoped disposition of an Apple unresolved version](nvstorage-object-map.html#scenario=apple-versions&step=1); [External-editor handoff from an encrypted collection](nvstorage-object-map.html#scenario=external-editor&step=1); [Automatic repair of positively absent same-root NV Data](nvstorage-object-map.html#scenario=repository-repair&step=1); [Fresh-store repair from complementary retained copies](nvstorage-object-map.html#scenario=private-repair&step=1); [Required retained object missing from all available sources](nvstorage-object-map.html#scenario=missing-history&step=1); [Private backup containing unpublished and pending work](nvstorage-object-map.html#scenario=private-backup&step=1); [Same-key password rewrap and full key/profile conversion](nvstorage-object-map.html#scenario=password-rewrap&step=1); [Current-note recovery after local acceptance failure](nvstorage-object-map.html#scenario=unsaved-recovery&step=1); [Close with local work pending and provider work stalled](nvstorage-object-map.html#scenario=quit-offline&step=1); [Collection switch, cancellation and late completion](nvstorage-object-map.html#scenario=collection-switch&step=1); [Verified migration from recovered epoch-4 state](nvstorage-object-map.html#scenario=legacy-migration&step=1); [Optional current-row recoding and full-VACUUM maintenance](nvstorage-object-map.html#scenario=idle-maintenance&step=1).
- [CLEAN-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Publication retry after an uncertain completion](nvstorage-object-map.html#scenario=publication-retry&step=1); [Retraction after a later Delete covers a preserved edit](nvstorage-object-map.html#scenario=retracted-copy&step=1); [Snapshot retention ancestry and logical operation cuts](nvstorage-object-map.html#scenario=snapshot-retention&step=1); [Automatic repair of positively absent same-root NV Data](nvstorage-object-map.html#scenario=repository-repair&step=1); [Fresh-store repair from complementary retained copies](nvstorage-object-map.html#scenario=private-repair&step=1).
- [ROOT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Local save while the provider is unavailable](nvstorage-object-map.html#scenario=offline-save&step=1); [Startup with positively disclosed but unreadable newer evidence](nvstorage-object-map.html#scenario=work-offline&step=1); [Shared-note windows during composition and remote publication](nvstorage-object-map.html#scenario=shared-windows&step=1); [Dedicated saved-search windows and bookmark preferences](nvstorage-object-map.html#scenario=saved-search-windows&step=1); [Fresh-store repair from complementary retained copies](nvstorage-object-map.html#scenario=private-repair&step=1); [Current-note recovery after local acceptance failure](nvstorage-object-map.html#scenario=unsaved-recovery&step=1); [Close with local work pending and provider work stalled](nvstorage-object-map.html#scenario=quit-offline&step=1); [Root move followed by replacement at the old pathname](nvstorage-object-map.html#scenario=root-move&step=1); [Collection switch, cancellation and late completion](nvstorage-object-map.html#scenario=collection-switch&step=1); [Optional current-row recoding and full-VACUUM maintenance](nvstorage-object-map.html#scenario=idle-maintenance&step=1).
- [CKPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Local save while the provider is unavailable](nvstorage-object-map.html#scenario=offline-save&step=1); [Delayed save completion with a newer pending generation](nvstorage-object-map.html#scenario=delayed-save&step=1); [Returning startup with optional snapshot work queued](nvstorage-object-map.html#scenario=fast-startup&step=1); [Reconstruction of invalid derived current rows](nvstorage-object-map.html#scenario=derived-rebuild&step=1); [Snapshot retention ancestry and logical operation cuts](nvstorage-object-map.html#scenario=snapshot-retention&step=1); [Close with local work pending and provider work stalled](nvstorage-object-map.html#scenario=quit-offline&step=1); [Optional current-row recoding and full-VACUUM maintenance](nvstorage-object-map.html#scenario=idle-maintenance&step=1).
- [WAIT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Startup with positively disclosed but unreadable newer evidence](nvstorage-object-map.html#scenario=work-offline&step=1); [Scoped disposition of an Apple unresolved version](nvstorage-object-map.html#scenario=apple-versions&step=1); [Close with local work pending and provider work stalled](nvstorage-object-map.html#scenario=quit-offline&step=1); [Root move followed by replacement at the old pathname](nvstorage-object-map.html#scenario=root-move&step=1).
- [DELETE-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Receipt of a Delete before its parent edit](nvstorage-object-map.html#scenario=child-first&step=1); [Concurrent Delete and offline edit on separate Macs](nvstorage-object-map.html#scenario=delete-race&step=1); [Retraction after a later Delete covers a preserved edit](nvstorage-object-map.html#scenario=retracted-copy&step=1); [Named restoration followed by deletion of the fresh birth](nvstorage-object-map.html#scenario=recently-deleted&step=1); [Concurrent compensation of the same action](nvstorage-object-map.html#scenario=concurrent-undo&step=1); [Disappearance of an unadmitted pending external file](nvstorage-object-map.html#scenario=disappeared-file&step=1); [External disappearance during deletion confirmation](nvstorage-object-map.html#scenario=external-deletion&step=1).
- [HIST-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Crash recovery before and after the local commit](nvstorage-object-map.html#scenario=save-crash&step=1); [Automatic merge of strictly separated line edits](nvstorage-object-map.html#scenario=separated-merge&step=1); [Review after overlapping edits or a third head](nvstorage-object-map.html#scenario=merge-review&step=1); [Ordinary editing of one unresolved head](nvstorage-object-map.html#scenario=ordinary-conflict-edit&step=1); [Concurrent Delete and offline edit on separate Macs](nvstorage-object-map.html#scenario=delete-race&step=1); [Retraction after a later Delete covers a preserved edit](nvstorage-object-map.html#scenario=retracted-copy&step=1); [Snapshot retention ancestry and logical operation cuts](nvstorage-object-map.html#scenario=snapshot-retention&step=1); [Historical body restoration with current title and labels](nvstorage-object-map.html#scenario=selective-history&step=1); [Named restoration followed by deletion of the fresh birth](nvstorage-object-map.html#scenario=recently-deleted&step=1); [Causal Undo after relaunch or on another Mac](nvstorage-object-map.html#scenario=portable-undo&step=1); [Reviewed Undo with an actual-current inverse](nvstorage-object-map.html#scenario=reviewed-undo&step=1); [Concurrent compensation of the same action](nvstorage-object-map.html#scenario=concurrent-undo&step=1); [Partial native Undo followed by relaunch](nvstorage-object-map.html#scenario=native-remaining&step=1); [Shared-note windows during composition and remote publication](nvstorage-object-map.html#scenario=shared-windows&step=1); [Dedicated saved-search windows and bookmark preferences](nvstorage-object-map.html#scenario=saved-search-windows&step=1); [Durable preservation of a selected unresolved revision](nvstorage-object-map.html#scenario=conflict-copy&step=1); [Fresh private-store bootstrap from a selected repository](nvstorage-object-map.html#scenario=fresh-mac&step=1); [Encrypted history, plaintext output and conversion limits](nvstorage-object-map.html#scenario=privacy-profile&step=1).
- [CRYPT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [External-editor handoff from an encrypted collection](nvstorage-object-map.html#scenario=external-editor&step=1); [Fresh private-store bootstrap from a selected repository](nvstorage-object-map.html#scenario=fresh-mac&step=1); [Private backup containing unpublished and pending work](nvstorage-object-map.html#scenario=private-backup&step=1); [Password unlock with an unavailable remembered key](nvstorage-object-map.html#scenario=unlock&step=1); [Same-key password rewrap and full key/profile conversion](nvstorage-object-map.html#scenario=password-rewrap&step=1); [Encrypted history, plaintext output and conversion limits](nvstorage-object-map.html#scenario=privacy-profile&step=1); [Verified migration from recovered epoch-4 state](nvstorage-object-map.html#scenario=legacy-migration&step=1).
- [BACKUP-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Private backup containing unpublished and pending work](nvstorage-object-map.html#scenario=private-backup&step=1); [Same-key password rewrap and full key/profile conversion](nvstorage-object-map.html#scenario=password-rewrap&step=1); [Encrypted history, plaintext output and conversion limits](nvstorage-object-map.html#scenario=privacy-profile&step=1); [Repository copy with unavailable entries and no private store](nvstorage-object-map.html#scenario=repository-copy&step=1); [Current-note recovery after local acceptance failure](nvstorage-object-map.html#scenario=unsaved-recovery&step=1); [Verified migration from recovered epoch-4 state](nvstorage-object-map.html#scenario=legacy-migration&step=1).
- [REPAIR-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Startup with positively disclosed but unreadable newer evidence](nvstorage-object-map.html#scenario=work-offline&step=1); [Reconstruction of invalid derived current rows](nvstorage-object-map.html#scenario=derived-rebuild&step=1); [Restart during retained-history verification](nvstorage-object-map.html#scenario=verification-restart&step=1); [Disappearance of an unadmitted pending external file](nvstorage-object-map.html#scenario=disappeared-file&step=1); [Automatic repair of positively absent same-root NV Data](nvstorage-object-map.html#scenario=repository-repair&step=1); [Fresh-store repair from complementary retained copies](nvstorage-object-map.html#scenario=private-repair&step=1); [Required retained object missing from all available sources](nvstorage-object-map.html#scenario=missing-history&step=1); [Fresh private-store bootstrap from a selected repository](nvstorage-object-map.html#scenario=fresh-mac&step=1); [Private backup containing unpublished and pending work](nvstorage-object-map.html#scenario=private-backup&step=1); [Repository copy with unavailable entries and no private store](nvstorage-object-map.html#scenario=repository-copy&step=1).
- [IMPORT-01](../../iCloud-Drive-Support-Spec.md#normative-requirement-registry) — [Automatic import of an eligible ordinary text file](nvstorage-object-map.html#scenario=automatic-import&step=1); [Projection stamp arriving before its named history](nvstorage-object-map.html#scenario=stamp-waits&step=1); [Source change before external-file choice admission](nvstorage-object-map.html#scenario=pending-choice&step=1); [Source change after external-file operation admission](nvstorage-object-map.html#scenario=admitted-file&step=1); [Disappearance of an unadmitted pending external file](nvstorage-object-map.html#scenario=disappeared-file&step=1); [External disappearance during deletion confirmation](nvstorage-object-map.html#scenario=external-deletion&step=1); [New projection intent C while installation B is unfinished](nvstorage-object-map.html#scenario=projection-abc&step=1).
