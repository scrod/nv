# Swift storage library: phased implementation and testing

Date: 2026-09-10. Status: implementation roadmap; the phases and tests below are not completion claims.

Build the portable storage library with **ordinary Swift definitions as the executable source of canonical values and encodings**. No CUE, ConcreteIR, schema compiler, generated Swift, or replacement schema language is required. Start with a complete local save/reopen slice, then extend that same production path to distributed history and application integration.

This plan sequences the [library architecture](swift-storage-library-proposal-v2.md) and [conformance strategy](swift-storage-conformance-testing-strategy.md). Their text has been aligned with the current policies below; use the detailed type-boundary discussion and `TC-*` contract cards without duplicating them here. The [specification](../../iCloud-Drive-Support-Spec.md), [Protocol](../Protocol.md), [Encryption](../Encryption.md), [ADRs](../../adr), and [CONTEXT](../../../CONTEXT.md) remain the product/algorithm authorities. [Format TODO](../Format-TODO.md) identifies unfinished byte definitions, not permission to assign provisional production values.

The [first save/reopen contract](first-save-reopen-contract.md) supplies initial record layouts, creation/bootstrap ordering and runtime method/ownership contracts. Its status table and [Phase 2 evidence](phase2-local-runtime-validation.md) distinguish the working ordinary local save/reopen path from unfinished general action/Current semantics and final application activation. Codecs or a checked initial import alone still issue no durability authority.

[LocalStore](../LocalStore.md) fixes the private SQLite mapping and returning-launch
algorithm. Required history/index/pin acceptance is one transaction; current
materialization has a separate failure boundary.
The existing provider snapshot format is unchanged. Credential lifecycle and
production SQLCipher/repair qualification remain distinct gates.

## 1. Alignment with the current specification

