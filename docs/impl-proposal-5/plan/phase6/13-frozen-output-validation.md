# P6.1 — Frozen output qualification

Contract: [frozen ownership and byte release](13-frozen-output-contract.md).
This qualification covers private retained inputs. It does not establish physical
installation, source accounting or completed pending-file settlement.

## Required witnesses

| Check | Independent observation |
| --- | --- |
| `projectionObservationsIndependentLayouts` | Python literal bytes for six observation states, exact decoding/encoding, all truncated prefixes, profile and absent/empty metadata distinctions |
| `projectionFrozenOwnershipRejectsContradictoryGenerations` | Frozen/latest/accepted ordering, exact same-generation output and collection/birth constraints |
| `projectionFrozenBytesRemainOwnedAfterLatestReplacement` | Direct SQL chunk bytes still contain both the frozen old output and newer intention |
| `projectionFrozenOutputPreservesSourceAcrossNewerIntentAndRestart` | A/B/D bytes and original source survive C replacement, logical Delete, complete private copy and ordinary reopening; only unowned C is released |
| `projectionByteReleaseIsAtomicAndNoteScoped` | Two notes with equal bytes stay independently owned; two cleanup failures roll back both owner and chunks; successful replacement releases only the first note's obsolete bytes; same-note identical output reuses chunks |
| `projectionFreezeChecksOwnerAndAtomicFailure` | Wrong store/session/association and stale captures reject, two freeze-write failures retain prior state, current same-state retry is idempotent, another transition stays excluded |
| Existing encoded-read race | Frozen bytes remain readable while a new intention changes the private generation; final stale-owner check rejects the delayed result |

The A accepted observation is deliberately seeded as a passive record. These tests
qualify its preservation; rooted receipt issuance remains P6.2/P6.4.

The process runner now executes ten intent-switch schedules (with/without a
frozen old output), five freeze schedules, and the existing historical UTF-8 read
after Delete. Faults are termination immediately before/after commit, ENOSPC and
EIO, each with a successful companion. The parent independently checks exact SQL
chunk keys/bytes, private generation and note values. Recovery receives only the
surviving store and selection/unlock inputs. EIO is classified by recovered exact
state rather than assumed rollback. Successful retry is required afterward.

## Commands

```sh
make -C tests run-swift-storage \
  'SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter projection'
# Repeat with -c release; Linux also uses --jobs 1.
python3 tools/check-projection-observation-fixtures.py
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
# Repeat optimized and using Linux's target-triple module path.
python3 tools/test-storage-runtime-mutations.py --configuration debug \
  --only p61-frozen-drop-owner --only p61-frozen-forget-bytes \
  --only p61-frozen-omit-write --only p61-output-stale-reader
# Repeat optimized; every existing mutation remains in the unchanged cross-product.
```

After the explicit successful [standalone product build](08-portable-projection-validation.md#commands):

```sh
python3 tools/test-projection-output-process.py --binary NVStorage/.build/debug/NVStorageProbe
# Repeat optimized and on Linux; check the final Linux ELF with check-storage-elf.py.
```

Compiler probes add ordinary and sibling-client rejection of passive-record
substitution and frozen-field mutation, retaining all earlier construction checks:
39 ordinary plus 45 same-module checks. The driver's exact total is 84. Its first
run passed every individual check but failed its obsolete `80` total; the corrected
total retains required discovery rather than relaxing a diagnostic assertion.

## Recorded results

macOS arm64 / Swift 6.4: all 70 projection functions passed debug (88.893 seconds)
and optimized (45.374 seconds). These elapsed times include concurrent qualification
load and are not performance benchmarks. Debug and optimized compiler probes passed
all 84 cases. Debug and optimized mutation controls each failed at the designated
assertion with passing baselines. Both standalone products were explicitly built
successfully and passed all 16 process schedules.
The app build passed using the previously approved deployment-target override;
its existing deployment warnings remain.

Linux arm64 / Swift 6.4: all 70 debug functions passed (21.318 seconds), and all 70
optimized functions passed (11.029 seconds). Both configurations passed all 84
compiler probes. Both standalone products built successfully and passed all 16
process schedules. Both final ELF files passed PIE, W^X, non-executable-stack and
RELRO checks, including the RWX negative control. Source/fixture SHA-256 manifests
match the local build across 235 inputs. Independent observation/transport fixtures,
mutation setup and index self-test/completeness checks passed.

Logs are `/tmp/nv-p61-frozen-*`. Debug process artifacts are
`nv-projection-output-42lw93zm` under the macOS temporary directory; debug mutation
artifacts are `nv-runtime-mutations-4ufm7d7r/results.json` there. Optimized artifacts
are `nv-projection-output-qe7347lp` and `nv-runtime-mutations-_lo38l4x/results.json`.
Linux process artifacts are `/tmp/nv-projection-output-zh6bgh8d` (debug) and
`/tmp/nv-projection-output-y382mp6w` (optimized); copied logs and matching manifests
are `/tmp/nv-p61-frozen-linux-*` and `/tmp/nv-p61-frozen-local.sha256`.

## Reuse and remaining scope

Swift inputs were frozen before builds. The broad projection selection reruns
history, description production/retention, encoding, private observation and
repair consumers affected by the record change. Native encoding API experiments,
unrelated phase results, Core evidence boundaries and epoch-4 paths are unchanged
and retain their prior qualification; no new C or Apple API is used.

`PendingReferenceSafety` still checks frozen/latest retention, recoverable byte
ownership and stale reference switches; `ProjectionTransitionSafety` separately
checks A/B/C publication and exact source-accounting obligations. Their effective
runner configurations and assertions remain unchanged. Static correspondence and
new executable SQL witnesses supplement, rather than replace or broaden, the
recorded finite model results. Physical power-loss behavior remains unqualified.

The subsequent [settlement/platform report](14-settlement-record-validation.md)
qualifies the complete private settlement-transfer mapping and finished Intel
library paths. A frozen record remains preserved
until checked settlement can transfer its owners. It does not restore consent,
automatically perform file effects after restart or complete a pending import.
This earlier report's Intel check established availability only; use that later
report for the completed executable qualification.
