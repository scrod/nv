# Bounded discovery metadata and accepted-hint batches

Date: 2026-10-11. Status: implemented P5.3 performance follow-up, before P5.4
provider/host integration. The [qualification report](bounded-discovery-batches-validation.md)
records production witnesses, measurements and remaining platform boundaries.
The earlier prototypes in the [discovery work analysis](discovery-work-analysis.md)
remain planning measurements, distinct from production qualification.

## 1. Outcome and boundaries

Reduce the repeated work in an unchanged repository sweep at two boundaries:

1. Observe several leaves through an already-held directory, sharing root and
   ancestor checks around one bounded metadata operation.
2. Look up their accepted-file hints in one database turn, sharing context checks
   and using one indexed joined query.

Keep discovery proportional to disclosed filenames, with bounded resources and
opportunities for local saves between turns. Healthy current-row startup remains
independent of a repository sweep. Preserve public APIs, the default discovery
budget of 16 and maximum of 64, encoded formats, private schema and hint codec.
Use the existing listing stack, private groups, accepted membership, database
actor and receive machinery. Additional state is bounded, session-local stream
mode/buffering and immutable in-flight batch values.

Changed/unknown files keep the existing exact observation/read/receive path.
Acceptance transactions, barriers, receipts, pending-generation clearing and
single-file installation/replacement remain unchanged. Bootstrap candidates and
key descriptors retain their existing paths; only accepted segment objects
qualify for the hint shortcut. Parked/rejected input, first-publication hint
seeding, trigger coalescing and legacy catalog/copy optimizations are separate
work. In particular, keep the legacy reconciliation's two catalog fences.

Authorities: the [specification](../../../iCloud-Drive-Support-Spec.md),
[ADR-0013](../../../adr/0013-publish-exact-copies-of-durable-local-segments.md),
[vocabulary](../../../../CONTEXT.md), [Protocol](../../Protocol.md) and
[model boundaries](../../../tla/README.md). Use the
[conformance strategy](../swift-storage-conformance-testing-strategy.md) and
[Phase 5 testing plan](../phase5-provider-root-testing-plan.md) throughout.
Consult the [Apple API ledger](../../../Apple-API-Contract-Validation.md) for the
Darwin implementation. Batching changes observation cost, not file identity,
catalog completeness, deletion authority or acceptance semantics.

## 2. Preserve these contracts

| Boundary | Required guarantee |
| --- | --- |
| Native observation | Preserve raw leaf bytes and all nine existing fingerprint fields: kind, device, inode, size, link count, modification seconds/nanoseconds and change seconds/nanoseconds. Preserve no-follow and special-file outcomes. |
| Root ownership | Validate the same held root/ancestor chain before and after each bounded native operation and root permission around asynchronous handoffs. An old pathname must not retarget the owned object. |
| Hint reuse | Require a freshly rooted matching fingerprint, valid existing hint codec/length/digest and exact accepted membership in the intended private store. A hint miss selects ordinary read/receive. |
| Database context | Match the connection's checked store/descriptor and live history health for the batch. Physical ownership checks bracket the synchronous lane turn and each commit; fixed opening checks are reused for that connection's lifetime. Mutable hint contents and exact accepted membership are checked by the query consumer. |
| Receive | Each object's exact bytes enter the existing durable receive path independently. A later failure preserves earlier retained inputs; a batch completion is not an all-or-nothing receive transaction. |
| Discovery progress | Preserve nested parent/child progress, late/lower-numbered disclosure, provider-renamed duplicates and later ordinary passes after an empty or completed pass. |
| Live model | A discovery observation conveys transport results. Existing checked publication and generation matching remain responsible for live-note changes. |

A metadata group contains observations made during an interval, not a frozen
directory snapshot. File changes after a matching observation remain eligible
on later ordinary passes. A body read for a miss must still match its exact
captured observation before and after reading. Known history damage stays a
recovery outcome; it must not be converted into a cache miss or ignored because
all hint rows happened to match.

## 3. Increment 1 — freeze the baseline and batch contracts

Before changing production paths:

- Preserve source/toolchain hashes, baseline binaries or an isolated source
  snapshot, fixtures and raw results from the existing two benchmark drivers.
  Keep component measurements and complete production sweeps separately named.
- Add opt-in work counters at the actual native observation, database lookup and
  discovery consumers. Count metadata batches, ancestor opens/checks, hint-query
  batches, SQL statements/VM work/scans, physical-owner checks, actor turns, body
  reads/bytes and envelope decodes. Document measured versus source-derived counts.
