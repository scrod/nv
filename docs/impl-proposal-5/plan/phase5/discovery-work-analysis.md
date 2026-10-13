# Discovery caller and repeated-work analysis

Date: 2026-10-11. This is a measured implementation review and a recommended
follow-up, rather than an implemented optimization or a change to storage policy.
The production discovery, rooted I/O and database paths are unchanged by this
analysis. The added diagnostics are opt-in.

## Conclusion

The dominant unchanged-file costs are repeated work at two boundaries:

1. Every leaf observation reopens and rechecks the same protocol-directory
   ancestry, although the active listing already holds that ancestry.
2. Every accepted-file hint gets its own database turn and repeats twelve
   header/schema/private-state queries before its two actual lookup queries.

The simplest useful change is a bounded metadata batch followed by a bounded
accepted-hint lookup. Reuse the existing listing descriptors, database owner,
hint records and accepted membership. Keep changed-file reads and acceptance on
their existing checked paths. This needs small batch adapters and focused race
qualification, rather than another persistent cache or a collection-wide graph.

The [bounded discovery batch plan](bounded-discovery-batches-plan.md) specifies
the implementation, immutable batch boundaries, partial-failure tests and
integrated qualification. The measurements below remain prototype/baseline
evidence until that production work passes its gates.

Caller scheduling also matters: a completed discovery pass must stop its own
continuations, and multiple triggers should share one active pass. Later ordinary
opportunities must remain available even if callbacks were missed or a previous
pass saw nothing. The application adapter is not wired yet, so its actual scan
frequency is not currently measurable.

## Caller inventory

### Modern immutable repository

The actual path is:

```text
RepositoryRootSession.discover(into: store / bootstrap candidate)
  protocol-scoped parent/child listing
  inspect each candidate -> observe -> RootLane -> nv_root_snapshot
  rooted fingerprint -> LocalStoreSession.knownDiscoveryHint -> database lane
    unchanged accepted identity: return an observation
    otherwise: exact file read -> descriptor decoding or Runtime receive
```

`RepositoryDiscovery.swift` supplies the two public entry points and their
qualification hook. Current callers are exchange/failure/lifecycle tests, the
opt-in benchmarks, and `RepositoryExchangeProbe.swift`'s headless client. There
is no application caller of this API yet. `noteRepositoryChange` likewise has
test callers today; P5.4 will connect the presenter/OS adapter.

Healthy `LocalStoreSession.open`, ordinary persist, snapshot creation and scoped
Undo/conflict queries do not invoke repository discovery. Their private-database
work must remain separate from a transport sweep. In particular, a full provider
listing is not an added healthy-launch gate.

`captureRepositoryPublication` selects accepted database objects, rather than
scanning the filesystem. It already provides `RepositoryPublicationBatch.nextPass`
to continue from a completed acceptance prefix. Routine publication should carry
that cursor forward; the test helper's deliberately complete republication is not
a requirement to republish all history after every save. Explicit full repair and
copy remain different operations.

### Existing application reconciliation and other directory consumers

| Consumer | When it runs | Finding |
|---|---|---|
| `NotationDirectoryManager.synchronizeNotesFromDirectory` | Startup, foreground, file-event/retry requests, explicit file opening, format transitions, restoration and save-error recovery; also a legacy sync-session caller | Plaintext mode performs a first catalog, detached preparation and a second exact catalog fence. Single-database mode returns before enumeration. Both catalogs are intentional correctness work. |
| `_requestDirectoryScan` / `_performScheduledDirectoryScan` | File-event and retry scheduling | Already coalesces these requests. A direct successful scan clears the queued flag, making an already queued wrapper a no-op. Other direct or `performSelector` callers can still request an extra transaction. |
| `uniqueFilenameForTitle:fromNote:` -> `caseInsensitiveRegularFileExistsNamed:excludingName:` | Initial filenames, rename and conflict-copy filename selection | Each eligible collision attempt builds a complete bulk catalog. Reusing one operation-local occupancy inventory could reduce repeated scans, while exclusive installation and collision retry remain authoritative. This cost is source-observed, not separately timed here. |
| `StartupRecovery._legacyTemporaryDatabaseDataReturningName` | Exceptional epoch-4 temporary-database recovery | Builds one bulk catalog, then observes each regular file before testing whether its name can be a legacy temporary database. Filtering names first could avoid unrelated per-file metadata work. Qualify legacy error behavior before changing it. |
| `RepositoryCopy.preserveAvailable`, active-store saved-work copy and export | Explicit preservation, recovery/copy/export | Enumerates for the requested copy, outside routine discovery. The copier reads source bytes for their digest, reads them again to copy, then verifies destination bytes. A fused copy/digest could reduce source reads, but independent destination verification and source stability remain necessary. Lower priority than routine discovery. |
| `AlienNoteImporter.notesInDirectory:` | Explicit folder import | Separate import workflow with per-item attributes/content reads. |
| `TemporaryFileCachePreparer` and `URLGetter` directory use | External-editing cache maintenance and temporary-download housekeeping | Separate temporary-file workflows, rather than immutable-history discovery or healthy startup. |

