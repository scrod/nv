# Phase 4 S3/S4: complete bootstrap and current-row reconstruction

Date: 2026-10-03. Implementation is present; qualification results and remaining
limits are recorded below. Authority and planned gates are in the
[S3/S4 plan](phase4-bootstrap-reconstruction-plan.md). Later physical projection,
private-record integration, backup/salvage activation and application adapters
remain separate Phase 4 work.

## Production mapping

`InitialCollectionWriterV1` freezes birth-sorted values and their commitment, then
emits Genesis, packed complete Import groups, ImportComplete, packed initial
pages and the flat initial root. Runtime's dedicated producer seals one output
buffer at a time and waits for candidate retention before advancing.
`InitialCollectionV1.build` remains a small-fixture/convenience adapter.

The shared `InitialBootstrapValidationV1` checks both fixture and store readers.
It retains compact operation/reference facts, actions and final initial rows,
rather than all envelopes or a second dictionary of historical bodies. Exact
references, complete groups, canonical digest, scope maxima and descriptor/Genesis
binding remain required. Its package store variant identifies the original
logical import cut while allowing required transport envelopes to contain later
complete actions. Runtime separately validates those actions against their
declared causal inputs before acceptance.

`BootstrapCandidate` owns the physical lock, connection and staged commitment.
`retain` commits exact compatible bytes independently of acceptance; `resume`
checks the existing selected header. `complete` fixes the selected initial root,
obtains the private checked store-backed batch and atomically commits exact object
membership, occurrences/edges, descriptor/pin and wakeups. Only normal complete
opening returns an editable `LocalStoreSession`. Repeating a chosen root reads
its existing commitment rather than creating a redundant transaction.

`PreparedReconstruction` is file-private with a private initializer. It captures
the actual connection, selected store/descriptor/bootstrap, accepted target and
starting view metadata. It reissues a checked basis from exact accepted general
root/pages and history; absent a general root it verifies the original initial
root. All seven general record classes are compared with represented history.
Outside-cut work is the set of accepted **logical operations** minus represented
ancestry, with whole-action membership. This includes earlier-received branches
and extra groups in the snapshot's addressing envelopes. Unaffected snapshot cells
contribute directly to the installed result; affected scopes and linked
preservation outputs use the same collection reducer as ordinary reduction.
Complete operation and collection-action frontiers are restored separately.

The synchronous installer rechecks owner/header, required history, bootstrap,
target and complete starting view metadata, then replaces all derived cells/context
and issues a fresh epoch in one transaction. Advanced history or another same-
target rebuild triggers repreparation. It preserves accepted history, pins,
independent private groups and presentation/pending ownership. A reconstruction
result is consumed through the existing publication fences; save acknowledgment
remains tied to exact committed generations.

Healthy indexed opening remains separate. Required-state loss and accepted-history
damage retain their repair outcomes; I/O and cancellation retain their original
failure categories. Disposable row damage selects reconstruction. Known history
damage immediately revokes publication even if recording the observation fails.
The new reconstruction path removes the old import-only materializer that could
stamp a complete acceptance sequence onto initial rows without its later effects.

## Connected executable coverage

Both provider profiles use real encrypted private SQLCipher pages. The observer's
expected values and command log stay outside a recovering child. Independent SQL
and Node inspection check retained envelopes, complete memberships/occurrences,
dependency/pin coverage, private generations and exact cells/context.

