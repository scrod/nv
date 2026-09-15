# Aged current-row startup after a clean exit

Date: 2026-09-14. Executable physical-layout experiment, not a production Swift
adapter or a new storage-format decision. Sources:
[`AgedStartupStorageComparison.m`](../../../tests/AgedStartupStorageComparison.m),
the reused [`StartupStorageComparison.m`](../../../tests/StartupStorageComparison.m)
and [runner](../../../tests/run-startup-storage-comparison.py).

## Result and design implications

The subsequent [clean-quit locality investigation](clean-quit-locality-strategy.md)
tests per-cell compression, page geometry and bounded read-ahead against the
fragmented-free-space case below. It supplies a concrete non-rewriting candidate
and its limits; this earlier report's measurements remain unchanged.

**Aging can make current-row startup substantially slower than the fresh packed
baseline, even when the database was safely saved and closed.** Table-order
loading helps, but scattered current pages remain an independent problem. A
current-table rewrite can restore near-packed performance when it obtains good
locality; it is **not** a locality guarantee when SQLite reuses scattered free
pages. Do not turn that conditional result into mandatory rewrite-on-quit policy.

Adopted implementation clarifications in [LocalStore](../LocalStore.md): scan in
table/rowid order; decode directly into final unpublished note/context storage;
bound temporary allocations; retain one consistent read capture and final
publication checks. These do not restore the removed packed cache or change
causal/durability semantics. The former blanket prohibition on text processing
inside *any* transaction now distinguishes short write transactions from startup's
read-only streaming decode. No live editor or UI work is performed by that reader.

The remaining performance design task is **clean-exit locality maintenance**.
Neither a clean WAL checkpoint, a bigger SQLite page cache, nor a successful
current-table rewrite alone promises packed-like cold startup. Whole-database
compaction is a useful diagnostic, not a suitable mandatory quit step over
unbounded history. Packed storage itself is not intrinsically immune to SQLite
free-page allocation: this experiment does not prove arbitrary future BLOB
replacements remain contiguous either.

## Workload and measurement boundary

- Apple Silicon, macOS 26.6.2; existing SQLCipher Community 4.19.0 / SQLite 3.53.4
  CommonCrypto build. Public synthetic raw key, no password KDF in the interval.
- Actual proposal [DDL](sqlite-local-schema.sql): `current_notes` is a rowid table
  with a unique binary UUID index, `objects` retains immutable synthetic BLOBs,
  and the free-list stress uses `private_groups`. Other protocol tables exist but
  are not populated with a complete accepted causal graph. This is **not** a
  bootstrap/history-validation or materialization-backlog test.
- Main case: 10,000 live notes; 100,000 initial unrelated 4-KiB objects; initial
  insertion plus ten randomly ordered update rounds, totaling 110,000 current
  writes, 10,094 delete/recreate pairs and 210,000 retained objects. Recreated
  notes receive fresh UUIDs. Every update changes generated contents, with bodies
  varying between roughly 1–16 Ki UTF-16 code units. Final benchmark cells total
  55,086,848 bytes, including 256 synthetic authoring-reference bytes per note.
- The cells use the earlier experiment's exact common-note-field codec, plus a
  bounded synthetic context field. They are **not** the unfinished canonical
  current-cell codec or full causal-frontier validator. The references measure
  space, reading, retention and hashing, not graph validation.
- Five randomized fresh-process trials per main combination, cold and warmed.
  Every full load builds actual `NoteObject` values, retained context and complete
  title/body/label search buffers, then executes identical synchronous queries.
  Rows stream directly from SQLite without a concatenated encoded collection.
  All full-decode variants drain temporary autoreleased objects every 256 notes,
  except the explicitly labeled lifetime control. No asynchronous search.
- The independently generated final record set is retained as an oracle outside
  SQLite. After the timer and RSS sample, re-encoding must match every full
  record exactly by UUID, including dates, title, labels, body and context, with
  no duplicate/missing note. Query order cannot weaken equality. Search results
  and context checksums agree. Raw-row controls instead touch all bytes and do
  not initialize notes/search; their timings are never called ready-to-edit.
- All fixture writes commit with WAL, `synchronous=FULL`, `fullfsync=ON`; final
  checkpoint/TRUNCATE must report no remaining frames, and the database closes
  before measurement. Every measured load asserts zero WAL reads and zero SQL
  sorts. This deliberately excludes crash/WAL reconstruction. It also assumes
  current rows are up to date, not merely that newer history is durable.
- Cold preparation uses `MS_INVALIDATE`, verifies zero resident file pages with
  `mincore`, and requires measured kernel read bytes at least equal to input
  bytes. It does not flush SSD/controller caches or cold-start every framework.
  Eviction, residency enumeration, instrumentation allocation and oracle checks
  are **outside** startup timing, not proposed launch work. Warming runs precede
  warmed samples; the OS can still evict pages, and their actual I/O is recorded.
