# Bounded discovery batches — implementation and qualification

Date: 2026-10-11. Implements the [bounded metadata/hint plan](bounded-discovery-batches-plan.md).
Qualification results below distinguish completed evidence from outstanding gates.

The subsequent [private-connection reuse increment](private-connection-reuse.md)
replaces repeated fixed header/schema queries and per-statement physical checks
with connection-bound context and synchronous-turn/commit checks. The results
below preserve the original batched implementation's measurements; the follow-up
records the new one-query-per-group bound and qualification separately.

## Production mapping

`RepositoryRoot.swift` owns the existing bounded listing stack on RootLane.
`NVRepositoryFiles.c` observes held-directory groups with Darwin
`getattrlistbulk`, or portable no-follow `fstatat`. Root and every retained ancestor
are checked before and after each native turn. The native packed buffer is
2,560 bytes: 64 times the minimum valid 40-byte record, accommodating a maximum
255-byte leaf while bounding the record count. Raw read-ahead is at most 64 leaves;
the Swift discovery turn admits only its remaining candidate budget.

Type-specific packed layouts, returned masks, offsets, lengths, nanoseconds,
per-entry errors and name bytes are checked. Directories omit file-only fields;
missing fields select fresh stat rather than zero defaults. ENOTSUP/ENOSYS/EINVAL
switches once to a freshly opened portable enumeration descriptor. EIO remains a
failure. Enumeration offsets are confined to their selected mode.

Only raw names and cursor progress survive a returned discovery turn. Resumption
refreshes selected names through the held directory, including after native EOF.
The stream closes after EOF and its tail are both consumed, explicit abandonment,
or owner retirement. Public names-only listing behavior stays unchanged.

`RepositoryDiscovery.swift` prepares eligible observations, enters the database
actor once per group, validates the existing header/required state, then performs
one indexed VALUES/join query. All answers start as misses and are filled by
verified input ordinal. Codec, 96-byte payload, exact fingerprint, domain-separated
digest and accepted membership are checked. `RepositoryHintLookup` has a
file-private issuer and binds ordered requests, root permission, store ID and
incarnation; its actual consumer checks applicability after suspension.

Each miss keeps the existing exact read/receive/remember-hint path. Receives,
acceptance, barriers, receipts, live publication and pending-generation clearing
remain per object and unchanged. Store/integrity failures propagate. A hint-write
failure can follow durable retention; the next ordinary pass retries the same
bytes idempotently. No persistent schema, hint codec, public API, sidecar,
long-lived cache, new trigger worker or UI was added.

## Executable evidence

- Local strict debug and optimized: 52 affected root/listing/file/bootstrap/exchange/batch
  test functions passed in each configuration (51 in the main selection plus the
  separate post-lookup-change witness). Both profiles use the existing encrypted
  private database.
- Compiler boundaries: all 72 ordinary-client/same-module probes passed in each
  configuration, including
  batch, metadata-entry and hint-lookup construction/decoding challenges. Runtime
  wrong-root/store/order/incarnation consumers are separate passing tests.
- Native: 32 ASan/UBSan mode/budget cases passed, with strict conversion, alignment
  and memory diagnostics. Independent direct-stat and raw-name inventories cover
  regular, directory, symlink, hardlink, FIFO, Unicode and 255-byte names. The parser
  also runs malformed-record controls and 20,000 bounded fuzz inputs per run.
- Three isolated native guard-removal controls fail at their exact ancestor,
  missing-attribute and I/O-classification assertions, with fresh passing companions.
- Nine isolated Swift production-source mutations fail at designated assertions:
  digest, accepted membership, ordinal, incarnation, ordered request binding,
  raw-tail loss, stale handoff, persisted-hint loss and filename filtering.
- ThreadSanitizer: nine batch/held-owner/cancellation functions passed.
- AddressSanitizer: the nine-function campaign also passed with instrumented
  SQLCipher and its expired-handle negative control. The driver preserves malformed
  UTF-8 diagnostic bytes while inspecting its required ASCII test/control markers.
- Fresh-process debug and optimized: all 12 real-file bootstrap, retention/acceptance/callback,
  materialization/recovery and sync-error schedules passed. Independent inspectors
  check exact envelopes, membership, actions, values/context and pending work;
  recovering processes receive ordinary selection/unlock inputs.
