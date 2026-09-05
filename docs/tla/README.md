# iCloud Drive TLA+ models

Start with [Proposal 5 coverage and model disposition](Proposal5-Coverage.md) for the newest segment design. It identifies the highest-priority properties, new checks, shared components, and current proof boundaries. These are bounded checks, not a whole-implementation refinement proof.

Models abstract envelope bytes and bounded decoding. The adopted dictionary-free
zstd provider profile is checked by executable codecs, independent fixtures and
malformed-frame tests, not by a TLA+ compression proof. Changing the unreleased
compression tag's encoding does not change modeled acceptance/retention actions.
See [Encryption](../impl-proposal-5/Encryption.md#compression-profile).

The [whole-active-set audit](Storage-Protocol-Audit.md) adds a critical compound-property checklist, independently reproduced errors and remaining end-to-end gaps. It explains why checking recorded intent or finding one successful trace does not establish the actual result in every execution.

The adopted [specification](../iCloud-Drive-Support-Spec.md), ADRs and proposal 5 use immutable history. Retired models, configurations, results and provenance are isolated in the [archive](retired/impl-proposal-4/README.md); they are not active segment coverage. Do not load that archive during routine specification or implementation work. Do not apply its shared-checkpoint/current-file authority rules to segment collections. Proposal 5 changes NV history storage, not Apple's API guarantees: there is still no globally complete provider disclosure, portable Apple version identity, reverse-provider root recovery, or upload-qualified durability.

## Reading model names against the specification

Start with the grouped [glossary](../../CONTEXT.md) and the protocol's [graph/lifecycle reading guide](../impl-proposal-5/Protocol.md#reading-the-terminology). A variable name is local to its model, not a substitute for the production contract. In particular:

| Model name | Meaning in that model | Boundary when reading the spec |
| --- | --- | --- |
| `materialization` in [ImmutableSegmentDurabilitySafety](ImmutableSegmentDurabilitySafety.tla) and [SegmentDeletionSafety](SegmentDeletionSafety.tla) | Represented-input abstraction of a derived current view whose loss must not erase retained changes | Not its concrete row encoding or a requirement to store all history in current rows; never authoritative shared history |
| `accepted` in [SegmentMergeSafety](SegmentMergeSafety.tla) | Dependency-linked reducer input; receipt can advance it before prepared-view publication, and `EditDerived` adds a pending local edit before `PersistEdit` completes | Not a proof that every member has crossed the spec's accepted-history durability/pin barrier |
| `durable` and `applied` in [SegmentDeletionSafety](SegmentDeletionSafety.tla) | `durable` can contain an installed incoming child awaiting parents; `applied` also includes immediate pending local admissions | Stored objects need not yet form a complete closure; live admission need not yet be durable. `Apply` and `Recover` enforce their respective closure rules |
| `Publish` in [SegmentMergeSafety](SegmentMergeSafety.tla) and [SegmentBootstrapSafety](SegmentBootstrapSafety.tla) | Prepared live-view/startup publication | Atomic model publication, not cloud upload |
| `Publish` in [ImmutableSegmentDurabilitySafety](ImmutableSegmentDurabilitySafety.tla) and [SegmentDeletionSafety](SegmentDeletionSafety.tla) | Adding an immutable object to modeled provider availability | Provider publication, not proof that every peer received it |
| `Parents` versus `NoteAnc`/`editParents` in [SegmentMergeSafety](SegmentMergeSafety.tla) | Operation knowledge versus note supersession | Known alternatives are not automatically replaced by ordinary Current edits |
| `parents`, `target`, `Root`, `Leaves` in [CausalUndoRules](CausalUndoRules.tla) | Action-scope ancestry, compensation targets, initial family action and terminal compensation-family members | Neither filesystem roots nor note heads; scope ancestry and compensation ancestry answer different questions |
| `Required` and `pin` in [RepositoryRepairSafety](RepositoryRepairSafety.tla) | Finite required object evidence and private loss-detection state; local repair commits the pin before activation | Not proof of pin byte encoding, arbitrary acceptance/crash composition, or globally complete remote history |

The [SQLite key/backup/salvage checks](../impl-proposal-5/plan/sqlcipher-validation.md#adopted-key-backup-and-salvage-follow-up)
test native inputs to repair, not a refinement of this model. Its `pinned` →
`active` step maps to a reopened verified sibling database followed by the durable
selected-store-record cutover; that concrete crash mapping remains an integration
gate. Password-free recovery uses no Keychain/secret sidecar. Full `.recover`
output is not trusted committed history. The 2026-09-13 focused repair rerun passed
all 49 configured outcomes; see [Verification](../impl-proposal-5/Verification.md).

Read each model's `Init`, actions, checked properties and runner configuration together. The table describes intended/safe actions; mutation configurations deliberately violate particular guards. A finite scalar, token or supplied valid graph stands for the evidence stated in that model's assumptions, not an Apple guarantee inferred from its name. Separate models do not automatically compose into a stronger proof merely because they use the same word. The [coverage map](Proposal5-Coverage.md) and [verification boundaries](../impl-proposal-5/Verification.md#what-these-checks-do-not-prove) identify the remaining bridges.

## Retained identity experiments — not proposal-5 acceptance proofs

[`UUIDAssociationLab.tla`](UUIDAssociationLab.tla) compares association and deletion-intent rules across copies, stripped attributes, restoration, and observationally indistinguishable inputs. The [association experiment report](UUID-Reconciliation-Experiments.md) records counterexamples, conditional rules, and missing evidence. This is not the adopted import classifier.

[`CausalIncarnationSafety.tla`](CausalIncarnationSafety.tla) separately tests fresh birth tokens, observed-remove causal context, delayed deletion, and crash recovery against an overwritable metadata register. Its [metadata experiment report](Incarnation-Metadata-Experiments.md) connects these rules to live xattr/copy/replacement probes and the consumer/provider API boundary. Birth association and local durability are inputs to this small model, not proved by it; complete-exchange agreement is not unconditional provider convergence. The shared runner's `--only Causal` option selects its 12 checks.

The two-Mac follow-up adds a concrete `currentSnapshot` comparison to `UUIDAssociationLab` (`--only currentSnapshot`), plus [`DeletionIntentTransportSafety.tla`](DeletionIntentTransportSafety.tla) (`--only DeletionIntent`). The former never reads the lab's `proof` input: it compares item IDs only within one verified local observation frame and explicitly defers independent cross-host imports. Its passing checks are not cross-host alias convergence. The latter assumes already-correct birth binding and tests independent source/artifact delivery, receipt durability, artifact purge, restoration, and one crash. Its purged-before-observation witness rules out claiming guaranteed intent discovery. These experiments share the runner; the [follow-up report](Incarnation-Metadata-Experiments.md#two-mac-follow-up-measured-binding-and-intent-transport) records actual API observations, test corrections, proof boundaries, and retained artifacts.

The [protocol-combination report](Protocol-Combination-Experiments.md) compares three further experimental models. [`LiveBindingHandshake.tla`](LiveBindingHandshake.tla) tests actual nonce/message transitions, copies between steps, local endpoint fences, and explicitly relayed transcripts. [`BindingIntentComposition.tla`](BindingIntentComposition.tla) instantiates those transitions and feeds their result into deletion/receipt/restoration/recovery rules; binding and lifecycle execution are deliberately phased, and its local summary is not a segment-history implementation. [`IntentRetirementLab.tla`](IntentRetirementLab.tla) tests acknowledgment gaps, collection, newcomers, and restored-backup rejoining; its passing pinned-bootstrap policy requires an independently selected complete snapshot reference. Use `--only LiveBinding`, `--only BindingIntent`, or `--only IntentRetirement`. These investigative models do not establish unconditional automatic identity discovery or bounded total metadata. The report separates safety, conditional progress, negative controls, and the unresolved product/authority choices.

Three further [co-add policy experiments](CoAdd-Policy-Experiments.md) compare the deferred simultaneous-import idea without adopting it: [`CoAddIntentLab`](CoAddIntentLab.tla) separates observable matching from fresh-create intent, [`CoAddSlotLab`](CoAddSlotLab.tla) compares filename occupancy-event/release tokens, and [`CoAddLateHistoryLab`](CoAddLateHistoryLab.tla) tests imports against delayed causal deletion, explicit restoration, pending review and crash recovery. Those three contribute 112 checks. Identical-observation fixtures retain the false-join and stale-echo/restoration trade-offs. The slot allocator assumes a valid finite occupancy history; it is not composed with claim recording or the late-history model. Its added FSEvents controls reject a raw rename hint as logical release authority and local event IDs as a shared slot token; the report includes separate macOS 14/26 compiled replay observations. Co-add remains disabled.

[`CoAddRevalidationLab`](CoAddRevalidationLab.tla) adds the [historical-hint follow-up](CoAdd-Policy-Experiments.md#historical-hints-and-revalidation--coaddrevalidationlab): full inspection, history-first ordering, hint priority and restart-on-hint rules with asymmetric delivery, safe-save/return-rename false alarms, replay gaps and scope races. `--only CoAddRevalidation` selects its 133 checks; `--only CoAdd` includes all 245 checks across the four co-add labs. It distinguishes a bounded pass ending from successful association, and candidate ordering from a latency improvement. Its finite accepted episode history and exact validation boundary are inputs; no occupancy writer or physical-identity proof is added. Prefer the state/action and result tables in the report before interpreting its safety, UX, temporal and negative-control runs.

The [external-import follow-up](External-Import-Policy-Experiments.md) compares the now-adopted narrow automatic-import/repair rule with rejected/deferred alternatives; it does **not** enable co-add. [`ExternalImportPolicyLab`](ExternalImportPolicyLab.tla) compares 22,528 threshold rules over 63 fixtures, plus composite policies; its survey is a decision table, not a distributed protocol. [`ExternalImportAdmissionLab`](ExternalImportAdmissionLab.tla) instantiates its targeted predicate and connects it to two-host import, late history/Delete, local durability, dependency parking, races and one crash. `check-uuid-experiments.py --only ExternalImport` selects both, including controls and late-duplicate/wait-resume witnesses. Wider policies remain experiments. `ProjectionStampSafety` checks eligibility before automatic birth and preservation of any admitted identity. Read the [adoption/coverage record](../impl-proposal-5/Verification.md#external-file-admission-and-pending-recovery--adopted-policy), not survey counts as measured user preferences.

The pending-file checks follow the [concrete commit/recovery contract](../impl-proposal-5/Protocol.md#pending-file-commit-and-recovery-records) in four small modules:

| Module / runner filter | Boundary checked |
| --- | --- |
| [`ExternalFileLifecycleSafety`](ExternalFileLifecycleSafety.tla) / `external-file` | Latest versus frozen input, reservation/admission/history/receipt, UI closure, repeat scans and up to two crashes. Recovery clears its volatile file frame; fresh evidence precedes receipt settlement. A later Delete does not erase an Import. Separate classifier fixtures reuse `ExternalImportPolicyLab`; this is one tracked pending item, not global path/body deduplication. |
| [`PendingReferenceSafety`](PendingReferenceSafety.tla) / `pending-reference` | One two-payload reference replacement, separate payload barriers, old/new complete metadata recovery at one crash, independent frozen ownership and cleanup. Installer checks are contracts, not a filesystem or codec proof. |
| [`ExternalAssociationSafety`](ExternalAssociationSafety.tla) / `association` | Equal/Keep Current/Use File/two-field merge, two competing choices, separate admission/seal/pin/projection/receipt, changed input/root, unrelated head and Delete. Fixed Current/base and scalar values; no arbitrary text or complete causal reducer. No crash is inlined here. |
| [`ProjectionTransitionSafety`](ProjectionTransitionSafety.tla) / `projection-transition` | A→B→C edit/rename/format intent, exact file/root verification, source accounting, delayed publication and exact-generation clearing. Accepted B can retire A without clearing intended C. Physical replacement/source validation are inputs; restart reconstruction is an integration gate. |

These are complementary boundary checks, **not** an `INSTANCE` composition or end-to-end refinement with the entire two-host bridge. Durable records, volatile claims/consent and audit-only evidence are distinct. Negative controls remove real ordering/fencing conditions; witnesses require actual values/receipts, including merged independent fields and recovery after two crashes. Read [Verification](../impl-proposal-5/Verification.md#pending-file-completion-checks--2026-09-08) for executed results and remaining production gates.

The older identity-policy labs are experiments, not acceptance proofs. Positive file association is a conditional input, not a newly assumed Apple API. The adopted segment protocol supplies committed identity and causal ancestry without inferring physical identity for independent external imports; the targeted import and pending-file models above check only their stated adopted slices.

Run the hypotheses, assertion-specific mutations, and non-vacuity witnesses with:

```sh
python3 docs/tla/check-uuid-experiments.py \
  --java /path/to/java --jar /path/to/tla2tools.jar
```

An expected counterexample rejects that hypothesis; it does **not** mean the policy is safe. The runner requires exhaustive completion for passing assertions and the designated failure for counterexamples. Logs and traces remain in a fresh temporary directory. See the report before interpreting any green result.

## Private SQLite transaction and fast-start mapping

[`SQLiteCollectionSafety`](SQLiteCollectionSafety.tla) connects staged SQL writes,
atomic history/private-state acceptance, captured current-row materialization,
durable ready work, retained preview/import identity, fresh physical association
and two crashes. An independently ordered peer applies the same finite history.
`check-segment-models.py --only sqlite-collection --timeout 900` selects four
safety scenarios, twelve assertion-specific mutations and five reachability
witnesses. The [transaction validation report](../impl-proposal-5/plan/sqlite-collection-transaction-validation.md)
records actual completion results, the ready-queue correction, compiled SQLite/
SQLCipher crash tests and the remaining production boundaries. No claim of a
completed check should be inferred merely from its presence in the inventory.
The report is the single source for current per-scenario state counts and runtimes.
Remote SQL transactions are atomic actions while Import's writes remain expanded;
focused cases expand the remote transactions. Controls must fail their named
assertion and witnesses must reach their designated outcome.

The [LocalStore contract](../impl-proposal-5/LocalStore.md) now adopts the SQLite
mapping; the [Phase 2 adapter audit](../impl-proposal-5/plan/phase2-platform-and-type-audit.md) records its implemented subset and concrete model mapping. SQL atomicity and validated complete objects are
inputs; actual filesystem association is outside that transaction. Independent
expected-value assertions check the fixed graph. No fairness, `VIEW`, symmetry,
state or depth constraints are used. It does not prove arbitrary merges,
multi-operation action decoding, power-loss behavior or the whole Swift adapter.

[`SQLiteFastStartSafety`](SQLiteFastStartSafety.tla) refines returning current-row
startup: acceptance versus materialization, consistent capture, a rebuild epoch,
one crash/reopen, known damage and final editable-publication fencing. Three
batches create two notes, delete one and update only the other's authoring
context. Independent expected rows check the incremental update. Run
`--only sqlite-fast-start`: one exhaustive safe case (**1,015 states**), five
designated mutation controls and three reachability witnesses. The
[validation report](../impl-proposal-5/plan/sqlite-fast-start-validation.md) records
21 real-SQL checks using the implementation DDL, including consistent readers,
no old-history reads on healthy startup and multi-parent ready work. The cache
format, builders, batch tokens, changed-birth log and pruning floors are removed.

Physical page locality, per-cell compression and the optional read-ahead candidate
are tested by the [clean-quit executable experiments](../impl-proposal-5/plan/clean-quit-locality-strategy.md),
not proved by these logical models. A physical hint cannot establish represented
history or replace consistent SQL capture; its presence/absence changes I/O only.
The adopted [opportunistic full-VACUUM policy](../impl-proposal-5/plan/clean-quit-locality-strategy.md#adopted-opportunistic-full-vacuum-policy)
must preserve these logical states. Its writer admission, cancellation/settling,
space-failure behavior and performance over subsequent edit cycles remain
executable qualification gaps, not properties established by the SQLite models.

Read the earlier per-file private installation/pin actions in durability, repair
and external-recovery models as **abstract surrounding obligations**, not the
new concrete SQL transaction cuts. Provider/projection file barriers remain real;
the removed private object-file/pin-file gap must not be recreated in Swift just
to match an old model. Neither SQLite model is a formal refinement of all those
models or an authentication/reducer proof. Provider snapshot authentication/closure and private current-row correctness
remain separate validation boundaries; neither is a packed startup cache.

## Proposal 5 segment coverage — adopted design

### Compound recovery and compensation bridges

`--only bridge-` selects three bounded, inlined protocol bridges. They carry the
same observations, history operations or file generations across component
boundaries; they do not claim an `INSTANCE` refinement of the complete storage
implementation. The [verification record](../impl-proposal-5/Verification.md#three-compound-bridges--2026-09-08)
documents assumptions, deliberately broken variants, crash-cut witnesses and
executed results.

| Model / narrower runner filter | Connected behavior |
| --- | --- |
| [ExternalRecoveryBridge](ExternalRecoveryBridge.tla) / `bridge-external-` | Latest versus frozen preview ownership; competing Local State pin/reference/settlement replacements; Import, association Put or neutral repair; two crashes; peer causal/concurrent Delete; repeat-scan identity. |
| [ProjectionRecoveryBridge](ProjectionRecoveryBridge.tla) / `bridge-projection-` | Durable B/C intent and peer history; captured A→B→C file transitions; compare-after-replace and retained displaced bytes; source cleanup; receipt publication; restart; delayed Delete and fresh restored occupant. |
| [CompensationOverlapBridge](CompensationOverlapBridge.tla) / `bridge-compensation-` | Shared causal candidate rules author actual Undo/Redo/inverse records; same-note remote overlap, disjoint title edit, competing Undo or observing edit; separate admission/install/pin/ack; delayed receipt and restart. |

Safety has no fairness premise. Only the compensation convergence cases assume
eventual processing of finite admitted/delivery work; no user approval is fair.
Positive current-file association and checked installation remain stated
contracts, not physical-identity or Apple API proofs. In particular, replacement
can install NV bytes **and** preserve unexpected displaced bytes for reconciliation;
it is not an atomic compare-and-swap against unrelated writers. A historical
receipt cannot authorize source deletion after restart.

[`ImmutableSegmentDurabilitySafety.tla`](ImmutableSegmentDurabilitySafety.tla) separates local sealing, single-writer transaction staging, atomic SQLite acceptance and callback delivery, exact pending generations, materialization loss, crash recovery and independent provider publication. Its stable payload is the committed history, not a private segment-file directory. [`SegmentDeletionSafety.tla`](SegmentDeletionSafety.tla) checks two established note births across two hosts, explicit causal deletion versus concurrent edit preservation, fresh restoration, dependency-closed application/restart, and expected-original-only physical removal. These check [proposal 5](../impl-proposal-5/README.md), whose durable local segments replace the separate mutable WAL. Separate files are projection inputs/outputs, not the authoritative history transport.

Run `python3 docs/tla/check-segment-models.py --java /path/to/java --jar /path/to/tla2tools.jar`. The default runner contains 554 cases, including shared components, the undo/window/repair families, 16 projection-stamp checks and 75 checks across the four pending-file families above, plus 64 compound bridge checks and 21 SQLite transaction checks and 9 focused fast-start checks. This is the runnable inventory, not a claim that every family was rerun in the latest edit. `--only sqlite-collection`, `--only bridge-`, `--only bootstrap`, `--only action`, `--only merge`, `--only nv-copy-`, `--only ordering`, `--only stamp`, `--only external-file`, `--only pending-reference`, `--only association`, `--only projection-transition`, `--only repository`, `--only repair-`, `--only portable-`, `--only undo-`, `--only undo-execution-`, `--only review-`, `--only shared-view-`, `--only file-` and `--only local-lane` isolate families. All positive merge scenarios check safety plus rank/progress obligations on their full graph; `--full-temporal --only merge-converges-third --timeout 900` additionally runs the expensive direct three-head convergence check. The [results and boundary report](../impl-proposal-5/Verification.md#model-results) records actual outcomes, state counts, timeouts, fairness and unmodeled work. A green expected counterexample rejects that policy or reaches its named witness; it is not a safety proof of a broken rule.

[`SegmentActionRecoverySafety.tla`](SegmentActionRecoverySafety.tla) checks complete action-record/note-value persistence, guarded undo/redo, fresh restoration, crash, peer delivery and peer eligibility after receiving complete compensations. [`SegmentMergeSafety.tla`](SegmentMergeSafety.tla) checks concrete two-field values and actual finite ancestry, ambiguous bases/third heads, stale prepared publication, explicit edit provenance and conditional convergence. Neither claims exact native typing undo or proves arbitrary text merging. [History-rule reference checks](../impl-proposal-5/Verification.md#executed-history-rule-reference-checks) exercise the LF kernel in Python; codec, UI and actual file/segment bridges remain necessary.

Recently Deleted's default-list exclusion after a durable Restore is a derived UI/index rule, not an asserted list-membership property in these models. Fresh-birth restoration and atomic action persistence provide adjacent coverage; exact source-entry provenance, restart/remote index rebuild and delete-after-restore visibility need the [restored-entry integration cases](../impl-proposal-5/Verification.md#required-history-feature-integration-matrix). Do not interpret retained deletion history as a requirement to keep a restored row visible, or the existing model passes as proof of the new list predicate.

[`NVConflictCopySafety.tla`](NVConflictCopySafety.tla) checks the adopted representation-only NV Save as new note policy: source-head selection is independent of completed copy dispositions, while unresolved attention excludes only exact copied revisions. Two hosts author reciprocal copies, deliver records independently, settle temporary differing Current pins and recover one crashed host. Separate cases extend the source or modify/delete a completed copy. `--only nv-copy-` runs 5 positives (including conditional transport/recovery progress), 7 mutation controls and 5 witnesses. Positive graphs finish at 816–1,336 states, without constraints/cutoffs. The [result/boundary report](../impl-proposal-5/Verification.md#nv-conflict-copy-disposition--adopted-policy) records evidence and required UI/codec tests. Valid payload binding and complete local installation are assumed; this is not Apple disposition, slot-allocation, arbitrary merge or full installer/UI composition coverage.

[`NativeUndoSpanSafety.tla`](NativeUndoSpanSafety.tla) checks two saved spans' exact remaining effects through partial native undo/redo, asynchronous capture/completion and one crash; native commands do not continue after recovery. [`UndoHistoryHandoffSafety.tla`](UndoHistoryHandoffSafety.tla) checks old-index/new-action ordering on one already-selected causal branch, refused commands, guarded remote/current-value compensation and note/derived-position recovery. Its remote input is a value/frontier invalidation, not the complete portable candidate set. These **integration experiments** assume correct native span attribution and a complete local barrier. They are not AppKit models or an `INSTANCE` bridge to peer transport. The [two-OS experiment report](../impl-proposal-5/Native-Undo-Experiments.md) separates confirmed call sequences, candidate UX compromises and required actual-editor tests. `--only undo-handoff-` and `--only undo-spans` together run 8 positives, 12 mutations and 9 transition-specific witnesses; `--only undo-` also includes the execution family below. No arbitrary text rebase is claimed.

[`PortableCausalUndoSafety.tla`](PortableCausalUndoSafety.tla) checks two hosts deriving Undo/Redo from the same validated action graph despite independent delivery/index order. Per-scope causal parents order candidates; separate compensation edges identify actual Undo/Redo targets. Concrete expected-ID tables check walking backward, repeated Undo/Redo, retained redo sequences, competing compensation branches, command-relative ambiguity after an independent edit, suppression by an independent causal descendant, scope isolation and private-state rebuild. `--only portable-` runs 25 positives, 10 mutations and 9 witnesses across twenty-one finite scenarios. Safety has no fairness premise; four progress checks assume eventual fixture delivery, indexing/rebuild and invocation. Invoke selects a candidate without executing its note-value compensation. The shared reducer is exercised dynamically below; production decoding/native routing remain integration gates, and equal-history agreement alone is only consistency, not an independent semantic oracle.

[`ConcurrentUndoExecutionSafety.tla`](ConcurrentUndoExecutionSafety.tla) imports the same pure [`CausalUndoRules.tla`](CausalUndoRules.tla) reducer and uses its results to author actual finite note/action changes. Two hosts can undo A concurrently; the joined history continues through reviewed redo/undo/redo or an independent edit/undo/redo. Separate scenarios cover a no-op sibling, distinct restoration births, and an incoming other-note edit invalidating review or surviving pending completion. Prepare/approve/admit/encode/complete-install/ack, parked receipt/application, and one crash/recovery are separate transitions. Independent concrete-value/candidate assertions, exact-admission/recovery/presentation action properties and completion witnesses prevent a selection-only or success-flag claim. `--only undo-execution-` selects 5 positives, 9 mutations and 9 witnesses. The sole temporal check assumes eventual local settlement/recovery and dependency delivery/application; no user approval is fair. Finite request plans, one joined intervention point, scalar/birth operations and an abstract complete installation barrier keep the graph bounded without depth/state constraints. This bridges candidate selection to effects in that scope, not arbitrary text, native multi-family coverage, actual codecs/filesystem operations or a refinement of every adjacent model. Read [Verification](../impl-proposal-5/Verification.md#what-these-checks-do-not-prove) before extending the claims.

[`ReviewedUndoSafety.tla`](ReviewedUndoSafety.tla) checks the adopted distinction between command review and explicit history/conflict actions. One scalar replacement and its inverse retain actual before/after values, an older redo tail and an unaffected scope. Preview/cancel, note/stack/root invalidation, local write/install/completion and one crash are separate transitions. `--only review-` selects 6 positives, 12 mutations and 8 witnesses. Command scenarios preserve the old redo tail; new-action scenarios clear only their scope's eligibility. Inverse checks require the actual pre-approval Current rather than the original action value. Admission/presentation assertions compare pre/post transitions, not a success flag. Local settlement fairness never forces user approval. The remote/local changes are already-durable inputs before approval; another edit during pending compensation, fresh-birth/bulk review, actual codecs and a post-restart reopened UI remain separate integration gates. This is no generic native-undo, text-merge or conflict-disposition proof.

[`SegmentBootstrapSafety.tla`](SegmentBootstrapSafety.tla) now distinguishes complete import, read-only snapshot preview, independent page/root delivery, foreign evidence, a retained local tail and private settings independent of materialization rebuild. The durability/deletion models now name that derived state `materialization`, not `checkpoint`; it is neither required Local State nor legacy authoritative history. Actual Local State codecs/key cutover, Finder-visible `NV Data` and complete materialized backups remain concrete/model gates. No model assumes globally complete provider disclosure.

[Initial-bootstrap Swift checks](../impl-proposal-5/plan/remaining-storage-validation.md#initial-bootstrap-validation)
connect actual envelopes, exact references, complete initial action groups/scope
frontiers, Genesis/ImportComplete and all snapshot rows. They exercise concrete
parts of this model's validity assumptions; they do not prove local installation,
tail application, final startup publication or arbitrary-history refinement.
The initial-only validator is not called on healthy current-row startup.

The ordinary-conflict scenario in `SegmentMergeSafety` deliberately lets an edit know both heads while replacing only Current; separate causal and note-predecessor graphs prevent implicit resolution. [`SegmentDeletionOrderingSafety.tla`](SegmentDeletionOrderingSafety.tla) fixes the source DAG D₀ concurrent with E→D₁, optionally extended by E→F concurrent with D₁, and explores both observers' deliveries/publications plus independent copy edits and a view restart. It rejects sticky temporary copies, per-Delete unions, overbroad descendant suppression and erased independent work. Its accepted history is already durable; it complements rather than replaces the installer/crash model.

[`ProjectionStampSafety.tla`](ProjectionStampSafety.tla) independently varies current bytes, stamp and retained history. It checks waiting for referenced evidence, exact/unique association, and preservation of explicit Imports; hashes/schema/root fences are assumptions to verify in concrete callers. [`RepositoryCopySafety.tla`](RepositoryCopySafety.tla) copies a captured available inventory including historical/deleted and unimported data with no source private store. Its progress mutation rejects a private-state prerequisite; its retention mutation rejects current-only export. Neither model proves actual xattr transport, Finder behavior, filesystem atomicity or globally complete history. The spec's copy scope is the available repository, not all application state.

[`RepositoryRepairSafety.tla`](RepositoryRepairSafety.tla) separates observable provider/private damage from presumed cause and splits exact-copy construction, verification, private pinning and activation. Eighteen finite scenarios include disclosure during an already editable session and positively disclosed newer/unmaterialized provider evidence to missing/partial/inaccessible/foreign provider data, root replacement, missing/partial/unreadable/unwritable private data, complementary copies and shared loss. Its controls reject a manual top-level `NV Data` restore gate, Work Offline for generic failure, foreign overwrite, incomplete/fabricated claims, stale-root use, provider-gated ordinary editing, revoking active editing on disclosure, incremental republishing before complete local repair, and destructive local repair. The repair union, positive disclosure classification, exact-byte validation, permission results and retained frontier are trusted finite inputs; actual filesystem/API tests remain required.

[`SharedNoteViewOwnershipSafety.tla`](SharedNoteViewOwnershipSafety.tla) is the entry point for shared-window ownership: view prepare/admit versus observer/render callbacks, note-bound undo, detach/close-all/reopen, committed state versus a marked draft, and asynchronous local capture/recovery. `--only shared-view- --timeout 300` runs 4 exhaustive checks, 9 mutation controls and 8 witnesses. The largest full graph has 2,056,617 states; scenario splitting bounds routing and composition separately without state/depth constraints. Native attribution, actual input-context completion and complete imported remote state are explicit inputs. Its composition scenario tests the separate-snapshot adapter only: it does not require that production mechanism, model normal focus transfer, or prohibit every alternative draft-recovery design. Retain its note/action-agreement assertions; do not promote adapter-specific coverage into a platform contract. Its command cursor is not a caret or serialized native stack. Read it alongside the span/handoff, review and action/recovery models, not as their formal composition. The [shared-window report](../impl-proposal-5/Native-Undo-Experiments.md#shared-window-follow-up) connects each tested obligation to concrete probes and remaining NV integration work.

## Shared current-file and durability components

These five modules remain active because their focused guards do not depend on mutable journal storage. Run them through `check-segment-models.py`; the [coverage map](Proposal5-Coverage.md) and [verification report](../impl-proposal-5/Verification.md) define their limits.

| Model | Active contract and boundary |
| --- | --- |
| [CurrentVisibleReconciliationSafety](CurrentVisibleReconciliationSafety.tla) | Equal complete catalogs around captured current files; root/model fences, selected-input representation and exact dirty-generation consumption. It does not assign physical identity, implement content merging, or decide the modern external-deletion preference. |
| [SeparateFileDeletionSafety](SeparateFileDeletionSafety.tla) | Exact accepted-incarnation removal only after local command durability; preserve replacement files. Recording omission/retirement grants no physical authority. Identity/absence are supplied observations, not conclusions from a filename. |
| [UnresolvedVersionResolutionSafety](UnresolvedVersionResolutionSafety.tla) | Exact local note/copy durability plus exact file installation before selected/snapshot-scoped Apple disposition; partial failure, retired copy slots and later arrivals. `pendingHistoryDurable` is an abstract complete segment/action/parent barrier. Setter-time evidence does not require copies to remain live afterward. Slot allocation, retirement encoding, restart and UI scheduling require concrete tests. |
| [CrossMachineConflictDispositionSafety](CrossMachineConflictDispositionSafety.tla) | Two observers with independent local generations and selected-member scopes. One host cannot supply another's local completion or consume a later member. This is not composition with note transport, actual file installation or the whole resolver. |
| [LocalDurabilityLaneIndependence](LocalDurabilityLaneIndependence.tla) | Per-admitted-edit local staging/barrier progress under local weak fairness while provider work can remain stalled forever. No provider fairness or particular storage format is required. |

Apple disclosure is not a complete history. An unreadable member cannot be chosen; Save resolves only its selected member, Use only applicable captured members. No model grants version removal. Dismissal, bounded background retries, automatic retry on re-presentation and fresh generation checks remain [resolver integration requirements](../impl-proposal-5/Verification.md), not consequences of a boolean durability gate.

## Environmental assumptions and implementation obligations

The models assume the exact inputs named in their own boundaries: validated immutable values and causal ancestry, complete scoped catalogs, current root/store/generation evidence, truthful local durability/installation results, and applicable Apple member snapshots. They do not prove those API, codec or filesystem facts. Missing evidence disables only the dependent success transition; it cannot be manufactured from elapsed time, callbacks, labels, upload state or path similarity.

Current [Apple API contract validation](../Apple-API-Contract-Validation.md), [safe replacement](../Foundation-Safe-Replacement-Migration.md) and [production integration gates](../impl-proposal-5/Verification.md) supply the concrete obligations. In particular, descriptor locking/ownership, exact byte readback, causal closure/pin durability, selected-member setters, cryptography, real crash recovery and AppKit behavior require implementation tests. Safety assumes no cloud fairness; temporal results depend only on the explicitly configured fairness and finite bounds. Separate model passes do not compose into a whole-implementation proof.

The [whole-set audit addendum](../impl-proposal-5/Verification.md#whole-active-model-audit--2026-09-08) records the strengthened result assertions and added races. `--only shared-catalog` and `--only shared-apple-` now exercise all three formerly unwired shared components, including their designated mutations. `SegmentDeletionSafety` adds full transitive recovery and `orderedRestore`/`mixed` scenarios; `CrashHost = 0` permits both hosts to crash in one execution. `SegmentDeletionOrderingSafety` adds known-but-unchosen E alongside F replacing H. Repair adds separate mid-copy provider-root, provider-source and private-store invalidation cases. These additions do not connect real Apple verification queries, actual file installation or every lifecycle failure into a single proof.

Every positive deletion configuration also checks the [finite rank argument](Storage-Protocol-Audit.md#conditional-convergence-check-the-argument-not-only-the-outcome) on its full graph, without narrowing `Next`. `FairSpec` uses aggregate pipeline fairness; `PerActionFairSpec` retains the original per-action premise. `--only mixed-both-converge` remains a direct `EventualAgreement` check in the default inventory, even when an execution exceeds the time limit. A completed safety/rank run does not turn that unfinished direct temporal run green. `--only reject-stallDelivery` checks the rank premise and direct divergence separately, with rank assertions absent from the temporal negative control.
