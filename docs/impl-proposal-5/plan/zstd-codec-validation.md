# Zstd-only new storage compression

Date: 2026-09-14. The adopted [compression profile](../Encryption.md#compression-profile)
replaces the unreleased provider-envelope zlib encoding with zstd. It also makes
zstd the rule for future compressed private records. Uncompressed records remain
valid; this does not enable the still-unqualified current-row dictionary adapter.

## Concrete mapping

- `ObjectCompressionV1` fixes `none = 0`, `zstd = 1`. There is no new-format zlib
  reader, writer or negotiation path. No existing released segment collection
  needs compatibility with the discarded development bytes.
- `ZstdFrameV1` uses pinned, statically embedded zstd 1.5.7,
  `f8745da6ff1ad1e7bab384bd1f9d742439278e99`. The upstream C sources are preserved
  under their BSD license; `CZlib` and its system-library dependency are removed.
- The writer uses level 3 and a self-contained frame. Readers require explicit
  exact content size, dictionary-free input, bounded window/output, one regular
  frame and complete consumption. Checksums may be absent or valid, not corrupt.
- Authentication precedes frame interpretation. Compression changes exact
  envelope hashes, not semantic operation IDs. Retry still retains exact bytes.
- SQLCipher encrypts pages; it does not compress note data. Legacy epoch-4
  database/WAL paths and historical zlib benchmark controls remain intact. They
  do not define a codec for new segment collections. Node's Zstandard API lives
  in the module named `node:zlib`; its name does not imply use of DEFLATE.

## Tests and independent observations

`ObjectEnvelopeTests` retain all earlier scope, key, truncation, byte-damage and
framing checks. Added cases exercise literal raw-block and checksummed frames,
empty contents, exact 64-MiB output (repeated and poorly compressible data),
over-limit input, both sides of the window
limit, unknown content size, dictionary fields (including zero IDs), reserved
bits, skippable frames, empty second frames, trailing data and legacy zlib bytes.
Near-valid malformed frames have valid outer authentication in **both** suites;
their bad-authentication companions require authentication failure first.

`check-envelope-fixtures.mjs` reconstructs the twelve literal envelopes using
independent crypto and a frozen valid raw-block frame. It does not require new
encoder versions to reproduce the same compressed representation.
`NVStorageProbe zstd-envelopes` invokes the real sealer for all three object kinds,
both suites and empty/nonempty payloads. `check-zstd-frames.mjs` checks twelve
distinct cases, independently decrypts/verifies them and compares the decoded
bytes to its own expected payload. Its separate block-boundary parser rejects
extra frames before calling Node's bounded zstd decoder. Production recovery
receives none of these expected values or reports.

`test-zstd-mutations.py` builds an isolated baseline and then independently removes
five guards: exact frame boundary, dictionary-field exclusion, known content size,
window ceiling and authenticate-before-decompress. All five produced the intended
assertion failures. A compile/setup failure, absent test or unrelated assertion
does not count. `test-storage-phase2.py --mutations` includes this campaign.

## Executed evidence

| Environment | Checks | Result |
| --- | --- | --- |
| Development Mac, arm64 / Swift 6.3.3 | Full debug and optimized Swift suites | 75 tests passed in each configuration |
| Development Mac | Optimized qualification driver | 15 commands passed, including 72 fresh-process scenarios, 46 independent SQL/envelope inspections, 21 Core and 22 Runtime compiler probes, schema and fixture checks |
| Development Mac | AddressSanitizer, new embedded C codec plus Swift boundary | Five focused tests passed, including both suites and 64-MiB output |
| Development Mac | Codec mutations | All five failed at their intended assertions after a valid baseline |
| Intel macOS 11.7.11 and 14.8.9 | 11.5-targeted optimized writer, embedded zstd | Twelve envelopes per host independently verified; no external libzstd dependency |
| Ubuntu arm64 / Swift 6.1.3 / SQLCipher OpenSSL | Optimized Swift suite, compiler probes, writer and process recovery on ext4 | 75 tests passed; all 21 Core and 22 Runtime compiler probes passed; twelve writer envelopes and all 46 SQL/envelope reports from 72 process scenarios independently verified |
| Legacy application | `build.sh` and `test-epoch4-v5-compatibility.sh` | Passed |

Local logs use `/tmp/nv-zstd-*`. The optimized driver report is
`nv-storage-phase2-g5dtzp_b` and mutation artifacts are `nv-zstd-mutations-_q3kdue9`
under the development Mac's system temporary directory. Intel binaries are in
`/tmp/nv-zstd-intel-build/`; the remote bundle is `/tmp/nv-zstd-intel-qualification/`
on each Mac. Their inspected reports are `/tmp/nv-zstd-macos11-envelopes.json`
and `/tmp/nv-zstd-macos14-envelopes.json` on the development Mac.

Ubuntu source is `/tmp/nv-storage-disk/nv-zstd-platform.ywqjrK/`; its build is
`/tmp/nv-storage-disk/nv-zstd-build/`. The first returning build exhausted the old
tmpfs quota. Copying it to ext4 then exposed Clang's non-relocatable module cache;
the old cache was preserved as `ModuleCache.pre-zstd`, and a new cache built in
place. Those failed setup attempts are not credited test results. The native
linker's RWX LOAD-segment warning also occurs in the pre-zstd binary and logs;
it remains a Linux toolchain/release-hardening issue, not a codec-contract waiver.
Native process stores are `/tmp/nv-storage-disk/nv-storage-process-dhhj1jt2/`;
independently checked reports are `/tmp/nv-zstd-linux-process-reports/` on the
development Mac. The twelve Linux writer envelopes are
`/tmp/nv-zstd-linux-envelopes.json`. All remote files are synthetic and retained.
The final payload-headroom extension also passed a focused debug run on the Mac;
its log is `/tmp/nv-zstd-payload-headroom.log`.

The actual storage protocol transitions and safety predicates are unchanged.
TLA+ models abstract bounded validated envelopes; they do not prove compression
or C memory safety, and were not rerun for this codec substitution. No physical
power-loss qualification or new provider/application integration is claimed.

## Compiler diagnostic compatibility

The Runtime construction probe now accepts the two exact known diagnostics for
private `HistoryUnit`: Swift 6.3's private-protection message and Swift 6.1's
`cannot find 'HistoryUnit' in scope`. It still requires failure at the marked
source line. New classifier controls reject success, another line/symbol and
compiler/setup failures. The 60-second compiler deadline and production access
control are unchanged; this supports both compilers rather than selecting one.
All 22 Runtime probes and their classifier controls passed on both Swift 6.1.3
and 6.3.3. All 21 Core probes passed on each platform as well.
