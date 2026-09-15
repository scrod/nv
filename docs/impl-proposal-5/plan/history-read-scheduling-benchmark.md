# Rough history-read scheduling benchmark

Date: 2026-09-16. Investigation only; production scheduling is unchanged.

## Question and result

Does yielding after every historical lookup add enough overhead to investigate
small batches? **Yes, modestly:** complete validation took about **15–23% longer**
than the same validator with uninterrupted database access. At 1,024 prior edits,
the difference was **46–54 ms**. A lookup-trace experiment suggests that groups of
16 could recover most of the read-side overhead while usually keeping each turn
near one millisecond on this machine.

This supports a small follow-up experiment, rather than a storage redesign.
Ordinary saves that qualify for current-state validation avoid this traversal.

## Method

- Apple M1, macOS 26.6.2, Swift 6.4, optimized build, existing pinned SQLCipher.
- Both provider profiles; private database pages are encrypted in both cases.
- Two real stores with identical bootstrap; actual Put captures, sealed objects,
  acceptance and materialization build a linear history before timing.
- Two current notes; one accumulates 64, 256 or 1,024 edits with roughly 1 KiB
  synthetic bodies. The other note stays unchanged.
- A new, unaccepted edit is checked using the complete existing validator. One
  mode performs all reads directly in one database turn; the other uses the
  production `historyWork`/`historyRead` readers, including owner, damage and
  accepted-prefix checks. Timings include opening/decoding the candidate and
  checking its complete historical context, but exclude construction, acceptance,
  materialization and durable writes.
- Warm caches, one warm-up and three measured repetitions per mode; order
  alternates. Counters are disabled during timing. Profiles and sizes run serially.
- A separate untimed validation records its exact lookup sequence. Replaying
  that sequence in groups of 1, 16, 64 or 256 keeps the real indexed reads,
  envelope verification and decoding. Each group uses the production fenced
  `historyRead`. Checksums and lookup counts ensure matching work.
- Assertions confirm that measurements preserve the receiving store's current
  notes and accepted sequence; subsequent normal receipt accepts the candidate
  and produces the independently expected body. The opt-in test passed.

## Complete validation

Median milliseconds across three measured runs:

| Provider objects | Prior edits | Logical lookups | Uninterrupted | Current scheduled reads | Added time |
| --- | ---: | ---: | ---: | ---: | ---: |
| Public-hash | 64 | 341 | 15.73 | 18.75 | 19% |
| Public-hash | 256 | 1,301 | 58.92 | 72.36 | 23% |
| Public-hash | 1,024 | 5,141 | 257.69 | 311.42 | 21% |
| Encrypted | 64 | 341 | 19.94 | 23.51 | 18% |
| Encrypted | 256 | 1,301 | 73.24 | 86.58 | 18% |
| Encrypted | 1,024 | 5,141 | 318.55 | 364.80 | 15% |

The difference includes repeated ownership/prefix checks as well as queue
coordination. It is not a measurement of pure thread-switch cost. A logical
lookup may perform several SQL queries and reread an envelope; 1,024 prior edits
produced 5,141 reader calls in this validator.

## Batching estimate

Replay of the 5,141 recorded lookups at 1,024 prior edits. These are **read-trace
times**, not complete batched-validator times:

| Lookups per turn | Public-hash total, ms | Encrypted total, ms | Typical turn p95, ms, public / encrypted |
| ---: | ---: | ---: | ---: |
| 1 | 306.56 | 391.58 | 0.066 / 0.083 |
| 16 | 257.52 | 315.10 | 0.86 / 1.09 |
| 64 | 255.51 | 303.90 | 3.35 / 3.95 |
| 256 | 246.67 | 307.65 | 12.61 / 15.96 |

Totals and p95 columns are medians across runs. Turn measurements include the
queue wait plus the fenced read work, so they are only a rough contention proxy.
Groups of 16 reduced median replay time by **16% / 20%**; much larger groups
provided relatively little additional benefit while holding database access
longer. One encrypted 16-lookup run had a 17.25 ms maximum turn, despite its
1.54 ms p95. These observations are not worst-case latency guarantees.

## Interpretation and limits

The batching replay knows its future requests in advance. The actual validator
discovers them incrementally, so this experiment does not implement or validate
resumable batched traversal. Interspersed graph computation, concurrent writes,
stale-prefix retries and real save-acknowledgment latency require the next test.
No safety check or production path was changed to obtain these results.

This is a warm-cache, small-body, linear-history measurement on one machine.
It says little about cold storage, large bodies, branching, contention or slower
hardware. Three repetitions establish an approximate scale rather than a
release performance budget. The skills' measurement-first guidance informed the
separation of whole validation from read-only replay and the alternating warm
measurements; no optimization was adopted from those results alone.

## Reproduce

```sh
NV_HISTORY_READ_BENCHMARK=1 make -C tests run-swift-storage \
  SWIFT_STORAGE_TEST_FLAGS='-c release --filter historyReadSchedulingBenchmark'
```

Source: `NVStorage/Tests/NVStorageRuntimeTests/HistoryReadBenchmark.swift`.
The benchmark is opt-in so normal correctness runs remain unchanged. Original
output: `/tmp/nv-history-read-benchmark.log`. One SwiftPM warning interleaved
with a stdout line; the encrypted 256-edit scheduled run 3 was 86.580 ms.
