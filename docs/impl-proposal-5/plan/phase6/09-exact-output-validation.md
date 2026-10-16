# P6.1 — Exact encoded-output qualification

Contract: [exact output and private chunks](09-exact-output-contract.md).
This extends the previously qualified accepted/intended record writer. Later
[complete queries](10-complete-binding-query-validation.md) and the
[local producer](11-projection-producer-validation.md) add their own qualification.
Physical receipts, producer retention growth and settlement-owner cleanup retain
separate gates in the [completion ledger](06-completion-ledger.md).

## Cases and observations

The focused suite includes 17 functions. New coverage includes:

- The production preparer versus 98 fixed legacy NSString observations (14
  encodings × seven input spellings), recorded independently on macOS 11/14/26
  and Linux. Per-platform native conversion outcomes are explicit; the rejected
  same-encoding-ID byte-reconstruction hypothesis remains rejected.
- Independent UTF-8, UTF-16 external/BOM, Mac Roman, embedded NUL and promotion
  expectations, plus exact canonical captured-output framing and every truncated
  prefix. An encoder's own round trip is not the oracle.
- Actual intent retention, fresh reopen and complete backup with exact encoded
  bytes and unchanged canonical note spelling. Encrypted provider mode retains
  its existing rejection; plaintext-provider collections still use keyed private
  SQLCipher pages.
- Below/at/above 1-MiB chunk boundaries and a multiple-chunk output. Two injected
  failures after chunk insertion but before owner insertion leave neither new
  chunks nor a new owner. Successful retry preserves every exact byte.
- Missing chunks, unsupported chunk codecs, same-size altered bytes, wrong store,
  old session and stale private generations. A controlled paused read followed by
  a newer intent must fail at its final ownership check.
- Complementary repair includes encoded bytes from the secondary source in either
  source order. Same-birth conflicting observations remain incomplete.

`test-projection-output-process.py` independently observes success, termination
before/after commit, ENOSPC and ambiguous EIO. Reopening receives only surviving
selection/unlock inputs. Python computes the expected UTF-16 bytes, digest keys,
chunk inventory and old/new atomic alternatives independently; canonical notes
must retain the edit even if its projection intent did not commit. Stored data
and ownership must agree before retrying unrelated/new output.

The same script exports a Mac-produced synthetic private store containing NFD
`e + acute` as Mac Roman `8e`, and checks that store on Linux. Linux's native
lossless encoder rejects this particular request in the recorded experiment.
Successful receiver recovery must still return `8e`, while retaining the original
NFD note spelling, rather than regenerating UTF-8 or changing note history.

Compiler probes cover immutable prepared bytes, exact text issuer construction,
and the existing current/private evidence boundaries. The private suite increases
from 58 to 60 checks; Core increases from 65 to 69. Existing checks remain intact.
Five targeted mutations challenge final read ownership, aggregate digest checks,
omitted chunk persistence, lossy conversion and complementary repair.

## Commands

```sh
make -C tests run-swift-storage \
  'SWIFT_STORAGE_TEST_FLAGS=-c debug --no-parallel --filter projectionText --filter projectionEncoded --filter projectionObservations --filter projectionIntent'
# Repeat with -c release; the Linux VM uses --jobs 1.
python3 tools/check-projection-observation-fixtures.py
python3 tools/test-swift-storage-types.py --modules NVStorage/.build/debug/Modules
python3 tools/test-storage-private-types.py --modules NVStorage/.build/debug/Modules
# Repeat against release modules.
python3 tools/test-projection-output-process.py --binary NVStorage/.build/debug/NVStorageProbe
# Repeat against the optimized probe after an explicit successful product build.
python3 tools/test-storage-runtime-mutations.py --configuration debug \
  --only p61-output-stale-reader --only p61-output-ignore-digest \
  --only p61-output-omit-bytes --only p61-output-lossy-conversion \
  --only p61-repair-drop-complement-observation
# Repeat with --configuration release; the existing cross-product is unchanged.
```

Use the [probe build commands and completion checks](08-portable-projection-validation.md#commands),
including pinned SQLCipher, strict compiler flags and Linux linker hardening.
For the cross-host case, export to a new directory on macOS, copy that closed
synthetic directory intact to Linux, then run `--check-cross-host` there:

```sh
python3 tools/test-projection-output-process.py --binary NVStorage/.build/debug/NVStorageProbe \
  --export-cross-host /tmp/nv-p61-output-macos-crosshost
python3 tools/test-projection-output-process.py --binary NVStorage/.build/aarch64-unknown-linux-gnu/debug/NVStorageProbe \
  --check-cross-host /tmp/nv-p61-output-macos-crosshost
```

## Results and boundaries

The complete 17-function selection passed on macOS arm64 / Swift 6.4 in debug
(11.222 s) and optimized (11.755 s), and on Ubuntu arm64 / Swift 6.4 in debug
(2.469 s) and optimized (1.068 s). Each run includes the 98 independently recorded
encoding observations. Both configurations on both platforms passed all five
fresh-process failure schedules, all 69 Core compiler probes and all 60 private
compiler probes at this increment's source state. Linux ELF checks passed.

All five targeted mutations reached their designated runtime assertions in debug
and optimized builds, with passing companions. Debug evidence comprises
`nv-runtime-mutations-iw237dbg` and `nv-runtime-mutations-9a77kn9z`; optimized
evidence is `nv-runtime-mutations-x4efptep`, under the macOS temporary directory.
The independent private-output fixture passed. The legacy app build passed using
the previously approved deployment-target diagnostic override.

The actual Mac-to-Linux private-store transfer passed using both Linux probes:
Mac Roman byte `8e` was retained exactly while the note remained NFD `e + acute`.
The initial cross-host script compared the note list using Python ordering against
Swift's differently ordered list. It was corrected to sort the observed list in
Python; both exact note spellings and exact output bytes remain required.

Logs: `/tmp/nv-p61-output-{debug,release}-qualified.log`,
`/tmp/nv-p61-output-{core,private}-types-{debug,release}.log`,
`/tmp/nv-p61-output-process-{debug,release}.log`, and on Ubuntu,
`/tmp/nv-p61-output-linux-{debug,release}-final.log`,
`/tmp/nv-p61-output-linux-{core,private}-types-{debug,release}.log`,
`/tmp/nv-p61-output-linux-process-{debug,release}.log`,
`/tmp/nv-p61-output-linux-crosshost-{debug,release}.log`.
The later [complete-binding reader](10-complete-binding-query-contract.md) adds
source-query and whole-output consumers with separately recorded qualification;
these results retain their original scope.

Superseded encoded chunks remain retained pending explicit settlement-owner
accounting. No automatic garbage collection, physical replacement or global
descriptor scan is introduced. Existing TLA+ captured-byte/atomic-intent premises
remain unchanged; executable SQL/process evidence qualifies this mapping rather
than rerunning unchanged models. This report does not claim complete P6.1,
Intel-library runtime qualification or physical power-loss durability.
