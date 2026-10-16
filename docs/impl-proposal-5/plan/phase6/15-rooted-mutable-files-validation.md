# P6.2 — Rooted mutable-file qualification

Status: **in progress**, with integrated reads, native exclusive creation and
replacement qualification listed below. The Swift creation consumer, checked
replacement-input factory and internal physical replacement consumer have
executable coverage, including fresh-process recovery inspection.
Replacement still requires displaced-artifact accounting and cleanup. This is
not completion of P6.2's six physical operations.

## Lessons carried forward from the Objective-C tests

The existing `NVRootedDirectory` tests remain behavioral acceptance criteria,
as required by [the Foundation migration](../../../Foundation-Safe-Replacement-Migration.md#preservation-of-the-atomic-note-saves-contract).
Their scenarios are catalogued in [IntegrationTests](../../../IntegrationTests.md).
The table distinguishes equivalent new-path evidence from work still required;
a passing legacy binary qualifies its existing backend, not a new Foundation
consumer.

| Existing scenario / lesson | P6.2 evidence and remaining gate |
| --- | --- |
| `snapshot-stress`, `snapshot-boundary-races`, `snapshot-failures`: bytes, encoding, tags and identity must describe the same open file | Production rooted-read tests challenge final-name substitution, metadata change, failed reads and moved roots. The replacement probe's child reader requires complete old or new bytes with the corresponding mode, dates and xattrs; it requires observations on both sides of installation. |
| `atomic-rollback`: compare the exact expected source and preserve the actual displaced contents | The native replacement probe changes the target before preflight and after preflight, inspects the resulting backup independently, and checks every observed effect classification. Matching timestamps or successful coordination never replace the byte comparison. The internal Swift consumer retains both snapshots and the durable candidate; fresh recovery/settlement of unexpected displaced contents remains required. |
| `atomic-rollback`, `atomic-replacement-capabilities`: preparation, metadata and final verification can fail independently | Wrong stage/source, corrupted preparation, metadata-copy failure, final body/metadata interference and before/after-effect errors have native companions and isolated controls. Permission/xattr/date checks run on APFS, APFSX, HFS+ and HFSX. Complete metadata/provider qualification and the limited-filesystem outcome remain separate gates. |
| `atomic-rollback`: cleanup must prove ownership of the item it removes | Creation retains its owned-stage and cleanup checks. Replacement currently retains all displaced material; backup change/rename tests prevent treating an unverified backup as settled. Replacement cleanup and restart accounting are still to be implemented and qualified. |
| `directory-relocation-races`, `deep-directory`: the opened directory remains the authority when paths move or are reused | Rooted reads and creation have move/reopen tests; the native replacement probe moves the opened root and creates another directory at its former path. Full deep-path and rename-in-flight replacement qualification remain gates, subject to the explicitly adopted fresh deep-HFS+ opening limitation. |
| `rename-without-preflight`, `rename-enoent-source-proof`: avoid existence-check races; ENOENT only settles a genuinely absent source | These remain explicit requirements for the forthcoming rename/source-cleanup consumer. Replacement of one filename does not qualify either behavior. |
| `filename-collisions`, `case-sensitive-filename-collisions`: preserve unrelated occupants and handle case-only renames deliberately | Creation tests preserve late occupants. Same-name replacement preparation rejects rename inputs. Case-only renames, destination collision handling and independent source accounting remain rename-consumer gates. |
| `file-outbox-crash-recovery`, `disk-full-recovery-contract`, `wal-durability-boundaries`: file installation and durable user actions have separate completion boundaries | Modern tests use accepted immutable history and exact frozen/intended generations instead of the legacy WAL. Creation completion preserves newer pending edits. Replacement-input tests retain frozen B while newer C survives reopen; native abrupt-exit checks preserve both installed and displaced bytes. These still require connected replacement/SQL recovery and I/O-failure schedules. |

`snapshot-in-place-observation` also supplies an important limit: stable
intermediate states from an uncoordinated in-place writer can be indistinguishable
from finished writes. P6.2 retains the atomic safe-save producer contract rather
than claiming that coordination or repeated observations eliminate that limit.
Only backend-specific capability injection needs translation to Foundation fault
points. The old behavioral assertions, failure classifications and preservation
requirements remain.

## Entry points

```sh
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'projectionFileRead|projectionCreation'"
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c release --no-parallel --filter 'projectionFileRead|projectionCreation'"
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'projectionReplacement|projectionCreation|projectionFileRead'"
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c release --no-parallel --filter 'projectionReplacement|projectionCreation|projectionFileRead'"
python3 tools/test-storage-runtime-mutations.py --only p62-recovery-source-history --only p62-recovery-final-owner --only p62-recovery-root --only p62-recovery-inspection-context
python3 tools/test-storage-runtime-mutations.py --only p62-replace-fresh-candidate --only p62-replace-final-history --only p62-replace-uncertain-retirement --only p62-create-receipt-context
python3 tools/test-projection-files-c.py
python3 tools/test-projection-files-c.py --only create
python3 tools/test-projection-files-c.py --only crash
python3 tools/test-projection-files-c.py --only source
python3 tools/test-projection-files-c.py --only source --filesystems HFS+ HFSX
python3 tools/test-projection-files-c.py --only source --foundation --filesystems HFS+ HFSX
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'projectionSource|projectionDeletion|projectionReplacement|projectionCreation|projectionFileRead'"
python3 tools/test-storage-runtime-mutations.py --only p62-source-reservation-write --only p62-source-final-owner --only p62-source-uncertain-retirement --only p62-source-recovery-owner --only p62-source-recovery-captured-store --only p62-source-recovery-context --only p62-source-recovery-final
python3 tools/test-projection-files-c.py --foundation
python3 tools/test-projection-read-process.py --binary NVStorage/.build/debug/NVStorageProbe
python3 tools/test-projection-create-process.py --binary NVStorage/.build/debug/NVStorageProbe
python3 tools/test-storage-root-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-root-types.py --modules NVStorage/.build/release/Modules
python3 tools/test-storage-runtime-mutations.py --only p62-read-cancellation --only p62-read-final-owner
python3 tools/test-storage-runtime-mutations.py --only p62-create-final-history --only p62-create-live-note --only p62-create-receipt-context
python3 tools/test-storage-runtime-mutations.py --only p62-read-kind-before-size
```

Use the mutation driver's `--configuration release` for the optimized campaign.
The process driver uses the existing `root-hold` client and independently creates
and checks all filesystem inputs. It has eight required scenarios: exact raw
metadata/bytes/times, empty files, replacement after capture, metadata-only change,
wrong kinds/links/absence, moved root versus replacement pathname, revoked
generation, and fresh-process reopening. It retains every synthetic fixture.

The Swift suite checks exact and empty bytes, caller budgets including expanded
encoded-file budgets, wrong owners, stale generations, replacement by a new
physical item, wrong kinds/hard links, entered-read close/cancellation and owned
root movement. It uses actual production accessors and native reads. Independent
Foundation reads check preserved inputs.

The native driver compiles actual production code with strict conversion/memory
diagnostics, rejects static-analyzer findings and runs ASan/UBSan at O0 and O2.
Fifteen cases include raw attribute presence/empty/absence, exact values,
permissions, short reads, EINTR, EIO, premature EOF, changed metadata/permissions,
replacement at the last name check, stale identity, hard link, symlink, invalid
leaf, allocation limit and descriptor exhaustion. Both ordinary and retaining
read variants run every case and control. The retaining variant independently
checks the descriptor's identity, close-on-exec flag, caller-owned close and
failure cleanup; descriptor counts also catch leaks from ordinary reads.
Both configurations require the complete positive
marker and kill two isolated mutations at the designated `result == expected_result`
assertion: omitted final name verification and omitted revision checking.

An initial mutation removed only one of the two revision checks; the remaining
final-name revision check correctly rejected the race. The retained negative
control instead removes revision comparison throughout the reader, directly
challenging the required property without relaxing any production assertion.

Root construction probes retain every existing check and add ordinary/same-module
construction rejection, immutable fields, Decodable rejection and a valid public
consumer. The reader increment's count was 142 (69 ordinary, 69 same-module, four actual
source ownership/executor probes). The first run executed every check successfully
but hit the old inventory-count assertion; the counter was updated to include
the eight new checks.

## Native exclusive-creation qualification

`tests/ProjectionFilesCreateProbe.c` calls the actual preparation/installation
functions with real filesystem effects. Its 31 scenarios cover exact and empty
output, short writes/EINTR, EIO/ENOSPC/zero-progress writes, missing mandatory
attributes, mandatory versus optional attribute failures, preparation/installation
barriers, directory-sync reporting, stage corruption/substitution/collision,
wrong owner/permissions/leaf/body, late destination collision, later replacement
or in-place edit, final metadata changes, lost syscall return, root move/loss and
requested creation timestamps. Independent POSIX reads inspect bytes, metadata,
permissions and preserved named artifacts. Failed preparation cannot be installed.

O0 and O2 each require the exact 31-case completion marker and five isolated
negative controls: overwrite instead of exclusive creation, early success,
omitted mandatory-tag readback, acceptance of absent mandatory metadata, and
omitted final-name revision comparison. Each must fail its designated assertion;
all previous reader controls and the repository mutation cross-product remain.
The native source also passes strict conversion/memory diagnostics, the Clang
static analyzer, ASan and UBSan.

`tests/ProjectionFilesCreateProcessProbe.c` abruptly exits a child at stage
creation, completed staging, namespace installation or final verification; the
fifth scenario completes normally. A pipe independently proves that interrupted
operations delivered no acknowledgement. Fresh owners/descriptors inspect the
surviving stage or destination and retry from a separate exclusive stage. The
retry either installs at the still-absent destination or reports collision while
preserving both the already-installed output and retry stage. Both configurations
require all four interrupted schedules and their acknowledged companion.
The initial fixture used an incorrect literal attribute length (14 rather than
15 bytes); correcting that independent test oracle produced the passing run.
These are process-termination tests, not simulated persistence loss or physical
power-loss evidence. Frozen SQL inputs and receipt publication are outside this
native harness and retain their separate P6.1/P6.4 scope.

The driver defaults to all native campaigns. `--only read`, `--only create` and
`--only crash` select complete subcampaigns for explicit qualification reuse;
they preserve their O0/O2, sanitizer, assertion and negative-control checks. A
selected run does not claim the omitted campaigns executed.

### Results, 2026-10-15

- Local macOS, Intel macOS 14.8.9 and Intel macOS 11.7.11 passed all native
  read/create/process campaigns in O0 and O2, including static analysis,
  ASan/UBSan and the seven total reader/creation controls. Local log:
  `/tmp/nv-p62-exclusive-create-qualified.log`; remote logs:
  `/tmp/nv-p62-create-final-mini.log` and `/tmp/nv-p62-create-final-orbb.log`.
- Ubuntu arm64 passed the same campaign on its memory-backed `/tmp` at
  `/tmp/nv-p62-create-final-linux.log`. The runner uses Clang from the installed
  Swift 6.4 toolchain. Creation-time requests return the explicitly asserted
  `ENOTSUP`; the successful Linux companions use modification-time metadata.
  The full campaign also passed on its disk-backed ext4 mount with
  `TMPDIR=/tmp/nv-storage-disk`; log `/tmp/nv-p62-create-ext4-linux.log`, artifacts
  `/tmp/nv-storage-disk/nv-projection-files-c-1i572f5q`. A final Linux-only
  assertion checks the exact unsupported-creation-time error, qualified with
  the complete `--only create` campaign on that same disk mount.
- Actual package `CStorageIO` debug/optimized builds passed in 2.23/1.87 s,
  without rebuilding/relinking unchanged Swift suites. Logs:
  `/tmp/nv-p62-create-c-target-{debug,release}.log`. The app build passed with the
  established diagnostic-only deployment override at
  `/tmp/nv-p62-create-app-build.log`; deployment target 11.5 remains unchanged.

These results qualify the narrow native boundary. Reuse the already-completed
Swift reader and P6.1 compiler/history suites: their production Swift files and
boundaries are unchanged by this increment. No raw native result is promoted to
an accepted projection receipt. Additional volume/provider checks, OS-provided
stage acquisition, unique Swift stage ownership, consumer probes and connected
history-to-file schedules remain required before that bridge is complete.

## Integrated creation bridge (qualification in progress)

`ProjectionFileCreationTests` exercises exact UTF-8 and retained UTF-16 output,
independent file bytes, encoding/tag plist contents, dates, mode and stamp outcome;
missing frozen input; wrong store/root; a Delete before installation; newer C or
Delete during a held native install; cancellation, close and reassociation after
the effect; late destination collision/replacement; root movement versus a new
old-path occupant; and stale receipts/session evidence. Private frozen inputs and
newer intentions survive both completion and ordinary reopening. Test callbacks
hold the actual stage/install boundaries on the dedicated root executor.

An initial root-move test incorrectly assumed the old bookmark would resolve to
the moved directory after restart and old-path replacement. Installation itself
followed the held directory, but the existing association check rejected the new
attempt. The corrected test exercises explicit reopening with a freshly captured
association and still rejects old-session evidence; production continuity checks
are unchanged.

`test-projection-create-process.py` uses the public Runtime from separate children.
Its macOS cases are normal creation, exit after verified installation before
callback, a newer retained intention, and a foreign destination occupant. Every
retry independently inspects exact bytes and all projection-private rows and
preserves the frozen input. The Linux companion requires explicit unsupported
creation-date capability and an absent destination. Native stage/intermediate
process exits retain their separately qualified C campaign; these public cases
connect surviving SQL state to the real physical consumer.

Compiler probes add eight ordinary/same-module root cases and two actual-source
ownership probes, yielding 160 root checks; private issuer checks total 88.
The new receipt is immutable, constructor-restricted and bound to its exact
creation attempt. Native stage copying and off-executor transfer must fail at
the marked line. Added mutations challenge final history applicability, live-note
admission and receipt-attempt checks; the affected reader controls remain included.

