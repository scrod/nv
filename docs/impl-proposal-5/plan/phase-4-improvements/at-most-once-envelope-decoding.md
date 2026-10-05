# At-most-once envelope decoding per history traversal

Date: 2026-10-04. Status: implemented for `REVIEW-HISTORY-2`. The
[validation report](validation.md) records the shared reader, exact source
coverage checks and executed qualification. The
[storage review](../storage-review-follow-up.md) preserves the starting evidence.

## Goal and boundary

Build each required history graph by visiting its required Changes envelopes,
decoding each exact envelope at most once and extracting all applicable operation
and action records together. Preserve exact indexed membership, representative
references, duplicate equivalence, complete graph checks and final publication
fences.

The unit of this guarantee is one traversal attempt of one captured accepted
prefix in one owned private store. Within that attempt, each required SegmentID
has at most one envelope verification/decompression and one Changes payload
decode. A successful attempt visits every required envelope. Snapshot occurrence
audits and reference checks belonging to that traversal reuse its checked results.

An interrupted attempt can start again from retained bytes. Independent bootstrap
validation, a later graph traversal, or a different captured prefix can decode an
envelope again. Measure those phases and attempts separately as well as end to
end. [Reusing one graph across recovery batches](recovery-graph-reuse.md) addresses
`REVIEW-HISTORY-3` separately; this plan optimizes the graph each batch currently
requests. Qualify the traversal and recovery improvements independently and together.

The implementation adds traversal-local identifiers and checked values, using
existing database tables/indexes. Keep provider and private encoded formats,
persistent state and the ordinary current-state save path unchanged. The resulting
graph remains proportional to required history; temporary envelope buffers are
bounded independently of total history.

## Authority and evidence

- [Specification](../../../iCloud-Drive-Support-Spec.md): START-01, CKPT-01,
  DUR-01, HIST-01, PUB-01 and REPAIR-01.
- [ADR 0016](../../../adr/0016-repair-from-validated-immutable-copies.md) and
  [CONTEXT](../../../../CONTEXT.md): retained history, accepted prefixes,
  distinct graph relationships and ownership/applicability.
- [LocalStore](../../LocalStore.md), [schema](../sqlite-local-schema.md) and
  [S3/S4 plan](../phase4-bootstrap-reconstruction-plan.md): actual acceptance,
  snapshot verification and reconstruction boundaries.
- [Swift proposal](../swift-storage-library-proposal-v2.md),
  [conformance strategy](../swift-storage-conformance-testing-strategy.md) and
  [Phase 4 safety contracts](../phase4-data-safety-contracts.md): issuer/consumer
  restrictions, independent expected results and failure/mutation testing.