- No competing benchmark/build ran during measurements. Ordinary host workload
  was not disabled. Medians and observed maxima are recorded; five samples do
  not establish a p99 or hard wall-clock bound. The VFS measures actual read
  requests and kernel I/O, not physical APFS extents or controller operations.

## Main comparison

All rows below contain the **same final notes and history**. Rebuilt uses a
transactional replacement of only `current_notes`, copied in existing rowid
order. Compacted uses `VACUUM` on another closed fixture copy. Both maintenance
operations happen before measured startup. Packed controls are fresh experimental
flat/compressed BLOBs written after churn; neither is a supported private format.

Cold complete note/search startup, median milliseconds (five trials):

| Database layout | Table order | UUID order | Flat packed | Compressed packed |
| --- | ---: | ---: | ---: | ---: |
| Aged, no maintenance | 2,076.0 | 2,220.5 | 819.2 | 1,155.2 |
| Current table rewritten | 831.2 | 1,362.2 | 912.5 | 795.0 |
| Whole database compacted | 882.2 | 1,342.8 | 853.8 | 790.9 |

Observed table-order maxima were 2,164.4 / 1,171.5 / 963.1 ms respectively.
Some packed and warmed samples also varied substantially; the roughly 0.8–0.9 s
near-packed results are not claims of precise equivalence. The especially slow
aged compressed median was dominated by decoder/CPU time, not its 7.3 ms median
`pread` time. Do not attribute all elapsed-time variance to storage layout.

The read metrics independently support the locality finding:

| Metric, table-order capture | Aged | Current table rewritten |
| --- | ---: | ---: |
| Current B-tree pages | 15,843 | 14,326 |
| Current-page bytes | 64,892,928 | 58,679,296 |
| Unused bytes inside current pages | 8,123,621 | 2,060,581 |
| Current overflow pages | 10,937 | 10,937 |
| Median kernel bytes read | 160.1 MiB | 56.3 MiB |
| Median time inside `pread` | 1,242.7 ms | 47.2 ms |

