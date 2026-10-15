# P5.6 — Repair implementation and qualification ledger

Date: 2026-10-14. Status: **implemented and qualified within the limits recorded here**.
The [plan](06-repair-replacement-and-copy.md) remains the acceptance authority.
This increment connects missing-repository repair and complementary repository
reads. Integrated private activation, verified switching and bounded complementary
fresh-process recovery now have production witnesses. Occupied damage follows
stop-and-Save-As; automatic missing-entry repair remains. The P56-01–25 crosswalk
below connects each scenario to its production witnesses. Broader generated S1–S6
combinations belong to P5.7; distribution and physical power-loss qualification
remain separate. This ledger separates executed evidence from those later gates.

## Complementary-source access isolation

The repair reader now reports an unreadable or wrong-kind protocol subtree using
the existing source-index/path/failure report, closes that listing, and continues
available entries or later explicitly selected sources. Requested-file observation
uses the existing `inspect` result so access failures have the same classification
as file-read failures. Root permission is rechecked after a listing error; lost
ownership, cancellation and contradictory validated identities remain terminal.
Known required membership must be present before a replacement candidate is created.
Sources and their permissions remain unchanged. No persistent state, cache, receipt
or additional permission type was added; the existing restricted source/issue issuers
and actual contextual consumers are retained.

`repositoryRepairReportsSourceAccessAndRequiresCompleteUnion` uses both profiles
and five source conditions, with and without a second complete source: healthy,
unreadable protocol hierarchy, occupied hierarchy, unreadable requested object and
unrelated invalid bytes. It verifies exact reconstructed bytes/current values,
reports, preserved permissions/occupants, listing cleanup and absence of a candidate
when required evidence is unavailable everywhere. The existing damaged/misnamed
complement tests remain companions. `repositoryRepairReaderKeepsLostPermissionTerminal`
requires exact stale-permission rejection after invalidate or close. These permissions
tests require a non-root process so mode-bit denial is actually exercised.
`repositoryRepairReaderPreservesCancellationAfterListing` checks cancellation both
before discovery and after a prior call exhausted the listing. A final cancellation
check preserves that terminal outcome when the traversal has no frames left.

Qualification entrypoints:

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter repositoryRepair'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel --filter repositoryRepair'
python3 tools/test-storage-runtime-mutations.py --only repair-source-access-report --only repair-source-incomplete-candidate --only repair-complement-report --only repair-complement-locator --timeout 900 --jobs 2
python3 tools/test-storage-runtime-mutations.py --only repair-source-cancelled-end --timeout 900 --jobs 2
```

The first access matrix passed all 20 cases. Its initial ownership test expected
closed/fenced errors, but the existing generation check correctly returns
`stalePermission` first; the test now requires that exact existing outcome.
The first compile attempt used three argument collections, which Swift Testing
rejects; the same cross-product is expressed with two collections and a tuple.
Neither correction changes production ownership checks or scenario coverage.
Final local qualification (macOS 26.6.2 arm64, Swift 6.4):

| Check | Result |
| --- | --- |
| Debug repair regressions | All 20 functions passed in 67.650 seconds; `/tmp/nv-p56-source-final-debug.log`. |
| Optimized repair regressions | All 20 functions passed in 35.295 seconds; `/tmp/nv-p56-source-final-release.log`. |
| Access/report/complete-union mutations | Passing baseline and four intended failures; `/tmp/nv-p56-source-mutations.log`. This campaign preceded the final exhausted-reader cancellation check; those four challenged paths are unchanged. |
| Exhausted-reader cancellation mutation | Final-source passing baseline and intended failure; `/tmp/nv-p56-source-cancel-mutation.log`. |
| Instrumented SQLCipher/Runtime ASan | Three functions / 28 cases passed in 26.713 seconds, with the native valid companion and intended expired-handle control; `/tmp/nv-p56-source-asan.log`, `nv-cipher-sanitizer-e36znpf8`. |
| Compiler boundaries | 42 checks in eight batched invocations; `/tmp/nv-p56-source-types.log`. |
| Application | Approved Xcode 27 deployment-diagnostic override passed with macOS 11.5 unchanged; `/tmp/nv-p56-source-app-override.log`. The ordinary `build.sh` still reports that known diagnostic. |

Source-isolation campaign SHA-256: `RepositoryRepairSource.swift`
`271eadb034143da358956e9cd874bc8d6909d6b14e5ec6069083320fe8788137`;
test source before the later connected-schedule addition: `RepositoryRepairTests.swift`
`c086380d18c25524a6703c9aaa0f6ac9d24c1e5ffb3e4b7be5cdb6faff72cb79`.
These tests reopen repaired stores in-process; the broader fresh-process S4 gate
below remains separate.
The cancellation check was found during code review after the initial access
matrix; its negative control removes that exact final check. Existing root/read
cancellation checks and cleanup remain unchanged.

This implements acquisition of the model's exact repair union, whose per-source
availability and byte validation remain trusted inputs. It changes no modeled
activation, preservation or complete-closure condition; no TLC rerun is claimed
for errno/reporting behavior outside the model.

## Bounded saved-history payloads

`CapturedRepositoryHistory` now retains a fixed accepted prefix and its checked
canonical name/hash inventory. Its private constructor binds the inventory to
the original store/session. Both saved-work copying and destination verification
reuse `captureRepositoryPublication`: at most 16 objects and a 4 MiB encoded-byte
budget per batch, with the existing one-oversized-object allowance within the
envelope ceiling. Decoding and installation have their existing temporary buffers;
this is a bound on selected payload batches, not a 4 MiB process-memory claim.

Preflight validates the complete captured cut before copy effects. Consumption
rereads exact bytes in bounded turns, compares every name/hash against the captured
inventory, and checks that every captured name was visited. A durable verification
request spans these reads and their final completeness check. Later acceptance
stays outside the cut. Source closure, cancellation or damaged/missing records
leave the source and any already copied output preserved. Canonical reservations
still include failed installations, preventing fallback to damaged source bytes.

This adds no persistent state or cache. Inventory, seen-name and result metadata
remain proportional to object count. The tradeoff is an additional bounded reread
of payloads rather than keeping their entire contents alive. Copy plus destination
verification each preflight and consume their inventory: four history reads per
object across those two operations. Healthy returning startup is unchanged.

Qualification entrypoints:

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter repositorySavedCopy'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel --filter "repositorySavedCopy|collectionCopySwitch|activeRecoveryCopy|recoveryCopy|repositoryCopyStages|explicitCurrentExport|repositoryPublication"'
python3 tools/test-storage-runtime-mutations.py --only copy-drop-unpublished --only copy-unreserve-failed-history --only copy-omit-inventory-completeness --only copy-unbounded-publication-batch --timeout 900
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-repository-copy-process.py --binary NVStorage/.build/debug/NVStorageProbe
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter 'repositorySavedCopyRechecksCapturedHistory|recoveryCopyReservesVerifiedNamesAfterInstallFailure|collectionCopySwitchRechecksDestinationAndSelectionOwner' --jobs 2
```

`repositorySavedCopyStreamsFixedHistory` runs both profiles at 64/256/1,024 actions
using independently checked shared fixtures and physically separate stores. It
checks actual selected-batch maxima/read counts, every copied hash, current values
and reacquired destination verification. Copy and verification timings are reported
separately. `repositorySavedCopyRechecksCapturedHistory` pauses after the first
batch and saves, removes/corrupts the final record, closes, or cancels. The save
companion must finish the original cut without consuming the new edit; damaged
cases must leave a durable damage marker, inspected through a fresh diagnostic
connection. Mutation controls challenge skipped copies, lost reservations, omitted
inventory completion and enlarged batches.

The copy model's captured-inventory and truthful-coverage conditions are unchanged.
Its runner still selects separate safe, progress, negative and reachability cases
for available fixed inputs. The correspondence was checked by inspection (plus a
successful SANY syntax/level check); actual source loss during a read is executable
coverage outside that model's input abstraction. This is not a newly checked
formal refinement or progress proof. No model assertions were relaxed, and TLC
was not rerun merely for the batching change.

Completed local qualification (macOS 26.6.2 arm64, Swift 6.4):

| Check | Recorded result |
| --- | --- |
| Debug growth and interrupted reads | Two functions / 16 cases passed, 500.552 seconds; `/tmp/nv-p56-stream-growth-debug.log`. All six growth cases require four exact history reads per object across copy plus destination verification, and the calculated number of 16-object batches. |
| Debug affected regressions | The 17 existing copy/switch/export/publication functions passed in `/tmp/nv-p56-stream-debug.log`. Its four failures were in the initial new fault fixture: the immutable-update trigger prevented damage injection, and a fenced live connection refused diagnostic inspection. The corrected fixture injects below that trigger and inspects through a reopened diagnostic connection; the final growth/fault run above passes without changing production protections. |
| Optimized growth and affected regressions | All 19 functions passed in 582.406 seconds; `/tmp/nv-p56-stream-release.log`. This includes all growth sizes/profiles, interrupted reads and the existing copy/switch/export/publication checks. |
| Compiler boundaries | 42 checks, eight batched invocations; `/tmp/nv-p56-stream-types.log`. The new inventory constructor remains file-private. |
| Targeted mutations | Passing final baseline and all four controls fail at their designated assertions; `/tmp/nv-p56-stream-mutations-final.log`. Exact-source isolated build reused after correcting the fixture; the cross-product remains intact. |
| Fresh process | All 24 copy/switch cases pass; `/tmp/nv-p56-stream-process.log`, independent inventories/SQL observations in `nv-copy-process-t_u4nnqx`. |
| Instrumented SQLCipher/Runtime ASan | Three functions / 16 cases pass in 87.291 seconds, with the native valid companion and intended expired-handle control; `/tmp/nv-p56-stream-asan.log`, `nv-cipher-sanitizer-ewmmp1be`. |
| Application | `build.sh` encounters the existing Xcode 27 deployment diagnostic. The previously approved diagnostic override passes with macOS 11.5 unchanged; `/tmp/nv-p56-stream-app-override.log`. |

Measured debug workloads (seconds, concurrent qualification load; not controlled
before/after speed comparisons):

| Profile | Actions / saved objects | Largest selected payload batch | Copy | Destination verification |
| --- | --- | --- | --- | --- |
| Password-free | 64 / 72 | 10,192 bytes / 16 objects | 3.783 | 0.910 |
| Password-free | 256 / 264 | 10,208 bytes / 16 objects | 10.820 | 1.793 |
| Password-free | 1,024 / 1,032 | 10,224 bytes / 16 objects | 29.219 | 4.463 |
| Encrypted | 64 / 72 | 9,936 bytes / 16 objects | 1.853 | 0.331 |
| Encrypted | 256 / 264 | 9,952 bytes / 16 objects | 6.470 | 1.073 |
| Encrypted | 1,024 / 1,032 | 9,968 bytes / 16 objects | 26.559 | 4.526 |

These use small note bodies. Existing publication byte-budget/oversized-object
companions also pass in the affected debug run. Shared fixture construction took
266.502/122.773 seconds by profile; it is outside the measured copy/verification
intervals. A process sample shows active complete-file installation and durability
calls during copying, rather than a stalled batch reader. No barrier was removed.

Optimized copy/verification seconds were 1.753/0.287, 6.181/1.020 and
25.615/8.865 for password-free 64/256/1,024-action cases, and 2.764/1.507,
7.805/1.691 and 25.897/4.737 for encrypted cases. Batch maxima matched the debug
table. These are qualified workload observations, not a controlled speed comparison;
the optimization bounds retained payload memory rather than eliminating durability
work. The existing publication-growth companion still reports 93 SQL steps for
three selected objects at every size, in both profiles.

Frozen production fingerprints: `CollectionCopies.swift`
`c2eae7a72d72e10f17439a340a3f474962f41b6dc17b6bba6ab77c28f89c549f`;
`RepositoryPublication.swift`
`724c7c3496bc916af55797abaea3e5bb00dfc68f406fd531f086922a27ad41e0`;
`RepositoryCopy.swift`
`2715ea2f287457d0440e3b9f2d19d1e20bfcf6739a079bde467d8cb78fe6f368`.
The test source is `5a0cd1aa60eb99a1522fbbcd92e5ec4c2b23e192049b195a6ddb903d91f696da`;
the fresh-process binary is `96aca74e15022f8ab8812aa5bb5e5862287e84ec76788321a6f24d37304f3131`.

## Integrated verified copy switch

### Entered provider accessor schedules

`collectionCopySwitchRefusesEnteredAccessorAndPreservesEditing` holds a real
Foundation installation accessor. Save As reports busy, leaves selection and
destination untouched, and a new local edit becomes durable while the accessor
remains entered. After release, bounded explicit fresh preparations must succeed;
intermediate busy/stale-copy outcomes retain selection and the exact edited value.
Late discovery can write verification/hint rows after an idle observation, so the
existing all-writes source fence may conservatively refuse that particular copy.
The test retains that fence and requires progress within three preparations after
finite interference. It does not weaken the source comparison to history alone.

`collectionCopySwitchSettlesAccessorBeforeSelection` starts the old accessor after
copy preparation. Actual transport stopping, both held root owners, unchanged
selected bytes and final admission are observed before the accessor is released.
Once this final handoff is admitted, cancellation settles the owned operation;
the source remains preserved and the new owner can save and reopen independently.
The old store retains its original value. Both profiles and both cancellation
schedules are required. `switch-skip-accessor-settlement` challenges the actual
settlement call rather than substituting a simulated callback.

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter "collectionCopySwitchRefusesEntered|collectionCopySwitchSettlesAccessor"'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel --filter "collectionCopySwitch|collectionStartupReassociationRetainsEntered"'
python3 tools/test-storage-runtime-mutations.py --only switch-skip-accessor-settlement --timeout 900 --jobs 2
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter 'collectionCopySwitchRefusesEntered|collectionCopySwitchSettlesAccessor' --jobs 2
```

This adds executable correspondence for existing root-accessor lifetime and switch
admission rules, with unchanged production behavior and evidence constructors.
The switch model still abstracts actual worker settlement; the executable
accessor test supplies that boundary observation, not an additional formal proof.
Final local qualification passed both test functions/six parameter cases in debug
(10.476 s) and optimized (5.260 s) builds, and against ASan-instrumented SQLCipher
(10.116 s). The mutation fails at the intended `sourceOpen` assertion in all four
handoff cases, with a passing companion. Its first form survived an earlier test
that observed selection too early; the strengthened test observes the original
connection's lifetime while the accessor is still held. Production settlement and
compiler boundaries were unchanged.

Artifacts: `/tmp/nv-p56-accessor-qualified-debug.log`,
`/tmp/nv-p56-accessor-qualified-release.log`,
`/tmp/nv-p56-accessor-qualified-asan.log`,
`/tmp/nv-p56-accessor-mutation-final.log`. Sanitizer artifacts are under
`nv-cipher-sanitizer-bbkvg3yl`; mutation artifacts under
`nv-runtime-mutations-c15w1n6n` in the system temporary directory. Final
`RepositoryCoordinationTests.swift` SHA-256:
`aee0c6cccebc538c4c80098465d5161ad4a2fc3dbfe66e31564349d81670d94c`.

### Connected complementary private recovery

`tools/test-storage-repository-repair-process.py` connects the first half of S4:
an acknowledged private edit absent from the provider; a corrupt, non-frontier
private object still valid in the provider; a different provider object missing
but retained privately; settings; a committed Import whose callback was lost;
later Delete; and both latest and frozen pending input. A failed diagnosis write
leaves a real durable verification request before process termination. Recovery
starts with public static salvage, not ordinary opening of the damaged database.

Both profiles exercise normal recovery, process termination immediately before/
after private-state installation, EIO/ENOSPC during that installation, and loss of
the activation callback. Every first installation failure is followed by a second
ENOSPC failure, then fresh recovery using only surviving ordinary inputs. The
parent checks selected-record bytes, exact immutable inventory, settings, pending
links/payloads and Current, and independently decodes the reconstructed history.
Original files (including the WAL and unlock evidence) remain byte-identical;
the transient shared-memory index is excluded from that preservation comparison.
The normal bounded publisher subsequently restores the missing provider entry and
publishes the saved local edit; existing provider bytes remain exact.

```sh
PKG_CONFIG_PATH="$PWD/NVStorage/.deps/sqlcipher/lib/pkgconfig" swift build --build-system native --package-path NVStorage --product NVStorageProbe
python3 tools/test-storage-repository-repair-process.py --binary NVStorage/.build/debug/NVStorageProbe
```

The aggregate phase-2 qualification driver includes this process campaign using its
already qualified executable. This process campaign qualifies the first half of
S4; the connected controller schedule below covers post-activation namespace
interference. The publisher witness here is a separate boundary check.
The debug companion and all 12 schedules passed in both debug and optimized builds.
Logs:
`/tmp/nv-p56-complementary-normal.log`,
`/tmp/nv-p56-complementary-full-debug.log`,
`/tmp/nv-p56-complementary-full-release.log`.
The initial direct probe build lacked the pinned SQLCipher `PKG_CONFIG_PATH`;
the existing linkage check correctly refused that binary. The commands above and
the aggregate driver retain the pinned dependency. Neither credential handling nor
linkage checks were relaxed.
The exact EIO (`database(1034)`) and ENOSPC (`database(13)`) assertions were added
after these runs and passed against all 12 retained child failure observations in
each configuration. The successful executions and raw results were reused; no
runtime source or input changed. Artifacts are `nv-repair-process-_4gt5f2l` (debug)
and `nv-repair-process-u72pnevq` (optimized) under the system temporary directory.

### Post-activation namespace interference

`repositoryRepairConnectedActivationNamespaceRace` starts from complementary
private/provider loss, an unpublished edit, settings, a frozen admitted pending
choice and a newer pending preview. It constructs and activates the actual repaired
store, then reopens that selection after another provider namespace loss. While
automatic repair is held after capturing its complete source, a new local edit
commits and another writer creates either a compatible or valid foreign descriptor.
Both profiles exercise both contenders.

The original absent-name attempt must stop with EEXIST and leave the contender
unchanged. Explicit Retry accepts the compatible descriptor and ordinary publication
restores the complete inventory, including the newer local edit. A foreign
descriptor instead yields the source-preserving Save As request. Independent reopen
checks exact historical bytes, current values, settings, latest/frozen pending
payloads and the admitted reservation. Selected-record bytes and the damaged
original database stay unchanged throughout the second repair. This connects the
same saved inputs through recovery and later interference; it adds no production
state, public API or policy.

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter repositoryRepairConnectedActivationNamespaceRace'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel --filter "repositoryRepairConnectedActivationNamespaceRace|repositoryRepairIntegratedActivation|repositoryRepairPreservesNamespaceRaceWinner"'
python3 tools/test-storage-runtime-mutations.py --only repair-connected-settings --timeout 900 --jobs 2
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter repositoryRepairConnectedActivationNamespaceRace --jobs 2
```

