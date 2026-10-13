# P5.3 — First real local repository exchange

Status: implemented and qualified for local exchange within the documented
platform, performance and physical-durability limits. See the
[evidence and remaining boundaries](03-local-repository-exchange-validation.md).
Dependency: [P5.2](02-immutable-files-and-namespace.md).

Testing: [discovery, delivery and live-state priorities](../phase5-provider-root-testing-plan.md#discovery-delivery-and-live-state--first-priorities),
P5-CREATE, P5-REJECT, P5-REPLAY and connected schedules S1/S2. Complete a real
disk-to-second-store path before connecting Apple APIs.

## Implementation

1. Add a narrow owner-issued publication capture of exact accepted objects and
   required descriptors at a checked history prefix. Reuse existing membership,
   dependency and sequence indexes. Select bounded batches rather than assembling
   the entire repository on every save/launch. Release SQL turns before provider
   effects; a retained database cursor must not span blocking transport work.
2. Consume captured bytes through P5.2's strict installer. Include complete known
   bootstrap/snapshot dependencies and descriptor retention. Publication ordering
   may reduce receiver waits, but correctness must tolerate every delivery order.
   Lost completion retries the same sealed bytes; equal installed finals still
   require their verification/barriers. Local save acknowledgment stays separate.
3. Implement protocol-scoped discovery under the owned root. Enumerate nested
   writer directories and descriptors with bounded work/memory. Decode an observed
   candidate's own identity, including a valid provider-renamed duplicate. Sequence
   holes and lower numbers appearing later remain eligible. A local scan position
   is neither causal order nor proof that a provider directory is complete.
4. Track discovery invalidation/progress within the session. An early empty pass
   cannot consume the only hint about still-undisclosed work. Ordinary subsequent
   discovery opportunities revisit applicable directories independently of a new
   callback; define and test those opportunities explicitly. Preserve candidates
   already handed to Runtime through its existing durable receive queue.
   Nested discovery retains a bounded parent/child stream stack so inspecting a writer preserves progress
   through its parent. Bound open resources by protocol depth rather than
   collecting every writer or object name in memory. Add interleaved parent/child
   resume, cancellation and generation-change witnesses at that connection.
5. Connect reads to `receive`, parking, dependency wakeups, rejection reporting,
   bounded validation, catch-up and checked headless publication. Use existing
   automatic validation resumption after finite save interference. A discovered
   object does not become a new local authored action just because it was received.
6. For an explicitly selected collection, connect discovered initial descriptor,
   root/pages and import closure to `BootstrapCandidate`. Keep incomplete retained
   input noneditable. Test interrupted continuation and separate concurrent
   bootstraps; explicit collection selection precedes editable opening. P5.5 later
   connects this mechanism to the complete startup/health decision boundary.

Use [the protocol](../../Protocol.md) for canonical paths and meanings, and
[CollectionCopies](../../../../NVStorage/Sources/NVStorageRuntime/CollectionCopies.swift)
for the existing complete-copy capture. Retain that full capture for explicit
copy; add only the bounded Runtime access needed by routine transport. Existing
`retainedObject(at:)` supplies exact single-object access but does not enumerate
an outgoing inventory.

## State and language boundaries

Keep accepted publication input, untrusted observed input, retained waiting input
and accepted history distinct. Capture factories remain within their checked
owner boundary; consumers check store, root session and lifecycle applicability.
Discovery binds the existing local-store incarnation or bootstrap connection UUID
alongside the selected store ID. Immutable results retain these values across
owner retirement; a reopened owner must obtain a fresh applicable turn.
Use immutable bounded batches and exhaustive outcomes for installed, waiting,
rejected, changed and unavailable work. Provider failure preserves local bytes.

Reuse durable accepted membership and queue records to recover after restart.
Session-local scan/capture cursors can accelerate a pass; they grant no persistent
completeness or cleanup authority. Demonstrate a missing obligation before adding
durable transport state. Retain all accepted history; publication/upload success
does not justify removing local objects or pruning provider files.

Rebuildable accepted-file hints use the existing private groups, freshly rooted
file fingerprints and exact accepted membership. Fingerprints survive ordinary
reopening; session/generation permissions govern the live operation separately.
Changed or malformed hints use the normal receive path. Successful retention can
record a hint before a parked object becomes accepted; reuse still requires
accepted membership, including after later prerequisite wakeup.

## Tests

- Create two independently owned private stores and repository directories. Save
  bootstrap/edit/Delete, install real files, discover them through the adapter,
  then exec fresh readers with ordinary selection/unlock inputs. Check exact bytes,
  membership, values, contexts and history using an independent inspector.
- Exercise child before multiple parents, encrypted input before descriptor,
  snapshot root before pages, shared envelopes, repackaged operations, renamed
  duplicates and concurrent branches. Crash after retention, after acceptance
  before completion, during catch-up and again during reopening.
- Run S2 with controlled directory visibility: an early empty pass, new writer
  directory, high child before low parent and no further hints. Drive only the
  implementation's ordinary discovery opportunities and require exact progress.
- Run S1's held result/newer edit or Delete through the actual receive/publication
  consumer, including equal visible body with changed represented context. Old
  completion cannot replace live state or clear the newer pending generation.
- Place malformed/unsupported/wrong-collection neighbors and blocked descendants
  beside valid work. Repeat rejection-write failure and restart; preserve bytes,
  actual blocking reason and eventual unrelated progress after storage recovers.
- Replay older local backups and duplicate delivery with fresh writer epochs/action
  origins. Check deletion against available accepted evidence, concurrent content
  preservation and fresh-birth Restore rather than unconditional global agreement.
- Measure selection/read/decoding and bounded resources as unrelated history grows
  through 64/256/1,024 actions. Keep publication/discovery costs distinct from
  healthy local startup; directory enumeration may grow with file count.

Add issuer/construction and same-type wrong-context probes. Target mutations at
missing dependencies, dropped dirty work, high-water filtering, duplicate logical
effects, early acceptance and stale publication. Require actual adapter reachability,
valid companions and intended independent failures for both profiles.

The [same-file directory-scan benchmark](directory-scan-performance.md) compares
the actual optimized Objective-C catalog with rooted listing, per-file
observations and complete unchanged discovery. It found substantial repeated
metadata/context-check overhead despite zero historical body reads. Keep this
cost visible independently of healthy current-row startup. The implemented
[bounded metadata and accepted-hint groups](bounded-discovery-batches-validation.md)
amortize checked root/database work and preserve per-object durable receive,
fresh buffered-name observations and independent later discovery opportunities.

The [bounded discovery batch plan](bounded-discovery-batches-plan.md) makes that
follow-up concrete: held-directory metadata, one indexed hint lookup per group,
partial-failure and stale-context tests, and paired integrated benchmarks.

## Exit gate

The first complete path works with real files: local save → strict installation →
second-store discovery/acceptance → checked values → fresh-process reopen. Delayed
prerequisites, missing hints, duplicate delivery and newer live work retain the
specified outcomes. Record this local baseline separately from P5.4's provider
qualification; uploading a file is not evidence that another store consumed it.

The [expanded P5.4 plan](04-apple-coordination-and-discovery.md#2-p53-closure-and-source-baseline)
records the remaining connections: actual coordination, presenter lifetime and
automatic callers for publication/discovery opportunities. Its first increment
preserves the qualified batch and persistent-connection paths before adding these
consumers; the opportunity enum alone is not a resumption scheduler.