Only a modest reduction in page count accompanies a much larger I/O improvement.
UUID order adds index-driven table lookups: the aged fixture performs 20,493
measured reads instead of 15,851 in table order. Actual query plans are retained
in each artifact. SQLite describes the [index lookup trade-off](https://sqlite.org/queryplanner.html#sorting)
and [page-locality diagnostics](https://sqlite.org/dbstat.html).

The one measured current-table rewrite cost **2,296.2 ms**, plus 4.3 ms final
checkpoint/close; whole-database compaction cost **19,863.0 ms**, plus 43.2 ms.
These are individual maintenance observations, not five-trial medians. A startup
gain does not make either operation free at quit. The current-only rewrite grew
this database temporarily and left the old table's pages on the freelist.

## Free-list counterexample to unconditional table rewriting

Same generation seed, notes, contexts and retained history, but interleave one
16-KiB private payload every ten mutations and release those payloads at the end.
That leaves **45,451 free pages (177.5 MiB)** scattered among retained data. This
is deliberately adverse pending-buffer cleanup, not a claim about typical users.
The packed baselines are constructed **before** the release and therefore do
not consume the holes; their result must not be generalized to packing after
arbitrary cleanup.

Three cold trials per layout/access variant, all exact-value checks passing:

- Current-table rewrite still reduces the current B-tree to the same 14,326
  pages, but table-order startup is **1,709.6 ms**, with **124.9 MiB** kernel reads
  and **880.9 ms** inside `pread`. It reuses scattered free pages.
- Whole-database compaction restores 56.3 MiB of reads and about 56.5 ms inside
  `pread`; its complete-startup median is 1,075.8 ms, including CPU variance.
- Current-only rewrite costs 2,957.9 ms; full compaction costs 18,729.4 ms before
  their final close. Neither becomes an adopted automatic operation.

This is a measured failure of the proposed *performance guarantee*, not data
loss and not a SQLite contract violation. A table is logically ordered without
being physically contiguous. [SQLite VACUUM](https://sqlite.org/lang_vacuum.html)
explains why full compaction can improve layout; it does not promise that an
ordinary INSERT/SELECT table rebuild avoids the freelist.

## Secondary factors

- **SQLite page cache:** aged cold table-order medians were 2,099.7 / 2,076.0 /
  2,099.8 ms with 512 KiB / 4 MiB / 64 MiB caches. The larger cache raised peak
  RSS to about 337 MiB without solving cold scattering. UUID-order rereads
  decreased, but the cold-start penalty remained. No default enlargement adopted.
- **Temporary lifetimes:** batching autorelease-pool drainage reduced table-order
  peak RSS from **612.8 to 262.0 MiB**; cold medians were 2,212.1 versus 2,076.0 ms.
  The packed control similarly dropped from 717.6 to 366.7 MiB. Temporary growth
  is avoidable even though keeping all final notes/search state is intentional.
- **Intermediate collection buffers:** direct-row peak RSS was **262.0 MiB**
  versus **366.7 MiB** for the flat packed control with identical pool discipline.
  Direct rows retain final decoded values/context, not borrowed SQLite pointers.
- **macOS read-ahead:** 24 additional cold measurements reuse the original file
  images with `F_RDAHEAD=0` on the measured descriptor. Aged table-order median
  remained 2,049.6 ms; rebuilt table-order rose to 1,016.9 ms and flat packed to
  roughly 920–960 ms. It does not solve this problem; keep normal read-ahead.
  This controls [the documented read-ahead flag](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html),
  not every source of kernel read amplification. No Apple API violation inferred.
- **CPU versus I/O:** raw byte-touch controls isolate the layout penalty without
  constructing notes/search. Main cold table-order medians were about 1.30 s
  aged versus 0.23 s rebuilt/compacted. Once reads are compact, note construction,
  decoding and search preparation dominate. The required production Swift codec,
  framework startup, real windows and full acceptance catch-up remain unmeasured.

## Smaller-note comparison

The same 100,000-object initial history with 1,000 live notes, ten rounds and
256-character base bodies produced 11,000 current writes, 987 delete/recreate
pairs and 111,000 retained objects. Final cells occupy 682,064 bytes, including
the same 256 context bytes per note. Another **120** measured loads passed.

Cold complete startup, median milliseconds (five trials):

| Layout | Table order | UUID order | Flat packed | Compressed packed |
| --- | ---: | ---: | ---: | ---: |
| Aged | 32.84 | 36.59 | 12.01 | 11.63 |
| Current table rewritten | 12.18 | 14.50 | 12.40 | 12.30 |
| Whole database compacted | 12.42 | 15.54 | 11.86 | 12.05 |

The aged table-order maximum was 34.85 ms; current-only rewrite cost 31.9 ms
plus 27.0 ms final checkpoint/close in one observation. Full compaction cost
4,388.9 ms plus 12.8 ms close. Thus the same relative locality effect can be a
small absolute cost for smaller notes; do not generalize the large-note seconds
to every collection. This does not change the free-list counterexample.

## Reproduction and artifacts

Use the existing qualified SQLCipher source build containing `libsqlite3.a` and
`sqlite3.h`. `--skip-build` reuses already refreshed application object files;
omit it to rebuild the app first. The driver always compiles a new probe.

```sh
python3 tests/run-startup-storage-comparison.py --skip-build --aged \
  --notes 10000 --body-chars 4096 --history 100000 --churn-rounds 10 \
  --repeats 5 --conditions warm cold --secondary \
  --sqlcipher-build /path/to/sqlcipher --key-mode raw

# Same final state, with a deliberately fragmented freelist:
python3 tests/run-startup-storage-comparison.py --skip-build --aged \
  --notes 10000 --body-chars 4096 --history 100000 --churn-rounds 10 \
  --hole-interval 10 --repeats 3 --conditions cold \
  --sqlcipher-build /path/to/sqlcipher --key-mode raw

# Reuse completed baseline images; do not overlap benchmark runs:
python3 tests/run-startup-storage-comparison.py --skip-build --aged \
  --notes 10000 --body-chars 4096 --history 100000 --churn-rounds 10 \
  --repeats 3 --conditions cold --layouts aged rebuilt --read-ahead off \
  --reuse-aged-root /path/to/baseline-artifact-directory \
  --sqlcipher-build /path/to/sqlcipher --key-mode raw
```

Main: **240** measured loads; free-list stress: **36**; read-ahead control: **24**.
Smaller-note comparison: **120** (repeat the main command with `--notes 1000
--body-chars 256` and omit `--secondary`). Total: **420**, comprising 360 full
note/search loads and 60 explicitly raw-read controls. All full-decode loads
passed exact note/context/search checks and all cold loads
passed the residency/I/O gates. The 48-load, 100-note smoke run passed first.
Raw controls are explicitly marked `decode: false`, not complete startup.

Temporary artifact directories under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`:

- `nv-startup-comparison-qj83kie8`: main 240-load matrix.
- `nv-startup-comparison-321rwwnp`: free-list stress.
- `nv-startup-comparison-eagwkm9j`: read-ahead disabled, reused main images.
- `nv-startup-comparison-8iwpnjjc`: smaller-note comparison.
- `nv-startup-comparison-x7cc7tpy`: initial smoke run.

Each contains full JSON measurements, subprocess logs and a compiled probe;
original runs also retain synthetic fixtures and independent expected bytes.
These temporary artifacts are not durable user-data storage. Reproducible source
and this report are the lasting record. The current-row SQL contract suite also
passes **21** checks, including a new query-plan guard against UUID-index startup
traversal or a temporary sort. No TLA+ transition or invariant changed: physical
row order and temporary allocation lifetimes are below those models' abstraction,
so their configurations were not rerun for this performance experiment.

`zsh build.sh` passed after the benchmark runs (with existing sandbox/Xcode
service warnings). The original non-aged harness also passed a six-load functional
regression check; its tiny-fixture timings are not additional performance evidence.
