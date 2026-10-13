# P5.1 — Root ownership and independent execution: qualification

Date: 2026-10-10. Status: P5.1 implementation and available-platform qualification complete.
Read the [part plan](01-root-ownership-and-execution.md) and
[caller inventory](00-caller-inventory.md) for the consuming boundaries.
All six P5.1 obligations have production witnesses. Later provider, distribution
and physical-power-loss gates remain explicit below.

## Implemented boundary

`RepositoryRootSession` owns actor-isolated admission, lifecycle and generations.
Its private `RootLane` runs synchronous filesystem turns on a dedicated
`StorageExecutor`, separate from the private database and history resources.
The non-Sendable `RootLease` confines the C owner to that executor and reuses the
existing executor-bound disposal pattern. This adds session-local resources,
rather than persistent records, schemas, wire formats or unchecked Sendable
conformances.

The C owner opens an existing final directory without following it, obtains
nonblocking exclusive directory-object flock and rechecks physical selection.
Component-wise acquisition/revalidation supports paths beyond `PATH_MAX`.
It retains the directory descriptor, local device/inode and an object-bound
loss-event resource: kqueue on Darwin, inotify on Linux. Delivered deletion,
revocation/unmount or lost-watch evidence stays latched. Absence of an event
does not establish provider completeness or continued logical association.

Rooted metadata observations reject unsafe relative components, traverse child
directories without following symlinks, and close only their own borrowed
descriptors. Ordinary child errors preserve ownership. A failed retained-root
check fences the session. Successes, ordinary errors, root-loss errors and delayed
continuity comparisons all recheck their admission generation after suspension.

The closed lifecycle is active, fenced, closing or closed. A positively equal
candidate can restore admission to the same retained directory; unavailable or
different candidates leave it fenced. Quiesce invalidates admission and joins
entered turns while retaining the physical lock. Close invalidates before joining
and releases the owner exactly once. Cancellation before admission starts no turn;
an entered turn retains its resources until actual completion. Controller handoff,
concurrent close and final disposal preserve continuous ownership.

`RepositoryRootPermission` and `RepositoryEntryObservation` have file-private
constructors. Consumers check the issuing session and generation. A permission
is distinct from local action capture or acceptance evidence. Exact bytes,
installation, logical root association and Apple coordination are subsequent
consuming boundaries, not claims made by this metadata reader.