- Add independent expected inventory/metadata/hint oracles and the mixed
  hit/miss, sparse-result and budget-boundary fixtures below. Retain the current
  single-leaf path as a test comparison while replacing the production caller.
- Freeze processing-budget and native read-ahead accounting. A consumed candidate
  costs the existing leaf step; a refill costs the listing step. Bound a native
  refill's entries and bytes separately, and prevent read-ahead from admitting
  extra SQL/body/receive work beyond the remaining turn budget.

Keep at most one outstanding metadata operation and one hint lookup for an active
discovery pass. Choose groups from the remaining turn allowance, capped at 64;
start with the existing 16-entry page size. Test budgets 1, 2, 16 and 64, including
changes between calls. Raw read-ahead is bounded to at most 64 names per active
directory stream and 16,320 name bytes (64 × the existing 255-byte leaf limit).
Cap the native packed buffer at 64 KiB and derive its actual read capacity from
the minimum record width so the returned record count is bounded as well. The
stack remains bounded by protocol depth. Record the actual tighter default and
resource high-water marks.

Gate: baseline assertions and new valid fixtures pass with the original path;
fault hooks demonstrably reach the intended production boundaries. No benchmark
or test result relies only on the optimized and original implementations agreeing.

## 4. Increment 2 — held-directory metadata batches

### Portable primitive first

Extend the private rooted listing boundary in
[RepositoryRoot.swift](../../../../NVStorage/Sources/NVStorageRuntime/RepositoryRoot.swift)
and [NVRepositoryFiles.c](../../../../NVStorage/Sources/CStorageIO/NVRepositoryFiles.c).
Observe a bounded set of named leaves with descriptor-relative, no-follow
`fstatat` through the held directory. Check its root/ancestor chain around the
group rather than opening that chain again for every leaf.

Return copied immutable per-entry observations or ordinary child failures.
Root/ancestor failure prevents issuing the group as applicable observations;
ordinary child failure preserves the sibling results. Keep the existing exact
read primitive for candidates requiring contents. Parent/child stream resumption
and same-owned-root movement must retain their established outcomes.

### Darwin bulk primitive

Use `getattrlistbulk` with the attributes needed for the same nine-field
observations. Reuse the legacy bulk catalog's algorithmic lessons, while keeping
the repository's raw names, fields and classification. Qualify this production
primitive rather than substituting the benchmark's regular-APFS-only parser.

- Parse record lengths, bounds, alignment, name offsets/lengths, returned-attribute
  masks and per-entry errors explicitly. Check integer conversions and allocation
  limits before accessing records. Injected malformed records exercise the parser;
  they are not evidence that Apple produced those records.
- Missing required attributes take a fresh descriptor-relative observation or an
  explicit unavailable outcome. Packed defaults must never become valid metadata.
- Choose one enumeration mode for a stream. `readdir` and `getattrlistbulk` must
  use separate enumeration descriptors. Define the supported capability-error
  fallback set from platform contracts; ordinary I/O or root failures keep their
  failure meaning.
- On a stream-level unsupported result, reopen in portable mode at most once for
  that stream/pass. Preserve consumed receive results and tolerate repeated names
  through existing idempotency. Avoid repeated fallback/restart loops or skipping
  an unread tail. Per-entry attribute fallback does not change enumeration mode.
- Bound packed reads by both bytes and maximum possible record count. Ensure the
  buffer accommodates a maximum valid leaf; small caller budgets must still make
  progress. Retain excess names in the existing bounded progress buffer.

### Buffer freshness and EOF

Use bulk attributes immediately for entries processed in the current turn.
Across a returned turn, retain only pending raw names/cursor progress, then obtain
fresh metadata for those names through the held directory on resumption. Discard
their old attributes. Keep the held stream usable until its buffered names are
consumed, even if the native enumeration has reached EOF. Close it only after
both native EOF and the pending-name tail are drained, or owner retirement.

This reuses the existing progress buffer rather than maintaining a second
metadata cache. EOF means the end of this local pass; a later ordinary opportunity
still starts a new pass. Invalidating a pass must not repeatedly restart it before
its already-disclosed siblings can progress.

Keep the public names-only listing and single-use cursor contract intact. The
EOF-tail lifetime change belongs to the internal discovery stream.

Gate: exact-field/raw-name comparisons, controlled native races, fallback/EOF and
mixed-budget tests pass for both primitives. Native pointer/buffer ownership stays
inside RootLane; production handoff carries immutable copied values only.

## 5. Increment 3 — one indexed accepted-hint lookup per group

