# Swift 6.4 compiler and platform qualification

## Adopted compiler boundary

NVStorage requires Swift 6.4 or newer and explicitly uses Swift 6 language mode.
Core and Runtime enable `strictMemorySafety()` and `treatAllWarnings(as: .error)`
through typed SwiftPM settings. The package retains its macOS 11.5 deployment
target and pinned dependency revisions. Production Core and Runtime use checked
Sendable conformances and actor ownership throughout; their source contains zero
`@unchecked Sendable`, `@preconcurrency` imports or `nonisolated(unsafe)` declarations.

These settings implement the [language-guided design](swift-storage-library-proposal-v2.md#2-compiler-enforcement-and-the-trusted-boundary)
and [issuer/consumer tests](swift-storage-conformance-testing-strategy.md#3-test-the-obligations-not-just-their-names).
The compiler identifies the following manually audited interoperation boundaries:

| Adapter | Ownership and bounds argument | Qualification |
|---|---|---|
| `Argon2idV1` | Initialized password, salt and output arrays are borrowed through synchronous C calls; exact capacities accompany pointers; secret buffers are wiped within the same borrow. | Independent descriptor fixtures, unlock/descriptor tests, C sanitizer campaign. |
| `ZstdFrameV1` | Fixed-capacity array borrows, bounded frame/window checks, exact consumed input and decoded output. | Independent zstd fixtures, malformed-frame and length checks, sanitizer campaign. |
| Bootstrap key wrapping and private database-key derivation | Crypto's synchronous key borrows are consumed or copied while the key owns their initialized bytes. | Independent descriptor/bootstrap fixtures and both database protection profiles. |
| `RecoveryKeyV1` | A checked 256-bit key supplies 32 bytes; bit indices are bounded during its synchronous borrow. | Independent recovery-key fixtures and typo/malformed-input cases. |
| `Database` | Private connection/directory handles stay with the actor-owned connection. SQLite copies transient bindings; column data becomes owning Swift values before statement advancement/finalization. | Actual key-call compiler challenge, owned-directory tests, independent fresh-process histories, SQLCipher ASan. |
| `StorageExecutor` | Actors retain their executors; enqueued jobs retain the executor until execution. Final disposal borrows a nonescaping callback through a synchronous queue hop. | Checked-storage/escape compiler challenges, disposal/reopen tests and sanitizers. |

`@safe Database` documents its encapsulated pointer ownership. Local `unsafe`
expressions identify individual C/crypto/executor uses. These markers preserve
the obligation to audit C contracts and pointer lifetimes; they supplement the
runtime/fault tests rather than certifying C library internals.

The two lock-protected test gates retain their existing test-only unchecked
conformances. Their controlled pauses qualify actual production consumers.

## Compiler challenges

Core's ordinary-client and same-module probes now run with strict concurrency,
strict memory-safety checking and warnings as errors. Runtime has 68 construction
and isolation probes, including valid companions and these actual-source challenges:

- Add mutable storage to `StorageExecutor`: require the checked-Sendable error.
- Require Sendable transfer of its private final C-handle value: require rejection.
- Change `synchronizeRelease` to `queue.async`: require either the escaping-capture
  error or Linux's exact non-Sendable `release`-capture error at the marked line.
- Schedule that actual release through an escaping `DispatchWorkItem`: require
  the nonescaping-parameter error on both platforms, independently of Dispatch's
  Sendable annotations.
- Omit `unsafe` at the SQLCipher key borrow: require the memory-safety error at
  the marked call.

Directly replacing the original inline cleanup `queue.sync` with `queue.async`
produced an SDK-downgraded warning, even with global and diagnostic-group warning
promotion. A noncopyable-value prototype still allowed that escaping capture.
Neither experiment qualified hard enforcement. The adopted nonescaping helper
produces a language-level escaping-capture error; its positive companion compiles.
Linux's direct asynchronous overload first reports a hard Sendable-capture error.
Both exact diagnostics are recognized at the marked line; the separate work-item
challenge requires the lifetime error on both platforms. Compiler setup failures,
wrong lines, other messages and zero exit status remain failed challenges.

## Platform checks

The macOS host uses Apple Swift 6.4 (`swiftlang-6.4.0.34.1`) on arm64 macOS 26.6.2.
Final debug and optimized suites passed after enabling memory-safety errors
(138.584 and 62.116 seconds respectively). All 31 Core and 68 Runtime compiler
probes passed. The targeted final SQLCipher-instrumented ASan run covered the
disposal and command-worker paths with both protection profiles; its independent
heap-use-after-free control confirmed that the cipher archive was instrumented.
Swift Testing lists 160 functions including the disabled opt-in benchmark; 159
active functions execute. Thirty abandoned orderly exits per profile, normal
quiescing companions and repeated failed-close cases passed 74 independent
fresh-process history inspections.

The Ubuntu arm64 VM now uses the official Swift 6.4 release for Ubuntu 26.04,
installed at `/opt/swift-6.4.0-ubuntu26.04-aarch64`, on Ubuntu 26.10. The obsolete
Swift 6.1 compiler package was removed through its package manager; no unchecked
Dispatch-key wrapper was introduced. Archive SHA-256:
`f025192dc013174524d9dc7f76a999b1ab5e1e46af8fd9893b6d5d4cc3d510bc`.
The official detached signature verified. Its signing key was valid at signing
and expired afterward; verification retained that warning. Current official key
material reported no revocation.

Linux's complete debug inventory passed: all 159 active Swift Testing functions,
with the same disabled opt-in benchmark as macOS. The first complete run compiled successfully
but failed command-worker scheduling assertions on the one-CPU VM and later hit
write errors in its quota-limited RAM-backed `/tmp`. A separate, disk-backed
single-function run reproduced the command pause exhausting the shared Swift
task executor before a competing save could complete. The implementation uses a
short-lived actor with a dedicated executor for each frozen calculation, retaining
the same cancellation, closure/header checks and captured-prefix fence. The
existing assertions and time limits remain unchanged. All three unchanged
command-scheduling functions (18 parameter combinations) passed on this one-CPU
VM after the correction. Full-inventory checks run sequentially in fresh,
disk-backed temporary batches, with exact discovery and completion checks.
All 31 Core and 68 Runtime construction/isolation probes passed, including the
independent lifetime challenge. Strict owner/fault-adapter C diagnostics passed.
The actual Linux test executable passed PIE, W^X, non-executable-stack and RELRO
inspection; a deliberately writable code mapping failed its designated check.
The final process probe passed the same permission checks. Both profiles passed
30 abandoned orderly exits, normally quiesced companions and repeated failed-close
cases: 74 complete reports independently inspected from exact retained history.

Kernel logs identified compiler processes killed for memory exhaustion during
the final build. Temporary disk-backed swap allowed the test executable to link;
the separate process probe built after omitting debug symbols (`-gnone`), keeping
strict concurrency, actor checks and the package's memory-safety/error settings.
Its optimization level remains debug. The larger swap file was released and
emptied before rerunning the growing-history workload, which had exhausted the
remaining disk space. Successful batches cover the complete inventory; earlier
resource-failed runs remain separate artifacts. SwiftPM's zero exit status
accompanied by `Build cancelled!` is recorded as a failed build, never as
successful qualification.
The temporary swap files were deactivated and emptied after qualification; no
system startup configuration was changed.

The default SwiftBuild backend also failed to install a probe object file. Linux
checks continue through the existing documented native backend, pinned SQLCipher,
bundled lld and ELF permission checks. That default-backend run remains a failed
tooling experiment, separate from compiler/runtime qualification.

## Artifacts and scope

Host logs are under `/private/tmp/nv-swift64-upgrade/`; Linux logs/builds are under
`/tmp/nv-storage-disk/`. Sanitizer and process runners print their independent
artifact directories. The final artifacts include:

- macOS: `local-final-debug.log`, `local-final-release.log`,
  `local-final-types2.log`, `local-final-core-types.log`, `local-final-asan.log`
  and `local-final-release-command-mutation-escalated.log`. Both debug and
  optimized owner-blocking mutations failed at their intended `gate.held`
  assertion; their valid companions passed.
- Linux: `swift64-debug-batches2/batch-00.log` through `batch-09.log`
  (111 functions) and `swift64-debug-remaining/results.json` (48 functions).
  Their disjoint union covers all 159 active names from the independently captured
  full inventory; each successful batch requires matching discovery, completion
  and nonzero test count.
- Linux compiler probes: `nv-swift64-final-runtime-types2.log` and
  `nv-swift64-final-core-types2.log` (68 and 31 probes).
- Linux process probe: `nv-swift64-final-probe-gnone-build.log`,
  `nv-swift64-final-disposal.log`, `nv-swift64-final-disposal-inspection.log`,
  `nv-swift64-final-probe-elf.log` and
  `swift64-temporaries/nv-disposal-process-d1syyzb9/inspections.json`.

`build.sh` rejected Xcode 27's older deployment-target range. The identical app
build passed with `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO`, retaining
the deployment warning and original target. App interaction code is unchanged.

Actual execution of the final binary on the unavailable Intel macOS 11/14 hosts,
physical power loss and provider/UI integration retain their separate qualification
requirements. Linux optimized execution and Linux sanitizer instrumentation were
not repeated in this upgrade campaign; optimized execution and the targeted
instrumented-cipher campaign passed on macOS. Encoding, acceptance, conflict,
deletion and compensation policies
are unchanged; no TLA+ behavior or safety condition was weakened for this upgrade.

Compiler references: [strict memory safety (SE-0458)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0458-strict-memory-safety.md),
[typed SwiftPM setting](https://developer.apple.com/documentation/packagedescription/swiftsetting/strictmemorysafety(_:)),
[custom executors (SE-0392)](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md).
