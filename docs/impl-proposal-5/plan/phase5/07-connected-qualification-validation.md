# P5.7 — Connected qualification ledger

Started: 2026-10-14. Status: **implemented and qualified within the limits below**. The
[P5.7 plan](07-connected-qualification.md) defines the obligations; requirements
and executed evidence remain separately identified.

## Evidence baseline and reuse

P5.6's final production source is the starting point. Preserve its
[qualification ledger](06-repair-replacement-and-copy-validation.md), including
the first failures, actual source hashes, signed two-Mac results and platform
limits. New connected tests reuse existing real issuers and observers. Exact
production/harness inventories and binary hashes accompany each new campaign;
the dirty checkout's commit ID alone is insufficient provenance.

| Obligation | Existing component evidence | New connected work |
| --- | --- | --- |
| S1 retention, dependencies, stale completion | Receive/ordinary-save and process-cut suites | Two-parent repository delivery plus interrupted recovery; live pending generations |
| S2 discovery continuity | P5.3 batches/transport and P5.4 adapters | Empty pass, later prerequisites, renamed duplicates and restart |
| S3 startup/progress | OptionalStartup and P5.5 admission | Actual collection publication, optional queue and finite local interference |
| S4 repair/copy/switch | P5.6 complementary fresh-process, 62-case Linux slice and signed repair/copy | Additional composed recovery/interference schedules; preserve occupied source |
| S5 causal actions | Phase 3 independent wire/SQL and causal models | Same histories through real repository consumers, old backups and third writer |
| S6 owner/accessor lifetime | P5.4–P5.6 entered-accessor, root and switch checks | Joined local save, late completion and fresh recovery |
| Compiler and mutation boundaries | P5.6 root/private probes and targeted defects | Affected boundaries and new witnesses; existing cross-product unchanged |
| Platform/scaling/privacy | Part ledgers and growth witnesses | Source-impact audit plus uncovered connected observations |

Unchanged component evidence retains its recorded responsibility and platform
scope. It does not establish the new connections or certify a changed executable.
No storage policy, public API or format change is authorized by this ledger.

## Execution

### Reviewed reuse boundary

At the initial baseline, comparison with the P5.6 final mutation report
`nv-runtime-mutations-u76yu_17/results.json` with this checkout: all **180
production/vendor files and 126 existing test inputs** match exactly, with no
production additions. The P5.6 signed repair runner hashes to
`073acd80f5378e6311a354eb384d843879929d20b11f283f2ef0725e514897c1`.
P5.7 adds tests, their target membership, controller/observer code and mutation
registrations. The connected campaign subsequently found and corrected one
publication-driver scheduling statement, documented below. The other 179 production/
vendor files retain that baseline. There is no storage protocol, constructor-access,
compiler-flag, schema, dependency or Apple API fallback change.

Accordingly retain P5.6's completed compiler/private/root boundaries, growth
counts, native volume/loss/sanitizer controls, legacy/app checks and signed
repair/copy/Undo witness at their recorded revisions. This is **component-result
reuse after an input-impact review**, not a claim that the new test bundle ran
there, and not a fabricated `qualification_reuse.py` cache hit. New executable
scenarios always run. The changed driver is requalified in debug/optimized tests,
its new targeted mutation, instrumented sanitizer execution, Linux, macOS 11 and
signed two-Mac iCloud execution. Existing TLA+ results keep their finite model scope.

### New connected witnesses

`Phase5ConnectedTests.swift` belongs exactly once to
`NVStorageRepositoryTests`. Its four functions / fourteen cases cover both profiles:

- Six delayed acceptance receipts meet a newer edit, an equal-body new generation
  or Delete; exact historical E remains, rooted remote R arrives, stale host
  publication is rejected, F remains pending until its own receipt, and fresh
  opening preserves F/R.
- Four actual `CollectionSession` publications catch up required Changes while
  optional snapshot validation and provider acquisition are held. The failed
  host-callback companion retains ready admission. A local save completes before
  release; snapshot acceptance follows without another delivered object.
- Two actual repository-driver cases park a two-parent child, reopen, then
  deliver the remaining parent. Two deliberately interfering saves exhaust
  validation's immediate attempts. The live receiver registers its save wait;
  save completion resumes acceptance and current-row materialization. OS hints
  are detached for this test and the ordinary revisit is set beyond its watchdog.
- Two multi-batch publication cases hold an early batch, commit a later edit,
  observe its actual save notification, and then release the batch. With no new
  hint or timer, both the exact file and the real publication result must appear.

