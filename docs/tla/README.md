# iCloud Drive TLA+ models

The active models refine the current-visible/local-WAL design in `docs/iCloud-Drive-Support-Spec.md`, ADR-0013, and ADR-0014. They deliberately omit complete provider-history discovery, automatic version resolution, provider-visible WALs, active/retained claims, upload-qualified cleanup, and automatic root-loss classification because those behaviors are no longer requirements.

## Active models

| Model | Scope |
| --- | --- |
| `CurrentVisibleReconciliationSafety` | Complete current catalogs around selected current-file reads; root/model invalidation; representation of every selected visible input; exact dirty-generation consumption; conservative retry. |
| `SeparateFileDeletionSafety` | Exact-incarnation removal for an admitted logical deletion; explicit external-versus-NV removal origin; same-name replacement/recreation preservation; fresh-UUID import; action-level checks that checkpoint omission and retired metadata have no file-removal authority. |
| `UnresolvedVersionResolutionSafety` | User-invoked operation-local unresolved snapshots; deterministic saved copies, retired deleted copy identities, and current-note choices; exact local WAL/file installation before snapshot-scoped resolution; partial retry and later arrivals; no provider-version removal. |
| `CurrentCheckpointNoteMergeSafety` | No-write checkpoint-current mismatch; complete note-set/base-relative-deletion reconciliation; monotonic retired deterministic identities; exceptional whole-union retirement WAL durability and base-mismatch recovery; ignored competing settings; exact-current retry rejection after another replacement. |
| `CrossBoundaryDurabilitySafety` | Two successive local generations across out-of-order WAL/file completion, checkpoint-current contention, merged/recovered-input settlement across crash/restart, one exact retry, and directory-durable WAL cleanup. |
| `CrossMachineRestartRecoverySafety` | Two-host current-file/checkpoint ordering with one local decision and crash per host; host-local WAL survival; provider-current restart reconstruction; exact recovery-file/checkpoint settlement; fresh-WAL editing gate. |
| `CrossMachineCheckpointContentionSafety` | Two hosts closing from one predecessor; `C0`→`C1`→joined `C2`; no-write current-change handling; whole-union version-8 retirement durability; crash/restart; same-byte current-version invalidation. |
| `CrossMachineConflictDispositionSafety` | Two hosts concurrently snapshotting and disposing unresolved members; shared deterministic identity with host-local candidate reuse; selected-only versus snapshot-wide resolution; independent exact local source/copy generations; later arrivals and intervening edits. |
| `CrossMachineCurrentVisibleSafety` | Two-host composition of independently delivered current note files and checkpoints; conditional concurrent-edit preservation and the measured delete/edit current-visible ceiling; exact-current checkpoint writes; monotonic propagation of retired deterministic identities; bounded single-round concurrent-edit convergence. Four configurations isolate those concerns. |
| `MultiRoundCrossMachineSafety` | Causal decision-token accounting for two hosts and two edit rounds each; independent note-file/checkpoint delivery; settled-file checkpoint publication; conditional displaced-current preservation; permanent loss of one host after its durable work is provider-published. |
| `LocalWALSafety` | One self-describing host-local WAL; admitted/appended/durable stages; settled note files; exact local checkpoint coverage; crash/restart; WAL deletion only after verification and Application Support directory durability; provider stall independence. |
| `JournalLaneIndependence` | Weakly fair local append/barrier progress while provider work may remain permanently stalled. |
| `JournalRecoverySafety` | Ordered valid-prefix replay, exact-base versus mismatch semantics, v8 retirement, already-represented cleanup, checkpoint omission of ordinary deletions, and uncertain-evidence retention. |
| `MultiJournalRecoverySafety` | Independent per-WAL order, per-note preservation, delete/edit decisions, mismatched v8 retirement, complete checkpoint coverage and local cleanup. |
| `StartupSafety` | Checkpoint/materialization/offline choices, explicit creation, detached rebuild/format choices, cancellation ownership, exact-current installation, and fresh-WAL editing gates. |
| `JournalLifecycle` | Two local directory-lock contenders; retention through moves/authority changes; positive recovery association; burned IDs; header/directory durability; immutable headers across moves; provider-independent local durability and authority fencing. |
| `QuitSafety` | Callback/final-external-edit draining, checkpoint metadata versus header-only cleanup, single-use close attempts, one automatic exact-current retry, merged settlement, override and directory-lock release after observer teardown. |
| `StorageTransitionSafety` | Old-contract checkpoint, stable plaintext export, Save-As bootstrap, independent target credentials, exact cutover, crash-surviving checkpoint/key pairs, and fresh-WAL publication. |
| `ReconciliationDecisionSafety` | Independent current-file outcome oracle for body/rename/deletion/association cases; trustworthy bases; preservation independent of unrelated deterministic recovery candidates; rejection of stale prepared decisions. |
| `ReconciliationDurabilityBridge` | Instantiated decision/WAL/startup actions with actual UUID-qualified payload handoffs; partial durability, checkpoint omission, crash/reopen, and fresh-WAL admission. |
| `StorageStartupBridge` | Instantiated storage/startup actions; reopen actual crash-surviving checkpoint/key pairs, root-local WAL recovery, Save-As separation, and provider-format compatibility. |