Local debug and optimized witnesses: 12 focused tests and four process schedules
passed; 160 root and 88 private compiler probes passed. All six selected runtime
mutations failed at their designated assertions in both configurations. Native O0/O2, static
analysis, ASan/UBSan, seven native controls and five process schedules per
configuration passed again after adding the installed fingerprint to the C result.
Linux debug and optimized configurations pass all eight applicable functions on disk-backed ext4,
including the original failing case and all six kind/budget combinations.
Their fresh-process companions preserve frozen bytes and return the exact
unsupported capability without creating a file. The optimized build completed
in 855.89 seconds; the selected tests completed in 0.264 seconds. The manifest's
existing linker warning remains separate from the production link, which retains
lld, RELRO and immediate binding. The process companion reuses that built binary.

Intel macOS 14.8.9 and 11.7.11 each passed all four public creation-process
schedules, including retained private-state inspection after the missing callback.
The common optimized binary SHA-256 is
`da99083fc22d5541fb14c056125efb849c9c8ed0d5d932224fbc32a9c899ea89`.
macOS 11 retains the documented compiler workaround and separately supplied
`libswift_Concurrency.dylib`. Its first launch failed before executing storage
because the system Python launcher stripped the inherited DYLD path; setting
that path inside Python for the child produced the passing campaign. This is
qualification of that explicit runtime configuration, not final app packaging.

Logs: `/tmp/nv-p62-create-swift-{debug,release}.log`,
`/tmp/nv-p62-create-{types,private-types}-{debug,release}.log`,
`/tmp/nv-p62-create-process-{debug,release}.log`,
`/tmp/nv-p62-create-swift-{mini,orbb}.log`,
`/tmp/nv-p62-create-bridge-native.log` and
`/tmp/nv-p62-create-mutations-{debug,release}.log`.
The app build passed with the established diagnostic-only deployment override.
The test-target inventory preserves all 83 Runtime sources exactly once across
three targets; the regenerated validation index covers 453 sources and 171 documents.

The Linux disk-backed ext4 run found a genuine read-classification ordering bug:
an unsupported directory's 4096-byte metadata size reached the body-size check
before its kind check, producing `sizeLimit` instead of `kindCollision`. The
existing assertion is retained. The adapter now checks kind and link count before
body size; the test adds a zero-byte budget alongside its original 1024-byte
budget for all three unsupported occupant kinds. Local debug/optimized companions
pass, and restoring the old order fails the new debug/optimized mutation at the
exact kind assertion. The corrected disk-backed ext4 debug suite passes. This is a
classification correction, with every former size, identity and ownership check
preserved.

Reuse: unchanged P6.1 byte fixtures, history validation, freeze/intent SQL-failure
campaigns and TLA+ results retain their original scope. The three creation controls
and two read lifecycle controls use their actual production paths; the additional
check-order control qualifies the later classification correction separately.
Snapshot/model transitions, legacy Objective-C callers, and UI behavior are unchanged.
Physical power loss, additional claimed volumes/providers, completed projection
settlement and conditional replacement/removal remain independent gates.

## Volume precision qualification

`test-projection-create-process.py --filesystem APFSX` (also `APFS`, `HFS+`,
`HFSX`, `ExFAT`) places only the note roots on a disposable disk image. Private
SQL remains on the host volume. Each image is detached after the run and retained
for inspection. The runner verifies the actual filesystem and case behavior;
ExFAT uses the ordinary ownership-disabled removable-volume configuration.
The original four process schedules retain every assertion. A fifth case seeds
fractional logical dates in actual initial history and independently checks the
physical receipt, filesystem dates, exact bytes and surviving private owners.

`--native-probe /path/to/O2-valid-create` additionally runs the already-built
native companion from `test-projection-files-c.py`, preserving its full scenario
set and assertions. Its initial 31-case version exposed HFS+/HFSX's timestamp
limitation while all four whole-second public companions passed. The failed
stage retained `desired`, exact encoding/tags and mode 0640; the requested
mtime `1700000003.234567890` was stored as `1700000003.000000000`, and no
destination was installed. This matches Apple's documented
[HFS+/APFS precision](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/VolumeFormatComparison/VolumeFormatComparison.html).

The user approved filesystem-rounded dates during preparation, followed by
exact verification of that representation at installation. Production now
queries the held same-volume stage once, retains one private precision flag,
and recognizes HFS+/HFSX's whole-second representation. Other adapters retain
their existing nanosecond checks; arbitrary rounding/tolerances remain rejected.
Both sides of exact readback check dates, and final body/attribute/date readback
runs after synchronization. This moves the existing post-install read to the
final boundary, without adding another full body pass. It also prevents a
coarse change timestamp alone from hiding a late metadata edit.

Five added native cases bring the campaign to 36: altered staged modification
date, altered staged creation date, altered final modification date, altered
final creation date, and replacement of the final name at the last boundary.
The new date-check mutation must fail the intended preparation assertion.
The final-name mutation now has its own late namespace witness, independently
of metadata timestamps. Linux retains explicit unsupported creation-date cases.
The process fixture initially attempted to change creation time through an edit;
existing history validation correctly rejected it. The corrected fixture seeds
those dates at creation, preserving that validation rule.

Local native O0/O2, static analysis, ASan/UBSan, eight native negative controls
and both five-schedule process campaigns pass. Local Swift debug and optimized
12-function suites pass. HFS+ and HFSX debug each pass all five public process
cases and all 36 native cases. Optimized APFSX and HFS+ runs each pass all five
public cases, all 36 native cases and all five native interrupted-process cases.
Optimized HFSX passes the five public and five interrupted-process cases, reusing
the unchanged 36-case binary already exercised on that volume. `--native-crash-probe`
runs that previously built interrupted-process client on the same mounted volume.

Intel macOS 14.8.9 passes all five public cases on APFS and HFS+; macOS 11.7.11
passes them on APFS. Both use the same optimized binary, SHA-256
`f4552803152f96d82850aeb0b2f47e2142f971be8cc96c2596e8a7010319b967`.
The established macOS 11 compiler/runtime workaround remains a distribution
qualification caveat. Linux ext4 passes the updated 36 native cases, six native
creation mutations and five interrupted-process cases at O0/O2 with strict
diagnostics, static analysis and ASan/UBSan. Earlier Linux Swift debug/optimized
and unsupported-creation results remain scoped to their unchanged API boundary;
the changed native code receives this separate Linux qualification.

ExFAT remains an explicit failing gate: its first public case returned
`uncertain / changed`, left the final name absent and preserved all frozen/private
rows. Independent inspection found the retained prepared file presented mode
0700 after requesting 0600. Its fixed permission presentation needs a separately
qualified contract; no permission check, exclusive-create requirement or assertion
was relaxed. The failed image and exact result remain available. Initial image
format/mount setup failures were fixture failures, not storage API evidence.

Logs: `/tmp/nv-p62-rounded-dates-{native-create,native-crash,swift-debug,swift-release}.log`,
`/tmp/nv-p62-rounded-dates-hfs-debug.log`,
`/tmp/nv-p62-hfs-timestamp-observation.log`,
`/tmp/nv-p62-create-volume-exfat.log`, and
`/tmp/nv-p62-exfat-stage-observation.log`.
Additional logs: `/tmp/nv-p62-rounded-dates-{hfsx-debug,hfs-release,apfsx-release,hfsx-release,mini,orbb,native-linux}.log`.
The app build passes with the established diagnostic-only deployment override
(`/tmp/nv-p62-rounded-dates-app-build.log`).
The unchanged Swift evidence constructors, ownership types, model transitions
and P6.1 record encodings retain their prior compiler/model/fixture qualification.
The additional state is one operation-local native precision flag, with no new
persisted field or public API. Native, process and production build checks qualify
the changed consumers rather than rerunning unrelated history campaigns.

## Native replacement qualification in progress

`tests/ProjectionFilesReplaceProbe.m` calls the actual `NVAppleReplaceProjection`
adapter and native stage/replacement consumers. Its 18 scenarios include ordinary
and empty outputs, removal of a stale advisory stamp, changed preflight target,
occupied backup candidate, a target replacement after preflight, root movement
and replacement, final target/metadata interference, changed/renamed backups,
wrong source revision and stage kind, corrupted preparation, metadata-copy failure,
errors before/after the Foundation effect and cancelled coordination. Independent
descriptor reads inspect current/displaced bytes and preserved permissions/xattrs.
The harness counts actual replacement calls, including zero-call refusal cases.

The first production-primitive run rejected an installed permission mismatch:
default metadata handling changed a verified mode-0640 stage to 0600. LLDB
confirmed that `UsingNewMetadataOnly` retained 0640 at the same verification
boundary. The alternate-option candidate passed the initial 18 cases. A separate
generated probe normalized accessor URLs to absolute form while keeping the
default option; it still failed the unchanged installed-output assertion.
Logs: `/tmp/nv-p62-native-replace-initial.log`,
`/tmp/nv-p62-replacement-new-metadata-debugger4.log`,
`/tmp/nv-p62-native-replace-new.log`, `/tmp/nv-p62-absolute-metadata.log`.
This is a bounded observation of the API usage being tested, not a claim that
Foundation violated its documented contract.

`python3 tools/test-projection-files-c.py --only replace` is the focused
qualification entry point: O0/O2, strict diagnostics, ASan/UBSan, static analysis,
valid companions and six isolated controls. The controls challenge source
preflight, occupied backup protection, comparison of the actual displaced bytes,
final backup-name checking, ambiguous API failure and the directory-reference
anchor. A missing private-header include in the first generated-control build
was a harness error; it is not counted as a successfully detected mutation.
Completed results and remaining gaps are recorded below as qualification proceeds.

The shared post-install refactor passes the existing native read/create/crash
campaign (`/tmp/nv-p62-replacement-creation-regression.log`), retaining all eight
existing controls. Debug public Swift consumers pass six creation and six reader
functions (`/tmp/nv-p62-replacement-swift-debug.log` and
`/tmp/nv-p62-replacement-swift-read-debug.log`). The initial debug filter selected
only creation, so the reader functions were run separately using that same build.
The expanded native campaign adds five ordinary abrupt-exit boundaries and three
late-target boundaries. A separate inspector process checks the surviving named
files and their exact bytes, permissions and unrelated xattr. Both O0 and O2 pass
the 18 scenarios, concurrent reader, eight abrupt-exit schedules and all six
controls on local APFS and APFSX/HFS+/HFSX images:
`/tmp/nv-p62-replacement-lifecycle-volumes2.log`. The same native campaign passes
on the macOS 14 Intel Mini and macOS 11 Intel VM:
`/tmp/nv-p62-replacement-lifecycle-mini.log` and
`/tmp/nv-p62-replacement-lifecycle-orbb.log`. These process checks establish
filesystem preservation; they do not yet exercise SQL-backed ownership of a
displaced artifact after restart.

The volume harness compares resolved mount paths because `hdiutil` may return
`/private/var` for a requested `/var` path, while retaining its filesystem and
case-sensitivity assertions. Foundation coordination requires the native probe
to run outside the tool sandbox; a sandbox-denied accessor is not an API result.
An initial fresh-process inspector used an unavailable Python xattr wrapper;
the passing campaign reads xattrs directly through Darwin's descriptor API.

The Swift replacement-input tests validate both history bindings and freeze exact
old/new bytes, including privately retained UTF-16 output. They challenge changed
ownership, wrong stores, renames, deletion, changed observations and restart while
newer intended work remains. Debug and optimized runs pass all 16 selected test
functions (replacement inputs plus existing creation/read regression functions):
`/tmp/nv-p62-replacement-input-debug2.log` and
`/tmp/nv-p62-replacement-input-release.log`. The fixture seeds a passive prior
file observation; these tests qualify preparation, not a physical replacement
receipt. The original source-history mutation survived because reading the new
envelope also checked the removed old occurrence. The strengthened fixture
separately damages the old sealed bytes with intact occurrence indexes. Its
UTF-16 case now detects the omitted source validation at the designated assertion,
while both valid encoding companions pass. All four then-current targeted controls
passed in `/tmp/nv-p62-replacement-input-mutations-debug2.log`. The corrected
compiler inventories also passed: 90 private and 166 root probes, in
`/tmp/nv-p62-replacement-input-private-types-debug2.log` and
`/tmp/nv-p62-replacement-input-root-types-debug2.log`. Those results precede the
reservation additions below and are reused only for their unchanged boundaries.

### Private reservation qualification in progress

`ProjectionReplacementAttemptV1` and the internal committing issuer add a durable
candidate location before the future physical effect. The independent Python
fixture pins its exact bytes; Swift checks both encoding directions, every
truncation, trailing bytes, scope/profile restrictions, same-name source and
oversized framing. Runtime companions exercise SQL readback, duplicate refusal,
repeated transaction aborts, newer intended contents, logical Delete, reopen and
complete private-store copy. Damaged codec/payload/key/frozen owner must receive
the precise unsupported or integrity outcome during verification and reopen.
The final nominal-ID 21-function debug run passed in
`/tmp/nv-p62-replacement-reservation-debug3.log`. All 94 ordinary/same-module
private-boundary probes passed in
`/tmp/nv-p62-replacement-reservation-private-types-debug2.log`. The six targeted
controls passed in `/tmp/nv-p62-replacement-reservation-mutations-debug.log`;
that isolated package predates the nominal-ID refinement and qualifies its
unchanged SQL/ownership guards. An optimized invocation outside the repository
runner selected another SQLCipher installation and was correctly rejected by
the required cipher check; it supplies no runtime qualification. The rerun uses
the pinned dependency through `make -C tests run-swift-storage`.
The pinned optimized rerun passed all 21 selected functions in
`/tmp/nv-p62-replacement-reservation-release3.log`. Passive
root/source observations are seeded here; these are database/record tests, not
qualification of a physical replacement, provider identity or fresh-child
reconciliation of displaced contents.

The type boundary gives the attempt its own nominal ID and keeps the live
`ReservedProjectionReplacement` constructor confined to its committing file.
The physical consumer must additionally provide fresh rooted evidence. New
controls challenge omitted SQL insertion and loss of the frozen-owner check.
No previous mutation cross-product or physical test case is removed.

### Internal physical replacement integration

`ProjectionFileReplacementTests.swift` uses actual rooted creation to establish
the source, a test-seeded passive accepted record, ordinary durable edits, frozen
replacement input, SQL reservation and the production Foundation replacement.
The accepted-record seed is explicit: P6.4 settlement is not being claimed.

