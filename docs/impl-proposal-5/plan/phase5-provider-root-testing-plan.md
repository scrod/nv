# Phase 5 testing plan: provider transport and physical roots

Date: 2026-10-08

Status: implementation and qualification plan; the cases below are planned, not completed evidence.

Scope: Phase 5 of the [Swift roadmap](swift-storage-implementation-plan.md#9-phase-5--provider-and-physical-root-adapters).

Implementation order: [multipart Phase 5 plan](phase5-provider-root-implementation-plan.md),
with prerequisite, compiler-boundary, test and exit gates for P5.0–P5.7.

The expanded [P5.4 implementation plan](phase5/04-apple-coordination-and-discovery.md)
connects P5.3 callers to real coordination and automatic scheduling.
Its [P54-* matrix](phase5/04-apple-coordination-and-discovery.md#5-scenario-and-independent-observation-matrix)
specializes the families below for accessor/presenter lifetime, bounded resumption,
materialization/continuity inputs and signed two-Mac production consumers. These
have revision-bound results in the
[P5.4 qualification ledger](phase5/04-apple-coordination-and-discovery-validation.md).
The detailed [P5.5 plan](phase5/05-startup-and-root-reassociation.md) specializes
startup/create/root/replay cases as P55-01–24, with ordered implementation gates,
real admission/choice/transition consumers, independent observations, fault cuts
and compiler/mutation checks. Those P5.5 witnesses remain planned.

## 1. Purpose, authority and boundaries

Connect the implemented storage library to real directories without losing the
properties established by the local and two-store tests. The first useful path is
local save → exact provider installation → discovery on another independently
owned store → complete acceptance → checked current values → fresh-process reopen.
Qualify each increment before adding the next.

The [specification](../../iCloud-Drive-Support-Spec.md), [ADRs](../../adr),
[CONTEXT](../../../CONTEXT.md) and [active-model coverage](../../tla/Proposal5-Coverage.md)
remain the authorities. This plan applies the [conformance strategy](swift-storage-conformance-testing-strategy.md)
and [Swift language-boundary proposal](swift-storage-library-proposal-v2.md) to
physical effects. Read the [Apple API ledger](../../Apple-API-Contract-Validation.md)
and [Foundation migration contract](../../Foundation-Safe-Replacement-Migration.md)
when qualifying those adapters. Test labels here name scenarios, not new protocol
records, persistent state or public API types.

Phase 5 implements root/provider adapters and headless consumers of their results.
It exercises existing Create/Edit/Delete/Restore/conflict/compensation semantics
through transport. Plaintext projection admission, association, external-deletion
confirmation and pending-file completion remain Phase 6; AppKit editing, resolver
presentation, actual Command-Z routing and application quit/switch remain Phase 7.
Shared physical helpers get their primitive tests now, with actual later callers
remaining explicit gates. Provider transport for `PlaintextFilesV1` is therefore
qualified separately from that profile's complete text-file feature.

Use both profiles throughout. Both private databases have encrypted pages;
`EncryptedSegmentsV1` also conceals note contents in the provider repository.
Every new compressed envelope uses the adopted zstd profile. Preserve epoch-4
opening/recovery/export and the existing benchmarks; legacy WAL scenarios supply
legacy evidence only.

### Acceptance properties

| Property | Independent evidence required | Contract basis |
| --- | --- | --- |
| A saved action survives failure | Exact immutable bytes, complete action/operation membership and required closure survive fresh reopening, including lost completions | DUR-01, CKPT-01; TC-DUR-04–06 |
| Transport preserves the saved action | The receiver reads the sender's exact sealed bytes and obtains the independently expected identities, values and dispositions once | DISC-01, HIST-01; TC-DISC-01, TC-ACT-04, TC-MERGE-02 |
| Filesystem effects address the owned resource | Independent contenders and rooted observations establish authority; replacement at the same pathname never transfers it | AUTH-01, ROOT-01; TC-ROOT-01, AV-15–16 |
| Partial information grants no additional authority | Missing, unreadable, unsupported, wrong-context or stale evidence cannot authorize overwrite, partial acceptance, editable bootstrap or cleanup | START-01, PUB-01, REPAIR-01; TC-ASY-01, TC-START-02–03 |
| Local saving is independent of transport | An actually entered, held provider accessor coexists with a completed local durability barrier and later fresh reopen | ROOT-01, WAIT-01; TC-LIVE-01 |
| Valid work resumes | After finite interference ends, owned ready work finishes without another delivery; after storage failure, explicit recovery/retry resumes unrelated work | WAIT-01, DUR-01; TC-ASY-01, TC-DISC-01 |
| Repair and copy preserve evidence | The exact validated union, private-only work and displaced artifacts remain accounted for; incomplete output is never reported as full history | REPAIR-01, BACKUP-01, CLEAN-01; TC-REPAIR-01, TC-COPY-01–02 |
| Privacy survives error handling | Real output, staging, recovery artifacts and diagnostic sinks satisfy the declared profile without plaintext fallback | CRYPT-01; TC-PRIV-01 |

Agreement between two receivers is supplementary: they can agree after losing
the same action. Compare with independently specified contents, identities,
unresolved alternatives, represented revisions, Undo/Redo candidates and pending
obligations. A newly admitted edit may remain pending; durability assertions apply
only at its actual complete local barrier.

## 2. Delivery order and test ownership

The increments below are implementation/test packages, not additional product
phases. Reuse the existing test driver and production library rather than creating
a second storage implementation or general workflow framework.

These 5A–5E groups organize testing scope. The
[dependency-ordered parts](phase5-provider-root-implementation-plan.md#dependency-order)
divide them into concrete implementation increments: P5.0–P5.2 establish 5A,
P5.3 delivers 5B, P5.4–P5.5 connect 5C, P5.6 connects 5D and P5.7 consolidates 5E.
Qualification starts in the part introducing the effect, not only in P5.7.

| Increment | Production path and tests to complete together | Exit evidence |
| --- | --- | --- |
| 5A — physical boundary | Inventory helpers; implement owned root/private-directory acquisition, coherent reads and strict exclusive immutable installation. Test independent processes, collisions, barriers and actual cleanup | Root ownership and installation predicates hold on qualified local filesystems; unavailable capabilities return explicit outcomes |
| 5B — first real exchange | Publish real durable bootstrap/actions/descriptors; discover, retain, accept, reduce and reopen a second store. Start P5-DISC, P5-DELIVER and P5-LIVE here | Missed wakeups, reordered delivery and stale prepared results are exercised through the actual adapter, not just Core |
| 5C — provider execution | Bind coordination, presenter/materialization and root-session lifecycle; test hung accessors, cancellation, same-root moves, replacement and startup classification | Local progress, lifetime fences and actual API observations support the production consumers |
| 5D — recovery and transitions | Connect provider repair, complementary private repair, repository copy and explicit root reassociation to qualified physical helpers | Repeated crash/I/O schedules preserve sources and complete known history without acquiring stale physical permissions |
| 5E — qualification | Run filesystem/OS/architecture/profile jobs, signed two-Mac tests, privacy/resource checks and connected schedules | A revision-bound report distinguishes passing production witnesses, unsupported operations and remaining release gaps |

In 5A, freeze a caller inventory listing actual symbols and their intent, execution
lane, evidence issuer, final consumer, durability boundary and cleanup owner.
Update it as each path lands. The following existing material is reusable evidence
and infrastructure, with a new production-caller witness still required:

- [Integration guide](../../IntegrationTests.md) and [Makefile](../../../tests/Makefile):
  rooted snapshots, relocation, deep directories, filename collisions, stress,
  filesystem images and standalone library jobs.
- `NVStorage` native Swift tests, fresh-process probe and independent history
  inspector: acceptance, scoped queries, pending inputs, repair and copy fixtures.
- AV-01–03/07–09/12–13 and AV-15–17: status/materialization, coordination,
  invalidation, root identity, app identity, directory exclusion and immutable
  installation. Successful probes establish only their observed primitive.
- Foundation replacement and directory-lock probes: explicit metadata, displaced
  bytes, current-URL reconstruction, independent contention and descriptor lifetime.

Keep `make -C tests run-swift-storage` and `run-swift-storage-phase2` as existing
regression entrypoints. Add the new suites and process schedules to that driver
as they become executable; document exact additional selections in the integration
guide. Live-provider and disk-image jobs remain separately selected. Planned
scenario IDs in this document are not executable commands.

## 3. Test boundary and independent observations

Use four separate roles for each critical scenario:

1. **Stimulus:** an immutable command schedule and literal/independently generated
   expected history; it specifies user intent and environment changes.
2. **Production executor:** the actual Runtime, root adapter and qualified physical
   helper. Inject faults below effects, not by returning fabricated receipts.
3. **Observer:** independent descriptors/processes, exact-byte inventories and SQL
   inspection establish effects. A runtime success flag is a claim to check.
4. **Recovery consumer:** a newly exec'ed production client receives only surviving
   roots/stores, normal selection/unlock inputs and explicit choices. The expected
   notes and the parent's acknowledgment log stay with the observer.

For two-store tests use separate private directories, owners, writer epochs and
action origins. Exchange real envelopes through the real transport path. Selected
three-writer cases add a later branch, an independent snapshot tip or a copied
disposition that two writers would omit. A deterministic local delivery controller
controls visibility/readability and notifications while invoking production
decisions; the live two-Mac run separately qualifies actual provider delivery.

Use native Swift Testing with parameterized cases and per-test owned temporary
directories. Await explicit entry/effect/return handshakes, not sleeps or an
assumed number of `Task.yield()` calls. Callback confirmations must remain active
through the observed completion. Protect genuinely shared provider/image fixtures
at the driver level: `.serialized` on one suite does not exclude another process
or suite. Use the existing completion controls and workers; no new concurrency
dependency or forced main-thread executor is needed.

Each critical case has a valid companion, a minimally invalid or interfering
variant, a witness that reaches the challenged production boundary, independent
assertions and a targeted mutation (§10). A path returning unsupported, never
starting, or permanently rejecting all work cannot qualify the valid case.

### Evidence that must be recorded

- Captured command/action/operation IDs, exact sealed object IDs/bytes and closure.
- Root/private-store identities and generations, separately from collection IDs;
  local filesystem IDs are compared only within their qualified local context.
- Low-level operation entry/return, completed barriers, namespace observations and
  completion delivery as separate events.
- Accepted versus parked/rejected membership, reverse waits, retained frontier,
  verification requests and current-row represented prefix/context.
- Independently expected values, note births/heads, unresolved alternatives,
  copied-version dispositions and relevant Undo/Redo candidates.
- Pending generations, owned buffers/descriptors, lifecycle and completed cleanup.

Debug diagnostics carry closed classifications and synthetic identifiers. Keep
secret-bearing oracle fixtures in explicitly test-owned artifacts, distinct from
production logs inspected by the privacy tests.

## 4. Qualify physical operations by intent

| Operation | Required checks and race variants | Completion predicate |
| --- | --- | --- |
| Owned root/private directory | Non-following open, independently exec'ed contention, separate scan close, descriptor handoff, kill/reacquire, move, recreated old path, unknown continuity | Ownership addresses the actual directory object; provider and private ownership remain independent; no retarget from matching path/collection bytes |
| Coherent immutable read | Length/bounds before allocation; exact rooted open; truncate/rewrite/replace during observation; placeholder/read failure; changed collection/profile | Retained bytes and observation belong to the same verified object; failure/unknown is not absence or a valid empty object |
| Exclusive immutable installation | Complete staged bytes; generated locator; file barrier; exclusive final-name install; rooted exact readback; every required directory barrier; equal/foreign/wrong-kind race winners | Only a complete verified object is published at the final name; equality is idempotent only with the required verification and durability work |
| Existing regular-file replacement | Complete stage, same-volume operation, preserved displaced bytes, rooted installed identity/readback, required metadata and intent-specific barriers | Typed not-installed / verified / reconciliation-required result accurately accounts for old, new and displaced contents |
| Protocol directory creation or directory repair | Nested creation barriers, populated directories, kind collisions, compatible/foreign concurrent occupants, preserved damaged input | Qualified add-only partial output or a verified replacement; complete known closure is required before reporting full repair |
| Repository copy or recovery export | Captured source inventory, exact copy verification, independently inspected destination and missing dependencies; source changes | Exact captured inventory is preserved or reported incomplete. Full-history copy and current-state export remain distinct |

### 4.1 Strict new-object installation

Sweep every production caller: segment, descriptor, snapshot page/root, repair and
repository copy. An equal preexisting final must exercise the real verification
and applicable namespace barriers, including the “another process installed it
but no durability evidence survived” companion. Conflicting bytes under one
immutable locator are preserved and reported, never overwritten or accepted.

Challenge the actual path-rendering/discovery boundary with wrong locator kinds,
collections/profiles, malformed widths/tags, traversal components, reserved names,
nested symlinks, excessive lengths/counts and valid objects under renamed leaves.
Enforce bounds before reads/allocations and authenticate encrypted payloads before
interpreting or decompressing them. Publish/retry by copying the already retained
sealed bytes: inspect both invocation counts and inventories to catch resealing.
Receiving/materializing those bytes must author no echo Put or new local action.

The legacy `NVInstallNewFile` path in [NVRootedDirectory.m](../../../NVRootedDirectory.m)
can fall back to opening the final name and then copying into it. Its reported
best-effort capability can expose empty/partial contents. A successful legacy
test therefore cannot qualify strict immutable publication. Force that fallback
in a reader-race test. Qualify a complete-stage exclusive-install mechanism before
reuse, or return the specified unsupported/sync-paused outcome. Filesystem names
and capability advertisements alone choose no policy. A missing primitive is a
contract gap to report, not permission to weaken the contract silently.

### 4.2 Foundation replacement and caller gates

Reuse the full [Foundation acceptance table](../../Foundation-Safe-Replacement-Migration.md#preservation-of-the-atomic-note-saves-contract).
In particular:

- Obtain the same-volume replacement directory through fresh operation-local URL
  state. After replacement, regenerate later references; the returned URL is a
  candidate, with rooted reopen/identity/readback providing the actual check.
- Verify complete old-or-new visibility with concurrent independent readers.
  Test occupied backup names before invoking Foundation, retained exact backup
  bytes and late failures exposing original-item candidate locations. Fresh naming
  and observation are not an atomic reservation against arbitrary other writers.
- Distinguish note replacement's displaced-byte conflict accounting from mutable
  selected-store metadata's expected-current **no-write** precondition. Exercise
  both consumers; no generic Boolean “overwrite” branch substitutes for intent.
- Check permissions, unrelated xattrs and mandatory note-owned encoding/tags/dates
  for later projection callers, with best-effort Finder metadata kept separate.
  A matching payload with failed mandatory metadata is not a completed projection.
- Exercise symlinks, directories/FIFOs, hard-link ambiguity, case-sensitive physical
  collisions, case-only operations, deep roots and ancestor/root movement.
- Preserve typed reconciliation-required outcomes after installed-byte or metadata
  failure. A delayed completion never clears a newer pending generation.

Existing-file replacement does not qualify absent-file installation or replacement
of a populated directory. Keep old backends until their migration gates pass.
Private database transactions stay on the local lane; the selected-store locator
is a separate physical metadata caller. Phase 6/7 still qualify their actual note,
legacy/export and application callers after primitive success.

State the supported external producer contract in each race test. Atomic safe
saves can be coherently observed; an arbitrary same-vnode intermediate write can
look stable without being complete. Neither `NSFileCoordinator`, a pre-check nor
identity-checked cleanup is fictional atomic compare-and-swap against unrelated
writers. If a primitive cannot meet the promised effect/preservation contract in
an admissible race, keep the counterexample and report the implementation or policy
gap. Do not remove the race merely to pass.

## 5. Failure and crash exploration

Instrument the actual effect sequence, keeping final-name publication distinct
from local SQL acceptance:

| Boundary | Controlled challenge | Independent observation |
| --- | --- | --- |
| Create/open stage or protocol directory | Collision, access failure, symlink/kind change, root invalidation | Foreign entries untouched; stage belongs to the captured owner |
| Write/prepare stage | Short/zero progress, EINTR where applicable, EIO, ENOSPC, failed metadata preparation | Incomplete bytes never gain final-object or durability authority |
| Verify and synchronize staged file | Altered bytes, sync failure, crash around the actual return | Exact intended bytes and completed file barrier distinguished from merely written bytes |
| Install name / replace captured item | Exclusive-create loser, displaced unexpected bytes, moved/replaced root | Surviving name/object/displaced inventory matches the typed result; no unrelated overwrite |
| Reopen/verify installed object | Changed name/identity, partial read, permission failure, late API error | Ambiguity retains recoverable inputs; no equality/URL-only success |
| Synchronize affected directories | Failed barrier; nested parent not yet durable | Required namespace durability established separately from file synchronization |
| Retain/park/accept incoming bytes | SQL/VFS failure, prerequisite arriving during parking, crash after commit before return | Old or complete committed membership/waits; exact bytes survive; no partial group |
| Materialize/publish/complete | New local edit/Delete, same-body context change, closed session, held callback | History remains durable; only matching context/generations are consumed |
| Diagnose/reject/repair/settle | Repeated write failure and a second crash during recovery | Durable verification/queue obligations and displaced/unique inputs survive; unrelated work can later resume |

At each reachable boundary first run single faults, then selected interference
and second-failure schedules. Include cancellation before admission, after an
effect is admitted, after the syscall/transaction succeeds and before its callback.
Record whether an effect did not occur, occurred but completion is lost, or is
ambiguous. Inject only failures a real primitive can produce; do not insert an
imaginary suspension in the middle of an atomic rename or SQL commit.

Use pipe-confirmed child-process cuts before/after effects, fresh exec/reopen and
independent inventory. A child killed before a scheduled fault is reached is an
invalid witness. Persistent faults are bounded in the harness and followed by a
healthy explicit retry/reopen companion. Recovery itself gets the same fault
seams, including failure while recording damage or rejection.

### Separate persistence fault classes

1. **Process termination:** the OS may retain unsynchronized data. Qualifies lost
   callbacks, transaction recovery and ownership release, not power-loss durability.
2. **Simulated persistence loss:** a small test-only namespace/barrier model tracks
   file bytes and directory entries separately, including nested directories.
   Unsynchronized effects may survive or disappear independently where allowed
   by the qualified primitive; successful barriers constrain allowed loss.
3. **Later corruption/removal:** damage after valid acceptance triggers detection
   and repair; it is not a failed original commit.
4. **Machine/volume restart:** actual restart/detach/remount observations record their
   storage/cache regime. VM reset is not automatically physical power loss.

The simulated model observes the real adapter's operations and supplies an explicit
environment contract. Version its permitted loss/reordering rules per primitive,
including atomic-rename restrictions; arbitrary surviving mixtures are not a
faithful crash model. Self-test it with an always-durable defect, omitted directory
barriers and partial final publication; the intended assertions must fail. It
qualifies ordering under that model, while OS probes separately justify its inputs.
Hardware power-loss qualification remains explicitly open until actually measured.

## 6. Scenario families

Each row inherits §3's valid companion, production reachability and independent
oracle requirements. The last column names a plausible defect, not a permitted
production option. Expand cases incrementally rather than taking a Cartesian
product of every dimension.

### Discovery, delivery and live state — first priorities

| Family / contract | Schedule and important variants | Assertions / defect control |
| --- | --- | --- |
| P5-DISC / TC-DISC-01 | Callback before listing visibility; no callback; coalesced hints; new nested writer directory; sequence holes; low sequence appearing after high; renamed valid duplicates. Then cease notifications while ordinary scoped discovery opportunities continue | Every subsequently readable disclosed valid object is eventually retained/processed once under those opportunities. Dirty generations survive an early empty pass. No maximum-sequence or quiet-callback completeness inference. Mutate early dirty clearing, omitted nested enumeration or high-water filtering |
| P5-DELIVER / TC-DUR-05, TC-ACT-04 | Child before parent, multiple prerequisites, descriptor after encrypted object, root before pages, shared page, concurrent branches, conflict-renamed duplicate and repackaged equivalent operations; crash while incomplete | Exact retained bytes and complete accepted membership; no editable partial action/bootstrap; parents wake existing waits; logical effects once. A page is not accepted root history by itself. Mutate dropped waits, early acceptance or duplicate action execution |
| P5-LIVE / TC-ASY-01, PUB-01 | Hold received reduction/completion, admit newer edit or Delete, then release; also unchanged visible body with changed represented revision/context, equal-value heads and a third branch arriving during preparation | Old action remains durable but cannot overwrite newer live values or clear their pending work. Preserve all alternatives and exact represented inputs; recompute after finite interference. Mutate missing note/context fence or captured-body restoration |

Conditional progress requires eventual readable inputs and scheduled useful
discovery/processing turns. It never assumes that an undisclosed remote branch
must become visible or that an indefinitely broken provider must recover. A held
required input has a companion that releases it without another notification;
prove progress when the environment permits it.

### Roots, coordination and lifecycle

| Family / contract | Schedule and important variants | Assertions / defect control |
| --- | --- | --- |
| P5-ROOT / TC-ROOT-01, AV-15–16 | Same directory moved/renamed; old path recreated with identical collection bytes; bookmark stale/unknown/unavailable; same root two local processes; separate private owner; detach/remount; close canceled during handoff | Continuous owned-resource exclusion, positive continuity only, no retarget or offline bypass of known live contention; independent private ownership remains required. Mutate path/collection-ID equality as permission or scan close releasing the owner |
| P5-COORD / AV-03/07/13 | Accessor receives a changed URL; error without usable access; provider callback reenters; unrelated child changes during directory coordination; presenter relinquishment and unregister | Use actual accessor context; filesystem access stays inside its valid coordinated interval; expensive detached validation consumes copied bytes afterwards. Directory coordination is not a frozen recursive catalog. Presenter replies once promptly. Mutate stale URL, work after accessor return or cross-lane synchronous wait |
| P5-LANE / TC-LIVE-01, WAIT-01 | Real accessor enters and remains held; admit/seal/commit local edit; cancel/time out provider request; quiesce/close; reopen or attempt switch; finally release accessor | Local barrier completes while provider is held. Timeout/cancel alone does not release/reuse its buffers/descriptors or promise it stopped. Late results stay fenced; close settles owned local work and reports remaining provider resources honestly. Mutate shared execution lane, premature resource release or stale completion use |

Test actor reentrancy across actual suspensions: reserve work before `await`, then
attempt another operation and change lifecycle/context before resumption. Actor
isolation protects mutable ownership but does not freeze an asynchronous operation.
Use a dedicated bounded blocking resource, not `Task.detached` as a claimed thread
pool. Test exact callback completion counts, C/Objective-C buffer lifetimes and
descriptor baselines through repeated cancellation/failure cycles.

### Restart, classification and rejected work

| Family / contract | Schedule and important variants | Assertions / defect control |
| --- | --- | --- |
| P5-REPLAY / TC-DUR-04–06, TC-START-03 | Restore older private/repository backups; restart both peers; redeliver old/renamed/duplicated objects; two sessions restored from the same allocator state; later concurrent edit and fresh-birth Restore | New editable sessions allocate fresh writer epochs/action origins; exact sealed retries keep their identities. After accepting applicable Delete history, older ancestors cannot resurrect that birth; concurrent preserved content and fresh restoration survive. Detect competing same-name bytes rather than overwriting. Mutate reused epoch/origin, arrival-order selection or duplicate effects |
| P5-START / TC-START-02–03, START-01 | Returning healthy closure: generic offline/full/access/coordination error versus already disclosed named unread newer/required evidence; disclosure before/after editing; evicted copy already local. Fresh store: incomplete bootstrap, complete snapshot preview, missing key, known accepted loss, optional roots before required ready Changes | Only the specified positive startup disclosure offers Work Offline, and only with complete usable local closure. Later discovery never revokes healthy editing. Fresh incomplete history stays noneditable; complete preview is separately read-only. Required work is not hidden by optional queue order. Mutate error→absence/Work Offline, late gate closure, partial bootstrap or optional-root blocking |
| P5-CREATE / START-01, AUTH-01 | Preexisting empty/unavailable selected directory, exclusively created new destination, interrupted import and two independent concurrent bootstraps in one provider folder | Creation in an existing directory requires explicit intent; an empty listing is not permission. A completed import matches its frozen count/digest/values; concurrent unrelated bootstraps remain distinct and require selection. Mutate silent initialization, partial-import completion or latest-bootstrap election |
| P5-REJECT / TC-DUR-04, receive rejection contracts | Malformed/unsupported/wrong-collection extras among valid work; multi-level/multi-parent dependents; crash or repeated failure while recording rejection; explicit retry/reopen | Retained exact input is either fully rejected or retryable; accepted history unchanged; valid unrelated work resumes. Dependents report blocked prerequisite, retain bytes/waits and are not themselves indiscriminately rejected. Mutate descendant rejection, dropped bytes or a poisoned ready-queue loop |

Test classifications through the actual consumers as well as a table-driven
decision function. Live provider probes establish available raw inputs, not every
desired condition: an accepted eviction request without observed eviction is
inconclusive. No positive newer-version API result means no speculative startup
gate. Forward provider identity is supplemental and must pass AV-09 before use;
inconclusive results preserve unknown continuity. Reverse lookup, portable Apple
version IDs, upload status and provider brand grant no authority.

Backup replay assertions are relative to available validated evidence. Before an
undisclosed Delete arrives, a restored older store can legitimately show its older
known state. Total rollback of every local loss-detection record cannot reveal the
erased branch by itself. Test later reconciliation and preservation of all available
copies rather than claiming detection of information absent from every source.

### Repair, preservation and confidentiality

| Family / contract | Schedule and important variants | Assertions / defect control |
| --- | --- | --- |
| P5-REPAIR / TC-REPAIR-01, REPAIR-01 | Same-root local `NV Data` omission; owned damaged entry; complementary private/provider halves; unread disclosed evidence; compatible/foreign race winner; preservation/install/barrier failure; second crash during repair | Repair automatically only with required positive evidence; preserve damaged/foreign sources; rebuild private first if needed; union exact compatible inputs; retain unpublished objects and private obligations. No full-closure claim or activation until verified durable completion. Mutate timestamp preference, overwritten winner or premature cutover |
| P5-COPY / TC-COPY-01–02 | Repository-only source without Application Support; placeholders, unknown files, dependency holes; source changes; independently verified destination; local failure with pending RAM edit | Preserve captured available inventory and report holes; full copy does not fabricate genesis or claim to save absent unpublished/RAM work. Current-state recovery export is separately disclosed. Source stays recoverable. Mutate missing-object success, source cleanup or private-state prerequisite |
| P5-CLEAN / CLEAN-01 | Abandoned owned stage, foreign stage-like names, displaced recovery artifact, cancellation, name replaced between observation and cleanup | Remove only provably owned disposable staging within the helper's qualified race contract. Accepted/sealed history and foreign/recovery evidence survive. Uncertain cleanup retains evidence and reports its state. Mutate cleanup by filename prefix or upload/derived-view success |
| P5-PRIV / TC-PRIV-01 | Synthetic body/title/passphrase/path/bookmark markers in encrypted sends, errors, malformed inputs, wrong credentials, repair/copy/staging and exported outputs; both private database profiles | No prohibited plaintext in actual production sinks or encrypted repository artifacts; nonsecret descriptor fields checked against their schema. Explicit plaintext export is confined to its chosen destination. Mutate plaintext fallback, error payload logging or an unprotected temporary output |

Enumerate the repair matrix compositionally: root continuity/ownership, entry kind,
access, exact identity/authentication, required closure, preservation feasibility
and destination writability. Pair observable-equivalent “user deletion”, “provider
failure” and “backup failure” causes: classifications must not depend on a presumed
cause. Exercise missing, partial, corrupt, unsupported, read-only, permission-denied,
symlinked and wrong-kind entries at root, protocol-directory, descriptor/object and
private hierarchy levels. Only compatible validated bytes enter the repair union.

Keep provider confidentiality separate from physical private-page encryption:
password-free collections use their adopted recoverable key derivation and remain
usable with Keychain unavailable. Their privacy test must not invent a user-secret
requirement. Marker absence in artifacts is not a whole-process zeroization proof.

## 7. Connected lifecycle schedules

These close gaps between otherwise separate tests. Execute the difficult
transitions in the same production run, with independent observations at each
stage and fresh-process final readers. Use exact small expected histories, then
bounded generated variants (§10).

### S1 — delayed dependencies, newer edits and two crashes

1. A durably saves bootstrap and edit E while transport is held; verify local bytes.
2. Publish exact objects. B discovers E before its parent/descriptor and parks it;
   crash B after retention/parking at the designated cut.
3. Reopen B, release prerequisites and hold its prepared view after complete
   acceptance. Admit newer local edit F or Delete under the normal headless host
   boundary; release E's result and check stale publication/clearing is rejected.
4. Persist F; kill after commit before callback. Fresh reopen reconstructs E and F
   with independent values, alternatives and membership. Exchange complete bytes
   in both directions and check causal results, not just agreement.

Valid companions finish both actions. An admitted but not durable F remains owned
pending work during the live test; only the committed variant promises crash recovery.

### S2 — discovery without a second callback

1. Send a hint for a new writer directory before the controlled listing exposes it.
2. Complete that empty discovery turn. Expose a high-sequence child first, a lower
   prerequisite later and a duplicate under a provider-renamed leaf; send no hints.
3. Drive only the adapter's ordinary discovery opportunities. Require retained
   dirty generation/continued scoped enumeration, eventual exact acceptance and
   one logical action. Repeat across restart and a failed read.

Keep a separate live-provider observation with a positively delivered peer item;
the deterministic missing-callback schedule is an adapter test, not a claim that
the provider omitted that exact notification in the live run.

### S3 — startup requirements and optional snapshot processing

1. A returning store has complete current rows, pending required Changes and queued
   independent snapshots. Hold optional preparation, including a root placed ahead
   of a required Change. Verify actual checked publication after required work.
2. Stop local-save interference; release the worker without another delivery and
   require exact snapshot acceptance with unchanged current values.
3. Pair with a fresh-store bootstrap needing snapshot pages/import closure and with
   an unfinished verification request: these cannot use the optional-work exemption.
4. Inject already disclosed unread required evidence before publication versus
   later disclosure, generic unavailability and an evicted already-local copy.
   Observe exact edit-admission/status choices and eventual reconciliation.

### S4 — complementary repair, competing occupants and failed recovery

1. Arrange a required closure split across private/provider copies, with a locally
   unpublished object and private settings/verification/pending-input records.
2. Validate the union, build a fresh private sibling and fail before/after pin commit
   and selected-store activation; fail again during reopening/diagnosis.
3. After healthy explicit retry, verify retained unique private work and activation,
   then repair the same-root provider repository. Race a compatible directory or
   foreign occupant against installation; stop and reclassify the captured attempt.
4. Independently inspect every source/displaced artifact and final known closure.
   Missing evidence in all sources yields explicit incomplete recovery, not success.

### S5 — old backups, deletion and a third branch

1. Two stores share creation/edit history; A durably deletes that birth while B is
   offline. Restore an older B backup and restart both with fresh allocators.
2. Redeliver old ancestors and equivalent repackaged operations. Add B's genuinely
   concurrent edit and a fresh-birth Restore; deliver Delete in both relative orders.
3. Add a third writer's later descendant or conflict-copy disposition; include copy
   deletion and another source descendant where that feature applies.
4. Check exact retained bodies, identities, source selection, unresolved attention,
   Recently Deleted exclusion and applicable Undo/Redo candidates after reopening.

Do not require deletion to erase concurrent recoverable content, infer logical
identity from equal paths/bodies, or sweep text files by deleted UUID/filename.
Actual projection-removal authority remains a Phase 6 caller test.

### S6 — stuck provider work, local durability and stale resources

1. Hold an actually entered coordinated accessor, then complete a local save and
   inspect its local barrier independently.
2. Cancel/time out, initiate quiesce and move or replace the root. Attempt another
   provider operation/explicit Re-open while the first still owns resources.
3. Release the accessor. Verify no effect/completion is retargeted to the replacement,
   no duplicate reply occurs, and ownership is released only at the safe boundary.
4. Fresh-process reopening preserves the saved action and durable unfinished work;
   repeat with rejection-record I/O failure and then healthy retry.

Explicitly distinguish same-object move, positive replacement and unknown
continuity. Retry examines the existing session; Re-open supplies a new explicit
association. Neither transfers old permissions to the selected successor.

## 8. OS, filesystem and API qualification

### Qualification layers

| Layer | Run and record | Claim boundary |
| --- | --- | --- |
| Portable host-free | Debug/optimized native Swift suites, fixtures, schema/type probes, mutation/process schedules; portable writable adapters separately | Core semantics and qualified local-store behavior; not Darwin/File Provider equivalence |
| Actual local filesystem | Production root adapter, independent readers/contenders, safe replacement/creation, permission and namespace failures | Measured operation capabilities on that filesystem/OS |
| Disk images | APFS/APFSX, HFS+/HFSX, ExFAT; genuine image ENOSPC, detach/remount, nested barriers and metadata variants | Per-operation results; image success is not live provider behavior |
| App-context provider | Signed LaunchServices harness using the production adapter, actual presenter/materialization/coordination inputs | API inputs and consumer behavior with recorded signing/entitlement/environment context |
| Two real Macs | Both send directions, fresh peer processes, exact peer-read inventories, concurrent writers, observed root/file delivery and evictions | Specific delivered scenarios, never all-provider/global convergence |
| Restart/power qualification | Process kill, machine restart and explicitly qualified physical persistence campaign recorded separately | Only the corresponding failure class; no stronger claim from a VM/process reset |

Run the supported oldest macOS executable path (declared deployment target 11.5),
an Intel macOS 14 host, and current supported arm64 macOS. Record exact OS builds,
architectures, compiler/SDK versions, language mode, dependency revisions and
distribution/runtime requirements. An available macOS 11 VM provides evidence for
its actual version; a compiler/deployment workaround or test-runner failure is
documented separately from a successfully executed library/bridge binary and
default release packaging. Compile-only availability is insufficient.

Use Linux arm64 for portable and qualified writable-store jobs, byte exchange and
ownership/lifetime checks. Preserve strong contracts: an unavailable OS primitive
produces an explicit qualification gap/outcome, not an unnoticed weaker adapter.
Other providers/network filesystems are observational until their relevant
operation contracts are qualified. Provider brand never changes runtime semantics.

### Live-test setup and capability records

- Use a newly owned synthetic subtree below the authorized API testing folder;
  operate only on verified test fixtures. Keep run markers/inventories and failed
  artifacts for diagnosis. Account resets, provider-private tools and filling a real
  account's quota are outside the test method. Genuine ENOSPC uses a test image.
  Respect each host's mutation/cleanup permissions; a synthetic pathname itself
  grants no additional authority to delete or reset anything.
- Require a signed/app-context witness where CLI/SSH behavior differs. Record user
  session, entitlements, provider domain observations and actual adapter revision.
- For each capability record requested stimulus, observed transition, raw typed
  errors, contract required by the caller and completed checks. Classify **passed**,
  **failed**, **unsupported**, or **inconclusive/not exercised** separately.
- Demonstrate actual eviction/dataless state and rematerialization, not request
  acceptance. For remote replacement/move, require receiving-host observation;
  sender success/upload status and elapsed time prove neither delivery nor identity.
- Validate documented API usage before interpreting an unexpected result as an
  Apple violation. Record the discrepancy and reproduce with a minimal correctly
  scoped probe, then through the production consumer. Keep AV findings current.

Check updated accessor URLs, error/access intervals, cancellation, presenter reply
and replacement backup behavior against the linked primary references in the
[API ledger](../../Apple-API-Contract-Validation.md#primary-apple-references) and
[migration plan](../../Foundation-Safe-Replacement-Migration.md#why-the-migration-is-plausible).
In particular, a coordinator cancellation return is not proof an entered accessor
finished, and coordinating a directory is not a recursive freeze of its children.
Use neither assumption in the fault controller or capability classifier.

## 9. Work bounds, latency and resource tests

The [bounded discovery batch follow-up](phase5/bounded-discovery-batches-plan.md)
supplies the concrete native/SQL batching matrix and integrated benchmark gates.
Use it alongside these whole-phase work/resource and scheduling requirements.

Measure healthy publication, background discovery, selected acceptance, snapshot
processing and fresh reconstruction separately. Hold current-note count/body size
fixed while growing unrelated ordinary history and provider filenames. Use 64,
256 and 1,024 actions for strict ordinary cases, then larger opt-in workloads.
Include sequential covering snapshots, wide independent tips and many writer
directories; history and frontier width are separate dimensions.

Record SQL work, historical envelope opens/decodes, bytes, catalog entries/turns,
worker time, pending buffers, open descriptors and peak memory. Healthy local
startup uses indexed current rows/required work; it does not replay every old
object or materialize every text file. Optional discovery/verification cannot gate
that publication. A directory listing may still be O(number of entries): report
its cost instead of describing the whole transport as constant-time. Previously
accepted envelopes should not be decoded on every ordinary discovery turn without
a required verification reason; if the implementation does so, report/benchmark
the cost rather than silently granting an unqualified shortcut.

Require bounded per-turn discovery/processing and bounded in-flight accessors,
queued decoded bodies and descriptors using the adopted limits and measured
resource policy. Work-budget exhaustion yields/resumes; it does not reject valid
long history, truncate a frontier or impose a collection lifetime limit. Repeat
same-history tests under different budgets and require identical eventual results.
An accessor that cannot be stopped does not permit unlimited replacement attempts.

Measure local-save delay while provider work is actually held and under a backlog,
then prove progress after finite interfering saves end. Keep strict work-count and
semantic assertions separate from timing observations. Freeze regression budgets
from representative measured baselines; record cold/warm runs and I/O regime.
No absolute latency claim substitutes for a barrier or permits incomplete startup,
disabled validation, a packed cache or asynchronous/debounced search.

Run strict Swift concurrency/exclusivity/memory diagnostics, optimized builds,
applicable ASan/TSan and C-boundary sanitizers over the new ownership/cleanup paths.
Stress repeated hold/cancel/retry/close cycles and compare descriptor/resource
baselines only after actually entered accessors settle. Sanitizer/tool limitations
remain explicit evidence gaps; suppressions require narrow justification.

## 10. Compiler boundaries, mutations and bounded schedules

### Language-backed separation

Keep the implementation small: reuse local/provider ownership coordinators,
immutable messages, existing acceptance receipts and generation fences. Use
issuer-restricted evidence for exact installation and contextual root permission,
distinct from untrusted URLs/locators and from private acceptance. Closed enums
describe lifecycle and outcomes. Selective unique ownership fits descriptors,
staging and in-flight tickets where it simplifies lifetime; immutable bytes and
historical facts remain shareable. These patterns add no persistent permission
registry or duplicate history store.

Compile-failure clients challenge ordinary module visibility and same-module
constructor restrictions. Include fabricated install/ownership evidence, parsed
bytes used as acceptance, swapped identifier/edge roles, raw paths as validated
locators, actor-isolated resources escaping and duplicate consumption where
noncopyable ownership is adopted. Require the intended failure at the marked
source line plus a valid companion. Dynamic consumers separately reject correct
types from the wrong root/store/session/profile/prefix or stale generation.

Audit production FFI and bridge entrypoints for unchecked access/Sendable escape
hatches, mutable buffer aliasing, improper C lifetime and safety-disabling flags.
Objective-C supplies frozen inputs/intent, not trusted receipts. Private receipt
construction and actor isolation improve the trusted boundary; independent
issuance/use tests still establish what those values actually certify.

### Targeted defects

Implement isolated mutation campaigns as each witness becomes available:

| Defect | Intended failing assertion / family |
| --- | --- |
| Acknowledge before file/namespace or SQL acceptance barrier | Exact durability predicate; installation sweep, P5-DELIVER |
| Treat an equal existing final as already durable without checks | Existing-byte/barrier companion; P5-DELIVER |
| Allow partial final publication or mutable overwrite of immutable identity | Concurrent reader and foreign-occupant preservation; §4.1 |
| Drop a dependency/wakeup or accept easy members of a group | Complete membership and eventual prerequisite wakeup; P5-DELIVER |
| Consume callback-before-visibility dirty work or skip sequence holes | Eventually observed IDs after notifications stop; P5-DISC |
| Use old URL/path/collection equality as authority | Independent replacement-root and wrong-context no-effect check; P5-ROOT/COORD |
| Release ownership at timeout/cancel or share the provider/local executor | Resource lifetime and local barrier while held; P5-LANE |
| Apply a stale prepared body or clear a newer pending generation | Exact live values/context and pending work; P5-LIVE |
| Drop verification/rejection obligations on write failure | Fresh-process repeated-failure preservation; P5-REJECT/REPAIR |
| Reject descendants wholesale or let one invalid object poison the queue | Valid neighbor/blocked-descendant outcomes and progress; P5-REJECT |
| Reuse restored allocators or replay a logical effect | Fresh epoch/origin, exact actions/births; P5-REPLAY |
| Infer absence/Work Offline from error, or edit partial bootstrap | Actual startup classifier/publication; P5-START |
| Overwrite a repair race winner or activate incomplete union | Displaced/foreign inventory and pin/activation check; P5-REPAIR |
| Clean retained/foreign artifacts or report incomplete copy as full | Source inventory and explicit completeness; P5-CLEAN/COPY |
| Leak plaintext through a stage/error or decrypt before authentication | Actual sink/profile and intended-layer checks; P5-PRIV |

Require a passing baseline, nonzero discovery of every selected case/parameter,
reachability at the intended boundary and the intended invariant failure. A
compilation error, unrelated failure, timeout or skipped feature does not kill a
mutation. Keep expected assertion failures distinct from harness discovery errors;
retain the robust Swift Testing output checks already adopted.

Generate bounded small histories/delivery schedules around the actual effect
seams: two writers, one/two notes, two/three complete actions, dependency/rejection
variants, one and then two crashes/failures. Exhaust applicable orders of these
explicit events, then add selected three-writer cases and reproducible seeded
larger schedules. Retain/minimize a failing seed and list exactly what was
enumerated; no arbitrary graph size or provider fairness proof is implied.

Metamorphic companions include duplicate delivery, relative delivery permutation,
equivalent operation repackaging, repeated restart, safe root movement, and different
work budgets. Compare with an independent small reference history and literal
expected difficult cases as well as fast/full production agreement.

### Existing model correspondence

Use [model guidance](../../tla/README.md) for scenarios and their limits:

- `ImmutableSegmentDurabilitySafety`, `SQLiteCollectionSafety` and
  `SQLiteFastStartSafety`: exact complete acceptance, retained closure, derived
  rows and checked publication. Physical helpers must establish their OS inputs.
- `SegmentBootstrapSafety`, `ReceiveSnapshotAssemblySafety`,
  `SnapshotReconstructionSafety` and `SnapshotRetentionCoverageSafety`: partial
  receipt versus complete bootstrap/recovery, independent logical cuts and tips.
- `ReceiveResumptionSafety`, `ReceiveRejectionSafety`,
  `OptionalReadyStartupSafety` and `LocalDurabilityLaneIndependence`: actual
  notification/reservation, finite interference, rejection and independent progress.
- `SegmentMergeSafety`, `SegmentDeletionSafety`, causal Undo and conflict-copy
  checks: independently expected values, births, contexts and dispositions in S1/S5.
- `RepositoryRepairSafety`: validated union, source preservation and pin-before-
  activation; concrete namespace/access/generation facts are test obligations.

These are complementary bounded checks, not a combined implementation proof.
Their abstract valid objects, atomic commits or physical observations cannot serve
as executable test oracles for the facts the adapter must establish. Rerun/change
relevant models when a modeled behavior changes; a documentation-only plan needs
no unrelated TLC rerun. Add a small focused scheduling model only if implementation
exposes an important unmodeled interaction. Preserve safety assertions and examine
counterexamples as potential specification flaws before dismissing them as models.

## 11. Reporting and completion gates

For each increment record source/dependency/toolchain revisions, exact commands,
discovered cases/parameters, seeds/cuts, positive companions, fault class, observed
primitive, mutation/assertion and retained artifact locations. Maintain a caller
coverage table and a qualification matrix; link the completed report from this
plan and the roadmap. A planned/unsupported/inconclusive case stays visibly open.

Phase 5 completion requires:

1. Real physical production paths satisfy the operation predicates for every
   claimed supported target, with explicit outcomes for unqualified capabilities.
2. Both profiles pass exact-byte two-store transport, causal outcomes, fresh-process
   recovery and the critical connected schedules, including second recovery failures.
3. Healthy local publication/saving progresses independently of discovery or a
   held provider accessor; finite-interference and missed-notification companions
   resume without accidental event dependencies.
4. Root continuity, actor/resource ownership, cancellation and stale-consumer checks
   survive ordinary/same-module compiler probes, dynamic challenges and mutations.
5. Repair/copy preserves known complete history and unique private work, accounts
   for incomplete output and foreign evidence, and never invents global completeness.
6. Debug/optimized, fixtures/schema, C/sanitizer, applicable native integration and
   available platform/live jobs pass; missing release qualification is stated.
7. Privacy and resource/scaling measurements cover actual adapter outputs and
   healthy versus exceptional startup separately. Legacy compatibility remains green.

If a supported target cannot satisfy a promised primitive, or a connected witness
reveals a genuine policy contradiction, stop that qualification and request a
decision before changing the contract. Preserve the failing example and complete
unaffected work. Platform unavailability never converts into a pass.

Phase 6 adds actual text-file/pending-decision callers; Phase 7 adds human-reviewed
AppKit/input/lifecycle behavior; Phase 8 closes distribution, security and physical
power-loss release gates. Their later placement does not defer Phase 5's real disk,
OS, fault, privacy or cross-machine tests until the end of development.