| Plan IDs | Executable checks and distinguishing observations |
| --- | --- |
| B01/B02 | Literal bootstrap fixture and both readers; zero/two/64/256-note packed imports; authentic wrong count/digest/row/reference/Genesis/profile/action/scope cases with valid companions. The wrong-row test matches the claimed digest to the forged row, isolating exact imported-value verification. |
| B03/B04 | Public candidate close/resume, incomplete root, duplicate retention, concurrent owner/wrong context; production 64/256/1,024-note creation, fresh normal open and an eligible first save with zero ancestor traversals. Independent 64-note child bootstrap at real commit/install cuts. |
| B05/R02 | `bootstrapAndSnapshotPreserveIncidentalOrdinaryGroups`: original imports plus Edit/Delete in one required envelope. General shared-envelope E/F fixture preserves F, sentinel and conflicting heads; a split multi-note cut rejects. |
| R01 | Branches accepted before and after snapshot acceptance, followed by a third-writer descendant; both outside-cut heads and untouched snapshot cells survive reconstruction and reopen. |
| R03 | Late covering Delete retracts only untouched automatic preservation; independent editing/adoption survives later source deletion, with exact identity and retirement checks, snapshot reconstruction and reopen. |
| R04 | Reciprocal copies, copy deletion and subsequent explicit copy slot preserve source/dispositions; Restore provenance and Recently Deleted exclusion survive rebuilding and follow-on history queries. |
| R05/R06 | Native partial compensation → snapshot → further Undo → rebuild → actual Redo. Equal-body rename preserves exact newer revision/scope and real Undo/Redo targets. Existing connected multi-note/review/three-writer reducers remain part of the common suite. |
| R07/R08 | Hold real preparation; accept newer E while host F remains pending; reject old publication. Rebuild twice at the same accepted target, update settings and a nonempty opaque private sentinel while held, require three preparations/two installs and exact private bytes/generations. |
| R09 | Invalid derived cells repair with retained bytes unchanged and subsequent saving. Missing required settings and corrupt accepted Genesis block success/reopen; actual damage revokes preexisting publication. Existing required-page/occurrence and repeated marker-failure cases remain active. |
| R10 | Existing durable assembly/wait/rejection/resumption cases run through the same ready queue and opener; independent work progresses after finite failures/interference, and missing input is distinct from rejected prerequisites. |
| R11 | Healthy current-row/no-old-BLOB tests and growing ordinary history retain indexed opening. Production many-note fresh opens witness fast first saves. Reconstruction counters witness the seed, outside operations, affected/reused cells and complete installation. |

`test-storage-bootstrap-reconstruction-process.py` passed **26 fresh-process
schedules**, 12 bootstrap and 14 reconstruction, across both profiles. Cases
terminate before/after actual commit, after commit before completion, and during
row/view installation; selected cases fail again during recovery. Real VFS EIO
and ENOSPC cases preserve committed history/private state. Follow-on edits use the
actual recovered context. SQL transactions expose complete prior/replacement state,
rather than invented partially visible commits.

The common `test-storage-phase2.py` driver requires discovery of the new gates
and includes this child driver alongside earlier history, snapshot, receive,
Restore, merge, compensation and generated schedules. The larger resource campaign
is explicitly opt-in, separate from discovered-but-skipped test inventory.

## Language boundaries and isolated challenges

Ordinary clients and sibling files try to construct the actual private bootstrap
owner and prepared reconstruction. Existing probes challenge forged accepted
batches/receipts, asynchronous transaction closures, escaped SQL values, mutable
captures and incomplete outcome handling. Actual consumers recheck right-type,
wrong-store/session/view inputs. Production retains Swift 6 strict concurrency,
strict memory safety, warnings-as-errors and actor-isolated synchronous SQL work.

The seven Core bootstrap mutations all reached their designated runtime
assertion. Their controls cover incomplete scope maxima, a wrong imported value,
missing completion ancestry, unchecked digest, wrong Genesis object/profile and
rejection of a valid context. Reconstruction mutations separately challenge
omitted outside work, envelope-as-cut membership, stale accepted target,
same-target epoch, private-state reset and body-only continuation. Each campaign
requires a valid baseline, nonzero required discovery and exact assertion
attribution; compilation/setup failure is a separate nonqualification outcome.

The first mutation run exposed two insufficient witnesses. A later branch touched
the same note and masked omitted outside-cut work; its replacement now asserts the
exact recovered bodies before delivering that branch. An invalid stale installation
could throw before its designated body assertion; its witness now explicitly
requires a completed reconstruction, as well as exact bodies and preparation
counts. All six mutations subsequently failed at their intended assertions.

One initial continuation fixture used a fully no-op action as an automatic Undo
candidate. The actual policy legitimately has no meaningful automatic effect to
undo in that case. The fixture now uses an equal-body rename, preserving its
intended test of distinct history with equal text and a real inverse. Production
Undo policy and assertions were preserved. Setup failures from sandbox compiler
cache access and concurrent compiler resource exhaustion are retained separately.

## Model correspondence

`SnapshotReconstructionSafety.tla` bridges finite complete bootstrap, optional
transport sharing, earlier/later outside-cut history, preparation, atomic install,
final publication and up to two crashes. Its independent value/frontier oracle
checks the fixed graph; a second same-history worker makes the epoch check
non-vacuous. Boundaries map to candidate retention, `acceptStoredBootstrap`,
`PreparedReconstruction.prepare/install` and existing model publication.

