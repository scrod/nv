# Phase 4A/4B follow-up: durable snapshots and complete-history recovery

Date: 2026-10-03. Status: S1–S4 implemented. The
[S1 report](phase4-snapshot-acceptance-validation.md) records durable local
root/page acceptance, exact retry and fresh-process qualification. The
[S2 report](phase4-received-snapshot-validation.md) adds received assembly,
atomic waits/wakeups, rejection isolation and its qualification limits. The
[S3/S4 report](phase4-bootstrap-reconstruction-validation.md) adds resumable
complete bootstrap and guarded snapshot-plus-history reconstruction. These make the first bundle of the
[Phase 4 plan](phase4-startup-recovery-plan.md) concrete, after the
[first executable snapshot increment](phase4-general-snapshot-validation.md).
It introduces no product-policy change.

## Scope and starting point

Implement in order: **durable root/page acceptance → incomplete-candidate intake
and bootstrap → snapshot plus all other accepted history → guarded installation
and fresh-process recovery**. Complete each increment's executable gate before
expanding it. Use the existing actor-owned SQLCipher store, collection sealer,
acceptance transaction, retained-history pin and current-row publication path.

Authority: [specification](../../iCloud-Drive-Support-Spec.md#startup-creation-and-private-current-state),
[Protocol](../Protocol.md#snapshots-startup-rejoin-and-retention),
[LocalStore](../LocalStore.md#logical-schema-and-transaction-boundaries),
[CONTEXT](../../../CONTEXT.md), ADRs
[0002](../../adr/0002-require-an-acceptable-startup-store.md),
[0005](../../adr/0005-separate-startup-cache-private-state-and-visible-history.md)
and [0016](../../adr/0016-repair-from-validated-immutable-copies.md).
Follow the [Swift design](swift-storage-library-proposal-v2.md),
[conformance strategy](swift-storage-conformance-testing-strategy.md) and
[Phase 4 data-safety contracts](phase4-data-safety-contracts.md), particularly
T01–T05/T10 and `TC-START-01`, `TC-DUR-01/04/06`, `TC-EVD-01`, `TC-LIMIT-02`.

The existing [general record contract](general-snapshot-record-contract.md)
already defines complete paged claims, structural preview and semantic checking
against locally accepted history. `VerifiedGeneralSnapshotClaims` records the
completed checks matching specific immutable claims to their represented cut.
Root/page durability and permission to replace a current view require additional
checks.

Concrete implementation sites:

| Existing boundary | Extension |
| --- | --- |
| Core `GeneralSnapshotV1` / `GeneralSnapshotPreviewV1` | Keep the frozen wire layout; connect bounded emission/assembly to retained exact objects. |
| Runtime `GeneralSnapshots.swift` | Owned construction, semantic verification, durable-basis reconstruction and exceptional rebuild preparation. |
| `HistoryDatabase.swift`: private `HistoryObject` / `ValidatedHistoryBatch` / `accept` | Versioned initial/general payload dispatch and issuer-confined complete snapshot acceptance. |
| `ReceivedObjects.swift` / `ReceiveRejection.swift` | Page/root candidates, exact waits, arrival wakeups and specific rejection classification. |
| `LocalStore.swift` / `OrdinaryDatabase.swift` / `GraphMaterialization.swift` | Exceptional snapshot-based rebuild; ordinary indexed catch-up stays intact. |
| `Publication.swift` / headless model | Existing owner/view/presentation/live-generation checks remain the final publication boundary. |

Both profiles keep encrypted private database pages, existing key derivations and
zstd envelopes. Provider discovery/publication, Apple APIs, application UI,
selected-store cutover, backup/salvage, remaining private-record codecs and
maintenance remain their separately planned increments. A portable reader of
controlled repository objects is sufficient here; it grants no filesystem
mutation authority or globally complete provider view.

## Non-negotiable recovery invariants

1. Accept complete validated objects and action groups with exact bytes, indexed
   occurrences/dependencies, descriptors, retained pin and wakeups committed
   together. A callback reports a commit; it never creates one.
2. Keep two distinct sets: the **operation ancestry represented by the snapshot**
   and the **objects retained to verify/read it**. An addressing object can also
   contain another complete action outside that ancestry.
3. Rebuild through a captured accepted target using the snapshot's represented
   operations **plus every accepted operation outside that set**, including
   earlier-received divergent branches. A local acceptance sequence orders SQL
   work, not causal inclusion. Snapshot acceptance time cannot define the tail.
4. A snapshot-only acceptance batch advances retention/coverage without authoring
   a note action, resetting current values or repeating known logical effects.
5. Rebuild derived rows/context only. Preserve history, original bootstrap/pin
   evidence and independently updated private groups. Known required-history
   damage blocks editable success even if an optional snapshot looks usable.
6. Install one complete current view under a fresh epoch. Revalidate actual
   owner/store/session, history target, view and host generation at the relevant
   consumers; immutable semantic facts remain separate from session permission.
7. Healthy returning startup stays on indexed current rows and required ready/
   catch-up work. General snapshot selection/verification and historical replay
   belong to exceptional rebuild or explicit optional construction.

## Increment 1 — Locally constructed, durably accepted root/page sets

Start with a complete, already accepted bootstrap/history. This isolates the SQL
acceptance mapping from receive-order and new-client bootstrap concerns.

1. Add a headless owned snapshot-construction operation. Capture neutral accepted
   history through the existing capture API, then emit through the collection's
   existing sealer. Reserve each allocation before suspension, seal once and
   durably retain exact emitted bytes as candidate objects. Yield optional work
   between bounded objects so ordinary saves retain access to the sealer/writer.
   A later save leaves a valid older snapshot, not a newer-state replacement.
2. Extend private payload dispatch for initial versus general root/page magic and
   version. Unsupported layouts/reducers have explicit outcomes. Derive object
   dependency edges from the verified tree and canonical references: root to
   manifest/tree and referenced history/bootstrap; index pages to children;
   Changes objects retain their own complete dependency edges. Use the existing
   payload layout, rather than adding an on-wire root field or inventing causal
   operations for pages.
3. Assemble and semantically check the exact retained candidate set. The private
   validation issuer creates a complete acceptance batch binding those bytes,
   collection/protection, bootstrap and checked history. Revalidate the issuer's
   acceptance-time context using the existing serialized acceptance boundary.
   Retry preparation when necessary while retaining the exact sealed bytes.
4. Commit root, newly accepted pages, complete dependencies, acceptance membership,
   descriptor coverage where applicable, pin advancement and dependent wakeups
   in the normal transaction. Reuse equal already accepted pages. Read the
   current pin inside this transaction; never replace it from a captured older
   construction result. Keep object and operation frontiers distinct.
5. Let normal catch-up advance through a snapshot-only batch with unchanged cells
   and authoring context. Issuance of a snapshot result conveys exact object
   coverage, not saved-note generations. On ambiguous completion, recover actual
   committed membership before retrying; exact duplicates allocate no new batch.

Cancellation preserves emitted owned bytes and admitted/ambiguous work. A stopped
build with pages but no complete root remains a candidate, not an accepted
snapshot. Accepted objects remain retained. Candidate cleanup is a separate,
proven-owned operation; this increment needs no new garbage-collection policy.
Closing drains required work and releases optional construction without removing
its retained candidates. Optional snapshot failure never adds a durable-quit gate.

**Gate S1:** both profiles build, accept, close and reopen a real general snapshot.
An independent inspector verifies exact root/pages, edges and expanded pin;
Current and logical action counts are unchanged. Concurrent ordinary saving,
duplicate acceptance and missing-callback recovery preserve every committed object.

## Increment 2 — Durable candidate intake, waits and progress

The [focused S2 implementation/test plan](phase4-received-snapshot-plan.md) expands
this increment into typed intake, arrival/acceptance wakeups, atomic parking,
rejection/lifecycle handling and resource/fresh-process gates. It incorporates
the concrete S1 ownership and delayed-completion findings and preserves S3/S4's
separate all-branch recovery obligations.

1. Generalize receive/status/ready processing to Changes, initial/general pages
   and roots. Retain exact input before reporting retained/waiting status. A
   bounded valid page can be assembly input while unaccepted. Its arrival alone
   cannot issue an accepted-history receipt or make a collection editable.
2. Reuse `objects`, `ready_objects` and exact-ID `object_waits`. Prefer waking
   dependent work transactionally on **both byte arrival and acceptance**; the
   validator determines from the actual child whether it needs retained assembly
   bytes or accepted history. An extra wake may repark a Changes object whose
   parent is merely retained. It never bypasses semantic validation.
3. Close the lost-wakeup race: after assembly discovers missing input, recheck
   those requirements in the same serialized transaction that installs waits
   and removes ready work. Input that arrived/was accepted during preparation
   must leave the child runnable. Root-before-page, page-before-root and arrival
   during parking require no future event to complete.
4. Traverse the complete manifest iteratively; durable waits can discover more
   exact dependencies on later passes. Roots consume candidate pages before
   accepting the complete verified root/page set, so no root/page circular
   acceptance requirement exists. A rejected root does not reject shared pages
   or descendants indiscriminately.
5. Extend typed outcomes/rejection reasons for missing pages, missing accepted
   history, unsupported payload/reducer, invalid manifest or semantic claims,
   scheduling deferral and I/O/ownership failure. Preserve unsupported candidates
   and blocker diagnostics. Classify damage to already accepted required bytes
   separately from rejection of an optional incoming root.
6. Reuse automatic validation resumption after finite local-save interference,
   durable ready work on reopen and existing shutdown ownership. A database
   failure while recording waits/rejection leaves exact retained retryable input
   or the complete committed transition. It must not loop on one bad optional
   root or prevent unrelated ready work from progressing after recovery.

The preferred wakeup design adds no durable per-page flag or second queue. If a
concrete requirement cannot be represented by these existing roles, document the
smallest necessary schema/codec revision and its crash ordering before writing it;
update both DDL copies, schema fixtures and open-version outcomes together.

**Gate S2:** bounded delivery permutations and fresh-process parking/crash cases
reach complete acceptance once the last exact prerequisite becomes usable.
Witness root/page acceptance and unrelated progress; “waiting,” “unsupported” or
timeout alone cannot pass a positive case.

## Increment 3 — History closure and large complete bootstrap

The [focused S3/S4 plan](phase4-bootstrap-reconstruction-plan.md) supplies the
implementation order, scalable-construction checks, risk-ranked failure matrix,
Swift issuer/consumer boundaries and reconstruction-model bridge for this and the
following increment. The [S3/S4 execution report](phase4-bootstrap-reconstruction-validation.md)
records their production paths and qualification separately from S1/S2's results.

1. Route unaccepted Changes prerequisites through the existing complete-group
   validators/acceptance path before a general root's semantic check uses them.
   Having a page that references an operation does not accept that operation.
   A complete structural preview can exist while this work remains pending.
2. Replace the bootstrap's all-object RAM map requirement with bounded candidate
   retention and a store-backed exact-locator reader. Share initial validation
   of Genesis, original count/digest, complete Imports/actions, ImportComplete,
   initial root/pages and the acyclic descriptor binding. Support zero notes,
   multiple groups per envelope and multiple batches. Initial roots currently
   use flat page lists; qualify their packed-page limits explicitly. General
   snapshots use multi-level manifests; any needed initial-format scaling change
   requires a concrete layout and independent fixtures before implementation.
3. Keep initial construction in a new exclusively owned candidate. Incomplete
   construction never produces ordinary editable startup. Commit the fully
   verified bootstrap unit and its required association/pin before activation;
   bounded retention must not turn it into partially editable independent
   collections. Existing incomplete/damaged stores retain explicit outcomes.
4. Validate later disclosed history normally, including a referenced envelope
   containing an extra complete group outside the snapshot cut. Retain its exact
   full membership; subsequent recovery includes that extra action. Preserve the
   original bootstrap commitment when a general root supplies newer values.

**Gate S3:** a fresh child, given normal selection/unlock inputs and controlled
repository/candidate bytes, reaches complete bootstrap only with the whole
commitment. Missing/contradictory imports remain explicit; valid redelivery
completes. Memory is bounded for retained envelope/page buffers without an
artificial lifetime cap on history, note count or frontier width.

## Increment 4 — Snapshot plus all accepted history, and guarded installation

1. Keep healthy valid/lagging current-row startup unchanged. Enter the exceptional
   path only for invalid derived state, fresh bootstrap or the later repair
   consumer. Required-state/header/key failures retain their separate outcomes.
2. Select an applicable retained snapshot using bounded metadata queries on that
   exceptional path. Any valid cut is usable. Candidate ranking may reduce work,
   but timestamps, filenames, writer sequence and arrival order confer no
   authority. An invalid unaccepted optional candidate can fall back to usable
   complete history; a damaged accepted required object triggers repair.
3. Reconstruct a durable basis from actual accepted root/pages and expanded pin
   coverage, checked protection/bootstrap, exact occurrences and semantic claims.
   Then capture accepted target H and the current rebuild/view state. Facts from
   a previous process or a preview alone cannot issue this basis.
4. Determine the operation cut from exact parents and complete action membership.
   Enumerate accepted membership through H using existing indexes and subtract
   that cut by logical operation identity. Process each remaining complete group
   exactly once in dependency-consistent order, including branches accepted
   before the root and extra groups sharing its addressing objects. Local
   sequences support enumeration only; duplicate transport occurrences add no
   logical application.
5. Introduce a recovery adapter taking checked snapshot state/continuation plus
   outside-cut groups. Carry unchanged snapshot cells forward; apply ordinary
   changes with the existing rules and recompute affected conflict/deletion/
   automatic-preservation scopes using exact retained ancestry as needed.
   Include linked deterministic outputs affected by source Deletes, retirements
   or independent edits. Reuse the existing reducers, rather than implementing
   a second merge, Delete or compensation policy. Direct row updates require
   their matched-basis conditions; divergent inputs use shared graph reduction.
   Validate writer before-states against declared history, never receiver arrival
   order or whichever Current happens to be displayed.
6. Refactor shared reducer inputs only where necessary for store-backed historical
   lookup. Keep full-history reduction as a separately exercised correctness
   reference and explicit conservative fallback. Complex scopes may still read
   extensive ancestry; measure it. A test that ignores snapshot inputs and only
   replays all history does not qualify the new snapshot-based path or prove an
   acceleration claim. Require witnesses that the actual checked snapshot state
   supplies the rebuild's starting cells/context.
7. Prepare complete rows, authoring context and continuation results away from
   the writer. Recheck actual owner/header, healthy required history, captured
   target and starting view/epoch in a synchronous derived transaction. Install
   the complete rows/context through H under a fresh view epoch. Leave private
   groups and accepted history untouched. New accepted work during preparation
   causes catch-up/repreparation rather than stale editable publication.
8. Drain remaining actionable ready work, catch up and consistently capture current
   rows through the stable startup target using the existing opener. Final
   publication uses the existing session/view/presentation/live-generation
   consumer. During a live rebuild, preserve pending host work and presentation
   pins via their existing overlay/fences; snapshot completion clears no pending
   note generation. Restore Note History, Recently Deleted and causal Undo/Redo
   through exact retained records, independently of native undo objects.

**Gate S4:** snapshot-based recovery and independent full reduction agree with
hand-expected values, heads, deleted/retired identities, dispositions, restoration
provenance, scope context and Undo/Redo results. Test equal visible bodies with
different continuation state. The first eligible ordinary save after reopening
retains checked-current-state validation with zero ancestor traversals; existing
eligibility conditions for derived/conflicting states remain unchanged.

## Swift-backed separation of responsibilities

The following are responsibilities, not a requirement to introduce every listed
name as a public type. Prefer small concrete types at genuine issuer/consumer
boundaries; keep final spellings aligned with the existing vocabulary.

| Value / authority | Issuer and consumer rule | Static and runtime challenge |
| --- | --- | --- |
| Decoded initial/general payload enum | Version dispatcher preserves exact envelope bytes alongside their typed payload. Exhaustive cases direct assembly/validation. | Unsupported versions cannot enter a successful supported case; probe incorrect kind combinations. |
| Complete preview / existing verified claims | Keep private issuers for structural assembly versus semantic checking. | Clients and same-module siblings cannot construct/redecode evidence or pass preview as semantic proof. |
| Private validated snapshot acceptance batch | Extend the existing `ValidatedHistoryBatch` issuer; `accept` consumes the same exact checked objects. | Forged batches/async transaction closures fail compilation; same-type wrong-context inputs fail the actual consumer. |
| Durable snapshot basis | Store-owned query/verification after commit or reopening; binds exact root, cut, store/session, protection/bootstrap and required coverage. | A semantic fact cannot substitute for durable coverage; old-session/wrong-store evidence fails consumption. |
| Prepared rebuild | Restricted reducer issuer binds basis, target H, starting view/epoch, rows and context. Installer owns fresh epoch allocation. | Arbitrary rows cannot masquerade as checked rebuild; stale same-prefix epochs and advanced history fail installation/publication. |
| Receive outcome | Closed variants separate retained assembly input, waiting/blocking, accepted coverage and explicit failure/deferral. | Exhaustive consumers keep preview availability distinct from editing; no boolean “valid/ready” shortcut. |

Keep C connection/statement lifetimes inside the existing database actor on its
blocking executor. Transactions use synchronous closures; bulk workers exchange
checked `Sendable` values and use bounded asynchronous reads. Every suspension
that separates preparation from an effect has a concrete applicability recheck.
Actor isolation checks memory access, while these consumers check logical races.
Use noncopyable ownership only for an actual uniquely owned resource when it
simplifies cleanup; immutable facts can remain copyable. Add no unchecked
concurrency conformance, public acceptance constructor, persisted permission or
long-lived validation cache.

## Executable test and observation matrix

Reuse Swift Testing, real envelopes/reducers/SQLCipher, existing fault and
completion gates, the probe child and independent history inspector. Every
negative has a valid companion. Use `#require` for prerequisites/path witnesses;
parameterize profiles and deliberate schedules, with isolated owned directories.
Expected values and inspection records belong to the observing test process,
never the recovering child. Deterministic gates replace timing-based sleeps.

| Case | Schedule / intended path | Independent required observation / challenge |
| --- | --- | --- |
| S-A: acceptance join | Accept root/pages while an ordinary save advances the old pin; duplicate/retry after held completion. | Exact bytes, complete edges/membership, union pin, transactional wakeups; no repeated action or cleared pending generation. Mutate stale pin or early result. |
| S-B: assembly versus acceptance | Root, two leaves/index and two history prerequisites in bounded delivery orders; input arrives during parking; shared page and duplicate deliveries. | Named waits survive restart; last prerequisite alone enables progress, root accepted only with full pages/history. Mutate arrival wakeup or candidate-as-accepted. |
| S-C: rejection isolation | Authentic bad root, unsupported prerequisite, valid shared page and unrelated ordinary input; fail rejection/wait writes twice. | Retained retryable bytes or complete rejection, precise blockers, accepted history intact and unrelated progress after storage recovers. Mutate broad descendant rejection or swallowed I/O. |
| S-D: complete bootstrap | Zero/two/many notes; several complete groups per object; remove/change each import/page and interrupt candidate construction. | Exact Genesis count/digest and complete ImportComplete closure precede editability. Mutate partial bootstrap or snapshot-instead-of-commitment. |
| S-E: represented cut | Envelope contains complete E and F; snapshot represents E only; alternatively split a multi-note group. | Valid recovery includes F once; partial-group cut rejected at semantic boundary. Mutate object-set-as-operation-cut. |
| S-F: all branches | Snapshot on L; R branch accepted before/after root; later E/Delete; selected third-writer descendant; root choices with different cuts. | All exact accepted membership survives; independently expected bodies/heads/context, no arrival-order winner. Mutate sequence-only tail or snapshot replacement. |
| S-G: connected semantics | Reciprocal copies, output edit/Delete, new source descendant; Delete/edit preservation plus late covering Delete; Restore and overlapping Undo/Redo. | Exact dispositions/retirements, preserved independent work, fresh births, Recently Deleted and candidate/review/inverse results. Use the Phase 3 connected fixtures, not only matching current bodies. |
| S-H: stale installation | Change owner/session, view epoch at equal prefix, history target, presentation pin or live pending generation between prepare/install/publish. | Actual installer/publisher rejects stale permission; newer pending state survives. Mutate one context fence at a time. |
| S-I: derived versus required damage | Damage current rows/context with intact history; separately remove/corrupt required accepted history; fail damage recording and recovery again. | Derived rebuild preserves private groups; known loss blocks editable success and live admission stays revoked despite marker-write failure. Mutate reset/row omission/usable-snapshot fallback past pin. |
| S-J: restart cuts | Terminate before/after acceptance, after commit before callback, during rebuild/install and before publication; second failure during reopening. | Membership determines survival independent of callbacks; complete rebuilt view or retryable rebuild, never partial editable state. Mutate lost-ack omission or skipped catch-up. |
| S-K: locality and work | Growing old history with fixed current notes; wide indexes, multi-level pages; finite saves interrupt exceptional work then stop. | Healthy open performs no historical BLOB/operation replay; exceptional work yields and resumes without another arrival. First eligible ordinary save has zero ancestor traversals. Lower budgets change work turns, not results. |

### Fresh-process fault cuts

Place hooks around real effect boundaries, preserving synchronous transaction
atomicity. Sweep process termination before commit, after commit before callback,
and around these separate transactions: candidate retention/arrival wakeup;
parking/rejection; complete acceptance/pin; derived installation. Preparation and
final publication get separate stale-context/termination cuts. Include committed
SQL WAL work without requiring maintenance checkpoint success.

Use the existing fault layer for EIO, ENOSPC, busy and ambiguous commit outcomes
at candidate, acceptance and installation writes. Test cancellation/quiesce both
before admission and after owned bytes exist. Verify exact retry and retained
pending generations, rather than treating every thrown error as known rollback.

For each cut, inspect surviving exact envelopes, accepted occurrences, dependency
edges, pin, ready/wait/rejection entries, private groups and rows/context. Reopen
with only normal selection/unlock inputs and available retained objects; then
independently compare the child's result. Run a second failure during recovery
followed by a healthy reopen. Separate **process termination**, **simulated
persistence loss** and **later corruption** in artifacts and conclusions;
physical power-loss durability remains its own platform qualification.

Start with scripted schedules and one-cut sweeps. Enumerate small fixed delivery
and completion orders, then selected three-writer interactions; record bounds,
full schedules and seeds. Avoid a universal cross-product of all formats,
histories, faults and platforms. Reduce discovered failures without removing the
contested transition or turning a semantic failure into an earlier parser failure.

## Qualification, model correspondence and completion

- Extend existing fixture/type/mutation/process drivers and required discovery;
  add a focused snapshot process driver only if it makes the existing probe
  easier to use. Reuse existing format fixtures unless a layout actually changes.
  Inspect dependency/pin/current results independently of Runtime success flags.
- Run debug and optimized host-free suites, independent fixtures, affected schema
  checks, ordinary-client and same-module construction probes. Strict Swift 6.4
  isolation/memory-safety diagnostics stay enabled. Same-type wrong-context cases
  test real consumers, complementing compilation failures.
- Run isolated production mutations for the S-A–S-K safeguards, including an
  always-wait/always-unsupported control. Require passing baselines, named test
  discovery, a reached intended path and the designated assertion. Setup failure,
  unrelated diagnostics and generic timeout receive no correctness credit.
- Map acceptance/install/publication to `SQLiteCollectionSafety`,
  `SQLiteFastStartSafety`, `SegmentBootstrapSafety` and the existing receive
  resumption/rejection models via [the TLA README](../../tla/README.md).
  Existing complete-input/atomic-SQL assumptions do not prove page intake,
  semantic verification or the Swift installer. If those assumptions hide the
  arrival-versus-acceptance or outside-cut branch race, add a focused bounded
  bridge before closing the gate: two pages, an earlier divergent branch, a
  snapshot cut, acceptance/install and crash/reopen. Keep safety assertions,
  targeted mutations and reachability witnesses independent; progress assumes
  eventual usable prerequisites and finite interference, not user approval or
  globally complete disclosure. Read effective configurations/runner and record
  completed checks; documentation alone requires no rerun or proof claim.
- Qualify affected Runtime/process/type checks on arm64 macOS and Linux Swift
  6.4, then Intel/macOS 11 back-deployment where available. Report unavailable
  environments explicitly; retain API/compiler contracts. Run relevant sanitizer
  campaigns over changed actor/C/streaming paths. No new Apple API dependency
  means no live-iCloud experiment is required to close this portable bundle.
- Record per-increment source hashes, commands, discovered tests, fault hits,
  actual snapshot/tail-path witnesses, mutation verdicts, work counts and limits
  in an updated execution report. Measure exceptional rebuild separately from
  healthy launch; claim speed improvement only from equivalent verified workloads.

This bundle completes when S1–S4 and S-A–S-K pass through production consumers
under both profiles, including fresh-process repeated-failure cases. Required
private codecs, consistent backup/salvage/activation, repository copy/export,
locality/maintenance and remaining platform/power-loss gates still follow under
4C–4F; snapshot success does not check them off.