- [TLA coverage](../../../tla/README.md#private-sqlite-transaction-and-fast-start-mapping):
  modeled history/reconstruction conditions that this concrete optimization preserves.

Before this increment, `DatabaseLane.retainedGraph` walked operation and action indexes
separately. `Database.operation` and `Database.action` reopened and decoded their
whole source envelope for each requested member. Packed bootstrap envelopes thus
repeat substantial work. The 64-note review fixture used 88 decodes and about
2.28 MB of decoded payload for one graph.

`snapshotHistoryGraph` subsequently decoded accepted Changes objects again to
audit their occurrences. `CheckedSnapshotAcceptance.verifyWithGraph` decoded
preview-referenced envelopes again to check exact references. Include these
consumers when eliminating repeat work. Authentication and membership checks
remain required even when the same operation appears in several envelopes.

The [resource campaign](../phase4-bootstrap-reconstruction-validation.md) measured
roughly 11–13 seconds for complete 1,024-note initialization and 25–26 seconds for
2,048 notes. Those single-run totals include other work. Establish isolated graph
and reconstruction timings before claiming how much this optimization saves.

## Reader design

### 1. Capture the traversal and required sources

Capture store/collection/profile, database connection identity, verifier context
and accepted target `H` through the existing owned database lane. Record indexed
operation/action membership through `H`, including each existing representative
`source_object`, `source_index` and `first_seq`. Capture the scalar metadata that
the current reader verifies against decoded values.

Read compact metadata in bounded indexed pages. Reuse the graph's necessary
reference maps where possible. Build a short-lived distinct source-locator set
on the worker for ordinary full-graph reads; this set is much smaller than a
cache of decoded bodies. Deduplicate by full object identity, preserving exact
locator checks. Writer/sequence pairs alone do not identify an envelope.

Preserve two existing scopes explicitly:

| Consumer | Required envelope scope |
| --- | --- |
| Ordinary retained graph | Union of the representative source objects needed for operations and actions first accepted through `H` |
| Snapshot history/occurrence audit | Every accepted Changes envelope through `H`, including repackaged duplicates; also validate all representative source references |

Use the same envelope-processing routine for both scopes. A snapshot consumer
requires evidence of the complete occurrence audit. An ordinary command should
not begin reading arbitrarily many duplicate-only envelopes merely to use the
new reader. Capture those scope distinctions in restricted request/result types.

For complete occurrence audits, page accepted-object metadata using the existing
`accepted_objects(seq, object_id)` index and a strict keyset cursor bounded by
`H`. For representative reads, fetch the distinct captured sources directly.
Inspect actual query plans: avoid per-envelope full scans of operation/action
tables, large blocking sorts on the database lane and queries that hide required
missing bytes through an inner join. Keep snapshot roots/pages and unaccepted
candidates in their existing, separately classified paths.

### 2. Read one owned envelope and decode on the history worker

Fetch one required envelope's bounded immutable bytes and needed indexed metadata
under the owned connection. Check accepted membership through `H`, expected
locator, kind and selected context. Release the database lane before expensive
hash/AEAD verification, zstd decompression and record decoding.

Use the existing canonical envelope and Changes decoders exactly once on those
owned bytes. Process operations and actions from that one decoded payload. The
object-kind/profile checks and semantic canonicalization stay in force. Return
checked immutable records and small occurrence facts; preserve error provenance
when reporting back to the owner.

Begin with one envelope in flight per traversal. Stream metadata/occurrence rows
in bounded pages where an envelope contains many records. Yield between database
turns and envelopes; check cancellation at safe boundaries. A maximum-size
envelope remains one potentially substantial decode, so measure worker duration
and local-save latency rather than promising a fixed wall-clock yield interval.

### 3. Check records, occurrences and duplicate equivalence

For each processed envelope:

- Match decoded operation/action IDs and ordered record indexes to its stored
  occurrence rows in both directions. Catch missing, extra and misaddressed rows.
- Match representative metadata to the decoded record: kind, birth/action link,
  source index and acceptance sequence, plus applicable action origin/scope links.
- Compare repeated identities using the existing complete semantic equality
  rules. Equivalent repackaging contributes no second logical action; conflicting
  contents fail with the existing accepted-history classification.
- Preserve the stored representative references even when a different duplicate
  is encountered first. Enumeration order must not redefine source provenance.
- Decode the complete transport payload and handle every relevant member.
  A snapshot's operation cut is applied after constructing its checked history;
  another operation sharing that envelope can remain outside that cut.

At the end, compare reconstructed membership with the independently enumerated
operation/action indexes for `first_seq <= H`. An empty or truncated source
enumeration cannot certify a complete graph. Retain the existing private
`RetainedGraph` issuer's causal-parent, note-predecessor, complete-action,
scope-parent and previous-origin checks. Keep those edge roles distinct.

Release the temporary envelope/payload buffers after their required values and
checks have been incorporated. Avoid retaining duplicate body copies or large
source buffers through small slices. The graph owns the unique record values
needed by existing reducers.

### 4. Reuse checked occurrence evidence in snapshot consumers

Issue a restricted traversal result containing the checked graph, captured
context and, for a complete occurrence audit, explicit evidence of that coverage.
Snapshot reference consumers can then check exact locator/index/ID membership
using the already-audited immutable occurrence rows, with accepted sequence
bounded by `H`, and compare against the graph's semantic value.

This avoids retaining every decoded duplicate envelope in memory. Bind that
coverage to the exact owning connection, store, prefix and verifier. Its validity
relies on accepted membership and bytes being immutable under the existing owner;
later appended objects are outside its captured prefix. Recheck ownership and
health at consumption. Arbitrarily mutable or foreign SQL state grants no coverage.

Consolidate `snapshotHistoryGraph`'s audit into the envelope traversal, then adapt
`verifyWithGraph` to consume the coverage rather than reopen each referenced
Changes envelope. Verify non-representative duplicate occurrences just as strictly
as representative ones. A wrong snapshot reference remains an invalid snapshot
claim; a contradiction in retained bytes/indexes remains accepted-history damage.

Snapshot roots/pages and initial-bootstrap proof may have their own necessary
reads outside this traversal. Keep their counts visible in whole-operation
measurements. Extending byte reuse to those separate proof stages requires its
own explicit evidence boundary; do not relabel repeated calls to hide their cost.

## Concurrency, failure and Swift boundaries

The captured accepted prefix is immutable under append-only acceptance. A later
save can append work while an older graph is read. Include exactly the requested
prefix and preserve each caller's final applicability checks: deriving a fact
about `H` differs from installing it as Current after the target or view changes.
Same-target view replacement, closed ownership and wrong-profile evidence keep
their existing failure paths.

Keep database handles and SQL mutable state actor-isolated, with synchronous
transactions/turns. Workers receive owned `Sendable` inputs. Introduce a private
captured-read value and a restricted checked-result issuer only where they encode
these concrete boundaries. A metadata row or decoded payload cannot construct
complete graph or occurrence-coverage evidence. Prefer exhaustive scope enums
and explicit result types to flags; keep nominal operation/action indexes distinct.

Moving decoding off the database lane must preserve `checkingRetainedHistory`'s
health latch and durable damage-recording path. Worker errors return with enough
context to distinguish corrupted accepted evidence, unsupported history,
transient I/O, cancellation and invalid caller/snapshot claims. No partial graph
can reach a reducer or acceptance/installation consumer.

Coordinate with the [verification-reminder plan](durable-verification-recovery.md):
its reminder covers the full logical check, including final graph/occurrence
validation. Decoding an envelope once does not finish that operation's obligation.
This optimization contributes no separate persistent verification state. Keep
partial buffers and context local to an attempt; retries use freshly checked
ownership and retain exact accepted bytes and pending work.

## Implementation sequence

| Gate | Change | Required evidence |
| --- | --- | --- |
| E0 — Baseline and scope | Inventory every decode in graph/snapshot/reconstruction paths; add per-attempt/per-object observations and isolate timings | Existing repeated decodes are observed at the real envelope and payload decoder boundaries; healthy opening remains a zero-graph control |
| E1 — Shared reader | Capture representative metadata, enumerate unique source envelopes and decode each on the worker | Packed ordinary graph has exact membership/references and at-most-once decoding; malformed accepted bytes preserve health behavior |
| E2 — Complete occurrence coverage | Extend the same reader to the full accepted Changes scope; issue restricted coverage and adapt snapshot consumers | Duplicate/non-representative references and shared-envelope cuts remain correct; snapshot graph audits no longer reopen Changes envelopes |
| E3 — Races and recovery consumers | Exercise commands, snapshot capture/verification and current-row reconstruction through the reader | New saves can proceed; stale results cannot publish; final graph failures and crash/retry preserve required evidence |
| E4 — Qualification | Run the matrix, compiler probes, mutations and isolated/end-to-end benchmarks | REVIEW-HISTORY-2 becomes an ordinary passing assertion; measured costs and remaining graph-memory/repeated-traversal limits are reported |

Keep a test-only version of the old reader as a comparison while developing the
new one. Independently authored expected results remain the primary oracle; two
readers agreeing does not establish that either preserved the correct history.
Complete each gate with executable tests before expanding the consumers.

## Critical tests and negative controls

Use both provider profiles with the actual SQLCipher runtime. Apply TC-START-01,
TC-EVD and TC-ASY obligations, connected Phase 3 histories and S3/S4 preservation
checks from the conformance strategy.

| Case | Input or schedule | Required observation |
| --- | --- | --- |
| ED01 — Packing | Same independently expected history with one record per envelope, many groups per envelope and group/page boundaries | Equal identities, values, references and continuation; every required envelope and Changes payload decoded exactly once per successful traversal |
| ED02 — Identity/repackaging | Exact duplicate delivery, equivalent operations in new envelopes, mixed old/new operations, duplicate-only envelopes | Logical actions occur once; each scope reads its required objects; representative references remain the stored ones |
| ED03 — Shared snapshot cut | Imports plus later edits share an envelope; a snapshot represents only a proper complete cut | Outside-cut edits/conflicts survive reconstruction; no partially represented action becomes a valid cut |
| ED04 — Index/byte disagreement | Omitted/extra occurrence, wrong record index/ID, wrong source/sequence, missing BLOB, conflicting duplicate | Specific corruption/incompleteness outcome at the intended check, with valid neighbors succeeding; no partial graph publication |
| ED05 — Snapshot references | Exact reference to a non-representative occurrence; then alter its index, locator, kind or claimed ID | Valid reference works from checked coverage; invalid claims fail without manufacturing corruption of healthy retained history |
| ED06 — Concurrent history | Hold a decode; append a new action or repackaged envelope; complete the old traversal | Captured `H` excludes later membership; old facts remain scoped; full-view consumers recheck their actual target |
| ED07 — Ownership/late failure | Close/reopen, replace view at equal `H`, cancel during worker decode, or fail final graph checking | Stale consumers fail precisely; accepted data/private state remain intact; corruption still reaches the owning health gate |
| ED08 — Independent collections | Two stores with overlapping logical history; same-type wrong context or protection | Neither decoded values nor coverage from one owner authorizes the other |
| ED09 — Lifecycle results | Restore, reciprocal conflict copies, delete/edit preservation and Undo/Redo histories followed by rebuild/reopen | Independently expected contents, unresolved alternatives, identities, action relationships and next command candidates survive |
| ED10 — Scheduling/memory | Large envelopes and many small envelopes, with a local save admitted between read turns | Save completes under existing scheduling rules; temporary buffer count remains bounded while graph growth is reported separately |
| ED11 — Restart | Terminate during graph preparation and after history commit before derived installation; repeat an I/O failure on recovery | Fresh process reconstructs exact expected current state and retained history; attempts are separately counted |

Extend `packedBootstrapGraphDecodesEachEnvelopeOnce` beyond aggregate counters.
Count envelope opening and Changes parsing per `(attempt, SegmentID)` at their
actual execution boundaries. Require all expected IDs to be visited on success;
zero work or skipped duplicate validation cannot pass an at-most-once assertion.
Permit a failed attempt to end after its first failure and report its partial
coverage separately. Add explicit snapshot capture/verification/reconstruction
consumers so a helper-only improvement cannot conceal downstream repeat decoding.

Use ordinary-client, same-module and issuer-file construction probes for new
evidence, plus actual same-type wrong-context consumers. Mutations must reach
named assertions: reopen a decoded envelope; decode payload separately for actions;
skip an occurrence or final graph check; accept a conflicting duplicate; pick the
first encountered occurrence as representative; ignore `H`; substitute graph
membership for exact snapshot occurrence; suppress worker corruption; publish an
obsolete view. Preserve valid companions and nonzero discovery.

Fresh-process observers receive normal selection/unlock inputs and surviving
store files. Inspect exact envelopes and database membership independently of
runtime return flags. Keep termination, I/O failure, simulated persistence loss
and later corruption as distinct fault classes.

## Measurement, completion and limits

Measure optimized builds with fixture construction outside the timed region.
Time graph reading, occurrence/reference auditing, reduction and full reconstruction
separately, then measure complete initialization/opening as a separate workload.
Use warm-up plus repeated alternating baseline/new runs on the same immutable
stores. Label warm-cache results; cold-read qualification is a separate experiment.

Vary 64/256/1,024/2,048-note packed imports, fixed-current-note collections with
growing edit histories, packing density, representative versus duplicate-only
objects, and note sizes. Record per-ID decode counts, encoded/decoded bytes, SQL
statements/rows/query plans, worker/DB turn durations, save latency, live temporary
buffer high water and overall graph memory. Qualify the chosen source scope so
duplicate-heavy ordinary queries do not acquire an accidental all-object scan.

At-most-once decoding removes amplification by packed member count; graph work
still grows with unique required records and, for complete audits, all accepted
occurrences. Avoid claims of constant-memory history traversal or proportional
wall-clock speedup from a counter reduction alone. Scope narrowing, repeated
graph construction and optional-ready-snapshot startup scheduling retain their
separate review IDs.

Run affected debug/optimized suites, independent fixtures, construction probes,
schema/query checks, targeted mutations and fresh-process schedules on macOS
and Linux with existing strict flags. Audit worker/C-buffer ownership and run
applicable sanitizer checks. Record unavailable platforms explicitly.

Update the review report, LocalStore/implementation correspondence and common
qualification driver when the guarantee passes. Preserve existing TLA safety
conditions; this read-path optimization does not by itself change the modeled
durability or reduction policy. If implementation changes a captured-prefix,
ownership or publication assumption, update and run the applicable model family
before claiming equivalence. Physical power loss and arbitrary concurrent database
tampering remain outside these performance measurements.
