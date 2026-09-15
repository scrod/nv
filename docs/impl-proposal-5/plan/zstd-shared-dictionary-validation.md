# Shared zstd dictionaries for private current rows

Date: 2026-09-14. Experimental follow-up to the
[compression/locality matrix](sqlite-rewrite-locality-validation.md). This does
not adopt a codec, dictionary lifecycle, provider format, or new quit obligation.
The [subsequent tuning decision](clean-quit-locality-strategy.md#bounded-dictionary-tuning-selected-for-the-candidate)
selects level 3 and a bounded 1,024-note / 8-MiB sample for the implementation
candidate; the measurements on this page retain their original inputs.

## What is tested

Use the existing [aged-startup runner](../../../tests/run-startup-storage-comparison.py)
and compiled probe, with experiment-only
[dictionary helpers](../../../tests/ZstdDictionaryExperiment.h) and
[dependency/crash checks](../../../tests/ZstdDictionaryContracts.h). No app or
Swift-library dependency changed. Real notes, provider roots, credentials and
note interaction code are not used.

The dictionary and its SHA-256 digest are rows in the **same SQLCipher database**
as current notes. Every independently compressed current cell names its exact
dictionary digest; the zstd frame's shorter dictionary ID is cross-checked, not
used as sole identity. The 32-byte per-cell reference, dictionary reads, hash
validation and preparation are included in measured storage/launch costs. The
experimental registry is bounded to four dictionaries; this is a test limit,
not a production retention policy or lifetime limit.

Encoders reuse `ZSTD_CDict` and a compression context; decoders prepare each
`ZSTD_DDict` once and reuse it and a bounded single-cell output buffer. Each frame
can be read independently and in any order. Raw fallback counts the extra
reference overhead before deciding compression is worthwhile. The API contract
fixes compression level at CDict construction; these tests do not pretend that
changing unrelated CCtx parameters afterward changes that level. See the
[pinned zstd API](https://raw.githubusercontent.com/facebook/zstd/v1.5.7/lib/zstd.h).

Training uses `ZDICT_trainFromBuffer`, with three inputs: 4,096 independently
generated records; 4,096 evenly spaced actual current cells (21,835,010 bytes);
or **all 10,000 exact current cells** (53,986,411 bytes). The latter excludes
only the eight-byte outer comparison-stream header, not any current row.
The independent-data sweep requests 8-, 32- and 64-KiB dictionaries; actual
current-data tests request 8 and 32 KiB. Sample generation, dictionary training, prepared-dictionary setup,
current-row encoding, replacement transaction, hint construction and final
checkpoint/close are measured separately. Training need not be repeated for each
save or launch. The [training API guidance](https://raw.githubusercontent.com/facebook/zstd/v1.5.7/lib/zdict.h)
motivates using many small samples and measuring effectiveness. Held-out data
tests reuse on future input. It is **not required** when the goal is to compress
exactly the current rows used to train the dictionary, provided dictionary
storage and preparation costs are counted. These are the default trainer's
heuristics, not an exhaustive search for an optimal dictionary or optimization
of measured launch latency. The trainer's own internal search/sampling still
applies when all rows are supplied.

### Workloads and limits of held-out evaluation

- **Original words:** the prior 10,000-note aged fixture, 210,000 history objects,
  12,393 free 16-KiB pages, 55,086,848 decoded note/context bytes. Its tiny repeated
  vocabulary is deliberately favorable. Holding out record IDs does **not** make
  this a representative natural-text benchmark or remove its template bias.
- **Mixed genres:** 10,000 synthetic notes, variable lengths around 1–16 Ki UTF-16
  units, six genres (project tasks, recipes, journals, code, research, contacts),
  Unicode, variable words and independent pseudo-random identifiers. Three edit
  rounds, 4,054 delete/recreate pairs, 60,000 retained history objects, 11,266 free
  pages and 53,986,419 decoded bytes. Training uses new records from the same
  generator. This is more varied but still templated, not real-world corpus
  qualification.

All performance runs use 16-KiB SQLCipher pages, a 4-MiB SQLite page cache,
table-order streaming and the same optional bounded ciphertext read-ahead.
The source aged image is copied before current-only recompression. Historical
objects and the packed comparison streams are untouched; there is no VACUUM.
The dictionary experiment retains the ordinary complete note/context/search
oracle and starts every measured process from a committed, checkpointed,
closed database. Cold preparation verifies zero file-page residency and the
runner checks actual kernel reads; timed WAL reads and SQL sorts must be zero.
Packed controls remain comparison instruments, not supported storage.

## Performance results

Sizes below are decimal MB of current-table payload **plus dictionary bytes**;
SQLite page counts expose allocation separately. Full startup includes SQL,
decryption, dictionary preparation, complete NoteObject/context construction and
synchronous search initialization. Each initial total is a three-cold-trial
median; samples of other kinds are interleaved within a run. A training/encoding
time is one maintenance observation, not a median or a bounded deadline.

### Independent training: storage improves, launch benefit is workload-dependent

Zstd level 3, dictionaries trained on the matching synthetic family:

| Workload / dictionary | Current + dictionary MB | Current pages | Ordinary startup ms | With read-ahead ms | Cell decode ms, with read-ahead |
| --- | ---: | ---: | ---: | ---: | ---: |
| Words / none | 18.97 | 1,278 | 926 | 858 | 74 |
| Words / 8 KiB | 16.49 | 1,098 | 914 | 846 | 85 |
| Words / 32 KiB | 16.34 | 1,086 | 946 | 889 | 87 |
| Words / 64 KiB | 16.49 | 1,096 | 918 | 857 | 84 |
| Mixed / none | 16.08 | 1,061 | 549 | 500 | 75 |
| Mixed / 8 KiB | 14.64 | 964 | 470 | 441 | 63 |
| Mixed / 32 KiB | 14.50 | 954 | 623 | 492 | 69 |
| Mixed / 64 KiB | 14.59 | 957 | 571 | 462 | 67 |

The original words fixture saves 13–14% of current payload but adds roughly
10 ms of decoding and has no consistent launch improvement. Mixed data saves
9–10%, but its initial 500-to-441-ms comparison overstates an established codec
gain: construction time also changed from 336 to 298 ms. Unchanged packed-control
times varied greatly; one mixed 32-KiB run's packed-zlib median was **848 ms**.
Those observations are retained, not discarded as impossible.

A **five-trial confirmation** on the same mixed images gives 509 ms without a
dictionary and 507 ms with the 8-KiB dictionary. Packed-zlib controls in those
runs are 442 and 468 ms; packed-zstd controls are 427 and 416 ms. Thus these
measurements do not establish a reliable full-launch gain. An alternating,
12-passes-per-variant, same-process **decode-only** comparison gives 71.29 ms
without a dictionary and 69.05 ms with it. It excludes SQL/I/O/NoteObject work
and is reported as codec evidence only.

Increasing compression level is not a universal improvement: mixed level 6
without a dictionary produces 15.74 MB / 1,039 pages, with 466-ms prefetched
startup and 68-ms cell decode. A 32-KiB dictionary produces 14.56 MB / 957 pages,
but 513-ms startup and 79-ms cell decode. Encoding takes 598 versus 684 ms.
Training uses the default trainer, not a separately tuned level-6 dictionary
search. These measurements do not justify a higher-level default.

**Drift control:** a 32-KiB dictionary trained on words but used for mixed notes
produces **17.05 MB**, worse than 16.08 MB without a dictionary. A raw fallback
does not protect against this regression: dictionary compression can beat raw
bytes while losing to plain zstd. Any adaptive choice should compare against
ordinary compression too, not assume that an available dictionary is useful.

Independent training costs approximately 0.5–1.6 s in the measured cases;
sample generation plus training/setup costs 1.3–2.4 s. Dictionary load/hash/
DDict preparation inside startup is approximately 0.25 ms for 8 KiB,
0.6 ms for 32 KiB and 1 ms for 64 KiB. It is not repeated for every row.

### Train on the exact current state

These tests, inspired by the user's sqlite-zstd example and direct question,
use the identical mixed current cells as compression input and training input.
Current-only sampling does not inspect retained history. The sampling experiment
caps data at 32 MiB; the all-current fixture allows 128 MiB and explicitly fails
instead of silently sampling when exceeded. Neither is a proposed production
memory limit or mandatory startup scan.

| Training input / dictionary | Current + dictionary MB | Current pages | Training s | Setup including sampling/training s | Current recode transaction s | Prefetched startup ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Separate mixed records / 8 KiB | 14.64 | 964 | 0.54 | 1.50 | 0.77 | 441 |
| 4,096 current cells / 8 KiB | 14.51 | 957 | 1.08 | 2.13 | 0.73 | 500 |
| All 10,000 current cells / 8 KiB | 14.53 | 957 | 1.99 | 2.30 | 0.57 | 423 |
| Separate mixed records / 32 KiB | 14.50 | 954 | 1.02 | 1.95 | 1.33 | 492 |
| 4,096 current cells / 32 KiB | 14.40 | 947 | 0.99 | 1.25 | 0.88 | 521 |
| All 10,000 current cells / 32 KiB | 14.38 | 947 | 1.98 | 2.27 | 0.60 | 425 |

The recode transaction includes reading/decoding old current rows, inserting
the dictionary, encoding/inserting replacement rows, indexes and COMMIT; it
does not include prior training, subsequent hint construction or final close.
The all-current cases additionally spend 30–33 ms building hints and 10–11 ms
checkpointing/closing, roughly **2.9 s overall maintenance**. The full two-second
training buffer is not needed during launch. In an app, current values already
in memory may avoid the sampling SQL read; that saving was not measured here.

Training on all rows is valid, but does **not** guarantee the best output:
the 8-KiB all-current dictionary is slightly worse than the sampled one; the
32-KiB all-current dictionary is slightly better. Finite dictionary capacity
and the trainer's heuristics matter. Differences are small, and all-current
training takes about twice the sampled trainer time here.

The later all-current runs also have faster **unchanged packed controls**
(packed zlib 380–381 ms, packed zstd 361–363 ms) and approximately 289-ms note
construction. Do not attribute their full 423–425-ms totals versus earlier
500–521-ms totals to training selection. Their paired, rotating-order codec-only
tests give clearer evidence: **62.97 → 52.91 ms** for the 8-KiB dictionary and
**63.24 → 53.21 ms** for 32 KiB. Each is twelve passes per alternative, with
complete byte equality checked separately. That is about 10 ms saved in decoding,
not 80–100 ms proven saved in whole startup.

### Did the official decompression example expose a missing optimization?

The [official example](https://github.com/facebook/zstd/blob/dev/examples/dictionary_decompression.c)
already matches the important choice: prepare a `ZSTD_DDict` once and use
`ZSTD_decompress_usingDDict`. Our probe additionally reuses DCtx/output storage,
which the example allocates per file. Its optional `refDDict` variant is for
controlling context parameters, not a different decompression algorithm. The
[pinned implementation](https://raw.githubusercontent.com/facebook/zstd/v1.5.7/lib/decompress/zstd_decompress.c)
routes `ZSTD_decompressDCtx` through `ZSTD_decompress_usingDDict` with its referenced
dictionary.

Twelve rotating-order passes per variant on the same validated mixed 8-KiB frames:

| Decoder-only path | Median ms / 10,000 notes |
| --- | ---: |
| Existing strict wrapper, reused DCtx/DDict/output | 63.12 |
| Example's core checks/API, with the same reuse | 61.54 |
| Bind `refDDict` once, then `decompressDCtx` | 62.33 |
| Exact one-frame boundary scan only; no decompression | 0.45 |

The less strict diagnostic paths run only after full strict validation and
produce byte-for-byte equal output. They are not replacement production decoders.
The main decoder retains one extra raw dictionary copy (8–64 KiB), whereas the
example frees that input after creating the DDict. It can be omitted from a
decode-only registry; it is not a missing per-note fast path. All measured
launches include the current implementation's copy. There is no justification
here for dropping bounded output, exact dictionary binding or framing checks.

## Useful ideas from sqlite-zstd, without adopting its extension

The [article](https://phiresky.github.io/blog/2022/sqlite-zstd/) suggests grouped
dictionaries, training from existing rows, caching prepared decoders and doing
compression as incremental maintenance. Its redundant event/JSON workload is
not an NV startup benchmark. We tested its actual-current-data idea above; the
existing probe already reuses prepared decoders.

The [project's API](https://github.com/phiresky/sqlite-zstd) also uses a small
local integer dictionary reference, stores dictionaries in the database, and
allows new/changed rows to remain uncompressed until bounded maintenance. Those
are useful implementation candidates:

- A private integer reference to an immutable, validated dictionary row could
  replace our conservative 32-byte per-cell hash. Keep exact dictionary bytes
  bound in the registry; do not rely only on zstd's short frame ID. Not tested
  here; even eliminating all 32 reference bytes would save only 0.32 MB at
  10,000 notes, before replacement reference/row overhead.
- Reuse a suitable dictionary for ordinary edits, or use plain zstd/raw cells;
  train/recompress only when likely worthwhile. A new dictionary cannot decode
  old frames: mixed generations must stay readable until their references retire.
- A few data-shape cohorts might improve heterogeneous compression, but extra
  dictionary reads, selection policy and lifetime costs need measurement. This
  experiment uses one active dictionary for performance, and multiple only in
  crash/retention tests. It has **not** qualified multi-cohort startup.
- Incremental compression can avoid mandatory whole-current-table work on quit.
  If quit-time retraining is selected instead, freeze the exact current generation
  and install that dictionary plus matching encoded rows atomically; existing
  logical durability does not wait for this optional physical optimization.

Transparent views/triggers are unnecessary to get these benefits in a new
storage library. Compact/nonstandard framing and whole-database VACUUM from the
example are not adopted. Keep this a private current-cell optimization: provider
objects and retained history remain independently interpretable, and losing a
dictionary must not remove the only durable representation of user data.

## Dependency and abrupt-exit checks

These tests use small, runner-owned copies, not performance fixtures in place:

| Check | Required observed result |
| --- | --- |
| Direct zstd read without the required dictionary | API returns an error |
| Direct read with another trained dictionary | API returns an error for the mismatching dictionary ID |
| Reverse read order | Exact decoded values equal forward-order results; no preceding-note dependency |
| Incompressible tiny value | Raw fallback round-trips without a dictionary dependency |
| Ordinary non-dictionary frame after dictionary use | Exact decode; context reuse does not carry a hidden dependency |
| Abrupt exit before dictionary + half-row transaction commits | Reopen exposes one original dictionary and unchanged complete current values/history |
| Abrupt exit after COMMIT, before checkpoint/close | Normal SQLite recovery exposes two referenced dictionary generations and unchanged complete values/history |
| Cleanup while both generations remain referenced | Neither dictionary is removed |
| All rows moved to a third generation, then cleanup | Only the two unreferenced dictionaries are removed; all values remain readable |
| Referenced dictionary removed | Reject missing exact dependency; no silent row omission |
| Dictionary bytes changed while retaining its original zstd ID and claimed SHA-256 | Reject hash mismatch |
| Cell refers to an unknown hash | Reject missing exact dependency |
| Cell hash names A but frame was compressed with B | Reject frame/dictionary-ID mismatch |

The crash checks compare hashes of all decoded current values and exact retained
object bytes before/after, assert the nonzero counts of actual references to
both generations, and run the full independent note/context/search oracle after
normal SQLite recovery/checkpoint. They therefore do not rely merely on flags
saying a migration completed. Before-COMMIT and after-COMMIT processes exit
without orderly SQLite close. This is **process-crash evidence**, not power-loss
qualification. The closed-file measurement VFS is not misused for WAL recovery.

Four rejection controls require the specific error reason, not merely any
nonzero process exit. An early harness version asserted that some dictionary
must exist before inspecting a missing-dictionary fixture; it was corrected so
the actual reference lookup detects the missing dependency. No acceptance
condition was relaxed to make that negative control pass.

Missing/corrupt dictionaries are not proven recoverable by these checks. They
show detection and no successful partial load. Production reconstruction would
still have to rebuild derived current values from independently validated history,
following [LocalStore](../LocalStore.md), not discard required private state or
claim the dictionary is optional while live rows depend on it.

## Interpretation boundaries

This changes the physical encoding of a synthetic current materialization, not
its logical authority. The [specification](../../iCloud-Drive-Support-Spec.md),
[quit ADR](../../adr/0008-reuse-the-existing-quit-flow.md),
[vocabulary](../../../CONTEXT.md) and [model coverage](../../tla/README.md) remain
unchanged. There are no new TLA+ transitions; TLC is not rerun for codec timings.
These checks do not prove accepted-history/current-view correspondence, the
production Swift codec, recovery UI, concurrent admission or a complete migration.

The existing Homebrew zstd 1.5.7 static library targets macOS 13; the experiment
runs on macOS 26.6.2/arm64 and does not establish macOS 11.5 or Intel support.
SQLCipher is the same pinned Community 4.19.0 / SQLite 3.53.4 build used previously.
Measurements on a live development machine retain outliers and separate codec
time from note construction; small total-time differences are not guarantees.

## Reproduction and artifacts

Start from a fresh fixture, or add `--reuse-aged-root` with a matching prior
artifact; new variants are written to a new temporary directory:

```sh
python3 tests/run-startup-storage-comparison.py --skip-build --aged \
  --notes 10000 --body-chars 4096 --body-pattern mixed \
  --history 20000 --churn-rounds 3 --hole-interval 4 \
  --page-size 16384 --cell-codec zstd --cell-decoder stream --zstd-level 3 \
  --dictionary-size 8192 --dictionary-pattern mixed \
  --dictionary-training all-current --repeats 3 --conditions cold \
  --layouts recompressed-hinted --aged-kinds table table-prefetch compressed zstd \
  --prefetch-workers 8 --sqlcipher-build /path/to/sqlcipher --key-mode raw \
  --zstd-prefix /path/to/zstd
```

Use `--dictionary-training held-out` or `current` for the other inputs, and
`--dictionary-size 0` for the plain-zstd control. To reproduce the original words
fixture, use `--body-pattern words --dictionary-pattern words --history 100000
--churn-rounds 10 --hole-interval 10`. Dictionary sizes tested are 8,192, 32,768
and 65,536 bytes, levels 3 and 6. The mixed/word-trained drift run deliberately
uses different body and training patterns.
The historical `current` runs on this page used
`--dictionary-sample-limit 4096 --dictionary-sample-budget 33554432`; specify
those explicitly now that the runner defaults are 1,024 and 8 MiB. The
`all-current` diagnostic still explicitly bypasses sampling, with its separate
128-MiB fixture bound; it is not the selected quit strategy.

For isolated API/lifetime checks, use a small fixture (`--notes 100 --history
200 --churn-rounds 2 --hole-interval 2 --dictionary-size 8192`) and
`--dictionary-contracts`. `--dictionary-micro-baseline /path/to/matching/plain/store.sqlite`
adds the alternating decode-only comparison. `--dictionary-example-comparison`
adds the strict-wrapper/example/refDDict comparison on a dictionary fixture.
These microbenchmarks verify full decoded equality; they are not cold launches.
Raw test files and all intermediate values are synthetic.

Temporary roots under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`, with prefix
`nv-startup-comparison-`:

| Suffix | Experiment | Timed full loads |
| --- | --- | ---: |
| `2w84y8b8` | Initial dictionary smoke | 4 |
| `vg6phy57` | API/dependency/crash matrix and smoke | 4 |
| `qjhb72if`, `tb6mxy2k`, `g4a0mnmy`, `synrs_bi` | Words: none, 8, 32, 64 KiB | 48 |
| `b5iz2qa9`, `_c2fj5xr`, `7pyfeej4`, `lnegm8zo` | Mixed: none, 8, 32, 64 KiB | 48 |
| `wbqnad6_`, `4ib115tr` | Mixed level 6: none, 32 KiB | 24 |
| `45z54n5l` | Mixed with word-trained 32-KiB dictionary | 12 |
| `0s78oy44`, `6wjjomda` | Five-trial mixed confirmation, latter with codec-only comparison | 30 |
| `0mn156b3` | Official example API/framing comparison | 1 |
| `divksnuz`, `vzg3dkmw` | Actual current sample: 8, 32 KiB; codec comparisons | 24 |
| `1qskcj7w`, `0v02d9bc` | All exact current rows: 8, 32 KiB; codec comparisons | 24 |
| `3z5edhr_` | No-zstd-build zlib regression | 1 |
| `kggyqzsr` | Final-source rerun of complete dictionary contract matrix | 1 |

**Completed: 221 timed complete note/context/search loads**, all exact-value
oracles and cold I/O checks passed, with zero timed WAL reads/sorts. The 13
API/crash/retention/rejection checks also pass in both executions, each with four
additional untimed complete startup oracles after crash recovery/maintenance. Decoder comparisons
are separate from that count. Failed setup/early harness runs are not counted
as successful validation. Raw per-trial JSON and command outputs are retained;
this report and test source are the durable evidence, not temporary file names.

`zsh build.sh` exits successfully with the existing Xcode/Simulator-service
sandbox warnings. No TLA+ model changed or was rerun. The performance-profiling
guidance influenced phase separation, complete ready-to-search measurement,
cold-I/O verification and retaining unfavorable/outlier results.