The final debug test passed all four parameter cases (5.714 s). The optimized run
passed the new test and two existing activation/namespace companions: three
functions / ten parameter cases in 15.105 s (new test: 7.000 s).
ASan-instrumented SQLCipher passed the four connected cases in 9.730 s, with the
native valid-handle companion and intended expired-handle failure. Logs:
`/tmp/nv-p56-connected-race-final-debug.log`,
`/tmp/nv-p56-connected-race-final-release.log`,
`/tmp/nv-p56-connected-race-asan.log` (artifacts `nv-cipher-sanitizer-6b_151kc`).
The settings-omission mutation passed its companion and failed at the intended
reopened-settings assertion in all four cases (`/tmp/nv-p56-connected-race-mutation.log`,
artifacts `nv-runtime-mutations-0bzq3900`). Existing mutation cross-products remain
unchanged. Final `RepositoryRepairTests.swift` SHA-256:
`83c2d25475a2733ac119d6c7948c82fba544b71aa163fc39ff3135c73f52872a`.
This is a bounded executable lifecycle, not exhaustive enumeration of all P56-*
schedules. Physical power loss and cross-host provider delivery remain separate.

`CollectionSession.switchRepositoryAndSavedWork` now connects the fixed-copy
preparation to the actual destination and selection consumers. The existing
operation reservation permits edits during preparation. The destination is
reacquired and every known saved descriptor/object is compared with the checked
private copy before its fresh physical association is recorded. Complete saved
history and required private inputs authorize activation; unavailable extra
repository files remain explicit in the copy report and preserved at the source.

At the final transition, provider work settles and `DatabaseLane.retireForCopy`
compares the source connection/write cut and retires SQL in one actor turn. A
settled file/journal observation authorizes selection's reacquisition of source
exclusion. Intervening source writes cause a safe refusal with the old owner still
editable. A known unchanged selection failure reopens the source if it was already
retired. An uncertain installation retains candidate, both roots and source
exclusion in the explicit pending phase. `resumeCopySwitch` finishes the same
installed item and barriers; it never performs a second selection rename. A
durably selected candidate whose integrated adoption fails reports its selected
identity for reopening. Explicit close preserves both stores for normal recovery.

No new persistent record or format is introduced. `VerifiedReplacement` now keeps
only the source selection/observation needed by activation rather than entire
salvage inventories. Private constructors remain the issuing boundary. Transition
reservation returns the previous phase as an operation-local value; removing the
shared scratch field prevents a refused concurrent preparation from clearing another
operation's rollback state. Retry and Re-open use that same smaller boundary.

| Test / validation | Principal observation |
| --- | --- |
| `collectionCopySwitchPreservesHistoryAndPrivateInputs` | Real selection changes only after complete history/private transfer; latest and frozen previews, reservations and settings survive; old capture cannot affect either closed source or new owner. |
| `collectionCopySwitchRefusesNewSourceWork` | Read companion succeeds; Delete, settings, pending and rolled-back writes invalidate the cut. New work survives, and a later quiet preparation switches successfully. |
| `collectionCopySwitchSettlesSelectionFailures` | Before-install failure retains usable source; later failures remain pending, both roots/source remain excluded, repeated barrier failure preserves the attempt, then resumption succeeds. |
| `collectionCopySwitchRechecksDestinationAndSelectionOwner` | Changed copied bytes and wrong selection-owner evidence fail at their actual consumers; the source remains selected/editable. |
| `collectionCopySwitchClosePreservesRestartInputs` | Closing uncertain activation releases ownership while retaining both stores; ordinary reopening reads the actual new selection. |
| `collectionCopySwitchKeepsCompetingPreparationScoped` | A second preparation cannot retire the source while the first owns admission; the source stays usable, and the first preparation subsequently completes. |
| `tools/test-storage-repository-copy-process.py` | Adds 12 switch schedules to the 12 existing copy schedules: both profiles, normal/abrupt post-activation exit, repeated private-identity transaction crashes/EIO/ENOSPC, recovery and successful retry. Recovery receives surviving selection/unlock inputs, independently checked SQL/private/history values and destination-only bootstrap. |
| Compiler probes | 42 checks, including public switch clients, restricted result/source proof constructors and prior evidence boundaries. |
| Runtime mutations | `switch-source-cut`, `switch-destination-history`, `switch-release-source`, `switch-competing-reservation` target source preservation, destination verification, pending exclusion and final admission. |
| `RepositorySwitchSafety` | 18 bounded checks: safety/progress, late private writes, cooperating source reopening, durable acknowledgement, old/new crash selection and designated unsafe controls. |

Commands (debug and release use the same source selectors):

```sh
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'collectionCopySwitch|selectionFault|selectionResumption|selectionRefuses|verifiedSelection|privateCopyPreparation|privateBackupSourceFence'"
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-repository-copy-process.py --binary NVStorage/.build/arm64-apple-macosx/debug/NVStorageProbe
python3 tools/test-storage-runtime-mutations.py --only switch-source-cut --only switch-destination-history --only switch-release-source --only switch-competing-reservation --timeout 900
```

Initial final-source debug qualification passed all 12 selected functions / 52
parameter cases (204.967 seconds with concurrent qualification work;
`/tmp/nv-p56-switch-final-debug.log`). The compiler run passed 42 checks in seven
batched invocations with no fallback batches (`/tmp/nv-p56-switch-types.log`).
The model run passed all 18 cases (`/tmp/nv-p56-switch-tla2.log`); the first sandboxed
attempt could not open TLC's local worker socket and is not a model result.
The initial Swift test expected a resumed attempt to repeat the already-completed
rename; it now injects the second failure at the actual remaining durability
barrier. Production behavior and the required repeated-failure assertion remain.
The initial optimized run passed the same 12 functions / 52 cases in 39.488 seconds.
Two mutation guards initially used `Issue.record`, so the runner correctly refused
to classify them as its required exact `#expect` failure. The guards now use explicit
expectations; the runner's discovery and marked-line rules are unchanged.

After replacing the shared transition scratch field with an operation-local return
value, the final debug and optimized runs passed 12 functions / 42 cases, including
the additional competing-copy witness and the existing Retry/Re-open companions.
Debug took 241.519 seconds and optimized took 33.909 seconds under concurrent
qualification load. These are execution observations, not controlled benchmarks.

| Final qualification | Result / artifact |
| --- | --- |
| Debug / optimized transition and copy tests | Both passed; `/tmp/nv-p56-switch-local-phase-debug.log`, `/tmp/nv-p56-switch-local-phase-release.log`. |
| Real SQLCipher + Runtime AddressSanitizer | 12 functions / 42 cases passed (155.535 seconds), plus the valid native handle and intended expired-handle control; `/tmp/nv-p56-switch-local-phase-asan.log`. |
| Fresh-process repository copy and switch | All 24 schedules passed on the final debug executable; `/tmp/nv-p56-switch-local-phase-process.log`. |
| Existing integrated private-repair process regression | All 12 schedules passed against the unchanged private-repair consumers; `/tmp/nv-p56-switch-private-regression.log`. |
| Targeted runtime mutations | All four produced their intended assertion failures after a passing companion; `/tmp/nv-p56-switch-local-phase-mutations.log`. Existing mutation cross-products remain unchanged. |
| Compiler / model boundaries | The 42 construction checks and 18 model checks above remain applicable: the final simplification changes private state ownership, not evidence construction or the modeled selection protocol. |
| Native diagnostics / application build | Strict C syntax diagnostics passed. Clang analysis reported two possible negative `dirfd` inputs in the catalog comparison, whose `fstat` errors are handled; this is not a warning-free analyzer result. `build.sh` encountered the known Xcode 27 deployment-target diagnostic; the approved `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` invocation then passed, retaining the 11.5 target (`/tmp/nv-p56-switch-app-override.log`). |

The fresh-process executable has SHA-256
`193646928d4c1c293d9dec780bf531b9ea7c791bc2fcbe907598e8385d0d86fe`.
Base commit is `28f47a4b108bd7f126f3c7e67340d68cee9bd885` plus the recorded
uncommitted changes. Key final-source fingerprints are:

| Source | SHA-256 |
| --- | --- |
| `CollectionStartup.swift` | `7fbf30cf4319c7b4b4a43d23e2b0bef5696dbde8aa0297d004c77809d3b2117a` |
| `CollectionCopies.swift` | `2730c039b17aaa54ad78c18d0cf83196c81bd08308dc9c07dc3f92084837a1e0` |
| `PrivateBackup.swift` | `a1742c3b922dfcbc7704adfa4b25f3350da2b4f3160b87a7f83468f421b4a51d` |
| `PrivateRepair.swift` | `75c07543293c8ee317d155de4c13985329bde2b8510b92f05ee7a5d338f509c3` |
| `StoreSelection.swift` | `f7f0df51a970b98e48566d9ff00139c1c468e7866b0aaf63e05f992cd40c45e0` |
| `Database.swift` | `a81fd0e3a49e4f8a77c60b07bfca746b254df46884190ecff7e95a3d0f7f1dd7` |
| `LocalStore.swift` | `d8f024e6f975267e3fbefc1835d0827ac287cd66e8fbe47d7790f803fa3ae1da` |
| `NVStorageIO.c` | `a26d60bcf46357b6970c84d9885406a676149cc9a17b223597d50ff8b40da79f` |
| `CollectionCopySwitchTests.swift` | `481195cbb666d9ed4e86307ebed595fe95ce16024764d8398985c4ef5732c0ea` |
| `RepositorySwitchSafety.tla` | `66402803455724e22306972945f5b6b24dfd921bf98f55168885d70a32e665fd` |

These checks do not qualify the full S4 matrix or physical power-loss behavior.
The remote SSH keys are unavailable in this session; this increment's platform
execution is current arm64 macOS, not renewed Linux/macOS 11/Intel qualification.

## Fixed private-copy preparation

`LocalStoreSession.preparePrivateStoreCopy` is an internal preparation step for
P5.6G. It reuses the complete fixed-reader backup, assigns a fresh local-store ID
and association scope transactionally, then normally reopens and verifies complete
private state. Existing `repair-source/` provenance preserves readable old-scope
pending snapshots/reservations. Exact immutable bytes and the backed-up accepted
indexes retain their meanings; fresh session writer/action-origin allocation remains
the ordinary opening behavior. This preparation issues no `VerifiedReplacement`
and cannot change the selected store. The integrated consumer above supplies the
destination association and final handoff.

The fixed-reader boundary also captures a file-restricted connection/write-count
value. `checkBackupSource` checks the issuing local session and connection, healthy
history and that exact count. Settings, pending inputs and rolled-back writes can
invalidate it independently of accepted history. The counter is transient. The
pinned SQLCipher source implements SQL `total_changes()` through
`sqlite3_total_changes64()`; its documented scope is writes on that connection,
including trigger/foreign-key work. The private owner has one writer. This check
does not replace physical ownership or the eventual serialized check-and-retire
consumer, and is not claimed to detect arbitrary externally injected corruption.

Tests in `PrivateBackupTests.swift` cover exact object inventories, current values,
settings, latest/frozen private snapshots, review-only reservation recovery, fresh
writer identities, wrong live session/connection and restart, intervening edit/
settings/pending writes, rollback and unchanged-read companions. Missing required
association refuses preparation while preserving both the source and the verified
backup; the source remains writable. Three same-module construction probes and
ordinary-client factory-access probes challenge the issuer/consumer boundary.
Two targeted mutation controls challenge omitted write-count comparison and
missing old-scope provenance.

| Test | Purpose |
| --- | --- |
| `privateCopyPreparationPreservesHistoryAndPrivateInputs` | Independent exact-byte/current/private-input observations after preparation and normal reopen, with new writer context and a later source edit. |
| `privateBackupSourceFenceIncludesPrivateOnlyWrites` | Five source schedules per profile; wrong connection/session and reopened-source rejection; the unchanged-read companion succeeds. |
| `privateCopyPreparationFailurePreservesSourceAndBackup` | Missing association refuses independent preparation while preserving a normally reopenable backup and writable original. |

```sh
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'privateCopyPreparation|privateBackupSourceFence|fixedPrivateBackup|backupBudget|backupCancellation|backupReopens|backupRebuilds'"
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-runtime-mutations.py --only copy-source-private-change --only copy-private-capture-scope --timeout 900
```

These selectors are also required by the main phase-2 driver.

Qualification on macOS 26.6.2 arm64 / Swift 6.4:

- Eight fixed-backup/preparation functions pass in debug (35.485 seconds,
  `/tmp/nv-p56-private-copy-debug2.log`). After making the preparation-success
  assertion explicit, the final debug subset also passes eight functions including
  adjacent complementary-repair, verification and receive-class regressions
  (146.153 seconds, `/tmp/nv-p56-private-copy-final-debug.log`).
- The final optimized fixed-backup/preparation subset passes eight functions
  (10.168 seconds, `/tmp/nv-p56-private-copy-final-release.log`).
- All three new functions / 14 parameter cases pass AddressSanitizer
  (70.821 seconds, `/tmp/nv-p56-private-copy-asan.log`). This is Runtime coverage;
  it does not claim a new fully instrumented SQLCipher campaign or power-loss proof.
- Compiler qualification passes 39 checks (17 ordinary clients, 22 same-module)
  without fallback batches (`/tmp/nv-p56-private-copy-final-types.log`).
- All 52 existing fresh-process private-state/backup/repair/activation fault
  schedules pass for both profiles (`/tmp/nv-p56-private-copy-process.log`), using
  `tools/test-storage-private-process.py` and the newly built ordinary-client probe.
  They qualify regression behavior of the public backup and repair paths, not the
  still-internal copy/switch preparation or its future activation consumer.
- `copy-source-private-change` reaches its exact stale-source assertion
  (`/tmp/nv-p56-private-copy-mutations.log`). The same initial campaign classified
  the provenance control as an unrelated failure because complete verification
  refused preparation before its originally designated pending-read assertion.
  The test now explicitly requires successful preparation; the isolated repeat
  reaches that precise assertion (`/tmp/nv-p56-private-copy-scope-mutation.log`).
  Production safeguards and mutation cross-products were preserved.
- `build.sh` reports the known Xcode 27 deployment diagnostic. The explicit
  approved override builds successfully (`/tmp/nv-p56-private-copy-app-workaround.log`)
  with the 11.5 target unchanged. Remote qualification is unavailable because the
  three previously supplied SSH key paths are absent on this host.