| Test | Independent assertions |
| --- | --- |
| `projectionReplacementInstallsAndRetainsDisplacedSource` | UTF-8/UTF-16 target B and backup A bytes, permissions, required encoding/tags/dates, optional metadata result, exact reservation, unchanged frozen owner and fresh-session reopen; a different input cannot consume its receipt |
| `projectionReplacementBurnsOccupiedCandidates` | Two observed occupied candidates remain untouched and use different UUIDs even with the same captured input; a third attempt installs while preserving both occupants |
| `projectionReplacementReservationFailurePreventsEffect` | Two failed SQL inserts precede staging; original bytes and pending owners survive; successful retry really installs |
| `projectionReplacementPreservesInterferingFiles` | Changed preflight target, changed installed target, changed backup and insufficient backup-read budget preserve every surviving stream and distinguish known no-effect from uncertainty |
| `projectionReplacementFencesHeldCompletion` | Deterministic post-effect hold admits newer C, Delete, cancellation or root close; both files remain while only applicable completion is issued and pending state remains exact |
| `projectionReplacementFollowsMovedRoot` | Replacement follows the held directory after it moves; an occupant at its former pathname remains untouched |
| `projectionReplacementRejectsForeignEvidenceBeforeEffect` | Foreign root snapshot and store cannot reserve or modify either source; correct-context companion installs |
| `projectionReplacementFailedRetirementRetainsCandidate` | Failed no-effect SQL retirement preserves the candidate and occupied bytes through reopen; outstanding work prevents another uninspected attempt |

The expanded debug run passed all 29 selected functions in
`/tmp/nv-p62-replacement-bridge-debug2.log`. All 98 private construction/role probes
passed in `/tmp/nv-p62-replacement-bridge-private-types.log`, including ordinary
visibility and same-module attempts to forge replacement receipts or no-effect
retirement evidence. The optimized run passed the same 29 functions in
`/tmp/nv-p62-replacement-bridge-release.log`. All four selected debug controls
passed at their designated assertions in
`/tmp/nv-p62-replacement-bridge-mutations2.log`: repeated candidate UUID, omitted
final history check, retiring uncertain work, and the existing creation-receipt
context control. The latter's match was made creation-specific after the new
replacement consumer introduced the same spelling; its original asserted
behavior is unchanged. The application build passed in
`/tmp/nv-p62-replacement-bridge-app-build.log` with the established deployment
diagnostic override. Index self-tests, regeneration and completeness checks pass.
All 166 root probes passed in `/tmp/nv-p62-replacement-bridge-root-types.log`,
including the actual-file unique stage ownership and executor confinement checks.
The prior bridge's Ubuntu debug run passed all 17 applicable functions in
`/tmp/nv-p62-replacement-bridge-linux.log`; Darwin-only physical replacement
tests remain outside that result. Its optimized private probes also all passed
in `/tmp/nv-p62-replacement-bridge-private-types-release.log`. These results
precede the recovery-inspection additions below. No cleanup or
reinstallation is inferred from a persisted record.

The public physical replacement consumer, displaced-artifact cleanup/accounting,
`NSFileOriginalItemLocationKey` fallback inspection, provider identity,
remaining metadata/volume cases, original removal and
rename/source accounting remain required gates. No legacy/UI path is changed.

### Fresh replacement recovery inspection — qualification in progress

The recovery input issuer checks the retained source/output history and frozen
ownership after reopening, including after logical Delete. The root consumer
observes the current file and backup candidate independently and rechecks the
issuing store/root before publishing. It preserves all physical/private inputs.
Tests challenge intact/changed/missing backups, a symbolic link, missing current
file, read-size bounds, wrong root/store/session and candidate loss while reading.
Later edit/Delete companions still permit inspection of the retained material.

`projectionReplacementFreshProcessRecovery` reuses the already-built Swift test
bundle through its toolchain runner. The exec'ed participant receives only normal
selection/unlock inputs and storage locations, never an expected-body oracle or
acknowledgment log. Abrupt exits after candidate commit, stage preparation,
namespace effect and receipt delivery are paired with a clean completion and
two independent recovery launches. Further cases crash during recovery, retain
an unrelated occupied candidate before the accessor, and add newer edit/Delete
history before inspecting. Parent-side disk reads, exact private observations,
current values and acceptance sequence are the independent assertions. These
are process-termination schedules, not persistence-loss or power-loss evidence.

The first complete debug and optimized runs passed all 35 selected functions in
`/tmp/nv-p62-replacement-recovery-debug5.log` and
`/tmp/nv-p62-replacement-recovery-release.log`, including all nine child-process
schedules and the historical-byte corruption companion. All 102 private
construction/visibility probes passed in
`/tmp/nv-p62-replacement-recovery-types-debug2.log` and
`/tmp/nv-p62-replacement-recovery-types-release.log`. The four selected controls
passed at their intended assertions in
`/tmp/nv-p62-replacement-recovery-mutations-debug3.log`: omitted historical-source
verification, final candidate ownership, root association, and the existing
replacement-input source-history control. Source needles for the unchanged
read/cancellation controls were narrowed to their original consumer after the
inspector introduced similar code; their behaviors and cross-product remain.

Ubuntu's affected debug build passed all 17 applicable functions in
`/tmp/nv-p62-replacement-recovery-linux.log`; the physical replacement/recovery
matrix is Darwin-only. The application build also passed in
`/tmp/nv-p62-replacement-recovery-app-build.log` with the established deployment
diagnostic override. The Intel Mini is reachable and reports macOS 14.8.9, but
its installed Swift 6.0.3 cannot compile this Swift 6.4 package. Earlier native
Intel results remain scoped to their unchanged C/Foundation consumers.

One parallel top-level campaign reported three `.ownership(35)` failures during
reopening (`/tmp/nv-p62-replacement-recovery-debug3.log`). The prescribed serial
schedule passes while every test retains its own controlled races. The exact
cause of the parallel-only contention remains a diagnostic follow-up; no
ownership assertion was relaxed and no production retry was introduced.

A subsequent refinement explicitly binds each inspection consumer to the
caller-supplied recovery input. A same-store/root/frozen-transition companion
changes only the committed candidate and requires the older inspection to be
rejected as wrong context. Its final runs are recorded below as they complete.

Review of the private-copy path also caught a concrete error in the first
inspector draft: it compared the historical attempt's store scope with the
recovering store identity. Verified copies retain their original capture scope
through `repair-source/`. The temporary recovery input now carries its issuing
store independently, and the existing captured-scope reader still checks the
record. `projectionReplacementRecoverySurvivesPrivateCopy` makes a real consistent
private copy, confirms its different store identity, closes both source and copy,
reopens the copy and inspects the original root. It requires unchanged candidate,
source/output bytes, note values and physical files, while rejecting the source
session's old input. The `p62-recovery-captured-store` control reinstates the
incorrect scope comparison and must fail that issuance assertion.

The final debug and optimized runs pass all **37** selected functions in
`/tmp/nv-p62-replacement-recovery-debug7.log` and
`/tmp/nv-p62-replacement-recovery-release3.log`. The exact-candidate control is
caught at its designated assertion in
`/tmp/nv-p62-replacement-recovery-context-mutation.log`; the captured-store
regression is caught in `/tmp/nv-p62-replacement-recovery-copy-mutation.log`.
Together with the preceding four controls, these are six isolated mutation
qualifications with passing companions. The final debug private-boundary run
passes all 102 probes in `/tmp/nv-p62-replacement-recovery-types-debug3.log`.
No persistent format, table, sidecar or long-lived cache was added for recovery
inspection. Temporary evidence carries its live issuing context and exact
captured attempt, while prior private scopes remain passive, validated history.
The final Linux debug build and its 17 applicable functions also pass in
`/tmp/nv-p62-replacement-recovery-linux2.log`.
The final optimized compiler campaign passes all 102 probes in
`/tmp/nv-p62-replacement-recovery-types-release2.log`. Index regeneration,
completeness checks and mutation-driver setup self-tests pass. The existing
TLA+ physical-observation and post-restart permission conditions remain intact;
these tests qualify their concrete read boundary without a model transition
change or a new TLC proof claim.

### Original local Delete permission

`ProjectionDeletionInputTests.swift` exercises the internal store/root issuers
and consumers through actual SQLCipher acceptance and coherent file reads. The
fixture seeds P6.4's passive accepted relationship from a real file and checked
history; physical settlement and the application classifier remain later gates.
The eight functions cover 19 argument cases:

| Witness | Independently observed requirement |
| --- | --- |
| `projectionDeletionRequiresOriginalLocalBarrier` | UTF-8/native UTF-16 and single/multi-note Deletes; exact command/action/object, retry identity, retained source ownership and unchanged physical bytes |
| `projectionDeletionRequiresCheckedOriginalSource` | A Put cannot obtain Delete evidence; unfinished frozen output retains its source obligation; corrupt source history blocks issuance |
| `projectionDeletionRejectsForeignStore` | Same-type inputs and receipts remain bound to their actual store/session/connection |
| `projectionDeletionRejectsReceiptForAnotherCommand` | An edit receipt with the same covered birth/generation is rejected as wrong context; the exact Delete receipt succeeds |
| `projectionDeletionRequiresAcceptedPhysicalIdentity` | Changed body, equal-body new physical item and another root cannot supply the accepted source capture |
| `projectionDeletionFencesPreAdmissionCapture` | A model change before or during root matching prevents issuance of the pre-admission source token |
| `projectionDeletionRejectsChangedLiveOwner` | Changed association/source generation, closed/reopened store and invalidated root fence the actual consumers; reopening leaves the logical Delete and file bytes intact |
| `projectionDeletionAcceptsRepackagedCommandBeforeLocalEnvelope` | A real received equivalent envelope accepts first while local persistence is held after sealing; the local receipt still names its own envelope, both exact envelopes survive, and the canonical action occurrence can belong to the earlier envelope |

The last case found an overly restrictive initial check equating the action's
first stored occurrence with the local receipt's envelope/sequence. The final
issuer uses `CheckedEnvelopeRecords` to verify the exact receipt envelope and
complete indexed membership, then independently verifies the captured action
and its earlier-or-equal accepted occurrence. The ordinary persistence path
carries an optional qualification callback alongside its existing seal result;
the test adds no database round trip or production scheduling resource.

Run the final focused suite with the pinned dependency runner:

```sh
make -C tests run-swift-storage \
  "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'projectionDeletion|projectionReplacement|projectionCreation|projectionFileRead'"
```

Repeat with `-c release`. All **45 selected functions** pass in
`/tmp/nv-p62-deletion-input-debug4.log` and
`/tmp/nv-p62-deletion-input-release2.log` against the final frozen sources. Both
builds retain strict concurrency, strict memory safety and warnings-as-errors.
Earlier builds correctly rejected test files edited during compilation; those
incomplete builds supply no qualification result.

The six `p62-delete-*` controls in `tools/test-storage-runtime-mutations.py`
all pass their companions and fail at the designated assertion in
`/tmp/nv-p62-deletion-input-mutations-final.log`. They challenge the exact local
command receipt, final pre-admission fence, physical identity, Delete eligibility,
historical source validation and support for earlier equivalent occurrences.
The receipt-context control checks the precise wrong-context outcome while the
independent accepted-membership check remains present. The first source-history
control inadvertently called a second API that still verified UTF-8 history;
its survival was a mutation-construction error. The corrected control bypasses
history using current rows and is caught at the intended assertion. The initial
report and sources remain preserved separately from the final campaign.

The three new immutable evidence types have ordinary-client visibility and
same-module file-private-constructor challenges in
`tools/test-storage-private-types.py`. All **108** checks pass against debug and
optimized modules (`/tmp/nv-p62-deletion-private-types-debug.log` and
`/tmp/nv-p62-deletion-private-types-release.log`). The earlier debug declaration
checks are reused for their unchanged issuers; the final optimized campaign
checks the current sources. The saved-action receipt probe challenges its actual
capture-bound constructor. The full Runtime suite passes its existing **135**
checks plus its seven separate locality checks in
`/tmp/nv-p62-deletion-runtime-types-debug3.log` and
`/tmp/nv-p62-deletion-runtime-types-release.log`. Earlier attempts hit a
60-second watchdog under concurrent build load; the final runs keep that same
watchdog and every diagnostic assertion.

Ubuntu arm64 with Swift 6.4 passes all eight new functions/19 cases in
`/tmp/nv-p62-deletion-input-linux-final.log`. The first two-job build was killed
by the VM's OOM handler. The successful final-source retry uses one compiler job
with identical compiler settings and test selection; no contract, assertion or
source check was relaxed, and no files were deleted. This is debug Runtime
qualification on Linux; the optimized Runtime and new constructor checks above
were run on the local arm64 Mac. The unchanged native source primitive retains
its separate macOS 11/14 and filesystem matrix below. The app target also builds
with its established deployment diagnostic override
(`/tmp/nv-p62-deletion-app-build-final.log`).

That run qualifies the live permission boundary, with no namespace effects;
the connected original-source increment below adds the reservation and move.
Recovery accounting and physical settlement remain required before application
integration. Add the coupled cases
for failed materialization and corruption of the just-accepted Delete envelope
at that boundary. Include delete/recreate attempts against locally scoped file
identity while descriptors are closed; qualify the required identity lifetime
rather than assuming an observation remains a permanent incarnation token.
Before wiring large multi-note removal, reuse one command-level capture/action
validation and receipt-envelope read across its per-file operations. The current
internal per-file factory repeats those complete-group checks; calling it once
per affected file can create quadratic batch work. Keep each file's own fresh
association/snapshot checks and benchmark increasing batch sizes when introducing
that shared short-lived evidence. These tests qualify permission semantics,
not a large-batch work bound.
The initial native source-quarantine platform matrix below remains recorded
evidence for that earlier candidate; the strengthened original-snapshot matrix
below qualifies its current boundary. No TLA+ transition/assertion or public
storage API changes here.

### Connected original-source reservation, move and recovery

The current consumer uses the real SQLCipher acceptance path, required-private
record, operation-local Foundation coordinator and native move. The fixture still
seeds the P6.4 accepted relationship explicitly; these tests do not claim that
the classifier or completed source settlement is implemented.

