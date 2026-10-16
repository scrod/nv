# P6.1 — Portable projection transport qualification

Contract: [current v1 placement](08-portable-projection-contract.md).
This qualifies the containing record, actual acceptance and retention, not local
producer scheduling, a complete portable query API, or physical association.

## Cases and independent observations

Seven new functions contain 15 cases:

| Test | Required observations |
| --- | --- |
| `projectionTransportIndependentBytesAndCanonicalAbsence` | Independent binding/payload/envelope/hash bytes, unique empty encoding, truncation, ordering/duplicates and mandatory dependency membership |
| `projectionTransportChecksAuthenticatedContext` (2) | Real public/encrypted envelopes; matching plaintext companion, foreign collection and encrypted-profile description rejection |
| `projectionTransportChecksDerivedSourceAndPreservesLogicalIdentity` (2) | Equal/merged literal sources, exact body, unchanged operations/actions, changed envelope payload, one source read, sync/async agreement, missing/self/wrong-result failure |
| `projectionTransportValidatesCompleteOversizedSource` | 100 complete source occurrences validate through real note ancestry; one envelope read, independent expected body; the bounded stamp is omitted in full |
| `projectionTransportAcceptsHistoryWithoutEditingNotes` (4) | Real ordinary/equal/merged/automatic accepted histories delivered in reverse; exact SQL operation/action preservation, full dependencies/frontier, no private observation creation, idempotent delivery, reopen and derived-row rebuild |
| `projectionTransportRejectsClaimsBeforeAcceptance` (4) | Wrong identity/index/collection/profile rejected before membership; exact bytes/rejection retained, prior notes/prefix preserved and unrelated edit succeeds |
| `projectionTransportParkingAndAcceptanceRollbackSurviveReopen` | Exact missing source parks across reopen; two acceptance-write failures preserve bytes/ready work/prior frontier; another reopen completes without another delivery |

`check-projection-transport-fixtures.py` independently constructs the current
optional-section bytes and public envelope/hash. The existing JavaScript SQL/wire
observer now independently parses this section, verifies ordering, exact source
dependencies/occurrences, profile/collection, and represented values. It does not
treat an output digest as proof of a physical file or its encoding.

`test-projection-transport-process.py` adds five isolated child-process schedules:
success, termination before/after acceptance commit, ENOSPC and synchronization
EIO. Python authors the incoming descriptor/envelope independently. Recovery gets
selection/unlock inputs only, not expected notes or acknowledgment records.
Independent inspection checks exact retained bytes, membership, dependency edges,
frontier, unchanged logical operations/actions, current bodies and duplicate retry.
No received description creates a private accepted-file record.

The EIO case explicitly tests an ambiguous commit. A failure response cannot
promise rollback: raw reopened membership must show either the complete new
coverage or retryable input with unchanged old coverage. Recovery must finish the
same object exactly once in either case. Termination, simulated write/sync failure
and later corruption remain distinct fault classes.

## Commands

```sh
make -C tests run-swift-storage \
  'SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter projectionTransport --filter projectionHistory --filter derivedState --filter projectionIntent --filter bootstrap'
# Repeat with -c release; Linux may add --jobs 2.
python3 tools/check-projection-transport-fixtures.py
PKG_CONFIG_PATH="$PWD/NVStorage/.deps/sqlcipher/lib/pkgconfig:$PKG_CONFIG_PATH" \
  swift build --build-system native --package-path NVStorage \
  --configuration debug --product NVStorageProbe
python3 tools/test-projection-transport-process.py --binary NVStorage/.build/debug/NVStorageProbe
# Repeat against release. Linux paths include the actual target triple.
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/debug/Modules
# Repeat against release.
python3 tools/test-storage-runtime-mutations.py --configuration debug \
  --only p61-transport-ignore-source --only p61-transport-ignore-profile \
  --only p61-transport-omit-dependency --only p61-transport-ignore-collection
# Repeat with --configuration release.
```

The process suite requires an explicit successful product build from the same
sources. A passing `swift test` does not establish that the standalone probe was
relinked. Require `Build of product 'NVStorageProbe' complete!` and reject a
`cancelled!` result, even when SwiftPM returns zero. On Linux, use the same pinned
SQLCipher environment and add the existing production build/linker flags:

```sh
PKG_CONFIG_PATH="$PWD/NVStorage/.deps/sqlcipher/lib/pkgconfig:$PKG_CONFIG_PATH" \
  swift build --build-system native --use-integrated-swift-driver \
  --disable-build-manifest-caching --package-path NVStorage \
  --configuration debug --product NVStorageProbe --jobs 1 \
  -Xswiftc -use-ld=lld -Xlinker -z -Xlinker relro -Xlinker -z -Xlinker now
python3 tools/check-storage-elf.py NVStorage/.build/aarch64-unknown-linux-gnu/debug/NVStorageProbe
python3 tools/test-projection-transport-process.py \
  --binary NVStorage/.build/aarch64-unknown-linux-gnu/debug/NVStorageProbe
```

The full Phase 2 driver also requires every new test's discovery and runs the
independent transport fixtures/process checks. The Core compiler suite retains
issuer-only envelope construction and adds immutable profile/context-role probes
in both ordinary and same-module clients. No new unchecked conformance or public
acceptance constructor is added. Four new mutation controls must reach their
designated runtime assertion, rather than fail setup or compilation.

## Results and reuse boundaries

Local macOS arm64 / Swift 6.4:

- Selected debug suite: 28 functions passed, 22.332 s after recompiling project callers.
- Selected optimized suite: 28 functions passed, 18.467 s.
- Core compiler probes: all 65 (37 ordinary, 28 same-module) passed in both configurations.
- All five fresh-process schedules passed in debug and optimized builds.
- Independent transport fixture and legacy app build passed; the app used the
  previously approved Xcode deployment-target diagnostic override.

Local logs: `/tmp/nv-p61-transport-debug-recompiled.log`,
`/tmp/nv-p61-transport-release-final.log`,
`/tmp/nv-p61-transport-types-{debug,release}.log`,
`/tmp/nv-p61-transport-process-{debug,release}.log` and
`/tmp/nv-p61-transport-app-build.log`.

The first broader incremental debug run crashed in
`SharedSnapshotSink.emit` when reading the changed `OpenedObjectV1` layout. Its
symbolicated report was `swiftpm-testing-helper-2026-10-15-041657.ips`. Recompiling
project callers, without changing source semantics or assertions, passed that
same test and the full selected set. The failed run is excluded from qualification.
The original narrower transport run had passed; it alone did not qualify all
callers affected by the layout change.

All four targeted mutations reached their required runtime assertions in both
configurations. Artifacts under
`/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/` are
`nv-runtime-mutations-l1b2ap4l` (debug) and `nv-runtime-mutations-yfvtfkre`
(optimized). All 333 code/resource/manifest inputs in the optimized campaign
match current files; the additional Finder `.DS_Store` inventory item changed
and is explicitly excluded from that code-equality statement.

Ubuntu arm64 / Swift 6.4:

- The same 28 selected functions passed in debug (8.697 s) and optimized (1.819 s).
- All 65 Core compiler probes passed in both configurations.
- All five fresh-process schedules passed in both configurations.
- The freshly linked debug executable passed PIE, W^X, non-executable-stack and
  RELRO checks, including the RWX negative control.
- All 333 code/resource/manifest inputs matched the local qualified source set.

The first debug process attempt used an older standalone probe and failed with
`trailingBytes`; it is excluded. Explicit product builds then exposed two build
environment problems: the first omitted the pinned SQLCipher include environment,
and later SwiftPM runs returned zero while reporting cancellation. Kernel logs
confirmed that the latter runs lost `swift-frontend` to the OOM killer. A stale
`.build/debug` symlink was also preserved and replaced by SwiftPM's actual-target
link; correcting that link alone did not resolve the memory failure. No cancelled
build or old-product process run counts as a pass. The source/dependency versions,
compiler checks and linker hardening stayed unchanged.

The completed results and the excluded attempts were archived locally before
adjusting the disposable VM's memory:
`/tmp/nv-p61-transport-linux-prerestart.tar.gz`. It contains the
`nv-p61-transport-linux-{debug,release,types-debug,types-release,process-release}.log`
files, source equality log and process artifacts. After increasing the disposable
VM from 4 to 6 GiB, the unchanged strict debug product build completed in 37.09 s
and all five process schedules passed. A temporary 512-MiB swap file had been
insufficient at 4 GiB; the successful 6-GiB run used no swap. Its build, process,
ELF logs and exact process artifacts are archived locally in
`/tmp/nv-p61-transport-linux-debug-final.tar.gz`; the remote process directory was
`/tmp/nv-projection-transport-bj6ja275`.

Earlier private-observation crash tests and unrelated platform checks remain reusable
only for unchanged behavior; they do not qualify this new section. No schema,
native filesystem API, physical effect, encoded note/action preimage or modeled
safety transition changed. Full-suite, Intel-library, physical-power-loss and
complete P6.1 qualification are not claimed here.
