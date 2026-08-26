# iCloud Drive TLA+ models

These models exercise the highest-risk safety boundaries and selected progress
requirements in `docs/iCloud-Drive-Support-Spec.md` and ADRs 0001–0012. They
are deliberately split by lifecycle so that one abstraction cannot satisfy a
requirement by silently borrowing state from an unrelated procedure. One
bounded glue model connects the distributed obligations those lifecycle models
share without duplicating their internal algorithms. Small companion models
add orthogonal cardinality or liveness checks instead of forming one
intractable Cartesian product.

| Model | Scope |
| --- | --- |
| `QuitSafety` | Final dirty-bit/provider barrier, admitted callback drain, WAL and note-file settlement, at most one frozen checkpoint, exact read-back, request/checkpoint/local-version upload identity, mandatory resume after a successful pause, explicit-path failure isolation from legacy qualification, active-to-retained fallback ordering, provably empty owned-journal cleanup without checkpoint qualification, reentrant termination, and journal-before-record cleanup. |
| `JournalLifecycle` | One acting Mac's directory lock and current-host registry: fresh journal IDs, synchronized header-before-active-claim-before-edit ordering, bookmark/root/header/base validation, stale bookmark refresh, copied folders, missing and ambiguous claims, restart-time directory synchronization before missing-claim pruning, ordinary-local unclaimed recovery, active-to-retained crash ordering, exact checkpoint coverage, and later qualified multi-journal cleanup. Remote writers are abstract environment evidence here. |
| `HostLocalJournalOwnership` | Two-host refinement boundary: shared checkpoint/journal artifacts, host-indexed active and retained preferences and advisory locks, exclusive journal creation, active-to-retained ordering, receipt-qualified cleanup by the owning host, and transition-level preservation of another host's claims. |
| `CrossMachineDurability` | Bounded two-host glue model: one acknowledged edit, actual journal/checkpoint/note contents, distinct provider authority and per-host replicas, independently reordered cross-file deliveries, exact checkpoint qualification before journal deletion, host-local preference isolation, and startup/offline omission handling. `CrossMachineConvergence.cfg` separately adds explicit note-upload/delivery fairness and checks direct convergence. |
| `CrossMachineGenerationSafety` | Focused two-host, two-edit, two-journal-generation companion: retained-coverage advancement, equality-only mismatch recovery, a third cleanup checkpoint, independently reordered provider delivery/deletion, process crashes at four persistence boundaries, reader-visible omissions, and writer-machine loss from every post-install phase with explicit accounting for work that had never left that machine. |
| `JournalRecoverySafety` | Integrity-valid ordered prefixes, torn/corrupt suffixes, exact-base update/delete/settings replay, already-represented cleanup, conservative base-mismatch salvage, and root-specific cleanup durability. |
| `MultiJournalRecoverySafety` | Three records across two journals and two notes: fixed order inside one journal, every cross-journal interleaving, independent and concurrent updates, cross-journal and within-journal delete/update cases, duplicate idempotence, anti-resurrection, base-mismatch rejection, and per-journal cleanup only after complete checkpoint coverage. |
| `JournalLaneIndependence` | Two admitted edits progressing through append and barrier-sync while provider work may remain permanently stalled; weak fairness applies only to NV's local durability actions. |
| `ReconciliationSafety` | Canonical, unresolved, and nonlocal note-file versions; stable identity, unambiguous filename/content fallback, ambiguity, path/timestamp rejection, and no-match handling; fast-forward, one-sided unchanged edits/deletes, orthogonal and simultaneous content/rename changes, two-edit merge, missing/unsafe bases, delete/edit and rename/delete conflicts, pure and content-bearing rename races, an independent scenario outcome/artifact oracle, complete and partial enumeration, independently changing provider catalog tokens and persistent version identifier sets, non-reusable root session incarnations, structure/UUID-LSN validation, dirty follow-up scans, provider-version resolution eligibility, and historical durability. |
| `ReconciliationDecisionSafety` | Exhaustive conflict-decision kernel over all twenty-two fixtures and every order of canonical, unresolved, and nonlocal processing; independent outcome/artifact oracle, identity evidence, conflict provenance, identity-bound name-independent deletion representation, and no-loss interface discharge. |
| `ReconciliationFencingSafety` | Exhaustive transaction-control abstraction for complete/incomplete enumeration, readable/unreadable and represented/unrepresented versions, independently changing provider catalog tokens and persistent version identifier sets, root session incarnation replacement, note/structure changes, complete publication versus partial preservation, provider-version resolution eligibility, complete-commit dirty recalculation, retry-path dirty retention, and transaction progress. |
| `CurrentVisibleFallbackSafety` | Stable-unsupported current-visible refinement with complete current fences, preexisting exact resolution eligibility, operational dirty-generation consumption, retries after unreadable/stale inputs, and independent stable-unsupported requalification after root-session replacement. |
| `StartupSafety` | Paused-item repair before freshness, current/stale/unmaterialized/absent/unavailable/corrupt or unacceptable checkpoints, provider-current parent authority, explicit versus operation-owned creation with a fresh installed checkpoint before journal publication, mandatory legacy-before-active-before-uncovered-retained recovery, covered-retained fast startup, offline eligibility, all-or-nothing note-file rebuild from absent or unacceptable checkpoint state using either a complete exact snapshot or documented-stable-unsupported current-visible snapshot, expected-absence or opaque exact-predecessor-incarnation installation, same-status predecessor replacement and no-install mismatch, limited-history presentation for the fallback, late arrivals, exact replacement verification, and accepted-checkpoint/fresh-journal-before-editing ordering. |
| `RecoveryEvidenceSafety` | Routine-sync isolation of database and unclaimed-journal evidence, all-version persistent version identifier snapshots, canceled/partial/failed recovery, deterministic conflict identities and tombstones, duplicate and identical-live suppression, ignored deletion/settings evidence, database-version-only transient resolution eligibility, one-confirmation discard, later arrivals, and preservation while a remote journal writer may exist. The generic later durability chain is deliberately delegated to `ReconciliationSafety`. |
| `StorageTransitionSafety` | Controlled restart from incompatible storage, old-format checkpoint and journal retirement, idempotent plaintext export, divergent external files, provider catalog token fencing, copy-on-write remembered-credential provisioning for encrypted rekeying, target-item read-back before checkpoint cutover, post-commit old-item cleanup, artifact-directed crash retry without a phase ledger, and format/key/credential agreement before editing. |

