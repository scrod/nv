# P5.5 — Startup and root reassociation qualification

Updated: 2026-10-13. Status: P5.5's headless implementation and qualification are
complete within the capability/distribution limits below. Qualification includes
separately completed component reruns; earlier aggregate timeouts remain recorded
as incomplete runs. The
[plan](05-startup-and-root-reassociation.md) defines scope and exit conditions.

### Qualified source identity

The worktree includes earlier uncommitted storage increments. These SHA-256 values
identify the final P5.5 production paths independently of that surrounding diff:

| Source | SHA-256 |
| --- | --- |
| `CollectionStartup.swift` | `0dd1112e054f76a56c40a9411b2025b32cd33e2cd06d04649a56e46dd9b35f97` |
| `CollectionBootstrap.swift` | `d74f85d12b6b0f78727bf6bedef5eda0179ae51094f69f3e414ec4de1e907aa1` |
| `RepositoryRoot.swift` | `ead7b308bffa11f289dc7bcb52b83d2941c8407dfd2bf6498892dec57ca74c24` |
| `RepositoryTransport.swift` | `b8af99217614cc2564bf7c4bca61e2ede40f7a5354698c9b669642c4e657ce1f` |
| `LocalStore.swift` | `54b681621d882687abe56d24a74d9eb07516a95de8832fabc5e16581c32197a6` |
| `NVAppleFileAccess.m` | `9fcf7fea6703a71ba4059d36f967c14413325945d78e02c5c28f2c0f0b1bfcd0` |
| `NVAppleFileAccess.h` | `3d62469bbeeb0951b2c0f43cc5eb788d9cc38fcba6b6e17013d9cde59b483aea` |

## Production boundaries

`CollectionSession` joins the owned private opener, required-state recovery,
physical root association, checked host publication and independently scheduled
transport. Its actor owns one attempt generation and one unsettled transition.
`CollectionPreparedPublication`, `CollectionCapturedAction` and `WorkOfflineChoice`
have issuer-restricted constructors; their consumers check owner/attempt, actual
local health and existing view/history fences. Recovery requests are separately
issuer-restricted classification values. Their later P5.6 consumers must obtain
fresh effect authority from the actual store/root owners. Publishing
reserves the selection through the synchronous host callback. A throwing callback
preserves the prior phase and enables no ordinary transport handoff.

The physical root is acquired independently of the complete private opener.
Generic provider failures preserve healthy local startup. A missing private
association requires explicit binding, and known root contention remains scoped.
Missing or damaged repository data dispatches to the typed P5.6 repair request;
P5.5 never reports that repair has already occurred.

An initial named unread object absent locally can issue Work Offline. Exact bytes
already retained, late disclosure and generic errors cannot issue that choice.
One named materialization demand shares the existing transport worker, wakeup and
timer. The default attempt consists of the initial request and two bounded
retries; save/hint notifications leave an exhausted attempt exhausted. Exact
readable, authenticated normal receive settles it. Request acknowledgment alone
does not. Same-root Retry renews the attempt without losing the reused worker's
physical-root/exact-locator completion routing.
Retry replaces the named worker's obsolete permission context with freshly
disclosed evidence. Stale input pauses instead of generating an immediate retry
loop. A separate held-attachment witness requires successful local publication
to enable ordinary transport whichever of publication or attachment settles last.
Both use the existing worker and admission state.

Acceptance and current-row installation are separate transactions. Publication
that encounters their intervening lag returns retryable `staleCapture`; it neither
publishes partial values nor diagnoses missing history. The regression holds the
actual current-row installation after acceptance, then checks exact retained
bytes and complete current values after release and fresh reopening.

The user-approved held-accessor rule allows Work Offline from the original exact
disclosure when a fresh read is busy. Fresh local-health and same-live-root/attempt
checks remain required. Local publication/save can complete before the accessor
returns; pending input and original physical ownership survive. This issues no
provider-write permission. A stale root or failed local health rejects the choice.
An unavailable Retry preserves the named pending item and healthy local admission
without pretending that old root evidence is currently usable.