| Source | SHA-256 |
| --- | --- |
| `NVStorageRuntime/PrivateBackup.swift` | `f12ba67ee27e3a9a83bdb81c49cc5e20cb2e63e123a1b1b29fe331daf395da78` |
| `NVStorageRuntime/PrivateRepair.swift` | `c75f0626abfc5cd82d8146450e5caa09545154af56913763074231a68955cb94` |
| `NVStorageRuntime/Database.swift` | `4bb5487510d632fa1fe8d0dc1441c6e01e2cd328a91165487eb3b28815be6651` |
| `PrivateBackupTests.swift` | `b5c994668f141167bc952bd0607399f5e67a1b8e90a242edf8deaa9d3f38460b` |

The final source handoff, destination association, selection ambiguity and their
connected process-cut tests remain open. Existing models retain their safety
conditions and their stated repository-copy/repair boundaries; this preparation
has executable evidence, not a claim of a newly proven end-to-end switch.

## Complete canonical copy installation and independent recovery — 2026-10-14

Canonical history copying reuses the existing P5.2 complete-stage installer through
the private root owner. Exact bytes are prepared and read back before exclusive
rename; final readback and file/directory barriers precede the copy report. This
also covers saved-history export when the source repository is unavailable. Empty
regular files remain opaque preserved evidence, copied through exclusive empty-file
creation. Unknown regular files retain streaming copy and metadata preservation.
The old direct-write history installer and duplicate path-opening native copy
constructors were removed. Copy results remain byte inventories, not activation
evidence or accepted-history receipts.

The destination has its own retained physical owner. Creation rejects descendants
of the held source. A destination moved/replaced during work fails the selected-path
check; the result cannot identify a foreign directory at the original pathname.
Source-root moves retain the existing path-independent read behavior. Linux and
macOS share preparation/installation ordering; platform qualification below is
macOS only for this increment.

`repositoryCopyStagesCanonicalBytesAndPreservesRaces` runs both profiles with normal
completion, a competing final entry, stage-name substitution and moved/replaced
destination. A required confirmation observes the complete stage before rename.
The assertions independently inspect the exact original, final and preserved bytes.
The existing broad root/files/bootstrap/copy regression set passed 36 functions
in 180.992 seconds (`/tmp/nv-p56-staged-regressions.log`); 17 optimized functions
passed in 30.527 seconds (`/tmp/nv-p56-staged-release.log`). Those runs precede the
small integrated copy-only entry point described below.

`tools/test-storage-repository-copy-process.py` drives the ordinary public Runtime
API through `RepositoryCopyProbe.swift`. Both profiles exercise normal copy,
damaged canonical file, obstructed hierarchy, unavailable source, termination after
copy but before its report, and missing dependency. After copying, it preserves
both source directories at different paths. A new child receives only destination,
new private directory and ordinary password input; it independently discovers the
descriptor/bootstrap and uses `CollectionBootstrapSession`. Expected values and
source SQL observations remain in the parent. Exact envelope inventory, operation/
action membership, dependencies, predecessors and restoration records are compared
independently, including the separate JavaScript history verifier. All 12 schedules
pass; encrypted normal-copy recovery also refuses a wrong password without creating
a private candidate or changing the copy (`/tmp/nv-p56-copy-process-final2.log`).
The missing-dependency copy remains preservable but cannot become editable.

AddressSanitizer passes four focused production tests (34.621 seconds,
`/tmp/nv-p56-staged-asan.log`). Native address/undefined sanitizers pass the
existing fault/cleanup suite, 31 pipe-confirmed process cuts, repeated recovery
failures, later-corruption companions and observer controls
(`/tmp/nv-p56-staged-native2.log`). This instruments the rebuilt root/copy boundary;
it is not a new instrumented SQLCipher campaign or physical power-loss proof.
Strict C diagnostics pass. The root/private compiler runners passed 154 checks
(122 root, 32 private) with strict concurrency/memory-safety settings and no
fallback batches (`/tmp/nv-p56-staged-root-types.log`,
`/tmp/nv-p56-staged-types.log`).

The direct-write mutation is rejected at its precise occupied-entry reporting
assertion (`/tmp/nv-p56-staged-direct-mutation.log`). The initial runner pointed
to the reached confirmation's diagnostic, which its existing expectation matcher
does not recognize; only the mutation's designated assertion was corrected.
The confirmation and all production checks remain required. Source-damage,
unavailable-inventory and dropped-unpublished-work controls also reached their
intended failures (`/tmp/nv-p56-staged-mutations.log`); that combined run reports
failure for the initial matcher issue, not a passing campaign.

Run the fresh-process check against the qualified probe binary:

```sh
python3 tools/test-storage-repository-copy-process.py --binary NVStorage/.build/arm64-apple-macosx/debug/NVStorageProbe
python3 tools/test-storage-runtime-mutations.py --only copy-direct-canonical-write --timeout 900
```

The process runner is also required by `tools/test-storage-phase2.py`. Foundation
coordination needs ordinary host access: a sandboxed rerun failed acquiring its
temporary destination, while the same run outside that tool sandbox passed. This
is not classified as a provider failure or an Apple contract violation. The app
build passes with the existing explicit deployment-diagnostic override
(`/tmp/nv-p56-staged-app-workaround.log`); plain `build.sh` still reports the known
Xcode 27 diagnostic and the deployment target remains 11.5.

### Integrated copy-only handoff

`CollectionSession.copyRepositoryAndSavedWork(to:)` reserves its existing operation
count before suspension, borrows the active root when available, and otherwise
reports repository extras unavailable while preserving the checked saved history.
Close and reassociation refuse during this operation; ordinary local edits remain
admitted. The copy reports its fixed accepted prefix and excluded private pending
items. Source selection, association and writer ownership remain unchanged. The
source continues to own work newer than that cut and every excluded private input.
No new persistent state or publicly constructible evidence is introduced.

Review also found a partial-failure hole: the reserved-name map originally came
from successful installations. If staging failed before publication, traversal
could then copy damaged source bytes into that still-empty name. The copy remained
explicitly incomplete, but that fallback contradicted the selected-byte policy.
Reservations now come from the complete captured local history, regardless of an
individual installation result. `recoveryCopyReservesVerifiedNamesAfterInstallFailure`
substitutes a real prepared stage and requires the damaged-source name to remain
absent with an unmet exact-byte requirement, while preserving both source damage
and the verified original stage. Its successful-install companion uses the same
damaged source. The targeted control restores the former reservation expression.
That control reaches the exact absence assertion
(`/tmp/nv-p56-copy-reservation-mutation.log`); the four production parameter cases
also pass AddressSanitizer (`/tmp/nv-p56-copy-reservation-asan.log`, 12.529 seconds).

The final debug copy set passes 12 functions, including the four failed-install
companions and both integrated functions (147.008 seconds,
`/tmp/nv-p56-copy-final-debug2.log`). The same 12 optimized functions pass in
23.402 seconds (`/tmp/nv-p56-copy-final-release2.log`). An intermediate optimized
build refused a source modified during compilation and was discarded; these final
runs use frozen matching sources. These timings are qualification observations
under concurrent work, not a controlled performance comparison.
Both integrated functions also pass under
AddressSanitizer (21.641 seconds, `/tmp/nv-p56-integrated-copy-asan.log`). The
fresh-process 12-schedule suite passed again against the integrated build
(`/tmp/nv-p56-integrated-copy-process.log`). Private compiler qualification now
passes 34 checks, including ordinary/same-module refusal to construct an
`ActiveRepositoryCopy` (`/tmp/nv-p56-copy-final-types.log`). The exact-prefix and
unavailable-inventory mutation campaign passes both intended failures
(`/tmp/nv-p56-integrated-copy-mutations.log`).

The source fingerprints for the final debug/optimized set are:

| Source | SHA-256 |
| --- | --- |
| `NVStorageRuntime/RepositoryCopy.swift` | `7af1f46eeb2f00e9d6703c7577e70eb0480710244a61f7702138285c8520d518` |
| `NVStorageRuntime/RepositoryRoot.swift` | `13f01b8dca17a41c267b102c7938fe77f1a582fb32614c0d4c237dd4a5312a96` |
| `NVStorageRuntime/CollectionCopies.swift` | `e054df24f8ba81c268daf63fed8ef8a9f855d1ca2b1d509a255de22739424d39` |
| `NVStorageRuntime/CollectionStartup.swift` | `f0296a5e4b21c280ffdeb5334faad3f914ede3ca11ced8257564b40c6b47bf19` |
| `RepositoryCopyTests.swift` | `672db34aa4cc22d2cecaf5036ddbb82e87559ede24ca00a542aaf8d551b2c865` |
| `CollectionStartupTests.swift` | `6d0b27d9ff6cf0cc335109e15e925b77b3decb5c4ddd0724a33bddaf7d1cda3b` |
| `RepositoryCopyProbe.swift` | `6644d2d486be440880882e3a50a3ba84dbd45f9136630b68b85dd21e92526468` |
| `tools/test-storage-repository-copy-process.py` | `4f258e02ad250aaf9cfa1f6cb1b1fb75db175918c297864e78a4a523af105cd6` |

The later integrated-switch section qualifies the final newer-work/private-input
handoff and selection failure cases. Full complementary provider/private S4 and
cross-platform/provider qualification remain open; these copy and independent
bootstrap tests alone do not qualify those gates. Existing model safety conditions
remain; correspondence names the concrete installer and independent copy consumer.

## Coordinated copy increment — 2026-10-14

`RepositoryCopy.preserveAvailable` acquires a source root or borrows an explicitly
supplied existing `RepositoryRootSession`. `copyRepositoryAndSavedWork` has the
corresponding owned-root overload. Copy admission reserves the root before
suspension. A borrowed native descriptor stays on the existing root executor;
private non-Sendable `RootCopyAccess` surrounds each synchronous read/write turn
with the root's coordinator. Combined source-read/destination-write access uses
Foundation's canonical lock ordering. Cancellation/fencing stops later grants;
close waits for traversal resources and their duplicated ownership descriptor.
Ordinary saves remain on the separate database executor.

Directory traversal retains at most 16 copied names per depth-first frame and
rechecks each resumed stream's physical directory. File bytes use the existing
64 KiB streaming buffer. The initial slice retained saved-history payloads in full;
the bounded saved-history increment above replaces that representation. Inventory
and report metadata still grow with history. Neither is a bounded-total-memory
claim or a new healthy-startup scan.

The approved damaged-source rule is implemented: exact checked local history
reserves canonical destination names first. Differing source bytes or obstructing
entries stay untouched and produce path-specific issues. No archive directory is
created. Known byte requirements can be fully satisfied while the available
source-inventory report remains partial. Destination reconstruction tests read
copied bytes independently and expect the saved note values.

Qualified debug witnesses: `recoveryCopyUsesVerifiedHistoryAndReportsPreservedDamage`
(both profiles × corrupt file, populated directory and obstructed hierarchy),
`repositoryCopyStreamsWideAndNestedInventories` (147 files),
`coordinatedRepositoryCopyKeepsOwnedSourceAndStopsStaleWork` (root move, invalidation,
cancellation and replaced subdirectory), and existing locked-byte/metadata,
unavailable-source, unpublished-work and occupied-repair companions.
The final source run in `/tmp/nv-p56-copy-final-debug.log` records eight test
functions passing in 28.915 seconds. The same eight optimized functions pass in
23.427 seconds (`/tmp/nv-p56-copy-progress-release2.log`). These timings describe
qualification runs, not a controlled performance comparison.

AddressSanitizer passes both the four-schedule owned-root race test and the
147-file traversal test (5.740 seconds, `/tmp/nv-p56-copy-asan2.log`). This covers
the newly compiled Swift/native copy boundary; it is not a new instrumented
SQLCipher dependency campaign. The application build passes with the previously
approved explicit `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` Xcode setting
(`/tmp/nv-p56-copy-app-workaround.log`). Plain `build.sh` still encounters the
existing Xcode 27 deployment-target diagnostic; the target remains unchanged.

`copy-hidden-source-damage` passes its companion and fails at the intended
path-report assertion after removing the source-byte comparison
(`/tmp/nv-p56-copy-mutation.log`). Existing mutation cross-products remain intact.
The private-evidence compiler runner passes 32 ordinary/same-module checks,
including inaccessible `RootCopyAccess` construction, with no fallback batches
(`/tmp/nv-p56-copy-types2.log`). Both accepted compiler diagnostic spellings still
require failure at the marked source line. Strict C diagnostics also pass.

`RepositoryCopySafety` has 17 passing configured outcomes, including exhaustive
finite safety/progress, reachability witnesses and required negative controls
(`/tmp/nv-p56-copy-tla-final.log`). The first draft incorrectly conflated installed
local history with inspected source entries; its failed reporting invariant led
to separating those states. No assertion was weakened. This model does not prove
Foundation coordination or physical copying.

The earlier coordinated-copy runs in this subsection apply to these source fingerprints:

| Source | SHA-256 |
| --- | --- |
| `NVStorageRuntime/RepositoryCopy.swift` | `2d13d73c6e0da0a7f04c3ba0ada73a882233f19a3a2f12f167285e917bd2c7e8` |
| `NVStorageRuntime/RepositoryRoot.swift` | `edfdd1d34614ee5d661ea393377ea493e7fadf6ed4abeabf80532d099f403d03` |
| `RepositoryCopyTests.swift` | `e01f5d77a8ccf21f101104bac55e0edc8939cefd5c231714b9a91e766a9a1049` |
| `RepositoryCopySafety.tla` | `89afdd1dfcd4515bca0cc567ccf4f8d1c66b12eb38b361cc6d1b8605727c6c5f` |

