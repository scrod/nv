# Phase 2 platform, type-boundary and model audit

Date: 2026-09-14. Follow-up to [Phase 2 validation](phase2-local-runtime-validation.md).
This qualifies the ordinary-history development slice, not a shipping provider
engine, arbitrary-history refinement proof or physical power-loss guarantee.

Subsequent [zstd and compiler-diagnostic qualification](zstd-codec-validation.md)
records the adopted new codec, fresh platform checks and the resolution of the
diagnostic mismatch described below. This document's earlier counts are retained
as evidence of that original campaign, not claims about changed codec bytes.

## Executed platform checks

| Machine | Actual execution | Result and boundary |
| --- | --- | --- |
| Intel VM, macOS 11.7.11 (20G1443) | Optimized x86_64 `NVStorageProbe`, deployment target 11.5; SQLCipher 4.19.0/CommonCrypto; bundled Swift concurrency backdeployment library | All 72 fresh-process checks passed, both profiles. All 46 resulting SQL/envelope reports independently verified afterward. This is actual macOS 11 execution, not execution through Rosetta. The exact 11.5 point release was not available. |
| Intel Mac Mini, macOS 14.8.9 (23J631) | Same optimized x86_64 probe and pinned cipher | All 72 fresh-process checks passed, both profiles; all 46 independent inspections passed. |
| arm64 Ubuntu 26.10 development VM | Initially Python/system SQLite; subsequently native Swift 6.1.3, Swift Crypto 4.5.2 and SQLCipher 4.19.0/OpenSSL 4.0.1 | Initial 17 schema tests and four Python fixture entrypoints passed. After the fixes below, all 72 Swift tests passed in debug and release. Each configuration passed all 72 fresh-process checks and 46 independent inspections, both profiles. The optimized process campaign used ext4; debug used tmpfs. The separate Runtime compiler-probe diagnostic mismatch is recorded below. Physical power loss remains unqualified. |

The Intel executable was built locally with Swift 6.3.3 and SDK 26.5. Its Mach-O
deployment target is 11.5. The macOS 11 VM's Swift 5.5.2 cannot build this Swift 6
package; the Mini's Swift 6.0.3 cannot resolve the currently pinned Swift ASN.1
1.7.2 manifest, which requires tools 6.1. No dependency was silently downgraded.
The package's Swift language mode, compiler/tool dependencies and runtime minimum
are separate requirements.

`tools/build-storage-cross-macos.py` builds the pinned, previously generated
SQLCipher amalgamation for Intel in a fresh `/tmp` directory. It records the
source revision, hashes and compiler arguments; it uses no configure/make cleanup
or system installation. SwiftPM's cross build used:

```sh
PKG_CONFIG_PATH=/tmp/<cross-build>/lib/pkgconfig swift build \
  --package-path NVStorage --scratch-path /tmp/<cross-build>/swift \
  --triple x86_64-apple-macosx11.5 -c release --product NVStorageProbe
```

The deployed bundle contains the executable, its schema resource bundle, Apple's
`libswift_Concurrency.dylib`, test scripts and synthetic fixtures. It contains no
real note collection, credentials, Git history or private application database.
No sudo, filesystem cleanup or `rm` command was used in that initial remote campaign. All test
artifacts remain under `/tmp`. Synthetic WAL-tail truncation and directory
move/return are intentional fault scenarios; neither touches user files.

The remote process runner used `--defer-independent-inspection`. This explicitly
leaves cryptographic inspection pending while preserving a distinct report for
every verification point, including multiple generations of the same case.
`tools/inspect-storage-process-artifacts.py` subsequently required all 72 scenario
records and ran the unchanged independent Node/OpenSSL inspector on all 46 reports
per host. The production recovery child never receives these reports or the
parent's expected-note oracle. A missing or failing inspection prevents this
second-stage pass; deferred execution is not a waived assertion.

Retained evidence for this run:

- Local build and independently checked reports: `/tmp/nv-storage-intel-t1jzy9tx/`.
- macOS 11 final harness: `/tmp/nv-storage-platform.XwIx4b/final/`; generated stores:
  `/tmp/nv-storage-process-4kt98zgb/`.
- Mac Mini final harness: `/tmp/nv-storage-platform.AtcdPd/final/`; generated stores:
  `/tmp/nv-storage-process-7p4rs3_q/`.
- Ubuntu harness/results: `/tmp/nv-storage-platform.NoGzum/`; each schema case logs
  its retained `/tmp/nv-sqlite-schema-*` directory.

### Ubuntu toolchain installation follow-up