The specification's stable requirements map to these existing mechanisms rather than to duplicate prose in each model: `AUTH-01` is refined by root-incarnation fences; `START-01` by `StartupSafety`; `DISC-01` and routine `PUB-01` by the reconciliation models; `REC-01` by `RecoveryEvidenceSafety`; `DUR-01`, `QUAL-01`, and `CLEAN-01` by the quit, journal, recovery, and cross-machine models; `ROOT-01` by their edit/publication/cleanup guards; and `CKPT-01` by startup, quit, and transition installation boundaries. `CAP-01` and `WAIT-01` are Apple/UI refinement contracts and do not create TLA+ success transitions.

Run the complete finite configurations with a released `tla2tools.jar`:

```sh
for model in \
  QuitSafety \
  JournalLifecycle \
  HostLocalJournalOwnership \
  CrossMachineDurability \
  CrossMachineGenerationSafety \
  JournalRecoverySafety \
  MultiJournalRecoverySafety \
  JournalLaneIndependence \
  ReconciliationSafety \
  CurrentVisibleFallbackSafety \
  StartupSafety \
  RecoveryEvidenceSafety \
  StorageTransitionSafety
do
  java -XX:+UseParallelGC -jar /path/to/tla2tools.jar \
    -workers auto \
    -lncheck final \
    -coverage 60 \
    -metadir "/tmp/notation-tlc-$model" \
    -config "docs/tla/$model.cfg" \
    "docs/tla/$model.tla"
done

# Keep provider fairness out of the safety configuration. This second run puts
# the two explicit fairness assumptions into the specification and checks the
# convergence leads-to properties directly over the same state graph.
java -XX:+UseParallelGC -jar /path/to/tla2tools.jar \
  -workers auto \
  -lncheck final \
  -coverage 60 \
  -metadir /tmp/notation-tlc-CrossMachineConvergence \
  -config docs/tla/CrossMachineConvergence.cfg \
  docs/tla/CrossMachineDurability.tla
```