The reconciliation caller sites are `NotationController.m:706,721,968`,
`AppController.m:1154`, `NotationPrefs.m:522`, `DeletionManager.m:272`,
`SyncSessionController.m:213` and the save/conflict recovery sites in
`NoteObject.m:1233,1398,1414,1422`. The coalescer is in
`NotationDirectoryManager.m:232`; the transaction starts at line 457. These line
numbers describe the reviewed source and may move with subsequent edits.

Routing asynchronous requests through one coalescer is worth considering when
adapting those callers. Calls requiring an immediately fresh result keep that
requirement. This analysis changes neither the application UI nor its synchronous
input/search behavior.

## Scan frequency and continuation

Useful existing properties in `RepositoryDiscovery.swift`:

- Parent/child cursors survive a successful bounded turn. Inspecting a writer
  does not restart the parent listing or assemble an unbounded name array.
- An invalidation increments the existing counter without repeatedly restarting
  an in-progress pass.
- At most one discovery call is active; another call receives `busy`.
- Test/probe loops stop when `passEnded` is true.

Remaining integration concerns:

- `opportunity` currently labels the caller's reason but does not change the
  algorithm. Any call after `passEnded` starts a fresh pass, including a
  `backgroundTurn`. An unconditional continuation loop would therefore rescan
  forever; the library does not currently start such a loop itself.
- A `busy` guard is not a trigger coalescer. The adapter should reserve one
  session-owned worker, merge incoming requests and let the current pass finish.
  Use the existing captured/latest invalidation values to retain follow-up work.
- A fatal handoff error clears the whole traversal state. Retrying a failure
  near the end of a large pass repeats the prefix's metadata and hint checks.
  Ordinary per-entry unavailability is already handled separately. Cursor and
  unconsumed-leaf preservation might help transient failures, but must be scoped
  to an applicable root/store/session; address the larger batch costs first.
- Missed callbacks, early empty listings, new writer directories and late lower
  sequence numbers require later independent opportunities. A callback-only
  scanner, filename high-water mark or permanent completed-pass flag would lose
  supported work. The exact idle scheduling cadence remains adapter work, not
  an excuse to run back-to-back completed passes.

Known paths and disclosed prerequisites can prioritize checks. Periodic ordinary
namespace revisits still provide the fallback for unannounced or renamed input.
The specification and `RepositoryDiscoverySafety` model place that recurring
opportunity obligation on the caller; they do not prescribe a busy polling loop.

## Per-item work in the unchanged accepted case

### Native observation

For `NV Data/v1/segments/<writer>/<leaf>`, `nv_root_snapshot` duplicates the root
descriptor, opens four ancestor directories, observes the leaf, rechecks every
ancestor and closes the descriptors. On its ordinary successful Darwin path,
source inspection gives four `openat`, nine `fstatat`, ten `fstat`, one descriptor
duplication, two root-event polls and five closes per leaf, excluding surrounding
listing work. This is a source-derived count, not a syscall-tracer measurement.

The listing already owns the relevant ancestors. Checking them around a bounded
batch and reading leaf metadata relative to the held writer directory avoids
reconstructing that same path for every leaf.

### Database hint lookup

At 1,024 unchanged accepted files the production work counter recorded exactly
14,336 statements and 1,024 database turns, with zero historical record reads or
envelope decodes. Each file accounts for:

- Twelve header/schema/required-private-state queries, including settings and
  association decoding.
- One hint-row query and one exact accepted-membership query.

Each `Database.each` also validates physical ownership before preparing its SQL
statement. `nv_storage_owner_validate` uses four metadata calls. Thus these
14,336 statements entail 57,344 private-store metadata checks on the healthy path,
in addition to the repository observations. This second count is derived from
the instrumented statement count and the owner-check implementation.

Statements are prepared, bound, stepped and finalized each time. A statement
cache alone would leave the repeated header/private-state work, ownership calls
and executor crossings. The bounded join directly removes more repetition.

The accepted-hint digest and fingerprint hashing still happen per file, as they
should for the checked inputs. Small array copies and the at-most-16-name
`removeFirst` buffer are not the demonstrated dominant costs.

## Executable measurements