Replace the per-leaf lookup in
[RepositoryDiscovery.swift](../../../../NVStorage/Sources/NVStorageRuntime/RepositoryDiscovery.swift)
with an internal bounded lookup for the eligible metadata entries. Enter the
existing database lane once and keep its operation synchronous:

1. Check lifecycle and capture the intended store incarnation before suspension.
2. Enter the physically checked lane turn, match its checked store/descriptor and
   require live history health. Opening established fixed schema/header/private
   context; mutable hint rows and accepted membership are read below.
3. Bind requested ordinal, hint key and fingerprint in one bounded `VALUES` CTE.
   Join `private_groups` to `accepted_objects` through the stored object ID, using
   the existing primary-key indexes. Use placeholders for all input values.
4. Verify each result's ordinal, codec, exact 96-byte payload, fingerprint, object
   ID and existing domain-separated digest. Initialize every requested answer as
   a miss and fill only independently verified hits.
5. Check ownership at completion and target lifecycle/root applicability after
   suspension, before consuming answers. Return a fully checked bounded result.

At 64 entries the proposed three-bind request uses 192 parameters; qualify that
against the actual linked SQLCipher build. Empty requests perform no hint query.
Keep sparse and duplicate-key requests correctly associated with their original
inputs. SQL may return fewer rows than inputs; positional zipping is unsafe.
Use an input ordinal plus exact captured request identity, not query row position,
to attach results. A malformed hint remains a miss for that input. A database,
ownership or required-state error fails the operation with its existing outcome.

Acceptance and settings changes before the lane turn are evaluated against the
actual lookup-time store. Other lane work cannot interleave within its synchronous
operation. The accepted-membership join establishes the existing shortcut only;
it issues neither new history acceptance nor authority over the physical file.

### Language-backed boundaries

Reuse `RepositoryEntryObservation`, `RepositoryObservationHint`, root permission
and existing store incarnation rather than adding another identity registry.
Use the smallest internal immutable batch wrappers needed to bind directory/root,
exact ordered requests and intended target. Confine constructors to the relevant
checked issuer; expose only read access needed by the consumer. Keep native
resources actor-isolated, reserve work before awaiting and recheck revocable
context at the consumer. Keep strict concurrency/Sendable checking; use closed
per-entry outcomes instead of parallel optional arrays.

Gate: production lookup matches independent expected IDs/misses, including sparse
and corrupted hints. Construction probes and same-type/wrong-context consumers
reject forged or stale evidence. Existing receipt and current-model boundaries
remain intact.

## 6. Increment 4 — connect the batches without changing receive

Process a metadata group in discovery order: report ordinary child failures,
look up eligible segment hints once, then reuse hits or perform the existing
exact read/descriptor/receive for each miss. Keep per-file hooks around actual
observation/read/durable handoff; add explicit batch-entry/lookup-return hooks
for deterministic schedules. A hook or fast/full comparison alone is not the
independent oracle.

Preserve successful bounded progress and every pending raw name at budget
exhaustion. Fatal handoff failure may retain the existing reset-and-revisit
behavior, with already admitted bytes owned durably. Close/cancellation keeps
entered operations and buffers owned until they settle, then retires streams.
No cancellation result implies rollback of a completed receive or hint write.

This increment does not implement the P5.4 trigger worker. Its integration
contract is unchanged: continue a pass until `passEnded`, coalesce overlapping
triggers in the eventual adapter, and preserve independent later ordinary
opportunities. A completed or empty pass cannot claim lasting completeness.

## 7. Race, failure and lifecycle qualification

Every family needs a passing companion, a controlled adverse schedule, actual
production-consumer reachability and independent observations. Use gates/entered
signals rather than sleeps. Inspect exact envelopes, accepted membership,
retained/waiting/rejected bytes, values/context and pending work as applicable.