## Hybrid reconciliation checks

`ReconciliationSafety` is the integrated model. Its explicit graph combines
conflict artifacts, transaction interleavings, and durability history, so it is
also checked by three additive lanes:

1. `ReconciliationDecisionSafety` exhaustively checks conflict semantics and
   proves provider-version representation for every selected readable version,
   including explicit decision ancestry for one-sided local wins.
2. `ReconciliationFencingSafety` exhaustively checks that the shared interface
   can publish a complete exact transaction only through the exact provider fence
   and unchanged model/root inputs; partial evidence remains preservation-only.
   `CurrentVisibleFallbackSafety` separately starts after a documented stable
   unsupported historical-version result and proves that the narrower current
   fences may consume only their serviced dirty generation without changing any
   eligibility earned by an earlier exact transaction.
   Provider catalog token values are normalized to transaction-relative changed
   flags because the procedure observes only equality with its snapshots. Transaction scratch
   state is canonicalized after its historical witnesses are recorded. This
   keeps every before/after-fence ordering and arbitrary repeated transactions
   while removing absolute history that cannot affect a later decision.
3. Seeded `ReconciliationSafety` simulation checks the unchanged integrated
   state machine for every named scenario, including longer traces that a
   breadth-first run has not reached.

`ReconciliationInterface` contains the shared predicates used by the two small
exhaustive models. The integrated module deliberately remains independent and
retains its own guards and oracle, so a shared mistaken implementation cannot
make every lane pass in the same way.

The runner executes the two exhaustive models first and then four reproducible
simulation seeds for each of the twenty-two scenarios:

```sh
docs/tla/run-hybrid-reconciliation.zsh /path/to/tla2tools.jar
```

The default simulation budget is 10,000 traces of depth 100 per scenario and
seed. `HYBRID_TRACE_COUNT`, `HYBRID_TRACE_DEPTH`, `HYBRID_SEEDS`,
`HYBRID_SIMULATION_WORKERS`, `HYBRID_OUTPUT_ROOT`, and `JAVA_BIN` may override
the run without changing a model. The total trace count must divide evenly
across the worker count because TLC applies its `num` limit per worker.
Generated configurations, logs, counterexample traces, and TLC metadata are written
under one timestamped `/tmp/notation-tlc-hybrid-*` directory.

### Fast sampling-only reconciliation subtests

For a rougher, faster sampling-only pass, skip the two exhaustive kernels and
run each integrated reconciliation scenario once with a smaller trace budget.
From the repository root in `zsh`:

```zsh
set -euo pipefail

jar=/path/to/tla2tools.jar
output_root="/tmp/notation-tlc-reconciliation-sample-$(date +%Y%m%d-%H%M%S)"
workers=8
total_traces=1000
depth=50
seed=2026082401
(( total_traces % workers == 0 ))
traces_per_worker=$((total_traces / workers))
scenarios=(
  fastForward twoEditsMerge missingBase unsafeMerge
  deleteEdit localDeleteRemoteEdit renameRace renameOnlyRace
  renameRemoteEdit unmatchedIdentity ambiguousIdentity
  pathTimestampIdentity filenameContentIdentity multiVersion
  localEditRemoteUnchanged remoteRenameLocalEdit
  remoteRenameOnly localRenameRemoteUnchanged
  localRenameRemoteDelete localDeleteRemoteRename
  localRenameTwoEditsMerge remoteRenameTwoEditsMerge
)

mkdir -p "$output_root"/{configs,logs,states,traces}
for scenario in $scenarios; do
  config="$output_root/configs/$scenario.cfg"
  log="$output_root/logs/$scenario.log"
  sed "s/@SCENARIO@/$scenario/g" \
    docs/tla/ReconciliationSimulation.cfg.in > "$config"
  java -XX:+UseParallelGC -jar "$jar" \
    -workers "$workers" \
    -simulate "num=$traces_per_worker" \
    -depth "$depth" \
    -seed "$seed" \
    -coverage 1 \
    -teSpecOutDir "$output_root/traces" \
    -metadir "$output_root/states/$scenario" \
    -config "$config" \
    docs/tla/ReconciliationSafety.tla 2>&1 | tee "$log"
  ! grep -q '^Error:' "$log"
done
```

