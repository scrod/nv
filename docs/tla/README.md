# iCloud Drive TLA+ models

These models exercise the highest-risk safety boundaries and selected progress
requirements in `docs/iCloud-Drive-Support-Spec.md` and ADRs 0001–0012. They
are deliberately split by lifecycle so that one abstraction cannot satisfy a
requirement by silently borrowing state from an unrelated procedure.

| Model | Scope |
| --- | --- |
| `QuitSafety` | Final dirty-bit/provider barrier, admitted callback drain, WAL and note-file settlement, one frozen checkpoint, exact read-back, request/checkpoint/local-version upload identity, mandatory resume after a successful pause, explicit-path failure isolation from legacy qualification, reentrant termination, and journal-before-record cleanup. |
| `JournalLifecycle` | Directory lock, fresh journal IDs, synchronized header-before-claim-before-edit ordering, bookmark/root/header/base validation, stale bookmark refresh, copied folders, missing and ambiguous claims, ordinary-local unclaimed recovery, exact replacement qualification, and crash-interleaved offline handoff. |
| `JournalRecoverySafety` | Integrity-valid ordered prefixes, torn/corrupt suffixes, exact-base update/delete/settings replay, already-represented cleanup, conservative base-mismatch salvage, and root-specific cleanup durability. |
| `ReconciliationSafety` | Canonical, unresolved, and nonlocal note-file versions; stable identity, unambiguous filename/content fallback, ambiguity, path/timestamp rejection, and no-match handling; fast-forward, one-sided unchanged edits/deletes, orthogonal and simultaneous content/rename changes, two-edit merge, missing/unsafe bases, delete/edit and rename/delete conflicts, pure and content-bearing rename races, an independent scenario outcome/artifact oracle, complete and partial enumeration, independently changing provider catalog tokens and persistent version identifier sets, non-reusable root session incarnations, structure/UUID-LSN validation, dirty follow-up scans, provider-version resolution eligibility, and historical durability. |
| `ReconciliationDecisionSafety` | Exhaustive conflict-decision kernel over all twenty-two fixtures and every order of canonical, unresolved, and nonlocal processing; independent outcome/artifact oracle, identity evidence, conflict provenance, identity-bound name-independent deletion representation, and no-loss interface discharge. |
| `ReconciliationFencingSafety` | Exhaustive transaction-control abstraction for complete/incomplete enumeration, readable/unreadable and represented/unrepresented versions, independently changing provider catalog tokens and persistent version identifier sets, root session incarnation replacement, note/structure changes, complete publication versus partial preservation, provider-version resolution eligibility, complete-commit dirty recalculation, retry-path dirty retention, and transaction progress. |
| `StartupSafety` | Paused-item repair before freshness, current/stale/unmaterialized/absent/unavailable/corrupt checkpoints, provider-current parent authority, explicit versus operation-owned creation, mandatory legacy-before-active recovery, offline eligibility, all-or-nothing note-file rebuild, late arrivals, exact replacement verification, and fresh-journal-before-editing ordering. |
| `RecoveryEvidenceSafety` | Routine-sync isolation of database and unclaimed-journal evidence, all-version persistent version identifier snapshots, canceled/partial/failed recovery, deterministic conflict identities and tombstones, duplicate and identical-live suppression, ignored deletion/settings evidence, provider-version resolution eligibility, separate-file/checkpoint/upload durability, one-confirmation discard, later arrivals, and preservation while a remote journal writer may exist. |
| `StorageTransitionSafety` | Controlled restart from incompatible storage, old-format checkpoint and journal retirement, idempotent plaintext export, divergent external files, provider catalog token fencing, atomic new-format cutover, artifact-directed crash retry without a phase ledger, and format/key agreement before editing. |

Run the complete finite configurations with a released `tla2tools.jar`:

```sh
for model in \
  QuitSafety \
  JournalLifecycle \
  JournalRecoverySafety \
  ReconciliationSafety \
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
```

## Hybrid reconciliation checks

`ReconciliationSafety` is the integrated model. Its explicit graph combines
conflict artifacts, transaction interleavings, and durability history, so it is
also checked by three additive lanes:

1. `ReconciliationDecisionSafety` exhaustively checks conflict semantics and
   proves provider-version representation for every selected readable version,
   including explicit decision ancestry for one-sided local wins.
2. `ReconciliationFencingSafety` exhaustively checks that the shared interface
   can publish a complete transaction only through the exact provider fence
   and unchanged model/root inputs; partial evidence remains preservation-only.
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
is applied only to work NV controls once it remains enabled; no model assumes
that a provider, network, user, or unreadable artifact eventually succeeds.

Atomic replacement, directory synchronization, immutable persistent version
identifiers, the truth of any implementation assertion that authoritative
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

The models do not prove the Objective-C implementation, Apple API behavior,
cryptographic encoding, UUIDv5/SHA-256 byte vectors, UI disclosure,
thread affinity, redacted diagnostics, or epoch-4 archive compatibility. Those
remain integration, crash-point, vector, and implementation-review obligations.
