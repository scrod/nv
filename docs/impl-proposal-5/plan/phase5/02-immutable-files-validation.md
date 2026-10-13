# P5.2 — Immutable files and rooted namespace qualification

Date: 2026-10-10. Status: implemented and qualified within the capability and
distribution limits below. P5.3's transport/acceptance connection is implemented;
see its [separate qualification](03-local-repository-exchange-validation.md).
Read the [part plan](02-immutable-files-and-namespace.md),
[root-owner qualification](01-root-ownership-validation.md) and
[physical testing contracts](../phase5-provider-root-testing-plan.md#4-qualify-physical-operations-by-intent).

## Implemented source boundary

`RepositoryObjects.swift` renders descriptor/segment destinations from checked
identities. `ImmutableRepositoryObject` freezes the exact envelope/descriptor and
its collection/profile context. Its restricted factories perform codec and
identity checks. P5.3's publication caller separately supplies private accepted
membership and dependency closure; a parsed object is not an acceptance receipt.

`RepositoryRootSession` reuses P5.1's admission generation, actor, dedicated
filesystem executor and continuous physical directory ownership. Permission and
in-flight work are reserved before suspension. Observations, coherent contents,
discovery leaves/cursors and installation evidence have restricted constructors.
Consumers check their issuing root/session/generation and exact object context.
No persistent schema, sidecar, permission registry or unchecked Sendable
conformance is added.

`NVRepositoryFiles.c` supplies the narrow native effects:

- Retain every traversed parent descriptor; reject unsafe components and followed
  intermediate symlinks. Recheck held/named identities and retained-root health.
- Read a bounded regular single-link file against exact before/after held and
  named observations. Complete envelope validation remains the next boundary.
- Resume one shallow directory stream in turns of at most 256 inspected entries,
  including dot entries. Return raw untrusted leaf bytes. A new stream replaces
  the old one; each successful continuation rotates its existing UUID slot, so
  replay rejects before advancing the stream. P5.3 extends the original single
  stream to a bounded parent/child stack; its separate witnesses qualify nested
  progress and retirement while retaining continuous root ownership.
- Create a 0600 root-owned stage, write/verify all bytes, synchronize it, then use
  Darwin `renameatx_np(RENAME_EXCL)` or Linux `renameat2(RENAME_NOREPLACE)`.
  Reopen/verify exact final bytes and identity, synchronize every parent directory
  bottom-up and finish Darwin's hardware-cache request. Equal existing objects
  undergo the same final verification and barriers.
- Return verified, not-installed or uncertain, with separate namespace-effect,
  retained-stage and cleanup-error accounting. Lost rename returns and late
  failures retain the original exact retry input. A stale Swift completion returns
  uncertain evidence rather than authorizing later bookkeeping.

The global object-size ceiling is the existing encoded envelope limit; protocol
paths have at most six 255-byte components. Listing budgets yield rather than
imposing a collection-file-count ceiling. Verification uses a bounded streaming
buffer. File reads allocate only after the issuing observation passes the caller's
byte limit.

## Supported producer and durability contracts

The qualified producer exposes complete immutable finals or atomic safe saves and
preserves another operation's reserved owned stages. Directory/file observations
are checked evidence, not an atomic reservation against arbitrary same-vnode
writers. Stable intermediate in-place writes remain outside the producer contract;
authentication/schema checks still apply to every received object. No settling
delay turns intermediate bytes into a transaction.

Owned cleanup compares the current named stage with its retained descriptor.
Displaced, wrong-kind, hard-linked or otherwise ambiguous names survive. The
check-to-unlink interval relies on the reserved-stage producer contract: a
noncooperating process can always replace a name between separate syscalls.
Uncertain cleanup preserves evidence and reports its state. There is no startup
prefix sweep of unknown artifacts.

Process termination leaves the operating system running. The separate
`NamespaceLossV1` observer applies permitted persistence loss to actual recorded
native effects: file bytes and directory-entry maps require their own barriers;
an exclusive rename exposes only a complete file. On Darwin, directory fsyncs are
followed by the final hardware-cache request. The minimal-survival case drops
other newly created names. Its independent negative controls challenge
always-durable behavior, missing namespace barriers and partial final visibility.
This abstraction tests the claimed ordering, not actual power loss or a storage
device that falsely reports successful synchronization.

## Requirement-to-witness map

| P5.2 obligation | Production witness / independent observation |
| --- | --- |
| Bounded rooted observations, reads and shallow catalogs | Swift 519-leaf/budget-7 resume; replay/wrong-directory/stale cursor; changed-directory stream disposal; native short/EINTR/zero/error/truncate/safe-save/same-vnode/permission/size/absence companions; exact descriptor baselines. P5.1 retains beyond-PATH_MAX root acquisition and movement witnesses. |
| Canonical identities and hostile namespaces | Both profiles through checked factories; wrong collection/profile/locator/descriptor rejection before effects; provider-renamed duplicate identified from its envelope; seven raw path violations; incompatible regular/directory/symlink/FIFO/hardlink/intermediate/stage occupants preserved. |
| Complete-stage exclusive installation | Independent readers at actual syscall gates; staged-file barrier before any final visibility; final exact bytes/identity and five nested namespace barriers; partial visible-final copy mutation rejected. |
| Truthful duplicate/failure/retry outcome | Equal independently written, previously unbarriered final retains its inode and gains real barriers; native fault counts prove each injection; lost rename return preserves installed bytes and returns uncertain; delayed canceled/invalidated/closed Swift completion retains exact input. |
| Add-only protocol directories | Every mkdir fault; competing final and replaced nested directories; preserved winners; image ENOSPC/remount; complete-object results stay distinct from complete-repository repair. |
| Owned disposal and compiler boundary | Foreign/displaced stage preservation, repeated cleanup failure, empty-stage ambiguity, held-root lifetime and fresh owned retry; restricted constructor/role/decoding probes and actual wrong-context consumers; sanitizer/static analysis and targeted mutations. |

## Executed checks

Primary host: arm64 macOS 26.6.2 (25G83), Swift 6.4/Xcode 27. Tests use isolated
temporary roots; both provider profiles use the existing encryption contracts.

| Check | Result |
| --- | --- |
| Affected debug / optimized Swift suites | All 31 test functions pass in debug (42.534 s) and optimized (5.529 s), including all eight file functions and 18 root functions, plus affected acceptance/copy companions. |
| Fresh Swift subprocesses | Both profiles pass prepare → install → independent canonical-path/disk inspection → fresh read/decode → equal retry in debug and optimized builds; encrypted repository/staging bytes contain no fixture body. The Python oracle derives the writer, sequence and complete-envelope hash directly from encoded bytes. |
| Native ASan/UBSan | 28 Darwin fault schedules, 31 pipe-confirmed cuts, three crash/write-failure/crash/retry schedules, seven raw path violations, coherent-read/race companions and exact descriptor baselines pass. |
| Native mutations | Seven isolated production-source mutations require intended failures: omitted stage barrier, omitted directory barriers, premature evidence, equal-final shortcut, mutable overwrite, visible-final copy and filename-based cleanup. |
| Swift construction/context/mutations | All 40 ordinary/same-module probes pass against each of the debug and optimized modules. Four selected mutations fail at the designated assertions: borrowed-lock release, stale read error, stale install completion and cursor replay. |
| Swift ASan / TSan | Instrumented SQLCipher ASan controls and all 26 root/file functions pass. All 26 also pass under Swift TSan (33.757 s), with no reported race. The native TSan run passes but predates the two additional compatible-winner races; the final ASan/UBSan run includes all seven races. |
| Strict C boundary | Conversion/alignment/warning checks, static analysis with zero diagnostics, and actual ASan/UBSan native effects pass. |
| Filesystem images | APFS/APFSX and HFS+/HFSX pass exclusive install, equal retry, nested barriers, actual detach/remount, genuine ENOSPC and successful exact retry. ExFAT records the explicit capability gap below. |
| Intel macOS 14.8.9 / macOS 11.7.11 | Final native ASan/UBSan suites pass on both. Both profiles pass fresh Swift subprocesses on both systems. The Mini also executes all 31 Swift test functions (17.033 s). Orbb uses the separately identified compiler/concurrency-runtime variant below; its Swift Testing framework requires a newer OS, so no full Swift test-bundle claim is made there. |
| Ubuntu 26.10 arm64 / Swift 6.4 | Final native ASan/UBSan suite passes with 25 faults, 28 process cuts and all seven races; all seven native mutations pass. Successful current-source builds execute all 31 Swift functions in debug (13.338 s) and optimized (2.606 s). Fresh subprocesses pass for both profiles in both configurations. All 40 compiler probes pass in each configuration. Both executables pass PIE, W^X, non-executable-stack and RELRO checks, including the RWX negative control. |
| TLA+ correspondence | Unchanged `LocalDurabilityLaneIndependence` exhaustive run passes, 64 states. These effects qualify environmental predicates; no safety assertion or modeled acceptance rule changes. |
| Application/schema build | All 19 schema checks pass. `build.sh` reaches Xcode 27's deployment-target diagnostic; the explicit previously authorized `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` build succeeds. Application interaction sources remain unchanged. |

### Findings and capability limits

**ExFAT allocation changes identity evidence.** On the actual image, an empty
new file reported an allocation-placeholder inode; after the first write the
retained descriptor reported the allocated inode. The implementation now reads
fresh identity from that descriptor before rename, final verification and cleanup.
Empty stages remain preserved when cleanup cannot establish an unambiguous owned
incarnation. The subsequent native exclusive rename returned ENOTSUP (45).
ExFAT root ownership remains separately qualified by P5.1, while this immutable
installation operation is unsupported. There is no visible-final-copy fallback.

**Failure injection must reach the intended boundary.** An early image-full test
left enough residual capacity for a small stage. The corrected test fills its
owned image to real ENOSPC and requests an 8 MiB object, while preserving the
already installed object. Reclaiming only its owned filler permits an exact retry.
Earlier path-spelling and image-attach harness failures are excluded from positive
evidence. No production contract was weakened.

**Mutation attribution is strict.** An early cursor mutant rejected the first
valid continuation instead of permitting replay. That run is an unrelated failure,
not a passing negative control; the corrected mutant preserves one cursor identity
and must fail the explicit replay-rejection assertion.

**Qualification failures stay distinct from passing evidence.** A Linux native
mutation baseline exhausted the test user's RAM-backed `/tmp` quota and failed
before the intended race gate. Its EDQUOT outcome supplied no installation
evidence. The unchanged suite and seven mutations pass after scoped reclamation
of old synthetic database files. Inventories retain the exact reclaimed paths;
reports, source and binaries survive. SwiftPM's experimental integrated driver
also printed cancellation despite returning success and launching an existing
test executable. Those canceled builds cannot establish a current-source build;
compiler resource failures and successful reruns are recorded separately.
The final debug build uses the ordinary native driver and reports `Build
complete!`; the optimized integrated-driver build also completes explicitly.
The disposable VM has 4 GiB RAM, its existing 2 GiB compressed swap and a scoped
768 MiB qualification swap file. Resource adjustments change the test host,
not storage contracts or compiler safety settings.

The macOS 11 Swift distribution limitation from P5.1 remains: the tested compiler
variant executes with an isolated concurrency runtime, while default distribution
qualification is still open. P5.3's accepted-history/publication exchange, P5.4's
Apple coordination/live providers, P5.6's mutable replacement/populated repair and
physical power-loss qualification remain distinct subsequent boundaries.

The Intel executable was cross-built with the documented
`-disable-concrete-type-metadata-mangled-name-accessors` workaround. Orbb loads
only the isolated test concurrency runtime through its child environment; no
system library is replaced. The resulting executable's minimum deployment
version remains 12 despite the requested 11.5 target. Successful execution of
this variant therefore qualifies its behavior, not a default macOS 11 release
artifact.

## Reproduction

Use a writable compiler cache where required and one build job. The native tools
compile the actual production C implementation with test-only syscall observation
and fault interposition; they never inject a pre-issued Swift receipt.

Current source-file selections use declaration names from the checked test
catalogue. They preserve every selected function and its parameter matrix after
the test-target partition. The result counts above remain dated campaign evidence.

```sh
python3 tools/generate-test-index.py --check
NV_IMMUTABLE_FILTER=$(python3 -c 'import json,sys; rows=json.load(open("docs/test-index/catalog.json"))["entries"]; names=[r["name"] for r in rows if r["kind"]=="swift" and r["source"].rsplit("/",1)[-1] in sys.argv[1:]]; assert names; print("|".join(names))' RepositoryFilesTests.swift RepositoryRootTests.swift ActorAcceptanceTests.swift RepositoryCopyTests.swift)
NV_FILE_ROOT_FILTER=$(python3 -c 'import json,sys; rows=json.load(open("docs/test-index/catalog.json"))["entries"]; names=[r["name"] for r in rows if r["kind"]=="swift" and r["source"].rsplit("/",1)[-1] in sys.argv[1:]]; assert names; print("|".join(names))' RepositoryFilesTests.swift RepositoryRootTests.swift)
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS="--disable-sandbox --jobs 1 --no-parallel --filter \"$NV_IMMUTABLE_FILTER\""
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS="--disable-sandbox --configuration release --jobs 1 --no-parallel --filter \"$NV_IMMUTABLE_FILTER\""
make -C tests run-swift-storage-root-types
make -C tests run-swift-storage-root-types SWIFT_STORAGE_ROOT_MODULES=../NVStorage/.build/release/Modules
make -C tests run-swift-storage-immutable-process
make -C tests run-swift-storage-immutable-process SWIFT_STORAGE_ROOT_BINARY=../NVStorage/.build/release/NVStorageProbe
make -C tests run-swift-storage-immutable-files SWIFT_STORAGE_IMMUTABLE_FLAGS='--sanitize address,undefined'
make -C tests run-swift-storage-immutable-mutations
make -C tests run-swift-storage-immutable-volumes
python3 tools/test-storage-runtime-mutations.py --disable-sandbox --jobs 1 --only root-borrow-unlocks-owner --only root-stale-read-error --only immutable-stale-completion --only immutable-replayed-listing-cursor
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --jobs 1 --filter "$NV_FILE_ROOT_FILTER"
env PKG_CONFIG_PATH="$PWD/NVStorage/.deps/sqlcipher/lib/pkgconfig" swift test --build-system native --disable-sandbox --package-path NVStorage --scratch-path NVStorage/.build-thread-sanitizer --sanitize thread --jobs 1 --no-parallel --filter "$NV_FILE_ROOT_FILTER"
```

The image job mounts only its newly created bounded images and always detaches
them. Retained artifacts include `nv-immutable-volumes-26ghtfbz` under `/private/tmp`,
native effect/fault logs, isolated mutation patches/manifests and fresh-process
fixtures. Principal artifact locations:

- Primary host: `/tmp/nv-p52-debug-final.log`,
  `/tmp/nv-p52-release-final.log`, `/tmp/nv-p52-native-final.log`,
  `/tmp/nv-p52-c-mutations-final.log`,
  `/tmp/nv-p52-swift-mutations-final.log`, `/tmp/nv-p52-swift-asan.log`,
  `/tmp/nv-p52-swift-tsan.log`, and the debug/optimized type/probe logs with the
  same prefix.
- Mini: `/tmp/nv-p52-swift.rqA0zV` and `/tmp/nv-p52-native.GiIxCj`;
  local reports `/tmp/nv-p52-mini-swift.log`,
  `/tmp/nv-p52-mini-process-final.log`, `/tmp/nv-p52-mini-native-final.log`.
- Orbb: `/tmp/nv-p52-swift.5qHCcp` and `/tmp/nv-p52-native.nbuHn8`;
  local reports `/tmp/nv-p52-orbb-process-final.log` and
  `/tmp/nv-p52-orbb-native-final.log`.
- Ubuntu: `/var/lib/nv-storage-test-volume/nv-startup-scope.M2juR3`;
  local native reports `/tmp/nv-p52-linux-native-complete.log` and
  `/tmp/nv-p52-linux-mutations-final.log`; final Swift build/test/probe reports
  `/tmp/nv-p52-linux-debug-qualification.log`,
  `/tmp/nv-p52-linux-release.log`, `/tmp/nv-p52-linux-release-probe-types.log`
  and `/tmp/nv-p52-linux-types-debug-final.log`; hardening report
  `/tmp/nv-p52-linux-elf.log` and `/tmp/nv-p52-linux-elf-debug.log`.
  The two reclaimed-file inventories
  are `p52-retired-synthetic-databases.nul` and
  `p52-retired-synthetic-databases-second.nul` under
  `/var/lib/nv-storage-test-volume`.

SHA-256 identities for the qualified source/artifacts:

| Item | SHA-256 |
| --- | --- |
| `NVRepositoryFiles.c` | `edf6145165efb03e0aa97b309018f0b4959c0721c49a64440074f1d1ce6fd382` |
| `NVRepositoryRoot.c` | `5adc4b867187277ff6577c12dcbe6bfef5b637150e87e9e507889083c86449da` |
| `NVRepositoryRoot.h` | `59df6da9e1941637ea7c9db547c6e5875d6ff22eaceabc948c8befb13c16f8b2` |
| `RepositoryRoot.swift` | `7950840f006d6ff2bae2725182a9c317528a9ef438b82ded467a153589d97423` |
| `RepositoryObjects.swift` | `e3d587a294e5392ca64094e1b6cc5efa1adae8fc2810bfffe92ad7c262244b18` |
| Intel `NVStorageProbe` | `794f8e760fa39123640266c45156aef0dc847b84dc5ea19b4da6102e67b22652` |
| Intel Swift test bundle | `04850e74069c96f9fc38085d53d0a4b1d9f377cdfcd05b16a57ce50e6678a253` |
| Isolated Orbb concurrency runtime | `8d4c70c66fee1bed34f756942e490a27f34bf31b54e2cd182677058acf22cefb` |

## Exit assessment

All six P5.2 implementation obligations have production witnesses, valid
companions and independent failure observations. Strict compiler and mutation
checks qualify the issuing/consuming boundary; actual native effects qualify
the installation predicates. P5.3 can now connect those distinct proofs through
the real publication/receive caller. Unsupported ExFAT installation, default
macOS 11 distribution and physical power-loss qualification remain explicit
limits rather than passing claims.