Qualification entrypoints (existing build results are reused for compiler and
mutation prerequisites):

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--filter "coordinatedRepositoryCopy|recoveryCopyUsesVerified|repositoryCopyStreams|repositoryOnlyCopy|repositoryCopyReports|activeRecoveryCopy|repositoryRepairOccupied" --no-parallel'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --filter "coordinatedRepositoryCopy|recoveryCopyUsesVerified|repositoryCopyStreams|repositoryOnlyCopy|repositoryCopyReports|activeRecoveryCopy|repositoryRepairOccupied" --no-parallel'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--sanitize address --scratch-path /Users/scrod/Projects/Notation/NVStorage/.build-address-sanitizer --filter "coordinatedRepositoryCopyKeepsOwnedSourceAndStopsStaleWork|repositoryCopyStreamsWideAndNestedInventories" --no-parallel'
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-runtime-mutations.py --only copy-hidden-source-damage --timeout 900
```

The later increment above qualifies staged canonical installation and fresh-process
copy recovery. The integrated-switch section separately qualifies private-input
transfer and selection races; the connected S4 sections above add bounded recovery
and interference qualification. Broader combinations remain open. No copy report is
activation evidence.
Remote qualification remains unavailable because this session's three previously
provided SSH key files are absent. Physical power loss remains unqualified.

### Qualified source identity

Base commit: `28f47a4b108bd7f126f3c7e67340d68cee9bd885`, with this increment's
uncommitted changes. The first qualified slice used these SHA-256 fingerprints;
subsequent private-activation additions are separately qualified below. These
fingerprints do not qualify those later changes.
the generated validation index separately fingerprints the inventoried test and
runner sources.

| Source | SHA-256 |
| --- | --- |
| `NVStorageRuntime/CollectionStartup.swift` | `aa9350d46827f304efb02a22c32dad60ca3d4755d949a56117fc91aeaad8df32` |
| `NVStorageRuntime/PrivateRepair.swift` | `4dcbac2ec018c8e01ebd16060d364d2a8e51db4f33a39c603767353306126edf` |
| `NVStorageRuntime/RepositoryRepairSource.swift` | `1ed6bee71ec3f505907321647c1ca2cfd09704837f4e3e56ff19e661842eef6b` |
| `NVStorageRuntime/RepositoryRoot.swift` | `1e6b4bc1fc9fb06edbe7dbb60bf6e1ca05895953a05a2abefe08ca6494b83ab8` |
| `NVStorageRuntime/RepositoryPublication.swift` | `b95d99ec47370f38d4df96639c0f703c138a7de8e03debad37309b237c999721` |
| `NVStorageRuntime/RepositoryTransport.swift` | `c6a1ccf3e0e926d144b113e2b4975ca2703bfbb1084cc30f2f027eb6a3a4733b` |
| `CStorageIO/NVRepositoryFiles.c` | `d7b2fb92a3aa00f38160d7dd0e1654d890aa5154cf6c3565fa4b5b61deb5911d` |
| `RepositoryRepairTests.swift` | `9fbbc61453bae77441c4a110ef1e030e14c7ddf4219e6db52ea907e70f15359c` |
| `tests/RepositoryRepairReplacementProbe.m` | `8ef2c0685d93294198b1f9d3ad360b588a7d4ea3272d6f41413ccce16b406e08` |
| `tools/test-storage-repair-replacement-capability.py` | `6c0ff1a8d1c5309dbbf592469424e8b09020fb61fe14062bbb2e2f26c149a456` |

## Implemented boundary

`CollectionSession` owns one reserved repair task and its scoped status. Initial
acquisition and late transport observations/errors reobserve the current entry
before automatic same-root repair. Healthy local publication and saving continue.
Retry starts a new attempt; persistent failure pauses it. Close/reassociation
cancel preparation and join owned work before releasing resources. Known local
history damage retains the required-history recovery outcome.

`CheckedRepositoryRepair` is issued only after bounded publication captures verify
the complete accepted prefix, including descriptors and retained objects. The
fixed capture uses the existing exact immutable installer. Newer edits remain
independently durable and available to normal transport; completion reports only
its captured prefix and count. No persistent table or codec was added. Healthy
compatible startup does not invoke this history traversal.

For a missing top-level directory, a uniquely owned empty stage is opened before
exclusive publication as `NV Data`. Its descriptor transfers to the repair owner
and stays held across bounded turns. Path traversal uses that held directory;
fresh name checks reject replacement without following the competing directory.
The attempt releases its descriptor on completion/error/close. Reserved staging
names retain the existing private-producer assumption; arbitrary tampering with
an unbound unique stage before it is opened is outside that assumption. Abandoned
stages remain preserved rather than inferred safe to remove from their names.

`RepositoryRepairSource` binds an explicitly selected root, live permission and
collection descriptor context. A bounded depth-first reader loads requested
missing IDs, then verifies exact envelopes/descriptors and canonical locations.
`buildVerifiedReplacement` supplements preserved private membership with these
bytes and uses normal bootstrap/intake, private-state reconstruction and reopen
validation. Available provider files never manufacture accepted membership.
A corrupt/misaddressed requested candidate is reported by source index, relative
path and typed failure; the reader continues to later candidates/sources. A complete
replacement carries these issues separately from its exact validated history.
Missing required closure still fails before candidate creation. Root/permission
loss and contradictory valid identities remain terminal for the attempt. Source
files remain untouched. The complementary-source access increment above extends
bounded acquisition to report unreadable subtrees and continue other selected
sources, while preserving those terminal authority and completeness checks.

Listing pages contain at most 16 names and the reader returns one object at a
time. Existing exceptional reconstruction still holds history-proportional
evidence and graph state; this is not a bounded-total-memory repair claim.

### Integrated private activation and saved-work fallback

`CollectionSession.preserveForPrivateRepair` fences integrated admission, settles
provider work and uses the existing preservation-first private-store path. A
pre-close busy refusal keeps the live owner available; a failure after the private
connection closes leaves the integrated owner explicitly closed. Original inputs
remain preserved in both cases.

`repairPrivateStore` combines the exact source evidence, verifies/reopens its
sibling, optionally rechecks an owned repository association, and activates through
`SelectedStoreOwner`. Outcomes distinguish integrated opening, pending activation,
and a durably selected candidate requiring a later ordinary reopen.
`resumePrivateRepair` completes an ambiguous activation before adopting that owner.
The selection actor retains one in-memory attempt and its native file/directory
handles until completion or explicit close. Retry checks the same candidate and
the actual held installed/displaced items, then repeats durability barriers; it
does not perform another replacement. Repeated I/O failure remains uncertain.
An identical-byte but different-inode selected file fails this consumer.
Process restart uses ordinary selection and candidate reopening; the in-memory
attempt is not a new persistent journal.

`copyRepositoryAndSavedWork` can now export its complete captured saved history
when source-root opening fails. Its result reports the unavailable repository
inventory separately from satisfied exact-history requirements. Private pending
input remains in the source, and an occupied destination remains untouched.
Coordinated repository copying and the optional switch now have the separate
implementation/qualification entries above; the full P5.6 matrix remains broader.

The additional production witnesses are:

| Test | Required observation |
| --- | --- |
| `repositoryRepairIntegratedActivationPreservesSourceAndReportsAmbiguity` | Complementary repository bytes plus unpublished private history; verified activation; two failed barrier retries then successful integrated adoption; unchanged damaged source |
| `repositoryRepairIntegratedPreservationClosesOldAdmission` | Saved edit survives preservation; old owner rejects subsequent mutation |
| `repositoryRepairIntegratedBusyPreservationRetainsAdmission` | Busy preservation retains usable local state and permits a subsequent successful preservation |
| `selectionResumptionChecksPhysicalIdentityAndCandidate` | Wrong candidate rejected, selection lease remains held, same-byte replacement cannot satisfy the held-item barrier |
| `activeRecoveryCopyPreservesSavedHistoryWithMissingRepository` | Missing repository reports incomplete extras while exact saved history reconstructs current values; pending input and occupied destinations remain intact |

The extended debug selection/startup/repair run passed 41 tests (173.190 s), and
the final copy run passed four tests (4.676 s). The 29 private compiler probes
passed, including the new public retry consumers and existing restricted evidence
construction. The selection-barrier mutation failed at its intended assertion.
The first busy-preservation mutant was rejected for an unused variable; the
corrected mutant preserves compilation and fails at the intended open-admission
assertion. These are targeted additions, not a replacement for the existing
mutation cross-product or the remaining S4 matrix.

Commands and artifacts:

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--filter "repositoryRepair|collectionStartup|selectionResumption|selectionFault|verifiedSelection|selectionRefuses" --no-parallel'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--filter "activeRecoveryCopy|repositoryOnlyCopy|repositoryCopyReports" --no-parallel'
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-runtime-mutations.py --only repair-selection-barrier --only repair-preservation-busy --only copy-unavailable-inventory --timeout 900
python3 tools/test-storage-private-process.py --binary NVStorage/.build/arm64-apple-macosx/debug/NVStorageProbe --only integrated
```

The fresh-process driver passed all 12 new integrated schedules, across both
profiles: before/after private-state installation, EIO, ENOSPC, normal activation
and process termination after activation. Each failed reconstruction is followed
by a second ENOSPC attempt and a successful new sibling. Independent SQL/history
inspection compares exact object inventory, current values, settings, latest
pending bytes and frozen admission records. The receiving process receives only
surviving selection/unlock inputs. These qualify the integrated private path;
the complementary-source process campaign and namespace-race sections above extend
that evidence to bounded S4 scenarios. Broader P56-* combinations remain open.

Logs: `/tmp/nv-p56-integrated-debug.log`, `/tmp/nv-p56-copy-final-debug.log`,
`/tmp/nv-p56-private-types.log`, `/tmp/nv-p56-activation-mutations.log`,
`/tmp/nv-p56-busy-mutation.log`, `/tmp/nv-p56-integrated-process.log`.
Fresh-process artifacts: `nv-private-process-0jdgrhwb` beneath the local temporary
directory. The final native ASan/UBSan regression campaign also passed
(`/tmp/nv-p56-native-final2.log`). All 45 combined optimized repair/startup/selection/
copy tests passed (154.678 s, `/tmp/nv-p56-integrated-release.log`). The unavailable-
inventory mutation failed at its intended completeness assertion
(`/tmp/nv-p56-copy-mutation.log`). Together with the four earlier repair controls,
all seven targeted P5.6 mutations have designated runtime failures and passing
companions; no existing cross-product was removed.

Final index self-test, regeneration and completeness check passed (406 sources,
141 documents). The required application build again hit Xcode 27's deployment-
target diagnostic; the approved override passed, with the deployment/destination
warnings retained (`/tmp/nv-p56-app-final.log`,
`/tmp/nv-p56-app-final-override.log`). Full-suite results were not claimed or rerun.

| Integrated implementation source | SHA-256 |
| --- | --- |
| `NVStorageRuntime/CollectionStartup.swift` | `62952cc84b8afc669a8e991abd1bd90db5bb7f30dc676821bd4125a64ab85450` |
| `NVStorageRuntime/PrivateRepair.swift` | `a2aa1449026086794e9cea07f2dfd34355dcc47a4e5bf92d05b69d8594fc5557` |
| `NVStorageRuntime/StoreSelection.swift` | `977b37c6ae72408cd2cc1c26810f60bfb94ae45ae8b8503860f50c9a473ef053` |
| `NVStorageRuntime/RepositoryCopy.swift` | `5c4948af5b679b889b6273f17b9d403684349de7f349c1a8bf4bfda2a80ab399` |
| `CStorageIO/NVStorageIO.c` | `c1a3ea2292f0fb84222365a0710e61199a7816ad555768dfdde163b7bafea7b0` |

## Witnesses and commands

The first ten new Swift cases run for both provider profiles, with encrypted private
pages in each:

| Test | Independent assertion / scope |
| --- | --- |
| `repositoryRepairChecksWholePrefixAndRetainsNewerWork` | Exact initial bytes/prefix; newer edit retained after reopening; wrong store/session rejected |
| `repositoryRepairRejectsMissingLastObjectBeforeIssuingCoverage` | Missing last object blocks evidence; independent SQL observes membership and durable damage marker |
| `repositoryRepairAutomaticallyRestoresWithoutBlockingLocalSave` | Held repair permits actual publication/save; restored bytes match; newer edit survives reopen |
| `repositoryRepairPreservesNamespaceRaceWinner` | Competing directory/marker unchanged; occupied final name pauses repair |
| `repositoryRepairFencesReplacedNamespaceBetweenBatches` | Competing directory stays foreign-only after delayed installation |
| `repositoryRepairRespondsToLateDiscoveryWithoutAnotherEvent` | Actual directory move during discovery reaches repair through transport failure; no extra event delivered |
| `repositoryRepairNamespaceRejectsWrongOwnerAndStaleAttempt` | Wrong permission/token, overlapping reservation and repeated settlement rejected by actual consumers |
| `repositoryRepairClosePreservesPartialOutputForFreshRetry` | Close joins cancellation; fresh reopen completes partial namespace |
| `repositoryRepairComplementsPrivateLossWithoutLosingUnpublishedWork` | Repository restores damaged bytes; unpublished edit, settings and pending input survive private reconstruction; fenced source rejected |
| `repositoryRepairRejectsMisnamedComplementAndMissingClosure` | Missing/misaddressed evidence refuses candidate creation; source bytes and resource cleanup checked |

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--filter repositoryRepair --no-parallel'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --filter "repositoryRepair|collectionStartup" --no-parallel'
python3 tools/test-storage-root-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-runtime-mutations.py --only repair-incomplete-prefix --only repair-newer-prefix --only repair-directory-binding --only repair-complement-locator --timeout 900
python3 tools/test-storage-immutable-files.py --sanitize address,undefined
python3 tools/test-storage-repair-replacement-capability.py
```

Executed locally: all 34 first-slice debug repair/startup tests passed (134.812 s,
including the ten new two-profile cases); all 126 compiler probes passed;
all four mutation controls produced their designated runtime failures. The
aggregate driver requires discovery of the ten new cases. Compiler probes cover
ordinary/same-module construction and actual-file unique ownership/executor
confinement. Existing mutation cross-products remain intact.

The native ASan/UBSan campaign passed: directory replacement before traversal,
after its first check, during staging, after installation and between held turns;
staged-directory/occupied-name races; the existing 31 process cuts, repeated
failure/retry schedules and independent loss/visibility controls. These native
process tests are not yet the integrated fresh-process P5.6/S4 campaign.

The unchanged `RepositoryRepairSafety` runner passed all 49 configured safety,
progress, mutation and reachability cases. The first sandboxed run failed before
exploration because TLC's local RMI listener was prohibited; the unrestricted
rerun completed. This is finite model evidence, not whole-program refinement.

Artifacts: `/tmp/nv-p56-repair-final-debug.log`, `/tmp/nv-p56-types-qualified.log`,
`/tmp/nv-p56-mutations-qualified.log`, `/tmp/nv-p56-native-final.log`,
`/tmp/nv-p56-tla-repair-allowed.log`, `/tmp/nv-p56-replacement-capability-final.log`.
The same 34 first-slice optimized tests passed (133.171 s), recorded in
`/tmp/nv-p56-repair-final-release.log`.

`build.sh` encountered the existing Xcode 27 deployment-target error. The equivalent
app build passed with the documented
`__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` override
(`/tmp/nv-p56-app-build-override.log`); deployment-target and destination warnings
remain. The first final debug invocation was blocked by compiler-cache sandbox
permissions before compiling the package; the normal-cache rerun above passed.

## Stop-and-Save-As and complementary-source follow-up

The final policy removes provider occupied-entry replacement from the production
backlog. `CollectionSession` now maps actual repair/install collisions to the
existing `preserveRepositoryCollision` request while healthy local saves remain
available. Initial descriptor/parent kind failures use the same classification.
The request describes Save As/recovery availability; application controls remain
Phase 7. No persistent record, replacement backend or cleanup authority was added.

| Added production witness | Independent observation |
| --- | --- |
| `repositoryRepairOccupiedDamageOffersSaveAsAndKeepsLocalEdits` | Both profiles × regular file/directory/symlink; unchanged occupant identity and contents through two retries; local edit survives reopen; available-file copy preserves regular/directory data and reports the symlink |
| `repositoryRepairLatePublicationCollisionOffersSaveAs` | Damage after the actual publication capture reaches the collision request; original bytes remain untouched and Current stays readable |
| `repositoryRepairInitialWrongKindOffersSaveAs` | Both profiles × descriptor directory/symlink, keys-directory replacement and version-directory replacement; initial/Retry classification remains collision, local values remain readable, source marker remains exact |
| `repositoryRepairContinuesAfterDamagedComplementWithExplicitReport` | First backup contains corrupt bytes, second contains the exact required envelope; reconstruction preserves the original object and Current, reports the first source, and releases listing resources |

`RepositoryRepairSourceIssue` has an issuer-restricted initializer. Its operation-
local report grants no installation or activation permission. Existing restricted
`VerifiedReplacement` issuance still requires complete accepted membership,
required private state and normal close/reopen validation. If required bytes are
missing everywhere, no incomplete replacement is issued. The direct build caller
can inspect the report; future integrated recovery presentation remains an open
gate.

The broad debug regression passed 48 tests (206.903 s); the initial collision-only
run passed its two definitions/eight parameter cases. These cover both profiles.
The private-boundary campaign passed all 31 checks, including ordinary and actual-
module attempts to construct the issue report. Its first run passed the individual
checks but exposed the old expected-count value; that count is now 31. The
report-omission mutation's first form was compiler-rejected for an unused mutable
variable; the compiling form fails at the intended report-count assertion.
Occupied-request, late-collision, exact-locator and final descriptor-kind mutations
also fail at their designated assertions with passing companions. Existing
cross-products remain.

The descriptor-kind work exposed a mistaken handwritten `keys` path in both the
new check and one fixture. Healthy repair companions rejected it. Final code uses
the existing typed repository/version/keys paths, and fixtures cover each occupied
parent. This adds two constant metadata observations to an explicit health check;
it adds neither a directory scan nor a history traversal. The superseded debug
and mutation-baseline failures are retained as diagnostics, not qualification.

The updated `RepositoryRepairSafety` model passed all 58 configured checks,
including occupied-damage preservation, Save As/editing progress and intended
negative/reachability witnesses. Its save-as flag models availability, not physical
copy/activation. The former 28-check displacement experiment is archived below.

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--filter "repositoryRepair|collectionStartup|selectionResumption|selectionFault|verifiedSelection|selectionRefuses|activeRecoveryCopy|repositoryOnlyCopy|repositoryCopyReports" --no-parallel'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --filter "repositoryRepair|collectionStartup|selectionResumption|selectionFault|verifiedSelection|selectionRefuses|activeRecoveryCopy|repositoryOnlyCopy|repositoryCopyReports" --no-parallel'
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-runtime-mutations.py --only repair-occupied-request --only repair-late-collision --only repair-complement-report --only repair-complement-locator --only repair-descriptor-kind --timeout 900
python3 docs/tla/check-segment-models.py --java "/Applications/Wolfram Engine.app/Contents/Resources/Wolfram Player.app/Contents/SystemFiles/Java/MacOSX-ARM64/bin/java" --jar /tmp/nv-tlc-tool.Cap9hd/tla2tools.jar --model RepositoryRepairSafety
```