The user authorized development-tool installation and source transfer, then
expanded the VM to 2 GB RAM and 10 GB disk. Swift 6.1.3 (Ubuntu package), its
bundled Clang 17, GCC/G++ 15, make, pkg-config, OpenSSL 4.0.1 development headers
and zlib development headers are now available. There is no swap; `/tmp` is a
973-MB tmpfs. Test source, build outputs and synthetic stores use `/tmp` paths.
After its per-user quota blocked a compiler-probe run, a new, dedicated directory
at `/var/lib/nv-storage-test-volume` was bind-mounted at `/tmp/nv-storage-disk`.
This uses the VM's ext4 root volume; it leaves the existing tmpfs and its files
unchanged. The final optimized process campaign used this disk-backed directory.
The mount and synthetic artifacts remain available; no cleanup was performed.

Before expansion, GCC was killed during both optimized and diagnostic SQLCipher
compilation. The upstream generation step performed its own temporary-source
cleanup; no application data was involved. The user's subsequent reboot cleared
that tmpfs workspace. After expansion, direct `gcc -O2` compilation of the
revision-checked amalgamation succeeded. All later attempts use direct
compilation, without make or cleanup commands. The pin remains
`c4b275a47932888216bade83aff2bbc73df0ff85`; the amalgamation/header SHA-256 values
match the Intel campaign. No system SQLite fallback is used.

The native run exposed three real portability defects:

1. Strict C11 hid the ownership helper's POSIX declarations on glibc. The helper
   now selects `_XOPEN_SOURCE=700` on Linux. Its original strict diagnostics pass.
2. Swift Crypto 3.15.1's Linux `SymmetricKey` lacked `Sendable`. The package now
   pins upstream 4.5.2, revision `da9d28d69ebe3894b18376c8f2395c2f37b8448f`, which
   supplies that conformance. There is no NV `@unchecked Sendable` workaround or
   `@preconcurrency` suppression. The added cross-task envelope test and original
   independent crypto fixtures execute on both platforms.
3. Swift 6.1 inferred the raw-key concatenation as a 35-element `[Any]`, selecting
   the optional-returning `flatMap` overload, instead of a 67-byte `[UInt8]`.
   Passing and then wiping that existential buffer caused a runtime crash.
   A minimal compiler reproduction confirmed its type, count and element stride.
   The C-boundary buffer is now explicitly `[UInt8]`; the original encrypted-open
   and fresh-process tests pass without changing their assertions.

These are representation, dependency and compiler-boundary fixes. They change no
storage protocol transition, wire encoding, durability predicate or TLA+ safety
condition. No TLA+ rerun is claimed for this follow-up. Compiler probes preserve
their expected diagnostic text/source-location checks and 60-second deadlines;
their new retention option keeps temporary artifacts.

All 21 native Core construction probes and their diagnostic-classifier self-checks
passed. The original Runtime campaign passed 17 cases, then stopped on a diagnostic wording
difference: Swift 6.1 rejects same-module access to private `HistoryUnit` with
`cannot find 'HistoryUnit' in scope`, at the intended marked source line, whereas
Swift 6.3 reports the expected private-protection diagnostic. This is a failing
harness expectation, not evidence that the type became accessible. After user
approval, the probe accepts either exact diagnostic while retaining the marked
line, required failure, symbol and timeout checks. All 22 Runtime cases now pass
on both compilers in the [zstd follow-up](zstd-codec-validation.md). Four remaining
Runtime probes had not been reached by the original native run.
An earlier timeout under concurrent compiler/test load and the tmpfs quota failure
are setup failures, not qualification passes.

Retained workspace: `/tmp/nv-storage-native.LJFlKR/`; final debug build:
`swift-crypto4-build/`; debug process stores: `/tmp/nv-storage-process-_mg8cjsi/`.
The direct SQLCipher cold-start negative control and valid companion both pass
with OpenSSL; logs are under `/tmp/nv-sqlcipher-cold-start-613qid3v/`.
Native optimized process stores and their 72-scenario result are retained at
`/tmp/nv-storage-disk/nv-storage-process-fg573kd5/`; the runner log is
`/tmp/nv-storage-disk/process-release.log`. The final Runtime compiler log is
`/tmp/nv-storage-disk/runtime-types-final.log`.

The final local macOS follow-up passes all 72 Swift functions in debug and
release, all 72 optimized process scenarios, all 46 independent reports, the
21 Core and 22 Runtime construction probes, the nine targeted runtime mutation
challenges, and the complete optimized qualification driver (14 commands).
The application build also passes. Local logs use the
`/tmp/nv-storage-ubuntu-followup-*` prefix; the final driver preserves its report
at `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-storage-phase2-7mzfmfpf/`.
The independently checked native debug and optimized reports are in
`/tmp/nv-linux-debug-reports/` and `/tmp/nv-linux-release-reports/` on the Mac,
respectively. Each contains all 72 scenario records and 46 separately checked
SQL/envelope reports. Neither tmpfs process recovery nor ext4 process termination
and injected VFS failures establish persistence through host or physical power loss.

