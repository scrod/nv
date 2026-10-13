# P5.4 — Implementation and qualification ledger

Updated: 2026-10-12. Status: P5.4 A–F implemented and qualified within the explicit
platform/capability limits below. The final-source signed two-Mac exchange passes
both profiles, including independent byte/history inspection and fresh reopening.
The user-approved fresh deep-HFS+ opening limitation is aligned across the
specification and separately qualified safe-refusal tests. Distribution signing,
physical power loss and unavailable supplemental stimuli keep their separate gates.
The [plan](04-apple-coordination-and-discovery.md) defines completion;
the observations below qualify only their named consumers.

## Landed effects and lifecycle boundary

The Darwin root executor now runs real synchronous coordination around bounded
metadata, exact reads, add-only directory creation, private stage preparation and
final two-URL installation. Each actual accessor URL is checked against the
continuously held native root. A retained opaque CF file reference follows the
held object after a move. Physical acquisition checks, rather than textual path
equality, handle `/var` aliases and reject replacement objects. Resolution of an
expanded pathname is distinct from use of that retained reference.

Stage consumption uses source `forDeleting` and ordinary destination writing.
A file-private, noncopyable `RootPreparedStage` retains the verified native
descriptor across preparation/install grants. Its exact identity and bytes are
checked again before exclusive rename. Metadata-only provider changes between
grants preserve the binding; fresh before/after read and final namespace checks
remain strict. This
avoids treating an internal disposable stage as a presented user-document move.
The split retains the existing readback, file, directory and hardware barriers.
It requires separate live-provider qualification; a directory grant is never
assumed to exclude arbitrary child changes.

One presenter has an independent reply queue and synchronized URL snapshot.
All mutable admission state remains actor-isolated. The two narrow synchronized
cells use NSLock: the presented NSURL lives in the internal conditional Objective-C
target, and only the Swift coordinator cancellation cell uses `nonisolated(unsafe)`.
Production introduces no `@unchecked Sendable`. The coordinator cell exposes only Apple's documented
cross-thread `cancel` capability. Entered effects retain resources until return;
logical invalidation and private saving remain independently runnable.

## Executed local witnesses

- Debug strict Swift 6.4: `repositoryCoordinationCancellationBeforeEntry` and
  `repositoryCoordinationEnteredReadPreservesEditDeleteAndReopen`, four parameter
  cases across two tests, passed. The real accessor-entry hook runs inside the
  Foundation callback. Cancellation before entry yields ECANCELED and zero native
  read entries. An entered read can remain held through local edit, Delete,
  private-store reopen and root close; a contender remains excluded until return.
- `repositoryPresenterRegistrationGettersAndLateReplies` passed: concurrent URL
  getters, balanced registration, late callbacks and exact reader/writer/save/
  deletion replies. Separate external-process write/move and actual presenter
  opportunity checks pass through `test-storage-apple-peer.py` (initial witness
  `/tmp/nv-p54-peer.log`). The eviction companion acknowledges exactly once,
  unregisters, rejects old permissions and re-registers only after positive
  same-root revalidation; its macOS 14.4 guard preserves older runtime support.
- Thirteen focused root/file/metadata/lifecycle regression tests passed, including
  same-object root moves, 519-entry listing, buffered-tail changes, foreign
  occupants and local durability while root work is held.
- `python3 tools/test-storage-immutable-files.py --sanitize address,undefined`
  passes the full final-source campaign (`/tmp/nv-p54-final-immutable-cuts.log`):
  28 I/O/barrier schedules, 31 pipe-confirmed process cuts with fresh exact retry,
  three repeated crash/write-failure/crash/recovery schedules, coherent-read and
  foreign-occupant companions, and all three observer-defect controls.
- `python3 tools/test-storage-coordinated-install.py --sanitize address,undefined`
  passed 23 split-install scenarios. Independent namespace/barrier observations,
  changed stage/parent checks, eleven I/O schedules and three killed-process cuts
  preserved exact retry input and prohibited installation into replaced context.
  Native split effects are qualified here; Foundation scheduling is exercised by
  the separate Swift consumers above. Added cases preserve same-size changed
  bodies, extra hard links and displaced equal-byte stages, while accepting a
  metadata-only change to the continuously held object.