Artifacts: `/tmp/nv-p56-stop-regression-debug.log`,
`/tmp/nv-p56-stop-regression-release.log`, `/tmp/nv-p56-stop-final-debug3.log`,
`/tmp/nv-p56-stop-final-release.log`, `/tmp/nv-p56-stop-types-final2.log`,
`/tmp/nv-p56-stop-mutations.log`, `/tmp/nv-p56-stop-report-mutation.log`,
`/tmp/nv-p56-stop-descriptor-mutation3.log`,
`/tmp/nv-p56-stop-repair-tla.log`. The first mutation aggregate contains the
compiler-rejected report mutant; its separate corrected rerun is the qualifying
result. The corresponding broad optimized run passed all 48 tests (159.905 s).
The final optimized repair/targeted-startup follow-up passed all 21 tests
(22.829 s). The debug repair/startup follow-up passed 40 of 41 tests; the remaining
busy-preservation test assumed publication-triggered background receive had
already settled. Its success path now waits for actual repair/receive settlement
through existing owner notifications. Its explicit activation-busy refusal,
usable-owner assertion and successful later preservation remain required. Separate
repetition and mutation results below qualify that correction. Older
`final-debug`/`final-debug2` and `descriptor-mutation`/
`descriptor-mutation2` logs contain the superseded fixture/path failures; the
interrupted `final-debug2` run was stopped after diagnosis to avoid further work
on already rejected code.