## Language-enforced design: what is actually enforced

The implementation follows v2's separation of construction, truthful issuance and
current applicability. It does not implement every future merge/undo capability
named in that proposal, nor does a successful build prove the issuer is truthful.

| Boundary | Actual mechanism | Remaining obligation |
| --- | --- | --- |
| Identifier and edge roles | Distinct collection/store/birth/action/origin/operation/segment types; distinct causal-parent and note-predecessor sets; checked scalars and explicit wire codecs | Correct IDs of the correct role still need semantic validation. |
| Canonical values and operation identity | Bounded intrinsic constructors; explicit canonical field traversal; computed operation IDs; independent literal bytes/hash fixtures | Hashing the wrong semantic fields is caught by fixtures/mutations, not nominal typing. |
| Bootstrap and ordinary acceptance | Exact-byte decode, complete declared-history validation and SQL commit behind the same private acceptance boundary | The private SQL implementation remains trusted to write complete membership, retention and wakeups and to honor the actual database barriers. |
| Snapshot, capture and completion | Store-issued snapshot; immutable captures; file-private `CommitHandle`, `AcceptedHistoryReceipt`, `PreparedModelChange` and settings constructors | Store/session/view/host-generation applicability is checked by the real consumer. Historical success never reinstalls captured text. |
| Async resource ownership | One actor-owned in-flight sealer and one serial database lane; database handles are not Sendable | Two private unchecked Sendable queue containers and reviewed C/pointer adapters remain explicit trusted boundaries. |
| Graph-derived data | Canonical action references and private current-row context plus centralized exact writer-history validation | Canonical reference arrays are not independent certificates of complete scope maxima. Later merge/compensation/contextual capability types remain unimplemented. |

### Defect corrected by this audit

`HistoryUnit` previously had module-internal memberwise construction. The callers
validated first, but unrelated code in the module could assemble a unit and call
`accept` without the intended semantic check, or pair parsed payload A with bytes B.
That was weaker than v2's issuer-only boundary.

`HistoryUnit`, its bootstrap assembler and the raw `accept` function are now private
to `HistoryDatabase.swift`. The module's ordinary entrypoint accepts exact bytes and
the expected locator; it opens and decodes those bytes itself, validates against the
declared retained writer history, and commits within one transaction. Bootstrap
acceptance similarly validates and constructs its unit inside that boundary. The
ready-queue parking/acceptance decision shares that file and transaction. Store/header
context is checked there as well. There is no transferable unchecked history token
or caller-supplied payload/dependency map at the commit boundary.

This preserves the v2 principle without creating a ceremonial public
`DependencyClosedSegment` between two adjacent private calls. The semantic validator
remains the trusted issuer; low-level SQL methods remain part of the trusted storage
implementation. This is language enforcement against accidental authority
construction, not protection against malicious same-module raw SQL or unsafe code.

Ordinary-client and same-module probes now check `HistoryUnit` inaccessibility in
addition to receipt/snapshot/prepared-change construction. All 22 Runtime and 21 Core
compiler cases passed on the development Mac. The native Swift 6.1 diagnostic
difference is recorded above. Valid clients still compile; negative cases require the
intended type/access diagnostic, not an unrelated build failure.

## Implementation-to-model mapping

### Implementation bug exposed by an existing model assertion

`SQLiteFastStartSafety.NoKnownDamagePublication` was stronger than the live Runtime
path: after `retainedObject` reported invalid accepted bytes, a previously prepared
view could still publish because its view generation had not changed. The new
`discoveredRequiredHistoryDamageBlocksPreparedPublication` test first reproduced
that specific forbidden success (two notes returned instead of the required error).
This was an implementation bug, not a reason to weaken the model.

Accepted-object reads and accepted payload/index interpretation now latch the
session's required-history failure. The database lane rejects subsequent publication
or mutation and attempts a separate `history-damage` private-group transaction after
the failing operation unwinds. Reopen checks this marker. Original retained bytes,
pin and settings are preserved for repair; ordinary code cannot reset the marker.
The first failing call retains its precise error. A malformed incoming envelope or
wrong caller locator is not evidence of damaged accepted history, and transient SQL
busy/I/O failures are not relabeled as corruption.

The unit test covers both profiles and validates a successful publication after
rejecting invalid incoming bytes, followed by blocked publication after actual
accepted-byte corruption and blocked reopen. Two additional process cases inspect
the exact committed marker independently and require refusal by another fresh
opener. A ninth Runtime mutation removes the live damage guard and must fail this
specific publication assertion. Marker-write failure or a crash before its commit
can lose the persistent observation, while the live session remains blocked; full
physical-failure qualification of that interval remains open and is stated in
the schema/LocalStore contract. The model's atomic damage event represents durably
recorded knowledge, not proof that every attempted marker survives a crash.