| Family | Cases | Required observation |
| --- | --- | --- |
| P5-BATCH-META | Empty/one/full/overflow groups; 1/2/16/64 budgets; many writers; Unicode, 255-byte and invalid-UTF-8 names; regular files, symlinks, hard links and special files | Exact raw inventory and nine-field observations; explicit classification; bounded buffers; no dropped EOF tail or starvation of later directories. |
| P5-BATCH-PARSE | Unsupported bulk attributes/filesystem; per-entry errors; missing masks; truncated/overlapping records, bad offsets and lengths; long names under small budgets | Safe bounded parsing, fresh per-entry fallback and one-way stream fallback; siblings progress; no zero-default observations or endless restart. |
| P5-BATCH-ROOT | Rename/move/replace root, ancestors and writer directory before, during and after metadata; symlink substitution; root generation changes while lookup is held | Existing same-owned-object behavior or explicit stale/unavailable result; no retargeting, stale-result publication or leaked stream. |
| P5-BATCH-HINT | All hits, all misses and sparse mixed results; permuted rows; duplicate request keys; wrong codec/length/fingerprint/digest/ID; retained-but-unaccepted and rejected objects | Every answer matches its exact input; only verified accepted hits skip reads; malformed hints use normal read; actual store errors propagate. |
| P5-BATCH-CHANGE | Replace/truncate/edit a file after metadata, before/after lookup and during body read; change a buffered leaf between turns; safe-save rename | Across-turn metadata is refreshed; misses require exact coherent reads. A captured hit is only an observation of its matched generation; later changes remain discoverable, not permanently suppressed. |
| P5-BATCH-CONTEXT | Wrong store/descriptor, close/reopen, private-directory/database replacement, history damage, root retirement between capture/SQL/result consumption | Intended context/integrity rejection before an incompatible result is consumed; no conversion into a miss or successful empty batch. |
| P5-BATCH-PARTIAL | Fail native observation, lookup, receive, hint write or rejection write after earlier siblings; repeat failures, cancel, crash and fail again during recovery | Earlier retained inputs survive independently; remaining files stay retryable; accepted effects occur once; unrelated work resumes after storage recovers. |
| P5-BATCH-LATE | Empty pass then new writer; high child before multiple lower parents; renamed duplicate; parent later, without another callback | Normal later opportunities and durable wakeups accept exact closure; no filename high-water or callback-only shortcut. |
| P5-BATCH-LIVE | Hold metadata/lookup/receive completion; save a newer edit or Delete; deliver acceptance/settings changes; close or restart | Existing generation checks preserve newer pending work, durable history and retained frontier; no older body installed through batch completion. |

Exercise EIO, ENOSPC where a durable write is involved, busy/interrupted SQL,
allocation failure and error while recording rejection/damage. Distinguish native
child unavailability, root fencing, hint corruption and database failure. Separate
process termination, simulated persistence loss and later corruption in reports.

Connect both independently owned stores through real installed files for both
profiles: bootstrap → edit/Delete → out-of-order discovery → partial failure →
fresh-process reopen → retry. Include snapshot roots before pages and renamed/
repackaged objects. The recovering child receives normal selection/unlock inputs,
not the parent's expected-note or acknowledgment log. Independently verify logical
actions occur once and all required retained bytes survive.

Run many consecutive batches with local saves interleaved between database turns.
After finite interference stops, require automatic ready-work progress without
another incoming object or restart. Discovery itself uses its normal caller
opportunities; a harness must not invent a special retry path to qualify it.

### Compiler, mutation and model checks

- Extend ordinary-client and same-module construction probes for new batch/result
  evidence. Challenge same-type foreign root/store/session consumers separately.
  Keep strict debug/optimized builds and existing access-control probes.
- Target mutations at missing post-batch ancestor/context checks, missing required
  attributes, wrong ordinal mapping, omitted fingerprint/digest/membership checks,
  swallowed store damage, dropped buffered tails and premature EOF/receive
  completion. Require nonzero discovery, passing controls and the designated
  independent assertion. Retain existing pending-generation mutations.
- Fuzz the narrow packed-record parser with bounded input and valid companions;
  run C memory/conversion diagnostics, ASan/UBSan and applicable actor/cleanup
  TSan checks. Record unsupported sanitizer/platform combinations explicitly.
- Use [RepositoryDiscoverySafety](../../../tla/RepositoryDiscoverySafety.tla)
  and its runner together. Its current checks cover late disclosure, nested
  progress, durable handoff, dependency closure, logical-once effects and stale
  turns; native metadata and SQL correctness need executable evidence.
- Add a small two-entry batch/partial-handoff refinement or focused companion
  model for buffer-tail preservation across failure, generation change and
  restart. Preserve the existing assertions and all 15 runner cases. Add
  dropped-tail/stale-batch controls and reachability witnesses; keep bounds small
  and fairness assumptions explicit. Report finite exhaustive results separately
  from measured scheduling and physical durability.

## 8. Integrated benchmarks and work gates

Extend the existing [directory comparison](directory-scan-performance.md),
`tools/benchmark-storage-directory-scan.py` and
`tools/benchmark-storage-discovery-work.py`. Reuse the actual optimized
Objective-C bulk catalog as a comparison, including its intentional two-catalog
transaction cost. Keep its different fields/responsibilities labeled.