Same local M1/macOS/APFS environment as the
[legacy bulk comparison](directory-scan-performance.md), Swift 6.4, optimized
build, nine warm samples after warmup. Real saved-edit envelopes accumulate behind
two current notes. Both profiles use encrypted SQLCipher private pages. Accepted
identities and final current values are checked independently of timing.

Complete unchanged discovery, median milliseconds:

| Files | Public, budget 16 | Encrypted, budget 16 |
|---|---:|---:|
| 64 | 18.383 | 28.460 |
| 256 | 82.232 | 92.559 |
| 1,024 | 353.522 | 510.835 |

The production source is unchanged from the earlier 289–295 ms baseline at
1,024 files. Interactive-machine load varied; this is not evidence of a new
production regression or a provider-encryption penalty. Stage order, work
counts and relative improvements are more useful here than absolute release
latency thresholds. Raising the complete discovery budget to 64 did not
reliably help: its 1,024-file medians were 364.425 and 666.460 ms. The name-list
page remains capped at 16 and per-file calls remain separate.

Native-only prototypes on those same 1,024-file fixture directories:

| Metadata path | Public median ms | Encrypted-fixture median ms |
|---|---:|---:|
| Production listing + per-file observation, budget 16 | 148.031 | 172.096 |
| Held-directory `fstatat`, batch 64 | 10.364 | 11.699 |
| `getattrlistbulk`, exact observation fields, batch 64 | 4.692 | 5.159 |
| `getattrlistbulk`, exact observation fields, batch 256 | 1.823 | 2.080 |

Each native candidate verifies every raw name and all nine observation words
against a production-observed inventory, rejects duplicates and checks complete
coverage. It uses the production listing's root/ancestor checks before and after
each batch. The 64-entry bulk candidate was approximately 32–33 times faster in
this final run. Earlier samples varied from 2.3 to 4.3 ms for that candidate,
with the same qualitative result. Batch 256 measures amortization potential;
it is not a proposed increase to Runtime's current 64-step maximum.

Database-only diagnostics, 1,024 hints, median milliseconds:

| Database work | Public | Encrypted |
|---|---:|---:|
| Header checks repeated per file, one overall lane turn | 153.864 | 246.848 |
| Existing two hint queries + header, one turn per file | 195.149 | 322.213 |
| Existing hint queries, header once per batch of 64 | 36.921 | 50.643 |
| Joined hint/membership lookup, header once per batch of 64 | 10.093 | 13.589 |

The join preserves payload shape, fresh fingerprint, hint digest and exact
accepted-identity checks. With the prototype's structure, sixteen 64-file batches
would issue 208 statements: twelve header checks and one joined query per batch,
versus 14,336 now. That 208 is a calculation from the prototype, not an additional
instrumented production result. Consumer checks and any final batch fencing
remain requirements of a production implementation.

These are isolated components, not a combined optimized Runtime. The SQL-only
tests precompute rooted hints; native tests exclude Swift/database work. Test
assertion and boundary costs also differ. Their timings cannot simply be added
to claim an integrated sweep latency. Bare legacy catalog timing is likewise
not the cost of its complete reconciliation transaction.

## Secondary repeated work

These source findings deserve separate workloads after the accepted-file path:

1. A bootstrap target always misses the accepted-hint path. An interrupted or
   incomplete bootstrap can reread retained candidate bodies on a later sweep.
2. Parked/rejected objects are not accepted membership. Their retained bytes do
   not currently qualify for hint reuse, so repeated sweeps reread and reopen
   them; retained parked objects can revisit queue/wakeup bookkeeping and hint
   upserts. A rejection lookup occurs after the receive attempt. The write/barrier
   cost of repeated delivery has not been measured here. Distinguish reusable
   retained-byte observations from accepted-history evidence before optimizing
   this path; the existing specification explicitly requires acceptance for the
   current hint shortcut.
3. Key descriptors bypass the accepted-hint lookup and are decoded each pass.
   They are normally few, but discovery reads them under the much larger segment
   ceiling even though their decoder has a 16,384-byte bound. A codec-specific
   read bound could avoid unnecessary oversized allocations/reads while keeping
   invalid-input outcomes explicit.
4. The first scan of locally published accepted objects has no seeded hints.
   Publication could issue a hint from its exact final verified installation,
   avoiding a first redundant reread. A separate later `stat` is insufficient:
   it could associate the accepted identity with intervening replacement bytes.
   This would need a narrow extension to installation evidence and race tests.
5. A stream of genuinely new objects performs actual decoding, retention,
   acceptance and ready-work processing. Those are different duties from an
   unchanged-file sweep. Measure them separately before changing transaction or
   acknowledgment boundaries.

## Recommended implementation order and safety boundaries

### 1. Bounded metadata observations

