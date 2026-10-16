# P6.1 — Filename and descriptor qualification

Scope: the passive values in the [descriptor contract](02-projection-descriptor-contract.md),
following the [stamp qualification](01-projection-record-validation.md).
Neither this slice nor the earlier codec qualifies physical projection admission.
Later [portable placement](08-portable-projection-contract.md),
[exact encoding retention](09-exact-output-contract.md) and
[complete-binding queries](10-complete-binding-query-contract.md) have separate
qualification ledgers; the results below remain the original codec/filename scope.

## Checks and independent observations

| Check | Observation |
| --- | --- |
| `projectionDescriptorIndependentLayouts` (three cases) | Literal Python-built descriptors for NFC/NFD filenames and empty body; exact fields; every truncated prefix and trailing-byte rejection |
| `projectionLeafExactSpellingAndAliases` | Separate exact-byte equality/hash from case/normalization aliases; preserve POSIX literal colon/backslash and ordinary names near reserved names |
| `projectionLeafRejectsUnsafeNames` (13 cases) | Constructor and decoder reject empty/traversal/separator/NUL and reserved-name case variants |
| `projectionDescriptorRejectsMalformedAndWrongProfile` | Exact error classifications for unsupported header/format, excessive versus truncated lengths, invalid UTF-8 and encrypted-profile presence |
| `projectionDescriptorUsesExistingPayloadBound` | Below/at/above the existing payload ceiling; this is a wire resource bound, not a claimed physical filename capacity |
| Four additional Core construction probes | Nominal leaf type, immutable spelling/descriptor filename, distinct descriptor and stamp roles; ordinary and same-module clients |
| Three `p61-descriptor-*` mutation controls | Required assertion detects case-sensitive reservation, normalization of output spelling and Swift canonical string equality replacing exact filename equality |

The production addition is `NVStorageCore/ProjectionDescriptorV1.swift`. It adds
no persistent state, segment member, hash change, public physical permission,
native API, actor or UI behavior. P5.7's recorded results remain applicable to
their original paths. The stamp regression tests run alongside these additions;
the full Core campaign completed for that preceding slice remains recorded at
its tested inputs rather than being relabeled as a new full-suite run.

## Commands

```sh
python3 tools/check-projection-descriptor-fixtures.py
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='--no-parallel --filter projection'
make -C tests run-swift-storage SWIFT_STORAGE_TEST_FLAGS='-c release --no-parallel --filter projection'
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/release/Modules
python3 tools/test-storage-runtime-mutations.py --only p61-descriptor-reserved-name --only p61-descriptor-path-normalization --only p61-descriptor-collision-alias --timeout 900
python3 tools/test-storage-runtime-mutations.py --configuration release --only p61-descriptor-reserved-name --only p61-descriptor-path-normalization --only p61-descriptor-collision-alias --timeout 900
python3 tools/generate-test-index.py --self-test
python3 tools/generate-test-index.py --check
```

On the existing Linux native build, obtain Modules from the actual native bin
path (`.build/aarch64-unknown-linux-gnu/{debug,release}/Modules`); its old
`.build/debug` symlink points to another build-system output and is unsuitable
as a qualification input. Use the same Makefile and strict settings, with
`--jobs 2` on the VM. Preserve the existing mutation cross-product.

## Execution ledger

Local host: Apple Silicon macOS 26.6.2, Swift 6.4. On 2026-10-15:

- Independent descriptor/stamp fixtures passed.
- The combined projection suite passed: **11 functions / 31 cases**, debug
  62.833 seconds and optimized 0.600 seconds. The large synthetic wire-boundary
  case accounts for 62.720 / 0.549 seconds; ordinary descriptor cases total under
  0.03 seconds in the optimized run. These are test durations, not physical-I/O
  measurements. Logs: `/tmp/nv-p61-descriptor-{debug,release}.log`.
- Compiler probes passed in both configurations: **33 ordinary-client and 24
  same-module checks**, retaining exact diagnostic/line checks and strict flags.
  Logs: `/tmp/nv-p61-descriptor-types-{debug,release}.log`.
- All three mutation controls reported **targeted runtime failure** in both
  configurations, with passing companions. Reports under
  `/var/folders/0c/0qwr3g9n3vb8_1pn33g2xcxh0000gp/T/`:
  `nv-runtime-mutations-oryv_gfw/results.json` (debug) and
  `nv-runtime-mutations-6z5_uxh5/results.json` (optimized).
- The application build passed using the previously approved Xcode deployment
  diagnostic override, retaining macOS 11.5. Bare `build.sh` still encounters
  that known toolchain diagnostic. Logs:
  `/tmp/nv-p61-descriptor-app-build{,-override}.log`.
- Index self-tests, regeneration/completeness and `git diff --check` passed.

Ubuntu arm64 / Swift 6.4 passed the same 11 functions / 31 cases: debug 43.352
seconds and optimized 0.317 seconds, with matching source/fixture hashes.
Both Linux compiler-probe configurations passed all 33 ordinary-client and 24
same-module checks. Logs are retained on the VM under
`/tmp/nv-p61-descriptor-{debug,release,types-debug,types-release}.log` and copied
locally in `/tmp/nv-p61-descriptor-ubuntu-logs.tar`. Builds reused the existing
native workspace and dependencies; the known manifest linker/deprecated-driver
warnings remain separate from production compiler settings.
The rebuilt release probe and test executable both pass `check-storage-elf.py`
(PIE, W^X, non-executable stack, RELRO and the RWX negative control); see
`/tmp/nv-p61-descriptor-ubuntu-elf.log`.

Each mutation report records 319 copied inventory entries. All production,
test, fixture and package inputs still match; only the root Finder `.DS_Store`
changed afterward, outside the compiled/resource inputs. No mutation result is
being reused for changed production code.

The first debug run exposed a test
expectation error: the existing scalar reader reports `lengthLimit` for an
excessive declared length before checking available bytes. The test now
distinguishes that case from an in-bound but truncated declaration; production
checks were unchanged.

Exact source SHA-256:

```text
ProjectionDescriptorV1.swift 40dfc61d47a3d7ab7817b2ca52f4ae2b8dffae169a2601172e1046ca01874973
ProjectionDescriptorTests.swift 1a3ac2a8e642f24d52a97aa35f1c6cd3d463e283650c391e9a98ed3d12900880
projection-descriptor.json 62d1c84314175ae9bfb00321d4f030c575172789f1c0495d5a93e0a77b33aed7
```

## Remaining dependencies

The [third slice](03-history-observation-validation.md) now qualifies private
accepted/intended records, raw metadata presence and history-checked UTF-8 output.
Output-name generation/collision selection, general encoding preparation,
portable transport placement and standalone history-backed stamp admission
still precede mutable-file integration.
The legacy inventory identifies those responsibilities without adopting the old
heuristic identity decisions. No TLA+ transition changed, so its existing safety
conditions remain intact and TLC was not rerun for this value-codec-only slice.