| Area | Current direction |
| --- | --- |
| Canonical definitions | Direct Swift constants/enums/value types and explicit codecs, independently reviewed byte fixtures, exhaustive test mappings and API checks. Do not recreate CUE as a Swift DSL or macro system. |
| Early persistence milestone | Implement the smallest complete action/bootstrap subset and real installer together. Test acknowledgment/recovery before expanding to every operation. |
| Existing source and evidence | Reuse `tests/Makefile`, app sources, the reference script, active TLA+ runners and API-contract documents. `NVStorage` contains Core and the first SQLCipher Runtime path, with issuer/consumer/compiler/process checks. Use the Phase 2 report's exact supported subset and qualification limits. |
| NV conflict copies | Saving separately represents only the selected revision, **not** an implicit Keep Current. Source-head reduction and unresolved attention are distinct. Test the adopted [copy policy](../Verification.md#nv-conflict-copy-disposition--adopted-policy); its byte representation remains unfinished. |
| External imports and pending decisions | Ordinary eligible files auto-import after mandatory exceptions and narrow per-note repair checks. Late independent duplicates remain possible; no co-add. The [pending commit/recovery rules](../Protocol.md#pending-file-commit-and-recovery-records) are specified, while their concrete codecs remain implementation work. |
| Content scope | New work is plaintext-first; attachments are unsupported and RTF/HTML design is deferred. Preserve legacy recovery and explicitly handle unsupported migration inputs; never flatten silently. |
| Input and undo | Follow [AppKit's input boundary](../../Apple-API-Contract-Validation.md#text-input-and-undo-platform-boundary). No custom composition state machine or durable draft protocol is prescribed. Test registered external undo edits before considering the unaccepted coarse fallback. |
| Test organization | Use native package tests through the existing Makefile on macOS and directly in portable jobs; keep legacy executables. No third-party/duplicate framework. Qualify the runner separately from the shipped library's deployment target. |

This changes implementation organization, not synchronization semantics. It introduces no second WAL, shared mutable head, receipt/membership service, new provider metadata directory, garbage collection, device revocation, automatic UUID unification, or cloud-completeness claim.

## 2. Implementation boundary and Swift-native format definitions

Use `NVStorage/` as the package location. Create targets only as their first functionality lands:

| Target | Responsibility | Excluded |
| --- | --- | --- |
| `NVStorageCore` | Exact values/identities, bounded bytes, crypto composition, graph validation, deterministic history/merge/undo rules | AppKit, provider callbacks, filesystem authority, implicit time/random inputs to reducers |
| `NVStorageRuntime` | Local ownership, installation, acceptance/pin commit, recovery and repository coordination; narrow OS execution adapters | Live `NoteObject` mutation, synchronous provider waits on the local lane |
| `NVStorageApple` | Rooted-helper integration, coordination/presenters, Keychain/bookmarks, Objective-C/main-thread bridge | Alternate codecs/reducers or authority issued by Objective-C |
| Test support | Synthetic fixtures, low-level faults, effect observation, small disk model, child-process driver | Production dependency or public unchecked receipt constructors |

Core is platform-independent. Runtime supports writable storage only through qualified platform adapters. Initially qualify Darwin for application use and run the core corpus on Darwin/Linux; add non-Darwin writable adapters when their contracts can be demonstrated. A Linux build is not evidence that an ordinary URL-write implementation satisfies NV's rooted replacement/durability contract. Do not promise Windows filesystem or credential support from portability of the values.

### Canonical definitions

1. Put fixed tags, widths, domain-separation bytes, version values and protocol limits in small, versioned Swift declarations beside the codecs that own them. Define nominal IDs and graph roles, not aliases to one generic UUID/digest array.
2. Encode fixed-width integers and fields explicitly. Never persist native structure layout, Swift `Hasher`, dictionary iteration order, reflected properties or a synthesized general-purpose archive as canonical protocol bytes.
3. Keep semantic operation encoding separate from transport-reference encoding. Where useful, one explicit canonical traversal feeds byte/hash/size sinks. Reference expansion, action membership and exact fields still require independent tests; a shared traversal can consistently omit the same field.
4. Keep intrinsic validation separate from graph context, and immutable evidence separate from revocable permission. A bounded missing-reference token is constructible; an identified/accepted object requires its real issuer. Correctly typed evidence for the wrong object/store/incarnation must fail dynamically.
5. Use a closed `ProtocolLimit` declaration and a separately maintained exhaustive, no-`default` test-strategy switch. Keep `WorkBudget` separate: yielding is not rejection, truncation, or an ancestry-age limit.
6. Written field tables and literal expected bytes remain review inputs independent of production declarations. Tests may deliberately repeat expected values; that is an oracle, not a competing production schema. Do not regenerate expected hashes/preimages from the Swift encoder under test.

No general code generator or reference codec is an initial deliverable. Reuse the existing Python merge/recovery vectors. A later tool that renders documentation from Swift would be optional presentation tooling, not a new format authority or an independent correctness check.

### Freeze only what the next phase actually writes

For each enabled record, complete its Format TODO row: field/order/width/presence, comparator/normalization, identity participation, limits/outcomes and annotated valid/invalid vectors. Identify whether the choice follows existing source/spec or needs product review. A genuinely unresolved choice blocks that encoder/feature, not unrelated finished primitives. Never fill a TODO with a convenient default.

The first slice needs real note values, Create/Put/Delete and complete action groups, genesis/import completion, descriptors, a complete initial-import snapshot and enough Local State to store association/pin/settings. General post-edit provider snapshots, native remaining-effect encoding and pending-file receipts can follow. Initial snapshot verification may replay the complete imported history; it must not skip the creation-completion requirement or claim fast general snapshot validation. Unsupported variants remain unavailable; this development subset is not permission to ship a partially conforming writer.

## 3. Phase overview

Phase numbers below are local to this roadmap. The last column maps to the existing broad [delivery plan](../Implementation.md#ordered-delivery-plan) and conformance strategy gates.

| Phase | Reviewable result | Depends on | Existing mapping |
| --- | --- | --- | --- |
| 0. Boundaries and compatibility | Real build/test entrypoints, ownership map, first-slice format decisions | — | Broad 0–1; G0 |
| 1. Swift values and bytes | Direct canonical definitions and complete minimal public/encrypted records | 0 | Broad 1; G1/WP2 |
| 2. Local durability and reopen | Real save → pin → completion → fresh recovery, with failures | 1 | Broad 2; G1/WP3 |
| 3. Portable history across stores | Actual encoded actions, conflicts, deletion, merge and compensation across two stores | 2 | Broad 3 and backend of 6; G2/WP4 |
| 4. Startup, repair and copy | Retained-history recovery, validated snapshots and source-preserving transitions | 2; history portions of 3 | Broad 2–4; G2 and copy portions of G3 |
| 5. Provider/root integration | Exact immutable transport and independent local progress using actual adapters | 3–4 | Broad 4; G3/WP5 |
| 6. Plaintext and pending decisions | Existing-file reconciliation, crash-safe import/association, exact projection effects | 3–5 | Broad 5; G3/WP5 |
| 7. Application and lifecycle | Faithful capture, history/undo/resolver UI, close and legacy migration | Relevant 2–6 | Broad 6a–6d; G3/WP5 |
| 8. Qualification | Revision-bound release evidence for every enabled capability | 0–7 | Broad 7; G4/WP6 |

Tests arrive with each implementation, not in phase 8. A minimal headless command adapter starts in phase 2; actual UI adoption waits for phase 7 and human review. Native undo compatibility experiments can start in phase 0, before the core API is frozen. Phase 4's local work need not wait for all undo features in phase 3; no live provider is needed for phases 1–4.

## 4. Phase 0 — Establish the real boundary

**Implement/design**

- Inventory the actual mutation and replacement callers using [Implementation's source map](../Implementation.md#concrete-source-changes): `NotationController`, `NoteObject`, `NotationDirectoryManager`, `DeletionManager`, `ExternalEditingSession`, `AppController`, `FrozenNotation` and `NVRootedDirectory`. Record which existing contract is reused and which segment-mode branch changes it. Do not rewrite search, selection or the responder chain as preparation.
- Establish a small package/client test, pinned Swift toolchain and dependency revisions, Swift 6 language mode and available strict memory-safety diagnostics. Reject safety-disabling release options; document each necessary unsafe/FFI exception locally. Keep compiler, SDK, language mode and deployment target distinct.
  The adopted package baseline is Swift 6.4 or newer: Core and Runtime enable
  strict memory-safety checking with warnings as errors, alongside Swift 6
  concurrency checking. See the [compiler/platform qualification](swift64-platform-qualification.md).
- Use an owned-byte bounded cursor as the low-dependency baseline. An upstream parser is optional only if a short real compatibility probe shows a smaller maintained surface; no parser fork project.
- Qualify the proposed Swift Crypto, existing/pinned Argon2 and zstd dependencies for the required build/runtime combination. Reuse stdlib/Foundation where their semantics suffice; optional Swift System/Collections/normalization dependencies need a concrete reason. Resolve reproducible passphrase normalization with fixtures and a documented Unicode policy, not assumed host equivalence.
- Add proposed Makefile entrypoints for package/static/scenario tests without changing existing test meaning. Confirm the production library can be exercised in a standalone executable on the oldest supported OS even if the package's test runner cannot.
- Review first-slice label/date/text/limit definitions against actual legacy fields. Measure realistic whole-note sizes, input rate and encoding expansion; preserve fixed wire ceilings. Do not freeze values by guessing what AppKit can load or introduce note paging.
- Schedule isolated registered-external-undo experiments through the existing probe harness. Preserve the distinction between ordinary undo registration and authoring new portable operations. These inform the later adapter, not a new core composition policy.

**Tests / exit**

Build a positive ordinary client and separate-client negative cases against actual available APIs, without `@testable`. Match intended diagnostics; unrelated build errors do not pass. Exercise debug/optimized builds and run a representative actual macOS 11 executable as soon as that environment is available. Record missing environments as blocked qualification, not a reason to abandon portable development.

Deliver a short symbol/requirement/test map and a first-slice format checklist. `TC-STATIC-01–04` are implemented progressively as those APIs exist; an absent issuer cannot already have passed its contract test.

## 5. Phase 1 — Values, canonical encoding and envelopes

**Implement**

- Nominal identities and exact UTF-8 values; explicit distinctions among referenced IDs, computed identity, canonical sets, graph-derived scope frontiers and represented note revisions. Preserve exact body spelling; recovery-key/passphrase normalization does not normalize stored bodies.
- The bounded cursor, explicit writers and the fixed 124-byte envelope header. Use the specified public/hash and encrypted suites and private/provider kind/scope separation; no native layout or suite selected as trusted policy from incoming bytes.
- Complete first-slice operation/action/payload, descriptor, initial snapshot and private-state formats using the first-save contract. Keep allocation/hash dependencies acyclic: allocate action/operation inputs, identify members, construct/validate the complete action record, frame, then seal.
- Pinned-context authentication, HKDF/AAD composition, bounded zstd consumption and typed malformed/unsupported/waiting/deferred outcomes. Unknown framing and authenticated unknown payloads remain distinct. Fixed test keys/nonces never become production API controls.
- Full action-group framing even in the minimal subset. No per-keystroke record requirement and no accepted valid-looking prefix of an invalid segment.

Implemented so far: first-subset operation/action and whole changes-payload codecs,
canonical claim expansion, group consistency and exact direct-reference checks;
envelope/descriptor/initial-snapshot codecs and connected initial-import validation.
The [first-save boundary](first-save-reopen-contract.md#implemented-action-and-payload-boundary)
lists remaining semantic/cryptographic checks; the SQLite schema is not permission
to bypass them in a save/reopen adapter.

**Tests**

Implement `TC-CAP-01`'s core capture portion, `TC-BYTE-01–02`, `TC-CRYPT-01`, applicable `TC-LIMIT-01`/`TC-ZSTD-01` and static clients. Include literal header offsets, exact preimages/IDs and independent size calculations; public/encrypted known-answer vectors; same operation under alternative valid transport references; nonzero-offset slices and mutable-buffer changes; truncation at every byte of short fixtures; malformed lengths/counts/order/UTF-8; wrong profile/key/collection/scope.

Near-valid semantic negatives must reach the intended validator with valid outer framing/authentication. Keep impossible-to-encode symbolic graph cases labeled as internal validator tests. Exercise real entrypoints at feasible below/at/above limits and test the intended outcome, not merely any error. Add targeted field/AAD/length-guard mutations and fuzz instrumentation smoke tests.

**Exit:** exact reviewed bytes/identities and classifications agree on supported core platforms/architectures, and meaningful mutations are detected. Both suites have real crypto composition tests. No provider writes or claims of durable storage yet.

## 6. Phase 2 — One complete local save and fresh reopen

The first local path is implemented. [Phase 2 validation](phase2-local-runtime-validation.md)
maps actual symbols and tests to the requirements below, including remaining
platform, physical-power-loss and later-reducer gates. The checks run through
`make -C tests run-swift-storage-phase2`; `--configuration release --mutations`
selects the complete optimized challenge campaign. The raw-cell baseline leaves
the adopted zstd candidate intact for the next physical-codec qualification task.

The [current-basis increment](current-basis-validation.md) reuses complete current
rows for eligible ordinary saves and maintains frontiers through direct parents.
Its growing-ancestry measurements and exact eligibility tests supplement Phase 2.
The [hardening increment](phase2-hardening-validation.md) adds off-writer ancestry
validation with one-read writer turns, one-batch materialization, durable receive
rejection and seeded two-store crash/retry schedules. It records remaining release
qualification separately from these implemented ordinary-history behaviors.

The implemented [automatic continuation after interfering saves](validation-resumption-plan.md)
keeps the existing receive operation alive and reuses its durable queue and local
save-completion waiters. It adds no stored scheduling state. The
[follow-up results](validation-resumption-results.md) cover race/lifecycle tests,
atomic rejection failures and derived blocked-prerequisite diagnostics.

When revisiting concurrency boundaries, consider actor-based ownership wherever
it can simplify the implementation and strengthen compiler-enforced safety
together. The [database-actor adoption](actor-database-adoption.md) implements the
dispatch-backed owner and asynchronous history lookups explored by the
[isolated prototype](actor-database-prototype.md). Preserve synchronous SQL
transactions, admission/generation fences, save progress during history work and
shutdown ownership. Qualification includes the complete shared validator and
resource cleanup; actual macOS 11 execution remains a platform gate.

**Implement**

- One local store owner and one sealer; immutable captures preserve complete action boundaries and before/after state. Reserve in-flight work before suspension. Reuse the application's pending-generation semantics rather than introducing a second journal or parallel note-value store.
- A qualified private SQLite adapter retaining exact immutable BLOBs with complete acceptance/index/pin/ready-work transactions. The separate immutable exclusive installer is for later provider publication, not private objects.
  The [initial SQL schema and transaction contract](sqlite-local-schema.md) now provide executable DDL and direct SQL checks for this first subset. Implement it behind the complete Core validator; do not mistake foreign keys for semantic validation. Later pending/projection tables are not enabled by this increment. [Completion evidence](remaining-storage-validation.md) records implemented envelope/descriptor/initial-snapshot/recovery codecs separately from those remaining gates.
- One owner serializes acceptance and independent settings/pending-state transactions; no public `markDurable`/`markPinned` shortcuts. Validate complete causal/action closure before acceptance, and persist reverse-dependency wakeups in the same commit.
- Recover actual committed identities and drain ready work without relying on callbacks. Materialize indexed accepted changes in a separate derived transaction; use direct current-row startup with no packed representation. Known required corruption is not editable emptiness.
- A headless command/completion client through the production capture API. Keep later live generations pending; local completion never replays its captured body into Current.

**Acceptance oracle**

At durable acknowledgment or incoming acceptance, independently establish: complete semantically valid groups; every required object/descriptor in the expanded committed pin closure; exact verified bytes and qualified durable namespace reachability; matching collection/store incarnation; and current local ownership. Do not impose this predicate on immediate local admission. A later valid edit/Delete may change Current while earlier acknowledged work remains historical.

**Tests**

Start with two notes, one changed and one untouched. Freeze E, commit its exact history/indexes/pin but hold completion, admit newer F, then release E. Check both history and pending generations; repeat with F a Delete. Kill a child inside SQL/VFS effects, before/after commit and during recovery/materialization. Run the real opener with **only the surviving database/journal and normal key/startup inputs**. The parent's expected command/acknowledgment log is never recovery input.

Implement `TC-DUR-01–05`, `TC-EVD-01`, local `TC-ASY-01`, `TC-LIVE-01`, basic `TC-START-01` and both provider profiles over encrypted private pages. Cover RAM-only parent versus same-envelope parent, multi-parent parked work, SQL/VFS ENOSPC/EIO/commit ambiguity, an older settings plan after newer acceptance, incompatible receipts and stale/cancelled callbacks. Provider namespace/directory-barrier tests belong to the provider installer phase.

Use the real SQLite engine with controlled effects **below** the acceptance API, including its VFS and child-process driver. Reuse the [compiled transaction experiments](sqlite-collection-transaction-validation.md) and [fast-start SQL/model cases](sqlite-fast-start-validation.md) as schedules, not substitutes for the production path. Keep the small filesystem model for provider/projection work; do not reimplement SQLite's pager or invent a private object/pin-file gap.

**Exit:** complete acknowledged groups/closure survive the specified crash boundary; committed work survives lost callbacks; ready work drains and current rows catch up; no completion clears newer work. Both profiles use the real acceptance/reopen path independent of provider progress. SQL/VFS process-fault tests do not alone qualify physical power loss.

## 7. Phase 3 — Portable semantics through two independent stores

**Status (2026-10-01): complete.** The portable exit gate is qualified through
real independent stores on arm64 and Intel macOS. The
[qualification report](phase3-validation.md) records exact execution scope,
corrected test-driver/schema failures and outstanding macOS 11/Linux release
qualification. Provider, physical-file and application integration remain in
their subsequent phases.

The [first history-reader increment](phase3-history-validation.md) implements
paged retained revisions, detached previews and logical deletion-entry inputs
through real independent stores. The [Restore increment](phase3-restoration-validation.md)
adds fresh births, exact deletion provenance and durable Recently Deleted exclusion.
The [merge engine increment](phase3-merge-validation.md) implements the pinned
plaintext algorithm, note-ancestry head/base selection, deterministic provenance
and detached accepted-history previews. The [derived-state reference increment](phase3-derived-state-validation.md)
adds canonical equal/merge subrecords, exact dependency reconstruction and
file-private checked-result issuance. The [connected record contract](phase3-connected-record-contract.md)
now integrates those states into editable current rows, complete writer-history
validation, ordinary saves, deletion/preservation, source choices/copies, historical
recovery and causal compensation. The [phase-3 qualification report](phase3-validation.md)
records the complete portable increment and its executed checks, separately from
later provider/application integration and outstanding platform qualification.

The [phase-3 schedule and observation matrix](phase3-schedule-observation-matrix.md)
defines the connected lifecycle gates, exact intermediate observations, bounded
delivery/crash schedules, valid companions and targeted mutations. Its coverage
map links each supported row to the executed report; selected combinations and
exhaustively enumerated dimensions are reported separately.

**Implement**

- Dependency parking/resumption and complete writer-context validation through actual envelopes. Scope parents are all maxima of declared writer inputs, including applicable pending ancestry, not receiver Current or the lazy history UI index.
- History/Recently Deleted derivation and explicit fresh-birth recovery; then the pinned conservative merge and its inspectable provenance; then portable causal compensation/candidate rules. Capture action metadata from the start even while presentation arrives later.
- Current-only note predecessors distinct from causal knowledge. Equal-value/merged Current carries every represented input. Temporary local Current pins release through a scheduled generation-fenced reduction without waiting for another provider event.
- Explicit Delete coverage, retractable automatic preservation, independent edits of preserved copies and monotonic retirement. NV conflict copies acknowledge exact revisions without selecting/replacing the source; later copy edits/deletion do not revoke disposition or recreate it.
- Actual Undo/Redo inverses, partial-coverage record support when frozen, command-relative review, fresh restored births and independent compensation families. No timestamp/arrival-order cursor or origin ownership rule.

**Tests**

Run `TC-ACT-01–05`, `TC-SEM-01–02`, `TC-MERGE-01–02`, `TC-DUR-06` and `TC-LIMIT-02` against two independent stores and a fresh-process variant. Exchange **real bytes**, child-first/duplicated/reordered/temporarily hidden, with no shared indexes or expectations obtained from the production reducer. Assert exact expected values, retained operations, heads, represented inputs, candidate sets and birth mappings—not merely peer agreement.

Port concrete expectations from `CausalUndoRules`, `ConcurrentUndoExecutionSafety`, `SegmentMergeSafety`, `SegmentDeletionOrderingSafety`, `NVConflictCopySafety` and `CompensationOverlapBridge`. Use existing LF/reference vectors independently. Challenge all-known-head predecessors, omitted scope maxima, sticky automatic copies, wrong actual compensation, stale Current pins and dropped action members.

Add reciprocal copy → copy edit/Delete → later source descendant schedules; pending compensation → late remote overlap → pin/ack → both-store reopen; observed versus concurrent Delete → fresh restoration → delayed old Delete. Large or rich opaque one-sided/equality fixtures retain their stated limits where supported; no new rich encoder is required. A 10,001-token two-sided merge requires review, not invalidation of the note.

**Exit:** the finite scenario corpus reaches independently expected results after complete delivery and fair local settling, preserves unchosen work, and detects its named mutations. This is bounded implementation conformance, not arbitrary-history refinement or proof that a provider eventually discloses every object.

## 8. Phase 4 — Startup, repair, repository copy and private state

The [detailed Phase 4 plan](phase4-startup-recovery-plan.md) starts with general
post-edit snapshots, large multi-batch bootstrap and snapshot-plus-history
recovery/current-row reconstruction as one correctness bundle. Required private
formats, backup/salvage/activation, repository copy/export and physical startup
qualification follow as separate gated increments. Existing healthy current-row
startup remains the normal launch path.

The [4C–4E private-state, repair and copy plan](phase4-private-state-repair-copy-plan.md)
orders complete private codecs/transactions and damage classification before
consistent backup, working-copy salvage, verified fresh-sibling activation and
repository copy/export. Its production fault matrix, independent observations
and Swift issuer/consumer probes qualify preservation of unique private work as
well as accepted history; application/provider surfaces retain their later gates.
The [4C–4E report](phase4-private-state-repair-copy-validation.md) records the
implemented private codecs/reference transactions, fixed-cut keyed backup,
complementary reconstruction, verified selection and distinct copy/export paths.
It separates executed local failure schedules from provider/UI integration and
physical power-loss qualification.

Its [data-safety testing and Swift boundary plan](phase4-data-safety-contracts.md)
prioritizes committed-history preservation, required-data-loss classification,
private input ownership, consistent backup and verified selection cutover. Each
gate couples restricted evidence issuance with actual consumer/failure tests;
actor isolation alone does not establish applicability after suspension.

The [first executable snapshot increment](phase4-general-snapshot-validation.md)
provides paged canonical records, complete previews and semantic verification
against real accepted post-edit history. [Durable local root/page acceptance](phase4-snapshot-acceptance-validation.md)
now connects those checks to the existing history transaction, retained pin and
fresh-process ready recovery. [Received snapshot assembly](phase4-received-snapshot-validation.md)
now handles exact candidate intake, waits and complete acceptance.
[Complete bootstrap and all-branch reconstruction](phase4-bootstrap-reconstruction-validation.md)
complete the S3/S4 production paths of the first bundle; the
[durable snapshot acceptance/recovery plan](phase4-snapshot-acceptance-recovery-plan.md)
defines their ordered executable gates, bounded candidate wakeups, complete
bootstrap, all-branch recovery, fresh-process faults and Swift evidence consumers.

The implemented [received-snapshot S2 plan](phase4-received-snapshot-plan.md) covers
exact root/page intake, retained-byte versus accepted-history waits, atomic arrival
wakeups/parking, isolated rejection and bounded-work qualification. Its tests
preserve S1's exact receipts/ownership and make the separate S3/S4 recovery gates
explicit rather than counting snapshot acceptance as completed reconstruction.

The implemented [S3/S4 bootstrap and reconstruction plan](phase4-bootstrap-reconstruction-plan.md) provides:
store-backed complete initial construction, then snapshot-seeded reduction of
all accepted outside-cut history and guarded current-row installation. Its
risk-ranked matrix, fresh-process fault cuts, language boundaries and focused
model bridge have their executed evidence and limits in the
[S3/S4 report](phase4-bootstrap-reconstruction-validation.md). Their companion
[4C–4E increment](phase4-private-state-repair-copy-validation.md) now implements
private formats and local backup/salvage/activation. Physical current-cell
optimization and real provider/application integration retain their own gates.

Follow the [remaining Phase 4 plan](phase4-current-row-locality-maintenance-plan.md)
for production baseline measurements, zstd current cells/dictionaries, initial
checked-capture reuse, separately qualified cipher geometry/read-ahead and safe
idle full-VACUUM. Its LOC01–LOC18 matrix connects byte, crash, recovery, lifetime,
performance and compiler checks. Outstanding review findings retain explicit
API/policy/format gates; physical optimization does not count them as fixed.

The [4F contract](private-current-row-codec.md) and
[report](phase4-current-row-locality-maintenance-validation.md) now record
current framing/dictionaries, one-shot checked opening capture and explicit
maintenance/cancellation. Keep 4-KiB cipher geometry and ordinary no-hint SQL
startup; alternative geometry, read-ahead and automatic maintenance remain
separate gates. No automatic recoding/training schedule is enabled.

The [storage review follow-up](storage-review-follow-up.md) adds executable work-
growth and interrupted-diagnosis witnesses plus stronger compiler construction
boundaries. All seven issues now have implemented remedies; general-v2
[snapshot retention coverage](phase-4-improvements/snapshot-retention-coverage.md)
addresses sequential root growth through exact accepted parent links. Its
[qualification report](phase-4-improvements/snapshot-retention-coverage-validation.md)
separates executed checks from remaining concurrent-width and physical-I/O limits. The
[Phase 4 improvements](phase-4-improvements/README.md) implement a
[durable verification recovery plan](phase-4-improvements/durable-verification-recovery.md)
for interrupted diagnoses, followed by
[at-most-once envelope decoding](phase-4-improvements/at-most-once-envelope-decoding.md)
within captured history traversals and their snapshot occurrence checks, then
[one checked graph for recovery catch-up](phase-4-improvements/recovery-graph-reuse.md)
across unapplied general-reducer batches before editable publication. The
[validation report](phase-4-improvements/validation.md) records executed checks,
performance observations and remaining qualification limits. The
[startup/scoped-query increment](phase-4-improvements/startup-and-scoped-queries.md)
then defers independent optional snapshots until successful host publication and
selects note-specific Undo/conflict records before decoding, while preserving
collection-wide copied-version IDs. Its
[report](phase-4-improvements/startup-and-scoped-queries-validation.md) records
qualification. The [benchmark backlog](phase-4-improvements/benchmark-backlog.md)
keeps independent concurrent snapshot width and further workload measurements separate.

**Implement**

- Expand the initial bootstrap to large multi-batch imports and general post-edit provider snapshots. The minimum complete initial snapshot belongs to phases 1–2. General snapshot acceleration requires its complete format and applicability verification; authentication alone cannot certify derived contents. The private packed startup cache is removed from the design.
- Implement [the concrete fast-start algorithm](../LocalStore.md#concrete-returning-launch-algorithm): exact acceptance prefix, required ready-work draining, current-row catch-up and final publication fence; independent optional snapshots drain after successful checked publication. Only invalid materialization/bootstrap/repair requires exceptional history rebuilding. Keep full current bodies/compact authoring frontiers in memory before editing.
- The [equivalent-load benchmark](remaining-storage-validation.md#startup-remove-the-packed-cache) selects current rows alone. Omit packing, cache/delta tables and cache-only bookkeeping. Retain production workload/fragmentation measurements as release qualification.
- Qualify the [clean-quit locality candidate](clean-quit-locality-strategy.md): independently compressed current cells, page geometry and optional bounded physical-page read-ahead, measured separately and together. The candidate's producer/invalidation/reader/failure cuts are specified there; the synthetic probe does not implement them all. Do not impose whole-history VACUUM or unconditional table rebuilding on quit, freeze cipher geometry from startup results alone, or treat an I/O hint as current-state/history coverage. Keep normal startup correct with no hint.
- Implement the [opportunistic full-VACUUM policy](clean-quit-locality-strategy.md#adopted-opportunistic-full-vacuum-policy) only after qualification: healthy idle owner, cooldown plus measured fragmentation, temporary-space/work budget, required-write priority, settled cancellation and durable hint invalidation. Calibrate thresholds with realistic post-compaction aging; test resumed-input to durable-commit latency, interruption/crash/space failures and exact history/private-state retention. This is optional maintenance, not a new startup/quit barrier or SQLite auto-vacuum mode.
- Implement the [SQLite backup/salvage/activation mapping](../LocalStore.md#sqlite-backup-salvage-and-replacement-activation): keyed consistent backup including live-WAL work and unlock descriptors; preserve damaged DB/journals; use fresh working-copy connections after page errors; independently validate immutable bytes and complete private pending/settings groups; verify and reopen a fresh sibling before durable selection-record cutover. Preserve missing-state evidence and never call provider-only reconstruction complete private recovery.
- Use the [specified public or CK-derived database key](../LocalStore.md#database-keys-and-password-free-recovery). Password-free database copies need no Keychain/key sidecar; encrypted copies need usable same-key descriptors and a secret, not device migration. Password rewrap changes no database key; no second password UI or native-rekey state machine. Test descriptor-install/SQL-commit uncertainty, missing bootstrap, wrong profile, and unavailable remembered credentials without downgrade.
- Repository-only Save As distinct from current-state recovery/export. Preserve available history/identities without requiring source Application Support or undisclosed remote changes. Required credentials/association cutover is source-preserving and add-only/readback-verified; Apple credential effects are qualified later.

**Tests**

Implement `TC-START-01–03`, local `TC-REPAIR-01`, `TC-COPY-01–02`, `TC-KEY-01`'s portable portions, remaining private-format bounds and long-history budgets. Test authentic-but-wrong provider snapshots/current rows, missing/contradictory pages/import batches, wrong local scope, derived-row corruption, pinned loss versus undisclosed loss after total pin erasure, settings replacement races, and copied-store ambiguity.

Sweep failure during union copy, pin commit, activation and association cutover, then fail recovery itself. No old store is deleted or foreign occupant overwritten. A budget yield resumes rather than truncating ancestors; no size budget may truncate notes. Repository copies report unavailable captured bytes/dependencies and do not claim to save pending RAM edits or private pending-file buffers.

**Exit:** complete available history reconstructs current rows; incomplete known required history cannot become editable; failed repair/cutover preserves recoverable sources. The concrete snapshot-verification method has independent wrong-result tests before fast-start use. Existing launch targets remain measured gates, not an excuse to trust derived values blindly.

## 9. Phase 5 — Provider and physical-root adapters

**Implement**

- Bind the qualified rooted helpers to Runtime's exact intents; keep provider immutable installation, private SQL transactions and expected-projection replacement separate. Follow [safe replacement](../../Foundation-Safe-Replacement-Migration.md), including preserved displaced bytes and typed reconciliation-required outcomes—not a fictional atomic compare-and-swap against unrelated writers.
- One independently owned provider/root lane, bounded disclosure/discovery, exact sealed-byte publication and local receive/acceptance. Retain resources through timed-out accessors; no shared serial resource that strands local saves behind provider work.
- Translate actual provider/file observations into classifications without inventing authority. No reverse-provider lookup, portable historical Apple IDs, uploaded-as-durable, sequence-max completeness or callback-as-global-barrier.
- Transparent repair of locally missing/repairable `NV Data` only under positive same-root and complete required local evidence. Work Offline is only the specified startup option for positively disclosed newer/required unread evidence; generic offline/full errors or later disclosure do not revoke healthy editing.

**Tests**

Complete `TC-ROOT-01`, `TC-DISC-01`, real-lane `TC-LIVE-01`/`TC-ASY-01`, provider `TC-REPAIR-01` and startup disclosure cases. Exercise same-object moves versus same-path replacement with identical collection bytes, two local contenders, lock/descriptor lifetime, symlinks/wrong-kind entries, compatible/foreign race winners and a provider accessor that actually enters and stays stuck while a local save completes.

Use [Apple contract validation](../../Apple-API-Contract-Validation.md) AV-15–17 and applicable discovery/materialization cases through production adapters. Two-device tests use only an authorized synthetic subtree and compare peer-read bytes. A missing stimulus/timeout is inconclusive; do not reset accounts or manipulate real quotas to make a test run.

**Exit:** no operation acquires authority from matching paths/IDs, unavailable evidence or upload status; actual local execution progresses independently. Confirmed API probes support only their measured primitives and must be connected to the adapter being shipped.

## 10. Phase 6 — Plaintext projection and pending-file recovery

**Implement**

- Reuse the transactional fenced catalog flow for current plaintext inputs, with history/body/stamp arriving independently. Adopt ordinary eligible automatic imports and narrow per-note repair candidates, with missing-history/deletion/copied-provenance exceptions taking precedence. FSEvents only prioritizes inspection.
- Track intended and last accepted projections across unfinished A→B→C saves/renames, with exact source accounting. Retire a previous comparison input only at the adopted accepted-transition boundary; a delayed B completion must not clear C.
- Implement the [private pending records](../Protocol.md#pending-file-commit-and-recovery-records): one latest validated snapshot, independent frozen admitted inputs, exact operation/birth reservation and atomic receipt/pending settlement. Use the same private SQLite transaction machinery, not another database or sidecar.
- Association separates identity choice from content choice. A neutral repair writes no Put/action; changed contents use ordinary capture/acceptance. Competing claims and new logical Delete invalidate stale choices without losing captured input or replaying consent.
- Unexplained external absence obeys `confirmFileDeletion` locally or remotely. Explicit causal Delete has different logical semantics, but neither grants a filename/UUID sweep. Physical deletion remains the original expected-snapshot operation after local durability.

**Tests**

Extend `TC-PROJ-01–02`, `TC-ROOT-01` and the adopted `IMPORT-01` matrix beyond the older strategy's broad stamp cases. Exercise all four pending-file families and `ExternalRecoveryBridge`/`ProjectionRecoveryBridge` through real codecs/installer/Local State and two-store history:

- Latest B replaces A only after safe storage; an admitted A keeps independent ownership. Failed replacement or unreadability retains previous readable input. Closing a view is not abandonment.
- Import commits, receipt does not, process crashes twice: recover the exact operation before scanning and reuse its birth even if it was subsequently edited/deleted. No blanket equal-body/path deduplication.
- Competing association choices, neutral repair crash, changed preview after consent, Delete before/after admission and a newer unreviewed snapshot. Never reinterpret a click or replay a persisted reservation as consent.
- A→B→C with delayed callbacks/restart, safe-save displacement, returned/renamed files, copied/stripped/skewed stamps, placeholders and mandatory-metadata errors. Distinguish installed-needs-reconciliation from no-write failure.
- No plausible broken relationship imports fresh; unrelated missing notes do not prompt. Active intended path or exact nonempty bytes can nominate that particular repair-needed note only; never pool evidence between notes. Delayed history may leave separate admitted births.

**Exit:** admitted observations cannot repeatedly create new notes after restart; exact approved inputs remain recoverable; subsequent bytes remain subsequent work; physical source cleanup never follows merely from a historical receipt or matching name.

## 11. Phase 7 — Application capture, history UI and lifecycle

**Implement in user-facing order**

1. Integrate the real Objective-C admission/capture/completion seam; freeze mutable buffers and exact note/action/attachment generations. Retain 2.7-second idle and 15-second first-pending scheduling plus forced boundaries. Search stays synchronous. This is not a timer-defined undo policy.
2. Expose Note History, selective recovery and Recently Deleted with fresh-birth Restore; then inspectable conservative merges; then portable causal Undo/Redo with invocation-scoped review. Real command-to-capture tests must preserve title/labels/dates/untouched fields and exact action membership.
3. Keep native fine-grained undo where valid. Test properly registered external changes, native span attribution and multi-window routing. Follow standard AppKit composition/focus behavior; defer remote editor application to a safe boundary and revalidate. The synthetic separate-snapshot adapter and Undo Saved Edit fallback are not prescribed solutions.
4. Complete the badge-invoked embedded resolver replacing `LinkingEditor` with a read-only `NSTextView` or equivalent. The × always dismisses; per-version operations can continue; re-presentation restarts exhausted bounded attempts without an explicit Retry button or overlapping accessor.
5. Keep NV choices, Note History, Undo review and Apple member disposition distinct. Apple resolution requires captured admission, exact local action/closure barrier, exact plaintext installation, then fresh coordinated source/member checks and subsequent verification. Neither preview bytes nor a successful local save alone grants disposition.
6. Wire one close/switch owner, external-editor handoff, source-preserving Save As/profile transitions, epoch-4 migration/recovery/export and credentials. Local failure preserves admitted work; materialization failure alone cannot fail durable quit. No last-chance persistence in termination callbacks.

**Tests / exit**

Complete actual-caller `TC-CAP-01–02`, `TC-ASY-01`, `TC-UI-01`, `TC-CLOSE-01`, signed `TC-KEY-01`, `TC-LEGACY-01` and privacy cases. Verify the initiating view can close after admission, observer callbacks do not create duplicate actions or see half-published indexes, and stale same-note generations fail even when the causal frontier is unchanged. Inspect actual compensation and recovered indexes, not menu labels alone.

Test failed versus empty Apple queries, successful setter with delayed verification, restart, independent NV conflicts, newly arriving members, and changed/deleted recovery copies. Completed dispositions remain completed historically; in-flight reuse still needs its exact qualifying evidence. No Apple identifier is stored as portable NV revision identity and no version-removal call is authorized.

Human sign-off, actual keyboard/IME/undo/accessibility exercises and review are required before modifying core interaction paths. The portable core can be ready while this gate remains blocked; do not claim full application readiness from headless tests.

## 12. Phase 8 — Qualification, not a late testing phase

The release matrix includes:

| Area | Required evidence |
| --- | --- |
| Portable core | Reviewed corpus on Darwin/Linux, Intel/ARM where claimed, debug and optimized; no semantic-byte/identity divergence |
| Deployment | Actual macOS 11.5 binary launch and exercised API paths, plus other supported representative OSs; SDK flags alone do not qualify |
| Persistence | Real installer/replacement/lock tests on claimed filesystems, child-process crash recovery, separately documented persistence-loss/power-cycle assumptions |
| Provider | Two-device exact-byte evidence, reordered/missing metadata/history, root lifecycle and no global-completeness inference |
| Crypto/privacy | Independent primitive/composition vectors, dependency/security review, signed credential failures, synthetic marker inspection of all success/failure/temp/log paths |
| Application/legacy | Existing integration suites, real capture/undo/resolver/close tests, epoch-4 compatibility and explicit unsupported migration paths |
| Resource/performance | Full current-note/search readiness, cold/warm launch, durable-tail replay, memory, local barrier latency, KDF cost, provider backlog and retained growth on realistic workloads |

Attachments/new RTF/HTML functionality are not an enabled feature gate here. Handling existing unsupported inputs safely is. Protocol-history GC, whole-note paging and custom schedulers remain absent unless measurements and separate decisions justify them. Long small-note histories still require bounded resumable processing; small current notes do not imply small ancestry.

**Release exit:** no enabled feature relies on an unresolved format/policy, unqualified claimed platform primitive, missing critical caller/bridge, silently skipped required test, or unexplained critical mutation survivor. Neither this checklist nor a suite count is a proof of the whole program.

## 13. Test organization, model connection and evidence

### Keep the machinery small and the assertions independent

Reuse the conformance strategy's contract IDs, including `TC-IMPORT-01` for the adopted import/pending rules. Each important boundary needs a success/progress witness, near-valid forbidden case, independently expected outcome and targeted mutation. The same ownership/acceptance test must cover authoring, receive, bootstrap, reopen and repair callers where their input construction differs.

Use four observations: admitted commands/completions, actual low-level effects, independent fixture/closure/value expectations, and fresh production recovery. An issuer's success flag is not evidence that its barrier occurred. Test the harness too: wrong expected bytes, missing gates/scenario registration, no-op fault injection, bogus compile failures and an always-durable disk must fail. No untrusted-input trap is an acceptable typed rejection.

Begin with hand-scripted schedules; sweep one failure or intervening event across real boundaries, then persistent failure and a second recovery failure. Add bounded two-store permutations and seeded structured histories after the checks catch their named mutants. Preserve the complete schedule as well as seeds. Do not multiply every platform/codec/history/UI dimension into one enormous test.

Apply mutations to isolated builds of production code, not to the oracle, and leave no permissive production switch. Classify targeted detection, compile-blocked, survived, unreachable, unrelated failure and inconclusive separately. Positive companions catch implementations that reject everything or never acknowledge. A survival explained by another real guard merits review, not deletion of that guard to improve a score.

### TLA+ is a source of schedules and obligations, not generated Swift

Use the [active model map](../../tla/Proposal5-Coverage.md), [runner guide](../../tla/README.md) and [audit](../../tla/Storage-Protocol-Audit.md). Retired proposal-4 models remain excluded. For each bridge, read the actual module, checked configuration and runner expectation before translating it.

| Production boundary | Most relevant existing models |
| --- | --- |
| Install/closure/pin/completion | `ImmutableSegmentDurabilitySafety`, `SegmentDeletionSafety`, `RepositoryRepairSafety`, `LocalDurabilityLaneIndependence` |
| Applied history and compensation | `SegmentActionRecoverySafety`, `CausalUndoRules`, `PortableCausalUndoSafety`, `ConcurrentUndoExecutionSafety`, `CompensationOverlapBridge` |
| Source values/deletion/copy disposition | `SegmentMergeSafety`, `SegmentDeletionOrderingSafety`, `NVConflictCopySafety` |
| Startup/repair/copy | `SegmentBootstrapSafety`, `RepositoryRepairSafety`, `RepositoryCopySafety` |
| Pending inputs and physical projection | `ExternalFileLifecycleSafety`, `PendingReferenceSafety`, `ExternalAssociationSafety`, `ProjectionTransitionSafety`, `ExternalRecoveryBridge`, `ProjectionRecoveryBridge`, shared catalog/deletion/stamp checks |
| Native/resolver application seam | `NativeUndoSpanSafety`, `SharedNoteViewOwnershipSafety`, `ReviewedUndoSafety`, `UnresolvedVersionResolutionSafety`, `CrossMachineConflictDispositionSafety` |

Replay **environment choices**, not a broken model's illegal internal command to acknowledge early. Correct code should park/reject/defer as appropriate; the corresponding production mutation exercises the faulty transition. Keep intermediate physical effects, acknowledgment, exact generations and Current's represented inputs observable, not just final text.

Add implementation-to-model trace checking only for a clearly defined projection that closes a demonstrated gap. Use the harness's ordered observation stream; do not sort independent Mac logs by wall time and call that a global execution. Require complete trace consumption, reject missing/unknown critical observations, and prove the mapping rejects known-invalid traces. Never map receipt existence directly to proven durability. Finite trace acceptance is not whole-program refinement.

When a concrete test/model disagrees, first check fixtures, reachable states, observation mapping and the actual API contract. If the modeled counterexample is valid, revisit the protocol/implementation and update the spec, ADR/vocabulary and relevant models together. Do not weaken an assertion or remove the offending state merely to pass. Timeouts remain inconclusive, expected mutation failures remain negative evidence, and progress claims state their fairness/finite-input assumptions.

### Commands and CI

Existing commands to retain (run from the repository root; live/platform tests remain opt-in):

```sh
./build.sh
make -C tests run-core
make -C tests run-platform
make -C tests run-native-undo-probes
tools/test-epoch4-v5-compatibility.sh
python3 docs/impl-proposal-5/check-history-rules.py
python3 docs/tla/check-segment-models.py --java /path/to/java --jar /path/to/tla2tools.jar
```

Use the model runner's documented `--only` filters during focused work. The full release inventory includes each relevant family; a previously completed unrelated family is not new execution evidence.

`make -C tests run-swift-storage` runs the implemented package tests;
`make -C tests run-swift-storage-phase2` additionally runs the concrete local
fresh-process/fault, independent-oracle, compiler-client and schema/fixture checks.
Use `SWIFT_STORAGE_PHASE2_FLAGS='--configuration release --mutations'` for the
optimized mutation campaign. Broader provider/two-store scenario coverage still
grows with its implementation. Portable jobs invoke the package's native runner
without building the Cocoa app. The toolchain-provided Swift Testing runner has
been exercised on the development Mac; compatible standalone assertions must still
qualify the oldest supported OS without duplicating the entire suite.

- Change/PR: deterministic completed-feature contracts, independent bytes, static clients, directly affected mutations and relevant reference/model/legacy checks. Zero matched required tests is an error.
- Extended: failure/completion sweeps, small-history permutations, structured fuzzing and raw parser/decompression targets, supported sanitizer configurations and optimized runs. Authentication-bypassing fuzz entrypoints are test-only and explicitly scoped.
- Release: the complete enabled-feature/platform matrix and actual application/provider/credential exercises. Qualify fuzz/sanitizer instrumentation with an intentional failure before crediting quiet runs.

Keep one concise obligation-to-entrypoint/test index. Execution records carry source/binary/toolchain/dependency revisions, fixture provenance/digests, model/disk assumptions, full schedule, reached fault boundary, effects/acks/reopen inventories, assertion names and mutation disposition. Use synthetic data only. A prior green result does not survive a changed issuer/oracle/adapter automatically; blocked and inconclusive cases remain visible.

## 14. First implementation handoff

Start phases 0–2 as the first work sequence: actual package/toolchain boundary; direct Swift fixed header/values; reviewed minimal complete records; then one real public/encrypted local save with an untouched-note control, held completion, newer edit and fresh reopen. Require the early-ack, missing-parent, regressed-pin and stale-completion challenges to distinguish bad code.

That milestone earns expansion to two-store semantics. It does not wait for a schema generator, universal simulator or every UI detail, and it does not claim that unimplemented storage features are safe merely because their types compile.