The completed runner has six exhaustive safe cases, nine designated mutation
counterexamples and five reachability witnesses, with **162, 838, 26,598, 27,065,
21,540 and 91,602 states** in the safe cases. Positives check history preservation,
install applicability and eventual completion under stated weak fairness/finite
delivery/fault assumptions. Witnesses reach the earlier branch, shared-envelope
extra group, stale refusal, same-history epoch and two crashes. The unchanged
`SegmentBootstrapSafety` and `SQLiteFastStartSafety` families also completed their
safe cases, targeted controls and witnesses.

This bridge assumes valid complete immutable inputs, atomic SQL and the separately
tested reducers. Retained pending input survives its modeled crash; unpersisted
typing is outside that claim. It proves the stated finite graph/schedules, rather
than arbitrary merging, codec truth, cryptography, executor behavior or physical
power-loss durability. No safety assertion or state constraint was weakened to
obtain completion.

## Resource, platform and release limits

The initial codec remains a flat manifest; general roots retain their multilevel
tree. Literal encoding and the exact byte-budget function agree. With one locator
and one frontier reference, 1,048,572 page entries occupy 67,108,824 decoded bytes;
the next entry exceeds the existing 64-MiB payload bound. This is a wire-budget
test, not an allocation/performance test of a million-page collection. Packing
is qualified at ordinary many-note workloads. Oversized complete rows/root
construction fail explicitly while preserving the source/candidate.

Incremental emission bounds owned encoded envelope/page buffers. Final values
and identity/reference metadata remain proportional to imported contents/history.
The complete initial acceptance commit is one synchronous transaction. Exceptional
general verification still constructs a full retained graph; touched-scope reuse
does not claim sublinear total history reads or constant-memory recovery.
Measure encoded-buffer high water, candidate reads, acceptance time, largest
writer turn and end-to-end completion separately in the opt-in resource test.

The optimized opt-in campaign passed all eight cases on the Apple Silicon host
(Swift 6.4, macOS 26.6.2; real pinned SQLCipher). Both profiles encrypt private
pages; the profile column names the provider envelope policy. These are single
runs with concurrent qualification work, rather than statistically isolated
startup benchmarks. Completion includes initial verification, atomic acceptance,
exceptional initial reconstruction and normal reopening.

| Notes | Objects | Largest encoded buffer, public/encrypted (bytes) | Candidate reads, each profile | Acceptance public/encrypted (s) | Complete public/encrypted (s) |
| --- | --- | --- | --- | --- | --- |
| 64 | 5 | 77,294 / 77,278 | 31 | 0.031 / 0.026 | 0.394 / 0.376 |
| 256 | 7 | 245,882 / 245,866 | 43 | 0.129 / 0.049 | 2.575 / 1.847 |
| 1,024 | 14 | 245,992 / 245,976 | 87 | 0.515 / 0.453 | 10.845 / 13.402 |
| 2,048 | 24 | 246,266 / 246,250 | 147 | 1.009 / 1.067 | 24.623 / 26.086 |

The largest measured writer turn at 2,048 notes was 1.065 / 1.125 seconds.
Encoded high water measures the producer's owned output and verified candidate
buffers, rather than claiming a bound on the entire process. Final values,
compact bootstrap facts and the exceptional retained graph remain proportional
to their contents. A thread sample of the slower ASan campaign showed active
per-record decoding of packed envelopes, not a deadlock. Repeated decoding in
the exceptional graph reader remains a performance opportunity; healthy indexed
opening and its zero-ancestor first save remain separate paths.

Instrumentation first omitted these store-backed candidate reads, then counted
receive assembly reads twice when moved to the shared reader. The shared reader
now owns the increment; existing exact receive read-count assertions were kept.
The original creation crash driver also used the second global COMMIT as a proxy
for accepted history. That is now an input-retention commit. Its partial-retention
case remains, and its history-commit cut is armed at the actual acceptance SQL
phase. Two added cases per profile bring that independent driver to 76 checks.

Qualification logs/artifacts remain in temporary directories. The execution ledger
records completed campaigns and their qualification boundaries. Process termination,
later corruption and injected VFS
faults are distinct from physical power loss. Provider I/O, live app publication,
final selected-store activation and the later private/projection codecs remain
their independent release gates.

## Execution ledger

