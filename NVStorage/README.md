# NVStorage

Portable Swift values and history validation, plus the first private SQLCipher
storage runtime. The Objective-C app does not import this package yet.

## Build and test

From the repository root, with Swift 6.1 or newer and a C compiler:

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
The Linux test driver also selects the integrated native Swift driver and disables
manifest caching, matching the qualified Swift 6.1 VM build configuration.
For an instrumented SQLCipher build, set `NV_SQLCIPHER_DEST` to a separate prefix
and `NV_SQLCIPHER_SANITIZERS=address`, then run `tools/test-storage-sanitizers.py
--prefix <prefix>`. It qualifies the sanitizer with a deliberate library-internal
failure before running Runtime tests.

## Entry points

`LocalStoreSession.create(directory:collection:notes:protection:passphrase:)`
seals frozen initial values on its worker and creates a new private candidate.
The overload accepting `InitialCollectionV1` retains already-sealed creation input.
`open(selection:protection:)` checks physical ownership, header and required state,
recovers SQL transactions, drains ready work and catches up current rows.

Use `snapshot()` to capture current values and their authoring basis. Construct an
immutable `CapturedActionGroup`, then call `persist(capture:)`. An accepted receipt
names exact covered generations; `HeadlessModel.complete` clears only matching
pending generations. A pending result owns a `CommitHandle` for retrying the same
bytes. `prepareReduction`/`publish` bind model publication to the checked view and
host generation. `quiesce()` drains admitted work; failed outstanding commits keep
the owner open and return `busy` until retried. Task cancellation does not discard
admitted inputs. Explicit checkpoint maintenance is independent of save receipts.

Both profiles encrypt database pages. The password-free profile uses the specified
publicly derivable database key, so encryption in that profile is not secrecy.
Encrypted-profile callers supply their validated collection key. No Keychain
dependency or credential transition is introduced here.

Supported history is bootstrap plus ordinary single-valued Create/Put/Delete,
including rename and labels. Concurrent bodies, compensation, conflict-derived
births and later reducers have explicit unsupported outcomes. Current rows use
the uncompressed correctness-baseline codec; zstd remains the selected subsequent
physical-codec task. See the [Phase 2 report](../docs/impl-proposal-5/plan/phase2-local-runtime-validation.md)
for evidence, limitations and remaining qualification.

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
