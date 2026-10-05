# Deferred startup and history-query investigations

Date: 2026-10-04; updated 2026-10-08. Status: measurements and follow-up backlog.
Initial capture reuse is qualified; scoped queries and optional startup processing
are also qualified within their documented Runtime boundaries. Snapshot-root retention coverage
uses the qualified general-v2 format; its [production report](snapshot-retention-coverage-validation.md)
records the chain and fan-in work bounds. The
[review report](../storage-review-follow-up.md) supplies executable witnesses;
sequential snapshot-root growth now has a strict one-root work assertion. The implemented
remedies now use ordinary strict assertions.

The three [implemented improvements](README.md) address interrupted verification,
repeated envelope decoding and repeated recovery graph construction. The initial
current-row capture now has the [4F remedy](../phase4-current-row-locality-maintenance-validation.md).
The [startup/scoped-query plan](startup-and-scoped-queries.md) and
[report](startup-and-scoped-queries-validation.md) record the two new remedies.
Independent concurrent root width remains for separate investigation. Measure against those
improvements as they land so a removed decoding cost is not attributed twice.

The [remaining Phase 4 plan](../phase4-current-row-locality-maintenance-plan.md)
orders production current-row/codec measurements and checked-capture reuse. The
separate startup/scoped-query increment now adopts required/optional scheduling;
snapshot retention uses its own production qualification report. Preserve the
strict work witnesses as further physical-I/O and concurrent-width measurements proceed.

## Initial current-row capture — implemented in 4F

**Evidence:** `REVIEW-START-1`. Opening plus the first host capture decodes every
current cell three times; the two-note witness observes six decodes. Healthy
returning startup still avoids old Changes payloads.

**Current result:** one checked opening capture is handed off once under fresh
owner/history/view/context/presentation fences. The two-note production witness
now strictly requires two decodes, instead of accepting six as a known issue.
The stale-first-handoff mutation fails at the actual consumed result. No public
API change or maintained cache was needed. Remaining allocation/cold-load and
larger production measurements are recorded in the 4F report. Independent
snapshot frontier width retains its separate scaling measurement.

**Candidate:** have opening return its checked complete row capture with the
session, rather than discard validated cells and read them again. Reuse a single
owned result, with a final owner/history/view fence; avoid introducing a second
maintained cache.

**Measure:** grow live note count and body size at fixed history; then grow history
at fixed current rows. Compare complete open-to-note/search-model time, decoded
bytes, allocations and peak live memory with equivalent host initialization.
Include the actual current-cell physical codec as it is qualified, distinguishing
uncompressed and zstd results. Report first-open/cold-read methodology separately
from warm repeated reads.

**Safety/decision gate:** stale capture after ready acceptance, same-prefix view
replacement, private settings and newer host input must retain existing outcomes.
Count all opening/capture paths, not only a new convenience API. Tradeoff: a public
result/API adjustment and explicit lifetime/publication ownership. This is a
relatively narrow candidate to evaluate first, subject to measured benefit.

## Scope Undo and conflict history reads — qualified

**Evidence:** `REVIEW-HISTORY-1`. Undo and conflict queries for an untouched note
previously built two full collection graphs, including bodies from unrelated notes.

**Current result:** indexed note-scope/current-head selection and one shared
checked envelope reader. Untouched-note/no-copy queries read zero envelopes;
fixed queried history reads one envelope at 64/256/1,024 unrelated actions.
Complete global conflict-copy IDs are preserved with one derived partial index
in private schema revision 3. Collection queries and command execution retain
their existing full path. See the linked validation report for executed checks.

**Candidate:** use indexed scope, note, represented-head and action relationships
to select the required records before opening their envelopes. Begin with queries
whose complete, fully represented scope can be established economically. Retain
the full traversal as a correctness reference and a route for genuinely broad work.

**Measure:** fixed queried-note history while unrelated notes/history grow, then
fixed total history while the queried dependency closure grows. Include empty
results, long note histories, multi-note actions, collection scope, compensation,
restoration and automatic/conflict-copy families. Record SQL work, envelopes and
bodies decoded, latency and memory. Count shared-envelope costs honestly: selecting
one member may require verifying a large envelope.

