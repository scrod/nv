# Clean-quit locality: measured options and implementation direction

Date: 2026-09-14. Follow-up to [aged current-row startup](aged-current-row-startup-validation.md).
Status: **tested design candidate, not a frozen SQLCipher profile, current-cell
codec or production read-ahead implementation**. The single private database,
current-row startup and removal of the packed cache remain adopted. These
experiments do not establish packed-equivalent performance for every collection.
The [opportunistic full-VACUUM policy](#adopted-opportunistic-full-vacuum-policy)
is adopted; its scheduling thresholds and interruption/latency qualification
remain implementation gates, not completed test results.

Implementation follow-up (2026-10-07): the
[private current-row contract](private-current-row-codec.md) freezes the bounded
raw/zstd/dictionary framing and its database mapping. The
[4F report](phase4-current-row-locality-maintenance-validation.md) records the
production-path tests and warm measurements. The implementation retains 4-KiB
cipher pages, omits physical read-ahead, and exposes explicit bounded compaction
for qualification. Automatic maintenance remains disabled. The measurements and
candidate recommendations below describe the earlier experiments; the follow-up
records which parts were implemented and which still need qualification.

The [follow-up rewrite/codec matrix](sqlite-rewrite-locality-validation.md)
now tests full VACUUM with compressed 16-KiB rows, rewrite plus read-ahead,
insertion/index/freelist variations, reusable decoding, and zstd. Zstd narrows
the non-rewriting median gap to about 9% in its confirmation run, but includes
a substantial slow outlier. The measurements below remain the original zlib
experiments; they are not an exhaustive ranking of the newer candidates.
The subsequent current-only recompression sweep tests zstd levels 1–19 and
minimum-match/strategy options. Levels 3–6 remain the useful candidates: high
levels spend substantially more encoding time without a clear startup gain.
It does not support making all-row recompression a mandatory quit step.
The [shared-dictionary follow-up](zstd-shared-dictionary-validation.md) additionally
tests exact-current-data training, dictionary reuse, mixed-generation crash
ordering and corruption checks. Dictionaries reduce some current-row payloads
but do not establish a reliable full-launch improvement or an automatic
retraining-on-quit policy.

## Bounded dictionary tuning selected for the candidate

The user has selected **zstd level 3 with capped training**, rather than raising
compression levels or training on every note at each quit. Use these initial
implementation/qualification values:

- At most **1,024 candidate notes**, distributed across the captured current
  collection, not just its first notes; at most **8 MiB total encoded training
  input**, and an **8-KiB output dictionary**. These are optimization budgets,
  not limits on note size, collection size, history or the rows actually saved.
- Select from already resident, consistently captured current values. Do not
  reread every current SQL cell or scan history just to train. Avoid serializing
  an oversized sample solely to discover it exceeds the remaining budget; skip
  it using checked length bounds. Do not visit an unbounded succession of other
  candidates to fill the quota. Save every note normally whether sampled or not.
- Train at most once for that captured generation, off the interaction thread.
  Reuse an applicable existing dictionary, or use independent level-3/raw cells,
  when there are too few useful samples, training fails, or optimization is
  skipped/cancelled. A dictionary is not required for an otherwise durable quit.
- These input bounds are not a hard wall-clock deadline. Training and disk I/O
  can still run slowly. Cancellation makes the output inapplicable; it does not
  authorize freeing worker-owned buffers or interrupting an in-flight commit.
- If installing a new dictionary, atomically retain its exact bytes and the
  referencing current rows with unchanged current-view generation checks.
  Retain every old dictionary still referenced by rows. Never update a dictionary
  in place under an existing reference or make immutable provider/history objects
  depend on this private optimization.

This selects the **compression/training tuning**, not automatic table rewriting
on every quit, a frozen binary cell encoding, a new cipher page size or a packed
cache. The [continued rewrite investigation](sqlite-rewrite-budget-validation.md)
tests the remaining physical allocation choices. Production byte fixtures,
supported-platform qualification and the actual adapter's generation/crash
boundaries remain required. No modeled logical acceptance transition changes.

## Recommendation

Do not make table replacement, freelist exhaustion or whole-database VACUUM a
normal quit requirement. Instead, pursue **smaller current rows plus bounded
read-ahead of their actual pages**. This addresses scattered allocation without
trying to force SQLite to allocate a contiguous extent:

1. Qualify independently compressed current cells with a raw fallback, and
   16-KiB database pages. They retain one current representation, not a second
   cache. Compression happens before encryption and before the short writer
   transaction. Decode one cell at a time into final unpublished note/context
   storage. Do not change provider object bytes or compress ciphertext.
2. At a healthy clean quit, after materialization catches up, optionally retain
   a small **physical read-ahead hint** in the same private database: sorted page
   locations for the current-note B-tree, including overflow pages. It contains
   no note values, causal records, coverage certificate or portable identity.
3. At the next eligible launch, use bounded concurrent reads to warm those
   ciphertext pages, then execute the ordinary consistent SQL current-row load
   and every existing decoder/publication check. The hint neither supplies
   values nor excuses any SQL read, validation, history-loss check or fence.

The strongest measured word-text combination was **916 ms**, versus **1,184 ms**
for the same compressed current rows without read-ahead and **757 ms** for the
experimental packed control. It needed no current-table rewrite. This is an
improvement, **not proof that packing has no possible performance benefit**.
The earlier fresh-database result must not be generalized to all aged layouts.

The first adapter experiment should isolate the read-ahead optimization from
the row-codec/page-size decision: it also works with unchanged 4-KiB/raw rows.
Do not silently freeze all three changes on the strength of one machine's
startup workload. Whole-store write amplification, memory pressure, other
platforms and the production codecs still need qualification below.

## Measurements

All large cases use the earlier workload: 10,000 live notes, 210,000 retained
synthetic history objects, ten edit rounds, 10,094 delete/recreate pairs, 52.54 MiB
of final note/context bytes and deliberately fragmented free space. All final
word-text note/context bytes are identical across the codec/page-size variants.
Every measurement follows successful FULL-synchronous commits, a completed
TRUNCATE checkpoint and close. Every load reads zero WAL bytes, constructs all
actual NV note/search values and passes independent exact-value checks.

Cold complete startup medians, milliseconds; three trials unless stated:

| Page size / current-cell storage | Aged table scan | Current table rewritten | Packed compressed control, aged image |
| --- | ---: | ---: | ---: |
| 4 KiB / per-cell zlib | 1,958 | 1,121 | 777 |
| 16 KiB / raw | 1,529 | 1,366 | 763 |
| 16 KiB / per-cell zlib | 1,165 | 1,004 | 782 |

The last variant reduces overflow pages from the original raw 4-KiB fixture's
10,937 to **zero**, but still has 2,025 scattered current pages and about 12 MiB
unused within them. Larger pages/compression do not guarantee contiguous or
densely filled storage. Its current-table rewrite costs **883 ms** in one
observation for a roughly 161-ms median startup gain; that does not justify
unconditional rewrite-on-quit. These codec/layout changes were exercised
throughout aging, not just applied to a fresh final table.

Read-ahead tests use a saved page list, not a DBSTAT scan during launch. All
prefetch time and subsequent normal SQL loading are included in startup:

| Same-image comparison | Ordinary scan | With read-ahead | Packed compressed |
| --- | ---: | ---: | ---: |
| Raw 4 KiB, one worker, adjacent pages only | 2,128 | 1,778 | 791 |
| Raw 4 KiB, eight workers, adjacent only | 2,121 | 1,163 | 768 |
| Raw 4 KiB, eight workers, bounded gap coalescing; five trials | 2,083 | 1,048 | 768 |
| Compressed 16 KiB, eight workers, adjacent only; five trials | 1,184 | **916** | 757 |

The last row's observed read-ahead maximum was **1,093 ms**. Current-row peak RSS
was about **265 MiB**, versus **342 MiB** for packing. Read-ahead adds at most
eight 256-KiB scratch buffers plus a small page/range list, not a duplicate
encoded note collection. Its SQL reads still authenticate/decrypt pages normally.

The raw hint occupies **126,744 bytes** (15,843 eight-byte page numbers); building
it cost **982 ms**, plus 16 ms final checkpoint/close, in one observation. With
compressed 16-KiB rows it occupies **16,200 bytes** and costs **351 ms**, plus
16 ms close. These include scanning current pages and saving the hint, not
rebuilding history. Quit is not free: measure this cost alongside launch savings.
The prototype uses plain page numbers; a production codec may encode adjacent
ranges without giving those ranges semantic authority.

### Less-compressible text

The adverse fixture substitutes deterministic random printable ASCII with the
**same body byte lengths**. It is a sensitivity test, not typical prose or a
sample of user data. Current payload stays about 45.8 MiB after per-cell
compression instead of the word fixture's 19.3 MiB. Even with 16-KiB pages and
zero overflow, aging leaves **5,774 pages** and roughly 43.8 MiB unused inside
them. Eliminating overflow alone does not eliminate fragmentation.

- Ordinary compressed current-row scan: **1,300 ms**; rewritten: **912 ms**;
  packed control: **440 ms**. The ASCII-only decoder is also faster than the
  Unicode-word decoder; do not compare these absolute times as an I/O-only effect.
- Same hinted image, adjacent-only read-ahead: **1,337 → 769 ms**; packed **467 ms**.
  Kernel reads stay about **91.7 MiB**, rather than increasing materially.
- Allowing each range to include gaps up to four times its selected-page count
  reduces a separately repeated same-image median **1,318 → 649 ms**, but reads
  about **216.5 MiB** instead of 91.7 MiB. This is an explicit throughput/extra-I/O
  tradeoff, not free locality. Prefer adjacent-only coalescing as the initial
  conservative candidate; do not adopt the larger amplification automatically.

## Concrete candidate lifecycle and failure rules

This section is the proposed adapter experiment, not behavior already implemented
by the synthetic probe. It preserves [LocalStore](../LocalStore.md) and
[ADR 0008](../../adr/0008-reuse-the-existing-quit-flow.md).

### Clean quit

1. Follow the existing admission/quiescence, local history/private-state and
   projection/provider quit ordering. Fully catch up current rows/context for
   the optimized path. A committed edit is already safe before hint work.
2. Under exclusive ownership, capture the current view epoch/prefix, store and
   schema/cipher geometry. On a bounded read transaction enumerate only the
   current B-tree's pages with `dbstat WHERE name='current_notes'`; sort/coalesce
   that page set. SQLite's documented DBSTAT interface includes overflow pages.
   The pinned source's name constraint restricts traversal to that B-tree, not
   every retained object. [DBSTAT documentation](https://sqlite.org/dbstat.html).
3. Release the read transaction. Install the bounded hint in a short generation-
   checked SQL transaction only if its captured current layout is still valid.
   Keep it separate from required private-state roles; no second file or note
   representation is needed. Do not retain a writer transaction across scanning,
   text processing or provider work. The probe's single-transaction construction
   is only a maintenance-cost experiment, not this production transaction cut.
4. Finish ordinary checkpoint/close. There is no extra durable-note barrier,
   cloud publication, backup obligation or cleanup of retained history. Hint
   failure alone cannot prevent an otherwise durable quit. A genuine shared
   database I/O/integrity error still invokes the normal failure classification.

Work is bounded by current pages (plus sorting that page set), not total
historical BLOB bytes or total freelist size. For oversized hints, omit/truncate
the optimization, **never reject a collection or omit a note**. Concrete
production byte/time scheduling budgets remain a qualification task; the probe
caps hint parsing and per-worker scratch but is not a general cancellation adapter.

### Returning launch

1. Establish the ordinary local owner/store/key and consistent startup target.
   Use this optimization only for the qualified clean, checkpointed main-file
   path. Do not try to prefetch a live/recovered WAL using main-file offsets.
   Startup catch-up still runs normally; if it changed current rows, skip an old
   hint. A hint is not evidence that catch-up is unnecessary.
2. Read the optional hint via SQL, under the same selected store. Verify its
   bounded codec, scope/epoch/layout generation and cipher page size. Validate
   strictly increasing, in-range offsets with checked arithmetic. Missing,
   unsupported, stale or malformed *hint contents* mean ordinary startup.
   SQLCipher page-authentication/database errors are not merely malformed hints.
3. Use a positively matched read-only handle to the selected physical database.
   Schedule a fixed small number of ciphertext reads with bounded buffers and
   coalesced adjacent ranges. Do not feed raw page bytes into the note decoder
   or SQLite pager. All actual values still come from SQLite. The production
   file-handle/root-replacement check and cancellation lifetime need qualification.
4. Perform the existing table-order SQL load, strict current-cell/context decode,
   full in-memory search initialization and final owner/epoch/prefix publication
   checks. Ignoring, partially completing or using an ineffective hint must not
   change the logical result. Never publish early because prefetch completed.

A work/queue budget is not a hard deadline on a blocked kernel read. Do not
close/reuse its descriptor or free its buffers while outstanding work is using
them. This is launch I/O, not background/debounced search or editor interaction.

### Invalidation and storage boundary

- Invalidate any saved hint in the same transaction that changes current rows
  or their layout generation. Ordinary context-only acceptance still updates
  the required view correctly; the hint never replaces that context.
- Keep `auto_vacuum=NONE` for this candidate. Other-table writes may allocate
  free pages but do not authorize assuming an allocated current page moved.
  Invalidate before explicit schema/layout maintenance, repair/replacement or
  page-size conversion, including maintenance that leaves note values unchanged.
  [`auto_vacuum` is not table defragmentation](https://sqlite.org/pragma.html#pragma_auto_vacuum).
- A missing hint is not missing retained history or lost user settings. It is
  disposable acceleration within the same database; it never travels in NV Data.
  Do not revive cache certificates, acceptance-batch tokens, changed-birth logs,
  provider-snapshot trust or cross-file activation for this purpose.
- Compression is per **derived current cell**, not SQL indexes as opaque bytes
  or immutable history. Unknown/corrupt current-cell codecs require the existing
  materialization repair, not silent row skipping. Independent bounded codec
  fixtures/raw fallback tests precede production adoption.

## Adopted opportunistic full-VACUUM policy

Occasionally compact a healthy private database when it is idle and a measured
locality benefit justifies the work. This is **optional scheduled full `VACUUM`**,
not SQLite `auto_vacuum=FULL` or `INCREMENTAL`; retain `auto_vacuum=NONE`.
It does not prune retained history, introduce a packed cache, retrain dictionaries
or require table replacement on each quit. Ordinary current-row saving/startup
must remain correct when maintenance never runs.

- **Eligibility:** require both a substantial cooldown since successful
  compaction and evidence of fragmentation worth addressing, especially in the
  current-note B-tree. Elapsed time or total freelist size alone is insufficient.
  Collect evidence off the startup/required-quit path; do not add a mandatory
  scan of historical bytes or all database pages. Consider total database size
  when estimating cost, since full VACUUM rewrites retained history as well.
  Keep scheduling observations private and advisory, never history evidence.
- **Admission:** use the existing exclusive local-store owner, only while the
  database is healthy, no required commit is pending and admitted changes are
  already durable. Do not overlap repair, store/key transitions or close. Check
  temporary-space headroom; a preflight is not a reservation. Lack of space or
  budget means skip, not a user-facing prerequisite to editing or quitting.
- **Writer priority:** VACUUM is the deliberate exception to short *ordinary*
  write transactions. Run it off the interaction thread, but do not mistake
  that for concurrent write availability. Resumed editing, required persistence
  and a quit request each trigger cancellation/cessation of maintenance. Qualify the actual
  worst observed time until the writer can accept and durably commit new work,
  including rollback, final commit and checkpoint phases. An interrupt request
  is not completion; retain connection/resources and exclusive ownership until
  the operation settles. Do not acknowledge RAM-only edits or invent another
  journal to conceal a maintenance-induced saving delay. Keep automatic
  execution disabled until this behavior meets the normal saving/quit contract.
- **Layout and failures:** durably invalidate any physical read-ahead hint
  before starting; rebuild it only after successful maintenance under fresh
  layout/generation checks. Interrupted maintenance may leave the hint absent.
  Preserve all logical identities, exact retained objects, private pending
  state, current values/context, accepted prefixes and key/security policy.
  Failed/skipped maintenance alone is nonfatal; actual database I/O/integrity
  failures use the existing recovery policy, never in-place repair by VACUUM.
  Record successful completion separately from attempts and back off failures
  or cancellations rather than repeatedly restarting while the user is active.

Exact cooldown, fragmentation, space and latency budgets remain to be calibrated;
there is no adopted monthly schedule or guarantee of packed-equivalent launch.
Firefox's [VacuumManager](https://searchfox.org/firefox-main/source/storage/VacuumManager.cpp)
provides the idle/cooldown/participant-veto scheduling precedent, not NV's numeric
thresholds. SQLite documents [whole-store space and repacking](https://sqlite.org/lang_vacuum.html),
[serialized writes](https://sqlite.org/isolation.html) and
[non-instant interruption](https://sqlite.org/c3ref/interrupt.html).

Before enabling this policy, measure locality and cold full-note/search startup
through realistic edit, growth, delete/recreate and clean-quit cycles **after one
VACUUM**, with matching never-vacuumed controls. Also qualify resumed-input to
durable-commit latency and cancellation at different phases; process crash/reopen,
space exhaustion, failed checkpoint/close, exact history/private-state retention
and stale-hint rejection. A process-kill result is not power-loss proof. The
existing repeated fixed-value rewrites do not establish benefit lifetime, and
the logical TLA models do not establish maintenance cancellation or I/O latency.

## Alternatives and remaining qualification

Full [VACUUM](https://sqlite.org/lang_vacuum.html) rewrites the database and can
restore locality, but depends on retained history size and temporary space.
Consuming every free page before appending a current table merely substitutes
work proportional to an unbounded freelist. Neither is an appropriate mandatory
quit step. Larger page geometry is a supported SQLCipher setting, not a guarantee
about per-table allocation. [SQLCipher page size](https://www.zetetic.net/sqlcipher/sqlcipher-api/#cipher_page_size).

Before adopting a physical format/default, qualify:

- Actual Swift current-cell/frontier decoding and complete note/search startup;
  independent compression framing/length/fallback tests, both collection profiles.
- Representative small collections, long notes, larger contexts and real prose;
  repeated close/edit/reopen cycles, not only the single aged endpoint.
- Intel macOS, other supported platforms/storage and low-memory pressure. This
  machine's page cache, SSD queue depth and read-ahead behavior are not portable
  latency contracts. An 8-worker setting is a tested candidate, not a universal optimum.
- Whole-store acceptance/lookup/checkpoint/write-amplification effects of 16-KiB
  pages. Startup alone cannot select the global cipher profile.
- Actual hint generation/invalidation/installation, crash at each boundary,
  cancellation, owner/root replacement, shared-page corruption and read errors.
  Logical hint faults below are narrower tests, not proof of those adapter cuts.

If the release requirement is *guaranteed packed-like physical layout*, these
results do not satisfy it. An independently rebuilt current-state file would
provide control over file layout but reintroduce another representation and its
activation/binding costs; that would require revisiting the adopted decision,
not silently restoring a packed cache. Within the current one-database design,
bounded read-ahead is the best tested non-rewriting direction, with residual
hardware/workload dependence stated explicitly.

## Reproduction and evidence

Use the existing [runner](../../../tests/run-startup-storage-comparison.py) and
[compiled probe](../../../tests/AgedStartupStorageComparison.m). For example:

```sh
python3 tests/run-startup-storage-comparison.py --skip-build --aged \
  --notes 10000 --history 100000 --churn-rounds 10 --hole-interval 10 \
  --page-size 16384 --cell-codec zlib --repeats 5 --conditions cold \
  --layouts aged rebuilt hinted --aged-kinds table table-prefetch compressed \
  --prefetch-workers 8 --sqlcipher-build /path/to/sqlcipher --key-mode raw
```

Add `--body-pattern random` for the adverse text fixture. `--prefetch-workers 1`
and `--prefetch-amplification 4` isolate the scheduling/coalescing alternatives.
`--reuse-aged-root` reuses matching closed images, creating any new variant in
the new output directory without mutating earlier artifacts. All measurements
run sequentially, in randomized variant order, with a fresh child per load.

Cold preparation, actual-note oracle and measurement limitations are the same
as the [preceding report](aged-current-row-startup-validation.md). In particular,
eviction/residency scans and instrumentation allocation are outside timing, not
proposed startup work. Prefetch, hint SQL reads, decoding and search are **inside**
timing. Parallel `pread_ms` is summed worker service time and may exceed wall
time; use `prefetch_ms`/`total_ms` for elapsed-time comparisons. Nonadjacent-read
counts after parallel prefetch describe concurrent completion order, not a
SQLite B-tree traversal. No TLC rerun is required for this physical experiment:
the adopted logical transitions/invariants have not changed.

Temporary artifact directories under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`:

| Suffix after `nv-startup-comparison-` | Experiment |
| --- | --- |
| `uqdyintx` | Eight-load 100-note compression smoke test |
| `r04brdvr` | 4-KiB compressed cells, 18 loads |
| `h4_qoziz` | Raw 4-KiB saved hint, serial read-ahead, nine loads |
| `blijktue` | 16-KiB raw cells, 12 loads |
| `qxrx_fui` | Raw 4-KiB hint, eight workers, nine loads |
| `8h4k8xfx` | Same hint, bounded gap coalescing, 15 loads |
| `sa553okb` | 16-KiB compressed cells, 12 loads |
| `6bcqro84` | Adverse text, 16-KiB compressed cells/layouts/gap read-ahead, 21 loads |
| `cnnt22bw` | Word text, 16-KiB compressed cells/adjacent read-ahead, 15 loads |
| `wzfgo9ks` | Adverse text, adjacent read-ahead, nine loads |
| `2swkabxc`, `bvimn98x`, `n1lohtja` | Malformed, empty and deliberately wrong-page hints; one full load each |

These contain JSON results, subprocess logs and synthetic fixtures where newly
created. Source and this report are the durable record, not temporary artifacts.

**Completed validation:** 131 full note/context/search loads: 120 large-fixture
comparisons, eight small smoke loads and three hint-fault checks. All passed
exact-value and cold-residency/I/O checks, with zero WAL reads. Empty/malformed
hints performed no prefetch; the valid-looking wrong-page hint read unrelated
pages but still produced the identical complete notes through ordinary SQL.
That is a correctness check of hint non-authority, **not** a test of production
layout-generation invalidation or actual disk corruption. Those remain above.

The 21 existing real-SQL fast-start checks and 17 schema tests pass unchanged.
`zsh build.sh` also passes with the existing sandbox/Xcode-service warnings.
The original FrozenNotation/direct-row/packed harness additionally passes three
tiny-fixture functional regression loads; those are not performance evidence or
part of the 131-load count above.
The performance-profiling guidance informed measuring complete ready-to-search
work, controlling cold I/O and reporting the unfavorable workload, not just
timing the successful prefetch calls.