The local compiler is Swift 6.4 from Xcode 27 on Apple Silicon macOS 26.6.2.
All stores use the pinned SQLCipher 4.19.0 revision
`c4b275a47932888216bade83aff2bbc73df0ff85`. Production concurrency,
memory-safety and warnings-as-errors settings remain enabled. The provider profile
changes envelope policy; both profiles still encrypt the private database.

| Campaign | Executed result / artifact |
| --- | --- |
| Initial complete debug suite | Swift Testing reported 206 test entries; `/tmp/nv-s34-full-debug.log`. Subsequent connected witnesses were added separately. |
| Final optimized suite | 209 active functions discovered and passed; Swift Testing reported 211 entries including the two explicitly skipped opt-in resource/scheduling benchmarks; 660.634 s. `nv-storage-phase2-60qo06rl/swift.log` under the local temporary artifact root. The bootstrap resource benchmark ran separately below. |
| Final debug affected functions | 12 functions passed, 159.702 s; `/tmp/nv-s34-debug-final-targets.log`. These include the strengthened continuation/private-state/required-loss cases and shared-envelope witness. |
| Independent S3/S4 child schedules | 26 passed locally, and 26 on each of macOS 11, macOS 14 and Linux arm64; `/tmp/nv-s34-process2.log`, `/tmp/nv-s34-macos11-process.log`, `/tmp/nv-s34-macos14-process.log`, `/tmp/nv-s34-linux-process-hardened.log`. Each host covers both profiles and uses the same independent observer. The final Linux run uses the hardened binary identified below; its artifact root is `/tmp/nv-s34-process-x_pqoeve`. |
| Original independent child schedules | 76 passed on final source; `/tmp/nv-s34-original-process-final2.log`, artifact `nv-storage-process-kzldtec0`. This retains the original retention cut and adds the exact acceptance-phase cases. |
| Actual compiler boundaries | All 113 runtime construction/isolation probes plus the diagnostic-classifier self-check passed on both local macOS and Linux; `/tmp/nv-s34-final-types.log`, `/tmp/nv-s34-linux-types-final2.log`. The original 60-second per-command bound and diagnostic/source-line assertions remain unchanged. |
| Core semantic mutations | Seven isolated mutants reached their designated runtime assertions; `/tmp/nv-s34-bootstrap-mutations.log`, artifact `nv-bootstrap-mutations-_yt8qdsb`. |
| Reconstruction mutations | Six isolated mutants reached their designated runtime assertions, with all five designated baseline functions passing; `/tmp/nv-s34-runtime-mutations-final2.log`, artifact `nv-runtime-mutations-tts_q5ac`. |
| Instrumented SQLCipher / Swift ASan | Valid-handle and intended expired-handle controls passed; 13 affected runtime functions passed in 1,702.129 s. `/tmp/nv-s34-asan.log`, artifact `nv-cipher-sanitizer-mgfurj0s/runtime.log`. This includes the 1,024-note production bootstrap and connected compensation/Restore cases. |
| Swift TSan | Three contested reconstruction functions, six parameter cases, passed in 195.798 s; `/tmp/nv-s34-tsan.log`. |
| Resource campaign | All eight opt-in 64/256/1,024/2,048-note cases passed; `/tmp/nv-s34-resource-release2.log`, 84.488 s. Read counts and encoded-buffer measurements are reported above. |
| Focused reconstruction TLC | Six exhaustive safe cases, nine intended safety counterexamples and five reachability witnesses; `/tmp/nv-s34-tla-epoch.log`, artifact `nv-reconstruction-tla-qjvwohna`. |
| Existing model correspondence | Complete `SegmentBootstrapSafety` and `SQLiteFastStartSafety` families passed their safe cases, negative controls and witnesses; `/tmp/nv-s34-bootstrap-models.log`, `/tmp/nv-s34-fast-models.log`. |
| Linux runtime / exact counters | 13 affected functions passed in 159.890 s; a further two manifest-boundary/read-count functions passed in 84.780 s. `/tmp/nv-s34-linux-runtime-final.log`, `/tmp/nv-s34-linux-counter-final.log`. |
| Linux executable permissions | The hardened probe passed PIE, W^X, non-executable stack and RELRO checks; the deliberate RWX-header mutation was rejected. The VM's `elf-hardened.log` records the result. |
| Connected regression schedules | All 60 Phase 3 lifecycle/delivery schedules, eight generated command schedules with all six fault classes reached, and 18 rejection schedules passed through the final optimized common driver. Its per-stage logs preserve the independent observations and reached cuts. |
| Complete optimized common driver | All 31 commands passed; 209 active functions discovered, zero failed commands. `/tmp/nv-s34-release-final3.log`, artifact `nv-storage-phase2-60qo06rl/results.json`. This includes 35 Core and 113 Runtime compiler probes, their classifier self-checks, all independent fixture/encoding checks, 17 schema tests and strict owner/fault-adapter C diagnostics. |
| Application build | The existing app builds with Xcode 27's explicit `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` command-line setting; `/tmp/nv-s34-app-build-explicit-setting.log`. App/editor source is unchanged. |