| Witness | Independently observed requirement |
| --- | --- |
| `projectionSourceAttemptIndependentLayout` | Independently constructed exact bytes, every truncation, trailing bytes, version/profile/scope/length and nominal-ID boundaries |
| `projectionSourceCapturesOriginalAndRecoversAfterReopen` | UTF-8/UTF-16 originals move with exact bytes/metadata; record and owners survive normal reopening; old grant expires |
| `projectionSourceReservationPersistsBeforePhysicalEntry` | The actual exact SQL row exists before any file effect |
| `projectionSourceReservationFailurePreventsMove` | Repeated SQL write failures stop before physical admission; source/owners survive and a later valid companion succeeds |
| `projectionSourceBurnsOccupiedRecoveryNames` | Each occupied candidate is preserved and retired; a later attempt uses a distinct UUIDv4 |
| `projectionSourcePreservesChangedOriginal` | Changed body, equal-body new physical item and changed permissions remain at the source and cannot qualify as the old file |
| `projectionSourceKeepsChangedArtifactForRecovery` | A late artifact replacement retains the record and both original/new streams |
| `projectionSourceKeepsNewSourceOccupant` | Capturing the old source preserves a newly created original-name occupant |
| `projectionSourceFencesHeldCompletion` | Changed association, record generation or root invalidates completion while retaining artifacts |
| `projectionSourceRecoverySurvivesPrivateCopy` | Actual verified private copy retains original scope/bytes; fresh evidence binds to the replacement owner |
| `projectionSourceRecoveryBindsExactInputAndFinalOwner` | Two real captures in the same store challenge exact-input binding independently of foreign-store rejection; wrong root and changed final private owner fail at the actual consumer |
| `projectionSourceValidatesRequiredRecoveryRecord` | Codec, payload, key, source owner and accepted Delete membership have precise unsupported/integrity outcomes |
| `projectionSourceFreshProcessRecovery` | Exec'ed crash cuts before reservation, after its commit, after move and after return; a second crash during inspection; two normal fresh inspections agree on exact surviving bytes/record/current state |

The fresh child receives only selection/unlock/repository inputs. Its expected
notes, file bodies and cut-specific presence assertions stay in the independent
parent. Child discovery, exit status and successful single-test completion are
required; the disabled child participant is separately exercised by all crash
schedules. Termination and SQL trigger failures remain distinct fault classes.

Seven `p62-source-*` controls separately challenge the real reservation write,
final owner fence, uncertain-record retention, source owner, captured-vs-live store
scope, exact inspection input and final recovery check. All existing mutation
controls and the original-Delete permission checks remain present. Compiler
probes challenge ordinary visibility and same-module file-private construction
for the six new evidence types, plus source/replacement attempt-ID separation.

