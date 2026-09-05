# Private SQLite storage experiment

**Current decision (2026-09-14):** the packed-cache comparisons below are historical benchmark evidence, not a supported storage format. [The final equivalent-load comparison](remaining-storage-validation.md#startup-remove-the-packed-cache) selected direct current rows; [LocalStore](../LocalStore.md) removes the packed representation and its supporting machinery. SQLite transaction, indexing, locality and durability findings remain relevant.

Status: executed exploratory evidence, 2026-09-13. The subsequent
[LocalStore contract](../LocalStore.md) now adopts the private database direction;
the measurements below are still prototype evidence, not a production adapter.

Follow-up: [SQLCipher validation](sqlcipher-validation.md) now tests encrypted
startup, WAL recovery, native rekey and optional key wrapping. It identifies a
reproducible rekey success-reporting failure under injected late I/O errors.

[Connected transaction validation](sqlite-collection-transaction-validation.md)
now maps commit/reopen, parked acceptance and pending import/association to one
private database, including durable ready work and current-row materialization.

## Question and result

Can an embedded database replace a custom private paged catalog/graph index,
and also store exact segment bytes and current-note startup state, without
reading all historical objects on ordinary launch?

**Yes, for the tested access patterns.** A synthetic database grew from 49 MB
to 2.35 GB while cache-plus-tail loading continued to request about 1.21 MB.
Keeping current values in their own table also bounded the read workload by
the current collection rather than its history. Physical file placement was
not controlled. These are SQLite page-access results, not NV launch benchmarks
or a proof of the storage protocol.

The [cold-data/FrozenNotation follow-up](#cold-data-comparison-with-frozennotation)
below tests the actual legacy serializer and note reconstruction. Its results
qualify the initial suggestion that a separate bulk startup snapshot may be
unnecessary.

## Reproduce

```sh
python3 tests/run-sqlite-local-store-probe.py
# Small correctness/crash run:
python3 tests/run-sqlite-local-store-probe.py --sizes 2000 --repeats 1
```

The runner compiles [the C probe](../../../tests/SQLiteLocalStoreProbe.c) with
`clang -std=c11 -O2 -Wall -Wextra -Werror` and system `libsqlite3`.
It uses a fresh temporary directory, never the real collection, and retains
fixtures and JSON results. The default fixture databases total about 2.9 GB.
No additional dependency, production source, normative document or TLA model
was changed. The app and unchanged TLA configurations were not rebuilt.

## Method and limits

- macOS 26.6.2, arm64, system SQLite `3.51.0`, source ID
  `2025-06-12 13:14:41 f0ca7bba1c5e232e5d279fad6338121ab55af0c8c68c84cdfb18ba5114dcaapl`.
- 1,000 current notes with 1,024-byte bodies; one synthetic 4,096-byte object
  per operation; a fixed 32-application suffix beyond the snapshot.
- Ordinary rowid tables hold objects, application order, current rows, private
  bookkeeping and a serialized snapshot. Objects have a unique, random-looking
  32-byte key. A narrow `WITHOUT ROWID` table indexes parent edges.
- The payload, identity generator and last-applied-value reducer are synthetic:
  **not** NV envelopes, SHA-256, encryption, causal reduction or action groups.
  Reading all payload bytes is forced by a checksum; recovered note IDs are
  checked against an independently calculated final state.
- 4 KiB pages, 4 MiB SQLite page cache, mmap disabled. Every measurement uses a
  fresh process/connection. The OS/device cache is **not** flushed.
- A forwarding VFS counts SQLite `xRead` calls and requested bytes, including
  opening/header reads. These are not physical SSD reads. Timings include open,
  setup and the query, but not NV decoding, search-index construction or AppKit.
- Performance fixtures are checkpointed before measurements. WAL crash
  recovery is tested on small fixtures, not a large retained-WAL backlog.
- The parent test follows one 64-step chain. It does not establish complexity
  bounds for arbitrary DAG ancestry, compensation or merge-base queries.

SQLite documents [rowid B-tree lookup](https://sqlite.org/rowidtable.html) and
[clustered composite primary keys](https://sqlite.org/withoutrowid.html).
The latter is appropriate for narrow adjacency rows; it is not automatically
the best choice for large BLOBs. Schema organization controls which logical
pages a query needs, not their ultimate physical placement on an SSD.

## Measurements

Median of three runs. MB/GB are decimal. History counts exclude the 31 newly
inserted tail objects; the 32nd tail application uses an older parked object.

| Initial historical objects | Database size | Snapshot + tail: requested bytes | Snapshot + tail | Current rows only | Full synthetic replay |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 10,000 | 49.48 MB | 1,210,468 | 2.396 ms | 2.291 ms | 61.065 ms |
| 100,000 | 471.92 MB | 1,214,564 | 2.436 ms | 2.334 ms | 1,555.178 ms |
| 500,000 | 2.35 GB | 1,214,564 | 2.815 ms | 2.626 ms | 7,725.723 ms |

Snapshot-plus-tail performed zero SQL full-scan steps. Scanning only the 1,000
current rows requested 1,380,452 bytes at every history size. The full-replay
control requested about 2.09 GB at the largest size. Its time also includes
touching every synthetic payload, so the timing difference is not purely I/O.

At 500,000 objects, 64 exact object lookups requested about 1.20 MB; 64 parent
lookups requested 20,580 bytes. In contrast, enumerating **all object IDs**
requested about 22.95 MB and took 36.522 ms. An indexed catalog makes selective
queries possible; a full catalog scan is still linear in history size.

The main run passed 54 measured queries and 18 crash/error cases. After adding
exact returned-ID assertions to point/parent lookups, the 2,000-object smoke
run passed all six queries and all 18 crash/error cases again.

Raw main results:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-sqlite-local-probe-k8omqeqp/results.json`.
Final smoke results:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-sqlite-local-probe-j62pw9kq/results.json`.

## Correctness boundaries exercised

**Stored is not represented.** Object 7 is stored before the snapshot but
parked. It is applied only after the snapshot, following 31 new objects.
The tail query uses an indexed, transactionally assigned **local application
sequence**, not object insertion order. Recovery must include object 7 and
produce the exact expected final state. Its late application is an artificial
fixture for coverage, not a proposed last-arrival-wins NV reducer.

**Crash ordering.** Each of the following runs in WAL and DELETE journal mode:

| Cut / error | Required recovered outcome |
| --- | --- |
| After inserting object, after updating application/current/marker rows, or before commit | Entire prior transaction |
| After commit, before acknowledgement | Entire new transaction |
| Commit parked object alone | Object retained, not silently applied |
| Commit required state, then crash in a separate cache refresh | New required state, old internally consistent cache; suffix restores the new value |
| During delegated VFS write or sync | Either complete transaction, never mixed bookkeeping |
| Inject `SQLITE_FULL` on a write | Error observed; failed transaction leaves prior state |

The verifier checks the recovered row relationships, exact cache value/coverage,
suffix recovery, foreign keys, integrity and object immutability enforcement.
The private marker is a scalar fixture, **not** the real retained-history pin
or a dependency-closure proof. `integrity_check` is used only on these tiny
crash fixtures; this does not propose a mandatory full-database launch check.

The writer uses `synchronous=EXTRA` and `fullfsync=ON`. SQLite documents that
EXTRA adds a directory-sync guarantee in DELETE mode and is equivalent to FULL
in WAL mode; consult the [synchronous/fullfsync contracts](https://sqlite.org/pragma.html#pragma_synchronous).
The runner kills only the process. It does not simulate power loss, dishonest
storage hardware, every possible write cut, or torn sectors. A first probe
incorrectly expected the injected full-disk error during INSERT; SQLite could
defer that write to COMMIT. The harness was corrected to check both boundaries.
This was a test scheduling error, not an API-contract violation.

## Candidate design, if adopted

1. Keep canonical sealed envelopes as immutable BLOB values, with exact IDs and
   acceptance/dependency status indexed separately. Retain the portable codec,
   validator and reducer. SQLite supplies local transactions, not causal rules.
2. Commit accepted history bytes and necessary acceptance/publication
   bookkeeping together. Previously parked objects may be accepted in a later
   transaction. This removes a separate object-file/catalog installation gap.
3. Give each completed local history-application batch a monotonically
   increasing sequence under the single local owner. Bind current materialization to its store
   incarnation, schema/reducer version and exact represented application prefix.
   A later batch incorporating an old object is still in the suffix. This is
   **not** a portable writer sequence, causal frontier or cloud-completeness
   claim; exact object membership and causal frontiers remain indexed data.
4. Maintain current values and compact authoring frontiers separately from old
   revisions. Read those current tables directly after indexed
   acceptance catch-up; no second packed snapshot is required. Historical queries use indexed lookups as needed.
5. Keep materialization failure independent of successful note durability:
   commit required history even if a later materialization update fails. Binding
   current values and their represented prefix in one transaction prevents torn pairs;
   it does not prove the reducer computed the right values.
6. Export the exact canonical envelopes to the existing immutable `NV Data`
   layout. Never synchronize the private database, its WAL or its shared-memory
   file. SQL table layout does not become the provider protocol.

This can eliminate a hand-built private paging engine and recurring local
directory-difference scans. It cannot eliminate provider discovery, closure
validation, causal frontier maintenance, root fencing, file-replacement
validation or the need to load all **current** note bodies into memory before
NV's synchronous search/editing starts.

## Gates before changing the proposal

- **Encryption:** encrypting only segment BLOBs leaves current rows and indexes
  exposed. The [existing protection contract](../Encryption.md#local-secret-and-plaintext-handling)
  covers sensitive private state too. SQLCipher is a candidate: its documented
  design encrypts database and WAL/journal data pages, but nonencrypted
  file-backed temporary storage must be avoided. It requires a separate SQLite
  build. [SQLCipher design](https://www.zetetic.net/sqlcipher/design/).
  The original experiment did not benchmark it; see the subsequent
  [SQLCipher qualification](sqlcipher-validation.md), including its open rekey gate.
- **Recovery scope:** corruption of a shared database can affect more than one
  independently stored segment. Specify exact repair/export/backup behavior
  for unreadable indexes/pages and unpublished objects. Do not discard the
  entire DB merely because it contains derived caches. Settings and accepted
  history are not expendable. Decide which minimal association/loss evidence
  should survive independently of the database.
- **No hidden startup scan:** transactions establish construction consistency,
  not absence of later corruption in unread historical pages. Define and test
  the fast verification boundary explicitly; retain on-read/background damage
  checks and required-history repair. Neither filenames nor SQL metadata prove
  unread bytes remain intact. SQLCipher page authentication is also on access.
- **Durability and latency:** qualify the chosen SQLite/VFS build on supported
  platforms, realistic note sizes, single-action save frequency, large WAL
  recovery and concurrent history readers. Long-lived readers can obstruct
  checkpoints. SQLite's [WAL documentation](https://sqlite.org/wal.html) explains
  these constraints and a recently fixed upstream WAL-reset race; Apple's fork
  must be qualified by its build, not assumed patched/unpatched from its version
  string alone. These single-owner probes do not exercise that race.
- **Spec/model alignment:** [Protocol's private current-state contract](../Protocol.md#snapshots-startup-rejoin-and-retention),
  [Implementation](../Implementation.md), [ADR 0004](../../adr/0004-make-local-history-durable-before-external-effects.md)
  and [ADR 0005](../../adr/0005-separate-startup-cache-private-state-and-visible-history.md)
  currently describe separate file barriers. Adopting transactional BLOB storage
  requires an explicit local-adapter refinement and corresponding crash tests;
  the [existing TLA results](../../tla/README.md) do not automatically prove it.
  Logical history/materialization/private-state separation can remain even if the three
  share a database container.

Recommendation: investigate SQLite as the primary **private** store before
implementing a custom paged index. Do not choose table-only startup from the
warm synthetic result alone: the cold-data comparison below shows a measurable
bulk-read advantage and substantial sensitivity to SQLite page size.

## Cold-data comparison with FrozenNotation

Follow-up, 2026-09-13. This remains an experiment, not an adopted cache format.

### Executed comparison

[StartupStorageComparison.m](../../../tests/StartupStorageComparison.m) links
the actual current `FrozenNotation`, `NoteObject`, `NotationPrefs` and compression
implementation objects. It invokes the real nested keyed-archive/compression
path for creation and the real unpacking path for recovery. It does not substitute
plain dictionaries for `NoteObject`s. This is the project's current legacy
checkpoint implementation, not a benchmark of an old released executable.

```sh
python3 tests/run-startup-storage-comparison.py
# Sensitivity runs, after refreshing app objects:
python3 tests/run-startup-storage-comparison.py --skip-build \
  --notes 10000 --page-size 16384 --repeats 3
python3 tests/run-startup-storage-comparison.py --skip-build \
  --notes 1000 10000 --body-chars 1024 --repeats 3
```

`build.sh` completed before linking the probes; Xcode emitted sandbox-related
simulator-service warnings, not app build errors. No app source, production
storage behavior or TLA model changed. The executable has a separate test bundle
identity and never opens a real collection, window, controller or keychain.

The main fixture has 1,000 or 10,000 notes, approximately 4,096 UTF-16 code units
per body, deterministic shuffled words/numbers, accented text, Japanese, Greek
and emoji, distinct titles, labels, UUIDs and dates. The common encoded values
occupy 4.41 MB / 44.12 MB. The database also contains 100,000 unrelated synthetic
4 KiB historical objects which must not be loaded with current values. Encryption
and nontrivial rich-text attributes are not exercised.

Six readers recover the same common fields and construct real `NoteObject`s,
including their existing lowercase search caches:

| Reader | Purpose |
| --- | --- |
| `frozen-file` | Real compressed FrozenNotation checkpoint as a file |
| `frozen` | **Exactly the same archive bytes** in one SQLite BLOB; isolates container overhead |
| `flat-file` | Simple benchmark-only length-prefixed current values in a file |
| `flat` | Same flat bytes in one SQLite BLOB |
| `compressed` | Flat bytes compressed using NV's existing zlib wrapper, in SQLite |
| `rows` | One flat current-value record per indexed SQLite row |

The flat codec covers UUID, creation/modification dates, title, labels and plain
body. It is deliberately not `StartupCacheV1`: no full causal/action index,
authoring-frontier verification, authentication or local tail is implemented in
this follow-up. The earlier suffix probe tests a separate synthetic boundary;
these results must not be combined into a claim of complete startup correctness.
The constructor also generates a temporary UUID/date before the test restores
the saved ones; it is not an optimized future Swift-to-NV adapter.

### Establishing cold file data

`F_NOCACHE` alone **did not establish cold reads on the already-cached SQLite
fixture**: setting it succeeded, yet a probe still reported zero kernel disk-read
bytes. This is not evidence of an API violation; disabling caching is not a
promise to evict all preexisting cached pages. Apple describes
[the flag](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fcntl.2.html)
and recommends aligned buffers for
[uncached reads](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/FileSystem/Articles/FilePerformance.html).

The successful preparation is specific to each synthetic file:

1. Map the closed, clean fixture read-only, without faulting its contents in.
2. Call `msync(MS_SYNC | MS_INVALIDATE)`; Apple documents
   [cached-data invalidation](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/msync.2.html).
3. Require `mincore` to report **zero resident pages**, then unmap and close.
4. Run the reader in a fresh process and require kernel-accounted read bytes
   to be at least the recovered encoded payload size.

Invalidation and whole-file residency enumeration are benchmark preparation,
**not** proposed production startup steps, and are outside the timing interval.

Three conditions are interleaved in seeded random order:

- **Warm:** immediately precede the measurement with the same reader.
- **Cold:** invalidate first, then use normal cached I/O/read-ahead. This is the
  more relevant approximation of launching with cold collection data.
- **NOCACHE:** invalidate first, then continue bypassing caching, using aligned
  bounce buffers for SQLite requests. This is a separate I/O-policy experiment,
  not synonymous with a normal cold launch.

SQLite mmap is disabled and each connection has a fresh 4 MiB pager cache. The
test-only VFS uses a separate read-only descriptor for fixture bytes; it does
not inspect private SQLite struct layouts. No fixture has concurrent writers
or a live WAL. The VFS is not a proposed writable production adapter.

All 120 cold/bypass reads in the main run met the full-payload kernel-I/O
threshold, and all 60 warm reads reported zero kernel disk-read bytes. The
initial runner gate was 80%; a separate check of all recorded results established
the stricter full-payload threshold, now enforced by the runner. The follow-up
runs use that stricter gate directly. No disk image or global cache purge was
needed. This does **not** flush filesystem metadata, executable/framework pages,
or SSD-controller caches, and is not a cold-boot/device-power-cycle benchmark.
A freshly mounted disk image alone would not demonstrate that its backing
file's cache was cold.

### Main results: cold data, normal I/O

Median of five measurements, milliseconds, 4 KiB SQLite pages. Load includes
opening/querying and retaining the encoded data; decode includes decompression
when applicable and real note-object/search-cache reconstruction. The shared
Foundation/AppKit machinery is warmed with one unrelated synthetic note before
timing. Field verification and teardown occur afterward. This is **not** total
application launch, controller attachment, list sorting or editor display time.

| Representation | 1,000 notes: load | Decode | Total | 10,000 notes: load | Decode | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| FrozenNotation file | 0.9 | 51.0 | 52.0 | 4.8 | 518.4 | 523.0 |
| Identical FrozenNotation BLOB | 2.7 | 51.1 | 53.8 | 8.3 | 518.1 | 526.0 |
| Flat file | 2.3 | 52.3 | 54.6 | 15.0 | 523.7 | 538.8 |
| Flat BLOB | 4.6 | 52.4 | 56.9 | 23.9 | 524.6 | 548.7 |
| Compressed flat BLOB | 2.3 | 55.6 | 57.8 | 8.0 | 556.4 | 564.1 |
| Individual current rows | 13.0 | 52.4 | 65.5 | 110.2 | 524.2 | 634.6 |

Column medians are calculated independently. The 10,000-note FrozenNotation
archive is 12.20 MB; flat values are 44.12 MB, and compressed flat values are
9.33 MB. The smaller compressed flat form saves I/O but adds decompression
work; it did not win total elapsed time on this fixture.

**Keeping `F_NOCACHE` enabled markedly changes the comparison.** At 10,000 notes
the flat SQLite BLOB's loading phase was 246.0 ms with bypass versus 23.9 ms
from cold data with normal I/O. The FrozenNotation file was 6.5 versus 4.8 ms.
SQLite issued 10,787 read requests for the flat BLOB versus 12 bulk reads for
the compressed archive file. These are different request shapes, and bypass
removes important caching/read-ahead benefits. The bypass figures should not
be presented as expected normal launch times.

### Page-size sensitivity

With identical 10,000-note data and three repetitions, changing SQLite pages
to 16 KiB reduced the individual-row cold loading phase from **110.2 to 28.8 ms**.
Their total became **553.4 ms** rather than 634.6 ms. The flat BLOB loaded in
22.7 ms and the identical FrozenNotation BLOB in 8.2 ms.

Larger pages are not a free improvement: this particular fixture database grew
from 572.75 MB to 666.91 MB, and row loading's kernel-accounted read bytes grew
from 46.14 MB to 54.69 MB. Fewer requests and less overflow-related access can
matter more than minimum byte count. No physical SSD placement was controlled.
This single sensitivity run is not enough to select a production page size.

### Shorter-note sensitivity

With bodies targeting 1,024 rather than 4,096 UTF-16 code units, 4 KiB SQLite
pages and three repetitions, the flat decoder does win overall. The cold-data
totals were:

| Representation | 1,000 shorter notes | 10,000 shorter notes |
| --- | ---: | ---: |
| FrozenNotation file | 19.1 ms | 194.0 ms |
| Identical FrozenNotation BLOB | 20.2 ms | 196.2 ms |
| Flat BLOB | 17.4 ms | 161.4 ms |
| Compressed flat BLOB | 17.3 ms | 165.8 ms |
| Individual current rows | 18.0 ms | 166.3 ms |

This reinforces the need to measure realistic note-size distributions instead
of declaring either representation universally faster. The 10,000 shorter-note
run contains 11.64 MB of common flat values and a 4.20 MB FrozenNotation archive.
Its 108 measured loads passed byte-for-byte common-field comparisons and the
strict cold/bypass I/O gates.

### Interpretation and boundaries

- SQLite remains promising for atomic private storage and indexed history,
  **not because these results show faster legacy startup**. The exact-archive
  control shows only about 3 ms total overhead at 10,000 notes.
- Bulk startup data can materially outperform separately stored rows on cold
  reads. Page size reduces that difference. Keep both options open until the
  actual protected format and production adapter are measured.
- Reconstructing current notes dominates elapsed time here. Replacing
  `NSKeyedUnarchiver` with this unoptimized flat decoder does not automatically
  improve it. Neither path may skip required in-memory search state to win a
  benchmark.
- The main run passed 180 measured loads with identical common-field checksums.
  The final probe additionally compares the reconstructed common-field bytes
  byte-for-byte against the fixture outside the timed interval; the 54-measurement
  16 KiB run includes this stronger check.
- No history replay in this comparison, lack of encryption, simple attributes and intentionally
  favorable bulk allocation mean this is a feasibility comparison, not the
  final fast-start performance gate. It does not prove semantic cache validity,
  authenticated history inclusion, crash recovery or provider completeness.

Main results:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-startup-comparison-ro22alsl/results.json`.
16 KiB results:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-startup-comparison-snmhfq4d/results.json`.
Shorter-note results:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-startup-comparison-givlm95l/results.json`.

Together these runs contain **342 measured loads**, plus preparation reads and
a separate 18-measurement smoke run. Latencies are observations, not CI timing
thresholds; wrong recovered contents or failure to establish cold I/O are hard
test failures.
