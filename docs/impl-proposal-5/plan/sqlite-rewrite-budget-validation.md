# Bounded dictionary training and continued table-rewrite investigation

Date: 2026-09-14. Follow-up to [shared dictionaries](zstd-shared-dictionary-validation.md)
and the [initial allocator/rewrite matrix](sqlite-rewrite-locality-validation.md).
The user selected bounded sampling and zstd level 3. This pass implements that
experiment, records the candidate's tuning in [clean-quit locality](clean-quit-locality-strategy.md#bounded-dictionary-tuning-selected-for-the-candidate),
and investigates allocation with **identical already-compressed current cells**.
It does not adopt mandatory table replacement or whole-store compaction.

## Selected training budget

Use at most **1,024 candidate notes / 8 MiB of retained training input**, an
**8-KiB dictionary**, and **zstd level 3**. Note and byte limits are both needed:
a fixed note count alone does not bound the input when notes are unusually long.
These limits never restrict actual note saving or history. The output size is
the initial candidate tuning, not a new portable format requirement.

The probe now parameterizes `--dictionary-sample-limit` and
`--dictionary-sample-budget`; their defaults are 1,024 and 8,388,608 bytes.
Explicit `all-current` remains a diagnostic, not the selected quit strategy.
The driver checks actual sample counts/bytes against both caps. Insufficient
samples or trainer failure leaves ordinary independent level-3 compression
available; a missing dictionary required by an existing cell is still an error,
not permission to skip the note or silently reinterpret it.

Same 10,000-note mixed fixture and three cold trials per reader. Table payload
includes per-cell references and SQLite record payload but not the separately
counted 8-KiB dictionary. Maintenance timings are single observations:

| Candidate cap | Notes actually sampled | Training input MiB | Training ms | Sampling + training/setup ms | Current payload MB | Recode transaction ms | Prefetched launch ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 512 | 512 | 2.74 | 107 | 328 | 14.517 | 581 | 423 |
| 1,024 | 1,024 | 5.48 | 218 | 1,502 | 14.520 | 584 | 418 |
| 2,048 | 1,596 | 8.00 | 350 | 870 | 14.524 | 1,163 | 413 |

For comparison, all-current 8-KiB training consumed 53.99 MB and took 1,988 ms,
producing 14.525 MB of current payload. This supports limiting training, not
paying for all notes. The 1,024 setting leaves some diversity headroom over 512
while retaining a small observed trainer cost. It is not proven universally
optimal. The 2,048 case really hits the byte cap; it does not quietly train on
all selected records. Its final accepted samples total 8,387,793 bytes.

**Do not conceal the sampling cost.** This executable locates evenly distributed
samples by scanning the current SQL table and decoding selected cells; its
1,024-case setup took 1.50 s, of which only 0.22 s was training. That is not an
appropriate production sampling implementation for NV, whose current values
are already in memory. The candidate requires bounded selection/encoding from
that captured resident collection, not an additional SQL/current-body scan.
The note/byte caps bound trainer input, not elapsed I/O time, the full current
table rewrite, or all other obligations of application quit. No hard deadline
or measured full-app-quit guarantee is claimed.

Startup totals again vary with unrelated work: the unchanged packed-zlib
median in the 1,024 run was 534 ms, versus 379 and 368 ms in the adjacent runs.
Use exact size/count evidence and phase timings; do not infer that changing
the sample cap alone changes full startup by the differences in that table.

## Allocation experiment: fixed bytes, changing physical placement

All following variants copy the exact 1,024-sample result. No further training
or recompression occurs. The source has 959 current-table pages, 60,000 retained
history objects, and the earlier aged fixture's fragmented free space. The
current table is already densely packed by the initial compression/rewrite.
Every current dictionary/frame is unchanged. Each variant is a new copy; the
source and its independent complete-value oracle are never modified.

Use the same SQLCipher 4.19.0 / SQLite 3.53.4 build, 16-KiB pages, 4-MiB startup
page cache, mmap disabled, independent per-cell decoding, complete NoteObject/
context/search construction, and eight-worker bounded ciphertext read-ahead.
Each measured child follows COMMIT, TRUNCATE checkpoint and close, verified OS
page eviction, zero timed WAL reads/sorts and actual kernel reads. All full
loads compare exact values/context against the independent expected stream.