The optimized common driver and final hardened Linux child campaign completed.
Earlier cold-build timeouts, the default-link ELF permission failure and invalid
measurement runs remain failed setup/qualification artifacts, rather than passing
evidence. The local qualified process probe has SHA-256
`fb2926f3b21560479f8c39b1ee918c943eb2cbeab99068856860a208a853cc5d`.

### Platform build variants

The two Intel hosts ran the identical optimized probe, SHA-256
`349a3c5566975c3866d3e1e35f8adbee47865efa89d863916e56e93c52b4c46c`.
The Intel build requested `x86_64-apple-macosx11.5` and used
`-Xswiftc -Xfrontend -Xswiftc -disable-concrete-type-metadata-mangled-name-accessors`.
On macOS 11.7.11, the probe also loaded Xcode's Swift concurrency backdeployment
library through its isolated `DYLD_LIBRARY_PATH`. macOS 14.8.9 used the same probe.
Xcode 27's SwiftPM output still declares Mach-O minimum OS 12.0. These real macOS
11 execution results qualify that tested workaround variant, not the default
distribution/build metadata for macOS 11. `/tmp/nv-s34-intel-build.log` records
the build; each process runner's first line identifies its per-case artifact root.

The Linux source/build lives in the VM's persistent disk-backed test directory,
with temporary aliases restored after its resource-expansion reboot. It uses
Swift 6.4, the native SwiftPM backend and the same pinned cipher. The first
compiler-probe attempt timed out during cold setup; the successful retry retains the same
required diagnostic category, marked line and 60-second per-command timeout.
The default bfd-linked probe fails the real writable-executable-mapping assertion.
The documented bundled-lld settings (`-use-ld=lld`, `-z relro`, `-z now`) passed
the unchanged observer and its deliberate permission mutation. The final probe's
SHA-256 is `1e2fc4695a109f711f9aa77751e74eb5b2bcdf0b2fe11e42a78b0a704c511b40`.
The native product rebuild took 152.00 seconds, with `-gnone` and the existing
integrated-driver options; `runtime-hardened-build.log` records its exact output.
No diagnostic, library contract or safety assertion is waived for either platform.

### Reproduction and source identity

The common entrypoint is `python3 tools/test-storage-phase2.py --configuration release`.
The focused child entrypoint is `python3 tools/test-storage-bootstrap-reconstruction-process.py --binary <probe>`;
its SSH options retain local independent observation of remote children.
`docs/tla/check-reconstruction-model.py` runs the focused bridge. Core bootstrap
and runtime reconstruction mutation commands, filters and source hashes are
recorded in their isolated `results.json` artifacts. Compiler probes run against
the actual built modules through `tools/test-storage-runtime-types.py`.

The final production bootstrap/reconstruction logic has these SHA-256 identities:

| Source | SHA-256 |
| --- | --- |
| `InitialCollectionWriterV1.swift` | `488aef3c814d65c5128adab255220c4171a3b8d5b13d3bd22e2c4b439607b7fd` |
| `BootstrapConstruction.swift` | `a44e1919c72ca30944c16022d8c121411b61e1a4abe88ea09824b12d712c9af2` |
| `GeneralSnapshots.swift` | `6a242c032d57ab1e6477ef76573a9dced65f5966616900735ddc85ff859f9ca2` |
| `SnapshotReconstructionSafety.tla` | `4de051203818f69cc7f4509b9eff772a333767e4185ad5bab29c20d24ac4a7c8` |

The sanitizer and Intel campaigns preceded the final shared-reader measurement
correction and optional creation fault-phase helper. Those changes affect
measurement and the test driver; the production bootstrap/reconstruction logic
above is identical. Final local/Linux exact-count and child checks exercise those
later changes. Physical power loss, provider integration, final selected-store
activation and later Phase 4 private/projection codecs remain explicit limits.
