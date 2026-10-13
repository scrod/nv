# NVStorage

Portable Swift values and history validation, plus the private SQLCipher
storage runtime. The Objective-C app does not import this package yet.

NVStorage and all segment/private formats are unreleased. NV's last public
release was in 2011 and used epoch-4 Notes & Settings. Compatibility covers
epoch-4 opening, journal recovery and explicit legacy export in the macOS app;
superseded development encodings require no reader or migration in this library.

## Build and test

The [project test index](../docs/Test-and-Validation-Index.md) lists individual
Core/Runtime tests, process/fixture/type/mutation checks and their plan references.

From the repository root, with Swift 6.4 or newer and a C compiler:

```sh
bash tools/build-storage-deps.sh
make -C tests run-swift-storage
make -C tests run-swift-storage-phase2
make -C tests run-swift-storage-phase2 SWIFT_STORAGE_PHASE2_FLAGS='--configuration release --mutations'
```

SQLCipher 4.19.0 is built at the exact revision recorded in the build script into
ignored `.deps/sqlcipher`. It uses CommonCrypto on Darwin and OpenSSL on Linux.
There is no system-SQLite fallback. Direct SwiftPM invocations need
`PKG_CONFIG_PATH="$PWD/NVStorage/.deps/sqlcipher/lib/pkgconfig"`.
The existing test driver supplies it. Initial dependency acquisition needs network
access; `NV_SQLCIPHER_SOURCE` can name an already available Git checkout.

Swift Crypto is pinned to 4.5.2, whose Linux `SymmetricKey` has upstream `Sendable`
conformance. Both platforms retain Swift 6 concurrency checking. Linux builds
also require OpenSSL development headers and a C++ compiler. Zstd 1.5.7 is embedded
as portable C sources in `Vendor/Zstd`; no system zlib/zstd dependency is needed
by NVStorage. The package resolution records the exact Swift Crypto and Swift
ASN.1 revisions. All new compression uses zstd; legacy database/WAL compatibility
remains in the existing application path. Independent Node checks use its zstd
functions, which happen to live in the `node:zlib` module.