The corrected busy-preservation case passed ten repetitions per profile in debug
(8.919 s) and optimized builds (8.450 s), and its existing mutation still produced
the designated `remainsOpen` failure. Logs: `/tmp/nv-p56-stop-busy-debug.log`,
`/tmp/nv-p56-stop-busy-release.log`, `/tmp/nv-p56-stop-busy-mutation.log`.
The other 40 final debug cases and the 21 optimized follow-up cases are reused;
the full suite was not rerun. Repetition command:

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--filter repositoryRepairIntegratedBusyPreservationRetainsAdmission --no-parallel --maximum-repetitions 10 --repeat-until fail'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --filter repositoryRepairIntegratedBusyPreservationRetainsAdmission --no-parallel --maximum-repetitions 10 --repeat-until fail'
python3 tools/test-storage-runtime-mutations.py --only repair-preservation-busy --timeout 900
```

The application build required the established Xcode 27 deployment-diagnostic
override and then passed (`/tmp/nv-p56-stop-app-override.log`); the deployment-
target/destination warnings remain. Existing native sanitizer and fresh-process
private-activation results above remain distinct evidence for their unchanged
primitives; this follow-up does not claim new live-provider or power-loss testing.

| Final follow-up source | SHA-256 |
| --- | --- |
| `NVStorageRuntime/CollectionStartup.swift` | `21797f17ffdbc361ec7d32a4918e4d53a1e70ba53c0115c95f793d83debf6517` |
| `NVStorageRuntime/PrivateRepair.swift` | `b3a12c12d0dd12119e97917074e012d180b8942aa84120d731446e1625a452c9` |
| `NVStorageRuntime/RepositoryRepairSource.swift` | `3f89048be51b55868de0e3a4898d42083d02c3383b62ff33d7de063d52b38703` |
| `RepositoryRepairTests.swift` | `49ac8462e87e1b146551224e6097c86ae007e4f33dfd281e056c37702561afd5` |

## Existing-item replacement capability gap

`RepositoryRepairReplacementProbe.m` uses actual dual-URL coordination, an
OS-provided same-volume replacement directory, retained backup, and a
pipe-controlled uncoordinated child writer immediately after the final
expected-entry check. Five ASan/UBSan cases passed on macOS 26.6.2 arm64:

| Case | Current after replacement | Preserved backup | No-write mismatch contract |
| --- | --- | --- | --- |
| Regular file, no race | replacement | old | valid companion |
| Regular file, concurrent entry replacement | replacement | concurrent | **not provided** |
| Populated directory, no race | replacement | old | valid companion |
| Populated directory, concurrent entry replacement | replacement | concurrent | **not provided** |
| Populated directory, concurrent child edit | replacement | concurrent | **not provided** |

Apple documents retained backups and cooperative arbitration, rather than an
expected-generation replacement parameter. See [FileManager replacement](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:))
and [coordinated access](https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(with:queue:byaccessor:)).
This is a limitation of the concrete precheck/replacement approach, not an Apple
contract violation or an impossibility proof for every filesystem design. It
does not qualify production replacement metadata, crash durability or delivery.

The final 2026-10-14 policy is **stop-and-Save-As for occupied damage** and
automatic exclusive repair for missing entries. The earlier preserved-replacement
direction was withdrawn before any production replacement record/backend existed.
Private selected-store activation and ordinary note-saving remain separate.

The prior 28 finite checks and their assumptions are retained with the
[retired exploratory model](../../../tla/retired/impl-proposal-5/preserved-replacement/README.md).
They qualify neither the current policy nor a production replacement path.
The Foundation probe remains useful capability evidence for the simpler policy.

## Bounded accepted-name checks

`RepositoryInventory.swift` selects at most 16 canonical names at a fixed accepted
prefix. File-private cursor/batch/check issuers bind the selected names to the store
incarnation and final root permission. The existing transport worker runs this
pass after a stable directory pass, using its existing timer and bounded retry
state. A failed batch retains its cursor. Later accepted work belongs to a subsequent
pass. The background prefix is capped by completed publication batches; pending
outgoing bytes remain owned by their original write attempts. Publication remains
paused after a failed check until the existing repair or
explicit retry path reestablishes access; local editing stays independent.

The root's exact-name metadata turn groups names by protocol directory, preserves
any separately owned discovery cursor, and closes its temporary directory handle
before returning. Checked observation hints skip reads only when their accepted
identity equals the expected canonical identity. Changed bytes must hash to that
identity. This distinction matters when discovery validly accepts another envelope
found under the wrong canonical filename. Known occupied damage uses Save As;
unknown invalid extras remain outside this accepted-name check.

Private membership reads retain the existing durable verification-request guard.
A crash during that guard may require conservative verification of its captured
history prefix on reopen. Ordinary completed passes clear their own request.
Warm passes perform metadata/index work rather than historical payload decoding;
the two private verification barriers per batch are included in measurements.
There is no added persistent table, journal, inventory, queue or timer.

Qualification commands:

```sh
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter "repositoryInventory|collectionInventory|repositoryDriverCoalescesHintStorm"'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --jobs 2 --no-parallel --filter "repositoryInventory|collectionInventory|repositoryDriver|repositoryRepair|repositoryMetadata"'
python3 tools/test-storage-runtime-mutations.py --only inventory-wrong-hint-identity --only inventory-missing-entry --only inventory-wrong-session --only driver-lost-coalesced-followup --timeout 900 --jobs 2
python3 tools/test-storage-runtime-mutations.py --only inventory-ahead-publication --timeout 900 --jobs 2
python3 tools/test-storage-root-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter 'repositoryInventoryChecksCanonicalNames|repositoryInventoryRejectsChangedObservation|collectionInventoryRepairsMissingAndPreservesDamage|repositoryInventoryRetriesFailedBatch' --jobs 2
```

The tests exercise canonical missing/corrupt/wrong-kind/symlink/hardlink/misnamed
objects, unchanged hints, an unrelated invalid neighbor, fixed prefixes with later
local edits, wrong store/root/session, replacement after metadata capture,
cancellation, retry exhaustion/resumption, and actual collection repair/Save As
without presenter notification. Work checks retain 64/256/1,024 actions and both
profiles with isolated stores. Frozen fixture bytes populate those benchmark roots;
separate direct and connected cases use production publication. This avoids repeating
thousands of coordinated installations merely to time a metadata pass.

Initial diagnostic corrections were a test-only namespace typo (`NV Data/keys`
instead of the canonical `NV Data/v1/keys`), a wrong-root expectation that now
requires the existing `wrongContext` result, and selection of the exact first
captured name for the observation race. The interrupted diagnostic run is not
qualification or timing evidence. LLDB confirmed active installation during its
original expensive growth setup. The probe runner's exact discovery count increases
from 126 to 134 for four new issuers in both client contexts; all prior checks remain.

Model correspondence: accepted-name checking implements observation, which the
repair model assumes as an input. All 58 `RepositoryRepairSafety` configurations
passed with existing safety/progress/reachability controls (`/tmp/nv-p56-inventory-repair-tlc.log`).
The 17 accessor/driver scheduling checks also passed
(`/tmp/nv-p56-inventory-driver-tlc.log`). No modeled safety or fairness condition
changed. The application passes the approved
Xcode 27 deployment-diagnostic override with macOS 11.5 unchanged
(`/tmp/nv-p56-inventory-app-override.log`); ordinary `build.sh` still reports that
known diagnostic.

Completed checks on macOS 26.6.2 arm64 / Swift 6.4:

| Check | Result and evidence |
| --- | --- |
| Debug inventory plus coalescing companion | Seven functions / 36 parameter cases passed in 402.945 s; `/tmp/nv-p56-inventory-qualified-debug.log` |
| Compiler boundaries | All 134 checks passed; ordinary and same-module issuer refusal plus actual-file unique-ownership/executor checks; `/tmp/nv-p56-inventory-types-final.log` |
| ASan with instrumented SQLCipher | Four functions / 26 parameter cases passed in 71.802 s, plus valid-handle companion and intended expired-handle rejection; `/tmp/nv-p56-inventory-asan.log`, artifacts `nv-cipher-sanitizer-lnv42iz3` |
| New inventory mutations | Wrong accepted identity, omitted missing-name failure and wrong session each failed at its exact assertion after the passing companion; `/tmp/nv-p56-inventory-mutations.log`, artifacts `nv-runtime-mutations-rdr7c2go` |

The existing coalescing mutation initially stopped at compilation because its
replacement made `again` unused under warnings-as-errors. Its corrected recipe
keeps the variable used while removing the intended condition. Requalification
passed the same companion and failed at the exact coalesced-pass assertion in both
profiles (`/tmp/nv-p56-inventory-requalification.log`, artifacts
`nv-inventory-mutation-requalification-eb13eq1o`). The existing isolated build was
reused after matching every source/fixture hash; only Finder's `.DS_Store` metadata
was excluded from that comparison. The compile failure is not counted as mutation
success. No compiler setting, discovery check or mutation cross-product changed.

The broader optimized run found a genuine scheduling regression: accepted-name
checking included newly accepted bytes that a failed publication still owned.
Treating those as lost paused its pending write retry. The correction reuses the
existing publication cursor's complete acceptance batches, excluding its final
partial sequence. Before any completed publication, the inventory scope is empty;
this empty result needs no history-verification request. Successful nonempty
publication requests another discovery opportunity. The existing retry-count,
exact-byte and bounded-delay assertions remain unchanged. The new
`inventory-ahead-publication` mutation removes this cap and must fail those
assertions. Its permanent companion, `repositoryInventoryLeavesUnpublishedWorkOwned`,
first pauses publication with a retry beyond the attempt deadline, then waits for
the actual inventory result. It requires an empty scope and the original publication
failure, then explicitly resumes and checks every installed immutable byte. This
avoids a race between a fast inventory pass and a short retry timer. Direct tests
also cover zero/completed/partial/out-of-range prefixes.
The corrected debug run passed all 11 functions / 22 parameter cases in 32.822 s
(`/tmp/nv-p56-inventory-publication-final-debug.log`). The earlier broad run is
component evidence, not a passing aggregate campaign.

Final prefix-correction qualification:

| Check | Result and evidence |
| --- | --- |
| Optimized inventory/metadata/repair/driver regression | 36 functions / 130 parameter cases passed in 80.128 s; `/tmp/nv-p56-inventory-publication-final-release.log`; six completed unchanged growth cases reused separately |
| Deterministic paused-publication companion | Both profiles passed debug in 2.295 s and optimized in 1.195 s; `/tmp/nv-p56-inventory-owned-debug.log`, `/tmp/nv-p56-inventory-owned-release.log` |
| Prefix mutation | Passing companion followed by the intended empty-scope assertion failure in both profiles; `/tmp/nv-p56-inventory-deterministic-mutation.log`, artifacts `nv-inventory-mutation-requalification-0tix5t5d`; exact-source isolated build reused |
| ASan prefix/retry follow-up | Two functions / four cases passed in 19.555 s with instrumented SQLCipher and the native handle controls; `/tmp/nv-p56-inventory-prefix-asan.log`, artifacts `nv-cipher-sanitizer-8oq3hgzi` |
| Final compiler boundaries | All 134 checks passed again against the corrected module; `/tmp/nv-p56-inventory-types-prefix.log` |
| Final application build | Approved deployment-diagnostic override passed; `/tmp/nv-p56-inventory-final-app-override.log`; ordinary `build.sh` retained its known Xcode 27 diagnostic |

The original retry test also caught the prefix mutation
(`/tmp/nv-p56-inventory-publication-mutation.log`); the permanent mutation now uses
the deterministic companion above. All original retry assertions remain present.

Warm debug work measurements include both private verification barriers per batch:

| Ordinary actions / canonical objects | Batches | Public-profile elapsed | Encrypted-profile elapsed |
| --- | --- | --- | --- |
| 64 / 72 | 5 | 0.114 s | 0.103 s |
| 256 / 264 | 17 | 0.396 s | 1.007 s |
| 1,024 / 1,032 | 65 | 2.048 s | 1.455 s |

Every measured pass performed exactly one metadata refresh per canonical object,
zero body reads, zero envelope decodes and zero ancestor visits, with at most 16
names per batch. These are background-pass timings during concurrent qualification,
not launch-time or uncontended latency promises. Fixture construction, initial
observation and warm measurement together took 338.994 s for the six growth cases;
the warm table excludes that setup/cold work. Initial hint recording still uses the
existing per-observation write path and merits separate profiling if it becomes
material. Neither the stored hints nor this pass qualify undetected later disk
corruption as a complete integrity audit.

The initial debug/growth qualification used these source SHA-256 values; the
publication-prefix correction is qualified separately below:

```text
RepositoryInventory.swift      3ce87346375971b65c0a48bcab16c5e08dca83afcd649f0ffabd633792a3e42a
RepositoryTransport.swift      2edd02e70b81ce7aed8ee54a63d104c6c22421b9f99250ab9b0ec7f3761d208f
RepositoryInventoryTests.swift b79eb6b9abc0b029a0beff69e24a891cfed6193050e5ffd0809340a89eb9fc6f
```

The optimized growth component also passed all six unchanged size/profile cases
before the later driver regression: 0.063/0.232/0.906 s for the public profile and
0.074/0.240/0.896 s for the encrypted profile at 64/256/1,024 actions. Its fixture,
cold and warm work totaled 267.087 s. LLDB observed active SQLCipher durability
work in `GrowthHistoryFixtures.build`, rather than a stopped worker. This sample
was outside the measured warm checks. The final optimized rerun skips only
`repositoryInventoryWarmWorkIsBounded`, reusing that completed component's sizes,
profiles and work assertions. All changed publication-prefix and retry paths run
again. This is component-result reuse, not a claim that the earlier failed
aggregate passed.

Final production/source SHA-256 values:

```text
RepositoryInventory.swift      9c0768dbe488fc18c0199dfe4a0c4d48959269bc3c6e990b9c42b99cf14918f2
RepositoryTransport.swift      9f578a79307f907665acc0cab5fbd122662b6d40f8ea6de128bfaf2d54b70b42
RepositoryPublication.swift    096226ac1b6d3fc964c19eae43b009892b524a8c7a0d9b49a9f4da262c90e4d1
RepositoryInventoryTests.swift 40f8bdf69ccf04bd994a521bcb75ed36f929270928ecfc025f000ca8eb57b8de
```

## Quiet copy with periodic inventory — 2026-10-14

The healthy-source witness reproduced a genuine scheduling problem in both
profiles: inventory's durable verification reminders invalidated Save As's
`total_changes()` cut while the user made no edit. The uncorrected production path
returned `sourceRetained(.staleCapture)` in both cases
(`/tmp/nv-p56-quiet-copy-baseline2.log`). The earlier baseline attempt overlapped a
source edit with compilation and is setup failure, not behavioral evidence.

The collection now supplies an actor-isolated scheduling callback to both transport
attachment paths. It uses the existing operation count and root/phase state. A new
optional inventory turn yields to reserved collection work through the existing
delayed demand and timer; its cursor and unconsumed retry budget remain intact.
The worker reserves before awaiting the callback and rechecks lifecycle afterward.
This adds an immutable callback, not a second worker, mutable suspension flag,
permission token, persistent record or transfer protocol. Entered work, ordinary
discovery/publication and user saves retain their original ownership. The final
source-cut and physical-accessor settlement checks are unchanged.

`collectionCopySwitchDefersOptionalInventory` uses the real healthy published root,
actual collection controller and periodic driver. A named idle gate separates
warm-up from the captured copy; the copy's final-preparation gate then permits an
actual periodic opportunity. Both profiles require unchanged SQL write count and
an observed deferral. The quiet case activates and independently compares source
and destination envelope bytes. The newer-edit case refuses stale selection and
reopens the newer body. The cancellation case preserves the old selection and
reopens the original bodies. Both retained-source cases require a later actual
inventory check without another input or refresh command.

This also exposed generic cancellation classification as `.integrity`. Runtime
now preserves `StorageError.cancelled` explicitly, with non-rejection and
ownership/access classification. Raw and classified cancellation both retain
unfinished verification obligations for replay. No admitted input is discarded.
`verificationCancellationReplaysExactScope` now tests both error representations
in both profiles through durable-reminder inspection and normal reopen.

Initial focused debug qualification passed all six copy schedules in 13.043 seconds
(`/tmp/nv-p56-quiet-copy-debug.log`). The broader debug copy/switch, driver,
cancellation and save-interference suite passed 23 functions in 153.860 seconds
(`/tmp/nv-p56-quiet-copy-regression-debug.log`); its verification case predates the
additional classified-cancellation parameter. Final qualification follows below.
These are test-execution observations under concurrent qualification load, not
performance benchmarks. Existing TLA safety conditions remain unchanged; the scheduling
preference is an executable correspondence obligation rather than a new stability proof.

Final qualification on macOS 26.6.2 arm64 / Swift 6.4:

| Check | Observed result and evidence |
| --- | --- |
| Optimized connected regression | 47 functions / one suite passed in 209.288 seconds, including startup, copy/switch, driver, cancellation, and finite save interference. `/tmp/nv-p56-quiet-copy-regression-release.log`. |
| Final debug cancellation and retained-source reopening | Three functions / eight cases passed in 4.776 seconds. The verification test covers raw and classified cancellation in both profiles. `/tmp/nv-p56-quiet-copy-final-debug.log`. |
| ASan, including instrumented SQLCipher | Three functions / 14 cases passed in 49.244 seconds; the native valid-handle companion and intended expired-handle negative also passed. `/tmp/nv-p56-quiet-copy-asan.log`; `nv-cipher-sanitizer-kvznatp2/runtime.log` beneath the platform temporary directory. |
| Compiler boundaries | All 134 root and 42 private-store checks passed, retaining ordinary-client, same-module and actual-source ownership/executor probes. `/tmp/nv-p56-quiet-copy-root-types.log`, `/tmp/nv-p56-quiet-copy-private-types.log`. |
| Scheduling and final-handoff mutations | `inventory-ignores-copy-reservation`, `switch-source-cut`, and `switch-skip-accessor-settlement` each produced the intended targeted runtime failure, following a passing three-function / 20-case companion. `/tmp/nv-p56-quiet-copy-mutations.log`; artifacts `nv-runtime-mutations-hd7ogmiw` beneath the platform temporary directory. |
| Interrupted verification mutation | `verification-skipped-replay` failed the intended exact pending-reminder assertion in all four cases; the final-source companion passed in 3.281 seconds. `/tmp/nv-p56-quiet-copy-verification-mutation.log`; artifacts `nv-copy-verification-requalification-k3bvuq__` beneath the platform temporary directory. |
| Test infrastructure | Mutation-manifest self-test and test-target ownership checks passed; the latter retained all 75 Runtime sources exactly once. |
| Legacy application build | `./build.sh` encountered Xcode 27's known deployment-target diagnostic. The existing `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO` override built successfully, preserving the deployment target. `/tmp/nv-p56-quiet-copy-app.log`, `/tmp/nv-p56-quiet-copy-app-override.log`. |

The first three mutation runs froze the final scheduling and switch code before
the later verification-cancellation refinement. The final replay control reused
that isolated build only after matching its entire source/fixture manifest to the
workspace, rerunning the companion and checking the exact intended assertion.
Its report records the source hashes and validates restoration after mutation.
The optimized and sanitizer runs include the final verification change. Compiler
results continue to cover the unchanged declarations and access boundaries.

The earlier repair/driver/switch model results remain applicable; this increment
adds a scheduling preference while retaining the existing publication, validation
and source-cut predicates. No model run or physical power-loss test is inferred
from the executable results. Remote qualification remains unavailable because
the SSH key files are absent on this host.

Revision-bound source fingerprints:

| File under `NVStorage/` | SHA-256 |
| --- | --- |
| `Sources/NVStorageRuntime/RepositoryTransport.swift` | `bbd4cc337f5c80730fe09955094ea6294b2b48589739ecaf7ed53301e1d271b7` |
| `Sources/NVStorageRuntime/CollectionStartup.swift` | `6dc5e6ebbb68981e20c18b4ab97687dbe01ca7ba0ee691c261824217377670b7` |
| `Sources/NVStorageRuntime/Database.swift` | `154c9ccb69e0bb5904aa0693db74eba62e4b906b5df8a8cdb2d10abb71c8c11e` |
| `Sources/NVStorageRuntime/Commit.swift` | `5dbc0d2877790660cf4ead0acd706ad08b600984083592bc96b0de7bc121c7a6` |
| `Sources/NVStorageRuntime/StorageHealth.swift` | `cfc8d69c107db321dae1cdb3a74e7f93be60444419dfb63790660997438f74f7` |
| `Sources/NVStorageRuntime/ReceiveRejection.swift` | `ffe87db268f38203cb1d0ba36fecd02f06a81abd6b3c22e336779e4679e5f8ef` |
| `Sources/NVStorageRuntime/Verification.swift` | `6504bf3f02b1059204bc6e69ca8b984356d3ad4d897a800f0e1efc8dbb9b2c36` |
| `Tests/NVStorageRuntimeTests/CollectionCopySwitchTests.swift` | `a94e055bb1422c5f1a5f88b38a039adf2ca40e097326a5a7c16d6d1c4883784c` |
| `Tests/NVStorageRuntimeTests/VerificationTests.swift` | `c5905563ceaa73273ff304c539b273b15f671df312697cb15d379ec015568f4f` |

Commands:

```sh
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=--jobs 2 --no-parallel --filter "collectionCopySwitch|repositoryDriver|verificationCancellation|backupCancellation|receivedSnapshotCancellation|snapshotCancellation|commandCalculationChecksClose|validationResumesAfterTwo"'
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=-c release --jobs 2 --no-parallel --filter "collectionCopySwitch|repositoryDriver|verificationCancellation|backupCancellation|receivedSnapshotCancellation|snapshotCancellation|commandCalculationChecksClose|validationResumesAfterTwo|collectionStartup"'
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=--jobs 2 --no-parallel --filter "verificationCancellationReplaysExactScope|collectionCopyKeepsSourceSelectionAndLaterEdits|collectionCopyWithoutRootPreservesSavedHistory"'
python3 tools/test-storage-runtime-mutations.py --only inventory-ignores-copy-reservation --only switch-source-cut --only switch-skip-accessor-settlement --timeout 900 --jobs 2
python3 tools/test-storage-runtime-mutations.py --only verification-skipped-replay --timeout 900 --jobs 2
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter 'collectionCopySwitchDefersOptionalInventory|collectionCopySwitchSettlesAccessorBeforeSelection|verificationCancellationReplaysExactScope' --jobs 2
python3 tools/test-storage-root-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
```

## Selection cancellation and closed evidence — 2026-10-14

The standalone selection witness found that a cancelled task could still enter
installation. Both profiles reproduced failures before the call, at the last
pre-install cut and on resumption of an uncertain attempt; the after-install
companion correctly completed. `/tmp/nv-p56-selection-cancel-baseline.log`
records six failures across eight schedules.

`SelectedStoreOwner` now checks cancellation before install/resume admission and
after expected-current validation immediately before installation. The existing
`attempted` distinction reports an unchanged record for cancellation at that last
cut. Once installation has started, ordinary readback/barrier settlement remains
mandatory. A cancelled resumption retains the pending selection and source leases.
The change adds three checks and no tracked state or evidence constructors.

The broader optimized regression caught a necessary interaction: final Save As
admission precedes settlement of an entered old-root accessor. Cancellation after
that admission already promises completion of the owned handoff. Applying the
standalone check to the caller's cancelled task broke the existing two-profile
`collectionCopySwitchSettlesAccessorBeforeSelection` witness. Its expectation was
retained. That handoff now owns a bounded activation task with independent
cancellation and awaits its result before releasing any resources. The existing
transition state still prevents concurrent handoffs/close. This adds one temporary
task, not a new actor, persistent field or permission bypass; the normal typed
selection consumer performs every context, source and durability check.

`selectionCancellationPreservesEffectBoundary` covers all four cuts in both
profiles, including successful resumption after cancellation, independent selected
record bytes, source exclusion, preserved source bytes and ordinary reopening of
both candidates. `selectionClosedCandidatePreservesPendingExclusion` closes twice,
then challenges a saved copy of the evidence before installation and while an
installed selection is uncertain. The closed candidate refuses activation; the
selection owner separately retains source exclusion until its own explicit close.
A fresh owner reads the exact surviving selection and both databases remain usable.

Qualification completed so far:

| Check | Evidence |
| --- | --- |
| Debug lifecycle/repair regression | Nine functions / 34 cases passed in 36.246 seconds. `/tmp/nv-p56-selection-lifecycle-final-debug.log`. |
| Debug admitted-handoff companion | Four functions / 22 cases passed in 28.548 seconds, including actual entered-accessor cancellation and quiet-copy inventory deferral. `/tmp/nv-p56-selection-handoff-debug.log`. This run predates only the equivalent exact-assertion spelling for the mutation marker. |
| Final optimized lifecycle/repair/copy regression | All 18 selected functions passed in 62.989 seconds against the final source. `/tmp/nv-p56-selection-handoff-release.log`. This includes standalone cancellation, closed evidence, pending resumption, admitted handoff, source-cut interference and integrated private repair. |
| Standalone cancellation mutations | All three designated checks failed at their exact assertions after a passing companion. `/tmp/nv-p56-selection-lifecycle-requalified.log`; `nv-selection-requalification-v68ev050` beneath the platform temporary directory. |
| Admitted-handoff mutation | Removing independent activation cancellation fails the unchanged completion requirement in both cancelled cases. `/tmp/nv-p56-selection-handoff-mutation.log`; `nv-selection-requalification-f7nxrfo5`. |
| Private-store compiler boundaries | All 42 ordinary-client/same-module checks passed. `/tmp/nv-p56-selection-lifecycle-types.log`. Issuers, public APIs and encoded layouts remain unchanged. |
| Initial ASan lifecycle check | Three functions / 16 cases passed in 43.977 seconds, including instrumented SQLCipher and its valid/expired-handle controls. `/tmp/nv-p56-selection-lifecycle-asan.log`; `nv-cipher-sanitizer-ayz4z6hb`. The final handoff task is qualified separately below. |
| Final ASan handoff/lifecycle check | Four functions / 22 cases passed in 44.091 seconds against the final source, with instrumented SQLCipher and its valid/expired-handle controls. `/tmp/nv-p56-selection-handoff-asan.log`; `nv-cipher-sanitizer-k_vfxhoa`. |
| Fresh-process repair | All 12 profile/schedule combinations passed with independent SQL/byte/history observations, repeated EIO/ENOSPC, termination and lost activation callbacks. `/tmp/nv-p56-selection-lifecycle-process.log`. This exercises private repair activation, not the separately changed Save As handoff. |
| Selection model | All 18 configured outcomes passed: ten exhaustive safety/progress checks and eight intended counterexamples. `/tmp/nv-p56-selection-lifecycle-tla-qualified.log`; `nv-segment-tlc-60y8un74`. The module is unchanged, maximum safe state space 92; cancellation/closed-evidence behavior remains an executable obligation. |
| Application build | The normal build reports the known Xcode 27 deployment-target diagnostic; the approved override succeeds with macOS 11.5 retained. `/tmp/nv-p56-selection-lifecycle-app-override.log`. |

The first mutation campaign used generic `Issue.record` failures, which the strict
classifier correctly refused as qualification evidence. The tests now use explicit
`#expect` assertions; the classifier was unchanged. Requalification reused the
completed isolated build only after comparing every source/fixture hash, rerunning
the passing companion and confirming source restoration after each mutation. Old
failed reports remain preserved. The first model run was a sandbox setup failure
(TLC's local RMI listener was denied), not a model counterexample. Its successful
rerun used the same model and configurations.

Final-source fingerprints:

```text
StoreSelection.swift            7ecdc17be0582849b358e896690b6255d977180826448e87235bf2b42c146ec3
CollectionStartup.swift         f37ae21148ddce39d9ac1c0bc03a9d0cdd36de0f0d06b566544fd1ac387ca0af
StoreSelectionTests.swift       0031a6b11f975b08ed6bf699d71bf73a81b343a21251912f2161f4fd50f4b9e7
RepositoryCoordinationTests.swift ea5215304f5cf62122b39104d973819abbe0ba075f79409f08931c294de808ea
```

Entrypoints:

```sh
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=--jobs 2 --no-parallel --filter "selectionCancellationPreservesEffectBoundary|selectionClosedCandidatePreservesPendingExclusion|verifiedSelectionActivation|selectionFault|selectionResumption|selectionRefuses|repositoryRepairIntegrated|collectionCopySwitch"'
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=-c release --jobs 2 --no-parallel --filter "selectionCancellationPreservesEffectBoundary|selectionClosedCandidatePreservesPendingExclusion|verifiedSelectionActivation|selectionFault|selectionResumption|selectionRefuses|repositoryRepairIntegrated|collectionCopySwitch"'
python3 tools/test-storage-runtime-mutations.py --only selection-cancelled-admission --only selection-cancelled-install --only selection-cancelled-resumption --only selection-cancel-admitted-handoff --jobs 2 --timeout 900
python3 tools/test-storage-repository-repair-process.py --binary NVStorage/.build/release/NVStorageProbe
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter 'selectionCancellationPreservesEffectBoundary|selectionClosedCandidatePreservesPendingExclusion|collectionCopySwitchSettlesAccessorBeforeSelection|collectionCopySwitchDefersOptionalInventory' --jobs 2
```

## Repair-union identities and repeated repair — 2026-10-14

The new production-path union tests first construct and accept each source
independently, then preserve both stores and reconstruct in both source orders.
They cover repackaged identical operations, distinct conflicting edits, reused
action IDs with contradictory claims, independent pending inputs and colliding
pending-item identities. Original database, journal, unlock-descriptor and directory
inventories are compared after each successful or rejected attempt. Repackaging
retains both exact envelopes while logical history occurs once; a contradictory
action returns `OrdinaryHistoryError.conflictingClaim`, and conflicting pending
groups return `StorageError.incomplete`.

Repeated repair exposed an implementation gap. A previously repaired complementary
store carried original pending snapshots under an earlier local-store scope. Its
older `repair-source/` bindings were omitted because only the primary store's generic
private groups were copied. The exact pending bytes survived, but complete verification
refused reconstruction with `wrongContext`. `/tmp/nv-p56-union-nested-confirmed.log`
records both profiles failing the intended assertion; the primary-source ordering
was already valid. This was a production mapping error, not a policy or model change.

`installRepairPrivateState` now retains those existing bindings from every private
source in the same private-state transaction. It verifies their framing, codec,
collection and retained descriptor, coalesces exact duplicates and rejects conflicting
binding records. The primary-group installation leaves these already-checked bindings
intact. Existing pending readers still check the original scope; no bypass, new table,
new evidence constructor, persistent cache or format version was introduced.

| Test | Independent obligation |
| --- | --- |
| `repairUnionChecksLogicalIdentity` | Both envelopes survive repackaging; exact historical bodies and conflict count survive independent branches; conflicting action IDs refuse reconstruction in both input orders. Six parameter cases, twelve reconstruction schedules. |
| `repairUnionPreservesOrRefusesPendingGroups` | Four exact latest/frozen payloads and their original review reservations survive independent items; colliding item records stop reconstruction rather than pick a source. Four cases, eight reconstruction schedules. |
| `repairUnionKeepsEarlierRepairCaptureScopes` | Repair → reopen → complementary repair → reopen retains older pending bindings and review state in both input orders. Two cases, four second-repair schedules. |
| `repairUnionValidatesInheritedCaptureScope` | Exact existing binding survives; foreign collection, missing retained descriptor and unsupported codec yield distinct outcomes. Eight cases. |

The selected debug regression passed 13 functions / 40 cases in 57.463 seconds,
including encrypted-page salvage, verification-scope rebinding, rejected/parked input,
portable conflict/Restore/Redo and integrated private repair. Log:
`/tmp/nv-p56-union-debug.log`. All 42 existing private compiler-boundary checks pass
against the rebuilt module (`/tmp/nv-p56-union-types.log`). The standard app build
again requires the documented Xcode 27 diagnostic override, which passes while
retaining macOS 11.5 (`/tmp/nv-p56-union-app-override.log`).

| Additional check | Terminal evidence |
| --- | --- |
| Optimized regression | The same 13 functions / 40 cases passed in 81.073 seconds. `/tmp/nv-p56-union-release.log`. |
| Fresh-process repair | All 12 profile/schedule combinations passed, including repeated EIO/ENOSPC and activation callback loss. `/tmp/nv-p56-union-process.log`; `nv-repair-process-002p_2_6` beneath the platform temporary directory. Independent SQL/history/byte checks and private-marker scans remain intact. This is regression qualification of the integrated repair path; the nested-scope cases above use separate normal openings in one process. |
| Instrumented SQLCipher/ASan | The two pending-union/repeated-repair functions / six cases passed in 23.204 seconds. `/tmp/nv-p56-union-asan.log`; `nv-cipher-sanitizer-ga3gqliq`. Instrumented native valid-handle and designated expired-handle controls also passed. |
| Isolated mutations | All four controls reached their designated runtime assertions after a passing companion with complete discovery: omitted complementary source, overwritten pending record, dropped earlier capture scope and omitted retained-descriptor check. `/tmp/nv-p56-union-mutations.log`; `nv-runtime-mutations-w_kt8x12`. The existing cross-product, classifier and production compiler flags are unchanged. |

The process campaign used rebuilt optimized probe SHA-256
`73a23c72d0752609a9bf72ef37bfe079b67735ac35edb94d3ef2ec45640bd910`.
Remote checks remain unavailable: all three previously supplied SSH key paths are
absent on this host. No new physical power-loss claim is made.

```sh
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=--jobs 2 --no-parallel --filter "repairUnion|complementaryRepair|repairedVerification|repairPreservesReceive|partialPrivateSalvage|encryptedPageSalvage|repositoryRepairIntegrated"'
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=-c release --jobs 2 --no-parallel --filter "repairUnion|complementaryRepair|repairedVerification|repairPreservesReceive|partialPrivateSalvage|encryptedPageSalvage|repositoryRepairIntegrated"'
python3 tools/test-storage-runtime-mutations.py --only repair-union-omit-complement --only repair-union-overwrite-pending --only repair-union-drop-earlier-scopes --only repair-union-unretained-descriptor --jobs 2 --timeout 900
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-repository-repair-process.py --binary NVStorage/.build/arm64-apple-macosx/release/NVStorageProbe
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter 'repairUnionKeepsEarlierRepairCaptureScopes|repairUnionPreservesOrRefusesPendingGroups' --jobs 2
```

The repair model's coherent exact-input assumption remains unchanged; these tests
discharge additional concrete obligations beneath it. No TLA+ safety condition or
input abstraction was weakened. Source fingerprints for this increment:

```text
PrivateRepair.swift      720495bef55dda65b56e62cdd19031edc5011061d233b39a5fcb862e2d6c9c4c
PrivateRepairTests.swift 5421db2f2baa1cd6f61331eac077e419f338efb64528b1dda8cf9618ef9668dd
```

## Post-activation provider failures and automatic-repair growth — 2026-10-14

The fresh-process repair campaign adds three schedules per profile, for 18 total.
Each new schedule first fails private reconstruction with EIO, fails again with
ENOSPC, then completes verified activation from the preserved complementary copies.
It subsequently removes `NV Data` from the selected root by moving it to a retained
test artifact. The independent parent then exercises:

- Two real directory-permission denials, each in a fresh collection process, with
  an accepted local edit during each paused repair. Restoring access and reopening
  alone must finish automatic repair.
- An occupied damaged descriptor, preserved at the same inode through two fresh
  openings and two local edits. After the test explicitly moves that occupant to
  another preserved artifact, reopening must repair the now-missing entry.
- Process termination after complete automatic repair and checked host publication,
  before the process reports completion. Independent readers inspect the installed
  closure and reopen the private store using only ordinary selection/unlock inputs.

The new `collection-repair` probe uses the public collection API and observes its
actual repair state. It publishes checked current rows before capturing user edits;
the first probe draft omitted that host step and was correctly rejected by
`requireEditable`. The correction changes test setup, not production admission.
The permission schedule requires a non-root user; it fails explicitly under root
rather than silently bypassing the actual denial. Original source bytes, selected
record, private settings, frozen/latest pending inputs and independent history
decoding remain checked. Encrypted repository output also excludes the newer edit
markers. Termination here tests process recovery, not physical persistence loss.

`repositoryRepairGrowthYieldsToSavesAndKeepsCapturedCut` uses the existing shared
history fixture at 64/256/1,024 edits in both profiles. Every case receives a separate
physical store. The real collection repairs a missing repository; gates at the
first and second installation batches admit an edit and Delete. The test requires
the complete older inventory and exact bytes, the fixed accepted prefix, at most
16 objects / 4 MiB per small-object batch, zero graph reconstruction/ancestor walks,
and both newer actions retained after ordinary reopening. The normal outgoing
worker is held separately, so its later publication cannot conceal an erroneously
broadened repair cut. Final cleanup waits for that worker's actual admission.
No test imposes a wall-clock pass threshold; emitted repair/save timings are
observations under the current test load. The mutation changes repair's batch cap
to 64 and must fail the exact expected-batch-count assertion with all six cases
still discovered. Existing compiler boundaries and mutation cross-products remain
unchanged.

Qualification entrypoints:

```sh
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=--jobs 2 --no-parallel --filter "repositoryRepairGrowthYieldsToSavesAndKeepsCapturedCut|repositoryRepairConnectedActivationNamespaceRace"'
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=-c release --jobs 2 --no-parallel --filter "repositoryRepairGrowthYieldsToSavesAndKeepsCapturedCut|repositoryRepairConnectedActivationNamespaceRace"'
python3 tools/test-storage-repository-repair-process.py --binary NVStorage/.build/arm64-apple-macosx/release/NVStorageProbe
python3 tools/test-storage-runtime-mutations.py --only repair-growth-batch-limit --jobs 2 --timeout 1200
```

Swift test builds the probe as well as the tests; reuse that executable for the
process campaign rather than immediately rebuilding it with a different testability
configuration. A frozen binary plus its adjacent Runtime resource bundle can be
used while another configuration is building.

These are concrete witnesses for existing complete-prefix, preservation and local
editing rules. No production policy, encoding, evidence constructor or TLA+
assumption changed; the prior applicable model results remain relevant.

Recorded local results:

| Check | Terminal evidence |
| --- | --- |
| Fresh-process repair | All 18 profile/schedule combinations passed. `/tmp/nv-p56-provider-process-release-final.log`; artifacts `nv-repair-process-2yjpqvz4` beneath the platform temporary directory. The frozen optimized probe SHA-256 is `3acb854288ec227bf334516f861589ced202b0bea7e4cfdebc312ac198dab08d`. |
| Initial debug growth run | All six profile/size cases passed in 329.353 seconds, including fixture creation. `/tmp/nv-p56-repair-growth-debug-final.log`. This preceded the explicit wait for outgoing-worker admission during cleanup; final-source qualification is recorded separately below. |
| Final-source debug companion | All six profile/size cases passed in 475.530 seconds, including fixture creation, in the isolated mutation campaign's `baseline.log` under `nv-runtime-mutations-zsa9hphi`. This uses the final cleanup-admission check. The campaign ran alongside other qualification work; these elapsed times are not a before/after performance comparison. |
| Optimized growth and race companion | Two functions / ten cases passed in 468.590 seconds, including shared fixture creation. `/tmp/nv-p56-repair-growth-release.log`. All three sizes in both profiles and the four compatible/foreign namespace-race cases ran. |
| Repair batch mutation | `repair-growth-batch-limit` completed with `targeted runtime failure`; all six profile/size cases ran and the designated batch-count assertion rejected the 64-object mutation. `/tmp/nv-p56-repair-growth-mutation.log`; detailed logs and source hashes in `nv-runtime-mutations-zsa9hphi/results.json`. |
| Application | `build.sh` reports the known Xcode 27 macOS 11.5 deployment diagnostic. The already approved diagnostic-only override passes with that deployment target unchanged. `/tmp/nv-p56-repair-connected-app.log`, `/tmp/nv-p56-repair-connected-app-override.log`. |

The debugger trace `/tmp/nv-p56-repair-growth-threads.log` showed the shared
encrypted fixture actively committing edit 390 with the normal synchronization
barrier. Setup cost was kept separate from repair timing; no durability setting,
history size, profile or test watchdog was relaxed to accelerate qualification.

The optimized small-note runs repaired 72/264/1,032 objects in 5/17/65 batches.
Maximum batch payload was 10,224 bytes; both profiles reached exactly 16 objects
per full batch. Repair took 2.72–38.63 seconds under the concurrent qualification
load; gated local edit/Delete saves took 42–90 milliseconds. These are separate
observations, not latency promises or a test of the maximum-size envelope allowance.

## Bounded private-repair payload reads — implementation and qualification

`PrivateRepairEvidence` now retains issuer-restricted `RepairObjectReference`
values: exact SQL identity fields, canonical path, encoded length and SHA-256.
Envelope/descriptor validation precedes their construction. The original preserved
working database remains the local byte source. Complementary repository sources
retain their original root permission; listing cursors close after acquisition.
Duplicate inventory entries must agree exactly. Complete known membership still
precedes candidate creation.

Construction rereads one required object at a time and compares its metadata,
length and digest before ordinary bootstrap/intake. Subsequent reads repeat that
comparison. SQL bounds the encoded column before transferring it to Swift, and
provider reads retain their existing size and physical-context checks. Available
unaccepted objects are retained individually, followed by the existing atomic
private-group and wait/ready/rejection installation. Any failure leaves the sibling
unselected and preserves original inputs. The replacement capability still requires
complete validation, normal reopening and the existing activation fences.

This removes the additional whole-history encoded buffers from salvage and union
construction. Inventory metadata, pending private records and the semantic graph
still have size-dependent memory costs. Fresh independent keyed reads preserve the
existing damaged-page isolation; the tradeoff is additional source I/O during
exceptional reconstruction, not extra healthy-startup work or a persistent cache.

New qualification:

- `privateRepairGrowthReadsExactObjectsIndividually`: 64/256/1,024-action shared
  fixtures, both profiles, isolated source/replacement stores, per-object read
  counts and sizes, independent expected bytes, current values and source
  preservation. These observations supplement the reference type's payload-free
  layout; they are not a whole-process constant-memory or RSS claim.
- `privateRepairRechecksWorkingCopy`: intact companion, body/metadata damage,
  missing object, wrong store context, and corruption after the first read;
  successful retry with the original evidence after restoring the exact bytes.
- `repositoryRepairRechecksCapturedSource`: intact companion, changed/missing
  canonical bytes, revoked root permission and cancellation after inventory
  capture, before construction consumes the source.
- `repair-reread-metadata`: omit the exact metadata comparison and require the
  designated rejection assertion to fail. Existing inherited-descriptor and
  pre-candidate completeness mutations remain qualification requirements.
- Compiler probes retain all earlier checks and add ordinary/same-module denial
  of access to `RepairObjectReference` (44 checks total).

The model's exact validated union, complete pin before activation and source
preservation predicates are unchanged. Reread failures exercise the concrete
acquisition/validation boundary rather than adding a weaker modeled success path.
No API, encoding, schema, replacement policy or Apple API assumption changes.
Terminal test results and their source revisions are recorded below.

| Check | Terminal evidence |
| --- | --- |
| Focused debug regression | 12 functions / 54 cases passed in 126.897 seconds. `/tmp/nv-p56-bounded-repair-debug-final.log`. |
| Compiler boundaries | All 44 ordinary/same-module checks passed. `/tmp/nv-p56-bounded-repair-types.log`; the existing checks and their exact marked-line requirements remain intact. |
| Targeted mutations | All three controls reported `targeted runtime failure`, with the three-function / 40-case passing companion. `/tmp/nv-p56-bounded-repair-mutations.log`; source manifest, patches and exact assertion locations in `nv-runtime-mutations-8omjobcv/results.json`. |
| Debug growth | All six profile/size cases passed in 868.481 seconds, including 392.735 seconds of fixture construction. `/tmp/nv-p56-bounded-repair-growth-debug-final.log`. The already-built test bundle was reused through SwiftPM's testing helper with Xcode's framework/library paths, without another compilation. |
| Optimized growth and connected regression | 16 functions / 86 cases passed in 783.158 seconds, including all six growth cases and connected activation/access-failure companions. `/tmp/nv-p56-bounded-repair-release.log`. Shared fixture construction accounts for 419.232 seconds; growth alone takes 704.905 seconds. |
| Final-source debug regression | 12 functions / 54 cases passed in 85.224 seconds. `/tmp/nv-p56-bounded-repair-final-debug.log`. |
| Final-source optimized follow-up | Three functions / 24 cases passed in 23.409 seconds. `/tmp/nv-p56-bounded-repair-final-release.log`. The exact-source reread and receive-state companions supplement the earlier broad optimized campaign. |
| Final-source fresh-process recovery | All 18 profile/schedule combinations passed. `/tmp/nv-p56-bounded-repair-final-process.log`; independent child observations, reconstructed history and inventories in `nv-repair-process-_fcbwizh`. The debug probe was reused from the passing test build; its SHA-256 is `a1153cce6f261b77ac47c2430108b53177c2981f901b830f1c44c50e69233b22`. |
| Final-source ASan / SQLCipher | Three functions / 24 cases passed in 87.528 seconds, with instrumented native valid-handle and expired-handle controls. `/tmp/nv-p56-bounded-repair-final-asan.log`; `nv-cipher-sanitizer-w7t6e6ap/runtime.log`. |
| Application | The ordinary script reports the known Xcode deployment diagnostic. The approved diagnostic-only override passes with macOS 11.5 unchanged. `/tmp/nv-p56-bounded-repair-app.log`, `/tmp/nv-p56-bounded-repair-app-override.log`. |

The focused debug, mutation and initial growth runs use `PrivateRepair.swift`
SHA-256 `e3ef5fa31114c522cb6fa326a41e75defd5dcf764e1b9fd9ee0ab2a8b5680f6f`.
Final inspection restored the explicit comparison between the requested catalog
ID and the row's returned ID before issuing its reference. This preserves the
earlier salvage check even if a damaged index were to return an unexpected row.
The final source hash is
`a8290fb8a70c19fb43c0da3a76ae03c6dc46b2028b7add2ccc571e2a80d10e01`;
the final-source ASan, debug, optimized follow-up and process checks include it. The changed
check leaves the three challenged guards and all positive expected identities
unchanged; the earlier results retain their recorded source provenance.

The debug small-note fixtures contain 72/264/1,032 objects. Their largest reread
remains 642 bytes in the public profile and 626 bytes in the encrypted profile at
all three sizes. Salvage takes 0.36–11.54 seconds and reconstruction 6.87–234.14
seconds under concurrent qualification load. These observations qualify bounded
object delivery and complete reconstruction, not a latency promise, isolated
before/after comparison or a maximum-envelope stress measurement. Normal startup
continues to use its separately qualified current-row path.
The optimized run preserves the same per-object sizes and exact inventories;
salvage takes 0.15–8.54 seconds and reconstruction 4.11–138.21 seconds. The final
requested-ID guard's debug follow-up rebuild takes 17.06 seconds, reusing existing
test objects rather than repeating the full build or growth fixtures.

```sh
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=--jobs 2 --no-parallel --filter "privateRepairRechecksWorkingCopy|repositoryRepairRechecksCapturedSource|repairUnion|complementaryRepair|repairedVerification|encryptedPageSalvage|partialPrivateSalvage|repairPreserves"'
make -C tests run-swift-storage 'SWIFT_STORAGE_TEST_FLAGS=-c release --jobs 2 --no-parallel --filter "privateRepairGrowthReadsExactObjectsIndividually|privateRepairRechecksWorkingCopy|repositoryRepairRechecksCapturedSource|repairUnion|complementaryRepair|repairedVerification|encryptedPageSalvage|partialPrivateSalvage|repairPreserves|repositoryRepairConnectedActivationNamespaceRace|repositoryRepairComplementsPrivateLoss|repositoryRepairReportsSourceAccess"'
python3 tools/test-storage-private-types.py --modules NVStorage/.build/arm64-apple-macosx/debug/Modules
python3 tools/test-storage-runtime-mutations.py --only repair-reread-metadata --only repair-union-unretained-descriptor --only repair-source-incomplete-candidate --jobs 2 --timeout 1200
python3 tools/test-storage-sanitizers.py --prefix NVStorage/.deps/sqlcipher-asan --filter 'privateRepairRechecksWorkingCopy|repositoryRepairRechecksCapturedSource|repairPreservesReceiveClassesAndWakesComplementedDependencies' --jobs 2
python3 tools/test-storage-repository-repair-process.py --binary NVStorage/.build/arm64-apple-macosx/debug/NVStorageProbe
```

## Signed repair/copy lifecycle runner

`tools/test-storage-apple-repair.py` adds a P56-25 consumer of the production
startup-controller and its public copy/switch APIs. It reuses the signed
LaunchServices relay, isolated host directories and independent Node history
decoder from the existing transport harness. The probe adds command routing and
observations; production formats, ownership and evidence issuers are unchanged.

Each protection profile performs these connected steps:

1. Create two notes and bootstrap an independent peer from the repository.
2. Deliver an edit and its Undo/Redo, then a peer Delete and fresh-birth Restore.
   Assert expected bodies and identities and the restored source's exclusion
   from Recently Deleted. Exact acceptance, rather than equal current bodies,
   establishes receipt of compensation history.
3. Preserve the synthetic `NV Data` directory outside the active root and reopen.
   Require automatic missing-entry repair, exact installed bytes and healthy
   editing. The preserved original is checked independently.
4. Put damaged synthetic bytes at a canonical snapshot name. Require occupied
   damage to pause provider effects while a new local edit remains durable.
5. Copy without switching, then switch to a fresh repository and private store.
   Require the exact saved cut, explicit preserved-source report, unchanged
   damaged source bytes/inode, copied unrelated file and actual selected-store
   readback. At most three fresh switch attempts accommodate only documented
   `staleCapture`/`busy` interference; each rejected attempt preserves the source.
6. Bootstrap another fresh peer using only the destination repository and normal
   unlock inputs. Verify full retained history independently, then Undo/Redo the
   post-damage edit on that peer and deliver those exact actions back. Both stores
   must retain the same complete history and the independently expected notes.

Local-only semantic commands run while their signed collection owner is closed.
Repair, copy, switch and provider discovery/publication use the signed production
consumer. Live mode transfers only harness/configuration and selection/unlock
inputs over SSH; immutable collection data must arrive through the provider.
Unavailable names can wait; permission failures fail explicitly. Received but
unaccepted actions remain pending until exact acceptance is observed.

```sh
python3 tools/test-storage-apple-repair.py --self-test
python3 tools/test-storage-apple-repair.py --local-binary NVStorage/.build/arm64-apple-macosx/debug/NVStorageProbe --timeout 120
python3 tools/test-storage-apple-repair.py --local-binary NVStorage/.build/arm64-apple-macosx/release/NVStorageProbe --remote-binary /tmp/qualified/NVStorageProbe --ssh-target scrod@scrodmini.local --ssh-key /tmp/scrodmini_ed25519 --repository-parent '/Users/scrod/Library/Mobile Documents/com~apple~CloudDocs/API_Contract_Testing' --timeout 600
```

The initial signed debug companion passed both profiles in
`/tmp/nv-p56-apple-repair-debug.log`, with exact reports under
`/tmp/nv-p56-apple-repair-gohln9ab`. The runner's valid companions and six deliberate
bad history/membership/note/copy reports passed their intended checks. Later runner
refinements distinguish pending acceptance and absent names from integrity/access
failures; final optimized and live qualification are recorded separately below.
Existing production mutation campaigns remain required and unchanged.

The first live run passed the public profile, then exposed an observation error
in the encrypted profile. The complete-history oracle ran while accepted history
was at sequence 3 and materialized current rows were still at sequence 2. Those
are deliberately separate transactions. The exact captured report reproduces the
oracle's frontier mismatch; reopening that same peer completed the normal work
and passed the unchanged full oracle (nine retained objects, seven operations,
four actions). The failed attempt is retained at
`/tmp/nv-p56-apple-repair-rez_m95o`; the confirming recovery report is
`/tmp/nv-p56-intermediate-reopen-oracle.json`.

The runner now polls the exact object's hash and accepted membership during
delivery, with SQLite integrity/foreign-key checks. It performs the full semantic
comparison after closing the corresponding signed owner, when the observation
is quiescent. All final byte, dependency, membership, current-value and copy-report
assertions remain. The self-test requires an unaccepted object to remain pending.
No production implementation, persistence policy or model assertion changed.

The Intel execution follow-up passed all 12 `--only integrated` private-repair
schedules on each restored host: macOS 14.8.9 Mini
(`/tmp/nv-p56-mini-private.log`, `nv-private-process-y4fl_ebo`) and macOS 11.7.11
Orbb (`/tmp/nv-p56-orbb-private.log`, `nv-private-process-72myap2v`). Both profiles
cover repeated before/after-commit termination, EIO/ENOSPC, successful integrated
repair and missing activation callback. Each report is independently decoded on
the controlling Mac. The Intel Swift 6.4 probe SHA-256 is
`b0778ca152205747ed47e0ebe68ebf953edd7e433edb5c80e4116cf0b9a22ff0`;
the optimized arm64 probe is
`ee934b67d58d1cc510794deb8d6806213f092b174770b22eb879a99a4968f887`.
The documented metadata-accessor compiler workaround and isolated concurrency
runtime are still required on Orbb. Xcode 27 still stamps minimum OS 12.0 despite
the 11.5 target request; successful macOS 11 execution leaves that distribution
gate explicit. No system runtime was replaced on either Mac.

The corrected final runner passed both profiles in the signed local debug
companion (`/tmp/nv-p56-apple-repair-debug-final.log`,
`nv-p56-apple-repair-9k15trln`) and the optimized two-Mac iCloud run
(`/tmp/nv-p56-apple-repair-live-final.log`, `nv-p56-apple-repair-ho0qd5rt`).
Each profile repaired 11 exact objects, switched successfully on its first
attempt, and finished with 14 retained objects on both independent stores after
the final remote Undo/Redo. The live fixture is the synthetic
`API_Contract_Testing/P56-dd5779a8309c461395be8bc1be22c543` repository;
all history crossed through iCloud. Exact reports and independent decoding
outputs remain in the artifact directories. Runner SHA-256:
`073acd80f5378e6311a354eb384d843879929d20b11f283f2ef0725e514897c1`.
This qualifies those connected consumers on macOS 26.6.2/14.8.9, not production
distribution, physical power loss or induced account-full/offline conditions.

## Scenario-to-consumer crosswalk

These witnesses implement the plan's P56 scenarios. The sections above retain
commands, parameter counts, faults and source provenance; the
[validation index](../../../Test-and-Validation-Index.md) inventories individual
declarations and runners. This crosswalk connects those checks, rather than
claiming exhaustive coverage of every possible interleaving.

| Plan cases | Production witnesses and observations |
| --- | --- |
| P56-01–03 | `repositoryRepairAutomaticallyRestoresWithoutBlockingLocalSave`, `repositoryRepairRespondsToLateDiscoveryWithoutAnotherEvent`, `repositoryRepairChecksWholePrefixAndRetainsNewerWork`, and `collectionInventoryRepairsMissingAndPreservesDamage`: actual automatic repair, exact closure and unchanged local admission. |
| P56-04 | P5.5's `collectionStartupOfflineProceedsWithLiveHeldAccessor`, exact-unread/late-disclosure companions, and P5.6 held-accessor switch tests: named evidence, healthy local edits and owned accessor settlement remain separate. |
| P56-05, 09 | `repositoryRepairComplementsPrivateLossWithoutLosingUnpublishedWork`, `complementaryRepairPreservesUnpublishedHistoryAndPrivateInputs`, pending-group/capture-scope union tests, and `repairedVerificationUsesMembershipRatherThanCopiedSequence`: complete compatible union and preserved private inputs. |
| P56-06–07 | `repositoryRepairGrowthYieldsToSavesAndKeepsCapturedCut`, `repositoryRepairConnectedActivationNamespaceRace`, namespace-fencing tests and `coordinatedRepositoryCopyKeepsOwnedSourceAndStopsStaleWork`: newer saves and contenders remain independently accounted for. |
| P56-08, 10, 12 | Encrypted-page/partial salvage, required-membership and rejected-input tests in `PrivateRepairTests`; `repositoryRepairRejectsMisnamedComplementAndMissingClosure`; repeated-failure process runner: salvage remains explicit, incomplete history stays unselected. |
| P56-11 | Explicit creation/private-loss bootstrap and wrong-parent checks carried from P5.5, plus `repositoryRepairComplementsPrivateLossWithoutLosingUnpublishedWork`: fresh ownership and no silent alternate location. |
| P56-13 | `complementaryRepairKeepsConflictRestoreAndCausalRedo`, snapshot-retention recovery companions and the signed P56-25 lifecycle: retained history preserves logical state independently of delivery order. |
| P56-14–15 | `repositoryRepairOccupiedDamageOffersSaveAsAndKeepsLocalEdits`, wrong-kind/late-collision/source-access matrices and `recoveryCopyUsesVerifiedHistoryAndReportsPreservedDamage`: source occupants stay intact; verified local bytes supply fresh canonical destinations. |
| P56-16–17 | `test-storage-repository-repair-process.py`, `test-storage-private-process.py --only integrated`, selection-fault/resumption/cancellation tests and connected post-activation recovery: repeated failures, actual selected-record readback, exact bytes and independent reopening. |
| P56-18–20 | `test-storage-repository-copy-process.py`, repository-only/active-recovery-copy tests and `explicitCurrentExportHasFreshBirthsAndUsableCredentials`: source-unavailable recovery, honest partial copies, saved-work supplementation and distinct fresh export. |
| P56-21 | `CollectionCopySwitchTests`, both entered-accessor switch tests and the signed lifecycle: actual copy-only/selection changes, private inputs, stale cuts and old-owner settlement. |
| P56-22 | Stage-substitution/namespace-race tests, owned native cleanup controls, reader cancellation and `repositoryRepairClosePreservesPartialOutputForFreshRetry`: recovery/foreign contents survive; disposable-resource ownership is checked. |
| P56-23 | Two-profile copy/repair/export suites, independent envelope decoding and marker checks, plus wrong-key fixtures: provider confidentiality and password-free recoverability are checked separately. |
| P56-24 | 64/256/1,024-action repair, saved-copy, private-salvage and inventory tests: exact batch/read bounds, preserved captured cuts and local-save progress; metadata/exceptional reconstruction remain history-proportional. |
| P56-25 | `test-storage-apple-repair.py`: signed local companions and actual two-Mac provider delivery through repair, occupied damage, copy/switch, fresh bootstrap and remote Undo/Redo. |

## Final platform follow-up

### Linux test scheduling follow-up

The restored Ubuntu 26.10 arm64 host uses Swift 6.4 and the unchanged strict
production compiler/linker settings. The first targeted run discovered all 11
selected test functions; ten passed, while the competing-copy companion failed.
An isolated repeat reproduced it. Adding the typed outcome to its failure report
showed `sourceRetained(busy)` (`/tmp/nv-storage-disk/p56-competing-diagnostic.log`).
The test's `collectionBodies` helper performs a real host publication, which
starts the existing receive owner. It had released its held copy immediately
after that publication, unintentionally racing the receive-settlement guard.

The companion now waits for actual receive settlement before requiring successful
cutover. An additional case deliberately holds that owner, requires exact busy
refusal and unchanged selection/source, then releases it and requires a fresh
copy/switch to succeed. All original competing-preparation, selected-record and
note-value assertions remain. The four cases (two profiles × settled/held receive)
pass locally in debug (10.339 seconds) and optimized code (5.300 seconds);
production code and modeled behavior are unchanged.
The existing `switch-competing-reservation` mutation still targets the original
reservation assertion: its final isolated four-case baseline passes (10.230
seconds), and removing that guard produces the designated runtime failure.
Logs: `/tmp/nv-p56-competing-final-debug.log`,
`/tmp/nv-p56-competing-final-release.log`,
`/tmp/nv-p56-competing-final-mutation.log`; isolated artifacts:
`nv-runtime-mutations-u76yu_17`. Final test-source SHA-256:
`6f87518487bffccdbb377925c92d3e7a20d2db730dcca0a7cd223b5d909b0a19`.

Linux's compiler-boundary campaign passed all 44 checks in eight batched
invocations (19 ordinary-client checks / 5.471 seconds and 25 same-module checks /
78.634 seconds), with no fallback batches. Its log is
`/tmp/nv-storage-disk/p56-final-private-types.log` on the VM. Both actual debug
executables pass PIE, W^X, non-executable-stack and RELRO checks and reject the
deliberate RWX mutation (`/tmp/nv-p56-ubuntu-elf.log` on the controlling Mac).
SwiftPM's separate manifest-linker warning remains visible; it does not describe
either qualified executable. The VM is managed by Multipass; SSH is sufficient
for these runs. No Linux API, compiler or safety contract was relaxed.

All 12 Linux `--only integrated` fresh-process schedules also pass, with each
history report independently decoded on the controlling Mac:
`/tmp/nv-p56-ubuntu-private-final.log`, `nv-private-process-wyzxjijv`.
These are the same before/after-commit termination, repeated EIO/ENOSPC,
successful repair and missing activation-callback cases run on both Intel Macs.
The first launch attempted the probe while SwiftPM was relinking it and received
an explicit missing-executable error; the recorded successful campaign began
after linking. It supplies no evidence for that failed launch. Temporary swap
created during compilation was removed once memory pressure subsided; test
artifacts and build caches remain.

The final Linux debug slice passes all 11 selected functions / 62 parameter
cases in 49.325 seconds after a 599.06-second build. Its four competing-copy
cases pass in 4.042 seconds. Log on the VM:
`/tmp/nv-storage-disk/p56-final-debug-settled.log`. The filter covers private
and repository-source rereads, retained receive classes, coordinated copy and
all portable `collectionCopySwitch*` tests. The optimized run uses the same
filter and parameter cross-product: all 11 functions / 62 cases pass in 15.937
seconds after a 658.61-second module rebuild. Its four competing-copy cases pass
in 1.212 seconds. Both optimized executables pass the same ELF checks and reject
the RWX control. Summary on the controlling Mac:
`/tmp/nv-p56-ubuntu-release-qualification.log`.

The first optimized attempt stopped before test discovery because Clang loaded
the same `_Builtin_stddef` cache through both `/tmp/nv-storage-disk` and its
`/var/lib/nv-storage-test-volume` bind-mount path. Native stat confirmed identical
device/inode values for the reported files; the dependency lockfile matched the
controlling workspace exactly. With all compiler processes stopped, only release
`ModuleCache` and `Modules` were moved to
`/tmp/nv-storage-disk/p56-release-cache.sTa7tz` for a clean module rebuild.
Compiled C objects, dependency sources, lockfile and every strict flag were retained.
The failed build is recorded in `p56-final-release.log`; the rerun uses
`p56-final-release-clean-modules.log` in the same VM artifact directory. The
build failure is not a test failure or evidence of a weakened Linux contract.

Final optimized SHA-256 values:

- `NVStorageProbe`: `0493485693c803a2242d8ace8fc2c90c2d10224ff4df126af48ebce01ff2c93f`.
- `NVStoragePackageTests.xctest`: `3388dfe469497c3a2bcb393c46b4b52c9dbd39c5e83ff8127bd613bb13f54c9c`.

The remote private-repair reader, repository-repair reader, strengthened switch
test and dependency lockfile match the controlling workspace hashes
(`/tmp/nv-p56-ubuntu-source-parity.log`). These final targeted checks supplement
the earlier full/component campaigns at their recorded source revisions; they
do not claim a newly executed full suite.

### Remaining phase-wide and release gates

The bounded private-source reader's local debug/optimized, growth, compiler,
mutation, fresh-process and sanitizer gates are complete within the source
provenance recorded above. The affected S4 repair/activation consumers pass. These
bounded schedules cover repeated private-state installation failures,
post-activation provider failure/occupied damage, local edits, lost callbacks,
namespace contenders and held-accessor switching.

- The broader S1–S6 generated
  combinations remain the explicit [P5.7 connected qualification](07-connected-qualification.md)
  scope; passing these witnesses is not a claim that every schedule is equivalent.
- P56-25's signed two-Mac repair/copy witness and the affected macOS 11/14
  private-repair process checks passed as recorded above. The affected Linux
  debug/optimized, compiler-boundary, fresh-process and executable-security checks
  also passed with the same contracts and strict compiler settings.
- Production distribution and physical power-loss qualification remain separate
  from these signed test applications and process-termination checks.

The active repair model retains complete-input, physical-authority and truthful-effect
requirements. Occupied-entry preservation replaces the withdrawn displacement
protocol. Concrete tests supplement the model's filesystem assumptions.
