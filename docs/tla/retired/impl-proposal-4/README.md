# Retired proposal-4 TLA+ models

These files are historical comparison material, **not current acceptance tests or implementation authority**. Start with the [active model guide](../../README.md) for the adopted segment design. Do not load this archive for ordinary proposal-5 work.

## Archive scope and running

The [archived validation index](Test-and-Validation-Index-Archived.md) lists every
retired module/configuration and runner case with its historical command and
document references. Active project coverage has its own index outside this archive.

Moved on 2026-09-08: 17 unchanged modules and 20 unchanged configurations, plus the baseline runner. Sixteen modules belong exclusively to the retired persistence/lifecycle/decision suite; `UUIDAssignmentRace` additionally depends on mutable checkpoint reconciliation and old-UUID WAL replay. Its 58 original experiment cases now live in `check-uuid-assignment.py`, outside the active experimental runner. All archived `INSTANCE` dependencies are colocated. No model or configuration was deleted or weakened.

The five storage-independent component models remain in the active directory. Some descriptions below mention their historical role; that text is not their current contract. Epoch-4 opening/export support remains required, but preserving these models does not create a proposal-4 compatibility requirement.

From the repository root:

```sh
python3 docs/tla/retired/impl-proposal-4/check-migrated-models.py \
  --java /path/to/java --jar /path/to/tla2tools.jar
python3 docs/tla/retired/impl-proposal-4/check-uuid-assignment.py \
  --java /path/to/java --jar /path/to/tla2tools.jar
```

The first runner retains 67 checks of nine baseline/bridge models. The second retains only the retired assignment experiment. Other archived configurations can be run using the baseline recipe below. Expected counterexamples remain negative controls or witnesses, not positive safety proofs. Archived results are historical unless a dated rerun is explicitly recorded; moving files does not expand those proofs.

## Archive-move validation — 2026-09-08

All 17 moved modules and 20 configurations are byte-identical to their pre-move working-tree versions. The remaining models/configurations are unchanged except for one shared-model comment removing an obsolete composition reference. All 52 modules pass SANY parsing/semantic analysis with dependencies resolved from their own directories. All 362 segment-runner cases are unchanged; the original 525 experimental cases are preserved exactly as 467 active plus 58 archived cases.

Selected TLC checks produced all 131 expected outcomes: 58 archived assignment cases, 27 archived bridge/broken-handoff/witness cases, and 46 active association cases. The rest of the archived 67-case baseline runner was not rerun for this move. Logs under `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`: `notation-tla-retired-uuid-ms4lkxfv`, `notation-tla-migration-check-btsztuno`, and `notation-tla-uuid-2neqrzg8`. A preliminary concurrent active run failed to find a temporary TLC standard module; it is excluded, and the complete active slice passed with an isolated `java.io.tmpdir`. These checks validate relocation/runner behavior, not new product semantics.

Python syntax, TLA-related Markdown targets/anchors, and `git diff --check` pass. `./build.sh` completed with the existing Xcode environment warnings. No production app behavior changed.

## Retired model disposition

| Module | Reason for retirement / reusable idea |
| --- | --- |
| `ReconciliationDecisionSafety` | Retain as proposal-4 baseline only. Its unconditional external-absence result, checkpoint bases and abstract fuzzy merge are **not** the proposal-5 external confirmation/causal merge policy. Extract guards/oracle patterns, not the old reducer. |
| `JournalLifecycle` | Retain baseline; extract directory ownership, burned identities and positive association, not fresh-WAL-header/recovery-cleanup admission. |
| `QuitSafety` | Retain baseline; extract single close owner, external-edit draining and callback fencing. Retire shared-checkpoint retry/WAL cleanup from proposal-5 claims. |
| `StorageTransitionSafety` | Retain baseline; reuse source-preserving cutover/independent credentials, not a checkpoint/WAL pair as new-history authority. |
| `StartupSafety` | Retain baseline; its provider-current checkpoint, format rebuild and fresh-WAL gate are superseded for segment collections. New bootstrap model replaces only the documented startup slice, not every legacy choice. |
| `CurrentCheckpointNoteMergeSafety` | Retire from proposal-5 proof set; shared mutable-checkpoint note merge is absent. Retain as retired-baseline comparison evidence only. |
| `CrossMachineCheckpointContentionSafety` | Retire from proposal-5 proof set; two closing writers' mutable checkpoint CAS is absent. Retain baseline regression coverage. |
| `CrossBoundaryDurabilitySafety` | Retire checkpoint/WAL-cleanup composition from proposal-5 claims. Exact-generation/crash obligations transfer to segment checks; retain baseline. |
| `CrossMachineRestartRecoverySafety` | Retire provider-current checkpoint/WAL composition from proposal-5 claims. Segment replay is a different authority rule; retain baseline. |
| `CrossMachineCurrentVisibleSafety` | Retire as a proposal-5 end-to-end model. Independent current-file/checkpoint delivery is not segment transport; its preservation ceilings remain relevant contrast evidence. Retain baseline. |
| `MultiRoundCrossMachineSafety` | Retire as a proposal-5 end-to-end model. Its repeated-round and host-loss scenarios should inform future segment bridges, not be relabeled as segment delivery. |
| `LocalWALSafety` | Retain legacy/proposal-4 durability and cleanup checks only. No active mutable WAL in segment collections. |
| `JournalRecoverySafety` | Retain legacy/migration valid-prefix and mismatch recovery; not modern segment replay. |
| `MultiJournalRecoverySafety` | Retain legacy/migration recovery with independent WAL orders; not global segment ancestry. |
| `ReconciliationDurabilityBridge` | Retire from proposal-5 proof set; its executable `INSTANCE` imports really are old decision/WAL/startup actions. Keep those baseline checks connected. |
| `StorageStartupBridge` | Retire from proposal-5 proof set; its checkpoint/key artifact handoff is not the new segment/local-state/cache layout. Keep baseline. |
| `UUIDAssignmentRace` | Retain design experiment: independent external imports and conflicting IDs remain relevant; checkpoint/WAL settling modes are not v5 acceptance tests. |

## Earlier inventory audit

The audit compared all pre-existing `.tla`/`.cfg` files with git. The 28 tracked modules and 31 tracked configurations were exact `HEAD` content before this work. They are recoverable in commits `4d42084` (proposal-4/component work), `03b88db` (identity experiments), or `57b36adf0c0a801c75116debfb9b3c9f73e5eb72` (the old lane pair). The proposal-5 files were untracked working-tree work and must not be deleted on a git-history assumption.

Each module's same-named `.cfg` has the same disposition; the three additional current-visible configurations are called out below. Runner-generated negative/witness configurations are temporary and reproducible, not additional source models.



## Relocated baseline guide

The following guide is preserved from the former active README. References to “current,” “modern,” requirement IDs, and acceptance checks in this section describe **proposal 4 at the time**, not today's spec. Shared-model descriptions can predate their segment adaptations.

## Retired proposal-4 baseline and shared components

| Model | Scope |
| --- | --- |
| `CurrentVisibleReconciliationSafety` | Complete current catalogs around selected current-file reads; root/model invalidation; representation of every selected visible input; exact dirty-generation consumption; conservative retry. |
| `SeparateFileDeletionSafety` | Shared exact-incarnation removal after an admitted deletion's local durability barrier; external-versus-NV removal origin, replacement preservation, fresh-UUID import, and no removal authority from snapshot omission/retired metadata. |
| `UnresolvedVersionResolutionSafety` | User-invoked operation-local unresolved snapshots; deterministic saved copies, retired deleted copy identities, and current-note choices; exact local WAL/file installation before snapshot-scoped resolution; partial retry and later arrivals; no provider-version removal. |
| `CurrentCheckpointNoteMergeSafety` | No-write checkpoint-current mismatch; complete note-set/base-relative-deletion reconciliation; monotonic retired deterministic identities; exceptional whole-union retirement WAL durability and base-mismatch recovery; ignored competing settings; exact-current retry rejection after another replacement. |
| `CrossBoundaryDurabilitySafety` | Two successive local generations across out-of-order WAL/file completion, checkpoint-current contention, merged/recovered-input settlement across crash/restart, one exact retry, and directory-durable WAL cleanup. |
| `CrossMachineRestartRecoverySafety` | Two-host current-file/checkpoint ordering with one local decision and crash per host; host-local WAL survival; provider-current restart reconstruction; exact recovery-file/checkpoint settlement; fresh-WAL editing gate. |
| `CrossMachineCheckpointContentionSafety` | Two hosts closing from one predecessor; `C0`→`C1`→joined `C2`; no-write current-change handling; whole-union version-8 retirement durability; crash/restart; same-byte current-version invalidation. |
| `CrossMachineConflictDispositionSafety` | Two hosts concurrently snapshotting and disposing unresolved members; shared deterministic identity with host-local candidate reuse; selected-only versus snapshot-wide resolution; independent exact local source/copy generations; later arrivals and intervening edits. |
| `CrossMachineCurrentVisibleSafety` | Two-host composition of independently delivered current note files and checkpoints; conditional concurrent-edit preservation and the measured delete/edit current-visible ceiling; exact-current checkpoint writes; monotonic propagation of retired deterministic identities; bounded single-round concurrent-edit convergence. Four configurations isolate those concerns. |
| `MultiRoundCrossMachineSafety` | Causal decision-token accounting for two hosts and two edit rounds each; independent note-file/checkpoint delivery; settled-file checkpoint publication; conditional displaced-current preservation; permanent loss of one host after its durable work is provider-published. |
| `LocalWALSafety` | One self-describing host-local WAL; admitted/appended/durable stages; settled note files; exact local checkpoint coverage; crash/restart; WAL deletion only after verification and Application Support directory durability; provider stall independence. |
| `LocalDurabilityLaneIndependence` | Shared weakly fair local staging/barrier progress while provider work may remain permanently stalled; renamed from `JournalLaneIndependence`. |
| `JournalRecoverySafety` | Ordered valid-prefix replay, exact-base versus mismatch semantics, v8 retirement, already-represented cleanup, checkpoint omission of ordinary deletions, and uncertain-evidence retention. |
| `MultiJournalRecoverySafety` | Independent per-WAL order, per-note preservation, delete/edit decisions, mismatched v8 retirement, complete checkpoint coverage and local cleanup. |
| `StartupSafety` | Checkpoint/materialization/offline choices, explicit creation, detached rebuild/format choices, cancellation ownership, exact-current installation, and fresh-WAL editing gates. |
| `JournalLifecycle` | Two local directory-lock contenders; retention through moves/authority changes; positive recovery association; burned IDs; header/directory durability; immutable headers across moves; provider-independent local durability and authority fencing. |
| `QuitSafety` | Callback/final-external-edit draining, checkpoint metadata versus header-only cleanup, single-use close attempts, one automatic exact-current retry, merged settlement, override and directory-lock release after observer teardown. |
| `StorageTransitionSafety` | Old-contract checkpoint, stable plaintext export, Save-As bootstrap, independent target credentials, exact cutover, crash-surviving checkpoint/key pairs, and fresh-WAL publication. |
| `ReconciliationDecisionSafety` | Independent current-file outcome oracle for body/rename/deletion/association cases; trustworthy bases; preservation independent of unrelated deterministic recovery candidates; rejection of stale prepared decisions. |
| `ReconciliationDurabilityBridge` | Instantiated decision/WAL/startup actions with actual UUID-qualified payload handoffs; partial durability, checkpoint omission, crash/reopen, and fresh-WAL admission. |
| `StorageStartupBridge` | Instantiated storage/startup actions; reopen actual crash-surviving checkpoint/key pairs, root-local WAL recovery, Save-As separation, and provider-format compatibility. |

