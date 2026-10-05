# Phase 4: snapshots, startup and source-preserving recovery

Date: 2026-10-05. Status: canonical general snapshots, durable local root/page
acceptance, received assembly, complete bootstrap and current-row reconstruction
are implemented; see the
[S1 report](phase4-snapshot-acceptance-validation.md) and
[S2 report](phase4-received-snapshot-validation.md) and
[S3/S4 report](phase4-bootstrap-reconstruction-validation.md).
The portable 4C–4E private-state, repair/activation and copy/export paths are also
implemented; see their [report](phase4-private-state-repair-copy-validation.md).
4F and closing qualification follow the
[remaining-work plan](phase4-current-row-locality-maintenance-plan.md).
Phase numbers refer to the
[Swift roadmap](swift-storage-implementation-plan.md#8-phase-4--startup-repair-repository-copy-and-private-state),
whose numbering differs from the broad [delivery sequence](../Implementation.md#ordered-delivery-plan).

Start with **general post-edit provider snapshots and recovery through their
later history**. Bundle large initial imports and exceptional current-row
reconstruction with this work: they share complete-history verification,
bounded page handling and the editable-startup boundary. Healthy returning
startup continues to load private current rows; adding snapshots introduces no
mandatory historical replay there.

Authority: [specification](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state),
[Protocol](../Protocol.md#snapshots-startup-rejoin-and-retention),
[LocalStore](../LocalStore.md), [ADR 0002](../../adr/0002-require-an-acceptable-startup-store.md),
[ADR 0005](../../adr/0005-separate-startup-cache-private-state-and-visible-history.md),
[ADR 0016](../../adr/0016-repair-from-validated-immutable-copies.md) and
[CONTEXT](../../../CONTEXT.md). Follow the
[language-enforced design](swift-storage-library-proposal-v2.md) and
[conformance strategy](swift-storage-conformance-testing-strategy.md).

The companion [data-loss tests and Swift contract boundaries](phase4-data-safety-contracts.md)
supplies the prioritized failure scenarios, issuer/consumer responsibilities,
compiler challenges and independent observations for these gates. Begin with
snapshot/tail preservation and semantic verification; qualify unique private
inputs, backup credentials and source-preserving activation before repair is
enabled. Its language experiments are preliminary, not production qualification.

After the [first executable snapshot increment](phase4-general-snapshot-validation.md),
follow the [durable acceptance and complete-history recovery plan](phase4-snapshot-acceptance-recovery-plan.md)
for the remaining 4A/4B work. It orders root/page retention, candidate arrival
wakeups, complete bootstrap, snapshot-plus-all-branches reconstruction and
fresh-process installation tests, with concrete issuer/consumer boundaries.

The implemented [received-snapshot plan (S2)](phase4-received-snapshot-plan.md)
distinguishes retained assembly bytes from accepted history, closes arrival/
parking races, and carries forward the index-completeness, connection/lifecycle,
hidden-state and resource concerns exposed by the earlier increments.
Complete store-backed bootstrap (S3), followed by snapshot plus all other
accepted history and guarded current-row installation (S4), are now implemented.
The [focused bootstrap/reconstruction plan](phase4-bootstrap-reconstruction-plan.md)
defines their staged implementation and data-loss qualification, including
complete-batch prefix accounting, earlier-received branches, hidden continuation
state, repeated recovery failures and compiler-restricted evidence consumers.

## Starting point (before this bundle) and boundaries

The [Phase 3 report](phase3-validation.md) and
[typed-boundary follow-up](typed-runtime-boundaries-validation.md) establish the
portable action/reduction foundation. Extend that production path rather than
build a parallel snapshot reducer.

| Existing implementation | Phase 4 extension |
| --- | --- |
| `InitialSnapshotV1` and `InitialBootstrapValidationV1` check initial-import pages against Genesis/Imports/ImportComplete | Versioned general snapshot pages/root and verification after edits, conflicts, Deletes, restorations and compensations |
| `InitialCollectionV1.build` seals bounded single-note groups but retains the complete object map in memory | Incremental candidate construction and bounded multi-batch/page processing for large imports |
| File-private `HistoryObject` / `ValidatedHistoryBatch` bind decoded records to exact bytes | Typed general-snapshot validation/acceptance with equally restricted evidence issuance |
| Receive/ready processing accepts changes objects; bootstrap admits initial snapshot kinds | Durable ordinary intake of snapshot pages/roots, including incomplete and rejected prerequisites |
| `recoverMaterialization` reconstructs the initial import, then catch-up applies later accepted batches | General verified snapshot/replay reconstruction and snapshot-plus-tail/branch recovery |
| Current cells, authoring context, indexed acceptance and guarded materialization already work | Preserve these paths, broaden invalid-materialization coverage and verify complete continuation state |
| Selected-store/recovery-key codecs exist | Qualify backup, salvage and the physical selected-store activation transaction |

The first bundle needs neither a live provider nor application UI. Use isolated
owned stores and exact object exchange. Actual provider discovery/publication
belongs to Phase 5, plaintext file reconciliation to Phase 6, and editor/native
undo integration to Phase 7. Carry forward outstanding Phase 3 platform
qualification; a new snapshot pass does not close those gates automatically.

Both profiles retain encrypted private SQLCipher pages and their existing key
derivations. New compression uses zstd. Keep epoch-4 opening/recovery/export in
the macOS application and retain its compatibility tests.

## Invariants for every increment

- Snapshot correctness, complete local history and final editable publication
  are separate checks. A received snapshot's protection does not establish its
  claimed reduction result.
- Recover **all locally accepted history**, including work outside the chosen
  snapshot, unacknowledged commits and concurrently disclosed branches. Local
  acceptance sequences order catch-up; operation parents define causal history.
- Retain exact objects/descriptors and a truthful pin. Snapshots never replace
  required history or grant pruning, filesystem authority or global freshness.
- Rebuilding derived rows preserves settings, retained pending inputs and
  accepted history. Known required-history loss enters repair even when current
  rows decode successfully.
- Current values, represented revisions, unresolved alternatives, deletion and
  retirement effects, restoration provenance, action context and subsequent
  Undo/Redo queries must agree with independent expected history.
- Actor-owned database transactions remain synchronous. Bulk reads/computation
  use bounded turns, yielding database access to saves and resuming after finite
  interference. Cancellation preserves owned durable inputs.
- Evidence consumers check collection/profile/key, store/session, represented
  history, reducer version and view/lifecycle generations as applicable. A
  copied value or equal numerical prefix supplies no substitute for those checks.
- Per-object limits and work budgets preserve complete inputs. Valid long-lived
  history is processed incrementally; no age/depth cap or truncated frontier is
  introduced.

## First bundle: 4A and 4B

### 4A — General snapshot format, construction and independent verification

The [first executable increment](phase4-general-snapshot-validation.md) implements
the [record contract](general-snapshot-record-contract.md), complete preview and
semantic checking against locally accepted history. Root/page retention and
verification of not-yet-accepted history still precede the complete Gate 4A/4B.

**Deliver first:** a written record contract, independent byte fixtures, Core
codecs and a resumable verifier for real post-edit history. Reuse the envelope
kinds, scalar/reference rules, exact value semantics and enabled Phase 3 records.

1. Inventory the continuation state needed at a stated operation frontier.
   Include full live values and their represented/head references, deleted-birth
   evidence, typed retirement, copy dispositions and automatic-preservation
   provenance, plus complete relevant action-scope/origin references. Explicitly
   identify which indexes are serialized and which are reconstructed from exact
   retained records. History/Undo queries may read their records on demand; the
   snapshot must preserve their results and ordinary editing context without
   duplicating every past body in a new archive.
2. Freeze general root/page versioning, tags, ordering, counts, digests, exact
   locators, required reducer/profile versions and complete-consumption rules.
   Distinguish these records from the existing initial-import layout. Specify
   bounded paging for each growing index and the complete page manifest; resolve
   oversized manifest representation before enabling that encoder. A budget
   cannot silently omit pages or become a collection-lifetime limit. Update
   [Format TODO](../Format-TODO.md#5-genesis-import-and-provider-snapshots) with
   exact field tables and fixtures, marking only completed work.
3. Capture one owned, dependency-closed accepted prefix and its logical frontier.
   Perform bulk construction outside the database transaction using immutable
   checked inputs. Local prefix/store generations bind the worker privately;
   portable records name exact history rather than a local sequence. A later
   save leaves a valid older snapshot, not permission to install older Current.
   Derive the portable state from neutral history reduction, separately from
   pending RAM edits and a local presentation pin. Snapshot creation authors no
   note/action changes. Start with an explicit headless build operation; qualify
   automatic scheduling from measured cost/benefit later.
4. Seal pages and then their root once, retain exact bytes through uncertain
   completion, and use normal acceptance/pin/wakeup transactions. The root's
   dependencies include its complete page set and required history. Snapshot
   acceptance adds retention coverage without repeating logical effects of
   already accepted operations. Reuse the collection's sealer, yielding optional
   construction between bounded objects so required saves retain priority.
   Failure or cancellation of optional construction cannot fail an already
   durable save. Provider publication remains a later adapter.
5. Independently verify received claims: authenticate/integrity-check bounded
   envelopes; validate the full manifest, pages and references; establish the
   bootstrap commitment and complete action/dependency closure; compute the
   claimed frontier's logical state; compare every value and continuation index.
   The initial correctness baseline uses history reconstruction on this
   exceptional path. A digest over the snapshot's own rows is a framing check,
   not the semantic oracle. Qualify any faster verification method separately
   against this reference before claiming acceleration.
6. Keep **operation ancestry represented by the snapshot** distinct from **object
   dependencies required to read it**. An object can contain another complete
   action outside the claimed operation frontier. Verify the represented cut,
   retain the extra evidence, and apply additional accepted history afterward;
   do not confuse transport membership with causal observation. A claimed cut
   cannot observe only part of an action group.
7. Separate complete profile-protected read-only preview from a history-verified
   recovery basis. Preview requires all pages/counts/digests and bounded complete
   displayed values. Public-profile integrity and encrypted-profile authentication
   retain their distinct guarantees. Missing history remains explicit; only
   complete durable closure permits editing. Use issuer-owned evidence types and explicit
   outcomes for missing pages/history, unsupported versions, invalid claims and
   canceled/deferred work. Implement the headless boundary here; wire its UI in
   the application phase.

**Gate 4A:** independently built public/encrypted fixtures cover empty, initial,
edited, deleted, concurrent, restored and compensated histories. Authentic but
wrong values or continuation indexes fail the semantic check. Missing exact
inputs name their locators and succeed after valid redelivery. Construction and
verification obey bounded work/cancellation, and evidence cannot be forged by
ordinary clients or same-module sibling files.

### 4B — Complete bootstrap, snapshot-plus-history recovery and startup fencing

1. Generalize Runtime intake/status/ready draining to typed pages and roots.
   Preserve bytes, dependency waits, rejection diagnostics and automatic
   resumption. Invalid optional incoming snapshots cannot poison unrelated
   accepted history. Missing/corrupt **accepted required** objects retain the
   different store-damage outcome. A root never becomes usable from a partial
   page set or a dependency flag without actual validated bytes.
   Retained candidate pages may supply assembly input before their enclosing
   snapshot is accepted. Distinguish that availability from accepted causal
   prerequisites; verification issues the complete root/page batch before
   acceptance. Do not create a root-waits-for-accepted-pages / pages-wait-for-root
   deadlock or give a candidate page editable-state authority. Reuse equal
   accepted pages normally. Page arrival and parent acceptance must durably wake
   the applicable root validation.
2. Build large initial imports incrementally in an owned candidate. Retain exact
   sealed batches/pages there rather than require an all-object RAM map. Use
   existing indexed records and bounded workers to verify the original
   count/digest, complete groups and ImportComplete coverage. Interrupted
   construction stays incomplete; no partial collection is activated. Qualify
   zero-note creation and multiple pages/groups per batch as well as large
   imports. Preserve the acyclic descriptor/genesis/completion/snapshot binding.
3. Add the exceptional rebuild path using a verified applicable snapshot or
   complete retained history. Start from its represented operation closure and
   union the accepted history outside it, including branches—not merely larger
   writer numbers or newer filenames. A general snapshot does not waive the
   original initial-import commitment. Preserve existing bootstrap/pin evidence
   instead of replacing it with whichever snapshot arrived last.
4. Install complete rebuilt rows/context under a fresh view epoch in the guarded
   derived transaction. Keep history acceptance independent. Recheck the
   captured owner/store/target immediately before installation/publication; a
   changed target requires catch-up or renewed preparation. Restart identifies
   actual committed membership, not a callback or remembered worker result.
5. Reuse the [returning-launch algorithm](../LocalStore.md#concrete-returning-launch-algorithm):
   validate required state/unfinished verification, drain ready Changes and their
   discovered required prerequisites independently of queue order, catch up the indexed
   suffix, capture all current rows/context consistently and fence publication.
   Independent optional snapshots stay durable until successful host publication
   reserves the existing receive worker; complete verification and automatic
   resumption after finite save interference remain required. See the
   [startup/query increment](phase-4-improvements/startup-and-scoped-queries.md).
   Valid current rows remain the normal path. Only invalid materialization,
   fresh bootstrap or repair may require historical reconstruction. A rejected
   acceleration candidate falls back to complete usable history where available;
   it never excuses loss named by a surviving pin.
6. Restore portable Note History, Recently Deleted and causal Undo/Redo from
   retained records. Recovered settings/receipts remain private. A rebuild
   restores no physical deletion permission, native undo objects or user consent.
   Keep the existing provider-withheld startup policy separate; no new generic
   Work Offline condition is introduced.

**Gate 4B:** two independent stores and fresh child processes recover the exact
expected state after real changes, page/history reordering, a lost callback and
repeated recovery failure. Healthy startup forbids historical BLOB/operation
reads when no required work exists. The first eligible ordinary save after
recovery retains the existing zero-ancestor-traversal guarantee.

### First-bundle scenario and observation matrix

The [expanded scenarios](phase4-data-safety-contracts.md#critical-production-path-scenarios)
define the setup, fault schedules, observable invariants and mutation targets.
T01–T05/T10 qualify this bundle; T06–T09 prepare required-private-state and physical
recovery, with their respective later gates.

Each row runs through production consumers under both profiles, with a valid
companion, independent expected values and a targeted mutation. Independently
inspect surviving exact envelopes, SQL membership/pins and current/context rows;
the fresh recovery process receives normal selection/unlock inputs, never the
parent's expected-state oracle.

| Scenario / contract | Required observation and challenge |
| --- | --- |
| Post-edit snapshot → later edit/Delete → crash/reopen; `TC-START-01`, `TC-DUR-01/06` | Preserve old history, apply the later edit/deletion and protect newer pending generations. Challenge skipped tail, early completion and deletion omission. |
| Snapshot on L, concurrent R, then a third writer/descendant | Union all accepted branches regardless of snapshot arrival order; preserve represented/unchosen heads and independent work. Challenge snapshot-as-latest replacement and arrival-ordered selection. |
| Authentic wrong body, represented head, scope maximum, retirement, disposition or restoration index; `TC-CRYPT-01`, `TC-START-01` | Reach the semantic verifier and reject the particular wrong claim. Round trips or agreement between two consumers alone do not qualify it. |
| One dependency object also contains an unrepresented complete group; snapshot cuts through a group | Valid complete cut recovers its stated state and later unions the extra group; partial-group cut fails. Challenge object-membership-as-causal-observation. |
| Root/pages/history in all small delivery orders; missing, duplicate, contradictory or unsupported prerequisite; `TC-START-01`, `TC-LIMIT-02` | Complete preview stays distinct from editability; exact waiting/blocking reasons survive restart; redelivery or finite save interference is followed by progress without another incoming event. |
| Reciprocal conflict copies → output edit/Delete → snapshot → new source descendant | Copy dispositions survive independently of output liveness; source Current still follows ordinary reduction and the new descendant is assessed separately. Challenge snapshot omission/recreation of handled copies. |
| Delete/edit preservation → independent copy edit → late covering Delete/retirement → snapshot | Retract only eligible untouched automatic state; preserve independent work and original deleted-birth absence. Challenge flattened provenance or retirement by filename. |
| Restore and overlapping Undo/Redo, including named multi-note groups | Same exact history entries, fresh births, Recently Deleted exclusions, inverse values and candidate/review outcomes as direct reduction. Challenge current-values-only snapshots. |
| Invalid current rows with healthy history versus missing pinned evidence | Rebuild only derived state and preserve supported private groups; known required loss blocks editable success. Challenge settings reset, partial row omission and accepting a snapshot in place of lost history. |
| Change owner/view/history during capture, materialization or final publication; `TC-EVD-01` | Actual consumer rejects stale evidence; an equal numerical prefix with a different epoch/store does not pass. Challenge omitted context/final checks. |
| Crash/write failure before/after acceptance and derived commit, then fail recovery again; `TC-DUR-04` | Exact committed bytes remain recoverable; no premature acknowledgment, lost required pin or partially editable state. Keep process termination, simulated persistence loss and later corruption separate. |
| Increasing old history, fixed current set; large import and wide continuation indexes; `TC-PERF-01`, `TC-LIMIT-02` | Healthy launch reads current rows plus required indexed work; exceptional replay yields and eventually completes. No truncation, quadratic retained ancestry matrix or new all-history launch scan. |

## Subsequent Phase 4 increments

Follow the [concrete 4C–4E implementation and test plan](phase4-private-state-repair-copy-plan.md)
for the increments below. It begins with private records/reference transactions
and shared health outcomes, then qualifies backup/salvage/repair/activation before
reusing those boundaries for copy/export. The portable 4C–4E paths now have their
production consumers and independent checks in the
[validation report](phase4-private-state-repair-copy-validation.md). The sections
below retain their obligations; 4F and platform/provider integration remain separate.

### 4C — Required private records and common damage classification

Freeze the remaining local association/settings and pending-group codecs and
independent fixtures needed to preserve private state during repair. Cover latest
versus frozen pending payloads, reservations, provisional claims, exact operation
links, settled observations and reference generations. Map supported nonempty
host settings explicitly; preserve unsupported versions as evidence. Keep root
bookmarks and platform effects behind their adapters.

Implement the shared immutable health result from
[Protocol](../Protocol.md#repository-and-private-store-repair-protocol): scope,
entry kind/access, known damage/required closure, validated candidates and
positive withheld-provider evidence. First qualify private-store and controlled
local-repository inputs. Phase 5 adds actual provider observations; raw error
codes alone establish neither absence nor corruption. Distinguish invalid
derived rows, required-private-state loss, accepted-history damage, unknown/wrong
credentials and unsupported formats. Validate complete private groups; a partial
group supplies preserved evidence, not replayable consent.

**Gate:** wrong-kind/symlink/inaccessible/corrupt/unsupported fixtures have precise
outcomes. Derived rebuilding preserves valid nonempty settings and private
buffers. Loss of unique pending contents is reported separately from history loss.
Private format completion prepares Phase 6; it does not yet implement external
file admission or physical association effects.

### 4D — Consistent backup, salvage and fresh-sibling activation

Implement [LocalStore's physical recovery mapping](../LocalStore.md#sqlite-backup-salvage-and-replacement-activation):
bounded keyed SQLite backup with a fixed captured read state/live-WAL contents
and exact unlock descriptors; preserved originals/journals; working-copy salvage
through normal recovered SQL reads; fresh connections after page/codec errors;
independent validation of immutable bytes and complete private record groups.
Treat recovered acceptance flags and low-level SQL recovery output as candidate
evidence. Valid orphan bytes alone do not establish that a local action committed;
preserve/quarantine ambiguous provenance rather than publish it as recovered
consent or history.

Build the complementary repair union in a fresh sibling with new local indexes,
preserving exact history identities and unique private work. Verify its required
pin, complete current state and normal unlocking route by fresh reopen before
durably switching the selected-store reference. Maintain one owner over both
candidates and selection; ambiguous activation reads back the reference and
preserves both candidates. Allocate fresh writer/action origins.

Qualify the existing selected-store codec's actual expected-generation
installation, file/directory barriers and readback against
[safe replacement](../../Foundation-Safe-Replacement-Migration.md#caller-scope-under-proposal-5)
and the relevant [Apple contract evidence](../../Apple-API-Contract-Validation.md).
Keep platform implementations explicit and retain equally strong portable
contracts; any proposed compatibility weakening requires user approval.

**Gate:** `TC-REPAIR-01`, `TC-DUR-06`, portable `TC-KEY-01`. Interrupt backup,
union copy, required-state commit, fresh reopen and selection cutover, including
ENOSPC/EIO and a second recovery failure. Verify old sources/foreign occupants
survive, private pending/settings groups remain complete, password-free copies
need no Keychain, and encrypted copies unlock with retained descriptors plus an
authorized secret. Missing required history prevents complete activation.
Device-bound credential provisioning and actual provider repair stay in their
later adapter gates.

### 4E — Repository copy and recovery export

Implement the portable capture/copy/verification boundary from the
[copy/export contract](../Implementation.md#repository-copy-versus-current-notes-export).
Repository-only copy preserves available exact history/descriptors and associated
files, including unknown files, without source Application Support. Report
unreadable captured entries, changed files and incomplete known dependencies;
available byte preservation need not await an editable complete closure.

Keep private backup, history-preserving repository copy and fresh-current-state
recovery export as distinct commands/results. An active-session recovery copy
must account for its admitted work through the existing local barrier/repair
union, or explicitly take the current-state export path. Verify destination
credentials and association before any cutover; source data remains preserved.
Actual placeholders/root coordination and application choices are qualified in
Phases 5/7 rather than inferred from the portable tests.

**Gate:** local `TC-COPY-01/02`, portable `TC-KEY-01`; repository-only input,
missing dependencies, concurrent source changes, locked ciphertext preservation,
pending RAM work and interrupted destination/cutover all have distinct honest
results. Copying never claims undisclosed remote history or silently becomes a
current-row-only export.

### 4F — Current-row compression, locality and optional maintenance

Follow the [ordered 4F and closing qualification plan](phase4-current-row-locality-maintenance-plan.md):
production baseline, physical codec/dictionaries, checked-capture reuse,
separate page-geometry/read-ahead qualification, safe idle VACUUM and connected
regression. It also records the original four performance investigations and
their explicit API, scheduling and retention-format decision gates.

Implementation update (2026-10-07): current framing/dictionaries, the checked
opening-capture handoff and explicit cancellable compaction are qualified within
the [4F report's scope](phase4-current-row-locality-maintenance-validation.md).
The handoff closes the redundant-row-decoding finding. The later
[startup/scoped-query increment](phase-4-improvements/startup-and-scoped-queries.md)
implements optional post-publication snapshot work and indexed note-scoped reads;
its [report](phase-4-improvements/startup-and-scoped-queries-validation.md) records
qualification. Snapshot-root retention growth and the remaining physical
qualification gates stay open. Automatic maintenance remains disabled.

Qualify the selected [zstd/locality candidate](clean-quit-locality-strategy.md)
after the correctness bundle. Freeze the physical cell/dictionary format and
fixtures; test raw fallback, mixed rows, dictionary loss/corruption and bounded
direct-to-final decoding. Measure page geometry separately before changing a
cipher profile. Any physical read-ahead hint remains dispensable advice with
qualified producer/invalidation/reader/crash cuts.

Then qualify opportunistic full VACUUM: healthy idle ownership, measured
fragmentation/cooldown, adequate space/work budget, required-write priority and
settled interruption. Measure benefit lifetime under realistic aging and the
delay from resumed input to durable save. Optional maintenance failure alone
cannot invalidate a durable save or become a startup/quit requirement.

**Gate:** equivalent full-current/search initialization, aged cold/warm layouts,
correct no-hint startup, exact history/private-state retention and failure cuts.
Keep the removed packed cache removed. Row compression and physical maintenance
do not delay 4A/4B or supply logical snapshot correctness.

## Test/model qualification and completion

- Extend the existing Swift Testing, independent fixture/inspection, child-process,
  VFS/fault, compiler-probe and targeted-mutation drivers. Run debug and optimized
  builds, require nonzero intended test discovery and designated mutation failures.
  Construct invalid evidence with valid authentication where testing semantics.
- Compare snapshot recovery with direct history reduction **and** independent
  expected values/references. Check conflicts, retirement, dispositions, history,
  restoration and Undo/Redo—not merely note count or two-store convergence.
- Use [SegmentBootstrapSafety](../../tla/SegmentBootstrapSafety.tla),
  [SQLiteFastStartSafety](../../tla/SQLiteFastStartSafety.tla),
  [SQLiteCollectionSafety](../../tla/SQLiteCollectionSafety.tla) and
  [RepositoryRepairSafety](../../tla/RepositoryRepairSafety.tla) as the existing
  scheduling/ordering basis. Their finite checks do not implement general
  snapshot codecs or semantic verification. Document concrete transaction and
  evidence correspondence. If new snapshot/rebuild transitions expose an
  uncovered cross-component race, extend a focused model with independent state
  assertions, witnesses and mutations; retain its safety conditions and run its
  actual runner configurations. Do not rerun unrelated models for codec-only work.
- Qualify both profiles on supported arm64/macOS, Intel/macOS and Linux/Swift
  targets using the same fixture outcomes and strict compiler checks. Audit new
  C/SQLite boundaries with relevant sanitizers. Record unavailable platforms and
  physical power-loss testing as unqualified, not inferred from process-kill tests.
- At each gate, update its record/implementation contract, Format TODO and a
  phase-specific validation report with commands, outcomes and limitations. Update
  spec/ADR/CONTEXT/model correspondence when semantics actually change. Run
  `build.sh` and affected legacy compatibility checks for significant code changes.

**Phase 4 completion:** general snapshots and large bootstraps recover faithful
editable state from complete available history; healthy returning launch stays
indexed; damaged stores are repaired/activated with sources and unique private
work preserved; copy/export/key outcomes remain distinct; selected physical
optimizations satisfy correctness and measured performance gates. No stage
claims global provider completeness. The portable 4A–4F paths and review remedies
have executed qualification reports with explicit limits. The later
[startup/scoped-query report](phase-4-improvements/startup-and-scoped-queries-validation.md)
records the optional-snapshot and scoped-read increment. Snapshot-root retention
growth, automatic maintenance and the other unexecuted physical gates retain
their separate obligations.
