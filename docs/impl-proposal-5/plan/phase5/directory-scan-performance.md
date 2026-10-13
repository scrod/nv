# Directory-scan performance baseline

This compares the existing application's optimized catalog with P5.3's new
repository scanner. It is a performance finding, rather than a change to storage
policy or permission checks.

## Implementations and measurement

The current Objective-C implementation is `-[NVRootedDirectory newCatalog:]`
in [NVRootedDirectory.m](../../../../NVRootedDirectory.m). It calls
`getattrlistbulk` with a 64-KiB buffer and constructs compact catalog arrays.
The upstream source at `origin/master` used `FSGetCatalogInfoBulk`; the
comparison here invokes the actual current Objective-C implementation, rather
than a Foundation substitute or a reimplementation of its algorithm.

[DirectoryScanBenchmark.m](../../../../tests/DirectoryScanBenchmark.m) compiles
that source, its ordinary helpers and the production rooted C implementation
with Clang `-O2` and the application's prefix header. A subclass makes the
Foundation fallback an explicit failure, ensuring the measurement actually
exercises the bulk path. Independent name/file-ID inventories must agree before
timing. It measures:

- One production bulk catalog, including its allocations and filename decoding.
- Two production catalogs plus `isExactlyEqualToCatalog:`, including sorting and
  comparison: the catalog portion of the existing application's consistency fence.
- Production native name listing with budgets of 16 and 256 entries.
- Production native listing plus exact rooted observations for every file.
- Actual Swift `discover` and contextual result validation against accepted local
  history, using the normal 16-step turn budget.

The first four comparisons inspect identical writer directories and files.
Discovery also traverses the protocol's parent directories and an empty keys
directory. The real-history fixtures contain two current notes and 64, 256 or
1,024 saved-edit envelopes in one writer directory. They intentionally isolate
historical segment scanning from descriptor reads and initial bootstrap delivery.
Both provider profiles still use encrypted SQLCipher private pages.

Each algorithm receives a warmup followed by nine measured passes. Native
algorithm order rotates between rounds. Swift uses the optimized production
build; work instrumentation and the provider-read hook run in a separate,
excluded verification pass. Every measured file must return
`unchangedAccepted`; the verification pass must read zero provider bodies and
zero historical database records, and decode zero envelopes. Timing therefore
measures the best-case unchanged sweep rather than downloading, acceptance or
historical replay. The scanner's root/session remains unchanged during a sample
set; this does not qualify hint reuse across reopening.

The driver writes structured per-case result files independently of SwiftPM's
interleavable terminal output. It requires both profiles, all three sizes,
nonzero passing test discovery, complete sample counts and the independent
observations. It preserves its temporary collections and all raw samples.

## Findings

Final complete optimized run on Apple M1, 16 GiB RAM, macOS 26.6.2, APFS,
Swift 6.4; medians in milliseconds:

| Profile / files | Bulk catalog | Two-catalog fence | Native listing + observations | Complete unchanged discovery |
|---|---:|---:|---:|---:|
| Public / 64 | 0.070 | 0.170 | 6.731 | 17.873 |
| Public / 256 | 0.190 | 0.528 | 24.162 | 70.171 |
| Public / 1,024 | 0.924 | 2.272 | 99.066 | 294.719 |
| Encrypted / 64 | 0.075 | 0.165 | 6.815 | 17.869 |
| Encrypted / 256 | 0.194 | 0.529 | 24.536 | 73.408 |
| Encrypted / 1,024 | 0.792 | 2.301 | 99.212 | 289.092 |

At 1,024 files, native names alone took about 3.3 ms with budget 16 or 0.73 ms
with budget 256. Thus small-turn name listing adds some overhead, but the much
larger cost appears when the new implementation separately observes each file.
The full path then adds Swift boundary crossings, hint hashing and database work.
The independent SQL work pass counted exactly 14 statements per historical file:
896, 3,584 and 14,336 statements. These include repeated header/schema/private-state
validation and accepted-membership lookup; they perform considerably more work
than a name/metadata catalog. The difference between the C and complete Swift
measurements is not attributed exclusively to SQL.

Additional enumeration-only fixtures isolate larger counts and directory fan-out.
Their bodies are synthetic and carry no history-validation claim:

| Files / writer directories | Bulk catalog | Two-catalog fence | Native listing + observations |
|---|---:|---:|---:|
| 1,024 / 64 | 1.828 | 3.514 | 104.585 |
| 10,000 / 1 | 9.925 | 29.612 | 968.034 |

The old and new scanners have different responsibilities; the complete sweep is
not equivalent to the old application's entire reconciliation transaction.
Nevertheless, the metadata-only comparison already demonstrates a substantial
regression. At 1,024 files the complete new sweep costs approximately 126–130
times the old two-catalog fence, even after accepted-file hints avoid body reads.
Successful correctness tests do not make that latency acceptable by themselves.

This distinction matters as history grows: the legacy catalog normally scans
current projection files, whereas the transport directory accumulates historical
objects even with a fixed number of current notes. Bounded turns limit each
piece of work; they do not eliminate the cost of repeatedly completing that
growing sweep. Callback-only discovery or a provider sequence high-water mark
would sacrifice existing late-disclosure guarantees and is not a substitute for
reducing the per-file cost.

Healthy startup from private current-note rows is a separate path. These numbers
must not be described as added launch latency, nor should a complete transport
sweep become a prerequisite for publishing those healthy rows. Fresh bootstrap,
first-pass body reads, provider placeholders, cold filesystem caches and remote
provider behavior are separate measurements. The Intel Mac Mini could not be
reached for this comparison (`scrodmini.local` did not resolve).

## Low-state follow-up

The subsequent [caller and repeated-work analysis](discovery-work-analysis.md)
traces both modern and legacy discovery callers, counts repeated ownership/SQL
work and measures bounded metadata/SQL prototypes against exact observations.
It supports the two changes below without changing production behavior. The
report also separates trigger coalescing from the required later opportunities
to discover late or unannounced provider input.

The [bounded discovery batch plan](bounded-discovery-batches-plan.md) now specifies
the implementation order, race/failure checks and paired production benchmarks
for these two changes. Its completion gates preserve this baseline comparison.

Two complementary changes merit investigation before host/provider integration:

1. Observe a bounded group through the already-owned writer-directory stream.
   On macOS, investigate reusing the existing bulk-metadata approach; elsewhere,
   batch descriptor-relative observations through the held directory. This can
   avoid reopening and checking every ancestor separately for every leaf.
   Preserve exact required observation fields, no-follow behavior and root/parent
   applicability before and after each bounded turn. Actual body reads and
   installations retain their existing exact-file checks.
2. Query accepted-file hints as a bounded group in one serialized database turn.
   Validate owner/header/required state for that turn, then check every selected
   fingerprint and exact accepted identity. Keep the generation/session checks
   surrounding asynchronous handoff. This amortizes repeated schema/context
   queries and executor crossings without adding a persistent cache or another
   semantic table.

The trade-off is a modest batch-reading adapter and additional batch-level race
tests. Preserve changed-file detection, late/lower-numbered discovery, renamed
duplicates, root replacement, cancellation, storage failures and intervening
acceptance. A bulk catalog provides observations; it never grants completeness,
deletion, cleanup or publication authority. A larger name-list budget alone
does not address the dominant per-file costs.

Rerun the same-file comparisons after each change, keeping raw enumeration,
metadata, SQL counts and complete-sweep time separate. Retain both unchanged-file
companions and changed-file/failure tests; reduce repeated work by sharing checks
within a bounded owned turn, rather than deleting the checks.

## Reproduction

From the repository root, with the documented storage dependencies built:

```sh
python3 tools/benchmark-storage-directory-scan.py
```

The benchmark is opt-in; the driver supplies the native executable, result
directory and repetition count. Its Swift test is skipped during ordinary suites.
An explicit benchmark run only qualifies after all six result files and the
passing discovery summary are verified. This diagnostic records timings rather
than asserting a hardware-independent millisecond ceiling.

Final qualification passed both profile cases and every size, including the
actual provider-read hook in the excluded verification passes. Swift tests took
193.101 seconds including fixture construction; that suite duration is separate
from the per-sweep timings. The earlier complete run reproduced the same
performance finding (approximately 289–293 ms at 1,024 files).

Final log: `/tmp/nv-p53-directory-scan-benchmark-final.log`.
Raw samples, compiler/source hashes, fixture directories and the passing Swift
log are preserved under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-directory-scan-benchmark-j_txvxl8/`.
The earlier complete run remains under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-directory-scan-benchmark-g3kl7t2o/`.