### Correspondence and remaining abstraction boundaries

No adopted storage policy was relaxed to accommodate the implementation. The main
transaction model already anticipated the SQLite mapping. The implementation closes
its concrete validation/commit premise; the model does not prove parsing or SQLCipher.

| Concrete code | Model fact/action | Scope of correspondence |
| --- | --- | --- |
| `HistoryDatabase` validation and atomic acceptance | `SQLiteCollectionSafety` staged writes and `Commit` / `RecoverAccept` | Complete validated input is a model premise; real codecs, exact envelopes, membership and SQL/VFS failures are executable evidence. |
| `drainReady`, object waits and SQL wakeup trigger | Ready work and dependency-closed acceptance before `Recover` | Real receipt order is not causal order; parked objects can become ready after a later acceptance and restart. The model's ready set abstracts eligible work, while the real queue can contain candidates that require rechecking/parking. |
| `materializeBootstrap`, `catchUp`, `snapshot`, `publish` | `SQLiteFastStartSafety` materialization, consistent prepare and fenced publication | A real suffix transaction can cover several abstract batches. Invalid-view rebuild is exceptional; healthy startup is indexed, not full replay. Broader repair/damage lifecycle and the final AppKit publication seam remain development gates. |
| `persist`, exact recovered-identity retry, `HeadlessModel.complete` | `ImmutableSegmentDurabilitySafety` acceptance, `Ack`, crash/recover and pending-generation invariants | Callback delivery is separate from durable commit. Two finite full-state changes abstract exact values; this model does not validate arbitrary action ancestry. |
| Same-origin predecessor validation | Declared writer history and retained action provenance | No global last-arrival origin election was introduced. Later distributed undo models remain requirements for future reducers, not completed implementation coverage. |

One retained model still named its private steps `FileSync`, `InstallName` and
`DirectorySync`. These are now `BeginAcceptance`, `StageMembership` and
`CommitAcceptance`, matching the implemented database boundary. Only the atomic
commit changes stable history. A single-writer guard and separately named
`OneAcceptanceWriter` invariant now match the serial lane; a new `multiWriter`
negative control proves the guard is exercised. Provider file/directory barriers
remain provider obligations, not renamed SQLite operations.

Ran all 14 configurations of `ImmutableSegmentDurabilitySafety`:

- Exhaustive crash safety: 1,229 distinct states.
- Exhaustive fair offline completion: 129 distinct states. Local progress is an
  explicit fairness assumption; no provider fairness was added.
- Eight designated broken-policy counterexamples, including the new single-writer
  control and the unchanged early-ack, lost-pending, pruning and lost-callback checks.
- Four reachability witnesses, each reaching its named outcome. These are witnesses,
  not safety proofs of an intentionally false assertion.

There are no state/depth constraints, symmetry or `VIEW` reductions in this run.
Artifacts: `nv-segment-tlc-6o1il46t` under the local system temporary directory.
Use `check-segment-models.py --model ImmutableSegmentDurabilitySafety` with the
documented Java/JAR arguments to reproduce the family. The nine
`SQLiteFastStartSafety` checks were also rerun to confirm the known-damage obligation:
1,015 states in the exhaustive safe case, five designated mutation counterexamples
and three witnesses, all successful. Its `NoKnownDamagePublication` assertion was
retained unchanged; a comment now names the damage-marker atomicity boundary.
Artifacts: `nv-segment-tlc-l6hrp_8h`. Other models were reviewed as mapping sources,
not rerun or relabeled as full implementation proofs.

After both fixes, all 71 local Swift functions passed in debug and
optimized builds, the full optimized driver passed all 14 commands (including 72
fresh-process checks), all nine Runtime mutants failed at their intended
assertions with a valid baseline, and the legacy application build passed. The
optimized full-driver directory is `nv-storage-phase2-vmb4s44u`; the debug mutation
directory is `nv-runtime-mutations-031wx2n2`. Previous sanitizer results remain
separately dated evidence; this follow-up does not claim a new sanitizer campaign.

Native Linux Swift/SQLCipher runtime execution is covered above; its Runtime
compiler-probe campaign now also passes under the approved exact-diagnostic rule
in the [zstd follow-up](zstd-codec-validation.md). Physical
power failure, complete receive quarantine, resumable large-history processing,
general concurrent reduction/undo, repair activation and provider/application
integration remain qualification or implementation work. Future-feature models
were not narrowed to the currently supported reducer.