This samples 1,000 total traces of depth 50 for each of the twenty-two
subtests. `total_traces` must divide evenly by `workers`; TLC's `num` value is
per worker. Increase the trace count and depth, or repeat with different seeds,
for stronger sampling. This shortcut does not run the exhaustive decision and
fencing lanes and is therefore a smoke check, not an acceptable complete
hybrid result.

A simulation success is evidence of no violation in those sampled behaviors,
not a proof. A partial exhaustive checkpoint can be resumed only with its exact
module and configuration; new properties are never claimed to have been
retroactively checked over its fingerprints. The hybrid result is acceptable
only when both small exhaustive queues drain with every property satisfied,
all scenario/seed simulations finish cleanly, intended action coverage is
nonzero in aggregate, and the mutation controls still fail for their intended
reason.

`RecoveryEvidenceSafety` deliberately stops when a complete exact recovery adds
database-version identifiers to the transient shared eligibility map. It models
no recovery-specific checkpoint boundary. `ReconciliationSafety` independently
proves that an identifier from that map can resolve only after representation,
file durability, checkpoint coverage, and exact upload confirmation;
`QuitSafety` models the root-closing checkpoint and override boundary.

`StorageTransitionSafety` treats Keychain bindings as host-local artifacts, not
provider state. It explores fresh add/read-back, checkpoint cutover, crashes,
orphaned target items, and optional post-commit old-item removal, but assumes the
truth of each Security-framework success or failure result. AV-14 supplies the
real-system refinement; neither the model nor the implementation assumes a
transaction spanning Keychain Services and checkpoint replacement. Encrypted
**Save Current Collection As…** reuses the model's fresh add/read-back-before-
install obligation but not its same-collection old-item deletion action. The
model contains one collection and therefore does not prove that two Save-As
destinations own distinct items; AV-14's deterministic multi-destination test is
the required refinement of that implementation rule.

Every configured invariant and temporal property must pass, every modeled
action and intended conflict branch must have nonzero coverage, and the state
queue must reach zero. A large generated-state count alone is not a correctness
result.

`ReconciliationSafety` may be checked as disjoint `EnabledScenarios`
partitions when one all-scenario fingerprint set becomes disk-bound. The
scenario never changes after initialization, so this is an exact partition of
the same state graph: the partition sets must be nonempty, pairwise disjoint,
and have union `Scenarios`; every partition must drain its queue and pass all
properties, while their aggregate coverage must reach every intended branch.
The checked reconciliation matrix has twenty-two named fixtures; it includes both
directions for one-sided edit, rename, and delete interactions without claiming
to enumerate every semantically equivalent replacement value.

The configurations use small symbolic sets: two note mutations or file states,
three version roles, two root session incarnations, bounded generation changes, and enough
fresh IDs for the modeled installations. UUID exhaustion is outside the
abstraction, so fresh-ID progress properties explicitly stop making claims once
the finite test set is exhausted. Reconciliation uses one representative
content or rename mutation per transaction because the transaction fence
observes the resulting LSN inequality, not the replacement value. Weak fairness
is applied only to work NV controls once it remains enabled in the safety
configurations. The separately named `CrossMachineConvergence.cfg` is the sole
counterfactual provider-fair run: it assumes only settled-note upload and
delivery to the reader so that direct convergence can be checked. No safety
result assumes that a provider, network, user, or unreadable artifact eventually
succeeds.