The following mapping uses the **retired proposal-4 meanings** of the requirement IDs, not the current specification's registry. The [disposition table](../../Proposal5-Coverage.md#model-inventory-and-disposition) determines each component's limited proposal-5 applicability:

- `DISC-01` and `PUB-01`: `CurrentVisibleReconciliationSafety`, with physical deletion refined by `SeparateFileDeletionSafety`.
- `REC-01`: `UnresolvedVersionResolutionSafety`, with two-host concurrent disposition refined by `CrossMachineConflictDispositionSafety`.
- `CKPT-01`: `CurrentCheckpointNoteMergeSafety`, with two-host current contention, crash/restart, and version-8 retirement composition refined by `CrossMachineCheckpointContentionSafety`.
- Cross-host composition of `PUB-01`, `CKPT-01`, and displaced-body input to `REC-01`: `CrossMachineCurrentVisibleSafety`, with repeated bounded rounds and host loss refined by `MultiRoundCrossMachineSafety`.
- `START-01` and `DUR-01`: provider-current startup plus host-local recovery are composed in `CrossMachineRestartRecoverySafety`; local generation/checkpoint/cleanup boundaries remain in `LocalWALSafety`, `LocalDurabilityLaneIndependence`, and `CrossBoundaryDurabilitySafety`.
- `CLEAN-01`, `AUTH-01`, `ROOT-01`, and `WAIT-01` retain implementation/API refinements described below; no model manufactures those environmental facts.
- The seven lifecycle/decision models expand local record replay, startup admission, creation, closing, storage cutover, and current-file decisions. These are separate bounded checks, not machine-checked refinement links to the composition models.

## How to read the retired baseline and its shared components

Most modules are independent bounded checks. The first four arrows below remain abstract interfaces, not machine-checked refinement links. The final two are executable bridges: they use `INSTANCE` to run selected existing actions and check concrete model-payload handoffs across them. They do not establish a whole-spec refinement hierarchy or compose the imported modules' fairness assumptions.

| Focused boundary | Composition path |
| --- | --- |
| `CurrentVisibleReconciliationSafety` + `SeparateFileDeletionSafety` | → `CrossMachineCurrentVisibleSafety` → `MultiRoundCrossMachineSafety` |
| `CurrentCheckpointNoteMergeSafety` + `CrossBoundaryDurabilitySafety` | → `CrossMachineCheckpointContentionSafety` |
| `LocalWALSafety` + `LocalDurabilityLaneIndependence` + `CrossBoundaryDurabilitySafety` | → `CrossMachineRestartRecoverySafety` |
| `UnresolvedVersionResolutionSafety` | → `CrossMachineConflictDispositionSafety` |
| `ReconciliationDecisionSafety` + `LocalWALSafety` + `StartupSafety` | → `ReconciliationDurabilityBridge` (executable payload bridge) |
| `StorageTransitionSafety` + `StartupSafety` | → `StorageStartupBridge` (executable artifact bridge) |

For a change to the retired baseline, start with the leftmost affected focused model and then follow its composition path. For the adopted design, start with the proposal-5 coverage map instead. If a behavior crosses rows, assume no model proves that joint interaction unless a boundary section below says so; implementation and integration/crash tests must establish the link.

## Running the retired-baseline/shared configurations

Use a released `tla2tools.jar`:

```sh
for model in \
  CurrentCheckpointNoteMergeSafety \
  CrossBoundaryDurabilitySafety \
  CrossMachineRestartRecoverySafety \
  CrossMachineCheckpointContentionSafety \
  MultiRoundCrossMachineSafety \
  LocalWALSafety \
  JournalRecoverySafety \
  MultiJournalRecoverySafety \
  StartupSafety \
  JournalLifecycle \
  QuitSafety \
  StorageTransitionSafety \
  ReconciliationDecisionSafety \
  ReconciliationDurabilityBridge \
  StorageStartupBridge
do
  java -XX:+UseParallelGC -jar /path/to/tla2tools.jar \
    -workers auto \
    -lncheck final \
    -coverage 60 \
    -metadir "/tmp/notation-tlc-$model" \
    -config "docs/tla/retired/impl-proposal-4/$model.cfg" \
    "docs/tla/retired/impl-proposal-4/$model.tla"
done

for config in \
  CrossMachineCurrentVisibleSafety \
  CrossMachineCurrentVisibleDeleteEdit \
  CrossMachineCurrentVisibleRetirement \
  CrossMachineCurrentVisibleConvergence
do
  java -XX:+UseParallelGC -jar /path/to/tla2tools.jar \
    -workers auto \
    -lncheck final \
    -coverage 60 \
    -metadir "/tmp/notation-tlc-$config" \
    -config "docs/tla/retired/impl-proposal-4/$config.cfg" \
    "docs/tla/retired/impl-proposal-4/CrossMachineCurrentVisibleSafety.tla"
done
```

Every configured invariant/property must pass, every action enabled by that configuration's scenario must have nonzero coverage, and each state queue must reach zero. A simulation-only success is not a proof.

The seven migrated models and two bridges also have executable assertion-specific negative controls and reachability witnesses:

```sh
python3 docs/tla/retired/impl-proposal-4/check-migrated-models.py \
  --java /path/to/java --jar /path/to/tla2tools.jar
```

The stdlib-only runner first exhaustively checks each model and rejects unexercised top-level actions, then mutates disposable copies. A negative control passes only when its designated assertion finds a counterexample; parse/evaluation errors, timeouts, and undetected mutations fail the run. Bridge controls can mutate an imported module as well as the handoff. Seven unmodified-model witness runs deliberately assert that important terminal paths are unreachable and must produce a trace reaching them; they prove possibility, not eventual progress. Source models remain untouched. Logs, traces, state counts, and a JSON manifest remain in a fresh temporary directory. `--model NAME` selects one model and its controls. The default 120-second per-run timeout is a resource limit, never a correctness rule or TLC state constraint.

## Model boundaries

### Current-visible reconciliation

The model begins after Foundation has returned one complete first catalog and immutable current-file inputs. Catalog equality is an opaque equality result, not a revision number. A provider callback may change the catalog/dirty generation before or after the second observation. A positively verified same-root move is stuttering; an authority change replaces the root-session incarnation and invalidates captured work. Failure to establish positive root continuity disables commit; root-unavailable UI and explicit session termination remain outside this transaction model.

The model checks only current files. It contains no `other`, unresolved, or nonlocal traversal role and no provider-version resolution state. The concrete implementation still must establish candidate association, exact byte reads, merge-base trust, `NVMergedText` output, filenames, Unicode/case behavior, and the visible conflict matrix through deterministic/integration tests. In particular, volume-qualified document IDs and session-only file IDs are optional unique equality witnesses: the model does not assume they survive eviction, rematerialization, replacement, or restart. Their absence/change must exercise the conservative filename/content/import fallback.

This model gives no current file a UUID identity and grants no deletion authority from filename, content, timestamp, or missing filesystem identity. `SeparateFileDeletionSafety` below refines the physical deletion decision; concrete tests still must establish the real identity witness and coordinated revalidation. General removal records are host-local WAL evidence only and disappear after verified checkpoint coverage; the model does not require a provider deletion watermark.

Negative controls must fail when a commit omits catalog equality, root-session equality, structural/note equality, selected-input representation, or serviced-generation equality.

### Physical separate-file deletion

`SeparateFileDeletionSafety` fixes one original note, one accepted file incarnation, one replacement incarnation, and one fresh UUID. It explores logical deletion before and after external removal, same-name replacement, or recreation. Removal is enabled only while the accepted incarnation is still current; an already-absent file completes without removal, while a mismatch preserves the visible replacement and imports it under the fresh UUID. The state records whether absence came from the modeled external environment or NV's exact accepted-incarnation delete. Temporal action properties require checkpoint omission and deterministic-identity retirement to preserve the complete physical-file state.

The external-removal origin is an abstract environmental classification, not an inference NV may manufacture from a missing path or provider result. The model does not establish how Foundation identity evidence is obtained, whether a provider reports it truthfully, or concrete filename/body equivalence. Those remain API-contract and integration tests. Removing the exact-incarnation guard, making checkpoint omission remove a file, or making retirement remove a file must falsify the corresponding invariant or action property.

### Explicit unresolved-version disposition

The model intentionally assumes no completeness for `providerVersions`. Presenting the embedded resolver from the alert badge snapshots whatever Apple disclosed for one visible file. New arrivals remain outside that snapshot and survive its disposition. An unreadable member cannot be selected.

**Save as new note** maps one source UUID plus canonical body to one deterministic base recovery identity and may resolve only its selected member after an exact reusable slot is both WAL-durable and installed. Title, labels, names, provider identity, and slot allocation are outside the state abstraction. **Use this version** may change the current body only through the explicit choice transition and may resolve captured snapshot members only after the chosen current-note generation is WAL-durable and exactly installed. Per-member resolution can stop early to model partial setter failure; a fresh unresolved query leaves those members and later arrivals selectable.

