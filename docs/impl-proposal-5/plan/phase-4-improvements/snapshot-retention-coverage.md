# Snapshot retention coverage

Status: implemented and qualified within the portable Runtime boundary.
Executed checks, production measurements and remaining limits are recorded in
the [validation report](snapshot-retention-coverage-validation.md).

## Contract

The single current general-snapshot v1 format includes canonical exact
retention-parent locators as tag 8 records in the existing paged manifest. Its
236-byte root always contains eight counts, including zero for an empty parent
set. Initial-bootstrap encodings and public Runtime methods keep their existing
shapes. All segment formats remain unreleased; the compatibility boundary is
epoch-4 opening, recovery and explicit export, rather than earlier draft bytes.

A parent link covers an already accepted supported snapshot root and its
previously validated object closure. It preserves bytes independently of the
operation cut describing note values. An old logical cut may cover a later
snapshot without replacing that snapshot's operations or selecting a state winner.

Capture the accepted snapshot-root frontier in the same database turn as the
acceptance prefix. Issuer-restricted acceptance evidence checks exact parent
locators, protected root bytes, kind, collection and accepted membership. Reuse
accepted parent closure. Commit root/pages, membership, dependencies, frontier
advancement and wakeups atomically. Only named parent entries leave the frontier;
concurrent independent roots remain. Missing/unsupported parents retain existing
parking/blocking outcomes and optional background scheduling.

Fresh reconstruction deduplicates required snapshot traversal locally and reuses
checked logical history. Retain all ancestor bytes, on-demand damage detection
and durable verification requests. Use the existing schema and dependency graph.

## Implementation and qualification order

1. Freeze the single v1 root/stream/category layout and independent literal fixtures;
   qualify empty/populated canonical parents, wide manifests and malformed inputs.
2. Capture and verify parents under the existing owner; connect receive waits
   and exact edges to the atomic acceptance transaction.
3. Test sequential/concurrent/delayed roots, differing cuts, duplicates, restart,
   wrong-context evidence and missing/corrupt/wrong-kind parent inputs. Independently
   check bytes, closure, frontier, values, conflicts and Undo candidates.
4. Exercise process termination and I/O failure around acceptance, including
   committed work whose completion is lost. Require prior coverage or the entire
   new committed coverage. Extend construction probes and targeted mutations.
5. Check a bounded two-writer scheduling model for capture, verification,
   delivery, atomic frontier update and restart, with negative controls and
   reachable difficult states.
6. Benchmark production chains at 1, 8, 64 and 256 roots and wide fan-in. A
   sequential chain requires one startup leaf check; accepted parents introduce
   zero ancestor traversal. Report reconstruction and separate attempts separately.
7. Run debug/optimized, affected fixture/type/schema/mutation/process checks and
   available platforms. Align spec, glossary, ADRs and model correspondence.

## Planning evidence and boundaries

The warm optimized compact-frontier proxy reduced two-note, 256-snapshot whole
open medians from 20–22 ms to 15.5–16.4 ms and root checks from 256 to one.
Bookkeeping cost approximately 30–60 microseconds per link before the existing
commit barrier. Full auditing of those roots took 0.36–0.38 seconds. The proxy
changed synthetic indexes, so these measurements qualify the direction, not
the production encoding or recovery path.

Pruning, snapshot creation scheduling, UI/provider integration and physical
power-loss qualification remain separate increments. Production results are
recorded in the companion validation report.