An offset run is consecutive database-file page numbers, **not physical SSD
extents**. Traversal runs additionally require increasing adjacency in B-tree
walk order. The whole span can be distorted by an isolated root page: the
VACUUM case has one distant root and 958 adjacent non-root current pages.

### One rewrite, same current-cell bytes

Three cold trials per reader, medians in milliseconds. Rewrite cost is one
observation, excluding hint generation/checkpoint/close. Writes include the
instrumented SQLite WAL/main-file work, not earlier source-copy I/O or physical
SSD amplification. Every row below retains exactly 959 current-table pages.

| Layout | Offset / traversal runs | Ordinary launch ms | Read-ahead launch ms | Packed zlib / zstd ms | Rewrite ms | SQLite writes MB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| No additional rewrite | 813 / 959 | 474 | 403 | 364 / 375 | — | 0.15 |
| Copy, inline unique index | 955 / 959 | 559 | 395 | 364 / 361 | 219 | 64.22 |
| Copy, deferred unique index | 955 / 958 | 511 | 401 | 364 / 367 | 215 | 64.19 |
| Keep source in memory, release old table first | 815 / 933 | 444 | 406 | 366 / 354 | 170 | 44.84 |
| Temporarily reserve up to 16 MiB | 877 / 958 | 516 | 407 | 366 / 351 | 397 | 114.96 |
| Full VACUUM, diagnostic only | 2 / 2 | 367 | 385 | 381 / 346 | 4,106 | 953.58 |

An ordinary second rewrite cannot improve page filling because the input is
already dense. It actually raises offset fragmentation from 813 to 955 runs
and expands the span from 28,951 to 35,793 pages. That explains why table
rewriting is not inherently defragmentation. Releasing the old table first
reduces writes and changes which free pages are available, but does not make
placement contiguous. Its whole-current temporary copy is an additional memory
trade-off, not an implementation recommendation.

VACUUM still demonstrates that locality matters: ordinary measured read service
falls from roughly 94–143 ms to **5 ms**. With decoding now inexpensive, ordinary
row startup is 367 ms versus 346-ms packed zstd. Cell decoding is 53 ms versus
36 ms for that packed stream, explaining much of the residual gap. The
apparently faster result than packed zlib also includes different note-
construction timing; do not generalize it as universal row/packed parity.
Read-ahead is unnecessary overhead on this contiguous image. Full VACUUM's
database-wide 954-MB writes / 4.1 s remain unsuitable as required quit work
with unbounded history.

### Repeated rewrites do not converge

Four successive physical rewrites, with no logical edits/history growth between
them, retain identical values and constant page counts. This is a favorable
stationary control, **not** a simulation of intervening user editing. Each pass
checkpoints/closes and records its new geometry; final cold loads verify full
note/context/search equality.

| Rewrite | Offset runs, passes 1 → 4 | Traversal runs, passes 1 → 4 | Per-pass rewrite ms |
| --- | --- | --- | --- |
| Inline index | 955 → 818 → 955 → 819 | 959 → 933 → 959 → 959 | 215, 204, 202, 201 |
| Deferred index | 955 → 813 → 955 → 813 | 958 → 932 → 958 → 959 | 300, 215, 209, 207 |
| Release old table first | 815 → 816 → 821 → 821 | 933 → 959 → 935 → 959 | 167, 162, 161, 159 |

The allocator mostly alternates between available scattered page sets; additional
rewrites do not steadily cluster them. Four-pass final read-ahead medians are
409, 414 and 409 ms, respectively—no convincing advantage over 403-ms baseline.

### Writer-cache, preallocation and bounded-reservation controls

These each start again from the same unmodified source, not from the previous
experiment's output. Startup always returns to the same 4-MiB cache.

| Controlled change | Offset / traversal runs | Cache spills | Rewrite ms | SQLite writes MB | Read-ahead launch ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Deferred index, original 4-MiB writer cache | 955 / 958 | 1,726 | 215 | 64.19 | 401 |
| Deferred index, 64-MiB writer cache | 955 / 958 | 0 | 323 | 64.19 | 426 |
| Deferred index, spill disabled | 955 / 958 | 0 | 259 | 64.19 | 419 |
| Inline index, native 16-MiB VFS chunk hint | 955 / 959 | 1,726 | 343 | 64.22 | 387 |
| Reserve up to 32 MiB before deferred-index copy | 786 / 959 | 5,846 | 674 | 165.59 | 427 |

