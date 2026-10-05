# Phase 3: fresh-birth Restore

The [record contract](restoration-record-contract.md) implements Restore for
HIST-01 and TC-ACT-05. A typed, store-issued source
capture supplies the prior value and exact deletion/revision references. An
ordinary complete action creates fresh births, and the same acceptance transaction
indexes its restoration provenance. `recentlyDeleted` reads that accepted evidence;
`deletions` continues to expose the retained historical entries.

## Safety and scope

- Restore uses full writer-context history validation. Ordinary current-state
  fast validation explicitly delegates restoration actions to that path.
- Each result is a fresh Create with exact source value, complete membership,
  scope maxima and prior-origin checks. Source Delete and prior revision must be
  causally observed. A transport locator, section position and identity all match.
- Multi-note Restore commits all provenance/members together. Duplicate or
  repackaged delivery adds retention coverage without repeating logical actions.
- Exclusion follows local acceptance, independently of current-row rebuilding,
  callback delivery, upload, projections and the resulting birth's continued life.
  A listing uses its captured prefix; starting a new listing observes new commits.
- Separate owners can explicitly restore the same entry into two fresh births.
  Each result survives. Only the named birth/deletion action is hidden.

The completed [connected increment](phase3-validation.md) adds alternate prior
branches, exact equal/merged/automatic prior states, general historical recovery
and compensating Undo/Redo. It preserves the same exact deletion-entry predicate.
UI, Apple version disposition and physical-file installation remain later gates.

## Executable checks

`RestorationTests.swift` exercises both profiles, two independent stores,
child-first delivery/restart, exact retry, repackaging, duplicate arrival,
simultaneous restores, source-birth/source-action specificity, ordinary-copy
non-exclusion, current-row reconstruction and subsequent edit/Delete of the fresh
birth. Actual wrong-store/session consumers reject store-issued captures.
Near-valid received objects change value, source birth/action/index, scope parents,
causal observation or fresh identity. Every rejection has a valid received
companion and checks that the source row and prior current state survive.

`RestorationCodecTests.swift` decodes the independently specified 202-byte action
fixture, checks every provenance field, round-trip bytes, truncations, missing and
duplicate mappings and incompatible action kind. `check-restoration-fixtures.py`
independently constructs its bytes. The Node envelope inspector reads both
profiles, verifies source/result values and identities, and compares retained
envelopes with SQL membership and restoration facts.

`test-storage-restoration-process.py` runs 12 schedules across both profiles:
normal, exit before commit, exit after commit before callback, exit during current
row installation, VFS write EIO and VFS SQLITE_FULL. Fresh openers receive only
selection/unlock inputs. Before-commit failure leaves the source visible; a
completed commit survives callback loss. Later current-row rebuild and deletion
of the restored birth preserve the original exclusion.

The compiler harness includes ordinary-client and same-module construction probes
for `CapturedRestoration`. Mutation controls omit the accepted provenance index,
condition exclusion on a live restored copy, and skip exact copied-value validation.
Each must fail its named assertion after a passing baseline.

## Model correspondence and limits

The existing `SegmentDeletionSafety` fresh-birth rule and
`SegmentActionRecoverySafety` complete-action/recovery rules remain unchanged.
The TLA+ review guidance was used to check that correspondence; no new model
transition or invariant was needed. As documented in the TLA README, those models
do not establish the concrete Recently Deleted list predicate. These production
codec, SQL, peer and process tests supply that additional evidence for the
supported subset; they are not a general implementation refinement proof.

These tests distinguish process termination from simulated EIO/full-disk failure;
neither qualifies physical power loss. Provider transport, editor integration and
execution on Intel macOS remain separate qualifications.

## Commands and initial-increment results

The counts and artifacts below record the original direct-state increment before
the connected layout added its optional-prior-state presence byte. Its 201-byte
fixture was an unreleased draft. The current 202-byte fixture, full-state Restore
records and complete connected results are qualified in the [Phase 3 report](phase3-validation.md).

```sh
python3 tools/test-storage-phase2.py --configuration debug
python3 tools/test-storage-phase2.py --configuration release
python3 tools/test-storage-runtime-mutations.py --only restoration-omitted-provenance-index --only restoration-requires-live-copy --only restoration-wrong-value
```

Final qualification on macOS arm64, Swift 6.4:

- Debug and optimized: **20 qualification stages passed in each configuration**,
  with **106 active Swift test functions** (the additional opt-in benchmark stays
  disabled). Both runs include all 12 Restore fresh-process schedules, the
  existing recovery campaigns and independent envelope/SQL inspection.
- All **40 compiler construction/isolation probes**, **17 schema tests**, canonical
  fixtures and strict C-boundary checks passed. The two schema copies match.
- All **three targeted Restore mutations** failed their intended assertions after
  a passing baseline: omitted provenance, exclusion depending on a live restored
  copy, and an incorrect copied value.
- The legacy app built with the previously approved Xcode 27 setting
  `__DIAGNOSE_INVALID_DEPLOYMENT_TARGET_AS_ERROR=NO`; the default build reports the
  known macOS 11.5 deployment-target diagnostic.

Ubuntu arm64, Swift 6.1.3: the optimized affected suite passed **seven functions**
(the six Restore functions plus the existing reordered-delivery history test,
**18 parameterized cases total**). All **12 fresh-process Restore schedules**
and the independent **201-byte fixture** also passed, followed by all **40
compiler probes** and **17 schema tests**. The test run used the real pinned
SQLCipher build, and preserved its artifacts under `/tmp/`.

Local final-run artifacts: `nv-storage-phase2-b79wcdma` (debug),
`nv-storage-phase2-zvigbkk5` (optimized), and `nv-runtime-mutations-my0evha_`
under the macOS temporary directory. Ubuntu process evidence is in
`/tmp/nv-storage-disk/nv-restoration-process-fly4d7ce`.