The process runner executes real `NVStorageProbe` issuers in fresh processes.
The default manifest has **56 cases**: two profiles × (18 fixed-history
dependency permutations/cuts, callback-loss plus a second recovery failure,
two backup/Restore orders, reciprocal copies, two reviewed-compensation orders,
and four generated schedules). All six dependency orders share the same sealed
history per profile and own separate mutable receiver stores. The final S5
backup/Restore and reviewed-compensation orders likewise clone the same checked,
closed authored stores; each case has independent mutable roots and stores. Generated cases
author eight actions across three writers, optionally add a snapshot, and retain
every exact envelope, seed database, selected input, order and cut in
`wire-schedule.json`. The independent observer owns expected values; recovery
children receive only surviving storage and ordinary inputs.

`--replay` selects the same logical cases with newly recorded authoring IDs.
`--replay-wire` validates frozen-input hashes and reuses the *same* IDs, bytes,
initial store and cuts in a fresh physical directory. This distinction matters:
a random seed alone does not reproduce distributed identity ordering.

### Completed local runs

| Check | Result and raw evidence |
| --- | --- |
| New Swift debug | Three functions / 12 cases passed in 20.836 s; `/tmp/nv-p57-debug-final.log`. Target inventory also passed: 76 Runtime source files exactly once across three modules. |
| New Swift optimized | Same three functions / 12 cases passed in 12.600 s; `/tmp/nv-p57-release-final.log`. |
| ASan + instrumented SQLCipher | Three functions / 12 cases passed in 24.124 s, plus the native valid/expired-handle controls; `/tmp/nv-p57-asan.log`, `nv-cipher-sanitizer-mcvsd80f/runtime.log`. |
| Observer controls | Twelve designated manifest/value/byte/cut/prefix/retention checks reject their altered inputs and accept companions. The two additional cut controls distinguish pre-commit from post-commit state before retry. They supplement, rather than stand in for, reached production effects. |
| Exact frozen replay | Encrypted generated seed 1 passed with exact prior bytes/cut; `/tmp/nv-p57-wire-replay.log`, `nv-p57-wire-aiztrjxt`. |
| Process pilots | Four connected schedules passed in `nv-p57-connected-cahyhfxr`; generated public-0/encrypted-1 in `nv-p57-connected-1ylj8522`; reviewed compensation and fixed-history encrypted dependency pilot in `nv-p57-connected-7jt90pop`. |
| Optimized full manifest | All 56 cases passed with stable source/binary and exact manifest completion; `/tmp/nv-p57-process-release.log`, `nv-p57-connected-ys5hhb10`. Probe SHA-256 `bbb1a60c27678ebf37a7df3848d11f8e2e4974d0ae4533df5e23b01742a84327`. The subsequent debug/extended campaigns additionally inspect the raw state immediately after each injected cut, before retry. |
| Debug full manifest | All 56 cases passed, including raw pre-retry commit/parking observations; `/tmp/nv-p57-process-debug.log`, `nv-p57-connected-bp_mtjum/manifest.json`. |
| Extended generated schedules | All 32 cases (seeds 0–15 × both profiles) passed, including immediate pre-retry cut observations, exact retained bytes and independent current values. `/tmp/nv-p57-generated-extended.log`, `nv-p57-connected-qxaxdhvq/manifest.json`; stable source/binary and complete discovery checked. |
| Final same-history S5 companions | All ten cases passed in each configuration after freezing the same authored IDs/bytes across opposite delivery orders: `/tmp/nv-p57-fixed-fixtures-debug.log`, `nv-p57-connected-diwd2g4l`; `/tmp/nv-p57-fixed-fixtures-release.log`, `nv-p57-connected-cr8c24d3`. These supersede the earlier S5 order-pair comparison, which separately authored valid histories. |
| Shared-fixture refactor check | Both selected child-first pre/post-commit cases pass with the final cloning helper and optimized probe: `/tmp/nv-p57-fixed-dependencies.log`, `nv-p57-connected-i7rhqkq6`. The complete six-order dependency matrix above used the same frozen-history rule before helper extraction. |
| Harness/documentation finish | Connected observer controls and signed-runner prefix companions pass. All 13 build/result-reuse tests pass. Index self-tests, regeneration/completeness check and `git diff --check` pass; new cases and all four mutations are indexed. |
| Targeted defects | Clearing newer pending work and skipping live-generation validation both fail their exact connected assertions. `nv-runtime-mutations-eoahoe60` preserves the passing eight-case companion and both results. Interrupted validation also fails its exact registered-wait assertion after attribution correction, with a new two-profile companion: `/tmp/nv-p57-mutation-attribution-2.log`, `nv-runtime-mutations-cbqj26nd`. All existing mutation registrations/cross-products remain. |