These models map to stable requirements as follows:

- `DISC-01` and `PUB-01`: `CurrentVisibleReconciliationSafety`, with physical deletion refined by `SeparateFileDeletionSafety`.
- `REC-01`: `UnresolvedVersionResolutionSafety`, with two-host concurrent disposition refined by `CrossMachineConflictDispositionSafety`.
- `CKPT-01`: `CurrentCheckpointNoteMergeSafety`, with two-host current contention, crash/restart, and version-8 retirement composition refined by `CrossMachineCheckpointContentionSafety`.
- Cross-host composition of `PUB-01`, `CKPT-01`, and displaced-body input to `REC-01`: `CrossMachineCurrentVisibleSafety`, with repeated bounded rounds and host loss refined by `MultiRoundCrossMachineSafety`.
- `START-01` and `DUR-01`: provider-current startup plus host-local recovery are composed in `CrossMachineRestartRecoverySafety`; local generation/checkpoint/cleanup boundaries remain in `LocalWALSafety`, `JournalLaneIndependence`, and `CrossBoundaryDurabilitySafety`.
- `CLEAN-01`, `AUTH-01`, `ROOT-01`, and `WAIT-01` retain implementation/API refinements described below; no model manufactures those environmental facts.
- The seven lifecycle/decision models expand local record replay, startup admission, creation, closing, storage cutover, and current-file decisions. These are separate bounded checks, not machine-checked refinement links to the composition models.

## How to read the suite

Most modules are independent bounded checks. The first four arrows below remain abstract interfaces, not machine-checked refinement links. The final two are executable bridges: they use `INSTANCE` to run selected existing actions and check concrete model-payload handoffs across them. They do not establish a whole-spec refinement hierarchy or compose the imported modules' fairness assumptions.

| Focused boundary | Composition path |
| --- | --- |
| `CurrentVisibleReconciliationSafety` + `SeparateFileDeletionSafety` | → `CrossMachineCurrentVisibleSafety` → `MultiRoundCrossMachineSafety` |
| `CurrentCheckpointNoteMergeSafety` + `CrossBoundaryDurabilitySafety` | → `CrossMachineCheckpointContentionSafety` |
| `LocalWALSafety` + `JournalLaneIndependence` + `CrossBoundaryDurabilitySafety` | → `CrossMachineRestartRecoverySafety` |
| `UnresolvedVersionResolutionSafety` | → `CrossMachineConflictDispositionSafety` |
| `ReconciliationDecisionSafety` + `LocalWALSafety` + `StartupSafety` | → `ReconciliationDurabilityBridge` (executable payload bridge) |
| `StorageTransitionSafety` + `StartupSafety` | → `StorageStartupBridge` (executable artifact bridge) |