`removedVersions` never changes. The model needs no checkpoint, upload state, provider-version recovery ledger, or provider identifier archive. It models deletion of a saved copy before resolution by retiring its deterministic identity; that identity cannot be reused in the abstraction. Concrete slot allocation selects the next nonretired deterministic UUID, and exact-base WAL recovery plus the checkpoint's compact retired set makes retirement persistent. The model abstracts exact note generations and candidate integrity into per-disposition WAL/file gates: an edit or deletion before resolution disables the concrete install gate, while ordinary edit/deletion after confirmed resolution is outside the model. The implementation must compare concrete UUID, canonical body, generation/LSN, installed-file evidence, and retired-set membership rather than treating UUID equality as the gate.

Swapping between `LinkingEditor` and `ConflictResolverView` is stuttering state outside this safety model. Dismissing the resolver does not cancel an admitted operation; concrete waiting/error state is per member, background retry is finite per attempt, re-presentation automatically reactivates parked attempts without duplicating running ones, no explicit Retry action exists, and a later source edit must invalidate a pending **Use this version** exact-generation gate. These UI/liveness refinements require integration tests, not another resolution transition or persistent ledger.

Negative controls must fail if resolution precedes either local gate, a saved disposition resolves a different member, a current choice resolves a later arrival, a current body changes without an explicit choice, identical saved states receive different identities, or any provider version is removed.

### Cross-machine unresolved-version disposition

`CrossMachineConflictDispositionSafety` fixes two hosts, two disclosed members, and one resolver operation per host. The second member may arrive before or after either host's snapshot. Both hosts may concurrently choose **Save as new note**, **Use this version**, or **Current** against independent host-local source notes and saved-copy candidates. Saved copies for the same member derive the same deterministic recovery identity, while each host must reuse and verify its own exact candidate generation; those local generations are neither shared nor compared across Macs. An intervening local candidate edit parks only the stale disposition rather than authorizing resolution. Each **Use this version** operation likewise advances and validates only its host-local source generation, so one Mac's choice cannot make another Mac's independently valid local choice stale.

The shared provider-member sets abstract Apple's eventual unresolved/resolved state, while source bodies, candidate bodies, generations, edits, and installation gates are host-local. Subsequent current-file publication, conflict creation, delivery, and reconciliation are owned by `CrossMachineCurrentVisibleSafety`; this model does not silently serialize them through shared local state or claim to prove their joint composition. It also does not claim that Apple returns a complete history, persist provider identifiers, model the resolver view/retry scheduler, or replace the more detailed single-host partial-failure and retired-slot checks in `UnresolvedVersionResolutionSafety`. It checks the cross-host disposition-authority boundary: **Save as new note** changes only its selected member, **Use this version** changes only members in its operation snapshot, later arrivals survive an older snapshot, resolution is monotonic, and provider history is never removed.

Negative controls must fail if save resolution occurs before the installed-copy stage, exact local candidate reuse increments its generation, one host's choice mutates another host's source, use resolution consumes a later arrival, a modified copy remains valid evidence, or the source body changes outside an explicit choice or later ordinary edit.

### Checkpoint-current note reconciliation

The model begins after `NVCheckpointTransaction` has rejected an expected-current mismatch without writing and has returned an exact immutable snapshot of the canonical current checkpoint. It treats the retained accepted checkpoint, frozen complete live note set, and captured complete current checkpoint as three immutable inputs. An abstract `Absent` decision is a deletion only relative to base membership; it is represented in pending WAL work but omitted from material checkpoint records. The merge represents every non-base local and captured-current note decision, including delete/edit preservation, and unions the branches' retired deterministic identity sets before deterministic allocation. Competing settings are never imported.

Every newly published representation must become WAL-durable and its separate-file obligation must settle before a fresh checkpoint attempt. Only on this `NVCheckpointInstallCurrentChanged` path, the entire merged retired set is also reasserted durably in the host-local WAL before retry; ordinary deletion of a deterministic conflict note still appends only that note's version-8 record. Reasserting the union is required because the accepted and captured checkpoints may each formerly have been the only durable source for part of it. The attempt names the captured current version as its exact predecessor. A later current replacement may expose a concurrent retired set that omits captured entries; it disables commit and remains a no-write result. The focused recovery step unions the durable assertions without applying deletion, modeling positively associated base-mismatch recovery after a crash.

The abstraction conservatively preserves both sides of unsafe concurrent record changes rather than modeling `NVMergedText`. Concrete trusted-base classification, the specification's automatic conflict-preservation identity vectors, note decoding, publication on the main thread, and duplicate later separate-file delivery remain implementation tests.

The no-write mismatch condition is an action property over the transition's actual pre/post checkpoint-written state; it is not a witness maintained by the mismatch action. Negative controls must fail if mismatch writes, competing settings are imported, a non-base note/deletion decision is unrepresented, a deletion record is materialized in the checkpoint, any merged retirement lacks WAL durability before retry, base-mismatch recovery loses an asserted retirement, or a changed current version satisfies the retry.

### Cross-boundary durability composition

`CrossBoundaryDurabilitySafety` composes exactly two cumulative local note generations and three checkpoint incarnations. It permits an older WAL completion after the newer generation is pending, an older separate-file completion after the newer generation is admitted, a first checkpoint-current mismatch, WAL/file settlement of the captured current input, an exact retry, a second checkpoint replacement, and crash/restart around both that settlement and Recovery Journals directory synchronization. A crash before verification reconstructs the first incomplete merge/WAL/file phase from the then-current checkpoint plus the surviving local WAL; it cannot turn that work into a fresh uncontended checkpoint write. Settlement progress is reused only while the captured current version still equals provider Current; a changed current version restarts the aggregate settlement. Those aggregate bits stand for recovery-derived note, removal, and version-8 retirement obligations, not redundant journaling of every unchanged note loaded from an accepted checkpoint. A second mismatch enters a terminal rejected phase for that root-closing operation; a later user Retry is a new operation outside the model.

The stale-WAL and current-changed no-write conditions are temporal properties over the actual actions, rather than witness sets maintained by those same actions. The model otherwise abstracts WAL bytes, record coalescing, note bodies, Foundation replacement outcomes, and operation scheduling; it is not a proof of arbitrary generation counts or multiple concurrent notes. Concrete crash-point and byte-level tests remain required. Removing exact pending-generation matching, writing on current-changed, forgetting recovered-input settlement on restart, entering retry before merged-file installation, allowing crash loss of a still-linked durable WAL, or reporting closed before Recovery Journals directory durability must each falsify its corresponding property or invariant.

### Cross-machine startup and restart recovery

`CrossMachineRestartRecoverySafety` fixes two hosts, one source-decision token and at most one crash for each host, and two file/checkpoint writes per host. Current note-file delivery and reconciliation are independent of checkpoint publication. A crash discards volatile live and uncaptured pending work but preserves the host's durable Application Support WAL. Restart captures only provider Current `Notes & Settings`, unions its exact complete note set with the surviving local WAL, settles a differing recovery file state, and exposes editing only after an exact current checkpoint outcome and a fresh WAL. A checkpoint change during recovery is a no-write recapture; prior settlement can be reused only if the captured checkpoint and exact file version still match.

Decision tokens deliberately abstract bodies, deletions, preferences, individual WAL records, and `NVMergedText`. Provider checkpoints are not routine cross-device database input in this model: they are consumed by startup or written under exact-current closure. Durable decisions in this model remain in a host-local WAL or a monotonic checkpoint, so this configuration neither assumes nor checks Apple's displaced-Current retention; `CrossMachineCurrentVisibleSafety` owns that conditional branch-preservation check. The model proves no provider fairness or physical persistence and does not replace byte-level crash-point tests.

Negative controls must fail if a crash drops a durable WAL token, a checkpoint publishes with an unsettled file or undurable pending WAL, current-change handling writes, recovery completion accepts a stale file/checkpoint version, or an editable restart exposes no fresh WAL.

### Cross-machine checkpoint-current contention

`CrossMachineCheckpointContentionSafety` fixes two hosts closing from one checkpoint predecessor, one note-decision and one version-8 retirement assertion per host, one crash per host, and at most three checkpoint versions. The first exact-current writer may install `C1`; the loser captures `C1` without writing, unions both complete branches and retired sets, WAL-durably reasserts the union, settles the aggregate file obligation, and may install joined `C2` only against that exact captured version. A same-state replacement changes only the checkpoint version so TLC checks that byte equality cannot reuse stale settlement. A crash clears volatile merge state, while restart reconstructs from provider Current plus every surviving local note and retirement assertion.

The initial local decision and retirement assertion are already durable, and file settlement is an aggregate gate; record bytes, automatic-preservation UUID allocation, base-relative deletion, settings, directory synchronization, and individual note-file writes remain in the focused models and concrete tests. This model checks cross-host composition of their interfaces rather than duplicating those state spaces.

Negative controls must fail if current-change or stale-retry paths write, retry precedes whole-union retirement durability or exact-version file settlement, restart drops a durable retirement assertion, or a descendant checkpoint omits an already published decision or retirement.

### Cross-machine current-visible composition

Four configurations share one transition system while keeping body races and deterministic-identity retirement out of each other's state spaces. They fix exactly two hosts, three body values, one deterministic identity, and at most two checkpoint writes per host. Each body scenario admits one source-note change per host before either note-file or checkpoint publication, so it covers a mutually stale, shared-base race rather than repeated or fresh-then-stale edit rounds. `CrossMachineCurrentVisibleSafety.cfg` checks two edits, `CrossMachineCurrentVisibleDeleteEdit.cfg` checks a deletion racing an edit, `CrossMachineCurrentVisibleRetirement.cfg` checks retirement propagation, and `CrossMachineCurrentVisibleConvergence.cfg` checks the bounded convergence property described below. `MultiRoundCrossMachineSafety` separately covers two edit rounds and one permanent host loss; `CrossMachineRestartRecoverySafety` separately covers bounded cross-host crash/restart. Arbitrary note, host, or round counts and byte-level WAL internals remain outside these composition models.

Current note-file delivery/reconciliation and checkpoint observation are separate actions, so TLC explores both relative orders; another delivery or observation of the same generation is stuttering. A successful coordinated publication and the writer's accepted view are one atomic abstraction because the implementation exposes no safe intermediate publication state. Lower-level WAL, replacement, verification, and retry phases remain split in their focused models. A checkpoint write is enabled only when the writer's expected generation still names the exact provider current checkpoint and its accepted snapshot agrees. `CheckpointWritesUseExactCurrent` is a regression postcondition; the exact-current guard plus the joined-branch and canonical-retirement invariants carry the preservation argument.

