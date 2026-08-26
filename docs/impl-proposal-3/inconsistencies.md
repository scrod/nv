# Documentation inconsistency review

Status: findings from nine full review passes of [README.md](README.md) against the normative sources — [Robust iCloud Drive Support](../iCloud-Drive-Support-Spec.md), [CONTEXT.md](../../CONTEXT.md), the [ADRs](../adr), [Apple API Contract Validation](../Apple-API-Contract-Validation.md), and [Foundation safe-replacement migration](../Foundation-Safe-Replacement-Migration.md). Passes 1-3 (2026-08-25/26) covered the pre-broadening design, the provider-neutral rework, and the retained-journal protocol. Pass 4 (2026-08-26) verified the current-visible fallback, root-closure unification, credential cutover, and resolution coverage. Pass 5 (2026-08-27) reviewed the root-loss/**Save Current Collection As…** design. Pass 6 (2026-08-27) reviewed implementation-proposal concreteness. Pass 7 (2026-08-29) verified the integrated requirement registry and closed the exact rebuild-predecessor, deleting-tail, vnode-handoff, and formatting-disclosure gaps. Pass 8 (2026-08-29) closed restart-time missing-journal directory durability and made authority-handoff activation explicitly provisional. Pass 9 (2026-08-29) checked omitted proposal details against the actual import, matching, retry, and undo paths. Where this report conflicts with the normative sources, they remain authoritative.

Severity classes: **cross-source inconsistency**, **ambiguity**, **proposal-internal**.

## Pass 5 verdict

Every previously open item is now resolved and verified: findings 3, 4, 5, 9, and 10 (structural generation, rebuild preconditions, export fence, lock lifetime, journal-creation lane) plus N3 (AGENTS.md now carries the conditional checks for the AV ledger and migration plan) and N4-2 (the migration plan's phase-2 list now uses the canonical boundary vocabulary and includes Save As). The root-loss design is unusually well swept — ADR-0010 was rewritten as its decision record, AV-08 was expanded with real vnode probes and honest open items, CONTEXT gained "Confirmed root loss" and "Save Current Collection As," and `StartupSafety` grew the two cited rebuild invariants. P5-1 through P5-4 have all been resolved normatively and in the proposal.

## Pass 5 findings

### P5-1. **Save Current Collection As…** does not specify Keychain/credential handling for encrypted collections — RESOLVED

spec:141 and README.md:472-474 say the destination bootstrap archives "staged target preferences whose storage format is `SingleDatabaseFormat`" with "notes, settings, and metadata equal to the frozen live store." Nothing states what happens to the credential identity. If the frozen store is encrypted with a remembered passphrase, copying the settings snapshot aliases the destination checkpoint to the **original** collection's `keychainDatabaseIdentifier`/Keychain item. Two problems follow:

1. Save As does not run the copy-on-write provisioning that every other path uses (spec:177-178: fresh never-reused identifier, add-only `SecItemAdd`, read-back plus KDF validation *before* installing a checkpoint that names the item). An encrypted destination can therefore be installed referencing an item NV never validated in that role.
2. A later passphrase cutover on any one collection deletes "the old item" after its verified target install (spec:178), silently stranding every *other* surviving checkpoint that aliases it — e.g., collection C (item K1) → root lost → Save As to D1 (references K1) → root of D1 lost → Save As to D2 (references K1) → passphrase change on D2 provisions K2 and deletes K1 → D1's installed checkpoint no longer has its matching Keychain item. That directly violates the spec's own promised invariant and verification row: "proof that every installed remembered-passphrase encrypted checkpoint still has its matching Keychain item" (spec:192/:198).

Resolution: each remembered-encrypted Save-As destination now provisions and validates a fresh, independent Keychain item before its bootstrap can name the identifier. It never copies, updates, or deletes the source credential; later cutover can therefore remove only that destination's former item. The spec, proposal, ADR-0011, AV-14, migration plan, and TLA+ coverage boundary all state the same ownership rule.

### P5-2. Editing and WAL durability during *inconclusive* root continuity are unspecified — RESOLVED

Resolution: provider-authority uncertainty alone remains nonblocking while rooted identity and the independently synchronized WAL are healthy. Vnode delete/revoke, deletion accommodation, or an append/outbox/barrier failure instead selects one transient edit-admission gate, urgently drains already admitted records through the existing durability lane, and resumes only after namespace recoverability, descriptor/header/claim validity, an empty outbox, and a successful barrier are revalidated. A permanently unlinked or revoked journal cannot resume that session. This reuses the existing pending set and WAL error path rather than creating another scheduler or durable state machine.

### P5-3. The inconclusive-loss UI matrix omits Quit — RESOLVED

The spec and proposal include quit after explicit discard confirmation in the inconclusive matrix and specify that canceling the Save panel before destination creation returns to the same blocking root-loss prompt without changing either session, journal, claim, or credential.

### P5-4. Positive deletion classification is effectively unreachable for unknown-authority roots — RESOLVED

spec:139 (and README.md:456) require, for provider-managed **or unknown** storage, "validated evidence that no identity-equivalent logical provider item remains" before a vnode delete selects `confirmedGone`. An unknown-authority root has no validated provider-identity facility to consult, so a genuine deletion leaves it inconclusive indefinitely (Retry stays visible even though the vnode is gone). This is a defensible fail-closed choice, but the spec should either acknowledge it or define the promotion path (e.g., authority discovery later resolving to confirmed ordinary-local upgrades the delete event to confirmed loss).

Resolution: an unknown root remains inconclusive initially, then reruns the saved vnode-delete classification when authority discovery positively establishes ordinary-local storage or a captured provider pair. Ordinary-local authority promotes directly; provider authority uses the exact AV-08 reverse-identity recipe. Unsupported or ambiguous discovery still retains Retry.

## Carried findings after integration

- **#11 — RESOLVED.** `START-01` now gives paused-checkpoint resume failure the exact startup choices and permits offline work only when the complete checkpoint and mandatory journals satisfy the ordinary offline rule.
- **#12 — REJECTED.** `-[NSOperationQueue addBarrierBlock:]` is available on the supported deployment range (macOS 10.15 and later). The proposal correctly uses it to drain presenter operations already submitted to that operation queue; the separate serial underlying queue orders the vnode/FSEvents work.
- **N4-1 — RESOLVED.** The normative `CheckpointIDsAreNeverReused` citation now includes `ReconciliationSafety.tla`.
- **N2 — RESOLVED AS PRODUCT POLICY.** Every positively classified provider-managed root uses the plaintext conversion contract. iCloud is the tested first-class provider; other File Providers remain capability-based best effort rather than receiving a different storage policy.

## Pass 5 resolutions, with verification

- **#3 (structural generation) — RESOLVED.** spec:55, CONTEXT's rewritten structural-generation entry, and README.md:98 now agree: a verified same-root move under unchanged authority changes neither structure nor generation; an authority change is fenced by the never-reused session incarnation instead; "the notes root is replaced" is gone from all definitions. The proposal's root-move section (:442-444) drops the increment-on-move and adds the authority-change handoff preserving the lock, journal, and obligations — matching ADR-0010's rewritten text and the AV-08 accessor findings (a root move can complete inside a batch-preparation accessor).
- **#4 (rebuild preconditions) — RESOLVED.** spec:46, ADR-0002, and README.md:328 now align on "no acceptable canonical database checkpoint can produce a startup store" over "any NV-readable separate-file root" with three explicit snapshot scopes (exact current-known; ordinary-local current catalog; stable-unsupported current-visible with persistent limited-history status); both new invariants exist in `StartupSafety.tla`, and the verification rows cover ordinary-local and unacceptable-but-decodable cases.
- **#5 (export fence) — RESOLVED** by aligning all three sources on catalog-only: spec:179 ("verifies that the provider catalog token is unchanged across the export fence. The export fence is catalog-only…"), ADR-0011 (unchanged, now matching), README.md:514 ("This is deliberately a catalog-only fence").
- **#9 (lock lifetime) — RESOLVED.** spec:117 now defines the root-session-lifetime lock with explicit acquisition/release ordering, matching README.md:56/:58.
- **#10 (journal-creation lane) — RESOLVED.** spec:132-133 assigns journal namespace operations (creation/header sync, discovery, demotion, cleanup) to the provider lane with the descriptor handoff to the durability lane, matching README.md:157 and the rewritten ADR-0010.
- **N3 — RESOLVED.** AGENTS.md now adds the conditional checks for `Apple-API-Contract-Validation.md` and `Foundation-Safe-Replacement-Migration.md` alongside the four normative sources.
- **N4-2 — RESOLVED.** The migration plan's phase 2 now enumerates the canonical semantic boundaries and explicitly covers both Save-As installations and the never-cross-root-coverage rule.

## Pass 6: implementation-proposal concreteness

The question this pass: where must a competent implementer still invent load-bearing behavior because the proposal under-specifies it? Cross-source consistency is no longer the binding constraint; concreteness is. Items are ordered by how binding the invented decision is. (Verified first: the P5-1/P5-2 incorporations are consistent across the spec, proposal :51/:98/:157/:444/:457-462, ADR-0011, the file map, and the formal-state mapping, and `NVBarrierSyncFileDescriptor` plus the WAL byte outbox are existing code — `NVRootedDirectory.m:50`, `WALController.m:461-470` — so the proposal references rather than invents them.)

### C-1. Persistence-format byte layouts are named but never defined — RESOLVED

Four on-disk/plist contracts are stability-critical (cross-launch, cross-version, and in two cases read by code that must agree forever), yet have no concrete format anywhere:

- **Checkpoint-base-identity encoding** (README.md:380): "construct, validate, encode, decode, and compare a tagged modern UUID or tagged 32-byte epoch-4 SHA-256 digest" — no tag values, byte order, UUID form, length framing, or total size. This value is written into every journal header and compared to gate recovery.
- **Modern journal header** (:150): "a magic value, header-format version, random journal ID, canonical checkpoint base identity, and CRC using the existing `NSData` CRC helper" — no field order/widths, CRC coverage (which fields, padding), magic value, or starting version number. This header is the trust root for valid-prefix replay.
- **The fixed hidden directory-lock file's name and contents** (:151, :310): reconciliation excludes it "by name" and two NV versions must agree on it, but its filename appears in no source, nor whether it has content.
- **Registry property-list shapes** (:336-339): the exact keys/types for `NVActiveJournal.<journalID>` (bare bookmark data or a dictionary) and `NVRetainedJournal.<journalID>` (schema-version integer value, key names), plus the canonical string form of `Interim Note-Changes.<journalID>` (UUID case/dashes).

Related: the epoch-5 **ancestry archive field** shape (:252-256) — archive key names and how (identifier, role) pairs are encoded — deserves a pinned layout alongside the compatibility vectors. A short format appendix with byte/field layouts and test vectors closes all of these; after code ships they become compatibility contracts.

Resolution: the normative spec now contains one epoch-5 persistence-format appendix fixing the checkpoint-ID and tagged-base bytes, modern journal magic/version/length/CRC layout and vectors, canonical UUID names, `.nv-root.lock`, direct active and retained property-list shapes, and the versioned ancestry archive object graph. The proposal binds slice 1 and its deterministic tests to those exact contracts; Foundation plist/keyed-archive container bytes remain deliberately noncanonical while their semantic key/type/value shapes are fixed.

### C-2. The provider root-loss identity classification has no concrete probe recipe — RESOLVED

README.md:456/:458 promote a vnode delete to `confirmedGone` (suppressing Retry and canceling all old-session publication) only after "operation-local File Provider/file-reference evidence establishes that no identity-equivalent logical item remains," and the accommodation path defers to "applicable identity classification or an independently validated equivalent." No document states the decision procedure — which API calls, in which order, with which results constitute proof versus eviction-versus-replacement. AV-08's requirement list marks the boundary but is a validation matrix, not an algorithm. This is the most safety-relevant classification in the new design; the proposal should specify the probe sequence or explicitly bind it to one AV-08-validated recipe so implementations cannot each invent their own.

Resolution: after vnode deletion, the proposal now uses the captured File Provider domain/item pair to enumerate the exact domain manager and reverse-resolve that item. A coordinated URL round trip to the same pair proves survival; only exact-domain `NSFileProviderErrorNoSuchItem` for the captured item proves provider deletion. Every unavailable, unsupported, missing-domain, mismatched, account/network, or other result remains inconclusive. AV-08 now owns the consumer-app validation matrix, and provider-managed `confirmedGone` remains disabled until it passes.

### C-3. The `NVCheckpointTransaction`'s "expected current checkpoint evidence" has no enforcement semantics — RESOLVED

:386/:396 pass "the expected current checkpoint snapshot/version" into the transaction, but nothing says what a mismatch means: a preflight compare-and-swap that fails installation (with which typed failure), or advisory diagnostics? The scenario is real — another Mac may have installed a newer checkpoint while this Mac edits — and install-over versus refuse is a correctness-relevant choice the implementer would otherwise make alone. One sentence on mismatch behavior closes it.

Resolution: expected-current evidence is now a mandatory no-write local CAS inside the coordinated accessor. Ordinary close/transition uses the accepted predecessor's retained exact bytes and available local-version ID; exceptional replacement names its explicitly classified predecessor, and creation expects absence. Any mismatch returns `NVCheckpointInstallCurrentChanged`, invokes no replacement, leaves checkpoint/journal/claim state intact, and follows the existing pre-install retry/cancel-or-override path. Undelivered server concurrency remains the exact-upload/fallback-retention boundary.

### C-4. The edit-admission gate and termination/transition quiescing are two unreconciled mechanisms — RESOLVED

:98 defines exactly one main-thread admission check, selected by the root session "only for local journal-durability uncertainty." Separately, `AppController` "prevents new user edits once termination or a controlled storage transition starts" (:77). Is termination quiescing routed through the same `NotationController` check (the obvious single-choke-point implementation), or a second mechanism? The file map's "one main-thread edit-admission gate" implies reuse, but termination is not a journal-durability uncertainty, so the stated selection rule excludes it. State the relationship (one gate with multiple selecting reasons, or two mechanisms).

Resolution: there is one authoritative `NotationController` mutation check with independent `lifecycleQuiescing` and `journalDurabilitySuspended` reason bits. `AppController` owns the former and `NVRootSession` the latter; either blocks edits, clearing one cannot clear the other, and their state machines/UI remain separate. The TLA+ README identifies lifecycle selection with modeled quiescing and durability selection as an unmodeled safety-strengthening refinement.

### C-5. Two wait-without-bound loops have no settling policy — RESOLVED

- **Root-closure reconciliation** (:415, step 3): "repeat final reconciliation until … fences are stable" — no iteration bound or fallback under constant remote churn; is perpetual waiting intended, with only the pre-checkpoint-failure override as an exit?
- **Startup materialization** (:319, step 6): no bound before the quit/choose-folder/work-offline choices appear. The no-timeout-proves-truth principle is right; the UX wait bound (or an explicit "wait indefinitely with progress and cancel") should still be stated so the behavior is deliberate.

Resolution: `WAIT-01` now defines wait and cancellation uniformly. No elapsed time establishes correctness or automatic failure; app-owned progress remains visible, a UI delay may reveal already authorized actions, and cancellation waits for operation ownership before taking the applicable root/checkpoint outcome. A final close may wait indefinitely only while the user elects to keep waiting.

### C-6. The authority-discovery ancestor walk is unpinned — RESOLVED

:315: "positive ubiquitous-item evidence on the item or nearest applicable existing ancestor" — how far up the tree NV walks, where it stops (first positive, first nonexistent parent, volume root), and what an exhausted walk yields are unspecified, and the answer affects correctness (a provider-managed ancestor several levels up). One paragraph pins the walk.

Resolution: the spec, proposal, and AV-09 now require a root-first, nearest-existing-ancestor walk that remains on the same volume, stops at the first positive provider result or the volume root, and returns `unknown` on any missing, inaccessible, changing, or erroring step. Exhausting that negative walk is not enough to classify ordinary-local storage; local-only shortcuts require the separately validated positive AV-09 recipe.

### C-7. Smaller concreteness items

- **Operation-queue barrier (carried #12, :60/:220) — REJECTED:** the supported SDK exposes `-[NSOperationQueue addBarrierBlock:]`; no substitute sentinel protocol is required.
- **Session observers across the authority-change handoff — RESOLVED:** the old presenter, FSEvents stream, and vnode source are drained and removed through a non-closing handoff path; the successor registers replacements on the transferred root and revalidates namespace/journal identity before handoff completion.
- **Barrier strength — REJECTED:** `NVBarrierSyncFileDescriptor` first attempts `F_BARRIERFSYNC` and falls back to `fsync` only when the barrier command is unsupported. Directory synchronization is a separate best-effort/checked-boundary contract, and the design makes no `F_FULLFSYNC` hardware-durability promise.
- **Bounded-backoff parameters** (initial delay, cap, jitter) are named everywhere and specified nowhere — acceptable at architecture level, but a default in the verification section would keep tests deterministic.
- **Undo-manager interplay:** publication-path mutations (conflict notes, reconciled content) and the edit gate's blocking behavior are never related to `NSUndoManager`; one sentence (publication mutations are non-undoable groupings, or undo is coalesced with them) prevents divergent implementations.

## Remaining implementation-detail priority

The correctness-affecting wait, authority, resume, checkpoint-citation, and provider-policy findings above are resolved. The remaining C-7 items are implementation details to pin while their owning slices are written; they do not require another synchronization protocol or persistent state.

## Pass 7 resolution note

The latest review's remaining correctness findings are incorporated. `StartupSafety` now captures an opaque exact rebuild-predecessor incarnation and permits a same-status replacement that must take the no-install rediscovery path. Ambiguous multi-journal cleanup includes `deleting` and its directory-durability/claim-removal tail. Authority-change handoff owns presenter and observer replacement explicitly. The conversion documents now describe formatting/attachment loss as a required extension to NV's existing cleartext confirmation path, not as existing UI behavior.

## Pass 9: omission review

The proposal now makes explicit that database and unclaimed-journal recovery imports enter the existing pending WAL/file sets; exact rebuild includes every disclosed current and historical/nonlocal version and applies the candidate URL's extension decoder; mandatory journals are defined without blocking startup on unresolved database versions or unclaimed provider journals; and the all-candidate version pass begins from coordinated reads as required by AV-05. The normative spec now permits an exact accepted checkpoint to seed a note's merge base only under the existing settled-file checkpoint boundary.

Startup pause repair, AV-04 serial fallback, transient `EBUSY`, and the conservative pre-macOS-26 resource-key observation path are pinned to the provider lane and existing sync/wait ownership. New recovery/rebuild actions are presentation-owned by `AppController`; the proposal now says to add, rather than retain, the CFPreferences helpers and monotonic termination phase. External publication reuses the existing non-undoable prepared-state behavior, while the one mutation gate also covers undo/redo. Provider-visibility retry reuses the existing deterministic `0.1/0.5/2/10/30`-second schedule instead of adding another policy.

The identity-precedence decision is resolved in favor of the normative identity-first behavior. Epoch 5 first associates unique stable filesystem identities across the complete candidate set, then applies unambiguous filename and content fallback only to candidates still unmatched. This intentionally changes the current filename-first implementation so a newly created file reusing an old name cannot capture the UUID of the renamed original. Same-name safe replacement still reaches filename fallback when no unique stable-identity association exists. The formal models begin after identity classification, so the concrete pass ordering remains covered by focused implementation tests rather than a new TLA+ transition.