A verified same-directory move under unchanged provider authority is stuttering
at the reconciliation abstraction: path text is not a model input, so the move
changes neither structural state nor root session and existing fences decide
publication normally. A provider authority/account change instead refines to
`ReplaceRootSessionIncarnation`, `ReplaceRootSessionIncarnationWithSameInputs`,
or `ReplaceRootSession`; the captured-session mismatch rejects work from the
former authority even when every visible file input is identical. AV-08 and
AV-09, rather than TLC, establish directory and opaque-domain continuity.

Provider-authority uncertainty with an otherwise valid rooted journal is also
stuttering for edit durability: provider publication remains disabled by the
existing authority fences, while local edits use the unchanged journal path.
Vnode deletion or revoke, deletion accommodation, or an append/outbox/barrier
failure instead selects the durability reason in one concrete main-thread
edit-admission mask and removes edit actions until rooted identity, namespace
recoverability, and journal durability are revalidated. The lifecycle reason in
that same mask refines the existing modeled quiescing/transition phases; the two
reasons have independent owners and clearing either cannot clear the other. The
models do not represent the reason mask or transient UI gate; they already assume
the truth of local journal-durability results and apply no fairness to an
unavailable filesystem. Removing edit actions on failed durability therefore
strengthens safety without changing a modeled transition or liveness promise.
AV-08 and fault-injected WAL tests establish the concrete gate and resumption
conditions.

Confirmed namespace deletion is terminal for the old root session rather than
a reconciliation transition: cancellation makes every captured completion
ineligible, and NV publishes no checkpoint, cleanup, or merge into that root.
**Re-open from Disk** begins ordinary startup under a fresh session. **Save
Current Collection As…** constructs an independently and exclusively created
root from the frozen live store, using the modeled checkpoint-verification and
storage-transition boundaries without claiming a transaction with the deleted
root. A remembered-encrypted destination must additionally take the modeled
fresh credential provisioning precondition and may never take source-item
cleanup. The current models do not prove cross-root construction, independent
credential ownership, or its UI; AV-08, AV-14, and deterministic exclusive-
create/export/crash tests establish them.

Most models abstract checkpoint installation as an enabled atomic action. The
implementation's mandatory expected-current bytes/available-local-version
compare-and-swap removes that action when a locally observed checkpoint changed;
it never enables an install, cleanup, or publication forbidden by a model.
`StartupSafety` additionally makes the rebuild boundary explicit: absent-root
rebuild carries expected absence, an unacceptable predecessor carries an opaque
exact incarnation, and appearance or even same-status incarnation replacement
takes a no-install discovery restart. Every successful rebuild installation
records the raw status and incarnation comparisons. Other checkpoint callers retain the
safety-strengthening refinement: mismatch leaves the prior checkpoint and
journal/claim intact and takes the specified pre-install failure/override branch.
Concurrent server state not yet visible locally remains covered by the
independently modeled exact-upload qualification or retained-journal fallback.
Deterministic accessor-race tests must establish the concrete no-write boundary.

Provider-backed `confirmedGone` similarly refines the models' positive-deletion
environment input only after a vnode delete plus the AV-08-validated reverse
File Provider lookup returns exact-domain `NSFileProviderErrorNoSuchItem` for the
captured item. A surviving same-pair URL or every ambiguous/error result leaves
that input false. TLC does not validate this Apple API classifier.
Because the policy grants no new old-root publication or destructive action,
it changes no existing TLA+ transition or safety predicate.

`CrossMachineDurability.cfg` therefore checks no-loss, deletion-ordering,
startup, and host-locality safety with no provider fairness.
`CrossMachineConvergence.cfg` instead conjoins fair settled-note upload and
reader delivery with the specification, then checks direct leads-to properties
for arrival in the reader replica and final representation. This avoids relying
on a fairness implication whose semantics are sound but whose antecedent is
hard to audit for exercised behavior. Mutation controls must fail when foreign
preference claims are erased by a host action, journal deletion bypasses exact
uploaded-checkpoint coverage, reader reconciliation is disabled, or either
fair note-delivery action cannot reach the reader replica.

