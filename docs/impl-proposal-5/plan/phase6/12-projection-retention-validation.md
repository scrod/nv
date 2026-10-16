# P6.1 — Description retention qualification

Contract: [local producer and retention coverage](11-projection-producer-contract.md#retention-coverage).
This increment closes the measured repeated-description startup-growth issue.
Private settlement/frozen byte ownership has separate qualification in the
[P6.1 completion ledger](06-completion-ledger.md).

## Evidence and boundaries

`projectionProducerRetentionBoundsStartupAndAcceptanceWork` keeps two notes and
their logical history fixed while accepting 64 real produced descriptions. At
1/8/64 it reopens the store, checks actual retained-leaf and history-read counters,
and compares notes and authoring context independently with their initial values.
Every dependency set is compared with the previous exact envelope plus the source
occurrences. Every old envelope remains byte-identical. Exceptional current-row
reconstruction is a separate required companion. Acceptance counters must remain
fixed after the first link, with zero graph loads, recursive SQL or ancestry walks.

`projectionProducerRetentionPreservesConcurrentTipsAndDelayedJoin` uses two
independent producers. A frozen capture followed by another arrival preserves the
uncovered tip. A later envelope covers both. A third store receives the join first,
one branch later, then restarts before the last prerequisite arrives. It must
complete without another join delivery, preserve exact bytes, and produce the same
independently checked note values/context.

`projectionProducerRetentionRejectsDamagedParentBeforeCoverage` corrupts a parent
before validation and, separately, after validation but before acceptance. The
test explicitly disables the immutable-row trigger for this later-corruption fault.
The production owner blocks further use; a separate raw connection checks unchanged
acceptance/frontier and absent child edges. Reopening must report required-history
damage. `projectionProducerRetentionRejectsMisaddressedCoverage` challenges exact
locator and object-kind checks with valid subsequent companions.

The existing producer tests still exercise exact retry, pending-byte ownership,
changed private/history inputs, wrong session, actual cancellation and missing
callbacks. The process driver now seeds an accepted parent description before
each success/exit-before/exit-after/ENOSPC/EIO schedule. Its independent parser
checks both declared dependencies, retained older bytes, atomic membership/frontier,
and ordinary fresh-process recovery. `--retention-growth` now requires bounded
leaves and a growing retained-byte inventory; the earlier unbounded diagnostic
and recorded timings remain in [report 11](11-projection-producer-validation.md).

Compiler checks add ordinary-client and sibling-file denial of the new private
`CheckedProjectionCoverage` type, bringing the private-boundary driver to 80
checks. Three added mutations omit frontier capture, parent validation or the
final parent recheck. The original four producer mutations remain unchanged.

## Commands

```sh
make -C tests run-swift-storage \
  'SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter projectionProducer'
# Repeat with -c release; Linux uses --jobs 1.
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
# Repeat with optimized modules and Linux's target-triple directories.
python3 tools/test-storage-runtime-mutations.py --configuration debug \
  --only p61-coverage-capture --only p61-coverage-verify --only p61-coverage-final-check
# Repeat optimized. Preserve the original producer controls and cross-product.
```

After the [explicit standalone product build](08-portable-projection-validation.md#commands):

```sh
python3 tools/test-projection-producer-process.py --binary NVStorage/.build/debug/NVStorageProbe
python3 tools/test-projection-producer-process.py --binary NVStorage/.build/release/NVStorageProbe --retention-growth
```

## Model correspondence and reuse

The existing `SnapshotRetentionCoverageSafety` transitions already separate
captured immutable parents, exact verification, final recheck, atomic edges/frontier,
callbacks and restart. The new Changes-description coverage uses those same graph
rules; it retains a separate snapshot-root frontier. This is correspondence for
the generic retention obligation, not a new whole-program refinement proof or a
proof of projection encodings/physical installation. Existing model configurations,
assertions and completed runs remain unchanged. Executable tests above provide
the additional concrete witnesses and scheduling intersections.

Source-binding/encoding fixtures, prior ordinary-action/compiler guarantees and
native encoding API results are reused only within their recorded unchanged scope.
No new Apple API assumption, schema, codec version or public result shape is added.
Physical power loss and final Intel library qualification remain explicit separate
gates. Returning startup and acceptance counters exclude exceptional reconstruction;
frontier width and actual source-reconstruction complexity still matter.

## Execution record

Initial corruption-test development caught the immutable-row SQL trigger, then
the production owner's post-damage read fence. The final test uses explicit later
corruption injection and an independent raw observer; production checks remain intact.

All eleven producer functions (20 parameterized/single cases) passed on macOS
arm64 / Swift 6.4 in debug (15.089 s) and optimized (14.845 s), and Linux arm64 /
Swift 6.4 in debug (1.716 s) and optimized (0.633 s). Each configuration on both
hosts passed all 80 compiler probes: 37 ordinary and 43 sibling-module checks.
SHA-256 inventories match across 235 package/source/test/fixture files, excluding
Finder metadata and its AppleDouble copies.

Both standalone product configurations completed explicitly on both hosts. Each
passed all five linked-description process schedules. Linux products passed PIE,
W^X, non-executable-stack and RELRO checks, including the RWX negative control.
The toolchain's manifest-linker warning remains separate from those checked final
ELFs. The legacy app build passed using the previously approved deployment override.
Independent transport/observation fixtures, mutation setup and validation-index
self-test/completeness checks passed. No C boundary or model transition changed.

All three new mutants and the existing `actor-final-prefix` control failed at
their intended runtime assertions in debug and optimized builds, with passing
companions. The actor mutation's text match now includes its neighboring acceptance
call so it uniquely targets the same original fence despite the new parent-prefix
check; its behavior/assertion/cross-product is unchanged. Reports:
`nv-runtime-mutations-j196rese/results.json` and
`nv-runtime-mutations-8kkrt54t/results.json` under the macOS temporary directory.
The earlier four producer controls remain reusable at their unchanged checks.

### Work bounds and timings

At 1/8/64 descriptions, returning startup checks exactly **two** envelopes: the
bootstrap root and newest description. It reads zero historical bodies and builds
zero history graphs. After the first link, acceptance reads three historical
envelopes, records four envelope decodes and checks one additional parent; those
counts remain fixed through 64 descriptions. Ancestor visits, graph construction
and recursive SQL are zero. Every old description remains byte-identical and the
separate full reconstruction companion passes.

The optimized independent process experiment observed 2/2/2 frontier entries
instead of the earlier 2/9/65. Whole-child warm-open medians were 15.48/14.28/28.87 ms
(three repetitions, including process startup). Concurrent compiler qualification
and host I/O make these unsuitable for a latency-improvement claim. The verified
improvement is the eliminated history-proportional envelope checking; SQLite lookup,
live frontier width, source validation and normal journal costs remain.

Artifacts under the macOS temporary directory:
`nv-projection-producer-f2dpagr0` (debug process),
`nv-projection-producer-hzn69imk` (optimized process), and
`nv-projection-producer-omvkmf5k/growth.json` (growth).
Logs are `/tmp/nv-p61-coverage-*`; Linux process artifact paths are recorded in
the copied `nv-p61-coverage-linux-process-{debug,release}.log` files. The source
hash manifests are `/tmp/nv-p61-coverage-{local,linux}.sha256`.

This closes the repeated-description retention-growth gate. Subsequent
[frozen ownership](13-frozen-output-validation.md) and
[settlement/platform qualification](14-settlement-record-validation.md) close the
remaining P6.1 record gates. Physical file installation and power-loss
qualification retain their separate boundaries.