- All 19 private-schema checks passed; schema and hint codec are unchanged.
- App build and epoch-4 compatibility passed with the explicitly qualified Xcode
  deployment-target diagnostic override. The initial unmodified invocation still
  diagnoses Xcode 27's old deployment-target restriction; no compiler safety check
  or supported application target was relaxed.

The new partial-hint-write test fails twice after the first sibling handoff,
independently inspects retained bytes, reopens and retries, then checks exact
membership and current values. Known damage, wrong header, actual query failure,
held lookup owner retirement, changed buffered leaves and mixed 1/2/16/64 budgets
retain distinct outcomes. Existing late-parent, live-edit/Delete, rejected-neighbor,
repackaged/shared-envelope and second-recovery-failure tests remain active.
`repositoryHintHitChangedAfterLookupRemainsDiscoverable` also changes a previously
accepted file while its matching lookup completion is held. The captured old hit
may finish; the next ordinary pass must read exactly one changed body, retain both
exact envelopes and publish the new expected value.

APFS rejects invalid-UTF-8 creation in the native fixture; the Darwin parser tests
preserve injected raw bytes. Legal Unicode names whose decomposed representation
exceeds the existing 255-byte protocol leaf limit retain the explicit bounded-path
failure. Tests use valid NFC/NFD-compatible leaves plus a 255-byte ASCII boundary;
this increment changes no filename policy.

### Platform qualification

| Target | Completed production and native witnesses |
| --- | --- |
| macOS 26 arm64, Swift 6.4 | Debug/optimized affected suites, both sanitizer campaigns, compiler probes, native parser/fallback controls and both fresh-process configurations. |
| macOS 14.8.9 Intel | 17 optimized batch/exchange/failure/lifecycle functions, all 12 fresh-process schedules, 32 native mode/budget cases and three native controls. |
| macOS 11.7.11 Intel | All 12 fresh-process schedules through the production Swift probe, 32 native cases and three controls. Uses the previously documented isolated Swift concurrency runtime and compiler metadata-accessor workaround. |
| Ubuntu arm64, Swift 6.4 | 17 debug and 10 optimized batch/exchange/owner functions; a separate debug post-lookup-change/sparse-result pair; all 12 optimized fresh-process schedules; bidirectional macOS↔Linux bootstrap/edit/Delete/reopen for both profiles; 16 native portable cases and the applicable post-ancestor control. |

The macOS 11 execution evidence preserves the existing distribution caveat:
the tested compiler emits a newer Mach-O deployment requirement for the ordinary
requested target. The isolated runtime/workaround qualifies these executions,
not an unmodified minimum-system release package. No system runtime was replaced.
The Ubuntu native path creates and verifies an actual invalid-UTF-8 leaf; Darwin
bulk claims rely on the three Darwin targets, rather than the portable fallback.
Linux optimized tests/probe pass PIE, W^X, nonexecutable-stack and RELRO checks,
with the RWX negative control rejected. The initial default debug binary lacked
RELRO; the final sparse-result/late-change run relinked with the established
explicit hardening flags and passed the same observer. That failure is preserved
in `ubuntu-elf.log`, with the successful correction in
`ubuntu-debug-hardening-ssh.log`; it was not treated as a passing qualification.

## Models and correspondence