`EvidenceBodies` is intentionally global: it unions both hosts, provider Current, Apple-reported unresolved bodies, and the checkpoint. In the concurrent-edit configurations, branch recoverability therefore means that some replica or provider representation retains each admitted branch, not that every host has already imported it. The delete/edit configuration represents source-UUID omission separately from bodies; omission is absence from a complete checkpoint, not a serialized tombstone. Once that absence becomes canonical it is monotonic and every host current with that checkpoint honors it. That configuration deliberately does not assert global recovery of an edited body after provider deletion: live macOS 14/26 tests disclosed no such Current or unresolved evidence, and a host that accepts the later deletion may lose its last live copy. The model does not represent or make claims about provider data unavailable through current-visible inputs.

A canonical retired deterministic identity is retained by descendant checkpoints, and any host that has accepted the canonical checkpoint excludes it from its live deterministic set. A stale host may still hold or create that identity until it observes the retirement; exact-current checkpoint CAS prevents that stale state from entering a descendant checkpoint. The model's observe transition removes the identity unconditionally. Concrete reconciliation is stricter: if the corresponding live candidate changed, it preserves the content and refuses to treat that candidate as reusable rather than deleting data.

`ProviderPreservesDisplacedCurrent` makes the only new provider dependency explicit. In this model, “preserves” means “keeps the body observable as Current or unresolved,” not “retains it somewhere in provider storage.” The concurrent-nondeletion body configurations set it to `TRUE`: when a stale-base file publication displaces a different current body, that displaced body remains available as Apple-reported unresolved evidence. This is an environmental contract, not something TLA+ proves. Setting it to `FALSE` falsifies concurrent branch recoverability for at least one ordering; routine current-visible synchronization still works, but the stronger no-silent-branch-loss claim does not. The delete/edit configuration sets it to `FALSE` and omits that recoverability invariant to match the live Current/unresolved result. Once a joined concurrent-edit checkpoint contains both bodies, later exact-current checkpoint writes may not separate them.

`CrossMachineCurrentVisibleConvergence.cfg` adds weak fairness for enabled delivery, file reconciliation, checkpoint observation, and differing exact-current checkpoint publication. For the one-round concurrent-edit scenario, after both file branches have published, it proves that the two hosts eventually reach and permanently retain equal body, absence, and retirement sets. The fixed two-write bound is sufficient for this property. Delete/edit does not promise branch recovery or automatic host-state convergence after deletion hides the edited file. The model makes no convergence claim for repeated edits, retirement, crashes, permanent provider stalls, or an unfair environment.

Cross-Mac WAL independence is not a state variable in this model. It follows from the architectural fact that modern WALs are host-local plus the single-host `LocalWALSafety` and `LocalDurabilityLaneIndependence` checks; this composition model must not be cited as proving it.

For concurrent nondeletion bodies, negative controls must fail when displaced Current retention is disabled or a divergent merge drops the local body (`ConcurrentBranchesRemainRecoverable`). The delete/edit configuration replaces that inapplicable global guarantee with `DeleteEditLossRequiresAcceptedDeletion`: the edited body can leave all modeled current-visible evidence only after the edit host accepts deletion through either provider Current or a newer complete canonical checkpoint carrying source absence. Other negative controls remove exact-current checkpoint CAS (joined-branch or canonical-retirement monotonicity), canonical source-absence advancement (`CanonicalSourceAbsenceIsMonotonic`), or the retired-set union from checkpoint observation (`AcceptedRetirementsAreNeverForgotten`). Coverage expectations are scenario-specific: the delete/edit configuration intentionally permits loss after an accepted deletion with no disclosed edit, body configurations leave create/retire actions at zero, and retirement leaves all file actions at zero. Only invariants relevant to each scenario are configured.

### Repeated cross-machine rounds and host loss

`MultiRoundCrossMachineSafety` fixes two hosts, two edit decisions per host, at most two checkpoint writes per host, and permanent loss of at most one host. A second-round edit is admitted only after both first-round files have published, but file delivery, reconciliation, checkpoint observation, and checkpoint publication remain independently ordered. A host may publish a checkpoint only after its own pending note-file obligation has settled. Cumulative decision tokens record causal contributions without enumerating historical bodies; they are not literal body, deletion, retirement, or resolver states. Loss is enabled only after that host has no pending file and all of its locally durable decisions have been provider-published; the lost host's local authority is then erased.

Within those bounds, TLC checks that every causal decision token remains in some live/provider representation, every published token remains in provider evidence, canonical checkpoint history is monotonic, and a lost host retains no local authority. This nondeletion model applies the displaced-current preservation assumption independently to every modeled displacement; TLA+ does not prove Apple retains a body, and the live contract probe establishes only the specified single stale-base nondeletion round under bounded host schedules. The model proves neither literal body recovery, arbitrary repeated-round behavior, eventual convergence, nor provider/network liveness, and it does not include delete/edit, retired identities, resolver disposition, or host-local WAL crashes. Disabling displaced-current preservation, permitting loss with unpublished work, removing exact-current checkpoint CAS, or allowing checkpoint publication while that host has a pending file must falsify its corresponding invariant or action property.

### Host-local WAL durability

`LocalWALSafety` begins after a valid header has been created and the Application Support directory synchronized. `LocalDurabilityLaneIndependence` separately checks creation-independent append/barrier liveness while provider work is permanently stalled.

The WAL model distinguishes checkpoint installation from exact verification and WAL unlink from Recovery Journals directory synchronization. A crash after unlink but before directory durability may restore or omit the namespace entry; either restart path still requires verified coverage before reaching closed state. Every WAL-durable edit remains either in an existing WAL or in an exactly verified checkpoint's coverage. `CrossBoundaryDurabilitySafety` separately explores an older completion racing a newer pending generation. Exact UUID/LSN matching and byte-level coalescing remain concrete scheduling refinements; tests must show that coalescing never clears an intervening generation.

The model exercises the covering-checkpoint closure path. The no-checkpoint shortcut for an exactly header-only WAL with an unchanged checkpoint-scoped dirty generation depends on concrete archive-generation and byte-level header evidence, so it remains an implementation/crash-point test rather than a second modeled cleanup authority.

The model contains no provider upload action. Provider state cannot authorize or prevent local deletion. Cross-Mac loss of WAL-only work is outside the guarantee by product decision; separate note files are the cross-Mac representation.

Negative controls must fail if WAL deletion precedes verified checkpoint coverage, closed state precedes directory durability, an uncovered durable edit loses both WAL and checkpoint representation, or local append/barrier progress is conditioned on provider completion.

## Environmental assumptions and implementation obligations

The active models assume truthful results for:

- coordinated shallow catalog completeness and immutable selected current snapshots;
- positive root-session/provider-authority identity and structural/UUID-LSN comparison;
- local WAL header validation, record framing, checksum/decoder results, append/barrier synchronization, and Application Support directory synchronization;
- exact checkpoint replacement/read-back/decode/identity verification;
- one exact coherent checkpoint-current witness returned by the no-write result: complete bytes, the host-local `NVFileObservation`, and current local `NSFileVersion` identity when available; the model's abstract version changes only represent replacements observable through that witness;
- bookmark resolution plus independent resolved-directory identity validation;
- Apple-reported unresolved version objects remaining bound to their supplied immutable content while each coordinated member read executes;
- for the conditional cross-machine nondeletion branch-preservation claim only, each modeled stale-base publication that displaces a different current body leaving that body current or Apple-reported unresolved; the delete/edit configuration assumes no such observable Current/unresolved retention, and the repeated-round token model applies the nondeletion contract per displacement without establishing Apple behavior beyond the separately tested one-round cases;
- successful `resolved = YES` updates affecting only their designated members and later unresolved queries truthfully reporting every remaining member;
- advisory locking of the opened root-directory object, retained descriptor ownership, and coordinator accessor ownership.

