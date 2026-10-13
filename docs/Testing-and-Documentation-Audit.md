# Testing and documentation audit

Date: 2026-10-14. Scope: project-owned testing, validation documentation and their
links to current source. The workspace was clean at the start. Generated build
products, dependency downloads and vendored upstream suites were excluded from
the repository audit; retained qualification artifacts were used only to verify
test discovery and selection.

This is a reconciliation record, not a new storage/platform qualification. The
executable changes restore the sanitizer runner's full Runtime default selection,
check that selector and retire the stale discovery-variant rebuild modes while
preserving frozen-bundle replay. Production sources, test functions,
assertions, argument matrices, mutations, compiler boundaries and TLA+ conditions
remain unchanged.

## Coverage and interpretation

The audit used the [test index](Test-and-Validation-Index.md), source/support
inventory and concrete runners together. The review covered native/default and
platform Make targets, native scenario dispatch, Swift Core/Runtime test
membership and discovery, independent fixtures/oracles, process/compiler/mutation
runners, SQL/startup/undo/provider experiments, and current/retired formal-model
navigation. Release/build entrypoints retain the application qualification
boundary separately from the portable package.

Documentation was read against the [specification](iCloud-Drive-Support-Spec.md),
[ADRs](adr), [vocabulary](../CONTEXT.md), [formal guide](tla/README.md), proposal-5
roadmap/contracts and revision-bound qualification reports. The Apple API ledger
and Foundation replacement plan retain their conditional implementation roles.
No reconciliation changes a synchronization rule or requires a new model run.

The testing-audit skill informed the check for lost test scope and misleading
successful runs. Pattern matches for sleeps, shared fixtures and force unwraps
were inspected in context; polling/watchdogs, actor-owned immutable fixture
construction and known-valid literal setup were not treated as defects merely
because those patterns appeared.

Legacy epoch-4 opening/recovery/export and legacy database/WAL/file-save tests
remain active. Unreleased segment/private schemas have no draft-byte compatibility
requirement. Compact V1 and extended V2 canonical current cells are actively
emitted representations, rather than names that alone justify retirement.
Historical root-lock, incarnation, SQLite and undo experiments retain their
documented observational boundaries. Dated result counts and transient artifact
paths remain historical evidence, not current-suite counts or automatic cleanup
targets.

## Resolved findings