For a change, start with the leftmost affected focused model and then follow its composition path. If a behavior crosses rows, assume no model proves that joint interaction unless a boundary section below says so; implementation and integration/crash tests must establish the link.

## Running the active configurations

Use a released `tla2tools.jar`:

```sh
for model in \
  CurrentVisibleReconciliationSafety \
  SeparateFileDeletionSafety \
  UnresolvedVersionResolutionSafety \
  CurrentCheckpointNoteMergeSafety \
  CrossBoundaryDurabilitySafety \
  CrossMachineRestartRecoverySafety \
  CrossMachineCheckpointContentionSafety \
  CrossMachineConflictDispositionSafety \
  MultiRoundCrossMachineSafety \
  LocalWALSafety \
  JournalLaneIndependence \
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
    -config "docs/tla/$model.cfg" \
    "docs/tla/$model.tla"
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
    -config "docs/tla/$config.cfg" \
    "docs/tla/CrossMachineCurrentVisibleSafety.tla"
done
```

Every configured invariant/property must pass, every action enabled by that configuration's scenario must have nonzero coverage, and each state queue must reach zero. A simulation-only success is not a proof.

The seven migrated models and two bridges also have executable assertion-specific negative controls and reachability witnesses:

```sh
python3 docs/tla/check-migrated-models.py \
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

Cross-Mac WAL independence is not a state variable in this model. It follows from the architectural fact that modern WALs are host-local plus the single-host `LocalWALSafety` and `JournalLaneIndependence` checks; this composition model must not be cited as proving it.

For concurrent nondeletion bodies, negative controls must fail when displaced Current retention is disabled or a divergent merge drops the local body (`ConcurrentBranchesRemainRecoverable`). The delete/edit configuration replaces that inapplicable global guarantee with `DeleteEditLossRequiresAcceptedDeletion`: the edited body can leave all modeled current-visible evidence only after the edit host accepts deletion through either provider Current or a newer complete canonical checkpoint carrying source absence. Other negative controls remove exact-current checkpoint CAS (joined-branch or canonical-retirement monotonicity), canonical source-absence advancement (`CanonicalSourceAbsenceIsMonotonic`), or the retired-set union from checkpoint observation (`AcceptedRetirementsAreNeverForgotten`). Coverage expectations are scenario-specific: the delete/edit configuration intentionally permits loss after an accepted deletion with no disclosed edit, body configurations leave create/retire actions at zero, and retirement leaves all file actions at zero. Only invariants relevant to each scenario are configured.

### Repeated cross-machine rounds and host loss

`MultiRoundCrossMachineSafety` fixes two hosts, two edit decisions per host, at most two checkpoint writes per host, and permanent loss of at most one host. A second-round edit is admitted only after both first-round files have published, but file delivery, reconciliation, checkpoint observation, and checkpoint publication remain independently ordered. A host may publish a checkpoint only after its own pending note-file obligation has settled. Cumulative decision tokens record causal contributions without enumerating historical bodies; they are not literal body, deletion, retirement, or resolver states. Loss is enabled only after that host has no pending file and all of its locally durable decisions have been provider-published; the lost host's local authority is then erased.

Within those bounds, TLC checks that every causal decision token remains in some live/provider representation, every published token remains in provider evidence, canonical checkpoint history is monotonic, and a lost host retains no local authority. This nondeletion model applies the displaced-current preservation assumption independently to every modeled displacement; TLA+ does not prove Apple retains a body, and the live contract probe establishes only the specified single stale-base nondeletion round under bounded host schedules. The model proves neither literal body recovery, arbitrary repeated-round behavior, eventual convergence, nor provider/network liveness, and it does not include delete/edit, retired identities, resolver disposition, or host-local WAL crashes. Disabling displaced-current preservation, permitting loss with unpublished work, removing exact-current checkpoint CAS, or allowing checkpoint publication while that host has a pending file must falsify its corresponding invariant or action property.

### Host-local WAL durability

`LocalWALSafety` begins after a valid header has been created and the Application Support directory synchronized. `JournalLaneIndependence` separately checks creation-independent append/barrier liveness while provider work is permanently stalled.

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

The directory-lock assumption has a dedicated [AV-16 real-system probe](../Apple-API-Contract-Validation.md#av-16--root-directory-lock-contract). `JournalLifecycle` models a stable opened directory object and rejects lock loss during same-root moves or authority handoff. `QuitSafety` models final release as a separate post-WAL-cleanup, post-observer-drain step. Neither proves Objective-C ownership or behavior when the provider replaces/revokes the root itself; those outcomes require the positive-continuity fence and integration/contract tests. The rejected child lock-file probe remains comparison evidence only.

If the implementation cannot establish an assumption for an operation, it removes that operation's success transition: routine reconciliation remains dirty, conflict disposition leaves the member unresolved/retryable, startup/cleanup preserves the local WAL, or root continuity remains unavailable until positive recovery or explicit user-directed session termination. No timeout, callback, menu state, path comparison, negative provider result, or provider label substitutes for evidence.

The safety configurations assume no provider/network fairness. The bounded concurrent-edit convergence configuration explicitly assumes weak fairness for its enabled delivery, reconciliation, observation, and publication actions; it does not establish that a real provider or network is fair. Other weak fairness is limited to NV-controlled local actions that remain enabled. The models do not prove Objective-C memory ownership, Apple API behavior, actual filesystem persistence, bookmarks across OS releases, UI wording, logging redaction, cryptographic vectors, safe-replacement behavior, or epoch-4 compatibility. Those remain real-system, integration, crash-point, and implementation-review obligations.

## Proposal-3 provenance and redundancy audit

The 2026-09-03 audit compared every `.tla` and `.cfg` against proposal #3 at `57b36adf0c0a801c75116debfb9b3c9f73e5eb72`, then mapped its actions and configured assertions to the current specification, vocabulary, ADRs, and proposal #4. Before this cleanup there were 27 modules and 30 configurations. Sixteen modules and sixteen configurations were byte-for-byte unchanged from that commit; the other eleven modules and fourteen configurations did not exist there. Age alone is not a deletion criterion.

### Active files retained

Every row in **Active models** is now a current-design acceptance model. Thirteen modules, including the two handoff bridges, originated after the comparison commit; seven retained older modules have now been rewritten as described below. `JournalLaneIndependence.tla/.cfg` remains the sole unchanged older pair. Each module has its same-named configuration; `CrossMachineCurrentVisibleSafety.tla` additionally has `CrossMachineCurrentVisibleDeleteEdit.cfg`, `CrossMachineCurrentVisibleRetirement.cfg`, and `CrossMachineCurrentVisibleConvergence.cfg`. This accounts for twenty-one active modules and twenty-four active configurations.

`JournalLaneIndependence` is the important unchanged exception: its weak-fairness check that local append/barrier work progresses despite a permanently stalled provider remains exactly relevant. The newer durability models do not replace that liveness property. Keep it as-is.

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

One root, note, structural, or catalog invalidation can occur after preparation. Rejection leaves published state untouched and dirty. Routine conflict notes use fresh ordinary identities: a free, exact, modified, retired, or inconsistent automatic-recovery candidate neither suppresses required preservation nor gets overwritten. The model checks this separation explicitly; it does not allocate automatic checkpoint/WAL candidates or resolver recovery slots. Those domains retain their distinct normative policies. Random UUID bytes, normalization/title/label vectors, actual filename association, physical file removal, and actual NVMergedText output remain separate tests; physical deletion is checked by SeparateFileDeletionSafety. No historical version or persistent provider identifier participates.

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