Linux executable tests use Swift's bundled lld with RELRO/immediate binding.
`tools/check-storage-elf.py` verifies the resulting PIE and W^X/stack/RELRO
permissions. Apply and qualify equivalent settings in downstream executables.
The Linux test driver selects the native Swift driver and disables manifest caching.
Swift 6 language mode checks actor isolation and `Sendable` transfers on both
platforms. Core and Runtime enable strict memory-safety checking and treat warnings
as errors through typed SwiftPM settings. Their named C adapters acknowledge each
raw borrow locally, with owned buffers, bounded copies and synchronous disposal.
The private executor uses Dispatch's checked, immutable queue-identity
key; the C-handle release adapter is inventoried in the
[actor ownership contract](../docs/impl-proposal-5/plan/actor-database-adoption.md#connection-lifetime).
For an instrumented SQLCipher build, set `NV_SQLCIPHER_DEST` to a separate prefix
and `NV_SQLCIPHER_SANITIZERS=address`, then run `tools/test-storage-sanitizers.py
--prefix <prefix>`. It qualifies the sanitizer with a deliberate library-internal
failure before running Runtime tests.

The [Swift 6.4 qualification report](../docs/impl-proposal-5/plan/swift64-platform-qualification.md)
records the compiler probes, runtime checks and remaining platform limits.

The [Phase 4 improvement report](../docs/impl-proposal-5/plan/phase-4-improvements/validation.md)
records interrupted-verification recovery, exact per-envelope graph reading and
one-graph unpublished recovery. The common driver includes their fixtures,
fresh-process schedules and compiler boundaries. Opt-in scaling comparisons use
`NV_STORAGE_IMPROVEMENT_BENCHMARK=1` with the filters
`packedReaderImprovementMeasurements` and `recoveryWorkAcrossHistoryAndLag`.

The [Phase 4C–4E report](../docs/impl-proposal-5/plan/phase4-private-state-repair-copy-validation.md)
describes nonempty private settings, exact pending-input transactions, fixed-cut
keyed backup, complementary repair and verified selection, plus distinct
repository-copy and fresh-current export paths. The common driver includes their
independent fixtures, private construction probes and fresh-process schedules.

## Entry points

`LocalStoreSession.create(directory:collection:notes:protection:passphrase:)`
seals frozen initial values on its worker and creates a new private candidate.
The overload accepting `InitialCollectionV1` retains already-sealed creation input.
`open(selection:protection:)` checks physical ownership, header and required state,
recovers SQL transactions, replays unfinished verification requests, drains ready
Changes and their required prerequisites, and catches up current rows. Independent
optional snapshots stay durably queued until successful checked host `publish`
starts the existing receive worker. See the
[startup/scoped-query qualification](../docs/impl-proposal-5/plan/phase-4-improvements/startup-and-scoped-queries-validation.md).
General catch-up before first publication
prepares one complete checked accepted prefix; live catch-up retains its per-batch
route. Healthy up-to-date rows keep their indexed startup path.

Use `snapshot()` to capture current values and their authoring basis. Construct an
immutable `CapturedActionGroup` with an `OrdinaryActionKind`, then call
`persist(capture:)`. Specialized commands issue captures carrying their exact
Restore, conflict, historical-recovery or compensation provenance. An accepted receipt
names exact covered generations; `HeadlessModel.complete` clears only matching
pending generations. A pending result owns a `CommitHandle` for retrying the same
bytes. `prepareReduction`/`publish` bind model publication to the checked view and
host generation. `quiesce()` drains admitted work; failed outstanding commits keep
the owner open and return `busy` until retried. Task cancellation does not discard
admitted inputs. Explicit checkpoint maintenance is independent of save receipts.

`receive(_:)` retains exact Changes or initial/general snapshot envelopes. Its
closed outcomes distinguish accepted history, retained assembly pages, pending
validation, typed byte/history waits and rejected prerequisites. `receivedObjectStatus(at:)`
reconstructs those requirements from the retained inputs. Roots accept only their
complete verified page/history closure; optional work remains recoverable through
close and reopen. See [received-snapshot qualification](../docs/impl-proposal-5/plan/phase4-received-snapshot-validation.md).
Definitive stale-capture or canonical-encoding rejection before sealing returns
the unchanged input handle and releases its local reservation, allowing later
valid saves. Sealed bytes and uncertain persistence outcomes remain owned for retry.

Both profiles encrypt database pages. The password-free profile uses the specified
publicly derivable database key, so encryption in that profile is not secrecy.
Encrypted-profile callers supply their validated collection key. No Keychain
dependency or credential transition is introduced here.

`collectionSettings`/`saveCollectionSettings` and association methods use
store/session-bound expected generations. Pending methods retain latest previews,
prepare ordinary Import/association captures, recover their exact committed
identities and settle matching observations. They leave physical file installation
to the later adapter.

`backupPrivateStore` produces a normally reopenable fixed-state database copy.
`preserveForRepair`/`salvagePrivateStoreDiagnosing` preserve source evidence;
`buildVerifiedReplacement` validates complementary committed history/private
inputs and issues a separately activatable replacement. `RepositoryCopy` preserves
available repository bytes even while locked. `copyRepositoryAndSavedWork` also
includes unpublished saved history; `exportCurrentValues` creates fresh history
from complete current values. Their result types keep backup, copy, export and
selection obligations distinct.

`captureGeneralSnapshot()` freezes neutral accepted values and continuation
claims. `persistGeneralSnapshot(capture:)` retains bounded exact candidate pages,
checks the complete root against its represented history, and accepts its root,
pages, dependencies and retained pin together. `retry(snapshot:)` resumes the same
sealed bytes through an owner-issued handle. A distinct `AcceptedSnapshotReceipt`
reports durable snapshot coverage. Fresh reopening retains a complete optional
root for the receive worker started by checked host publication; required snapshot
prerequisites are processed before that publication. Both paths preserve current
notes and ordinary edit acknowledgment. Optional snapshot construction permits durable close, preserving
retained candidates and the committed outcome of a delayed completion.
See the [S1 report](../docs/impl-proposal-5/plan/phase4-snapshot-acceptance-validation.md)
for the tested acceptance failure cuts.

`create(directory:collection:notes:protection:passphrase:)` incrementally seals
frozen initial values into an owned `BootstrapCandidate`. The candidate's public
retain/resume/complete API supports interrupted construction. Complete store-backed
verification and atomic acceptance precede ordinary editable opening.
`rebuildCurrentRows()` reuses a checked snapshot's unchanged cells and applies
every accepted logical operation outside its cut, then guards one complete
replacement against history and view changes. It preserves private groups and
pending host work. Healthy reopening retains indexed current-row loading.
See the [S3/S4 report](../docs/impl-proposal-5/plan/phase4-bootstrap-reconstruction-validation.md)
for connected reconstruction, exact continuation and fresh-process qualification.

Supported plaintext history includes bootstrap, Create/Put/Delete, rename, labels,
fresh-birth Restore, multi-head equality/conservative merge, delete/edit preservation,
explicit source choice and conflict copies, historical field recovery and portable
causal Undo/Redo. Native compensation records carry exact remaining effects for
the later AppKit adapter. Private current rows use bounded raw, plain zstd or
dictionary frames; the encoder selects the smallest complete representation and
the decoder verifies the named dictionary's full digest. Explicit recoding can
train a bounded dictionary and install it atomically with its rows. The
[Phase 4F report](../docs/impl-proposal-5/plan/phase4-current-row-locality-maintenance-validation.md)
records the implemented codec, checked first capture, explicit maintenance and
remaining cold-load/resource qualification. See the [Phase 2 report](../docs/impl-proposal-5/plan/phase2-local-runtime-validation.md)
for the local durability foundation and the [Phase 3 report](../docs/impl-proposal-5/plan/phase3-validation.md)
for connected semantics, schedules and qualification boundaries.

`history(for:after:limit:)` pages accepted revision metadata for a birth or logical
Delete entries. `preview(_:)` loads a detached exact operation/action and, for a
Delete, its recorded prior value. Store-issued cursors keep a fixed history prefix
while saves continue. `restoration(from:as:)` captures a selected Delete's prior
value for `CapturedActionGroup(snapshot:restoring:)`. `HistoryQuery.recentlyDeleted`
excludes precisely the entries named by durably accepted restorations, including
after the restored birth is deleted. See the [Restore contract](../docs/impl-proposal-5/plan/restoration-record-contract.md)
and [phase-3 evidence](../docs/impl-proposal-5/plan/phase3-restoration-validation.md).
The qualification driver includes two-store history, Restore and connected
merge/preservation/copy/compensation lifecycles with fresh-process commit/crash/I/O
schedules for both profiles.

`reductionPreview(for:)` computes detached note-head/base/value evidence from one
captured accepted prefix. The portable `NVConservativeMergeV1` engine preserves
exact LF/UTF-8 text and the declared represented inputs. Its deterministic merge
descriptor is inspectable without emitting a history operation. Editable
multi-input current rows retain all represented revisions; subsequent ordinary
edits supersede precisely those inputs. See the [merge contract](../docs/impl-proposal-5/plan/conservative-merge-contract.md)
and [qualification scope](../docs/impl-proposal-5/plan/phase3-merge-validation.md).

`DerivedStateReferenceV1` encodes equal/merge claims with exact operation references.
Asynchronous reconstruction resolves those occurrences and recomputes the value
against a supplied complete note graph, issuing `ReconstructedDerivedStateV1`
through a file-private constructor. The [subrecord contract](../docs/impl-proposal-5/plan/derived-state-reference-contract.md)
and [connected record contract](../docs/impl-proposal-5/plan/phase3-connected-record-contract.md)
describe the subrecord and its complete writer-history validation, current-row
encoding and ordinary-edit consumers.

`conflicts(for:)` returns Current, unresolved alternatives and exact separately
represented revision IDs. `chooseVersion` captures an explicit source-body choice;
`copyVersion` captures representation-only recovery using a body-bound key and
checked slot. `recoverHistory` changes selected fields or creates a fresh ordinary
historical copy. `pinCurrent`/`releaseCurrentPin` provide temporary local presentation
fences while keeping neutral source selection independent of copy dispositions.

`undoCandidates` derives direction-specific causal candidates.
`prepareCompensation` returns a store-issued `AutomaticCompensation`,
`CompensationReview`, candidate choice or no-effect outcome. `applyCompensation`
accepts the automatic command; `applyReviewedCompensation` explicitly approves
the disclosed review and any selected replacements. Both revalidate the exact
scope, values and session before capturing one complete action. An automatic
command's `forReview()` presents the same frozen command for explicit review.
Actual inverses preserve unrelated fields and
fresh restoration mappings. `nativeCompensation` captures attributed member steps
and per-saved-group remaining coverage. These portable APIs supply the semantics
for the later shared editor/router integration.

The [typed-boundary follow-up](../docs/impl-proposal-5/plan/typed-runtime-boundaries-validation.md)
documents private validated acceptance batches, command-specific capture intent,
automatic/reviewed compensation, exhaustive receive-error classification and
explicit lifecycle/owned-commit states, with their compiler and runtime checks.

The [hardening follow-up](../docs/impl-proposal-5/plan/phase2-hardening-validation.md)
documents off-writer history checks, per-batch catch-up, durable receive rejection
and generated two-store failure schedules. `receive` reserves one inbound attempt;
valid local saves can interleave with its historical reads.
After save interference, that owned receive resumes from existing completion
notifications. `receivedObjectStatus(at:)` exposes waiting versus blocked
prerequisites, including transitive rejection reasons. Rejected candidates and
blocked descendants retain their exact bytes. See [follow-up qualification](../docs/impl-proposal-5/plan/validation-resumption-results.md).

The [zstd codec qualification](../docs/impl-proposal-5/plan/zstd-codec-validation.md)
records the current compression format, pinned sources, independent fixtures,
mutation checks and platform results.

`CStorageFaults` and `NVStorageProbe` are test support. Neither is a dependency of
the `NVStorageRuntime` product. Tests operate on disposable synthetic collections.