The directory-lock assumption has a dedicated [AV-16 real-system probe](../../../Apple-API-Contract-Validation.md#av-16--root-directory-lock-contract). `JournalLifecycle` models a stable opened directory object and rejects lock loss during same-root moves or authority handoff. `QuitSafety` models final release as a separate post-WAL-cleanup, post-observer-drain step. Neither proves Objective-C ownership or behavior when the provider replaces/revokes the root itself; those outcomes require the positive-continuity fence and integration/contract tests. The rejected child lock-file probe remains comparison evidence only.

If the implementation cannot establish an assumption for an operation, it removes that operation's success transition: routine reconciliation remains dirty, conflict disposition leaves the member unresolved/retryable, startup/cleanup preserves the local WAL, or root continuity remains unavailable until positive recovery or explicit user-directed session termination. No timeout, callback, menu state, path comparison, negative provider result, or provider label substitutes for evidence.

The safety configurations assume no provider/network fairness. The bounded concurrent-edit convergence configuration explicitly assumes weak fairness for its enabled delivery, reconciliation, observation, and publication actions; it does not establish that a real provider or network is fair. Other weak fairness is limited to NV-controlled local actions that remain enabled. The models do not prove Objective-C memory ownership, Apple API behavior, actual filesystem persistence, bookmarks across OS releases, UI wording, logging redaction, cryptographic vectors, safe-replacement behavior, or epoch-4 compatibility. Those remain real-system, integration, crash-point, and implementation-review obligations.

## Proposal-3 provenance and redundancy audit

The 2026-09-03 audit compared every `.tla` and `.cfg` against proposal #3 at `57b36adf0c0a801c75116debfb9b3c9f73e5eb72`, then mapped its actions and configured assertions to the then-current specification, vocabulary, ADRs, and proposal #4. Before this cleanup there were 27 modules and 30 configurations. Sixteen modules and sixteen configurations were byte-for-byte unchanged from that commit; the other eleven modules and fourteen configurations did not exist there. Age alone is not a deletion criterion.

### Active files retained

The audit below describes the **proposal-4 baseline**, not proposal-5 acceptance. Thirteen modules, including two handoff bridges, originated after its comparison commit; seven retained older modules were rewritten as described below. Each module has its same-named configuration; `CrossMachineCurrentVisibleSafety.tla` additionally has `CrossMachineCurrentVisibleDeleteEdit.cfg`, `CrossMachineCurrentVisibleRetirement.cfg`, and `CrossMachineCurrentVisibleConvergence.cfg`. This accounts for twenty-one baseline/shared modules and twenty-four configurations, separate from the segment and investigative suites.

The original `JournalLaneIndependence` pair was the unchanged exception. It is now named `LocalDurabilityLaneIndependence`, with staging terminology generalizing WAL append to the shared local-lane boundary; the weak-fairness guarantee is retained and rerun. New finite segment checks do not make the standalone per-admitted-edit obligation obsolete.

### Deleted redundant and superseded files

Every file below was unchanged from the comparison commit. Each named module's same-named `.cfg` was removed as well, except the configuration-free helper. “Replacement” means coverage of the **still-required** behavior, not a claim that today's models prove the retired architecture's stronger or different promises.

| Removed module/configuration | Current coverage and reason not to port it |
| --- | --- |
| `CrossMachineDurability` and `CrossMachineConvergence.cfg` | `LocalWALSafety`, `CrossMachineRestartRecoverySafety`, and the current-visible cross-machine safety/convergence configurations cover local durability and current-file/checkpoint delivery. Provider WAL delivery/deletion, foreign preference claims, and upload-qualified recovery are gone. The old shared-WAL remote-recovery guarantee is deliberately not reproduced. |
| `CrossMachineGenerationSafety` | `CrossBoundaryDurabilitySafety`, `CrossMachineCheckpointContentionSafety`, and `MultiRoundCrossMachineSafety` cover successive local generations, checkpoint contention, repeated publication, and bounded host loss. Advancing retained receipts across provider WAL generations has no current counterpart. |
| `HostLocalJournalOwnership` | Its host-local objects are **preference claims over shared journal files**, not today's physically host-local WALs. Cross-host claim noninterference/demotion and provider-qualified deletion no longer exist. `LocalWALSafety` and restart composition retain local cleanup/recovery checks; the rewritten `JournalLifecycle` now checks local creation/root association and local lock contention. |
| `CurrentVisibleFallbackSafety` | `CurrentVisibleReconciliationSafety` directly checks current catalogs, selected inputs, root/model fences, and dirty-generation handling. Current-visible is the primary policy, so unsupported-history capability gates and preservation of earlier all-version resolution eligibility are obsolete. |
| `ReconciliationFencingSafety` | Current transaction fencing is covered by `CurrentVisibleReconciliationSafety`; explicit snapshot-scoped disposition is covered by `UnresolvedVersionResolutionSafety` and its cross-host composition. Complete historical-set fencing and automatic resolution eligibility are no longer requirements. |
| `ReconciliationSafety` | The old combined all-version transaction duplicates the focused fencing and disposition responsibilities now covered separately. Its useful pure merge/rename cases remain in `ReconciliationDecisionSafety` below; keeping a second historical traversal/composition model adds no current coverage. It must not be substituted for a current-visible end-to-end proof. |
| `ReconciliationInterface` | Only the old reconciliation family used this all-version fence helper. Active models, including the rewritten current-file decision table, have their own current-scope predicates. |
| `RecoveryEvidenceSafety` | Historical database/journal **Recover Notes** and **Discard** are explicitly unsupported. Deterministic copies, retired identities, additive preservation, and snapshot-limited explicit resolution have current focused counterparts in the resolver and checkpoint models. No historical checkpoint/version removal authority is retained. |

The obsolete `run-hybrid-reconciliation.zsh` and `ReconciliationSimulation.cfg.in` were also unchanged and were removed with their all-version model dependencies. Their generated scenario runs are not current-visible integration coverage. The exhaustive active configurations above remain the supported runner recipe. Git retains every deleted source.

### Migrated lifecycle and decision models

The seven former migration candidates are now rewritten current-design acceptance models, not executable proposal-3 history. Together with the twelve previously active models and two executable bridges, the suite has twenty-one modules and twenty-four configurations. The bounds below are deliberate; no state constraint hides an inconvenient reachable state.

#### Local record replay

JournalRecoverySafety explores every two-record sequence over an ordinary UUID and a reserved-v8 UUID, base/edit/deletion values, each valid-prefix length, exact versus mismatched bases, header validity, and positive/other/unknown association. A detached per-WAL reducer is compared with an independent last-record/prefix oracle. Ordinary removals serialize as absence from a set of live note records, never a general checkpoint tombstone. A v8 deletion contributes retirement even on mismatch without deleting the source. An already-represented fixture supplies an actual matching checkpoint payload; equality of note/conflict/retirement results permits the read-only cleanup shortcut. A corrupt suffix cannot take it.

MultiJournalRecoverySafety has two ordered two-record WALs, two notes, and eleven fixtures: independent/concurrent changes, delete/edit, delete-then-edit and edit-then-delete, duplicate states, mismatch, mismatched v8 retirement, v8 delete-then-edit, equal bodies on different UUIDs, and interleaved notes. It replays each branch independently and then joins their final states, without a cross-WAL LSN order or legacy-first rule. Choosing one nondeletion branch for the original note is a deterministic tie break, not temporal ordering; the other remains a UUID-qualified conflict input. Exact-base deletion wins the source UUID while a differing final update is preserved. Every asserted retirement enters the complete checkpoint. Assertions inspect per-note states and checkpoint sets, not a disposition flag or a self-issued coverage receipt. Superseded intermediate records inside one WAL need not remain separate notes.

Both replay models independently check checkpoint membership/absence for every source UUID, including untouched base notes, plus exact expected conflicts and retirements. These predicates derive expectations from immutable record inputs, not `Serialize` or mutable reducer output. They run at installation/read-back and WAL cleanup, including cleanup followed by crash. Mutating the serializer to emit nothing or omit unchanged notes must fail; serialized-data equality against that same serializer is not sufficient evidence.

These models assume truthful classification/decoding, immutable captured inputs, and the focused checkpoint transaction's exact verified success boundary. The v8 mismatch fixtures exercise the modern-WAL retirement projection; ordinary-record ordering also applies to legacy/modern combinations, without granting arbitrary legacy UUID bytes new semantics. They do not establish CRC/encryption/decoder behavior, bookmark identity, arbitrary-length replay, deterministic UUID byte derivation, or automatic-candidate allocation/integrity decisions; those remain concrete tests. The routine decision model below checks a different identity domain and cannot fill that allocation boundary. Crash is terminal in these checks and may undo an unsynchronized unlink; restart is separately composed by CrossMachineRestartRecoverySafety and CrossBoundaryDurabilitySafety. Weak fairness is limited to local prefix/replay/reduction actions, proving that this finite local calculation finishes or crashes; there is no provider, checkpoint, or cleanup fairness assumption.

#### Startup outcomes and root/WAL creation

StartupSafety enumerates thirteen checkpoint/WAL scenarios on provider-managed and non-provider fixtures. It distinguishes provider-current acceptance before any note catalog, materialization success/failure, complete offline input, uncertain mandatory WALs, already-represented recovery, explicit versus exclusively owned creation, and detached rebuild. Rebuild includes decoder/Ignore choice, mixed-format selection, provider plaintext/disclosure, unreadable input, and one catalog, checkpoint, and root-session disturbance. Installation and read-back acceptance are separate actions. A stale rebuild is rejected without invoking the root-closing merge; returning to fresh discovery is outside this one-attempt model. Cancellation while an accessor is owned requests cancellation but cannot finish until that accessor returns. Editing needs accepted complete data, recovered matching WAL input, applicable checkpoint verification, local cleanup, and a synchronized fresh header/directory.

JournalLifecycle adds two processes contending for one local directory-object lock, three bounded WAL IDs, six candidate-artifact classifications, and independent root association/provider availability. A positively associated torn WAL blocks creation. Copied, unresolved, or invalid-header candidates remain untouched and grant no recovery/cleanup authority; active root/WAL association uncertainty independently blocks new mutation. Exclusive creation burns failed IDs and requires recovery settlement; WAL descriptor exposure follows both header and directory synchronization while the independently modeled directory lock remains continuously owned. Same-root moves never rewrite open headers or drop that lock; authority changes invalidate older provider snapshots without dropping it or disabling local append/barrier work. Crash ends the attempt, releases the process-local lock, and retains local durable evidence. This is not a proof that advisory locking excludes uncooperative applications, that a replacement root inherits a lock, or that successful forward lookup permits reverse lookup.

Startup aggregates matching WAL recovery rather than repeating the record state space; the two replay models expand that boundary. Its absent-checkpoint fixture means coordinated checkpoint absence inside a positively opened root, not a missing root path or failed lookup. Creation classifies API results rather than implementing the header parser or forward-provider evaluator. Neither model adds timeout-based absence/deletion inference, a read-only mode, or automatic session termination.

#### Closing and storage/credential transitions

QuitSafety bounds one close operation, one presenter callback, one possible final external-editor mutation, and two competing checkpoint replacements. It separately tracks checkpoint-scoped metadata and WAL note records, so metadata-only changes defeat header-only cleanup. Stable callback/final-read settlement precedes a single-use attempt; one current mismatch adds remote/retirement obligations and permits one fresh exact-current attempt. A second mismatch parks at the close UI. Reentry and applicationWillTerminate cannot write. A failed operation may be before installation or after installation but before successful read-back; neither permits WAL cleanup. Override retains the local WAL. The directory lock remains held through WAL descriptor closure, directory-durable cleanup (or evidence-preserving override), and observer/operation drain; only a separate final release action closes the root owner. Cancel retains the lock, while process crash releases it. Actual vnode-handler/MRC ownership and cross-controller storage handoff remain integration obligations.

StorageTransitionSafety covers plaintext conversion, in-place encrypted rekey, encrypted Save As, and plaintext Save As. An initially durable local WAL protects the one live change missing from the old checkpoint. In-place conversion verifies a complete old-contract checkpoint and locally removes its WAL before changing formats. Save As does not mutate that source checkpoint or credential: it verifies an independent bootstrap; an encrypted database-only bootstrap can itself be the final target, whereas plaintext export needs a final target checkpoint. Key addition, exact read-back validation, checkpoint installation, verification, and old-key deletion are separate actions. A colliding foreign item remains untouched. Every physically installed checkpoint retains its required credential even if NV crashes before recognizing success; old-key deletion is post-cutover only, and Save As cannot alias or delete the source key.

The export check fixes three live note-state tokens and one external divergent token. Known exports finish before the stable catalog/snapshot pair is captured; a later external change forces refencing, and its state must be preserved before final installation. This abstracts complete current catalogs and exact installed file states, not a catalog token magically unchanged by NV's own exports. One same-bytes checkpoint replacement can invalidate the full expected-current witness. Fresh header/directory synchronization gates publication of the target controller. Crash checks persistent artifacts directly; relaunch/format decoding, process death during individual filesystem syscalls, Keychain availability/KDF correctness, and arbitrary future cutovers remain implementation tests. Neither model assumes an atomic Keychain/filesystem transaction or provider progress.

#### Current-file decisions

ReconciliationDecisionSafety enumerates nine body-pair classes, every pair of three names, nine association-evidence classes, four merge-base origins, safe/unsafe text merge, and five unrelated automatic recovery-candidate states. A separately structured outcome oracle checks original-note body/name, UUID-distinct ordinary imports, and routine conflict preservation. Wrong-volume document IDs, wrong-session file IDs, duplicate identity, and path/timestamp-only evidence cannot attach a file; changed identity may use an independent unambiguous filename/content fallback. Missing or unsettled-checkpoint bases cannot justify a content merge. An unchanged accepted file snapshot followed by deletion has no invented historical branch; a still-local changed/renamed state is preserved.

One root, note, structural, or catalog invalidation can occur after preparation. Rejection leaves published state untouched and dirty. Routine conflict notes use fresh ordinary identities: a free, exact, modified, retired, or inconsistent automatic-recovery candidate neither suppresses required preservation nor gets overwritten. The model checks this separation explicitly; it does not allocate automatic checkpoint/WAL candidates or resolver recovery slots. Those domains have distinct policies in that retired baseline; this fixture does not prove proposal-5 identity allocation. Random UUID bytes, normalization/title/label vectors, actual filename association, physical file removal, and actual NVMergedText output remain separate tests; physical deletion is checked by SeparateFileDeletionSafety. No historical version or persistent provider identifier participates.

#### Executable sensitivity checks

The seven migrated models have 33 negative controls: empty checkpoint serialization, dropped unchanged notes, wrong record order, corrupt-suffix cleanup, dropped retirement, represented-cleanup without retirement coverage, incomplete multi-WAL combination, omitted checkpoint retirement, incomplete offline input, implicit creation, stale rebuild catalogs, premature editing/descriptor exposure, competing local lock owners, directory-lock loss during a move or authority handoff, directory-lock loss at WAL unlink or before observer drain, stale authority, metadata-blind empty cleanup, excess automatic retry, unsettled merge/retirement, untrusted merge bases, wrong-volume association, ignored conflicting renames, discarded safe-merge results, stale decision publication, overwritten unrelated recovery candidates, retirement-suppressed routine preservation, unvalidated credentials, premature old-key deletion, Save-As credential aliasing, and ignored export fences. The bridge section below adds eighteen fault controls and seven reachability witnesses.

Every critical assertion is evaluated against reachable outcomes or actual before/after state. Negative controls test selected fault classes, not arbitrary model correctness; shared abstractions and specification misunderstandings can still escape them. The active cross-machine models remain necessary for composition, and Apple contract/integration tests must establish environmental inputs. Passing TLC establishes the configured finite abstraction only, not an unbounded theorem or a proof of Apple's APIs.

#### Recorded exhaustive check

After the audit corrections on 2026-09-03, TLC `2026.09.01.002747` (`95b800c`), Java 21, four workers, and a 1 GiB heap completed all seven migrated configurations with empty queues and every top-level action exercised. All 29 negative controls produced their designated counterexamples. The fifteen existing configurations also passed. These counts describe the configured bounds, not comparative proof strength:

| Migrated model | Distinct reachable states |
| --- | ---: |
| JournalRecoverySafety | 7,921 |
| MultiJournalRecoverySafety | 407 |
| StartupSafety | 18,142 |
| JournalLifecycle | 70,080 |
| QuitSafety | 19,260 |
| ReconciliationDecisionSafety | 320,760 |
| StorageTransitionSafety | 1,096 |

The 2026-09-03 directory-lock update rechecked the two affected configurations with released TLC 2.19 (`5a47802`), Java 21, four workers, and no state constraint. `JournalLifecycle` remained at 70,080 distinct states; the explicit final-release stage increased `QuitSafety` to 22,842. All top-level actions were exercised. Both baselines and all ten applicable controls passed: the four new controls each produced the designated counterexample for loss during move, authority handoff, WAL unlink, or pre-observer-drain release.

### Executable handoff bridges

These bridges run imported actions rather than reimplementing the component algorithms. `StartupSafety.Initial` is a pure initializer shared with its unchanged standalone scenario matrix. The bridges attach actual payloads to its checkpoint/recovery tokens: token 1 decodes the captured checkpoint, and token 2 applies the captured matching WAL. A completion flag alone cannot satisfy the end-to-end payload assertions. Imported actions still abstract successful API operations; no bridge turns local installation into an upload guarantee.

`ReconciliationDurabilityBridge` connects decision publication to atomic pending-set admission, independent append/barrier/file completion, checkpoint installation and read-back, local cleanup, and ordinary startup. Ninety decision fixtures combine every body-pair class with two name pairs and five association/base/merge/unrelated-retirement profiles. The source/import/conflict roles denote distinct local UUIDs, not file xattrs or portable provider IDs. Actual body/name rows follow each stage. Logical deletion becomes checkpoint omission; the bridge performs no physical deletion. A crash can occur at each durability stage, and an unsynchronized unlink can reappear. Startup reconstructs from the actual installed checkpoint plus surviving synchronized rows, settles derived files, checks the full current witness, cleans up, and synchronizes a fresh WAL before editing. A same-bytes checkpoint replacement can invalidate recovery installation/read-back; root changes and cancellation remain independently possible.

Its assertions require exact payload admission, exact WAL/file completion, complete checkpoint serialization, recoverability of every synchronized row, and faithful reopened data. Per-UUID membership/absence predicates independent of `Apply` check complete decision output at installation and clean reopening, and the captured checkpoint plus surviving WAL at recovery installation, cleanup, and reopening. Unchanged source notes remain independently protected even when they have no pending/WAL row. Controls corrupt `Apply` to drop unchanged base data and must fail separately at installation, recovery cleanup, and reopening; other controls drop conflict admission/serialization, substitute empty WAL bytes, discard restart evidence, or forge file settlement. Four controls mutate imported decision/startup actions (lost conflict publication, retirement-suppressed routine preservation, premature fresh-WAL admission, and omitted current-witness comparison). Witness traces reach a delete/edit conflict's complete WAL recovery after a crash before any checkpoint installation, a conflict-containing clean reopen, routine delete/edit preservation despite an unrelated retired candidate, and a clean import/reopen retaining the unchanged source. The bound is one final record per UUID and one crash/reopen, not arbitrary ordered replay, second crashes during recovery, changed-content competing checkpoints, or cross-host delivery; the existing replay and cross-machine models retain those separate responsibilities. Automatic-candidate allocation/reuse and changing retired sets remain outside this bridge.

`StorageStartupBridge` runs all four storage-transition modes, crashes at any stage, and selects an existing source or destination checkpoint to reopen. It independently reads that root's captured format and credential and includes only its own WAL. A physically installed but not yet acknowledged target may reopen after fresh validation; an unavailable credential blocks startup rather than inheriting an old success flag. Save As cannot transplant source WAL bytes or use the source credential for its target. Opening an old-format checkpoint under positively established provider management requires conversion and stops at that requirement, rather than silently admitting editing. Ordinary startup otherwise reuses its recovery, exact-install, cleanup, and fresh-WAL actions with the captured payload. Controls select the wrong checkpoint/key, transplant a WAL, omit credential/format gates, or drop replayed contents. Witnesses reach unacknowledged-target reopening, recovery from the old source WAL, and completed plaintext provider reopening.

Storage bounds remain the four remembered-encryption/plaintext fixtures, three original live tokens plus one divergent file token, one transition crash, and one startup. Further conversion, unremembered-key/passphrase UI, crypto/decoder correctness, additional crashes, and unrelated future edits are not proved. Neither bridge assumes provider fairness or asserts eventual completion under unavailable storage. These executable edges strengthen local end-to-end safety; they do not make the other abstract arrows machine-checked or extend the cross-machine delete/edit recoverability ceiling.

The post-audit 2026-09-03 validation used the TLC/Java setup above: `ReconciliationDurabilityBridge` completed 431,192 distinct states, and `StorageStartupBridge` completed 63,352. Both queues emptied and every top-level bridge action was exercised. The full runner passed all 63 checks: nine baselines, forty-seven designated fault counterexamples, and seven unmodified-model reachability witnesses; the other fifteen active configurations also passed. Thus all twenty-four configurations were exhaustively rechecked. The two added witnesses reach the repaired audit scenarios with their data intact, rather than avoiding loss by making those paths unreachable. These remain finite safety checks, not promises of provider progress.


## Original UUID reconciliation report

This earlier report compared the retired assignment model with the still-investigative association lab. Historical combined counts and policy recommendations below are not the active runner inventory or adopted import policy. Run the assignment half with the archived runner above; the active association report remains [separate](../../UUID-Reconciliation-Experiments.md).

# UUID reconciliation experiments

Status: experimental, **not adopted product policy**. No production code, normative specification, or ADR was changed. UUID xattrs, aliases, and an NV-managed Trash protocol still require a policy decision and implementation design.

## What the experiments establish

Choosing a common UUID and establishing common file identity are different problems. The first has useful convergent rules. The second cannot always be solved automatically from database UUIDs, xattrs, names, and content: distinct histories can expose exactly the same inputs.

The strongest tested candidate keeps the existing live database UUID stable, treats xattrs as claims, and reconciles through **durable aliases scoped to a positively established file incarnation**. It preserves both hosts' edit payloads and old-UUID WAL references in the bounded assignment experiment. That is conditional: no existing Apple API is presumed to supply the necessary cross-host association proof. Unknown association or intent remains unresolved, with inputs retained; it is not silently classified as a new note or a deletion.

## Connection to the current implementation and contracts

- [`NoteObject.m`](../../../../NoteObject.m) initializes fresh note identities with `CFUUIDCreate`; [`NotationDirectoryManager.m`](../../../../NotationDirectoryManager.m) prepares external additions independently and publishes a detached transaction.
- [Proposal #4](../../../impl-proposal-4/README.md), under current-file identity and checkpoint-current reconciliation, gives unmatched files fresh UUIDs and associates competing checkpoint records by UUID. It explicitly prohibits UUID xattrs. Thus a common external file need not have a common logical UUID on two independently importing hosts.
- The current [`CONTEXT.md`](../../../../CONTEXT.md), [spec](../../../iCloud-Drive-Support-Spec.md), and [ADR-0014](../../../adr/0014-distinguish-logical-deletion-projections-and-conflict-disposition.md) now use committed birth identity and explicit causal Delete. This report investigated the retired proposal-4 checkpoint/UUID scheme; its physical-association counterexamples still apply, but checkpoint omission is no longer modern deletion authority.
- [Apple contract observations](../../../Apple-API-Contract-Validation.md) show syncable custom attributes arriving on both Macs, surviving tested eviction/materialization and rename, being copied by Finder, and being removed by generic atomic replacement. Historical conflict bodies did not reliably carry them. Missing attributes therefore are not proof of a new note; equal attributes are not proof of the same incarnation. No reverse File Provider lookup or portable historical `persistentIdentifier` is assumed.

Existing checkpoint/cross-machine models begin with an already-identified source UUID. These experiments test that missing premise, rather than claiming those existing proofs cover independent import.

## 1. Concurrent assignment and checkpoint/WAL reconciliation

[`UUIDAssignmentRace`](UUIDAssignmentRace.tla) has two hosts, one external file, two proposed UUIDs, one edit payload per host, and at most two successful checkpoint installations. Both hosts start from the same empty checkpoint for this file. Each can independently import it and capture an initial xattr proposal before seeing the other's write.

Import, initial stamping, provider delivery, reassignment, edit/WAL admission, checkpoint capture, exact-current attempt, merge, settlement, crash, and recovery are separate actions. A close can race metadata convergence. The second closer must reconcile against the actually installed checkpoint; recovery consumes that checkpoint and the actual modeled old-UUID WAL row, not an invented already-normalized recovery result.

The model stores finite sets of edit payload tokens, not text or diff-match-patch output. A joined row is one logical identity with both payloads retained; this is not permission to concatenate conflicting text. Concrete conflict-note allocation, payload ordering, and file installation remain separate obligations.

| Rule | Effective UUID eventually agrees¹ | No duplicate logical row after both closes | Old WAL replay does not fork identity | Old WAL UUID remains in local aliases and installed checkpoint | Live DB UUID never changes |
| --- | --- | --- | --- | --- | --- |
| `database`: ignore tags | No | No | No | Yes | Yes |
| `restamp`: keep DB UUID and correct differing observed tags | No | No | No | Yes | Yes |
| `xattr`: adopt the observed tag | Yes | No | No | No | No |
| `eagerMinimum`: choose smaller UUID and periodically restamp | No | No | No | No | No |
| `minimum`: choose smaller UUID; write only to correct observed metadata | Yes | No | No | No | No |
| `aliases`: minimum plus retained learned UUID aliases | Yes | No | No | Yes | No |
| `scoped`: additionally join positively associated checkpoint rows | Yes | Yes² | Yes² | Yes | No |
| `stable`: scoped aliases, but retain each live DB UUID | Yes³ | Yes² | Yes² | Yes | Yes |

¹ Only in the separate `Mode = "settle"` configuration, with no closing and weak fairness for local processing and latest-state delivery. This is not a promise of convergence while offline, nor delivery of every intermediate metadata value. Close/recovery safety uses no fairness assumption.

² The one-file model gives `scoped` and `stable` a positive same-file association for these rows. Blindly applying their union operation across all records would be unsafe. The second model tests that limitation, including a control that injects a false-positive proof.

³ Both live DB UUIDs can remain different. Agreement is on the effective alias representative, not mutation of both `NoteObject` identities. Checkpoint reconciliation chooses a canonical representative while retaining claims needed to replay old local UUIDs. The witness `NeverMergedWithDistinctLiveIDs` reaches a single merged row with two distinct live IDs.

### Counterexamples worth retaining

1. **Independent imports survive a correct checkpoint CAS as duplicates.** Both import before either tag is visible, creating UUIDs A and B. A closes with `{A}`. B's stale installation is correctly rejected, but UUID-only reconciliation sees two additions and installs `{A,B}`. Both payloads survive; logical identity does not converge. This is the current-policy hypothesis, not an invented overwrite bug.
2. **Correct metadata convergence can happen too late.** Even minimum/alias rules allow closing before either host observes the competing claim. Learned aliases alone cannot join checkpoint rows whose association was never learned.
3. **Reassignment is a durability change.** A WAL row exists under A, then the live record adopts B. If only B is serialized, A's durable reference is no longer represented by the identity mapping. Merely changing the in-memory UUID or xattr is insufficient. The serializer and replay controls detect missing alias coverage.
4. **Periodic re-stamping can prevent its own convergence.** An A host writes A; a B host blindly re-stamps B before observing A. The cycle is weakly fair because B never has a continuously enabled opportunity to read A. The change-triggered minimum variant stops the unnecessary write and passes under the same fairness assumptions; stronger provider fairness was not added to hide the failure.

## 2. Association, copies, deletion intent, and restoration

[`UUIDAssociationLab`](../../UUIDAssociationLab.tla) exhaustively explores 24 explicit fixtures (23 in the initial run) and one optional edit, replacement, restoration, or checkpoint disturbance between capture and publication. It does not take the Cartesian product of unlimited histories. Each fixture contains two candidate records, their observable UUID/tag/name/body/epoch evidence, and separately held ground-truth origin/intent used only by assertions.

The decision function can inspect only its captured observation. It cannot inspect the fixture name or ground truth. `proof = same/different/unknown` is an explicit conditional input: verified **same incarnation**, not equal tags, local inode values compared across Macs, filenames, or historical version identifiers. Positive Trash fixtures additionally assume the record is genuine NV deletion evidence for that incarnation; a plain user-created subdirectory supplies no such guarantee by itself.

| Rule family | No false joining of copies | No incorrect final separation of one file | No false intentional deletion |
| --- | --- | --- | --- |
| DB UUID wins | Fails | Fails | Fails |
| Xattr wins | Fails | Fails | Fails |
| Minimum DB/xattr UUID | Fails | Fails | Fails |
| Equal filename and body | Fails | Fails | Fails |
| Global UUID alias set | Fails | Fails | Fails |
| Equal UUID plus copied incarnation xattr | Fails | Passes by deferring nonmatches | Fails |
| Checkpoint omission overrides intent uncertainty | Fails | Fails | Fails |
| Revalidated incarnation evidence; otherwise defer | Passes conditionally | Passes conditionally | Passes conditionally |

The passing evidence rule actually joins independent imports, keeps known copies separate, accepts positively identified Trash deletion, preserves the local edit from a delete/edit race, keeps a restored source, and installs/reopens its results. Separate reachability traces require each of those paths. It is not an always-defer policy. Nevertheless `NoDeferral` deliberately fails: some fixtures cannot safely finish automatically.

These are isolated rule hypotheses, not a claim that today's implementation applies each rule or can produce every hypothetical UUID/xattr combination. In particular, the first model's duplicate-import trace tests the current UUID-only checkpoint-association premise; the second model also exercises proposed xattr/alias protocols that are not implemented.

### Indistinguishable histories

The model checks that these pairs expose identical complete decision inputs but different required classifications:

- Two imports sharing a tag, versus a copied tag on a different file that was assigned another local DB UUID.
- A safe-save replacement that stripped the tag, versus a newly created, unrelated file with the same name/body and no tag.
- An old Trash entry followed by restoration and another unexplained disappearance, versus intentional deletion of the original incarnation. Copying the incarnation attribute does not distinguish them.
- A complete competing checkpoint that never contained the note, versus a checkpoint whose writer intentionally deleted it. A receiver's base membership plus the incoming checkpoint's omission does not establish that incoming branch's ancestry.
- A real intentional deletion whose Trash evidence has been purged before observation, versus unexplained external disappearance.

This fixture-equality assertion is a sanity check on the indistinguishability construction, not a separately deep safety proof. Its consequence is information-theoretic: a deterministic decision function receiving equal observations returns equal decisions. When the correct automatic answers differ, at least one answer is wrong unless additional evidence or an unresolved state is allowed. Random tie-breaking cannot provide an all-behaviors safety guarantee either.

Trash-first delivery keeps the still-visible source. Source-absence-first delivery without corresponding intent evidence defers. Restored/new incarnations cannot inherit an old incarnation's deletion authority. None of these actions physically unlinks a current file; the original expected-snapshot removal rule remains a separate constraint.

## Candidate rules to carry forward

The most promising direction is `stable` plus the second model's guarded evidence policy, **not unconditional xattr authority**:

1. Keep a live DB UUID as a stable local handle. Use an xattr to advertise/discover a candidate identity, not to overwrite an existing note merely because it differs.
2. Establish whether competing records refer to the same incarnation before joining them. A different proven incarnation is a separate identity even if it copied the UUID and every attribute. Unknown remains unresolved; missing metadata is not proof of separation.
3. For an established association, retain all necessary old UUID aliases and choose a deterministic representative. Do not repeatedly restamp without an observed reason. Persist aliases with the checkpoint and make replay use them; dropping them after merely changing a live object is unsafe.
4. Scope aliases and deletion evidence to the established incarnation. Do not let global transitive UUID aliases join a later copy or let an old Trash record delete a restored note. An NV-authored restore can issue a fresh incarnation, but an external byte/attribute-identical restore is still ambiguous.
5. Accept automatic remote deletion only with both relevant intentional-deletion evidence and current incarnation applicability. Otherwise preserve the in-memory note and offer/retain the confirmation decision. A filename, equal UUID, timeout, or arbitrary incoming checkpoint omission cannot supply the missing facts.

These two modules are complementary experiments, **not an executable refinement/composition proving this combined protocol**. Before adopting it, the design must specify how positive cross-host association and intent evidence are obtained and persisted. In particular, a durable alias is not useful if its incarnation binding was guessed. Existing local, volume-qualified filesystem matching does not automatically bind a remote checkpoint row to that same file.

The stable-handle variant also requires an explicit rule for alias-aware pending sets, undo/external-edit references, source-UUID-derived deterministic conflict identities, and alias retirement. Those implementation and schema costs are not proven away by the small model. No alias garbage-collection protocol or universal fully automatic resolution has been established.

## Verification and bounds

In the initial 2026-09-04 run, TLC 2.19 with the Wolfram-bundled Java 21 runtime verified all **97 expected outcomes**: 29 exhaustive passes, 46 rejected policy/property hypotheses, 11 reachability witnesses, and 11 detected mutations. The combined baselines visited 533 states (`scoped` assignment), 463 (`stable` assignment), and 401 (evidence/intent lab), with zero states left on every passing queue. These are finite model-checking results, not an unbounded theorem about all files or histories. The [two-Mac follow-up](../../Incarnation-Metadata-Experiments.md#two-mac-follow-up-measured-binding-and-intent-transport) expands the shared matrix to 125 verified outcomes, including concrete local-observation rules and deletion-intent transport; it does not establish portable binding for independent imports.

Run `check-uuid-experiments.py` as described in the [suite README](../../README.md). It runs combined safety baselines, each policy/property pair separately, liveness checks, deliberately false unreachability claims, and mutations of disposable source copies. Baselines also reject unexercised top-level actions. A timeout, parse/evaluation error, or wrong assertion failure is a failed experiment, never a proof.

Controls drop incoming checkpoint data, omit serialized/replayed aliases, bypass exact-current CAS, trust copied/false-positive association evidence, bypass publication fencing, drop a delete/edit preservation result, serialize an empty checkpoint, discard deferred inputs, and indefinitely stall an unknown-evidence decision. Each must fail its designated assertion. The false-positive-evidence control is particularly important: the conditional passing policy must fail if its supposed association proof lies.

The finite bounds keep these runs small; no state/depth constraint truncates exploration. One optional disturbance is sufficient to challenge captured input applicability, but is not an arbitrary-race proof. `UUIDAssociationLab` checks capture → decision → fenced publication → abstract local barrier → checkpoint install → reopen, plus rejection/deferral. It does not model a crash before every intermediate barrier. Deferred inputs remain owned in the model; permission to quit would require separately proven durable preservation, not merely a UI flag.

`UUIDAssignmentRace` checks old-UUID WAL recovery after both checkpoint closes, before modeled WAL cleanup. It does not establish torn-record recovery, exact LSN ordering, all crashes during alias migration, arbitrary host/file counts, or permanent host loss. Existing durability models retain their responsibilities but would need actual alias-bearing payload bridges after a protocol is selected.

No live Apple API tests were rerun for the initial UUID experiment. The subsequent [incarnation metadata experiments](../../Incarnation-Metadata-Experiments.md) add causal-state checks and local APFS/iCloud API probes without adopting a protocol. Any proposed new association/Trash protocol still needs two-Mac tests for independent import, copy, external safe save, offline restore, asymmetric delivery, and checkpoint/file ordering. Current API observations justify treating attributes as fallible evidence, not assuming a portable identity mechanism that has not been demonstrated.


## References removed from active and proposal-4 documents

These excerpts preserve the original qualifications and provenance without leaving obsolete model names in normal implementation context.

### Historical combined experiment counts

From `Protocol-Combination-Experiments.md`:

The addition contains 58 checks across three models. All 183 expected outcomes
in the shared experimental matrix were verified, including the preceding 125
regressions: 49 exhaustive passes, 76 rejected hypotheses/properties, 36
reachability witnesses, and 22 mutation controls. After making the handshake's
local-handle/hidden-item distinction explicit, all 43 affected handshake and
composition checks were rerun successfully. Representative exhaustive
state counts are 19,952 (handshake/retarget), 23,052 (combined ordinary lifecycle),
46,479 (combined retarget), and 407 (retirement with stale reads). No exploration
is cut off by a state/depth constraint.

From `Incarnation-Metadata-Experiments.md`:

The expanded matrix verified all **125 expected outcomes** (16 additions): 33 passing configurations, 53 rejected policy/property hypotheses, 22 reachability witnesses, and 17 mutation controls. The new combined baselines visited 396 states (`currentSnapshot`) and 192 states (intent transport), with no depth/state truncation. These are exhaustive finite-model checks, not unbounded proofs. Both harness architectures compiled and `./build.sh` succeeded, with Xcode environment warnings.

### Former shared-model comment

`CrossMachineConflictDispositionSafety` formerly stated: “Current-file publication and reconciliation remain in CrossMachineCurrentVisibleSafety.” That was an uncomposed proposal-4 boundary, not a segment transport proof. Its active comment now states the uncovered boundary without directing readers to a retired module.

### Reference relocated from `docs/impl-proposal-5/Verification.md`

Existing proposal-4 models remain comparative evidence for their documented retired design and reusable component boundaries, not proof that the source implements them. `SeparateFileDeletionSafety`, `UnresolvedVersionResolutionSafety`, root/lifecycle decision tests and safe-replacement contracts can inform the new bridges; `CurrentCheckpointNoteMergeSafety` and local-WAL retirement models do not prove segment history by renaming variables. Keep the active/shared/retired/investigative distinction in [the TLA README](../../README.md).

### Reference relocated from `docs/impl-proposal-4/README.md`

The seven formerly retained proposal-3 models are now current-design checks: `JournalRecoverySafety`, `MultiJournalRecoverySafety`, `StartupSafety`, `JournalLifecycle`, `QuitSafety`, `StorageTransitionSafety`, and `ReconciliationDecisionSafety`. Run their exhaustive configurations and assertion-specific negative controls with [check-migrated-models.py](check-migrated-models.py), alongside the existing focused/cross-machine suite. Use [the documented bounds and interfaces](README.md#migrated-lifecycle-and-decision-models), not the models' filenames, to decide which claims apply. These checks do not replace production-code tests of WAL bytes/CRC/decoding, actual candidate association/UUID derivation, `NVMergedText`, Keychain read-back/KDF checks, AppKit admission/undo, exact filesystem witnesses, or restart/crash points. The verified-completion interfaces between independent models still require integration tests.

### Reference relocated from `docs/impl-proposal-4/README.md`

Two [executable handoff bridges](README.md#executable-handoff-bridges) now reuse the component actions: `ReconciliationDurabilityBridge` checks that exact note/removal/conflict payloads survive pending-set admission, WAL/file completion, checkpoint serialization, and startup after cleanup or crash; `StorageStartupBridge` checks reopening the surviving source/destination checkpoint with its own credential and root-associated WAL. Keep equivalent production integration tests: abstract completion flags are insufficient if serialized rows, root association, or decoder output disagree. After a transition crash, validate the actual installed checkpoint rather than a lost in-memory success flag; an old encrypted/database-only checkpoint found under provider management remains a conversion input, not permission to enable provider-mode editing. The bridges exercise that existing requirement without adding a migration ledger or changing product behavior.

### Reference relocated from `docs/impl-proposal-4/pre-implementation_gap_report.md`

**3. The detached decision function's input/output schema is under-specified for what the matrix actually needs, and two matrix rows have no existing implementation.** The proposal's field list — "the two catalogs, selected file snapshots, root/session and dirty/structural generations, and affected live-note UUID/LSN/name/base values" — omits state the current decision phase demonstrably reads from live objects: each note's `shouldWriteToFile`/pending-write membership (today `_stageOrAddDeletedNotes:` consults `pendingFileWrites` specifically to avoid classifying NV's own owed write as an external deletion, [NotationDirectoryManager.m:406](../../../../NotationDirectoryManager.m)), title/labels/content/format for merge decisions, and the last accepted per-note file snapshot. `ReconciliationDecisionSafety` models name/body/association classes abstractly and explicitly leaves "actual filename association… and `NVMergedText` output" to concrete tests — so the policy is checked but the algorithm is mine to design. Concretely missing rows: "independent rename and content edit → combine" and "conflicting renames" (today's tiers attach a rename only when *content is unchanged* — `processNotesAddedByContent:` requires content equality — so a remote rename+edit currently degrades to delete+fresh-import, losing UUID continuity and, per item 1, tripping the confirmation panel). Also unspecified: how rename combination treats an extension change (which implies a format change) and case-only renames in the case-insensitive namespace; and the commit-side mapping "UUIDs back to still-matching live notes" when a prepared result references a note that was deleted between decision and the (passed) fence check. This is the most safety-relevant data structure in the project, and the proposal describes its shape, not its contents.

### Reference relocated from `docs/Apple-API-Contract-Validation.md`

The stale-base probe gates only an external displaced-body claim for its specified simultaneous nondeletion round under both locally ordered host schedules; it is not a prerequisite for preserving NV-committed branches. The inspector records Apple's Current winner but does not equate it with unknowable internal server publication order. The edit/delete probe is observational: the macOS 14/26 run exposed zero of eight edited bodies as Current or unresolved on either host after deletion won, so that stronger current-visible claim is excluded. `otherVersionsOfItemAtURL:` also exposed none, and every nonlocal request for the deleted original URL completed with `NSCocoaErrorDomain/4`; these results do not prove provider-side destruction. Until the required nondeletion modes pass on each supported OS, the corresponding displaced-current claim remains conditional rather than established. `MultiRoundCrossMachineSafety` applies the nondeletion contract independently at each bounded modeled displacement; its passing result is not evidence that Apple preserves displaced bodies across an arbitrary or repeated publication sequence. Any stronger product claim requires a separate repeated-round live-provider test.

### Reference relocated from `docs/Apple-API-Contract-Validation.md`

The [directory-descriptor probe](../../../IntegrationTests.md#root-directory-descriptor-lock-probe) checks independent-process contention and descriptor lifetime, including rename/move, child replacement, and process death. All local contenders opening the same directory must address the same exclusion resource regardless of their writer-epoch IDs. The retired `JournalLifecycle` and `QuitSafety` models check older abstract retention/release ordering; they do not prove platform behavior.

### Reference relocated from `docs/tla/Protocol-Combination-Experiments.md`

- Binding and lifecycle execution are phased, not fully interleaved. This is a
  real output-to-input bridge, not a proof of concurrent binding and deletion.
- The checkpoint action is a local covering-checkpoint abstraction. It is not
  proposal #4's competing-checkpoint CAS/three-input merge. Existing checkpoint
  models and `UUIDAssignmentRace` retain that separate coverage; the full
  alias-bearing checkpoint/recovery implementation is not proved by combining
  their test counts.
- One modeled receipt/operation is not a general exactly-once delivery service.
- No receiver action removes a physical file. Current-file replacement and
  removal retain their existing separate model/API obligations.
- Barriers abstract successful local durability, not byte codecs, fsync behavior,
  complete process recovery, or every crash point in an implementation.