All 15 unchanged `RepositoryDiscoverySafety` runner cases pass. The new focused
`RepositoryMetadataBatchSafety` runner passes nine cases: exhaustive safe
safety/conditional progress over 35,134 states, five designated defect controls,
and three progress witnesses. Its two entries share an EOF stream and have
independent durable handoffs; root/store/file change, two write failures and one
restart may interleave. Across-turn refresh and tail preservation refine the
concrete discovery loop. Recurring ordinary caller opportunities after finite
interference are explicit assumptions. The model supplies neither provider
disclosure fairness nor native/SQL/cryptographic correctness; those are the
executable obligations above. [Model navigation](../../../tla/README.md#metadata-batches-and-partial-handoff).

## Measurements

The original release binary and source copies were frozen before replacement.
The primary comparison preserves four optimized builds and replays identical
physical files and quiesced stores, with independent expected IDs and unchanged
note/context/accepted-membership checks. Three rounds rotate variant order, taking
nine warm samples per round (27 per workload), with no compilation between timed
variants. Instrumentation runs are separate from timed passes.

| 1,024 unchanged files, budget 16 | Public profile | Encrypted profile |
| --- | ---: | ---: |
| Original production path | 252.21 ms | 273.64 ms |
| Batched lookup, old per-leaf rooted observations | 171.37 ms | 170.18 ms |
| Batched metadata, one hint query per leaf | 163.11 ms | 163.24 ms |
| Combined production path | 41.11 ms | 42.42 ms |
| Combined speedup over original | 6.14× | 6.45× |

Combined 1,024-file ranges were 38.57–56.02 ms public and 39.30–55.38 ms encrypted;
original ranges were 234.58–603.69/235.95–866.61 ms. The component variants use
real checked primitives in isolated builds: lookup-only calls the old complete
rooted observation within the bounded native fences; metadata-only retains one
database turn/query per requested hint. They preserve all safety checks rather
than exposing a production bypass switch.

Budget 64 combined medians were 30.67/31.85 ms public/encrypted. At budget 16,
64-file medians were 2.99/3.26 ms and 256-file medians 10.68/10.40 ms. These warm
local measurements meet the plan's fourfold target for both profiles; they are
neither cold-filesystem nor provider-latency guarantees.

The earlier independent nine-sample work-analysis runs measured 554.21→87.26 ms
public and 416.42→47.22 ms encrypted at 1,024 files. Keep those raw planning-to-
production observations, but prefer the same-physical-fixture rotated comparison
above when quoting a speedup.

At 1,024 files the instrumented sweep executes 138 actual hint batches/DB turns
and 1,794 statements (exactly 13 per group), versus 14,336 original statements.
Physical owner checks remain enabled: 1,932, or 14 per group. There are 150
metadata operations, 300 ancestor checks, 81 bulk calls and 484 fresh-stat calls
for buffered tails; maximum observed group/name storage is 13/1,183 bytes.
Provider body reads, historical reads and envelope decodes are zero. Positive SQL
scan counters belong only to the fixed `sqlite_schema` header check; hint lookup
uses primary-key joins, with zero hint-table full scans.

### Actual legacy bulk catalog

The optimized Objective-C comparator runs the real legacy `getattrlistbulk` scan
and retains its two catalog fences. A separate native measurement runs the new
metadata implementation over the same raw names and independently checks inode
inventory. At 1,024 files the encrypted/public profile fixtures measured:

| Work | Encrypted fixture | Public fixture |
| --- | ---: | ---: |
| Complete new discovery sweep | 49.97 ms | 59.04 ms |
| New native metadata sweep | 5.43 ms | 11.50 ms |
| Portable held-directory metadata | 5.89 ms | 10.52 ms |
| Legacy two catalog fences | 3.50 ms | 7.09 ms |
| Previous per-leaf rooted metadata | 120.02 ms | 405.07 ms |

At 10,000 files in one writer, new native metadata took 50.27 ms versus 46.30 ms
for the legacy two fences and 1,133.82 ms for the old per-leaf rooted observations.
The 64-writer, 1,024-file fixture took 18.47/6.27 ms for new metadata/legacy two
fences. Directory count still costs held-stream establishment and validation.
These are warm local medians, not equivalence claims about differently populated
catalogs. Complete discovery also performs exact store/required-state validation,
private owner checks, fingerprint/digest work and asynchronous consumer fences;
the legacy metadata catalog alone performs different work.

### Foreground saves

The opt-in latency witness admits eight ordinary edits while a real 1,024-file
unchanged sweep runs. Its first save completes while the actual lookup completion
is held. After release, the sweep finishes through ordinary opportunities, reads
zero provider bodies and preserves the independently expected 1,024 object IDs
and final two note values.

Encrypted-profile save medians were 44.08 ms without discovery and 42.29 ms during
discovery; public-profile medians were 40.02/52.16 ms. The maximum measured queue
entry delays were 0.44/1.20 ms. The public-profile end-to-end increase includes
concurrent work beyond queue entry; these eight samples do not establish a tail
latency bound. The instrumented unchanged sweep's largest DB turns were
0.32/0.81 ms. Batching retains save opportunities between groups; it does not
promise contention-free end-to-end save latency.

## Reproduction and artifacts

Current source-file selections use declaration names from the checked test
catalogue. They preserve every selected function and its parameter matrix after
the test-target partition. The result counts above remain dated campaign evidence.

```sh
python3 tools/generate-test-index.py --check
NV_BATCH_FILTER=$(python3 -c 'import json,sys; rows=json.load(open("docs/test-index/catalog.json"))["entries"]; names=[r["name"] for r in rows if r["kind"]=="swift" and r["source"].rsplit("/",1)[-1] in sys.argv[1:]]; assert names; print("|".join(names))' RepositoryBatchTests.swift RepositoryExchangeTests.swift RepositoryExchangeFailureTests.swift RepositoryExchangeLifecycleTests.swift RepositoryBootstrapExchangeTests.swift RepositoryRootTests.swift RepositoryListingTests.swift RepositoryFilesTests.swift)
make -C tests run-swift-storage-metadata-batches
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS="--disable-sandbox --jobs 2 --no-parallel --filter \"$NV_BATCH_FILTER\""
python3 tools/test-storage-root-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-repository-exchange.py --binary NVStorage/.build/debug/NVStorageProbe
python3 tools/benchmark-storage-discovery-work.py
python3 tools/benchmark-storage-directory-scan.py
env NV_STORAGE_DISCOVERY_ANALYSIS=/absolute/path/to/results swift test --build-system native --package-path NVStorage --configuration release --disable-sandbox --no-parallel --filter repositoryDiscoveryWorkAnalysisLatency
python3 docs/tla/check-repository-metadata-batches.py --java /absolute/path/to/java --jar /absolute/path/to/tla2tools.jar
```

Replay the four preserved bundles using their original fixture directory:

```sh
python3 tools/benchmark-storage-discovery-variants.py --replay-only /absolute/path/to/nv-discovery-variants-artifacts --replay-rounds 3
```

This requires the `original`, `metadata-only`, `lookup-only` and `combined`
`.xctest` bundles and their quiesced fixtures, plus a compatible macOS/Xcode
runtime. The runner compiles the small C launcher once before timing, rotates
bundle order and retains successful nonzero-discovery, both-profile,
same-fixture, object-count, workload and sample-count checks. Archive existing
replay logs and JSON outputs before repeating a campaign in that directory:
replay writes fresh results to the same output names.

The partial-source `--baseline` and `--rebuild-original` modes were retired on
2026-10-14; see the [resolved audit decision](../../../Testing-and-Documentation-Audit.md#resolved-maintenance-decision).
The recorded timings remain evidence for their frozen implementation. Use the
discovery-work and directory-scan commands above to measure current code.

Primary log directory: `/tmp/nv-discovery-batches.AMB8Gc`.
Frozen source copies and baseline test bundle are there. Original analysis output:
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-discovery-work-k76ygeay`;
combined output: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-discovery-work-c8t7ck5r`.
The baseline driver's ending manifest overlapped source editing; identify that
baseline by its frozen binary/source copies rather than attributing its ending
source hashes to the old build. Raw samples and independent inventories remain
available. Native final controls: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-metadata-batches-2ju62cny`;
Swift mutations: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-runtime-mutations-6k95ywl6`;
focused TLC: `/tmp/nv-metadata-tla-4_9ud8ke`.
Four preserved builds, exact fixture configuration, rotated replay logs and
`replay-results.json`: `/tmp/nv-discovery-variants-1dc06mtx`.
Actual legacy/native comparison: `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-directory-scan-benchmark-g2nidltz`.
Bidirectional macOS/Linux exchange: `/tmp/nv-cross-host-repository-o8t8ye2q`.
Foreground-save raw samples: `latency-public.json` and `latency-encrypted.json` in
the primary log directory. Its test asserts independent final inventory/values
and actual held-completion save progress, rather than a machine-specific deadline.
Linux qualification appends `-Xswiftc -use-ld=lld -Xlinker -z -Xlinker separate-code
-Xlinker -z -Xlinker noexecstack -Xlinker -z -Xlinker relro -Xlinker -z -Xlinker now`
to the Swift commands and checks both test executables and the optimized probe
with `tools/check-storage-elf.py`.

Physical power-loss behavior and coordinated/live-provider disclosure remain
separate, unqualified gates. Process termination, simulated persistence loss and
later corruption retain their distinct classifications.