The larger glue model deliberately retains one edit. Its companion
`CrossMachineGenerationSafety` fixes exactly two distinct edits and two journal
generations, with checkpoints 0–3, so deleting one generation cannot be hidden
by survival of the other. It explores synchronized retained-coverage
advancement plus process crashes before first-claim synchronization, after the
second checkpoint but before advancement, before advancement synchronization,
and after local journal removal but before provider deletion. Writer-machine
loss is available from every post-first-checkpoint phase. Work that had never
reached any remote replica at physical machine loss is recorded as outside the
distributed guarantee; every other acknowledged edit must remain recoverable.
The model also requires a reader that observes reordered deletion while still
omitting the edit to remain dirty. Provider uploads and reader deliveries remain
unfair and independently ordered. This keeps the complete companion to a few
hundred thousand states rather than multiplying the larger model's startup,
preference, and delivery dimensions.

`MultiJournalRecoverySafety` similarly begins after the valid-prefix parser
boundary proved by `JournalRecoverySafety`. One journal has an ordered
two-record prefix while the second journal may interleave at every legal point.
The model requires every nondeletion update to remain canonical,
conflict-preserved, idempotently duplicated, superseded by a later same-journal
record, or durably checkpoint-covered. It checks both within-journal
delete-then-update and update-then-delete semantics, cross-journal races,
equal-state deduplication in either journal order, and anti-resurrection after
an applied delete. `JournalRecoverySafety` independently retains its existing
already-represented duplicate scenario. `JournalLaneIndependence` gives
ADR-0010 its separate progress check:
provider completion has no fairness and becomes permanently disabled after a
stall, while weakly fair append and barrier-sync actions must still make every
admitted edit durable. Coupling either local action to provider availability
violates that property.

The negative controls for these companions must fail: omit `edit1` from the
cleanup receipt while allowing both journals to disappear; permit provider
deletion without the captured checkpoint authorization; reverse the two
same-journal records; create a conflict for an identical record; resurrect a
note after its terminal ordered delete; let a cross-journal update overwrite an
earlier one instead of preserving it; or add provider availability as an append
precondition. The checked configurations report violations of the corresponding
coverage, order, idempotence, anti-resurrection, update-preservation, and
provider-independent durability predicates.

The `StartupSafety` expected-current negative control must likewise fail when
`InstallRebuildCheckpoint` omits incarnation equality while the same-status
predecessor-replacement action remains enabled.

The `JournalLifecycle` deletion-order negative control must fail when either
startup pruning or ordinary cleanup can add a final claim-clear witness before
the absent journal instance enters `directoryDurableDeletions`.

Atomic replacement, truthful success from the modeled directory-synchronization
action, immutable persistent version identifiers, the truth of any implementation assertion that authoritative
candidate discovery is complete, correct checksum/decoder results,
advisory-lock behavior, and coordinator accessor semantics are environmental
assumptions at the points named by the actions. Recovery-evidence readability
varies before a run and for each unprocessed immutable snapshot member; after a
version has been read or failed, later access changes wait for the next run and
cannot alter that disposition.
The discovery abstraction begins after Apple has disclosed the candidate URLs
and version identifiers for a transaction; it contains no Spotlight or
`NSMetadataQuery` state. Removing a metadata-query startup/reconciliation gate
therefore does not change a modeled transition, fairness assumption, or safety
predicate. Coordinated catalog completeness, absent-current historical-version
discovery, and callback-to-catalog visibility remain environmental contracts in
[Apple API Contract Validation](../Apple-API-Contract-Validation.md). If any of
those contracts cannot be established, the implementation must use the modeled
incomplete/dirty path rather than claim `CompleteFence`.