Two diagnostics found during implementation were application mistakes, not
Apple contract violations: Swift URL bridging discarded file-reference behavior,
and lexical prefixes rejected physically equal `/var` aliases. The retained CF
reference and native comparison fix those seams. Long-path process witnesses
and both-profile immutable installations pass (`/tmp/nv-p54-reference-process.log`).
Those long-path observations concern the tested APFS host, not every filesystem.

## Foundation volume follow-up and approved deep-HFS+ limitation

The final production root-volume rerun passed APFS/APFSX but failed ordinary
HFS+ acquisition with `ESTALE` (`/tmp/nv-p54-final-root-volumes.log`, artifacts
`/private/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-root-volumes-zkxdomz1`).
Foundation converted the descriptor alias to a reference with the wrong resolved
location. The physical comparison correctly refused it. The earlier P5.1 native
volume results remain native evidence; they did not qualify this newer Foundation
seam.

The corrected issuer tries the selected path only as another candidate after an
unusable descriptor reference. Both the candidate and its resolved system
reference must positively match the continuously owned directory. The Swift
caller captures the diagnostic before closing resources. A same-type unrelated
candidate probe permits only rejection or the independently held root. The
production volume driver now also moves the owned root, recreates its old name
and checks exact original reads and replacement preservation before detach.
The corrected production adapter passes ordinary APFS, APFSX, HFS+, HFSX and
ExFAT move/read/replacement/detach/remount checks
(`/tmp/nv-p54-hfs-fix-volumes.log`). Static analysis and ASan/UBSan also pass the
actual local and selected-HFS+ preparation/install companions
(`/tmp/nv-p54-hfs-fix-stage.log`). These are short-path qualification results.

The stronger production deep-path test narrows the remaining issue: an already
owned HFS+ root survives a move to a pathname longer than 4 KiB and exact
coordinated reads still succeed. After detach/remount, however, fresh acquisition there fails with
`unavailable(ESTALE)` because neither the descriptor alias nor the selected deep
pathname produces a usable root reference (`/tmp/nv-p54-deep-hfs.log`). This
fresh-open success assertion failed (`/tmp/nv-p54-deep-hfs-final.log`). A standalone
experiment that inspected the moved reference's path reported Cocoa code 256;
it is not evidence that all deep HFS+
coordination fails, and does not supersede the production read witness.
Changing directory-owner authority or substituting an uncoordinated effect is
not authorized. No such fallback was added, and no Apple contract violation is
claimed. Direct descriptor-alias bookmarks also failed to resolve in the isolated
HFS+ companion; they are not an adopted alternative.

A further read-only metadata experiment checked five candidates: the whole deep
URL, directory-descriptor alias, alias reference, and the final leaf beneath a
parent alias or its reference. The component-opened deep pathname independently
matched the fixture; its Foundation resource query failed with Cocoa code 258,
and reference creation failed. The alias returned resource IDs, but its generated
reference's metadata lookup failed with code 260; alias bookmarks captured but
failed resolution with code 4. Parent-alias/leaf variants also failed. Merely
obtaining opaque resource metadata therefore supplied no usable positively bound
reference in these tests. No identifiers were parsed and no fallback was adopted.
This is an observation-only experiment, not a production compatibility pass
(`/tmp/nv-p54-hfs-resource.log`; source/executable under
`/private/tmp/nv-p54-hfs-resource.6oAF0N/`). The existing synthetic image was mounted
read-only and detached afterward; all artifacts remain preserved.

On 2026-10-12 the user approved this narrow fresh-opening limitation. The
specification, ADR-0006, vocabulary, protocol, caller inventory and P5.4 platform
matrix now preserve ordinary HFS+ opening and the already-owned deep-move/read
requirements while reporting safe fresh-deep refusal explicitly. The production
adapter and its physical checks are unchanged. Capability refusal preserves
healthy private editing and uses existing Retry/reassociation/Save As boundaries;
it supplies no generic Work Offline eligibility or uncoordinated effect.

