# P5.3 — Real local repository exchange qualification

Date: 2026-10-10–11. Status: implemented and qualified for local repository exchange
within the platform, performance and physical-durability limits below.
Read the [part plan](03-local-repository-exchange.md) and
[physical-file qualification](02-immutable-files-validation.md) for scope.

## Production path and state

`RepositoryPublication.swift` captures a bounded, frozen accepted-history prefix
from the owned private database. It checks exact retained descriptors, bytes and
direct accepted dependencies before issuing a publication batch. Keyset cursors
bind store, session and cut; a completed batch can begin a subsequent pass for
later accepted objects. SQL work ends before the strict rooted installer runs.
Physical installation evidence remains separate from local save acknowledgment.

`RepositoryDiscovery.swift` connects bounded rooted enumeration and coherent reads
to the actual durable receive queue or an explicitly selected bootstrap candidate.
It examines the envelope's identity even under an arbitrary safe duplicate name.
Child-before-parent input remains retained; existing acceptance, wakeup, rejection
and materialization machinery supplies the logical results. Initial assembly also
queues incidental ordinary actions sharing the bootstrap envelope, so completion
includes their effects before editable publication.

The root owner retains a bounded stack of directory streams. Inspecting a writer
preserves its parent's progress; resuming a parent retires deeper streams.
Cancellation, generation changes and closing release applicable resources. Each
continuation is single-use. An early empty pass ends only that pass: subsequent
open, foreground, save-settled, refresh or background-turn opportunities revisit
the namespace without requiring a fresh provider callback.

Existing private groups hold rebuildable accepted-file hints. Their fingerprints
bind the relative path and checked file attributes; freshly issued root permissions
govern each live use. The fingerprint survives an ordinary reopening, while an old
permission still fails at its consumer. Reuse also requires exact accepted
membership in the selected healthy private database. Changed files, malformed
hints and incomplete membership take the ordinary read/receive path. Recording a
hint after durable retention permits reuse once a parked object is later accepted.

These changes add no persistent table, semantic transport log or long-lived graph
cache. C filesystem effects remain the qualified P5.2 implementation.

## Connected witnesses

| Requirement | Production witness and independent observation |
| --- | --- |
| Exact bounded outgoing history | `RepositoryPublicationTests`: frozen cuts, byte/object budgets, subsequent passes, direct accepted dependencies, exact bytes and wrong-store/root/session consumers. |
| Nested discovery preserves progress | `RepositoryListingTests`: 19 writers with interleaved child reads; exact name inventory, bounded descriptors, replay/cancel/generation/close checks. |
| Real bootstrap, edit and Delete exchange | `RepositoryExchangeTests` and the fresh-process driver: strict files → second private store → normal reopen; exact objects, operations, actions, current values and editing context. |
| General snapshot root before pages | `repositoryExchangePagedSnapshotWaitsAcrossRestart`: production snapshot capture/construction → strict files → root-only waiting input → reopened receiver → every file except one leaf → final leaf delivery. Exact retained root/pages, accepted dependencies, unchanged note values/context and five operations/three actions are independently inspected. |
| Delayed disclosure and dependencies | Early empty pass, high child before low parent, multiple prerequisites, later ordinary opportunities without another hint, and durable waiting input across restart. |
| Identity comes from inspected contents | Arbitrarily renamed duplicate, repackaged equivalent operations and equal visible body with different represented history; exact envelope coverage grows while logical effects occur once. |
| Shared bootstrap envelope | `RepositoryBootstrapExchangeTests`: Import and a later edit/Delete share an envelope; selected descriptor bytes are known before the descriptor file is disclosed; incomplete input stays noneditable; final and reopened values include the tail. |
| Explicit collection selection | Concurrent distinct bootstraps in one physical repository retain separate identities; each explicitly selected candidate admits its own complete closure and reports foreign input. |
| Newer live work survives old completion | Held actual read/delivery followed by edit or Delete; stale prepared publication cannot invoke the host or clear a later pending generation. |
| Storage and cancellation preserve ownership | Repeated hint/rejection write failure, blocked descendants and unrelated valid neighbors, safe-save during read, cancellation after durable handoff, and restart/retry through the actual queue. |
| Backup replay preserves causal deletion | Independent old private backup, fresh writer/origin, concurrent edit versus Delete, automatic content preservation and fresh-birth Restore; Recently Deleted and duplicate membership checked after reopening. |
| Reopening preserves useful read work | `repositoryExchangeReopenReusesCheckedObservations`: old permission rejects, unchanged files require zero body reads under fresh permissions, and one new file is accepted once. |
| Owner retirement preserves the evidence boundary | `repositoryExchangeReopenedOwnerRejectsPreviousTurn`: close and release the issuing owner, reopen the same physical store and persistent ID, reject the old turn, then validate a newly issued turn and independently expected note values. |
| Work bounds are measured at actual consumers | 64/256/1,024 ordinary actions: bounded publication reads, zero ancestor visits, indexed SQL without scans, bounded enumeration resources, zero unchanged body reads and one new-file read. |