Retry compares the continuously held root. Explicit Re-open reserves the
transition, independently checks the selected directory and exact descriptor,
writes the existing association record, then reads back its exact value and
generation. A committed result adopts after old work actually returns; unchanged
binding retains the source. Unreadable completion retains one transition owning
both resources for readback retry. Cancellation and missing callbacks cannot undo
a committed binding. Passive bookmarks propose candidates; independent device/
file comparison rejects old-path replacements. No new persistent table, sidecar,
validation cache or durable offline/consent flag is introduced.

`CollectionBootstrapSession` retains one explicitly selected incomplete import.
Its read-only preview requires every displayed page, count and digest. Editable
completion requires complete durable import/history and normal private reopening.
Failure during that reopening can retry the same committed snapshot. Explicit
creation exclusively acquires the requested destination and `NV Data`, preserves
foreign occupants, commits complete private history and binds it. The host-facing
selection cutover reuses `VerifiedReplacement`/`SelectedStoreOwner` and their
expected-current record contract.

### Ephemeral state ownership

| Fields | Producer and consumer | Settlement / lifetime |
| --- | --- | --- |
| `identity`, `attempt` | Opening creates the owner; choices, captures, publication and callbacks consume its context. Retry or committed association adoption advances the attempt. | Old-attempt evidence is rejected; owner identity lasts through close. |
| `store`, `association` | The complete opener supplies the store; existing association SQL supplies the generation-checked binding. Admission and reassociation read it. | Exact readback updates the binding; terminal close quiesces the store. Only the existing SQL record persists. |
| `root`, `acquisition`, `acquired` | Independent acquisition produces an owned resource or scoped failure; phase-safe consumption compares its physical association. | Adopt or close stale/unadopted resources; close joins acquisition and releases ownership after actual work settles. |
| `phase`, `repositoryHealth`, `repositoryRequest` | Actual local/root observations and operation settlement update the closed decision/status. Public admission and recovery consumers inspect it. | Successful reinspection clears obsolete repair status; callback failure restores the prior phase; terminal settlement becomes closed. |
| `transport` | One attaching reservation becomes the existing driver. Successful publication or later attachment enables its normal handoff. | Reassociation and close stop/join/detach it; failed attachment returns to idle. |
| `operations`, `phaseBeforeTransition` | Admission increments an in-flight count before suspension; transition reservation freezes the prior phase. | Scoped `defer` decrements/clears them; a live operation prevents competing terminal/root adoption. |
| Waiting disclosure / `deferredDisclosure` | Exact root disclosure issues the initial wait; Work Offline or late evidence retains the named input for transport. | Exact named receive clears it. Restart reevaluates surviving resources; no durable consent or offline flag is replayed. |
| Pending `AssociationTransition` | A reserved rebind captures source/target resources and expected/current SQL values. | Readback decides unchanged versus committed binding; adoption waits for actual old work. Repeated readback failure retains the same transition. |

Required durable history, pending bytes, private settings, association and selected
store records keep their existing issuers and storage protocols. This inventory
adds no separate persistent startup/transport ledger.

## Tests and independent observations

| Plan cases | Production witnesses / observations |
| --- | --- |
| P55-01/06/14/20 | Literal closed health matrix, actual failed open and root consumers, collision/missing-association companions; existing private-health/repair suites retain scoped damage and preservation checks. |
| P55-02–05/23 | Actual checked publication while root acquisition is held; existing required/optional, verification and rebuild suites; fixed two notes at 64/256/1,024 ordinary ancestors. |
| P55-07–09 | Exact unread input, already-local/late companions, stale choices, local-health failure, bounded named worker, same-root Retry completion and an actual held accessor with an independent contender. |
| P55-10–14 | Complete initial/general read-only previews, page/digest/closure failures, partial selected intake, committed-import reopen retry and explicit creation; existing P5.3 fresh/rejected/independent bootstrap coverage remains applicable. |
| P55-15–18/21 | Moved/replaced passive association, entered-accessor reassociation, actual association SQL commit/write/sync cuts, ambiguous readback and a second recovery failure. |
| P55-19 | Fresh-process edit/Delete then older-root association preserves newer history, current values and authoring context. Existing Phase 3 and P5.3 suites cover later causal branches/Restore/copies; these separate checks are not a single whole-protocol refinement proof. |
| P55-22/24 | Restricted-construction/decoding/isolation probes, actual wrong-owner/session consumers, exact envelope/hash/SQL observations, encrypted synthetic marker scans and orderly resource settlement. |