The process campaigns use explicit repository delivery and independent fresh
owners; they do not execute the automatic publication loop changed below. Their
unchanged acceptance/recovery/semantic scope remains valid. The final S5 runs also
execute the corrected probe. The original debug/optimized Swift and sanitizer
rows above identify their three-function baseline; the affected driver delta is
recorded separately rather than replacing those records.

### Discovered production defect: a save during a multi-batch publication

The signed exchange first exposed an observer error: acceptance can lead current
rows, so querying the semantic view mid-catch-up can correctly return `staleCapture`.
The runner now polls exact accepted membership, waits for materialization and joins
finite transport before comparing semantic results. It retains every value, conflict,
Undo, byte and fresh-open assertion. Its self-test includes caught-up and lagging
prefix companions. The original failure is `/tmp/nv-p57-icloud-transport.log`.

That correction revealed a real implementation defect on both debug and optimized
builds. A save notification arriving during an early batch set the driver's existing
`again` request. Advancing to the next batch discarded it; the final batch could go
idle at its older fixed history prefix. The new edit remained durable locally but
was not published until another opportunity. Original failures remain in
`/tmp/nv-p57-icloud-settled.log`, `/tmp/nv-p57-signed-local-settled.log` and
`/tmp/nv-p57-signed-local-debug.log`. The deterministic two-profile regression fails
the exact physical-install assertion before the fix (`/tmp/nv-p57-prefix-baseline.log`).

`RepositoryTransportDriver` now closes each nonempty publication drain with an
indexed empty pass. This discovers later accepted work even when its notification
arrived during an older continuation. It uses the existing cursor, reservation and
state enum. The cost is one additional bounded capture/check at a quiet drain's end;
there is no added persistent state, history-body replay or weaker installation check.
Production source SHA-256:
`3be1cf393a85e302350a44e134faac2cdce7417d318dada78d9ae336af187d35`.

| Final correction qualification | Result |
| --- | --- |
| Local debug / optimized affected suite | All 12 connected/driver functions / 28 cases pass, 44.350 / 41.302 s; `/tmp/nv-p57-prefix-fixed-debug.log`, `/tmp/nv-p57-prefix-fixed-release.log`. |
| Targeted regression mutation | Removing the follow-up restores the exact intended two-profile failure, with a passing companion; `/tmp/nv-p57-prefix-mutation.log`, `nv-runtime-mutations-4h93x7q5/results.json`. Existing mutation cross-products remain intact. |
| Instrumented Runtime + SQLCipher ASan | New two-profile regression plus entered-accessor deadline case: two functions / three cases pass in 7.688 s; native valid/expired-handle controls pass. `/tmp/nv-p57-prefix-asan.log`, `nv-cipher-sanitizer-_lfhfj24/runtime.log`. |
| Ubuntu debug / optimized affected suite | All 12 functions / 28 cases pass, 9.689 / 4.523 s; `/tmp/nv-p57-linux-prefix-debug.log`, `/tmp/nv-p57-linux-prefix-release.log`. Same strict production settings and final driver source. |
| Intel macOS 11.7.11 automatic driver | Both profiles pass five automatic saves across stop/restart, exact provider-file bytes and independent fresh opening; `/tmp/nv-p57-orbb-driver.log`, host artifacts `nv-p57-driver-process-5i6r_xzk`. Isolated concurrency runtime remains required. |
| Signed current-arm64 / Intel macOS 14.8.9 iCloud | Both profiles pass actual automatic bidirectional transport, snapshots/retention, concurrent conflicts, Delete/edit preservation, independent exact-byte inspection and fresh reopening; `/tmp/nv-p57-icloud-final.log`, `nv-p54-apple-transport-1gsme00f`. History travels through iCloud, not SSH. |

Final probes: debug arm64
`04018cb8d33ff71b8ea7c5c79fb602288797bc90e507eebec2b9b804a7346ce7`,
optimized arm64
`0e054a7db16491118aac16a15347a2ca62af6d73b7c45053ed1d3051d5141cd6`,
Intel
`d59f7af7878258250c5972dc1414940efffe785fc0a934beeea1a8472f61c337`.
The macOS 11 standalone controller is `/tmp/nv-p57-driver-process.py`, SHA-256
`380e5fea5077a37116d900232291f5c7ebb27dd6e162b8e8228e88e589c0762d`;
its execution uses the existing probe's FIFO driver and normal selection inputs.