The final-source volume run passes deep APFS move/read and fresh remounted opening.
HFS+ passes the already-owned deep move/read, then reports only the exact expected
fresh-open `ESTALE` limitation. Independent descriptor-based checks establish
unchanged root identity, namespace and both original/replacement bytes, plus
released cooperating-writer ownership. The report records a limitation rather
than a successful open (`/tmp/nv-p54-approved-deep-volumes.log`; artifacts
`/private/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-root-volumes-5_mg2pnv`).
Thirteen host-free classifier controls require the exact filesystem, deep mode,
exit code, empty output and diagnostic; other errors and filesystems remain
failures. Five isolated in-memory guard mutations each fail the intended classifier
assertion after a passing companion (`/tmp/nv-p54-refusal-mutations-final.log`);
an earlier runner setup rejected a nonunique replacement before its affected
mutation ran and is excluded. Ordinary APFS/APFSX/HFS+/HFSX/ExFAT production
move/read/replacement/detach/remount checks also pass on the final executable
(`/tmp/nv-p54-approved-ordinary-volumes.log`; artifacts
`/private/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-root-volumes-h3z8j92_`).
Model correspondence was checked statically against the existing
post-acquisition owner assumption; no modeled transition, invariant or fairness
condition changed, so this policy alignment requires no TLC rerun.

Final follow-up qualification:

- Strict debug coordination companions pass four parameter cases across two
  functions (`/tmp/nv-p54-hfs-fix-debug.log`). The optimized `repository` selection
  passes 62 functions in 391.191 s (`/tmp/nv-p54-hfs-fix-release.log`); this selection
  differs from the earlier 81-function repository/rooted campaign.
- All 92 compiler construction/confinement outcomes pass against the updated
  optimized module (`/tmp/nv-p54-hfs-fix-types.log`). Production retains its
  Sendable annotation and actor/noncopyable boundaries.
- The ASan/UBSan real-install companion and unverified-path mutant pass their
  designated checks (`/tmp/nv-p54-hfs-fix-mutation.log`). The mutant must reach the
  fallback and fail the unrelated-root assertion with exit 7, before every stage
  write; empty fixture inventory independently confirms no effect.
- All seven independent production root-process groups pass
  (`/tmp/nv-p54-hfs-fix-root-process.log`). Deep APFS passes both move/read and
  fresh remounted acquisition (`/tmp/nv-p54-deep-apfs-final.log`). The first deep
  APFS harness run used a whole-path open in its independent contender; correcting
  that observer to component-wise opens preserved the exclusion assertions.
- macOS 11.7.11 runs the current-SDK Intel minimum-target-11.5 ASan/UBSan boundary
  executable successfully (`/tmp/nv-p54-hfs-fix-orbb-cross-stage.log`). An
  independent Python observer checks exact final bytes and empty stage inventory.
  Orbb's old local SDK cannot parse `NS_SWIFT_SENDABLE`; that attempted build is
  not a runtime failure or qualified compiler configuration. The current-SDK
  cross-build retains the annotation and runs with its matching ASan runtime.
- The owned diagnostic HFS+ image was detached after positive image/device
  verification. Every failed fixture and image remains available; no data was
  deleted. Python syntax checks and `git diff --check` pass.
- The required app build passes with the approved deployment diagnostic override
  explicitly supplied to `xcodebuild`
  (`/tmp/nv-p54-hfs-fix-app-build-explicit.log`). Supplying the same value only as
  an environment variable to `build.sh` did not override Xcode's setting and
  failed at deployment-target diagnosis; no source/build-policy relaxation was
  used to reinterpret that failure.