`tools/test-storage-startup-process.py` runs 18 fresh-process schedules, both
profiles, using only normal selection/unlock and surviving resources in recovery.
Independent SQL inventory, exact hashes, canonical history decoder, association
device/file identity, settings, current values/context and unrelated file checks
are kept outside the production opener. Actual cuts distinguish before commit,
after commit/before callback, write and sync failures. Failed recovery is repeated
before healthy retry. Process termination is not simulated power loss or later
corruption.

Final source passes 43 focused functions in both debug and optimized builds,
including both provider profiles, real held accessors, complete startup work counts
and presenter/driver consumers (`/tmp/nv-p55-presenter-final-debug-focus.log` and
`/tmp/nv-p55-presenter-final-release-focus.log`). All 18 fresh-process schedules
pass on local arm64 macOS 26.6.2, Intel macOS 14.8.9 and Intel macOS 11.7.11:
`/tmp/nv-p55-presenter-local-process.log`,
`/tmp/nv-p55-presenter-mini-process.log` and
`/tmp/nv-p55-presenter-orbb-process.log`. The remote observer protocol carries
inspected reports and verification replies only; recovery receives normal
selection/unlock inputs rather than the observer's expected notes or acknowledgments.
Orbb uses the previously documented isolated concurrency runtime and compiler
workaround; this qualifies execution on that OS, not default release packaging.

Twelve isolated controls reached their designated runtime assertions:
generic wait, omitted local membership, late gating, wrong choice owner, omitted
preview digest, skipped binding write, missing publication reservation, truncated
named attempts, stale Retry evidence, misclassified acceptance/current-row lag
and lost attaching-worker handoff, plus self-generated presenter hints. The ten-control campaign and final handoff
control are `/tmp/nv-p55-mutations-final-source.log` and
`/tmp/nv-p55-attaching-mutation.log`. Their production paths remain unchanged by
the subsequent presenter-origin correction. The actual-presenter control passes
its companion and reaches the intended failure in
`/tmp/nv-p55-presenter-mutation.log`. Setup/compiler/unrelated
failures never count as killed mutations.

Native root C diagnostics/static analysis and ASan/UBSan pass, including exclusive
creation, physical identity and contender checks (`/tmp/nv-p55-native-root.log`).
The final presenter bridge additionally passes Clang static analysis with strict
conversion/sign/alignment diagnostics (`/tmp/nv-p55-presenter-c.BNSJsC`). An
ASan/UBSan-instrumented independent peer completes real coordinated write/move
through the final production owner (`/tmp/nv-p55-presenter-peer.pz4PBv/result.log`).
Final source passes 42 instrumented-SQLCipher/AddressSanitizer Runtime functions
and 34 ThreadSanitizer startup/bootstrap/presenter functions
(`/tmp/nv-p55-presenter-final-asan.log`,
`/tmp/nv-p55-presenter-final-tsan.log`). The SQLCipher instrumentation campaign
also checks a valid native handle and catches the intended expired-handle control.
ThreadSanitizer covers Swift and the presenter bridge; its SQLCipher dependency
is the ordinary pinned build rather than the separately instrumented ASan build.

