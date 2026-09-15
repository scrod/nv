# SQLite rewrite placement and decoding: follow-up experiments

Date: 2026-09-14. Follow-up to [clean-quit locality](clean-quit-locality-strategy.md).
This is a synthetic performance investigation, not adoption of a format,
maintenance policy, second database or packed cache. Logical history acceptance,
current-view consistency and quit obligations are unchanged.
The [continued bounded-work investigation](sqlite-rewrite-budget-validation.md)
adds repeated rewrites, writer-cache/spill controls, bounded free-space
reservation, VFS preallocation and freed-page zeroing, with fixed dictionary-
compressed current bytes. The [current tuning decision](clean-quit-locality-strategy.md#bounded-dictionary-tuning-selected-for-the-candidate)
selects level 3 and bounded training; the older level-3/6 alternatives below
remain descriptions of the original experiments, not an unresolved tuning choice.

## Questions and experimental controls

1. Does full VACUUM close the remaining startup gap with 16-KiB pages and
   independently compressed current cells?
2. Does current-table rewriting combine usefully with saved-page read-ahead?
3. How much per-row decoding cost is allocation/inflater setup, and how much
   remains after reusing those resources?
4. Which insertion/allocation choices improve placement in a fragmented database?
5. Can slower current-row compression at quit improve full cold startup, and
   which compression settings are worth that cost?

Use the [compiled probe](../../../tests/AgedStartupStorageComparison.m) and
[runner](../../../tests/run-startup-storage-comparison.py). The main matrix starts
from independent copies of the same previously aged 10,000-note image: 210,000
retained synthetic history objects, 12,393 scattered free 16-KiB pages, and
55,086,848 uncompressed note/context bytes. The word workload, public SQLCipher
key, full note/search initialization and independent exact-value oracle are those
of the [preceding experiment](aged-current-row-startup-validation.md). No actual
user collection, provider root, Keychain, or note-interaction code is touched.

Each measured process starts after successful commit, TRUNCATE checkpoint and
close. Cold preparation invalidates file pages and verifies zero residency;
the runner also requires actual kernel reads covering the encoded payload.
WAL reads and SQL sorts during startup must be zero. Every full load re-encodes
all notes and compares all fields and retained context against the external
oracle after timing. Packed controls retain their original experimental role;
none is introduced into the implementation. Three or five repetitions are
observations, not latency bounds or power-loss tests.

The new instrumentation separates current-cell decompression/wrapper allocation
from note/context construction. Startup totals still include SQL, page
authentication/decryption, any read-ahead, temporary cleanup and search setup.
Separate medians are not an exact additive decomposition. Parallel `pread_ms`
is summed service time, not elapsed time.

## Rewrite variations

All variants preserve exact note values. Rewrites are benchmark transactions,
not a proposed long-held production writer transaction.

| Variant | Controlled change |
| --- | --- |
| `rebuilt` | Original create/copy in ascending rowid order/drop/rename transaction; unique birth index maintained during copying |
| `birth-order` | Copy in UUID order instead; destination rowids still ascend |
| `deferred-index` | Populate the rowid table first, then create the unique birth index before committing |
| `deferred-birth` | Combine UUID-order input with deferred index creation |
| `recycled` | Retain current rows in an in-memory temporary table, drop the original first, then rebuild; old pages become available before allocation |
| `transfer` | Identical-schema `INSERT … SELECT *` without ORDER BY; inspect EXPLAIN for SQLite's RowCell transfer optimization |
| `reverse-rowid` | Explicitly preserve source rowids and insert them in descending order, avoiding the append-only insertion path |
| `reserved` | Temporarily consume the freelist, build current rows at the end of the file, create the birth index afterward, then release the reservation |
| `reserved-inline` | Same exhaustion control, but maintain the unique index while copying |
| `contiguous-pool` | After exhausting scattered holes, allocate and release a contiguous disposable extent; build from that free pool with a deferred index |
| `compacted` | Full SQLite VACUUM |
| `recompressed` | Decode and independently re-encode only current cells into a replacement table; retain historical objects and packed controls unchanged; no VACUUM |
| `recompressed-compacted` | Same current-cell conversion followed by diagnostic full VACUUM |

Deferred-index variants retain NOT NULL/CHECK validation and restore identical
birth uniqueness before COMMIT, but use a named unique index instead of the
inline UNIQUE declaration. They are experimental equivalent constraints, not
a silently modified production schema. Reservation/pool variants are deliberate
causal controls with O(freelist) work, not recommended mandatory maintenance.

Suffix `-hinted` saves the current B-tree's page list **after** the selected
layout operation. Ordinary and prefetched reads then use the identical image;
hint construction and rewriting have separate maintenance timers. No timed
startup enumerates DBSTAT or scans old history.

## What the allocator explains

The pinned SQLCipher source is commit
`c4b275a47932888216bade83aff2bbc73df0ff85`, SQLite 3.53.4. Relevant functions are
`allocateBtreePage`, `balance_quick`, `freePage2` in `src/btree.c`,
`xferOptimization` in `src/insert.c`, and `fcntlSizeHint` in `src/os_unix.c`.
These implementation observations are **not stable public placement contracts**:

- Ordinary allocation reuses free pages before extending the database. Its
  proximity search, when requested, examines leaves of the current freelist
  trunk rather than searching the entire free space for an ideal extent.
- The right-edge rowid insertion fast path calls allocation with **no proximity
  preference**. Increasing logical rowids therefore do not imply increasing
  file offsets. Removal of a freelist entry can swap in another entry, so even
  a contiguous free pool need not be consumed in traversal order.
- Larger rows/pages, page filling and insertion direction affect B-tree balance
  and overflow. A smaller table can still consist of almost entirely isolated
  pages. Conversely, clustered offsets can help reads despite nonmonotonic
  traversal within that small region.
- Index allocation competes with table allocation. Deferring an index can
  reduce interleaving when fresh space is available, but cannot make scattered
  free pages contiguous.
- File-size/chunk preallocation is a different layer. It can influence file
  growth at the VFS/filesystem boundary; it does not instruct the B-tree
  allocator to bypass its freelist or reserve an extent for one table.

SQLite documents [VACUUM](https://sqlite.org/lang_vacuum.html) as a way to
repack tables/indexes and reduce fragmentation. It is database-wide;
auto/incremental vacuum primarily reclaim space and do not supply equivalent
table compaction. [DBSTAT](https://sqlite.org/dbstat.html) supplies page numbers,
traversal paths and utilization for checking placement. Our run counts describe
consecutive **database-file offsets**, not physical SSD extents or APFS allocation.

## Decode controls

`--cell-decoder allocate` retains the prior per-cell NSData allocation and
`uncompress2` baseline. `scratch` reuses one bounded growable output buffer but
still calls `uncompress2` separately. `stream` also reuses a zlib inflater with
`inflateReset` between **independent** cells; it never carries a prior note's
dictionary or identity into the next one. Every compressed input must finish
with exactly the declared output and consume its full input. Raw fallback
borrows the current SQL bytes until that row has been decoded.

This tests allocation/setup, not a new compression format. The
[zlib contract](https://zlib.net/manual.html) permits reset without freeing and
reallocating internal state. Every mode retains complete field/context/search
equality; production codecs, error propagation and limits still need their own
qualification.

## Placement results

Main zlib-level-1 matrix: three cold trials per method. Each row compares
ordinary SQL and read-ahead **on the same closed hinted image**. Maintenance
is one observed rewrite/VACUUM duration, excluding hint construction and final
checkpoint/close. Rounded milliseconds:

| Layout | Current pages | Contiguous offset runs | Ordinary startup | With read-ahead | Packed zlib control | Rewrite/VACUUM |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Aged, no rewrite | 2,025 | 2,018 | 1,193 | 901 | 744 | — |
| Ascending-rowid rewrite | 1,373 | 1,224 | 1,078 | 972 | 737 | 901 |
| UUID-order input | 1,374 | 1,225 | 994 | 946 | 738 | 1,015 |
| Deferred birth index | 1,373 | 1,223 | 1,070 | 964 | 754 | 523 |
| UUID order + deferred index | 1,374 | 1,224 | 1,038 | 932 | 744 | 1,065 |
| Release old table first | 1,373 | 1,369 | 1,088 | 895 | 743 | 885 |
| SQLite transfer optimization | 1,373 | 1,224 | 999 | 934 | 750 | 637 |
| Descending explicit rowids | 2,650 | 2,359 | 1,108 | 1,030 | 732 | 1,041 |
| Exhaust freelist; defer index | 1,373 | 1 | 889 | 840 | 731 | 2,667 |
| Full VACUUM | 1,373 | 2 | 871 | 881 | 757 | 14,612 |

The separate untouched aged image gave 1,316 ms versus its 737-ms packed control.
It has the same current values/layout as the hinted copy but is a distinct file;
do not interpret that cross-file timing difference as the cost of merely storing
a hint. Within-image comparisons, page placement and phase timings are stronger
evidence than ranking small timing differences between copies.

Two additional three-trial controls isolate fresh allocation from index timing:

| Allocation control | Offset runs / traversal runs | Ordinary / read-ahead / packed ms | Rewrite ms |
| --- | ---: | ---: | ---: |
| Exhaust freelist, inline index | 17 / 17 | 856 / 834 / 740 | 2,636 |
| Contiguous free pool, deferred index | 3 / 1,373 | 952 / 966 / 757 | 4,489 |

What these establish:

- **VACUUM really fixes the I/O fragmentation.** Its 1,372 non-root current pages
  form one run; the separately allocated root explains the second. Ordinary
  measured read time falls from about 307 ms to 7.5 ms. The remaining startup
  cost is not a failure to compact current pages.
- **Rewriting fills pages, but does not solve scattered allocation.** The normal
  rewrite reduces table size from 33.18 MB to 22.50 MB while nearly every page
  remains a separate run in traversal order. Adding read-ahead helps that image,
  but does not beat the best non-rewriting observation reliably.
- **Deferred indexes help only part of the problem.** On the fragmented fixture
  they reduce observed rewrite cost, not fragmentation. At the file's fresh end
  they eliminate index-induced gaps: 17 runs become one. The main copy query's
  input order does not itself unify the free space.
- **Contiguous availability and ordered consumption are different.** A mostly
  contiguous free pool gave only three offset runs, yet all 1,373 pages were
  nonadjacent in traversal order. It reduced the seek region substantially but
  was not equivalent to end-of-file append or VACUUM.
- **Changing insertion direction is not a useful fix here.** Descending rowids
  almost doubled the current page count and left about 22.8 MB unused within
  pages. The unordered transfer path emitted a RowCell opcode and reduced copy
  overhead, but produced essentially the same fragmented layout as the normal
  rewrite. It does not transfer source pages into contiguous destination space.

The reservation control filled roughly 202 MB of holes and caused about 723 MB
of measured SQLite writes across WAL/main-file work. Full VACUUM caused about
2.79 GB. The pool control caused about 896 MB. These are VFS bytes, not physical
SSD write amplification; costs exclude earlier fixture copies. They demonstrate
the source of locality, not a justification for O(freelist) or O(history) work
at every quit. No low-level free-page manipulation or custom SQLite allocator
was used.

## Decompression results before zstd

On the same compacted zlib-level-1 image, output-buffer reuse and inflater reuse
have modest effects, not the large effect needed to explain the whole gap:

| Row decoder | Trials | Ordinary startup ms | Per-cell inflate/wrapper ms | Note/context construction ms |
| --- | ---: | ---: | ---: | ---: |
| Prior allocating baseline | 3 | 871 | 137 | 686 |
| Reuse output buffer | 5 | 852 | 128 | 673 |
| Reuse output + inflater | 5 | 853 | 128 | 674 |

The last pass's packed control was 742 ms, including 48 ms decompression and
659 ms construction. On the fragmented hinted image, reusable inflater startup
was 1,182 ms ordinarily and 893 ms with read-ahead; it does not fix disk layout.
The buffers are still worth reusing to avoid unnecessary intermediates, but
these observations do not justify claiming they remove per-cell codec cost.

**Compression levels were not previously matched.** Independent cells used
`Z_BEST_SPEED` (level 1); NV's `compressedData` packed control uses
`Z_DEFAULT_COMPRESSION` (level 6). A follow-up recompresses every current cell
at level 6, then vacuums the image. Five trials give 1,287 pages, 816-ms ordinary
startup, 118-ms per-cell decompression and 651-ms construction. Thus matching
levels helps, but does not remove the codec-phase gap versus the packed stream.
Re-encoding/copying cost about 2.12 seconds before its approximately 15-second
VACUUM. A production encoder would perform compression outside the writer cut;
this benchmark intentionally measures the full diagnostic conversion.

That run's packed total was 841 ms, with 51-ms decompression and **754-ms
construction**. The apparently faster row total therefore cannot be attributed
to better decompression or used as proof of packed-equivalent startup. This
machine/workload shows significant construction-time variability between runs;
compare the phase evidence and repeated controls, not a favorable total alone.

An uncompressed 16-KiB VACUUM control also passes: 4,040 current pages, 833-ms
ordinary startup, 790 ms with read-ahead and 772-ms packed control (five trials).
There is no per-cell inflate cost, but more SQLCipher pages must be read and
decrypted. Its 15.58-second VACUUM still scales with the historical store. Neither
always compressing nor always storing raw can be selected solely from one total.

## Zstd follow-up

At the user's suggestion, the probe optionally links the already installed
zstd 1.5.7 library using `--zstd-prefix`. No dependency was added to the app or
Swift package. Cells use independent level-3 frames, a raw fallback, one reusable
output buffer and `ZSTD_DCtx`. The packed zstd control also uses level 3. Both
packed controls are constructed before releasing private buffers, matching the
earlier baseline's placement advantage. SHA-256 comparison of the independent
oracle confirms exactly the same final note/context bytes as the zlib fixture.

The new zstd fixture is aged throughout the same workload, not merely compressed
at the endpoint. Three cold trials per combination:

| Zstd current-row layout | Ordinary startup ms | With read-ahead ms | Packed zlib ms | Packed zstd ms |
| --- | ---: | ---: | ---: | ---: |
| Aged, no rewrite | 1,087 | 821 | 760 | 791 |
| Current table rewritten | 933 | 888 | 741 | 827 |
| Full VACUUM | 830 | 803 | 782 | 798 |

Independent-cell inflate/wrapper time falls to approximately **73–78 ms**, versus
about 127–137 ms for reusable/allocating zlib-level-1 cells in the earlier runs.
Current table payload falls from 20.27 MB to **18.97 MB**. Aging still leaves
1,879 pages in 1,873 offset runs; the rewrite makes the table smaller but leaves
1,142 runs. Zstd is not a locality mechanism. VACUUM still costs **14.22 seconds**.
The non-rewriting hint costs **272 ms** to construct in one observation.

Packed zstd does **not** outperform packed zlib here: its decode phase takes
roughly 53–55 ms versus 47–50 ms for zlib, before note construction. Do not
substitute the library's general throughput claims for the measured workload.
These results favor zstd's independent-cell tradeoff, not universal codec
superiority or packed-equivalent performance for all databases.

### Shared dictionaries: follow-up candidate, not adopted

The user's [shared-dictionary suggestion](https://facebook.github.io/zstd/#small-data)
is particularly relevant to independent small records. A frame references a
fixed dictionary; it does not update a shared dictionary incrementally or require
the preceding note's frame. The [completed dictionary experiments](zstd-shared-dictionary-validation.md)
now compare independent training, sampling actual current rows and training on
all exact current rows, including mixed synthetic genres and a drift control.
Training on current rows is valid for compressing that fixed set; held-out data
tests future reuse. Neither makes this synthetic vocabulary representative.

An implementation investigation would also have to bind every cell to its exact
dictionary, retain that dictionary while referenced, and test mixed dictionary
generations/retraining, corruption and recovery. If scoped only to private
derived current cells, this need not change provider segments or make retained
history depend on a private dictionary. Storing dictionaries inside the encrypted
database is a candidate, not a new format/retention policy adopted by this report.
No dictionary was used in the measurements on this page; see the follow-up for
dictionary timings, generation/crash tests and their qualification limits.

### Five-trial confirmation and limits

A repeat on the **same aged zstd hinted image** gave median total startup of
**1,100 ms** ordinarily, **824 ms** with read-ahead, **757 ms** for packed zlib
and **770 ms** for packed zstd. Thus the non-rewriting result remains about
**9% above packed zlib**, not equivalent. Median peak RSS is approximately
262 MiB for prefetched current rows versus 342–343 MiB for the packed controls.

Prefetched totals ranged from 819 to **1,589 ms**; packed zlib ranged from 727 to
932 ms. The slow prefetched sample spent 1,184 ms constructing notes/context
and 135 ms inflating cells, while its 38-ms prefetch and exact read volume were
normal. This localizes most of that delay outside read-ahead; it does not identify
the underlying scheduler/CPU/allocator cause. Do not discard it or present a
median as a guarantee. Benchmarking occurs on a live development machine, not
an isolated performance lab. CPU, allocation and I/O phases can vary independently.

## Compression-level and option sweep: spend quit time where it helps

The next pass keeps the same aged level-3 source image and re-encodes **only
the 10,000 current rows**, preserving their exact 55.09-MB decoded state and
all historical objects. It does not rebuild/VACUUM the entire database. All
variants use reusable decode resources and independent frames with raw fallback.
The two original packed controls remain unchanged. Three cold trials per method:

| Current-cell encoder | Current table payload MB | Current pages | Encoding s | Full recode transaction s | Read-ahead launch ms | Cell decode ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Zstd 1 | 19.35 | 1,302 | 0.25 | 1.01 | 931 | 87.2 |
| Zstd 3 | 18.97 | 1,278 | 0.29 | 1.08 | 898 | 76.3 |
| Zstd 6 | 18.66 | 1,249 | 0.76 | 1.54 | 867 | 74.4 |
| Zstd 9 | 18.47 | 1,235 | 1.53 | 2.30 | 895 | 73.9 |
| Zstd 15 | 17.73 | 1,174 | 5.33 | 6.25 | 880 | 82.6 |
| Zstd 19 | 17.65 | 1,165 | 11.34 | 12.46 | 881 | 82.8 |
| Zstd 9, minimum-match search 6 | 19.10 | 1,290 | 1.45 | 2.34 | 884 | 75.6 |
| Zstd 9, double-fast strategy | 18.98 | 1,280 | 0.27 | 1.86 | 886 | 77.3 |

Encoding/recode are single maintenance observations; launch/decode are medians.
The transaction includes source decoding, insertion and table replacement;
encoding is a subset, **not an additional cost**. Hint construction adds 34–107
ms and final checkpoint/close 6–12 ms in this pass. Diagnostic geometry inspection
and fixture copying are not included. None of these is an end-to-end app quit.
The actual in-memory encoder would not need to decode the old SQL cells first.
Explicit double-fast strategy replaces the level's default strategy; it should
not be interpreted as retaining all level-9 search effort.

Higher compression is not monotonically faster to decode. Here levels 15–19
reduce payload by about 7% versus level 3 but take 18–39 times its encoding time
and have slower cell decoding. Raising level 3 to 6 costs about 0.46 seconds of
extra encoding for all current notes, but removes only 0.31 MB and roughly 2 ms
of cell decoding. Level 9 brings still smaller incremental gains. Minimum-match
6 does not help this workload, and double-fast is broadly similar to level 3.

Do not treat the 867-ms level-6 total as proof of a 31-ms launch improvement
over level 3. Median note/context construction spans 670–717 ms among these
prefetched runs. Level-9 totals range from 868 to 1,177 ms; level-1 totals range
from 848 to 1,104 ms. Even the unchanged packed-zstd control varies from a
741-ms median in one pass to 957 ms in another. The stable source bytes and
phase breakdown support the size/codec tradeoffs, not a precise global ranking
of small total-time differences on this live machine.

A five-trial confirmation reuses the exact level-6 recompressed image without
performing another rewrite: prefetched current-row startup is **859 ms** median
(850–995 ms), versus **777 ms** for unchanged packed zlib and **746 ms** for
unchanged packed zstd. Current-cell decoding is 73.8 ms, note/context
construction 664 ms and prefetch 76 ms. The launch gap remains; higher
compression alone has not established packed-equivalent startup. This is a
different layout from the earlier non-rewriting 824-ms level-3 result, so it
does not establish that changing level 3 to 6 makes that earlier path slower.

For further qualification, **default level 3 or 6** is more defensible than
high levels or tuned search parameters. Level 6 is the modest-extra-encoding
candidate; level 3 remains a strong low-cost baseline. This does not justify
mandatory recompression/table replacement on every quit: choose the codec when
materializing changed current values, outside the short writer transaction,
and avoid repeatedly re-encoding unchanged rows. A proposed optional quit-time
upgrade would still need a measured benefit, bounded work and existing
generation/cancellation checks. No such production policy is adopted here.

## Implications and remaining qualification

1. Positive placement factors are **usable nearby/fresh space, avoiding allocation
   interleaving, dense page filling and favorable traversal order**. The tests
   distinguish them; no ordinary table-rewrite SQL clause guarantees them all.
2. Full VACUUM is an effective native locality baseline, but its O(history)
   copying is still unsuitable as mandatory clean-quit work. Exhausting the
   freelist replaces that with O(freelist) work, not a bounded solution.
3. Reusable scratch avoids unnecessary buffers; zstd is a stronger independent-
   cell candidate than the previously tested zlib choice. Neither establishes a
   guarantee, and neither is adopted as a new current-cell codec here.
4. These results do not yet justify moving current state into another database
   or restoring a packed cache. They also do not prove those designs unnecessary.
   First qualify the actual Swift codec, current-context validation, ordinary and
   unfavorable text, whole-store write cost, Intel/other platforms, memory
   pressure and repeated aging/quit cycles. The proposed saved-hint lifecycle
   still needs adapter crash/cancellation/ownership qualification.

The zstd tests used an existing Homebrew static library built for macOS 13,
which produces deployment-target warnings when linked into the macOS-11
probe. They ran on macOS 26.6.2 and **do not qualify macOS 11 compatibility**;
a production dependency must be built/qualified for the supported targets.
No user-facing storage policy, provider format, encryption boundary, mutation
semantics or TLA+ transition/assertion changed. TLC was not rerun for these
physical-layout/codec experiments. No automatic compaction was implemented.

## Reproduction and evidence

Example main matrix (use a fresh output, or reuse a matching completed aged
fixture with `--reuse-aged-root`):

```sh
python3 tests/run-startup-storage-comparison.py --skip-build --aged \
  --notes 10000 --history 100000 --churn-rounds 10 --hole-interval 10 \
  --page-size 16384 --cell-codec zlib --repeats 3 --conditions cold \
  --layouts hinted rebuilt-hinted compacted-hinted deferred-index-hinted \
    birth-order-hinted deferred-birth-hinted recycled-hinted reserved-hinted \
    transfer-hinted reverse-rowid-hinted \
  --aged-kinds table table-prefetch compressed --prefetch-workers 8 \
  --sqlcipher-build /path/to/sqlcipher --key-mode raw
```

Use `reserved-inline-hinted contiguous-pool-hinted` for the allocation controls,
`level6-compacted-hinted` to match zlib compression levels, and
`--cell-codec raw --layouts compacted-hinted` on the matching raw fixture.
`--cell-decoder allocate|scratch|stream` selects the resource-reuse control.
Zstd uses a newly aged fixture, `--cell-codec zstd --cell-decoder stream
--zstd-prefix /path/to/zstd`, and includes `zstd` among `--aged-kinds`. The
packed zstd control is present only in fixtures seeded with that optional build.

For the quit-time compression sweep, reuse the same level-3 aged zstd fixture
and select `--layouts recompressed-hinted`, `--zstd-level 1|3|6|9|15|19`,
optionally `--zstd-min-match 6` or `--zstd-strategy dfast`. Only current cells
are recompressed. Packed controls remain the original level-6 zlib and level-3
zstd streams, so changing a current-cell option cannot silently change the
comparison control. `encode_ms` measures encoding calls, `recode_ms` includes
source decoding and the replacement-table transaction, and hint construction
and final checkpoint/close are reported separately. These are not full app-quit
timings. No variant in this sweep requires rewriting the historical store.

The advanced settings use `ZSTD_compress2` after configuring/resetting a reused
compression context. `ZSTD_compressCCtx` would ignore those advanced parameters;
using it would make the options experiment invalid. Longer minimum-match
settings alter the encoder's search, not a requirement that every output match
have that length. See the pinned [zstd 1.5.7 API](https://raw.githubusercontent.com/facebook/zstd/v1.5.7/lib/zstd.h).

Temporary artifacts under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`, suffixes after
`nv-startup-comparison-`:

| Suffix | Completed checks |
| --- | --- |
| `i3d_342p` | 26 small-fixture rewrite/decoder smoke loads |
| `3gmydsb_` | 96 large main-matrix loads |
| `etw443j1` | 30 output-scratch loads |
| `xdks5pm6` | 30 output/inflater reuse loads |
| `5n2srsw2` | 18 fresh-allocation/contiguous-pool control loads |
| `c0pj8_ly` | 15 matched-zlib-level/VACUUM loads |
| `bdepezdr` | 15 raw-row/VACUUM loads |
| `k4ysssxu` | 11 small zstd/full-value smoke loads |
| `q_0_y1aa` | 36 newly aged zstd/layout loads |
| `1lyllrfm` | 20 confirmation loads on the same aged zstd hinted image |
| `67qcyrn4` | 2 allocating-zstd decoder smoke loads |
| `_2fig32r` | 2 scratch-zstd decoder smoke loads |
| `w1ekp_5b` | 4 current-only recompression/minimum-match smoke loads |
| `ryxsrqzk` | 12 level-1 current-only recompression loads |
| `mouchmg0` | 12 level-3 current-only recompression loads |
| `9vsex6oz` | 12 level-6 current-only recompression loads |
| `v4b644v3` | 12 level-9 current-only recompression loads |
| `7j41n1gm` | 12 level-15 current-only recompression loads |
| `qq_5x8pb` | 12 level-19 current-only recompression loads |
| `s3136e_u` | 12 level-9/minimum-match-6 loads |
| `iik8ejtg` | 12 level-9/double-fast loads |
| `xwwq62zb` | 15 confirmation loads on the same level-6 recompressed image |

Results retain full raw measurements, fixture geometry, exact arguments and
subprocess logs. Existing source fixture images are reused read-only; new layout
variants are copied into new temporary directories. All **416** completed loads passed
the exact note/context/search oracle, zero-WAL/zero-sort gates and cold-residency/
kernel-I/O checks. This is performance and decoder-equivalence evidence, not a
proof of the complete storage protocol or production corruption recovery.
`zsh build.sh` also completed successfully after the final probe changes;
existing simulator-service/deployment-target warnings are not platform
qualification for this experimental zstd dependency.

The performance-profiling skill informed measuring separate phases, retaining
unfavorable observations and testing setup/allocation hypotheses rather than
equating all decode time with allocation overhead.