The [model correspondence](../../../tla/README.md) now explicitly distinguishes
the accessor-driver model's individual-object abstraction from this frozen-prefix
interaction. The implementation restores its already-required eventual-publication
policy; no safety condition was weakened and no new TLC result is claimed.

### Platform execution

| Host | Actual new execution and bounds |
| --- | --- |
| Ubuntu 26.10 arm64 / Swift 6.4 | Four optimized connected process cases passed (public two-parent pre-commit / generated seed 2, encrypted callback-loss + second failure / reviewed compensation). `/tmp/nv-p57-ubuntu-connected.log`, host artifact `nv-p57-connected-42kp_3o6`. Strict debug runs all three Swift functions / 12 cases in 12.605 s; optimized passes the same cases in 0.933 s. `/tmp/nv-p57-linux-debug.log`, `/tmp/nv-p57-linux-release.log`. Production sources and `Package.resolved` matched before reusing the warm checkout. These elapsed test times use their existing shared setup and are not a cross-host speed comparison. |
| Intel macOS 14.8.9 | Four connected cases passed: public callback-loss/second failure and reviewed compensation, encrypted parked-child post-commit and generated seed 3. `/tmp/nv-p57-mini-connected-relay.log`, host artifact `nv-p57-connected-72o_mdzs`. |
| Intel macOS 11.7.11 | The same four cases passed on the actual VM: `/tmp/nv-p57-orbb-connected-runtime.log`, host artifact `nv-p57-connected-39l7uouo`. The existing isolated concurrency library is configured inside the Python launcher because macOS strips inherited DYLD variables when launching system Python. The documented compiler workaround/minimum-OS packaging limitation remains. |

Both Intel runs execute the existing probe with SHA-256
`b0778ca152205747ed47e0ebe68ebf953edd7e433edb5c80e4116cf0b9a22ff0`.
The Ubuntu optimized probe hashes to
`0493485693c803a2242d8ace8fc2c90c2d10224ff4df126af48ebce01ff2c93f`.
The source transfer bundle hashes to
`5f87c865efefb5a7086fe0fda76702068c509c9c51445f52ea734477317f9e7b`.
Detailed per-command/independent-oracle observations and source inventories remain
on their executing hosts. Intel Node observers ran unchanged on the controlling
Mac through fixed-command loopback SSH relays; the relays were stopped after
successful completion. This is external observation, not remote recovery.

Ubuntu cleanup removed exactly its inactive, verified Linux-swap artifact
`/tmp/nv-storage-disk/p52-qualification.swap` (768 MiB). It contained disposable
swap space, not history or source; test collections and failure evidence remain.

### Preserved first failures and harness corrections

- The restricted local tool sandbox returned `unavailable(5)` acquiring a real
  Foundation root. The exact same synthetic path succeeded under authorized
  native access. Rooted tests run with that access; the failed sandbox pilot
  remains `/tmp/nv-p57-pilot.log`.
- The initial backup fixture edited the independent observer's untouched-control
  note. It now creates a distinct third-writer birth instead. The original
  failure remains `/tmp/nv-p57-pilot-native.log`.
- The first driver witness requested accepted-only bytes for a parked input.
  Its independent SQL observation now reads retained candidate bytes. It then
  exposed an observer ordering error: acceptance can precede current-row
  catch-up. The corrected test proves live acceptance first and waits for the
  actual matching view prefix before the settled semantic comparison. All
  original dependency/save/byte assertions remain. Pilot logs 1–3 are retained;
  pilot 4 and the final debug/optimized runs pass.
- One mutation-harness wait initially assumed a nonexistent test-gate property;
  compilation rejected it. The gate now exposes its own actor-isolated entered
  count. The interrupted/failed campaigns retain their logs. A later attempt
  correctly refused warm-package reuse because Finder changed `.DS_Store`;
  synchronizing that copied metadata restored exact source equality.
- Intel platform attempts first exposed missing observer `argon2Sync` (Node 22)
  and the omitted macOS 11 isolated concurrency-runtime environment. These are
  harness/deployment prerequisites, not a production-storage verdict. The
  independent unchanged Node observer can run on the controlling Mac over an
  SSH loopback relay; all recovery execution and database reads remain on the
  tested host. The relay accepts only reports for that fixed observer command.

### Carry-forward map