Linux arm64 Swift 6.4 passes 35 final-source debug startup/bootstrap/driver functions
(`/var/lib/nv-storage-test-volume/nv-p55-linux-final-source-debug.log` on the VM).
Darwin presenter/coordination functions remain separately qualified on macOS.
The two-job Linux build exhausted memory; the passing build uses one job with
the same compiler checks. All 18 Linux fresh-process schedules also pass with the
independent decoder on this Mac (`/tmp/nv-p55-linux-debug-process-correct-path.log`).
The first launch command followed a stale SwiftPM convenience symlink; the passing
command names the verified native executable under
`.build/aarch64-unknown-linux-gnu/debug`. The preserved executable/resources are
`/tmp/nv-p55-linux-debug-qualified-se15mbds` after removing completed build outputs.
Optimized Linux passes the same 35 behavioral functions and all 18 fresh-process
schedules (`nv-p55-linux-final-release-focused-repeat.log` on the VM and
`/tmp/nv-p55-linux-final-release-process.log` on this host). The separate
64/256/1,024-ancestor work case passes both profiles with its original five-minute
test watchdog and all fixed-count assertions
(`nv-p55-linux-final-release-work-after-cleanup.log` on the VM).
The optimized executable passes PIE, W^X, nonexecutable-stack and RELRO checks,
including the executable-permission negative control
(`nv-p55-linux-final-elf.log` on the VM).

The first long optimized Linux campaign ended without a final test result and is
not counted as a pass. A subsequent isolated work run reached actual `SQLITE_FULL`
while constructing synthetic history; its pending commit was reported as failed,
not acknowledged. Removing verified inactive older compiler outputs supplied
headroom for the unchanged passing rerun. Inventories/logs preserve the exact
cleanup scope; current binaries, source, fresh-process and failed-run evidence
were preserved. These are process/disk-resource results, not inferred power-loss
or provider failures.
An initial Linux compiler-boundary run reaches ordinary-client checks and several
same-module checks, then exceeds one probe's 90-second limit while the optimized
dependency build is active. It is an incomplete campaign, not a compiler rejection
or passing probe. Its isolated optimized rerun passes all 116 ordinary-client,
same-module and actual-file checks with the same timeout and diagnostic rules
(`nv-p55-linux-final-root-types-release-repeat.log` on the VM). Final Linux
startup/bootstrap/root source hashes match the qualified source table above.

## Work bounds

The fixed-two-note healthy launch witness observes zero historical record reads,
graph loads and ancestor walks; exactly two current-cell decodes, 45 SQL statements
and two required leaves at each of 64/256/1,024 ancestors under both profiles.
This qualifies indexed logical startup work, not constant physical database-open
latency: journal recovery and filesystem/page costs remain outside those counters.
Provider acquisition and background verification are measured separately.

## Scheduling model