Contract basis: [normative ownership](../../../iCloud-Drive-Support-Spec.md#storage-identity-and-ownership),
[ADR-0006](../../../adr/0006-retain-positive-association-and-directory-ownership.md),
[ADR-0010](../../../adr/0010-separate-local-durability-from-provider-work.md),
TC-ROOT-01 / TC-STATIC-01–04 and the P5.1 portion of TC-LIVE-01 / TC-ASY-01.
Apple's [flock contract](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html)
defines shared lock lifetime for duplicated descriptors; closing a borrow preserves
the owner, whereas explicitly unlocking it would release the shared lock.
Swift's [actor contract](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)
permits interleaving at suspension, so admission reservation and consuming
post-await checks remain necessary.

## Requirement-to-witness map

| P5.1 obligation | Production witness and independent observation |
| --- | --- |
| Continuously own the physical root | Independent native flock and exec contenders; child/scan descriptor closure; same-object move and controller handoff; exact final close; pipe-confirmed holder kill/reacquisition. |
| Separate private and repository ownership | Actual root and SQLCipher private-store contenders are rejected independently, for both profiles; success on one resource cannot authorize the other. |
| Scope effects to current physical authority | Wrong-session permission, stale success/error/root-loss completion, delayed stale comparison, unsafe components, final symlinks, permission failure, and old-path replacement with identical collection-identity bytes. Original and replacement bodies are inspected independently. |
| Keep blocking repository work independent | Hold the actual root executor while public Runtime bootstrap/save/barrier/quiesce/fresh reopen finish for both profiles. A second root turn reports busy. No passing run uses the release backstop. |
| Fence lost/unknown continuity | Real empty-root replacement; inaccessible/different candidate; actual forced detach/remount on five filesystems. The old owner stays fenced after remount, and closing it cannot release a new owner's lock. |
| Join entered work and dispose exactly | Pre-admission cancellation; cancellation/invalidation during held work; quiesce waits while retaining exclusion; repeated concurrent close; abandoned owner cleanup; exact C directory/event close counts and descriptor baselines. |

## Executed evidence

Primary host: arm64 macOS 26.6.2 (25G83), Apple Swift 6.4
(`swiftlang-6.4.0.34.1`). Counts below distinguish test functions from parameter
instances; a selected test reporting unsupported would not qualify the behavior.

| Check | Result |
| --- | --- |
| Debug and optimized affected actor/copy/root suites | 23 functions / 46 instances pass in each configuration, including all 18 root functions / 33 instances. Existing acceptance, repository copy, recovery copy and current-only export retain their outcomes. |
| Optimized independent-process driver | All six witness groups pass against the final production probe, including a real directory scan, kill/reacquire, same-ID path replacement, empty-root replacement and paths beyond PATH_MAX. |
| Compiler construction/isolation probes | All 20 ordinary/same-module outcomes pass against each of the debug and optimized modules. Valid companions, exact diagnostics, marked source lines, strict concurrency and strict memory-safety checks are required. |
| Fifteen isolated mutations, primary Darwin host | Passing real companion and nonzero discovery; every mutant fails at its designated runtime assertion. Compilation errors and timeouts do not count as targeted failures. |
| Final Runtime Thread Sanitizer run | All 18 root functions / 33 instances pass in 15.177 seconds with no reported race. The Runtime/root bridge is instrumented; this does not claim a fully TSan-instrumented vendor SQLCipher archive. |
| Final SQLCipher Address Sanitizer campaign | All 18 root functions / 33 instances pass with the ASan SQLCipher archive. The archive's instrumentation and the independent SQLCipher use-after-free positive/negative controls pass. |
| Strict native C boundary | Warning/conversion/alignment diagnostics, static analysis and Address/UndefinedBehavior Sanitizers pass. 64 owner cycles, each containing 64 successful/unsafe/missing reads, return to the exact descriptor baseline. Unsupported flock and event-allocation-after-lock failures unwind ownership. Directory and event resources each close exactly once. |
| Five native volume lifecycles | APFS, case-sensitive APFS, HFS+, case-sensitive HFS+ and ExFAT all pass actual forced detach/remount, filesystem/case-sensitivity checks, latched old-root fencing, fresh ownership and independently checked surviving bytes. |
| Intel macOS 14.8.9 (23J631) | All 18 Swift root functions / 33 instances pass, including held work, independent local durability and quiesce. Final-production independent-process checks and native C analysis/sanitizers pass. |
| Intel macOS 11.7.11 (20G1443) | Final-production independent-process checks and native C analysis/sanitizers pass using the documented compiler/runtime variant below. The full Swift Testing framework requires macOS 14. |
| Ubuntu arm64 26.10, Swift 6.4 | Corrected optimized root suite: all 18 functions / 33 instances pass in 0.397 seconds, including held local durability and quiesce for both profiles. All six process-witness groups, all 20 strict ordinary/same-module compiler outcomes, and native C analysis/sanitizers/failure/close/baseline checks pass. Synthetic root fixtures use /tmp on tmpfs. Earlier optimized quiesce failure and a compiler timeout are excluded from positive evidence. |
| Existing local-lane TLA+ configuration | Unchanged LocalDurabilityLaneIndependence exhaustive check passes: 64 states, including local progress without provider fairness. Concrete executor wiring is checked by the held-root production tests. |
| Application build | xcodebuild install passes with the existing explicit __DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO argument. The 11.5 deployment warning remains. Application interaction code is unchanged. |

### Findings corrected during qualification

**Retained metadata did not prove namespace continuity.** A draft empty-root-loss
test returned ENOENT rather than ESTALE on APFS. Native inspection showed that
fstat still reported link count 2, while openat/F_GETPATH could still address the
unlinked directory. This was an incorrect inference from retained metadata, not
an Apple contract violation. The implementation now retains an object-bound
loss watch, and the real empty-replacement and five-volume loss tests require
fencing. Event delivery supplies negative evidence; quiet events do not prove
positive completeness.

**An empty actor method was insufficient as an optimized settlement barrier.**
The optimized Linux test caught quiesce returning before a held filesystem turn.
The settlement method now performs the existing executor isolation check,
establishing an observable queue turn. The requirement that quiesce wait and keep
the lock is unchanged. Its targeted mutations separately omit the join or release
the owner too early.

**Expensive cryptographic fixture construction belonged before timed schedules.**
A TSan stack sample showed Argon2 bootstrap wrapping, rather than blocked root
work, consuming the test interval. Immutable fixtures are now prepared once per
profile before entering controlled schedules. Actual SQLCipher creation, saving,
barrier and reopen still occur while the root turn is held. Production encryption,
the 20-second emergency release and 60-second test limits are unchanged.

**Negative controls must terminate independently.** The shared-executor mutant
could also block the delayed-comparison test before its controller released the
turn. That test now has the same explicit release backstop and asserts that it
was unused. The mutation runner classifies timeout separately even if an assertion
was printed; all fifteen final verdicts are actual designated failures. This
improves harness reliability rather than accepting stalled execution as evidence.

Earlier build/compiler watchdog expiries, missing testing-loader dependency and SIP-stripped launch
environment are excluded from successful evidence. No safety assertion or
production contract was weakened to accommodate them. Both final macOS and Linux
compiler suites pass on unchanged retries, retaining the 90-second per-probe
watchdog and all diagnostic/source-line checks.

### Intel execution and macOS 11 distribution boundary

The final production probe cross-build retains Swift 6 concurrency/memory-safety
checks and the existing
`-disable-concrete-type-metadata-mangled-name-accessors` compiler variant.
Its Mach-O minimum remains 12.0 despite the requested 11.5 triple, so the default
macOS 11 distribution gate remains separately unqualified. Actual execution on
11 succeeds with an isolated `libswift_Concurrency.dylib`, SHA-256
`8d4c70c66fee1bed34f756942e490a27f34bf31b54e2cd182677058acf22cefb`.
No system runtime was replaced.

The process driver sets `--probe-env DYLD_LIBRARY_PATH=...` directly on each
child because SIP can strip an outer environment through protected system Python.
This matches Apple's
[runtime protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html).

On the Mini, `tests/StorageSwiftTestingLauncher.c` loads the actual cross-built
test bundle's main entry point, with the matching Testing framework/interoperability
library staged in the temporary fixture. This follows
[SwiftPM's testing-helper entry point](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/swiftpm-testing-helper/Entrypoint.swift);
the launcher does not reimplement assertions. Its bundle uses the final production
sources and all positive tests. It predates only the last test-control addition:
the delayed-comparison emergency-release backstop, subsequently qualified locally
by the final debug/optimized, sanitizer and mutation runs.

## Reproduction and artifacts

Use a writable compiler cache where necessary. SwiftPM's disable-sandbox option
changes subprocess launch conditions; language/access-control/runtime checks stay
enabled. One build job avoids competing memory-heavy optimized builds.

Current source-file selections use declaration names from the checked test
catalogue. They preserve every selected function and its parameter matrix after
the test-target partition. The result counts above remain dated campaign evidence.

```sh
python3 tools/generate-test-index.py --check
NV_ROOT_FILTER=$(python3 -c 'import json,sys; rows=json.load(open("docs/test-index/catalog.json"))["entries"]; names=[r["name"] for r in rows if r["kind"]=="swift" and r["source"].rsplit("/",1)[-1] in sys.argv[1:]]; assert names; print("|".join(names))' RepositoryRootTests.swift)
NV_ROOT_COMPANION_FILTER=$(python3 -c 'import json,sys; rows=json.load(open("docs/test-index/catalog.json"))["entries"]; names=[r["name"] for r in rows if r["kind"]=="swift" and r["source"].rsplit("/",1)[-1] in sys.argv[1:]]; assert names; print("|".join(names))' ActorAcceptanceTests.swift RepositoryCopyTests.swift RepositoryRootTests.swift)
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS="--disable-sandbox --jobs 1 --no-parallel --filter \"$NV_ROOT_FILTER\""
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS="--disable-sandbox --configuration release --jobs 1 --no-parallel --filter \"$NV_ROOT_FILTER\""
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS="--disable-sandbox --configuration release --jobs 1 --no-parallel --filter \"$NV_ROOT_COMPANION_FILTER\""
make -C tests run-swift-storage-root-process
make -C tests run-swift-storage-root-process SWIFT_STORAGE_ROOT_BINARY=../NVStorage/.build/release/NVStorageProbe
make -C tests run-swift-storage-root-types
make -C tests run-swift-storage-root-types SWIFT_STORAGE_ROOT_MODULES=../NVStorage/.build/release/Modules
make -C tests run-swift-storage-root-c
make -C tests run-swift-storage-root-volumes SWIFT_STORAGE_ROOT_BINARY=../NVStorage/.build/release/NVStorageProbe
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --jobs 1 --filter "$NV_ROOT_FILTER"
env PKG_CONFIG_PATH="$PWD/NVStorage/.deps/sqlcipher/lib/pkgconfig" swift test --build-system native --disable-sandbox --package-path NVStorage --scratch-path NVStorage/.build-thread-sanitizer --sanitize thread --jobs 1 --no-parallel --filter "$NV_ROOT_FILTER"
python3 tools/test-storage-runtime-mutations.py --disable-sandbox --jobs 1 --only root-omitted-lock --only root-borrow-unlocks-owner --only root-matching-path-as-identity --only root-omitted-session --only root-omitted-completion-fence --only root-shared-local-executor --only root-unavailable-restores-admission --only root-close-reports-before-settlement --only root-stale-read-error --only root-omitted-loss-event --only root-loss-without-fencing --only root-stale-loss-error --only root-stale-continuity --only root-quiesce-skips-settlement --only root-quiesce-releases-owner
```

The ASan command requires the instrumented dependency prefix built by the existing
sanitizer/dependency procedure. The Mini's retained test bundle is invoked with:

Compute the checked selector in that host's repository shell before changing
directory, or pass its exact value into the remote shell. Shell variables are
local to their shell; the invocation below requires a populated root selector.

```sh
cd /tmp/nv-phase51-complete.x78PgF
env DYLD_FRAMEWORK_PATH="$PWD" DYLD_LIBRARY_PATH="$PWD" ./nv-phase51-testing-launcher --test-bundle-path ./NVStoragePackageTests.xctest/Contents/MacOS/NVStoragePackageTests --testing-library swift-testing --no-parallel --filter "${NV_ROOT_FILTER:?set the checked root selector in this shell}"
```

Final artifact directories, under the primary host's temporary directory unless
otherwise stated:

- `nv-runtime-mutations-dibhyshh`: fifteen designated failures, companion logs,
  exact patches, source manifest and timeout-classification self-test.
- `nv-cipher-sanitizer-py6s0q_4`: final ASan archive/control/runtime results.
- `nv-root-volumes-jtu3ij6g`: all five actual filesystem observations and device
  commands; fixtures are retained and all mounted images were detached.
- `nv-root-process-w9rja8st`: final optimized local process witnesses.
- `nv-segment-tlc-5ejrs357`: unchanged local-lane exhaustive run.
- Mini: `/tmp/nv-phase51-complete.x78PgF`, including
  `root-swift-suite-qualified.log`, `process-final.log`, `c-native.log`;
  process artifact `nv-root-process-0ffjaucl`, C artifact `nv-root-c-jzhtxzfa`.
- Orbb: `/tmp/nv-phase51-complete.Lufi9V/process-final.log` and
  `c-native.log`; process artifact `nv-root-process-mp8rdfoo`,
  C artifact `nv-root-c-_v7obnmr`.
- Ubuntu: `/tmp/nv-phase51.Ltzplu`, final qualification logs; owned build/source
  tree `/var/lib/nv-storage-test-volume/nv-startup-scope.M2juR3`.
  Logs: `linux-root-final-qualified.log`, `linux-process-final-qualified.log`,
  `linux-c-final-qualified.log`, `linux-types-final-qualified-retry.log`.
  Process artifact `nv-root-process-zjouni_g`, C artifact `nv-root-c-mwjzxvy3`,
  compiler artifact `nv-root-types-l3s2ryju`. Earlier source archives and the
  excluded first compiler-timeout log remain preserved.

Final SHA-256 identities:

| Source | SHA-256 |
| --- | --- |
| C root implementation | 7e32bc26fb64187e8890114efbd3de36ae8f9d2d221fcb148e8a29ce2169f336 |
| Runtime root implementation | c656fe6ee2e94d6e8fc4550e8ee4e7f7858b63d1d4395e2f32999ccf6981f113 |
| Shared database/executor implementation | a57d8134ccd17acba62d55d28499eb193b2d630d1dda695d6d9ad072db7306dd |
| Final root test source | 3ab8184314984213a31f53765934e7a944601fd26a0d02fec46059cc1455d4f4 |
| Mini test source before the bounded-control-only addition | 73acc4bca830537e58d6569b62b0bfbe0a95c89349ad73ad2a0faf01ad1bb71c |

The mutation manifest binds the complete package to its results. Recovery tests
receive ordinary surviving-store inputs, rather than these expected-result logs.

## Later qualification boundaries

P5.2 supplies bounded exact bytes, enumeration and strict immutable installation.
P5.4 supplies actual Foundation accessors/presenters, materialization and live
provider events. P5.5 connects logical collection/private-store association and
Retry/Re-open. Cold dataless roots, remote-origin events, additional provider/network
filesystem capability, default macOS 11 distribution and physical power loss
remain explicit later qualification, not implied by local root ownership.

The implementation enforces existing ownership/lane/lifecycle policy.
Normative semantics, ADR decisions, encoded formats and TLA+ transitions remain
unchanged; model correspondence now links the concrete held-root witness.