The reconciliation decision models treat `BaseState` as an already validated
merge base and do not distinguish whether its bytes came from an exact accepted
note-file snapshot or from an accepted checkpoint whose installation boundary
had settled that note's separate-file obligation. The concrete implementation
must enforce that source precondition and replace a checkpoint seed with every
later exact accepted snapshot; fault-injected merge tests, rather than another
distributed transition, establish that refinement.

The models likewise classify identity evidence as stable, unambiguous
filename/content fallback, ambiguous, or absent, but do not execute the concrete
matching passes. Epoch 5 deliberately applies unique stable filesystem identity
across the complete candidate set before filename and then content fallback on
the still-unmatched candidates. Rename-plus-old-name-reuse and same-name safe
replacement tests establish that ordering; the modeled decision begins only
after association has produced its evidence class.

In the reconciliation models, `Versions` is the complete set for every authoritative note candidate, including a candidate whose current catalog entry did not change and a visible `Title (conflict recovery <UUID>).ext` note file. The fixed checkpoint, legacy/modern journals, `.nv-root.lock`, and hidden `.nv-write-<UUID>` residue are the disjoint status/recovery projection: they cannot enter the note decision kernel or keep an otherwise complete note generation dirty. This partition is an implementation refinement of discovery, not another modeled version role; AV-03/AV-05 and artifact-churn integration tests establish it.

The journal models intentionally split ownership from replay semantics. `JournalLifecycle` blocks automatic action for ambiguous active claims, models pending versus directory-durable removal, and requires both restart pruning and ordinary cleanup to cross the directory-synchronization boundary before final claim clearing. `MultiJournalRecoverySafety` supplies the order-independent replay and one-covering-checkpoint obligations used by explicit all-candidate recovery. Their composition, UI availability, exact candidate snapshot, cancellation before irreversible member transition, persistence of completed cleanup/demotion, and fresh-journal suppression after partial failure are integration obligations; TLC does not prove the controller route between those two abstractions. `StartupSafety` likewise abstracts rebuilt notes after complete input selection and does not choose a concrete separate-file format. It does model the rebuild predecessor as an opaque incarnation that can change without changing corrupt/invalid status. Exact-scope selection of every disclosed current/historical version, built-in extension mapping, candidate-URL decoder assignment, explicit decoder/Ignore choices, per-file decoding, provider-managed plaintext export, the newly extended formatting-loss disclosure, and mixed ordinary-local target selection are deterministic bootstrap tests, not new distributed transitions.

`ReconciliationFencingSafety` models authority change as the atomic promotion of a fresh session incarnation. The implementation's authority-fenced old session and nonpublishing provisional successor refine to stuttering before that transition: neither may publish provider-derived results or authorize cleanup, while local WAL durability remains outside this model.

The models likewise contain no provider-brand classifier or persisted capability
profile. Positive provider-management evidence and each operation's advertised
capability and actual result refine the existing authority, success, failure,
complete, incomplete, current, and unknown inputs. `CurrentVisibleFallbackSafety`
models the routine-reconciliation form of the narrower exception after
`NSCocoaErrorDomain/NSFeatureUnsupportedError` establishes the session's
historical-discovery ceiling: its session-scoped
commit may consume accounted operational dirty state but cannot add or remove
resolution eligibility. `StartupSafety` separately models the bootstrap-rebuild
form, which may publish only a complete stable current-visible snapshot and must
retain session-continuous limited-history presentation. Neither form grants or blocks the
independently modeled exact checkpoint upload qualification. Transient or
ambiguous failure cannot select either branch, and no capability result
authorizes any other fence, resolution, or journal cleanup that the corresponding
model forbids.

The models do not prove the Objective-C implementation, Apple API behavior,
cryptographic encoding, the normative epoch-5 persistence layouts and vectors,
UUIDv5/SHA-256 byte vectors, UI disclosure,
thread affinity, redacted diagnostics, or epoch-4 archive compatibility. Those
remain integration, crash-point, vector, and implementation-review obligations.
The cross-machine model also does not model provider internals: its server
acceptance and per-host delivery actions are an interface that the independently
validated Apple API contracts must refine.