`CollectionStartupAssociationSafety` has 23 completed outcomes: seven exhaustive
finite safety/conditional-progress cases, nine exact defect counterexamples and
seven reached-path controls. Controls include Work Offline while an accessor is
held, saving before return, two readback failures, committed restart and canceled
adoption. Safety assumes no cloud fairness or eventual accessor return; the
configured progress check assumes finite storage failure and actual eventual
return. Complete closure, truthful named observations, physical identity and
atomic SQL are explicit inputs connected to executable witnesses, not proved
Apple API properties. [Model guide](../../../tla/README.md#integrated-startup-and-association).
The final 23-case run is `/tmp/nv-p55-tla-final-source.log`; the accessor-driver
companion has 17 completed outcomes in `/tmp/nv-p55-accessor-tla-final.log`.

## Qualification commands

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter collection'
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-startup-process.py --binary /absolute/path/NVStorageProbe
python3 tools/test-storage-root-types.py --modules /absolute/path/Modules
python3 tools/test-storage-runtime-mutations.py --help
python3 tools/test-storage-root-c.py
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter 'collection|repositoryDriver'
python3 docs/tla/check-collection-startup-association.py --java /absolute/path/java --jar /absolute/path/tla2tools.jar
```

The common driver requires discovery of the new startup/bootstrap tests and runs
the fresh-process schedules. Compiler probes require marked-line rejection and
valid companions in ordinary-client and same-module contexts. Mutation selection
uses the runner's exact `--only` names; the report records actual executed cases.

The final optimized Core, Runtime, private-state and root compiler campaigns all
pass, including same-module and actual-file construction/isolation challenges.
The separate final reruns are `/tmp/nv-p55-final-release-runtime-types-retry.log`,
`/tmp/nv-p55-final-release-private-types.log` (29 checks) and
`/tmp/nv-p55-final-release-root-types.log` (116 checks); Core results are in
`nv-storage-phase2-neaobomg/core-types.log`. Runtime's complete campaign retains
its own counted-case assertion, visibility-classifier controls and stricter SIL
checks around actor isolation and final native-handle release. The earlier
aggregate timeout is not substituted for any of these passing results.
The final debug root campaign also passes all 116 checks
(`/tmp/nv-p55-final-debug-root-types.log`); Linux's complete equivalent passes as
recorded above. The final debug Core campaign also passes in the completed
process follow-ups below.

Remote process execution with the independent decoder on the current host:

```sh
python3 tools/test-storage-startup-remote.py --binary /tmp/qualified/NVStorageProbe --ssh-target scrod@scrodmini.local --ssh-key /tmp/scrodmini_ed25519
```

For Orbb, use its independently staged Intel binary and the previously qualified
isolated concurrency runtime via `--probe-env DYLD_LIBRARY_PATH=/tmp/runtime`.
That is an execution qualification workaround, not a release distribution claim.

Signed headless application tests:

```sh
python3 tools/test-storage-apple-startup.py --local-binary /absolute/path/NVStorageProbe
python3 tools/test-storage-apple-startup.py --local-binary /absolute/path/NVStorageProbe --remote-binary /tmp/qualified/NVStorageProbe --ssh-target scrod@scrodmini.local --ssh-key /tmp/scrodmini_ed25519 --repository-parent '/Users/scrod/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing' --timeout 600
```

These LaunchServices/ad-hoc signed tests create only fresh synthetic P55-* roots.
They exercise actual integrated create/preview/bootstrap/edit/Delete, named
materialization observation, Retry, older-root Re-open and fresh exec. Requested
eviction is recorded separately from observed unread evidence. A provider that
supplies readable bytes qualifies the no-gate companion, not Work Offline under
real disconnection. No account-full stimulus, provider-private control or user
file mutation is used. Initial harness failures separated descriptor/segment
namespaces and made each restarted controller's FIFO/configuration/trace unique;
they were test errors, not Apple or Runtime contract violations.

The final passive-observer runs pass both profiles locally and over real two-Mac
iCloud delivery (`/tmp/nv-p55-apple-passive-observer-local.log`,
`/tmp/nv-p55-apple-passive-observer-two-mac.log`; artifacts
`/tmp/nv-p55-apple-startup-u5qd69sj` and
`/tmp/nv-p55-apple-startup-98t8_t62`). Segment bytes in the live test travel only
through iCloud; SSH transfers the executable, resources, harness and ordinary
selection/control inputs. Each receiver completes a verified read-only preview,
complete import, bidirectional edit/Delete, retained-root Retry, older-root
Re-open and fresh-process reconstruction. Independent SQL/envelope/hash observers
check retained membership and exact current values/context. In the final live run,
both profiles expose an actual initial unread named object after requested eviction
and exercise Work Offline before the exact bytes are received normally. This
qualifies that observed materialization schedule, not account-wide disconnection
or quota exhaustion.

An earlier observer called checked host publication every time it requested
status. Publication legitimately starts queued background work, making that
measurement interfere with its own idle predicate. A live thread sample showed
settled workers; the corrected harness reads transport status independently.
Another 300-second live run timed out before the bootstrap files were visible;
later independent inspection found all exact files. The passing rerun uses a
600-second whole-observation window, retaining the Runtime's original three-attempt/
15-second named retry bounds and every exact value/byte assertion. File checks
now propagate access errors rather than treating them as absence. Neither test
failure establishes an Apple contract violation.

## Qualification outcome and later consumers

The final full debug Swift suite passes 426 functions in two suites
(`/tmp/nv-p55-final-common-debug-repeat.log`, artifact
`nv-storage-phase2-onbtbaka/swift.log`). The subsequent 40-schedule received-snapshot
process campaign exceeded the driver's 900-second aggregate limit after 34
completed schedules; that aggregate run remains incomplete. The optimized common
driver completes all process campaigns, including all 40 received-snapshot and
60 connected Phase 3 schedules, then reaches its former 900-second compiler-campaign
limit without an individual compiler-probe failure. Neither wrapper timeout is a
passing aggregate result. The independent optimized compiler campaigns and Linux
qualification now pass. The separate debug received-snapshot rerun passes all 40
schedules with unchanged per-child checks
(`nv-p55-debug-process-followups-rsyemrln/received-snapshot.log`). All 26 debug
bootstrap/reconstruction schedules also pass, as does the final debug root compiler
campaign. All 13 remaining debug process/Core campaigns pass independently in
`nv-p55-debug-process-followups-rsyemrln/results.json`: received snapshots,
bootstrap/reconstruction, private repair/backup, current-row maintenance,
restoration, merge, all 60 connected Phase 3 schedules, scoped queries, all 18
startup schedules, eight generated schedules covering all six fault classes,
18 rejection schedules, cold cipher opening and Core compiler boundaries.
Each recorded command returns zero and retains its own independent byte/SQL/value
observations and individual watchdogs.
A prior full debug campaign hit its 3,600-second
whole-suite resource budget under concurrent qualification load. Its 7,200-second
rerun preserves each test's existing watchdog, discovery and correctness checks;
the timeout is not a passing result. The broad optimized Swift suite passes 425
functions before the presenter-origin delta; all 43 affected final-source optimized
functions pass separately. All 18 independent common-driver tail commands pass:
schema equality/tests, 12 independent record fixtures, envelope/current-row/
descriptor fixtures and strict owner/fault C diagnostics
(`nv-p55-tail-qualification-assn_vu7/results.json`).

The common driver now assigns a 3,600-second aggregate budget to the complete
40-schedule received-snapshot campaign while preserving every child's 120-second
watchdog. Its compiler-campaign budget is separately configurable through
`--compiler-suite-timeout` (default 3,600 seconds); individual marked-source-line,
required-diagnostic, nonzero-discovery, companion and 60/90/120-second probe checks
are unchanged. `--suite-timeout` separately controls the whole Swift-suite budget.
All budgets must be positive. Help and invalid-budget parser checks pass. A larger
aggregate budget supplies execution resources; it cannot turn an unfinished or
incorrect individual check into a pass.

Together the original completed components, explicit final-source affected-suite
reruns, compiler campaigns and independent tail/follow-up campaigns cover the
common driver's required checks. This is component qualification, not a claim
that either previously timed-out aggregate wrapper produced a passing result.
No individual assertion, companion, diagnostic, discovery check or fault class
was removed to complete it. Final source hashes match the table; Python harness
syntax and `git diff --check` also pass.

P5.6 supplies transparent physical repair/replacement/copy. Phase 6 supplies
plaintext reconciliation; Phase 7 supplies AppKit choices, application-wide
admission and quit/folder switching. The approved fresh deep-HFS+ limitation,
default distribution signing/runtime packaging, supplemental filesystem/OS
stimuli and physical power-loss qualification retain their explicit gates.
Epoch-4 sources and synchronous UI/search are unchanged. The epoch-4 compatibility
script was not rerun for this headless increment; no new legacy-compatibility pass
is claimed. `build.sh` encountered Xcode 27's legacy deployment-target diagnostic.
The equivalent app build passes with the previously approved
`__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` setting
(`/tmp/nv-p55-app-build-workaround.log`), with existing warnings retained.