Eliminating cache spills did not change page allocation or total write volume.
These single-maintenance observations do not prove a larger cache always slows
rewriting; they show no benefit here and no locality mechanism. Disabling spill
can let dirty-page memory grow beyond the nominal cache budget, so it is not a
free or bounded-memory fix. See SQLite's [cache/spill controls](https://www.sqlite.org/pragma.html#pragma_cache_spill).

The [native chunk-size hint](https://www.sqlite.org/c3ref/c_fcntl_begin_atomic_write.html)
is successfully accepted, but does not bypass SQLite's freelist. This rewrite
already has free pages and does not need fresh file growth. Geometry and writes
are identical to the unhinted inline-index copy; the lower observed launch total
is not evidence of better placement. We did not measure physical APFS extents
or prove chunk hints useless for genuinely extending a file.

Reserving 16 or 32 MiB changes which free pages the replacement consumes but
does not force a suitable extent. It adds substantial writes without a
consistent launch benefit. The earlier full-freelist-exhaustion experiment
does obtain fresh contiguous allocation; its work scales with free space,
not this fixed budget. Bounded reservation is not an equivalent shortcut.

### Freed-page zeroing is a write-volume factor, not a locality factor

This SQLCipher build reports `secure_delete=1` in every baseline above. A final
synthetic control turns it off only on the isolated rewrite connection. Exact
values and geometry remain unchanged: 959 pages, 955 offset runs, 958 traversal
runs. Instrumented writes fall from **64.19 to 32.20 MB**, and cache spills from
1,726 to 753. Rewrite time is 203 ms versus the earlier 215-ms baseline, but final
checkpoint/close takes another 43 ms; these single observations do not establish
a compelling overall quit-time gain. Prefetched launch remains 400 ms.

The experiment therefore identifies why dropping the old table writes so much,
without finding a placement improvement. **No application `secure_delete`
setting changes.** Reusing freed pages without zeroing has different forensic
retention behavior; encryption and retained history do not silently authorize
changing a privacy policy for other private records. Any production change
would require a separate scope/security review. See SQLite's
[secure-delete semantics](https://www.sqlite.org/pragma.html#pragma_secure_delete).

## What most influences rewriting

1. **Free-space location and consumption order.** This dominates contiguous
   placement. The pinned allocator reuses free pages before extending the file;
   right-edge rowid insertion does not request proximity, and selecting a leaf
   swaps another freelist entry into its place. Sorted logical rows do not imply
   sorted file offsets. This is an inspected implementation detail, not a stable
   public API guarantee.
2. **Whether the current table has wasted space to remove.** Initial compression/
   repacking reduces pages and I/O. Once cells/pages are already dense, another
   identical copy offers no page-count benefit and can worsen allocation.
3. **Allocation interleaving and when old pages become free.** Deferred indexes
   helped fresh-end placement in the earlier control, not scattered freelists.
   Dropping the old table early changes allocation and reduces writes here, at
   the expense of a whole-current temporary representation.
4. **Row/page geometry and traversal order.** Earlier large-row/overflow,
   reverse-insertion, page-size and UUID-order tests remain relevant. This pass
   intentionally fixes them to isolate the other factors.
5. **Writer cache and VFS growth hints.** They can affect cost at different layers,
   but do not provide table-specific placement control in these tests.
6. **Freed-page zeroing.** It substantially affects write volume when the old
   table is dropped, not placement of the new table. It remains enabled.

SQLite's documented [VACUUM](https://www.sqlite.org/lang_vacuum.html) addresses
whole-database fragmentation; it is not a table-only, bounded-quit operation.
We have not found a supported SQL clause that guarantees contiguous allocation
for one replacement table despite an arbitrary fragmented freelist. Do not
silently fork the allocator or manipulate free-page internals to obtain one.

## Scope and remaining tests

The selected bounded level-3 training profile is recorded, but automatic
retraining/rewrite-on-quit is not newly required. Keep optimizing changed current
values and optional physical read-ahead; use a rewrite only when a measured
expected benefit and work budget justify it. Whether to perform maintenance on
every clean quit or adaptively remains adapter design/qualification work.

The [spec](../../iCloud-Drive-Support-Spec.md), [quit ADR](../../adr/0008-reuse-the-existing-quit-flow.md),
[current-materialization definition](../../../CONTEXT.md) and
[TLA coverage boundary](../../tla/README.md) were checked. No causal/current-prefix,
durability, provider or publication semantics changed; TLC was not rerun.
The dictionary/frame wrappers are still experiment-only. Production codecs,
actual resident sampling, cancellation/activation, Intel/supported macOS builds,
less-templated text, growing/changing collections between quits and hardware/
memory pressure remain qualification work. This is a substantially fuller
allocation investigation, not a claim that every allocator workload was tested.

## Reproduction

The [runner](../../../tests/run-startup-storage-comparison.py) uses the existing
[compiled probe](../../../tests/AgedStartupStorageComparison.m). A sampled fixture:

```sh
python3 tests/run-startup-storage-comparison.py --skip-build --aged \
  --notes 10000 --body-pattern mixed --history 20000 --churn-rounds 3 \
  --hole-interval 4 --page-size 16384 --cell-codec zstd --cell-decoder stream \
  --dictionary-training current --dictionary-size 8192 --zstd-level 3 \
  --dictionary-sample-limit 1024 --dictionary-sample-budget 8388608 \
  --layouts recompressed-hinted --aged-kinds table table-prefetch compressed zstd \
  --conditions cold --repeats 3 --prefetch-workers 8 \
  --sqlcipher-build /path/to/sqlcipher --key-mode raw --zstd-prefix /path/to/zstd
```

For the allocation matrix, use that completed directory with
`--reuse-aged-root /path/to/result --source-layout recompressed-hinted`, omit
dictionary-training/size options (reuse existing dictionary frames), and select
the layouts in the tables. `--rewrite-passes 4` repeats only the physical
operation on the new copy. `--rewrite-cache-kib 65536`, `--rewrite-spill off`,
`--rewrite-chunk-mib 16` and `--reserve-budget-mib 32` select the separate controls.
All source fixture dimensions/codec/profile flags must match. The runner never
mutates a reused source, and does not reuse a layout built with conflicting
sample/writer settings. Per-pass geometry/writes/timing are retained in JSON.

Functional fallback controls use `--expect-training-fallback`: three notes,
or eight long notes with a 64-KiB sampling budget. They require a real declined
training result, zero dictionary-dependent cells and exact complete startup;
the positive performance runs still require actual dictionary-dependent cells.
These are non-vacuous fallback controls, not permission to omit a broken dependency.

## Completed checks and artifacts

**214 timed complete note/context/search loads pass**, with cold-residency/
kernel-I/O checks and no timed WAL reads or SQL sorts. The 13 dictionary API,
mixed-generation retention, abrupt-process-exit and rejection checks pass again,
including four additional untimed full-value startup oracles after recovery/
maintenance. The no-zstd build path and repeated named-index rewrites also pass.
The 2,048-candidate run hits the byte cap; the long-note fallback retains zero
training samples but saves/loads all eight notes exactly. No assertion was
weakened to make a missing required dictionary acceptable.

Temporary roots under `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`, with
prefix `nv-startup-comparison-`:

| Suffix | Run | Timed full loads |
| --- | --- | ---: |
| `4a9jxwa2` | Repeated-rewrite small smoke | 4 |
| `fltzoj2f`, `1wozy2ad`, `5ggq1dmx` | 512 / 1,024 / 2,048-candidate caps | 36 |
| `bka0gnni` | Fixed-byte main allocation matrix | 72 |
| `run4bmnf`, `gektq60n` | Larger writer cache / spill disabled | 24 |
| `ts6y4f8y` | Native chunk-size hint | 12 |
| `s57pwn7r` | 32-MiB bounded reservation | 12 |
| `yfbfpyvu` | Four successive rewrites, three strategies | 36 |
| `2lbplhxt`, `qmfhdoy2` | Too few / oversized training candidates | 4 |
| `wnj_z8cj` | Final sampled-dictionary lifecycle contracts | 1 |
| `j3e7f8ft` | No-zstd zlib/repeated-rewrite regression | 1 |
| `_yturin7` | Freed-page zeroing cost control | 12 |

The earlier reports' trial counts do not include these additional loads.
`results.json` preserves all timings, actual sampler/allocator settings, per-pass
geometry and fixture paths; `calls.jsonl` records commands/output. The source
and report, rather than temporary paths, are the durable evidence. `zsh build.sh`
passes with the existing Xcode/Simulator sandbox warnings. Performance-profiling
guidance informed fixed-byte controls, separate phase timing, verified I/O and
preserving unfavorable results, not ranking small noisy timing differences.