Extend the existing rooted listing boundary to return a bounded group of raw
names and exact observations. On Darwin, use bulk attributes; retain a portable
descriptor-relative `fstatat` batch fallback. Reuse the held ancestry and check
root/parent applicability around each bounded operation and its asynchronous
handoff. Changed-file reads and actual installations retain their exact
before/after file checks.

The legacy catalog is an algorithmic precedent, not a drop-in observation type:
its reconciliation fields and name filtering differ. Match all nine current
fingerprint fields, preserve raw name handling, special-file classification and
no-follow behavior. Apple's SDK manual requires checking returned-attribute masks
and per-entry errors; unsupported fields need an explicit individual fallback,
rather than interpreting packed zero defaults as real metadata. Do not mix
`readdir` and `getattrlistbulk` on one descriptor. Choose a stream mode or reopen
the appropriate stream when falling back. The prototype qualifies regular local
APFS files only; OS/filesystem/provider/race qualification remains necessary.

### 2. Bounded accepted-hint answers

After each metadata group, enter the existing database lane once. Validate
owner/header/required state within that turn, query the bounded hint keys and
accepted membership together, and verify every returned digest/fingerprint.
Keep issuer-restricted immutable answers scoped to the root permission and
selected store incarnation. Recheck lifecycle/context at the consumer after
suspension. Absence or malformed hints still select ordinary read/receive.

Use batches of 16 or 64 as measured candidates and preserve save fairness.
No persistent schema, sidecar, long-lived validation cache or broad new type
framework is required. Keep ownership checks around the bounded operation;
batching shares checks within its valid interval rather than dispensing with
the evidence they establish.

### 3. Adapter trigger coalescing

Use one session-owned worker and the existing pass/invalidation state. Merge
foreground, settled-save and presenter requests; continue a valid pass, stop
immediate continuation at its end, and preserve later independent ordinary
opportunities. Reuse the publication continuation separately. Qualify the
actual adapter's call frequency once it exists instead of inferring frequency
from the enum of possible opportunities.

### Acceptance checks for the follow-up

- Compare every batch observation and hint answer with independent expected
  names, fields and accepted identities; include changed and unchanged files.
- Root/ancestor replacement, symlinks, hard links, unsupported attributes,
  per-entry errors and file mutation between listing and body read preserve
  the established explicit outcomes.
- Same-type wrong-store/session evidence, close and generation change between
  metadata capture and SQL/consumer handoff cannot authorize a stale result.
- Intervening acceptance/settings changes, malformed hints, cancellation and
  transient/fatal I/O failures preserve bytes and unfinished obligations.
- Early empty passes, missing callbacks, new writer directories, lower parents,
  renamed duplicates and finite interfering saves retain eventual progress.
- Instrument real actor turns, statements, owner checks, metadata calls and body
  reads separately. Benchmark unchanged sweeps, first delivery, repeated parked
  input and many-writer cases. Bound resources and allow local saves between
  turns; avoid replacing per-file serial work with an unbounded task fan-out.

The remaining whole-sweep work is still proportional to disclosed filenames.
There is no safe promise of constant-time discovery with indefinitely growing
history and arbitrarily late disclosure. These changes aim to bring its native
portion close to bulk-scan performance and drastically reduce repeated SQL,
while preserving the existing evidence and discovery guarantees.

## Reproduction and evidence

```sh
python3 tools/benchmark-storage-discovery-work.py
```

The Swift diagnostic is
`NVStorage/Tests/NVStorageRuntimeTests/RepositoryDiscoveryAnalysisTests.swift`;
the native candidate is `tests/RepositoryDiscoveryBatchBenchmark.c`. The driver
checks nonzero passing test discovery, both profiles, all three sizes, nine
samples, SQL counts and native exact-field agreement. It preserves fixtures and
raw results. To rerun native measurements against the completed Swift fixtures:

```sh
python3 tools/benchmark-storage-discovery-work.py \
  --existing-results /tmp/nv-discovery-analysis.r9snV9
```

Results: `/tmp/nv-discovery-analysis.r9snV9/results.json`; build/test log:
`/tmp/nv-discovery-analysis.r9snV9/swift.log`. Optimized Swift qualification
passed both parameter cases (212.108 seconds including fixture construction).
The driver independently passed all six size/profile result files and native
comparisons. No production behavior or modeled safety condition changed, so
TLA+ configurations were not rerun for this diagnostic increment.

Read this with the normative discovery requirements in
`docs/iCloud-Drive-Support-Spec.md`, `CONTEXT.md`, ADR-0013, the discovery section of
`Protocol.md`, the Apple API validation ledger and
`docs/tla/README.md`'s `RepositoryDiscoverySafety` correspondence. Cold-cache,
remote-provider and alternate-OS performance, integrated batch correctness and
physical power-loss behavior remain outside these measurements.
