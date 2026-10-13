# Snapshot retention coverage: validation

Date: 2026-10-08; format clarification 2026-10-13. Implemented within the portable Runtime boundary.
The 2026-10-08 complete debug/optimized Swift suites and both 44-command integrated inventories
passed. The
[plan](snapshot-retention-coverage.md) and
[wire/acceptance contract](../general-snapshot-record-contract.md) define the increment.

The 2026-10-08 executed campaigns below used an unreleased development encoding.
The current format incorporates retention parents directly into v1 and removes
the superseded encoding branches. The [single-v1 qualification](general-snapshot-v1-validation.md)
records checks rerun against the current bytes. Earlier platform/timing results
remain evidence for their recorded revision, rather than a claim of rerunning
those platforms after the format correction. No segment format has shipped;
epoch-4 opening, recovery and explicit export remain the compatibility boundary.

## Production mapping and guarantees

`GeneralSnapshotV1.write` emits general-v1 roots and streams. The
236-byte root commits eight category counts and the v1 SHA-256 stream
digest. Tag 8 carries sorted, unique, exact 56-byte retention-parent locators
through the existing bounded data/index pages. Empty parent sets have a zero
eighth count in the same layout. Page and initial-bootstrap encodings retain
their existing layouts. Independent Python literal fixtures and the independent
Node history inspector require the single current v1 layout.

`GeneralSnapshotCapture` reads the accepted snapshot-root frontier and acceptance
prefix in one owned database turn. Its frozen inputs survive later independent
root acceptance. File-private `CheckedRetentionParents` opens each exact,
supported, accepted root under the collection's protection context. Issued
`CheckedSnapshotAcceptance` binds connection/store/prefix and rechecks each exact
sealed parent at the actual acceptance consumer. Accepted parent closure is
reused; this introduces no recursive parent-induced ancestor walk or persistent
validation cache.

Receive requirements use `preview.requiredLocators`, combining logical-cut
inputs and explicit retention parents while preserving their distinct meanings.
The existing transaction commits root/pages, accepted membership, exact
dependency edges, maximal retained frontier and reverse-wait wakeups together.
Only explicitly covered tips disappear. All ancestor bytes remain retained;
later independent tips survive and can be covered by a subsequent fan-in.
Missing parents park, and a rejected/unsupported prerequisite blocks its child
under the existing diagnostic without rejecting that child.

Reconstruction still validates the selected logical cut, complete groups and all
accepted history outside that cut. Covering a newer-cut root with an older-cut
snapshot preserves the later edit, its Undo context and original bytes. One
checked logical traversal is shared within a reconstruction attempt; separate
attempts remain separately measured. Known required-history damage, on-demand
ancestor checks and durable verification reminders keep their existing outcomes.
The schema, public Runtime method signatures and initial bootstrap are unchanged.

## Independent observations and difficult paths

The nine normal `SnapshotRetentionTests` functions run both profiles. They cover
sequential chains and repeated reopening; concurrent roots and stale captures;
delayed parent chains and durable wakeups; different represented cuts; empty parent sets
and wide fan-in; wrong kind/locator/collection, missing/corrupt parents;
unsupported-parent isolation; damage between proof and consumer; and shared
reconstruction work. Independent graph traversal computes both maximal tips and
their reachable accepted closure. Tests inspect exact bytes, membership, values,
editing context, conflicts and Undo candidates alongside Runtime outcomes.

The 22-case snapshot process driver runs with three preceding covering roots.
It terminates around candidate retention, acceptance and materialization and
injects ENOSPC/EIO/ambiguous synchronization. Each fresh child receives only
surviving storage and normal selection/unlock inputs. The parent independently
reads SQL and decodes protected envelopes: either prior coverage survives, or the
entire new root/page acceptance unit, edges and frontier survive. Committed work
survives a missing completion callback. Existing later edits remain present.

The six-case delayed-parent driver delivers newest roots first, restarts while
their exact parents are unavailable, then supplies the oldest root normally,
with a lost callback, or with commit EIO. Before recovery it inspects complete
root/page membership, same-batch sequence, exact parent edges and independent
maximal tips. After recovery it requires exact chain completion and wakeup
settlement, unchanged notes/operations, byte-for-byte retention, duplicate
idempotency and a second fresh reconstruction from damaged derived rows.