The native matrix now has **29 cases, eight controls and four crash cuts** per
optimization. In addition to the initial cases below, it independently changes
metadata/mode while presenting equal stat words, validates borrowed-attribute
framing and unlinks/recreates the source in the actual rename gap. The latter
requires the held inode descriptor and distinct recreated identity. Both direct
and real Foundation-coordinated builds run the complete matrix; the source pin
did not yet qualify the longer capture-to-entry identity lifetime. The later
[live descriptor increment](#live-original-source-descriptor-lifetime) supplies
that continuous pin for the original-Delete consumer.
The coordinated flavor also checks the exact attempted/successful move-notification
URL pairs for every scenario. Two extra controls omit outbound/restoration
completion independently. An overwriting-rename mutation uses a counted fault
helper so notification bookkeeping cannot conceal its designated preservation
assertion. The initial helper lacked a forward declaration; that compile/setup
failure is retained separately and supplies no mutation qualification.

The first exact-input mutation survived because another check rejected its
foreign-store fixture. The strengthened witness uses two valid candidates from
one live store/root, so removing only the input comparison must now reach the
designated wrong-context assertion. Its initial report/source archive remain
preserved; later qualification reruns every selected control with a fresh
baseline and exact source-manifest verification before compiler-artifact reuse.

The final focused debug suite passes **59 selected tests**, including its
separately invoked fresh child participants, in
`/tmp/nv-p62-source-integrated-debug-final.log`. Earlier debug/optimized suites also
passed before the notification refinement; their results remain scoped evidence,
not qualification of the final bridge. Both module configurations pass all
**122 private-boundary checks** (58 ordinary-client and 64 same-module), including
the new evidence constructors and nominal attempt roles:
`/tmp/nv-p62-source-integrated-private-types-debug.log` and
`/tmp/nv-p62-source-integrated-private-types-release.log`. These declarations and
access boundaries are unchanged by the native notification correction.

The final **29-case/eight-control/four-cut** native campaign passes at O0/O2
with ASan/UBSan and clean static analysis. Its coordinated flavor also passes
the two extra notification controls, retaining every original designated
assertion, on:

| Platform / filesystem | Final qualification log |
| --- | --- |
| Local arm64 macOS, APFS + HFS+ + HFSX | `/tmp/nv-p62-source-notices-final-native.log` |
| Intel macOS 14.8.9, APFS | `/tmp/nv-p62-source-notices-mini-final.log` |
| Intel macOS 11.7.11, APFS | `/tmp/nv-p62-source-notices-orbb-final.log` |
| Ubuntu arm64, tmpfs + ext4 (direct primitive) | `/tmp/nv-p62-source-integrated-linux-final.log` |

The app target builds with the approved deployment diagnostic override in
`/tmp/nv-p62-source-integrated-app-build.log`. Its legacy/UI sources are unchanged
by this storage-library increment. The validation-index self-test and completeness
check pass with 458 sources in `/tmp/nv-p62-source-integrated-index-final.log`.
All seven final `p62-source-*` mutations pass their companion and fail at the
designated runtime assertion in `/tmp/nv-p62-source-integrated-mutations-final.log`
(report directory `nv-runtime-mutations-2ke6lrne`). The exact-input control now
fails independently of the store/session checks. Before reusing the initial
campaign's compiler artifacts, its source package was archived at
`/tmp/nv-p62-source-initial-mutation-package.tar` and its initial report retained
as `nv-runtime-mutations-5r9rbbjq/source-initial-results.json`. The new driver
requires an exact current source manifest and reruns the baseline and every
selected control; no previous test success is substituted for this rerun.
Ubuntu arm64/Swift 6.4 passes all **22 selected source/deletion tests** after the
test-seam correction below, including child-process recovery, in
`/tmp/nv-p62-source-integrated-linux-final.log`. This final run uses all current
portable sources, one compiler job and the same strict settings/pinned cipher;
the preexisting Linux RWX linker warning remains reported rather than suppressed.
The final optimized suite passes the same **59 selected tests** with the async
hook in `/tmp/nv-p62-source-async-hook-release.log`. The final debug run and both
affected controls above use that same hook and retain the 20-second interference
deadline. No production compiler, access-control or safety check was relaxed.
Physical power-loss behavior remains unqualified.

The first Ubuntu Swift run exposed a blocking test synchronizer: its recovery
hook waited synchronously for async database interference and hit the 20-second
watchdog. The internal hook now suspends asynchronously; the test races its
database mutation against the same 20-second deadline using structured tasks.
The root turn remains reserved, every final owner/input assertion stays present,
and the two affected mutation controls rerun. The physical C campaign is unchanged
by this test-seam correction. The concurrency guidance favors this direct
suspension over adding threads, unchecked isolation or relaxed assertions.
Both affected controls pass their baseline and fail at the intended assertions in
`/tmp/nv-p62-source-async-hook-mutations.log` (`nv-runtime-mutations-mvnzbhaz`).
The earlier completed seven-control report and source snapshot remain preserved.

### Accepted-to-captured metadata commitment

The current `0x50524601` physical record now binds its nine words to the complete
raw metadata using the domain-separated 32-byte commitment specified in the
contract. Both original-Delete capture and replacement check that complete
accepted record before reservation/effect. The raw source-attempt observation
layout stays unchanged; no table, sidecar or long-lived validation state is added.
This directly revises the current unreleased layout without an old-format branch.

`projectionSourceRejectsAcceptedMetadataChanges` changes actual permissions,
encoding, OpenMeta tags, present-empty tags, Finder tags, stamp and modification
time. The creation-date companion runs on Darwin. For non-stat metadata the
fixture retains the prior commitment but deliberately aligns the stat prefix
with the new coherent snapshot, isolating the coarse-clock schedule. Capture
must reject before a source reservation; unchanged file bytes and the current
note set are independently checked. A fresh matching accepted-observation
companion succeeds. The accepted-state write is an explicit P6.4 fixture seam,
not qualification of its not-yet-implemented receipt producer.

`projectionReplacementRejectsAcceptedMetadataChanges` applies the same seven
raw-metadata cases to a real history/frozen-output/created-file fixture. The
wrong-context outcome must precede reservation and physical replacement; the
matching-observation companion must actually install B and retain A.

`projectionSourcePhysicalRecordIndependentOracle` compares all 104 bytes with
Python `stat`, `struct.pack` and `hashlib`. It independently obtains the nine
physical words from the real file and encodes the snapshot's public metadata
fields, including present-empty/raw binary attributes. Existing native witnesses
independently qualify the reader supplying those fields. This oracle qualifies
the concrete encoding/hash, not permanent physical identity.

The three new mutation controls omit the deletion/replacement metadata comparison
while preserving stat-prefix checks, or omit metadata from the hash. Each must
fail its named assertion with passing companions. The prior physical-identity
control reruns unchanged. Source-syscall/Foundation preservation, native sanitizer
campaigns, constructor boundaries, canonical history and general private record
framing are unchanged and retain their completed qualification. The live snapshot
and generation guards remain issuer-restricted.

The complete focused debug suite passes **63 selected tests** in
`/tmp/nv-p62-metadata-debug.log`; the optimized suite passes the same 63 in
`/tmp/nv-p62-metadata-release.log`. Ubuntu arm64/Swift 6.4 passes its **24 selected
source/deletion tests**, including the independent oracle, unchanged recovery
children and applicable equal-stat cases, in `/tmp/nv-p62-metadata-linux.log`.
Darwin-specific replacement/creation-date cases receive their Mac qualification
above, not a claimed Linux execution.

All three new controls plus the unchanged `p62-delete-source-identity` control
pass their companions and fail at the designated assertions in
`/tmp/nv-p62-metadata-mutations.log` (report `nv-runtime-mutations-c1mx_idq`).
The reused compiler package passed the exact source-manifest check; its previous
source state remains archived at `/tmp/nv-p62-pre-metadata-mutation-package.tar`.
The unchanged Core/private framing fixture checker passes; the app builds with
the existing approved deployment setting in `/tmp/nv-p62-metadata-app-build.log`.
The index self-test/completeness check covers the updated scenarios and sources.

`ProjectionTransitionSafety` and `ProjectionRecoveryBridge` still abstract exact
file-state/identity checks. SANY parses both in
`/tmp/nv-p62-metadata-model-syntax.log`; their model/configuration and previously
completed exhaustive campaigns are unchanged. These executable witnesses qualify
the newly connected metadata premise, not a new refinement proof or incarnation
guarantee. P6.4 accepted-state publication and complete source accounting remain
separate gates. The following live-descriptor increment closes the original-Delete
capture-to-entry lifetime gap.

### Live original-source descriptor lifetime

`captureProjectionDeletion` now obtains a fresh coordinated coherent read and
retains its exact descriptor through admission, local commit, reservation and
quarantine. Its bytes and complete physical record must still equal the accepted
capture. The C reader transfers the descriptor only after successful final name
and root checks. The quarantine consumer borrows and verifies it; every return
leaves closing responsibility with its caller.

A file-private `Sendable` class owns that single close and is shared by immutable
live capture/retry/result values. No table, private-record field, sidecar or
validation cache is added. Root closure invalidates effect permission while
ordinary ARC release disposes of any still-retained file descriptor. Restart
retains the existing inspection record, not this resource or physical permission.

Three production Swift tests add independent observations:

- `projectionSourceDescriptorFollowsLiveCapture` enumerates `/dev/fd` and uses
  `fstat` against independent device/inode attributes. Exactly one descriptor
  survives the pre-issue suspension, commit, reservation and quarantine; copies
  share it and the final release closes it. Its root-close companion keeps the
  descriptor live while requiring the actual effect consumer to reject the old
  permission.
- `projectionSourceFailedCaptureClosesDescriptor` interrupts issuance by a thrown
  error, cancellation or concurrent committed edit. It checks exact failure,
  descriptor release, unchanged file bytes and absence of a source reservation.
- `projectionSourceCaptureRereadsTheOriginal` changes body, metadata or replaces
  the physical item after the earlier snapshot. The issuer must reject before
  admission/reservation and leave both notes and current file intact.

The native source campaign grows from 29 to **33 cases**, preserving every old
case/control and adding invalid, foreign and closed borrowed descriptors plus
unlink/recreation after capture. It requires caller ownership of the descriptor
after every native outcome. Two new controls close the transferred descriptor
prematurely or omit borrowed-identity comparison; both must fail at the designated
runtime assertion. All eight earlier native controls, including the inode-pin
mutation, remain. The coordinated flavor retains both move-notification controls.

The native reader now runs **15 cases and two controls in each of two ownership
variants**, at O0/O2 with strict diagnostics, clean static analysis and ASan/UBSan.
Injected EMFILE leaves no output/descriptor and preserves the source. This is
resource-failure evidence, not qualification of an unbounded multi-file driver;
large command admission remains a separate resource-budget gate.

The construction suite retains its original 122 checks and adds six: ordinary
and sibling clients cannot name the file-private owner/read types, and sibling
clients cannot access the capture's descriptor accessor or resource field. The
capture constructor probe follows the current lease-bearing initializer.
`p62-source-descriptor-release` must catch an omitted final close;
`p62-delete-capture-fence` reruns its original final-owner challenge.

Entry points (use `--configuration release` for the optimized mutation campaign):

```sh
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'projectionSource|projectionDeletion|projectionReplacement|projectionCreation|projectionFileRead'"
python3 tools/test-projection-files-c.py --only read
python3 tools/test-projection-files-c.py --only source --foundation --filesystems HFS+ HFSX
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-runtime-mutations.py --only p62-source-descriptor-release --only p62-delete-capture-fence
```

The descriptor pin supplies the original-Delete consumer's capture-to-quarantine
identity premise. `ProjectionTransitionSafety` and `ProjectionRecoveryBridge`
continue to abstract identity/freshness checks; no action, safety condition or
configuration changed and no new TLC proof is claimed. Source settlement remains
a P6.4 gate; the following owned-cleanup increment implements its separate
physical boundary. Earlier completed metadata, history,
private-record and epoch-4 qualification is reused only for unchanged behavior.

Qualification for this increment:

| Boundary | Completed evidence |
| --- | --- |
| Actual Swift Runtime, local macOS arm64 | All **66 focused functions** pass debug and optimized, including the existing fresh-process crash/recovery cases: `/tmp/nv-p62-lease-debug.log`, `/tmp/nv-p62-lease-release.log` |
| Compiler boundaries | All **128 checks** pass against debug and optimized modules: `/tmp/nv-p62-lease-types-debug.log`, `/tmp/nv-p62-lease-types-release.log` |
| Runtime mutation qualification | Both controls pass their valid companions and fail their designated assertions in debug and optimized: `/tmp/nv-p62-lease-mutations.log`, `/tmp/nv-p62-lease-mutations-release.log` (reports `nv-runtime-mutations-8j3kyfz4`, `nv-runtime-mutations-iiof80is`). The reused compiler package passes the exact-source manifest check; its prior sources are archived at `/tmp/nv-p62-pre-lease-mutation-package.tar` |
| Native reader, local macOS | Both ownership variants pass all 15 cases and both controls at O0/O2: `/tmp/nv-p62-lease-read.log` |
| Native source, local APFS/HFS+/HFSX | All 33 cases, ten native controls, two additional coordinated controls and four crash cuts per valid flavor/configuration pass: `/tmp/nv-p62-lease-native-final.log`, artifacts `nv-p62-lease-native-final-_0vsch74` |
| Intel macOS 14.8.9 and 11.7.11 | Reader and direct/coordinated source campaigns pass O0/O2, plus unchanged Foundation capability/backup-name witnesses: `/tmp/nv-p62-lease-{read,native}.log` on each host |
| Linux arm64 native, tmpfs/ext4 | Both reader variants and all applicable source cases/controls/crash cuts pass: `/tmp/nv-p62-lease-read.log`, `/tmp/nv-p62-lease-native.log`, `/tmp/nv-p62-lease-native-ext4.log` on Ubuntu |
| Linux arm64 Swift 6.4 | All **27 source/deletion functions** pass debug and optimized: `/tmp/nv-p62-lease-linux.log`, `/tmp/nv-p62-lease-linux-release.log`; Darwin-specific Foundation replacement capability is not claimed from those runs |
| App and independent private framing | Legacy `build.sh` passes with the established deployment diagnostic setting in `/tmp/nv-p62-lease-app-build.log`; the independent private-record fixture checker still passes |

The first local SwiftPM attempts were denied compiler-cache/manifest-sandbox
access by the enclosing tool sandbox. Retrying the same checks outside that
sandbox passed. The first native run passed all direct controls, then its
coordinated companion failed inside the enclosing sandbox. The **identical
binary** passed outside it. The final campaign reuses all 48 exact already-built
ASan/UBSan binaries on fresh fixtures outside that sandbox and reruns every
native/control/crash/volume case, plus all 40 Foundation metadata/reader and 12
reference/race witnesses. No production or assertion change was needed.

The Linux native command needs the installed Swift toolchain's `bin` on PATH
for Clang. Its first missing-compiler setup failure ran no native checks; the
corrected full campaigns above passed. The existing Linux linker RWX warning
remains a separate release qualification item. Native results do not establish
provider ordering or physical power-loss durability, and these Intel results
qualify the native boundary rather than a newly distributed Swift binary.
To keep the disposable Ubuntu disk usable, 118 reproducible native executables
were removed from seven explicitly inventoried older artifact directories
(484,087,112 bytes); all source files, result logs and synthetic collections were
retained. The current qualification's source/fixtures and Swift compiler caches
remain available. This cleanup changes no test discovery or acceptance check.

### Owned source-artifact cleanup

**Invalidated earlier qualification: the public-name candidate failed the required last-check/unlink
schedule.** The earlier passing 22/25-case campaigns below did not test that exact
interval. `LAST_UNLINK_REPLACEMENT` adds a real child writer at the final
destructive syscall boundary (23 direct / 26 coordinated cases). It replaces the
checked recovery leaf, then requires the new contents to survive independently
of the API result. That candidate lost them and reported `REMOVED`.
Its failing `--only cleanup` result was a contract counterexample, not a waiver.
The protected-capture replacement and its expanded qualification are recorded
below. The earlier results remain evidence only for their stated smaller matrix.

The internal production path targets the exact owned recovery artifact
of a still-live original Delete. Its captured descriptor, durable command,
required attempt record, current association and root remain checked throughout.
The original note pathname is observed independently and a new occupant survives.
The source-attempt record and private byte owners remain intact; P6.4 still owns
complete source accounting and private settlement.

`ProjectionFilesCleanupProbe.c` first performs the real retaining read and source
quarantine, then invokes cleanup. Its **22 cases** cover exact/empty artifacts,
body/tag/mode changes with deliberately equalized stat words, absence, directory,
symlink, hard link, wrong/invalid borrowed descriptor, final-name replacement,
EIO before/after actual unlink, ENOSPC, a new artifact, failed final lookup,
directory-sync failure, moved/lost roots, late root invalidation and a new note
pathname occupant. Independent POSIX reads verify every surviving byte stream;
caller ownership of the borrowed descriptor is checked after every outcome.

Both O0/O2 variants use strict conversion/pointer diagnostics, clean Clang static
analysis and ASan/UBSan. The direct and coordinated flavors each kill six
designated mutations: omit full contents comparison, compare body alone while
omitting metadata, omit borrowed-FD
identity, omit final-name verification, omit the final root fence, or misreport
unavailable artifact metadata as absence. Two abrupt-exit cuts per valid flavor
stop after checking or immediately after unlink; Python independently inspects
the files. Each selected volume reuses the same binaries and complete control set.
The coordinated flavor adds three cases (25 total): accessor redirection,
coordinator failure before entry, and an error after the actual deletion. Its
earlier coordinator subclass checked the exact `WritingForDeleting` option before calling
the real implementation. Two adapter-source controls omit that option or accept
the redirected accessor; both must fail their designated runtime assertions.
The unchanged Foundation metadata/reference/backup-name witnesses also run when
`--foundation` is selected.

The production Swift cases are:

- `projectionSourceCleanupRemovesOnlyOwnedArtifact`: two real cleanup/reopen
  companions, with and without a new source occupant; record/accepted-state
  preservation, exact receipt checking, no-effect repeat, and rejection of the
  old capture in a new session.
- `projectionSourceCleanupPreservesChangedArtifact`: changed body/metadata/mode,
  returned original source, directory and hard link. Each preserves its actual
  contents and required record instead of issuing a removal receipt.
- `projectionSourceCleanupFencesCompletion`: root invalidation, required-record
  corruption, cancellation and a new artifact after physical cleanup. Actual
  removal alone cannot bypass the final owner/availability checks. Corruption
  must remain an integrity error, with raw retained record bytes checked separately.
- `projectionSourceCleanupReceiptRequiresExactCapture`: two genuine source
  captures in the same root/store prevent a foreign-store fence from masking an
  omitted exact-capture check. The unrelated retained artifact stays intact.

`projectionSourceFreshProcessRecovery` keeps all four previous cuts and adds
`cleanup-before`, `cleanup-after` and `cleanup-returned`. A second inspection
process crashes again; two subsequent fresh inspections must produce identical
independent reports. History/current notes and the durable attempt survive even
when both original and artifact names are absent. Reopening cannot construct a
new Delete for the already-deleted birth or recover the old physical permission.

The construction suite grows from 128 to **132 checks**, retaining every existing
check and challenging the cleanup receipt's file-private issuer/capture and its
ordinary-client visibility. Three Runtime controls omit final owner checking,
final artifact absence or exact receipt/capture context. Every control requires
passing companions and the named assertion; setup, compilation and discovery
failures do not qualify it.

Entry points:

```sh
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'projectionSource|projectionDeletion|projectionReplacement|projectionCreation|projectionFileRead'"
python3 tools/test-projection-files-c.py --only cleanup --foundation --filesystems HFS+ HFSX
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-runtime-mutations.py --only p62-cleanup-final-owner --only p62-cleanup-final-artifact --only p62-cleanup-receipt-context
```

Repeat the Swift suite/type probes against release modules and select
`--configuration release` for the optimized mutation campaign. The native driver
already runs O0/O2. Linux uses the same native cases without Foundation, separately
on tmpfs/ext4, and its actual portable Runtime source/deletion suite.

The [physical contract](15-rooted-mutable-files-contract.md#owned-original-source-cleanup)
requires protection of the replacement too. The approved UUIDv4 unseen-name
creation assumption does not exclude this cleanup race. No assertion or policy
is weakened to obtain a passing run. These tests do not qualify provider
delivery/order, physical power loss, final P6.4
settlement, or rename/update source accounting. The models' existing safety
conditions are unchanged; no new TLC/refinement proof is claimed.

The actual Swift Runtime passes **70 focused functions** in debug and optimized
locally (`/tmp/nv-p62-cleanup-debug-final.log`, `/tmp/nv-p62-cleanup-release.log`).
All **132 construction probes** pass both configurations in
`/tmp/nv-p62-cleanup-types-{debug,release}.log`. All three Runtime mutants pass
companions and fail their designated assertions in debug and optimized:
`/tmp/nv-p62-cleanup-mutations.log` (report `nv-runtime-mutations-eczv8jau`) and
`/tmp/nv-p62-cleanup-mutations-release.log` (report `nv-runtime-mutations-vlkwg1xx`).
The isolated compiler package passes its exact-source manifest check; its prior
sources remain archived at `/tmp/nv-p62-pre-cleanup-mutation-package.tar`.
The independent private-record fixture checker and required app build pass;
`/tmp/nv-p62-cleanup-app-build.log` retains the established deployment warning.

The first corruption witness incorrectly called the validating attempt reader
after deliberately changing the record's fixed generation. That reader correctly
returned integrity. The corrected test requires that error and independently
checks generation/payload bytes; no production behavior or guard changed.

Linux's `/tmp` quota later returned **EDQUOT** on a direct 4-KiB diagnostic write,
despite `df` showing free blocks. This explained the truncated output and SQLite
write errors; the attempted syscall-trace file itself could not be written.
After removing only 144 executable artifacts in ten explicitly inventoried old
native-test directories (588,765,568 reproducible bytes), the unchanged debug
suite passed **31 source/deletion functions**. Its optimized suite also passed
all 31: `/tmp/nv-p62-cleanup-linux-qualified.log`,
`/tmp/nv-p62-cleanup-linux-release.log`. Source files, logs, fixtures and test
collections remain retained; no contract check was relaxed for host capacity.

The earlier bounded native campaign used six controls plus the two Apple-adapter
controls. Its results below remain evidence only for their stated schedules;
they do not discharge the new final-syscall race or qualify the current cleanup
candidate:

| Host / scope | Completed result |
| --- | --- |
| Local macOS arm64, APFS/HFS+/HFSX | `/tmp/nv-p62-cleanup-native-qualified.log`; 32 binaries reused on three volumes, all 22 direct / 25 coordinated cases, all six native and two adapter controls at O0/O2, all physical crash cuts, and the unchanged 40/12 Foundation witnesses. Artifact directory: `nv-projection-files-c-_zr2yeg3`. Independent output counting requires all 97 campaign/companion completion lines, including all metadata and adapter controls |
| Intel macOS 14.8.9 | `/tmp/nv-p62-cleanup-native-qualified.log` on scrodmini; complete direct/coordinated campaign and Foundation companions |
| Intel macOS 11.7.11 | `/tmp/nv-p62-cleanup-native-qualified.log` on orbb; complete direct/coordinated campaign and Foundation companions |
| Linux arm64, tmpfs and ext4 | `/tmp/nv-p62-cleanup-native-qualified.log`, `/tmp/nv-p62-cleanup-native-qualified-ext4.log` on Ubuntu; every direct case/control and both crash cuts at O0/O2 on each filesystem |

All native results include strict diagnostics, clean static analysis and
ASan/UBSan. Intel results qualify the compiled native boundary, not a newly
distributed Swift Runtime binary. Existing macOS 11 Swift runtime/compiler
workaround and the Linux RWX linker warning retain their separate release
qualification. No new API contract violation or provider guarantee is inferred.

### Native source-quarantine qualification

The initial `tests/ProjectionFilesSourceProbe.c` campaign exercised the C candidate through
25 cases. It places an uncoordinated change after the complete source read and
immediately before the actual exclusive rename. Cases include changed contents,
a new inode with identical bytes/dates/tags, metadata-only edits, a late occupied
recovery name, and a new source occupant after capture or before restoration.
Further cases retain oversized bodies and symbolic links, preserve hard-linked
or wrong-kind preflight sources, handle injected EIO/ENOSPC and an error after a real move,
check moved/lost roots, and reject changed final recovery evidence. A failed
final source lookup stays unavailable while the recovery observation remains
usable. Empty content
has its successful companion.

The test's independent descriptor reads inspect every expected surviving body;
the source/new occupant and actual moved item are accounted separately. Six
mutations omit expected bytes, moved identity, moved tags, exclusive restoration
or final artifact verification, or misclassify an unavailable name as absent.
Each must fail its designated assertion, with a
passing baseline. Debug/optimized native builds retain strict conversion and
pointer diagnostics plus ASan/UBSan and static analysis. Four abrupt-exit cuts
per optimization stop before the move, after the move, before mismatch
restoration and before final checking; the Python parent independently reads
surviving files. Termination supplies process-crash evidence only.

The same compiled probes and mutations are reused on each selected volume;
separate artifact directories preserve source and replacement campaigns when
`--only all` runs both. The extracted exclusive-rename helper also runs the
unchanged exclusive-creation companions and controls. The Runtime's durable
reservation and Foundation coordination are now connected above; frozen-move
issuance and source settlement remain separate required gates. The live original-Delete issuer is qualified
separately below. No historical record or raw
native result can initiate an original removal after restart.

All 25 cases, six mutation controls and four crash cuts pass in both `-O0` and
`-O2` ASan/UBSan builds, with clean static analysis, on:

| Platform / filesystem | Qualification log |
| --- | --- |
| Local arm64 macOS, APFS + HFS+ + HFSX images | `/tmp/nv-p62-source-quarantine-volumes2.log` |
| Intel macOS 14.8.9, APFS | `/tmp/nv-p62-source-quarantine-mini.log` |
| Intel macOS 11.7.11, APFS | `/tmp/nv-p62-source-quarantine-orbb.log` |
| Ubuntu arm64, tmpfs | `/tmp/nv-p62-source-quarantine-linux3.log` |
| Ubuntu arm64, ext4 | `/tmp/nv-p62-source-quarantine-linux-ext4.log` |

The persistent Linux test location was independently confirmed as ext4; the
default `/tmp` campaign used tmpfs. Both were tested explicitly. No physical
power-loss or provider capability follows from either campaign. The native
exclusive-creation regression and all its original controls pass after sharing
the rename helper (`/tmp/nv-p62-source-creation-regression.log`). The unchanged
Swift consumers pass all 37 selected debug/optimized functions in
`/tmp/nv-p62-source-swift-debug.log` and
`/tmp/nv-p62-source-swift-release.log`; the final source-name-state refinement
receives its own native witnesses above. The app build passes with its
established deployment diagnostic override in `/tmp/nv-p62-source-app-build.log`.

The additional unavailable-name case came from reviewing the raw result shape:
an unsuccessful lookup must remain distinguishable from confirmed absence.
Each name now has an explicit three-state result, and the other name is still
inspected after one lookup fails. Its negative control catches accidental
conversion of the failed lookup to absence. The existing model source-removal
permission and source-accounting conditions remain unchanged; this candidate
now has its typed original-Delete Runtime and durable-record consumers above;
source accounting and cleanup remain separate gates.

## Foundation metadata capability probe

`tests/ProjectionReplacementProbe.m` measures the intended same-volume Foundation
replacement path with an operation-local file reference, coordination, retained
backup and open stage descriptor. Compile with:

```sh
clang -Wall -Wextra -Werror -fblocks tests/ProjectionReplacementProbe.m -framework Foundation -o /tmp/nv-projection-replacement-probe
```

Run that binary with a fresh empty temporary directory and `default` or `new`.
Each run creates only synthetic `old`/`new` files, metadata and retained artifacts.
The JSON reports actual body/backup bytes, exact encoding/tags/stamp/unrelated
attribute values and stage-to-installed device/inode equality.

Initial local APFS observations on 2026-10-15: both default metadata and
`UsingNewMetadataOnly` retained the new body and all staged attribute values,
preserved the old body in the backup, and kept the retained stage descriptor bound
to the installed file. The same endpoint/date outcomes passed on Intel macOS
11.7.11 and 14.8.9. The extended probe forks a syscall-only reader before the
effect, requires coherent old and new witnesses, and rejects any stable mixed
body/encoding/tags/stamp/modification-date tuple. Forty fresh local APFS runs
(20 per option) passed, as did both options on each Intel host. This is bounded
observational evidence, not proof of every interleaving. Other filesystems,
replacement failures and real provider identity remain separate gates. It is
not a production replacement backend.

The 2026-10-15 assumption-update rerun exposed two intermittent observations in
this probe. One reported an empty Foundation backup read; the next aborted in
an added native backup read before line-level diagnostics were available. Later
inspection found three-byte `old` backups in both fixtures. Their immediate
cause remains unestablished; the completed earlier campaign alone cannot dismiss
them. The probe now captures Foundation's read error, performs independent
descriptor-based body/backup reads, and reports assertion lines and errno. Every
original preservation/metadata assertion remains, with the native byte checks
added. A subsequent full 40-case/12-reference campaign and 200 additional
alternating-option replacements passed. These passing repetitions strengthen the
evidence but do not establish the cause of the earlier failures or qualify a
production backend. Exact immediate backup readback and an uncertainty outcome
remain required before any production completion/cleanup.

Investigative logs: `/tmp/nv-p62-backup-assumption.log`,
`/tmp/nv-p62-backup-read.log`; passing diagnostic campaign:
`/tmp/nv-p62-backup-read2.log`; additional repetitions:
`/tmp/nv-p62-backup-repeat.log`. All are isolated synthetic files. Final diagnostics
and assertions pass the final scoped run (`/tmp/nv-p62-backup-final.log`): 40
metadata/reader cases, 12 exact reference/race outcomes and the explicitly labelled
backup-name API-limit observation. The completed native/Swift suites are reused
because their production sources did not change in this clarification.

## Destination-reference race investigation

`tests/ProjectionReferenceRaceProbe.m` uses pipes to put a real uncoordinated
writer **after** the last expected-body check and **before** Foundation replacement.
It compares six public URL constructors under two schedules: move the selected
file outside the owned root and replace its old name; or move the entire root
and install a new directory/file at its former pathname.

Compile as above with this probe's source and pass a fresh fixture directory,
one of `file`, `parent`, `path`, `relative`, `file-relative`, `cf-parent`, and
`leaf` or `root`. JSON reports both bodies and both possible backup locations.

APFS results, reproduced on arm64 macOS 26 and Intel macOS 11.7.11/14.8.9:

| Constructor | Leaf moved outside root | Root moved/replaced |
| --- | --- | --- |
| Selected file's `fileReferenceURL` | Follows file outside root and replaces it there: unsuitable | Follows original file in moved root |
| `URLByAppendingPathComponent` / `CFURLCreateCopyAppendingPathComponent` on root reference | Replaces current leaf and preserves concurrent bytes | Becomes an ordinary pathname and replaces the new root's leaf: unsuitable |
| Ordinary pathname | Replaces current leaf and preserves concurrent bytes | Replaces new root's leaf: unsuitable |
| `URLWithString:relativeToURL:` | Preserves moved file; replaces current leaf with retained concurrent backup | Keeps original root anchor |
| `fileURLWithPath:isDirectory:relativeToURL:` | Preserves moved file; replaces current leaf with retained concurrent backup | Keeps original root anchor |

The candidate for production is the last constructor, using an already-issued,
positively checked directory reference and validated leaf. No private reference
path is fabricated. These results refine the migration's API use while retaining
its rooted containment and displaced-content requirements. A file reference
following a move is expected Foundation behavior, not a violated Apple contract.
The full production backend, provider and volume gates still apply.

## Backup-name assumption and API limit

The same probe's `backup` schedule asserts that the candidate backup is absent
inside the entered accessor, signals an independent process to install
`concurrent` at exactly that name, and only then calls Foundation. On macOS
26 arm64, 14.8.9 Intel and 11.7.11 Intel the call succeeds: current becomes `new`,
backup becomes `old`, and `concurrent` is lost. All files are synthetic fixtures.

This is documented behavior. The installed SDK's `NSFileManager.h` description
of `backupItemName` explicitly permits removing a pre-existing same-name item;
see Apple's [replacement method](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:)).
The option to retain the resulting backup does not confer exclusive name
creation. A second check and additional coordination cannot exclude an
uncoordinated writer between that check and the native effect.

The user explicitly retained the migration's original random-name assumption
on 2026-10-15. Each attempt uses a fresh UUIDv4 name, checks absence inside the
accessor and retires any observed occupied candidate. Deliberate creation at
that exact private name during replacement lies outside the assumption.
The previous absolute-preservation assertion exceeded that adopted contract;
the experiment now asserts the actual documented outcome and labels it an API
limit. The Foundation campaign retains every target-file/reference and metadata
assertion and additionally records this observation:

```sh
python3 tools/test-projection-files-c.py --foundation
```

The former stricter probe's local log is retained as investigative evidence:
`/tmp/nv-p62-backup-collision-capability.log`, with full JSON in
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-projection-files-c-puw2gvdp/late-backup-collision/result.json`.
Intel observations are `/tmp/nv-p62-backup-mini.json` and
`/tmp/nv-p62-backup-orbb.json` on their respective hosts. Production replacement
still requires its implementation and qualification, including observed occupied
candidate retirement, actual displaced-content retention and target-file races.
The model's existing unique backup slots and the separate occupied-repository-
damage policy remain unchanged.

## Completed read qualification, 2026-10-15

- Local debug and optimized runs each passed eight functions: six new reader
  functions plus the existing ownership/regeneration companions (0.106/0.097 s
  test execution). Linux debug/optimized passed all six reader functions
  (0.023/0.041 s). Logs: `/tmp/nv-p62-read-{debug,release}.log` locally and
  `/tmp/nv-p62-read-{debug,release}-linux.log` on Ubuntu.
- Native O0/O2, strict diagnostics, static analysis, ASan/UBSan and both isolated
  negative controls passed on local macOS, Ubuntu and both Intel Macs. The
  consolidated local `--foundation` run also required all 40 metadata/reader
  cases and all 12 constructor/race outcomes. Its log is
  `/tmp/nv-p62-native-and-foundation.log`; artifacts are
  `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/nv-projection-files-c-8yb2iojf`.
- Debug/optimized root-boundary campaigns passed all 142 probes. Their interface
  evidence remains applicable after adding the final cancellation check; the
  new cancellation behavior has its own executable controls.
- Debug/optimized runtime mutation campaigns passed valid companions and killed
  both controls at their designated assertions: lost final cancellation and lost
  final owner validation. Logs: `/tmp/nv-p62-read-mutations-{debug,release}.log`.
- The legacy app build passed with the established diagnostic-only deployment
  override; no legacy caller or UI source changed. Log:
  `/tmp/nv-p62-read-app-build.log`.
- The eight fresh-process reader scenarios passed with debug and optimized
  clients on local macOS and Ubuntu, plus the same optimized Intel client on
  macOS 14.8.9 and 11.7.11. Logs: `/tmp/nv-p62-read-process-{debug,release}.log`
  locally, `/tmp/nv-p62-read-process-{debug,release}-linux.log` on Ubuntu, and
  `/tmp/nv-p62-read-process-{mini,orbb}.log` on the Intel hosts. The Intel binary
  SHA-256 is `90ed2ab2473325ad390c8050d31405a7a9b12dd3456727b07f47142b173ed9f8`.
  It reuses the pinned Intel SQLCipher archive and P6.1's documented macOS 11
  compiler/runtime variant; default distribution packaging remains a separate
  qualification. These tests exercise the actual Swift root actor, coordination
  adapter and C reader, with Python independently controlling and inspecting files.

The process-client build uses the repository's native SwiftPM path, e.g.
`PKG_CONFIG_PATH="$PWD/NVStorage/.deps/sqlcipher/lib/pkgconfig" swift build --build-system native --package-path NVStorage --product NVStorageProbe -c debug`.
The first Intel attempt accidentally used SwiftPM's newer default Xcode backend,
which rejected deployment target 11.5. Retrying with the established native build
path passed without changing the deployment target or compiler safety settings.

## Reuse and remaining runs

The [P6.1 settlement ledger](14-settlement-record-validation.md) records completed
record/history/process/platform qualification. Its unchanged consumers retain
that evidence. No model or legacy application behavior changed in this read
slice. Live-provider checks, broader volume coverage and the remaining physical
write/consumer gates remain separate. Backup naming uses the approved assumption
above. Physical power loss remains unqualified.

### Protected cleanup capture and recovery

The final-check/unlink counterexample was independently reproduced in O0/O2
direct and real coordinated variants, each with a passing normal companion.
`/tmp/nv-p62-cleanup-last-unlink-witnesses.log` and the
`nv-p62-cleanup-gap-nnlxpd5j` artifact directory retain the exact logs and independent
named-byte inventories. All four found `preserved=0 outcome=1`; constructor and
post-effect checks could not recover those lost bytes. This invalidated the
earlier physical-removal claim without weakening the required assertion.

The new production consumer exclusively moves the public artifact into
`<recoveryName>.cleanup/item`, compares the actual captured state, and cleans
only the matching private child. A different item restores exclusively or stays
retained. The existing required attempt already determines this location; its
encoding and fixtures are unchanged. Parent identity, permissions, root lifetime,
borrowed descriptor, barriers and final record/capture checks remain enforced.
Empty protected directories stay retained for later P6.4 settlement. There is
no extra SQL table, sidecar record or public cleanup permission.

The native probe now has **33 direct / 37 coordinated cases**, including:

- A real child process replacing the public item immediately before its capture
  syscall; the actual foreign contents survive even when the public name is
  reoccupied and exclusive restoration cannot proceed.
- An in-place content change before capture, a public occupant arriving at the
  private unlink boundary, existing/symlink protected-directory collisions,
  substitution of the protected directory after capture, synchronization failure
  before/after capture, root loss after actual removal and an independently
  reappearing private child before final native observation.
- All earlier contents/metadata/descriptor, namespace, I/O, root and availability
  cases. Eight portable C controls challenge captured-content comparison and
  both final locations as well as the earlier guards. A ninth Darwin control
  omits inherited-ACL clearing; the normal companion installs an inheritable
  owner ACL and independently verifies owner-only mode and an empty/absent
  extended ACL on the resulting private directory. Three Foundation controls challenge move options
  and each accessor URL independently, inside actual granted coordination blocks.

Four abrupt exits stop after the public preflight, after capture, after private
verification or immediately after unlink. Python reads each surviving location
independently. The full native command reuses every O0/O2 binary/control on the
host volume and HFS+/HFSX. Normal host access is required for Foundation's daemon:
the tool sandbox returned Cocoa 512 before entry; the same companion binary
passed outside it. This access failure was not waived as a successful primitive.

Runtime qualification retains all earlier cases and adds:

- `projectionSourceProtectedRecoveryInspectsRetainedContents`: six exact/changed,
  independently occupied public name, hard-link, symlink and directory cases.
  Reopening reads the protected location without consuming its required record.
- `projectionSourceFreshProcessRecovery`: an explicitly named
  `protected-capture-fixture` stages the native crash boundary's retained location
  under a genuine durable attempt, then execs repeated independent inspectors.
  This fixture qualifies reconstruction of that location; the native abrupt-exit
  test separately qualifies the actual capture syscall boundary. Neither is
  presented as a single Swift-to-C crash-injection witness.
- `projectionSourceCleanupFencesCompletion`: an independently introduced
  protected child prevents a removal receipt. Its precise contents remain in the
  returned read-only observation. The associated mutant must fail the intended
  final-availability assertion.

`ProjectionCleanupSnapshot` is distinct from a direct-child note snapshot and
has a file-private issuer; it records exact attempt/root-scoped inspection
contents without authorizing physical removal. Construction probes now require
**135 checks**, including its issuer and ordinary-client visibility. Four cleanup
Runtime mutants challenge final owner, public absence, protected absence and
exact receipt/capture binding; the existing final recovery-owner mutant is also
requalified after adding the third read.

This increment preserves the models' safety conditions. The protected child's
owned-private-namespace premise is the existing private-staging premise, while
public artifact replacement remains an explicitly tested execution. Complete
source accounting/owner transfer, application enablement, rename/update and live
provider qualification remain separate gates. Process exits and fsync results
do not qualify physical power loss.

Qualification results for this follow-up:

- Local macOS debug and optimized runs each pass **71 focused tests**, including
  fresh-process recovery and the separate protected-location fixture. Logs:
  `/tmp/nv-p62-protected-cleanup-{debug,release}-qualified.log`.
- Ubuntu arm64 Swift 6.4 debug and optimized each pass **32 source/deletion
  tests** through the actual portable Runtime. Logs on that VM:
  `/tmp/nv-p62-protected-cleanup-linux-{debug,release}-qualified.log`.
- All **135 compiler-boundary probes** pass debug and optimized modules on both
  platforms. Local logs: `/tmp/nv-p62-protected-cleanup-types-debug2.log` and
  `/tmp/nv-p62-protected-cleanup-types-release.log`; Linux logs:
  `/tmp/nv-p62-protected-cleanup-linux-types-{debug,release}.log`.
- The final native matrix passes O0/O2, strict diagnostics, Clang static analysis
  and ASan/UBSan on local macOS, Intel macOS 14.8.9 and Intel macOS 11.7.11.
  Each Mac runs 46 binaries across its host volume and HFS+/HFSX, preserving all
  passing companions, designated mutation failures and four abrupt-exit cuts per
  valid variant. Linux passes its 18 portable variants on ext4. The final log on
  every host is `/tmp/nv-p62-protected-cleanup-native-qualified-final.log`.
- Both ordinary and descriptor-retaining read campaigns pass unchanged scenario
  coverage after extracting the shared directory reader. Log:
  `/tmp/nv-p62-protected-read-regression2.log`. Independent private-record and
  projection-observation fixtures pass; no encoded layout changes.
- Four cleanup Runtime mutations pass companions and fail their intended
  assertions in debug and optimized; the final recovery-owner mutation also
  passes its optimized companion and fails its intended assertion. Logs:
  `/tmp/nv-p62-protected-cleanup-mutations2.log` and
  `/tmp/nv-p62-protected-cleanup-mutations-release.log`. These target unchanged
  Swift checks; the subsequent native symmetric-absence guard has its own new
  native failure/companion and final-source Runtime suites above. The complete
  mutation setup checker still passes every registered mutation's exact source
  and assertion lookup. No unrelated cross-product is dropped or rerun.
- The application build passes with the established diagnostic-only deployment
  override; the existing deployment-range warning remains. Log:
  `/tmp/nv-p62-protected-cleanup-app-build.log`. Legacy/UI source is unchanged.

An initial final-source Linux rerun hit its tmpfs per-user quota and produced a
truncated log; it is not counted as a pass. Exactly 110 reproducible native
binaries from nine completed older artifact directories were removed
(459,155,000 bytes), using the saved
`/tmp/nv-storage-disk/nv-p62-completed-native-binaries-inventory.json`. Sources,
logs, fixtures, compiler caches and the final native binaries were preserved.
Both final Runtime configurations then passed without changing any assertion,
input limit or implementation contract.

## Active-presenter correction and single-accessor deletion

The [updated physical contract](15-rooted-mutable-files-contract.md#active-presenter-correction-and-direct-removal-adapter)
keeps this qualification separate from the earlier two-step Runtime consumer.
The real-protocol probe is [ProjectionFilesPresenterProbe.m](../../../../tests/ProjectionFilesPresenterProbe.m),
run by the existing [native driver](../../../../tools/test-projection-files-c.py).
It registers an `NSFilePresenter` on its own serial operation queue, performs
document saves with `initWithFilePresenter:self` on that queue, and observes its
actual URL, callbacks and subsequent saved files. Every fixture is synthetic.

### Findings and corrections

1. The original ordinary replacement used `WritingForReplacing`. The installed
   SDK explicitly excludes ordinary updates, even temporary-file-plus-rename
   safe saves, from that option. A real cooperating presenter was asked to close.
   The production adapter now uses destination options `0`, preserving the same
   note/document. `.forMerging` was also explored: it requests dirty saves before
   NV's effect and can invalidate the captured source. It is not silently adopted.
2. Foundation can normalize a requested rooted relative URL into its equivalent
   absolute file-path URL, particularly after presenter moves. Literal URL
   equality rejected valid grants. The existing exact-component/opaque-root
   matcher is now shared in a private header by both Apple bridges. Wrong names
   and same-named targets under other roots still fail before effects.
3. Separate source-to-public-recovery-to-protected moves can teach an editor a
   private save destination; its later save can recreate that artifact. Flags
   alone did not repair the two-accessor path. The new
   `NVAppleRemoveProjectionSource` uses one logical deletion accessor and the
   existing protected capture/comparison/removal algorithm. The source is
   `.forDeleting`; the exclusive protected child is `0`. Internal preservation
   emits no logical move notification. Actual public moves retain their notices.

These are corrections to API mapping, not Apple contract violations or new
causal deletion policy. No persistent field, table, sidecar or encoded layout is
added. The following Runtime port now uses the direct source method. Its
intermediate two-step Swift methods and protected-artifact wrapper are retired;
actual document/provider and later settlement gates remain separate.

### Independent outcomes

| Scenario | Required observable result |
| --- | --- |
| Ordinary update, clean/dirty/refusing editor | New bytes installed; exact old backup retained; editor stays open and retains its draft; subsequent save targets `Note.txt` |
| Delete, normal close | Deletion callback closes the presenter; source removed; no subsequent save |
| Delete, dirty peer saves during callback | Original snapshot no longer applies; no removal; exact dirty bytes remain |
| Delete refused | Explicit cancellation before effect; old file survives; later save still targets the original file |
| Delete, peer chooses to stay open | Exact original removed; later save recreates the public `Note.txt`, not a recovery path |
| Protected unlink returns EIO | Uncertain physical result; exact original remains in `recovery.cleanup/item`; a keep-open peer's later public save preserves both streams |
| Equivalent path-URL grants | Same outcomes, with exact root/components checked |
| Same leaf under a foreign root, source or destination | `ESTALE` before native effect; original and foreign namespaces remain intact |
| Genuine public move control | Presenter follows `Moved.txt`; later save uses that public destination |

The assertions decode actual Base64 file bytes independently of the native
outcome, require the chosen callback/close behavior, and check later save
destinations. Native race/fault/crash probes retain their complete previous
matrix and exact designated failures. The presenter campaign adds four controls:
ordinary `.forReplacing`, deletion `.forMoving`, advertising a private move, and
literal URL equality. Each passes its production companion and fails the named
semantic assertion. Compiler failure is not counted as a caught mutation.

### Run and evidence scope

```sh
python3 tools/test-projection-files-c.py --only presenter
python3 tools/test-projection-files-c.py --only cleanup --foundation --filesystems HFS+ HFSX
python3 tools/test-projection-files-c.py --only replace
python3 tools/test-projection-files-c.py --only source --foundation
python3 tools/test-projection-files-c.py --only foundation
```

`--only foundation` reruns the independent 40 metadata/reader and 12 reference/race
observations without recompiling the already qualified production variants.
The native runner's narrowly scoped source-notification mutations now select
their original function explicitly, because the shared protected-removal
algorithm also contains callback sites. Both original checks remain required.

The final presenter campaign has 18 exact scenarios and four targeted mutations
per optimization: **44 outcomes** across O0/O2, with strict diagnostics and
ASan/UBSan. The protected-removal campaign has 46 native/coordinated binaries on
each Mac, reused on the host volume and HFS+/HFSX, plus four independently inspected
abrupt-exit cuts per passing binary variant. Linux retains its 18 portable
variants. The earlier comparison artifacts are capability evidence; final
qualification uses the completed campaigns below.

- **Local macOS, Intel macOS 14.8.9 and Intel macOS 11.7.11:** all 44 final
  presenter outcomes pass on each host. Logs on each host:
  `/tmp/nv-p62-presenter-final-interop.log`.
- **All three Macs:** all 46 protected-removal binaries pass on the host volume
  and HFS+/HFSX, retaining all race/fault controls and abrupt-exit inspections.
  The independent 40 metadata/reader and 12 reference/race observations also
  pass. Each final log has 139 `PASS` lines:
  `/tmp/nv-p62-direct-cleanup-final.log`.
- **Ubuntu arm64:** all 18 portable protected-removal variants pass, with
  static analysis and ASan/UBSan. Log on that VM:
  `/tmp/nv-p62-direct-cleanup-final.log`.
- **Swift production regression:** debug and optimized each pass all 71 focused
  read/create/replacement/source/deletion tests. Logs:
  `/tmp/nv-p62-presenter-runtime-{debug,release}.log`. Swift evidence types and
  access-control boundaries are unchanged; previously completed 135-probe
  construction/consumer qualification is reused for those unchanged boundaries.
  These old-bridge regression results do not qualify the future direct-removal
  Swift consumer.
- **Affected native regressions:** complete replacement and generic source
  campaigns, including their exact mutation assertions and fresh-process cuts,
  pass. Logs: `/tmp/nv-p62-presenter-replacement-regression.log` and
  `/tmp/nv-p62-presenter-source-regression.log`.
- **Application build:** passes with the established diagnostic-only deployment
  override and existing deployment-range warning. Log:
  `/tmp/nv-p62-presenter-app-build.log`. Legacy caller and UI source are unchanged.
- **Bookkeeping:** index regeneration, self-tests and completeness check pass.
  Added classification checks cover the presenter/cleanup probes and cleanup
  mutations; all now link to this phase's contract and ledger. No new encoding
  fixture or modeled safety condition is changed.

One initial local supplementary Foundation probe failed its raw `open` assertion
with `EPERM` after replacement. The cause remains unconfirmed. Its first failed
run is not a pass; the complete diagnostic rerun and final campaign passed with
the same raw-read assertion. The test now prints the exact synthetic path and
error on failure. Log: `/tmp/nv-p62-presenter-foundation-diagnostic.log`.
An initial Linux invocation lacked the installed toolchain's `clang` on PATH;
the final campaign uses that toolchain explicitly, without changing checks.

This is protocol-participant interoperability, not full AppKit `NSDocument` UI
qualification. Live-provider ordering, the single-accessor Swift permission/
reservation/receipt migration, fresh-process recovery through that new consumer,
complete P6.4 source accounting, and application enablement remain separate
gates. No TLA transition or safety assertion changes; its correspondence now
records this concrete API correction without claiming an additional TLC proof.

## Direct Runtime removal and connected native crash recovery

The [current contract](15-rooted-mutable-files-contract.md#durable-original-source-reservation-and-inspection)
is implemented by `RepositoryRootSession.removeProjectionSource`. It reserves
the root turn before suspension, commits the required attempt before entry,
borrows the original coherent-read descriptor and invokes the single deletion
accessor. Fresh original/protected observations and exact store/root/command
checks precede its file-private `ProjectionSourceRemovalReceipt`. The two-step
Runtime methods, intermediate `ProjectionSourceCapture`/result, second native
cleanup wrapper and their diagnostic-only presenter modes are retired.
The generic public-relocation primitive retains its distinct capability tests.

### Minimal state and actual consumers

- Required private bytes and v1 encoding are unchanged. A native transient
  `directory_created` result records exclusive acquisition. A no-removal result
  may retire its candidate only when that flag is zero. An owned empty directory
  after failure retains its attempt, as do successful/uncertain effects pending
  later settlement. A foreign collision is preserved and burns its candidate.
- `UncapturedProjectionSource` has a file-private issuer. Its SQL consumer checks
  the exact live authorization and row before retirement. Passive recovery
  records cannot construct that permission.
- A removal receipt binds the existing descriptor-lease object's identity and
  exact Delete reference. Independently captured inputs from the same file and
  command are a wrong context; copies of the actual input share the lease.
  This needs no extra UUID, registry, table or long-lived cache.
- Recovery reads the public source and protected child only. Its nested snapshot
  remains distinct from a direct-child note snapshot. Completed removal, failed
  retirement, copied private stores and repeated reopening preserve source
  owners; none reconstructs a physical permission or publishes P6.4 settlement.

### Connected crash/failure evidence

[ProjectionFilesSyncFault.c](../../../../NVStorage/Tests/Support/NVStorageTestSupport/Resources/ProjectionFilesSyncFault.c)
is a **test-target resource**, compiled into a temporary injected library by the
parent test. It is absent from production target dependencies. It identifies
only synchronization of a protected directory inside the exact synthetic root.
All other calls reach the real system function. macOS uses dyld interposition;
Linux uses `LD_PRELOAD`. No fault option is added to the production adapter.

The actual Swift participant commits its history and reservation, then exits
inside native synchronization before capture, after capture or after unlink.
Another mode returns EIO after the directory was created, then exits after the
real Runtime handles that result. Subsequent fresh participants receive only
selection/unlock inputs and inspect surviving state. The parent independently
checks exact file bytes, logical notes, retained action bytes and required-row
presence. Inspection itself also exits once; two later reports must agree.
Twelve cuts/fixtures separate these real transitions from changed/protected and
protected-plus-public fixtures. No acknowledged-note oracle is supplied to recovery.

The SQL retirement-failure companion creates a foreign candidate, rejects the
exact private-row DELETE with a real trigger, and verifies that source, foreign
contents and row survive. A second removal is busy, unrelated note editing
continues, and reopening independently observes both streams. Existing reservation
write-failure and held-completion companions retain their checks.

### Discovered recovery bug and stronger negative controls

Linux exposed a genuine error-classification gap: protected inspection reached
the reader's size check before rejecting a directory. Its 4-KiB directory was
reported as `sizeLimit` rather than the required `kindCollision`. The stricter
zero-budget companion reproduced this on macOS for directories, symlinks and
hard links; log: `/tmp/nv-p62-direct-recovery-kind-counterexample.log`.

The typed recovery boundary now checks observed kind and single-link ownership
before content coordination or body budget. The six existing fixtures keep
their expected classifications, with a zero-byte budget for invalid kinds/links.
This fixes implementation ordering rather than widening allowed Linux outcomes.
Two mutations remove those exact checks and must fail at the kind/link assertion.

Changed Runtime controls cover final store ownership, current public/protected
absence, receipt context, uncertain retirement, original-capture identity,
recovery input/owner and the new owned-directory failure. In particular, deleting
the `directory_created` retirement condition loses the required record after
the actual injected EIO; the fresh-process record assertion detects it.
Every selected mutant retains passing companions, discovery and designated
assertions. The original mutation/test cross-product is preserved.

The new constructor/consumer set has **137 checks**: the removed intermediate
type's two obsolete probes are replaced by four useful checks for capture
identity confinement, recovery-versus-live permission, passive retirement and
the live consumer companion. The stale 135-count assertion caught the change;
it now requires exactly 137. All access-control, marked-line and diagnostic checks
remain. A new mutation's duplicated source needle was rejected during setup,
then scoped to its exact two-line recovery boundary; setup failure is not a kill.

### Qualification and reuse

```sh
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter 'projectionSource|projectionDeletion|projectionReplacement|projectionCreation|projectionFileRead'"
make -C tests run-swift-storage "SWIFT_STORAGE_TEST_FLAGS=-c release --no-parallel --filter 'projectionSource|projectionDeletion|projectionReplacement|projectionCreation|projectionFileRead'"
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-private-types.py --modules NVStorage/.build/release/Modules
python3 tools/test-projection-files-c.py --only cleanup --foundation --filesystems HFS+ HFSX
python3 tools/test-projection-files-c.py --only presenter
```

- Local macOS debug and optimized each pass **all 72 focused tests** on the final
  typed recovery boundary, including the new SQL failure. Logs:
  `/tmp/nv-p62-direct-runtime-{debug,release}-qualified.log`.
- Local construction/consumer qualification passes **137 checks** in both
  configurations. Logs: `/tmp/nv-p62-direct-types-{debug,release}-qualified.log`.
- The final native boundary passes strict diagnostics, static analysis and
  ASan/UBSan on local macOS, Intel macOS 14.8.9 and Intel macOS 11.7.11. Each Mac
  passes all **50 binaries** across its host volume and HFS+/HFSX, retaining the
  33 direct/37 coordinated scenarios, four abrupt-exit cuts per valid variant,
  all previous mutations and the added directory-acquisition mutation. Its
  independent Foundation companions also pass; each final native log has
  **151 PASS lines**: `/tmp/nv-p62-direct-bridge-native-final.log`.
- Each Mac also passes the **44 real-presenter outcomes** with explicit native
  ownership observations: `/tmp/nv-p62-direct-bridge-presenter-final.log`.
  Linux's final portable native campaign passes **20 variants**, with static
  analysis and ASan/UBSan, under the same native log name on that VM.
- Independent private-record and projection-observation fixture checks pass;
  encoded bytes are unchanged. Existing source/read/replacement and earlier
  compiler evidence is reused only for unchanged boundaries; the new Runtime
  results above replace the earlier old-bridge regression classification.

The isolated mutation cache is reused only after its complete non-build source
manifest matches. Debug's ten changed-boundary controls pass at
`/tmp/nv-p62-direct-runtime-mutations-debug.log`; the two later kind/link controls
pass at `/tmp/nv-p62-direct-kind-mutations-debug-qualified.log`. Those two guards
change only the newly challenged invalid-kind/link path; final-source passing
companions above preserve all earlier paths. The optimized campaign also passes
all twelve controls at
`/tmp/nv-p62-direct-runtime-mutations-release.log`. Ubuntu arm64 passes all
33 source/deletion tests and 137 construction/consumer checks in both debug
and optimized configurations. Logs on that VM:
`/tmp/nv-p62-direct-runtime-linux-{debug,release}-qualified.log` and
`/tmp/nv-p62-direct-types-linux-{debug,release}-qualified.log`. The full Swift
suite on the older Intel Macs remains a separate claim from their native
qualification above.

The app build passes with normal Xcode service access and the established
diagnostic-only deployment override:
`/tmp/nv-p62-direct-bridge-app-build-qualified.log`. The unchanged 11.5 deployment
target still produces its known range warning. The test-target inventory passes
all 24 self-tests and SwiftPM's resolved production dependency-closure checks:
`/tmp/nv-p62-direct-resource-membership-qualified.log`. The interposer resource
stays reachable only through test targets.

An unqualified Linux default-builder attempt failed creating a dependency file
and left a dangling generated `debug` alias. Its 189-MiB generated output was
removed, the alias was repaired to the existing native artifacts, and all further
runs use the documented Make/native workflow. No source or API contract was
changed for that tooling failure. To preserve space for qualification, 36 inactive
ELFs from two completed older native campaigns were removed (151,089,104 bytes),
retaining sources, fixtures, logs and the latest binaries. Inventory on the VM:
`/tmp/nv-storage-disk/nv-p62-direct-old-native-reclaim.json`.

This completes a concrete original-removal bridge, not all of P6.2 or P6.4.
Actual-document/provider qualification, rename/update/case-only/format paths,
remaining replacement/finalization gates and atomic source-accounting/owner
transfer retain their separate requirements. UI/legacy caller code is unchanged.
The model correspondence records this mapping of existing safety premises;
no modeled assertion or abstract transition changes, and no extra TLC proof or
physical power-loss qualification is claimed.

## Final-public-rename presenter companions

The existing source-move primitive and `NVAppleQuarantineProjection` adapter now
have direct presenter companions using **the final public filename** `Moved.txt`.
This extends the existing runner, preserving all earlier 44 outcomes. Eight added
scenarios cover clean/dirty/deletion-refusing/keep-open editors, Foundation's
normalized pathname grants, an occupied destination and foreign source/destination
grants. Two added mutations change moving intent to deletion or omit the explicit
successful-move notification. O0/O2 run all companions and controls with the
existing strict diagnostics and ASan/UBSan.

Independent observations require the exact old bytes at the final filename,
the editor's exact new URL, one explicit move notification, preserved dirty draft,
and a later editor save only at `Moved.txt`. An occupied destination remains
`foreign`, the original stays at `Note.txt`, no move is notified, and the editor's
later save still targets `Note.txt`. Foreign grants preserve both roots and
return the exact stale-context outcome.

The first negative-control registration expected missing delivery for an omitted
explicit notice. The OS also discovered that move, so delivery alone could not
prove the notification. The existing explicit-notice counter correctly failed;
the control now requires that designated assertion. A deletion-intent mutation
both closes the presenter and loses delivery; the close assertion is checked
first so its intended violation is reported. Neither setup/registration mismatch
counts as a detected control. No production behavior or check was relaxed.

```sh
python3 tools/test-projection-files-c.py --only presenter
```

Local macOS passes **64 outcomes**: 52 exact companions and 12 targeted negative
controls across O0/O2. Log: `/tmp/nv-p62-public-move-presenter-local-final.log`.
Intel macOS 14.8.9 and 11.7.11 each pass the same **64 outcomes**, with terminal
success at `/tmp/nv-p62-public-move-presenter-final.log` on each host. SHA-256
checks match all nine adapter/native/header/probe/runner inputs across the
three Macs. Existing native source-fault, replacement and direct-removal results
are reused for unchanged production code.

This is native move/presenter interoperability, not completion of logical
rename/update, case-only rename, format transitions, real `NSDocument` UI or
P6.4 settlement. The earlier Objective-C filename/collision/source-proof tests
remain requirements for those consumers.

## Native staged rename/update, including case-only changes

The new `nv_projection_relocate` and `NVAppleRelocateProjection` candidate
connects the previously checked stage and original-source preservation paths.
It retains the captured original at the reserved backup, exclusively installs
complete output, and reports source/backup separately from installation. A
known destination refusal restores exclusively where possible; a late original
occupant remains intact. All displaced bytes stay named for later accounting.
The shared exclusive-install helper preserves creation's preflight and exact
post-install checks. Existing same-name Foundation replacement is unchanged.

`ProjectionFilesRelocateProbe.m` exercises the actual candidate in 32 scenarios:
ordinary/empty/equal-body output, case-only and format changes, occupied
destination/backup, changed/coarse-clock metadata source, source replacement in
the rename gap, late destination, returned original, blocked restoration,
changed stage before or after capture, a returned case-only source,
final output/metadata/backup interference, root move/loss, wrong
stage/expected snapshot/grant, EIO before installation, lost syscall return,
cancelled/refused coordination, normalized and foreign grants, and a callback
error after physical completion. Exact errors and effect classifications remain
assertions. Source-descriptor lifetime, file contents, mode, required raw
encoding/tags, copied custom metadata, staged-date representation and actual
directory-entry capitalization are independently inspected.

Nine controls challenge destination preflight, exclusive installation, the
granted stage's identity, post-capture stage revalidation,
pre-capture complete metadata, exclusive restoration,
final name/metadata checks and explicit public move notification. Each must
compile with unchanged strict flags and fail its designated runtime assertion.
Six actual child exits cover before capture, retained original, pre-install,
post-namespace installation and final verification. A fresh independent process
checks exact original/output bytes, mode, custom metadata and mandatory
encoding/tags. It receives filesystem inputs, not the native result or a parent
success oracle. These native cuts qualify physical preservation; the future
SQL-backed relocation attempt/reopen path remains a separate requirement.

```sh
python3 tools/test-projection-files-c.py --only relocate --filesystems APFSX HFS+ HFSX
python3 tools/test-projection-files-c.py --only presenter
```

Local macOS passes all **128 native outcomes** over host APFS, APFSX, HFS+ and
HFSX: 80 valid/mutated binary-volume runs plus 48 fresh crash inspections.
Log: `/tmp/nv-p62-relocation-native-local-current.log`. All 32 positive scenarios
run in O0/O2 on each volume; all nine controls run at both optimization levels
on every volume. C/Objective-C static analysis and ASan/UBSan retain their checks.
Intel macOS 14.8.9 and 11.7.11 each complete the same **128 outcomes**, with
terminal success at `/tmp/nv-p62-relocation-native-current.log` on each host.
Thirteen production/header/probe/runner/volume-helper SHA-256 checks match
across all three Macs.

The expanded real-presenter matrix retains every previous case and adds the
new stage-backed ordinary/case-only/format move, draft policies, normalized and
foreign grants, and an independently presented occupied destination. A control
using replacing intent for the case-only destination closes the editor; the
production exclusive operation uses `0` and preserves it. Direct coordinated
case-only rename companions reproduce the framework's optional move callback:
its old-capitalization URL still identifies the correct new file. Every such
case requires actual same-file identity before/after the later save, exact
on-disk spelling, preserved draft/backup and NV's explicit notice. Distinct-name
moves still require delivery and the exact final URL. Actual optional callback
delivery is recorded separately, including absence, rather than reported as a
successful callback. All three Macs pass **90 presenter outcomes**: 76 exact
companions and 14 targeted controls across O0/O2. Local log:
`/tmp/nv-p62-relocation-presenter-local-recorded.log`; Intel logs:
`/tmp/nv-p62-relocation-presenter-current.log` on each host.

The returned-source case confirms both real namespace shapes. On an aliasing
volume the returned original occupies the new spelling and blocks installation;
on a case-sensitive volume the new output can install while the returned source
stays at its separate name. Neither result certifies source settlement or grants
permission to remove that occupant. The post-capture stage control also verifies
that merely reporting uncertainty after installing bad bytes is insufficient:
the independently instrumented physical-effect and surviving-file expectations
require refusal/restoration before the invalid stage enters the public namespace.

Production Swift regressions pass all **72 focused tests** in debug and
optimized builds: `/tmp/nv-p62-relocation-runtime-{debug,release}.log`.
Unchanged constructor/private-record encodings reuse their prior qualified
137-probe and independent-byte results. The shared creation helper passes all
14 O0/O2 valid/mutated creation variants, with static analysis and ASan/UBSan,
both locally (`/tmp/nv-p62-relocate-create-regression.log`) and on Ubuntu arm64
(`/tmp/nv-p62-relocation-create-regression.log` on that VM). The existing source
and Foundation replacement campaigns pass 49 and 30 outcomes respectively:
`/tmp/nv-p62-relocation-source-regression.log` and
`/tmp/nv-p62-relocation-replacement-regression.log`. The app build passes with
the established deployment diagnostic override and known target-range warning:
`/tmp/nv-p62-relocation-app-build.log`. No production compiler setting or old
mutation/test cross-product changes.

The first EIO fixture incorrectly expected restoration after an ambiguous syscall
error. Independent observation instead showed the original retained at backup
and the complete stage retained, with uncertainty and no success. The fixture
now asserts those exact surviving inputs; production did not relax the ambiguity
rule. An initial mutant failed strict compilation from removed-parameter uses;
explicit void uses keep that mutant runnable. A volume-helper import was corrected
to the existing projection helper. Existing move controls are scoped to their
original function now that another adapter uses moving intent. None of these
setup failures counts as a killed mutant or complete campaign.

This remains a native candidate. Its live Swift move permission, durable
reservation, same-generation receipt consumers, connected private-store
crash/reopen path and P6.4 settlement are not supplied by these tests. Existing
construction evidence is reused for unchanged Swift boundaries. Provider
identity, ExFAT, real `NSDocument` UI and physical power-loss qualification remain
separate gates. No encoding, schema, TLA+ transition or safety assertion changes.