`test-storage-root-volumes.py --deep-root` requires coordinated exact reading and
separately classifies fresh remounted acquisition beyond `PATH_MAX`. APFS still
requires successful fresh opening; HFS+ permits only the approved exact safe
refusal described above. A short-path pass cannot qualify an already-owned deep
read or a supported fresh-deep opening.
The diagnostic briefly tested a constructed `/.vol` path only to distinguish
reference-creation from native reachability. Apple's
[QA1113](https://developer.apple.com/library/archive/qa/qa2001/qa1113.html)
reserves that syntax for system use, so production neither constructs it nor
parses opaque file-reference identifiers. Deprecated FSRef APIs were not adopted.

## Automatic driver and copied platform observations

`RepositoryTransportDriver` owns one coalesced worker and one tokenized monotonic
wakeup. Publication captures at most eight objects/1 MiB; discovery defaults to
16 entries. Initial passes, save/receive settlement and positive root revalidation
use existing owner notifications. A 30-second ordinary idle revisit gives missing
callbacks a bounded opportunity latency at the cost of a periodic bounded scan.
Actual provider visibility still has no deadline/completeness promise. The error
attempt budget is three starts (initial, +1 s, +4 s) within 15 seconds; an entered
operation retains capacity until return. Ordinary hints/settlements preserve an
exhausted error. Foreground/refresh or positive revalidation starts one new attempt.
Persistent private-store failure pauses both directions without polling.

Selected availability copies residency/ubiquity/download/upload/error categories.
Native SF_DATALESS, actual reads, root/session and exact observation checks remain
separate. Materialization applies only to a disclosed ubiquitous item and its
success is a request acknowledgment. Forward provider lookup is asynchronous,
supplemental and checked again after callback; unknown/unsupported keeps physical
continuity unknown. URL opening retains any applicable security-scoped lease
through final root release. No Work Offline/startup product decision is made here.

### P54-04 coordinator error classification

`repositoryCoordinationFailureClassification` tests the actual internal mapper
used when a coordinator returns without an accessor result. Its 21 independent
cases include explicit Cocoa read/write diagnoses, positive POSIX errors, nil,
unknown/empty domains, integer overflow and zero/negative POSIX codes. Every
constructed NSError also carries an underlying missing-file error and incorrectly
typed supplemental path/description values. Expected codes come from a fixed test
table; the mapper uses only domain and code. The SDK's `FoundationErrors.h` supplies
the meanings of the recognized Cocoa cases. This corrects previously generic EIO
diagnoses for write permissions, full/read-only volumes and the general missing-file
code, while preserving failure and the existing resource/authority boundaries.

Strict debug passes all 21 cases plus actual cancellation and held-accessor
companions for both profiles (three functions, 2.344 s,
`/tmp/nv-p54-coordination-errors-debug-final.log`). Optimized coordination/presenter
qualification passes five functions in 0.718 s, including all 21 cases
(`/tmp/nv-p54-coordination-errors-release.log`). An isolated exact-source baseline
passes; removing the POSIX domain check produces 11 failures at the designated
classification assertion, rather than compilation/discovery failure
(`/tmp/nv-p54-coordination-errors-mutation.log`; result manifest under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-runtime-mutations-b8_zwwbn/`).
All 92 strict ordinary-client/actual-module construction and confinement outcomes
also pass against the updated debug module and actual source, including the
prepared stage's unique ownership and executor confinement
(`/tmp/nv-p54-coordination-errors-types.log`). Mutation setup/syntax checks and
`git diff --check` pass.

Ubuntu arm64 Swift 6.4 recompiles the same final source and passes the actual
root-ownership, wrong-session and both-profile hint-storm companions (three
functions, 0.947 s; remote `/tmp/nv-p54-coordination-errors-linux.log`). Source
hashes are captured in `/tmp/nv-p54-coordination-errors-linux-ssh.log` on this Mac.
The newly linked probe and test executable separately pass PIE, W^X,
non-executable-stack and RELRO checks plus the RWX observer control
(`/tmp/nv-p54-coordination-errors-linux-elf.log`). Darwin NSError cases are
conditionally absent there; this portable regression result supplies no Apple
coordination qualification.

Injected NSError values qualify classification, not proof that Foundation emits
each constructed payload. Real accessor-entry/effect/cancellation and native
partial-effect witnesses remain separate evidence. Root permissions, checked
observations and installation evidence keep their restricted constructors; the
new internal mapper returns only an error code. No public API, persistent state,
encoded value, model transition or safety condition changes, so this refinement
requires no TLC rerun.

### P54-10 hint-storm follow-up

`repositoryDriverCoalescesHintStormAcrossNestedPass` holds the first discovery
observation after metadata returns and before body reading, delivers 256 root
hints and waits for the existing driver
to consume every notification before releasing the observation. The internal
observation hook reports that event boundary; admission, scheduling and resource
state remain the production implementation. On Darwin the test removes only its
own presenter to isolate this controlled hint schedule from independent OS
callbacks. Separate presenter/peer tests retain real callback coverage.

The fixture contains 24 chained ordinary edits and one rejected neighbor in a
different writer directory. Independent assertions require exactly two completed
passes, at most 16 bounded turns, at most 16 returned entries per turn and at most
two live listing resources. Every accepted edit body is read exactly once across
both passes. The rejected neighbor is read once per pass, remains retained and
cannot prevent exact acceptance of all edits. SQL membership, complete current
values/context, empty prerequisite waits, released root ownership and reopening
are checked separately. This is a finite storm/resource witness; it grants no
provider disclosure or catalog-completeness guarantee.

Both profiles pass in debug (9.329 s,
`/tmp/nv-p54-hint-storm-debug.log`). All eight optimized driver functions pass
(19.765 s, `/tmp/nv-p54-hint-storm-release.log`). Two isolated mutations pass their
controls after a valid companion: removing the coalesced follow-up fails the
two-pass assertion; bypassing accepted-file hints fails the single-body-read
assertion. Both fail at the intended assertion for both profiles
(`/tmp/nv-p54-hint-storm-mutations.log`; independent result manifest under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-runtime-mutations-mvvk8het`).
Thread Sanitizer passes the storm witness for both profiles (10.148 s,
`/tmp/nv-p54-hint-storm-tsan.log`), including the native presenter target. Vendor
SQLCipher remains outside this targeted TSan instrumentation claim.

Ubuntu arm64 Swift 6.4 passes both profile cases in 0.651 s through the documented
native build entrypoint (`/tmp/nv-p54-hint-storm-linux-relinked.log` on the VM).
Both the actual probe and test executable pass PIE, W^X, non-executable-stack and
RELRO checks plus the RWX observer control
(`/tmp/nv-p54-hint-storm-linux-elf.log` on this Mac). Earlier setup attempts are
excluded: the alternate build system failed to open a generated dependency file;
the kernel killed a compiler in the two-job build for memory exhaustion; the
serial build reached a linker bus error under disk pressure. The same serial
build passed after recoverably moving 792 MB of a separate old benchmark's build
outputs to `/private/tmp/nv-ubuntu-startup-preserved.i3TeLH/build/` on this Mac.
The old benchmark's source, fixtures and logs remain on the VM. The failed
alternate outputs remain under `/tmp/nv-p54-alternate-build.7xoVzB/out` there.
Compiler diagnostics, source, link protections and test assertions stayed intact.

No encoded format, public API, persistence state or modeled safety condition
changes. Existing TLA+ scheduling results retain their recorded scope; this
follow-up adds executable work-count and notification-consumption evidence.

## Final-source checks completed so far

- Debug strict selected suite: 16 functions pass in 10.978 s
  (`/tmp/nv-p54-final-debug.log`).
- Optimized strict repository suite: 81 functions pass (`/tmp/nv-p54-release-repository.log`).
- Compiler boundaries: 92 outcomes pass (`/tmp/nv-p54-owned-stage-types.log`):
  45 ordinary and 45 actual-module companions/rejections plus two actual-file
  probes requiring noncopyability and executor confinement of the prepared stage.
- Six driver/availability/provider mutations all fail at their intended assertions
  after a valid companion (`/tmp/nv-p54-owned-stage-mutations.log`). The exact-batch
  witness compares the captured acceptance cut as well as locators: a discarded
  batch can otherwise recapture identical first-eight names under a newer cut.
  The idle-revisit witness removes only its own presenter so OS hints cannot
  conceal a missing ordinary wakeup. Earlier surviving mutations remain failed
  campaign evidence; those test corrections retain the production requirements.
- All seven existing native barrier/overwrite/cleanup mutations pass their
  designated controls (`/tmp/nv-p54-final-native-mutations.log`).
- SQLCipher ASan and the required real use-after-free positive/negative control
  pass; all 16 selected coordination/availability/driver functions pass
  (`/tmp/nv-p54-final-asan.log`). TSan passes the same 16 functions in 22.177 s,
  including the native presenter bridge (`/tmp/nv-p54-final-tsan-2.log`). This is
  not a fully TSan-instrumented vendor SQLCipher claim.
- The retry fixture now uses the production 15-second window. Earlier instrumented
  runs correctly expired its artificial one-second window and are excluded from
  positive evidence. A separate held-accessor test still forces actual expiry and
  checks retained capacity/exact retry; no production budget was enlarged.
- Static analysis and ASan/UBSan of the Foundation/native bridge pass through
  actual local and selected-iCloud preparation/install grants; exact final bytes
  and empty stage inventory are independently checked
  (`/tmp/nv-p54-final-apple-stage.log`). Real iCloud ctime changes between grants
  motivated the open descriptor, rather than weakening byte/identity validation.
- `RepositoryAccessorDriverSafety` passes all 17 exhaustive/control/witness checks
  (`/tmp/nv-p54-tla.log`). The [model entry](../../../tla/README.md#accessor-lifetime-and-the-automatic-transport-driver)
  separates safety without OS progress from conditional liveness.
- Independent Foundation peer write/move and presenter opportunity pass on final
  source (`/tmp/nv-p54-final-peer-2.log`). A previous rerun waited for SwiftPM's
  build-directory lock and executed no witness; it is excluded.
- Intel macOS 14.8.9 passes all 16 selected functions in 31.468 s through the actual
  Swift Testing entrypoint and matching test runtime
  (`/tmp/nv-p54-mini-tests-ssh.log`). Its seven production root-process groups also
  pass (`/tmp/nv-p54-mini-root-final-ssh.log`).
- macOS 11.7.11 passes all seven final production root-process groups, including
  selected availability, exact coordinated reading and supplemental forward
  identity (`/tmp/nv-p54-orbb-root-final-ssh.log`). This uses the previously
  documented compiler/isolated concurrency-runtime variant and retains the
  separate unqualified default-distribution gate. Swift Testing's newer OS
  requirement is separate from these production-process witnesses.
- Ubuntu Swift 6.4 passes ten portable functions in debug and optimized builds
  (`/tmp/nv-p54-linux-debug.log` and `/tmp/nv-p54-linux-release.log` on the VM).
  Darwin-only consumers remain explicitly absent there. Its 92 compiler outcomes
  pass (`/tmp/nv-p54-linux-types.log`). The optimized executable passes PIE, W^X,
  non-executable stack and RELRO checks, including the observer's RWX rejection
  control. The initial debug invocation omitted the documented lld flags and
  reproduced the known writable-executable LOAD segment. The hardened debug
  rerun passes all ten functions in 4.374 s and both actual debug/release
  executable checks (`/tmp/nv-p54-linux-hardened-ssh.log`); no check was relaxed.
- All 19 schema checks pass (`/tmp/nv-p54-schema.log`). `build.sh` encountered the
  Xcode 27 deployment-target diagnostic; the equivalent app build passes with
  the previously approved `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO`
  setting (`/tmp/nv-p54-app-build-override.log`). The target-range warning remains.

## Integrated work and performance

The final `benchmark-storage-discovery-work.py --skip-build` campaign passed both
profiles at 64, 256 and 1,024 files, with nine warm repetitions per variant
(`/tmp/nv-p54-final-discovery-benchmark.log`; results under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-discovery-work-5l6x1kd1`).
Exact work assertions retain bounded metadata groups, one indexed hint statement
per eligible group, zero old-body reads and the existing accepted-identity checks.
The held-lookup companion still permits a foreground save before release.

| Warm 1,024-file sweep, median ms | Public profile | Encrypted profile |
| --- | ---: | ---: |
| Production coordinated discovery, budget 16 | 198.944 | 306.976 |
| Production coordinated discovery, budget 64 | 132.384 | 209.301 |
| Native production metadata, group 16 | 130.587 | 123.902 |
| Native exact bulk metadata, group 16 | 9.720 | 7.751 |
| Native exact bulk metadata, group 256 | 1.874 | 1.612 |

These are distinct end-to-end and component measurements, rather than additive
costs. Coordination/reference checking introduces a substantial measured gap
over bulk metadata alone. The earlier private-connection-reuse campaign's
roughly 25–26 ms budget-16 sweep used a different run and implementation; this is
evidence for a paired follow-up, not a clean causal attribution or a claim of
unchanged wall time. Qualification jobs shared the machine during this campaign.

Foreground median save time was 115.086/136.450 ms without/with discovery for
public, and 45.491/40.994 ms for encrypted. Median database queue waits during
discovery were 0.038/0.280 ms respectively. Those observations qualify bounded
queue sharing, not a universal latency guarantee. A focused follow-up should
separate root-reference validation from each bounded coordination grant before
considering shared checks; any reuse must preserve actual accessor/root and
final-effect fences. Cold and live-provider timing remain separate measurements.

## Signed production exchange and authorization boundary

The LaunchServices harness uses only public Runtime APIs. It tests bootstrap,
bidirectional edit/Create/Delete, snapshot retention parents, concurrent branches,
Delete/edit preservation, exact retained envelopes and independent SQL/history
inspection, then execs fresh readers with normal selection/unlock inputs. SSH
transfers harness/configuration, never live segment bytes. Its local companion
uses separate roots and explicitly copies immutable files as a controlled
transport; it is not live-provider evidence.

The final signed local companion passes both profiles after the stage change
(`/tmp/nv-p54-signed-local-framed.log`; artifacts
`/tmp/nv-p54-apple-transport-d_ickdnj`). Its control relay now frames bytes
explicitly: TextIO could prefetch a second response while the selector waited
for another kernel readiness event. A mandatory adjacent-frame companion tests
that harness correction. Earlier stalled relay runs are excluded from positive
qualification; this was a harness read bug rather than a storage rollback.
Live qualification found and fixed two application assumptions: a second open of
`/dev/fd` returned EPERM despite a valid reachable iCloud reference, and ctime
changed between grants. Positive comparison of the system reference's resolved
path and the retained stage descriptor now have real iCloud witnesses.

The Mini subsequently bootstrapped exact provider history but the signed driver
waited before root acquisition. Its stack shows `candidate_parent/openat`, with
matching TCC requests for `net.notational.velocity.storage-contract`, while the
main runloop remains free. The user has been asked to answer the OS access prompt.
This is an authorization outcome, not a File Coordinator violation or a passing
two-host test. No permission database or account settings were modified.
The latest bounded attempt (`/tmp/nv-p54-signed-icloud-permission.log`, fixture
`/tmp/nv-p54-apple-transport-n19kp8qh`) retains its diagnostic stack and owned
artifacts. Its timed-out owned process was terminated; no fixture was deleted.

A subsequent recheck reused that exact signed app after independently confirming
the prior process had stopped. It again reached a matching TCC request and timed
out after 45 seconds before root acquisition (`/tmp/nv-p54-mini-access-recheck.log`,
remote diagnostic directory `/tmp/nv-p54-mini-access.EcJLUt`). The main runloop
remained free. The harness sampled and terminated only its owned process; no
account settings or permission database was modified.

The user-requested authorization retry on 2026-10-12 succeeded with that same
signed app. The current framed relay used a fresh owned control directory,
`/tmp/nv-p54-mini-access-retry.beuae9sz`, and observed `store-opened`, `root-opened`
and `running`; its provider query returned `identified` with an `active` root.
The app reported `stopped` and the relay exited successfully
(`/tmp/nv-p54-mini-access-retry.log`). This qualifies access for the existing
signed preflight app, separately from the final-source exchange below; the preflight
contributes no peer-delivery or recovery qualification. Existing fixtures and
macOS permission settings were preserved.

### Final-source real two-Mac exchange

The complete signed LaunchServices run now passes both public and encrypted
profiles on the arm64 macOS 26.6.2 host and Intel macOS 14.8.9 Mini
(`/tmp/nv-p54-final-source-icloud.log`; artifacts and independent inventories under
`/tmp/nv-p54-apple-transport-nxs7aefz`). SSH transfers only executable/resources,
harness and ordinary selection/control inputs. All live segment delivery uses
iCloud in the fresh owned `API_Contract_Testing/P54-b783d02cbd63493f95fa1ed53b386018`
fixture. No manual segment relay supplies a passing observation.

For each profile, the run checks complete peer bootstrap, automatic bidirectional
edit/Create/Delete, two snapshots with retention-parent acceptance, concurrent
branches and Delete/edit preservation. Each store retains 20 exact objects.
Independent SQL and envelope inspectors check hashes, expected exact saved bytes,
accepted object membership, operations and actions. Both stores agree on current
notes, two conflicting heads, alternatives and exact Undo candidate IDs. Fresh
child processes receive only normal selection/unlock inputs and reconstruct the
expected current values and authoring context. Both roots report identified
providers and active ownership; the selected installed object is independently
observed materialized/ubiquitous/current. The encrypted repository contains no
synthetic plaintext secret marker.

The final builds use Swift 6.4 and pinned SQLCipher with existing strict package
checks. The Intel build retains the documented concrete-metadata-accessor compiler
workaround; no API, isolation or durability check is relaxed. Build logs are
`/tmp/nv-p54-final-source-arm64.log` and `/tmp/nv-p54-final-source-intel.log`.
The unsigned source-executable SHA-256 values are
`614ea57d6a88ca9aff01cbd0456edc4194ebf6e776d18520309307f225f5e2d5` (arm64) and
`8cd00d6795362cd35263958116fc5f1b266a3e9216fefe4f131a71e3589b53e0` (Intel);
the transferred Intel input matches before and after execution. Each freshly
packaged app passes strict signature verification under
`net.notational.velocity.storage-contract`, ad-hoc signed and launched through
LaunchServices. Their CDHashes are `6924d787dd5c972dc63a685faa4b631592f92c1b`
and `43f1232bff91c6696902e17f57ebd441e0af0ac1`, respectively. This qualifies
those tested signatures, not production distribution signing.

Both drivers report orderly stop and their relays exit successfully. Independent
process checks find neither owned app running afterward, and both volume campaigns
detach their exact owned devices. All fixtures/images are retained. Python syntax
checks and `git diff --check` pass. No production logic or encoded format changed
during this final qualification; only the approved compatibility policy and its
capability/observation checks were added.

## Completion and separate qualification gates

P5.4's required production transport gate is closed by the final-source two-Mac
results, together with the earlier independent local, crash/I/O, compiler,
mutation, sanitizer, scheduling and platform witnesses. The approved fresh
deep-HFS+ limitation is tested as safe refusal, not successful opening. Existing
partial-effect, durable receive/rejection and P5.3 work-bound requirements remain.

Live eviction/full/offline stimuli count only when actually observed; unavailable
supplemental stimuli remain inconclusive. Production distribution signing,
default macOS 11 packaging and physical power loss remain separate release
qualification. Plaintext/UI integration and P5.5 startup/root reassociation retain
their later implementation gates. None of those are inferred from upload flags,
the preflight authorization result or this completed P5.4 exchange.