All five targeted Swift mutations pass qualification in one optimized campaign,
with passing companions and nonzero discovery.
They challenge unverified parent kind, clearing independent tips, omitted parent
dependencies, an uncommitted receipt and skipped final parent checks. Each must
fail at its designated assertion; compiler/setup failures never count. The first
frontier control affected bootstrap setup, and its next revision used a member
unavailable on the helper's tuple. Its corrected root-only mutation compiles and
fails at the strict concurrent-frontier assertion. Those failed campaigns remain
preserved. Malformed-root fixtures preserve the complete count layout so their
digest/rejection and unsupported-prerequisite checks exercise the current format.

## Executed qualification

| Campaign | Result |
| --- | --- |
| Local arm64, Swift 6.4 | Both complete Swift suites report 312 functions: 306 execute/pass, six opt-in benchmarks skip, and zero known issues. Debug/optimized times are 1,750.619/1,299.757 seconds. Both integrated 44-command inventories pass, including all 22 retention-prefix process schedules, six delayed-parent schedules, 132 Runtime compiler probes and the existing process/schema/fixture/C-boundary checks. |
| Intel Mac Mini, macOS 14.8.9 | The same 22 + six fresh-process schedules pass for both profiles, including the final strengthened pre-recovery atomicity assertions. |
| Intel macOS 11.7.11 | The same 22 + six schedules pass with the documented metadata workaround and isolated concurrency runtime. |
| Ubuntu arm64, Swift 6.4 | Optimized affected suite reports 13 functions: 12 pass and the opt-in benchmark is skipped. All 22 + six fresh-process schedules, 16 focused construction/actor probes, independent draft fixtures and 19 schema tests pass. PIE/W^X/non-executable-stack/RELRO checks pass and the RWX observer control is rejected. |
| SQLCipher instrumentation | ASan-instrumented production Runtime passes the six targeted codec/retention/consumer/reconstruction functions; valid-handle companion passes and the expired-handle control fails at the intended diagnostic. |
| TLA+ | All 17 final retention outcomes, 20 existing reconstruction outcomes, and 15 existing receive-assembly outcomes match their expected results. One contended assembly run timed out; its unchanged larger-time-budget rerun completed all 1,122,253 states. |
| Application build | `xcodebuild install` passes with the existing `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` setting and the existing 11.5 deployment warning. |

Intel qualification uses the recorded compiler workaround, rather than qualifying
default compiler metadata or final macOS 11 packaging. Source transfer and all
remote test artifacts stay in owned temporary/test-volume directories. The
independent envelope oracle stays in the parent, outside recovery.
The first Linux construction attempt overlapped an optimized build and exceeded
the existing 60-second compiler watchdog. Its standalone rerun passes with the
same watchdog, diagnostics, strict concurrency/memory-safety and marked-line
checks. No compiler or implementation contract was weakened.

## Production work and timing

The optimized opt-in `snapshotRetentionProductionBenchmark` measured real
retention-parent encodings/acceptance at 1, 8, 64 and 256 snapshots with two unchanged notes.
Returning opens inspect **one retained root**, load no historical Changes
envelopes and construct no graph. Every save performs two direct parent checks
(issuer and consumer), with **zero ancestor traversals**. Reconstruction builds
one logical graph and performs two direct parent checks for the selected root.
Wide fan-in of 64 accepted roots performs 128 direct checks, then reopens with
one retained tip. All measurements assert those work counts.

| Snapshots | Public-profile warm open median | Encrypted-profile warm open median | Public / encrypted reconstruction |
| --- | --- | --- | --- |
| 1 | 3.31 ms | 6.04 ms | 29.20 / 58.96 ms |
| 8 | 3.17 ms | 5.78 ms | 27.16 / 31.40 ms |
| 64 | 10.23 ms | 9.56 ms | 27.77 / 27.64 ms |
| 256 | 14.85 ms | 13.68 ms | 23.84 / 26.79 ms |

These are descriptive warm-cache measurements during other qualification work.
They are not a controlled wire-layout comparison, cold disk-read test or a constant-time
whole-open claim. Journal recovery and other existing SQL work remain in the
measured open. Ordinary chain capture/save medians are roughly 13–20/51–66 ms
after the initially slower encrypted run; fan-in saves took 72.90/58.06 ms.
Capture still checks logical history. The guaranteed improvement is elimination
of sequential root-check growth and parent-induced ancestor walking, not a claim
that all recovery or capture work becomes independent of lifetime history.
Exceptional reconstruction still reads accepted-root candidate metadata and
validates logical history. Only the selected snapshot's assembly is opened;
this increment bounds parent-induced traversal rather than every recovery query.

