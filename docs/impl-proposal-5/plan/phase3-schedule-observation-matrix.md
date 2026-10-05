# Phase 3: schedule and observation matrix

Status: implementation and qualification matrix. The [connected report](phase3-validation.md)
maps these required rows to executed tests, artifacts and qualification boundaries.
The rows themselves define expectations rather than claiming every Cartesian
combination has run. They make the existing
[phase-3 exit gate](swift-storage-implementation-plan.md#7-phase-3--portable-semantics-through-two-independent-stores)
concrete without changing product policy.

## 1. Authority and existing evidence

Read this matrix with the [conformance strategy](swift-storage-conformance-testing-strategy.md),
especially its independent observations, mutation verdicts and bounded exploration
rules. Semantic expectations come from the [normative spec](../../iCloud-Drive-Support-Spec.md#causal-values-conflicts-and-deletion),
[Protocol](../Protocol.md#action-records-and-cross-launch-undo),
[ADR-0014](../../adr/0014-distinguish-logical-deletion-projections-and-conflict-disposition.md),
[ADR-0015](../../adr/0015-retain-history-and-use-compensating-undo.md) and
[CONTEXT](../../../CONTEXT.md#3-history-relationships-and-derived-views).
`P3-*` labels below identify test scenarios, not new protocol concepts.

| Existing evidence | What it establishes | Remaining connection required here |
| --- | --- | --- |
| [History-reader report](phase3-history-validation.md) | Real retained revision reads, detached previews, deletion inputs and fresh-process checks | Connected report adds general history recovery and its conflict/undo interactions |
| [Restore report](phase3-restoration-validation.md) | Fresh births and durable exact deletion-entry exclusion | Connected report adds alternate prior branches, derived inputs and compensation birth mappings |
| [Merge report](phase3-merge-validation.md) | Concrete LF kernel, note ancestry, represented inputs, deterministic descriptors and persisted detached previews | Connected report adds editable multi-head current cells, action capture, guarded publication and ordinary reopen |
| [Derived-state report](phase3-derived-state-validation.md) | Canonical equal/merge subrecords and exact referenced-graph reconstruction; component cases for M1–M3/A1 | Connected report adds complete writer-history admission, actual consumers, generation fences, saved edits and fresh editable reopen |
| [TLA+ coverage and boundaries](../../tla/README.md) | Bounded semantic schedules, independent assertions, progress checks and negative controls at their stated abstractions | Actual record encoding, SQL acceptance, materialization, public consumers and fresh-process recovery composed with those semantics |

No existing preview-only pass qualifies editable merged startup. A feature returning
`unsupported` remains blocked for its positive rows. Negative tests may require
that outcome for genuinely unsupported input, alongside a supported valid companion.
New layouts first need canonical fixtures and validation, as required by the
[first-save contract](first-save-reopen-contract.md) and [format checklist](../Format-TODO.md).

## 2. Shared fixture and observation rules

Use two independently owned stores `H1` and `H2`, a shared valid bootstrap, one
subject birth `N` and an untouched sentinel birth. Add a third writer or a second
subject only where specified. Share sealed envelopes, never databases, current
rows, validation evidence or in-memory indexes. Run every positive connected
lifecycle under both provider profiles; both private databases remain encrypted.

In the tables, `X → Y` means Y causally observes X; `X ∥ Y` means neither observes
the other. Separately list every operation's **note predecessors**, every action's
**scope parents**, compensation target and restoration mapping. These are four
different relationships. Fixture expectations specify actual canonical IDs/bytes;
labels such as L and R are explanatory aliases. Stable Current is computed from
the specified raw revision-ID ordering, not fixture labels or delivery order.

Every row has an independently written expected-state table at its named cuts:

| Observation | Required contents and comparison |
| --- | --- |
| Durable history | Exact retained envelopes, object membership, operation/action identities, causal and note edges, complete action members, retention coverage and parked/rejected work. Repackaging can add envelopes without another logical action. |
| Current values | Exact body/title/labels/format, live and absent births, note heads, all represented revisions, merge descriptor/base/result and unresolved-attention set. Compare values and provenance together. |
| Deletion and copies | Eligible automatic-preservation sources, deterministic keys/births, explicit copy dispositions, retirement evidence and exact Recently Deleted entry/provenance pairs. |
| Undo/Redo | Exact candidates for each requested scope and direction, automatic/review/no-op classification, compensation-family edges, actual before/after values, remaining coverage and fresh-birth mappings. |
| Pending and publication | Captured generation/action/bytes; which receipt covers which generation; outstanding newer work; applied view/history generation. A durable receipt and a model publication have different responsibilities. |
| Progress | Named transition reached, obstruction removed, then intended acceptance/reduction/publication completed without another incoming object or user command used as an accidental wake-up. |

Use the strategy's four observation channels: external command/completion log,
low-level storage effects, independent byte/graph inspection and the production
fresh opener. The fresh child receives only surviving stores and normal selection/
unlock inputs. The parent retains the expected-state oracle and compares the child's
observations afterward. Inspection must decode actual action and provenance records;
runtime success flags or equality between peers are insufficient.

For finite fixtures, hand-author expected graphs/values or use a separate simple
reference calculation plus literal outcomes. Neither reference may call the Swift
production reducer, candidate selector or merge kernel it checks. Capture through
the supported public authoring path wherever that path exists; decoder injection
alone cannot qualify faithful capture. Near-valid malformed fixtures change one
intended fact while retaining valid authentication and all earlier prerequisites.

## 3. Schedule cuts and fault profiles

These labels name observations/hooks, not additional persisted states. Bind them
to actual runtime boundaries before counting a test as covering them.

| Cut | Stop or intervene at | Required witness |
| --- | --- | --- |
| B0 | User input/command captured, before admission | Exact candidate, represented revisions, values and generation captured |
| B1 | Admitted pending work and its sealed bytes fixed | Same action/operation IDs and sealed bytes owned through retry |
| B2 | Incoming candidate retained/parked, before all prerequisites are usable | Actual durable candidate plus exact dependency obligations |
| B3 | Acceptance transaction before and after COMMIT | Complete envelope/membership/retention/ready-work transaction outcome |
| B4 | Derived current-row update before and after its transaction | Accepted prefix versus materialized prefix; atomic complete row/context change |
| B5 | Prepared live result before the final generation/context check | A real prepared value exists before the interfering change |
| B6 | Commit completion/receipt delivery held, then released | Earlier generation committed while a later generation remains pending |
| B7 | Reopen recovery, before/after catch-up or resumed work | Fresh process reached the intended recovery step before a second failure |

Existing process-probe hooks include `NV_FAULT_COMMIT_BEGIN`, `COMMIT_END`,
`VIEW_UPDATE`, `CURRENT_INSERT`, `WRITE`, `SYNC`, `LOCK` and `SYNC_AFTER` in
[CStorageFaults](../../../NVStorage/Tests/Support/CStorageFaults/include/NVStorageFaults.h).
Map their exact transaction/ordinal to B3/B4/B6 in each trace; a COMMIT hook alone
does not establish which transaction it interrupted. B0/B1/B5 and feature-specific
continuations may require additional test-only controls at the real consumer.
Keep synchronous SQL transactions atomic; inject failures at real effects rather
than inventing half-committed SQLite states. Use actor/continuation gates, not sleeps.

| Profile | Enumerated stimulus | Required outcome |
| --- | --- | --- |
| F0: delivery | Every order of each row's finite offered objects; child-first receipt, one exact duplicate, one equivalent repackaging, and temporarily hidden prerequisite | A child waits for its complete exact closure; eventual complete delivery gives the independently expected result. Duplicate/repackaged records retain correct bytes and affect semantics once. |
| F1: crash | Process termination at each applicable B1/B3/B4/B6 cut, including committed-before-callback | No partial action. Pre-commit work may be absent; post-commit work survives without callback. Ambiguous completion is resolved from recovered exact membership, not the parent's expectation. RAM-only admission alone carries no crash-durability promise. |
| F2: second recovery failure | F1 committed-history/current-row-lag state, then fail/terminate at B7; separately repeat write failure twice before allowing recovery | Accepted history/settings survive; no partial editable publication. With storage restored, existing ready work and reduction complete. Retry identities do not multiply. |
| F3: interference | At B0/B5/B6 deliver a relevant remote record, admit a newer local edit/Delete, or change the owner/session/view context | Stale preparation/consent is rejected; admitted exact work retains its durability obligation; an older callback cannot clear or overwrite newer work. Current-pin release schedules fresh reduction. |
| F4: required evidence | Damage a required retained leaf/descriptor versus invalidate only derived rows; add an unrelated malformed object as a separate case | Required-history damage blocks editable success with a recovery outcome; derived-row invalidity rebuilds with intact private settings; unrelated invalid input is isolated. Total evidence loss has only the detection guarantees actually specified. |
| F5: finite work budgets | Same valid graph with small/large budgets; postpone validation with a finite series of saves, then stop saves and deliver nothing else | Identical eventual results, complete dependencies and explicit yield/resumption witnesses; no implicit history-depth limit or event-dependent starvation. |

Process termination, simulated loss of unsynchronized writes and later corruption
are separate campaigns and verdicts. F1 does not qualify physical power loss.
For every crash trace, assert obligations of receipts emitted before that crash;
also preserve committed work whose receipt was never emitted. Independently read
the recovered membership before deciding which ambiguous operation needs retry.

## 4. Feature matrix

Every row requires its valid companion, difficult-path witness and targeted
mutation failure. The final column describes defects to challenge, not production
options. All feature rows below are **connected** qualification gates; the
executed report records their results and existing component coverage is in §1.

### 4.1 Editable multi-head state and action capture

| ID / contracts | Fixture and schedule | Independent observations | Companion, witness and mutation |
| --- | --- | --- | --- |
| P3-M1 / TC-MERGE-01–02, TC-SEM-01 | Base body `a\ngap\nz`; L changes first line to A, R changes last line to Z. Deliver L/R in both orders; expose merged Current; edit it to E; exchange and reopen. Repeat with equal-valued distinct L/R. F0–F3. | Merged body exactly `A\ngap\nZ`, represented set `{L,R}`, exact base/descriptor; E's before-state and note predecessors cover both. Equal values also retain both IDs. Reduction/display emits no new operation; only the explicit E does. Normal editable reopen supplies complete context for the next edit. | Single-head ordinary edit companion. Witness actual merged/equal Current captured into E and consumed after reopen. Mutate dropping one represented input, minting a Put on reduction, or encoding a single-head before-state. |
| P3-M2 / TC-SEM-01, TC-ACT-01 | Incompatible L/R, stable Current L; ordinary E knows both but edits only L. Repeat body, rename and label edits; an independent conflict note already exists. F0/F1/F3. | E supersedes L, while R and the independent note survive. Causal parents can include R without making it a note predecessor. Compare unresolved attention after normal selection; do not assume E always wins raw-ID order. | Explicit source choice capturing L/R is the separate companion that may supersede both. Witness E accepted with R in its causal knowledge. Mutate all-known-head predecessors or knowledge-based note ancestry. |
| P3-M3 / TC-MERGE-02, TC-DUR-01 | Prepare two-head merge, then receive a third differing head T; separately T supersedes L. Also use a graph with two best common note ancestors. Hold at B5; repeat with a temporary Current pin released after local work settles. | No stale two-head result published over a changed input set; three differing heads and ambiguous best bases require review rather than pairwise/arbitrary-base merge. Dominated L drops from heads only via note ancestry. Pin release produces a new checked view even with no new provider event. | Unique-base merge companion; witness third-head acceptance or actual pin release before publication. Mutate frontier-only freshness, permanent pin, pairwise folding or arbitrary-base selection. |
| P3-A1 / TC-ACT-01, TC-ACT-04 | Scope maxima A/B incomparable; pending P follows A. New action knows P/B; parked Q and another-scope R coexist. Receiver has additional later history. Repeat a two-note complete action with one malformed/stale member. | Exact scope parents `{P,B}` at capture, with P earlier in the same complete envelope or already durable. Q/R excluded. Receiver validates declared writer inputs, not its own later Current. All action members accepted together or none. | Valid complete two-note group and valid later receiver history. Witness the valid group reaches semantic validation. Mutate omitted B, inclusion of Q/R, receiver-Current validation, wrong before-state, missing member or partial acceptance. |

### 4.2 Delete, preservation, retirement and restoration

| ID / contracts | Fixture and schedule | Independent observations | Companion, witness and mutation |
| --- | --- | --- | --- |
| P3-D1 / TC-SEM-02 | D0 concurrent with E; E precedes D1. First publish the automatic E copy from D0/E, then deliver D1. Contrast E→F with F concurrent with D1. F0–F3. | Source N absent throughout deleted states; E copy retracts once covered by D1, with E retained historically. F remains preserved when uncovered, without a redundant E copy. Retraction emits no RecoverCopy/Create/RetireConflict. | D0/E without D1 must produce visible preservation. Witness temporary E copy actually existed. Mutate sticky copies, per-Delete union or suppression of every descendant of E. |
| P3-D2 / TC-SEM-02, TC-DUR-01 | While E's automatic copy is live, admit independent edit P (separate variant: explicit copy P). Prepare D1 retraction, hold at B5, admit P before its final fence. Deliver P to a receiver already holding D1; crash around P's commit. | Pending P blocks stale retraction on its owner. Durable P remains independently represented after D1 and restart; receiver accepts its valid captured originating evidence despite different Current. Pre-commit crash need not recover RAM-only P. No old completion restores E over P. | Untouched copy from D1 must retract. Witness independent admission precedes stale publication and receiver already knows D1. Mutate receiver-Current origin check, missing pending fence or erasure of independent work. |
| P3-D3 / TC-SEM-02, TC-BYTE-01 | Two uncovered revisions produce the same canonical automatic key; cover only one, then both. Separately explicitly Delete the deterministic conflict birth and replay/repackage its source evidence. Include an unrelated different-key copy. | Same-key automatic view remains while another source is eligible, retracts when none is, and can reappear from new eligible evidence if merely retracted. Explicit Delete instead atomically retains retirement and prevents that key's automatic recreation. Different-key work survives. | Retraction-without-retirement versus explicit Delete-with-retirement companions. Inspect typed creation domain and retirement action, not UUID bits. Mutate premature retirement, omitted retirement or broad source-UUID suppression. |
| P3-D4 / TC-ACT-05, TC-DUR-06 | Delete N; Restore a named prior revision to fresh R. Hold before/after acceptance and before callback; delete R; replay old Delete. Repeat with alternate prior branch, and two hosts restoring the same entry independently. F0–F2/F4. | Exact durable `(source birth, deletion action, selected revision, resulting birth)` provenance excludes only the named entry. R's later Delete yields a new entry; original stays excluded. N remains absent. Concurrent R1/R2 both survive. Prior branches remain inspectable. | Generic historical copy does not exclude the deletion entry; failed/pending Restore barrier does not yet exclude it. Witness fresh-process derivation without callbacks. Mutate live-note-based exclusion, reused old birth or overbroad deletion-entry matching. |

### 4.3 Source choices, conflict copies and history commands

| ID / contracts | Fixture and schedule | Independent observations | Companion, witness and mutation |
| --- | --- | --- | --- |
| P3-C1 / TC-UI-01 portable variant, TC-SEM-01 | H1 temporarily shows L, H2 R; each saves the other's alternative as a separate note. Exchange dispositions; settle pins; edit/delete a completed copy, then introduce new source descendant T. F0–F3. | Original stays live with Current determined independently of dispositions. Original plus two copies may exist, one duplicating Current. Only exact recovered revisions leave unresolved attention. Copy edits/deletion preserve completed disposition and do not recreate the copy; new uncopied T is assessed normally. | One-sided copy and explicit Use this version companions. Witness both copies/dispositions durable, then copy deletion and new source head. Mutate implicit source Put/Delete/Keep Current, head removal on disposition or disposition loss on copy deletion. |
| P3-C2 / TC-UI-01 portable variant, TC-DUR-01 | Copy selected revision using its body key/slot. Retry after lost callback; receive equivalent envelope. Contrast a slot's exact usable evidence with modified/deleted/retired candidate, changed captured title/labels, and a separately admitted competing copy. | New admission chooses the lowest reusable or unused nonretired slot, with exact live-body/generation checks for reuse. One admitted retry retains exact IDs/bytes. Modified output is preserved rather than overwritten or falsely counted; a later explicit action may select another slot. Title/label/filename changes do not change the body key. Completed disposition remains historical despite later output changes. | Unmodified usable candidate versus changed candidate; witness the actual candidate verification and selected-revision binding. Mutate UUID-only reuse, title-derived key, premature disposition or retry identity reallocation. Concurrent distinct admitted actions are not assumed globally exactly-once. |
| P3-C3 / TC-SEM-01, TC-UI-01 portable variant | Capture explicit Use this version over L/R, preserving Current title/labels while choosing body. Deliver T before admission; separately admit first and deliver T later. Contrast body-only Note History recovery and a fresh separate history copy. | Before-admission staleness requires fresh choice, never silent widening. An admitted choice covers its captured heads only; later T survives as applicable. Ordinary history field recovery targets Current's represented inputs and preserves other fields/alternatives. Separate history copy has a fresh birth, not a conflict retry slot. Preview/cancel creates no action. | Valid unchanged source choice and no-effect preview companions. Witness T arriving on each side of admission. Mutate reused consent, all-known-head expansion, field overwrite or history/copy command conflation. |

### 4.4 Portable Undo/Redo and reviewed compensation

| ID / contracts | Fixture and schedule | Independent observations | Companion, witness and mutation |
| --- | --- | --- | --- |
| P3-U1 / TC-ACT-02 | Ordered A→B→C; Undo C, reviewed Undo B; reopen on peer, Redo B's actual compensation then C's. Separate value fixture: B changes Shopping→Groceries; concurrent Current is Errands; review Undo B to Shopping, then Redo. | Ordered redo tail survives. Value fixture records actual Errands→Shopping and its inverse Shopping→Errands, not Groceries. Unchanged fields and unresolved alternatives survive. Actual compensation and eligibility recover together. | Same bytes applied through explicit Note History are an independent action, with its specified redo-suppression consequences. Witness real Current Errands from valid history/ID ordering. Mutate original-after inversion, wrong command kind or cleared redo tail. |
| P3-U2 / TC-ACT-02, TC-EVD-01 | Prepare/approve review; change candidate frontier, affected value, owner/session or captured view before admission. Separately admit first, then dismiss or deliver an overlapping edit while commit completion is held. F1–F3. | Stale approval consumes nothing and cannot retarget. Valid admission persists despite dismissal. Completion preserves newer pending state and alternatives; restart reconstructs committed compensation exactly. Review cannot override missing evidence or partial-group failure. | Unchanged approved review must apply. An unrelated change outside the command's captured dependencies is a companion against unnecessarily global invalidation. Witness approval before intervention and actual consumer rejection. Mutate skipped context checks, approval replay or stale completion. |
| P3-U3 / TC-ACT-03 | A: 0→1; concurrent U/V Undo A: 1→0. Exchange; reviewed Redo U gives R: 0→1. Redo V now proposes no change; dismiss it. Undo R gives S: 1→0; Redo S gives T: 0→1. F0–F3. | Both U/V retained; no-op attempt adds no action and consumes no sibling. R/S/T have actual inverse edges/values; competing family remains reviewable. Dismissal leaves opposite applicable command and ordinary edits available. | Single compensation family automatically traversable when safe. Witness no-op V followed by successful reviewed Undo R and Redo S. Mutate no-op action, sibling coalescence, wrong inverse target or cross-direction dead end. |
| P3-U4 / TC-ACT-03 | After joined U/V, author independent X, then Undo/Redo X. Separately compare independent X causally after U against X concurrent with U; repeat after X is undone/redone. | Old-family fork alone does not force review of safe X commands. Causally later independent X suppresses the earlier redo branch even after X's compensation; concurrent X preserves alternatives. Scope ancestry does not manufacture compensation-family membership. | Same action in unrelated scope leaves requested scope intact. Witness successful independent-family continuation while old fork retained. Mutate scope-wide ambiguity, suppression based only on active effects or receipt-time ordering. |
| P3-U5 / TC-ACT-03, TC-ACT-05 | Concurrent Undo of one Delete creates fresh R1/R2 with equal values. Review Redo of R1's compensation; Undo that Redo creates R3; Redo its actual compensation. Exchange/reopen after each transition. | R1/R2/R3 distinct identities; first Redo deletes only R1, leaving R2; subsequent inverse maps to R3, never N or R2. Old Delete/retirement and exact restoration provenance survive; Recently Deleted exclusion follows those records. | Single restore chain plus equal-valued unrelated birth. Witness the three fresh IDs and each exact inverse mapping. Mutate body-based birth coalescence, stale original UUID or sibling deletion. |
| P3-U6 / TC-ACT-04, TC-CAP-02 portable records | Two-note named action: one stale/invalid/unsupported member. Separately encode validated partial native compensation across two saved-edit groups, then reopen and continue coarse Undo/Redo of the remaining effect. | Named action applies wholly or not at all. Partial-native records preserve actual before/after and coverage per group; remaining saved effect is not duplicated as a whole-group Undo. Redo reverses the actual partial compensation. | Whole valid group and complete native coverage companions. Witness failure after the first valid member is checked, and nonzero remaining effect after partial coverage. Mutate member omission, whole-group coverage or redo of the original full edit. Actual AppKit attribution remains a later integration gate. |

### 4.5 Progress, evidence and resource gates

| ID / contracts | Fixture and schedule | Independent observations | Companion, witness and mutation |
| --- | --- | --- | --- |
| P3-X1 / TC-LIMIT-02, TC-DUR-06 | A real merge/copy/compensation envelope needs two exact prerequisites; deliver child first, race last parent against parking, postpone validation with finite saves, then stop interference without another delivery or restart. Separately restart while ready work is pending. Apply F2/F4/F5. | Both prerequisites required; durable wakeups survive restart. In the uninterrupted variant, eligible work resumes and materializes on its own. Missing/rejected prerequisite reports the correct blockage and preserves input; unrelated ready work proceeds. Lost required accepted evidence blocks editable success, unlike rebuildable rows. | Complete valid closure with both budget settings. Witness actual parking, each missing prerequisite, resumed work and successful result. Mutate missed wakeup, one-of-two readiness, swallowed recovery failure or rejection propagated as descendant invalidity. |
| P3-X2 / TC-LIMIT-01–02, TC-MERGE-01 | Exact text/label boundary fixtures plus growing valid ancestry/frontiers; two-sided 10,001-LF-token merge and equal/one-sided long input; run allowed smaller work budgets. | Two-sided over-limit merge requires review while history remains valid. Supported equal/one-sided values follow their specified path. No dropped parent, arbitrary lifetime cap or silent truncation; representation overflow has an explicit specified outcome. Record real decoding/memory/work measurements. | Below/at/above finalized limits with valid authenticated companions. Witness expensive path and yields. Mutate off-by-one limit, review-as-invalid classification, truncated frontier or budget-as-rejection. Rich encoders/attachments remain outside this increment. |

## 5. Required connected lifecycles and three-writer cases

Focused rows do not replace these full production-path schedules. At every arrow,
capture the observations from §2, not only the final values.

| Lifecycle | Concrete sequence and expected terminal state | Required cuts and constituent rows |
| --- | --- | --- |
| L1: merge, edit, Delete, recover | L/R → editable merged Current → local E → remote Delete D → crash → reopen both. In the observing variant E→D, N is absent and E historical only. In the concurrent variant E ∥ D, N is absent and uncovered E is preserved. E must carry both merged inputs in either case. | M1/A1/D1; F0/F1/F2; kill after D acceptance before materialization and after E commit before callback. Compare accepted records as well as source/copy values. |
| L2: temporary preservation becomes independent work | D0 ∥ E → display automatic E copy → admit P editing it → receive D1 observing E → complete P → crash/reopen → deliver P to peer already holding D1. P survives as independent work; untouched companion retracts. | D1/D2/D3; also test P admission between retraction preparation and its B5 publication fence. Fail P's first commit and retry exact bytes. Separate variant terminates after successful commit before callback. |
| L3: reciprocal copy and later source work | Reciprocal L/R copies → durable dispositions → settle local pins → Delete one completed copy → crash/reopen → new source T → peer delivery. Original remains; deleted copy stays deleted; dispositions persist; T's uncopied conflict attention is computed independently. | C1/C2/D3; callback loss during first copy and second failure during current-row catch-up. Include a changed candidate before initial completion as a separate retry variant. |
| L4: compensation, overlap, review, inverse | A changes Shopping→Groceries. Undo A gives U: Groceries→Shopping. A remote X based on A, concurrent with U, changes Groceries→Errands. Deliver X and use a valid fixture where actual Current is Errands. Reviewed Redo U records R: Errands→Groceries. U remains an unchosen head; R returns to the common base, so the ordinary one-sided merge settles Current to Shopping, representing U/R. Undo R therefore records S: Shopping→Errands; Redo S records T: Errands→Shopping. | U1–U4; acceptance/materialization/callback/restart cuts. Check each exact action's actual before/after separately from the subsequently reduced Current. R must not implicitly dispose of U. X's concurrency preserves U for review; the ordered-X companion suppresses its earlier redo. Also deliver X only after compensation admission to challenge its pending completion. The separate U1 ordered-chain fixture tests preservation of the older redo tail. |

Use three writers for (1) L/R merge preparation with independent T before publish,
(2) D0, E→D1, and F extending E concurrently with D1, and (3) two concurrent
compensations plus independent X observing their joined history. These add distinct
causal shapes; a third passive receiver alone would not test them. Author on real
independent stores with selectively delivered exact prerequisites, not fabricated
receiver timestamps. Add the third writer's sealed bytes to the same fault/oracle
machinery; avoid multiplying every two-writer test by an irrelevant third store.

## 6. Bounded enumeration and anti-vacuity gates

Implement hand-authored rows first, then enumerate within each fixture's fixed
action graph. Default small histories contain at most six user actions beyond
bootstrap, two subject notes plus a sentinel, and two writers. The longer
compensation/lifecycle rows use their explicitly listed finite action sequence;
record its bound separately rather than truncate it. Protocol history is unbounded;
these are test sizes, not production limits.

For each small graph enumerate offered-envelope delivery permutations, including
child-before-parent receipt. Sweep one relevant interference and one crash across
the applicable cuts. Select committed-history/current-lag and parked-ready traces
for a second failure during recovery. Sweep exact duplicates and equivalent
repackaging at each semantically distinct receive state. Keep the full Cartesian
product for genuinely small fixtures only; report exhaustive dimensions separately
from selected combinations. Apply F4/F5 to representative complete merge,
preservation, copy and compensation lifecycles, not just ordinary actions.

Seeded generation follows those deterministic tests. Generate valid causal graphs,
declared note/scope edges and complete actions before perturbing one property.
Save the full choices, actual IDs, envelopes, delays, fault ordinals and outcomes;
a seed alone does not reproduce nondeterministic scheduling/identifiers. Shrinking
must retain the targeted contested transition and semantic failure. Record emitted,
executed, excluded and completed schedule counts plus each exclusion reason.

Every qualification run must establish:

1. **Supported positive path:** required tests discovered and a valid companion
   actually accepts, updates Current and reopens. Unsupported/early setup rejection
   cannot satisfy a positive feature gate.
2. **Reachability:** event assertions prove the row's contested state existed
   before interference, then the intended transition was attempted. For a stale
   publication test, preparing nothing and publishing nothing proves nothing.
3. **Independent correctness:** exact intermediate and final expectations from
   §2, including unchanged sentinel/other fields, retained alternatives and pending
   work. Final peer agreement is an additional check.
4. **Mutation sensitivity:** each named defect fails the intended assertion after
   required discovery and path witnesses; compilation/setup failures, an unrelated
   failure or an unexpected timeout do not qualify. Accept a timeout as progress
   evidence only with the named unmet obligation and blocked-work trace.
5. **Progress after quiescence:** once finite inputs/faults stop and required
   dependencies/storage are available, existing scheduling finishes eligible work.
   Do not generate another provider event, approval or local edit to make it finish.
   No test assumes eventual user consent or provider disclosure of hidden objects.
6. **Recovery distinction:** unsupported semantics, missing required evidence,
   corrupt required state, invalid derived rows and ordinary parked work have
   distinct expected outcomes. A test never weakens semantic checks for a platform.

Use ordinary-client/same-module construction probes for new checked evidence and
same-type/wrong-context tests at its real consumer. Keep test-only controls outside
release interfaces. Run debug and optimized portable suites, canonical independent
fixtures, schema checks and targeted mutation campaigns. Reuse the existing driver
and process probe; add discovery/hook assertions there rather than a parallel harness.

## 7. Model correspondence and deliberate remaining boundaries

| Test rows | Model source of schedules | Concrete obligation added |
| --- | --- | --- |
| M1–M3, A1, L1 | `SegmentMergeSafety`, action/scope rules | Exact LF/record IDs, complete encoded scope, editable current cells and final consumers. Model fields abstract text; its `accepted` can include pending local work. |
| D1–D3, L2 | `SegmentDeletionOrderingSafety`, `SegmentDeletionSafety` | Actual acceptance/crash cuts, copy identity/retirement, writer-evidence validation and pending-generation fence. Ordering model assumes durable accepted input. |
| D4, U5 | `SegmentActionRecoverySafety`, `ConcurrentUndoExecutionSafety` | Exact restoration-entry provenance and Recently Deleted derivation. The models do not assert the entire list-exclusion predicate. |
| C1–C3, L3 | `NVConflictCopySafety` | Exact selected-revision payload binding, usable-copy evidence, slots, real atomic acceptance and ordinary reopen; model assumes complete installation. |
| U1–U6, L4 | `CausalUndoRules`, `PortableCausalUndoSafety`, `ConcurrentUndoExecutionSafety`, `ReviewedUndoSafety`, `CompensationOverlapBridge`, `NativeUndoSpanSafety`, `NativeCausalUndoBridge` | Actual values/inverse records and complete byte/SQL/recovery paths. Scope parents and compensation links remain separate. Native coverage records do not prove AppKit attribution. |
| X1, F1–F5 | SQLite/durability, validation-resumption and rejection families listed in [TLA README](../../tla/README.md) | Compose the already-tested local storage boundaries with each newly supported semantic action, rather than assume ordinary-action tests cover every reducer. |

This matrix neither extends a model's proved state space nor claims a full
refinement between adjacent models. Keep each model's effective configuration,
runner mutation/witness expectations and stated fairness assumptions with its
evidence. Rerun or extend TLA+ when modeled behavior changes or a concrete failure
exposes an unmodeled policy interaction; documentation and test planning alone
require no rerun. A faithful counterexample calls for a spec review, not a weakened
assertion. A modeling error must be corrected with the intended safety claim intact.

Phase 3 qualifies portable semantics through the production local runtime.
Physical plaintext replacement/removal, provider discovery/upload, Apple-member
resolution, actual conflict/History UI, native undo attribution and input-method
behavior retain their later platform/application gates. No portable copy or Undo
test counts as an Apple resolution test. No derived retraction or historical
receipt grants authority to unlink a present file. Retain these caller obligations
in the conformance strategy's G3 work; do not simulate them as automatic success
inside a phase-3 result.

## 8. Implementation order and completion record

The [connected report](phase3-validation.md) is the completion/qualification map
for the implementation steps below. It preserves the distinction between
exhaustive small-graph delivery dimensions and selected crash/competing-work
schedules, and identifies each unavailable platform explicitly.

1. Connect merge/equal results to canonical current/action state and public edit
   capture; qualify M1–M3/A1, then L1 with observed/concurrent deletion as support
   becomes available. Freeze independent bytes before writing each new record.
2. Complete deletion/preservation/retirement and broader restoration: D1–D4,
   L1–L2. Add the actual automatic-birth edit and stale-retraction consumer tests.
3. Complete source choices, conflict copy and general history recovery: C1–C3,
   L3. Preserve their distinct action meanings and repeat identities.
4. Complete portable candidate/compensation execution: U1–U6 and L4, including
   command-relative review, actual inverses and partial-coverage codecs.
5. Apply X1/X2 and the selected repeated-recovery combinations to those connected
   paths; finish generated schedules and cross-platform qualification.

Each completed row must link a record with: source revision/toolchain/profile;
test names and actual schedule count/bounds; fixture IDs/digests; independent
expected/observed tables; hook/path witnesses; crash/fault class and ordinals;
child-process output; mutation ID, intended assertion and observed verdict; and
any unqualified platform or remaining integration boundary. Link the record here
and from the phase-3 implementation report. Until that record exists, a row is a
planned obligation, not completed coverage.

Phase 3 exits when all supported-scope rows and L1–L4 have those artifacts, ordinary
fresh reopening yields the expected editable state, every critical mutation is
detected or explicitly explained by independently verified equivalent protection,
and no unsupported reducer is being used as a passing substitute. Failures preserve
their traces and block the relevant feature gate until the implementation or,
where genuinely necessary, the reviewed specification is corrected.