**Safety/decision gate:** compare independent Undo/Redo candidates, unresolved
alternatives and exact represented inputs with the full implementation. Cross-note
members, compensation prerequisites and related preserved notes must survive scope
selection. Tradeoff: a more involved dependency selector; some legitimate commands
still require collection-wide work. Adding persistent indexes needs a separate
schema/maintenance justification, not just a faster synthetic query.

## Optional snapshot work before editability — qualified

**Evidence:** `REVIEW-START-2`. A ready optional snapshot can trigger historical
verification before otherwise healthy current rows reached the host.

**Current result:** startup independently selects required Changes and their
prerequisites; successful checked publication reserves the existing receive owner
to drain optional work. Finite save interference uses existing completion
notifications. Required verification, reconstruction and history checks stay
ahead of publication. There is no new persistent queue or polling mechanism.

**Candidate:** persist the received root/pages and classify readiness by whether
the work is required for editable recovery or optional acceleration. Perform
optional verification after publishing healthy current rows, with an automatic
wakeup and the same complete verification before the snapshot becomes usable.

**Measure:** open the same current store with no ready snapshot, one ready optional
snapshot and several ready snapshots. Vary represented history, shared dependencies
and overlap with required Changes work. Report time to editable publication and
time to complete snapshot verification separately, plus first-save latency during
background work. Include parked inputs becoming ready during startup.

**Safety/decision gate:** the normative startup contract now distinguishes
required draining from deferred independent snapshots.
Required causal input, bootstrap, repair and known-history verification obligations
still gate editability. Tests must show deferred work resumes with no additional
file event, survives restart and isolates rejection. Tradeoff: snapshots become
available for acceleration later and queue classification gains explicit semantics.

## Snapshot-root retention growth

**Evidence:** `REVIEW-START-3`. Repeated independent snapshot roots accumulate in
the retained frontier; the eight-snapshot witness checks eight root envelopes on
returning startup even though logical history is fixed.

**Implemented direction:** [general v2 retention-parent links](snapshot-retention-coverage.md) between snapshots,
separately from their logical operation frontiers. A newer root covers prior
roots through genuine verified dependency edges while preserving their bytes.
The [production report](snapshot-retention-coverage-validation.md) records actual
v2 encodings, sequential chains and wide fan-in. The eight-snapshot witness now
strictly requires one startup root check. Arbitrary independent concurrent roots
remain frontier tips until explicitly covered; this residual width is distinct
from sequential growth.

**Measure:** fixed logical history/current notes with 1, 8, 64 and 256 snapshot
roots; compare linear publication with concurrent writers, delayed older roots
and repackaged history. Record returning leaf checks/bytes/time, new-root
verification cost and fresh-store reconstruction cost. A compact linear frontier
does not imply bounded width under arbitrary concurrent publication.

**Safety/decision gate:** preserve lost-required-history detection and exact
retention coverage across partial delivery, missing parents and restart. Logical
snapshot applicability must remain distinct from retention ancestry. Tradeoff: a
format revision and more verification/ancestry during construction and recovery.
Removing old roots from the pin without coverage changes the loss-detection policy
and requires an explicit decision; it is not a local index optimization.

## Common qualification and follow-up

Use independent semantic expectations alongside work measurements, both provider
profiles, debug/optimized builds and representative note sizes. Separate database
cache effects, file-cache methodology and physical I/O claims. Keep timing ratios
descriptive until stable workloads justify a threshold. Current-row startup,
ordinary-save work bounds, complete retained history and required private state
remain mandatory throughout.

After envelope and graph reuse, profile reduction itself: grouping existing graph
records by birth/scope within one job may remove repeated collection-wide searches.
Treat this as a secondary hotspot investigation with ephemeral state; measure it
before designing another index or cache.

Promote each candidate to its own implementation plan only after measuring benefit,
identifying its issuer/consumer boundaries and specifying failure/mutation tests.
Changes to public APIs, authenticated formats or startup scheduling must be
documented explicitly. No item here authorizes history pruning, reduced validation
or a weaker compiler/platform contract.