| P57 obligations | Existing connected evidence retained; new evidence where needed |
| --- | --- |
| 01–03 | New fixed-history process schedules, second recovery cut and delayed-receipt/host publication test. |
| 04–05 | P5.3 `repositoryDriverRevisitsEmptyPassAndLatePrerequisite`, hint-storm/batch/restart/changed-read/hint-write witnesses; new process orders add actual roots, fresh owners and renamed duplicates. |
| 06–08 | New actual collection publication and driver resumption tests; existing required-bootstrap/rebuild/verification/damage and exact initial/late-disclosure consumers retain their distinct outcomes. |
| 09–10 | P5.6 complementary private/provider process runner, lost diagnosis reminder, repeated acceptance/activation failure, private-group union and `repairPreservesReceiveClassesAndWakesComplementedDependencies`. The latter actually carries parked, unsupported and unaccepted orphan bytes through replacement. |
| 11–13 | P5.6 `repositoryRepairConnectedActivationNamespaceRace`, occupied/source-preservation copy process, changed-source/competing-copy/optional-inventory guards and entered-accessor selection settlement. |
| 14–15 | P5.4–6 `repositoryCoordinationEnteredReadPreservesEditDeleteAndReopen`, wrong-context/late-reply/close exclusion, startup reassociation, and rooted rejection-write failure/blocked-neighbor reopening. |
| 16–18 | New rooted backup/Restore, reciprocal copy and deterministic review-required concurrent-compensation scenarios; third-writer independent actions and exact before/after observations. |
| 19–21 | Unchanged 64/256/1,024 startup, accepted-hint/batch, snapshot-frontier and repair growth witnesses retain exact work assertions; new live driver tests add finite-save interference. |
| 22–24 | Retain unchanged production sink/crypto/native-loss and P5.4–6 signed effects; new process/platform/sanitizer delta and its original failures are recorded separately above. |

## Final seven-gate audit and handoff

| Phase 5 exit gate | Evidence and scope |
| --- | --- |
| 1. Real physical predicates | P5.1–6 native/volume/coordination evidence remains applicable to unchanged primitives. Final signed exchange uses the corrected production driver. Approved fresh deep-HFS+ refusal and ExFAT exclusive-install limits remain explicit. |
| 2. Both-profile connected recovery and causality | Complete debug/optimized finite manifests, extended seeds, same-history S5 companions, independent Node/SQL/byte observers, and second-recovery cuts. Bounds are the enumerated schedules, not exhaustive distributed histories. |
| 3. Local progress and eventual background work | Actual collection publication, held provider/optional work, two interfering saves and the new multi-batch notification regression. All require progress before unrelated hints, timers or cleanup could mask the problem. |
| 4. Ownership and compiler enforcement | Reviewed unchanged private issuers, actor isolation, typed consumers and compiler settings retain P5.6's compiler/root/private probes. New tests obtain real evidence and challenge stale generations; four new mutations fail at their designated assertions. Driver changes remain inside its existing actor. |
| 5. Repair/copy preservation | P5.6's complementary private union, required groups, repeated activation failures, occupied-entry preservation, source-change and entered-accessor switching witnesses remain unchanged. P5.7 adds old-backup/Restore and fresh-owner transport, rather than reimplementing those effects. |
| 6. Executable/platform qualification | Local debug/optimized, fresh-process and instrumented sanitizer checks; Linux debug/optimized; Intel 11/14 probes and actual signed iCloud. Unchanged schema, independent encoding fixtures, native sanitizer/loss controls and compiler checks retain their source-bound results. |
| 7. Privacy, resources, scaling and legacy | Reviewed production sinks add no logging of user data. Signed encrypted-wire markers and exact retention checks remain; test fixtures/oracles are explicitly synthetic. Unchanged indexed startup, metadata/hint batches, 64/256/1,024 growth, bounded copy payloads, lifecycle cleanup and epoch-4/app checks retain their measured component scope. The new final empty pass adds bounded indexed work, not history-proportional startup. |

Phase 6 receives the implemented storage/repository boundaries and these limits;
it still supplies actual plaintext admission, association, expected-generation
projection replacement/removal and pending-decision callers. Phase 7 owns human-
reviewed AppKit/input/resolver/quit integration. Neither is counted as implemented
by this headless qualification. Production macOS 11 packaging (including the
documented compiler/runtime workaround), release security/distribution and physical
power loss remain Phase 8 gates. No broad Apple API violation or universal provider
convergence claim follows from these bounded results.

Physical power loss, application integration, production macOS 11 packaging and
distribution remain later gates, as specified by the plan.