The reopen-hint witness initially failed for both profiles: including a random
root-session UUID in the persisted fingerprint forced every body to be read again.
The fingerprint now contains file-observation attributes, while live session and
generation checks remain independently enforced. The corrupted-dependency witness
also inspects the durable damage record and retained bytes through a fresh raw
database reader after the normal owner has fenced damaged history.

Final review also found that escaped discovery results originally used an actor's
`ObjectIdentifier` without retaining that actor. Swift defines that identity for
the [instance's lifetime](https://developer.apple.com/documentation/swift/objectidentifier).
Discovery now binds the existing store ID and local session UUID, or the bootstrap
database's existing connection UUID. The reopening consumer witness exercises the
actual boundary; a targeted mutation omitting the session comparison must fail
there. This strengthens local evidence lifetime using already tracked values,
with no encoded-format or modeled scheduling change.

## Fresh-process failures

`tools/test-storage-repository-exchange.py` runs twelve schedules across plaintext
and encrypted provider profiles. Both private databases use SQLCipher. Children
receive normal selection/unlock inputs, rather than expected notes or an
acknowledgment oracle. The parent independently examines actual SQL rows and exact
envelopes with the separate history decoder.

The schedules cover incomplete bootstrap/resume, termination before and after
retention commit, after acceptance but before callback, materialization followed by
a second recovery interruption, and an acceptance synchronization error. Each
observes exact surviving membership, values, represented context, queue state and
absence of receive-to-new-local-action echo. SSH mode executes the same production
probe and filesystem effects remotely; independent decoding remains on the host.

The sync-error schedule additionally requires the exact `database(1034)` result
and a positive injected-fault hit count, separately from its retained-data checks.
Final Orbb qualification exposed a probe shutdown race: after the expected error,
`exit(2)` ran library destructors while an outstanding database verification read
was still executing. The crash stack records both threads
(`/tmp/nv-p53-owner-orbb-crash.txt`). The probe now quiesces its owned store before
error exit, retaining the original failure and independent recovery assertions.
This is test-client cleanup; production Runtime behavior and the intentional
abrupt-termination schedules are unchanged. The failed rerun
(`/tmp/nv-p53-owner-orbb-process.log`) is preserved separately from qualification.

All twelve passed with local debug and optimized probes, Ubuntu's Swift 6.4 debug
probe, the Intel macOS 14 probe and the macOS 11 test variant.
Logs: `/tmp/nv-p53-exchange-process-debug-3.log`,
`/tmp/nv-p53-exchange-process-release.log`, `/tmp/nv-p53-mini-process.log` and
`/tmp/nv-p53-orbb-process.log`; Ubuntu's report is
`/tmp/nv-p53-ubuntu-process.log`.

After the final owner refinement and probe cleanup, all twelve schedules also
passed on the Mini and Orbb with the strengthened explicit fault observer:
`/tmp/nv-p53-probe-cleanup-mini-process.log` and
`/tmp/nv-p53-probe-cleanup-orbb-process-2.log`. The first cleanup-only Orbb rerun
passed independently (`/tmp/nv-p53-probe-cleanup-orbb-process.log`).

The same final twelve schedules passed on local debug and optimized probes
(`/tmp/nv-p53-probe-cleanup-debug-process.log` and
`/tmp/nv-p53-probe-cleanup-release-process.log`) and Ubuntu's hardened optimized
probe (`/tmp/nv-p53-final-ubuntu-process-release.log`). These runs include the
explicit sync-error/fault-hit assertion and settled error-exit cleanup.

`tools/test-storage-repository-cross-host.py` additionally passed a mixed-host
round trip for both profiles: macOS authors bootstrap/edit/Delete; Ubuntu first
retains an incomplete root, reconstructs the complete repository, and authors a
new edit; macOS discovers that edit; both exec fresh readers. Independent SQL and
envelope checks verify all prior objects, exact action/operation membership,
unchanged deletion and matching represented context. Five intended actions remain
five actions, including after the reverse delivery. This qualifies portability
through actual files and independently owned stores, separately from cloud
transport. Log: `/tmp/nv-p53-cross-host.log`; fixtures and per-command trace:
`/tmp/nv-cross-host-repository-gcmiuxvr`.
The final probes repeated this complete round trip successfully for both profiles:
`/tmp/nv-p53-final-cross-host.log`; independent observations and traces are in
`/tmp/nv-cross-host-repository-3qozlvta`.

## Compiler, mutation and model checks

The root type-probe driver checks ordinary-client and actual same-module clients.
All 64 optimized probes passed, including publication cursors/batches/results,
discovery entries/turns/hints, actor isolation and live permission boundaries.
Runtime tests independently exercise same-type wrong-context consumers. Ubuntu's
Swift 6.4 compiler also passed all 64 ordinary/same-module debug probes.
The final local debug and optimized probes each passed all 64 cases
(`/tmp/nv-p53-owner-types-debug.log` and `/tmp/nv-p53-owner-types-release.log`),
including the updated discovery-turn constructor challenge.
Ubuntu's final strict Swift 6.4 build passed all 64 optimized ordinary/same-module
probes while idle, retaining the original diagnostic, marked-line and watchdog
requirements (`/tmp/nv-p53-owner-release-types.log` on the VM;
`/tmp/nv-p53-owner-ubuntu-qualification.log` on the host). An earlier optimized
attempt timed out during competing build work and is not credited as a pass.

Seven isolated mutation controls reached their intended assertions: omitted
accepted-dependency membership, omitted cursor context, lost shared-bootstrap
tail, consumed-only empty pass, stale handoff, lost persisted observation hint and
filename-only filtering. The empty-pass control's first attribution named a later
assertion; the actual earlier missing-waiting witness was then designated and
rerun successfully. Setup failures and misattribution remain distinct from a
targeted runtime failure. The final combined campaign passed its baseline and all
seven intended controls: `/tmp/nv-p53-mutations-debug-final.log`, with complete
patches, source manifests and per-control logs in `nv-runtime-mutations-xlcsvht5`.
Earlier attribution logs remain `/tmp/nv-p53-mutations-debug-2.log` and
`/tmp/nv-p53-mutations-debug-3.log`.

The final-source campaign adds omitted owner incarnation and passes all eight
designated controls, with a passing baseline and exact assertion/discovery
attribution: `/tmp/nv-p53-owner-mutations.log`;
`nv-runtime-mutations-jxg5jeyr/results.json` retains the source manifest and each
control's evidence. This campaign precedes the test-probe shutdown correction
described above; its unit-test path and production Runtime sources are unchanged by that
correction. The reproduction command below includes this eighth control.

`RepositoryDiscoverySafety.tla` checks bounded parent/child progress, durable
handoff, dependency-closed acceptance, identity-based duplicate handling and stale
consumer rejection. Two safe exhaustive configurations, eight defect controls
and five reachability witnesses passed. The two safe runs explored 29,792 and
15,586 distinct states respectively. Conditional progress assumes final positive disclosure and
fair local work; it makes no promise that a provider discloses everything.
See the [model entry point](../../../tla/README.md#bounded-real-repository-discovery)
and `/tmp/nv-p53-discovery-tla-3.log`.

## Qualification status and boundaries

The initial full local debug and optimized selections each passed 47 test functions,
including retained P5.1/P5.2 root and file companions. The final debug and optimized
selections, including the new owner-lifetime witness, each passed all 48 functions
(`/tmp/nv-p53-owner-final-debug.log` and `/tmp/nv-p53-owner-final-release.log`).
Eight additional existing bootstrap/receive test functions passed. AddressSanitizer passed twelve selected
test functions with the instrumented SQLCipher archive and its required
expired-handle negative control. ThreadSanitizer passed the four selected
listing/reopen/handoff tests and all six exchange-failure tests. The schema's
nineteen checks passed. Logs include `/tmp/nv-p53-debug-full.log`,
`/tmp/nv-p53-release.log`, `/tmp/nv-p53-receive-companions.log`,
`/tmp/nv-p53-asan.log`, `/tmp/nv-p53-tsan.log`, `/tmp/nv-p53-tsan-failures.log`
and `/tmp/nv-p53-schema.log`.

The final owner/bootstrap/handoff selection passed four functions under each
sanitizer. AddressSanitizer used the instrumented cipher and its expired-handle
control (`/tmp/nv-p53-owner-asan.log`); ThreadSanitizer exercised the actor
handoffs (`/tmp/nv-p53-owner-tsan.log`). The final Intel macOS 14 selection passed
all nine bootstrap/exchange-failure functions, including the new reopened-owner
consumer (`/tmp/nv-p53-owner-mini-swift.log`).

`build.sh` encountered Xcode 27's deployment-target diagnostic. The equivalent
build passed with the already documented explicit
`__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` argument; the deployment
warning remains visible. No application source or deployment requirement changed.
See `/tmp/nv-p53-app-build.log` and `/tmp/nv-p53-app-build-override.log`.

The Intel macOS 14 optimized selection passed all 47 functions
(`/tmp/nv-p53-mini-swift-2.log`); Ubuntu's debug selection passed the same 47
functions in eight disk-bounded batches
(`/tmp/nv-p53-ubuntu-debug-batches-ssh.log`). Its optimized selection also passed
all 47 functions (`/tmp/nv-p53-ubuntu-release-batches-ssh.log`), with PIE, W^X,
nonexecutable-stack and RELRO checks on both executables and the required RWX
negative control. These full selections precede the final owner-lifetime
refinement; its additional witness and affected final-source checks are recorded
separately below. The first Ubuntu attempts exhausted disposable fixture storage;
the second reported explicit POSIX ENOSPC.
Those failed runs qualify neither successful recovery nor platform compatibility.
Tests were rerun unchanged with sufficient temporary capacity. Cleanup removed
only disposable synthetic collections and reproducible older build directories;
source and qualification logs were preserved. Those fixtures can be recreated by
their recorded drivers. The active pinned SQLCipher dependency was rebuilt at
its configured path after an older dependency directory was cleaned.

After the final owner refinement, Ubuntu's debug and optimized strict builds each
passed thirteen affected owner/bootstrap/exchange/reopen functions. Both
executables again passed PIE, W^X, nonexecutable-stack and RELRO checks, including
the RWX negative control (`/tmp/nv-p53-owner-ubuntu-qualification.log`). These
targeted final-source passes supplement, rather than relabel, the earlier full
47-function selections. The paged-snapshot companion is qualified separately;
adding it changes no production Runtime or C source.

The added paged-snapshot function passed for both profiles in local debug and
optimized builds (`/tmp/nv-p53-paged-exchange-debug-final.log` and
`/tmp/nv-p53-paged-exchange-release.log`) and the Intel macOS 14 optimized test
bundle (`/tmp/nv-p53-paged-mini.log`). Its accepted dependency set is checked
against the manifest's required locators and tree root, separately from the
source database. Waiting root bytes survive reopening, while the accepted-only
accessor correctly reports incomplete until all pages have arrived. Qualification
freezes the final test-file SHA-256
`cde9e7dec3e944d08ef64408ba9d1641533b452e43f04f496b730d7da46a3622`.
Ubuntu's final debug and optimized companion runs also passed for both profiles:
`/tmp/nv-p53-paged-ubuntu-qualification-final.log` on the host and
`/tmp/nv-p53-paged-ubuntu-debug-final.log` /
`/tmp/nv-p53-paged-ubuntu-release-final.log` on the VM. The final ELF checks
again verify both test executables and the optimized probe, including the RWX
negative control (`/tmp/nv-p53-final-ubuntu-elf.log`).

The Intel macOS 11 probe uses the documented compiler workaround and isolated
concurrency runtime from P5.1/P5.2. It qualifies execution of that test variant,
rather than default macOS 11 distribution. No system library is replaced.

The [directory-scan benchmark](directory-scan-performance.md) remains a material
performance finding: full unchanged discovery at 1,024 files was roughly
126–130 times slower than the legacy two-scan fence, despite zero body reads.
Repeated rooted metadata and context checks dominate that original path.
[Bounded metadata/hint qualification](bounded-discovery-batches-validation.md)
records the subsequent production optimization, exact work gates and retained
safety evidence. The original measurements above remain baseline evidence;
healthy launch remains independent of either repository sweep.

Apple coordination, actual cloud-provider disclosure, unknown-collection startup
UI, mutable replacement/repair and physical power-loss qualification remain the
separate P5.4–P5.7 boundaries. Process termination and injected SQL I/O errors
exercise their stated failure classes only.

## Reproduction

Use the pinned SQLCipher dependency and one build job. Repeat the first command
with `--configuration release` for optimized qualification.

Current source-file selections use declaration names from the checked test
catalogue. They preserve every selected function and its parameter matrix after
the test-target partition. The result counts above remain dated campaign evidence.

```sh
python3 tools/generate-test-index.py --check
NV_EXCHANGE_FILTER=$(python3 -c 'import json,sys; rows=json.load(open("docs/test-index/catalog.json"))["entries"]; names=[r["name"] for r in rows if r["kind"]=="swift" and r["source"].rsplit("/",1)[-1] in sys.argv[1:]]; assert names; print("|".join(names))' RepositoryPublicationTests.swift RepositoryListingTests.swift RepositoryExchangeTests.swift RepositoryExchangeFailureTests.swift RepositoryExchangeLifecycleTests.swift RepositoryBootstrapExchangeTests.swift RepositoryRootTests.swift RepositoryFilesTests.swift)
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS="--disable-sandbox --jobs 1 --no-parallel --filter \"$NV_EXCHANGE_FILTER\""
python3 tools/test-storage-repository-exchange.py --binary NVStorage/.build/debug/NVStorageProbe
python3 tools/test-storage-repository-cross-host.py --local-binary NVStorage/.build/release/NVStorageProbe --remote-binary /absolute/test/host/NVStorageProbe --ssh-target test-user@test-host --ssh-key /absolute/test/key
python3 tools/test-storage-root-types.py --modules NVStorage/.build/release/Modules
python3 tools/test-storage-runtime-mutations.py --disable-sandbox --jobs 1 --only exchange-omitted-owner-incarnation --only exchange-unaccepted-dependency --only exchange-omitted-cursor-context --only exchange-lost-bootstrap-tail --only exchange-consumed-only-pass --only exchange-stale-handoff --only exchange-lost-observation-hint --only exchange-filename-filter
```

SSH process qualification additionally accepts `--ssh-target`, `--ssh-key` and
repeatable `--probe-env NAME=value` arguments. Retain source/build identity,
platform version, complete logs and independent observations with each run.