## Model correspondence and limits

`SnapshotRetentionCoverageSafety` has two stores and initial/a/b/join roots.
It separates frozen parent sets and logical cuts, byte delivery, parent proof,
atomic membership/edge/frontier updates, completion, idempotent retry, precommit
failure and restart. Independent maxima and reachability calculations check
complete retained coverage; action properties preserve capture, bytes, note
values and final parent revalidation. Four exhaustive safe scenarios cover
equal/differing cuts, unsupported input and post-proof damage. Six mutations
produce the specified counterexamples; seven witnesses reach concurrent tips,
different cuts, lost callbacks, fan-in, failed-then-successful acceptance and
damage after preparation and a supported child blocked by an unsupported parent.
That last scenario supplies a newer producer: its parent is usable there but
unsupported on the older receiver. The unverified-parent mutation keeps the
child's own format check, so its failure isolates unverified coverage rather
than merely accepting an unsupported root. The largest new check explores
504,964 states.

One root identity abstracts its complete protected root/page closure. Codec and
process checks and `ReceiveSnapshotAssemblySafety` supply page/byte evidence;
`SnapshotReconstructionSafety` supplies logical cut/tail recovery checks. SQL
transaction atomicity and previously validated parent closure remain concrete
inputs. There are no depth/state constraints; one crash and precommit failure
per store bound this safety/reachability experiment. It proves neither arbitrary
history liveness nor hardware power-loss durability.

Pruning, snapshot scheduling, provider/UI integration, automatic VACUUM and
physical power-loss qualification remain outside this increment. Concurrent
independent width, cold I/O and journal costs retain their own measurement gates.

## Artifacts and reproduction

- Production measurements: `/tmp/nv-retention-benchmark.log`.
- Local integrated inventories: `nv-storage-phase2-2dj6t539` (optimized)
  and `nv-storage-phase2-p5_ufrg_` (debug): all 44 commands pass in each.
  Logs: `/tmp/nv-retention-phase2-release-final.log` and
  `/tmp/nv-retention-phase2-debug-final.log`.
- Local process cases: `nv-snapshot-process-qnhnhmta` in the local temporary
  artifacts directory; strengthened delivery: `/tmp/nv-retention-delivery-hyptweum`.
- Mac Mini: `/tmp/nv-snapshot-process-nyraib7z`,
  `/tmp/nv-retention-delivery-ifyo1e0w`; probe `/tmp/nv-retention-mini.aJYdAC`.
- Orbb: `/tmp/nv-snapshot-process-u_asz_m5`,
  `/tmp/nv-retention-delivery-bzfndauj`; probe/runtime `/tmp/nv-retention-orbb.OTV1uz`.
- Ubuntu: `/tmp/nv-snapshot-process-k394m8bi`,
  `/tmp/nv-retention-delivery-bppz_y1u`; source/build under
  `/var/lib/nv-storage-test-volume/nv-startup-scope.M2juR3`.
- Instrumented SQLCipher: `nv-cipher-sanitizer-7d_d84u5`; final optimized
  five-control mutation campaign: `nv-runtime-mutations-36msgaq8`.
  Earlier qualified controls remain in `nv-runtime-mutations-b9oft89v`
  (four valid controls) and `nv-runtime-mutations-j8xnuy44`
  (corrected concurrent-tip control).
- Final strengthened model: `nv-improvements-tla-e1unmjxp`; original 16-case
  model campaign: `nv-improvements-tla-upyo129y`; reconstruction:
  `nv-reconstruction-tla-cnwd_sbb`; receive assembly:
  `nv-receive-tla-f_d7a7e_` plus completed unchanged rerun `nv-receive-tla-mi_adb9z`.

The integrated driver is `python3 tools/test-storage-phase2.py --configuration
debug` (repeat with `release`). New standalone process entrypoints are
`test-storage-snapshot-process.py --binary <probe> --retention-prefix 3` and
`test-storage-retention-delivery.py --binary <probe>`; both also support the
approved SSH test hosts. The new model uses
`docs/tla/check-improvement-models.py --only retention` with the documented Java
and TLC paths. Strict work benchmarks require `NV_RETENTION_BENCHMARK=1` and the
`snapshotRetentionProductionBenchmark` Swift Testing filter in an optimized build.