| ID / severity / category | Evidence and reconciliation |
| --- | --- |
| AUD-01 / HIGH / lost test scope | [Package.swift:5](../NVStorage/Package.swift#L5) partitions Runtime sources across three test modules. The sanitizer default previously matched only `NVStorageRuntimeTests`, selecting 144 of 335 Runtime functions. [test-storage-sanitizers.py:13](../tools/test-storage-sanitizers.py#L13) now matches Runtime, Recovery and Repository, selecting all 335 and excluding Core. Its default-selector assertions run beside the existing completion-classifier checks. Explicit targeted filters retain their meaning. |
| AUD-02 / HIGH / zero-match reproduction commands | Twelve P5.1/P5.2/P5.3/bounded-discovery reproduction references used source filenames as suite names, although their declarations are global functions (for example [RepositoryRootTests.swift:7](../NVStorage/Tests/NVStorageRuntimeTests/RepositoryRootTests.swift#L7)). Every old union selected zero entries in both retained 429-function inventories. [P5.1:161](impl-proposal-5/plan/phase5/01-root-ownership-validation.md#L161), [P5.2:169](impl-proposal-5/plan/phase5/02-immutable-files-validation.md#L169), [P5.3:275](impl-proposal-5/plan/phase5/03-local-repository-exchange-validation.md#L275) and [bounded discovery:217](impl-proposal-5/plan/phase5/bounded-discovery-batches-validation.md#L217) now derive declaration-name unions from the checked catalogue, preserving complete source-file and parameter coverage. Quotes carry alternation through Make. The separate Mini command requires its checked selector in that host shell. The integration guide's benchmark alternation is also escaped for Make. |
| AUD-03 / MEDIUM / stale implementation status | The README still called current-row compression a future task despite [CurrentRowFrameV1.swift:104](../NVStorage/Sources/NVStorageCore/CurrentRowFrameV1.swift#L104) choosing complete raw/plain/dictionary frames and [CurrentRows.swift:8](../NVStorage/Sources/NVStorageRuntime/CurrentRows.swift#L8) installing them. [NVStorage README:157](../NVStorage/README.md#L157) and the roadmap now link the implemented 4F codec, explicit recoding/maintenance and remaining cold-load/resource gates. The raw Phase 2 measurements remain their original baseline. |
| AUD-04 / MEDIUM / obsolete startup description | [LocalStore.swift:121](../NVStorage/Sources/NVStorageRuntime/LocalStore.swift#L121) drains `startupRequired`; [ReceivedObjects.swift:243](../NVStorage/Sources/NVStorageRuntime/ReceivedObjects.swift#L243) selects Changes and required prerequisites independently of queue order. [Publication.swift:35](../NVStorage/Sources/NVStorageRuntime/Publication.swift#L35) starts optional work only after checked host publication. The README and [S1 report:11](impl-proposal-5/plan/phase4-snapshot-acceptance-validation.md#L11) now state that split and link the later process-campaign adaptation. The original S1 results are not relabeled as a new campaign. |
| AUD-05 / MEDIUM / first-slice summaries out of sync | Roadmap summaries still called conflict-copy bytes and private pending codecs unfinished. The first-save contract still described empty-only settings and local selected-store cutover as future work. The [connected record contract:9](impl-proposal-5/plan/phase3-connected-record-contract.md#L9), [private-record contract:28](impl-proposal-5/plan/private-record-contract.md#L28) and Phase 3/4C–4E reports establish those enabled subsets. The [roadmap:19](impl-proposal-5/plan/swift-storage-implementation-plan.md#L19), [first-save contract:254](impl-proposal-5/plan/first-save-reopen-contract.md#L254) and Format TODO now distinguish implemented portable consumers from physical projection, host preference/migration and application gates. Initial layouts and dated counts are preserved. |
| AUD-06 / MEDIUM / schema and compatibility wording | [Database.swift:202](../NVStorage/Sources/NVStorageRuntime/Database.swift#L202) validates current schema 3, while the current-row contract said new candidates initialize revision 2. [private-current-row-codec.md:40](impl-proposal-5/plan/private-current-row-codec.md#L40) and Format TODO now describe revision 2's dictionary introduction followed by revision 3's conflict-copy index. Its stale development-row compatibility rationale was replaced with the actual raw benchmark/control uses at [CurrentStartupBenchmarkTests.swift:35](../NVStorage/Tests/NVStorageRuntimeTests/CurrentStartupBenchmarkTests.swift#L35) and [CurrentRowStorageTests.swift:41](../NVStorage/Tests/NVStorageRuntimeTests/CurrentRowStorageTests.swift#L41). Ordinary writers emit framed rows; the active controls and all bytes/assertions remain intact. |
| AUD-07 / MEDIUM / incomplete status propagation | The review summary still said snapshot-root growth was open despite its own implemented REVIEW-START-3 row and the [retention qualification](impl-proposal-5/plan/phase-4-improvements/snapshot-retention-coverage-validation.md). [storage-review-follow-up.md:10](impl-proposal-5/plan/storage-review-follow-up.md#L10) now distinguishes completed sequential coverage from concurrent frontier-width measurement. Its V1/V2 sentence now says each existing layout retains its respective bytes through the API refactor. Format TODO also links implemented incremental bootstrap and bounded ordinary-history/receive/discovery slices while retaining broader resource, global KDF/request and host admission gates. |
| AUD-08 / MEDIUM / misplaced historical authority | The proposal-4 gap report had no retirement status, referred to the then-current spec as current, and contained ten source links relative to the wrong directory (including one colon-style target). [pre-implementation_gap_report.md:3](impl-proposal-4/pre-implementation_gap_report.md#L3) now identifies its historical snapshot, links active requirements and fixes source-relative targets. Original findings and historical line labels are retained; the removed earlier blocker document is identified as historical context. No file was deleted. |
| AUD-09 / LOW / incomplete native navigation | [tests/Makefile:16](../tests/Makefile#L16) has six default executables, but the integration guide listed only two and said default Make builds every executable. It now lists all six, separates opt-in probes and links the native helper catalogue. It adds the two omitted `run-core` scenarios implemented at [NVIntegrationTest.m:7669](../tests/NVIntegrationTest.m#L7669) and [NVIntegrationTest.m:8999](../tests/NVIntegrationTest.m#L8999): file barrier/fallback and external-editing text merge. The root-lock section now links P5.1/P5.5 production ownership and preserves legacy cleanup as its separate boundary. |
| AUD-10 / LOW / stale heading link | The graph-reuse plan linked an old benchmark heading and still called optional scheduling a separate investigation. [recovery-graph-reuse.md:85](impl-proposal-5/plan/phase-4-improvements/recovery-graph-reuse.md#L85) now states required-before-publication/optional-after-publication ordering and links the implemented startup/scoped-query report directly. |
| AUD-11 / LOW / unlinked current asset | [Implementation.md:80](impl-proposal-5/Implementation.md#L80) cited the existing current `conflict_resolver.pdf` only as plain text. That citation now links the current proposal-5 asset. The PDF bytes, separate proposal-4 copy and all UI requirements are preserved. |
| AUD-12 / LOW / unavailable artifact links | Four absolute `/var/folders/...` links in the connection-reuse report pointed to original artifacts now absent on this host. [private-connection-reuse.md:135](impl-proposal-5/plan/phase5/private-connection-reuse.md#L135) now states their availability and records the exact paths as code text. Dated results, assertions and reproduction commands are retained; a future campaign generates new evidence rather than recreating the missing original records. |
| AUD-13 / MEDIUM / stale experiment reconstruction | The user approved retiring the discovery-variant runner's partial-source rebuild modes. It now requires `--replay-only`, retains `--replay-rounds` and preserves the complete replay function. Historical measurements and frozen bundles remain the experiment's evidence; current implementation benchmarks retain their separate entrypoints. See the [resolved maintenance decision](#resolved-maintenance-decision). |

## Resolved maintenance decision

`tools/benchmark-storage-discovery-variants.py` now supports preserved-bundle replay.
[Replay](../tools/benchmark-storage-discovery-variants.py#L14)
rotates four existing bundles over the same fixtures and requires successful,
nonzero discovery and exact observed results. That remains a meaningful
experimental entrypoint, bound to those preserved builds.

The retired fresh-build path copied the current package, deleted
`RepositoryBatchTests.swift` from that copy and replaced a partial set of Swift/C
sources with an older frozen baseline. The [explicit target table](../NVStorage/Package.swift)
still named that source, so the complete/disjoint membership checker rejected the
resulting inventory. Later Apple/startup/connection consumers also made a partial
baseline insufficient evidence of a coherent frozen revision. The audit diagnosed
that inventory mismatch without running the expensive four-build campaign.

The [bounded-discovery reproduction section](impl-proposal-5/plan/phase5/bounded-discovery-batches-validation.md#L235)
now gives the supported replay command. On 2026-10-14, the user chose to retire
`--baseline` fresh builds and `--rebuild-original` reconstruction, preserving
`--replay-only`, its checks and the recorded results. The script rejects the
retired options. A future optimization should use a coherent new comparison
baseline; current discovery-work and legacy-scan benchmarks remain available.

This resolves the audit's remaining maintenance choice. Product/synchronization
policy and current production test coverage are unchanged.

## Validation

| Check | Result and scope |
| --- | --- |
| `python3 tools/test-storage-test-targets.py` | Pass: 24 harness tests; all 72 Runtime source files occur exactly once across the three targets. |
| `python3 tools/test-storage-sanitizers.py --help` | Pass: existing nonzero-completion classifier checks and the new three-module/Core-exclusion checks execute before argument parsing. |
| Python compilation of the modified sanitizer runner | Pass; no instrumented library/runtime execution implied. |
| Catalogue selectors versus both preserved complete SwiftPM listings | Pass: 18 root, 23 root companions, 31 immutable companions, 26 file/root, 49 exchange and 52 batch/listing/file/bootstrap/exchange/root functions. Each selection equals its complete named-source declaration set in both debug and release; parameter signatures remain in the listings. |
| Restored sanitizer default versus the same listings | Pass: 335 functions, comprising 144 Runtime + 82 Recovery + 109 Repository. Core is excluded. The old default selected only 144. |
| Experimental batch-source removal versus the current membership checker | Expected rejection: `extra=Counter({'RepositoryBatchTests.swift': 1})` in the manifest's declared source set. This diagnoses the reconstruction seam without running the benchmark. |
| Replay-only retirement checks | Pass: the replay function's source is identical to the pre-retirement revision; Python syntax and help pass. Intercepted CLI dispatch preserves default 3/custom 9 rounds; missing replay input, both retired flags and out-of-range 0/10 rounds are rejected. Frozen bundles were not executed and their artifacts/results were untouched. |
| Native guide/source comparison | Two omitted runnable scenarios documented; helper-only subprocess modes remain indexed with their owning runner. Six default targets and opt-in probe boundaries match Make. |
| Markdown/source-link scan and `git diff --check` | Source-relative defects reconciled; whitespace check passes. Parent verification refreshes/checks the generated index and final local heading/navigation links after reconciliation. |

The selector checks used
`/tmp/nv-shared-history-pilot.3bISbR/after-debug-inventory.stdout.log` and
`after-release-inventory.stdout.log`: both contain the same 429 complete logical
test identities. The current declaration/membership catalogue supplies the source
mapping. An initial fresh SwiftPM listing attempt encountered the restricted
user module cache and then absent default-backend artifacts; those setup failures
are separate from the retained native-backend discovery evidence.

No full Swift, sanitizer, live-provider, app or TLC campaign was rerun for these
documentation/selection changes. Existing reports remain the authority for their
executed revisions, environments and limitations. Final index regeneration is a
source/reference completeness check, not execution of its catalogued tests.