Compare original production, metadata-only, lookup-only and combined production
paths against identical fixtures. Use isolated benchmark builds/test variants;
production must have one qualified checked path, not a runtime validation-bypass
switch. Preserve old work counts as baseline evidence and assert the new batch
counts from observed executed batches rather than silently loosening assertions.

| Dimension | Required workloads |
| --- | --- |
| Size/history | 64, 256 and 1,024 real actions with fixed two-note size; larger opt-in directories, separately varying writer count and frontier width. |
| Hit rate | Fully unchanged accepted sweep; one new/changed file; mixed 1% changes; complete first delivery. Parked/rejected/bootstrap workloads are separately labeled. |
| Layout/budget | One and many writer directories; partial last pages and long names; budgets 1/2/16/64; native bulk and portable fallback. |
| Lifecycle | Reopen before unchanged sweep, late parent after empty pass, intervening saves, cancellation/close and fresh-process partial-failure recovery. |
| Platform/profile | Both profiles with encrypted private pages; current arm64 macOS, macOS 14 Intel, minimum macOS 11 Intel and Linux arm64 where available. Apple API claims require Darwin evidence. |

Measure end-to-end time from the first discovery call to `passEnded`, plus native
metadata, database lookup, actual receive and time to discover new work separately.
Measure healthy current-row publication separately to detect accidental scan gates.
Report local-save queue delay under a large sweep and the largest single database
turn; fewer total actor turns must not conceal worse save latency.

Strict work/resource gates:

- An unchanged accepted sweep performs zero provider body reads and zero
  historical envelope decoding, as before.
- Root/ancestor opens are amortized over held directory streams; checks surround
  each bounded operation. No hidden per-leaf ancestry reopen remains in the batch
  fast path. Actual changed-file reads keep their existing checks.
- A nonempty eligible hint group performs one indexed joined hint query, with
  exact in-memory connection-context matching and physical entry/exit checks.
  Fixed schema/header validation occurs once per opening. Keep zero full-table
  scans for hint selection and measure actual physical owner checks. The
  [connection-reuse increment](private-connection-reuse.md) qualifies these
  operation boundaries, including loss during commit and delayed completion.
- Batch/actor/SQL work follows actual group count, including partial pages and
  failures. The prototype's hypothetical 208 statements at 1,024 files is not an
  exact production requirement; production grouping and fences determine it.
- Buffers/descriptors and outstanding native/SQL work stay within the declared
  entry/byte/depth limits as repository size grows. Avoid per-file task fan-out.
- All variants independently verify inventory, exact accepted IDs, retained bytes,
  values/context and pending work. Timing success cannot compensate for a changed
  semantic result or a skipped difficult path.

Timing methodology: separate instrumentation passes from timing passes; warm up,
rotate variant order and retain at least nine warm samples with host/load/build
metadata. Report medians and ranges; use a larger sample run for tail latency.
Fresh-process runs are process-cold, not necessarily filesystem-cold. Qualify any
uncached/disk-image regime separately; do not label `F_NOCACHE` data reads as a
cold metadata catalog. Preserve raw samples and reproducible commands.

Freeze performance regression budgets from paired representative baseline runs,
as required by the overall testing plan. The engineering target is at least a
fourfold warm unchanged-sweep improvement at 1,024 files on the reference Mac,
with a substantial native improvement toward the actual bulk catalog. Treat this
as a target to validate, not a previously measured combined result or a universal
millisecond ceiling. Require improvement in the complete production sweep for
both profiles, acceptable small-directory/save-delay results, and explain the
remaining gap to the legacy catalog. If the target fails, investigate counters
and variance before reconsidering it; preserve every safety gate.

## 9. Delivery and completion

Complete each increment's valid/race/failure tests before proceeding. Run affected
debug/optimized suites, compiler/schema checks, targeted mutations, fresh-process
exchange and available platform qualification. Preserve existing epoch-4
compatibility and single-file/root tests. Record unavailable hosts, filesystem
capabilities and physical power-loss qualification explicitly.

Save implementation results, raw-artifact locations, baseline/optimized counters,
model correspondence and reproduction commands alongside this plan. Update the
P5.3 validation report, discovery contract and Apple ledger to describe the actual
qualified primitive and its fallback. Align normative wording/glossary only where
implementation requires a concrete contract clarification; batching must preserve
the existing guarantees. Product-policy changes require separate approval.

Complete when exact results, bounded resources, partial-failure recovery and
late-disclosure progress pass, and integrated measurements demonstrate reduced
work and latency without moving provider work onto the launch/save critical path.
Then connect the same boundaries to P5.4's coordinated intervals and coalesced
trigger worker, and repeat its actual provider/accessor qualification.
